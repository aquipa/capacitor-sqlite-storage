import { registerPlugin } from '@capacitor/core';

import type { SQLitePlugin } from './definitions';

const SQLite = registerPlugin<SQLitePlugin>('SQLite', {
  web: () => import('./web').then((m) => new m.SQLiteWeb()),
});

export * from './definitions';
export { SQLite };
