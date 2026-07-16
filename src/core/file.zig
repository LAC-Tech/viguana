//! Representation of a file inside an editor.
//! In emacs or vim this is a "buffer"
//! Implemented with piece tables:
//! https://www.cs.unm.edu/~crowley/papers/sds.pdf

//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const math = std.math;
const mem = std.mem;
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
    _reserved: u1 = undefined,
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
    return limits.new_chars_until_swap_write * @sizeOf(u8) +
        limits.inserts_and_undos_until_swap_write * @sizeOf(Piece);
}

pub fn init(a: mem.Allocator, limits: Limits, file_buf: []const u8) !Self {
    var piece_tbl = try ArrayList(Piece).initCapacity(
        a,
        limits.inserts_and_undos_until_swap_write,
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
