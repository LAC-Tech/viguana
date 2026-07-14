const std = @import("std");
const viguana = @import("viguana");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const filename: []const u8 = if (args.len > 1) args[1] else "new_file";

    try viguana.run(allocator, init.io, filename);
}
