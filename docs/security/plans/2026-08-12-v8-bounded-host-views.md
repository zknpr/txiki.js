# Bounded Zero-Copy V8 Host Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every typed array and DataView decoded by `DefaultDeserializer` expose only its own payload through `.buffer`, without copying aligned payload bytes or adding IPC calls.

**Architecture:** Keep the existing private `OwnedInput` message copy. A new internal native deserializer method consumes one host-object payload and returns an exact-sized ArrayBuffer: an external bounded wrapper retaining `OwnedInput` when aligned, or an exact copy when unaligned. JavaScript constructs the final view at offset zero.

**Tech Stack:** Zig, QuickJS-NG C API, txiki.js standard library JavaScript, tjs test runner, native benchmark harness.

## Global Constraints

- Run from the repository root on `agent/v8-bounded-host-views`.
- Follow repository `CLAUDE.md` and preserve initialized submodules and ignored build outputs.
- Preserve byte-for-byte Node/V8 wire compatibility and public `tjs:v8` exports.
- Aligned payloads get an exact-sized ArrayBuffer wrapper with no payload allocation or payload copy. Unaligned multi-byte payloads retain the existing exact-copy behavior.
- Add one internal native call per host view; add no IPC call. The decoded view must have `byteOffset === 0` and `buffer.byteLength === byteLength`.
- `Deserializer.buffer` remains the existing full private message view for compatibility; decoded host views must not inherit it.
- Each aligned wrapper owns one `OwnedInput` reference. Detaching or collecting one wrapper must not invalidate siblings, the native parser, or the public full view.
- Support at least 300 simultaneously live aligned wrappers; use a `usize` reference count.
- Accept only alignments `1`, `2`, `4`, or `8`. Validate alignment before consuming bytes and propagate QuickJS exceptions explicitly.
- Set `TJS_V8_BASELINE` to the preserved pre-fix executable, whose SHA-256 must be `326e910a5b24262a7c7417cddd89e89b10b6b83b8d7943ac9ea1c5ce1fe90a5d`.
- A repeatable candidate regression greater than 5 percent in median or p95 typed-array deserialization is not acceptable without optimization or explicit user approval.
- Complete local correctness and performance verification before push. Open a normal ready-for-review PR, never a draft PR.

---

### Task 1: Add exact-extent and lifetime regressions

**Files:**

- Modify: `tests/test-v8.js:20-420`
- Reference: `src/js/stdlib/v8.js:70-105`

- [ ] **Step 1: Strengthen the shared view assertion**

  Extend `assertView(actual, expected)` with these public invariants:

  ```js
  assert.eq(actual.byteOffset, 0, 'decoded host views start at offset zero');
  assert.eq(actual.buffer.byteLength, actual.byteLength,
      'decoded host views expose only their payload through .buffer');
  ```

  Keep the constructor, byte length, and content assertions. This automatically covers every built-in typed array plus DataView already enumerated by the file.

- [ ] **Step 2: Add a sibling-widening exploit regression**

  Round-trip two distinct `Uint8Array` values in one object. Assert the returned buffers are distinct and exact-sized. Widen the first with `new Uint8Array(first.buffer)`, mutate all of it, and prove the second remains byte-for-byte unchanged. Before the fix, the exact-size assertion must fail because both values expose the serialized message.

- [ ] **Step 3: Add detach and lifetime coverage**

  Detach one returned view with `structuredClone(first.buffer, { transfer: [first.buffer] })`, then prove the sibling remains readable. Keep a returned view alive, drop the deserializer/result container reference, run `tjs.engine.gc.run()` twice, and prove its bytes remain valid.

- [ ] **Step 4: Exercise the unaligned-copy fixture**

  Deserialize Node's existing Int16Array fixture `ff0f5c0304ffff0001`. Its payload begins at an odd byte offset. Assert the returned `Int16Array` is correct, has offset zero, has an exact four-byte buffer, survives GC, and does not alias `DefaultDeserializer.buffer`.

- [ ] **Step 5: Add the reference-count boundary**

  Round-trip an array containing 300 independently allocated one-byte `Uint8Array` values, keep all decoded values live, validate the first/middle/last values, detach one, run GC, and validate the rest. This test must catch the current `u8` ownership ceiling once bounded wrappers exist.

- [ ] **Step 6: Record RED against the preserved pre-fix binary**

  ```bash
  : "${TJS_V8_BASELINE:?set TJS_V8_BASELINE to the preserved pre-fix executable}"
  expected_sha256="326e910a5b24262a7c7417cddd89e89b10b6b83b8d7943ac9ea1c5ce1fe90a5d"
  actual_sha256="$(shasum -a 256 "$TJS_V8_BASELINE" | awk '{print $1}')"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "TJS_V8_BASELINE has an unexpected SHA-256" >&2
    exit 1
  fi
  "$TJS_V8_BASELINE" run tests/test-v8.js
  ```

  Expected: the first exact-extent assertion fails with `buffer.byteLength` larger than the view payload. Record that assertion as RED evidence.

- [ ] **Step 7: Commit the failing regressions**

  ```bash
  git add tests/test-v8.js
  git commit -m "test: reproduce V8 host view buffer exposure"
  ```

---

### Task 2: Return bounded native payload buffers

**Files:**

- Modify: `src/v8_serialize.zig:55-95,1310-1475`
- Modify: `src/mod_v8_compat.zig:365-420`
- Modify: `src/js/stdlib/v8.js:80-105`
- Test: `tests/test-v8.js`

- [ ] **Step 1: Widen ownership accounting**

  Change `OwnedInput.references` from `u8` to `usize`. Keep the nonzero release assertion and replace the `maxInt(u8)` assertion with a checked `usize` increment guard so overflow cannot silently wrap.

- [ ] **Step 2: Add the deserializer primitive**

  Add this public-to-the-binding, internal-to-the-module method beside `readRawBytes`:

  ```zig
  pub fn readRawBytesBuffer(self: *Self, length: usize, alignment: usize) !c.JSValue {
      if (alignment != 1 and alignment != 2 and alignment != 4 and alignment != 8) {
          _ = c.JS_ThrowRangeError(self.ctx, "Unsupported host-view alignment");
          return Error.JSException;
      }
      const bytes = try self.readRawBytes(length);
      if (@intFromPtr(bytes.ptr) % alignment != 0) {
          const copied = c.JS_NewArrayBufferCopy(self.ctx, bytes.ptr, bytes.len);
          try exceptionCheck(copied);
          return copied;
      }

      self.input_owner.retain();
      errdefer self.input_owner.release();
      const bounded = c.JS_NewArrayBuffer(
          self.ctx,
          @constCast(bytes.ptr),
          bytes.len,
          0,
          releaseOwnedInput,
          self.input_owner,
          false,
      );
      try exceptionCheck(bounded);
      return bounded;
  }
  ```

  If repository Zig conventions require a different explicit error for invalid alignment, keep the security behavior: validation happens before `readRawBytes`, a JS exception is installed, and position is unchanged.

- [ ] **Step 3: Expose one private native method**

  Add `jsDeserializerReadRawBytesBuffer` in `src/mod_v8_compat.zig`. Require two arguments, parse both as `u32`, reject alignments other than `1/2/4/8` with a synchronous `RangeError`, call `des.readRawBytesBuffer()`, and map native errors through `mapNativeError`. Register:

  ```zig
  z.JS_CFUNC_DEF("_readRawBytesBuffer", 2, jsDeserializerReadRawBytesBuffer),
  ```

  Retain `_readRawBytes` because subclasses or existing internal consumers may depend on it.

- [ ] **Step 4: Use the bounded buffer in JavaScript**

  Replace the offset/full-buffer/copy branches in `DefaultDeserializer._readHostObject()` with:

  ```js
  const buffer = this._readRawBytesBuffer(byteLength, bytesPerElement);
  return new constructor(buffer, 0, byteLength / bytesPerElement);
  ```

  Keep the existing unknown-type and divisibility checks. `DataView.BYTES_PER_ELEMENT` is absent, so its alignment remains `1` and its third constructor argument remains the byte length.

- [ ] **Step 5: Build and run focused GREEN checks**

  ```bash
  make
  build/tjs run tests/test-v8.js
  ```

  Expected: exact extents, 300 live views, detach/GC tests, and every Node fixture pass.

- [ ] **Step 6: Run formatting/lint checks and commit**

  Use the repository's configured Zig and JavaScript formatting/lint targets discovered from `Makefile` and `package.json`, then:

  ```bash
  git add src/v8_serialize.zig src/mod_v8_compat.zig src/js/stdlib/v8.js
  git commit -m "fix: bound deserialized V8 host views"
  ```

---

### Task 3: Verify correctness and performance before publication

**Files:**

- Verify: `bench/bench-v8.js`
- Verify: `build/tjs`
- Record: task report in the plan's ignored SDD workspace

- [ ] **Step 1: Run the complete suite**

  ```bash
  make test
  ```

  Expected: every txiki.js test passes, including `tests/test-v8.js`.

- [ ] **Step 2: Run the fixed candidate benchmark**

  ```bash
  TJS_V8_BENCH_ROWS=100000 TJS_V8_BENCH_ROUNDS=9 TJS_V8_BENCH_BLOB_BYTES=32 build/tjs run bench/bench-v8.js
  ```

  Compare every run plus median and nearest-rank p95 with the preserved baseline. The recorded pre-fix deserialization medians are 104.269 ms for `bare` and 103.903 ms for `envelope`; use the full nine samples in the task report, not only those medians. If either median or p95 regresses reproducibly by more than 5 percent, optimize and rerun before publication.

- [ ] **Step 3: Confirm the aligned path does not copy payload bytes**

  Review the final diff and prove that aligned host payloads call `JS_NewArrayBuffer`, while only unaligned payloads call `JS_NewArrayBufferCopy`. Confirm `_readHostObject()` makes one native call after reading length/type and no `this.buffer` getter call.

- [ ] **Step 4: Confirm branch scope**

  ```bash
  git diff origin/master...HEAD --check
  git status --short
  git log --oneline origin/master..HEAD
  ```

- [ ] **Step 5: Push and open a normal PR only after all gates pass**

  Push `agent/v8-bounded-host-views`, then create a non-draft PR targeting `master`. Its body must contain Problem, Solution, Architecture, Per-file Changes, Security, and Test Plan, including allocation/IPC analysis, full benchmark samples, medians, p95 values, throughput where available, and relative deltas.
