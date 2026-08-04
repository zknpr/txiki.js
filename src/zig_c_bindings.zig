pub const v8_compat = @import("mod_v8_compat.zig");

pub const z = @import("tjs_structs.zig");
pub const c = z.c;

export fn zig__mod_v8_compat_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.c) c_int {
    return v8_compat.initModV8Compat(ctx, ns);
}
