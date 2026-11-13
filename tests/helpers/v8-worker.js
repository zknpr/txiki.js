import { Deserializer, Serializer, deserialize, serialize } from 'tjs:v8';

// Loaded by test-v8-worker.js. The tjs:v8 Serializer and Deserializer classes
// are looked up by this Worker runtime's own class ids, and the instances left
// to the GC run their finalizers here.
const row = { id: 7, name: 'x'.repeat(64), blob: new Uint8Array([ 1, 2, 3 ]), big: 2n ** 70n };

for (let i = 0; i < 200; i++) {
    const copy = deserialize(serialize(row));

    if (copy.id !== 7 || copy.name !== row.name || copy.big !== row.big || copy.blob[2] !== 3) {
        throw new Error(`round trip ${i} changed the row`);
    }

    const ser = new Serializer();

    ser.writeHeader();
    ser.writeValue(i);

    const des = new Deserializer(ser.releaseBuffer());

    des.readHeader();

    if (des.readValue() !== i) {
        throw new Error(`Serializer round trip ${i} changed the value`);
    }
}

tjs.engine.gc.run();
self.postMessage(Array.from(serialize(row)));
