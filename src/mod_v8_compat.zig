const z = @import("tjs_structs.zig");
const c = z.c;

const v8_serialize = @import("v8_serialize.zig");
const Serializer = v8_serialize.Serializer(NodeDelegate);
const Deserializer = v8_serialize.Deserializer(NodeDelegate);

const Error = v8_serialize.Error;

const QuickJSAllocator = @import("tjs_qjs_allocator.zig").QJSAllocator;

const cTRUE = 1;

/// Matches Node's behavior of calling `_writeHostObject` / `_readHostObject` in JS userland when encountering typed arrays.
const NodeDelegate = struct {
    this_obj: c.JSValue,

    const Self = @This();

    pub fn writeHostObject(self: Self, ctx: ?*c.JSContext, obj: c.JSValue) !void {
        const js_func = c.JS_GetPropertyStr(ctx, self.this_obj, "_writeHostObject");
        if (c.JS_IsException(js_func)) return error.JSException;
        defer c.JS_FreeValue(ctx, js_func);

        if (!c.JS_IsFunction(ctx, js_func)) return error.NotImplemented;

        var argv = [1]c.JSValue{obj};
        const js_result = c.JS_Call(ctx, js_func, self.this_obj, 1, &argv);
        defer c.JS_FreeValue(ctx, js_result);

        if (c.JS_IsException(js_result)) return error.JSException;
    }

    pub fn readHostObject(self: Self, ctx: ?*c.JSContext) !c.JSValue {
        const js_func = c.JS_GetPropertyStr(ctx, self.this_obj, "_readHostObject");
        if (c.JS_IsException(js_func)) return error.JSException;
        defer c.JS_FreeValue(ctx, js_func);

        if (!c.JS_IsFunction(ctx, js_func)) return error.NotImplemented;

        var argv = [0]c.JSValue{};
        const js_result = c.JS_Call(ctx, js_func, self.this_obj, 0, &argv);
        if (c.JS_IsException(js_result)) return error.JSException;
        return js_result;
    }

    // Host objects behavior is opted in via `setTreatArrayBufferViewsAsHostObjects`
    pub fn hasCustomHostObject(_: Self) bool {
        return false;
    }
    pub fn isHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !bool {
        return false;
    }
    pub fn throwDataCloneError(self: Self, ctx: ?*c.JSContext, msg: []const u8) !void {
        const get_ctor = c.JS_GetPropertyStr(ctx, self.this_obj, "_getDataCloneError");
        if (c.JS_IsException(get_ctor)) return error.JSException;
        defer c.JS_FreeValue(ctx, get_ctor);
        if (c.JS_IsFunction(ctx, get_ctor)) {
            const ctor = if (c.JS_IsConstructor(ctx, get_ctor))
                c.JS_DupValue(ctx, get_ctor)
            else
                c.JS_Call(ctx, get_ctor, self.this_obj, 0, null);
            if (c.JS_IsException(ctor)) return error.JSException;
            defer c.JS_FreeValue(ctx, ctor);
            if (!c.JS_IsConstructor(ctx, ctor)) {
                _ = c.JS_ThrowTypeError(ctx, "_getDataCloneError did not return a constructor");
                return error.JSException;
            }
            const s = c.JS_NewStringLen(ctx, msg.ptr, @intCast(msg.len));
            if (c.JS_IsException(s)) return error.JSException;
            defer c.JS_FreeValue(ctx, s);
            var argv = [1]c.JSValue{s};
            const err = c.JS_CallConstructor(ctx, ctor, 1, &argv);
            if (c.JS_IsException(err)) return error.JSException;
            // Throw the constructed error
            _ = c.JS_Throw(ctx, err);
            return error.JSException;
        }

        // Final fallback
        _ = c.JS_ThrowTypeError(ctx, "Data clone error");
        return error.JSException;
    }
};

const arrayBufferViewToSlice = v8_serialize.arrayBufferViewToSlice;

var serializer_class_id: c.JSClassID = 0;
var deserializer_class_id: c.JSClassID = 0;

fn getSerializer(ctx: ?*c.JSContext, value: c.JSValueConst) ?*Serializer {
    const opaque_ptr = c.JS_GetOpaque2(ctx, value, serializer_class_id) orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

fn getDeserializer(ctx: ?*c.JSContext, value: c.JSValueConst) ?*Deserializer {
    const opaque_ptr = c.JS_GetOpaque2(ctx, value, deserializer_class_id) orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

fn mapNativeError(ctx: ?*c.JSContext, err: anyerror, not_implemented: [*:0]const u8) c.JSValue {
    return switch (err) {
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
        Error.JSException,
        Error.DataCloneError,
        Error.DataCloneErrorDetachedArrayBuffer,
        Error.DataCloneDeserializationError,
        Error.DataCloneDeserializationVersionError,
        => z.JS_EXCEPTION,
        Error.NotImplemented => c.JS_ThrowTypeError(ctx, not_implemented),
        else => c.JS_ThrowTypeError(ctx, "V8 serialization failed"),
    };
}

fn initSerializer(ctx: ?*c.JSContext, obj: c.JSValue) !*Serializer {
    const ac = QuickJSAllocator.allocator(ctx);
    const ser: *Serializer = try ac.create(Serializer);
    errdefer ac.destroy(ser);
    ser.* = try Serializer.init(ac, ctx, .{ .this_obj = obj });
    return ser;
}

fn initDeserializer(ctx: ?*c.JSContext, obj: c.JSValue, js_view: c.JSValue) !*Deserializer {
    const ac = QuickJSAllocator.allocator(ctx);
    const des: *Deserializer = try ac.create(Deserializer);
    errdefer ac.destroy(des);
    des.* = try Deserializer.init(ac, ctx, js_view, .{ .this_obj = obj });
    return des;
}

fn jsSerializerConstructor(ctx: ?*c.JSContext, new_target: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (!c.JS_IsConstructor(ctx, new_target)) {
        return c.JS_ThrowTypeError(ctx, "not a constructor");
    }
    const proto = c.JS_GetPropertyStr(ctx, new_target, "prototype");
    if (c.JS_IsException(proto)) return z.JS_EXCEPTION;
    defer c.JS_FreeValue(ctx, proto);

    const obj = c.JS_NewObjectProtoClass(ctx, proto, serializer_class_id);
    if (c.JS_IsException(obj)) return z.JS_EXCEPTION;

    const ser: *Serializer = initSerializer(ctx, obj) catch |err| switch (err) {
        error.OutOfMemory => {
            c.JS_FreeValue(ctx, obj);
            return c.JS_ThrowOutOfMemory(ctx);
        },
        error.JSException => {
            c.JS_FreeValue(ctx, obj);
            return z.JS_EXCEPTION;
        },
        else => {
            c.JS_FreeValue(ctx, obj);
            return c.JS_ThrowTypeError(ctx, "Could not create Serializer");
        },
    };

    if (c.JS_SetOpaque(obj, ser) < 0) {
        ser.deinit();
        ser.ac.destroy(ser);
        c.JS_FreeValue(ctx, obj);
        return z.JS_EXCEPTION;
    }

    _ = argc;
    _ = argv;
    return obj;
}

fn jsSerializerFinalizer(_: ?*c.JSRuntime, this_val: c.JSValue) callconv(.c) void {
    const opaque_ptr = c.JS_GetOpaque(this_val, serializer_class_id) orelse return;
    const ser: *Serializer = @ptrCast(@alignCast(opaque_ptr));
    ser.deinit();
    ser.ac.destroy(ser);
}

fn jsSerializerWriteHeader(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    ser.writeHeader() catch |err| return mapNativeError(ctx, err, "Could not write header");
    _ = argc;
    _ = argv;
    return z.JS_UNDEFINED;
}

fn jsSerializerSetTreatArrayBufferViewsAsHostObjects(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    const mode = c.JS_ToBool(ctx, argv[0]);
    if (mode < 0) return z.JS_EXCEPTION;
    ser.setTreatArrayBufferViewsAsHostObjects(mode == cTRUE);
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteDouble(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var dbl: f64 = undefined;
    if (c.JS_ToFloat64(ctx, &dbl, argv[0]) != 0) return z.JS_EXCEPTION;
    ser.writeDouble(dbl) catch |err| return mapNativeError(ctx, err, "Could not write double");
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteValue(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    ser.writeObject(argv[0]) catch |err| return mapNativeError(ctx, err, "Method _writeHostObject not implemented");
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteRawBytes(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    const slice = arrayBufferViewToSlice(ctx, argv[0]) catch |err| switch (err) {
        error.JSException => return z.JS_EXCEPTION,
        error.OutOfMemory => return c.JS_ThrowOutOfMemory(ctx),
        else => return c.JS_ThrowTypeError(ctx, "Could not read bytes"),
    };

    ser.writeRawBytes(slice) catch |err| return mapNativeError(ctx, err, "Could not write raw bytes");
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteUint32(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var num: u32 = undefined;
    if (c.JS_ToUint32(ctx, &num, argv[0]) != 0) return c.JS_ThrowTypeError(ctx, "Could not convert argument to integer");
    ser.writeUint32(num) catch |err| return mapNativeError(ctx, err, "Could not write uint32");
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteUint64(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    var lo: u32 = undefined;
    var hi: u32 = undefined;
    if (c.JS_ToUint32(ctx, &lo, argv[0]) != 0 or c.JS_ToUint32(ctx, &hi, argv[1]) != 0) {
        return c.JS_ThrowTypeError(ctx, "Could not convert argument to integer");
    }
    const hi_64: u64 = @intCast(hi);
    const num: u64 = (hi_64 << 32) | lo;
    ser.writeUint64(num) catch |err| return mapNativeError(ctx, err, "Could not write uint64");
    return z.JS_UNDEFINED;
}

fn jsSerializerReleaseBuffer(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const ser = getSerializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    const bytes = ser.release() catch |err| return mapNativeError(ctx, err, "Could not release buffer");
    defer ser.ac.free(bytes);
    _ = argc;
    _ = argv;
    return c.JS_NewUint8ArrayCopy(ctx, bytes.ptr, bytes.len);
}

const serializer_class = c.JSClassDef{
    .class_name = "Serializer",
    .finalizer = jsSerializerFinalizer,
};
const serializer_proto_funcs = [_]c.JSCFunctionListEntry{
    z.JS_CFUNC_DEF("writeHeader", 0, jsSerializerWriteHeader),
    z.JS_CFUNC_DEF("writeValue", 1, jsSerializerWriteValue),
    z.JS_CFUNC_DEF("releaseBuffer", 0, jsSerializerReleaseBuffer),
    z.JS_CFUNC_DEF("writeUint32", 1, jsSerializerWriteUint32),
    z.JS_CFUNC_DEF("writeUint64", 2, jsSerializerWriteUint64),
    z.JS_CFUNC_DEF("writeDouble", 1, jsSerializerWriteDouble),
    z.JS_CFUNC_DEF("writeRawBytes", 1, jsSerializerWriteRawBytes),
    z.JS_CFUNC_DEF("_setTreatArrayBufferViewsAsHostObjects", 1, jsSerializerSetTreatArrayBufferViewsAsHostObjects),
};

fn jsDeserializerConstructor(ctx: ?*c.JSContext, new_target: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (!c.JS_IsConstructor(ctx, new_target)) {
        return c.JS_ThrowTypeError(ctx, "not a constructor");
    }
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    const proto = c.JS_GetPropertyStr(ctx, new_target, "prototype");
    if (c.JS_IsException(proto)) return z.JS_EXCEPTION;
    defer c.JS_FreeValue(ctx, proto);

    const obj = c.JS_NewObjectProtoClass(ctx, proto, deserializer_class_id);
    if (c.JS_IsException(obj)) return z.JS_EXCEPTION;

    const des: *Deserializer = initDeserializer(ctx, obj, argv[0]) catch |err| switch (err) {
        Error.JSException, Error.DataCloneError, Error.DataCloneErrorDetachedArrayBuffer, Error.DataCloneDeserializationError, Error.DataCloneDeserializationVersionError => {
            c.JS_FreeValue(ctx, obj);
            return z.JS_EXCEPTION;
        },
        Error.NotImplemented => {
            c.JS_FreeValue(ctx, obj);
            return c.JS_ThrowTypeError(ctx, "Method _readHostObject not implemented");
        },
        error.OutOfMemory => {
            c.JS_FreeValue(ctx, obj);
            return c.JS_ThrowOutOfMemory(ctx);
        },
    };

    if (c.JS_SetOpaque(obj, des) < 0) {
        des.deinit();
        des.ac.destroy(des);
        c.JS_FreeValue(ctx, obj);
        return z.JS_EXCEPTION;
    }

    return obj;
}

fn jsDeserializerFinalizer(_: ?*c.JSRuntime, this_val: c.JSValue) callconv(.c) void {
    const opaque_ptr = c.JS_GetOpaque(this_val, deserializer_class_id) orelse return;
    const des: *Deserializer = @ptrCast(@alignCast(opaque_ptr));
    des.deinit();
    des.ac.destroy(des);
}

fn jsDeserializerReadHeader(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    _ = des.readHeader() catch |err| return mapNativeError(ctx, err, "Could not read header");
    return z.JS_TRUE;
}

fn jsDeserializerGetWireFormatVersion(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (des.version != null) {
        return c.JS_NewUint32(ctx, des.version.?);
    } else {
        return z.JS_UNDEFINED;
    }
}

fn jsDeserializerReadDouble(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    const dbl = des.readDouble() catch |err| return mapNativeError(ctx, err, "Could not read double");
    return c.JS_NewFloat64(ctx, dbl);
}

fn jsDeserializerReadUint32(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    const val = des.readUint32() catch |err| return mapNativeError(ctx, err, "Could not read uint32");
    return c.JS_NewUint32(ctx, val);
}

fn jsDeserializerReadUint64(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    const val = des.readUint64() catch |err| return mapNativeError(ctx, err, "Could not read uint64");
    const hi: u32 = @intCast(val >> 32);
    const lo: u32 = @intCast(val & 0xFFFFFFFF);
    const tuple = c.JS_NewArray(ctx);
    if (c.JS_IsException(tuple)) return z.JS_EXCEPTION;
    if (c.JS_DefinePropertyValueUint32(ctx, tuple, 0, c.JS_NewUint32(ctx, hi), c.JS_PROP_C_W_E) < 0 or
        c.JS_DefinePropertyValueUint32(ctx, tuple, 1, c.JS_NewUint32(ctx, lo), c.JS_PROP_C_W_E) < 0)
    {
        c.JS_FreeValue(ctx, tuple);
        return z.JS_EXCEPTION;
    }
    return tuple;
}

fn jsDeserializerReadValue(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    const val = des.readObject() catch |err| return mapNativeError(ctx, err, "Method _readHostObject not implemented");
    return val;
}

fn jsDeserializerReadRawBytes(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var length: u32 = undefined;
    if (c.JS_ToUint32(ctx, &length, argv[0]) != 0) return z.JS_EXCEPTION;
    const bytes = des.readRawBytes(@intCast(length)) catch |err| return mapNativeError(ctx, err, "Could not read raw bytes");
    return c.JS_NewUint8ArrayCopy(ctx, bytes.ptr, bytes.len);
}

/// Same as `jsDeserializerReadRawBytes`, but just advanced the internal position and returns the starting offset.
fn jsDeserializerReadRawBytes_(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var length: u32 = undefined;
    if (c.JS_ToUint32(ctx, &length, argv[0]) != 0) return z.JS_EXCEPTION;
    const offset = des.position;
    _ = des.readRawBytes(@intCast(length)) catch |err| return mapNativeError(ctx, err, "Could not read raw bytes");
    return c.JS_NewUint32(ctx, @intCast(offset));
}

fn jsDeserializerBufferGetter(ctx: ?*c.JSContext, this_val: c.JSValueConst) callconv(.c) c.JSValue {
    const des = getDeserializer(ctx, this_val) orelse return z.JS_EXCEPTION;
    // This view is a private copy, so detaching or mutating the caller's input
    // cannot invalidate the native bytes retained by the deserializer.
    return c.JS_DupValue(ctx, des.js_view);
}

const deserializer_class = c.JSClassDef{
    .class_name = "Deserializer",
    .finalizer = jsDeserializerFinalizer,
};

const deserializer_proto_funcs = [_]c.JSCFunctionListEntry{
    z.JS_CFUNC_DEF("readHeader", 0, jsDeserializerReadHeader),
    z.JS_CFUNC_DEF("readValue", 0, jsDeserializerReadValue),
    z.JS_CFUNC_DEF("getWireFormatVersion", 0, jsDeserializerGetWireFormatVersion),
    z.JS_CFUNC_DEF("readUint32", 0, jsDeserializerReadUint32),
    z.JS_CFUNC_DEF("readUint64", 0, jsDeserializerReadUint64),
    z.JS_CFUNC_DEF("readDouble", 0, jsDeserializerReadDouble),
    z.JS_CFUNC_DEF("readRawBytes", 1, jsDeserializerReadRawBytes),
    z.JS_CFUNC_DEF("_readRawBytes", 1, jsDeserializerReadRawBytes_),
    z.JS_CGETSET_DEF("buffer", jsDeserializerBufferGetter, null),
};

pub fn initModV8Compat(ctx: ?*c.JSContext, ns: c.JSValue) c_int {
    const rt = c.JS_GetRuntime(ctx);

    _ = c.JS_NewClassID(rt, &serializer_class_id);
    if (c.JS_NewClass(rt, serializer_class_id, &serializer_class) < 0) return -1;

    const ser_proto = c.JS_NewObject(ctx);
    if (c.JS_IsException(ser_proto)) return -1;
    if (c.JS_SetPropertyFunctionList(ctx, ser_proto, &serializer_proto_funcs, @intCast(serializer_proto_funcs.len)) < 0) {
        c.JS_FreeValue(ctx, ser_proto);
        return -1;
    }

    const ser_ctor = c.JS_NewCFunction2(ctx, jsSerializerConstructor, "Serializer", 0, c.JS_CFUNC_constructor_or_func, 0);
    if (c.JS_IsException(ser_ctor)) {
        c.JS_FreeValue(ctx, ser_proto);
        return -1;
    }
    if (c.JS_SetConstructor(ctx, ser_ctor, ser_proto) < 0) {
        c.JS_FreeValue(ctx, ser_ctor);
        c.JS_FreeValue(ctx, ser_proto);
        return -1;
    }
    c.JS_SetClassProto(ctx, serializer_class_id, ser_proto);
    if (c.JS_DefinePropertyValueStr(ctx, ns, "Serializer", ser_ctor, c.JS_PROP_C_W_E) < 0) return -1;

    _ = c.JS_NewClassID(rt, &deserializer_class_id);
    if (c.JS_NewClass(rt, deserializer_class_id, &deserializer_class) < 0) return -1;

    const des_proto = c.JS_NewObject(ctx);
    if (c.JS_IsException(des_proto)) return -1;
    if (c.JS_SetPropertyFunctionList(ctx, des_proto, &deserializer_proto_funcs, @intCast(deserializer_proto_funcs.len)) < 0) {
        c.JS_FreeValue(ctx, des_proto);
        return -1;
    }

    const des_ctor = c.JS_NewCFunction2(ctx, jsDeserializerConstructor, "Deserializer", 1, c.JS_CFUNC_constructor_or_func, 0);
    if (c.JS_IsException(des_ctor)) {
        c.JS_FreeValue(ctx, des_proto);
        return -1;
    }
    if (c.JS_SetConstructor(ctx, des_ctor, des_proto) < 0) {
        c.JS_FreeValue(ctx, des_ctor);
        c.JS_FreeValue(ctx, des_proto);
        return -1;
    }
    c.JS_SetClassProto(ctx, deserializer_class_id, des_proto);
    if (c.JS_DefinePropertyValueStr(ctx, ns, "Deserializer", des_ctor, c.JS_PROP_C_W_E) < 0) return -1;

    return 0;
}
