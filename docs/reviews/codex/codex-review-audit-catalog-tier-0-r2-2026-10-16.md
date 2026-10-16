# Codex review — Audit Catalog tier 0 r2

- Range: `b03c3ce6b..ef4f1be69`
- Credits spent: unavailable
- Tokens: 75711
- Finding count: 4
- Verdict: fix — F1/F2 and F4 retain false-Missing paths; F3 misses supersession. F5 holds.
- Run: 2026-10-16T17:53:03Z (cycle #79, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — F1/F2 and F4 retain false-Missing paths; F3 misses supersession. F5 holds.

References are to `ef4f1be69`. Reproductions are source-derived; tests were read, not executed. No files written.

1. **P1 — F1: anchoring can still establish the wrong filesystem.** [CatalogAuditPlan.swift:245](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:245) accepts any resolved, existing parent under lane `/`; it establishes where the parent resides **now**, without proving where the cataloged file belongs.
   
   **Failure scenario:** unmount a custom mount at `/Users/rickb/media`, leaving its empty mount-point directory; audit `media/clip.mov`—anchoring and final proof both identify the underlying disk, so the offline file becomes Missing.
   
   This requires no microsecond race. Refusing nonexistent parents does not cover existing mount-point stubs. Historical volume identity or an explicit unprovable classification is needed.

2. **P1 — F2: the second stat and mount proof can describe different resolutions.** [CatalogAuditPlan.swift:323](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:323) stats the pathname, then independently resolves its parent at line 325; [VideoScanModel+CatalogAudit.swift:124](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:124) subsequently stamps Missing.
   
   **Failure scenario:** anchor a symlinked parent on filesystem A containing the file; retarget to B where it is absent for both stats, then retarget back to A before the mount read—the identity matches and the present file is marked Missing.
   
   The drive/link need not leave **and** return within the final window: only the return must occur there. Main-actor synchrony neither excludes external filesystem changes nor bounds syscall duration. **I would not accept this as closure.** A directory-fd-bound proof using `fstatfs`/`fstatat`, with traversal constrained against changed or escaping resolution, can bind absence to the checked filesystem. That requires an explicit directory-handle exception to literal “nothing opened”; no media-file open is required. It still cannot prevent an ordinary file arrival after the observation.

3. **P1 — F4: rollback remains vulnerable to equal-value ABA, especially `nil`.** [VideoScanModel+RemovalMarker.swift:62](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:62) compares values without tracking intervening writes.
   
   **Failure scenario:** audit restores a present Missing row, recording `wrote = nil`; during the save await, another door performs Trash → Put Back → Restore, returning to `nil`; the audit save fails and rollback reinstates the old Missing marker over the newer successful restore.
   
   An independently reinstated, exactly equal nonnil marker also passes. Timestamp/value equality cannot establish write ownership; rollback needs a mutation revision or equivalent ownership check. The current-instance fix holds, but this newer-write protection does not.

4. **P2 — F3: supersession is absent from the snapshot:** [CatalogAuditPlan.swift:63](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:63) omits `supersededByID`, although line 183 uses supersession to skip rows; set that field after planning and [apply’s guard:80](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:80) still permits marking or restoring the superseded row.

Remaining closure checks:

- **Never-provable cases:** permanently deleting a local parent under `/` leaves its rows unmarkable on every run. That is the declared conservative policy, but it limits coverage. A case-only folder rename on case-insensitive APFS does not itself produce ENOENT; the missing-parent allowance introduces no separate case-folding finding.
- **Archive:** live fixity/derivation checks hold. Cleanup/Delete Duplicates equivalence cannot be established from the permitted files.
- **Mirrors:** independent compare-and-set does not guarantee marker/mirror consistency. However, Missing deliberately leaves lifecycle unchanged at [RemovalMarker.swift:47](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:47); Missing plus `.cataloged` is therefore intentional, not another finding.
- **F5 — read, no findings:** [CatalogAuditJob.swift:504](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditJob.swift:504) gives failed saves precedence. The test at [CatalogAuditJobTests.swift:807](/Users/rickb/dev/VideoScan/VideoScanTests/CatalogAuditJobTests.swift:807) checks failed state, run marker, OUTCOME and CLI exit 1. Tests read, no additional findings.

## Brief

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


## Closure (Manager, 2026-10-16 — fix `5769a6647`, merged `b9d1f144a`)

All four closed RED FIRST (13 issues red against main in `CatalogAuditProveAtTheMarkTests` + the new `CatalogAuditRound2Tests`, then 87 tests in 10 suites green, Debug).

1. **F1 wrong filesystem (stub mount point) — closed.** The expected identity is the LANE ROOT's (`CatalogAuditMountIdentity.ofLaneRoot`): a `/Volumes/X` root must itself be a mount point (`mountOn == root`), else the lane anchors to nil and nothing under it is provable; "/" anchors to this Mac's Data volume (`/System/Volumes/Data` — `/` is the sealed system snapshot and every file a person writes lives on Data), falling back to "/" when Data is not a separate mount. Under "/" the stub rule (`CatalogAuditProof.stubRule`): a missing intermediate folder → "a deleted folder and an unmounted mount point look the same"; an empty direct parent → "the folder is empty (an unmounted mount point looks the same)"; both could-not-check, never a mark. Pins: `emptyMountPointStubUnderRootIsNeverGone`, deleted-subfolder, single-deleted-file-in-a-non-empty-folder, missing-parent-under-a-registered-lane-root, and the three anchor cases.
2. **F2 two resolutions (retargeted link) — closed.** `CatalogAuditDirectoryWalk`: open the nearest existing ancestor (`O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`), `fstatfs` for identity, `openat` per remaining folder, `fstatat(…, AT_SYMLINK_NOFOLLOW)` for the name; the ENOENT is bound to the handle's identity; a link where the walk lands or in the remainder → "a link in the path — not provable" (Darwin returns ENOTDIR, not ELOOP, for a refused link, so the failing component is identified with `fstatat` NOFOLLOW first). Intermediate links in the EXISTING part of the path are resolved by the kernel when the ancestor is opened (`/var` → `/private/var`). The directory handle (+ `fdopendir`/`readdir` on a `dup` for the stub rule) is the ONE declared exception to "nothing opened" — MOPS-14; sensor `directoryHandleIsTheOnlyOpenAndOnlyInThePlan`. Pins: `symlinkedParentRetargetedIsNeverGone`, link-in-remainder, walk values.
3. **F4 equal-value ABA — closed.** `VideoRecord.removalRevision` (additive, decodes as 0, carried by clone and rescan preservation; DTO stores it only when non-zero so legacy rows stay byte-identical); the ONE engine bumps it on every marker CHANGE (`stampRemoval` when the value differs; `clearRemoval` when a marker was there); `revertRemoval` requires the audit's own revision. Sensor `onlyTheEngineBumpsTheRemovalRevision`. Pins: `rollbackLeavesANewerEqualNilMarkerAlone`, `rollbackLeavesAnIdenticalMarkerReinstatedByAnotherDoorAlone`, ordinary rollback, JSON round trip.
4. **F3 supersession — closed.** `CatalogAuditRowSnapshot.supersededByID`; pin `supersededAfterPlanningIsDropped`.

Declared limits (accepted): a wholesale-deleted folder under "/" is a person's decision (Fix Links); a stale stub folder under /Volumes makes that lane unprovable until the drive mounts.

Round 3 brief: `docs/reviews/briefs/codex-brief-audit-catalog-tier0-r3-2026-10-16.md`.
