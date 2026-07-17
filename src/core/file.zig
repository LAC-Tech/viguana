//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"
//!
//! Implemented with Piece Tables, based on:
//!     "Data Structures for Text Sequences" (Charles Crowley. 1998)
//!     https://www.cs.unm.edu/~crowley/papers/sds.pdf

//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const heap = std.heap;
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
    ZeroDelete,
    ZeroInsert,
    OutOfBoundsDelete,
    OutOfBoundsInsert,
};

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_piece_tbl: ArrayList(Piece),

pub fn memory_needed(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        ((limits.edits_until_swap_write + 1) * @sizeOf(Piece));
}

pub fn init(a: mem.Allocator, limits: Limits, file_buf: []const u8) !Self {
    var piece_tbl = try ArrayList(Piece).initCapacity(
        a,
        // + 1 because piece tables start with one entry already
        limits.edits_until_swap_write + 1,
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
pub fn writeSequence(self: *const Self, w: *std.Io.Writer) !void {
    var it = Iterator{ .file = self, .piece_idx = 0 };
    while (it.next()) |span| {
        try w.writeAll(span);
    }
}

pub fn delete(self: *Self, start: FileSize, len: FileSize) !void {
    if (len == 0) return error.ZeroDelete;
    const end = math.add(FileSize, start, len) catch return error.OutOfBoundsDelete;
    const pieces = self._piece_tbl.items;

    var first_piece_offset: FileSize = 0;
    var last_piece_offset: FileSize = 0;
    var first_idx: usize = 0;
    var last_idx: usize = 0;

    {
        var pos: FileSize = 0;
        var maybe_first_idx: ?usize = null;
        var maybe_last_idx: ?usize = null;

        for (pieces, 0..) |p, i| {
            const piece_end = pos + p.len;
            if (start >= pos and start < piece_end) {
                maybe_first_idx = i;
                first_piece_offset = start - pos;
            }
            if (end > pos and end <= piece_end) {
                maybe_last_idx = i;
                last_piece_offset = end - pos;
                break;
            }
            pos = piece_end;
        }

        first_idx = maybe_first_idx orelse return error.OutOfBoundsDelete;
        last_idx = maybe_last_idx orelse return error.OutOfBoundsDelete;
    }

    const first_piece = pieces[first_idx];
    const last_piece = pieces[last_idx];

    var buf: [2]Piece = undefined;
    var replacements = ArrayList(Piece).initBuffer(&buf);

    if (first_piece_offset > 0) {
        var p = first_piece;
        p.len = first_piece_offset;
        try replacements.appendBounded(p);
    }
    if (last_piece_offset < last_piece.len) {
        var p = last_piece;
        p.start += last_piece_offset;
        p.len -= last_piece_offset;
        try replacements.appendBounded(p);
    }

    try self._piece_tbl.replaceRangeBounded(
        first_idx,
        last_idx - first_idx + 1,
        replacements.items,
    );
}

// TODO: still mostly clankery, I won't understand this later
pub fn insert(self: *Self, pos: FileSize, text: []const u8) !void {
    if (text.len == 0) return error.ZeroInsert;
    const pieces = self._piece_tbl.items;
    const add_buf = self._add_buf;

    var target_idx: usize = 0;
    var offset: FileSize = 0;

    {
        var pos_cursor: FileSize = 0;

        var maybe_target_idx: ?usize = null;
        for (pieces, 0..) |p, i| {
            const piece_end = pos_cursor + p.len;
            if (pos >= pos_cursor and pos <= piece_end) {
                maybe_target_idx = i;
                offset = pos - pos_cursor;
                break;
            }
            pos_cursor = piece_end;
        }
        target_idx = maybe_target_idx orelse return error.OutOfBoundsInsert;
    }

    const target = pieces[target_idx];
    const text_len =
        math.cast(FileSize, text.len) orelse return error.OutOfBoundsInsert;

    // If cursor is after most recently inserted, we can mutate piece in place
    if (offset == target.len and
        target.tag == .add and
        target.start + target.len == add_buf.items.len)
    {
        try self._add_buf.appendSliceBounded(text);
        pieces[target_idx].len = math.add(
            FileSize,
            target.len,
            text_len,
        ) catch return error.FileTooLarge;

        return;
    }

    const add_start =
        math.cast(FileSize, add_buf.items.len) orelse return error.FileTooLarge;
    try self._add_buf.appendSliceBounded(text);
    const new_piece = Piece{ .tag = .add, .start = add_start, .len = text_len };

    var buf: [3]Piece = undefined;
    var replacements = ArrayList(Piece).initBuffer(&buf);

    if (offset == 0) {
        // Insert before target; nothing removed.
        try replacements.appendBounded(new_piece);
        try self._piece_tbl.replaceRangeBounded(
            target_idx,
            0,
            replacements.items,
        );
    } else if (offset == target.len) {
        // Insert after target; nothing removed.
        try replacements.appendBounded(new_piece);
        try self._piece_tbl.replaceRangeBounded(
            target_idx + 1,
            0,
            replacements.items,
        );
    } else {
        // Interior: split into head, new, tail.
        var head = target;
        head.len = offset;
        try replacements.appendBounded(head);
        try replacements.appendBounded(new_piece);

        var tail = target;
        tail.start += offset;
        tail.len -= offset;
        try replacements.appendBounded(tail);

        try self._piece_tbl.replaceRangeBounded(
            target_idx,
            1,
            replacements.items,
        );
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
};

//------------------------------------------------------------------------ TESTS

// This test is brittle; more of a recorded debugging session
// Its purpose is to see if I am following the algorithm accurately
test "Crowley paper tests" {
    var aa = heap.ArenaAllocator.init(ta);
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

    // INSERT A WORD (Figure 10) -----------------------------------------------
    try f.insert(10, "English ");
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("English ", f._add_buf.items);
    try testing.expectEqualSlices(
        Piece,
        &[_]Piece{
            .{ .tag = .original, .start = 0, .len = 2 },
            .{ .tag = .original, .start = 8, .len = 8 },
            .{ .tag = .add, .start = 0, .len = 8 },
            .{ .tag = .original, .start = 16, .len = 4 },
        },
        f._piece_tbl.items,
    );
    seq.clearRetainingCapacity();
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A span of English text", seq.written());
}

test "deleting past end of file is invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");
    defer f.deinit_testing(a);

    try testing.expectError(
        error.OutOfBoundsDelete,
        f.delete(2_000_000_000, 2_000_000_000),
    );
}

test "empty deletes are invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");
    defer f.deinit_testing(a);

    try testing.expectError(error.ZeroDelete, f.delete(0, 0));
}

test "inserting nothing is invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");
    defer f.deinit_testing(a);

    try testing.expectError(error.ZeroInsert, f.insert(0, ""));
}
