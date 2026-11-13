#include "zig_c_bindings.h"

#include "private.h"
#include "utils.h"

/* tjs:v8's native classes live in the Zig archive, which calls back into the
 * class id functions below. Bootstrap enters through this file, so a static
 * link pulls it in from libtjs before it reaches that archive: GNU ld scans
 * archives once, in link order. */
void tjs__mod_v8_init(JSContext *ctx, JSValue ns) {
    JSValue v8 = JS_NewObjectProto(ctx, JS_NULL);
    CHECK_EQ(JS_IsException(v8), false);
    CHECK_EQ(zig__mod_v8_compat_init(ctx, v8), 0);
    CHECK_EQ(JS_DefinePropertyValueStr(ctx, ns, "v8", v8, JS_PROP_C_W_E), true);
}

static TJSClass tjs__v8_class(int v8_class) {
    CHECK(v8_class == TJS_V8_CLASS_SERIALIZER || v8_class == TJS_V8_CLASS_DESERIALIZER);
    return v8_class == TJS_V8_CLASS_SERIALIZER ? TJS_CLASS_V8_SERIALIZER : TJS_CLASS_V8_DESERIALIZER;
}

int tjs__v8_class_register(JSContext *ctx, int v8_class, const JSClassDef *def) {
    return tjs__class_register(ctx, tjs__v8_class(v8_class), def);
}

JSClassID tjs__v8_class_id(JSContext *ctx, int v8_class) {
    return tjs__class_id(ctx, tjs__v8_class(v8_class));
}

/* For finalizers, which get only the runtime. */
JSClassID tjs__v8_class_id_rt(JSRuntime *rt, int v8_class) {
    return tjs__class_id_rt(rt, tjs__v8_class(v8_class));
}
