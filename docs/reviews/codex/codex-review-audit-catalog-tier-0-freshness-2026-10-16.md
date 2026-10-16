# Codex review — Audit Catalog tier 0 + freshness

- Range: `8a1559863..b03c3ce6b`
- Credits spent: unavailable
- Tokens: 105396
- Finding count: 5
- Verdict: fix — false Missing marks and incomplete rollback remain possible.
- Run: 2026-10-16T17:20:01Z (cycle #78, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5
Verdict: fix — false Missing marks and incomplete rollback remain possible.

All references are to `b03c3ce6b`. Reproductions below are source-derived; tests were read, not executed. No files were written.

1. **P1 — The mount check can validate the wrong filesystem (invariants 1–2).** [CatalogAuditPlan.swift:105](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:105) uses the lexical root policy documented at [MediaFileOperations.swift:793](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/MediaFileOperations.swift:793); [CatalogAuditJob.swift:138](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditJob.swift:138) unconditionally accepts `/`. Neither establishes which filesystem a symlink actually reaches.
   **Failure scenario:** catalog `/Users/rickb/media/clip.mov`, where `media` links to an external drive; unplug that drive, and `stat` returns ENOENT while the checked root `/` remains mounted—the real file’s row becomes Missing. A custom mount outside `/Volumes` has the same problem.

2. **P1 — Unmount/remount during a chunk turns transient absence into a persistent mark (invariant 1).** [CatalogAuditJob.swift:264](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditJob.swift:264) collects stats before checking only the current mount-root presence at line 267. It retains no mount identity or evidence of continuity.
   **Failure scenario:** unplug after planning, let a path return ENOENT, then reconnect at the same root before the main actor resumes; the mount check passes and the now-present file is marked Missing. **The dangerous window is from the ENOENT observation until the post-stat mount check.** A separate check-to-apply window also remains after line 267.

3. **P1 — The apply guard misses intervening changes that return to the same key (invariants 4–5).** [VideoScanModel+CatalogAudit.swift:63](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:63) checks ID/path/marker equality, without a revision; line 87 also trusts the archive status captured during planning.
   **Failure scenario:** plan a live row, capture `.gone`, then complete Trash → Put Back → Restore at the same path before apply; the marker returns to `nil`, the guard passes, and the returned file is marked Missing. Likewise, setting archive fixity meanwhile does not prevent marking because `item.isArchived` remains false. A same-path rescan is not rejected merely because it refreshed the row.

4. **P1 — Rollback validates one object but can restore another, and can overwrite newer fields (invariant 3).** [VideoScanModel+CatalogAudit.swift:122](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:122) validates the current lookup, then invokes a memento whose [RemovalUndo.reinstate:189](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:189) writes the originally captured object, including lifecycle and archive stages.
   **Failure scenario:** apply a mark, replace the catalog entry with another instance carrying the same ID/path/marker, then fail the save; rollback returns `true` but restores the detached original, leaving the current entry marked. Even without replacement, newer lifecycle/archive-stage edits are overwritten if the removal marker still matches. The tests cover a newer *marker*, not these cases.

5. **P2 — Stop masks save failure:** [CatalogAuditJob.swift:479](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditJob.swift:479) converts failure to cancellation when Stop was requested; Stop followed by an unacknowledged save therefore returns CLI exit **4**, although marks were undone and the run marker says failed.

The remaining invariant checks:

- **2:** The errno classification holds: only ENOENT/ENOTDIR become `.gone`; EACCES, EPERM, EIO, ETIMEDOUT, ENXIO and EINTR cannot mark. Non-regular files cannot mark. `stat` follows symlinks: a genuinely dangling link becomes `.gone`; a working link and case variants on a case-insensitive filesystem resolve normally.
- **3:** Exactly one audit `stampRemoval` call exists. Within the job’s control flow, I found **no premature “completed” path**: it joins lanes and the ticker before the final acknowledged flush. That conclusion assumes the acknowledgment API’s stated durability contract; rollback has finding 4.
- **5–6:** No media-writing/moving/deleting call found. Missing rows still gone write nothing; returned rows use validating `clearRemoval`; Trash/removed rows are skipped. Planned archived live rows are report-only. I would retain that conservative archive policy for this cut.
- **7:** The existing-GUI refusal and viewer-role installation are present. **A later GUI launch can overlap the audit:** the process check runs once, and `main.swift` has no reciprocal audit check. Whether CatalogStore locking/generation checks safely reject the competing save cannot be established from the permitted files.
- **8:** Holds: red precedence, running exclusion, empty-registry grey headline, and singular counts.

**Read, no additional findings:** `CatalogAuditRun.swift`, `CatalogAuditCLI.swift`, `main.swift`, the additive `RemovalMarker.swift` change, the `.auditCatalog` kind registration, `CatalogFreshness.swift`, both named test files, and the referenced save/marker patterns.

## Brief

# Codex brief: Audit Catalog tier 0 (data-risk) + catalog freshness model (pure)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1000 words.

**One sentence (Rick, 2026-10-15/16):** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**Why it matters:** on October 4 a 33 GB VHS capture's staging copy vanished outside the app; for eleven days its row posed as a live copy — the duplicates job held its twin and Compare Media said "byte for byte" from stored hashes. This job is the standing guarantee that a row points at a file. It WRITES removal markers (`.missing`) on catalog rows; a wrong mark hides a real file from every view and every delete pool, so the invariants below are the whole review. Design: `docs/design/catalog_status_freshness_2026_10_16.md` §6 (the cut) and `docs/design/audit_archive_2026_10_15.md` §2a.

**Range:** `8a1559863..b03c3ce6b` on `main` (merge commit `b03c3ce6b`, the job is `a7d009fde`; the freshness model is `b365b7bf0` via `339ddc354`). Read files with `git show b03c3ce6b:<path>`. Paths under `VideoScan/VideoScan/` unless noted.
- `MediaOps/CatalogAuditPlan.swift` — the plan (live rows, or `.missing` rows re-checked for "came back", on a mounted root), lanes per volume root, `CatalogAuditStat.of` (ENOENT/ENOTDIR → gone; any other errno → unreadable = could not check; non-regular → notAFile), results, totals, words, top folders.
- `MediaOps/VideoScanModel+CatalogAudit.swift` — THE only row-mutating path: `applyCatalogAudit` (compare-and-set on id + path + the marker the row had when planned; one `stampRemoval(.missing(reason: .missingAtAudit))`, one `clearRemoval`), `revertCatalogAuditMark` (undo memento), the `catalogAuditNote` sink.
- `MediaOps/CatalogAuditJob.swift` — the MFO job: `isMounted` (fresh kernel mount table, not the 5 s reachability cache), `statChunk` / `statOffMain` (chunks of 256 off the main actor), the post-stat mount re-check, apply on main, batched `saveCatalogAcknowledged` every 25 marks / 60 s / end, undo of the unsaved batch on an unacknowledged save, Stop (finishes the chunk in flight, saves, "stopped (partial)"), refusals (read-only catalog, test-host shared catalog), `MediaFileOperationsCenter.startCatalogAudit`.
- `MediaOps/CatalogAuditRun.swift` — `catalog-audit.json` beside catalog.json via `AtomicFilePublish` (startedAt, finishedAt, outcome, partial, counts) + `announceLastRun(to:)` launch line.
- `App/CatalogAuditCLI.swift`, `App/main.swift` — `--audit-catalog [--quiet]` headless; refuses (exit 3) when the GUI is running (one catalog writer); installs the CatalogSync role so a viewer Mac refuses as read-only.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/RemovalMarker.swift` — `RemovalReason.missingAtAudit` (additive).
- `MediaOps/MediaFileOperations.swift` — kind `.auditCatalog`, chip "Audit".
- `VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogFreshness.swift` — PURE: `FreshnessPolicy.reason/judge/summarize`; precedence `attention ?? staleness ?? idle`; red > yellow > green > grey; running overlay; `staleKinds` excludes running/red/grey rows.
- Tests: `VideoScan/VideoScanTests/CatalogAuditJobTests.swift` (4 suites, 21 tests: logic incl. EACCES/EIO/ETIMEDOUT/EPERM never mark, unmounted root never mark, moved path / foreign marker / Restore-meanwhile / removed row all dropped, failed save undoes; 100k scale; poisoned marker file; source sensors), `VideoScan/VideoScanCore/Tests/VideoScanCoreTests/CatalogFreshnessTests.swift` (41).
- Reference, read-only: `MediaOps/VideoScanModel+RemovalMarker.swift` (`stampRemoval`, `clearRemoval`), `MediaOps/AudioFingerprintBackfillJob.swift` (the save/undo contract this copies), `MediaOps/FullHashBackfillResume.swift` (the marker-file pattern).

**Invariants to attack (prove with file:line or say it holds):**
1. A row whose volume root is not mounted is NEVER marked — not at plan time, not when the drive is unplugged mid-run (between the stat and the apply, or between chunks), not when a mount point exists as an empty folder, not for a non-/Volumes root. Name the window where an unmount reads as "gone".
2. Nothing but ENOENT/ENOTDIR marks: EACCES, EPERM, EIO, ETIMEDOUT, ENXIO, EINTR, a dangling symlink, a path through a symlinked folder, a non-regular file at the path, a path with a different case on a case-insensitive volume.
3. Every mark goes through `stampRemoval` (one call site) and lands only after an acknowledged save; on an unacknowledged save EVERY unsaved mark is undone and nothing newer is undone (compare-and-set); a crash between apply and save loses only in-memory marks. Is there any path where `catalog-audit.json` says "completed" while marks are unsaved?
4. A result is applied only to the row it asked about: same id, same `fullPath`, same marker as when planned. Name a sequence — Rescan, Relocate, Restore, a Trash move by another door, a path edit — between plan and apply that is NOT refused.
5. Nothing opens a media file for writing, renames, moves, trashes or unlinks anything; the only write beside the catalog is `catalog-audit.json`. Archived rows (`isArchived` / archive files) are reported, never marked (the builder's conservative reading of "nothing touches the archive" — say if you would mark them).
6. A `.missing` row whose file is back goes live only through `clearRemoval` (which validates the file is there); a `.missing` row still gone writes nothing; a row In the Trash or removed from the catalog is skipped.
7. Headless `--audit-catalog`: with the GUI open it refuses; with two Macs sharing the catalog (CatalogSync roles) the viewer refuses; is there a window where the headless run and a later GUI save race on `catalog.json` generation?
8. Freshness (pure): a red reason can never be outranked by yellow/green/grey; a running row is never queued by `staleKinds`; `summarize` over an empty registry is grey "Nothing to check" with no "drives not mounted" claim; words never say "N rows" for N == 1.

**Do only this:** findings against 1–8 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Known and out of scope (not findings): Fix Links (not built); the nightly script wiring; the Storage tab's older "Audit Catalog…" bookkeeping door (naming overlap, already noted); the mock status chip; wording.

**Do not explore outside the files listed above and their tests.**


## Closure (Manager, 2026-10-16 — fix `78f6f2d11`, merged `ef4f1be69`)

Principle adopted for all four P1s: **prove at the mark** — a row is marked gone only on evidence read at the moment of marking, on the filesystem the file was expected on. The chunk's ENOENT is a first pass that decides nothing. Every finding was shown RED against `b03c3ce6b` first (suite `CatalogAuditProveAtTheMarkTests`, 9 of 10 red, 31 issues), then GREEN.

1. **F1 wrong filesystem — closed.** `CatalogAuditMountIdentity` (statfs fsid + mountOn + mountFrom) is taken per lane off the main actor from the nearest existing ancestor after `realpath` of the parent; `CatalogAuditProof.atTheMark` accepts ENOENT only when the ancestor resolves to the SAME identity now. "/" has no exemption. Never provable → "could not check": a dangling link in the chain; under lane root "/" a parent folder that is not there (an unmounted non-/Volumes mount is indistinguishable from a deleted folder — refuse over guess); an ancestor not at/under a /Volumes root. Pins: `danglingSymlinkParentIsNeverGone`, `symlinkRetargetedToAnotherFilesystemIsNeverGone`.
2. **F2 unmount/remount in the window — closed.** `applyGone` re-stats SYNCHRONOUSLY on the main actor before the one `stampRemoval`: `.file` → present/changed/cameBack; `.notAFile`/`.unreadable` → could not check; only `.gone` on the same mount marks. Pins: `fileBackAtTheMarkIsPresentNotMarked`, `errnoAtTheMarkIsCouldNotCheck`. Residual (declared, carried to r2): the microseconds between the second stat and the statfs read.
3. **F3 same-key changes — closed.** `CatalogAuditRowSnapshot` (path, sizeBytes, removal, lifecycleStage, archiveStage, hasArchiveFixity, derivationKind, contentHashAt, dateModified) is the guard; `isArchived` is read from the live record; Trash→Put Back→Restore is caught by F2's re-stat. Pins: `snapshotFieldsChangedMeanwhileDropTheResult` (6 rows), `trashPutBackRestoreMeanwhileIsNotMarked`.
4. **F4 rollback — closed.** New engine primitive `VideoScanModel.revertRemoval` (one-writer file): acts on whatever instance is current, requires `rec.removal == wrote` by value, restores only the marker to `previous`, and each mirror only if it still holds the value the write left. No `RemovalUndo` memento. Pins: `rollbackClearsTheMarkOnTheCurrentInstance`, `rollbackLeavesANewerLifecycleEditAlone`, `rollbackLeavesANewerMarkerAlone`.
5. **F5 Stop masks a failed save — closed.** `finish(failedSave:)` sets `.failed` regardless of a Stop request; exit 1; run marker failed; OUTCOME "failed (partial)". Pin: `stopThenUnacknowledgedSaveIsFailed`.

Invariant 7 note (GUI launched after a headless audit) → GH #323, before the nightly wiring. MOPS-14 rewritten. Sensor `expectProofAtTheMark` pins the order (second stat before the one mark; no `await` in the model half; live `isArchived`; by-value revert).

Round 2 brief: `docs/reviews/briefs/codex-brief-audit-catalog-tier0-r2-2026-10-16.md`.

## Closed

Closed by `ef4f1be69` at 2026-10-16T17:53:03Z. 5/5 closed with red-first pins (prove at the mark); r2 running
