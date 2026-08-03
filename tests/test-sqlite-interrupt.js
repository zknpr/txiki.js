import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


const LONG_QUERY = `
    WITH RECURSIVE counter(value) AS (
        VALUES(0)
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 100000000
    )
    SELECT sum(value) AS total FROM counter
`;

const COMPLETING_QUERY = `
    WITH RECURSIVE counter(value) AS (
        VALUES(0)
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 100000
    )
    SELECT sum(value) AS total FROM counter
`;

async function testAsyncInterruptAndRecovery() {
    const db = new AsyncDatabase();
    const query = db.all(LONG_QUERY);

    setTimeout(() => db.interrupt(), 10);

    let error;
    try {
        await query;
    } catch (ex) {
        error = ex;
    }

    assert.ok(error, 'interrupted async query rejects');
    assert.eq(error.errno, 9, 'interrupted async query reports SQLITE_INTERRUPT');

    const rows = await db.all('SELECT 42 AS value');
    assert.eq(rows[0].value, 42, 'connection remains usable after interrupt');

    await db.close();
}

async function testAsyncInterruptWhileCloseIsQueued() {
    const db = new AsyncDatabase();
    const query = db.all(LONG_QUERY);
    const close = db.close();

    setTimeout(() => db.interrupt(), 10);

    let error;
    try {
        await query;
    } catch (ex) {
        error = ex;
    }

    assert.ok(error, 'interrupt remains callable while close waits for active work');
    assert.eq(error.errno, 9, 'query interrupted during close reports SQLITE_INTERRUPT');
    await close;
}

async function testAsyncOperationsAreFifo() {
    const db = new AsyncDatabase();

    const operations = [
        db.run('CREATE TABLE entries (value INTEGER)'),
        db.run('SAVEPOINT ordered'),
        db.run('INSERT INTO entries VALUES (?)', 1),
        db.run('ROLLBACK TO ordered'),
        db.run('RELEASE ordered'),
        db.run('INSERT INTO entries VALUES (?)', 2),
        db.all('SELECT value FROM entries'),
    ];
    const results = await Promise.all(operations);

    assert.eq(results[6].length, 1, 'FIFO transaction leaves exactly one row');
    assert.eq(results[6][0].value, 2, 'transaction and data statements execute in submission order');

    await db.close();
}

function testSyncDeadlineAndClear() {
    const db = new Database();

    db.setQueryDeadline(1);

    let error;
    try {
        db.prepare(LONG_QUERY).all();
    } catch (ex) {
        error = ex;
    }

    assert.ok(error, 'expired sync query deadline throws');
    assert.eq(error.errno, 9, 'expired sync query deadline reports SQLITE_INTERRUPT');

    db.clearQueryDeadline();

    const rows = db.prepare(COMPLETING_QUERY).all();
    assert.eq(rows[0].total, 5000050000, 'cleared deadline allows a long query to complete');

    db.close();
}

function testSyncInterruptWithoutActiveQuery() {
    const db = new Database();

    db.interrupt();
    assert.eq(db.prepare('SELECT 1 AS value').all()[0].value, 1);

    db.close();
}

async function testQueriesWithoutCancellation() {
    const syncDb = new Database();
    assert.eq(syncDb.prepare('SELECT 1 AS value').all()[0].value, 1);
    syncDb.close();

    const asyncDb = new AsyncDatabase();
    assert.eq((await asyncDb.all('SELECT 2 AS value'))[0].value, 2);
    await asyncDb.run('CREATE TABLE normal (value INTEGER)');
    await asyncDb.run('INSERT INTO normal VALUES (?)', 3);
    assert.eq((await asyncDb.all('SELECT value FROM normal'))[0].value, 3);
    await asyncDb.close();
}

await testAsyncInterruptAndRecovery();
await testAsyncInterruptWhileCloseIsQueued();
await testAsyncOperationsAreFifo();
testSyncDeadlineAndClear();
testSyncInterruptWithoutActiveQuery();
await testQueriesWithoutCancellation();
