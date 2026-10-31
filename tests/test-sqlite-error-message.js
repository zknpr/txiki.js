import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


// Errors carry SQLite's message for the failure ("no such table: missing"),
// not only the generic text of the code ("SQL logic error").
const SQLITE_ERROR = 1;
const SQLITE_CONSTRAINT = 19;
const SQLITE_RANGE = 25;

function caught(operation) {
    try {
        operation();
    } catch (error) {
        return error;
    }
}

async function caughtAsync(promise) {
    try {
        await promise;
    } catch (error) {
        return error;
    }
}

function assertFailure(error, errno, message, label) {
    assert.ok(error, label);
    assert.eq(error.errno, errno, `${label} (errno)`);
    assert.eq(error.message, message, `${label} (message)`);
}

const dir = await tjs.makeTempDir(`${tjs.tmpDir}/tjs-sqlite-errmsg-XXXXXX`);

try {
    const path = `${dir}/errors.db`;
    const db = new Database(path, { create: true });

    db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER CHECK (v > 0))');
    db.exec('INSERT INTO t VALUES (1, 1)');

    assertFailure(
        caught(() => db.prepare('SELECT * FROM missing')),
        SQLITE_ERROR,
        'no such table: missing',
        'prepare',
    );
    assertFailure(
        caught(() => db.exec('INSERT INTO t VALUES (1, 2)')),
        SQLITE_CONSTRAINT,
        'UNIQUE constraint failed: t.id',
        'exec',
    );

    const insert = db.prepare('INSERT INTO t VALUES (?, ?)');

    assertFailure(caught(() => insert.run(2, 0)), SQLITE_CONSTRAINT, 'CHECK constraint failed: v > 0', 'run');
    insert.finalize();

    const returning = db.prepare('INSERT INTO t VALUES (?, ?) RETURNING id');

    assertFailure(
        caught(() => returning.all(1, 3)),
        SQLITE_CONSTRAINT,
        'UNIQUE constraint failed: t.id',
        'all',
    );
    returning.finalize();

    assertFailure(
        await caughtAsync(db.allAsync('SELECT nope FROM t')),
        SQLITE_ERROR,
        'no such column: nope',
        'allAsync prepare',
    );
    assertFailure(
        await caughtAsync(db.allAsync('INSERT INTO t VALUES (?, ?) RETURNING id', [ 3, -1 ])),
        SQLITE_CONSTRAINT,
        'CHECK constraint failed: v > 0',
        'allAsync step',
    );
    db.close();

    const asyncDb = new AsyncDatabase(path);

    assertFailure(
        await caughtAsync(asyncDb.all('SELECT * FROM missing')),
        SQLITE_ERROR,
        'no such table: missing',
        'async all prepare',
    );
    assertFailure(
        await caughtAsync(asyncDb.run('INSERT INTO t VALUES (1, 5)')),
        SQLITE_CONSTRAINT,
        'UNIQUE constraint failed: t.id',
        'async run step',
    );
    // A failure the module detects itself, not SQLite, keeps the generic text
    // of its code: the connection's last call succeeded.
    assertFailure(
        await caughtAsync(asyncDb.all('SELECT :a', { ':b': 1 })),
        SQLITE_RANGE,
        'column index out of range',
        'async missing named parameter',
    );
    await asyncDb.close();
} finally {
    await tjs.remove(dir, { recursive: true });
}

console.log('sqlite error message: passed');
