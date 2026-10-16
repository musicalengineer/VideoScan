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
