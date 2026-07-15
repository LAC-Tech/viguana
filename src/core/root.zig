//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const ta = testing.allocator;

const vec = @import("vec.zig");
const Vec = vec.Vec;
//--------------------------------------------------------------- IMPLEMENTATION

/// Hard limits to prevent re-allocation
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
    // Read-only buffer to the original file
    file_buf: []const u8,
    /// Append only buffer to a temp file
    add_buf: Vec(u8),
    piece_tbl: Vec(Piece),
};

const Err = error{
    FileTooLarge,
};

const Self = @This();

/// All the heap memory that will ever be needed.
/// It's owned by core and should not be touched.
_heap_mem: []const u8,
_file: File,

fn init(
    a: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) (Err || mem.Allocator.Error || vec.Err)!Self {
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
            .file_buf = file_buf,
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
