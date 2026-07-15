//! Fixed capacity vectors that do not panic on overflow

//---------------------------------------------------------------------- IMPORTS
const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;
const ta = std.testing.allocator;
//--------------------------------------------------------------- IMPLEMENTATION
const Err = error{
    Overflow,
};
pub fn Vec(comptime T: type) type {
    return struct {
        const Self = @This();
        _buf: []T,
        len: usize = 0,

        pub fn init(buf: []T) @This() {
            return .{ ._buf = buf };
        }

        pub fn push(self: *Self, elem: T) Err!void {
            if (self.len + 1 > self._buf.len) {
                return Err.Overflow;
            }

            self._buf[self.len] = elem;
            self.len += 1;
        }
    };
}
//------------------------------------------------------------------------ TESTS
test "push 2 vals to one capacity vector" {
    const buf = try ta.alloc(u64, 1);
    defer ta.free(buf);
    var v = Vec(u64).init(buf);
    _ = try v.push(42);

    try testing.expectError(error.Overflow, v.push(42));
}
