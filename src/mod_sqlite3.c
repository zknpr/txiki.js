/*
 * txiki.js
 *
 * Copyright (c) 2023-present Saúl Ibarra Corretgé <s@saghul.net>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "private.h"

#include <math.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>


static JSClassID tjs_sqlite3_class_id;

typedef struct {
    sqlite3 *handle;
    uv_mutex_t mutex;
    uint64_t query_deadline_ns;
    unsigned int async_refs;
    bool closing;
} TJSSqlite3Handle;

static int tjs_sqlite3_progress_callback(void *opaque) {
    TJSSqlite3Handle *h = opaque;
    uint64_t deadline;

    uv_mutex_lock(&h->mutex);
    deadline = h->query_deadline_ns;
    uv_mutex_unlock(&h->mutex);

    return deadline != 0 && uv_hrtime() >= deadline;
}

static int tjs_sqlite3_close_locked(TJSSqlite3Handle *h) {
    sqlite3_progress_handler(h->handle, 0, NULL, NULL);
    h->query_deadline_ns = 0;

    int r = sqlite3_close_v2(h->handle);
    if (r == SQLITE_OK) {
        h->handle = NULL;
    }
    return r;
}

static void tjs_sqlite3_finalizer(JSRuntime *rt, JSValue val) {
    TJSSqlite3Handle *h = JS_GetOpaque(val, tjs_sqlite3_class_id);
    if (!h) {
        return;
    }
    /* Every async request owns handle_obj, so finalization implies there are
       no async_refs and it is safe to destroy the lifecycle mutex below. */
    uv_mutex_lock(&h->mutex);
    h->closing = true;
    if (h->handle && h->async_refs == 0) {
        tjs_sqlite3_close_locked(h);
    }
    uv_mutex_unlock(&h->mutex);
    uv_mutex_destroy(&h->mutex);
    js_free_rt(rt, h);
}

static JSClassDef tjs_sqlite3_class = {
    "Handle",
    .finalizer = tjs_sqlite3_finalizer,
};

static JSValue tjs_new_sqlite3(JSContext *ctx, sqlite3 *handle) {
    TJSSqlite3Handle *h;
    JSValue obj;

    obj = JS_NewObjectClass(ctx, tjs_sqlite3_class_id);
    if (JS_IsException(obj)) {
        return obj;
    }

    h = js_mallocz(ctx, sizeof(*h));
    if (!h) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }

    h->handle = handle;
    int r = uv_mutex_init(&h->mutex);
    if (r != 0) {
        js_free(ctx, h);
        JS_FreeValue(ctx, obj);
        return tjs_throw_errno(ctx, r);
    }

    JS_SetOpaque(obj, h);
    return obj;
}

static TJSSqlite3Handle *tjs_sqlite3_get(JSContext *ctx, JSValue obj) {
    return JS_GetOpaque2(ctx, obj, tjs_sqlite3_class_id);
}

static JSClassID tjs_sqlite3_stmt_class_id;

typedef struct {
    sqlite3_stmt *stmt;
} TJSSqlite3Stmt;

static void tjs_sqlite3_stmt_finalizer(JSRuntime *rt, JSValue val) {
    TJSSqlite3Stmt *h = JS_GetOpaque(val, tjs_sqlite3_stmt_class_id);
    if (!h) {
        return;
    }
    if (h->stmt) {
        sqlite3_reset(h->stmt);
        sqlite3_finalize(h->stmt);
    }
    js_free_rt(rt, h);
}

static JSClassDef tjs_sqlite3_stmt_class = {
    "Statement",
    .finalizer = tjs_sqlite3_stmt_finalizer,
};

static JSValue tjs_new_sqlite3_stmt(JSContext *ctx, sqlite3_stmt *stmt) {
    TJSSqlite3Stmt *h;
    JSValue obj;

    obj = JS_NewObjectClass(ctx, tjs_sqlite3_stmt_class_id);
    if (JS_IsException(obj)) {
        return obj;
    }

    h = js_mallocz(ctx, sizeof(*h));
    if (!h) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }

    h->stmt = stmt;

    JS_SetOpaque(obj, h);
    return obj;
}

static TJSSqlite3Stmt *tjs_sqlite3_stmt_get(JSContext *ctx, JSValue obj) {
    return JS_GetOpaque2(ctx, obj, tjs_sqlite3_stmt_class_id);
}

static JSValue tjs_new_sqlite3_error(JSContext *ctx, int err) {
    JSValue obj = JS_NewError(ctx);
    if (JS_IsException(obj)) {
        return obj;
    }

    if (JS_DefinePropertyValueStr(ctx,
                                  obj,
                                  "message",
                                  JS_NewString(ctx, sqlite3_errstr(err)),
                                  JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0 ||
        JS_DefinePropertyValueStr(ctx, obj, "errno", JS_NewInt32(ctx, err), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) <
            0) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    return obj;
}

JSValue tjs_throw_sqlite3_errno(JSContext *ctx, int err) {
    JSValue obj = tjs_new_sqlite3_error(ctx, err);
    if (JS_IsException(obj)) {
        return obj;
    }
    return JS_Throw(ctx, obj);
}

static JSValue tjs_sqlite3_open(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    const char *db_name = JS_ToCString(ctx, argv[0]);

    if (!db_name) {
        return JS_EXCEPTION;
    }

    int flags;
    if (JS_ToInt32(ctx, &flags, argv[1])) {
        JS_FreeCString(ctx, db_name);
        return JS_EXCEPTION;
    }

    sqlite3 *handle = NULL;
    int r = sqlite3_open_v2(db_name, &handle, flags, NULL);

    JS_FreeCString(ctx, db_name);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    // Enable sqlite extensions (but only via C calls)
    r = sqlite3_db_config(handle, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, NULL);
    if (r != SQLITE_OK) {
        sqlite3_close_v2(handle);
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    JSValue obj = tjs_new_sqlite3(ctx, handle);
    if (JS_IsException(obj)) {
        sqlite3_close_v2(handle);
    }

    return obj;
}

static JSValue tjs_sqlite3_close(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    uv_mutex_lock(&h->mutex);
    if (!h->handle) {
        uv_mutex_unlock(&h->mutex);
        return JS_UNDEFINED;
    }

    h->closing = true;
    if (h->async_refs != 0) {
        uv_mutex_unlock(&h->mutex);
        return JS_UNDEFINED;
    }

    int r = tjs_sqlite3_close_locked(h);
    uv_mutex_unlock(&h->mutex);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_interrupt(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) {
        return JS_EXCEPTION;
    }

    /* sqlite3_interrupt is thread-safe, but the handle must remain open until
       it returns. The same mutex gates close and deferred close. */
    uv_mutex_lock(&h->mutex);
    if (h->handle) {
        sqlite3_interrupt(h->handle);
    }
    uv_mutex_unlock(&h->mutex);

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_set_query_deadline(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) {
        return JS_EXCEPTION;
    }

    if (!JS_IsNumber(argv[1])) {
        return JS_ThrowTypeError(ctx, "Query deadline must be a number");
    }

    double ms;
    if (JS_ToFloat64(ctx, &ms, argv[1])) {
        return JS_EXCEPTION;
    }
    if (!isfinite(ms) || ms < 0) {
        return JS_ThrowRangeError(ctx, "Query deadline must be finite and nonnegative");
    }

    uint64_t now = uv_hrtime();
    uint64_t deadline;
    if (ms >= (double) (UINT64_MAX - now) / 1000000.0) {
        deadline = UINT64_MAX;
    } else {
        deadline = now + (uint64_t) (ms * 1000000.0);
        /* Zero is reserved for the disabled state. */
        if (deadline == 0) {
            deadline = 1;
        }
    }

    uv_mutex_lock(&h->mutex);
    if (!h->handle || h->closing) {
        uv_mutex_unlock(&h->mutex);
        return JS_ThrowInternalError(ctx, "Database is closed");
    }
    if (h->async_refs != 0) {
        uv_mutex_unlock(&h->mutex);
        return tjs_throw_sqlite3_errno(ctx, SQLITE_BUSY);
    }
    h->query_deadline_ns = deadline;
    sqlite3_progress_handler(h->handle, 1000, tjs_sqlite3_progress_callback, h);
    uv_mutex_unlock(&h->mutex);

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_clear_query_deadline(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) {
        return JS_EXCEPTION;
    }

    uv_mutex_lock(&h->mutex);
    if (!h->handle || h->closing) {
        uv_mutex_unlock(&h->mutex);
        return JS_ThrowInternalError(ctx, "Database is closed");
    }
    if (h->async_refs != 0) {
        uv_mutex_unlock(&h->mutex);
        return tjs_throw_sqlite3_errno(ctx, SQLITE_BUSY);
    }
    sqlite3_progress_handler(h->handle, 0, NULL, NULL);
    h->query_deadline_ns = 0;
    uv_mutex_unlock(&h->mutex);

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_load_extension(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *zFile = JS_ToCString(ctx, argv[1]);
    const char *zProc = JS_IsUndefined(argv[2]) ? NULL : JS_ToCString(ctx, argv[2]);

    if (!zFile) {
        return JS_EXCEPTION;
    }

    // zProc can be 0, it means "sqlite, do your best to quess it"

    int r = sqlite3_load_extension(h->handle, zFile, zProc, NULL);

    JS_FreeCString(ctx, zFile);
    if (zProc) {
        JS_FreeCString(ctx, zProc);
    }

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_exec(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *sql = JS_ToCString(ctx, argv[1]);

    if (!sql) {
        return JS_EXCEPTION;
    }

    int r = sqlite3_exec(h->handle, sql, NULL, NULL, NULL);

    JS_FreeCString(ctx, sql);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_prepare(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *sql = JS_ToCString(ctx, argv[1]);

    if (!sql) {
        return JS_EXCEPTION;
    }

    sqlite3_stmt *stmt = NULL;
    int r = sqlite3_prepare_v2(h->handle, sql, -1, &stmt, NULL);

    JS_FreeCString(ctx, sql);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    JSValue obj = tjs_new_sqlite3_stmt(ctx, stmt);
    if (JS_IsException(obj)) {
        sqlite3_finalize(stmt);
    }

    return obj;
}

static JSValue tjs_sqlite3_in_transaction(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    return JS_NewBool(ctx, !sqlite3_get_autocommit(h->handle));
}

static JSValue tjs_sqlite3_stmt_finalize(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_UNDEFINED;
    }

    int reset_r = sqlite3_reset(h->stmt);
    int finalize_r = sqlite3_finalize(h->stmt);
    h->stmt = NULL;

    if (reset_r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, reset_r);
    }

    int r = finalize_r;
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_stmt_expand(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_NewString(ctx, "");
    }

    char *sql = sqlite3_expanded_sql(h->stmt);
    if (sql == NULL) {
        return JS_ThrowOutOfMemory(ctx);
    }

    return JS_NewString(ctx, sql);
}

static JSValue tjs__stmt2obj(JSContext *ctx, TJSSqlite3Stmt *h) {
    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
    int count = sqlite3_column_count(h->stmt);

    for (int i = 0; i < count; i++) {
        const char *name = sqlite3_column_name(h->stmt, i);
        JSValue value;

        switch (sqlite3_column_type(h->stmt, i)) {
            case SQLITE_INTEGER: {
                value = JS_NewInt64(ctx, sqlite3_column_int64(h->stmt, i));
                break;
            }
            case SQLITE_FLOAT: {
                value = JS_NewFloat64(ctx, sqlite3_column_double(h->stmt, i));
                break;
            }
            case SQLITE3_TEXT: {
                value = JS_NewString(ctx, (const char *) sqlite3_column_text(h->stmt, i));
                break;
            }
            case SQLITE_BLOB: {
                value = JS_NewUint8ArrayCopy(ctx,
                                             (uint8_t *) sqlite3_column_blob(h->stmt, i),
                                             sqlite3_column_bytes(h->stmt, i));
                break;
            }
            default: {
                value = JS_NULL;
                break;
            }
        }

        JS_DefinePropertyValueStr(ctx, obj, name, value, JS_PROP_C_W_E);
    }

    return obj;
}

static JSValue tjs__sqlite3_bind_param(JSContext *ctx, sqlite3_stmt *stmt, int idx, JSValue v) {
    int r;

#define CHECK_VALUE(ret, i)                                                                                            \
    if (ret == -1) {                                                                                                   \
        return JS_ThrowTypeError(ctx, "Failed to convert type at position %d", idx);                                   \
    }

#define CHECK_RET(ret)                                                                                                 \
    if (r != SQLITE_OK) {                                                                                              \
        return tjs_throw_sqlite3_errno(ctx, ret);                                                                      \
    }

    switch (JS_VALUE_GET_NORM_TAG(v)) {
        case JS_TAG_BIG_INT: {
            int64_t x;
            r = JS_ToBigInt64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_int64(stmt, idx, x);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_STRING: {
            size_t len;
            const char *x = JS_ToCStringLen(ctx, &len, v);
            if (!x) {
                return JS_EXCEPTION;
            }
            r = sqlite3_bind_text(stmt, idx, x, len, SQLITE_TRANSIENT);
            JS_FreeCString(ctx, x);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_OBJECT: {
            size_t len = 0;
            uint8_t *x = JS_GetUint8Array(ctx, &len, v);
            if (!x) {
                return JS_EXCEPTION;
            }
            r = sqlite3_bind_blob(stmt, idx, x, len, SQLITE_TRANSIENT);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_INT: {
            int64_t x;
            r = JS_ToInt64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            if (x < INT_MIN || x > INT_MAX) {
                r = sqlite3_bind_int64(stmt, idx, x);
            } else {
                r = sqlite3_bind_int(stmt, idx, x);
            }
            CHECK_RET(r);
            break;
        }
        case JS_TAG_BOOL: {
            r = JS_ToBool(ctx, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_int(stmt, idx, r);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_NULL: {
            r = sqlite3_bind_null(stmt, idx);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_FLOAT64: {
            double x;
            r = JS_ToFloat64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_double(stmt, idx, x);
            CHECK_RET(r);
            break;
        }
        default:
            return JS_ThrowTypeError(ctx, "Invalid bound parameter type at position %d", idx);
    }

    return JS_UNDEFINED;

#undef CHECK_VALUE
#undef CHECK_RET
}

static JSValue tjs__sqlite3_bind_params(JSContext *ctx, sqlite3_stmt *stmt, JSValue params) {
    sqlite3_clear_bindings(stmt);

    if (JS_IsArray(params)) {
        JSValue js_length = JS_GetPropertyStr(ctx, params, "length");
        uint64_t len;
        if (JS_ToIndex(ctx, &len, js_length)) {
            JS_FreeValue(ctx, js_length);
            return JS_EXCEPTION;
        }
        JS_FreeValue(ctx, js_length);
        for (int i = 0; i < len; i++) {
            JSValue v = JS_GetPropertyUint32(ctx, params, i);
            if (JS_IsException(v)) {
                return v;
            }
            bool is_exception = JS_IsException(tjs__sqlite3_bind_param(ctx, stmt, i + 1, v));
            JS_FreeValue(ctx, v);
            if (is_exception) {
                return JS_EXCEPTION;
            }
        }
    } else if (JS_IsObject(params)) {
        JSPropertyEnum *ptab;
        uint32_t plen;
        if (JS_GetOwnPropertyNames(ctx, &ptab, &plen, params, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)) {
            return JS_EXCEPTION;
        }
        for (int i = 0; i < plen; i++) {
            JSAtom patom = ptab[i].atom;
            JSValue prop = JS_GetProperty(ctx, params, patom);
            if (JS_IsException(prop)) {
                JS_FreePropertyEnum(ctx, ptab, plen);
                return JS_EXCEPTION;
            }
            const char *key = JS_AtomToCString(ctx, patom);
            int idx = sqlite3_bind_parameter_index(stmt, key);
            if (idx == 0 || JS_IsException(tjs__sqlite3_bind_param(ctx, stmt, idx, prop))) {
                if (idx == 0) {
                    JS_ThrowReferenceError(ctx, "Could not find parameter '%s'", key);
                }
                JS_FreeValue(ctx, prop);
                JS_FreeCString(ctx, key);
                JS_FreePropertyEnum(ctx, ptab, plen);
                return JS_EXCEPTION;
            }
            JS_FreeValue(ctx, prop);
            JS_FreeCString(ctx, key);
        }
        JS_FreePropertyEnum(ctx, ptab, plen);
    } else {
        return JS_ThrowTypeError(ctx, "Invalid bind parameters type: expected object or array");
    }

    return JS_UNDEFINED;
}

typedef enum {
    TJS_SQLITE3_VALUE_NULL,
    TJS_SQLITE3_VALUE_INTEGER,
    TJS_SQLITE3_VALUE_FLOAT,
    TJS_SQLITE3_VALUE_TEXT,
    TJS_SQLITE3_VALUE_BLOB,
} TJSSqlite3ValueType;

typedef struct {
    TJSSqlite3ValueType type;
    char *name;
    union {
        int64_t integer;
        double number;
        struct {
            uint8_t *data;
            int length;
        } bytes;
    } value;
} TJSSqlite3RawValue;

typedef struct {
    TJSSqlite3RawValue *values;
} TJSSqlite3RawRow;

typedef struct {
    uv_work_t req;
    JSContext *ctx;
    TJSPromise result;
    TJSSqlite3Handle *owner;
    sqlite3 *handle;
    JSValue handle_obj;
    char *sql;
    TJSSqlite3RawValue *params;
    size_t param_count;
    bool named_params;
    bool all;
    int r;
    char **column_names;
    int column_count;
    TJSSqlite3RawRow *rows;
    size_t row_count;
    size_t row_capacity;
} TJSSqlite3AsyncReq;

static void tjs_sqlite3_raw_value_free(TJSSqlite3RawValue *value) {
    free(value->name);
    if (value->type == TJS_SQLITE3_VALUE_TEXT || value->type == TJS_SQLITE3_VALUE_BLOB) {
        free(value->value.bytes.data);
    }
}

static void tjs_sqlite3_raw_values_free(TJSSqlite3RawValue *values, size_t count) {
    if (!values) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        tjs_sqlite3_raw_value_free(&values[i]);
    }
    free(values);
}

static void tjs_sqlite3_async_req_free(TJSSqlite3AsyncReq *ar) {
    free(ar->sql);
    tjs_sqlite3_raw_values_free(ar->params, ar->param_count);
    if (ar->column_names) {
        for (int i = 0; i < ar->column_count; i++) {
            free(ar->column_names[i]);
        }
        free(ar->column_names);
    }
    if (ar->rows) {
        for (size_t i = 0; i < ar->row_count; i++) {
            tjs_sqlite3_raw_values_free(ar->rows[i].values, ar->column_count);
        }
        free(ar->rows);
    }
    free(ar);
}

static void *tjs_sqlite3_raw_copy(const void *data, size_t length, bool terminate) {
    if (length > SIZE_MAX - (terminate ? 1 : 0)) {
        return NULL;
    }

    size_t allocation = length + (terminate ? 1 : 0);
    if (allocation == 0) {
        return NULL;
    }

    uint8_t *copy = malloc(allocation);
    if (!copy) {
        return NULL;
    }
    if (length != 0) {
        memcpy(copy, data, length);
    }
    if (terminate) {
        copy[length] = '\0';
    }
    return copy;
}

static int tjs_sqlite3_serialize_value(JSContext *ctx, TJSSqlite3RawValue *result, JSValue value, int position) {
    int r;

    switch (JS_VALUE_GET_NORM_TAG(value)) {
        case JS_TAG_BIG_INT:
            r = JS_ToBigInt64(ctx, &result->value.integer, value);
            if (r < 0) {
                return -1;
            }
            result->type = TJS_SQLITE3_VALUE_INTEGER;
            break;
        case JS_TAG_STRING: {
            size_t length;
            const char *text = JS_ToCStringLen(ctx, &length, value);
            if (!text) {
                return -1;
            }
            if (length > INT_MAX) {
                JS_FreeCString(ctx, text);
                JS_ThrowRangeError(ctx, "Bound string at position %d is too large", position);
                return -1;
            }
            result->value.bytes.data = tjs_sqlite3_raw_copy(text, length, true);
            JS_FreeCString(ctx, text);
            if (!result->value.bytes.data) {
                JS_ThrowOutOfMemory(ctx);
                return -1;
            }
            result->value.bytes.length = (int) length;
            result->type = TJS_SQLITE3_VALUE_TEXT;
            break;
        }
        case JS_TAG_OBJECT: {
            size_t length;
            uint8_t *blob = JS_GetUint8Array(ctx, &length, value);
            if (!blob) {
                return -1;
            }
            if (length > INT_MAX) {
                JS_ThrowRangeError(ctx, "Bound blob at position %d is too large", position);
                return -1;
            }
            if (length != 0) {
                result->value.bytes.data = tjs_sqlite3_raw_copy(blob, length, false);
                if (!result->value.bytes.data) {
                    JS_ThrowOutOfMemory(ctx);
                    return -1;
                }
            }
            result->value.bytes.length = (int) length;
            result->type = TJS_SQLITE3_VALUE_BLOB;
            break;
        }
        case JS_TAG_INT:
            r = JS_ToInt64(ctx, &result->value.integer, value);
            if (r < 0) {
                return -1;
            }
            result->type = TJS_SQLITE3_VALUE_INTEGER;
            break;
        case JS_TAG_BOOL:
            r = JS_ToBool(ctx, value);
            if (r < 0) {
                return -1;
            }
            result->value.integer = r;
            result->type = TJS_SQLITE3_VALUE_INTEGER;
            break;
        case JS_TAG_NULL:
            result->type = TJS_SQLITE3_VALUE_NULL;
            break;
        case JS_TAG_FLOAT64:
            r = JS_ToFloat64(ctx, &result->value.number, value);
            if (r < 0) {
                return -1;
            }
            result->type = TJS_SQLITE3_VALUE_FLOAT;
            break;
        default:
            JS_ThrowTypeError(ctx, "Invalid bound parameter type at position %d", position);
            return -1;
    }

    return 0;
}

static int tjs_sqlite3_serialize_params(JSContext *ctx,
                                        JSValue params,
                                        TJSSqlite3RawValue **result,
                                        size_t *result_count,
                                        bool *named) {
    *result = NULL;
    *result_count = 0;
    *named = false;

    if (JS_IsUndefined(params)) {
        return 0;
    }

    int is_array = JS_IsArray(params);
    if (is_array < 0) {
        return -1;
    }
    if (is_array) {
        JSValue js_length = JS_GetPropertyStr(ctx, params, "length");
        uint64_t length;
        if (JS_IsException(js_length) || JS_ToIndex(ctx, &length, js_length)) {
            JS_FreeValue(ctx, js_length);
            return -1;
        }
        JS_FreeValue(ctx, js_length);
        if (length > INT_MAX) {
            JS_ThrowRangeError(ctx, "Too many bound parameters");
            return -1;
        }

        TJSSqlite3RawValue *values = calloc((size_t) length, sizeof(*values));
        if (length != 0 && !values) {
            JS_ThrowOutOfMemory(ctx);
            return -1;
        }
        for (uint64_t i = 0; i < length; i++) {
            JSValue value = JS_GetPropertyUint32(ctx, params, (uint32_t) i);
            if (JS_IsException(value) || tjs_sqlite3_serialize_value(ctx, &values[i], value, (int) i + 1) < 0) {
                JS_FreeValue(ctx, value);
                tjs_sqlite3_raw_values_free(values, (size_t) length);
                return -1;
            }
            JS_FreeValue(ctx, value);
        }
        *result = values;
        *result_count = (size_t) length;
        return 0;
    }

    if (!JS_IsObject(params)) {
        JS_ThrowTypeError(ctx, "Invalid bind parameters type: expected object or array");
        return -1;
    }

    JSPropertyEnum *properties;
    uint32_t property_count;
    if (JS_GetOwnPropertyNames(ctx, &properties, &property_count, params, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)) {
        return -1;
    }

    TJSSqlite3RawValue *values = calloc(property_count, sizeof(*values));
    if (property_count != 0 && !values) {
        JS_FreePropertyEnum(ctx, properties, property_count);
        JS_ThrowOutOfMemory(ctx);
        return -1;
    }
    for (uint32_t i = 0; i < property_count; i++) {
        JSValue value = JS_GetProperty(ctx, params, properties[i].atom);
        const char *name = NULL;
        if (!JS_IsException(value)) {
            name = JS_AtomToCString(ctx, properties[i].atom);
        }
        if (JS_IsException(value) || !name) {
            JS_FreeValue(ctx, value);
            tjs_sqlite3_raw_values_free(values, property_count);
            JS_FreePropertyEnum(ctx, properties, property_count);
            return -1;
        }

        size_t name_length = strlen(name);
        values[i].name = tjs_sqlite3_raw_copy(name, name_length, true);
        JS_FreeCString(ctx, name);
        if (!values[i].name) {
            JS_FreeValue(ctx, value);
            tjs_sqlite3_raw_values_free(values, property_count);
            JS_FreePropertyEnum(ctx, properties, property_count);
            JS_ThrowOutOfMemory(ctx);
            return -1;
        }
        if (tjs_sqlite3_serialize_value(ctx, &values[i], value, (int) i + 1) < 0) {
            JS_FreeValue(ctx, value);
            tjs_sqlite3_raw_values_free(values, property_count);
            JS_FreePropertyEnum(ctx, properties, property_count);
            return -1;
        }
        JS_FreeValue(ctx, value);
    }
    JS_FreePropertyEnum(ctx, properties, property_count);

    *result = values;
    *result_count = property_count;
    *named = true;
    return 0;
}

static int tjs_sqlite3_bind_raw_value(sqlite3_stmt *stmt, int index, const TJSSqlite3RawValue *value) {
    switch (value->type) {
        case TJS_SQLITE3_VALUE_NULL:
            return sqlite3_bind_null(stmt, index);
        case TJS_SQLITE3_VALUE_INTEGER:
            return sqlite3_bind_int64(stmt, index, value->value.integer);
        case TJS_SQLITE3_VALUE_FLOAT:
            return sqlite3_bind_double(stmt, index, value->value.number);
        case TJS_SQLITE3_VALUE_TEXT:
            return sqlite3_bind_text(stmt,
                                     index,
                                     (const char *) value->value.bytes.data,
                                     value->value.bytes.length,
                                     SQLITE_STATIC);
        case TJS_SQLITE3_VALUE_BLOB:
            if (value->value.bytes.length == 0) {
                return sqlite3_bind_zeroblob(stmt, index, 0);
            }
            return sqlite3_bind_blob(stmt, index, value->value.bytes.data, value->value.bytes.length, SQLITE_STATIC);
    }
    return SQLITE_MISUSE;
}

static int tjs_sqlite3_async_bind(TJSSqlite3AsyncReq *ar, sqlite3_stmt *stmt) {
    for (size_t i = 0; i < ar->param_count; i++) {
        int index = ar->named_params ? sqlite3_bind_parameter_index(stmt, ar->params[i].name) : (int) i + 1;
        if (index == 0) {
            return SQLITE_RANGE;
        }
        int r = tjs_sqlite3_bind_raw_value(stmt, index, &ar->params[i]);
        if (r != SQLITE_OK) {
            return r;
        }
    }
    return SQLITE_OK;
}

static int tjs_sqlite3_async_copy_columns(TJSSqlite3AsyncReq *ar, sqlite3_stmt *stmt) {
    ar->column_count = sqlite3_column_count(stmt);
    if (ar->column_count == 0) {
        return SQLITE_OK;
    }

    ar->column_names = calloc((size_t) ar->column_count, sizeof(*ar->column_names));
    if (!ar->column_names) {
        return SQLITE_NOMEM;
    }
    for (int i = 0; i < ar->column_count; i++) {
        const char *name = sqlite3_column_name(stmt, i);
        if (!name) {
            return SQLITE_NOMEM;
        }
        ar->column_names[i] = tjs_sqlite3_raw_copy(name, strlen(name), true);
        if (!ar->column_names[i]) {
            return SQLITE_NOMEM;
        }
    }
    return SQLITE_OK;
}

static int tjs_sqlite3_async_copy_row(TJSSqlite3AsyncReq *ar, sqlite3_stmt *stmt) {
    if (ar->row_count == ar->row_capacity) {
        size_t capacity = ar->row_capacity == 0 ? 8 : ar->row_capacity * 2;
        if (capacity < ar->row_capacity || capacity > SIZE_MAX / sizeof(*ar->rows)) {
            return SQLITE_NOMEM;
        }
        TJSSqlite3RawRow *rows = realloc(ar->rows, capacity * sizeof(*rows));
        if (!rows) {
            return SQLITE_NOMEM;
        }
        ar->rows = rows;
        ar->row_capacity = capacity;
    }

    TJSSqlite3RawValue *values = calloc((size_t) ar->column_count, sizeof(*values));
    if (ar->column_count != 0 && !values) {
        return SQLITE_NOMEM;
    }
    for (int i = 0; i < ar->column_count; i++) {
        int length;
        switch (sqlite3_column_type(stmt, i)) {
            case SQLITE_INTEGER:
                values[i].type = TJS_SQLITE3_VALUE_INTEGER;
                values[i].value.integer = sqlite3_column_int64(stmt, i);
                break;
            case SQLITE_FLOAT:
                values[i].type = TJS_SQLITE3_VALUE_FLOAT;
                values[i].value.number = sqlite3_column_double(stmt, i);
                break;
            case SQLITE3_TEXT: {
                const uint8_t *text = sqlite3_column_text(stmt, i);
                length = sqlite3_column_bytes(stmt, i);
                if (!text && length != 0) {
                    tjs_sqlite3_raw_values_free(values, ar->column_count);
                    return SQLITE_NOMEM;
                }
                values[i].type = TJS_SQLITE3_VALUE_TEXT;
                values[i].value.bytes.length = length;
                values[i].value.bytes.data = tjs_sqlite3_raw_copy(text, (size_t) length, true);
                if (!values[i].value.bytes.data) {
                    tjs_sqlite3_raw_values_free(values, ar->column_count);
                    return SQLITE_NOMEM;
                }
                break;
            }
            case SQLITE_BLOB: {
                const void *blob = sqlite3_column_blob(stmt, i);
                length = sqlite3_column_bytes(stmt, i);
                if (!blob && length != 0) {
                    tjs_sqlite3_raw_values_free(values, ar->column_count);
                    return SQLITE_NOMEM;
                }
                values[i].type = TJS_SQLITE3_VALUE_BLOB;
                values[i].value.bytes.length = length;
                if (length != 0) {
                    values[i].value.bytes.data = tjs_sqlite3_raw_copy(blob, (size_t) length, false);
                    if (!values[i].value.bytes.data) {
                        tjs_sqlite3_raw_values_free(values, ar->column_count);
                        return SQLITE_NOMEM;
                    }
                }
                break;
            }
            default:
                values[i].type = TJS_SQLITE3_VALUE_NULL;
                break;
        }
    }

    ar->rows[ar->row_count].values = values;
    ar->row_count++;
    return SQLITE_OK;
}

static void tjs_sqlite3_async_work(uv_work_t *req) {
    TJSSqlite3AsyncReq *ar = req->data;
    sqlite3_stmt *stmt = NULL;

    ar->r = sqlite3_prepare_v2(ar->handle, ar->sql, -1, &stmt, NULL);
    if (ar->r == SQLITE_OK) {
        ar->r = tjs_sqlite3_async_bind(ar, stmt);
    }

    if (ar->r == SQLITE_OK && ar->all) {
        ar->r = tjs_sqlite3_async_copy_columns(ar, stmt);
        while (ar->r == SQLITE_OK) {
            int step_r = sqlite3_step(stmt);
            if (step_r == SQLITE_ROW) {
                ar->r = tjs_sqlite3_async_copy_row(ar, stmt);
            } else if (step_r == SQLITE_DONE) {
                break;
            } else {
                ar->r = step_r;
            }
        }
    } else if (ar->r == SQLITE_OK) {
        int step_r = sqlite3_step(stmt);
        if (step_r != SQLITE_DONE && step_r != SQLITE_ROW) {
            ar->r = step_r;
        }
    }

    if (stmt) {
        int finalize_r = sqlite3_finalize(stmt);
        if (ar->r == SQLITE_OK && finalize_r != SQLITE_OK) {
            ar->r = finalize_r;
        }
    }
}

static JSValue tjs_sqlite3_async_rows_to_js(JSContext *ctx, const TJSSqlite3AsyncReq *ar) {
    JSValue result = JS_NewArray(ctx);
    if (JS_IsException(result)) {
        return result;
    }

    for (size_t row_index = 0; row_index < ar->row_count; row_index++) {
        if (row_index > UINT32_MAX) {
            JS_FreeValue(ctx, result);
            return JS_ThrowRangeError(ctx, "SQLite result has too many rows");
        }

        JSValue object = JS_NewObjectProto(ctx, JS_NULL);
        if (JS_IsException(object)) {
            JS_FreeValue(ctx, result);
            return object;
        }
        for (int column = 0; column < ar->column_count; column++) {
            const TJSSqlite3RawValue *raw = &ar->rows[row_index].values[column];
            JSValue value;
            switch (raw->type) {
                case TJS_SQLITE3_VALUE_NULL:
                    value = JS_NULL;
                    break;
                case TJS_SQLITE3_VALUE_INTEGER:
                    value = JS_NewInt64(ctx, raw->value.integer);
                    break;
                case TJS_SQLITE3_VALUE_FLOAT:
                    value = JS_NewFloat64(ctx, raw->value.number);
                    break;
                case TJS_SQLITE3_VALUE_TEXT:
                    value =
                        JS_NewStringLen(ctx, (const char *) raw->value.bytes.data, (size_t) raw->value.bytes.length);
                    break;
                case TJS_SQLITE3_VALUE_BLOB:
                    value = JS_NewUint8ArrayCopy(ctx, raw->value.bytes.data, (size_t) raw->value.bytes.length);
                    break;
            }
            if (JS_IsException(value) ||
                JS_DefinePropertyValueStr(ctx, object, ar->column_names[column], value, JS_PROP_C_W_E) < 0) {
                JS_FreeValue(ctx, object);
                JS_FreeValue(ctx, result);
                return JS_EXCEPTION;
            }
        }
        if (JS_DefinePropertyValueUint32(ctx, result, (uint32_t) row_index, object, JS_PROP_C_W_E) < 0) {
            JS_FreeValue(ctx, result);
            return JS_EXCEPTION;
        }
    }

    return result;
}

static void tjs_sqlite3_release_async(TJSSqlite3Handle *h) {
    uv_mutex_lock(&h->mutex);
    h->async_refs--;
    if (h->closing && h->async_refs == 0 && h->handle) {
        tjs_sqlite3_close_locked(h);
    }
    uv_mutex_unlock(&h->mutex);
}

static void tjs_sqlite3_async_after_work(uv_work_t *req, int status) {
    TJSSqlite3AsyncReq *ar = req->data;
    JSContext *ctx = ar->ctx;
    JSValue arg;
    bool reject = false;

    if (status != 0) {
        arg = tjs_new_error(ctx, status);
        reject = true;
    } else if (ar->r != SQLITE_OK) {
        arg = tjs_new_sqlite3_error(ctx, ar->r);
        reject = true;
    } else if (ar->all) {
        arg = tjs_sqlite3_async_rows_to_js(ctx, ar);
    } else {
        arg = JS_UNDEFINED;
    }
    if (JS_IsException(arg)) {
        arg = JS_GetException(ctx);
        reject = true;
    }

    TJS_SettlePromise(ctx, &ar->result, reject, arg);

    TJSSqlite3Handle *owner = ar->owner;
    JSValue handle_obj = ar->handle_obj;
    tjs_sqlite3_async_req_free(ar);
    tjs_sqlite3_release_async(owner);
    JS_FreeValue(ctx, handle_obj);
}

static void tjs_sqlite3_clear_promise(JSContext *ctx, TJSPromise *promise) {
    JS_FreeValue(ctx, promise->rfuncs[0]);
    JS_FreeValue(ctx, promise->rfuncs[1]);
    JS_FreeValue(ctx, promise->p);
    TJS_ClearPromise(ctx, promise);
}

static JSValue tjs_sqlite3_async_operation(JSContext *ctx, JSValue this_val, int argc, JSValue *argv, bool all) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) {
        return JS_EXCEPTION;
    }

    size_t sql_length;
    const char *sql = JS_ToCStringLen(ctx, &sql_length, argv[1]);
    if (!sql) {
        return JS_EXCEPTION;
    }

    TJSSqlite3AsyncReq *ar = calloc(1, sizeof(*ar));
    if (!ar) {
        JS_FreeCString(ctx, sql);
        return JS_ThrowOutOfMemory(ctx);
    }
    ar->sql = tjs_sqlite3_raw_copy(sql, sql_length, true);
    JS_FreeCString(ctx, sql);
    if (!ar->sql) {
        tjs_sqlite3_async_req_free(ar);
        return JS_ThrowOutOfMemory(ctx);
    }

    JSValue params = argc >= 3 ? argv[2] : JS_UNDEFINED;
    if (tjs_sqlite3_serialize_params(ctx, params, &ar->params, &ar->param_count, &ar->named_params) < 0) {
        tjs_sqlite3_async_req_free(ar);
        return JS_EXCEPTION;
    }

    uv_mutex_lock(&h->mutex);
    if (!h->handle || h->closing) {
        uv_mutex_unlock(&h->mutex);
        tjs_sqlite3_async_req_free(ar);
        return JS_ThrowInternalError(ctx, "Database is closed");
    }
    h->async_refs++;
    ar->handle = h->handle;
    uv_mutex_unlock(&h->mutex);

    ar->ctx = ctx;
    ar->owner = h;
    ar->handle_obj = JS_DupValue(ctx, argv[0]);
    ar->all = all;
    ar->r = SQLITE_OK;
    ar->req.data = ar;

    JSValue promise = TJS_InitPromise(ctx, &ar->result);
    if (JS_IsException(promise)) {
        tjs_sqlite3_release_async(h);
        JS_FreeValue(ctx, ar->handle_obj);
        tjs_sqlite3_async_req_free(ar);
        return promise;
    }

    int r = uv_queue_work(tjs_get_loop(ctx), &ar->req, tjs_sqlite3_async_work, tjs_sqlite3_async_after_work);
    if (r != 0) {
        JS_FreeValue(ctx, promise);
        tjs_sqlite3_clear_promise(ctx, &ar->result);
        tjs_sqlite3_release_async(h);
        JS_FreeValue(ctx, ar->handle_obj);
        tjs_sqlite3_async_req_free(ar);
        return tjs_throw_errno(ctx, r);
    }

    return promise;
}

static JSValue tjs_sqlite3_async_run(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    return tjs_sqlite3_async_operation(ctx, this_val, argc, argv, false);
}

static JSValue tjs_sqlite3_async_all(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    return tjs_sqlite3_async_operation(ctx, this_val, argc, argv, true);
}

static JSValue tjs_sqlite3_stmt_all(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_ThrowInternalError(ctx, "Statement has been finalized");
    }

    int r = sqlite3_reset(h->stmt);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    if (argc == 2) {
        JSValue params = argv[1];

        if (JS_IsException(tjs__sqlite3_bind_params(ctx, h->stmt, params))) {
            return JS_EXCEPTION;
        }
    }

    JSValue result = JS_NewArray(ctx);
    uint32_t i = 0;

    while ((r = sqlite3_step(h->stmt)) == SQLITE_ROW) {
        JS_DefinePropertyValueUint32(ctx, result, i, tjs__stmt2obj(ctx, h), JS_PROP_C_W_E);
        i++;
    }

    if (r != SQLITE_OK && r != SQLITE_DONE) {
        JS_FreeValue(ctx, result);
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return result;
}

static JSValue tjs_sqlite3_stmt_run(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_ThrowInternalError(ctx, "Statement has been finalized");
    }

    int r = sqlite3_reset(h->stmt);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    if (argc == 2) {
        JSValue params = argv[1];

        if (JS_IsException(tjs__sqlite3_bind_params(ctx, h->stmt, params))) {
            return JS_EXCEPTION;
        }
    }

    r = sqlite3_step(h->stmt);
    if (r != SQLITE_OK && r != SQLITE_DONE && r != SQLITE_ROW) {
        return tjs_throw_sqlite3_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static const JSCFunctionListEntry tjs_sqlite3_funcs[] = {
    TJS_CFUNC_DEF("open", 2, tjs_sqlite3_open),
    TJS_CFUNC_DEF("load_extension", 3, tjs_sqlite3_load_extension),
    TJS_CFUNC_DEF("close", 1, tjs_sqlite3_close),
    TJS_CFUNC_DEF("interrupt", 1, tjs_sqlite3_interrupt),
    TJS_CFUNC_DEF("set_query_deadline", 2, tjs_sqlite3_set_query_deadline),
    TJS_CFUNC_DEF("clear_query_deadline", 1, tjs_sqlite3_clear_query_deadline),
    TJS_CFUNC_DEF("async_run", 3, tjs_sqlite3_async_run),
    TJS_CFUNC_DEF("async_all", 3, tjs_sqlite3_async_all),
    TJS_CFUNC_DEF("exec", 2, tjs_sqlite3_exec),
    TJS_CFUNC_DEF("prepare", 2, tjs_sqlite3_prepare),
    TJS_CFUNC_DEF("in_transaction", 1, tjs_sqlite3_in_transaction),
    TJS_CFUNC_DEF("stmt_finalize", 1, tjs_sqlite3_stmt_finalize),
    TJS_CFUNC_DEF("stmt_expand", 1, tjs_sqlite3_stmt_expand),
    TJS_CFUNC_DEF("stmt_all", 2, tjs_sqlite3_stmt_all),
    TJS_CFUNC_DEF("stmt_run", 2, tjs_sqlite3_stmt_run),
    TJS_CONST(SQLITE_OPEN_CREATE),
    TJS_CONST(SQLITE_OPEN_READONLY),
    TJS_CONST(SQLITE_OPEN_READWRITE),
};

void tjs__mod_sqlite3_init(JSContext *ctx, JSValue ns) {
    JSRuntime *rt = JS_GetRuntime(ctx);

    /* Handle object */
    JS_NewClassID(rt, &tjs_sqlite3_class_id);
    JS_NewClass(rt, tjs_sqlite3_class_id, &tjs_sqlite3_class);
    JS_SetClassProto(ctx, tjs_sqlite3_class_id, JS_NULL);

    /* Statement object */
    JS_NewClassID(rt, &tjs_sqlite3_stmt_class_id);
    JS_NewClass(rt, tjs_sqlite3_stmt_class_id, &tjs_sqlite3_stmt_class);
    JS_SetClassProto(ctx, tjs_sqlite3_stmt_class_id, JS_NULL);

    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
    JS_SetPropertyFunctionList(ctx, obj, tjs_sqlite3_funcs, countof(tjs_sqlite3_funcs));

    JS_DefinePropertyValueStr(ctx, ns, "sqlite3", obj, JS_PROP_C_W_E);
}
