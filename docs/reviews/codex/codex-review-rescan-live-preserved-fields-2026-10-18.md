# Codex review — Rescan live preserved fields

- Range: `4ce05b520..6fa7c9ff3`
- Credits spent: unavailable (meter not exposed)
- Tokens: 91171
- Finding count: 2
- Verdict: fix — shared-path removal can still lose accepted edits, and reconciliation can erase fresh probe notes.
- Run: 2026-10-18T21:23:07Z (cycle #109, tools/codex_review.py)

## Dispositions (bug-fix agent, 2026-10-18, branch `worktree-agent-a517ebe73e8e0b54d`)

1. **P1: Trashed successor at a shared path. CLOSED.** Pinned by `AdvRescanEditDuringScanTests/trashedSuccessorStillBeatsAReplacedRowAtTheSamePath`. Successor selection now uses a rank, `VideoScanModel.sharedPathRank`: active 2 › removed (Trash/missing/purged) 1 › `.replacedAtPath` history 0. Array order decides only when two rows have the same rank. Red (12 issues), then green; reverted, red; re-applied, green.
2. **P2: a first edit erased the fresh probe note. CLOSED.** Pinned by `AdvRescanEditDuringScanTests/firstStarDuringTheScanKeepsTheFreshProbeNote`, `…/notesKeepHistoryAndTakeThisScansProbeDiagnostics` and `…/probeDiagnosticClassifierSplitsHistoryFromProbe`. `notes` is machine text with two owners. Probe diagnostics (ffprobe stderr and scan-engine diagnosis, signed or legacy) are re-derived by every scan. History lines are not: File Journey stamps (including the scan-authored Reconcile/Migrate/Confirm), Combine, cleanup, recipe, the document-ingest stamp, and unrecognized legacy lines. `RescanPreservedFields.apply(to:)` now writes `MachineNote.rescanMerged(kept:fresh:)`: the kept record's history lines followed by the fresh probe's diagnostic lines. The classifier is `MachineNote.isProbeDiagnostic` in VideoScanCore. The same carrier serves the snapshot pass, the live re-read and move adoption, so the scan-start snapshot no longer erases a fresh diagnostic either. Contract change: `ScanMergeScopeTests` `dossierAndUserFieldsSurviveSamePathRefresh` / `…ResumedScan` used to pin `notes == "curated"` verbatim. They now pin "the carried line first, and every other line is a probe diagnostic". Real ffprobe on their junk bytes now adds `scan: File is corrupt or incomplete — missing media index (moov atom not found)`.
3. **Note: Update Catalog cleanup of `pendingRescanRestoredPaths`. CLOSED.** The concern was real but harmless: close/cancel and the late park left a stale entry. `closeUpdateCatalog` now clears the entries for every parked or deferred root, and `parkScanResultsForUpdateCatalog` clears the entry when the sheet was closed before the scan finished. Pinned by `AdvRescanEditDuringScanTests/closingUpdateCatalogForgetsTheRestoredPaths` and `…/parkingAfterCloseForgetsTheRestoredPaths`. Apply consumes the entry through `commitScanResults`, as before.

## Codex answer

Credits spent: unavailable (meter not exposed) | Finding count: 2

Verdict: fix — shared-path removal can still lose accepted edits, and reconciliation can erase fresh probe notes.

1. **P1 — Trashing the current shared-path row defeats successor selection.** [ScanMerge.swift:750](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a517ebe73e8e0b54d/VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:750) prefers the current row only while `removal == nil`. When both rows have removal markers, array order decides; a trailing historical `.replacedAtPath` row overwrites the current row’s curated values and Trash marker. Both old IDs are subsequently purged, so persistence cannot recover the accepted edit.

   **Failure scenario:** Start with `[active, historicalReplaced]` at one path; edit the active row’s note, Trash it during the scan, then merge—the historical note and removal marker win.

   Prefer the current successor over `.replacedAtPath` history even after that successor is removed.

2. **P2 — A first edit during scanning erases the fresh probe note.** [ScanMerge.swift:763](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a517ebe73e8e0b54d/VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:763) invokes the whole carrier, including unconditional `rec.notes = self.notes` at [RescanPreservation.swift:473](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a517ebe73e8e0b54d/VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift:473). A new star or user note makes an otherwise plain live record eligible, replacing the fresh diagnostic with empty/stale live notes.

   **Failure scenario:** Snapshot a plain row, produce fresh “moov atom not found,” add a star to the live row, then merge—the probe diagnostic disappears.

   Preserve fresh probe diagnostics when carrying live curated fields.

No suspension exists between reconciliation and replacement in either merge path; codec, size, and partial MD5 remain untouched. The transient map is consumed by reconciliation and cleared by the discard helper. Actual Update Catalog Apply/cancel orchestration lies outside the permitted source files, so its cleanup wiring is not independently certified.

`VideoScanModel.swift`: scoped portions read, no findings. `AdvRescanEditDuringScanTests.swift`: read, no independent findings; its shared-path test leaves the successor active, and its probe-note test makes no concurrent edit.

Static review only. No files written or tests run; the tests create files.

## Brief

# Codex brief: rescan merge keeps edits made during the scan (2026-10-18 evening; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~500 words.

**The bug (adversarial 2026-10-18 #1, VOL-4, confirmed red on main 4ce05b520):** `snapshotPreservedFieldsForRescan` copied every curated field at scan start; at merge only `archiveFixity` was re-read from the live record, so notes/stars/tags/dates/places/people/disposition/attestations/removal marker edited during the scan (or while an Update Catalog preview was open) were overwritten by the scan-start copy, then the old id was purged (B2.3). **The fix:** commit `6fa7c9ff3` on branch `worktree-agent-a517ebe73e8e0b54d`, range `4ce05b520..6fa7c9ff3`. `reconcileLiveArchiveFixityBeforeReplacement` → `reconcileLivePreservedFieldsBeforeReplacement` applies `RescanPreservedFields(from: live).apply(to: fresh)` immediately before the swap (no await between), when the live record has keepable values or the fresh record was snapshot-restored (new transient `pendingRescanRestoredPaths`); active row beats a kept `replacedAtPath` row at a shared path; lifecycle pointers relinked again.

Files under `VideoScan/`: `VideoScan/Volumes/VideoScanModel+ScanMerge.swift` (`commitScanResults`, `reconcileLivePreservedFieldsBeforeReplacement`), `VideoScan/Catalog/VideoScanModel+RescanPreservation.swift` (`snapshotPreservedFieldsForRescan`, `applyPreservedFieldsAfterRescan`, `relinkLifecyclePointersAfterRescan`), `VideoScan/Model/VideoScanModel.swift` (`pendingRescanRestoredPaths`); test `VideoScanTests/AdvRescanEditDuringScanTests.swift` (9 tests; red 7/8 before, 265 related tests green after, revert → red).

**Do only this:** attack the invariant **"the live curated value at swap time is what lands — in memory and in catalog.sqlite — and the scan's own technical values (codec, size, MD5, probe note) still refresh."** At most THREE findings, P1 = a lost accepted edit or a resurrected removal/clear, each with a one-line failure scenario. Specifically check: an await or actor hop between the live read and the swap; partial merge and Update Catalog Apply paths; `pendingRescanRestoredPaths` leaking across scans or never cleared on discard/cancel; a fresh probe value wrongly overwritten by a stale live value; shared-path rows. Known and declared, NOT findings: a row hard-purged (not Trashed) during a scan comes back from the snapshot because the file is on disk (policy question for Rick); the snapshot itself keeps the last of two shared-path rows (corrected at swap).
**Do not explore outside the files listed above and their tests.**
