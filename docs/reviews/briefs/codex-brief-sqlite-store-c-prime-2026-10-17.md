# Codex brief: the SQLite store, parts 1 + 2a (step C′; data-risk: the integrity triggers) — 2026-10-17

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~900 words.

**One sentence (Rick, 2026-10-17):** the catalog moves to SQLite behind a plugin seam; the database must refuse every invalid write itself (triggers, CHECKs, FKs), advance its generation by exactly one per committed write, and refuse to run on a restored copy older than one this Mac already wrote until a person adopts it.

**Design:** `docs/design/catalog_sqlite_migration_2026_10_16.md` §10–§10d; `docs/design/catalog_contract_freeze_2026_10_17.md` §e; the DDL `docs/design/catalog_sqlite_schema_v1.sql` (v1.4; your four passes gated v1.3) and `docs/design/catalog_sqlite_schema_v1_checks.sql`.

**Range:** `4fb6a8b19..356bc83b0` on `main` (merges `5399f6189` part 1, `356bc83b0` part 2a). Paths under `VideoScan/VideoScanCore/`:
- `Sources/VideoScanCore/Store/CatalogRepository.swift` — the seam (Foundation-only protocol; named outcomes).
- `Sources/VideoScanCore/Store/GRDBCatalogRepository.swift` — GRDB 7.11.1 `DatabasePool`; pragmas; `integrity_check` + `foreign_key_check` at open; migrator (`v1_bookkeeping`, `v2_data`, FK checks immediate); `write(as:_:)` = BEGIN IMMEDIATE → body → CAS `UPDATE generations … WHERE generation = ?` (`changes()==1`) → high-water phase 1 (sidecar written BEFORE commit) → history row → COMMIT; `adopt(toHighWater:)`; `verify()`.
- `Sources/VideoScanCore/Store/CatalogHighWater.swift` — the sidecar: temp + fsync + rename + F_FULLFSYNC; parse rules (garbage/empty/lower/higher).
- `Sources/VideoScanCore/Store/CatalogBookkeepingSchema.swift` — part-1 DDL (generations + 7 triggers: the +1 rule, adopt rule).
- `Sources/VideoScanCore/Store/CatalogDataSchema*.swift` — the data DDL generated from the document (drift-pinned).
- `Sources/VideoScanCore/Store/JSONCatalogRepository.swift` — read-only import source.
- Tests: `Tests/VideoScanCoreTests/Store/*.swift` (contract suite parameterised over both repositories; GRDB suite; sensors; schema tests replaying the checks file; scale).

**Attack (prove with file:line, or say it holds):**
1. THE TRIGGER REWRITE (v1.4, `files_no_replace`): the agent rewrote the live-path uniqueness trigger from one subquery (quadratic — partial indexes unused because the fold term sat inside an OR) into two EXISTS terms with `volume_case_sensitive = 0` at top level. Prove the semantics are identical for: two live rows same path same volume; same path different volumes; case-alias on a case-insensitive volume; case-alias on a case-SENSITIVE volume (must be allowed); a tombstoned row at the same path (allowed?); an UPDATE that moves a row onto another live row's path; the `files_case_flag_matches_volume_*` triggers that the rewrite relies on — can a row reach the trigger with the wrong flag?
2. GENERATION + HIGH-WATER: interleavings — crash after phase 1 before COMMIT; crash after COMMIT before the history row is visible (same transaction? prove); two writers on one file (second process) — who loses and how; `adopt` racing a write; sidecar on a different filesystem than the database (rename atomicity); `highwater < generation` is raised silently — is that ever a loss signal? Does `verify()` run the same checks as `open`?
3. OPEN CHECKS: `integrity_check` on a 50 MB file at every open — cost; is `foreign_key_check` run with FKs enabled; a database with `grdb_migrations` ahead of the code (file from a newer app) — refused with words?; `user_version`/`schema_version` 7 for both part-1 and part-2 files — can a part-1 file be mistaken for complete?
4. SEAM: any GRDB or SQLite type leaking through `CatalogRepository`, `CatalogReader`, `CatalogTransaction` (the sensor says no — verify); `read` snapshot isolation vs the writer; the `@Sendable` body rule — can a body capture the repository and deadlock?
5. DDL DRIFT: the Swift copy is generated from the document and the test diffs `sqlite_master` after whitespace normalisation — name a change to the document the normalisation would hide (a changed CHECK constant? a dropped `STRICT`?).
6. FTS5 `content_text_fts` (v1.4 §6d): plain table, regenerable — can it ever be read as evidence; who deletes rows when a derived value is retracted (no triggers on a virtual table) — is the writer rule stated and pinned?
7. SCALE: 100k/100k/300k in 13 s through the write door — any trigger still O(n) per row (name it by EXPLAIN); the 12 ms archival commit — is `fullfsync` actually in effect on APFS (`PRAGMA fullfsync` queried back?).

**Do only this:** findings against 1–7 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the importer (not written), record mapping (not written), UI, wording.

**Do not explore outside the files listed above and their tests.**
