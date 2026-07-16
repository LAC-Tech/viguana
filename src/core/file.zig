//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"
//! Implemented with piece tables:
//! https://www.cs.unm.edu/~crowley/papers/sds.pdf

//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const ta = testing.allocator;
const ArrayList = std.ArrayList;
const Limits = @import("limits.zig").File;
//--------------------------------------------------------------- IMPLEMENTATION
const Self = @This();

/// Theoretical max 2Gb file size
const FileSize = u31;

const Piece = packed struct(u64) {
    tag: enum(u1) { original, add },
    start: FileSize,
    len: FileSize,
    _reserved: u1 = 0,
};

pub const Err = error{
    FileTooLarge,
};

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_piece_tbl: ArrayList(Piece),

pub fn predict_size(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        ((limits.inserts_and_undos_until_swap_write + 1) * @sizeOf(Piece));
}

pub fn init(a: mem.Allocator, limits: Limits, file_buf: []const u8) !Self {
    var piece_tbl = try ArrayList(Piece).initCapacity(
        a,
        // + 1 because piece tables start with one entry already
        limits.inserts_and_undos_until_swap_write + 1,
    );

    try piece_tbl.appendBounded(.{
        .tag = .original,
        .start = 0,
        .len = math.cast(
            FileSize,
            file_buf.len,
        ) orelse return error.FileTooLarge,
    });

    return .{
        ._file_buf = file_buf,
        ._add_buf = try ArrayList(u8).initCapacity(
            a,
            limits.new_chars_until_swap_write,
        ),
        ._piece_tbl = piece_tbl,
    };
}

// Only used to prevent leak reports in tests
// In practice all freeing and allocation is done (and test) at the top level
// Saves us allocating a buf, creating an fba, and destroying it each test.
fn deinit_testing(self: *Self, a: mem.Allocator) void {
    self._add_buf.deinit(a);
    self._piece_tbl.deinit(a);
}

// Derived/logical text
fn sequence(self: *const Self) Iterator {
    return Iterator{ .file = self, .piece_idx = 0 };
}

const Iterator = struct {
    file: *const Self,
    piece_idx: usize,

    /// Returns next contiguous span/piece of bytes
    fn next(self: *Iterator) ?[]const u8 {
        const pieces = self.file._piece_tbl.items;
        if (self.piece_idx >= pieces.len) return null;
        const piece = pieces[self.piece_idx];
        const buf = switch (piece.tag) {
            .original => self.file._file_buf,
            .add => self.file._add_buf.items,
        };
        const span = buf[piece.start .. piece.start + piece.len];

        self.piece_idx += 1;
        return span;
    }

    // Collects spans into a single buffer
    fn collect(self: *Iterator, a: mem.Allocator, buf: *ArrayList(u8)) !void {
        while (self.next()) |span| {
            try buf.appendSlice(a, span);
        }
    }
};

//------------------------------------------------------------------------ TESTS

// These tests are based on the Crowley paper

test "init & deinit" {
    var aa = std.heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    const f = try Self.init(a, Limits{}, "A large span of text");
    var seq_buf = try ArrayList(u8).initCapacity(a, 32);

    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqual(0, f._add_buf.items.len);
    try testing.expectEqualSlices(
        Piece,
        &[_]Piece{.{
            .tag = .original,
            .start = 0,
            .len = 20, // The paper says 19, but that looks to be an off by 1 error
        }},
        f._piece_tbl.items,
    );

    var seq = f.sequence();
    try seq.collect(a, &seq_buf);
    try testing.expectEqualStrings("A large span of text", seq_buf.items);
}
