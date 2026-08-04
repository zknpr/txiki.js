# V8 Serializer Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce public-QuickJS-API serialization time for 100,000 same-shape SQLite-style rows to at most the 59 ms incumbent result while preserving canonical V8 bytes and all lifetime defenses.

**Architecture:** Keep the existing public QuickJS boundary and V8 wire format. Establish a deterministic fork-local benchmark, instrument the serializer by phase, and retain only individually measured changes. Optimize repeated row objects with a bounded per-serializer property cache and optimize low-level writes only when the profile shows measurable cost.

**Tech Stack:** Zig 0.16.0, QuickJS-ng public C API, txiki.js stdlib, CMake, JavaScript benchmark scripts.

## Global Constraints

- Write only inside `/Users/zero/dev/txiki.js-fork`; do not probe the sandbox boundary.
- Do not use git-mutating commands.
- Use public QuickJS APIs only; do not dereference private QuickJS structures.
- Preserve the native-owned deserializer copy and detachment/lifetime protections.
- Preserve canonical Node/V8 output bytes and all existing behavior.
- Keep `-Wall -Werror` and cross-target Zig 0.16 compatibility.
- Measure one optimization lever at a time and discard changes that do not pay.

---

### Task 1: Deterministic benchmark and untouched baseline

**Files:**
- Create: `bench/bench-v8.js`
- Test: `tests/test-v8.js`

**Interfaces:**
- Consumes: public `serialize` and `deserialize` exports from `tjs:v8`.
- Produces: a deterministic 100,000-row mixed-value workload and machine-readable timing/size output.

- [x] **Step 1: Add the benchmark before serializer changes**

```js
const rows = buildRows(100_000);
const encoded = serialize(rows);
const decoded = deserialize(encoded);
console.log(JSON.stringify({ rows: rows.length, bytes: encoded.byteLength, serializeMs, deserializeMs }));
```

Use identical property insertion order for every row, include int32 values, doubles, Latin-1 strings, int64-range BigInts, and Uint8Array blobs, validate representative decoded values, warm up on a smaller payload, and report full-payload timings separately.

- [x] **Step 2: Run the untouched Release build benchmark**

Run:

```sh
cmake --build build -j 12
./build/tjs run bench/bench-v8.js
```

Record all iterations, output byte length, median serialization time, and median deserialization time before changing `src/v8_serialize.zig`.

### Task 2: Profile the serializer by phase

**Files:**
- Temporarily modify and then restore: `src/v8_serialize.zig`
- Temporarily modify and then restore: `src/tjs_qjs_allocator.zig`

**Interfaces:**
- Consumes: the deterministic benchmark from Task 1.
- Produces: measured attribution for enumeration/atoms, key encoding, value-string encoding, tags/varints, output growth/copies, identity-map work, and temporary allocations.

- [x] **Step 1: Add temporary profile counters around actual boundaries**

```zig
const Profile = struct {
    enumeration_ns: u64 = 0,
    key_string_ns: u64 = 0,
    value_string_ns: u64 = 0,
    identity_ns: u64 = 0,
    output_growth_ns: u64 = 0,
    tag_varint_ns: u64 = 0,
    allocation_count: u64 = 0,
};
```

Collect call counts and bytes together with elapsed time. Calibrate timer-pair overhead and subtract it from per-call buckets; use a second counter-only run to detect instrumentation distortion.

- [x] **Step 2: Run repeated profile builds and record attribution**

Run:

```sh
cmake --build build -j 12
TJS_V8_PROFILE=1 ./build/tjs run bench/bench-v8.js
```

Repeat until the ordering of major buckets is stable. Remove temporary reporting before the final build.

### Task 3: Same-shape row cache

**Files:**
- Modify: `src/v8_serialize.zig`
- Test: `tests/test-v8.js`

**Interfaces:**
- Consumes: public `JS_GetOwnPropertyNames`, `JS_GetProperty`, atom duplication/free APIs, and serializer output primitives.
- Produces: a bounded serializer-local cache containing retained atoms and canonical pre-encoded key bytes.

- [x] **Step 1: Add behavior-first cache invalidation cases**

```js
const rows = [
    { id: 1, name: 'a' },
    { id: 2, name: 'b' },
    { name: 'c', id: 3 },
    { id: 4, extra: true, name: 'd' },
];
assert.deepEqual(deserialize(serialize(rows)), rows);
```

Add canonical fixed-byte assertions for repeated same-shape objects so incorrect key reuse, reordering, added/deleted properties, getters, and enumerable changes fail before optimization.

- [x] **Step 2: Verify the new cache-specific test fails under a deliberate cache mutation**

Run `./build/tjs run tests/test-v8.js` with the test’s mismatching rows and confirm that a temporary unconditional-key-reuse mutation produces the expected byte/structure failure; restore the mutation before production work.

- [x] **Step 3: Implement and measure the bounded cache**

Cache duplicated atoms plus bytes emitted for each key after the first eligible plain object. For every later candidate, call `JS_GetOwnPropertyNames`, compare length and atom integers in order, and only then fetch values with `JS_GetProperty`. On mismatch, use the ordinary path and replace or bypass the cache without changing property semantics. Exclude accessors or verify property presence after getter evaluation so deletion behavior stays correct.

Run the benchmark after this change and retain it only if median serialization improves while `tests/test-v8.js` remains byte-identical.

### Task 4: Measured low-level hot-path changes

**Files:**
- Modify when supported by Task 2 evidence: `src/v8_serialize.zig`
- Test: `src/v8_serialize_test.zig`
- Test: `tests/test-v8.js`

**Interfaces:**
- Consumes: profile attribution and existing `ArrayListUnmanaged` output storage.
- Produces: fewer output capacity checks, allocations, and string passes without format changes.

- [x] **Step 1: Batch tag/varint capacity checks if measured**

Reserve the maximum encoded size once, write directly into `unusedCapacitySlice`, and advance length once. Apply `@branchHint(.unlikely)` only to allocation/error branches observed in the hot number paths. Measure independently and revert if the median does not improve.

- [x] **Step 2: Improve output reservation if measured**

Reserve a conservative top-level estimate based on row count and first-row encoded size, while retaining geometric growth and QuickJS allocator slack. Do not perform a second traversal. Measure independently and revert if it does not improve.

- [x] **Step 3: Reduce string temporary work if measured**

Keep one public UTF-16 conversion per string, detect Latin-1 in the same pass that copies into reserved output when alignment permits, and avoid any extra intermediate allocation. Cache pre-encoded property keys so repeated rows never reconvert them. Measure independently and revert if it does not improve.

- [x] **Step 4: Preserve numeric hot paths**

Keep direct int32/double tags and the short/int64 BigInt path. Add branch hints only to exceptional or wide-BigInt branches and verify exact Node fixtures.

### Task 5: Final verification and evidence

**Files:**
- Finalize: `bench/bench-v8.js`
- Verify all files changed by Tasks 1-4.

**Interfaces:**
- Consumes: optimized serializer and benchmark.
- Produces: before/after numbers, per-lever impact, full regression evidence, and changed-file rationale.

- [x] **Step 1: Remove all temporary instrumentation and rebuild Release**

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTJS_ZIG_TARGET=aarch64-macos
cmake --build build -j 12
```

- [x] **Step 2: Run required verification**

```sh
cmake --build build --target v8-zig-test -j 12
./build/tjs run tests/test-v8.js
./build/tjs run tests/test-sqlite.js
./build/tjs run tests/test-sqlite-interrupt.js
./build/tjs run bench/bench-v8.js
git diff --check
```

- [x] **Step 3: Audit ABI and ownership invariants**

Search final changed Zig code for private QuickJS fields/symbols, confirm all cached atoms and retained values are released, and confirm detachment tests still run against the native-owned input copy.

- [x] **Step 4: Report literal verification boundaries**

Report the real fixture only if a fixture database exists inside the workspace. Distinguish local micro-benchmark evidence from the user’s original fixture numbers and from unexecuted cross-platform CI.
