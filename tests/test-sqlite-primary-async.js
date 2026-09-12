import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


const LONG_QUERY = `
    WITH RECURSIVE counter(value) AS (
        VALUES(0) UNION ALL SELECT value + 1 FROM counter WHERE value < 1000000000
    ) SELECT sum(value) AS total FROM counter
`;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

async function rejection(promise) {
    try {
        await promise;
    } catch (error) {
        return error;
    }

    assert.fail('operation must reject');
}

function throwsBusy(operation) {
    let error;

    try {
        operation();
    } catch (caught) {
        error = caught;
    }

    assert.ok(error, 'overlapping synchronous access must throw instead of blocking');
    assert.eq(error.errno, 5, 'overlapping access reports SQLITE_BUSY');
}

async function primaryContextAndOwnedResults() {
    const db = new Database();

    try {
        db.exec('CREATE TABLE saved(value); BEGIN; INSERT INTO saved VALUES (7); CREATE TEMP TABLE local(value);');
        db.exec('CREATE INDEX pending_index ON saved(value); INSERT INTO local VALUES (8);');
        const blob = new Uint8Array([0, 127, 255]);
        const rows = await db.allAsync(
            'SELECT saved.value AS saved, local.value AS local, ? AS big, ? AS blob FROM saved, local',
            [9007199254740993n, blob],
        );

        assert.eq(rows[0].saved, 7, 'async execution sees uncommitted data');
        assert.eq(rows[0].local, 8, 'async execution sees the primary TEMP schema');
        assert.eq(rows[0].big, 9007199254740993n, 'unsafe integers remain lossless');
        blob.fill(1);
        assert.eq(rows[0].blob[2], 255, 'returned blobs own their bytes');
        const plan = await db.allAsync('EXPLAIN QUERY PLAN SELECT * FROM saved WHERE value = ?', [7]);

        assert.ok(plan.some(row => row.detail.includes('pending_index')), 'pending DDL is visible');
        assert.ok(db.inTransaction, 'the same transaction remains open');
        db.exec('ROLLBACK');
        assert.eq(db.prepare('SELECT count(*) AS n FROM saved').all()[0].n, 0, 'rollback still owns the write');
    } finally {
        db.close();
    }
}

async function cancellationAndRecovery() {
    const db = new Database();

    try {
        db.exec('CREATE TABLE saved(value); BEGIN; INSERT INTO saved VALUES (7); CREATE TEMP TABLE local(value);');
        const controller = new AbortController();

        db.setQueryDeadline(10000);
        const started = Date.now();
        const result = rejection(db.allAsync(LONG_QUERY, [], { signal: controller.signal }));

        await wait(20);
        controller.abort();
        const error = await result;

        assert.eq(error.message, 'Aborted', 'post-dispatch cancellation rejects with the signal error');
        assert.ok(!('errno' in error), 'signal cancellation does not expose a native error code');
        assert.ok(Date.now() - started < 2000, 'cancellation does not wait for the query deadline');
        db.clearQueryDeadline();
        assert.ok(db.inTransaction, 'cancelling a read preserves the pending transaction');
        assert.eq((await db.allAsync('SELECT value FROM saved'))[0].value, 7);
        assert.eq((await db.allAsync('SELECT count(*) AS n FROM local'))[0].n, 0);
        db.exec('ROLLBACK');
        assert.eq(db.prepare('SELECT count(*) AS n FROM saved').all()[0].n, 0);
    } finally {
        db.close();
    }
}

async function preAbortedAndInvalidRequests() {
    const db = new Database();
    const controller = new AbortController();

    try {
        db.exec('CREATE TABLE saved(value)');
        controller.abort();
        const error = await rejection(db.allAsync('INSERT INTO saved VALUES (1)', [], { signal: controller.signal }));

        assert.eq(error.message, 'Aborted');
        assert.eq(db.prepare('SELECT count(*) AS n FROM saved').all()[0].n, 0);
        await rejection(db.allAsync('SELECT * FROM missing_table'));
        await rejection(db.allAsync('SELECT ?', [Symbol('invalid')]));
        assert.eq((await db.allAsync('SELECT $value AS value', { $value: 23 }))[0].value, 23);
    } finally {
        db.close();
    }

    await rejection(db.allAsync('SELECT 1'));
}

async function abortDuringParameterConversionDoesNotExecute() {
    for (const DatabaseClass of [Database, AsyncDatabase]) {
        const db = new DatabaseClass();
        const query = (sql, params = [], options = {}) => db instanceof Database
            ? db.allAsync(sql, params, options)
            : db.all(sql, params, options);
        const controller = new AbortController();
        const params = [];

        await query('CREATE TABLE saved(value)');
        Object.defineProperty(params, 0, {
            get() {
                controller.abort();

                return 7;
            },
        });
        const error = await rejection(query('INSERT INTO saved VALUES (?)', params, { signal: controller.signal }));

        assert.eq(error.message, 'Aborted', 'abort during binding conversion must not be lost');
        assert.eq((await query('SELECT count(*) AS n FROM saved'))[0].n, 0, 'cancelled write did not execute');
        await db.close();
    }
}

async function overlappingAccessFailsPromptly() {
    const db = new Database();
    const statement = db.prepare('SELECT ? AS value');
    const controller = new AbortController();

    db.setQueryDeadline(10000);
    const result = rejection(db.allAsync(LONG_QUERY, [], { signal: controller.signal }));

    try {
        for (const operation of [
            () => db.exec('SELECT 1'),
            () => db.prepare('SELECT 1'),
            () => db.close(),
            () => db.inTransaction,
            () => db.setQueryDeadline(1),
            () => db.clearQueryDeadline(),
            () => db.loadExtension('not-loaded'),
            () => statement.all(1),
            () => statement.run(1),
            () => statement.finalize(),
            () => statement.toString(),
        ]) {
            throwsBusy(operation);
        }

        assert.eq((await rejection(db.allAsync('SELECT 1'))).errno, 5);
    } finally {
        controller.abort();
        await result;
        db.clearQueryDeadline();
        assert.eq(statement.all(12)[0].value, 12, 'busy refusal did not finalize the statement');
        statement.finalize();
        db.close();
    }
}

async function synchronousReentryCannotStartThreadedWork() {
    const db = new Database();
    const statement = db.prepare('SELECT ? AS value');
    let nested;
    const params = [4];

    Object.defineProperty(params, 0, {
        get() {
            nested = rejection(db.allAsync('SELECT 99'));

            return 4;
        },
    });
    assert.eq(statement.all(params)[0].value, 4);
    assert.eq((await nested).errno, 5, 'a parameter getter cannot start concurrent work');
    db.transaction(() => { nested = rejection(db.allAsync('SELECT 99')); })();
    assert.eq((await nested).errno, 5, 'a synchronous transaction callback cannot start async work');
    statement.finalize();
    db.close();
}

async function garbageCollectionDoesNotBlockCancellation() {
    const db = new Database();
    let statements = Array.from({ length: 100 }, () => db.prepare('SELECT 1'));
    const controller = new AbortController();

    db.setQueryDeadline(10000);
    const result = rejection(db.allAsync(LONG_QUERY, [], { signal: controller.signal }));

    await wait(20);
    const started = Date.now();

    // Dropping the last references invokes native finalizers immediately in
    // ref-counted engines; explicit GC also covers cyclic garbage.
    statements[0].cycle = statements[0];
    statements = null;
    tjs.engine.gc.run();
    const collectionMs = Date.now() - started;

    controller.abort();
    const error = await result;

    assert.ok(collectionMs < 2000, 'statement finalizers must not wait for a running SQLite query');
    assert.eq(error.message, 'Aborted');
    db.clearQueryDeadline();
    assert.eq((await db.allAsync('SELECT 18 AS value'))[0].value, 18);
    db.close();
}

async function deadlinesAndInterruptOrigin() {
    const db = new Database();

    db.setQueryDeadline(1);
    assert.eq((await rejection(db.allAsync(LONG_QUERY))).errno, 9, 'deadlines retain SQLITE_INTERRUPT');
    db.clearQueryDeadline();
    const controller = new AbortController();
    const result = rejection(db.allAsync(LONG_QUERY, [], { signal: controller.signal }));

    await wait(20);
    db.interrupt();
    controller.abort();
    assert.eq((await result).errno, 9, 'direct interrupt wins when it arrived first');
    assert.eq((await db.allAsync('SELECT 19 AS value'))[0].value, 19);
    db.close();
}

async function queuedThreadPoolCancellation() {
    const blockers = Array.from({ length: 4 }, () => ({ db: new AsyncDatabase(), controller: new AbortController() }));
    const blocked = blockers.map(({ db, controller }) => rejection(db.all(LONG_QUERY, [], { signal: controller.signal })));

    await wait(20);
    const db = new Database();
    const controller = new AbortController();
    const victim = rejection(db.allAsync(LONG_QUERY, [], { signal: controller.signal }));

    controller.abort();
    blockers.forEach(blocker => blocker.controller.abort());
    assert.eq((await victim).message, 'Aborted', 'abort before the first native step is not lost');
    await Promise.all(blocked);
    await Promise.all(blockers.map(blocker => blocker.db.close()));
    assert.eq((await db.allAsync('SELECT 20 AS value'))[0].value, 20);
    db.close();
}

async function signalListenersAreReleased() {
    const db = new Database();
    const controller = new AbortController();
    const signal = controller.signal;
    const listeners = new Set();
    const add = signal.addEventListener;
    const remove = signal.removeEventListener;

    Object.defineProperties(signal, {
        addEventListener: {
            value(type, listener, options) {
                listeners.add(listener);
                return add.call(this, type, listener, options);
            },
        },
        removeEventListener: {
            value(type, listener, options) {
                listeners.delete(listener);
                return remove.call(this, type, listener, options);
            },
        },
    });
    for (let i = 0; i < 50; i++) {
        assert.eq((await db.allAsync('SELECT ? AS value', [i], { signal }))[0].value, i);
        assert.eq(listeners.size, 0, 'successful operations remove their abort listener');
    }

    await rejection(db.allAsync('SELECT * FROM missing_table', [], { signal }));
    assert.eq(listeners.size, 0, 'failed operations remove their abort listener');
    controller.abort();
    assert.eq((await db.allAsync('SELECT 21 AS value'))[0].value, 21, 'late abort does not affect the next query');
    db.close();
}

for (const test of [
    primaryContextAndOwnedResults,
    cancellationAndRecovery,
    preAbortedAndInvalidRequests,
    abortDuringParameterConversionDoesNotExecute,
    overlappingAccessFailsPromptly,
    synchronousReentryCannotStartThreadedWork,
    garbageCollectionDoesNotBlockCancellation,
    deadlinesAndInterruptOrigin,
    queuedThreadPoolCancellation,
    signalListenersAreReleased,
]) {
    await test();
    console.log(`${test.name}: passed`);
}
