// CSQLiteCloseGuard.h — one non-variadic trampoline for sqlite3_db_config
// (Codex #151-1). Swift cannot call C variadic functions, and
// sqlite3_db_config(db, op, ...) is variadic; this wrapper is the whole
// module. For Rick: an extern "C" trampoline in front of a varargs API.
//
// The handle is passed as `void *` so this header need not include
// <sqlite3.h> (the SQLite3 and GRDBSQLite modules already declare `sqlite3`;
// a third declaration would only invite module conflicts). Pass a
// `sqlite3 *` (GRDB's `Database.sqliteConnection`).

#ifndef CSQLITECLOSEGUARD_H
#define CSQLITECLOSEGUARD_H

/// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE on the connection `db`: `on` = 1 means
/// its close neither checkpoints the WAL into the database nor deletes the
/// -wal / -shm. Returns the SQLite result code (0 = SQLITE_OK) and stores
/// the setting now in force in `*now` when `now` is not NULL.
int videoscan_sqlite3_no_ckpt_on_close(void *db, int on, int *now);

#endif
