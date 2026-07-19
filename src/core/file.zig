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
        DeleteTooLong,
    };

    const Insert = error{
        InsertZero,
        InsertTooLong,
    };

    const ByteSpan = error{
        ByteSpanZero,
        ByteSpanTooLong,
    };

    const Alloc = mem.Allocator.Error;
};

const ByteSpan = packed struct(u62) {
    start: Limits.Size,
    len: Limits.Size,

    fn init(start: Limits.Size, len: Limits.Size) Err.ByteSpan!ByteSpan {
        if (len == 0) return error.ByteSpanZero;
        _ = math.add(
            Limits.Size,
            start,
            len,
        ) catch return error.ByteSpanTooLong;
        return .{ .start = start, .len = len };
    }

    /// Safe to compute if Range created through init
    inline fn end(self: ByteSpan) Limits.Size {
        return self.start + self.len;
    }

    fn slice(self: @This(), bytes: []const u8) []const u8 {
        return bytes[self.start..self.end()];
    }

    fn resize(self: ByteSpan, new_len: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.init(self.start, new_len);
    }

    fn advance(self: ByteSpan, offset: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.init(self.start + offset, self.len - offset);
    }

    fn moveTo(self: ByteSpan, new_start: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.init(new_start, self.len);
    }
};

const Piece = packed struct(u64) {
    tag: enum(u1) { original, add },
    _reserved: u1 = 0,
    span: ByteSpan,
};

// TODO better name - not only the struct but the fields within
const FindRes = struct {
    // idx of the piece the position is found in
    idx: usize,
    // byte offset inside said piece it's found in
    offset: Limits.Size,
};

/// Positions must be ascending
// TODO better name
fn find(
    comptime n: usize,
    pieces: []const Piece,
    positions: [n]Limits.Size,
) ?[n]FindRes {
    var result: [n]FindRes = undefined;
    var next: usize = 0;
    var cursor: Limits.Size = 0;

    for (pieces, 0..) |p, i| {
        while (next < n and cursor + p.span.len > positions[next]) {
            result[next] = .{
                .idx = i,
                .offset = positions[next] - cursor,
            };
            next += 1;
        }
        if (next == n) return result;
        cursor += p.span.len;
    }
    return null;
}

const Self = @This();

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_piece_tbl: ArrayList(Piece),

pub fn memory_needed(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        (limits.edits_until_swap_write * @sizeOf(Piece));
}

pub fn init(
    a: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) (Err.Init || Err.Alloc)!Self {
    const file_buf_len = math.cast(
        Limits.Size,
        file_buf.len,
    ) orelse return error.OriginalFileTooLarge;

    var piece_tbl = try ArrayList(Piece).initCapacity(
        a,
        limits.edits_until_swap_write,
    );
    const initial_span = if (ByteSpan.init(
        0,
        file_buf_len,
    )) |span| span else |err| switch (err) {
        error.ByteSpanZero => null,
        error.ByteSpanTooLong => return error.OriginalFileTooLarge,
    };

    if (initial_span) |bs| {
        try piece_tbl.appendBounded(.{ .tag = .original, .span = bs });
    }

    return .{
        ._file_buf = file_buf,
        ._add_buf = try ArrayList(u8).initCapacity(
            a,
            limits.new_chars_until_swap_write,
        ),
        ._piece_tbl = piece_tbl,
    };
}

fn bufAt(self: @This(), idx: usize) ?[]const u8 {
    if (idx >= self._piece_tbl.items.len) return null;
    const p = &self._piece_tbl.items[idx];
    const buf = switch (p.tag) {
        .original => self._file_buf,
        .add => self._add_buf.items,
    };

    return p.span.slice(buf);
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
) (Err.Delete || Err.ByteSpan || Err.Alloc)!void {
    const delete_span = ByteSpan.init(start, len) catch |err| switch (err) {
        error.ByteSpanZero => return error.DeleteZero,
        error.ByteSpanTooLong => return err,
    };

    const pieces = self._piece_tbl.items;
    const frs = find(
        2,
        pieces,
        .{ delete_span.start, delete_span.end() - 1 },
    ) orelse return error.DeleteTooLong;

    const first = frs[0];
    const last = frs[1];

    var replacements: [2]Piece = undefined;
    var n: usize = 0;

    if (first.offset > 0) {
        var p = pieces[first.idx];
        p.span = try p.span.resize(first.offset);
        replacements[n] = p;
        n += 1;
    }

    const last_piece = pieces[last.idx];
    if (last_piece.span.len > last.offset + 1) {
        var p = last_piece;
        p.span = try p.span.advance(last.offset + 1);
        replacements[n] = p;
        n += 1;
    }

    try self._piece_tbl.replaceRangeBounded(
        first.idx,
        last.idx - first.idx + 1,
        replacements[0..n],
    );
}

pub fn insert(
    self: *Self,
    pos: Limits.Size,
    text: []const u8,
) (Err.Insert || Err.ByteSpan || Err.Alloc)!void {
    const text_len =
        math.cast(Limits.Size, text.len) orelse return error.InsertTooLong;
    const insert_span = ByteSpan.init(pos, text_len) catch |err| switch (err) {
        error.ByteSpanZero => return error.InsertZero,
        else => return err,
    };

    // The user has inserted two gigabytes of text before we went to swap?
    // I think we can safely panic.
    const add_buf_len =
        math.cast(Limits.Size, self._add_buf.items.len) orelse unreachable;

    const pieces = self._piece_tbl.items;

    const fr = if (find(1, pieces, .{insert_span.start})) |t| t[0] else {
        const new_span = try insert_span.moveTo(add_buf_len);
        try self._add_buf.appendSliceBounded(text);
        try self._piece_tbl.appendBounded(.{ .tag = .add, .span = new_span });
        return;
    };

    // Piece the insert will happen in.
    const piece = pieces[fr.idx];

    // If cursor is after most recently inserted, we can mutate piece in place
    if (fr.offset == piece.span.len and
        piece.tag == .add and
        piece.span.end() == self._add_buf.items.len)
    {
        const new_len = math.add(
            Limits.Size,
            piece.span.len,
            insert_span.len,
        ) catch unreachable;

        try self._add_buf.appendSliceBounded(text);
        var p = self._piece_tbl.items[fr.idx];
        p.span = try piece.span.resize(new_len);
        return;
    }

    const new_span = try insert_span.moveTo(add_buf_len);
    try self._add_buf.appendSliceBounded(text);

    if (fr.offset == 0) {
        // Insert before target; nothing removed.
        try self._piece_tbl.insertBounded(
            fr.idx,
            .{ .tag = .add, .span = new_span },
        );
    } else if (fr.offset == piece.span.len) {
        // Insert after target; nothing removed.
        try self._piece_tbl.insertBounded(
            fr.idx + 1,
            .{ .tag = .add, .span = new_span },
        );
    } else {
        var head = piece;
        head.span = try head.span.resize(fr.offset);
        var tail = piece;
        tail.span = try tail.span.advance(fr.offset);
        const replacements =
            [_]Piece{
                head,
                .{ .tag = .add, .span = new_span },
                tail,
            };

        // TODO: length 1, but 3 replacements?
        try self._piece_tbl.replaceRangeBounded(fr.idx, 1, &replacements);
    }
}

const Iterator = struct {
    file: *const Self,
    piece_idx: usize,

    /// Returns next contiguous span of bytes
    fn next(self: *Iterator) ?[]const u8 {
        const buf = self.file.bufAt(self.piece_idx) orelse return null;
        self.piece_idx += 1;
        return buf;
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
            .span = try ByteSpan.init(
                0,
                20, // Paper says 19, but that looks to be an off by 1 error
            ),
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
            .{ .tag = .original, .span = .{ .start = 0, .len = 2 } },
            .{ .tag = .original, .span = .{ .start = 8, .len = 12 } },
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
            .{ .tag = .original, .span = .{ .start = 0, .len = 2 } },
            .{ .tag = .original, .span = .{ .start = 8, .len = 8 } },
            .{ .tag = .add, .span = .{ .start = 0, .len = 8 } },
            .{ .tag = .original, .span = .{ .start = 16, .len = 4 } },
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

    try testing.expectError(
        error.ByteSpanTooLong,
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

test "can delete right up until the end of the file" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    var f = try Self.init(a, Limits{}, "neovim");
    try f.delete(3, 3);
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("neo", seq.written());
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

test "inserts at end of non-empty file" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    var f = try Self.init(a, Limits{}, "hello");
    try f.insert(5, " world");
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("hello world", seq.written());
}

// TODO: Maybe we do want to bloat piece table? that's another undo after all
// BUT that means every char insert is 8 bytes... per char undo could use text buf?
//test "optimization; two consecutive inserts should not bloat piecetable" {
//    var aa = heap.ArenaAllocator.init(ta);
//    defer aa.deinit();
//    const a = aa.allocator();
//
//    // "ac" -> insert "b" at 1 -> "abc" -> insert "d" right after the "b" -> "abdc"
//    var f = try Self.init(a, Limits{}, "ac");
//    try f.insert(1, "b");
//    try f.insert(2, "d");
//
//    try testing.expectEqualSlices(
//        Piece,
//        &[_]Piece{
//            .{ .tag = .original, .span = .{ .start = 0, .len = 1 } }, // "a"
//            .{ .tag = .add, .span = .{ .start = 0, .len = 2 } }, // "bd" merged
//            .{ .tag = .original, .span = .{ .start = 1, .len = 1 } }, // "c"
//        },
//        f._piece_tbl.items,
//    );
//}
