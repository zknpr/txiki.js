#ifndef TJS_ZIG_C_BINDINGS_H
#define TJS_ZIG_C_BINDINGS_H

#include <quickjs.h>

int zig__mod_v8_compat_init(JSContext *ctx, JSValue ns);

/* The tjs:v8 native classes. Zig sees only quickjs.h and this header, so it
 * names its classes with these values; src/zig_c_bindings.c maps them to
 * TJSClass entries in private.h. */
enum {
    TJS_V8_CLASS_SERIALIZER = 0,
    TJS_V8_CLASS_DESERIALIZER = 1,
};

/* Per-runtime JSClassIDs for the tjs:v8 classes, the same way every other
 * native class gets them (tjs__class_register in vm.c). A process-wide static
 * id would collide with the ids a Worker runtime hands out to its own classes.
 * Register returns -1 with an exception pending on failure. */
int tjs__v8_class_register(JSContext *ctx, int v8_class, const JSClassDef *def);
JSClassID tjs__v8_class_id(JSContext *ctx, int v8_class);
JSClassID tjs__v8_class_id_rt(JSRuntime *rt, int v8_class);

#endif
