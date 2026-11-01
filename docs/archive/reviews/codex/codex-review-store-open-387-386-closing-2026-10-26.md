# Codex review — Catalog open #387/#386 — closing pass on Codex #151 F1/F4/F5

- Range: `main..fix/store-durability-codex141`
- Credits spent: unavailable
- Tokens: 147220
- Finding count: 0
- Verdict: merge — F1/F4/F5 are closed by this review; no new data-loss risk found, with #389 excluded as requested.
- Run: 2026-10-26T17:54:33Z (cycle #152, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0  
Verdict: merge — F1/F4/F5 are closed by this review; no new data-loss risk found, with #389 excluded as requested.

Reviewed net `5e5c34f03..71c1f9980`, focusing on `a69e0e2f5..71c1f9980`.

- **F1:** protection precedes schema reads and remains through refusal paths, without a holder. The C trampoline matches [SQLite’s documented API](https://sqlite.org/c3ref/c_dbconfig_defensive.html#sqlitedbconfignockptonclose). After successful lifting, neither GRDB’s synchronous wrapper nor publication introduces another throwing step.
- **F4:** journal inspection and WAL creation use the resolved database path.
- **F5:** descriptor-based `fchmod` restores database permission bits after create-only opening.
- Pooled readers skip `reach`; the busy timeout precedes schema-reading pragmas.

Validation: C shim passed `-Wall -Wextra -Werror` syntax checking; **5 memory-only assertions passed** against Apple SQLite 3.54.0. **Repository suites were not rerun:** this session’s filesystem is read-only. Reviewed the regression tests and commit’s RED/GREEN evidence. No files changed; cold-open timing was not measured.

File verdicts, excluding the deferred #389 findings:

- `GRDBCatalogRepository.swift`: read, no findings.
- `SQLiteWALSidecar.swift`: read, no findings.
- `CatalogPreflightReader.swift`: read, no findings.
- `CSQLiteCloseGuard.c`: read, no findings.
- `CSQLiteCloseGuard.h`: read, no findings.
- `Package.swift`: read, no findings.
- `CatalogStoreOpenVerdictTests.swift`: read, no findings.
- `SQLiteWALSidecarTests.swift`: read, no findings.
- `CatalogStoreDurabilityCodex141Tests.swift`: read, no findings.
- `CatalogDataSchemaTests.swift`: read, no findings.
- `CatalogCornerCases2026_10_25Tests.swift`: read, no findings.

Dependency inspection was limited to the pinned GRDB setup, reader configuration, synchronous execution, and close paths.

## Brief

# Codex review brief — Catalog open: checks inside the writer's first lock, nothing deleted (#387); read-only doors restore a missing -wal (#386) (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "make sure the SQLite database is rock solid" — a catalog this build must refuse is left as found and nothing beside it is ever deleted; a read-only viewer opens a healthy catalog instead of failing with engine words.

**Rulings (docs/DECISIONS.md, 2026-10-26, Rick):** a refused open never deletes a journal file; the open checks run inside the writer's first `BEGIN IMMEDIATE` with the normal busy timeout. Read-only doors create a missing empty `-wal` when the folder is writable (create-only, never truncating), else refuse in words that say why.

**This is the closing pass on YOUR cycle #151 (docs/reviews/codex/codex-review-store-open-387-386-2026-10-26.md).** Fixed in `71c1f9980`: F1 (close protection = SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE via a C trampoline target `CSQLiteCloseGuard` + PERSIST_WAL, installed as the writer's first act before any schema read, lifted just before publish; holder connection removed), F4 (sidecar paths via realpath), F5 (fchmod to the DB mode after O_EXCL create). F2/F3 are filed as GH #389 — do not re-report them. Verify the three fixes, attack the new C shim and the lift-before-publish step, and report anything new only if it is a data-loss risk.

**Range:** `main..fix/store-durability-codex141` (focus `a69e0e2f5..71c1f9980`) — review the NET diff against main; the earlier commits on the branch (admission connection, AdmissionFootprint cleanup) are superseded by `de074ba5c` and `a69e0e2f5`. **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store` (read-only for you).

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
