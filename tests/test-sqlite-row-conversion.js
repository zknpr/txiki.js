import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database } from 'tjs:sqlite';


// A row that fails to convert must not leave its statement mid-step. That
// keeps the statement active, so VACUUM fails with "SQL statements in
// progress", and on a table it holds a read transaction that blocks writers.
// A 32 MiB TEXT cannot be converted under a 16 MB memory limit.
//
// Since QuickJS 0.17 (quickjs-ng 90aa2c4) an out-of-memory error cannot be
// caught, and running out of memory is the only way converting a row can fail:
// SQLITE_MAX_LENGTH (1e9) is below QuickJS's 2^30 - 1 string limit. So a
// failed conversion now ends the process, and the reset that the module still
// does on that path (b45ac83e) can no longer be observed from JavaScript. This
// test pins that: nothing after the failed call runs, not even its catch.
const BYTES = 32 * 1024 * 1024;
const MEMORY_LIMIT = 16 * 1000 * 1000;

// Control arm: without the limit the same row converts.
const db = new Database();
const [ row ] = db.prepare('SELECT printf(\'%.*c\', ?, \'x\') AS big').all(BYTES);

assert.eq(row.big.length, BYTES, 'the row converts without a memory limit');
db.close();

const args = [
    tjs.exePath,
    '--memory-limit',
    String(MEMORY_LIMIT),
    'run',
    path.join(import.meta.dirname, 'helpers', 'sqlite-row-oom.js'),
    String(BYTES)
];
const proc = tjs.spawn(args, { stdout: 'pipe', stderr: 'pipe' });
const [ status, stdout, stderr ] = await Promise.all([ proc.wait(), proc.stdout.text(), proc.stderr.text() ]);

assert.ok(status.exit_status !== 0 && status.term_signal === null, `the helper fails without crashing: ${stderr}`);
assert.ok(/InternalError: out of memory/.test(stderr), `the row fails to convert under the limit: ${stderr}`);
assert.eq(stdout, '', 'the out-of-memory error is not caught, so the helper reports nothing');

console.log('sqlite row conversion: passed');
