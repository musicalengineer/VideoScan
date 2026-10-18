# Codex review — One-job import write hold

- Range: `3234d6a17..aaff7a610`
- Credits spent: unavailable
- Tokens: 68986
- Finding count: 4
- Verdict: fix — held edits can be lost on termination, and holding disk writes does not make Verify’s live snapshot identical to the audited file.
- Run: 2026-10-18T00:06:54Z (cycle #98, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4

Verdict: fix — held edits can be lost on termination, and holding disk writes does not make Verify’s live snapshot identical to the audited file.

Line numbers refer to `aaff7a610`.

- **P1 — Quit-time saves are refused without a durable fallback.** [CatalogStore.swift:1019](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:1019), [ImportToSQLiteJob.swift:201](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:201). **Failure scenario:** edit after the audit’s final save, then terminate while Verify/import holds writes; the termination `saveNow` returns false, and the only catch-up requires the job to finish and its subsequent debounce to fire. The refusal counter preserves no data across exit. Termination must await cancellation, hold release, and a durable flush. The catch-up test checks that generation remains G; it never verifies the eventual catch-up.

- **P2 — Verify can certify a file different from its snapshot.** [VerifyCatalogJob.swift:299](/Users/rickb/dev/VideoScan/VideoScan/Integrity/VerifyCatalogJob.swift:299), [VerifyCatalogJob.swift:252](/Users/rickb/dev/VideoScan/VideoScan/Integrity/VerifyCatalogJob.swift:252). **Failure scenario:** change a row after the audit saves G but before Verify snapshots `model.records`; Verify examines changed memory, labels it G, and certifies the unchanged file solely because its generation also equals G. The import job’s generation check passes. The existing notes-edit test expects the importer’s dry run to accept disk G and defer the new note—harmless for that example, but not proof that integrity-relevant edits are safe. Whether Core rejects a particular structural edit cannot be established from the permitted files; false certification itself is established. Verify should consume the audited file or the exact saved snapshot.

- **P2 — Acquiring the hold does not drain previously admitted writes.** [ImportToSQLiteJob.swift:189](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:189), [CatalogStore.swift:288](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:288). **Failure scenario:** a non-owner save enters the write queue during the awaited preflight, then lands after `holdWrites`; the gate was checked before queueing and is never checked again. Additionally, `saveAcknowledged` does not set `saveInFlight`, so `hasUnsavedChanges` can report false while an acknowledged write is outstanding. A subsequent audit save normally supersedes that write through FIFO ordering, but the promised exclusion is false. Hold acquisition needs an atomic admission/drain boundary.

- **P3 — The timing wait can still refuse under a backward clock step.** [ImportToSQLiteJob.swift:258](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:258), [ImportToSQLitePhases.swift:69](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/ImportToSQLitePhases.swift:69). **Failure scenario:** audit finishes at `100.9`, the calculated sleep is `0.6s`, and wall time moves backward `0.7s`; Verify starts at `100.8`, producing equal whole-second timestamps and refusal. This fails closed; a constant clock offset is harmless. Recheck wall time after waking.

Read, no independent findings: the scoped model save forwarding, `CatalogAuditJob`, `ImportToSQLitePreflight`, `ImportDryRunMarker`, and `ImportToSQLiteMenuItems`. Stop/failure paths reach release; crashes discard the in-memory hold, and later jobs receive fresh tokens. Different normal build identities reject stale markers; commit unconditionally reruns audit, Verify, and import. MOPS-16’s guarantees need the fixes above.

Tests were read, not executed because they write files. No files written.

## Brief

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
