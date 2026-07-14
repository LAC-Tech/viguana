const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const testing = std.testing;

const Piece = struct {
    buf_type: enum { original, add },
    start: usize,
    len: usize,
};

const File = struct {
    /// A buffer to the original text document. This buffer is read-only.
    original_buf: []const u8,
    /// A buffer to a temporary file. This buffer is append-only.
    add_buf: ArrayList(u8),
    piece_tbl: ArrayList(Piece),

    pub fn init(allocator: mem.Allocator, original: []const u8) !File {
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

    pub fn deinit(self: *File, allocator: mem.Allocator) void {
        allocator.free(self.original_buf);
        self.add_buf.deinit(allocator);
        self.piece_tbl.deinit(allocator);
    }

    fn pieceBytes(self: *const File, piece: Piece) []const u8 {
        const end = piece.start + piece.len;
        return switch (piece.buf_type) {
            .original => self.original_buf[piece.start..end],
            .add => self.add_buf.items[piece.start..end],
        };
    }

    fn totalLen(self: *const File) usize {
        var len: usize = 0;
        for (self.piece_tbl.items) |p| {
            len += p.len;
        }
        return len;
    }

    pub fn insert(
        self: *File,
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
        self: *File,
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
    pub fn iter(self: *const File) Iterator {
        return .{ .table = self };
    }

    pub const Iterator = struct {
        table: *const File,
        piece_index: usize = 0,
        byte_index: usize = 0,

        pub fn next(self: *Iterator) ?u8 {
            while (self.piece_index < self.table.piece_tbl.items.len) {
                const p = self.table.piece_tbl.items[self.piece_index];
                if (self.byte_index < p.len) {
                    const b = self.table.pieceBytes(p)[self.byte_index];
                    self.byte_index += 1;
                    return b;
                }
                self.piece_index += 1;
                self.byte_index = 0;
            }
            return null;
        }
    };

    pub fn toString(self: *const File, allocator: mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, self.totalLen());
        var it = self.iter();
        var i: usize = 0;
        while (it.next()) |b| {
            result[i] = b;
            i += 1;
        }
        return result;
    }

    pub fn lineCount(self: *const File) usize {
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
        self: *const File,
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
    pub fn offsetToLineCol(self: *const File, offset: usize) struct {
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
        self: *const File,
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

    pub fn lineStartOffset(self: *const File, line: usize) usize {
        return self.lineColToOffset(line, 0);
    }

    pub fn lineEndOffset(self: *const File, line: usize) usize {
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

    pub fn lineLength(self: *const File, line: usize) usize {
        return self.lineEndOffset(line) - self.lineStartOffset(line);
    }
};

pub const Pos = struct { row: usize, col: usize };

pub const Size = struct { width: usize, height: usize };

pub const Mode = enum { normal, insert, command };

pub const Effect = union(enum) { quit, save, message: []const u8 };

pub const UndoEntry = struct {
    text: []const u8,
    cursor: Pos,

    pub fn deinit(self: *UndoEntry, allocator: mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Editor = struct {
    table: File,
    mode: Mode,
    cursor: Pos,
    scroll: usize,
    screen: Size,
    command: ArrayList(u8),
    filename: []const u8,
    dirty: bool,
    quit: bool,
    undo_stack: ArrayList(UndoEntry),
    saved_for_undo: bool,

    pub fn init(
        allocator: mem.Allocator,
        text: []const u8,
        filename: []const u8,
        screen: Size,
    ) !Editor {
        var table = try File.init(allocator, text);
        errdefer table.deinit(allocator);

        const undo_stack = ArrayList(UndoEntry).empty;
        const command = ArrayList(u8).empty;

        const cursor = Pos{ .row = 0, .col = 0 };
        if (table.lineCount() == 0) {
            // Empty file: start with one empty line.
            try table.insert(allocator, 0, "\n");
        }

        return .{
            .table = table,
            .mode = .normal,
            .cursor = cursor,
            .scroll = 0,
            .screen = screen,
            .command = command,
            .filename = try allocator.dupe(u8, filename),
            .dirty = false,
            .quit = false,
            .undo_stack = undo_stack,
            .saved_for_undo = false,
        };
    }

    pub fn deinit(self: *Editor, allocator: mem.Allocator) void {
        self.table.deinit(allocator);
        allocator.free(self.filename);
        self.command.deinit(allocator);
        for (self.undo_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.undo_stack.deinit(allocator);
    }

    pub fn screenSize(self: *Editor) Size {
        return self.screen;
    }

    pub fn setScreenSize(self: *Editor, size: Size) void {
        self.screen = size;
        self.clampScroll();
    }

    pub fn viewHeight(self: *Editor) usize {
        return if (self.mode == .command) self.screen.height - 1 else self.screen.height;
    }

    fn clampScroll(self: *Editor) void {
        const vh = self.viewHeight();
        const max_scroll =
            if (self.table.lineCount() > vh) self.table.lineCount() - vh else 0;
        self.scroll = @min(self.scroll, max_scroll);
    }

    fn ensureCursorVisible(self: *Editor) void {
        const vh = self.viewHeight();
        if (self.cursor.row < self.scroll) {
            self.scroll = self.cursor.row;
        } else if (self.cursor.row >= self.scroll + vh) {
            self.scroll = self.cursor.row + 1 - vh;
        }
    }

    fn lineCount(self: *Editor) usize {
        return self.table.lineCount();
    }

    fn clampCursor(self: *Editor) void {
        const lines = self.lineCount();
        if (self.cursor.row >= lines) self.cursor.row = lines - 1;
        const len = self.table.lineLength(self.cursor.row);
        if (self.cursor.col > len) self.cursor.col = len;
    }

    fn saveUndo(self: *Editor, allocator: mem.Allocator) !void {
        const text = try self.table.toString(allocator);
        try self.undo_stack.append(allocator, .{
            .text = text,
            .cursor = self.cursor,
        });
    }

    fn restoreUndo(self: *Editor, allocator: mem.Allocator) !void {
        if (self.undo_stack.items.len == 0) return;
        var entry = self.undo_stack.pop() orelse return;
        self.table.deinit(allocator);
        self.table = try File.init(allocator, entry.text);
        self.cursor = entry.cursor;
        self.dirty = true;
        self.saved_for_undo = false;
        entry.deinit(allocator);
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn insertAtCursor(
        self: *Editor,
        allocator: mem.Allocator,
        text: []const u8,
    ) !void {
        const offset = self.table.lineColToOffset(
            self.cursor.row,
            self.cursor.col,
        );
        try self.table.insert(allocator, offset, text);
        const new_pos = self.table.offsetToLineCol(offset + text.len);
        self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
        self.dirty = true;
        self.ensureCursorVisible();
    }

    fn deleteAtCursor(self: *Editor, count: usize) !void {
        const offset = self.table.lineColToOffset(
            self.cursor.row,
            self.cursor.col,
        );
        const total = self.table.totalLen();
        const end = @min(offset + count, total);
        if (end > offset) {
            try self.table.delete(offset, end);
        }
        const new_pos = self.table.offsetToLineCol(offset);
        self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
        self.dirty = true;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn deleteLine(self: *Editor, allocator: mem.Allocator) !void {
        const start = self.table.lineStartOffset(self.cursor.row);
        const end = self.table.lineEndOffset(self.cursor.row) + 1;
        const total = self.table.totalLen();
        const actual_end = @min(end, total);
        try self.table.delete(allocator, start, actual_end);
        self.cursor = .{ .row = self.cursor.row, .col = 0 };
        if (self.table.lineCount() == 0) {
            try self.table.insert(allocator, 0, "\n");
        }
        self.dirty = true;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn deleteLineContent(self: *Editor, allocator: mem.Allocator) !void {
        const start = self.table.lineStartOffset(self.cursor.row);
        const end = self.table.lineEndOffset(self.cursor.row);
        if (end > start) {
            try self.table.delete(allocator, start, end);
        }
        self.cursor = .{ .row = self.cursor.row, .col = 0 };
        self.dirty = true;
        self.ensureCursorVisible();
    }

    fn changeLine(self: *Editor, allocator: mem.Allocator) !void {
        try self.deleteLineContent(allocator);
        self.mode = .insert;
        self.saved_for_undo = false;
    }

    fn executeCommand(self: *Editor, allocator: mem.Allocator) !?Effect {
        const cmd = self.command.items;
        if (mem.eql(u8, cmd, "w")) {
            self.command.clearRetainingCapacity();
            self.mode = .normal;
            return .save;
        } else if (mem.eql(u8, cmd, "q")) {
            self.command.clearRetainingCapacity();
            self.quit = true;
            return .quit;
        } else {
            self.command.clearRetainingCapacity();
            self.mode = .normal;
            const msg = try allocator.dupe(u8, "unknown command");
            return .{ .message = msg };
        }
    }

    pub fn handleKey(
        self: *Editor,
        allocator: mem.Allocator,
        key: []const u8,
    ) !?Effect {
        switch (self.mode) {
            .normal => {
                if (key.len == 1) {
                    switch (key[0]) {
                        'h' => {
                            if (self.cursor.col > 0) self.cursor.col -= 1;
                        },
                        'j' => {
                            if (self.cursor.row + 1 < self.lineCount()) {
                                self.cursor.row += 1;
                                self.clampCursor();
                            }
                            self.ensureCursorVisible();
                        },
                        'k' => {
                            if (self.cursor.row > 0) {
                                self.cursor.row -= 1;
                                self.clampCursor();
                            }
                            self.ensureCursorVisible();
                        },
                        'l' => {
                            const len = self.table.lineLength(self.cursor.row);
                            if (self.cursor.col < len) self.cursor.col += 1;
                        },
                        'i' => {
                            self.mode = .insert;
                            try self.saveUndo(allocator);
                            self.saved_for_undo = true;
                        },
                        'd' => {
                            try self.saveUndo(allocator);
                            try self.deleteLine(allocator);
                            self.saved_for_undo = false;
                        },
                        'c' => {
                            try self.saveUndo(allocator);
                            try self.changeLine(allocator);
                            self.saved_for_undo = false;
                        },
                        'u' => {
                            try self.restoreUndo(allocator);
                        },
                        ':' => {
                            self.mode = .command;
                            self.command.clearRetainingCapacity();
                        },
                        else => {},
                    }
                }
            },
            .insert => {
                if (key.len == 1) {
                    const k = key[0];
                    if (k == 27) { // Esc
                        self.mode = .normal;
                        self.saved_for_undo = false;
                        // When leaving insert, clamp cursor to line end.
                        self.clampCursor();
                    } else if (k == '\r' or k == '\n') {
                        try self.insertAtCursor(allocator, "\n");
                    } else if (k == 127 or k == '\x08') { // Backspace / DEL
                        if (self.cursor.col > 0 or self.cursor.row > 0) {
                            const offset = self.table.lineColToOffset(
                                self.cursor.row,
                                self.cursor.col,
                            );
                            if (offset > 0) {
                                try self.table.delete(allocator, offset - 1, offset);
                                const new_pos =
                                    self.table.offsetToLineCol(offset - 1);
                                self.cursor = .{
                                    .row = new_pos.line,
                                    .col = new_pos.col,
                                };
                                self.dirty = true;
                                self.clampCursor();
                                self.ensureCursorVisible();
                            }
                        }
                    } else {
                        try self.insertAtCursor(allocator, key);
                    }
                }
            },
            .command => {
                if (key.len == 1) {
                    const k = key[0];
                    if (k == 27) { // Esc
                        self.mode = .normal;
                        self.command.clearRetainingCapacity();
                    } else if (k == '\r' or k == '\n') {
                        return try self.executeCommand(allocator);
                    } else if (k == 127 or k == '\x08') {
                        if (self.command.items.len > 0) {
                            _ = self.command.pop();
                        }
                    } else {
                        try self.command.append(allocator, k);
                    }
                }
            },
        }
        return null;
    }

    /// Return the visible line range and the screen-relative cursor position.
    pub fn renderInfo(self: *Editor) struct {
        scroll: usize,
        view_height: usize,
        cursor_screen: Pos,
    } {
        const vh = self.viewHeight();
        const cursor_screen = Pos{
            .row = self.cursor.row - self.scroll,
            .col = self.cursor.col,
        };
        return .{
            .scroll = self.scroll,
            .view_height = vh,
            .cursor_screen = cursor_screen,
        };
    }

    pub fn getVisibleLine(
        self: *Editor,
        allocator: mem.Allocator,
        screen_row: usize,
    ) ?[]u8 {
        const line = self.scroll + screen_row;
        if (line >= self.table.lineCount()) return null;
        return self.table.getLine(allocator, line) catch null;
    }

    pub fn getCommandLine(self: *Editor, allocator: mem.Allocator) !?[]u8 {
        if (self.mode != .command) return null;
        var result = ArrayList(u8).empty;
        try result.append(allocator, ':');
        try result.appendSlice(allocator, self.command.items);
        const slice = try result.toOwnedSlice(allocator);
        return slice;
    }
};

// ---- Tests ------------------------------------------------------------------

test "piece table insert and iterate" {
    const ta = testing.allocator;
    var pt = try File.init(ta, "hello");
    defer pt.deinit(ta);

    try pt.insert(ta, 5, " world");
    try pt.insert(ta, 0, "say ");

    const text = try pt.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "say hello world", text);
}

test "piece table delete" {
    const ta = testing.allocator;
    var pt = try File.init(ta, "hello world");
    defer pt.deinit(ta);

    try pt.delete(ta, 5, 11);
    const text = try pt.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "hello", text);
}

test "piece table line operations" {
    const ta = testing.allocator;
    var pt = try File.init(ta, "one\ntwo\nthree");
    defer pt.deinit(ta);

    try testing.expectEqual(@as(usize, 3), pt.lineCount());

    const line0 = try pt.getLine(ta, 0);
    defer ta.free(line0);
    try testing.expectEqualSlices(u8, "one", line0);

    const line1 = try pt.getLine(ta, 1);
    defer ta.free(line1);
    try testing.expectEqualSlices(u8, "two", line1);

    try testing.expectEqual(@as(usize, 0), pt.lineStartOffset(0));
    try testing.expectEqual(@as(usize, 3), pt.lineEndOffset(0));
}

test "editor movement" {
    const ta = testing.allocator;
    var ed = try Editor.init(
        ta,
        "abc\ndef\nghi",
        "test",
        .{ .width = 80, .height = 24 },
    );
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "l");
    _ = try ed.handleKey(ta, "l");
    _ = try ed.handleKey(ta, "l");
    _ = try ed.handleKey(ta, "l");
    try testing.expectEqual(@as(usize, 3), ed.cursor.col);

    _ = try ed.handleKey(ta, "j");
    try testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try testing.expectEqual(@as(usize, 3), ed.cursor.col);

    _ = try ed.handleKey(ta, "h");
    try testing.expectEqual(@as(usize, 2), ed.cursor.col);

    _ = try ed.handleKey(ta, "k");
    try testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "editor insert and undo" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "i");
    _ = try ed.handleKey(ta, "x");
    _ = try ed.handleKey(ta, "y");
    _ = try ed.handleKey(ta, "z");

    const text1 = try ed.table.toString(ta);
    defer ta.free(text1);
    try testing.expectEqualSlices(u8, "xyzabc\ndef", text1);

    _ = try ed.handleKey(ta, "\x1b"); // Esc
    _ = try ed.handleKey(ta, "u");

    const text2 = try ed.table.toString(ta);
    defer ta.free(text2);
    try testing.expectEqualSlices(u8, "abc\ndef", text2);
}

test "editor dd" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef\nghi", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "j");
    _ = try ed.handleKey(ta, "d");

    const text = try ed.table.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "abc\nghi", text);
}

test "editor cc" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef\nghi", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "j");
    _ = try ed.handleKey(ta, "c");
    _ = try ed.handleKey(ta, "x");
    _ = try ed.handleKey(ta, "y");
    _ = try ed.handleKey(ta, "\x1b"); // Esc

    const text = try ed.table.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "abc\nxy\nghi", text);
}

test "editor undo dd" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef\nghi", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "j");
    _ = try ed.handleKey(ta, "d");
    _ = try ed.handleKey(ta, "u");

    const text = try ed.table.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "abc\ndef\nghi", text);
}

test "editor undo cc" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef\nghi", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, "j");
    _ = try ed.handleKey(ta, "c");
    _ = try ed.handleKey(ta, "x");
    _ = try ed.handleKey(ta, "\x1b"); // Esc
    _ = try ed.handleKey(ta, "u");

    const text = try ed.table.toString(ta);
    defer ta.free(text);
    try testing.expectEqualSlices(u8, "abc\ndef\nghi", text);
}

test "editor command save and quit" {
    const ta = testing.allocator;
    var ed = try Editor.init(ta, "abc\ndef", "test", .{
        .width = 80,
        .height = 24,
    });
    defer ed.deinit(ta);

    _ = try ed.handleKey(ta, ":");
    _ = try ed.handleKey(ta, "w");
    const effect = try ed.handleKey(ta, "\r");
    try testing.expect(effect != null);
    try testing.expect(effect.? == .save);
    try testing.expectEqual(Mode.normal, ed.mode);

    _ = try ed.handleKey(ta, ":");
    _ = try ed.handleKey(ta, "q");
    const effect2 = try ed.handleKey(ta, "\r");
    try testing.expect(effect2 != null);
    try testing.expect(effect2.? == .quit);
    try testing.expect(ed.quit);
}
