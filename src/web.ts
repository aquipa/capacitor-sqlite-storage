import { WebPlugin } from '@capacitor/core';

import type { SQLitePlugin } from './definitions';

export class SQLiteWeb extends WebPlugin implements SQLitePlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
