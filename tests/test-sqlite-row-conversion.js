import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database } from 'tjs:sqlite';


// A row that fails to convert must not leave its statement mid-step. That
// keeps the statement active, so VACUUM fails with "SQL statements in
// progress", and on a table it holds a read transaction that blocks writers.
// A 32 MiB TEXT cannot be converted under a 16 MB memory limit.
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

assert.eq(status.exit_status, 0, `the helper exits cleanly: ${stderr}`);

const report = JSON.parse(stdout);

assert.eq(report.conversion, 'out of memory', 'the row fails to convert under the limit');
assert.eq(report.vacuum, 'ok', 'the statement is reset after the failed conversion');

console.log('sqlite row conversion: passed');
