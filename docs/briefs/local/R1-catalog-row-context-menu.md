# R1: overnight refactor, Catalog files table (GH #281)

**Night of 2026-10-05, M4, local.** Owner: Manager → `refactor` agent →
`testing` → `qa`. Branch `refactor/r1-catalog-table`. **Never merged overnight:**
Rick spot-tests in the morning, then it merges.

## Target
- `Catalog/CatalogContent+Table.swift`: `rowContextMenu` (lizard CCN 81 / 489 lines,
  `swiftlint:disable:next` at :514). File 1,949 lines.
- `Catalog/CatalogHelpers.swift`: 34 `@State` + the files table's
  `@FocusState` in a file named "Helpers". 1,862 lines.

## Goal (behavior-preserving ONLY)
1. Split `rowContextMenu` by menu section (open/reveal · verify · audio lifecycle ·
   rename/notes/tags · archive/promote · duplicates · delete/trash · …), each its own
   small `@ViewBuilder` func or View in a new file `CatalogRowContextMenu*.swift`.
   Every resulting function ≤ CCN 15 and ≤ 80 lines where possible; none > 30.
   Remove the `swiftlint:disable:next` at :514.
2. Pull menu *decisions* (what's enabled, labels, counts — e.g. the Verify
   "(N Files)" counting) into plain functions or a small struct that can be unit-tested
   without SwiftUI, and add those unit tests.
3. Gather the selection/focus state from `CatalogHelpers.swift` into one clearly named
   type/file (e.g. `CatalogTableState`), so a later change can add a volume-pane
   focus owner (`enum Pane`) in one place. **Do NOT change focus behavior tonight.**
4. If time remains: break up `tableWithCatalogTriggers`'s modifier chain (21.7 s
   type-check) into named modifiers.

## Rules
- Menu items, order, labels, enabled states, keyboard shortcuts and actions are
  identical before and after. Diff the menu structure by eye and in the report.
- **Source sensors pin code by file name:** `DeleteVolumeCatalogPlanTests`,
  `MediaFileOperationsWindowForwarderTests`, `MusicTriageOffMainTests`,
  `CatalogTrashShortcutTests`, `CatalogOpenShortcutTests`, `ReadOnlyVolumeTests`,
  `VerifyVideoJobTests` read `CatalogContent+Table`/`CatalogHelpers`/
  `CatalogView+VolumeTable` source. When code moves, update the sensor to the new file
  **without weakening what it asserts**, and show it still goes red when the guard is removed.
- Tests: Release, `ENABLE_TESTABILITY=YES`, `-only-testing` by suite. Run all
  `Catalog*` suites + the 7 sensors above + any suite that fails to compile. Baseline
  BEFORE the change (counts), then after. Check counts are non-zero.
- RAM: at most 2 xcodebuild test runs at once before midnight. Use your own `-derivedDataPath`.
- Command shape per CLAUDE.md (no `cd &&`, no leading `VAR=`, no leading loops).
- Stop by 01:45: commit what's green, note what's left. The 02:00 nightly needs the M4.
- No new features, no wording changes, no focus fix.

## Morning spot test for Rick (fill in the report)
Right-click a file in the Catalog: every section's items are there and work
(open, reveal, verify, rename, tags, archive, delete-to-Trash on a test file).
↑/↓ still walk the files. Multi-select right-click labels show the right counts.

Report: `docs/reviews/local/R1-catalog-row-context-menu.md`: before/after
lizard numbers, test counts, sensor changes, menu-parity table, what's left.
