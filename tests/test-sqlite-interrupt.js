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

async function getRejection(promise, message) {
    let error;
    try {
        await promise;
    } catch (ex) {
        error = ex;
    }

    assert.ok(error, message);
    return error;
}

function assertAbortError(error, message) {
    assert.ok(error instanceof Error, `${message}: rejects with Error`);
    assert.eq(error.message, 'Aborted', `${message}: has the incumbent-compatible message`);
    assert.ok(!('errno' in error), `${message}: does not expose SQLite errno`);
}

async function testAsyncInterruptAndRecovery() {
    const db = new AsyncDatabase();
    const controller = new AbortController();
    const query = db.all(LONG_QUERY, [], { signal: controller.signal });

    setTimeout(() => {
        db.interrupt();
        controller.abort();
    }, 10);

    let error;
    try {
        await query;
    } catch (ex) {
        error = ex;
    }

    assert.ok(error, 'interrupted async query rejects');
    assert.eq(error.errno, 9, 'direct interrupt with a passive signal reports SQLITE_INTERRUPT');

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

async function testPreAbortedSignalDoesNotExecute() {
    const db = new AsyncDatabase();
    await db.run('CREATE TABLE entries (value INTEGER)');

    const controller = new AbortController();
    controller.abort();

    const error = await getRejection(
        db.run('INSERT INTO entries VALUES (?)', [1], { signal: controller.signal }),
        'pre-aborted operation rejects',
    );
    assertAbortError(error, 'pre-aborted operation');

    const rows = await db.all('SELECT count(*) AS count FROM entries');
    assert.eq(rows[0].count, 0, 'pre-aborted SQL is not executed');

    await db.close();
}

async function testSignalAbortInterruptsRunningOperation() {
    const db = new AsyncDatabase();
    const controller = new AbortController();
    const query = db.all(LONG_QUERY, [], { signal: controller.signal });

    setTimeout(() => controller.abort(), 10);

    const error = await getRejection(query, 'running signal-aborted query rejects');
    assertAbortError(error, 'running signal-aborted query');

    const rows = await db.all('SELECT 43 AS value');
    assert.eq(rows[0].value, 43, 'connection remains usable after signal abort');

    await db.close();
}

async function testQueuedAbortedSignalDoesNotExecute() {
    const db = new AsyncDatabase();
    await db.run('CREATE TABLE entries (value INTEGER)');

    const runningController = new AbortController();
    const running = db.all(LONG_QUERY, [], { signal: runningController.signal });
    const queuedController = new AbortController();
    const queued = db.run('INSERT INTO entries VALUES (?)', [1], { signal: queuedController.signal });

    queuedController.abort();
    setTimeout(() => runningController.abort(), 10);

    assertAbortError(
        await getRejection(running, 'running operation rejects after abort'),
        'running operation',
    );
    assertAbortError(
        await getRejection(queued, 'queued operation rejects after abort'),
        'queued operation',
    );

    const rows = await db.all('SELECT count(*) AS count FROM entries');
    assert.eq(rows[0].count, 0, 'queued pre-aborted SQL is not executed');

    await db.run('INSERT INTO entries VALUES (?)', 2);
    assert.eq((await db.all('SELECT value FROM entries'))[0].value, 2, 'FIFO continues after queued abort');

    await db.close();
}

async function testSignalListenersAreRemovedOnSettle() {
    const db = new AsyncDatabase();
    const controller = new AbortController();
    const { signal } = controller;
    const listeners = new Set();
    let additions = 0;
    let removals = 0;
    const addEventListener = signal.addEventListener;
    const removeEventListener = signal.removeEventListener;

    Object.defineProperties(signal, {
        addEventListener: {
            value(type, listener, options) {
                if (type === 'abort') {
                    listeners.add(listener);
                    additions++;
                }
                return addEventListener.call(this, type, listener, options);
            },
        },
        removeEventListener: {
            value(type, listener, options) {
                if (type === 'abort') {
                    listeners.delete(listener);
                    removals++;
                }
                return removeEventListener.call(this, type, listener, options);
            },
        },
    });

    for (let i = 0; i < 50; i++) {
        const rows = await db.all('SELECT ? AS value', [i], { signal });
        assert.eq(rows[0].value, i);
    }

    assert.eq(additions, 50, 'each signalled operation installs one abort listener');
    assert.eq(removals, 50, 'each settled operation removes its abort listener');
    assert.eq(listeners.size, 0, 'no abort listeners remain after settlement');

    controller.abort();
    assert.eq((await db.all('SELECT 44 AS value'))[0].value, 44, 'abort after settlement has no effect');

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

async function testAsyncIntegerResultPrecision() {
    const db = new AsyncDatabase();
    const row = (await db.all(`
        SELECT
            9007199254740991 AS safe_max,
            9007199254740992 AS unsafe_power,
            9007199254740993 AS unsafe_adjacent,
            9223372036854775807 AS int64_max,
            -9007199254740991 AS safe_min,
            -9007199254740992 AS unsafe_negative,
            -9223372036854775808 AS int64_min
    `))[0];

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

    await db.close();
}

await testAsyncInterruptAndRecovery();
await testAsyncInterruptWhileCloseIsQueued();
await testAsyncOperationsAreFifo();
await testPreAbortedSignalDoesNotExecute();
await testSignalAbortInterruptsRunningOperation();
await testQueuedAbortedSignalDoesNotExecute();
await testSignalListenersAreRemovedOnSettle();
testSyncDeadlineAndClear();
testSyncInterruptWithoutActiveQuery();
await testQueriesWithoutCancellation();
await testAsyncIntegerResultPrecision();
