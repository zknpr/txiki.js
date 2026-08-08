import core from 'tjs:internal/core';
import { URLPattern } from 'urlpattern-polyfill';

import { registerObjectURL, revokeObjectURL } from './object-url.js';


const NativeURL = core.URL;
const NativeURLSearchParams = core.URLSearchParams;

// Add createObjectURL / revokeObjectURL.
NativeURL.createObjectURL = object => {
    if (!(object instanceof Blob)) {
        throw new TypeError('URL.createObjectURL: Argument 1 is not valid for any of the 1-argument overloads.');
    }

    const url = `blob:${crypto.randomUUID()}`;

    registerObjectURL(url, object);

    return url;
};

NativeURL.revokeObjectURL = revokeObjectURL;

// Add Symbol.iterator to URLSearchParams.
// entries() returns an Array from native code, so wrap it in a generator
// to produce a proper iterator conforming to the iterator protocol.
NativeURLSearchParams.prototype[Symbol.iterator] = function *() {
    yield* this.entries();
};

globalThis.URL = NativeURL;
globalThis.URLSearchParams = NativeURLSearchParams;
globalThis.URLPattern = URLPattern;
