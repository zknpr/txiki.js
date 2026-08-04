import core from 'tjs:internal/core';

const { Serializer, Deserializer } = core.v8;

function objectPrototypeToString(value) {
    return Object.prototype.toString.call(value);
}

function copy(source, destination, destinationStart, sourceStart, sourceEnd) {
    destination.set(source.subarray(sourceStart, sourceEnd), destinationStart);
}

function arrayBufferViewTypeToIndex(view) {
    const type = objectPrototypeToString(view);
    if (type === '[object Int8Array]') return 0;
    if (type === '[object Uint8Array]') return 1;
    if (type === '[object Uint8ClampedArray]') return 2;
    if (type === '[object Int16Array]') return 3;
    if (type === '[object Uint16Array]') return 4;
    if (type === '[object Int32Array]') return 5;
    if (type === '[object Uint32Array]') return 6;
    if (type === '[object Float32Array]') return 7;
    if (type === '[object Float64Array]') return 8;
    if (type === '[object DataView]') return 9;
    // Index 10 is Node's Buffer and decodes as its Uint8Array base type.
    if (type === '[object BigInt64Array]') return 11;
    if (type === '[object BigUint64Array]') return 12;
    if (type === '[object Float16Array]') return 13;
    return -1;
}

function arrayBufferViewIndexToType(index) {
    if (index === 0) return Int8Array;
    if (index === 1 || index === 10) return Uint8Array;
    if (index === 2) return Uint8ClampedArray;
    if (index === 3) return Int16Array;
    if (index === 4) return Uint16Array;
    if (index === 5) return Int32Array;
    if (index === 6) return Uint32Array;
    if (index === 7) return Float32Array;
    if (index === 8) return Float64Array;
    if (index === 9) return DataView;
    if (index === 11) return BigInt64Array;
    if (index === 12) return BigUint64Array;
    if (index === 13 && typeof Float16Array !== 'undefined') return Float16Array;
    return undefined;
}

class DefaultSerializer extends Serializer {
    constructor() {
        super();
        this._setTreatArrayBufferViewsAsHostObjects(true);
    }

    _writeHostObject(view) {
        let typeIndex = 1;
        if (!(view instanceof Uint8Array)) {
            typeIndex = arrayBufferViewTypeToIndex(view);
            if (typeIndex === -1) {
                throw new this._getDataCloneError(`Unserializable host object: ${view}`);
            }
        }

        this.writeUint32(typeIndex);
        this.writeUint32(view.byteLength);
        this.writeRawBytes(new Uint8Array(view.buffer, view.byteOffset, view.byteLength));
    }

    get _getDataCloneError() {
        return Error;
    }

    _getSharedArrayBufferId(_sharedArrayBuffer) {
        throw new Error('Method not implemented.');
    }
}

const defaultHostObjectWriter = DefaultSerializer.prototype._writeHostObject;

class DefaultDeserializer extends Deserializer {
    _readHostObject() {
        const typeIndex = this.readUint32();
        const constructor = arrayBufferViewIndexToType(typeIndex);
        if (constructor === undefined) {
            throw new Error(`Unknown host object type index: ${typeIndex}`);
        }

        const byteLength = this.readUint32();
        const bytesPerElement = constructor.BYTES_PER_ELEMENT || 1;
        if (byteLength % bytesPerElement !== 0) {
            throw new Error('Host object byte length is not element-aligned');
        }

        const byteOffset = this._readRawBytes(byteLength);
        const offset = this.buffer.byteOffset + byteOffset;
        if (offset % bytesPerElement === 0) {
            return new constructor(this.buffer.buffer, offset, byteLength / bytesPerElement);
        }

        // Node accepts unaligned host-object payloads by copying them first.
        const aligned = new Uint8Array(byteLength);
        copy(this.buffer, aligned, 0, byteOffset, byteOffset + byteLength);
        return new constructor(aligned.buffer, aligned.byteOffset, byteLength / bytesPerElement);
    }
}

function serialize(value) {
    const serializer = new DefaultSerializer();
    const writerDescriptor = Object.getOwnPropertyDescriptor(DefaultSerializer.prototype, '_writeHostObject');
    if (writerDescriptor?.value === defaultHostObjectWriter) {
        // The unmodified helper can emit Node's host-view bytes without three
        // JS/native calls per view. Patched public behavior stays in JS.
        serializer._setUseDefaultHostObjectWriter(true);
    }
    serializer.writeHeader();
    serializer.writeValue(value);
    return serializer.releaseBuffer();
}

function deserialize(buffer) {
    const deserializer = new DefaultDeserializer(buffer);
    deserializer.readHeader();
    return deserializer.readValue();
}

export {
    Serializer,
    Deserializer,
    DefaultSerializer,
    DefaultDeserializer,
    deserialize,
    serialize,
};
