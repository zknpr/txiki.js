import assert from 'tjs:assert';


const hasWebCrypto = tjs.engine.features.webcrypto;

assert.ok(typeof hasWebCrypto === 'boolean', 'features.webcrypto is boolean');
assert.equal(typeof globalThis.crypto, 'object', 'minimal crypto global is always available');
assert.equal(typeof globalThis.crypto.getRandomValues, 'function', 'getRandomValues is always available');
assert.equal(typeof globalThis.crypto.randomUUID, 'function', 'randomUUID is always available');
assert.equal(typeof globalThis.crypto.subtle === 'object', hasWebCrypto,
    'SubtleCrypto availability matches features.webcrypto');

const bytes = new Uint8Array(32);
assert.equal(globalThis.crypto.getRandomValues(bytes), bytes, 'getRandomValues returns its input view');

const uuid = globalThis.crypto.randomUUID();
assert.ok(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid),
    'randomUUID returns an RFC 4122 version 4 UUID'
);
