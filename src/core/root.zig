//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const ta = testing.allocator;

const Vec = @import("vec.zig").Vec;
//--------------------------------------------------------------- IMPLEMENTATION

/// In a bold, daring example of counter-YAGNIism, this is a struct.
/// All members have a default value, but one day it will be a zon file
const Limits = struct {
    /// I think this is neovim's `updatecount`
    // TODO: ludicrously small because I want to trigger bad behaviour ASAP
    new_chars_until_swap_write: usize = 8,

    /// I think this is neovim's `undolevels`
    // TODO: ludicrously small because I want to trigger bad behaviour ASAP
    inserts_and_undos_until_swap_write: usize = 8,
};

/// Theoretical max 2Gb file size
const FileSize = u31;

const Piece = packed struct(u64) {
    tag: enum(u1) { original, add },
    start: FileSize,
    len: FileSize,
    _reserved: u1 = undefined,
};

/// Representation of a file inside an editor.
/// In emacs or vim this is a "buffer"

// Implemented with piece tables:
// https://www.cs.unm.edu/~crowley/papers/sds.pdf
const File = struct {
    /// A buffer to a temporary file. This buffer is append-only.
    add_buf: Vec(u8),
    piece_tbl: Vec(Piece),

    pub fn init(buf: []u8, limits: Limits, file_buf: []const u8) !File {
        var old_size: usize = 0;
        var size: usize = undefined;

        size = limits.new_chars_until_swap_write * @sizeOf(u8);
        const add_buf = Vec(u8).init(buf[old_size .. old_size + limits]);
        old_size = size;

        size = limits.inserts_and_undos_until_swap_write * @sizeOf(Piece);
        var pieces = Vec(Piece).init(buf[old_size .. old_size + size]);

        try pieces.push(.{
            .tag = .original,
            .start = 0,
            // TODO return error, don't panic
            .len = math.cast(FileSize, file_buf.len) orelse
                debug.panic("File is {d} bytes long; must be less than {d}", .{
                    file_buf.len,
                    math.maxInt(FileSize),
                }),
        });
        return .{
            .add_buf = add_buf,
            .piece_tbl = pieces,
        };
    }
};

const Err = error{
    FileToOLarge,
};

const Self = @This();

_heap_mem: []u8,
_file: File,

fn init(
    a: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) !Self {
    const heap_mem_size =
        limits.new_chars_until_swap_write * @sizeOf(u8) +
        limits.inserts_and_undos_until_swap_write * @sizeOf(Piece);

    const heap_mem = try a.alloc(u8, heap_mem_size);
    var fba = heap.FixedBufferAllocator.init(heap_mem);
    const in_a = fba.allocator();

    var piece_tbl = Vec(Piece).init(
        try in_a.alloc(Piece, limits.inserts_and_undos_until_swap_write),
    );

    try piece_tbl.push(.{
        .tag = .original,
        .start = 0,
        .len = math.cast(
            FileSize,
            file_buf.len,
        ) orelse return error.FileTooLarge,
    });

    const result = Self{
        ._heap_mem = heap_mem,
        ._file = .{
            .add_buf = Vec(u8).init(
                try in_a.alloc(u8, limits.new_chars_until_swap_write),
            ),
            .piece_tbl = piece_tbl,
        },
    };

    // Memory needed was pre-calculated correctly
    debug.assert(heap_mem_size == fba.end_index);

    return result;
}

fn deinit(self: *Self, external_allocator: mem.Allocator) void {
    external_allocator.free(self._heap_mem);
}
//------------------------------------------------------------------------ TESTS
test {
    // TODO: can I get rid of this, since I import it anyway?
    _ = @import("vec.zig");
}

test "init & deninit" {
    var core = try Self.init(ta, Limits{}, "hello world!");
    defer core.deinit(ta);
}
