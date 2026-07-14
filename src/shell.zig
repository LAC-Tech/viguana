const std = @import("std");
const core = @import("core.zig");
const tui = @import("tui.zig");
const linux = std.os.linux;
const mem = std.mem;
const Io = std.Io;

pub const Shell = struct {
    allocator: mem.Allocator,
    io: Io,
    ring: linux.IoUring,
    stdin_fd: i32,
    stdout_fd: i32,
    editor: core.Editor,
    terminal: tui.Tui,
    input_buffer: [256]u8,
    running: bool,

    const READ_UD: u64 = 0;
    const WRITE_UD: u64 = 1;

    pub fn init(
        allocator: mem.Allocator,
        io: Io,
        filename: []const u8,
    ) !Shell {
        const text = try readFile(allocator, io, filename);
        defer allocator.free(text);

        const stdin_fd = Io.File.stdin().handle;
        const stdout_fd = Io.File.stdout().handle;

        var terminal = try tui.Tui.init(allocator, stdin_fd);
        errdefer terminal.deinit();

        const size = try terminal.getSize();
        var editor = try core.Editor.init(allocator, text, filename, size);
        errdefer editor.deinit(allocator);

        var ring = try linux.IoUring.init(16, 0);
        errdefer ring.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .ring = ring,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .editor = editor,
            .terminal = terminal,
            .input_buffer = undefined,
            .running = true,
        };
    }

    pub fn deinit(self: *Shell, allocator: mem.Allocator) void {
        self.ring.deinit();
        self.editor.deinit(allocator);
        self.terminal.deinit();
    }

    pub fn run(self: *Shell) !void {
        try self.render();
        while (self.running) {
            try self.submitRead();
            const cqe = try self.ring.copy_cqe();
            try self.handleCqe(cqe);
        }
    }

    fn submitRead(self: *Shell) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_read(self.stdin_fd, self.input_buffer[0..], 0);
        sqe.user_data = READ_UD;
        _ = try self.ring.submit();
    }

    fn submitWrite(self: *Shell, data: []const u8) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_write(self.stdout_fd, data, 0);
        sqe.user_data = WRITE_UD;
        _ = try self.ring.submit();
    }

    fn handleCqe(self: *Shell, cqe: linux.io_uring_cqe) !void {
        if (cqe.user_data == READ_UD) {
            if (cqe.res <= 0) return;
            const bytes = self.input_buffer[0..@intCast(cqe.res)];
            try self.processInput(bytes);
        } else if (cqe.user_data == WRITE_UD) {
            // Write completed; ignore.
        }
        if (self.running) {
            try self.render();
        }
    }

    fn processInput(self: *Shell, bytes: []const u8) !void {
        // V1: one byte per key, no escape sequences beyond bare Esc.
        for (bytes) |b| {
            const key = [1]u8{b};
            if (try self.editor.handleKey(self.allocator, &key)) |effect| {
                try self.handleEffect(effect);
            }
        }
    }

    fn handleEffect(self: *Shell, effect: core.Effect) !void {
        switch (effect) {
            .quit => self.running = false,
            .save => try self.saveFile(),
            .message => |msg| {
                std.log.err("{s}", .{msg});
                self.allocator.free(msg);
            },
        }
    }

    fn saveFile(self: *Shell) !void {
        const text = try self.editor.file.toString(self.allocator);
        defer self.allocator.free(text);
        try writeFile(self.io, self.editor.filename, text);
        self.editor.dirty = false;
    }

    fn render(self: *Shell) !void {
        const buffer = try self.terminal.render(&self.editor);
        try self.submitWrite(buffer);
        _ = try self.ring.copy_cqe(); // Wait for write completion.
    }
};

fn readFile(allocator: mem.Allocator, io: Io, filename: []const u8) ![]u8 {
    const file = Io.Dir.openFile(
        .cwd(),
        io,
        filename,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => |e| return e,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size = @as(usize, @intCast(stat.size));
    const text = try allocator.alloc(u8, size);
    errdefer allocator.free(text);
    _ = try file.readPositionalAll(io, text, 0);
    return text;
}

fn writeFile(io: Io, filename: []const u8, data: []const u8) !void {
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = filename, .data = data });
}

pub fn run(allocator: mem.Allocator, io: Io, filename: []const u8) !void {
    var shell = try Shell.init(allocator, io, filename);
    defer shell.deinit(allocator);
    try shell.run();
}
