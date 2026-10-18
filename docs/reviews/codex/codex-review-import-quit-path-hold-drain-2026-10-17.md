# Codex review — Import quit path + hold drain

- Range: `572dba8a3..b34f86c62`
- Credits spent: unavailable
- Tokens: 111944
- Finding count: 3
- Verdict: fix — quit still permits held-edit loss, and timeout release does not establish that the importer has stopped.
- Run: 2026-10-18T01:02:42Z (cycle #99, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3

Verdict: fix — quit still permits held-edit loss, and timeout release does not establish that the importer has stopped.

- **P1 — Failed persistence still permits termination.** [ImportToSQLiteQuit.swift:51](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteQuit.swift:51), [VideoScanApp.swift:275](/Users/rickb/dev/VideoScan/VideoScan/App/VideoScanApp.swift:275). **Failure scenario:** persistent ENOSPC or a write refusal makes `settleAndSave` return false; its caller discards that result and approves termination, and the unchecked `applicationWillTerminate` retry also fails, losing held edits. Propagate the result and retain the session unless persistence succeeds or a durable recovery copy exists.

- **P1 — Force-release is not a rollback or COMMIT fence.** [ImportToSQLiteQuit.swift:38](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteQuit.swift:38), [ImportToSQLiteJob.swift:387](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:387), [VideoScanApp.swift:388](/Users/rickb/dev/VideoScan/VideoScan/App/VideoScanApp.swift:388). **Failure schedule:** the importer passes its final cancellation poll and stalls in COMMIT; the timeout releases the hold and saves JSON; COMMIT subsequently finishes before process exit. The scoped code supplies a polling flag but obtains no transaction-completion acknowledgement before releasing. The `applicationWillTerminate` fallback releases without even cancelling the importer. Consequently, “never commits; SQLite rolls it back” is not established. The timeout test at [ImportToSQLiteTests.swift:650](/Users/rickb/dev/VideoScan/VideoScanTests/ImportToSQLiteTests.swift:650) quits during Verify, before any transaction exists. Core’s COMMIT implementation is outside the permitted scope; this is an ordering finding, not an executed late-COMMIT reproduction.

- **P2 — Hold acquisition can wait forever, and quit’s timeout does not escape that stall.** [CatalogStore.swift:318](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:318), [CatalogStore.swift:1046](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:1046). **Failure scenario:** an admitted save stalls indefinitely in filesystem I/O; the queued barrier never executes, Stop cannot interrupt acquisition, and timeout recovery blocks the main thread by synchronously saving behind the same stalled writer. There is no thrown-error counter leak: `encodeAndWrite` catches errors, and `acknowledgedInFlight` decrements at line 1131 whenever it returns.

Previous findings:

- **#1 OPEN:** quit durability remains incomplete as above.
- **#2 CLOSED:** [VerifyCatalogJob.swift:360](/Users/rickb/dev/VideoScan/VideoScan/Integrity/VerifyCatalogJob.swift:360) reads the file and checks its decoded generation.
- **#3 CLOSED:** [CatalogStore.swift:314](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:314) establishes admission before draining, including acknowledged saves; the new stall issue is separate.
- **#4 CLOSED:** [ImportToSQLitePhases.swift:93](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLitePhases.swift:93) rechecks wall time after waking.

Read, no additional findings: decoder deduplication, pair rewiring/revalidation, and returned designation use the same implementation as `load()`; file verification deliberately omits backup fallback and session-state adoption. [CatalogConstraints.swift:128](/Users/rickb/dev/VideoScan/VideoScan/Integrity/CatalogConstraints.swift:128) has no direct main-actor singleton access; transitive record-property and `storedFullDigest` implementations are outside scope.

Tests read, not executed because they write files. No files written.

## Closure (fix branch, 2026-10-17 night)

Every finding closed by a pinning test shown red first (Core: red on the
unmodified importer; app: red by mutation where the red needs a new seam).

| Finding | Pin | Red | Fix |
|---|---|---|---|
| P1 force-release is not a COMMIT fence | Core `CatalogImporterStagingTests` (6); app `ImportToSQLiteQuitPathTests.aLateCommitNeverReachesCatalogSQLite` (stall injected in the store's write after the last Stop poll, before COMMIT) | Core, unmodified importer: 6 tests, 15 issues — "Expectation failed: outcome == .stopped", "Expectation failed: !FileManager.default.fileExists(atPath: scene.databaseURL.path)". App, mutant (publish gate ignored): "Expectation failed: job.state == .cancelled", "Expectation failed: !FileManager.default.fileExists(atPath: scene.databaseURL.path)", "Expectation failed: next.state == .finished(summary: next.subtitle)" | `Import/CatalogImporter+Staging.swift` (staging folder, verified publish, database last, RENAME_EXCL, leftovers moved aside); `CatalogImporter.run(publishPermit:)`; `ImportStopFlag.claimPublish` |
| P1 failed persistence still permits termination | `aRefusedSaveAtQuitLeavesARecoveryCopy`, `bothFailingKeepsTheAppOpen`, `theTerminalSaveIsChecked`, `theNextLaunchSaysACopyIsThere`, `ImportToSQLiteQuitSensorTests` | mutant (no copy; the reply always quits, as on main): "Issue recorded" (expected a recovery copy, got unsaved), "Expectation failed: kept == .terminateCancel", "Expectation failed: words.contains("the recovery copy also failed")"; the launch notice is new behaviour with no main counterpart | `ImportToSQLiteQuit.SaveOutcome` / `terminateReply`; `App/CatalogQuitRecovery.swift`; `finishQuit` returns the reply; willTerminate cancels, releases, `saveAtTermination` |
| P2 holdWrites can wait forever | `theHoldGivesUpOnAStalledSave`, `theJobRefusesOnAStalledWriter`, `aQuitBehindAStalledWriterWritesTheCopy` | mutant (drain effectively unbounded): "Expectation failed: Date().timeIntervalSince(started) < 1.5", "Expectation failed: result == .writerStalled(heldSaves: 0)", "Expectation failed: job.wasRefused", "Expectation failed: Date().timeIntervalSince(started) < 2" | `CatalogStore.holdWrites(within:)` → `.writerStalled`; `waitForWriterToDrain`; the job refuses before phase 1; the quit skips its synchronous save behind a stalled writer |

Found while fixing (not a codex finding, recorded for the cutover): the
store's `close()` does not fold the WAL into catalog.sqlite (GRDB closes the
writer before its read-only readers) — measured 4 KB database + 745 KB WAL
after a 3-row import. The publish therefore moves the WAL with the database.
Anything that copies catalog.sqlite ALONE (a backup, an off-site copy) loses
the import. Recommended: `wal_checkpoint(TRUNCATE)` in
`GRDBCatalogRepository.close()` (Store/, outside this branch).

## Brief

# Codex brief: quit during a held import + hold drain + Verify-from-file (2026-10-17 night, data-risk: the catalog write gate)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~600 words.

**Your previous pass:** `docs/reviews/codex/codex-review-one-job-import-write-hold-2026-10-17.md` (4 findings). **The fix:** merge of `6c8ee4239` into main, range `572dba8a3..b34f86c62`. Files under `VideoScan/VideoScan/`: `MediaOps/ImportToSQLiteQuit.swift` (new: `settleAndSave`, `releaseHoldIfStillHeld`), `App/VideoScanApp.swift` (`finishQuit`, the `.terminateLater` paths, `applicationWillTerminate`), `Catalog/CatalogStore.swift` (`holdWrites` now async with a drain; `acknowledgedInFlight`; `decodeCatalogFile`), `Integrity/VerifyCatalogJob.swift` (`SnapshotSource`, `verifyCatalogSnapshot(auditedGeneration:)`, `auditedFileRows`), `MediaOps/ImportToSQLiteJob.swift`, `MediaOps/ImportToSQLitePhases.swift` (`waitForVerifyStart`), `Integrity/CatalogConstraints.swift` (`IntegrityRow.init(record:)` no longer @MainActor); tests `VideoScanTests/ImportToSQLiteTests.swift`.

**Attack:** (1) each of your four findings: CLOSED or OPEN with file:line. (2) Force-release ordering when the 30 s bound expires: can the held edits be saved while the importer's transaction is still open and later COMMITs (two writers)? (3) Can `holdWrites` hang forever (a save that never finishes; `acknowledgedInFlight` never decremented on a throw)? (4) Does `decodeCatalogFile` see exactly what `load()` sees (dedupe, pair rewiring, designation)? (5) `IntegrityRow.init(record:)` off the main actor — any main-actor state read?
**Do only this:** findings (P1 first) with file:line + one-line failure scenario; at most three P2/P3. **Do not explore outside the files listed above.**
