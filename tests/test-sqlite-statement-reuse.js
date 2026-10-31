import assert from 'tjs:assert';
import { Database } from 'tjs:sqlite';


// sqlite3_reset and sqlite3_finalize return the error of a statement's last
// step, which the call that ran it already threw. A statement whose call
// failed runs normally on the next call, and finalizes without throwing.
const SQLITE_CONSTRAINT = 19;

function caught(operation) {
    try {
        operation();
    } catch (error) {
        return error;
    }
}

const db = new Database(':memory:');

db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY)');

const insert = db.prepare('INSERT INTO t VALUES (?)');

insert.run(1);
assert.eq(caught(() => insert.run(1))?.errno, SQLITE_CONSTRAINT, 'run reports the failure');
insert.run(2);
assert.eq(caught(() => insert.run(2))?.errno, SQLITE_CONSTRAINT, 'run reports a second failure');
assert.eq(caught(() => insert.finalize()), undefined, 'finalize after a failed run');

const returning = db.prepare('INSERT INTO t VALUES (?) RETURNING id');

assert.eq(caught(() => returning.all(1))?.errno, SQLITE_CONSTRAINT, 'all reports the failure');
assert.eq(JSON.stringify(returning.all(3)), '[{"id":3}]', 'all after a failed all');
assert.eq(caught(() => returning.all(3))?.errno, SQLITE_CONSTRAINT, 'all reports a second failure');
assert.eq(caught(() => returning.finalize()), undefined, 'finalize after a failed all');

assert.eq(JSON.stringify(db.prepare('SELECT id FROM t ORDER BY id').all()), '[{"id":1},{"id":2},{"id":3}]');
db.close();

console.log('sqlite statement reuse: passed');
