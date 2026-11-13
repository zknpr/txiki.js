import assert from 'tjs:assert';
import path from 'tjs:path';
import { serialize } from 'tjs:v8';

// tjs:v8's native classes get per-runtime class ids like every other native
// class. With process-wide ids a Worker runtime registered them at the main
// runtime's ids and its next class collided with them, aborting the process
// at Worker bootstrap.
const NUM_WORKERS = 2;
const workerPath = path.join(import.meta.dirname, 'helpers', 'v8-worker.js');
const workers = [];
const pending = [];

for (let i = 0; i < NUM_WORKERS; i++) {
    const { promise, resolve, reject } = Promise.withResolvers();
    const w = new Worker(workerPath);

    w.onmessage = event => resolve(event.data);
    w.onerror = event => {
        event.preventDefault();
        reject(new Error(`worker ${i} failed: ${event.message}`));
    };

    workers.push(w);
    pending.push(promise);
}

const results = await Promise.all(pending);

for (const w of workers) {
    w.terminate();
}

const row = { id: 7, name: 'x'.repeat(64), blob: new Uint8Array([ 1, 2, 3 ]), big: 2n ** 70n };
const expected = Array.from(serialize(row));

for (const bytes of results) {
    assert.eq(bytes.join(','), expected.join(','), 'a Worker serializes like the main runtime');
}
