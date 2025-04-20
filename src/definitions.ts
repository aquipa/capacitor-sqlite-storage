export interface SQLitePlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
