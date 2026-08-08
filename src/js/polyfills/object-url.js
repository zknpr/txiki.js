// The registry is split from the URL polyfill so Worker can share it without
// forcing the Ada-backed URL constructors into URL-disabled bootstrap bundles.
const objectURLs = new Map();

export function registerObjectURL(url, object) {
    objectURLs.set(url, object);
}

export function revokeObjectURL(url) {
    return objectURLs.delete(url);
}

export function getObjectURL(url) {
    return objectURLs.get(url);
}
