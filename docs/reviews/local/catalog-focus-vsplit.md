# Catalog focus plan — fix/catalog-focus-vsplit (2026-10-06)

Plan: `docs/design/catalog_window_architecture_2026_10_06.md` (Fable's
corrections applied). Rick's rulings 10/6: "do what Finder does".

## Commits

| SHA | Step |
|---|---|
| b0c7c6f7 | 0: `CatalogKeyboardUITests` harness, `-gauntletFixtureCatalog` seam (3 × 20 `test_*` files in the Gauntlet sandbox), `[keys]` first-responder trace |
| 7e4042c5 | 1: `VSplitView` replaces `VerticalSplitView` (one SwiftUI hierarchy). No max-height cap; the divider stays where it's dragged. Adds the source sensors. |
| 8801bb59 | 2: one `@FocusState focusedPane: CatalogPane?`; edge 4 and the onAppear grab deleted; **`CatalogTableClickFocus`** (see below) |
| ccb762ea | 3: Space only in the files pane. 4: hidden selection dropped (`refreshRows`). 5: ⌘I = File ▸ Catalog Info; **Import Catalog… → ⇧⌘I**; hidden ⌘I Button gone. **Promote Selected scoped** (safety-critical) |
| 50d754d0 | 8: `VerticalSplitView.swift` moved to `.trash/`. All `notifyTargetsChanged()` calls kept |

Control branch `test/catalog-focus-control` (local, do not merge): the
0cb46905 shape on the step-0 harness.

## Red → green (Release, `ENABLE_TESTABILITY=YES`, M4)

| Case | main code (b0c7c6f7) | after step 1 | after step 2 | branch HEAD |
|---|---|---|---|---|
| 1 click file 3 → volume 0 → ↓ | **FAIL** (`[0]` ≠ `[1]`) | FAIL | pass | pass |
| 2 click file 3 → ↓↓ | pass (via edge 4) | pass | FAIL → pass after click-focus | pass |
| 3 Move to Trash follows pane | **FAIL** (enabled after volume click) | FAIL | pass | pass |
| 4 Space only in files | **FAIL** (toggled from volumes) | FAIL | FAIL | pass |
| 5 Tab / ⇧Tab (record only) | — | — | — | volumes → search → files → volumes |
| 6 control (0cb46905 shape) | case 2 **FAIL**: file arrows dead; volumes table keeps the keyboard | | | |
| 7 Promote Selected, hidden file | **FAIL** (enabled) | FAIL | FAIL | pass |
| 8 ⌘I Catalog Info follows volumes | (no such item on main) | | | pass |

Source sensors (`CatalogFocusPlanSensorTests`): 13 of 14 red on the step-0
code. The one green is a guard: the volumes pane publishes no file verbs.

Catalog* unit suites: 408 Swift Testing tests in 74 suites, plus 48 XCTest,
all pass (Release). Debug build passes.

## What the harness found (design Q3, answered)

The `[keys]` trace shows a click on a SwiftUI `Table` row selects the row
but **never moves first responder**. This holds in either pane, and in one
hierarchy too. The hit view is `SwiftUIOutlineTableView` with
`accepts=true refuses=false`, so it isn't refusing. VSplitView alone
therefore doesn't fix the arrows; main's edge 4 had been hiding it.

`CatalogTableClickFocus` applies Finder's rule explicitly:

- It is a local mouseDown monitor, installed only while the Catalog tab is
  on screen. It observes the event and never consumes it.
- On a click inside a table that isn't first responder, it makes that table
  first responder.
- It reacts to the click, never to selection. A volume click that
  re-filters the files can't move the keyboard.

**This deviates from the doc**, which assumed clicks focus tables natively.
It is the one `makeFirstResponder` in Catalog/, and it is sensor-pinned.
Manager/Rick: please review.

## Promote Selected (safety-critical)

- **Workflow:** "promote the files I can see highlighted in the Catalog to
  the Master Archive."
- **Cut:** the `catalogSelectedIDs` mirror (removed).
- **Outcomes:**
  - Enabled only while the files table has the keyboard.
  - At click time the IDs are visible ∩ selected.
  - If that set is empty, it refuses with a console line.
  - Otherwise it goes through the existing `requestPromote` (read-only
    refusal, no-master alert, identity check, confirmation sheet), which is
    unchanged.
- **Pins:** harness case 7, which was red on main;
  `CatalogPromoteScopeSensorTests`; `CatalogPromoteScopeTests` (logic plus
  100k-record scale).
- **No codex pass yet.** It's Rick's call. If he wants one, scope it to
  `CatalogPromoteCommand.swift`, the files-table focused value, and the
  `VideoScanApp` menu wiring.

## Open

- **Default focus at open (QA item 2, for Rick):** the volumes table has
  the keyboard when the Catalog opens. Harness case 9 (↓ with no click
  must move the files) was red. Two declarative attempts did not move it:
  - `.defaultFocus($focusedPane, .files)` on the common ancestor;
  - `.focusScope(ns)` on the root split plus `.prefersDefaultFocus(true,
    in: ns)` on the files table (tried and backed out).

  The `[keys]` trace shows the volumes NSTableView holds first responder
  before any key. The fix that would work is a programmatic focus write,
  which breaks the rule. Case 9 is pinned with a non-strict
  `XCTExpectFailure`, so it reports an unexpected pass once this is fixed.

## QA round 1 (FIX-FIRST)

1. Scope leak: fixed. `CatalogTableClickFocus` now acts only when
   `event.window === catalogWindow`. The window is captured by
   `CatalogWindowReader`, and while it's unknown the hook does nothing. An
   `isolated deinit { remove() }` backstop was added. Pinned by
   `CatalogClickFocusWindowScopeTests` (the predicate plus a guard sensor),
   red by new seam.
2. Default focus: stopped without a programmatic write, as instructed.
   See the item above.
- Step 6 (Tab): it already cycles correctly, so no `.focusSection` was
  needed.
- Step 7 ("All volumes" pill) was not done. It's wording, not focus.
- ⌘F was not added (it isn't trivial with the inline search field).
- The 3-click test for Rick: click a file, then click a volume, then press
  ↓. The volume selection should move and the file selection shouldn't.
  Also check ⌘⌫ (should be off) and Space (should do nothing).
