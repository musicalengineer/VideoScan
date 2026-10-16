# Codex review — Footage folders

- Range: `230781f01..512dcf79e`
- Credits spent: unavailable
- Tokens: 82906
- Finding count: 4
- Verdict: fix — a hidden selection can reach destructive actions.
- Run: 2026-10-16T22:25:30Z (cycle #85, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — a hidden selection can reach destructive actions.

- **P1 — Folder scope does not constrain action targets.** [CatalogContent+FolderTable.swift:438](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogContent+FolderTable.swift:438) selects every arriving derivative without clearing an unrelated event scope. Selection pruning uses pre-scope `tableData` ([CatalogTableState.swift:108](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogTableState.swift:108)); Trash and Promote use that same broader set ([CatalogContent+Table.swift:498](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogContent+Table.swift:498), line 231). **Reproduction:** scope to event B while a transcode from event A runs; when it finishes, its invisible derivative becomes selected and survives refresh. ⌘⌫ offers to trash it, despite its absence from the displayed event. Action targets and selection pruning must use the actual displayed record IDs.

- **P2 — A derivative’s archived copy can become the original.** [FootageFolders.swift:391](/Users/rickb/dev/VideoScan/VideoScan/Catalog/FootageFolders.swift:391): original A → transcode B → promoted byte-copy C admits C into `roots` because C shares B’s copy group; C wins keeper, B reads “copy,” and A reads “same event.”

- **P2 — An unassigned copy can follow the wrong event.** [FootageFolders.swift:372](/Users/rickb/dev/VideoScan/VideoScan/Catalog/FootageFolders.swift:372): A belongs to E1, its derivative B belongs to E2, and unassigned C shares A’s `duplicateGroupID`; if E2 wins the vote/UUID tie-break, C joins E2 instead of following A into E1.

- **P2 — The setting is not strictly Boolean.** [FootageFolderTableRow.swift:154](/Users/rickb/dev/VideoScan/VideoScan/Catalog/FootageFolderTableRow.swift:154): a stored numeric `1` bridges through `NSNumber` to `Bool`, turning folders ON; the poison test covers strings and dictionaries but misses numeric values.

The extracted linear cells, OFF keyboard/menu guards, legend, crumb, and Showing pill were read, no findings. No new O(records) body traversal was found; the rebuild fallback projects one record, although its archive-helper internals lie outside the allowed files. The named toolbar, helpers, organize menu, words, filename cell, ContentView, and model changes were read, no additional findings.

The snapshot’s equality gates hold. Sampled `v1:` digests are rejected; dangling ancestry and cycles terminate. Overlapping event membership uses the first claimant rather than rejecting the damaged overlap. The named jobs and tests were read: failure branches avoid adoption; cancellation during their awaited probe remains a pre-existing gap.

Literal OFF parity does not hold for derivative publication/selection; I treated your explicit requirement to reveal derivatives in both views as the exception.

Reviewed `512dcf79e`; no files written or tests rerun. Credit usage is not exposed to this session.

## Brief

# Codex brief: Footage folders — Show ▸ Events & Copies as Folders (UI + a pure join; not data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**One sentence (Rick, 2026-10-16):** the Catalog shows an event as a Finder-style folder with everything about it inside — recordings, their copies, what was made from them — so a person can date, rename, transcode, promote and tidy one occasion without leaving the row.

**Design:** `docs/design/footage_folders_2026_10_16.md` (§2 ruling, §3 relations, §4 model, §6 tests). The option is OFF by default; off must be byte-identical to today's linear table.

**Range:** `230781f01..512dcf79e` on `main` (merge `512dcf79e`; the work is `a1385a805`). Read with `git show 512dcf79e:<path>`. Paths under `VideoScan/VideoScan/`.
- `Catalog/FootageFolders.swift` — the pure join: `Row`, `Event`, `Relation` (`recording | madeFrom | copy | clip | sameEvent`), `Family`, `Index`, `Display`; `index(rows:events:)` (confirmed events only; copies by `storedFullDigest`+size else `duplicateGroupID`, a `v1:` sampled hash never; lineage by `derivedFrom`; a copy outside any event follows its original; keeper = archived file › archived content › ladder order › longest › the copy the versions were made from › catalog order, chosen among ORIGINALS); `compose(index:visible:sort:open:scope:)` → the FLAT display.
- `Catalog/FootageFoldersSnapshot.swift` — model-owned ObservableObject, equality-gated; the O(records) projection on the main actor per debounced catalog change, the join in `Task.detached`; runs only while the option is on AND the Catalog pane is on screen; `adoptDerivative` / `DerivativeLanding` = the ONE door a job's derivative enters the catalog by.
- `Catalog/FootageFolderTableRow.swift` — the folder table's row type; `FootageFolderSort` (KeyPathComparator ⇄ sort mapping by a data table); `CatalogFootageFoldersSetting` (strict Bool read — a poisoned value never reads ON); `CatalogTableReveal` (scrollRowToVisible on the NSTableView).
- `Catalog/FootageFolderWords.swift` — every word, glyph, colour, indent in one place.
- `Catalog/CatalogContent+FolderTable.swift` — a second `Table<FootageFolderTableRow>` drawn INSTEAD of the linear one while on (a folder is not a VideoRecord and must never reach ⌘⌫ / Promote as one); shared selection set + sort order; cells, legend, crumb, folder menu, double-click scope, row-menu items, keyboard (→/← open/close; ← on a member selects its folder; Esc clears a scope), reveal.
- `Catalog/CatalogContent+Table.swift` (cells extracted verbatim into shared builders; `catalogTableChoice`), `CatalogTableState.swift` (open set, scope, folder rows), `CatalogFilenameCell.swift` (`dimmed:`), `CatalogHelpers.swift`, `CatalogToolbar.swift`, `CatalogShowingSummary.swift` ("As folders" pill), `CatalogRowContextMenu+Organize.swift`, `App/ContentView.swift` (the Show option), `Model/VideoScanModel.swift` (storage + hook), `MediaOps/{Transcode,Reformat,Trim,RebuildAudio,Cleanup}Job.swift` (one-line `adoptDerivative` each).
- Tests: `VideoScan/VideoScanTests/FootageFoldersTests.swift` — Logic 21, Scale 1 (100k rows / 2k events / 30k copies: index 1.11 s vs 1.5 s budget, compose 0.24 s), Isolation 3, Sensor 5, Structure 5. 34 green (Debug) + neighbours.

**Attack (prove with file:line or say it holds):**
1. OFF IS OFF: with the option off, is anything different from before this range — a body that does extra work, a menu item, a key monitor that swallows a key, a publish, a save, a changed cell? Does the linear `Table` draw a record exactly as before after the cell extraction?
2. NO O(records) IN A BODY: the folder table's body, the crumb, the legend, the Showing pill, the row menu — do any touch `model.records`, iterate the index, or compute per row? Is `rebuildFolderRows`'s fallback bounded?
3. SELECTION AND DANGEROUS DOORS: a folder row is selected (click, ↑↓) — can ⌘⌫, Promote…, Transcode…, Delete Junk, Cleanup, Compare Media, or any row action receive a folder as if it were a record, or receive the folder's MEMBERS implicitly? Does a scope (double-click) change what a bulk action sees?
4. THE JOIN'S TRUTH: a `v1:` sampled hash never makes a copy; the keeper is an ORIGINAL (a promoted copy counts; "↳ made from it" points the right way); a copy outside any event follows its original; a superseded / hidden / set-aside row; a record in two events (Events v1 guarantees non-overlap — is that relied on, and what happens if it is violated by a damaged decisions file?); a `derivedFrom` pointing at a row that no longer exists; a cycle (`derivedFrom` A→B→A).
5. THE REVEAL: `adoptDerivative` on a job's success only (never on failure/cancel); the new row selected and revealed in both views; with a filter that hides it, "selected then pruned on the next refresh" — can that leave a stale selection that a later ⌘⌫ acts on?
6. PERSISTENCE AND ISOLATION: a poisoned setting reads OFF; a damaged events decisions file → no folders, no crash; the snapshot publishes only on change.

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the audit job; Fix Links; Add to Event… / New Event… (§5a, next cut); sound-based `⊂` relations (phase 2); wording and spacing (Rick iterates by eye).

**Do not explore outside the files listed above and their tests.**


## Closure (Manager, 2026-10-16 — fix `158cfd4be`, merged `51c3170c3`)

All four closed RED FIRST (19 issues red against main across 3 suites; then 106 tests in 13 suites green, Debug).
1. **P1 hidden selection → destructive doors — closed.** ONE rule, `CatalogSelectionPrune.displayed(_:foldersOn:folderRecordIDs:rows:)`, and one accessor on the content (`displayedSelection` / `displayedSelectedRecords` / `displayedIDs(among:)`): ⌘⌫, Promote…, ⌘I, ⌘O, the row menu's every item, the folder table's primary action all take selection ∩ displayed; the display landing prunes the selection; `DerivativeReveal.plan` decides `.select / .openScopeAndSelect / .hiddenByFilter / .outsideScope` BEFORE anything is selected (a derivative from another event lands unselected with one console line; a filter-hidden row is not selected even with the option off — closes the stale-selection trap). Pins: suite `FootageFoldersSelectionTests` (7) + sensors `everyRowActionGoesThroughTheDisplayedSelection`, `theRevealChecksTheDisplayBeforeSelecting`.
2. **P2 byte-copy of a derivative as keeper — closed.** Roots are originals (`isOriginal` walks `derivedFrom` inside the family); per copy group the member whose source is outside the group is the version and its byte-copies read "copy of it". Pin `aByteCopyOfADerivativeInheritsTheDerivativesPlace`.
3. **P2 unassigned copy's event — closed.** Per-copy-group vote before the family vote. Pin `anUnassignedCopyFollowsItsOwnCopyGroupsEvent`.
4. **P2 setting strictness — closed.** `CFGetTypeID == CFBooleanGetTypeID` before `as? Bool`. Pin `onlyAPlistBooleanReadsAsOn`.

Follow-ups noted, not changed: ContentView's Correlate / Analyze Duplicates / Find Similar Footage toolbar actions still take the raw selection (non-destructive); the row menu resolves records per id by linear search (pre-existing, `model.record(forID:)` is O(1)); programmatic selects under a scope are pruned by the display.

## Closed

Closed by `51c3170c3` at 2026-10-16T22:50:48Z. 1 P1 + 3 P2 closed red-first
