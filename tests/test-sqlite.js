import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database } from 'tjs:sqlite';


function testTypes(dbName) {
    const db = new Database(dbName);

    db.exec('PRAGMA journal_mode = WAL;');

    db.prepare('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)').run();
    
    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    
    ins.run('foo', 42, 4.2, new Uint8Array(16).fill(42));
    ins.run('foo', 43, 4.3, new Uint8Array(16).fill(43));
    ins.run('bar', 69, 6.9, new Uint8Array(16).fill(69));
    ins.run('baz', 666, 6.6, null);
    
    ins.finalize();

    assert.throws(() => ins.run('baz', 666, 6.6, null), InternalError);

    const data1 = db.prepare('SELECT * FROM test').all();
    const data2 = db.prepare('SELECT * FROM test WHERE txt = $txt').all({ $txt: 'foo' });

    assert.throws(() => db.prepare('SELECT * FROM test WHERE txt = $txt').all({ txt: 'foo' }), ReferenceError);
    assert.eq(data1.length, 4);
    assert.eq(data2.length, 2);

    assert.eq(data1[0].txt, 'foo');
    assert.eq(data1[0].int, 42);
    assert.eq(data1[0].double, 4.2);
    assert.eq(data1[0].data[0], 42);

    assert.eq(data1[3].txt, 'baz');
    assert.eq(data1[3].data, null);

    assert.throws(() => db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)').run(null, 42, 4.2, null), Error);

    db.close();
}

function testExistingDB() {
    const db = new Database(path.join(import.meta.dirname, 'fixtures', 'test.sqlite'), { readOnly: true });

    const data1 = db.prepare('SELECT * FROM test').all();
    const data2 = db.prepare('SELECT * FROM test WHERE txt = $txt').all({ $txt: 'foo' });

    assert.eq(data1.length, 4);
    assert.eq(data2.length, 2);

    assert.eq(data1[0].txt, 'foo');
    assert.eq(data1[0].int, 42);
    assert.eq(data1[0].double, 4.2);
    assert.eq(data1[0].data[0], 42);

    assert.eq(data1[3].txt, 'baz');
    assert.eq(data1[3].data, null);

    assert.throws(() => db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)').run('foo', 42, 4.2, null), Error);

    db.close();
}

function testNewDbNoCreate() {
    assert.throws(() => new Database(path.join(import.meta.dirname, 'fixtures', 'nope.sqlite'), { create: false }), Error);

}

function testCloseWithLiveStatement() {
    const db = new Database();

    db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');
    db.exec("INSERT INTO test (value) VALUES ('hello')");

    const stmt = db.prepare('SELECT * FROM test');
    assert.eq(stmt.all()[0].value, 'hello');

    db.close();
    stmt.finalize();
}

function testDefaultPageAndCacheSizes() {
    const db = new Database();

    assert.eq(db.prepare('PRAGMA page_size').all()[0].page_size, 8192);
    assert.eq(db.prepare('PRAGMA cache_size').all()[0].cache_size, -16384);

    db.close();
}

function testIntegerResultPrecision() {
    const db = new Database();
    const row = db.prepare(`
        SELECT
            9007199254740991 AS safe_max,
            9007199254740992 AS unsafe_power,
            9007199254740993 AS unsafe_adjacent,
            9223372036854775807 AS int64_max,
            -9007199254740991 AS safe_min,
            -9007199254740992 AS unsafe_negative,
            -9223372036854775808 AS int64_min
    `).all()[0];

    assert.eq(typeof row.safe_max, 'number');
    assert.eq(row.safe_max, 9007199254740991);
    assert.eq(typeof row.safe_min, 'number');
    assert.eq(row.safe_min, -9007199254740991);

    assert.eq(typeof row.unsafe_power, 'bigint');
    assert.eq(row.unsafe_power, 9007199254740992n);
    assert.eq(row.unsafe_adjacent, 9007199254740993n);
    assert.ok(row.unsafe_power !== row.unsafe_adjacent, 'adjacent unsafe integers remain distinct');
    assert.eq(row.int64_max, 9223372036854775807n);
    assert.eq(row.unsafe_negative, -9007199254740992n);
    assert.eq(row.int64_min, -9223372036854775808n);

    db.close();
}

testTypes();
testExistingDB();

const newDb = path.join(import.meta.dirname, `db-${tjs.pid}.sqlite`);

testTypes(newDb);

const result = await tjs.stat(newDb);

assert.ok(result.isFile, 'file was created ok');

await tjs.remove(newDb);

testNewDbNoCreate();
testCloseWithLiveStatement();
testDefaultPageAndCacheSizes();
testIntegerResultPrecision();

function testTransactions() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }
    });

    insMany([
        [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
        [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
        [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
        [ 'baz', 666, 6.6, null ],
    ]);

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.eq(data1.length, 4);
}

function testTransactionsError() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        throw new Error('oops!');
    });

    assert.throws(() => insMany([
        [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
        [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
        [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
        [ 'baz', 666, 6.6, null ],
    ]), Error, 'an error is thrown');

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.falsy(db.inTransaction);
    assert.eq(data1.length, 0);
}

function testTransactionsNested() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const ins2 = db.prepare('INSERT INTO test (txt, int) VALUES(?, ?)');

    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        throw new Error('oops!');
    });

    const insMany2 = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        try {
            insMany([
                [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
                [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
                [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
                [ 'baz', 666, 6.6, null ]
            ]);
        } catch(_) {
            // Ignore, so the outer transaction succeeds.
        }
    });

    insMany2([
        [ '1234', 1234 ],
        [ '4321', 4321 ],
    ]);

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.falsy(db.inTransaction);
    assert.eq(data1.length, 2);
}

function testExtensions(){
	let sopath = './build/libsqlite-test.so';
	switch(navigator.userAgentData.platform){
		case 'Linux':
			sopath = './build/libsqlite-test.so';
			break;
		case 'macOS':
			sopath = './build/libsqlite-test.dylib';
			break;
		case 'Windows':
			sopath = './build/libsqlite-test.dll';
		break;
	}

    const db = new Database();
    db.loadExtension(sopath, 'sqlite_test_ext_init')
    assert.eq(db.prepare("SELECT testfn();").all()[0]["testfn()"], 43)
}

testTransactions();
testTransactionsError();
testTransactionsNested();
testExtensions();
