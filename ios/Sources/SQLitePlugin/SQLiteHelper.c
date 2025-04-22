#import <sqlite3.h>

int enable_foreign_keys(sqlite3* db) {
    int dummy;
    return sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, &dummy);
}
