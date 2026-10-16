# Codex brief: Audit Catalog tier 0 — round 2 (the closure of r1's five findings)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**One sentence:** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**Round 1** (`docs/reviews/codex/codex-review-audit-catalog-tier-0-freshness-2026-10-16.md`, cycle #78) found: F1 wrong filesystem (lexical root, `/` accepted), F2 unmount/remount inside the stat→mark window, F3 apply guard misses same-key changes (Trash→Put Back→Restore; archive fixity set meanwhile), F4 rollback reinstates a detached whole-object memento / overwrites newer fields, F5 Stop masks a failed save.

**Range:** `b03c3ce6b..ef4f1be69` on `main` (the fix is `78f6f2d11`). Read with `git show ef4f1be69:<path>`. Paths under `VideoScan/VideoScan/`.
- `MediaOps/CatalogAuditPlan.swift` — `CatalogAuditRowSnapshot` (path, sizeBytes, removal, lifecycleStage, archiveStage, hasArchiveFixity, derivationKind, contentHashAt, dateModified); `CatalogAuditMountIdentity` (statfs fsid + mountOn + mountFrom); `expected(forDirectory:root:)` — realpath of the parent, walk up to the nearest existing ancestor, statfs; nil = never provable (dangling link in the chain; under lane root "/" a parent folder that is not there; an ancestor not at/under a /Volumes lane root); `CatalogAuditProof.atTheMark(item)` — the SYNCHRONOUS second stat, then the mount read; ENOENT accepted only when the ancestor resolves to the SAME identity now.
- `MediaOps/VideoScanModel+CatalogAudit.swift` — `applyCatalogAudit`: whole-snapshot guard; `applyGone` switches on `atTheMark`: `.file` → the present/changed/cameBack path; `.notAFile`/`.unreadable` → could not check; only `.gone` + same mount → `markGone` → the ONE `stampRemoval`; `isArchived` read from the LIVE record; `revertCatalogAuditMark` → by-value `revertRemoval`.
- `MediaOps/VideoScanModel+RemovalMarker.swift` — new engine primitive `revertRemoval(rec, wrote:previous:mirrors:)`: requires `rec.removal == wrote` (value equality) on whatever instance is current; restores the marker to `previous`; each mirror (lifecycleStage, archiveStage) goes back ONLY if it still holds the value the write left. `RemovalMirrors`.
- `MediaOps/CatalogAuditJob.swift` — lanes anchor their items (realpath + statfs per distinct folder, cached) off main right before the first stat; `conclude` → `finish(failedSave:)` sets `.failed` regardless of a Stop request (failed > stopped > completed; CLI exit 1).
- Tests: `VideoScan/VideoScanTests/CatalogAuditJobTests.swift` — new suite `CatalogAuditProveAtTheMarkTests` (10: dangling-link parent never gone; link retargeted to another filesystem never gone; file back at the mark → present; EACCES at the mark → could not check; six snapshot fields changed meanwhile → dropped; Trash→Put Back→Restore → present; rollback on the current instance; newer lifecycle edit survives rollback; newer marker left alone; Stop + unacknowledged save → failed); sensor `expectProofAtTheMark`. 31 tests in the audit suites + 57 engine regressions green (Debug).
- Reference, read-only: the r1 doc; `docs/practices/invariants/MediaOps.md` MOPS-14 (rewritten).

**Attack the closures (prove with file:line or say it holds):**
1. F1/F2 — Is there still a sequence of unmount / remount / symlink retarget / folder rename between the second stat and `stampRemoval` that marks a present file? The builder names one residual: between the second stat (ENOENT) and the statfs read, microseconds on the main actor, a drive that leaves AND returns. Say whether that is acceptable for this cut or must be closed with an fd anchored to the ancestor (fstatfs + fstatat), given the "nothing opened" rule.
2. F1 — The three "never provable → could not check" cases: is any of them wrong in the other direction (a row that SHOULD be markable is now never markable, forever)? Under a mounted /Volumes root a missing parent folder IS accepted as proof — is that sound on APFS with a case-insensitive rename of the folder?
3. F3 — Name a same-key change the snapshot does not see (a field the row's fate depends on that is not in `CatalogAuditRowSnapshot`), or a path where the live `isArchived` read disagrees with what Cleanup / Delete Duplicates consider archived.
4. F4 — `revertRemoval`: can it clear a marker another door wrote with an EQUAL value (same state, since, reason) after the audit's own mark was already undone or overwritten? Can the mirror compare-and-set leave a row with a marker of nil but a lifecycle stage of `.missing` (or the reverse)?
5. F5 — Any outcome path where the run marker, the MFO row, the OUTCOME line and the CLI exit disagree.

**Do only this:** findings against 1–5 (P1 first), each with file:line and a one-line failure scenario; then at most two P2/P3 one-liners. Out of scope (not findings): the headless-vs-GUI overlap (GH #323), Fix Links, nightly wiring, the freshness model (closed in r1), wording.

**Do not explore outside the files listed above and their tests.**
