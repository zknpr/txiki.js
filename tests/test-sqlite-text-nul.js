import assert from 'tjs:assert';
import { AsyncDatabase, Database } from 'tjs:sqlite';


// TEXT may contain NUL. Every read path returns it by length, as binds store it.
const dir = await tjs.makeTempDir(`${tjs.tmpDir}/tjs-sqlite-nul-XXXXXX`);

try {
    const path = `${dir}/nul.db`;
    const db = new Database(path, { create: true });

    db.exec('CREATE TABLE t(v TEXT)');
    db.exec('INSERT INTO t VALUES (\'a\' || char(0) || \'b\')');
    db.prepare('INSERT INTO t VALUES (?)').run('c\0d');

    const query = 'SELECT v, length(CAST(v AS BLOB)) AS bytes FROM t ORDER BY rowid';
    const expected = [ { v: 'a\0b', bytes: 3 }, { v: 'c\0d', bytes: 3 } ];
    const sync = db.prepare(query).all().map(row => ({ ...row }));

    assert.eq(JSON.stringify(sync), JSON.stringify(expected), 'synchronous reads keep NUL');
    db.close();

    const asyncDb = new AsyncDatabase(path);
    const threaded = (await asyncDb.all(query)).map(row => ({ ...row }));

    assert.eq(JSON.stringify(threaded), JSON.stringify(expected), 'thread-pool reads keep NUL');
    await asyncDb.close();
} finally {
    await tjs.remove(dir, { recursive: true });
}

console.log('sqlite text nul: passed');
