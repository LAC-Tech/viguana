const std = @import("std");

pub const Buffer = enum { original, add };

pub const Piece = struct {
    buffer: Buffer,
    start: usize,
    len: usize,
};

/// A piece table: two immutable-ish source buffers (original + add) and a list
/// of pieces that describe the current logical sequence.
pub const PieceTable = struct {
    allocator: std.mem.Allocator,
    original: []const u8,
    add: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),

    pub fn init(allocator: std.mem.Allocator, original: []const u8) !PieceTable {
        const owned_original = try allocator.dupe(u8, original);
        var pieces = std.ArrayList(Piece).empty;
        if (original.len > 0) {
            try pieces.append(allocator, .{ .buffer = .original, .start = 0, .len = original.len });
        }
        return .{
            .allocator = allocator,
            .original = owned_original,
            .add = .empty,
            .pieces = pieces,
        };
    }

    pub fn deinit(self: *PieceTable) void {
        self.allocator.free(self.original);
        self.add.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
    }

    fn pieceBytes(self: *const PieceTable, piece: Piece) []const u8 {
        return switch (piece.buffer) {
            .original => self.original[piece.start .. piece.start + piece.len],
            .add => self.add.items[piece.start .. piece.start + piece.len],
        };
    }

    pub fn totalLen(self: *const PieceTable) usize {
        var len: usize = 0;
        for (self.pieces.items) |p| {
            len += p.len;
        }
        return len;
    }

    pub fn insert(self: *PieceTable, offset: usize, text: []const u8) !void {
        if (text.len == 0) return;
        const start: usize = self.add.items.len;
        try self.add.appendSlice(self.allocator, text);

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, .{ .buffer = .add, .start = start, .len = text.len });
            return;
        }

        var current: usize = 0;
        var i: usize = 0;
        while (i < self.pieces.items.len) : (i += 1) {
            const p = self.pieces.items[i];
            if (current + p.len >= offset) {
                const split = offset - current;
                const left = Piece{ .buffer = p.buffer, .start = p.start, .len = split };
                const right = Piece{ .buffer = p.buffer, .start = p.start + split, .len = p.len - split };
                const new = Piece{ .buffer = .add, .start = start, .len = text.len };

                try self.pieces.ensureUnusedCapacity(self.allocator, 2);
                self.pieces.items[i] = left;
                self.pieces.insertAssumeCapacity(i + 1, new);
                self.pieces.insertAssumeCapacity(i + 2, right);
                return;
            }
            current += p.len;
        }

        // offset beyond the end: append.
        try self.pieces.append(self.allocator, .{ .buffer = .add, .start = start, .len = text.len });
    }

    pub fn delete(self: *PieceTable, start: usize, end: usize) !void {
        if (start >= end) return;
        const limit = end - start;
        var current: usize = 0;
        var i: usize = 0;
        var removed: usize = 0;
        while (i < self.pieces.items.len and removed < limit) {
            const p = &self.pieces.items[i];
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
                _ = self.pieces.orderedRemove(i);
                removed += p.len;
                continue;
            }

            if (start > piece_start and end < piece_end) {
                // Delete middle: split into two pieces.
                const left_len = start - piece_start;
                const right_start = p.start + (end - piece_start);
                const right_len = p.len - left_len - (end - start);
                const left = Piece{ .buffer = p.buffer, .start = p.start, .len = left_len };
                const right = Piece{ .buffer = p.buffer, .start = right_start, .len = right_len };
                try self.pieces.ensureUnusedCapacity(self.allocator, 1);
                self.pieces.items[i] = left;
                self.pieces.insertAssumeCapacity(i + 1, right);
                return;
            }

            if (start > piece_start) {
                // Trim tail.
                const keep = start - piece_start;
                p.len = keep;
                removed += p.len - keep;
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
    pub fn iter(self: *const PieceTable) Iterator {
        return .{ .table = self };
    }

    pub const Iterator = struct {
        table: *const PieceTable,
        piece_index: usize = 0,
        byte_index: usize = 0,

        pub fn next(self: *Iterator) ?u8 {
            while (self.piece_index < self.table.pieces.items.len) {
                const p = self.table.pieces.items[self.piece_index];
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

    pub fn toString(self: *const PieceTable, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, self.totalLen());
        var it = self.iter();
        var i: usize = 0;
        while (it.next()) |b| {
            result[i] = b;
            i += 1;
        }
        return result;
    }

    pub fn lineCount(self: *const PieceTable) usize {
        var count: usize = 1;
        var it = self.iter();
        while (it.next()) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    /// Returns the content of the given line without the trailing newline.
    /// Caller owns the returned slice.
    pub fn getLine(self: *const PieceTable, allocator: std.mem.Allocator, line_index: usize) ![]u8 {
        var buf = std.ArrayList(u8).empty;
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
    pub fn offsetToLineCol(self: *const PieceTable, offset: usize) struct { line: usize, col: usize } {
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
    pub fn lineColToOffset(self: *const PieceTable, line: usize, col: usize) usize {
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

    pub fn lineStartOffset(self: *const PieceTable, line: usize) usize {
        return self.lineColToOffset(line, 0);
    }

    pub fn lineEndOffset(self: *const PieceTable, line: usize) usize {
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

    pub fn lineLength(self: *const PieceTable, line: usize) usize {
        return self.lineEndOffset(line) - self.lineStartOffset(line);
    }
};

pub const Pos = struct {
    row: usize,
    col: usize,
};

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Mode = enum {
    normal,
    insert,
    command,
};

pub const Effect = union(enum) {
    quit,
    save,
    message: []const u8,
};

pub const UndoEntry = struct {
    text: []const u8,
    cursor: Pos,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UndoEntry) void {
        self.allocator.free(self.text);
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    table: PieceTable,
    mode: Mode,
    cursor: Pos,
    scroll: usize,
    screen: Size,
    command: std.ArrayList(u8),
    filename: []const u8,
    dirty: bool,
    quit: bool,
    undo_stack: std.ArrayList(UndoEntry),
    saved_for_undo: bool,

    pub fn init(allocator: std.mem.Allocator, text: []const u8, filename: []const u8, screen: Size) !Editor {
        var table = try PieceTable.init(allocator, text);
        errdefer table.deinit();

        const undo_stack = std.ArrayList(UndoEntry).empty;
        const command = std.ArrayList(u8).empty;

        const cursor = Pos{ .row = 0, .col = 0 };
        if (table.lineCount() == 0) {
            // Empty file: start with one empty line.
            try table.insert(0, "\n");
        }

        return .{
            .allocator = allocator,
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

    pub fn deinit(self: *Editor) void {
        self.table.deinit();
        self.allocator.free(self.filename);
        self.command.deinit(self.allocator);
        for (self.undo_stack.items) |*entry| {
            entry.deinit();
        }
        self.undo_stack.deinit(self.allocator);
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
        const max_scroll = if (self.table.lineCount() > vh) self.table.lineCount() - vh else 0;
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

    fn saveUndo(self: *Editor) !void {
        const text = try self.table.toString(self.allocator);
        try self.undo_stack.append(self.allocator, .{
            .text = text,
            .cursor = self.cursor,
            .allocator = self.allocator,
        });
    }

    fn restoreUndo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;
        var entry = self.undo_stack.pop() orelse return;
        self.table.deinit();
        self.table = try PieceTable.init(self.allocator, entry.text);
        self.cursor = entry.cursor;
        self.dirty = true;
        self.saved_for_undo = false;
        entry.deinit();
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn insertAtCursor(self: *Editor, text: []const u8) !void {
        const offset = self.table.lineColToOffset(self.cursor.row, self.cursor.col);
        try self.table.insert(offset, text);
        const new_pos = self.table.offsetToLineCol(offset + text.len);
        self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
        self.dirty = true;
        self.ensureCursorVisible();
    }

    fn deleteAtCursor(self: *Editor, count: usize) !void {
        const offset = self.table.lineColToOffset(self.cursor.row, self.cursor.col);
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

    fn deleteLine(self: *Editor) !void {
        const start = self.table.lineStartOffset(self.cursor.row);
        const end = self.table.lineEndOffset(self.cursor.row) + 1;
        const total = self.table.totalLen();
        const actual_end = @min(end, total);
        try self.table.delete(start, actual_end);
        self.cursor = .{ .row = self.cursor.row, .col = 0 };
        if (self.table.lineCount() == 0) {
            try self.table.insert(0, "\n");
        }
        self.dirty = true;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn deleteLineContent(self: *Editor) !void {
        const start = self.table.lineStartOffset(self.cursor.row);
        const end = self.table.lineEndOffset(self.cursor.row);
        if (end > start) {
            try self.table.delete(start, end);
        }
        self.cursor = .{ .row = self.cursor.row, .col = 0 };
        self.dirty = true;
        self.ensureCursorVisible();
    }

    fn changeLine(self: *Editor) !void {
        try self.deleteLineContent();
        self.mode = .insert;
        self.saved_for_undo = false;
    }

    fn executeCommand(self: *Editor) !?Effect {
        const cmd = self.command.items;
        if (std.mem.eql(u8, cmd, "w")) {
            self.command.clearRetainingCapacity();
            self.mode = .normal;
            return .save;
        } else if (std.mem.eql(u8, cmd, "q")) {
            self.command.clearRetainingCapacity();
            self.quit = true;
            return .quit;
        } else {
            self.command.clearRetainingCapacity();
            self.mode = .normal;
            const msg = try self.allocator.dupe(u8, "unknown command");
            return .{ .message = msg };
        }
    }

    pub fn handleKey(self: *Editor, key: []const u8) !?Effect {
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
                            try self.saveUndo();
                            self.saved_for_undo = true;
                        },
                        'd' => {
                            try self.saveUndo();
                            try self.deleteLine();
                            self.saved_for_undo = false;
                        },
                        'c' => {
                            try self.saveUndo();
                            try self.changeLine();
                            self.saved_for_undo = false;
                        },
                        'u' => {
                            try self.restoreUndo();
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
                        try self.insertAtCursor("\n");
                    } else if (k == 127 or k == '\x08') { // Backspace / DEL
                        if (self.cursor.col > 0 or self.cursor.row > 0) {
                            const offset = self.table.lineColToOffset(self.cursor.row, self.cursor.col);
                            if (offset > 0) {
                                try self.table.delete(offset - 1, offset);
                                const new_pos = self.table.offsetToLineCol(offset - 1);
                                self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
                                self.dirty = true;
                                self.clampCursor();
                                self.ensureCursorVisible();
                            }
                        }
                    } else {
                        try self.insertAtCursor(key);
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
                        return try self.executeCommand();
                    } else if (k == 127 or k == '\x08') {
                        if (self.command.items.len > 0) {
                            _ = self.command.pop();
                        }
                    } else {
                        try self.command.append(self.allocator, k);
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

    pub fn getVisibleLine(self: *Editor, allocator: std.mem.Allocator, screen_row: usize) ?[]u8 {
        const line = self.scroll + screen_row;
        if (line >= self.table.lineCount()) return null;
        return self.table.getLine(allocator, line) catch null;
    }

    pub fn getCommandLine(self: *Editor, allocator: std.mem.Allocator) !?[]u8 {
        if (self.mode != .command) return null;
        var result = std.ArrayList(u8).empty;
        try result.append(allocator, ':');
        try result.appendSlice(allocator, self.command.items);
        const slice = try result.toOwnedSlice(allocator);
        return slice;
    }
};

// ---- Tests ------------------------------------------------------------------

test "piece table insert and iterate" {
    const gpa = std.testing.allocator;
    var pt = try PieceTable.init(gpa, "hello");
    defer pt.deinit();

    try pt.insert(5, " world");
    try pt.insert(0, "say ");

    const text = try pt.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "say hello world", text);
}

test "piece table delete" {
    const gpa = std.testing.allocator;
    var pt = try PieceTable.init(gpa, "hello world");
    defer pt.deinit();

    try pt.delete(5, 11);
    const text = try pt.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "hello", text);
}

test "piece table line operations" {
    const gpa = std.testing.allocator;
    var pt = try PieceTable.init(gpa, "one\ntwo\nthree");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    const line0 = try pt.getLine(gpa, 0);
    defer gpa.free(line0);
    try std.testing.expectEqualSlices(u8, "one", line0);

    const line1 = try pt.getLine(gpa, 1);
    defer gpa.free(line1);
    try std.testing.expectEqualSlices(u8, "two", line1);

    try std.testing.expectEqual(@as(usize, 0), pt.lineStartOffset(0));
    try std.testing.expectEqual(@as(usize, 3), pt.lineEndOffset(0));
}

test "editor movement" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef\nghi", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("l");
    _ = try ed.handleKey("l");
    _ = try ed.handleKey("l");
    _ = try ed.handleKey("l");
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);

    _ = try ed.handleKey("j");
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);

    _ = try ed.handleKey("h");
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);

    _ = try ed.handleKey("k");
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "editor insert and undo" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("i");
    _ = try ed.handleKey("x");
    _ = try ed.handleKey("y");
    _ = try ed.handleKey("z");

    const text1 = try ed.table.toString(gpa);
    defer gpa.free(text1);
    try std.testing.expectEqualSlices(u8, "xyzabc\ndef", text1);

    _ = try ed.handleKey("\x1b"); // Esc
    _ = try ed.handleKey("u");

    const text2 = try ed.table.toString(gpa);
    defer gpa.free(text2);
    try std.testing.expectEqualSlices(u8, "abc\ndef", text2);
}

test "editor dd" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef\nghi", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("j");
    _ = try ed.handleKey("d");

    const text = try ed.table.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "abc\nghi", text);
}

test "editor cc" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef\nghi", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("j");
    _ = try ed.handleKey("c");
    _ = try ed.handleKey("x");
    _ = try ed.handleKey("y");
    _ = try ed.handleKey("\x1b"); // Esc

    const text = try ed.table.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "abc\nxy\nghi", text);
}

test "editor undo dd" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef\nghi", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("j");
    _ = try ed.handleKey("d");
    _ = try ed.handleKey("u");

    const text = try ed.table.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "abc\ndef\nghi", text);
}

test "editor undo cc" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef\nghi", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey("j");
    _ = try ed.handleKey("c");
    _ = try ed.handleKey("x");
    _ = try ed.handleKey("\x1b"); // Esc
    _ = try ed.handleKey("u");

    const text = try ed.table.toString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualSlices(u8, "abc\ndef\nghi", text);
}

test "editor command save and quit" {
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, "abc\ndef", "test", .{ .width = 80, .height = 24 });
    defer ed.deinit();

    _ = try ed.handleKey(":");
    _ = try ed.handleKey("w");
    const effect = try ed.handleKey("\r");
    try std.testing.expect(effect != null);
    try std.testing.expect(effect.? == .save);
    try std.testing.expectEqual(Mode.normal, ed.mode);

    _ = try ed.handleKey(":");
    _ = try ed.handleKey("q");
    const effect2 = try ed.handleKey("\r");
    try std.testing.expect(effect2 != null);
    try std.testing.expect(effect2.? == .quit);
    try std.testing.expect(ed.quit);
}
