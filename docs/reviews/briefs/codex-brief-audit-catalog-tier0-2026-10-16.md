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
