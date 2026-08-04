import assert from 'tjs:assert';
import { deserialize, serialize } from 'tjs:v8';


const ROW_COUNT = Number(tjs.env.TJS_V8_BENCH_ROWS ?? 100_000);
const ROUNDS = Number(tjs.env.TJS_V8_BENCH_ROUNDS ?? 3);
const WARMUP_ROWS = Math.min(ROW_COUNT, Number(tjs.env.TJS_V8_BENCH_WARMUP_ROWS ?? 2_000));
const BLOB_BYTES = Number(tjs.env.TJS_V8_BENCH_BLOB_BYTES ?? 32);
const INCLUDE_BLOBS = tjs.env.TJS_V8_BENCH_DISABLE_BLOBS !== '1';
const INCLUDE_BIGINTS = tjs.env.TJS_V8_BENCH_DISABLE_BIGINTS !== '1';
const SERIALIZE_ONLY = tjs.env.TJS_V8_BENCH_SERIALIZE_ONLY === '1';
const BENCH_SHAPE = tjs.env.TJS_V8_BENCH_SHAPE ?? 'both';
const MAX_SERIALIZE_MS = tjs.env.TJS_V8_BENCH_MAX_SERIALIZE_MS === undefined
    ? undefined
    : Number(tjs.env.TJS_V8_BENCH_MAX_SERIALIZE_MS);

if (!Number.isSafeInteger(ROW_COUNT) || ROW_COUNT < 1) {
    throw new RangeError('TJS_V8_BENCH_ROWS must be a positive safe integer');
}
if (!Number.isSafeInteger(ROUNDS) || ROUNDS < 1) {
    throw new RangeError('TJS_V8_BENCH_ROUNDS must be a positive safe integer');
}
if (!Number.isSafeInteger(BLOB_BYTES) || BLOB_BYTES < 0) {
    throw new RangeError('TJS_V8_BENCH_BLOB_BYTES must be a non-negative safe integer');
}
if (![ 'bare', 'envelope', 'both' ].includes(BENCH_SHAPE)) {
    throw new RangeError('TJS_V8_BENCH_SHAPE must be bare, envelope, or both');
}

function buildRows(count) {
    const kinds = [ 'insert', 'update', 'delete', 'checkpoint' ];
    const sources = [ 'worker', 'replica', 'client', 'scheduler' ];
    const rows = new Array(count);

    for (let i = 0; i < count; i++) {
        const payload = INCLUDE_BLOBS ? new Uint8Array(BLOB_BYTES) : null;
        if (payload !== null) {
            for (let byte = 0; byte < payload.length; byte++) {
                payload[byte] = (i * 17 + byte * 29) & 0xff;
            }
        }

        // Every row deliberately has the same insertion order. This models the
        // SQLite Explorer IPC path while keeping each value independently owned.
        rows[i] = {
            id: i,
            groupId: i & 4095,
            timestamp: 1_725_000_000_000.25 + i * 0.125,
            score: (i % 10_000) / 7,
            kind: kinds[i & 3],
            source: sources[(i >> 2) & 3],
            message: `event ${i}: actor ${i % 1_000} updated record ${i % 10_000}`,
            sequence: INCLUDE_BIGINTS ? 4_611_686_018_427_000_000n + BigInt(i) : i,
            payload,
        };
    }

    return rows;
}

function median(values) {
    const sorted = values.slice().sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
}

function validateRows(rows, decoded) {
    assert.eq(decoded.length, rows.length);

    for (const index of [ 0, Math.floor(rows.length / 2), rows.length - 1 ]) {
        const expected = rows[index];
        const actual = decoded[index];
        assert.eq(actual.id, expected.id);
        assert.eq(actual.timestamp, expected.timestamp);
        assert.eq(actual.message, expected.message);
        assert.eq(actual.sequence, expected.sequence);
        if (expected.payload === null) {
            assert.eq(actual.payload, null);
        } else {
            assert.eq(actual.payload.byteLength, expected.payload.byteLength);
            assert.eq(actual.payload[0], expected.payload[0]);
            assert.eq(actual.payload[actual.payload.length - 1], expected.payload[expected.payload.length - 1]);
        }
    }
}

const rows = buildRows(ROW_COUNT);
const warmupRows = rows.slice(0, WARMUP_ROWS);
const columns = [ 'id', 'groupId', 'timestamp', 'score', 'kind', 'source', 'message', 'sequence', 'payload' ];

function makeEnvelope(values) {
    return {
        id: 7,
        result: {
            columns,
            values,
            rowCount: values.length,
        },
    };
}

function validateDecoded(shape, expectedRows, decoded) {
    if (shape === 'bare') {
        validateRows(expectedRows, decoded);
        return;
    }

    assert.eq(decoded.id, 7);
    assert.eq(decoded.result.rowCount, expectedRows.length);
    assert.deepEqual(decoded.result.columns, columns);
    validateRows(expectedRows, decoded.result.values);
}

const allCases = [
    { shape: 'bare', payload: rows, warmupPayload: warmupRows },
    { shape: 'envelope', payload: makeEnvelope(rows), warmupPayload: makeEnvelope(warmupRows) },
];
const cases = BENCH_SHAPE === 'both'
    ? allCases
    : allCases.filter(benchmarkCase => benchmarkCase.shape === BENCH_SHAPE);

for (const benchmarkCase of cases) {
    if (SERIALIZE_ONLY) {
        serialize(benchmarkCase.warmupPayload);
    } else {
        validateDecoded(benchmarkCase.shape, warmupRows,
            deserialize(serialize(benchmarkCase.warmupPayload)));
    }
}
tjs.engine.gc.run();

const measurements = new Map(cases.map(benchmarkCase => [ benchmarkCase.shape, {
    bytes: 0,
    serializeTimes: [],
    deserializeTimes: [],
} ]));

for (let round = 0; round < ROUNDS; round++) {
    // Alternate order so thermal or GC drift cannot consistently favor one shape.
    const orderedCases = round % 2 === 0 ? cases : cases.slice().reverse();
    for (const benchmarkCase of orderedCases) {
        const measurement = measurements.get(benchmarkCase.shape);
        tjs.engine.gc.run();
        const serializeStart = performance.now();
        let encoded = serialize(benchmarkCase.payload);
        const serializeMs = performance.now() - serializeStart;
        measurement.bytes = encoded.byteLength;

        let decoded;
        let deserializeMs = 0;
        if (!SERIALIZE_ONLY) {
            const deserializeStart = performance.now();
            decoded = deserialize(encoded);
            deserializeMs = performance.now() - deserializeStart;
            validateDecoded(benchmarkCase.shape, rows, decoded);
            measurement.deserializeTimes.push(deserializeMs);
        }

        measurement.serializeTimes.push(serializeMs);
        console.log(`shape=${benchmarkCase.shape} round=${round + 1} serialize_ms=${serializeMs.toFixed(3)} deserialize_ms=${deserializeMs.toFixed(3)} bytes=${measurement.bytes}`);

        encoded = undefined;
        decoded = undefined;
        tjs.engine.gc.run();
    }
}

const results = cases.map(benchmarkCase => {
    const measurement = measurements.get(benchmarkCase.shape);
    return {
        shape: benchmarkCase.shape,
        bytes: measurement.bytes,
        serializeMs: Number(median(measurement.serializeTimes).toFixed(3)),
        deserializeMs: SERIALIZE_ONLY ? null : Number(median(measurement.deserializeTimes).toFixed(3)),
        serializeRunsMs: measurement.serializeTimes.map(value => Number(value.toFixed(3))),
        deserializeRunsMs: measurement.deserializeTimes.map(value => Number(value.toFixed(3))),
    };
});
const result = {
    rows: ROW_COUNT,
    rounds: ROUNDS,
    results,
};

console.log(JSON.stringify(result));

if (MAX_SERIALIZE_MS !== undefined) {
    if (!Number.isFinite(MAX_SERIALIZE_MS) || MAX_SERIALIZE_MS <= 0) {
        throw new RangeError('TJS_V8_BENCH_MAX_SERIALIZE_MS must be a positive number');
    }
    for (const shapeResult of results) {
        assert.ok(shapeResult.serializeMs <= MAX_SERIALIZE_MS,
            `${shapeResult.shape} serialize median ${shapeResult.serializeMs} ms exceeds ${MAX_SERIALIZE_MS} ms`);
    }
}
