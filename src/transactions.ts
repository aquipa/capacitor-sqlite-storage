import { txLocks } from './constants';
import type { SQLite } from './index';
import { newSQLError } from './utils';

type SQLStatementHandler = (tx: SQLitePluginTransaction, result: any) => void;
type SQLStatementErrorHandler = (tx: SQLitePluginTransaction, error: any) => boolean | void;

interface SQLExecuteItem {
  sql: string;
  params: any[];
  success: SQLStatementHandler | null;
  error: SQLStatementErrorHandler | null;
}

export class SQLitePluginTransaction {
  db: SQLite;
  fn: (tx: SQLitePluginTransaction) => void;
  error: ((err: any) => void) | null;
  success: (() => void) | null;
  txlock: boolean;
  readOnly: boolean;
  finalized = false;
  executes: SQLExecuteItem[] = [];

  constructor(
    db: SQLite,
    fn: (tx: SQLitePluginTransaction) => void,
    error: ((err: any) => void) | null,
    success: (() => void) | null,
    txlock: boolean,
    readOnly: boolean,
  ) {
    if (typeof fn !== 'function') {
      throw newSQLError('transaction expected a function');
    }

    this.db = db;
    this.fn = fn;
    this.error = error;
    this.success = success;
    this.txlock = txlock;
    this.readOnly = readOnly;

    if (txlock) {
      this.addStatement('BEGIN', [], null, (_, err) => {
        throw newSQLError(`unable to begin transaction: ${err.message}`, err.code);
      });
    } else {
      this.addStatement('SELECT 1', [], null, null);
    }
  }

  start(): void {
    try {
      this.fn(this);
      this.run();
    } catch (err) {
      txLocks[this.db.dbname].inProgress = false;
      this.db.startNextTransaction();
      if (this.error) {
        this.error(newSQLError(err));
      }
    }
  }

  executeSql(sql: string, values: any[], success?: SQLStatementHandler, error?: SQLStatementErrorHandler): void {
    if (this.finalized) {
      throw {
        message: 'InvalidStateError: This transaction is already finalized.',
        code: 11,
      };
    }

    if (this.readOnly && /^(\s|;)*(?:alter|create|delete|drop|insert|reindex|replace|update)/i.test(sql)) {
      this.handleStatementFailure(error, {
        message: 'invalid sql for a read-only transaction',
      });
      return;
    }

    this.addStatement(sql, values, success ?? null, error ?? null);
  }

  addStatement(
    sql: string,
    values: any[],
    success: SQLStatementHandler | null,
    error: SQLStatementErrorHandler | null,
  ): void {
    const sqlStatement = typeof sql === 'string' ? sql : (sql as any).toString();
    const params = Array.isArray(values)
      ? values.map((v) => {
          const t = typeof v;
          return v === null || v === undefined ? null : t === 'number' || t === 'string' ? v : v.toString();
        })
      : [];

    this.executes.push({ sql: sqlStatement, params, success, error });
  }

  handleStatementSuccess(handler: SQLStatementHandler | null, response: any): void {
    if (!handler) return;

    const rows = response.rows || [];
    const payload = {
      rows: {
        item: (i: number) => rows[i],
        length: rows.length,
      },
      rowsAffected: response.rowsAffected || 0,
      insertId: response.insertId,
    };

    handler(this, payload);
  }

  handleStatementFailure(handler: SQLStatementErrorHandler | null, response: any): void {
    if (!handler) {
      throw newSQLError(`a statement with no error handler failed: ${response.message}`, response.code);
    }

    if (handler(this, response) !== false) {
      throw newSQLError(`a statement error callback did not return false: ${response.message}`, response.code);
    }
  }

  run(): void {
    const batchExecutes = this.executes;
    const mycbmap: Record<number, Record<string, (res: any) => void>> = {};
    let txFailure: any = null;
    let waiting = batchExecutes.length;
    const tropts: {
      params: string[];
      sql: string;
    }[] = [];
    this.executes = [];

    const handlerFor = (index: number, didSucceed: boolean) => (response: any) => {
      if (!txFailure) {
        try {
          const execute = batchExecutes[index];
          if (didSucceed) {
            this.handleStatementSuccess(execute.success, response);
          } else {
            this.handleStatementFailure(execute.error, newSQLError(response));
          }
        } catch (err) {
          txFailure = newSQLError(err);
        }
      }

      if (--waiting === 0) {
        if (txFailure) {
          this.executes = [];
          this.abort(txFailure);
        } else if (this.executes.length > 0) {
          this.run();
        } else {
          this.finish();
        }
      }
    };

    batchExecutes.forEach((request, i) => {
      mycbmap[i] = {
        success: handlerFor(i, true),
        error: handlerFor(i, false),
      };
      tropts.push({
        sql: request.sql,
        params: request.params,
      });
    });

    const mycb = (results: any[]) => {
      results.forEach((r, i) => {
        const cbSet = mycbmap[i];
        if (cbSet && cbSet[r.type]) {
          cbSet[r.type](r.result);
        }
      });
    };

    this.db.bridge
      .backgroundExecuteSqlBatch({
        dbName: this.db.dbname,
        batch: tropts,
      })
      .then((results) => {
        mycb(results.results);
      });
  }

  abort(txFailure: any): void {
    if (this.finalized) return;

    this.finalized = true;

    const done = (cb: ((tx: SQLitePluginTransaction) => void) | null, err?: any) => {
      txLocks[this.db.dbname].inProgress = false;
      this.db.startNextTransaction();
      cb?.(err ? newSQLError(err.message, err.code) : txFailure);
    };

    if (this.txlock) {
      this.addStatement(
        'ROLLBACK',
        [],
        () => done(this.error),
        (_, err) => done(this.error, err),
      );
      this.run();
    } else {
      done(this.error);
    }
  }

  finish(): void {
    if (this.finalized) return;

    this.finalized = true;

    const done = (cb: any, err?: any) => {
      txLocks[this.db.dbname].inProgress = false;
      this.db.startNextTransaction();
      err ? this.error?.(newSQLError(err.message, err.code)) : cb?.();
    };

    if (this.txlock) {
      this.addStatement(
        'COMMIT',
        [],
        () => done(this.success),
        (_, err) => done(this.error, err),
      );
      this.run();
    } else {
      done(this.success);
    }
  }

  abortFromQ(sqlerror: any): void {
    this.error?.(sqlerror);
  }
}
