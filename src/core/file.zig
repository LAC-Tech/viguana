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
const Io = std.Io;
const Limits = @import("limits.zig").File;
//--------------------------------------------------------------- IMPLEMENTATION

// A range for an operation on a file
const Range = packed struct(u62) {
    const InitErr = error{ RangeZeroLen, RangeTooLong };

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

const Piece = packed struct(u64) {
    tag: enum(u1) { original, add },
    _reserved: u1 = 0,
    range: Range,
};

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
        InsertTextTooLarge,
    };
    const Alloc = mem.Allocator.Error;
};

const Self = @This();

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_piece_tbl: ArrayList(Piece),

pub fn memory_needed(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        ((limits.edits_until_swap_write + 1) * @sizeOf(Piece));
}

pub fn init(
    a: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) (Err.Init || Err.Alloc)!Self {
    var piece_tbl = try ArrayList(Piece).initCapacity(
        a,
        // + 1 because piece tables start with one entry already
        limits.edits_until_swap_write + 1,
    );

    // TODO: fix this. if the range is zero (ie empty file), just don't append
    // an initial piece
    const initial_range: ?Range = Range.initUsizeLen(
        0,
        file_buf.len,
    ) catch |err| {
        switch (err) {
            error.RangeZeroLen => null,
            error.RangeTooLong => return error.OriginalFileTooLarge,
        }
    };
    try piece_tbl.appendBounded(.{
        .tag = .original,
        .range = initial_range,
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
// In practice all freeing and allocation is done (and tested) at the top level
// Saves us allocating a buf, creating an fba, and destroying it each test.
fn deinit_testing(self: *Self, a: mem.Allocator) void {
    self._add_buf.deinit(a);
    self._piece_tbl.deinit(a);
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
    const pieces = self._piece_tbl.items;

    var first_piece_offset: Limits.Size = 0;
    var last_piece_offset: Limits.Size = 0;
    var first_idx: usize = 0;
    var last_idx: usize = 0;
    var buf: [2]Piece = undefined;
    var replacements = ArrayList(Piece).initBuffer(&buf);

    {
        var cursor: Limits.Size = 0;
        var maybe_first_idx: ?usize = null;
        var maybe_last_idx: ?usize = null;

        for (pieces, 0..) |p, i| {
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

    const first_piece = pieces[first_idx];
    const last_piece = pieces[last_idx];

    if (first_piece_offset > 0) {
        var p = first_piece;
        p.range = p.range.set_len(first_piece_offset) catch unreachable;
        try replacements.appendBounded(p);
    }
    if (last_piece_offset < last_piece.range.len) {
        var p = first_piece;
        p.range =
            last_piece.range.shift_start(last_piece_offset) catch unreachable;
        try replacements.appendBounded(p);
    }

    try self._piece_tbl.replaceRangeBounded(
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

    const pieces = self._piece_tbl.items;

    var add_buf = &self._add_buf;
    var target_idx: usize = 0;
    var offset: Limits.Size = 0;
    var buf: [3]Piece = undefined;
    var replacements = ArrayList(Piece).initBuffer(&buf);

    {
        var cursor: Limits.Size = 0;
        var maybe_target_idx: ?usize = null;

        for (pieces, 0..) |p, i| {
            const r = Range.init(cursor, p.range.len) catch unreachable;
            if (r.end() > insert_range.start) {
                maybe_target_idx = i;
                offset = insert_range.start - r.start;
                break;
            }
            cursor += p.range.len;
        }

        target_idx = maybe_target_idx orelse return error.InsertOutOfBounds;
    }

    const target = pieces[target_idx];
    // If cursor is after most recently inserted, we can mutate piece in place
    if (offset == target.range.len and
        target.tag == .add and
        target.range.end() == add_buf.items.len)
    {
        const new_len = math.add(
            Limits.Size,
            target.range.len,
            insert_range.len,
        ) catch return error.InsertTextTooLarge;

        try add_buf.appendSliceBounded(text);
        pieces[target_idx].range = target.range.set_len(new_len) catch unreachable;
        return;
    }

    const add_start = math.cast(
        Limits.Size,
        add_buf.items.len,
    ) orelse unreachable; // TODO: proper error
    try add_buf.appendSliceBounded(text);

    const new_piece =
        Piece{ .tag = .add, .start = add_start, .len = insert_range.len };

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

        const tail = target.shift_start(offset);
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
        error.DeleteOutOfBounds,
        f.delete(2_000_000_000, 2_000_000_000),
    );
}

test "empty deletes are invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");
    defer f.deinit_testing(a);

    try testing.expectError(error.DeleteZero, f.delete(0, 0));
}

test "inserting nothing is invalid" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();

    var f = try Self.init(a, Limits{}, "hi");
    defer f.deinit_testing(a);

    try testing.expectError(error.InsertZero, f.insert(0, ""));
}
