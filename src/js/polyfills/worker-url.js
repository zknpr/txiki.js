import { getObjectURL } from './object-url.js';


export function getWorkerObjectURL(specifier) {
    let url;

    try {
        url = new URL(specifier);
    } catch (_) {
        return undefined;
    }

    return url.protocol === 'blob:' ? getObjectURL(specifier) : undefined;
}
