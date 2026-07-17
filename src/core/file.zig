//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"
//!
//! Implemented with Piece Tables, based on:
//!     "Data Structures for Text Sequences" (Charles Crowley. 1998)
//!     https://www.cs.unm.edu/~crowley/papers/sds.pdf

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
fn writeSequence(
    self: *const Self,
    w: *std.Io.Writer,
) !void {
    var it = Iterator{ .file = self, .piece_idx = 0 };
    while (it.next()) |span| {
        try w.writeAll(span);
    }
}

// Clanker generated - I do not understand this.
fn delete(self: *Self, start: FileSize, len: FileSize) !void {
    const end = start + len;
    const pieces = self._piece_tbl.items;

    var cursor: FileSize = 0;
    // which piece contains the first deleted byte
    var start_idx: usize = 0;
    // how far into that piece the first deleted byte is
    var start_offset: FileSize = 0;
    // which piece contains the byte just past the deleted range
    var end_idx: usize = 0;
    // how far into that piece the deletion ends
    var end_offset: FileSize = 0;

    for (pieces, 0..) |p, p_idx| {
        const p_len: FileSize = @intCast(p.len);
        if (cursor + p_len > start) {
            start_idx = p_idx;
            start_offset = start - cursor;
        }
        if (cursor + p_len >= end) {
            end_idx = p_idx;
            end_offset = end - cursor;
            break;
        }
        cursor += p_len;
    }

    // Copying before anything is mutated
    const end_piece = pieces[end_idx];
    self._piece_tbl.items[start_idx].len = start_offset;
    if (end_idx > start_idx) {
        const gap = end_idx - start_idx;
        const rest = pieces.len - (end_idx + 1);
        if (rest > 0) {
            mem.copyForwards(
                Piece,
                self._piece_tbl.items[start_idx + 1 ..],
                self._piece_tbl.items[end_idx + 1 ..],
            );
        }
        self._piece_tbl.items = pieces[0 .. pieces.len - gap];
    }
    if (end_piece.len > end_offset) {
        try self._piece_tbl.insertBounded(start_idx + 1, .{
            .tag = end_piece.tag,
            .start = end_piece.start + end_offset,
            .len = end_piece.len - end_offset,
        });
    }
}

const Iterator = struct {
    file: *const Self,
    piece_idx: usize,

    /// Returns next contiguous span of bytes
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

// Test is brittle; more of a recorded debugging session
// Its purpose is to see if I am following the algorithm accurately
test "Crowley paper tests" {
    var aa = std.heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    // INITIAL STATE (Figure 8) -----------------------------------------------
    var f = try Self.init(a, Limits{}, "A large span of text");
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("", f._add_buf.items);
    try testing.expectEqual(0, f._add_buf.items.len);
    try testing.expectEqualSlices(
        Piece,
        &[_]Piece{.{
            .tag = .original,
            .start = 0,
            .len = 20, // Paper says 19, but that looks to be an off by 1 error
        }},
        f._piece_tbl.items,
    );
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A large span of text", seq.written());

    // DELETING A WORD (Figure 9) ---------------------------------------------
    try f.delete(2, 6);
    // Original file is read only
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("", f._add_buf.items);
    try testing.expectEqualSlices(
        Piece,
        &[_]Piece{
            .{ .tag = .original, .start = 0, .len = 2 },
            .{ .tag = .original, .start = 8, .len = 12 },
        },
        f._piece_tbl.items,
    );
    seq.clearRetainingCapacity();
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A span of text", seq.written());
}
