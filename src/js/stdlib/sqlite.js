import core from 'tjs:internal/core';
const sqlite3 = core.sqlite3;
const SQLITE_INTERRUPT = 9;
const SQLITE_BUSY = 5;

let controllers;
let runDatabaseSync;

function busyError() {
    return Object.assign(new Error('Database is busy with another operation'), { errno: SQLITE_BUSY });
}

// Every connection refuses ATTACH (see tjs_sqlite3_authorizer) except plain
// VACUUM's private temporary database and the one path permitted here.
function checkAttachPermit(path) {
    if (path === null || path === undefined) {
        return;
    }

    if (typeof path !== 'string' || path.length === 0 || path.includes('\0')) {
        throw new TypeError('An ATTACH permit must be a non-empty path without NUL characters, or null');
    }
}

class Database {
    #handle;
    #syncDepth = 0;
    #activeOperation;

    static {
        runDatabaseSync = (database, operation) => database.#runSync(operation);
    }

    #runSync(operation) {
        if (this.#activeOperation) {
            throw busyError();
        }

        // Parameter getters and transaction callbacks can re-enter JavaScript.
        // They must not start threaded work before the synchronous call returns.
        this.#syncDepth++;

        try {
            return operation();
        } finally {
            this.#syncDepth--;
        }
    }

    constructor(dbName = ':memory:', options = { create: true, readOnly: false }) {
        let flags = 0;

        if (options.create) {
            flags |= sqlite3.SQLITE_OPEN_CREATE;
        }

        if (options.readOnly) {
            flags |= sqlite3.SQLITE_OPEN_READONLY;
        } else {
            flags |= sqlite3.SQLITE_OPEN_READWRITE;
        }

        this.#handle = sqlite3.open(dbName, flags);
    }

    close() {
        return this.#runSync(() => {
            if (this.#handle) {
                sqlite3.close(this.#handle);
                this.#handle = null;
            }
        });
    }

    [Symbol.dispose]() {
        this.close();
    }

    exec(sql) {
        return this.#runSync(() => {
            if (!this.#handle) {
                throw new Error('Invalid DB');
            }

            sqlite3.exec(this.#handle, sql);
        });
    }

    async allAsync(sql, params = [], options = {}) {
        if (this.#activeOperation || this.#syncDepth !== 0) {
            throw busyError();
        }

        if (!this.#handle) {
            throw new Error('Invalid DB');
        }

        const handle = this.#handle;
        const activeOperation = { interruptOrigin: null };

        this.#activeOperation = activeOperation;
        let signal;

        const onAbort = () => {
            if (!activeOperation.interruptOrigin) {
                activeOperation.interruptOrigin = 'signal';
            }

            sqlite3.cancel_async(handle);
            sqlite3.interrupt(handle);
        };

        try {
            signal = options?.signal;

            if (signal?.aborted) {
                throw new Error('Aborted');
            }

            signal?.addEventListener('abort', onAbort, { once: true });

            if (signal?.aborted) {
                throw new Error('Aborted');
            }

            return await sqlite3.async_all(handle, sql, params);
        } catch (error) {
            if (activeOperation.interruptOrigin === 'signal' && error?.errno === SQLITE_INTERRUPT) {
                throw new Error('Aborted', { cause: error });
            }

            throw error;
        } finally {
            try {
                signal?.removeEventListener('abort', onAbort);
            } finally {
                this.#activeOperation = undefined;
            }
        }
    }

    interrupt() {
        if (this.#handle) {
            if (this.#activeOperation && !this.#activeOperation.interruptOrigin) {
                this.#activeOperation.interruptOrigin = 'direct';
            }

            sqlite3.interrupt(this.#handle);
        }
    }

    setQueryDeadline(ms) {
        return this.#runSync(() => {
            if (!this.#handle) {
                throw new Error('Invalid DB');
            }

            sqlite3.set_query_deadline(this.#handle, ms);
        });
    }

    clearQueryDeadline() {
        return this.#runSync(() => {
            if (!this.#handle) {
                throw new Error('Invalid DB');
            }

            sqlite3.clear_query_deadline(this.#handle);
        });
    }

    prepare(sql) {
        return this.#runSync(() => {
            if (!this.#handle) {
                throw new Error('Invalid DB');
            }

            return new Statement(sqlite3.prepare(this.#handle, sql), this);
        });
    }

    // Code for transactions is largely copied from better-sqlite3 and Bun
    // https://github.com/JoshuaWise/better-sqlite3/blob/master/lib/methods/transaction.js
    // https://github.com/oven-sh/bun/blob/main/src/js/bun/sqlite.ts

    get inTransaction() {
        return this.#runSync(() => {
            if (!this.#handle) {
                return false;
            }

            return sqlite3.in_transaction(this.#handle);
        });
    }

    transaction(fn) {
        if (typeof fn !== 'function') {
            throw new TypeError('Expected first argument to be a function');
        }

        const db = this;
        const controller = getController(db);

        // Each version of the transaction function has these same properties.
        const properties = {
            default: { value: wrapTransaction(fn, db, controller.default) },
            deferred: { value: wrapTransaction(fn, db, controller.deferred) },
            immediate: { value: wrapTransaction(fn, db, controller.immediate) },
            exclusive: { value: wrapTransaction(fn, db, controller.exclusive) },
        };

        Object.defineProperties(properties.default.value, properties);
        Object.defineProperties(properties.deferred.value, properties);
        Object.defineProperties(properties.immediate.value, properties);
        Object.defineProperties(properties.exclusive.value, properties);

        // Return the default version of the transaction function.
        return properties.default.value;
    }

    loadExtension(file, entrypoint=undefined) {
        return this.#runSync(() => sqlite3.load_extension(this.#handle,file,entrypoint));
    }

    permitAttach(path) {
        checkAttachPermit(path);

        return this.#runSync(() => {
            if (!this.#handle) {
                throw new Error('Invalid DB');
            }

            sqlite3.set_attach_permit(this.#handle, path ?? null);
        });
    }
}

// Return the database's cached transaction controller, or create a new one.
const getController = db => {
    let controller = (controllers ||= new WeakMap()).get(db);

    if (!controller) {
        const shared = {
            commit: db.prepare('COMMIT'),
            rollback: db.prepare('ROLLBACK'),
            savepoint: db.prepare('SAVEPOINT `\t_bs3.\t`'),
            release: db.prepare('RELEASE `\t_bs3.\t`'),
            rollbackTo: db.prepare('ROLLBACK TO `\t_bs3.\t`'),
        };

        controller = {
            default: Object.assign({ begin: db.prepare('BEGIN') }, shared),
            deferred: Object.assign({ begin: db.prepare('BEGIN DEFERRED') }, shared),
            immediate: Object.assign({ begin: db.prepare('BEGIN IMMEDIATE') }, shared),
            exclusive: Object.assign({ begin: db.prepare('BEGIN EXCLUSIVE') }, shared),
        };

        controllers.set(db, controller);
    }

    return controller;
};

// Return a new transaction function by wrapping the given function.
const wrapTransaction = (fn, db, { begin, commit, rollback, savepoint, release, rollbackTo }) =>
    function transaction() {
        return runDatabaseSync(db, () => {
            let before, after, undo;

            if (db.inTransaction) {
                before = savepoint;
                after = release;
                undo = rollbackTo;
            } else {
                before = begin;
                after = commit;
                undo = rollback;
            }

            try {
                before.run();

                const result = Function.prototype.apply.call(fn, this, arguments);

                after.run();

                return result;
            } catch (ex) {
                if (db.inTransaction) {
                    undo.run();

                    if (undo !== rollback) {
                        after.run();
                    }
                }

                throw ex;
            }
        });
    };

class Statement {
    #stmt;
    #database;

    constructor(stmt, database) {
        this.#stmt = stmt;
        this.#database = database;
    }

    finalize() {
        return runDatabaseSync(this.#database, () => sqlite3.stmt_finalize(this.#stmt));
    }

    [Symbol.dispose]() {
        this.finalize();
    }

    toString() {
        return runDatabaseSync(this.#database, () => sqlite3.stmt_expand(this.#stmt));
    }

    all(...args) {
        if (args && args.length === 1 && typeof args[0] === 'object') {
            args = args[0];
        }

        return runDatabaseSync(this.#database, () => sqlite3.stmt_all(this.#stmt, args));
    }

    run(...args) {
        if (args && args.length === 1 && typeof args[0] === 'object') {
            args = args[0];
        }

        return runDatabaseSync(this.#database, () => sqlite3.stmt_run(this.#stmt, args));
    }
}


class AsyncDatabase {
    #handle;
    #tail = Promise.resolve();
    #closing = false;
    #closePromise;
    #activeOperation;

    constructor(dbName = ':memory:', options = { create: true, readOnly: false }) {
        let flags = 0;

        if (options.create) {
            flags |= sqlite3.SQLITE_OPEN_CREATE;
        }

        if (options.readOnly) {
            flags |= sqlite3.SQLITE_OPEN_READONLY;
        } else {
            flags |= sqlite3.SQLITE_OPEN_READWRITE;
        }

        this.#handle = sqlite3.open(dbName, flags);
    }

    #enqueue(operation, signal) {
        if (!this.#handle || this.#closing) {
            return Promise.reject(new Error('Invalid DB'));
        }

        const handle = this.#handle;
        const result = this.#tail.then(() => {
            if (signal) {
                return this.#runSignalled(handle, operation, signal);
            }

            return operation(handle);
        });

        // A rejected operation must not poison the per-connection FIFO.
        this.#tail = result.then(() => undefined, () => undefined);

        return result;
    }

    async #runSignalled(handle, operation, signal) {
        if (signal.aborted) {
            throw new Error('Aborted');
        }

        const activeOperation = { interruptOrigin: null };

        const onAbort = () => {
            if (!activeOperation.interruptOrigin) {
                activeOperation.interruptOrigin = 'signal';
            }

            // interrupt() alone is not enough: SQLite clears its interrupt
            // flag while no statement is active, discarding aborts that land
            // before the queued request starts stepping. cancel_async marks
            // the request itself so the worker rejects it before running.
            sqlite3.cancel_async(handle);
            sqlite3.interrupt(handle);
        };

        this.#activeOperation = activeOperation;

        try {
            signal.addEventListener('abort', onAbort, { once: true });

            if (signal.aborted) {
                throw new Error('Aborted');
            }

            return await operation(handle);
        } catch (error) {
            // Direct interrupt() calls retain their native SQLITE_INTERRUPT error.
            if (activeOperation.interruptOrigin === 'signal' && error?.errno === SQLITE_INTERRUPT) {
                throw new Error('Aborted', { cause: error });
            }

            throw error;
        } finally {
            try {
                signal.removeEventListener('abort', onAbort);
            } finally {
                if (this.#activeOperation === activeOperation) {
                    this.#activeOperation = undefined;
                }
            }
        }
    }

    #parseOperationArgs(args) {
        let options;
        const optionsCandidate = args[1];

        // Preserve a legacy Uint8Array positional parameter while accepting
        // the incumbent's run/all(sql, params, options) call shape.
        if (args.length === 2 && optionsCandidate !== null && typeof optionsCandidate === 'object' &&
            !(optionsCandidate instanceof Uint8Array)) {
            options = args.pop();
        }

        if (options && args.length === 1 && args[0] === undefined) {
            args = [];
        } else if (args.length === 1 && typeof args[0] === 'object') {
            args = args[0];
        }

        return { params: args, signal: options?.signal };
    }

    run(sql, ...args) {
        const { params, signal } = this.#parseOperationArgs(args);

        return this.#enqueue(handle => sqlite3.async_run(handle, sql, params), signal);
    }

    all(sql, ...args) {
        const { params, signal } = this.#parseOperationArgs(args);

        return this.#enqueue(handle => sqlite3.async_all(handle, sql, params), signal);
    }

    interrupt() {
        if (this.#handle) {
            if (this.#activeOperation && !this.#activeOperation.interruptOrigin) {
                this.#activeOperation.interruptOrigin = 'direct';
            }

            sqlite3.interrupt(this.#handle);
        }
    }

    // Takes effect immediately, including for work already queued.
    permitAttach(path) {
        checkAttachPermit(path);

        if (!this.#handle || this.#closing) {
            throw new Error('Invalid DB');
        }

        sqlite3.set_attach_permit(this.#handle, path ?? null);
    }

    close() {
        if (this.#closePromise) {
            return this.#closePromise;
        }

        if (!this.#handle) {
            return Promise.resolve();
        }

        const handle = this.#handle;

        this.#closing = true;

        const close = this.#tail.then(() => sqlite3.close(handle));

        this.#closePromise = close.then(() => {
            this.#handle = null;
        }, error => {
            this.#closing = false;
            this.#closePromise = undefined;
            throw error;
        });
        this.#tail = this.#closePromise.then(() => undefined, () => undefined);

        return this.#closePromise;
    }

    [Symbol.asyncDispose]() {
        return this.close();
    }
}


export { AsyncDatabase, Database };
