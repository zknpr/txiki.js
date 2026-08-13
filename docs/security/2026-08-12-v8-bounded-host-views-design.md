# Bounded Zero-Copy V8 Host Views

Date: 2026-08-12

## Problem

The tjs:v8 DefaultDeserializer owns a private copy of the serialized message and exposes it as one Uint8Array. DefaultDeserializer._readHostObject() currently constructs every decoded typed array over that full message ArrayBuffer at the payload's offset. The typed array's visible elements are correct, but its public buffer property exposes the entire serialized message.

Code receiving one decoded view can therefore construct a wider Uint8Array over view.buffer and read serialized sibling values, object framing, and other payloads. It can also mutate bytes outside its own logical extent. In SQLite Explorer this boundary is crossed by native-worker IPC, so a value returned to one consumer must not grant access to unrelated bytes merely because the values shared one serialization message.

The invariant is that a deserialized host view's backing ArrayBuffer exposes exactly that view's serialized payload. Deserialization must retain the current private-input ownership safety, Node-compatible wire format, typed-array types, DataView behavior, and aligned zero-copy payload handling.

## Selected Design

Add one internal native deserializer operation that consumes a requested payload length and returns an exact-extent ArrayBuffer.

For an aligned payload, the returned object is a bounded external QuickJS ArrayBuffer whose base pointer is the start of the payload and whose byte length is exactly the payload length. It retains the existing OwnedInput allocation rather than copying payload bytes. DefaultDeserializer then constructs the requested typed array or DataView at byte offset zero over that bounded buffer.

For a payload whose native address is not aligned for the target element width, the native operation returns an exact-sized copied ArrayBuffer. This preserves the existing unaligned-copy behavior and avoids undefined or architecture-specific native access.

The operation receives the element alignment from the JavaScript host-object decoder. It accepts only the supported nonzero power-of-two alignments used by the built-in view constructors. Invalid arguments throw explicitly.

## Ownership and Lifetime

OwnedInput remains the single allocation containing the private message copy. Its reference count changes from u8 to usize because each live bounded external ArrayBuffer owns one reference.

The lifetime model is:

- the native Deserializer owns one reference;
- the existing full private js_view owns one reference;
- each aligned bounded external ArrayBuffer owns one reference;
- an unaligned copied buffer owns its own payload and does not retain OwnedInput.

Creating an aligned bounded buffer retains the owner before calling JS_NewArrayBuffer. If object creation fails, that reference is released before propagating the QuickJS exception. Detaching or collecting a bounded buffer invokes the existing release callback for only that reference. The message allocation is freed only after the deserializer, its full private view, and every bounded view have released their references.

Detaching one decoded view must not detach sibling views. Destroying the deserializer while decoded views remain live must not invalidate those views. More than 255 simultaneous aligned views must be supported without reference-counter overflow.

## JavaScript Interface and Data Flow

The internal method replaces the current combination of _readRawBytes() plus repeated buffer getter access inside DefaultDeserializer._readHostObject().

The flow becomes:

1. Read the host-object type index and payload byte length.
2. Validate that byte length is divisible by the constructor's element width.
3. Ask native code for an exact-extent payload buffer, passing length and alignment.
4. Construct the view at offset zero with the existing element count.

The serialized bytes and public tjs:v8 exports do not change. Serializer behavior does not change. The public Deserializer.buffer getter remains the caller-controlled private message copy for compatibility; the security fix is that decoded values no longer inherit that full buffer as their own backing store.

## Allocation and IPC Cost

An exact backing extent requires a distinct ArrayBuffer object; the standard typed-array buffer property cannot hide part of a shared ArrayBuffer. The selected design allocates only that small QuickJS wrapper for aligned payloads. It performs no second payload allocation, no payload copy, and no additional IPC.

It also replaces one raw-byte native call plus repeated native buffer-getter crossings with one native call that advances and returns the bounded buffer. This is expected to offset part of the wrapper-object cost, but performance will be measured rather than inferred.

The copying alternative is rejected because it allocates and copies every typed-array payload. Keeping the full shared buffer is rejected because it leaves the information-disclosure primitive intact. Proxying or subclassing typed arrays cannot change the standard buffer semantics reliably and would break compatibility.

## Error Handling

Truncated or oversized payloads continue through the existing deserialization error mapping. Unsupported alignment arguments and object-allocation failures throw synchronously. No failure may advance past a payload and then silently return a partial or wider view.

The existing external-buffer resize callback continues to reject nonzero resize requests without invalidating the original pointer.

## Verification

Focused tests in tests/test-v8.js will prove:

- every decoded built-in typed-array host object and DataView has byteOffset zero and buffer.byteLength equal to its own byteLength;
- a recipient cannot widen one view to read a sibling payload or framing bytes;
- mutating one decoded view cannot alter a sibling's bytes;
- detaching one decoded backing buffer leaves sibling views and remaining deserializer reads valid;
- decoded views remain valid after their DefaultDeserializer is collected;
- an unaligned multi-byte payload follows the exact-sized copy path;
- at least 300 simultaneous aligned host views survive collection and detachment without owner-reference overflow;
- Node-compatible fixture bytes and round trips remain unchanged.

The primary exact-extent test must fail against the current implementation before production code changes. The greater-than-255 test will be introduced after the first bounded implementation demonstrates the narrow counter overflow, then the counter will be widened.

Verification also includes make, the focused V8 test, the full make test suite, formatting, lint, and sanitizer or GC-stress coverage where supported.

## Performance Acceptance

The existing bench/bench-v8.js workload will be run with fixed rows, blob size, warmup, rounds, build type, and machine against preserved pre-fix and post-fix binaries. Results will report every run and the median serialize and deserialize times.

SQLite Explorer's native IPC benchmark will also compare the existing shipped binary with the candidate binary on the same machine. A repeatable median or p95 regression greater than 5 percent in the typed-array-heavy path is not acceptable without further optimization and explicit user approval. Noise inside that band will be reported as measured, not described as no cost.

## Delivery

The implementation and benchmarks will be complete locally before publication. The branch will then be pushed and a normal, ready-for-review pull request opened. The SQLite Explorer artifact workflow will be dispatched against the exact branch commit, and all five platform binaries will be consumed downstream by hash.
