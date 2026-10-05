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
