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
        InsertAddBufFull,
    };

    const ByteSpan = error{
        ByteSpanTooLong,
    };

    const Alloc = mem.Allocator.Error;
};

const ByteSpan = packed struct(u64) {
    const Tag = enum(u2) { original, add, unset };

    start: Limits.Size,
    len: Limits.Size,
    tag: Tag = .unset,

    fn init(start: Limits.Size, len: Limits.Size) Err.ByteSpan!ByteSpan {
        _ = math.add(
            Limits.Size,
            start,
            len,
        ) catch return error.ByteSpanTooLong;
        return .{ .start = start, .len = len };
    }

    fn withTag(self: ByteSpan, tag: Tag) ByteSpan {
        var result = self;
        result.tag = tag;
        return result;
    }

    fn initTag(start: Limits.Size, len: Limits.Size, tag: Tag) Err.ByteSpan!ByteSpan {
        const result = try ByteSpan.init(start, len);
        return result.withTag(tag);
    }

    fn empty(self: ByteSpan) bool {
        return self.len == 0;
    }

    /// Safe to compute if Range created through init
    inline fn end(self: ByteSpan) Limits.Size {
        return self.start + self.len;
    }

    fn slice(self: @This(), bytes: []const u8) []const u8 {
        return bytes[self.start..self.end()];
    }

    fn resize(self: ByteSpan, new_len: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.initTag(self.start, new_len, self.tag);
    }

    fn advance(self: ByteSpan, offset: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.initTag(self.start + offset, self.len - offset, self.tag);
    }

    fn moveTo(self: ByteSpan, new_start: Limits.Size) Err.ByteSpan!ByteSpan {
        return ByteSpan.initTag(new_start, self.len, self.tag);
    }
};

const Pieces = struct {
    fn cursor(self: *const Pieces) Cursor {
        return .{ .pieces = self._spans.items };
    }

    /// Walks left-to-right, converting logical byte positions into
    /// (piece index, offset-within-piece). Positions passed to locate()
    /// must be non-decreasing across calls -- it never rewinds.
    const Cursor = struct {
        pieces: []const ByteSpan,
        idx: usize = 0,
        pos: Limits.Size = 0, // logical start of pieces[idx]

        const Result = struct { idx: usize, offset: Limits.Size };

        fn locate(self: *Cursor, target: Limits.Size) ?Result {
            while (self.idx < self.pieces.len and
                self.pos + self.pieces[self.idx].len <= target)
            {
                self.pos += self.pieces[self.idx].len;
                self.idx += 1;
            }
            if (self.idx == self.pieces.len) return null;
            return .{ .idx = self.idx, .offset = target - self.pos };
        }
    };

    _spans: ArrayList(ByteSpan),

    fn init(
        a: mem.Allocator,
        capacity: Limits.Size,
        file_buf_len: Limits.Size,
    ) !Pieces {
        var spans = try ArrayList(ByteSpan).initCapacity(a, capacity);

        const initial_span =
            if (ByteSpan.init(0, file_buf_len)) |bs| bs else |err| switch (err) {
                error.ByteSpanTooLong => return error.OriginalFileTooLarge,
            };

        // A new file should logically not have an "original" piece.
        if (!initial_span.empty()) {
            try spans.appendBounded(initial_span.withTag(.original));
        }

        return .{
            ._spans = spans,
        };
    }

    fn get(self: Pieces, idx: usize) ByteSpan {
        return self._spans.items[idx];
    }

    fn getMut(self: Pieces, idx: usize) *ByteSpan {
        return &self._spans.items[idx];
    }

    fn getOrNull(self: Pieces, idx: usize) ?ByteSpan {
        const spans = self._spans.items;
        return if (spans.len > idx) spans[idx] else null;
    }
};

const Self = @This();

// Read-only buffer to the original file
_file_buf: []const u8,
/// Append only buffer to a temp file
_add_buf: ArrayList(u8),
_pieces: Pieces,

const n_initial_pieces = 1;

pub fn memory_needed(limits: Limits) usize {
    return (limits.new_chars_until_swap_write * @sizeOf(u8)) +
        ((limits.edits_until_swap_write + n_initial_pieces) * @sizeOf(ByteSpan));
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

    return .{
        ._file_buf = file_buf,
        ._add_buf = try ArrayList(u8).initCapacity(
            a,
            limits.new_chars_until_swap_write,
        ),
        ._pieces = try Pieces.init(
            a,
            limits.edits_until_swap_write + n_initial_pieces,
            file_buf_len,
        ),
    };
}

fn bufAt(self: @This(), idx: usize) ?[]const u8 {
    const p = self._pieces.getOrNull(idx) orelse return null;
    const buf = switch (p.tag) {
        .original => self._file_buf,
        .add => self._add_buf.items,
        .unset => @panic("untagged byte span stored in piece table"),
    };

    return p.slice(buf);
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
    const del_span = ByteSpan.init(start, len) catch |err| switch (err) {
        error.ByteSpanTooLong => return err,
    };

    if (del_span.empty()) return error.DeleteZero;
    const last_pos = del_span.end() - 1;

    var cur = self._pieces.cursor();
    const first = cur.locate(del_span.start) orelse return error.DeleteTooLong;
    const last = cur.locate(last_pos) orelse return error.DeleteTooLong;

    var replacements: [2]ByteSpan = undefined;
    var n: usize = 0;

    if (first.offset > 0) {
        replacements[n] = try self._pieces.get(first.idx).resize(first.offset);
        n += 1;
    }

    const last_piece = self._pieces.get(last.idx);
    if (last_piece.len > last.offset + 1) {
        replacements[n] = try self._pieces.get(last.idx).advance(last.offset + 1);
        n += 1;
    }

    // TODO: Pieces method
    try self._pieces._spans.replaceRangeBounded(
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
    const ins_span = ByteSpan.init(pos, text_len) catch |err| switch (err) {
        else => return err,
    };

    if (ins_span.empty()) return error.InsertZero;

    const add_buf_len = math.cast(
        Limits.Size,
        self._add_buf.items.len,
    ) orelse return error.InsertAddBufFull;

    var cur = self._pieces.cursor();
    const fr = cur.locate(ins_span.start) orelse {
        // Past the end of every piece: append fresh.
        const new_span = try ins_span.moveTo(add_buf_len);
        try self._add_buf.appendSliceBounded(text);
        // TODO method on pieces
        try self._pieces._spans.appendBounded(new_span.withTag(.add));
        return;
    };

    // A boundary position (offset 0) resolves to the *following* piece,
    // so the mergeable candidate is always the piece just before idx,
    // never pieces[idx] itself.
    if (fr.offset == 0 and fr.idx > 0) {
        const prev = self._pieces.get(fr.idx - 1);
        if (prev.tag == .add and prev.end() == add_buf_len) {
            const new_len = math.add(
                Limits.Size,
                prev.len,
                ins_span.len,
            ) catch unreachable;

            try self._add_buf.appendSliceBounded(text);
            const p = self._pieces.getMut(fr.idx - 1);
            p.* = try prev.resize(new_len);
            return;
        }

        // Boundary, but nothing to merge with: insert before target.
        try self._add_buf.appendSliceBounded(text);

        const new_span = (try ins_span.moveTo(add_buf_len)).withTag(.add);
        // TODO method on pieces
        try self._pieces._spans.insertBounded(fr.idx, new_span);
        return;
    }

    // Interior split: 0 < offset < piece.len is guaranteed here.
    const piece = self._pieces.get(fr.idx);
    const new_span = try ins_span.moveTo(add_buf_len);
    try self._add_buf.appendSliceBounded(text);

    const replacements = [_]ByteSpan{
        try piece.resize(fr.offset),
        new_span.withTag(.add),
        try piece.advance(fr.offset),
    };

    // Splitting one piece into up to 3: head, new text, tail.
    // TODO: method on pieces
    try self._pieces._spans.replaceRangeBounded(fr.idx, 1, &replacements);
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
        ByteSpan,
        &[_]ByteSpan{.{
            .tag = .original,
            .start = 0,
            .len = 20, // Paper says 19, but that looks to be an off by 1 error
        }},
        f._pieces._spans.items,
    );
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A large span of text", seq.written());

    // DELETING A WORD (Figure 9) ---------------------------------------------
    try f.delete(2, 6);
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("", f._add_buf.items);
    try testing.expectEqualSlices(
        ByteSpan,
        &[_]ByteSpan{
            .{ .tag = .original, .start = 0, .len = 2 },
            .{ .tag = .original, .start = 8, .len = 12 },
        },
        f._pieces._spans.items,
    );
    seq.clearRetainingCapacity();
    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("A span of text", seq.written());

    // INSERT A WORD (Figure 10) -----------------------------------------------
    try f.insert(10, "English ");
    try testing.expectEqualStrings("A large span of text", f._file_buf);
    try testing.expectEqualStrings("English ", f._add_buf.items);
    try testing.expectEqualSlices(
        ByteSpan,
        &[_]ByteSpan{
            .{ .tag = .original, .start = 0, .len = 2 },
            .{ .tag = .original, .start = 8, .len = 8 },
            .{ .tag = .add, .start = 0, .len = 8 },
            .{ .tag = .original, .start = 16, .len = 4 },
        },
        f._pieces._spans.items,
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

test "two consecutive inserts should not bloat piecetable" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    var f = try Self.init(a, Limits{}, "ad");
    try f.insert(1, "b");
    try f.insert(2, "c");

    try testing.expectEqualSlices(
        ByteSpan,
        &[_]ByteSpan{
            .{ .tag = .original, .start = 0, .len = 1 },
            .{ .tag = .add, .start = 0, .len = 2 },
            .{ .tag = .original, .start = 1, .len = 1 },
        },
        f._pieces._spans.items,
    );

    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("abcd", seq.written());
}

test "inserting on an empty file results in a single span" {
    var aa = heap.ArenaAllocator.init(ta);
    defer aa.deinit();
    const a = aa.allocator();
    var seq = std.Io.Writer.Allocating.init(a);

    var f = try Self.init(a, Limits{}, "");
    try f.insert(0, "test");

    try testing.expectEqualSlices(
        ByteSpan,
        &[_]ByteSpan{
            .{ .tag = .add, .start = 0, .len = 4 },
        },
        f._pieces._spans.items,
    );

    try f.writeSequence(&seq.writer);
    try testing.expectEqualStrings("test", seq.written());
}
