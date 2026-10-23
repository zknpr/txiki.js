import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


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

function attachIsDeniedUnlessPermitted(dir) {
    const outsidePath = `${dir}/outside.db`;

    createOutsideDatabase(outsidePath);

    const db = new Database(`${dir}/main.db`, { create: true });

    assertDenied(() => db.exec(`ATTACH ${quote(outsidePath)} AS x`), 'ATTACH of an existing file is refused');

    // Control arm: the same statement succeeds once permitted, so the refusal
    // above comes from the authorizer, not from the path or the syntax.
    db.permitAttach(outsidePath);
    db.exec(`ATTACH ${quote(outsidePath)} AS x`);
    assert.eq(db.prepare('SELECT value FROM x.secret').all()[0].value, 'outside', 'the permitted path attaches');
    assertDenied(() => db.exec('DETACH x'), 'DETACH is refused');

    db.permitAttach(null);
    assertDenied(() => db.exec(`ATTACH ${quote(outsidePath)} AS y`), 'withdrawing the permit refuses again');

    // A filename that is not a string literal reaches the authorizer as NULL.
    db.permitAttach(outsidePath);
    assertDenied(
        () => db.exec(`ATTACH ${quote(outsidePath.slice(0, -3))} || '.db' AS z`),
        'an expression filename is refused even when it evaluates to the permitted path',
    );
    db.permitAttach(null);

    // Plain VACUUM attaches a private temporary database named ''.
    db.exec('ATTACH \'\' AS scratch');
    db.exec('CREATE TABLE t(v); INSERT INTO t VALUES (1); VACUUM;');
    db.close();

    const readOnly = new Database(`${dir}/main.db`, { readOnly: true });

    assertDenied(
        () => readOnly.exec(`ATTACH ${quote(outsidePath)} AS x`),
        'a read-only connection refuses ATTACH, which would otherwise read the file',
    );
    readOnly.close();
}

async function vacuumIntoNeedsThePermit(dir) {
    const db = new Database(`${dir}/vacuum.db`, { create: true });
    const deniedCopy = `${dir}/denied-copy.db`;
    const permittedCopy = `${dir}/permitted-copy.db`;

    db.exec('CREATE TABLE t(v); INSERT INTO t VALUES (42);');

    assertDenied(() => db.exec(`VACUUM INTO ${quote(deniedCopy)}`), 'VACUUM INTO an unpermitted path is refused');
    assert.ok(!(await exists(deniedCopy)), 'a refused VACUUM INTO creates no file');

    db.permitAttach(permittedCopy);
    db.exec(`VACUUM main INTO ${quote(permittedCopy)}`);
    db.permitAttach(null);
    assert.ok(await exists(permittedCopy), 'the permitted VACUUM INTO writes its destination');
    db.close();

    const copy = new Database(permittedCopy, { readOnly: true });

    assert.eq(copy.prepare('SELECT v FROM t').all()[0].v, 42, 'the copy holds the data');
    copy.close();
}

async function asyncConnectionsAreCovered(dir) {
    const outsidePath = `${dir}/outside.db`;
    const db = new AsyncDatabase(`${dir}/vacuum.db`);
    const deniedCopy = `${dir}/async-denied-copy.db`;
    const permittedCopy = `${dir}/async-permitted-copy.db`;

    await assertDeniedAsync(db.run(`ATTACH ${quote(outsidePath)} AS x`, []), 'thread-pool ATTACH is refused');
    await assertDeniedAsync(db.run('VACUUM main INTO ?', [ deniedCopy ]), 'bound VACUUM INTO is refused');
    assert.ok(!(await exists(deniedCopy)), 'a refused async VACUUM INTO creates no file');

    // The embedder's own snapshot: permit, VACUUM INTO a bound path, withdraw.
    db.permitAttach(permittedCopy);

    try {
        await db.run('VACUUM main INTO ?', [ permittedCopy ]);
    } finally {
        db.permitAttach(null);
    }

    assert.ok(await exists(permittedCopy), 'the permitted async VACUUM INTO writes its destination');
    await assertDeniedAsync(
        db.run('VACUUM main INTO ?', [ `${dir}/after-withdraw.db` ]),
        'the async permit is withdrawn',
    );
    await db.close();
}

function permitArgumentsAreValidated() {
    const db = new Database();

    for (const value of [ '', 'a\0b', 42, {} ]) {
        assert.throws(() => db.permitAttach(value), TypeError, `permitAttach rejects ${JSON.stringify(value)}`);
    }

    db.permitAttach(undefined);
    db.permitAttach(null);
    db.close();
    assert.throws(() => db.permitAttach('/x.db'), Error, 'permitAttach on a closed database throws');
}

const dir = await tjs.makeTempDir(`${tjs.tmpDir}/tjs-sqlite-attach-XXXXXX`);

try {
    bundledVersionMeetsFloor();
    attachIsDeniedUnlessPermitted(dir);
    await vacuumIntoNeedsThePermit(dir);
    await asyncConnectionsAreCovered(dir);
    permitArgumentsAreValidated();
} finally {
    await tjs.remove(dir, { recursive: true });
}

console.log('sqlite attach authority: passed');
