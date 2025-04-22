export function newSQLError(error: any, code: number = 0): Error {
  let sqlError = error;

  if (!sqlError) {
    sqlError = new Error('a plugin had an error but provided no response');
  } else if (typeof sqlError === 'string') {
    sqlError = new Error(error);
  } else if (!sqlError.message) {
    sqlError = new Error('an unknown error was returned: ' + JSON.stringify(sqlError));
  }

  (sqlError as any).code = code;
  return sqlError;
}

export const nextTick = window.setImmediate || ((fn: () => void) => window.setTimeout(fn, 0));
