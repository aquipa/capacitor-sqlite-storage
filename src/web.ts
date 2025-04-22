import { WebPlugin } from '@capacitor/core';

import type { SQLitePlugin } from './definitions';

export class SQLiteWeb extends WebPlugin implements SQLitePlugin {
  async open(): Promise<void> {
    throw new Error('Web not supported.');
  }

  async close(): Promise<void> {
    throw new Error('Web not supported.');
  }

  async deleteDatabase(): Promise<void> {
    throw new Error('Web not supported.');
  }

  async isDatabaseOpen(): Promise<{ isOpen: boolean }> {
    return { isOpen: false };
  }

  async executeSqlBatch(): Promise<any> {
    throw new Error('Web not supported.');
  }
}
