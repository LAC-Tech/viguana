const std = @import("std");
const core = @import("core.zig");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const Dir = Io.Dir;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    io: Io,
    ring: linux.IoUring,
    stdin_fd: i32,
    stdout_fd: i32,
    editor: core.Editor,
    render_buffer: std.ArrayList(u8),
    input_buffer: [256]u8,
    running: bool,
    original_termios: posix.termios,

    const READ_UD: u64 = 0;
    const WRITE_UD: u64 = 1;

    pub fn init(allocator: std.mem.Allocator, io: Io, filename: []const u8) !Shell {
        const text = try readFile(allocator, io, filename);
        defer allocator.free(text);

        const size = try getTerminalSize();
        var editor = try core.Editor.init(allocator, text, filename, size);
        errdefer editor.deinit();

        var ring = try linux.IoUring.init(16, 0);
        errdefer ring.deinit();

        const stdin = Io.File.stdin().handle;
        const stdout = Io.File.stdout().handle;
        const original_termios = try posix.tcgetattr(stdin);
        var raw = original_termios;
        setRawMode(&raw);
        try posix.tcsetattr(stdin, .FLUSH, raw);

        const render_buffer = std.ArrayList(u8).empty;

        return .{
            .allocator = allocator,
            .io = io,
            .ring = ring,
            .stdin_fd = stdin,
            .stdout_fd = stdout,
            .editor = editor,
            .render_buffer = render_buffer,
            .input_buffer = undefined,
            .running = true,
            .original_termios = original_termios,
        };
    }

    pub fn deinit(self: *Shell) void {
        _ = posix.tcsetattr(self.stdin_fd, .FLUSH, self.original_termios) catch {};
        self.ring.deinit();
        self.editor.deinit();
        self.render_buffer.deinit(self.allocator);
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
            if (try self.editor.handleKey(&key)) |effect| {
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
        const text = try self.editor.table.toString(self.allocator);
        defer self.allocator.free(text);
        try writeFile(self.io, self.editor.filename, text);
        self.editor.dirty = false;
    }

    fn render(self: *Shell) !void {
        const size = try getTerminalSize();
        self.editor.setScreenSize(size);

        self.render_buffer.clearRetainingCapacity();

        // Clear screen and move cursor to top-left.
        try self.appendString("\x1b[2J");
        try self.appendString("\x1b[1;1H");

        const info = self.editor.renderInfo();

        // Draw visible buffer lines.
        var row: usize = 0;
        while (row < info.view_height) : (row += 1) {
            if (self.editor.getVisibleLine(self.allocator, row)) |line| {
                defer self.allocator.free(line);
                try self.appendString(line);
            }
            try self.appendString("\r\n");
        }

        // Draw command line when in command mode.
        if (self.editor.mode == .command) {
            const cmd_line = (try self.editor.getCommandLine(self.allocator)) orelse "";
            defer self.allocator.free(cmd_line);
            try self.appendFormat("\x1b[{d};1H", .{self.editor.screen.height});
            try self.appendString(cmd_line);
        }

        // Position cursor.
        if (self.editor.mode == .command) {
            const col = self.editor.command.items.len + 2;
            try self.appendFormat("\x1b[{d};{d}H", .{ self.editor.screen.height, col });
        } else {
            const cursor = info.cursor_screen;
            try self.appendFormat("\x1b[{d};{d}H", .{ cursor.row + 1, cursor.col + 1 });
        }

        try self.submitWrite(self.render_buffer.items);
        _ = try self.ring.copy_cqe(); // Wait for write completion.
    }

    fn appendString(self: *Shell, s: []const u8) !void {
        try self.render_buffer.appendSlice(self.allocator, s);
    }

    fn appendFormat(self: *Shell, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const written = try std.fmt.bufPrint(&buf, fmt, args);
        try self.appendString(written);
    }
};

fn readFile(allocator: std.mem.Allocator, io: Io, filename: []const u8) ![]u8 {
    const file = Dir.openFile(.cwd(), io, filename, .{}) catch |err| switch (err) {
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
    try Dir.writeFile(.cwd(), io, .{ .sub_path = filename, .data = data });
}

fn getTerminalSize() !core.Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(Io.File.stdout().handle, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS) return error.IoctlFailed;
    return .{ .width = ws.col, .height = ws.row };
}

fn setRawMode(termios: *posix.termios) void {
    termios.iflag.IGNBRK = false;
    termios.iflag.BRKINT = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INLCR = false;
    termios.oflag.OPOST = false;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@intFromEnum(linux.V.MIN)] = 1;
    termios.cc[@intFromEnum(linux.V.TIME)] = 0;
}

pub fn run(allocator: std.mem.Allocator, io: Io, filename: []const u8) !void {
    var shell = try Shell.init(allocator, io, filename);
    defer shell.deinit();
    try shell.run();
}
