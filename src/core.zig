const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const testing = std.testing;

const File = @import("file.zig");

const Pos = struct { row: usize, col: usize };

pub const Size = struct { width: usize, height: usize };

const Mode = enum { normal, insert, command };

pub const Effect = union(enum) { quit, save, message: []const u8 };

const UndoEntry = struct {
    text: []const u8,
    cursor: Pos,
};

pub const Editor = struct {
    file: File,
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
            .file = table,
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
        self.file.deinit(allocator);
        allocator.free(self.filename);
        self.command.deinit(allocator);
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
            if (self.file.lineCount() > vh) self.file.lineCount() - vh else 0;
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
        return self.file.lineCount();
    }

    fn clampCursor(self: *Editor) void {
        const lines = self.lineCount();
        if (self.cursor.row >= lines) self.cursor.row = lines - 1;
        const len = self.file.lineLength(self.cursor.row);
        if (self.cursor.col > len) self.cursor.col = len;
    }

    fn saveUndo(self: *Editor, allocator: mem.Allocator) !void {
        const text = try self.file.toString(allocator);
        try self.undo_stack.append(allocator, .{
            .text = text,
            .cursor = self.cursor,
        });
    }

    fn restoreUndo(self: *Editor, allocator: mem.Allocator) !void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop() orelse return;
        self.file.deinit(allocator);
        self.file = try File.init(allocator, entry.text);
        self.cursor = entry.cursor;
        self.dirty = true;
        self.saved_for_undo = false;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn insertAtCursor(
        self: *Editor,
        allocator: mem.Allocator,
        text: []const u8,
    ) !void {
        const offset = self.file.lineColToOffset(
            self.cursor.row,
            self.cursor.col,
        );
        try self.file.insert(allocator, offset, text);
        const new_pos = self.file.offsetToLineCol(offset + text.len);
        self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
        self.dirty = true;
        self.ensureCursorVisible();
    }

    fn deleteAtCursor(self: *Editor, count: usize) !void {
        const offset = self.file.lineColToOffset(
            self.cursor.row,
            self.cursor.col,
        );
        const total = self.file.totalLen();
        const end = @min(offset + count, total);
        if (end > offset) {
            try self.file.delete(offset, end);
        }
        const new_pos = self.file.offsetToLineCol(offset);
        self.cursor = .{ .row = new_pos.line, .col = new_pos.col };
        self.dirty = true;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn deleteLine(self: *Editor, allocator: mem.Allocator) !void {
        const start = self.file.lineStartOffset(self.cursor.row);
        const end = self.file.lineEndOffset(self.cursor.row) + 1;
        const total = self.file.totalLen();
        const actual_end = @min(end, total);
        try self.file.delete(allocator, start, actual_end);
        self.cursor = .{ .row = self.cursor.row, .col = 0 };
        if (self.file.lineCount() == 0) {
            try self.file.insert(allocator, 0, "\n");
        }
        self.dirty = true;
        self.clampCursor();
        self.ensureCursorVisible();
    }

    fn deleteLineContent(self: *Editor, allocator: mem.Allocator) !void {
        const start = self.file.lineStartOffset(self.cursor.row);
        const end = self.file.lineEndOffset(self.cursor.row);
        if (end > start) {
            try self.file.delete(allocator, start, end);
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
                            const len = self.file.lineLength(self.cursor.row);
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
                            const offset = self.file.lineColToOffset(
                                self.cursor.row,
                                self.cursor.col,
                            );
                            if (offset > 0) {
                                try self.file.delete(allocator, offset - 1, offset);
                                const new_pos =
                                    self.file.offsetToLineCol(offset - 1);
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
        if (line >= self.file.lineCount()) return null;
        return self.file.getLine(allocator, line) catch null;
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

    const text1 = try ed.file.toString(ta);
    defer ta.free(text1);
    try testing.expectEqualSlices(u8, "xyzabc\ndef", text1);

    _ = try ed.handleKey(ta, "\x1b"); // Esc
    _ = try ed.handleKey(ta, "u");

    const text2 = try ed.file.toString(ta);
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

    const text = try ed.file.toString(ta);
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

    const text = try ed.file.toString(ta);
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

    const text = try ed.file.toString(ta);
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

    const text = try ed.file.toString(ta);
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
