# catalog.sqlite cutover acceptance audit (2026-10-19)

The `qa` agent did this read-only. It worked on a read-only `.backup` copy of the real catalog; nothing was written to Application Support. The Manager verified gap 1 in the code and filed it as **#340 (P0)**.

**Verdict: solid, with 6 named gaps.**

## Evidence
| Check | Result |
|---|---|
| integrity_check / foreign_key_check | ok / none. Schema 10, all 5 migrations applied. |
| Reconciles with the JSON | JSON 13,793 = 11,683 kept + 2,110 quarantined. Its SHA-256 matches `catalog.cutover`'s `sourceSHA256`. |
| Rows now | 11,684 (10,702 active, 982 removed). The removal columns and the tombstones agree exactly. 6,441 distinct contents. |
| Full SHA-256 | **11,684 / 11,684**, 0 missing, `pending_rows` = 0. |
| Generations | 54 = high-water 54 = 55 history rows. |
| Quarantine 2,110 | removedNoDigest 1,842 · auditNeverSeen 237 · tier5Finding 28 · auditCouldNotCheck 2 · auditChanged 1 |
| catalog.json frozen | Untouched since 10/18 11:38:53. |
| Crash, disk full, CAS, high-water, savepoint, relaunch | Each covered by named suites, all passing (CatalogHardKill, CatalogDiskFull, GRDBCatalogRepository*, CatalogCommitIsolation, CatalogCutoverRegression, B21–B27). |
| Nightly | The Core lane's first night was 10/19. Every database suite passed. |
| Known issues | One: the near-full high-water case (#338). |
| CatalogLockRealBackupTests "blocked" | An old JSON check that needs a real backup file in Application Support. The gauntlet's isolated home doesn't have it, so the test skips, and the gauntlet counts a skip as a failure. It passes in the nightly. |

## Gaps (ranked)
1. **P0 #340.** After a refused SQLite launch, `applyReadOnlyMode(false)` (VideoScanApp.swift:633 → VideoScanModel.swift:1477) makes catalog.json writable again. That session's edits are then silently lost at the next good launch. It also clears read-only after a restoredBelowHighWater open. It has not fired; a fix is in progress.
2. **P1 #339.** Quarantine has no screen. Of its rows, **268** are ones the audit couldn't vouch for (237 never seen, 28 Tier-5, 3 changed or couldn't check); they may be real files on offline drives.
3. **P1.** catalog.json's other readers and writers:
   - Viewer sync ships only catalog.json, so **viewer Macs are frozen at 10/18**.
   - `previewsweepd` and the Hallie shell CLI read the stale JSON.
   - Python scripts (`merge_dossier_jsonl.py`, `dossier_batch.py`, `catalog_purge_dangling.py`, `repair_catalog_mediadisposition.py`, …) still `os.replace` catalog.json without checking `catalog.cutover`, so their output now goes nowhere.
4. **P1 #338.** On a near-full disk the high-water is raised before COMMIT, so the catalog reopens read-only with misleading words. Nothing is lost.
5. **P2.** Every SQLite launch still decodes the 80 MB catalog.json and rewrites `catalog.json.prev` (CatalogAuthorityFlip.swift:193 → CatalogStore.swift:751). That's wasted launch time and a write in the live folder.
6. **P2.** No app-level test of two writers (the headless `--audit-catalog` opens the database read-write too, #323).

Lower: no copy is taken before a future schema migration (proposal: `VACUUM INTO` first); no test of a file copy taken while the app runs (the WAL holds recent commits); #335, a strict-concurrency error in CatalogMarkerRelay.swift:64.

## Rick's decisions
1. Viewer Macs: ship catalog.sqlite to them, or accept frozen viewers until then?
2. The Python catalog.json writers: guard them, or retire them now?
3. #338: lower the high-water on SQLITE_FULL, or raise it only after COMMIT?
4. Does #340 block feature work until it's fixed? (The audit says yes. It's small and on a data path.)
