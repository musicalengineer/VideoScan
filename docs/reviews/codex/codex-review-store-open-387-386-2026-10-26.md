# Codex review — Catalog open: checks in writer's first lock, nothing deleted (#387); restore missing -wal (#386)

- Range: `main..fix/store-durability-codex141`
- Credits spent: unavailable
- Tokens: 169566
- Finding count: 5
- Verdict: block — refusal protection still has gaps, and GRDB can write after validation expires but before confirmation.
- Run: 2026-10-26T17:14:57Z (cycle #151, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — refusal protection still has gaps, and GRDB can write after validation expires but before confirmation.

Reviewed `5e5c34f03..a69e0e2f5`. The existing build passed **49 tests in 5 named suites**. The additional regression recipes below are **not executed RED tests**. No repository edits.

1. **P1 — Refusal-close protection starts too late and depends on a fallible holder.**  
   [GRDBCatalogRepository.swift:322](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:322), [holdFilesAsFound:1227](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1227).

   `PRAGMA synchronous` reads the schema **before** `reach` installs either close guard. A malformed schema can throw there; GRDB closes the writer without `PERSIST_WAL` or a holder. As the last connection, it can checkpoint committed frames and delete both sidecars. An in-memory probe against **Apple SQLite 3.54.0** confirmed this pragma returns `SQLITE_CORRUPT` for malformed schema SQL.

   Separately, when the holder cannot open, `PERSIST_WAL` preserves filenames but does **not** prevent checkpointing into the main file. Consequently, `leftAsFoundWords` can be false. SQLite provides a distinct [NO_CKPT_ON_CLOSE setting](https://sqlite.org/c3ref/c_dbconfig_defensive.html#sqlitedbconfignockptonclose) for this behavior.

   **Regression recipes:** use an uncheckpointed crash image containing malformed schema SQL; assert refusal preserves main/WAL bytes and both sidecars. Also force holder-open failure after the writer opens a newer-schema crash image; assert the main file remains unchanged. Close protection must cover the connection before its first schema read and survive holder failure.

2. **P1 — GRDB’s own writes bypass `confirm`.**  
   [GRDBCatalogRepository.swift:1192](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1192), [prepare:1275](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1275).

   `reach` releases its lock before GRDB’s WAL-mode switch and `grdb_issue_102` transaction. Neither confirms the verdict. Furthermore, GRDB’s `runMigrations` executes `CREATE TABLE IF NOT EXISTS grdb_migrations` **before entering any migration callback**.

   **Regression recipe using the existing hook:** in `injectAdmittedHook`, another connection raises `catalog_state.schema_version` above this build and drops `grdb_migrations`, then commits. Open eventually refuses, but GRDB first recreates that table in the already-inadmissible database. Assert the table remains absent after refusal; the traced path fails that assertion.

   A second barrier immediately after `reach` returns exposes the WAL-switch/init-write window. A later confirmation cannot undo those committed setup writes.

3. **P2 — The hot-journal check remains an unlocked snapshot.**  
   [GRDBCatalogRepository.swift:187](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:187).

   Another rollback-mode writer can leave a hot journal after `hotJournal` returns but before the first schema-reading pragma. SQLite then performs recovery—including journal deletion—before `reach` can refuse the catalog. The later `BEGIN IMMEDIATE` does not protect this earlier interval.

   **Regression recipe:** pause immediately after the byte check; install the existing test’s hot-journal image, representing another writer’s crash; resume opening. Assert refusal preserves the journal and main bytes. The current sequence instead recovers first. This needs protection across the transition to SQLite’s first read, not another unlocked check.

4. **P2 — Sidecar paths disagree with SQLite for a symlinked database.**  
   [GRDBCatalogRepository.swift:1126](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1126), [SQLiteWALSidecar.swift:49](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/SQLiteWALSidecar.swift:49).

   Both helpers append suffixes to the supplied pathname. SQLite resolves the database symlink and uses the **target’s** sidecar names; I verified final-component resolution through the installed Apple VFS.

   **Regression recipes:** open the hot-journal fixture through `alias.sqlite → catalog.sqlite`. The check misses `catalog.sqlite-journal`, permitting recovery and deletion before refusal. Separately, open a healthy WAL catalog without sidecars through that alias: the helper creates `alias.sqlite-wal`, while SQLite needs `catalog.sqlite-wal`, so the viewer still fails. Resolve or explicitly refuse aliases consistently before inspecting or creating sidecars.

5. **P2 — The created WAL does not necessarily receive the database’s permissions.**  
   [SQLiteWALSidecar.swift:52](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/SQLiteWALSidecar.swift:52).

   `open(..., mode)` applies the process umask. Unlike SQLite’s sidecar creation implementation, this helper does not restore the intended mode afterward. It can therefore leave a persistent WAL inaccessible to another user who can access the database.

   **Regression recipe:** database mode `0660`, process umask `0077`, missing WAL. Run the helper and assert WAL mode `0660`; it will be `0600`. Run this test in an isolated process because umask is process-wide.

The pooled-reader `readonly` guard correctly skips `reach`; the busy timeout is installed first. I found no lock-order deadlock in those paths; production-size cold-open timing was not measured.

- `CatalogPreflightReader.swift`: read, no findings independent of its shared helper.
- `CatalogStoreOpenVerdictTests.swift`: read, no findings against existing assertions.
- `SQLiteWALSidecarTests.swift`: read, no findings against existing assertions.
- `CatalogStoreDurabilityCodex141Tests.swift`: read, no findings against existing assertions.
- `CatalogDataSchemaTests.swift`: read, no findings.
- `CatalogCornerCases2026_10_25Tests.swift`: read, no findings against existing assertions.

Scope expansion was limited to `CatalogFileGuard`, the pinned GRDB/SQLite implementation, and official SQLite documentation needed to trace these behaviors.

## Brief

# Codex review brief — Catalog open: checks inside the writer's first lock, nothing deleted (#387); read-only doors restore a missing -wal (#386) (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "make sure the SQLite database is rock solid" — a catalog this build must refuse is left as found and nothing beside it is ever deleted; a read-only viewer opens a healthy catalog instead of failing with engine words.

**Rulings (docs/DECISIONS.md, 2026-10-26, Rick):** a refused open never deletes a journal file; the open checks run inside the writer's first `BEGIN IMMEDIATE` with the normal busy timeout. Read-only doors create a missing empty `-wal` when the folder is writable (create-only, never truncating), else refuse in words that say why.

**Range:** `main..fix/store-durability-codex141` — review the NET diff against main; the earlier commits on the branch (admission connection, AdmissionFootprint cleanup) are superseded by `de074ba5c` and `a69e0e2f5`. **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store` (read-only for you).

**Your earlier findings being closed:** Codex #144 block/4 (docs/reviews/codex/): (1) refusal cleanup could unlink another process's live -shm/-wal; (2) admission was a snapshot; (3) the "second look" connection could checkpoint another writer's frames on close; (4) admission dropped the 5 s busy timeout.

**Shape now:** `OpenVerdict.reach` runs from GRDB's `prepareDatabase` on the writer connection (after pragmas, before GRDB's `setUpWALMode` and its `grdb_issue_102` CREATE/DROP): `BEGIN IMMEDIATE`; integrity_check, foreign_key_check, version check; record `PRAGMA data_version`; ROLLBACK; refusal throws out of pool construction. Every later writing transaction (each migration body, the high-water reconcile) calls `confirm` first: unchanged `data_version` on the same connection → no foreign commit since; changed → re-check. A refusing writer's close is guarded by `SQLITE_FCNTL_PERSIST_WAL` plus a read-only "holder" connection kept open until after the writer closes, so close cannot checkpoint or delete. A hot rollback journal is refused from its bytes before any connection. `busy_timeout` is the first pragma. #386: `Store/SQLiteWALSidecar.swift` `prepareForReadOnlyOpen` — reads the 100-byte header; WAL-mode file with no `-wal` → `open(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW)` with the DB's mode; EEXIST is success; unwritable folder → `.refused(words)`. Wired into `openForReading`, `openReadOnly`, `CatalogPreflightReader`, and the read-write door's read-only fallback.

**In scope:** `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift` (OpenVerdict, makePool, prepareDatabase hook, holdFilesAsFound, confirm call sites, hot-journal check), `Store/SQLiteWALSidecar.swift`, `Store/CatalogPreflightReader.swift`; tests `CatalogStoreOpenVerdictTests.swift`, `SQLiteWALSidecarTests.swift`, `CatalogStoreDurabilityCodex141Tests.swift`, `CatalogDataSchemaTests.swift`, `CatalogCornerCases2026_10_25Tests.swift`.

**Invariants to attack:**
1. **Nothing is deleted or truncated** beside a refused file, by our code or by SQLite's close — including when the holder connection fails to open, and when the refusal happens at a later `confirm` (after GRDB's WAL setup / a migration already ran).
2. **No write reaches a file whose checks would now fail.** Find a write that happens outside a transaction guarded by `confirm` (GRDB internals, `writeWithoutTransaction` pragmas, the F1 `synchronous` set, schema-cookie bumps) or a `data_version` subtlety (it reflects other connections only; same-connection writes; reset across reopen) that lets a foreign commit slip by.
3. **The `prepareDatabase` hook runs on every connection GRDB makes** (readers too?) — does a reader run `BEGIN IMMEDIATE`, take the write lock, or run integrity_check per reader?
4. **Busy timeout and lock order:** the integrity check now runs under the write lock — can that deadlock or starve the app's own readers/other process at launch on a 300 MB catalog?
5. **#386 helper:** races (another process switches journal mode, creates/removes `-wal` between header read and open); symlinked sidecar or DB; permissions/ownership of the created file; a `-wal` created beside a file that is NOT a SQLite DB or is rollback-mode; is creating a 0-byte `-wal` ever harmful for a WAL DB whose `-shm` holds a stale index?
6. **Words truthful:** every refusal string claims exactly what is guaranteed ("wrote nothing to it and removed nothing beside it").

**Evidence already run:** RED seen per test (tables in commit messages); Core `--filter Catalog` 443 tests / 69 suites green, 9 known issues pre-existing; `run_catalog_tests.sh --app-only` 941 passed, 0 failed (2 known issues pre-existing in CatalogQuitCornerTests); sensor lane GREEN 573; manifest errors [].

**Known and accepted (do not report):** GRDBCatalogRepository.swift over SwiftLint file length; history duplication from the rebase (`7cc1fc36a`/`91d5c49a2`); #385 timing tests; ledger atomicity #384.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings."
