// CSQLiteCloseGuard.c — see the header. Links the system libsqlite3, the
// same library GRDB's GRDBSQLite module links, so the handle is the same
// library's object.

#include "CSQLiteCloseGuard.h"
#include <sqlite3.h>

int videoscan_sqlite3_no_ckpt_on_close(void *db, int on, int *now) {
    return sqlite3_db_config((sqlite3 *)db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, on, now);
}
