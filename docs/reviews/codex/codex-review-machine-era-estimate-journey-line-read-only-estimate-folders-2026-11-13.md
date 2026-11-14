# Codex review — Machine era estimate: journey line + read-only estimate folders

- Range: `origin/main..HEAD`
- Credits spent: unavailable
- Tokens: 148453
- Finding count: 4
- Verdict: fix — mode transitions expose synthetic-folder edit paths, unestimated content inherits folders, and real-folder reveals can remain pending.
- Run: 2026-11-14T02:40:44Z (cycle #290, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: fix — mode transitions expose synthetic-folder edit paths, unestimated content inherits folders, and real-folder reveals can remain pending.

Reviewed `79a973aa8..43426917f`. The uncommitted `FootageFoldersSnapshot.swift` edit is excluded. No files changed or tests run; the proposed RED checks below are unexecuted.

1. **[P2] The edit gate changes before the displayed folders do.**  
   [CatalogContent+FolderLabels.swift:167](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/Catalog/CatalogContent+FolderLabels.swift:167), [CatalogContent+FolderDrop.swift:90](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/Catalog/CatalogContent+FolderDrop.swift:90), [CatalogContent+FolderTable.swift:404](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/Catalog/CatalogContent+FolderTable.swift:404).

   `FootageFoldersSnapshot.publish(index:)` replaces the index synchronously, then recomposes the display asynchronously. Switching estimates off therefore leaves synthetic rows displayed briefly with `index.estimated == false`. Rename/Delete become available and can pass synthetic IDs into the store’s write methods. Those methods currently reject unknown IDs, so **this establishes an exposed path, not a confirmed persisted write**.

   Reproduction: display estimate folders, switch estimates off, and delay the replacement composition. Right-click a retained estimate row.

   Proposed RED check: publish and synchronously compose an estimate index, then publish a real index without yielding. Assert:
   ```swift
   #expect(snapshot.index.estimated ||
       !snapshot.display.rows.contains { $0.eventID == estimateID })
   ```
   The assertion fails. Gate actions using the displayed folder’s identity/type, or retire the old display before opening edits.

2. **[P2] Synthetic IDs occupy the real-folder UUID namespace.**  
   [MachineEstimateFolders.swift:66](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/Catalog/MachineEstimateFolders.swift:66).

   The `4000-8000` template is a valid version-4 UUID shape, just like real folders’ `UUID()`. The fixed prefix makes accidental collision extremely unlikely; it does not satisfy “can never equal.” `EventRecord` also accepts stored UUIDs without reserving this prefix. Combined with finding 1, an alias defeats the store’s unknown-ID refusal.

   Reproduction/proposed RED fixture: load a legitimate real-folder record with ID `E57A0000-0000-4000-8000-000100001991`, then assert its ID differs from `folderID(.year(1991))`. They are equal. Use an enforced disjoint namespace or distinct identity type.

3. **[P2] A content with no era inherits an estimate folder through lineage.**  
   [MachineEstimateFolders.swift:48](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/Catalog/MachineEstimateFolders.swift:48), followed by `FootageFolders.split` at line 419.

   Filtering synthetic event membership does not keep unestimated rows loose: the subsequent normal join assigns an unfiled derivative to its family’s leading folder. This contradicts the explicit no-era invariant and the legend. The same inheritance can include a derivative with only a sampled hash.

   Proposed RED test, using the existing test helpers:
   ```swift
   let parent = row("source.mov", digest: hex(1))
   var child = row("clip.mov", digest: hex(2))
   child.derivedFrom = parent.id
   let rows = [parent, child]
   let events = MachineEstimateFolders.events(
       rows: rows, eras: [hex(1): [era(1980, 1995)]])
   let index = FootageFolders.index(rows: rows, events: events)
   #expect(index.folders(of: child.id).isEmpty)
   ```
   The join places `child` in the estimated 1980s folder.

4. **[P2] Navigation to a real folder never leaves estimate mode.**  
   [ContentView.swift:1550](/Users/rickb/dev/VideoScan-wt/estimate/VideoScan/VideoScan/App/ContentView.swift:1550).

   `showFoldersWithoutFocus()` enables folders but does not disable estimates. Both Events’ “Show in Catalog” and the reveal after “Make Folder” use this path. While estimates remain enabled, refresh deliberately excludes real events, so `takePendingFolderReveal` cannot find the requested ID.

   Reproduction: enable estimates, visit Events, then choose “Show in Catalog” for a real folder. Alternatively, create a real folder from selected files while estimates are enabled. The requested folder remains unrevealed.

   Proposed RED integration test: exercise either route with estimates enabled, await the join/display, and assert the real folder is selected and `pendingFolderReveal` is cleared. Switch to real folders before completing that navigation.

Within the remaining named scope:

- `MachineEraResolver.swift` — read, no findings.
- `FootageFolders.swift`, `Index.estimated` — read, no findings.
- `MachineEraStore.swift` — read, no findings.
- `VideoScanModel+Provenance.swift` — read, no findings.
- `Model/ProvenanceTypes.swift` — read, no findings.
- `CatalogToolbar.swift` — read, no findings.
- `CatalogShowingSummary.swift` — read, no findings.
- `MachineEstimateFoldersTests.swift` — read, no findings.
- The three new `MachineEraResolverTests.swift` tests — read, no findings.

Scope expansion: traced the direct table/navigation/inspector callers and inspected the family-join, event-store identity/write checks, and digest helpers needed to verify these invariants.

## Brief

# Codex review brief — machine era estimate in the File Journey and as read-only Catalog folders

*Not data-risk code (a view; nothing is written). The owner asked for a Codex pass anyway. Review the one commit on `feat/machine-estimate-folders`.*

**Workflow in one sentence (the user's words):** "machine generated folders with estimated dates … only a view in the catalog … we can switch it off", and "the machine estimated date in the file journey … not confirmed until they confirm it".

**Range:** `origin/main..HEAD` (one commit) · **Worktree:** `/Users/rickb/dev/VideoScan-wt/estimate`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/Catalog/MachineEstimateFolders.swift` (new) — `events(rows:eras:)`, `folderID`, the toggle view
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Background/MachineEraResolver.swift` — `journeySentence`, `EstimateFolder`, `estimateFolder(era:)`
- `VideoScan/VideoScan/Catalog/FootageFoldersSnapshot.swift` — `estimated`, `setEstimated`, `watchEras`, `scheduleFootageFoldersRefresh`, `setFootageFoldersEstimated`, `footageFolderViewChanged`
- `VideoScan/VideoScan/Catalog/FootageFolders.swift` — `Index.estimated` only
- The read-only gates: `CatalogContent+FolderLabels.swift` (`folderRowMenu`), `CatalogContent+FolderDrop.swift` (`dropOnFolder`), `CatalogContent+FolderTable.swift` (`rowsFolder`, the legend)
- `VideoScan/VideoScan/Catalog/MachineEraStore.swift` (`journey(for:)`), `VideoScanModel+Provenance.swift` (`buildFileJourney`'s new event), `Model/ProvenanceTypes.swift` (`JourneyMachineEra`, `.machineEstimate`)
- `CatalogToolbar.swift`, `CatalogShowingSummary.swift`, `App/ContentView.swift` — the toggle, the pill, folder-view-off
- Tests: `VideoScanTests/MachineEstimateFoldersTests.swift`, the three new tests in `MachineEraResolverTests.swift`

**The change (attack it):**
1. While the option is on, the folder join (`FootageFolders.index`) is fed synthetic `Event`s built from the era cache instead of the user's own folders; `Index.estimated` is set true. Folder ids are synthetic UUIDs no store knows.
2. Every folder EDIT path must refuse or be unreachable while `index.estimated` is true. "Add to Folder ▸" (to one of the user's REAL folders) is deliberately still offered.
3. The File Journey gains one event, kind `.machineEstimate`, timestamped when the machine made the guess.

**Invariants that must hold:**
- NOTHING IS WRITTEN by the estimate view: no row in the events/folders store, no date, no assertion, no ledger event. Find any path that, with `index.estimated == true`, reaches `EventsDecisionStore` (rename, setKind, deleteFolder, EventsFolderDrop/EventsFolderRemoval `.apply`, confirm) carrying a synthetic folder id — context menu, drag and drop, keyboard, Make Folder, the folder inspector, the derivative reveal (`revealDerivative` / `selectDerivative`), "Show in its event", the pending drop/reveal state, a Person-page or Events-page link into the Catalog.
- A stale index: the option flips while a join task is in flight, or the folder view is turned off and on. Can `index.estimated` disagree with what the folders really are (estimated == false while the folders are synthetic, so the edit paths are open on synthetic ids; or estimated == true over the user's real folders, so his folders look read-only)? Look at `publish(index:)`'s equality gate, task cancellation, `stop()` keeping the old index, and `setFootageFoldersWanted`.
- A synthetic folder id can never equal a real folder's id.
- The user's own folders are exactly as before when the option goes off (nothing persisted except one UserDefaults bool).
- TRUTH: the journey line and folder titles never present the guess as a fact or a date; a content with no era gets no line and no folder; a sampled `v1:` hash never matches an era.
- No O(records) work in a SwiftUI view body; the Showing pill and the toggle redraw when the option flips.
- Swift 6 concurrency: the detached join captures only Sendable values.

**Known and accepted (do not report):**
- The 8B's ranges are mostly 10–20 years wide, so "decade of the midpoint" is coarse; that is what is being evaluated by the owner.
- UI words are the owner's to change.
- Folder state (open triangles, scope) resets when the option flips.
- You cannot run tests in the read-only sandbox.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by risk (a write under the estimate view is the top class), each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
