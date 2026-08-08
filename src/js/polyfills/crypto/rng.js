import { getRandomValues, randomUUID } from './random.js';


const crypto = Object.freeze({
    getRandomValues,
    randomUUID,
});

Object.defineProperty(globalThis, 'crypto', {
    enumerable: true,
    configurable: true,
    writable: true,
    value: crypto
});
