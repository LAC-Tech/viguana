const std = @import("std");
const core = @import("core.zig");
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;

/// Terminal UI: owns raw mode and ECMA-48 rendering. No io_uring.
pub const Tui = struct {
    allocator: mem.Allocator,
    stdin_fd: i32,
    original_termios: posix.termios,
    render_buffer: std.ArrayList(u8),

    pub fn init(allocator: mem.Allocator, stdin_fd: i32) !Tui {
        const original_termios = try posix.tcgetattr(stdin_fd);
        var raw = original_termios;
        setRawMode(&raw);
        try posix.tcsetattr(stdin_fd, .FLUSH, raw);

        return .{
            .allocator = allocator,
            .stdin_fd = stdin_fd,
            .original_termios = original_termios,
            .render_buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Tui) void {
        _ = posix.tcsetattr(
            self.stdin_fd,
            .FLUSH,
            self.original_termios,
        ) catch unreachable;
        self.render_buffer.deinit(self.allocator);
    }

    /// Query the terminal size. The returned slice is valid until the next
    /// call to render.
    pub fn getSize(self: *Tui) !core.Size {
        _ = self;
        var ws: posix.winsize = undefined;
        const rc = linux.ioctl(
            std.Io.File.stdout().handle,
            linux.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (linux.errno(rc) != .SUCCESS) return error.IoctlFailed;
        return .{ .width = ws.col, .height = ws.row };
    }

    /// Build a fresh ECMA-48 render buffer for the current editor state.
    /// The returned slice is valid until the next call to render.
    pub fn render(self: *Tui, editor: *core.Editor) ![]const u8 {
        const size = try self.getSize();
        editor.setScreenSize(size);

        self.render_buffer.clearRetainingCapacity();

        // Clear screen and move cursor to top-left.
        try self.appendString("\x1b[2J");
        try self.appendString("\x1b[1;1H");

        const info = editor.renderInfo();

        // Draw visible buffer lines.
        var row: usize = 0;
        while (row < info.view_height) : (row += 1) {
            if (editor.getVisibleLine(self.allocator, row)) |line| {
                defer self.allocator.free(line);
                try self.appendString(line);
            }
            try self.appendString("\r\n");
        }

        // Draw command line when in command mode.
        if (editor.mode == .command) {
            const cmd_line = (try editor.getCommandLine(self.allocator)) orelse "";
            defer self.allocator.free(cmd_line);
            try self.appendFormat("\x1b[{d};1H", .{editor.screen.height});
            try self.appendString(cmd_line);
        }

        // Position cursor.
        if (editor.mode == .command) {
            const col = editor.command.items.len + 2;
            try self.appendFormat("\x1b[{d};{d}H", .{
                editor.screen.height,
                col,
            });
        } else {
            const cursor = info.cursor_screen;
            try self.appendFormat("\x1b[{d};{d}H", .{
                cursor.row + 1,
                cursor.col + 1,
            });
        }

        return self.render_buffer.items;
    }

    fn appendString(self: *Tui, s: []const u8) !void {
        try self.render_buffer.appendSlice(self.allocator, s);
    }

    fn appendFormat(
        self: *Tui,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        var buf: [256]u8 = undefined;
        const written = try std.fmt.bufPrint(&buf, fmt, args);
        try self.appendString(written);
    }
};

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
