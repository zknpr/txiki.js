import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


const SQLITE_ERROR = 1;
const SQLITE_INTERRUPT = 9;
const SQLITE_CANTOPEN = 14;
const SQLITE_AUTH = 23;
// CVE-2026-11822/11824 (FTS5 heap overflow) are fixed in 3.53.2.
const MINIMUM_SQLITE_VERSION = [ 3, 53, 2 ];

const quote = path => `'${path.replaceAll('\'', '\'\'')}'`;

function assertDenied(operation, message) {
    let error;

    try {
        operation();
    } catch (caught) {
        error = caught;
    }

    assert.ok(error, message);
    assert.eq(error.errno, SQLITE_AUTH, `${message} (SQLITE_AUTH)`);
}

async function assertDeniedAsync(promise, message) {
    let error;

    try {
        await promise;
    } catch (caught) {
        error = caught;
    }

    assert.ok(error, message);
    assert.eq(error.errno, SQLITE_AUTH, `${message} (SQLITE_AUTH)`);
}

function assertFailure(error, errno, sqliteMessage, message) {
    assert.ok(error, message);
    assert.eq(error.errno, errno, `${message} (errno)`);

    if (sqliteMessage !== undefined) {
        assert.eq(error.message, sqliteMessage, `${message} (SQLite's message)`);
    }
}

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

async function exists(path) {
    try {
        await tjs.stat(path);

        return true;
    } catch {
        return false;
    }
}

function createOutsideDatabase(path) {
    const outside = new Database(path, { create: true });

    outside.exec('CREATE TABLE secret(value TEXT); INSERT INTO secret VALUES (\'outside\');');
    outside.close();
}

function bundledVersionMeetsFloor() {
    const db = new Database();
    const [ { version } ] = db.prepare('SELECT sqlite_version() AS version').all();

    db.close();

    const parts = version.split('.').map(Number);

    for (let i = 0; i < MINIMUM_SQLITE_VERSION.length; i++) {
        if (parts[i] !== MINIMUM_SQLITE_VERSION[i]) {
            assert.ok(parts[i] > MINIMUM_SQLITE_VERSION[i], `SQLite ${version} predates the CVE floor`);

            return;
        }
    }
}

function attachIsDenied(dir) {
    const outsidePath = `${dir}/outside.db`;

    createOutsideDatabase(outsidePath);

    const db = new Database(`${dir}/main.db`, { create: true });

    // SQLITE_AUTH comes only from an authorizer, so these refusals are the
    // runtime's, not the path's or the syntax's.
    assertDenied(() => db.exec(`ATTACH ${quote(outsidePath)} AS x`), 'ATTACH of an existing file is refused');
    assertDenied(
        () => db.exec(`ATTACH ${quote(outsidePath.slice(0, -3))} || '.db' AS z`),
        'an expression filename is refused',
    );

    // Plain VACUUM attaches a private temporary database named '', and DETACH
    // is refused even for a database the connection could attach.
    db.exec('ATTACH \'\' AS scratch');
    assertDenied(() => db.exec('DETACH scratch'), 'DETACH is refused');
    db.exec('CREATE TABLE t(v); INSERT INTO t VALUES (1); VACUUM;');
    db.close();

    const readOnly = new Database(`${dir}/main.db`, { readOnly: true });

    assertDenied(
        () => readOnly.exec(`ATTACH ${quote(outsidePath)} AS x`),
        'a read-only connection refuses ATTACH, which would otherwise read the file',
    );
    readOnly.close();
}

async function onlyVacuumIntoWritesACopy(dir) {
    const db = new Database(`${dir}/vacuum.db`, { create: true });
    const deniedCopy = `${dir}/denied-copy.db`;
    const copyPath = `${dir}/copy.db`;

    db.exec('CREATE TABLE t(v); INSERT INTO t VALUES (42);');

    assertDenied(() => db.exec(`VACUUM INTO ${quote(deniedCopy)}`), 'SQL-level VACUUM INTO is refused');
    assert.ok(!(await exists(deniedCopy)), 'a refused VACUUM INTO creates no file');

    // Control arm: the same destination through vacuumInto succeeds.
    db.vacuumInto(deniedCopy);
    assert.ok(await exists(deniedCopy), 'vacuumInto writes its destination');
    await tjs.remove(deniedCopy);

    // The destination is accepted only while that statement runs.
    db.vacuumInto(copyPath);
    assertDenied(() => db.exec(`ATTACH ${quote(copyPath)} AS x`), 'the last vacuumInto target stays unattachable');
    await tjs.remove(copyPath);
    assertDenied(() => db.exec(`VACUUM INTO ${quote(copyPath)}`), 'SQL-level VACUUM INTO its target stays refused');
    db.vacuumInto(copyPath);
    db.close();

    const copy = new Database(copyPath, { readOnly: true });

    assert.eq(copy.prepare('SELECT v FROM t').all()[0].v, 42, 'the copy holds the data');
    copy.close();
}

async function asyncConnectionsAreCovered(dir) {
    const outsidePath = `${dir}/outside.db`;
    const db = new AsyncDatabase(`${dir}/vacuum.db`);
    const deniedCopy = `${dir}/async-denied-copy.db`;
    const copyPath = `${dir}/async-copy.db`;

    await assertDeniedAsync(db.run(`ATTACH ${quote(outsidePath)} AS x`, []), 'thread-pool ATTACH is refused');
    await assertDeniedAsync(db.run('VACUUM main INTO ?', [ deniedCopy ]), 'bound VACUUM INTO is refused');
    assert.ok(!(await exists(deniedCopy)), 'a refused async VACUUM INTO creates no file');

    // Operations queued around the snapshot never see its destination
    // accepted, including one submitted before it. The pool runs these jobs
    // one after another, so this checks that the destination is cleared
    // between jobs. It does not exercise the authorizer's thread check:
    // JavaScript cannot use one connection from two threads at once
    // (tjs:internal/core is not importable), so that check is defence in
    // depth no test here can reach.
    const before = db.run(`ATTACH ${quote(copyPath)} AS early`, []);
    const snapshot = db.vacuumInto(copyPath);
    const after = db.run(`ATTACH ${quote(copyPath)} AS late`, []);

    await assertDeniedAsync(before, 'an ATTACH queued before vacuumInto is refused');
    await snapshot;
    await assertDeniedAsync(after, 'an ATTACH queued after vacuumInto is refused');
    assert.ok(await exists(copyPath), 'the async vacuumInto writes its destination');
    await db.close();
}

// A failed or interrupted vacuumInto leaves no destination accepted: an ATTACH
// of it is refused and the next vacuumInto runs. Its errors carry SQLite's
// message, not only the generic text of their code.
async function failuresClearTheDestination(dir) {
    const path = `${dir}/failures.db`;
    const existing = `${dir}/existing.db`;
    const inTransaction = `${dir}/in-transaction.db`;
    const interrupted = `${dir}/interrupted.db`;
    const missingDirectory = `${dir}/missing/copy.db`;
    const db = new Database(path, { create: true });

    db.exec(`CREATE TABLE t(v);
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 20000) INSERT INTO t SELECT x FROM n;`);
    db.vacuumInto(existing);

    assertFailure(
        caught(() => db.vacuumInto(existing)),
        SQLITE_ERROR,
        'output file already exists',
        'vacuumInto refuses an existing destination',
    );
    assertDenied(() => db.exec(`ATTACH ${quote(existing)} AS x`), 'a destination that already existed stays unattachable');

    db.exec('BEGIN');
    assertFailure(
        caught(() => db.vacuumInto(inTransaction)),
        SQLITE_ERROR,
        'cannot VACUUM from within a transaction',
        'vacuumInto fails inside a transaction',
    );
    db.exec('ROLLBACK');
    assertDenied(
        () => db.exec(`ATTACH ${quote(inTransaction)} AS x`),
        'a destination refused inside a transaction stays unattachable',
    );

    // A zero deadline has passed before the snapshot starts, so the progress
    // callback interrupts it once copying the table runs 1000 VDBE ops.
    db.setQueryDeadline(0);
    assertFailure(
        caught(() => db.vacuumInto(interrupted)),
        SQLITE_INTERRUPT,
        undefined,
        'a query deadline interrupts vacuumInto',
    );
    db.clearQueryDeadline();
    assertDenied(() => db.exec(`ATTACH ${quote(interrupted)} AS x`), 'an interrupted destination stays unattachable');

    db.vacuumInto(`${dir}/after-sync-failures.db`);
    db.close();

    const asyncDb = new AsyncDatabase(path);

    assertFailure(
        await caughtAsync(asyncDb.vacuumInto(existing)),
        SQLITE_ERROR,
        'output file already exists',
        'async vacuumInto refuses an existing destination',
    );
    await assertDeniedAsync(
        asyncDb.run(`ATTACH ${quote(existing)} AS x`, []),
        'a destination that already existed stays unattachable on the pool',
    );

    // Accepted, this ATTACH would fail with SQLITE_CANTOPEN instead.
    assertFailure(
        await caughtAsync(asyncDb.vacuumInto(missingDirectory)),
        SQLITE_CANTOPEN,
        undefined,
        'async vacuumInto fails without the parent directory',
    );
    await assertDeniedAsync(
        asyncDb.run(`ATTACH ${quote(missingDirectory)} AS x`, []),
        'a destination in a missing directory stays unattachable',
    );

    await asyncDb.vacuumInto(`${dir}/after-async-failures.db`);
    await asyncDb.close();
}

async function vacuumIntoArgumentsAreValidated() {
    const db = new Database();
    const asyncDb = new AsyncDatabase();

    for (const value of [ '', 'a\0b', 42, {}, null, undefined ]) {
        assert.throws(() => db.vacuumInto(value), TypeError, `vacuumInto rejects ${JSON.stringify(value)}`);

        let error;

        try {
            await asyncDb.vacuumInto(value);
        } catch (caught) {
            error = caught;
        }

        assert.ok(error instanceof TypeError, `async vacuumInto rejects ${JSON.stringify(value)}`);
    }

    db.close();
    await asyncDb.close();
    assert.throws(() => db.vacuumInto('/x.db'), Error, 'vacuumInto on a closed database throws');
}

const dir = await tjs.makeTempDir(`${tjs.tmpDir}/tjs-sqlite-attach-XXXXXX`);

try {
    bundledVersionMeetsFloor();
    attachIsDenied(dir);
    await onlyVacuumIntoWritesACopy(dir);
    await asyncConnectionsAreCovered(dir);
    await failuresClearTheDestination(dir);
    await vacuumIntoArgumentsAreValidated();
} finally {
    await tjs.remove(dir, { recursive: true });
}

console.log('sqlite attach authority: passed');
