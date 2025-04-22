import { registerPlugin } from '@capacitor/core';

import { DB_STATE_INIT, DB_STATE_OPEN, txLocks } from './constants';
import { SQLitePluginTransaction } from './transactions';
import { newSQLError, nextTick } from './utils';

interface SQLiteBridgePlugin {
  open(options: { dbName: string; location: string }): Promise<void>;
  close(options: { dbName: string }): Promise<void>;
  deleteDatabase(options: { dbName: string; location: string }): Promise<void>;
  isDatabaseOpen(options: { dbName: string }): Promise<{ isOpen: boolean }>;
  backgroundExecuteSqlBatch(options: {
    dbName: string;
    batch: {
      params: string[];
      sql: string;
    }[];
  }): Promise<{
    results: {
      rows?: Record<string, any>[];
      rowsAffected: number;
      lastInsertRowId: number;
    }[];
  }>;
}

const SQLiteBridge = registerPlugin<SQLiteBridgePlugin>('SQLitePlugin');

class SQLite {
  bridge = SQLiteBridge;
  openargs: any;
  dbname: string;
  dblocation: string;
  openSuccess: any;
  openError: any;
  constructor(openargs: { [x: string]: any; name: any }) {
    if (!openargs?.name) {
      throw newSQLError('Cannot create a SQLitePlugin db instance without a db name');
    }
    const dbname = openargs.name;
    if (typeof dbname !== 'string') {
      throw newSQLError('sqlite plugin database name must be a string');
    }

    const dblocations: string[] = ['docs', 'libs', 'nosync'];

    const iosLocationMap: {
      [key: string]: string;
    } = {
      default: 'nosync',
      Documents: 'docs',
      Library: 'libs',
    };

    const dblocation =
      !!openargs.location && openargs.location === 'default'
        ? iosLocationMap.default
        : openargs.iosDatabaseLocation
          ? iosLocationMap[openargs.iosDatabaseLocation]
          : dblocations[openargs.location];
    if (!dblocation) {
      throw newSQLError('sqlite plugin database location must be a string');
    }
    openargs.dblocation = dblocation;
    this.openargs = openargs;
    this.dbname = dbname;
    this.dblocation = dblocation;
    this.openSuccess = () => {
      console.log(`DB opened: ${dbname}`);
    };
    this.openError = (e: { message: any }) => {
      console.log(e.message);
    };
    this.open(this.openSuccess, this.openError);
  }

  databaseFeatures = {
    isSQLitePluginDatabase: true,
  };

  openDBs: { [s: string]: string } = {};

  addTransaction(t: SQLitePluginTransaction) {
    if (!txLocks[this.dbname]) {
      txLocks[this.dbname] = {
        queue: [],
        inProgress: false,
      };
    }
    txLocks[this.dbname].queue.push(t);
    if (this.dbname in this.openDBs && this.openDBs[this.dbname] !== DB_STATE_INIT) {
      this.startNextTransaction();
    } else {
      if (this.dbname in this.openDBs) {
        console.log('new transaction is queued, waiting for open operation to finish');
      } else {
        console.log('database is closed, new transaction is [stuck] waiting until db is opened again!');
      }
    }
  }

  transaction(fn: (tx: SQLitePluginTransaction) => void, error: (arg0: Error) => void, success: (() => void) | null) {
    if (!this.openDBs[this.dbname]) {
      error(newSQLError('database not open'));
      return;
    }
    this.addTransaction(new SQLitePluginTransaction(this, fn, error, success, true, false));
  }

  readTransaction(
    fn: (tx: SQLitePluginTransaction) => void,
    error: ((arg0: Error) => void) | null,
    success: (() => void) | null,
  ) {
    if (!this.openDBs[this.dbname] && error) {
      error(newSQLError('database not open'));
      return;
    }
    this.addTransaction(new SQLitePluginTransaction(this, fn, error, success, false, true));
  }

  startNextTransaction(): void {
    nextTick(
      ((_this) => {
        return () => {
          if (!(_this.dbname in _this.openDBs) || _this.openDBs[_this.dbname] !== DB_STATE_OPEN) {
            console.log('cannot start next transaction: database not open');
            return;
          }
          const txLock = txLocks[this.dbname];
          if (!txLock) {
            console.log('cannot start next transaction: database connection is lost');
            return;
          } else if (txLock.queue.length > 0 && !txLock.inProgress) {
            txLock.inProgress = true;
            const next = txLock.queue.shift();
            if (next) next.start();
          }
        };
      })(this),
    );
  }

  abortAllPendingTransactions() {
    const txLock = txLocks[this.dbname];
    if (!!txLock && txLock.queue.length > 0) {
      for (const tx of txLock.queue) {
        tx.abortFromQ(newSQLError('Invalid database handle'));
      }
      txLock.queue = [];
      txLock.inProgress = false;
    }
  }

  open(success: (arg0: this) => void, error: (arg0: Error) => void) {
    if (this.dbname in this.openDBs) {
      console.log('database already open: ' + this.dbname);
      nextTick(
        ((_this) => {
          return () => {
            success(_this);
          };
        })(this),
      );
    } else {
      console.log('OPEN database: ' + this.dbname);
      const opensuccesscb = ((_this) => {
        return () => {
          console.log('OPEN database: ' + _this.dbname + ' - OK');
          if (!_this.openDBs[_this.dbname]) {
            console.log('database was closed during open operation');
          }
          if (_this.dbname in _this.openDBs) {
            _this.openDBs[_this.dbname] = DB_STATE_OPEN;
          }
          if (!!success) {
            success(_this);
          }
          const txLock = txLocks[_this.dbname];
          if (!!txLock && txLock.queue.length > 0 && !txLock.inProgress) {
            _this.startNextTransaction();
          }
        };
      })(this);
      const openerrorcb = ((_this) => {
        return () => {
          console.log('OPEN database: ' + _this.dbname + ' FAILED, aborting any pending transactions');
          if (!!error) {
            error(newSQLError('Could not open database'));
          }
          delete _this.openDBs[_this.dbname];
          _this.abortAllPendingTransactions();
        };
      })(this);
      this.openDBs[this.dbname] = DB_STATE_INIT;

      SQLiteBridge.close({
        dbName: this.dbname,
      })
        .then(() => {
          return SQLiteBridge.open({
            dbName: this.dbname,
            location: this.dblocation,
          })
            .then(opensuccesscb)
            .catch(openerrorcb);
        })
        .catch(() => {
          return SQLiteBridge.open({
            dbName: this.dbname,
            location: this.dblocation,
          })
            .then(opensuccesscb)
            .catch(openerrorcb);
        });
    }
  }

  close(success: any, error: (arg0: Error | undefined) => void) {
    if (this.dbname in this.openDBs) {
      if (txLocks[this.dbname] && txLocks[this.dbname].inProgress) {
        console.log('cannot close: transaction is in progress');
        error(newSQLError('database cannot be closed while a transaction is in progress'));
        return;
      }
      console.log(`CLOSE database: ${this.dbname}`);
      delete this.openDBs[this.dbname];
      if (txLocks[this.dbname]) {
        console.log(`closing db with transaction queue length: ${txLocks[this.dbname].queue.length}`);
      } else {
        console.log('closing db with no transaction lock state');
      }
      SQLiteBridge.close({
        dbName: this.dbname,
      })
        .then(success)
        .catch(error);
    } else {
      console.log('cannot close: database is not open');
      if (error) {
        nextTick(() => error(undefined));
      }
    }
  }

  executeSql(statement: any, params: any, success: (arg0: any) => any, error: (arg0: any) => any) {
    const mysuccess = (_: any, r: any) => {
      if (!!success) {
        return success(r);
      }
    };
    const myerror = (_: any, e: any) => {
      if (!!error) {
        return error(e);
      }
    };
    const myfn = (tx: {
      addStatement: (arg0: any, arg1: any, arg2: (t: any, r: any) => any, arg3: (t: any, e: any) => any) => void;
    }) => {
      tx.addStatement(statement, params, mysuccess, myerror);
    };
    this.addTransaction(new SQLitePluginTransaction(this, myfn, null, null, false, false));
  }

  sqlBatch(
    sqlStatements: { constructor: ArrayConstructor },
    success: (() => void) | null,
    error: ((err: any) => void) | null,
  ) {
    if (!sqlStatements || sqlStatements.constructor !== Array) {
      throw newSQLError('sqlBatch expects an array');
    }
    const batchList: { sql: any; params: any }[] = [];
    for (const st of sqlStatements as Array<any>) {
      if (st.constructor === Array) {
        if (st.length === 0) {
          throw newSQLError('sqlBatch array element of zero (0) length');
        }
        batchList.push({
          sql: st[0],
          params: st.length === 0 ? [] : st[1],
        });
      } else {
        batchList.push({
          sql: st,
          params: [],
        });
      }
    }
    const myfn = (tx: { addStatement: (arg0: any, arg1: any, arg2: null, arg3: null) => any }) => {
      const results = [];
      for (const elem of batchList) {
        results.push(tx.addStatement(elem.sql, elem.params, null, null));
      }
      return results;
    };
    this.addTransaction(new SQLitePluginTransaction(this, myfn, error, success, true, false));
  }
}

export { SQLite };
