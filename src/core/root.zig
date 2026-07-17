//! Deterministic Core of the Editor.
//!
//! It should only allocate memory once and free it once.
//! This keeps memeory usage bounded, and simplifies design, and avoids memcpy

//---------------------------------------------------------------------- IMPORTS

const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const ta = testing.allocator;
const ArrayList = std.ArrayList;

const Limits = @import("limits.zig");
const File = @import("file.zig");
//--------------------------------------------------------------- IMPLEMENTATION
const Self = @This();

pub const Err = struct {
    pub const Alloc = mem.Allocator.Error;
};

/// All the heap memory that will ever be needed.
/// It's owned by core and should not be touched.
_heap_mem: []const u8,
_file: File,

fn init(
    one_shot_allocator: mem.Allocator,
    limits: Limits,
    file_buf: []const u8,
) (File.Err.Init || Err.Alloc)!Self {
    const heap_mem_size = File.memory_needed(limits.file);

    const heap_mem = try one_shot_allocator.alloc(u8, heap_mem_size);
    var fba = heap.FixedBufferAllocator.init(heap_mem);
    const a = fba.allocator();

    const result = Self{
        ._heap_mem = heap_mem,
        ._file = try File.init(a, limits.file, file_buf),
    };

    // Memory needed was pre-calculated correctly
    debug.assert(heap_mem_size == fba.end_index);

    return result;
}

fn deinit(self: *Self, one_shot_allocator: mem.Allocator) void {
    one_shot_allocator.free(self._heap_mem);
}
//------------------------------------------------------------------------ TESTS
test "init & deninit" {
    var core = try Self.init(ta, Limits{}, "hello world!");
    defer core.deinit(ta);
}
