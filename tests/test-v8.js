import assert from 'tjs:assert';
import {
    DefaultDeserializer,
    DefaultSerializer,
    Deserializer,
    Serializer,
    deserialize,
    serialize,
} from 'tjs:v8';


function bytesFromHex(hex) {
    const bytes = new Uint8Array(hex.length / 2);

    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }

    return bytes;
}

function hexFromBytes(bytes) {
    return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

function roundTrip(value) {
    return deserialize(serialize(value));
}

function assertNumber(actual, expected, message) {
    assert.ok(Object.is(actual, expected), message ?? `${actual} is not ${expected}`);
}

function assertView(actual, expected) {
    assert.is(actual.constructor, expected.constructor);
    assert.eq(actual.byteLength, expected.byteLength);
    assert.eq(actual.buffer.byteLength, actual.byteLength,
        'decoded host views expose only their payload through .buffer');
    assert.eq(actual.byteOffset, 0, 'decoded host views start at offset zero');
    assert.deepEqual(Array.from(new Uint8Array(actual.buffer, actual.byteOffset, actual.byteLength)),
        Array.from(new Uint8Array(expected.buffer, expected.byteOffset, expected.byteLength)));
}

assert.eq(typeof Serializer, 'function');
assert.eq(typeof Deserializer, 'function');
assert.eq(typeof DefaultSerializer, 'function');
assert.eq(typeof DefaultDeserializer, 'function');

{
    const deserializer = new Deserializer(Uint8Array.of(0xaa, 0xbb));

    assert.throws(() => deserializer._readRawBytesBuffer(1, 3), RangeError,
        'unsupported host-view alignment throws RangeError');
    assert.deepEqual(Array.from(deserializer.readRawBytes(1)), [ 0xaa ],
        'unsupported host-view alignment does not consume input');
    assert.throws(() => deserializer._readRawBytesBuffer(1, 0), RangeError,
        'zero host-view alignment throws RangeError');
    assert.deepEqual(Array.from(deserializer.readRawBytes(1)), [ 0xbb ],
        'zero host-view alignment does not consume input');
}

for (const value of [ undefined, null, false, true, 0, 1, -1, 2147483647, -2147483648, 2 ** 40, -(2 ** 40) ]) {
    assert.eq(roundTrip(value), value);
}

for (const value of [ -0, NaN, Infinity, -Infinity, Number.MIN_VALUE, Number.MAX_VALUE ]) {
    assertNumber(roundTrip(value), value);
}

for (const value of [
    '',
    'ASCII and Latin-1: \u00ff',
    'astral: \ud83d\ude00',
    'lone high: x\ud800y',
    'lone low: x\udc00y',
    'adjacent-but-unpaired: \ud800A\udc00',
]) {
    assert.eq(roundTrip(value), value);
}

for (const value of [
    0n,
    1n,
    -1n,
    2147483647n,
    -2147483648n,
    9223372036854775807n,
    -9223372036854775808n,
    (2n ** 100n) + 123n,
    -((2n ** 130n) + 7n),
]) {
    assert.eq(roundTrip(value), value);
}

const typedArrays = [
    new Int8Array([ -128, -1, 0, 127 ]),
    new Uint8Array([ 0, 1, 127, 128, 255 ]),
    new Uint8ClampedArray([ 0, 1, 254, 255 ]),
    new Int16Array([ -32768, -1, 0, 32767 ]),
    new Uint16Array([ 0, 1, 65535 ]),
    new Int32Array([ -2147483648, -1, 0, 2147483647 ]),
    new Uint32Array([ 0, 1, 0xffffffff ]),
    new Float32Array([ -0, 1.5, Infinity, -Infinity, NaN ]),
    new Float64Array([ -0, Math.PI, Number.MIN_VALUE, NaN ]),
    new BigInt64Array([ -9223372036854775808n, -1n, 0n, 9223372036854775807n ]),
    new BigUint64Array([ 0n, 1n, 0xffffffffffffffffn ]),
];
if (typeof Float16Array !== 'undefined') {
    typedArrays.push(new Float16Array([ 1.5, -2 ]));
}

for (const expected of typedArrays) {
    assertView(roundTrip(expected), expected);
}

{
    const expectedFirst = new Uint8Array([ 0x11, 0x22, 0x33 ]);
    const expectedSecond = new Uint8Array([ 0xa1, 0xb2, 0xc3, 0xd4 ]);
    const { first, second } = roundTrip({ first: expectedFirst, second: expectedSecond });

    assertView(first, expectedFirst);
    assertView(second, expectedSecond);
    assert.isNot(first.buffer, second.buffer, 'decoded sibling views have distinct buffers');

    const widenedFirst = new Uint8Array(first.buffer);
    widenedFirst.fill(0xee);
    assert.deepEqual(Array.from(second), Array.from(expectedSecond),
        'widening and mutating one decoded view cannot alter a sibling');

    structuredClone(first.buffer, { transfer: [ first.buffer ] });
    assert.eq(first.buffer.byteLength, 0, 'transferring a decoded view detaches only that view');
    assert.deepEqual(Array.from(second), Array.from(expectedSecond),
        'detaching one decoded view leaves its sibling readable');
}

{
    const expected = new Uint8Array([ 0x41, 0x42, 0x43, 0x44 ]);
    let result = roundTrip({ view: expected });
    const survivor = result.view;
    result = undefined;

    tjs.engine.gc.run();
    tjs.engine.gc.run();
    assertView(survivor, expected);
}

{
    const expected = new Uint8Array([ 9, 8, 7, 6 ]);
    const actual = roundTrip(expected);
    tjs.engine.gc.run();
    tjs.engine.gc.run();
    assertView(actual, expected);
}

{
    const backing = new ArrayBuffer(32);
    const bytes = new Uint8Array(backing);
    bytes.set([ 1, 2, 3, 4, 5, 6, 7, 8 ], 7);

    const expected = new DataView(backing, 7, 8);
    assertView(roundTrip(expected), expected);
}

{
    // The Node fixture's payload starts at byte 5, so Int16Array must take the unaligned-copy path.
    let deserializer = new DefaultDeserializer(bytesFromHex('ff0f5c0304ffff0001'));
    let sourceBuffer = deserializer.buffer.buffer;
    assert.ok(deserializer.readHeader());
    const actual = deserializer.readValue();
    const expected = new Int16Array([ -1, 256 ]);

    assertView(actual, expected);
    assert.isNot(actual.buffer, sourceBuffer,
        'unaligned host views copy instead of aliasing DefaultDeserializer.buffer');
    deserializer = undefined;
    sourceBuffer = undefined;
    tjs.engine.gc.run();
    tjs.engine.gc.run();
    assertView(actual, expected);
}

{
    // Keep the count above 255 to catch owner-reference counters that are too narrow.
    const expected = Array.from({ length: 300 }, (_, index) => new Uint8Array([ index & 0xff ]));
    const actual = roundTrip(expected);

    assertView(actual[0], expected[0]);
    assertView(actual[150], expected[150]);
    assertView(actual[299], expected[299]);

    const detachedIndex = 149;
    structuredClone(actual[detachedIndex].buffer, { transfer: [ actual[detachedIndex].buffer ] });
    assert.eq(actual[detachedIndex].buffer.byteLength, 0,
        'one detached view does not invalidate other live owner references');
    tjs.engine.gc.run();
    tjs.engine.gc.run();

    for (let index = 0; index < actual.length; index++) {
        if (index !== detachedIndex) {
            assertView(actual[index], expected[index]);
        }
    }
}

for (const expected of [ new ArrayBuffer(0), Uint8Array.from([ 1, 2, 3, 255 ]).buffer ]) {
    const actual = roundTrip(expected);
    assert.ok(actual instanceof ArrayBuffer);
    assert.deepEqual(Array.from(new Uint8Array(actual)), Array.from(new Uint8Array(expected)));
}

{
    const expected = {
        rowid: 7n,
        name: 'alpha',
        blob: new Uint8Array([ 1, 2, 3 ]),
        values: [ null, true, -0, { nested: 'yes' } ],
    };
    const actual = roundTrip(expected);

    assert.eq(actual.rowid, expected.rowid);
    assert.eq(actual.name, expected.name);
    assertView(actual.blob, expected.blob);
    assert.eq(actual.values[0], null);
    assert.eq(actual.values[1], true);
    assertNumber(actual.values[2], -0);
    assert.deepEqual(actual.values[3], expected.values[3]);
}

{
    // Node.js v24.12.0 / V8 13.6.233.17-node.37. Repeated row keys are
    // canonical bytes, so a shape cache may not alter their placement.
    const rows = [ { id: 1, name: 'a' }, { id: 2, name: 'b' } ];
    const expectedHex = 'ff0f41026f22026964490222046e616d652201617b026f22026964490422046e616d652201627b02240002';
    assert.eq(hexFromBytes(serialize(rows)), expectedHex);
    assert.deepEqual(deserialize(bytesFromHex(expectedHex)), rows);
}

{
    // Two-byte keys require position-dependent padding and intentionally take
    // the uncached path. Fixture: Node.js v24.12.0 / V8 13.6.233.17-node.37.
    const rows = [ { '\u0100': 1 }, { '\u0100': 2 } ];
    const expectedHex = 'ff0f41026f006302000149027b016f006302000149047b01240002';
    assert.eq(hexFromBytes(serialize(rows)), expectedHex);
    assert.deepEqual(deserialize(bytesFromHex(expectedHex)), rows);
}

{
    const rows = [
        { id: 1, name: 'a' },
        { name: 'b', id: 2 },
        { id: 3, extra: true, name: 'c' },
    ];
    const expectedHex = 'ff0f41036f22026964490222046e616d652201617b026f22046e616d652201622202696449047b026f220269644906220565787472615422046e616d652201637b03240003';
    assert.eq(hexFromBytes(serialize(rows)), expectedHex, 'shape mismatch must fall back without reusing keys');
    assert.deepEqual(roundTrip(rows), rows);
}

{
    const first = { id: 1, name: 'a', extra: 'kept' };
    const second = { id: 2 };
    Object.defineProperty(second, 'name', {
        configurable: true,
        enumerable: true,
        get() {
            delete this.extra;
            return 'b';
        },
    });
    second.extra = 'deleted';

    const actual = roundTrip([ first, second ]);
    assert.deepEqual(actual[0], first);
    assert.eq(actual[1].id, 2);
    assert.eq(actual[1].name, 'b');
    assert.falsy('extra' in actual[1], 'cached shape must preserve getter deletion semantics');
}

{
    // A shape-mismatching object nested in a NON-last property replaces the
    // shape cache while the cached walk of its parent row is still in flight.
    // Fixture: Node.js v24.12.0 / V8 13.6.233.17-node.37.
    const rows = [ { a: 0, b: 0 }, { a: { x: 1 }, b: 1 } ];
    const expectedHex = 'ff0f41026f220161490022016249007b026f2201' +
        '616f22017849027b0122016249027b02240002';
    assert.eq(hexFromBytes(serialize(rows)), expectedHex, 'nested object mid-walk keeps canonical key bytes');
    assert.deepEqual(deserialize(bytesFromHex(expectedHex)), rows);
}

{
    // Arrays of nested objects replace the shape cache twice per row while
    // the cached walk of the outer row is still in flight.
    // Fixture: Node.js v24.12.0 / V8 13.6.233.17-node.37.
    const rows = [ { a: [ { x: 1 }, { y: 2 } ], b: 1 }, { a: [ { x: 1 }, { y: 2 } ], b: 1 } ];
    const expectedHex = 'ff0f41026f22016141026f22017849027b016f22' +
        '017949047b0124000222016249027b026f220161' +
        '41026f22017849027b016f22017949047b012400' +
        '0222016249027b02240002';
    assert.eq(hexFromBytes(serialize(rows)), expectedHex, 'nested arrays mid-walk keep canonical key bytes');
    assert.deepEqual(deserialize(bytesFromHex(expectedHex)), rows);
}

{
    let hostWrites = 0;
    class TrackingSerializer extends DefaultSerializer {
        _writeHostObject(view) {
            hostWrites++;
            return super._writeHostObject(view);
        }
    }

    const serializer = new TrackingSerializer();
    serializer.writeHeader();
    serializer.writeValue(new Uint8Array([ 1, 2, 3 ]));
    const bytes = serializer.releaseBuffer();
    assert.eq(hostWrites, 1, 'DefaultSerializer subclasses retain the overridable host writer');
    assertView(deserialize(bytes), new Uint8Array([ 1, 2, 3 ]));
}

{
    const originalWriter = DefaultSerializer.prototype._writeHostObject;
    let hostWrites = 0;
    DefaultSerializer.prototype._writeHostObject = function (view) {
        hostWrites++;
        return originalWriter.call(this, view);
    };
    try {
        assertView(roundTrip(new Uint8Array([ 4, 5, 6 ])), new Uint8Array([ 4, 5, 6 ]));
    } finally {
        DefaultSerializer.prototype._writeHostObject = originalWriter;
    }
    assert.eq(hostWrites, 1, 'serialize observes a patched DefaultSerializer host writer');
}

{
    const expected = [ 1, null, 'x' ];
    expected.extra = 42;
    const actual = roundTrip(expected);

    assert.ok(Array.isArray(actual));
    assert.deepEqual(actual.slice(), expected.slice());
    assert.eq(actual.extra, 42);
}

{
    const expected = new Array(3);
    expected.extra = 'holes';
    const actual = roundTrip(expected);

    assert.eq(actual.length, 3);
    assert.falsy(0 in actual);
    assert.falsy(1 in actual);
    assert.falsy(2 in actual);
    assert.eq(actual.extra, 'holes');
}

{
    const shared = { id: 1 };
    const expected = [ shared, shared ];
    const actual = roundTrip(expected);

    assert.is(actual[0], actual[1]);
}

{
    const expected = { label: 'cycle' };
    expected.self = expected;
    const actual = roundTrip(expected);

    assert.eq(actual.label, 'cycle');
    assert.is(actual.self, actual);
}

{
    const key = { key: 1 };
    const expected = new Map([ [ 'a', 1 ], [ key, new Set([ 2, 'x' ]) ] ]);
    const actual = roundTrip(expected);

    assert.ok(actual instanceof Map);
    assert.eq(actual.get('a'), 1);
    const objectEntry = Array.from(actual.entries()).find(([ entryKey ]) => typeof entryKey === 'object');
    assert.eq(objectEntry[0].key, 1);
    assert.ok(objectEntry[1] instanceof Set);
    assert.deepEqual(Array.from(objectEntry[1]), [ 2, 'x' ]);
}

{
    const expected = new Date('2024-01-02T03:04:05.678Z');
    const actual = roundTrip(expected);
    assert.ok(actual instanceof Date);
    assert.eq(actual.getTime(), expected.getTime());
}

{
    const expected = /a.b/giuy;
    const actual = roundTrip(expected);
    assert.ok(actual instanceof RegExp);
    assert.eq(actual.source, expected.source);
    assert.eq(actual.flags, expected.flags);
}

// These fixtures were generated by Node.js v24.12.0 (V8 13.6.233.17-node.37)
// with node:v8.serialize. Exact equality is also an executable proof that Node's
// deserializer accepts the canonical bytes emitted by tjs for these values.
const nodeFixtures = [
    [ 'null', 'ff0f30', null, value => assert.eq(value, null) ],
    [ 'true', 'ff0f54', true, value => assert.eq(value, true) ],
    [ '-0', 'ff0f4e0000000000000080', -0, value => assertNumber(value, -0) ],
    [ 'NaN', 'ff0f4e000000000000f87f', NaN, value => assert.ok(Number.isNaN(value)) ],
    [ 'Infinity', 'ff0f4e000000000000f07f', Infinity, value => assert.eq(value, Infinity) ],
    [ 'astral string', 'ff0f630841003dd800de4200', 'A\ud83d\ude00B', value => assert.eq(value, 'A\ud83d\ude00B') ],
    [ 'lone surrogate', 'ff0f6306780000d87900', 'x\ud800y', value => assert.eq(value, 'x\ud800y') ],
    [ 'int64 BigInt', 'ff0f5a10ffffffffffffff7f', 9223372036854775807n, value => assert.eq(value, 9223372036854775807n) ],
    [ 'wide BigInt', 'ff0f5a207b000000000000000000000010000000', (2n ** 100n) + 123n, value => assert.eq(value, (2n ** 100n) + 123n) ],
    [ 'Uint8Array', 'ff0f5c010500017f80ff', new Uint8Array([ 0, 1, 127, 128, 255 ]), value => assertView(value, new Uint8Array([ 0, 1, 127, 128, 255 ])) ],
    [ 'Int16Array', 'ff0f5c0304ffff0001', new Int16Array([ -1, 256 ]), value => assertView(value, new Int16Array([ -1, 256 ])) ],
    [ 'ArrayBuffer', 'ff0f4203010203', Uint8Array.from([ 1, 2, 3 ]).buffer, value => assert.deepEqual(Array.from(new Uint8Array(value)), [ 1, 2, 3 ]) ],
    [ 'object', 'ff0f6f22016149022201622201787b02', { a: 1, b: 'x' }, value => assert.deepEqual(value, { a: 1, b: 'x' }) ],
    [ 'array', 'ff0f4103490230220178240003', [ 1, null, 'x' ], value => assert.deepEqual(value, [ 1, null, 'x' ]) ],
    [ 'Map', 'ff0f3b22016149023a02', new Map([ [ 'a', 1 ] ]), value => assert.eq(value.get('a'), 1) ],
    [ 'Set', 'ff0f2749022201782c02', new Set([ 1, 'x' ]), value => assert.deepEqual(Array.from(value), [ 1, 'x' ]) ],
    [ 'Date', 'ff0f4400e0b20d82cc7842', new Date('2024-01-02T03:04:05.678Z'), value => assert.eq(value.getTime(), 1704164645678) ],
    [ 'RegExp', 'ff0f522203612e621b', /a.b/giuy, value => {
        assert.eq(value.source, 'a.b');
        assert.eq(value.flags, 'giuy');
    } ],
];
if (typeof Float16Array !== 'undefined') {
    nodeFixtures.push([
        'Float16Array',
        'ff0f5c0d04003e00c0',
        new Float16Array([ 1.5, -2 ]),
        value => assertView(value, new Float16Array([ 1.5, -2 ])),
    ]);
}

for (const [ name, hex, value, check ] of nodeFixtures) {
    const bytes = bytesFromHex(hex);
    check(deserialize(bytes));
    assert.eq(hexFromBytes(serialize(value)), hex, `${name} serialization differs from Node`);
}

assert.throws(() => deserialize(new Uint8Array()), Error, 'truncated input is catchable');
assert.throws(() => deserialize(bytesFromHex('ff')), Error, 'truncated header is catchable');
assert.throws(() => deserialize(bytesFromHex('ff1030')), Error, 'unsupported version is catchable');
assert.throws(() => deserialize(bytesFromHex('000f30')), Error, 'bad version tag is catchable');
assert.throws(() => deserialize(bytesFromHex('ff0f42ffffffff0f')), Error, 'oversized truncated buffer is catchable');
assert.throws(() => deserialize(bytesFromHex('ff0f42ffffffff1f')), Error, 'overflowing varint is catchable');

// A failed value read leaves a partially constructed object in the native ID
// table. Reusing the deserializer must still throw normally, never dereference
// an object released while unwinding the first exception.
{
    const deserializer = new DefaultDeserializer(bytesFromHex('ff0f6f220161'));
    deserializer.readHeader();
    assert.throws(() => deserializer.readValue(), Error);
    assert.throws(() => deserializer.readValue(), Error);
}

// The native deserializer must retain its own bytes; detaching caller-owned
// storage after construction must not create a dangling native pointer.
{
    const input = bytesFromHex('ff0f6f22016149022201622201787b02');
    const deserializer = new DefaultDeserializer(input);
    structuredClone(input.buffer, { transfer: [ input.buffer ] });

    assert.eq(input.buffer.byteLength, 0);
    assert.ok(deserializer.readHeader());
    assert.deepEqual(deserializer.readValue(), { a: 1, b: 'x' });
}

// The public buffer view is backed by the same native-owned copy. QuickJS may
// detach the view, but it must not free the bytes still used by native parsing.
{
    const deserializer = new DefaultDeserializer(bytesFromHex('ff0f6f22016149022201622201787b02'));
    const exposed = deserializer.buffer;
    structuredClone(exposed.buffer, { transfer: [ exposed.buffer ] });

    assert.eq(exposed.buffer.byteLength, 0);
    assert.ok(deserializer.readHeader());
    assert.deepEqual(deserializer.readValue(), { a: 1, b: 'x' });
}
