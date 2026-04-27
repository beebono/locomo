const std = @import("std");
const app = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;

    try app.run(std.heap.smp_allocator);
}
