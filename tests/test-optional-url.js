import assert from 'tjs:assert';


const hasURL = tjs.engine.features.url;

assert.ok(typeof hasURL === 'boolean', 'features.url is boolean');
assert.equal(typeof globalThis.URL === 'function', hasURL, 'URL availability matches features.url');
assert.equal(
    typeof globalThis.URLSearchParams === 'function',
    hasURL,
    'URLSearchParams availability matches features.url'
);
assert.equal(typeof globalThis.URLPattern === 'function', hasURL, 'URLPattern availability matches features.url');

if (hasURL) {
    assert.equal(new URL('./worker.js', 'file:///tmp/native/entry.js').href,
        'file:///tmp/native/worker.js', 'relative file URL resolution works');
}
