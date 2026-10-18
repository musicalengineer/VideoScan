# Codex brief: Import to SQLite as one job — the owner-token write hold (2026-10-17, data-risk: the catalog write gate)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**One sentence:** Import to SQLite holds every catalog save from its first step to its last and inside that hold runs Audit Catalog, Verify Catalog and the import, so all three describe one generation; only the job's own audit save passes the hold.

**Range:** `3234d6a17..aaff7a610` on main (merge of `e9d7f41b2`). Files under `VideoScan/VideoScan/`: `Catalog/CatalogStore.swift` (`holdWrites(reason:owner:)`, `writePrecondition(as:)`, `saveAcknowledged(records:as:)`, `releaseWriteHold`), `Model/VideoScanModel.swift` (`saveCatalogAcknowledged(asHoldOwner:)`), `MediaOps/CatalogAuditJob.swift` (`writeHoldOwner`), `Integrity/VerifyCatalogJob.swift`, `MediaOps/ImportToSQLiteJob.swift`, `MediaOps/ImportToSQLitePhases.swift`, `MediaOps/ImportToSQLitePreflight.swift`, `MediaOps/ImportDryRunMarker.swift`, `Catalog/ImportToSQLiteMenuItems.swift`; tests `VideoScanTests/ImportToSQLiteTests.swift`; MOPS-16 in `docs/practices/invariants/MediaOps.md`.

**Attack:**
1. Can any save other than the token-bearing audit save land while the hold is up (debounced timer already scheduled before the hold; a save in flight when the hold is taken; `saveNow` at quit; another job's acknowledged save)? Is a held save ever LOST (counted but not caught up; app quits while held)?
2. Token leak: can the token outlive the job (crash/Stop/throw paths) and leave the store held forever, or be reused by a later job?
3. The audit's save "supersedes any pending debounced save" — background edits made before it land in generation G. Can an edit made AFTER the audit's save but before Verify reach Verify's in-memory snapshot while the file stays at G (the agent flagged this) — and does the importer, which reads the FILE, then import something Verify never certified, or refuse? Say which and whether it matters.
4. The 1.5 s wait for whole-second ordering between audit.finishedAt and report.startedAt — sound, or does a clock with sub-second skew still fail (or pass when it shouldn't)?
5. Build-identity marker (CFBundleVersion + Mach-O UUID): can a stale marker enable commit on a different build; does the commit run re-prove everything regardless?
**Do only this:** findings (P1 first) with file:line and a one-line failure scenario; at most three P2/P3. **Do not explore outside the files listed above.**
