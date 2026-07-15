//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"

const std = @import("std");

const debug = std.debug;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const ArrayList = std.ArrayList;
const BitStack = std.BitStack;

/// Theoretical max 4Gb file size
const Size = u32;

const PieceTbl = struct {
    // bit aliases.
    const original: u1 = 0;
    const add: u1 = 1;

    const Piece = packed struct(u64) { start: Size, len: Size };

    // TODO: v0.16, I imagine we may have to vendor this soon, API feels old
    tags: BitStack,
    pieces: ArrayList(Piece),

    fn init(a: mem.Allocator) !@This() {
        const initialCapacity = 4096; // TODO: arbitrary

        var tags = BitStack.init(a);
        try tags.ensureTotalCapacity(initialCapacity);

        return .{
            .pieces = try ArrayList(Piece).initCapacity(a, initialCapacity),
            .tags = tags,
        };
    }

    fn deinit(self: *@This(), a: mem.Allocator) void {
        self.tags.deinit();
        self.pieces.deinit(a);
    }

    fn appendOriginal(self: *@This(), a: mem.Allocator, piece: Piece) !void {
        try self.tags.push(original);
        try self.pieces.append(a, piece);
    }
};

const Self = @This();

/// A buffer to the original text document. This buffer is read-only.
original_buf: []const u8,
/// A buffer to a temporary file. This buffer is append-only.
add_buf: ArrayList(u8),
piece_tbl: PieceTbl,

pub fn init(a: mem.Allocator, original_buf: []const u8) !Self {
    var pieces = try PieceTbl.init(a);

    try pieces.appendOriginal(a, .{
        .start = 0,
        .len = math.cast(Size, original_buf.len) orelse
            debug.panic("File is {d} bytes long; must be less than {d}", .{
                original_buf.len,
                math.maxInt(Size),
            }),
    });
    return .{
        .original_buf = original_buf,
        .add_buf = .empty,
        .piece_tbl = pieces,
    };
}

pub fn deinit(self: *Self, a: mem.Allocator) void {
    self.add_buf.deinit(a);
    self.piece_tbl.deinit(a);
}

test "init & deinit with no leaks" {
    try testing.fuzz(testing.allocator, struct {
        fn run(a: mem.Allocator, smith: *testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];

            var file = try Self.init(a, input);
            defer file.deinit(a);
        }
    }.run, .{});
}
