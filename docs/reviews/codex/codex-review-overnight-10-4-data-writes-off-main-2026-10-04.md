# Codex review — Overnight 10/4 data writes + off-main

- Range: `20f98257..a772fecc`
- Credits spent: unavailable
- Tokens: 96354
- Finding count: 3
- Verdict: fix — People-store writes can erase picks, and family deletion can trash an unrelated profile.
- Run: 2026-10-05T01:15:11Z (cycle #41, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — People-store writes can erase picks, and family deletion can trash an unrelated profile.

Reviewed `20f98257..a772fecc`. These are source-derived reproductions; no runtime reproduction or tests were run. The working copy remained unchanged.

1. **P1 — One malformed pick causes an unrelated save to erase all picks.**  
   [PersonFinderTypes.swift:772](/Users/rickb/dev/VideoScan/VideoScan/People/PersonFinderTypes.swift:772) converts failure decoding the entire pick array into `[]`. The preservation logic at [line 929](/Users/rickb/dev/VideoScan/VideoScan/People/PersonFinderTypes.swift:929) decodes that same empty result and writes it back.

   **Reproduction:** Store two picks, one valid and one with an invalid `recordID`. Load the profile, edit notes, and perform an ordinary save. Both picks disappear without `FeaturedVideos.set`. [FamilyGroup.swift:47](/Users/rickb/dev/VideoScan/VideoScan/People/FamilyGroup.swift:47) has the equivalent failure when renaming a partially damaged family.

   Preserve unreadable rows verbatim, or refuse rewriting a damaged pick list.

2. **P1 — Family deletion trusts a photo path that can escape into another profile.**  
   [FamilyGroup.swift:99](/Users/rickb/dev/VideoScan/VideoScan/People/FamilyGroup.swift:99) accepts arbitrary decoded `photoFilename`. [Line 135](/Users/rickb/dev/VideoScan/VideoScan/People/FamilyGroup.swift:135) then trashes that URL.

   **Reproduction:** Set an otherwise valid family’s `photoFilename` to `../<synthetic-person-uuid>/profile.json`; remove the family. The unrelated person’s source-of-truth profile is also moved to Trash.

   Require the expected family-owned photo filename and reject path or symlink escapes before deletion.

3. **P1 — A refused photo operation can already have destroyed the previous photo.**  
   [FamilyGroup.swift:122](/Users/rickb/dev/VideoScan/VideoScan/People/FamilyGroup.swift:122) replaces the existing photo before `save(group)` reaches its write guard at line 91.

   **Reproduction:** Give a family an existing photo, enable viewer mode, and call `setPhoto` with another valid image. Replacement precedes the refusal; the old photo is gone although the operation reports failure.

   Check authorization before image writes and preserve the old photo until the JSON commit succeeds.

For **A**, all three files were **read, no findings**. Gate and live refusal agree for identical captured inputs. They can disagree after state changes: capture while a volume is writable, then mark it read-only before completion. The captured gate allows what the live rule refuses. Steward can publish that stale proposal because [Steward.swift:215](/Users/rickb/dev/VideoScan/VideoScan/Steward/VideoScanModel+Steward.swift:215) checks cancellation without comparing catalog/designation generations. Given the stipulated final live-rule rechecks, this does not authorize an unsafe delete.

For **B**, `FeaturedVideos.swift` and `FamilyEditSheet.swift` were **read, no independent findings**. Two picks, or a pick and the normal profile edit save, serialize synchronously on main without an intervening `await`. Scoped profile writers route through `write(profileJSONAt:folder:)`; rename retains the UUID folder. The persistence APIs themselves are not universally main-actor isolated. Fully undecodable families fail the shown edit/pick reloads, but direct `save` can overwrite them and `moveToTrash` can trash their JSON. JSON writes are atomic; JSON-plus-photo operations are not transactional. Ordinary external photo sources are read only; Apple Photos uses an owned temporary copy.

For **C**, all ten listed files were **read, no findings**. Inspected workers receive projected values, not `VideoRecord` elements. The model-capturing projection closures execute synchronously before detachment. `StewardInputHandoff` contains projected rows with a locked transfer. `PersonFinderModel.swift` was **read, no findings** for the reference queue: it captures value inputs and the locked generation counter.

`PersonVideosSection.swift` was **read, no demonstrated race**. Its detached task captures the shared `PreviewDiskCache` reference at [line 401](/Users/rickb/dev/VideoScan/VideoScan/People/PersonVideosSection.swift:401); that cache’s implementation is outside scope.

The music worker in `CatalogHelpers.swift` and archive worker in `ArchiveView+Table.swift` were outside the supplied file list and remained unread. Those gaps prevent a complete Part C clearance. No inspected capture explains the unresolved SIGSEGV.

## Brief

Scoped data-risk review — today's changes that decide deletions, write the People store, or read catalog data off the main actor. 2026-10-04, `main` range 20f98257..HEAD. Read with `git show <sha>` / `git diff 20f98257..HEAD -- <path>`. Do not explore outside the files below. Do not check out anything; ~/dev/VideoScan is Rick's working copy.

Context: two main-thread SIGSEGVs today inside Swift runtime metadata/refcount code during SwiftUI layout (GH #273). One is now explained: a deterministic crash copying an AnyView context menu in the Archive Timeline, fixed by 476230e1. The 12:36 one (`_swift_getGenericMetadata` ← `CatalogScanTarget.isScratchVolumePath` ← `CatalogView.body`) is not explained; heap corruption from a data race is the leading theory. Part C below is aimed at it.

## A — Steward delete gate off the main actor (e713415b; merged in a142158c)
Files: `VideoScan/VideoScan/Archive/VideoScanModel+MasterArchive.swift` (`isInsideMasterArchive(path:root:)`, `BulkDeleteGate`, `bulkDeleteGate(effect:volume:)`, `bulkDeleteSubject`), `VideoScan/VideoScan/Steward/VideoScanModel+Steward.swift`, `VideoScan/VideoScan/Steward/StewardCaseBuilder.swift`.
Invariant: for every record, effect and snapshot, `BulkDeleteGate.refusal(for: bulkDeleteSubject(r))` == `bulkDeleteRefusal(r, effect:, volume:)`. Only the steward's proposals use the gate; real deletes still call `bulkDeleteRefusal` and re-check at the final verdict (#258). Questions:
1. Find any input where the two disagree, especially snapshot staleness. The gate captures the archive-volume and read-only snapshots ONCE on main; the refusal re-reads them.
2. Can the steward's off-main result be applied after the catalog or the designations changed, so that it PROPOSES a delete the live rule would refuse? Is that harmless, given the final verdict re-checks?

## B — People-tab picks and family groups (a88d3abe, e37f0a1d, 94dd330c, 6886b4b2, 888c95cb)
Files: `VideoScan/VideoScan/People/FeaturedVideos.swift`, `VideoScan/VideoScan/People/PersonFinderTypes.swift` (`featuredVideos`, `save(writingFeaturedVideos:)`, `write(profileJSONAt:folder:writingFeaturedVideos:)`, decoder), `VideoScan/VideoScan/People/FamilyGroup.swift`, `VideoScan/VideoScan/People/FamilyEditSheet.swift`.
profile.json is the source of truth for the inner circle (Rick's ruling). Invariants:
3. No profile save loses any field. Picks change only through `FeaturedVideos.set`, and every other save carries the on-disk list forward (888c95cb). Find a save path that bypasses `write(profileJSONAt:…)`, or a rename/migration path where "on disk" is not the live file.
4. Two picks in quick succession, or a pick racing a People edit-sheet save: is any interleaving lossy? Everything is on the main actor; confirm that, or show the await that breaks it.
5. FamilyGroupStore: does `setPhoto` ever modify or move the source image? (Apple Photos data goes to our own temp file first.) Are atomic writes, and moveToTrash (family JSON plus photo), sound? Can a corrupt family file be overwritten or deleted?

## C — Off-main computations added today: data-race audit (a142158c, five commits e713415b..56977a99)
Files: `VideoScan/VideoScan/Catalog/CatalogStorageTotals.swift`, `Catalog/CatalogSizeTotals.swift`, `Catalog/CatalogView+ScanTargetsPane.swift`, `Catalog/CatalogDistributionPane.swift`, `Catalog/CatalogContent+Promote.swift`, `Archive/ArchiveView.swift`, `Archive/ArchiveView+Categories.swift`, `MediaOps/MusicTriage.swift`, `Steward/StewardCaseBuilder.swift`, `Steward/VideoScanModel+Steward.swift`.
`VideoRecord` is a mutable CLASS owned by the main actor.
6. Does ANY of these background tasks read a `VideoRecord` instance, the `records` array's elements, or another main-actor class (directly, through a closure capture, or via an `@unchecked Sendable` wrapper) instead of a value snapshot taken on main? Name file:line and the captured reference. This is the top question.
7. The same question for `People/PersonVideosSection.swift` (`loadCachedThumbnail`'s detached task) and `People/PersonFinderModel.swift` (`referenceLoadQueue`, dda76157).

Known and accepted (do not report): UI wording; SwiftLint warnings; picks reachable only from Catalog and People (the Archive menu entry was removed on purpose); a family has no crop controls; first-visit blanks while background totals land; the retired-drive bare-prefix quirk (moved unchanged).

Evidence already run: suites per commit, all Debug and filtered by suite with counts confirmed. Steward equivalence: 5 model states × 3 effects × 54 records. People suites 154/17. Picks-survival mutation-checked. An Address Sanitizer battery is running tonight. No Thread Sanitizer evidence yet.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>
- Rate each finding P1 (data loss, or a race that can corrupt memory) or P2/P3.

Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Closed

Closed by `497fda17` at 2026-10-05T02:22:15Z. 3/3 P1 closed with pinning tests (mutation-checked): quarantined pick rows carried forward; family photo name pinned to <UUID>-photo.jpg, no symlinks; write guard before any photo write, JSON committed before replace. Part A/C: no findings; stale steward proposal judged harmless (final verdict re-checks).

## Findings closed (overnight 2026-10-04)

| # | Finding | Closed by | Pinning test |
|---|---|---|---|
| 1 | One unreadable pick row → an ordinary save erases every pick (person and family) | 497fda17 | `PeopleCodexOvernightTests.aDamagedPickRowSurvivesAnOrdinarySave` (includes the stale-copy case; mutation-checked), `aDamagedFamilyPickRowSurvivesARename` |
| 2 | A crafted family `photoFilename` lets Remove trash another profile | 497fda17 | `aCraftedPhotoNameIsNeverTheFamilysPhoto` (mutation-checked), `trashAndPhotoWritesGoThroughTheGuards` |
| 3 | `setPhoto` replaced the old photo before the write guard | 497fda17 | `trashAndPhotoWritesGoThroughTheGuards` (guard before the first image write; JSON committed before replace) |

Part A note (stale steward proposal after a designation change) is accepted as harmless: the steward only proposes, and every delete re-runs the live rule at the final verdict (#258). Part C: no inspected background task reads a live `VideoRecord`, so the 12:36 SIGSEGV (#273) remains unexplained; Thread Sanitizer evidence is due tonight.
