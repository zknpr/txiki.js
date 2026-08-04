//! QuickJS ABI bindings used by the Zig compatibility module.
//!
//! Do not mirror private QuickJS structures here. QuickJS-NG deliberately keeps
//! JSObject, JSString, and JSBigInt opaque; all access in this port goes through
//! the public quickjs.h API so a dependency update cannot silently invalidate a
//! hand-written layout.

pub const c = @cImport({
    @cInclude("quickjs.h");
});

pub fn JS_CFUNC_DEF(
    comptime name: [*c]const u8,
    comptime length: u8,
    comptime func: ?*const c.JSCFunction,
) c.JSCFunctionListEntry {
    return .{
        .name = name,
        .prop_flags = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE,
        .def_type = c.JS_DEF_CFUNC,
        .magic = 0,
        .u = .{ .func = .{
            .length = length,
            .cproto = c.JS_CFUNC_generic,
            .cfunc = .{ .generic = func },
        } },
    };
}

pub fn JS_CGETSET_DEF(
    comptime name: [*c]const u8,
    comptime getter: ?*const fn (?*c.JSContext, c.JSValueConst) callconv(.c) c.JSValue,
    comptime setter: ?*const fn (?*c.JSContext, c.JSValueConst, c.JSValueConst) callconv(.c) c.JSValue,
) c.JSCFunctionListEntry {
    return .{
        .name = name,
        .prop_flags = c.JS_PROP_CONFIGURABLE,
        .def_type = c.JS_DEF_CGETSET,
        .magic = 0,
        .u = .{ .getset = .{
            .get = .{ .getter = getter },
            .set = .{ .setter = setter },
        } },
    };
}

const js_nan_boxing = c.INTPTR_MAX < c.INT64_MAX;

fn jsMkVal(comptime tag: i64, comptime value: i32) c.JSValue {
    return .{
        .tag = tag,
        .u = .{ .int32 = value },
    };
}

// translate-c cannot materialize these compound-value macros on 64-bit hosts.
pub const JS_NULL = if (js_nan_boxing) c.JS_NULL else jsMkVal(c.JS_TAG_NULL, 0);
pub const JS_UNDEFINED = if (js_nan_boxing) c.JS_UNDEFINED else jsMkVal(c.JS_TAG_UNDEFINED, 0);
pub const JS_FALSE = if (js_nan_boxing) c.JS_FALSE else jsMkVal(c.JS_TAG_BOOL, 0);
pub const JS_TRUE = if (js_nan_boxing) c.JS_TRUE else jsMkVal(c.JS_TAG_BOOL, 1);
pub const JS_EXCEPTION = if (js_nan_boxing) c.JS_EXCEPTION else jsMkVal(c.JS_TAG_EXCEPTION, 0);

comptime {
    // These are public ABI structs imported from the active dependency. The
    // assertions catch accidental preprocessing/configuration drift at compile
    // time without guessing any private QuickJS layout.
    if (@offsetOf(c.JSCFunctionListEntry, "u") <= @offsetOf(c.JSCFunctionListEntry, "magic")) {
        @compileError("unexpected JSCFunctionListEntry layout");
    }
    if (@sizeOf(c.JSPropertyEnum) < @sizeOf(c.JSAtom) + 1) {
        @compileError("unexpected JSPropertyEnum layout");
    }
}
