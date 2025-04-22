import type { SQLitePluginTransaction } from './transactions';

export const DB_STATE_INIT = 'INIT';
export const DB_STATE_OPEN = 'OPEN';

export const READ_ONLY_REGEX = /^(\s|;)*(?:alter|create|delete|drop|insert|reindex|replace|update)/i;

export const txLocks: Record<
  string,
  {
    queue: SQLitePluginTransaction[];
    inProgress: boolean;
  }
> = {};
