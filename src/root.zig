const std = @import("std");

pub const core = @import("core.zig");

/// Run the terminal editor shell for the given file path.
pub fn run(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
    const shell = @import("shell.zig");
    try shell.run(allocator, io, filename);
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
