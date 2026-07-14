//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const testing = std.testing;

const Piece = struct {
    buf_type: enum { original, add },
    start: usize,
    len: usize,
};

const Self = @This();

/// A buffer to the original text document. This buffer is read-only.
original_buf: []const u8,
/// A buffer to a temporary file. This buffer is append-only.
add_buf: ArrayList(u8),
piece_tbl: ArrayList(Piece),

pub fn init(allocator: mem.Allocator, original: []const u8) !@This() {
    // TODO: why are we duping here?
    const owned_original = try allocator.dupe(u8, original);
    var pieces = ArrayList(Piece).empty;
    try pieces.append(allocator, .{
        .buf_type = .original,
        .start = 0,
        .len = original.len,
    });
    return .{
        .original_buf = owned_original,
        .add_buf = .empty,
        .piece_tbl = pieces,
    };
}

pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
    allocator.free(self.original_buf);
    self.add_buf.deinit(allocator);
    self.piece_tbl.deinit(allocator);
}

fn pieceBytes(self: @This(), piece: Piece) []const u8 {
    const end = piece.start + piece.len;
    return switch (piece.buf_type) {
        .original => self.original_buf[piece.start..end],
        .add => self.add_buf.items[piece.start..end],
    };
}

pub fn totalLen(self: @This()) usize {
    var len: usize = 0;
    for (self.piece_tbl.items) |p| {
        len += p.len;
    }
    return len;
}

pub fn insert(
    self: *@This(),
    allocator: mem.Allocator,
    offset: usize,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const start: usize = self.add_buf.items.len;
    try self.add_buf.appendSlice(allocator, text);

    if (self.piece_tbl.items.len == 0) {
        try self.piece_tbl.append(allocator, .{
            .buf_type = .add,
            .start = start,
            .len = text.len,
        });
        return;
    }

    var current: usize = 0;
    var i: usize = 0;
    while (i < self.piece_tbl.items.len) : (i += 1) {
        const p = self.piece_tbl.items[i];
        if (current + p.len >= offset) {
            const split = offset - current;
            const left = Piece{
                .buf_type = p.buf_type,
                .start = p.start,
                .len = split,
            };
            const right = Piece{
                .buf_type = p.buf_type,
                .start = p.start + split,
                .len = p.len - split,
            };
            const new = Piece{
                .buf_type = .add,
                .start = start,
                .len = text.len,
            };

            try self.piece_tbl.ensureUnusedCapacity(allocator, 2);
            self.piece_tbl.items[i] = left;
            self.piece_tbl.insertAssumeCapacity(i + 1, new);
            self.piece_tbl.insertAssumeCapacity(i + 2, right);
            return;
        }
        current += p.len;
    }

    // offset beyond the end: append.
    try self.piece_tbl.append(allocator, .{
        .buf_type = .add,
        .start = start,
        .len = text.len,
    });
}

pub fn delete(
    self: *@This(),
    allocator: mem.Allocator,
    start: usize,
    end: usize,
) !void {
    if (start >= end) return;
    const limit = end - start;
    var current: usize = 0;
    var i: usize = 0;
    var removed: usize = 0;
    while (i < self.piece_tbl.items.len and removed < limit) {
        const p = &self.piece_tbl.items[i];
        const piece_start = current;
        const piece_end = current + p.len;

        if (start >= piece_end or end <= piece_start) {
            // No overlap.
            i += 1;
            current += p.len;
            continue;
        }

        if (start <= piece_start and end >= piece_end) {
            // Delete whole piece.
            _ = self.piece_tbl.orderedRemove(i);
            removed += p.len;
            continue;
        }

        if (start > piece_start and end < piece_end) {
            // Delete middle: split into two pieces.
            const left_len = start - piece_start;
            const right_start = p.start + (end - piece_start);
            const right_len = p.len - left_len - (end - start);
            const left = Piece{
                .buf_type = p.buf_type,
                .start = p.start,
                .len = left_len,
            };
            const right = Piece{
                .buf_type = p.buf_type,
                .start = right_start,
                .len = right_len,
            };
            try self.piece_tbl.ensureUnusedCapacity(allocator, 1);
            self.piece_tbl.items[i] = left;
            self.piece_tbl.insertAssumeCapacity(i + 1, right);

            return;
        }

        if (start > piece_start) {
            // Trim tail.
            const keep = start - piece_start;
            p.len = keep;
            i += 1;
            current += keep;
            continue;
        }

        // end lies inside this piece: trim head.
        const cut = end - piece_start;
        p.start += cut;
        p.len -= cut;
        removed += cut;
        i += 1;
        current += p.len;
    }
}

/// Iterate over the logical sequence of bytes.
pub fn iter(self: *const Self) Iterator {
    return .{ .file = self };
}

pub const Iterator = struct {
    file: *const Self,
    piece_index: usize = 0,
    byte_index: usize = 0,

    pub fn next(self: *Iterator) ?u8 {
        while (self.piece_index < self.file.piece_tbl.items.len) {
            const p = self.file.piece_tbl.items[self.piece_index];
            if (self.byte_index < p.len) {
                const b = self.file.pieceBytes(p)[self.byte_index];
                self.byte_index += 1;
                return b;
            }
            self.piece_index += 1;
            self.byte_index = 0;
        }
        return null;
    }
};

pub fn toString(self: *const Self, allocator: mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, self.totalLen());
    var it = self.iter();
    var i: usize = 0;
    while (it.next()) |b| {
        result[i] = b;
        i += 1;
    }
    return result;
}

pub fn lineCount(self: @This()) usize {
    var count: usize = 1;
    var it = self.iter();
    while (it.next()) |b| {
        if (b == '\n') count += 1;
    }
    return count;
}

/// Returns the content of the given line without the trailing newline.
/// Caller owns the returned slice.
pub fn getLine(
    self: @This(),
    allocator: mem.Allocator,
    line_index: usize,
) ![]u8 {
    var buf = ArrayList(u8).empty;
    var current_line: usize = 0;
    var it = self.iter();
    while (it.next()) |b| {
        if (current_line == line_index) {
            if (b == '\n') break;
            try buf.append(allocator, b);
        } else if (b == '\n') {
            current_line += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Convert a logical byte offset to a line/column pair.
pub fn offsetToLineCol(self: @This(), offset: usize) struct {
    line: usize,
    col: usize,
} {
    var line: usize = 0;
    var col: usize = 0;
    var it = self.iter();
    var i: usize = 0;
    while (it.next()) |b| {
        if (i >= offset) break;
        if (b == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
        i += 1;
    }
    return .{ .line = line, .col = col };
}

/// Convert a line/column pair to a logical byte offset.
pub fn lineColToOffset(
    self: @This(),
    line: usize,
    col: usize,
) usize {
    var current_line: usize = 0;
    var current_col: usize = 0;
    var offset: usize = 0;
    var it = self.iter();
    while (it.next()) |b| {
        if (current_line == line and current_col == col) return offset;
        if (b == '\n') {
            if (current_line == line) return offset;
            current_line += 1;
            current_col = 0;
        } else {
            current_col += 1;
        }
        offset += 1;
    }
    return offset;
}

pub fn lineStartOffset(self: @This(), line: usize) usize {
    return self.lineColToOffset(line, 0);
}

pub fn lineEndOffset(self: @This(), line: usize) usize {
    var current_line: usize = 0;
    var offset: usize = 0;
    var it = self.iter();
    while (it.next()) |b| {
        if (current_line == line and b == '\n') return offset;
        if (b == '\n') current_line += 1;
        offset += 1;
    }
    return offset;
}

pub fn lineLength(self: @This(), line: usize) usize {
    return self.lineEndOffset(line) - self.lineStartOffset(line);
}

test "insert and iterate" {
    const ta = testing.allocator;
    var f = try Self.init(ta, "hello");
    defer f.deinit(ta);

    try f.insert(ta, 5, " world");
    try f.insert(ta, 0, "say ");

    const text = try f.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "say hello world", text);
}

test "delete" {
    const ta = testing.allocator;
    var f = try Self.init(ta, "hello world");
    defer f.deinit(ta);

    try f.delete(ta, 5, 11);
    const text = try f.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "hello", text);
}

test "line operations" {
    const ta = testing.allocator;
    var f = try Self.init(ta, "one\ntwo\nthree");
    defer f.deinit(ta);

    try testing.expectEqual(@as(usize, 3), f.lineCount());

    const line0 = try f.getLine(ta, 0);
    defer ta.free(line0);
    try testing.expectEqualSlices(u8, "one", line0);

    const line1 = try f.getLine(ta, 1);
    defer ta.free(line1);
    try testing.expectEqualSlices(u8, "two", line1);

    try testing.expectEqual(@as(usize, 0), f.lineStartOffset(0));
    try testing.expectEqual(@as(usize, 3), f.lineEndOffset(0));
}
