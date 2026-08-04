const std = @import("std");

pub const z = @import("tjs_structs.zig");
pub const c = z.c;

const kLatestVersion = 15;
const maxRecursionDepth = 1024;

const cTRUE = 1;
const cFALSE = 0;

pub const Error = std.mem.Allocator.Error || error{
    DataCloneError,
    DataCloneErrorDetachedArrayBuffer,
    DataCloneDeserializationError,
    DataCloneDeserializationVersionError,
    NotImplemented,
    JSException,
};

fn bytesNeededForVarint(comptime T: type, value: T) usize {
    comptime {
        const type_info = @typeInfo(T);
        if (type_info != .int or type_info.int.signedness != .unsigned) {
            @compileError("Only unsigned integer types can be written as varints.");
        }
    }

    var result: usize = 0;
    var temp_value = value;
    while (temp_value != 0) : (temp_value >>= 7) {
        result += 1;
    }
    return result;
}

inline fn exceptionCheck(val: c.JSValue) !void {
    if (c.JS_IsException(val)) {
        @branchHint(.unlikely);
        return Error.JSException;
    }
}

fn freePropertyDescriptor(ctx: ?*c.JSContext, descriptor: c.JSPropertyDescriptor) void {
    c.JS_FreeValue(ctx, descriptor.value);
    c.JS_FreeValue(ctx, descriptor.getter);
    c.JS_FreeValue(ctx, descriptor.setter);
}

const OwnedInput = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    references: u8 = 1,

    fn create(allocator: std.mem.Allocator, source: []const u8) !*OwnedInput {
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        const owner = try allocator.create(OwnedInput);
        owner.* = .{ .allocator = allocator, .bytes = bytes };
        return owner;
    }

    fn retain(self: *OwnedInput) void {
        std.debug.assert(self.references < std.math.maxInt(u8));
        self.references += 1;
    }

    fn release(self: *OwnedInput) void {
        std.debug.assert(self.references != 0);
        self.references -= 1;
        if (self.references == 0) {
            const allocator = self.allocator;
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    }
};

fn releaseOwnedInput(
    _: ?*c.JSRuntime,
    opaque_ptr: ?*anyopaque,
    _: ?*anyopaque,
    size: usize,
) callconv(.c) ?*anyopaque {
    // External deserializer buffers are fixed-size. QuickJS must leave the
    // original pointer valid when a resize is requested and rejected.
    if (size != 0) return null;
    const owner: *OwnedInput = @ptrCast(@alignCast(opaque_ptr orelse return null));
    owner.release();
    return null;
}

inline fn getTypedArrayBuffer(ctx: ?*c.JSContext, obj: c.JSValue) !struct { c.JSValue, usize, usize, usize } {
    var offset: usize = 0;
    var length: usize = 0;
    var bytes_per_element: usize = 0;
    const buffer = c.JS_GetTypedArrayBuffer(ctx, obj, &offset, &length, &bytes_per_element);
    try exceptionCheck(buffer);
    return .{ buffer, offset, length, bytes_per_element };
}

pub fn arrayBufferViewToSlice(ctx: ?*c.JSContext, obj: c.JSValue) ![]u8 {
    if (c.JS_IsDataView(obj)) {
        const js_ab = c.JS_GetPropertyStr(ctx, obj, "buffer");
        try exceptionCheck(js_ab);
        defer c.JS_FreeValue(ctx, js_ab);
        const offset_value = c.JS_GetPropertyStr(ctx, obj, "byteOffset");
        try exceptionCheck(offset_value);
        defer c.JS_FreeValue(ctx, offset_value);
        const length_value = c.JS_GetPropertyStr(ctx, obj, "byteLength");
        try exceptionCheck(length_value);
        defer c.JS_FreeValue(ctx, length_value);
        var offset_u64: u64 = undefined;
        var length_u64: u64 = undefined;
        if (c.JS_ToIndex(ctx, &offset_u64, offset_value) != 0 or c.JS_ToIndex(ctx, &length_u64, length_value) != 0) {
            return Error.JSException;
        }
        var total: usize = 0;
        const bytes = c.JS_GetArrayBuffer(ctx, &total, js_ab) orelse return Error.JSException;
        if (offset_u64 > total or length_u64 > total - @as(usize, @intCast(offset_u64))) return Error.JSException;
        const offset: usize = @intCast(offset_u64);
        const length: usize = @intCast(length_u64);
        return bytes[offset .. offset + length];
    }

    const js_ab, const offset, const length, const bytes_per_element = try getTypedArrayBuffer(ctx, obj);
    defer c.JS_FreeValue(ctx, js_ab);

    var len: usize = 0;
    const bytes = c.JS_GetArrayBuffer(ctx, &len, js_ab);
    if (bytes == null) {
        @branchHint(.unlikely);
        return Error.JSException;
    }

    _ = bytes_per_element;
    // QuickJS-NG reports byte length here. Older QuickJS returned an element
    // count, which is why the snapshot multiplied this value and over-read all
    // non-byte views after the dependency update.
    if (offset > len or length > len - offset) return Error.JSException;
    return bytes[offset .. offset + length];
}

pub const SerializationTag = enum(u8) {
    version = 255,
    padding = 0,
    verify_object_count = '?',
    the_hole = '-',
    undefined = '_',
    null = '0',
    true = 'T',
    false = 'F',
    int32 = 'I',
    uint32 = 'U',
    double = 'N',
    big_int = 'Z',
    utf8_string = 'S',
    one_byte_string = '"',
    two_byte_string = 'c',
    object_reference = '^',
    begin_js_object = 'o',
    end_js_object = '{',
    begin_sparse_js_array = 'a',
    end_sparse_js_array = '@',
    begin_dense_js_array = 'A',
    end_dense_js_array = '$',
    date = 'D',
    true_object = 'y',
    false_object = 'x',
    number_object = 'n',
    big_int_object = 'z',
    string_object = 's',
    reg_exp = 'R',
    begin_js_map = ';',
    end_js_map = ':',
    begin_js_set = '\'',
    end_js_set = ',',
    array_buffer = 'B',
    resizable_array_buffer = '~',
    array_buffer_transfer = 't',
    array_buffer_view = 'V',
    shared_array_buffer = 'u',
    shared_object = 'p',
    wasm_module_transfer = 'w',
    host_object = '\\',
    wasm_memory_transfer = 'm',
    @"error" = 'r',
    _,
};

pub const ArrayBufferViewTag = enum(u8) {
    int8_array = 'b',
    uint8_array = 'B',
    uint8_clamped_array = 'C',
    int16_array = 'w',
    uint16_array = 'W',
    int32_array = 'd',
    uint32_array = 'D',
    float16_array = 'h',
    float32_array = 'f',
    float64_array = 'F',
    big_int64_array = 'q',
    big_uint64_array = 'Q',
    data_view = '?',
    _,
};

pub const ErrorTag = enum(u8) {
    eval_error_prototype = 'E',
    range_error_prototype = 'R',
    reference_error_prototype = 'F',
    syntax_error_prototype = 'S',
    type_error_prototype = 'T',
    uri_error_prototype = 'U',
    message = 'm',
    cause = 'c',
    stack = 's',
    end = '.',
    _,
};

pub const DefaultDelegate = struct {
    const Self = @This();
    pub fn hasCustomHostObject(_: Self) bool {
        return false;
    }
    pub fn isHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !bool {
        return false;
    }
    pub fn writeHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !void {
        return Error.NotImplemented;
    }
    pub fn readHostObject(_: Self, _: ?*c.JSContext) !c.JSValue {
        return Error.NotImplemented;
    }
    pub fn throwDataCloneError(_: Self, _: ?*c.JSContext, _: []const u8) !void {
        return Error.NotImplemented;
    }
};

const JSObjectHashContext = struct {
    const Self = @This();
    pub fn hash(_: Self, s: *c.JSObject) u64 {
        return @intFromPtr(s) * 3163; // Taken from QuickJS's hash function
    }
    pub fn eql(_: Self, a: *c.JSObject, b: *c.JSObject) bool {
        return a == b;
    }
};

const SetOrMap = enum(u1) { Set, Map };
const ObjectOrArray = enum(u1) { Object, Array };

const SerializedObject = struct {
    id: u32,
    retained: c.JSValue,
};

const CachedObjectProperty = struct {
    atom: c.JSAtom,
    encoded_key: ?[]u8 = null,
};

const ObjectShapeCache = struct {
    properties: std.ArrayListUnmanaged(CachedObjectProperty) = .empty,
    valid: bool = false,

    fn prepare(self: *ObjectShapeCache, allocator: std.mem.Allocator, ctx: ?*c.JSContext, props: []const c.JSPropertyEnum) !void {
        try self.properties.ensureTotalCapacity(allocator, props.len);
        for (props) |prop| {
            if (!prop.is_enumerable) return;
            self.properties.appendAssumeCapacity(.{ .atom = c.JS_DupAtom(ctx, prop.atom) });
        }
        self.valid = true;
    }

    fn deinit(self: *ObjectShapeCache, allocator: std.mem.Allocator, rt: ?*c.JSRuntime) void {
        for (self.properties.items) |property| {
            c.JS_FreeAtomRT(rt, property.atom);
            if (property.encoded_key) |bytes| allocator.free(bytes);
        }
        self.properties.deinit(allocator);
        self.* = .{};
    }

    fn matches(self: *const ObjectShapeCache, props: []const c.JSPropertyEnum) bool {
        if (!self.valid or self.properties.items.len != props.len) return false;
        for (self.properties.items, props) |cached, prop| {
            if (!prop.is_enumerable or cached.atom != prop.atom) return false;
        }
        return true;
    }

    fn isComplete(self: *const ObjectShapeCache, properties_written: u32) bool {
        if (!self.valid or properties_written != self.properties.items.len) return false;
        for (self.properties.items) |property| {
            if (property.encoded_key == null) return false;
        }
        return true;
    }
};

/// A V8 compatible serializer for QuickJS values.
pub fn Serializer(comptime Delegate: type) type {
    // XXX: comptime validate delegate type
    return struct {
        ac: std.mem.Allocator,
        ctx: ?*c.JSContext,
        rt: ?*c.JSRuntime,
        buffer: std.ArrayListUnmanaged(u8),
        id_map: std.HashMapUnmanaged(*c.JSObject, SerializedObject, JSObjectHashContext, std.hash_map.default_max_load_percentage),
        object_shape_cache: ObjectShapeCache = .{},
        next_id: u32 = 0,
        recursion_depth: u32 = 0,
        plain_object_class_id: c.JSClassID,

        treat_array_buffer_views_as_host_objects: bool = false,
        use_default_host_object_writer: bool = false,
        has_custom_objects: bool = false,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext, delegate: ?Delegate) !Self {
            const sample_object = c.JS_NewObject(ctx);
            try exceptionCheck(sample_object);
            defer c.JS_FreeValue(ctx, sample_object);
            return Self{
                .ac = allocator,
                .ctx = ctx,
                .rt = c.JS_GetRuntime(ctx),
                .buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 2),
                .id_map = .empty,
                .plain_object_class_id = c.JS_GetClassID(sample_object),
                .delegate = delegate,
                .has_custom_objects = if (delegate) |d| d.hasCustomHostObject() else false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.ac);
            self.object_shape_cache.deinit(self.ac, self.rt);
            var values = self.id_map.valueIterator();
            while (values.next()) |value| c.JS_FreeValueRT(self.rt, value.retained);
            self.id_map.deinit(self.ac);
        }

        pub fn writeHeader(self: *Self) !void {
            try self.writeTag(.version);
            try self.writeVarint(u32, kLatestVersion);
        }

        pub fn setTreatArrayBufferViewsAsHostObjects(self: *Self, mode: bool) void {
            self.treat_array_buffer_views_as_host_objects = mode;
        }

        pub fn setUseDefaultHostObjectWriter(self: *Self, mode: bool) void {
            self.use_default_host_object_writer = mode;
        }

        fn writeTag(self: *Self, tag: SerializationTag) !void {
            try self.buffer.append(self.ac, @intFromEnum(tag));
        }

        fn writeVarint(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be written as varints.");
                }
            }
            var temp_value = value;
            while (temp_value >= 0x80) : (temp_value >>= 7) {
                try self.buffer.append(self.ac, @intCast((temp_value & 0x7F) | 0x80));
            }
            try self.buffer.append(self.ac, @intCast(temp_value));
        }

        fn writeZigZag(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .signed) {
                    @compileError("Only signed integer types can be written as zigzag.");
                }
            }
            const UnsignedT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const bit_value: UnsignedT = @bitCast(value);
            const sign_bit: UnsignedT = @bitCast(value >> (@bitSizeOf(T) - 1));
            const zigzag_value: UnsignedT = bit_value << 1 ^ sign_bit;
            try self.writeVarint(UnsignedT, zigzag_value);
        }

        fn writeRawFloat64(self: *Self, value: f64) !void {
            const value_bytes: [@sizeOf(f64)]u8 = @bitCast(value);
            try self.writeRawBytes(&value_bytes);
        }

        pub fn writeDouble(self: *Self, value: f64) !void {
            try self.writeRawFloat64(value);
        }

        fn writeOneByteString(self: *Self, value: []const u8) !void {
            try self.writeVarint(usize, value.len);
            try self.writeRawBytes(value);
        }

        fn writeTwoByteString(self: *Self, value: []const u16) !void {
            try self.writeVarint(usize, value.len * @sizeOf(u16));
            const out = try self.reserveRawBytes(value.len * @sizeOf(u16));
            for (value, 0..) |code_unit, i| {
                out[i * 2] = @intCast(code_unit & 0xff);
                out[i * 2 + 1] = @intCast(code_unit >> 8);
            }
        }

        fn writeBigIntWord(self: *Self, negative: bool, magnitude: u64) !void {
            if (magnitude == 0) return self.writeVarint(u32, 0);
            try self.writeVarint(u32, (8 << 1) | @as(u32, @intFromBool(negative)));
            const out = try self.reserveRawBytes(8);
            var value = magnitude;
            for (out) |*byte| {
                byte.* = @intCast(value & 0xff);
                value >>= 8;
            }
        }

        fn writeBigIntContents(self: *Self, obj: c.JSValue) !void {
            if (c.JS_VALUE_GET_NORM_TAG(obj) == c.JS_TAG_SHORT_BIG_INT) {
                const value: i32 = c.JS_VALUE_GET_SHORT_BIG_INT(obj);
                const magnitude: u64 = if (value < 0)
                    @intCast(-@as(i64, value))
                else
                    @intCast(value);
                return self.writeBigIntWord(value < 0, magnitude);
            }

            // JS_ToBigInt64 is modulo 2^64. Comparing with a public-API
            // reconstruction distinguishes the hot exact-int64 case without
            // dereferencing QuickJS's private JSBigInt representation.
            var signed_value: i64 = undefined;
            if (c.JS_ToBigInt64(self.ctx, &signed_value, obj) == 0) {
                const reconstructed = c.JS_NewBigInt64(self.ctx, signed_value);
                try exceptionCheck(reconstructed);
                defer c.JS_FreeValue(self.ctx, reconstructed);
                if (c.JS_IsStrictEqual(self.ctx, obj, reconstructed)) {
                    const magnitude: u64 = if (signed_value < 0)
                        @intCast(-@as(i128, signed_value))
                    else
                        @intCast(signed_value);
                    return self.writeBigIntWord(signed_value < 0, magnitude);
                }
            }

            var unsigned_value: u64 = undefined;
            if (c.JS_ToBigUint64(self.ctx, &unsigned_value, obj) == 0) {
                const reconstructed = c.JS_NewBigUint64(self.ctx, unsigned_value);
                try exceptionCheck(reconstructed);
                defer c.JS_FreeValue(self.ctx, reconstructed);
                if (c.JS_IsStrictEqual(self.ctx, obj, reconstructed)) {
                    return self.writeBigIntWord(false, unsigned_value);
                }
            }

            const decimal_ptr = c.JS_ToCString(self.ctx, obj) orelse return Error.JSException;
            defer c.JS_FreeCString(self.ctx, decimal_ptr);
            var decimal = std.mem.span(decimal_ptr);
            const negative = decimal.len != 0 and decimal[0] == '-';
            if (negative) decimal = decimal[1..];
            if (decimal.len == 0) return Error.DataCloneError;

            // Convert decimal text to little-endian base-256. This is the safe
            // slow path for values wider than u64; common int64 BigInts never
            // enter it.
            var magnitude = try std.ArrayListUnmanaged(u8).initCapacity(self.ac, decimal.len / 2 + 1);
            defer magnitude.deinit(self.ac);
            magnitude.appendAssumeCapacity(0);
            for (decimal) |char| {
                if (char < '0' or char > '9') return Error.DataCloneError;
                var carry: u16 = char - '0';
                for (magnitude.items) |*byte| {
                    const product: u16 = @as(u16, byte.*) * 10 + carry;
                    byte.* = @intCast(product & 0xff);
                    carry = product >> 8;
                }
                while (carry != 0) {
                    try magnitude.append(self.ac, @intCast(carry & 0xff));
                    carry >>= 8;
                }
            }
            while (magnitude.items.len > 1 and magnitude.items[magnitude.items.len - 1] == 0) {
                magnitude.items.len -= 1;
            }
            if (magnitude.items.len == 1 and magnitude.items[0] == 0) {
                return self.writeVarint(u32, 0);
            }

            const byte_length = std.mem.alignForward(usize, magnitude.items.len, 8);
            if (byte_length > std.math.maxInt(u31)) return Error.DataCloneError;
            try self.writeVarint(u32, (@as(u32, @intCast(byte_length)) << 1) | @as(u32, @intFromBool(negative)));
            const out = try self.reserveRawBytes(byte_length);
            @memset(out, 0);
            @memcpy(out[0..magnitude.items.len], magnitude.items);
        }

        fn reserveRawBytes(self: *Self, size: usize) ![]u8 {
            try self.buffer.ensureUnusedCapacity(self.ac, size);
            const slice = self.buffer.unusedCapacitySlice();
            self.buffer.items.len += size;
            return slice[0..size];
        }

        pub fn writeRawBytes(self: *Self, bytes: []const u8) !void {
            try self.buffer.appendSlice(self.ac, bytes);
        }

        fn writeByte(self: *Self, value: u8) !void {
            try self.buffer.append(self.ac, value);
        }

        pub fn writeUint32(self: *Self, value: u32) !void {
            try self.writeVarint(u32, value);
        }

        pub fn writeUint64(self: *Self, value: u64) !void {
            try self.writeVarint(u64, value);
        }

        pub fn release(self: *Self) ![]u8 {
            return self.buffer.toOwnedSlice(self.ac);
        }

        pub fn writeObject(self: *Self, object: c.JSValue) Error!void {
            const tag = c.JS_VALUE_GET_NORM_TAG(object);
            switch (tag) {
                c.JS_TAG_INT => {
                    try self.writeSmi(object);
                },
                c.JS_TAG_UNDEFINED, c.JS_TAG_NULL, c.JS_TAG_BOOL => {
                    try self.writeOddball(object);
                },
                c.JS_TAG_FLOAT64 => {
                    try self.writeHeapNumber(object);
                },
                c.JS_TAG_BIG_INT, c.JS_TAG_SHORT_BIG_INT => {
                    try self.writeBigInt(object);
                },
                c.JS_TAG_STRING, c.JS_TAG_STRING_ROPE => try self.writeString(object),
                c.JS_TAG_OBJECT => {
                    const p: *c.JSObject = @ptrCast(c.JS_VALUE_GET_PTR(object));
                    if (!self.treat_array_buffer_views_as_host_objects) {
                        const array_type = c.JS_GetTypedArrayType(object);
                        const is_view = array_type >= 0 or c.JS_IsDataView(object);
                        if (is_view and !self.id_map.contains(p)) {
                            const info = try self.getArrayBufferViewInfo(object, array_type);
                            defer c.JS_FreeValue(self.ctx, info.buffer);
                            try self.writeJSReceiver(info.buffer, @ptrCast(c.JS_VALUE_GET_PTR(info.buffer)));
                        }
                    }
                    try self.writeJSReceiver(object, p);
                },
                else => {
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeOddball(self: *Self, oddball: c.JSValue) !void {
            const tag = c.JS_VALUE_GET_NORM_TAG(oddball);
            const v8_tag: SerializationTag = switch (tag) {
                c.JS_TAG_UNDEFINED => .undefined,
                c.JS_TAG_NULL => .null,
                c.JS_TAG_BOOL => if (c.JS_VALUE_GET_INT(oddball) == 0) .false else .true,
                else => unreachable,
            };
            try self.writeTag(v8_tag);
        }

        fn writeSmi(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.int32);
            try self.writeZigZag(i32, c.JS_VALUE_GET_INT(value));
        }

        fn writeHeapNumber(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.double);
            try self.writeDouble(c.JS_VALUE_GET_FLOAT64(value));
        }

        fn writeBigInt(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.big_int);
            try self.writeBigIntContents(value);
        }

        fn writeString(self: *Self, value: c.JSValue) !void {
            var length: usize = 0;
            const chars = c.JS_ToCStringLenUTF16(self.ctx, &length, value) orelse return Error.JSException;
            defer c.JS_FreeCStringUTF16(self.ctx, chars);
            const utf16 = chars[0..length];

            // Property values in row payloads are overwhelmingly Latin-1.
            // Tentatively encode that representation so detection and copying
            // share one pass; roll back for the position-sensitive UTF-16 form.
            const saved_len = self.buffer.items.len;
            try self.writeTag(.one_byte_string);
            try self.writeVarint(usize, length);
            const one_byte_output = try self.reserveRawBytes(length);
            var one_byte = true;
            for (utf16, one_byte_output) |code_unit, *byte| {
                if (code_unit > 0xff) {
                    one_byte = false;
                    break;
                }
                byte.* = @intCast(code_unit);
            }
            if (one_byte) return;
            self.buffer.items.len = saved_len;

            const byte_length = length * @sizeOf(u16);
            if (byte_length > std.math.maxInt(u32)) return Error.DataCloneError;
            if (((self.buffer.items.len + 1 + bytesNeededForVarint(u32, @intCast(byte_length))) & 1) != 0) {
                try self.writeTag(.padding);
            }
            try self.writeTag(.two_byte_string);
            try self.writeTwoByteString(utf16);
        }

        fn writeJSReceiver(self: *Self, obj: c.JSValue, p: *c.JSObject) !void {
            // If the object has already been serialized, just write its ID.
            const find_result = try self.id_map.getOrPut(self.ac, p);
            if (find_result.found_existing) {
                try self.writeTag(.object_reference);
                try self.writeVarint(u32, find_result.value_ptr.id);
                return;
            }

            // Otherwise, allocate an ID for it.
            const id = self.next_id;
            self.next_id += 1;
            find_result.value_ptr.* = .{
                .id = id,
                .retained = c.JS_DupValue(self.ctx, obj),
            };

            if (self.recursion_depth >= maxRecursionDepth) {
                _ = c.JS_ThrowRangeError(self.ctx, "Maximum serialization depth exceeded");
                return Error.JSException;
            }
            self.recursion_depth += 1;
            defer self.recursion_depth -= 1;

            if (c.JS_IsFunction(self.ctx, obj) or c.JS_IsProxy(obj)) {
                if (try self.isHostObject(obj)) return self.writeHostObject(obj);
                try self.throwDataCloneError();
            }

            if (c.JS_GetClassID(obj) == self.plain_object_class_id) {
                if (try self.isHostObject(obj)) return self.writeHostObject(obj);
                return self.writeJSObject(obj);
            }

            const typed_array_type = c.JS_GetTypedArrayType(obj);
            if (typed_array_type >= 0 or c.JS_IsDataView(obj)) return self.writeJSArrayBufferView(obj, typed_array_type);
            if (c.JS_IsArray(obj)) return self.writeJSArray(obj);
            if (c.JS_IsDate(obj)) return self.writeJSDate(obj);
            if (c.JS_IsRegExp(obj)) return self.writeJSRegExp(obj);
            if (c.JS_IsMap(obj)) return self.writeJSMap(.Map, obj);
            if (c.JS_IsSet(obj)) return self.writeJSMap(.Set, obj);
            if (c.JS_IsArrayBuffer(obj)) return self.writeJSArrayBuffer(obj);
            if (c.JS_IsError(obj)) return self.writeJSError(obj);

            if (try self.isPrimitiveWrapper(obj)) return self.writeJSPrimitiveWrapper(obj);
            if (try self.isHostObject(obj)) return self.writeHostObject(obj);
            try self.throwDataCloneError();
        }

        fn isPrimitiveWrapper(self: *Self, obj: c.JSValue) !bool {
            const prototype = c.JS_GetPrototype(self.ctx, obj);
            try exceptionCheck(prototype);
            defer c.JS_FreeValue(self.ctx, prototype);
            const global = c.JS_GetGlobalObject(self.ctx);
            try exceptionCheck(global);
            defer c.JS_FreeValue(self.ctx, global);
            const names = [_][*:0]const u8{ "Number", "String", "Boolean", "BigInt" };
            for (names) |name| {
                const constructor = c.JS_GetPropertyStr(self.ctx, global, name);
                try exceptionCheck(constructor);
                defer c.JS_FreeValue(self.ctx, constructor);
                const expected = c.JS_GetPropertyStr(self.ctx, constructor, "prototype");
                try exceptionCheck(expected);
                defer c.JS_FreeValue(self.ctx, expected);
                if (c.JS_IsStrictEqual(self.ctx, prototype, expected)) return true;
            }
            return false;
        }

        fn writeJSObject(self: *Self, obj: c.JSValue) !void {
            try self.writeJSObjectOrSparseArraySlow(.Object, obj);
        }

        fn getOwnPropertyNames(self: *Self, obj: c.JSValue) ![]c.JSPropertyEnum {
            var prop_enum: [*c]c.JSPropertyEnum = null;
            var len: u32 = 0;
            if (c.JS_GetOwnPropertyNames(self.ctx, &prop_enum, &len, obj, c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY) != 0) {
                return Error.JSException;
            }
            return prop_enum[0..len];
        }

        fn writeJSObjectOrSparseArraySlow(self: *Self, comptime kind: ObjectOrArray, obj: c.JSValue) !void {
            var length: i64 = undefined;
            if (kind == .Array) {
                if (c.JS_GetLength(self.ctx, obj, &length) != 0) return Error.JSException;
                if (length < 0 or length > std.math.maxInt(u32)) try self.throwDataCloneError();
            }

            const prop_enum = try self.getOwnPropertyNames(obj);
            defer c.JS_FreePropertyEnum(self.ctx, prop_enum.ptr, @intCast(prop_enum.len));

            try self.writeTag(if (kind == .Array) .begin_sparse_js_array else .begin_js_object);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length));

            const cache_hit = if (kind == .Object) self.object_shape_cache.matches(prop_enum) else false;
            var candidate_cache: ObjectShapeCache = .{};
            defer candidate_cache.deinit(self.ac, self.rt);
            if (kind == .Object and !cache_hit) try candidate_cache.prepare(self.ac, self.ctx, prop_enum);

            const properties_written = if (cache_hit)
                try self.writeJSObjectPropertiesCached(obj)
            else
                try self.writeJSObjectPropertiesSlow(obj, prop_enum, if (kind == .Object) &candidate_cache else null);

            try self.writeTag(if (kind == .Array) .end_sparse_js_array else .end_js_object);
            try self.writeVarint(u32, properties_written);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length));

            if (kind == .Object and !cache_hit) {
                self.object_shape_cache.deinit(self.ac, self.rt);
                if (candidate_cache.isComplete(properties_written)) {
                    self.object_shape_cache = candidate_cache;
                    candidate_cache = .{};
                }
            }
        }

        fn denseArrayElementCount(self: *Self, props: []const c.JSPropertyEnum, length: u32) !?usize {
            if (length > props.len) return null;
            for (0..length) |index| {
                const expected = c.JS_NewAtomUInt32(self.ctx, @intCast(index));
                if (expected == c.JS_ATOM_NULL) return Error.JSException;
                defer c.JS_FreeAtom(self.ctx, expected);
                if (props[index].atom != expected) return null;
            }
            return @intCast(length);
        }

        fn writeArrayNonElementProps(self: *Self, arr: c.JSValue, props: []c.JSPropertyEnum) !u32 {
            var properties_written: u32 = 0;
            for (props) |prop| {
                const key = c.JS_AtomToValue(self.ctx, prop.atom);
                try exceptionCheck(key);
                defer c.JS_FreeValue(self.ctx, key);
                const value = c.JS_GetProperty(self.ctx, arr, prop.atom);
                try exceptionCheck(value);
                defer c.JS_FreeValue(self.ctx, value);

                // Guard against getters deleting the property
                const has_property = c.JS_HasProperty(self.ctx, arr, prop.atom);
                if (has_property < 0) return Error.JSException;
                if (has_property == cFALSE) continue;

                try self.writeObject(key);
                try self.writeObject(value);
                properties_written += 1;
            }

            return properties_written;
        }

        fn writeJSArray(self: *Self, obj: c.JSValue) !void {
            var length_i64: i64 = undefined;
            if (c.JS_GetLength(self.ctx, obj, &length_i64) != 0 or length_i64 < 0 or length_i64 > std.math.maxInt(u32)) {
                try self.throwDataCloneError();
            }
            const length: u32 = @intCast(length_i64);
            const props = try self.getOwnPropertyNames(obj);
            defer c.JS_FreePropertyEnum(self.ctx, props.ptr, @intCast(props.len));

            const dense_element_count = try self.denseArrayElementCount(props, length);

            if (dense_element_count) |element_count| {
                try self.writeTag(.begin_dense_js_array);
                try self.writeVarint(u32, length);
                const identity_sample_size: u32 = @min(length, 16);
                const identity_sample_start = self.next_id;
                for (0..length) |i| {
                    const item = c.JS_GetPropertyUint32(self.ctx, obj, @intCast(i));
                    try exceptionCheck(item);
                    defer c.JS_FreeValue(self.ctx, item);
                    switch (c.JS_VALUE_GET_NORM_TAG(item)) {
                        c.JS_TAG_INT => try self.writeSmi(item),
                        c.JS_TAG_FLOAT64 => try self.writeHeapNumber(item),
                        else => try self.writeObject(item),
                    }
                    if (self.recursion_depth == 1 and i + 1 == identity_sample_size and length >= 4096) {
                        const sample_new_ids = self.next_id - identity_sample_start;
                        const estimated_ids = @as(u64, sample_new_ids) * length / identity_sample_size + 1;
                        // Sample after normal serialization so repeated-reference
                        // arrays do not trigger a large speculative allocation.
                        if (sample_new_ids >= identity_sample_size / 2 and
                            estimated_ids <= 1_000_000 and
                            estimated_ids > self.id_map.count())
                        {
                            try self.id_map.ensureTotalCapacity(self.ac, @intCast(estimated_ids));
                        }
                    }
                }

                const properties_written = try self.writeArrayNonElementProps(obj, props[element_count..]);

                try self.writeTag(.end_dense_js_array);
                try self.writeVarint(u32, properties_written);
                try self.writeVarint(u32, length);
            } else {
                try self.writeJSObjectOrSparseArraySlow(.Array, obj);
            }
        }

        fn getPrototypeMethod(self: *Self, constructor_name: [*:0]const u8, method_name: [*:0]const u8) !c.JSValue {
            const global = c.JS_GetGlobalObject(self.ctx);
            try exceptionCheck(global);
            defer c.JS_FreeValue(self.ctx, global);
            const constructor = c.JS_GetPropertyStr(self.ctx, global, constructor_name);
            try exceptionCheck(constructor);
            defer c.JS_FreeValue(self.ctx, constructor);
            const prototype = c.JS_GetPropertyStr(self.ctx, constructor, "prototype");
            try exceptionCheck(prototype);
            defer c.JS_FreeValue(self.ctx, prototype);
            const method = c.JS_GetPropertyStr(self.ctx, prototype, method_name);
            try exceptionCheck(method);
            if (!c.JS_IsFunction(self.ctx, method)) {
                c.JS_FreeValue(self.ctx, method);
                return Error.DataCloneError;
            }
            return method;
        }

        fn writeJSDate(self: *Self, obj: c.JSValue) !void {
            const get_time = try self.getPrototypeMethod("Date", "getTime");
            defer c.JS_FreeValue(self.ctx, get_time);
            const date = c.JS_Call(self.ctx, get_time, obj, 0, null);
            try exceptionCheck(date);
            defer c.JS_FreeValue(self.ctx, date);
            var milliseconds: f64 = undefined;
            if (c.JS_ToFloat64(self.ctx, &milliseconds, date) != 0) return Error.JSException;
            try self.writeTag(.date);
            try self.writeDouble(milliseconds);
        }

        fn writeJSPrimitiveWrapper(self: *Self, obj: c.JSValue) !void {
            const value_of = c.JS_GetPropertyStr(self.ctx, obj, "valueOf");
            try exceptionCheck(value_of);
            defer c.JS_FreeValue(self.ctx, value_of);
            const value = c.JS_Call(self.ctx, value_of, obj, 0, null);
            try exceptionCheck(value);
            defer c.JS_FreeValue(self.ctx, value);

            const tag = c.JS_VALUE_GET_NORM_TAG(value);
            switch (tag) {
                c.JS_TAG_BOOL => try self.writeTag(if (c.JS_VALUE_GET_INT(value) == 0) .false_object else .true_object),
                c.JS_TAG_FLOAT64, c.JS_TAG_INT => {
                    const dbl: f64 = if (tag == c.JS_TAG_INT) @floatFromInt(c.JS_VALUE_GET_INT(value)) else c.JS_VALUE_GET_FLOAT64(value);
                    try self.writeTag(.number_object);
                    try self.writeDouble(dbl);
                },
                c.JS_TAG_BIG_INT, c.JS_TAG_SHORT_BIG_INT => {
                    try self.writeTag(.big_int_object);
                    try self.writeBigIntContents(value);
                },
                c.JS_TAG_STRING, c.JS_TAG_STRING_ROPE => {
                    try self.writeTag(.string_object);
                    try self.writeString(value);
                },
                else => {
                    @branchHint(.unlikely);
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeJSRegExp(self: *Self, obj: c.JSValue) !void {
            const pattern = c.JS_GetPropertyStr(self.ctx, obj, "source");
            try exceptionCheck(pattern);
            defer c.JS_FreeValue(self.ctx, pattern);
            const flags_value = c.JS_GetPropertyStr(self.ctx, obj, "flags");
            try exceptionCheck(flags_value);
            defer c.JS_FreeValue(self.ctx, flags_value);
            const flags_ptr = c.JS_ToCString(self.ctx, flags_value) orelse return Error.JSException;
            defer c.JS_FreeCString(self.ctx, flags_ptr);

            var v8_flags: u32 = 0;
            for (std.mem.span(flags_ptr)) |flag| switch (flag) {
                'g' => v8_flags |= 1 << 0,
                'i' => v8_flags |= 1 << 1,
                'm' => v8_flags |= 1 << 2,
                'y' => v8_flags |= 1 << 3,
                'u' => v8_flags |= 1 << 4,
                's' => v8_flags |= 1 << 5,
                'd' => v8_flags |= 1 << 7,
                'v' => v8_flags |= 1 << 8,
                else => try self.throwDataCloneError(),
            };

            try self.writeTag(.reg_exp);
            try self.writeString(pattern);
            try self.writeVarint(u32, v8_flags);
        }

        fn writeJSMap(self: *Self, comptime as: SetOrMap, obj: c.JSValue) !void {
            const iterator_method = try self.getPrototypeMethod(if (as == .Map) "Map" else "Set", if (as == .Map) "entries" else "values");
            defer c.JS_FreeValue(self.ctx, iterator_method);
            const iterator = c.JS_Call(self.ctx, iterator_method, obj, 0, null);
            try exceptionCheck(iterator);
            defer c.JS_FreeValue(self.ctx, iterator);
            const next = c.JS_GetPropertyStr(self.ctx, iterator, "next");
            try exceptionCheck(next);
            defer c.JS_FreeValue(self.ctx, next);

            var entries: std.ArrayListUnmanaged(c.JSValue) = .empty;
            defer {
                for (entries.items) |entry| c.JS_FreeValue(self.ctx, entry);
                entries.deinit(self.ac);
            }
            while (true) {
                const result = c.JS_Call(self.ctx, next, iterator, 0, null);
                try exceptionCheck(result);
                defer c.JS_FreeValue(self.ctx, result);
                const done_value = c.JS_GetPropertyStr(self.ctx, result, "done");
                try exceptionCheck(done_value);
                defer c.JS_FreeValue(self.ctx, done_value);
                const done = c.JS_ToBool(self.ctx, done_value);
                if (done < 0) return Error.JSException;
                if (done != 0) break;

                try entries.ensureUnusedCapacity(self.ac, if (as == .Map) 2 else 1);
                const value = c.JS_GetPropertyStr(self.ctx, result, "value");
                try exceptionCheck(value);
                if (as == .Map) {
                    defer c.JS_FreeValue(self.ctx, value);
                    const key = c.JS_GetPropertyUint32(self.ctx, value, 0);
                    try exceptionCheck(key);
                    errdefer c.JS_FreeValue(self.ctx, key);
                    const map_value = c.JS_GetPropertyUint32(self.ctx, value, 1);
                    try exceptionCheck(map_value);
                    errdefer c.JS_FreeValue(self.ctx, map_value);
                    entries.appendAssumeCapacity(key);
                    entries.appendAssumeCapacity(map_value);
                } else {
                    entries.appendAssumeCapacity(value);
                }
            }

            try self.writeTag(if (as == .Map) .begin_js_map else .begin_js_set);
            for (entries.items) |entry| {
                try self.writeObject(entry);
            }
            try self.writeTag(if (as == .Map) .end_js_map else .end_js_set);
            if (entries.items.len > std.math.maxInt(u32)) return Error.DataCloneError;
            try self.writeVarint(u32, @intCast(entries.items.len));
        }

        fn writeJSArrayBuffer(self: *Self, obj: c.JSValue) !void {
            var byte_length: usize = 0;
            const bytes = c.JS_GetArrayBuffer(self.ctx, &byte_length, obj);
            if (bytes == null) {
                @branchHint(.unlikely);
                try self.throwDataCloneErrorDetachedArrayBuffer();
            }

            try self.writeTag(.array_buffer);
            if (byte_length > std.math.maxInt(u32)) return Error.DataCloneError;
            try self.writeVarint(u32, @intCast(byte_length));
            try self.writeRawBytes(bytes[0..@intCast(byte_length)]);
        }

        fn getArrayBufferViewInfo(self: *Self, val: c.JSValue, array_type: c_int) !struct {
            buffer: c.JSValue,
            byte_offset: usize,
            byte_length: usize,
            tag: ArrayBufferViewTag,
        } {
            if (array_type >= 0) {
                var byte_offset: usize = 0;
                var byte_length: usize = 0;
                var bytes_per_element: usize = 0;
                const buffer = c.JS_GetTypedArrayBuffer(self.ctx, val, &byte_offset, &byte_length, &bytes_per_element);
                try exceptionCheck(buffer);
                const tag: ArrayBufferViewTag = switch (array_type) {
                    c.JS_TYPED_ARRAY_UINT8C => .uint8_clamped_array,
                    c.JS_TYPED_ARRAY_INT8 => .int8_array,
                    c.JS_TYPED_ARRAY_UINT8 => .uint8_array,
                    c.JS_TYPED_ARRAY_INT16 => .int16_array,
                    c.JS_TYPED_ARRAY_UINT16 => .uint16_array,
                    c.JS_TYPED_ARRAY_INT32 => .int32_array,
                    c.JS_TYPED_ARRAY_UINT32 => .uint32_array,
                    c.JS_TYPED_ARRAY_BIG_INT64 => .big_int64_array,
                    c.JS_TYPED_ARRAY_BIG_UINT64 => .big_uint64_array,
                    c.JS_TYPED_ARRAY_FLOAT16 => .float16_array,
                    c.JS_TYPED_ARRAY_FLOAT32 => .float32_array,
                    c.JS_TYPED_ARRAY_FLOAT64 => .float64_array,
                    else => {
                        c.JS_FreeValue(self.ctx, buffer);
                        return Error.DataCloneError;
                    },
                };
                return .{ .buffer = buffer, .byte_offset = byte_offset, .byte_length = byte_length, .tag = tag };
            }
            if (!c.JS_IsDataView(val)) return Error.DataCloneError;
            const buffer = c.JS_GetPropertyStr(self.ctx, val, "buffer");
            try exceptionCheck(buffer);
            errdefer c.JS_FreeValue(self.ctx, buffer);
            const offset_value = c.JS_GetPropertyStr(self.ctx, val, "byteOffset");
            try exceptionCheck(offset_value);
            defer c.JS_FreeValue(self.ctx, offset_value);
            const length_value = c.JS_GetPropertyStr(self.ctx, val, "byteLength");
            try exceptionCheck(length_value);
            defer c.JS_FreeValue(self.ctx, length_value);
            var byte_offset: u64 = undefined;
            var byte_length: u64 = undefined;
            if (c.JS_ToIndex(self.ctx, &byte_offset, offset_value) != 0 or c.JS_ToIndex(self.ctx, &byte_length, length_value) != 0) {
                return Error.JSException;
            }
            if (byte_offset > std.math.maxInt(usize) or byte_length > std.math.maxInt(usize)) return Error.DataCloneError;
            return .{ .buffer = buffer, .byte_offset = @intCast(byte_offset), .byte_length = @intCast(byte_length), .tag = .data_view };
        }

        fn writeJSArrayBufferView(self: *Self, val: c.JSValue, array_type: c_int) !void {
            if (self.treat_array_buffer_views_as_host_objects) {
                if (self.use_default_host_object_writer) {
                    const saved_len = self.buffer.items.len;
                    errdefer self.buffer.items.len = saved_len;
                    try self.writeTag(.host_object);
                    return self.writeDefaultHostObject(val, array_type);
                }
                return self.writeHostObject(val);
            }

            try self.writeTag(.array_buffer_view);
            const info = try self.getArrayBufferViewInfo(val, array_type);
            defer c.JS_FreeValue(self.ctx, info.buffer);
            if (info.byte_offset > std.math.maxInt(u32) or info.byte_length > std.math.maxInt(u32)) return Error.DataCloneError;
            try self.writeVarint(u32, @intFromEnum(info.tag));
            try self.writeVarint(u32, @intCast(info.byte_offset));
            try self.writeVarint(u32, @intCast(info.byte_length));
            // V8 has special flags for length tracking and resizable array buffer backing,
            // but QuickJS doesn't have equivalent features. In V8 these flags would be:
            // uint32_t flags =
            //      JSArrayBufferViewIsLengthTracking::encode(view->is_length_tracking()) |
            //      JSArrayBufferViewIsBackedByRab::encode(view->is_backed_by_rab());
            // For QuickJS compatibility, we'll just write 0 as the flags value
            try self.writeVarint(u32, 0);
        }

        fn writeErrorTag(self: *Self, tag: ErrorTag) !void {
            try self.writeVarint(u32, @intFromEnum(tag));
        }

        fn writeJSError(self: *Self, obj: c.JSValue) !void {
            var message_desc: c.JSPropertyDescriptor = undefined;
            const message = c.JS_NewAtom(self.ctx, "message");
            defer c.JS_FreeAtom(self.ctx, message);
            if (message == c.JS_ATOM_NULL) return Error.JSException;
            const message_status = c.JS_GetOwnProperty(self.ctx, &message_desc, obj, message);
            if (message_status < 0) return Error.JSException;
            const message_found = message_status == cTRUE;
            defer if (message_found) freePropertyDescriptor(self.ctx, message_desc);

            var cause_desc: c.JSPropertyDescriptor = undefined;
            const cause = c.JS_NewAtom(self.ctx, "cause");
            defer c.JS_FreeAtom(self.ctx, cause);
            if (cause == c.JS_ATOM_NULL) return Error.JSException;
            const cause_status = c.JS_GetOwnProperty(self.ctx, &cause_desc, obj, cause);
            if (cause_status < 0) return Error.JSException;
            const cause_found = cause_status == cTRUE;
            defer if (cause_found) freePropertyDescriptor(self.ctx, cause_desc);

            try self.writeTag(.@"error");

            const name_object = c.JS_GetPropertyStr(self.ctx, obj, "name");
            try exceptionCheck(name_object);
            defer c.JS_FreeValue(self.ctx, name_object);

            const name_cstr = c.JS_ToCString(self.ctx, name_object);
            if (name_cstr == null) {
                @branchHint(.unlikely);
                return Error.JSException;
            }
            defer c.JS_FreeCString(self.ctx, name_cstr);

            const name = std.mem.span(name_cstr);
            if (std.mem.eql(u8, name, "EvalError")) {
                try self.writeErrorTag(.eval_error_prototype);
            } else if (std.mem.eql(u8, name, "RangeError")) {
                try self.writeErrorTag(.range_error_prototype);
            } else if (std.mem.eql(u8, name, "ReferenceError")) {
                try self.writeErrorTag(.reference_error_prototype);
            } else if (std.mem.eql(u8, name, "SyntaxError")) {
                try self.writeErrorTag(.syntax_error_prototype);
            } else if (std.mem.eql(u8, name, "TypeError")) {
                try self.writeErrorTag(.type_error_prototype);
            } else if (std.mem.eql(u8, name, "URIError")) {
                try self.writeErrorTag(.uri_error_prototype);
            } else {
                // The default prototype in the deserialization side is Error.prototype, so
                // we don't have to do anything here.
            }

            if (message_found) {
                if (!c.JS_IsString(message_desc.value)) try self.throwDataCloneError();
                try self.writeErrorTag(.message);
                try self.writeString(message_desc.value);
            }

            const stack = c.JS_NewAtom(self.ctx, "stack");
            defer c.JS_FreeAtom(self.ctx, stack);
            if (stack == c.JS_ATOM_NULL) return Error.JSException;
            const stack_val = c.JS_GetProperty(self.ctx, obj, stack);
            try exceptionCheck(stack_val);
            defer c.JS_FreeValue(self.ctx, stack_val);
            if (c.JS_IsString(stack_val)) {
                try self.writeErrorTag(.stack);
                try self.writeString(stack_val);
            }

            if (cause_found) {
                try self.writeErrorTag(.cause);
                try self.writeObject(cause_desc.value);
            }

            try self.writeErrorTag(.end);
        }

        fn writeHostObject(self: *Self, val: c.JSValue) !void {
            // Let delegate perform any custom serialization. If it throws, roll back.
            const saved_len = self.buffer.items.len;
            errdefer self.buffer.items.len = saved_len;
            if (self.delegate) |del| {
                try self.writeTag(.host_object);
                try del.writeHostObject(self.ctx, val);
            } else {
                return Error.NotImplemented;
            }
        }

        fn writeDefaultHostObject(self: *Self, val: c.JSValue, array_type: c_int) !void {
            const info = try self.getArrayBufferViewInfo(val, array_type);
            defer c.JS_FreeValue(self.ctx, info.buffer);

            const type_index: u32 = switch (info.tag) {
                .int8_array => 0,
                .uint8_array => 1,
                .uint8_clamped_array => 2,
                .int16_array => 3,
                .uint16_array => 4,
                .int32_array => 5,
                .uint32_array => 6,
                .float32_array => 7,
                .float64_array => 8,
                .data_view => 9,
                .big_int64_array => 11,
                .big_uint64_array => 12,
                .float16_array => 13,
                else => return Error.DataCloneError,
            };
            if (info.byte_length > std.math.maxInt(u32)) return Error.DataCloneError;

            var buffer_length: usize = 0;
            const bytes = c.JS_GetArrayBuffer(self.ctx, &buffer_length, info.buffer);
            if (bytes == null) try self.throwDataCloneErrorDetachedArrayBuffer();
            if (info.byte_offset > buffer_length or info.byte_length > buffer_length - info.byte_offset) {
                try self.throwDataCloneErrorDetachedArrayBuffer();
            }

            try self.writeVarint(u32, type_index);
            try self.writeVarint(u32, @intCast(info.byte_length));
            try self.writeRawBytes(bytes[info.byte_offset .. info.byte_offset + info.byte_length]);
        }

        fn writeJSObjectPropertiesCached(self: *Self, obj: c.JSValue) !u32 {
            var properties_written: u32 = 0;

            for (self.object_shape_cache.properties.items) |property| {
                const value = (try self.getPropertyForSerialization(obj, property.atom)) orelse continue;
                defer c.JS_FreeValue(self.ctx, value);

                try self.writeRawBytes(property.encoded_key.?);
                try self.writeObject(value);
                properties_written += 1;
            }

            return properties_written;
        }

        fn getPropertyForSerialization(self: *Self, obj: c.JSValue, atom: c.JSAtom) !?c.JSValue {
            var descriptor: c.JSPropertyDescriptor = undefined;
            const status = c.JS_GetOwnProperty(self.ctx, &descriptor, obj, atom);
            if (status < 0) return Error.JSException;
            if (status == cTRUE and descriptor.flags & c.JS_PROP_GETSET == 0) {
                c.JS_FreeValue(self.ctx, descriptor.getter);
                c.JS_FreeValue(self.ctx, descriptor.setter);
                return descriptor.value;
            }
            if (status == cTRUE) freePropertyDescriptor(self.ctx, descriptor);

            // Accessors can delete this property, and an earlier accessor can
            // expose an inherited replacement. Preserve the ordinary
            // GetProperty/HasProperty behavior for both cases.
            const value = c.JS_GetProperty(self.ctx, obj, atom);
            try exceptionCheck(value);
            errdefer c.JS_FreeValue(self.ctx, value);
            const has_property = c.JS_HasProperty(self.ctx, obj, atom);
            if (has_property < 0) return Error.JSException;
            if (has_property == cFALSE) {
                c.JS_FreeValue(self.ctx, value);
                return null;
            }
            return value;
        }

        fn writeJSObjectPropertiesSlow(
            self: *Self,
            obj: c.JSValue,
            prop_enum: []c.JSPropertyEnum,
            candidate_cache: ?*ObjectShapeCache,
        ) !u32 {
            var properties_written: u32 = 0;

            for (prop_enum, 0..) |prop, property_index| {
                if (prop.is_enumerable == false) continue;
                const key = c.JS_AtomToValue(self.ctx, prop.atom);
                try exceptionCheck(key);
                defer c.JS_FreeValue(self.ctx, key);
                const value = (try self.getPropertyForSerialization(obj, prop.atom)) orelse continue;
                defer c.JS_FreeValue(self.ctx, value);

                const key_start = self.buffer.items.len;
                try self.writeObject(key);
                if (candidate_cache) |cache| {
                    if (cache.valid) {
                        const encoded_key = self.buffer.items[key_start..];
                        const key_tag: SerializationTag = @enumFromInt(encoded_key[0]);
                        if (key_tag == .one_byte_string or key_tag == .int32 or key_tag == .uint32) {
                            cache.properties.items[property_index].encoded_key = try self.ac.dupe(u8, encoded_key);
                        } else {
                            cache.valid = false;
                        }
                    }
                }
                try self.writeObject(value);
                properties_written += 1;
            }

            return properties_written;
        }

        fn isHostObject(self: *Self, val: c.JSValue) !bool {
            if (!self.has_custom_objects) return false;
            return if (self.delegate) |del| try del.isHostObject(self.ctx, val) else return Error.NotImplemented;
        }

        fn throwDataCloneErrorMsg(self: *Self, comptime msg: []const u8) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, msg);
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, msg.ptr);
            }
            return Error.DataCloneError;
        }

        fn throwDataCloneError(self: *Self) !noreturn {
            return self.throwDataCloneErrorMsg("Data clone error");
        }

        fn throwDataCloneErrorDetachedArrayBuffer(self: *Self) !noreturn {
            return self.throwDataCloneErrorMsg("ArrayBuffer is detached");
        }
    };
}

/// A V8 compatible deserializer for QuickJS values.
pub fn Deserializer(comptime Delegate: type) type {
    // FIXME: comptime validate delegate type
    return struct {
        ac: std.mem.Allocator,
        ctx: ?*c.JSContext,
        rt: ?*c.JSRuntime,
        js_view: c.JSValue,
        data: []const u8,
        input_owner: *OwnedInput,
        position: usize = 0,
        version: ?u32 = null,
        next_id: u32 = 0,
        recursion_depth: u32 = 0,
        version_13_broken_data_mode: bool = false,
        suppress_deserialization_errors: bool = false,
        id_map: std.AutoHashMapUnmanaged(u32, c.JSValue),
        // array_buffer_transfer_map: *anyopaque = null,
        // shared_object_conveyor: *anyopaque = null,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext, buffer_view: c.JSValue, delegate: ?Delegate) !Self {
            const slice = try arrayBufferViewToSlice(ctx, buffer_view);
            const owner = try OwnedInput.create(allocator, slice);
            errdefer owner.release();

            // The new QuickJS memory API manages external buffers through a
            // realloc callback. Native parsing and the JS view each hold one
            // reference, so detaching either side cannot invalidate the other.
            const js_buffer = c.JS_NewArrayBuffer(ctx, owner.bytes.ptr, owner.bytes.len, 0, releaseOwnedInput, owner, false);
            try exceptionCheck(js_buffer);
            owner.retain();
            defer c.JS_FreeValue(ctx, js_buffer);

            var argv = [_]c.JSValue{
                js_buffer,
                c.JS_NewUint32(ctx, 0),
                c.JS_NewUint32(ctx, @intCast(owner.bytes.len)),
            };
            defer c.JS_FreeValue(ctx, argv[1]);
            defer c.JS_FreeValue(ctx, argv[2]);
            const js_view = c.JS_NewTypedArray(ctx, argv.len, &argv, c.JS_TYPED_ARRAY_UINT8);
            try exceptionCheck(js_view);
            return Self{
                .ac = allocator,
                .ctx = ctx,
                .rt = c.JS_GetRuntime(ctx),
                .js_view = js_view,
                .data = owner.bytes,
                .input_owner = owner,
                .id_map = .empty,
                .delegate = delegate,
            };
        }

        pub fn deinit(self: *Self) void {
            var values = self.id_map.valueIterator();
            while (values.next()) |value| c.JS_FreeValueRT(self.rt, value.*);
            self.id_map.deinit(self.ac);
            c.JS_FreeValueRT(self.rt, self.js_view);
            self.input_owner.release();
        }

        pub fn readHeader(self: *Self) !bool {
            if (try self.peekTag() != .version) {
                try self.throwDataCloneDeserializationVersionError();
            }
            try self.consumeTag(.version);
            const version = try self.readVarint(u32);
            if (version > kLatestVersion) try self.throwDataCloneDeserializationVersionError();
            self.version = version;
            return true;
        }

        fn peekTag(self: *Self) !?SerializationTag {
            var peek_position = self.position;
            var tag: SerializationTag = .padding;
            while (tag == .padding) {
                if (peek_position >= self.data.len) return null;
                tag = @enumFromInt(self.data[peek_position]);
                peek_position += 1;
            }
            return tag;
        }

        fn consumeTag(self: *Self, tag: ?SerializationTag) !void {
            const actual_tag = self.readTag();
            if (tag == null or actual_tag != tag) try self.throwDataCloneDeserializationError();
        }

        fn readTag(self: *Self) ?SerializationTag {
            var tag: SerializationTag = .padding;
            while (tag == .padding) {
                if (self.position >= self.data.len) return null;
                tag = @enumFromInt(self.data[self.position]);
                self.position += 1;
            }
            return tag;
        }

        fn readVarint(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be read from varints.");
                }
            }
            var value: T = 0;
            const bit_count = @bitSizeOf(T);
            var shift: usize = 0;
            while (true) {
                if (self.position >= self.data.len) {
                    @branchHint(.unlikely);
                    try self.throwDataCloneDeserializationError();
                }
                const byte = self.data[self.position];
                self.position += 1;
                const payload = byte & 0x7f;
                const has_another_byte = (byte & 0x80) != 0;

                if (shift >= bit_count) try self.throwDataCloneDeserializationError();
                const remaining = bit_count - shift;
                if (remaining < 7 and payload >= (@as(u8, 1) << @intCast(remaining))) {
                    try self.throwDataCloneDeserializationError();
                }
                value |= @as(T, @intCast(payload)) << @intCast(shift);
                if (!has_another_byte) return value;
                shift += 7;
            }
        }

        fn readZigZag(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .signed) {
                    @compileError("Only signed integer types can be read as zigzag.");
                }
            }
            const UnsignedT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const unsigned_value: UnsignedT = try self.readVarint(UnsignedT);
            const a: T = @intCast(unsigned_value >> 1);
            const b: T = @intCast(unsigned_value & 1);
            return a ^ -b;
        }

        pub fn readDouble(self: *Self) !f64 {
            if (self.position > self.data.len or @sizeOf(f64) > self.data.len - self.position) {
                try self.throwDataCloneDeserializationError();
            }
            const f64_bytes = self.data[self.position .. self.position + @sizeOf(f64)];
            const value = std.mem.bytesAsValue(f64, f64_bytes).*;
            self.position += @sizeOf(f64);
            return value;
        }

        pub fn readRawBytes(self: *Self, length: usize) ![]const u8 {
            if (self.position > self.data.len or length > self.data.len - self.position) {
                try self.throwDataCloneDeserializationError();
            }
            const slice = self.data[self.position .. self.position + length];
            self.position += length;
            return slice;
        }

        pub fn readByte(self: *Self) !u8 {
            if (self.position >= self.data.len) try self.throwDataCloneDeserializationError();
            const byte = self.data[self.position];
            self.position += 1;
            return byte;
        }

        pub fn readUint32(self: *Self) !u32 {
            return try self.readVarint(u32);
        }

        pub fn readUint64(self: *Self) !u64 {
            return try self.readVarint(u64);
        }

        pub fn readObject(self: *Self) Error!c.JSValue {
            if (self.version == null) try self.throwDataCloneDeserializationVersionError();
            if (self.recursion_depth >= maxRecursionDepth) {
                _ = c.JS_ThrowRangeError(self.ctx, "Maximum deserialization depth exceeded");
                return Error.JSException;
            }
            self.recursion_depth += 1;
            defer self.recursion_depth -= 1;

            const result = try self.readObjectInternal();

            // ArrayBufferView is special in that it consumes the value before it, even
            // after format version 0.
            if (c.JS_IsArrayBuffer(result)) {
                @branchHint(.unlikely);
                const tag = self.peekTag() catch |err| {
                    c.JS_FreeValue(self.ctx, result);
                    return err;
                };
                if (tag == .array_buffer_view) {
                    self.consumeTag(.array_buffer_view) catch |err| {
                        c.JS_FreeValue(self.ctx, result);
                        return err;
                    };
                    const view = self.readJSArrayBufferView(result) catch |err| {
                        c.JS_FreeValue(self.ctx, result);
                        return err;
                    };
                    c.JS_FreeValue(self.ctx, result);
                    return view;
                }
            }

            return result;
        }

        fn readObjectInternal(self: *Self) !c.JSValue {
            if (self.readTag()) |tag| switch (tag) {
                .verify_object_count => {
                    // Read the count and ignore it.
                    _ = try self.readVarint(u32);
                    return self.readObject();
                },
                .undefined => return z.JS_UNDEFINED,
                .null => return z.JS_NULL,
                .true => return z.JS_TRUE,
                .false => return z.JS_FALSE,
                .int32 => {
                    const value = try self.readZigZag(i32);
                    return c.JS_NewInt32(self.ctx, value);
                },
                .uint32 => {
                    const value = try self.readVarint(u32);
                    return c.JS_NewUint32(self.ctx, value);
                },
                .double => {
                    const value = try self.readDouble();
                    return c.JS_NewFloat64(self.ctx, value);
                },
                .big_int => {
                    return self.readBigInt();
                },
                .utf8_string => {
                    return self.readUtf8String();
                },
                .one_byte_string => {
                    return self.readOneByteString();
                },
                .two_byte_string => {
                    return self.readTwoByteString();
                },
                .object_reference => {
                    const id = try self.readVarint(u32);
                    return self.getObjectWithID(id);
                },
                .begin_js_object => {
                    return self.readJSObject();
                },
                .begin_sparse_js_array => {
                    return self.readSparseJSArray();
                },
                .begin_dense_js_array => {
                    return self.readDenseJSArray();
                },
                .date => {
                    return self.readJSDate();
                },
                .true_object, .false_object, .number_object, .big_int_object, .string_object => |t| {
                    return self.readJSPrimitiveWrapper(t);
                },
                .reg_exp => {
                    return self.readJSRegExp();
                },
                .begin_js_map => {
                    return self.readJSMap(.Map);
                },
                .begin_js_set => {
                    return self.readJSMap(.Set);
                },
                .array_buffer => {
                    const is_shared = false;
                    const is_resizable = false;
                    return self.readJSArrayBuffer(is_shared, is_resizable);
                },
                // .shared_array_buffer => {
                //     const is_shared = false;
                //     const is_resizable = true;
                //     return self.readJSArrayBuffer(is_shared, is_resizable);
                // },
                .@"error" => {
                    return self.readJSError();
                },
                .host_object => {
                    return self.readHostObject();
                },
                else => {
                    if (self.version) |v| if (v < 13) {
                        // Legacy host objects had no explicit '\\' tag. The
                        // unknown byte belongs to delegate data, so rewind it.
                        self.position -= 1;
                        return self.readHostObject();
                    };
                    try self.throwDataCloneDeserializationError();
                },
            } else {
                try self.throwDataCloneDeserializationError();
            }
        }

        fn readString(self: *Self) !c.JSValue {
            if (self.version.? < 12) return self.readUtf8String();
            const object = try self.readObject();
            if (!c.JS_IsString(object)) {
                c.JS_FreeValue(self.ctx, object);
                try self.throwDataCloneDeserializationError();
            }
            return object;
        }

        fn bigIntFromSerializedDigits(self: *Self, sign_bit: u1, digits_store: []const u8) !c.JSValue {
            if (digits_store.len == 0) {
                return c.JS_NewBigInt64(self.ctx, 0);
            }
            if (digits_store.len <= 8) {
                var magnitude: u64 = 0;
                for (digits_store, 0..) |byte, i| magnitude |= @as(u64, byte) << @intCast(i * 8);
                if (sign_bit == 0) return c.JS_NewBigUint64(self.ctx, magnitude);
                if (magnitude <= (@as(u64, 1) << 63)) {
                    const signed: i64 = if (magnitude == (@as(u64, 1) << 63))
                        std.math.minInt(i64)
                    else
                        -@as(i64, @intCast(magnitude));
                    return c.JS_NewBigInt64(self.ctx, signed);
                }
            }

            var hex = try std.ArrayListUnmanaged(u8).initCapacity(self.ac, 2 + digits_store.len * 2);
            defer hex.deinit(self.ac);
            hex.appendAssumeCapacity('0');
            hex.appendAssumeCapacity('x');
            var i = digits_store.len;
            while (i > 0) {
                i -= 1;
                const byte = digits_store[i];
                hex.appendAssumeCapacity("0123456789abcdef"[byte >> 4]);
                hex.appendAssumeCapacity("0123456789abcdef"[byte & 0xf]);
            }

            const global = c.JS_GetGlobalObject(self.ctx);
            try exceptionCheck(global);
            defer c.JS_FreeValue(self.ctx, global);
            const bigint_fn = c.JS_GetPropertyStr(self.ctx, global, "BigInt");
            try exceptionCheck(bigint_fn);
            defer c.JS_FreeValue(self.ctx, bigint_fn);
            const hex_value = c.JS_NewStringLen(self.ctx, hex.items.ptr, hex.items.len);
            try exceptionCheck(hex_value);
            defer c.JS_FreeValue(self.ctx, hex_value);
            var argv = [_]c.JSValue{hex_value};
            const positive = c.JS_Call(self.ctx, bigint_fn, z.JS_UNDEFINED, 1, &argv);
            try exceptionCheck(positive);
            if (sign_bit == 0) return positive;
            defer c.JS_FreeValue(self.ctx, positive);

            const source = "(value => -value)";
            const negate = c.JS_Eval(self.ctx, source, source.len, "<v8-deserialize>", c.JS_EVAL_TYPE_GLOBAL);
            try exceptionCheck(negate);
            defer c.JS_FreeValue(self.ctx, negate);
            var negate_argv = [_]c.JSValue{positive};
            const result = c.JS_Call(self.ctx, negate, z.JS_UNDEFINED, 1, &negate_argv);
            try exceptionCheck(result);
            return result;
        }

        fn readBigInt(self: *Self) !c.JSValue {
            const bitfield = try self.readVarint(u32);
            const sign_bit: u1 = @intCast(bitfield & 1);
            const byte_length: u31 = @intCast(bitfield >> 1);
            if (byte_length != 0 and byte_length % 8 != 0) try self.throwDataCloneDeserializationError();
            const digits_store = try self.readRawBytes(@intCast(byte_length));
            return self.bigIntFromSerializedDigits(sign_bit, digits_store);
        }

        fn readUtf8String(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(length);
            const val = c.JS_NewStringLen(self.ctx, bytes.ptr, length);
            try exceptionCheck(val);
            return val;
        }

        fn readOneByteString(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(length);
            var ascii = true;
            for (bytes) |byte| if (byte >= 0x80) {
                ascii = false;
                break;
            };
            if (ascii) {
                const val = c.JS_NewStringLen(self.ctx, bytes.ptr, bytes.len);
                try exceptionCheck(val);
                return val;
            }
            const utf16 = try self.ac.alloc(u16, bytes.len);
            defer self.ac.free(utf16);
            for (bytes, utf16) |byte, *code_unit| code_unit.* = byte;
            const val = c.JS_NewStringUTF16(self.ctx, utf16.ptr, utf16.len);
            try exceptionCheck(val);
            return val;
        }

        fn readTwoByteString(self: *Self) !c.JSValue {
            const byte_length = try self.readVarint(u32);
            if (byte_length % 2 != 0) try self.throwDataCloneDeserializationError();
            const bytes = try self.readRawBytes(byte_length);
            const utf16 = try self.ac.alloc(u16, byte_length / 2);
            defer self.ac.free(utf16);
            for (utf16, 0..) |*code_unit, i| {
                code_unit.* = @as(u16, bytes[i * 2]) | (@as(u16, bytes[i * 2 + 1]) << 8);
            }
            const ret = c.JS_NewStringUTF16(self.ctx, utf16.ptr, utf16.len);
            try exceptionCheck(ret);
            return ret;
        }

        fn readJSObject(self: *Self) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            const object = c.JS_NewObject(self.ctx);
            try exceptionCheck(object);
            errdefer c.JS_FreeValue(self.ctx, object);

            try self.addObjectWithID(id, object);

            const num_properties = try self.readJSObjectProperties(object, .end_js_object);
            const expected_num_properties = try self.readVarint(u32);
            if (num_properties != expected_num_properties) try self.throwDataCloneDeserializationError();

            std.debug.assert(self.hasObjectWithID(id));
            return object;
        }

        fn readJSObjectProperties(self: *Self, object: c.JSValue, end_tag: SerializationTag) !u32 {
            var num_properties: u32 = 0;
            while (true) {
                const tag = try self.peekTag();
                if (tag == end_tag) {
                    try self.consumeTag(end_tag);
                    return num_properties;
                }

                const key = try self.readObject();
                defer c.JS_FreeValue(self.ctx, key);

                const property_key = c.JS_ToPropertyKey(self.ctx, key);
                try exceptionCheck(property_key);
                defer c.JS_FreeValue(self.ctx, property_key);

                const value = try self.readObject();
                var value_owned = true;
                defer if (value_owned) c.JS_FreeValue(self.ctx, value);

                const atom = c.JS_ValueToAtom(self.ctx, property_key);
                defer c.JS_FreeAtom(self.ctx, atom);
                if (atom == c.JS_ATOM_NULL) return Error.JSException;

                // if the property already exists, something went wrong (probably getter/setter modified the object)
                const has_property = c.JS_HasProperty(self.ctx, object, atom);
                if (has_property < 0) return Error.JSException;
                if (has_property == cTRUE) try self.throwDataCloneDeserializationError();

                // JS_DefinePropertyValue consumes value even when it fails.
                value_owned = false;
                const code = c.JS_DefinePropertyValue(self.ctx, object, atom, value, c.JS_PROP_C_W_E);
                if (code < 0) return Error.JSException;
                num_properties = std.math.add(u32, num_properties, 1) catch {
                    try self.throwDataCloneDeserializationError();
                };
            }
        }

        fn readSparseJSArray(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            try exceptionCheck(array);
            errdefer c.JS_FreeValue(self.ctx, array);
            if (c.JS_SetLength(self.ctx, array, length) < 0) return Error.JSException;

            try self.addObjectWithID(id, array);

            const num_properties = try self.readJSObjectProperties(array, .end_sparse_js_array);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) try self.throwDataCloneDeserializationError();

            std.debug.assert(self.hasObjectWithID(id));
            return array;
        }

        fn readDenseJSArray(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            if (length > self.data.len - self.position) try self.throwDataCloneDeserializationError();

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            try exceptionCheck(array);
            errdefer c.JS_FreeValue(self.ctx, array);
            if (c.JS_SetLength(self.ctx, array, length) < 0) return Error.JSException;

            try self.addObjectWithID(id, array);

            var idx: u32 = 0;
            while (idx < length) : (idx += 1) {
                const tag = try self.peekTag();
                if (tag == .the_hole) {
                    try self.consumeTag(.the_hole);
                    continue;
                }

                const element = try self.readObject();
                var element_owned = true;
                defer if (element_owned) c.JS_FreeValue(self.ctx, element);

                // Serialization versions less than 11 encode the hole the same as
                // undefined. For consistency with previous behavior, store these as the
                // hole. Past version 11, undefined means undefined.
                if (self.version.? < 11 and c.JS_IsUndefined(element)) continue;

                // JS_DefinePropertyValueUint32 consumes element on all paths.
                element_owned = false;
                const code = c.JS_DefinePropertyValueUint32(self.ctx, array, idx, element, c.JS_PROP_C_W_E);
                if (code < 0) return Error.JSException;
            }

            const num_properties = try self.readJSObjectProperties(array, .end_dense_js_array);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) try self.throwDataCloneDeserializationError();
            std.debug.assert(self.hasObjectWithID(id));
            return array;
        }

        fn readJSDate(self: *Self) !c.JSValue {
            const value = try self.readDouble();
            const id: u32 = self.next_id;
            self.next_id += 1;
            const date = c.JS_NewDate(self.ctx, value);
            try exceptionCheck(date);
            errdefer c.JS_FreeValue(self.ctx, date);
            try self.addObjectWithID(id, date);
            return date;
        }

        fn readJSPrimitiveWrapper(self: *Self, tag: SerializationTag) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const value: c.JSValue = switch (tag) {
                .true_object => c.JS_ToObject(self.ctx, z.JS_TRUE),
                .false_object => c.JS_ToObject(self.ctx, z.JS_FALSE),
                .number_object => blk: {
                    const double = try self.readDouble();
                    const js_num = c.JS_NewFloat64(self.ctx, double);
                    defer c.JS_FreeValue(self.ctx, js_num);
                    break :blk c.JS_ToObject(self.ctx, js_num);
                },
                .big_int_object => blk: {
                    const bigint = try self.readBigInt();
                    defer c.JS_FreeValue(self.ctx, bigint);
                    break :blk c.JS_ToObject(self.ctx, bigint);
                },
                .string_object => blk: {
                    const js_str = try self.readString();
                    defer c.JS_FreeValue(self.ctx, js_str);
                    break :blk c.JS_ToObject(self.ctx, js_str);
                },
                else => unreachable,
            };
            try exceptionCheck(value);
            errdefer c.JS_FreeValue(self.ctx, value);
            try self.addObjectWithID(id, value);
            return value;
        }

        inline fn appendChar(arr: []u8, len: *usize, ch: u8) void {
            arr[len.*] = ch;
            len.* += 1;
        }

        fn readJSRegExp(self: *Self) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const pattern = try self.readString();
            defer c.JS_FreeValue(self.ctx, pattern);
            const v8_flags = try self.readVarint(u32);

            if ((v8_flags & ~@as(u32, 0x1bf)) != 0) try self.throwDataCloneDeserializationError();
            var flags: [8]u8 = undefined;
            var flags_len: usize = 0;
            if ((v8_flags & (1 << 0)) != 0) appendChar(&flags, &flags_len, 'g'); // global
            if ((v8_flags & (1 << 1)) != 0) appendChar(&flags, &flags_len, 'i'); // ignoreCase
            if ((v8_flags & (1 << 2)) != 0) appendChar(&flags, &flags_len, 'm'); // multiline
            if ((v8_flags & (1 << 3)) != 0) appendChar(&flags, &flags_len, 'y'); // sticky
            if ((v8_flags & (1 << 4)) != 0) appendChar(&flags, &flags_len, 'u'); // unicode
            if ((v8_flags & (1 << 5)) != 0) appendChar(&flags, &flags_len, 's'); // dotAll
            if ((v8_flags & (1 << 7)) != 0) appendChar(&flags, &flags_len, 'd'); // hasIndices
            if ((v8_flags & (1 << 8)) != 0) appendChar(&flags, &flags_len, 'v'); // unicodeSets

            const global = c.JS_GetGlobalObject(self.ctx);
            defer c.JS_FreeValue(self.ctx, global);

            const regexp_constructor = c.JS_GetPropertyStr(self.ctx, global, "RegExp");
            try exceptionCheck(regexp_constructor);
            defer c.JS_FreeValue(self.ctx, regexp_constructor);

            const flag_str = c.JS_NewStringLen(self.ctx, &flags, flags_len);
            try exceptionCheck(flag_str);
            defer c.JS_FreeValue(self.ctx, flag_str);

            var argv = [_]c.JSValue{ pattern, flag_str };
            const regexp = c.JS_CallConstructor(self.ctx, regexp_constructor, 2, &argv);
            try exceptionCheck(regexp);
            errdefer c.JS_FreeValue(self.ctx, regexp);

            try self.addObjectWithID(id, regexp);
            return regexp;
        }

        fn readJSMap(self: *Self, comptime kind: SetOrMap) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            const global = c.JS_GetGlobalObject(self.ctx);
            defer c.JS_FreeValue(self.ctx, global);
            const map_constructor = c.JS_GetPropertyStr(self.ctx, global, if (kind == .Map) "Map" else "Set");
            try exceptionCheck(map_constructor);
            defer c.JS_FreeValue(self.ctx, map_constructor);

            const map = c.JS_CallConstructor(self.ctx, map_constructor, 0, null);
            try exceptionCheck(map);
            errdefer c.JS_FreeValue(self.ctx, map);

            try self.addObjectWithID(id, map);

            const set_func = c.JS_GetPropertyStr(self.ctx, map, if (kind == .Map) "set" else "add");
            try exceptionCheck(set_func);
            defer c.JS_FreeValue(self.ctx, set_func);

            var length: u32 = 0;
            while (true) {
                const tag = try self.peekTag();
                if (tag == if (kind == .Map) .end_js_map else .end_js_set) {
                    try self.consumeTag(tag);
                    break;
                }

                var argv: [2]c.JSValue = undefined;
                argv[0] = try self.readObject();
                defer c.JS_FreeValue(self.ctx, argv[0]);
                if (kind == .Map) argv[1] = try self.readObject();
                defer if (kind == .Map) c.JS_FreeValue(self.ctx, argv[1]);

                const result = c.JS_Call(self.ctx, set_func, map, if (kind == .Map) 2 else 1, &argv);
                try exceptionCheck(result);
                defer c.JS_FreeValue(self.ctx, result);

                const increment: u32 = if (kind == .Map) 2 else 1;
                length = std.math.add(u32, length, increment) catch {
                    try self.throwDataCloneDeserializationError();
                };
            }

            const expected_length = try self.readVarint(u32);
            if (length != expected_length) try self.throwDataCloneDeserializationError();
            std.debug.assert(self.hasObjectWithID(id));
            return map;
        }

        fn readJSArrayBuffer(self: *Self, is_shared: bool, is_resizable: bool) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            if (is_shared) {
                // TODO:
                // uint32_t clone_id;
                // Local<SharedArrayBuffer> sab_value;
                // if (!ReadVarint<uint32_t>().To(&clone_id) || delegate_ == nullptr ||
                //     !delegate_
                //             ->GetSharedArrayBufferFromId(
                //                 reinterpret_cast<v8::Isolate*>(isolate_), clone_id)
                //             .ToLocal(&sab_value)) {
                //     RETURN_EXCEPTION_IF_EXCEPTION(isolate_);
                //     return MaybeHandle<JSArrayBuffer>();
                // }
                // Handle<JSArrayBuffer> array_buffer = Utils::OpenHandle(*sab_value);
                // DCHECK_EQ(is_shared, array_buffer->is_shared());
                // AddObjectWithID(id, array_buffer);
                // return array_buffer;
            }

            const byte_length = try self.readVarint(u32);
            if (is_resizable) {
                const max_byte_length = try self.readVarint(u32);
                if (byte_length > max_byte_length) try self.throwDataCloneDeserializationError();
            }

            const bytes = try self.readRawBytes(byte_length);
            const result = c.JS_NewArrayBufferCopy(self.ctx, bytes.ptr, byte_length);
            try exceptionCheck(result);
            errdefer c.JS_FreeValue(self.ctx, result);

            try self.addObjectWithID(id, result);
            return result;
        }

        fn readJSArrayBufferView(self: *Self, ab_val: c.JSValue) !c.JSValue {
            var buffer_byte_length: usize = undefined;
            if (c.JS_GetArrayBuffer(self.ctx, &buffer_byte_length, ab_val) == null) {
                try self.throwDataCloneDeserializationError();
            }

            const tag = try self.readVarint(u8);
            const byte_offset = try self.readVarint(u32);
            const byte_length = try self.readVarint(u32);
            if (byte_offset > buffer_byte_length or byte_length > buffer_byte_length - byte_offset) {
                try self.throwDataCloneDeserializationError();
            }

            const should_read_flags = self.version.? >= 14 or self.version_13_broken_data_mode;
            const flags = if (should_read_flags) try self.readVarint(u32) else 0;
            if (flags != 0) try self.throwDataCloneDeserializationError();

            const id = self.next_id;
            self.next_id += 1;

            const tag_enum: ArrayBufferViewTag = @enumFromInt(tag);
            const array_type: ?c.JSTypedArrayEnum, const element_size: u32 = switch (tag_enum) {
                .uint8_clamped_array => .{ c.JS_TYPED_ARRAY_UINT8C, 1 },
                .int8_array => .{ c.JS_TYPED_ARRAY_INT8, 1 },
                .uint8_array => .{ c.JS_TYPED_ARRAY_UINT8, 1 },
                .int16_array => .{ c.JS_TYPED_ARRAY_INT16, 2 },
                .uint16_array => .{ c.JS_TYPED_ARRAY_UINT16, 2 },
                .int32_array => .{ c.JS_TYPED_ARRAY_INT32, 4 },
                .uint32_array => .{ c.JS_TYPED_ARRAY_UINT32, 4 },
                .big_int64_array => .{ c.JS_TYPED_ARRAY_BIG_INT64, 8 },
                .big_uint64_array => .{ c.JS_TYPED_ARRAY_BIG_UINT64, 8 },
                .float16_array => .{ c.JS_TYPED_ARRAY_FLOAT16, 2 },
                .float32_array => .{ c.JS_TYPED_ARRAY_FLOAT32, 4 },
                .float64_array => .{ c.JS_TYPED_ARRAY_FLOAT64, 8 },
                .data_view => .{ null, 1 },
                else => try self.throwDataCloneDeserializationError(),
            };

            if (byte_offset % element_size != 0 or byte_length % element_size != 0) try self.throwDataCloneDeserializationError();

            //   bool is_length_tracking = false;
            //   bool is_backed_by_rab = false;
            //   if (!ValidateJSArrayBufferViewFlags(*buffer, flags, is_length_tracking, is_backed_by_rab)) {
            //     return MaybeHandle<JSArrayBufferView>();
            //   }

            var argv: [3]c.JSValue = undefined;
            argv[0] = ab_val;
            argv[1] = c.JS_NewUint32(self.ctx, byte_offset);
            argv[2] = c.JS_NewUint32(self.ctx, byte_length / element_size);
            defer c.JS_FreeValue(self.ctx, argv[1]);
            defer c.JS_FreeValue(self.ctx, argv[2]);
            const obj = if (array_type) |typed_array_type|
                c.JS_NewTypedArray(self.ctx, 3, &argv, typed_array_type)
            else blk: {
                const global = c.JS_GetGlobalObject(self.ctx);
                try exceptionCheck(global);
                defer c.JS_FreeValue(self.ctx, global);
                const constructor = c.JS_GetPropertyStr(self.ctx, global, "DataView");
                try exceptionCheck(constructor);
                defer c.JS_FreeValue(self.ctx, constructor);
                break :blk c.JS_CallConstructor(self.ctx, constructor, 3, &argv);
            };
            try exceptionCheck(obj);
            errdefer c.JS_FreeValue(self.ctx, obj);

            try self.addObjectWithID(id, obj);
            return obj;
        }

        fn readJSError(self: *Self) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            var tag: ErrorTag = @enumFromInt(try self.readVarint(u8));

            var error_name: [*:0]const u8 = "Error";
            switch (tag) {
                .eval_error_prototype => {
                    error_name = "EvalError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .range_error_prototype => {
                    error_name = "RangeError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .reference_error_prototype => {
                    error_name = "ReferenceError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .syntax_error_prototype => {
                    error_name = "SyntaxError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .type_error_prototype => {
                    error_name = "TypeError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .uri_error_prototype => {
                    error_name = "URIError";
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                else => {
                    error_name = "Error";
                },
            }

            var message: ?c.JSValue = null;
            if (tag == .message) {
                message = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (message) |x| c.JS_FreeValue(self.ctx, x);

            var stack: ?c.JSValue = null;
            if (tag == .stack) {
                stack = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (stack) |x| c.JS_FreeValue(self.ctx, x);

            const global = c.JS_GetGlobalObject(self.ctx);
            try exceptionCheck(global);
            defer c.JS_FreeValue(self.ctx, global);
            const error_constructor = c.JS_GetPropertyStr(self.ctx, global, error_name);
            try exceptionCheck(error_constructor);
            defer c.JS_FreeValue(self.ctx, error_constructor);
            const err_obj = c.JS_CallConstructor(self.ctx, error_constructor, 0, null);
            try exceptionCheck(err_obj);
            errdefer c.JS_FreeValue(self.ctx, err_obj);

            try self.addObjectWithID(id, err_obj);

            const no_enum = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE;

            if (stack) |x| {
                stack = null;
                if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "stack", x, no_enum) < 0) {
                    try self.throwDataCloneDeserializationError();
                }
            }
            if (message) |x| {
                message = null;
                if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "message", x, no_enum) < 0) {
                    try self.throwDataCloneDeserializationError();
                }
            }

            var cause: ?c.JSValue = null;
            if (tag == .cause) {
                cause = try self.readObject();
                const cause_value = cause.?;
                cause = null;
                if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "cause", cause_value, no_enum) < 0) {
                    try self.throwDataCloneDeserializationError();
                }
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (cause) |x| c.JS_FreeValue(self.ctx, x);

            if (tag != .end) try self.throwDataCloneDeserializationError();
            return err_obj;
        }

        fn readHostObject(self: *Self) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;
            const obj: c.JSValue = if (self.delegate) |del| try del.readHostObject(self.ctx) else return Error.NotImplemented;
            errdefer c.JS_FreeValue(self.ctx, obj);
            try self.addObjectWithID(id, obj);
            return obj;
        }

        fn hasObjectWithID(self: *Self, id: u32) bool {
            return self.id_map.contains(id);
        }

        fn getObjectWithID(self: *Self, id: u32) !c.JSValue {
            if (id >= self.id_map.count()) try self.throwDataCloneDeserializationError();
            const value = self.id_map.get(id);
            if (value == null or !c.JS_IsObject(value.?)) try self.throwDataCloneDeserializationError();
            return c.JS_DupValue(self.ctx, value.?);
        }

        fn addObjectWithID(self: *Self, id: u32, value: c.JSValue) !void {
            std.debug.assert(!self.hasObjectWithID(id));
            const retained = c.JS_DupValue(self.ctx, value);
            errdefer c.JS_FreeValue(self.ctx, retained);
            try self.id_map.put(self.ac, id, retained);
        }

        fn throwDataCloneDeserializationError(self: *Self) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, "Data clone deserialization error");
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, "Data clone deserialization error");
            }
            return Error.DataCloneDeserializationError;
        }

        fn throwDataCloneDeserializationVersionError(self: *Self) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, "Data clone deserialization version error");
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, "Data clone deserialization version error");
            }
            return Error.DataCloneDeserializationVersionError;
        }
    };
}

pub const DefaultSerializer = Serializer(DefaultDelegate);
pub const DefaultDeserializer = Deserializer(DefaultDelegate);
