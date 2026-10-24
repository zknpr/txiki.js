import { Database } from 'tjs:sqlite';


// Run by test-sqlite-row-conversion.js under --memory-limit, with the TEXT
// length as the last argument. Converting the row fails; the report says
// whether the connection is still usable for VACUUM afterwards.
const db = new Database();
const statement = db.prepare('SELECT printf(\'%.*c\', ?, \'x\') AS big');
const report = {};

try {
    statement.all(Number(tjs.args.at(-1)));
    report.conversion = 'succeeded';
} catch (error) {
    report.conversion = error?.message ?? String(error);
}

try {
    db.exec('VACUUM');
    report.vacuum = 'ok';
} catch (error) {
    report.vacuum = error?.message ?? String(error);
}

console.log(JSON.stringify(report));
