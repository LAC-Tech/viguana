//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"
//!
//! Implemented with Piece Tables, based on:
//!     "Data Structures for Text Sequences" (Charles Crowley. 1998)
//!     https://www.cs.unm.edu/~crowley/papers/sds.pdf

//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const ta = testing.allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Limits = @import("limits.zig").File;
//--------------------------------------------------------------- IMPLEMENTATION

// We treat request to do frivilous things like "delete 0 characters" as errors
// Silently doing nothing hides bugs - why is the caller sending bad data?
pub const Err = struct {
    pub const Init = error{
        OriginalFileTooLarge,
    };

    const Delete = error{
        DeleteZero,
        DeleteOutOfBounds,
    };

    const Insert = error{
        InsertZero,
        InsertOutOfBounds,
        InsertTextTooLarge, // TODO: I think this is redundant
    };
    const Alloc = mem.Allocator.Error;
};

/// A range for an operation on a file
const Range = packed struct(u62) {
    const InitErr = error{
        RangeZeroLen,
        RangeTooLong,
    };

    /// conceptually I believe this is the cursor position
    start: Limits.Size,
    /// number of bytes.
    /// do not set it directly, use `setLen` to catch range errors early
    len: Limits.Size,

    fn init(start: Limits.Size, len: Limits.Size) InitErr!@This() {
        if (len == 0) return error.RangeZeroLen;
        _ = math.add(
            Limits.Size,
            start,
            len,
        ) catch return error.RangeTooLong;
        return .{ .start = start, .len = len };
    }

    fn initUsizeLen(start: Limits.Size, len: usize) InitErr!@This() {
        const cast_len =
            math.cast(Limits.Size, len) orelse return error.RangeTooLong;

        return @This().init(start, cast_len);
    }

    /// Safe to compute if Range created through init
    fn end(self: @This()) Limits.Size {
        return self.start + self.len;
    }

    fn shift_start(self: @This(), offset: Limits.Size) InitErr!@This() {
        return @This().init(self.start + offset, self.len - offset);
    }

    fn set_len(self: @This(), new_len: Limits.Size) InitErr!@This() {
        return @This().init(self.start, new_len);
    }
};

const PieceTbl = struct {
    const Piece = packed struct(u64) {
        tag: enum(u1) { original, add },
        _reserved: u1 = 0,
        range: Range,

        fn head(self: Piece, offset: Limits.Size) Piece {
            return .{
                .tag = self.tag,
                .range = self.range.set_len(offset) catch unreachable,
            };
        }

        fn tail(self: Piece, offset: Limits.Size) Piece {
            return .{
                .tag = self.tag,
                .range = self.range.shift_start(offset) catch unreachable,
            };
        }

        fn span(self: Piece, file_buf: []const u8, add_buf: []const u8) []const u8 {
            const buf = switch (self.tag) {
                .original => file_buf,
                .add => add_buf,
            };
            return buf[self.range.start..self.range.end()];
        }
    };

    _tbl: ArrayList(Piece),
    // TODO: should be possible to calculate this? would make some checks easier
    //projected_len: usize = 0,

    fn init(a: mem.Allocator, limits: Limits, file_buf_len: usize) !@This() {
        var tbl = try ArrayList(Piece).initCapacity(
            a,
            // + 1 because piece tables start with one entry already
            limits.edits_until_swap_write + 1,
        );
        const initial_range =
            if (Range.initUsizeLen(0, file_buf_len)) |r| r else |err| switch (err) {
                error.RangeZeroLen => null,
                error.RangeTooLong => return error.OriginalFileTooLarge,
            };

        if (initial_range) |r| {
            try tbl.appendBounded(.{ .tag = .original, .range = r });
        }

        return .{ ._tbl = tbl };
    }

    fn create_add(start: Limits.Size, len: Limits.Size) Range.InitErr!Piece {
        return .{
            .tag = .add,
            .range = try Range.init(start, len),
        };
    }
};

const Self = @This();

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_pieces: PieceTbl,

pub fn memory_needed(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        ((limits.edits_until_swap_write + 1) * @sizeOf(PieceTbl.Piece));
}

pub fn init(
    a: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) (Err.Init || Err.Alloc)!Self {
    return .{
        ._file_buf = file_buf,
        ._add_buf = try ArrayList(u8).initCapacity(
            a,
            limits.new_chars_until_swap_write,
        ),
        ._pieces = try PieceTbl.init(a, limits, file_buf.len),
    };
}

// Derived/logical text
fn writeSequence(self: *const Self, w: *Io.Writer) Io.Writer.Error!void {
    var it = Iterator{ .file = self, .piece_idx = 0 };
    while (it.next()) |span| {
        try w.writeAll(span);
    }
}

pub fn delete(
    self: *Self,
    start: Limits.Size,
    len: Limits.Size,
) (Err.Delete || Err.Alloc)!void {
    const delete_range = Range.init(start, len) catch |err| switch (err) {
        error.RangeZeroLen => return error.DeleteZero,
        error.RangeTooLong => return error.DeleteOutOfBounds,
    };
    const pieces = self._pieces;

    var first_piece_offset: Limits.Size = 0;
    var last_piece_offset: Limits.Size = 0;
    var first_idx: usize = 0;
    var last_idx: usize = 0;
    {
        var cursor: Limits.Size = 0;
        var maybe_first_idx: ?usize = null;
        var maybe_last_idx: ?usize = null;

        for (pieces._tbl.items, 0..) |p, i| {
            const r = Range.init(cursor, p.range.len) catch unreachable;
            if (r.end() > delete_range.start) {
                maybe_first_idx = i;
                first_piece_offset = delete_range.start - r.start;
            }
            if (delete_range.end() > r.start) {
                maybe_last_idx = i;
                last_piece_offset = delete_range.end() - r.start;
                break;
            }
            cursor += p.range.len;
        }

        first_idx = maybe_first_idx orelse return error.DeleteOutOfBounds;
        last_idx = maybe_last_idx orelse return error.DeleteOutOfBounds;
    }

    const first_piece = pieces._tbl.items[first_idx];
    const last_piece = pieces._tbl.items[last_idx];

    var buf: [2]PieceTbl.Piece = undefined;
    var replacements = ArrayList(PieceTbl.Piece).initBuffer(&buf);

    if (first_piece_offset > 0) {
        try replacements.appendBounded(first_piece.head(first_piece_offset));
    }
    if (last_piece_offset < last_piece.range.len) {
        try replacements.appendBounded(last_piece.tail(last_piece_offset));
    }

    try self._pieces._tbl.replaceRangeBounded(
        first_idx,
        last_idx - first_idx + 1,
        replacements.items,
    );
}

// TODO: still mostly clankery, I won't understand this later
pub fn insert(
    self: *Self,
    pos: Limits.Size,
    text: []const u8,
) (Err.Insert || Err.Alloc)!void {
    const text_len = math.cast(
        Limits.Size,
        text.len,
    ) orelse return error.InsertTextTooLarge;

    const insert_range = Range.init(pos, text_len) catch |err| switch (err) {
        error.RangeZeroLen => return error.InsertZero,
        error.RangeTooLong => return error.InsertOutOfBounds,
    };

    const pieces = self._pieces._tbl.items;

    var offset: Limits.Size = 0;
    var maybe_target_idx: ?usize = null;
    {
        var cursor: Limits.Size = 0;

        for (pieces, 0..) |p, i| {
            const r = Range.init(cursor, p.range.len) catch unreachable;
            if (r.end() > insert_range.start) {
                maybe_target_idx = i;
                offset = insert_range.start - r.start;
                break;
            }
            cursor += p.range.len;
        }
    }

    const target_idx = if (maybe_target_idx) |i| i else {
        // Assuming if we don't find the target idx, the piece table is empty
        debug.assert(pieces.len == 0);
        try self._add_buf.appendSliceBounded(text);
        try self._pieces._tbl.appendBounded(.{ .tag = .add, .range = insert_range });
        return;
    };

    const target = pieces[target_idx];

    // If cursor is after most recently inserted, we can mutate piece in place
    if (offset == target.range.len and
        target.tag == .add and
        target.range.end() == self._add_buf.items.len)
    {
        const new_len = math.add(
            Limits.Size,
            target.range.len,
            insert_range.len,
        ) catch return error.InsertTextTooLarge;

        try self._add_buf.appendSliceBounded(text);
        pieces[target_idx].range = target.range.set_len(new_len) catch unreachable;
        return;
    }

    const add_start = math.cast(
        Limits.Size,
        self._add_buf.items.len,
    ) orelse unreachable; // TODO: proper error

    const new_piece = PieceTbl.create_add(add_start, insert_range.len) catch |err| {
        switch (err) {
            error.RangeZeroLen => unreachable,
            error.RangeTooLong => return error.InsertTextTooLarge,
        }
    };

    try self._add_buf.appendSliceBounded(text);
    if (offset == 0) {
        // Insert before target; nothing removed.
        try self._pieces._tbl.replaceRangeBounded(
            target_idx,
            0,
            &[_]PieceTbl.Piece{new_piece},
        );
    } else if (offset == target.range.len) {
        // Insert after target; nothing removed.
        try self._pieces._tbl.replaceRangeBounded(
            target_idx + 1,
            0,
            &[_]PieceTbl.Piece{new_piece},
        );
    } else {
        const replacements = [_]PieceTbl.Piece{
            target.head(offset),
            new_piece,
            target.tail(offset),
        };

        try self._pieces._tbl.replaceRangeBounded(target_idx, 1, &replacements);
    }
}

const Iterator = struct {
    file: *const Self,
    piece_idx: usize,

    /// Returns next contiguous span of bytes
    fn next(self: *Iterator) ?[]const u8 {
        const pieces = self.file._pieces._tbl.items;
        if (self.piece_idx >= pieces.len) return null;
        const piece = pieces[self.piece_idx];
        self.piece_idx += 1;
        return piece.span(self.file._file_buf, self.file._add_buf.items);
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
        PieceTbl.Piece,
        &[_]PieceTbl.Piece{.{
            .tag = .original,
            .range = try Range.init(
                0,
                20, // Paper says 19, but that looks to be an off by 1 error
            ),
        }},
        f._pieces._tbl.items,
    );
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A large span of text", seq.written());

    // DELETING A WORD (Figure 9) ---------------------------------------------
    try f.delete(2, 6);
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("", f._add_buf.items);
    try testing.expectEqualSlices(
        PieceTbl.Piece,
        &[_]PieceTbl.Piece{
            .{ .tag = .original, .range = .{ .start = 0, .len = 2 } },
            .{ .tag = .original, .range = .{ .start = 8, .len = 12 } },
        },
        f._pieces._tbl.items,
    );
    seq.clearRetainingCapacity();
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A span of text", seq.written());

    // INSERT A WORD (Figure 10) -----------------------------------------------
    try f.insert(10, "English ");
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("English ", f._add_buf.items);
    try testing.expectEqualSlices(
        PieceTbl.Piece,
        &[_]PieceTbl.Piece{
            .{ .tag = .original, .range = .{ .start = 0, .len = 2 } },
            .{ .tag = .original, .range = .{ .start = 8, .len = 8 } },
            .{ .tag = .add, .range = .{ .start = 0, .len = 8 } },
            .{ .tag = .original, .range = .{ .start = 16, .len = 4 } },
        },
        f._pieces._tbl.items,
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

    try testing.expectError(
        error.DeleteOutOfBounds,
        f.delete(2_000_000_000, 2_000_000_000),
    );
}

test "empty deletes are invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");

    try testing.expectError(error.DeleteZero, f.delete(0, 0));
}

test "inserting nothing is invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");

    try testing.expectError(error.InsertZero, f.insert(0, ""));
}

test "empty starting file" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    var f = try Self.init(a, Limits{}, "");

    try f.insert(0, "hello world");
    try f.writeSequence(&seq.writer);
}

test "initialises on max size file size" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    const original_file = try a.alloc(u8, math.maxInt(Limits.Size));
    _ = try Self.init(a, Limits{}, original_file);
}

test "gracefully errors if file is too large" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    const original_file = try a.alloc(u8, math.maxInt(Limits.Size) + 1);
    try testing.expectError(
        error.OriginalFileTooLarge,
        Self.init(a, Limits{}, original_file),
    );
}
