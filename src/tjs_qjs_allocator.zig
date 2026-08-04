const std = @import("std");

pub const c = @import("tjs_structs.zig").c;

/// A Zig allocator backed by a QuickJS runtime.
///
/// Finalizers receive a JSRuntime, not a live JSContext, so retaining the
/// context-backed allocator from the snapshot would use an invalid context
/// during teardown. The public `*_rt` allocation API is safe in both ordinary
/// calls and class finalizers.
pub const QJSAllocator = struct {
    pub fn allocator(ctx: ?*c.JSContext) std.mem.Allocator {
        std.debug.assert(ctx != null);
        return runtimeAllocator(c.JS_GetRuntime(ctx));
    }

    pub fn runtimeAllocator(rt: ?*c.JSRuntime) std.mem.Allocator {
        std.debug.assert(rt != null);
        return .{
            .ptr = rt.?,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(runtime: *anyopaque, n: usize, log2_ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const rt: *c.JSRuntime = @ptrCast(@alignCast(runtime));
        const ptr = c.js_malloc_rt(rt, n);
        std.debug.assert(@intFromEnum(log2_ptr_align) < 64);
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @as(usize, 1) << @intFromEnum(log2_ptr_align)));
        _ = ret_addr;
        return @ptrCast(ptr);
    }

    fn resize(runtime: *anyopaque, old_mem: []u8, log2_buf_align: std.mem.Alignment, n: usize, ret_addr: usize) bool {
        const rt: *c.JSRuntime = @ptrCast(@alignCast(runtime));
        if (n <= old_mem.len) {
            return true;
        }
        const full_len = c.js_malloc_usable_size_rt(rt, old_mem.ptr);
        if (n <= full_len) {
            return true;
        }
        _ = log2_buf_align;
        _ = ret_addr;
        return false;
    }

    fn free(runtime: *anyopaque, mem: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
        const rt: *c.JSRuntime = @ptrCast(@alignCast(runtime));
        _ = log2_buf_align;
        _ = ret_addr;
        c.js_free_rt(rt, mem.ptr);
    }

    fn remap(runtime: *anyopaque, old_mem: []u8, log2_buf_align: std.mem.Alignment, n: usize, ret_addr: usize) ?[*]u8 {
        const rt: *c.JSRuntime = @ptrCast(@alignCast(runtime));
        _ = ret_addr;
        const new_ptr_opt = c.js_realloc_rt(rt, old_mem.ptr, n);
        if (new_ptr_opt) |new_ptr| {
            std.debug.assert(std.mem.isAligned(@intFromPtr(new_ptr), @as(usize, 1) << @intFromEnum(log2_buf_align)));
            return @ptrCast(new_ptr);
        }
        return null;
    }
};
