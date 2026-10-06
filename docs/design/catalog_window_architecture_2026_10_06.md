# Catalog window — keyboard and focus architecture (design study, 2026-10-06)

Status: proposal, no app code changed. Baseline: `main` @ 94ff7fe8 (the revert of
0cb46905). Audience: Rick. Scope: the Catalog tab's two tables (volumes on top,
files below), the inspector, the search field, the menus that act on a selection,
and the keys ↑/↓, ⌘⌫, ⌘O, ⌘I, Space and Tab.

## 0. The short version

**Root cause.** The two tables live in **two separate SwiftUI hosting roots**.
`CatalogView.rootSplit` (ContentView.swift:572-584) wraps them in
`VerticalSplitView`, which builds an `NSSplitViewController` holding **two
`NSHostingController`s** (Shared/VerticalSplitView.swift:54-58). Each hosting
controller runs its own SwiftUI view graph. SwiftUI's focus API is specified per
*scene view hierarchy* — `FocusState` is "a value that SwiftUI updates as the
placement of focus within the scene changes" (Apple docs, FocusState) — and Apple
documents no bridging of focus between hosting controllers (the only bridging
options, `NSHostingSceneBridgingOptions`, cover the title and toolbar). So
there is no one place in SwiftUI that can see both tables at once. Every fix so
far has used one of two workarounds: (a) code that moves focus whenever something
changes, or (b) a `@FocusState` owned in one graph and bound in another. (a) causes
cross-pane side effects: a volume click re-filters the files and the files table
takes focus. (b) left the arrows dead in both panes (0cb46905, reverted).

**Recommendation.** Put both tables in **one** SwiftUI hierarchy with SwiftUI's own
`VSplitView`, which `CatalogContent` already uses for table+player and
`HSplitView` for the inspector (CatalogHelpers.swift:679-681). Then use the
documented pattern: one `@FocusState<CatalogPane?>` in the common ancestor, a
`.focused(equals:)` on each table, one `.defaultFocus`, and **no code that assigns
focus**. Menu commands read `focusedValue`s that only the focused table publishes.
The "jiggle" that motivated `VerticalSplitView` came from a DragGesture divider
(commit ec2b12c6), not from SwiftUI split views. It does not apply to `VSplitView`.

**Plan.** 8 small steps. Step 0 builds a real-keyboard XCUITest harness, which must
go red on today's `main`. No focus code changes before that harness exists.

---

## 1. Current structure (main @ 94ff7fe8)

### 1.1 View tree and hosting boundaries

```
NSWindow (WindowGroup "main", VideoScanApp.swift:544)
└─ HOST A: the window's NSHostingView — ContentView
   └─ CatalogView (ContentView.swift:287)            ← owns selection/filter @State
      └─ withAlerts(withSheets(rootSplit))           (:568-570; sheets :898-1105)
         └─ VerticalSplitView  (NSViewControllerRepresentable, :573)
            └─ NSSplitViewController
               ├─ HOST B: NSHostingController<AnyView>  — scanTargetsPane
               │    (CatalogView+ScanTargetsPane.swift:495)
               │    ├─ volume verbs row (Scan Volume…, Compare, …)
               │    ├─ volumeTable — Table(selection: $selectedVolumeIDs)
               │    │     (CatalogView+VolumeTable.swift:139)
               │    └─ hidden Button "" ⌘I (ScanTargetsPane.swift:918-927)
               └─ HOST C: NSHostingController<AnyView>  — bottomPane (:586)
                    ├─ CatalogToolbar (search TextField, CatalogToolbar.swift:538)
                    ├─ PreviewSweepStatusLine
                    └─ CatalogContent (CatalogHelpers.swift:678)
                       └─ HSplitView                       (:679)
                          ├─ VSplitView                    (:681)
                          │  ├─ banners + files Table       (CatalogContent+Table.swift:202)
                          │  └─ previewPlayer
                          └─ InspectorPanel (if showInspector) (:726)
                       + CatalogContent's own sheets (CatalogHelpers.swift:769-890)
```

C++ analogy: hosts B and C are two separate GUI frameworks embedded in one
window. Each has its own event loop state and its own idea of what has focus.
`CatalogView`'s `@State` lives in host A. The closures that `VerticalSplitView`
receives carry *values and bindings* into B and C. On every `CatalogView` body
evaluation, `updatePanes` replaces both root views with new `AnyView`s
(VerticalSplitView.swift:77-80). The bindings still work, because they are
references to host A's storage. But focus is not a binding. It is per-graph
machinery that sits over the AppKit first responder.

This boundary has caused trouble before. The commit that introduced
`VerticalSplitView` (ec2b12c6, 2026-04-21) also added `notifyTargetsChanged()`,
"scanTargets self-assignment to force SwiftUI table rebuild through NSSplitView
hosting chain" (VideoScanModel.swift:188-193). That hack has 32 call sites today.

### 1.2 State involved in selection, filter, focus and keyboard

| State | Declared | Host | Written by | Read by |
|---|---|---|---|---|
| `selectedVolumeIDs: Set<UUID>` | CatalogView @State, ContentView.swift:482 | A | volume Table (B); navigation verbs reset it to `[]` (:749, :770, :782, :964, :1194, :1244, :1330); `volumeShowFilterDidChange` trims it (:1364-1365) | `filterTargetPaths` (:456-458), ⌘I (:1387), volume menus |
| `filterTargetPaths` | computed, :456 | A → C as a value | derived | `CatalogContent.computeFiltered`; `onChange` → `tableData` (CatalogContent+Table.swift:149) |
| `selectedIDs: Set<UUID>` | CatalogView @State, :290 | A, @Binding into C | files Table; verbs (:752, :773, :785, :967, :1231, :1264, :1337); inspector `onSelectRecord` (CatalogHelpers.swift:660-662) | toolbar verbs, focusedValues for ⌘⌫/⌘O, inspector, Hallie mirror |
| `tableData` | `CatalogTableState` @State, CatalogTableState.swift:24 | C | 16 trigger sites, `tableData = computeFiltered()` (CatalogContent+Table.swift:98-152) | files Table |
| `filesTableFocused: Bool` | `CatalogTableState` @FocusState, :38 | C | `onChange(selectedIDs)` (CatalogHelpers.swift:734-736); `onAppear` (:765); `.defaultFocus` (:767) | `.focused(...)` on files Table (CatalogContent+Table.swift:180) |
| `highlightedTargetPath` | CatalogView @State, :461 | A | `onChange(selectedIDs)` (:804-812) | volume row tint (B) |
| `filterByIDs`, `focusMatchScore`, `focusLabel` | CatalogView @State, :393-400 | A | verbs; cleared by `onChange(searchText)` (:863-864) and `onChange(selectedVolumeIDs)` (:882-883) | `computeFiltered`, banner |
| `searchText` / `debouncedSearchText` | @SceneStorage :334 / @State :343 | A | search TextField (C); archivist (:852-859) | filter (C) |
| `livePreviewMode`, `spaceKeyMonitor` | CatalogContent @State, CatalogHelpers.swift:128, :133 | C | Space monitor | filmstrip |
| `showInspector` | CatalogView @State, :321 | A | toolbar toggle (C) | CatalogContent :726 |

("Focus" in `focusMatchScore`/`focusLabel`/`focusedMediaIDs` means the
A/V-pair *filter*, not keyboard focus. The doc never uses it in that sense.)

### 1.3 Every edge between the panes

1. **Volume click → files filter.** `selectedVolumeIDs` → `filterTargetPaths` →
   `onChange` → `tableData = computeFiltered()` (CatalogContent+Table.swift:149).
2. **Volume click → clears pair filter** (ContentView.swift:882-883) and starts
   thumbnail prewarm (:886).
3. **Files re-filter → selection change.** The rows under the selection change. The
   2026-10-06 investigation (074bacb6 message) traced "↑/↓ walked the files after
   clicking a volume" to this edge feeding edge 4. Main has no explicit prune, so
   the selection write-back here comes from the Table itself. That is consistent
   with the symptom, but nobody has confirmed it in isolation (§7, Q3).
4. **Selection change → focus grab.** `onChange(of: selectedIDs)` sets
   `filesTableFocused = true` unless an NSText is first responder
   (CatalogHelpers.swift:730-736). **This is the edge that steals the keyboard from
   the volumes table.**
5. **Files selection → volume row tint.** `highlightedTargetPath` (ContentView.swift:804-812).
   Paint only. It is still a host-A state write on every arrow step, which re-runs
   `CatalogView.body`, which makes `updatePanes` replace both hosts' root views.
6. **Inspector → selection.** `onSelectRecord` (CatalogHelpers.swift:660), then edge 4.
7. **Appear → focus.** `onAppear { filesTableFocused = true }` (:759-766) plus
   `.defaultFocus` (:767). Two writers for one thing.

The search field, the inspector's text fields and the sheets have no
focus code of their own. They take part only through the NSText guard in edge 4 and
in the Space monitor (CatalogHelpers.swift:344).

---

## 2. Keyboard routing as it actually happens

The AppKit order for a keystroke in the key window (Cocoa Event Handling Guide,
"Handling Key Events"): for a key with ⌘, `NSApp.sendEvent` first sends
`performKeyEquivalent:` down the **key window's view hierarchy**, and only if no
view claims it, to the **menu bar**. Local `NSEvent` monitors run *before* all of
that. A plain key (↑, Space, Tab) goes as `keyDown:` to the **first responder**
and then up the responder chain. SwiftUI's focus system is a layer over that:
`.focused` and `@FocusState` track which hosted view is (or contains) the first
responder, and `focusedValue` publishes values from the focused view's ancestors
to `Commands`.

The repo comments in CatalogTrashCommand.swift:6-9 and CatalogOpenCommand.swift:7-9
say "AppKit offers it to the menu bar before any view sees a keyDown". That is
roughly right in practice, because `onKeyPress` is a keyDown handler, not a
key-equivalent handler. Strictly, though, views see a ⌘-key first. That matters
for ⌘I below.

| Key | Path today | Where it breaks |
|---|---|---|
| ↑/↓ | Space monitor ignores it → first responder's `keyDown:` → NSTableView moves its row → SwiftUI writes the selection binding. | Whichever table is first responder gets the arrows. The 10/5 diagnosis (ba9512e8/e6df4c31, recorded in 71229e60) found that **clicking a file row did not make the files NSTableView first responder**. The volumes table, the window's first key view, kept it. Main papers over this with edge 4, and edge 4 steals the volumes table's arrows after a volume click (edges 1→3→4). |
| ⌘⌫ | key-equivalent pass through the views (nothing claims it) → menu bar → `CatalogTrashMenuItem` (VideoScanApp.swift:786), enabled when `@FocusedValue(\.catalogTrashSelection)` is non-nil and the count is > 0 (CatalogTrashCommand.swift:48-57). The value is published by the files Table (CatalogContent+Table.swift:185-186) in host C and read by the scene's Commands. | Works only while SwiftUI considers the files table focused. Because edge 4 focuses the files table after a volume click, the item can be enabled while the user is "in" the volumes pane, which acts on hidden or stale selections. Nobody has verified that the value crosses from host C to the menu. Measure it (§6). |
| ⌘O | Same route: `CatalogOpenMenuItem` (VideoScanApp.swift:705; CatalogOpenCommand.swift:69-79), published at CatalogContent+Table.swift:190-191. | Same as ⌘⌫. |
| ⌘I | **Collision.** A hidden `Button("")` with ⌘I in host B (ScanTargetsPane.swift:918-927) and File ▸ Import Catalog… ⌘I (VideoScanApp.swift:732). Views get key equivalents first, so whichever hosting view claims it first wins. Behaviour depends on which host answers `performKeyEquivalent:`. | A latent bug. Neither route is focus-scoped. |
| Space | Local keyDown monitor (CatalogHelpers.swift:361-373) runs before everything. It consumes bare Space when the first responder is inside **any** NSTableView (:349-353). | It also fires in the volumes table, which is wrong. A monitor is invisible to SwiftUI's focus model and is the only global hook in this window. |
| Tab / ⇧Tab | First responder → `insertTab:` → window `selectNextKeyView:` over the key-view loop. Each NSHostingView runs its own SwiftUI focus loop. | Nobody has tested whether Tab leaves host B for host C (or the reverse). With two graphs, two loops have to agree. Treat it as broken until measured. |

### 2.1 Can `@FocusState` or `focusedValue` span two NSHostingControllers?

**Not by any documented contract, and the evidence says no for `@FocusState`.**

- Apple defines `FocusState` against "the placement of focus within the
  scene". `focusedValue` is for "views whose state depends on the focused view
  hierarchy". `focusedSceneValue` is the scene-wide variant. All three describe one
  SwiftUI hierarchy. None mentions nested hosting controllers.
- `NSHostingController.sceneBridgingOptions` (macOS 14+) is the one documented
  hosting-to-window bridge. Its options are `.title`, `.toolbars` and `.all`.
  Nothing covers focus.
- Experiment 0cb46905 (reverted): the owner `@FocusState focusedPane` was in host A,
  with `.focused($focusedPane, equals: .volumes)` in host B and `.focused(… .files)` plus
  `.defaultFocus($focusedPane, .files)` in host C. Rick's test found **arrows dead
  in both panes**. The obvious reading: each host's focus system sees a binding
  whose value names a view it cannot find. It either fails to match or resigns its
  table's first responder to satisfy the binding, so the key goes to a
  non-table responder. That reading is consistent with the symptom. It is **not
  proven**: no first-responder log was taken during that run. Step 0 records
  this exact case so the question is settled by measurement.
- Why the opt-in probe passed (CatalogPaneFocusProbeTests in 074bacb6): it moved
  focus with `window.makeFirstResponder(table)`, which bypasses the click path and
  SwiftUI's focus arbitration, and it never sent a key. **A focus test must click
  and type the way a person does.** That is the rule behind §6.

**What SwiftUI does when `.focused` is bound in one host and the owner is in
another:** undocumented. The binding (a reference to host A's storage) carries
values fine. The *focus machinery* that turns "this view became first
responder" into a write, and "the value changed" into `makeFirstResponder`,
runs per host. Each host acts on half the information. Design so that the
question never arises.

---

## 3. The canonical Apple design for a two-pane table window

Finder, Mail and Music behave the same way. A click in a pane makes that pane's
table first responder (shown by the accent-coloured selection; the other pane's
selection turns grey). Arrows move within that pane only. Tab and ⇧Tab cycle panes.
Selecting in the source pane changes the content pane's *rows* but never its
*focus*. Menu items (Move to Trash, Open, Get Info) act on the **focused** pane and
are disabled when that pane can't do them.

In SwiftUI terms (WWDC21 "SwiftUI on the Mac: Build the fundamentals" and "…the
finishing touches"; WWDC23 "The SwiftUI cookbook for focus"; docs for `Table`,
`Commands`, `FocusedValues`):

- Each pane is a `Table`/`List` in **one** SwiftUI hierarchy.
- One `@FocusState` enum in the common ancestor, `.focused(equals:)` per pane.
  Use `.defaultFocus` for the opening position. The cookbook: "Focused values
  enable data flow between these different elements."
- Commands read `@FocusedValue` and are disabled when it is nil.
- `.contextMenu(forSelectionType:primaryAction:)` handles double-click and Return.
  This window already does that (CatalogContent+Table.swift:162-169; VolumeTable.swift:347-351).

**Container options**

| Option | Hosting | Fit here | Notes |
|---|---|---|---|
| `VerticalSplitView` (today) | 3 graphs | ✗ | Breaks focus (§2.1) and needed `notifyTargetsChanged`. Adds a full `AnyView` replace of both panes on every CatalogView body pass (VerticalSplitView.swift:77-80). Its one real feature is auto-growing the top pane to fit the rows (:82-106). |
| **`VSplitView`** | 1 graph | ✓ recommended | NSSplitView-backed SwiftUI container, macOS 10.15+. Already used in this window (CatalogHelpers.swift:681) and in Triage, Archive, Family Tree and Volumes. Keeps today's top/bottom layout. Loses the programmatic divider position. `.frame(minHeight:idealHeight:maxHeight:)` on the top pane sets limits and the initial share. |
| `NavigationSplitView` (sidebar \| content \| `.inspector`) | 1 graph | later, maybe | The most canonical for "sources → items → details" (Finder, Mail, Music). But the volumes table has ~10 columns, status buttons and a totals footer, which is not a sidebar list. It would also move volumes from top to left. That is Rick's call, not a fix. |
| Single-hosting NSSplitView (an `NSViewRepresentable` hosting **one** `NSHostingView` per pane is still two graphs) | — | ✗ | No AppKit wrapper can put two SwiftUI subtrees into one graph. Only a SwiftUI container can. |

**Does the "jiggle" argument hold on macOS 26?** No. The comment
(VerticalSplitView.swift:1-4) and ec2b12c6 blame "SwiftUI's DragGesture +
`.frame(height:)`", a hand-made divider whose height feedback looped through
layout. That was never `VSplitView`, which is backed by NSSplitView just like
`VerticalSplitView`. The app has run `VSplitView`/`HSplitView` in this very tab
since 2026-03/04 (git: `VSplitView` from ad78f33b, 2026-03-31), before `VerticalSplitView` existed, with no jiggle reports. The only thing given up is the
auto-height feature (§7, Q1).

---

## 4. Target architecture

```
HOST A only
CatalogView                         @FocusState focusedPane: CatalogPane?   (.volumes | .files)
└─ VSplitView
   ├─ ScanTargetsPane
   │   └─ volumes Table   .focused($focusedPane, equals: .volumes)
   │                      .focusedValue(\.catalogVolumeInfo, …)        (⌘I → menu)
   └─ bottomPane
       ├─ CatalogToolbar (search)            text field: normal focus, Tab-reachable
       └─ CatalogContent
           ├─ files Table  .focused($focusedPane, equals: .files)
           │               .focusedValue(\.catalogTrashSelection, …)   (⌘⌫)
           │               .focusedValue(\.catalogOpenSelection, …)    (⌘O)
           ├─ preview player
           └─ InspectorPanel
   .defaultFocus($focusedPane, .files)      ← the ONE programmatic mention
```

**Ownership rules** (each one is checked by a sensor test):

1. **Who may move keyboard focus:** a click, Tab/⇧Tab, and `.defaultFocus` at
   appearance. Nothing else. No `focusedPane = …`, no `makeFirstResponder`, and no
   focus write in any `onChange`/`onAppear`. (Explicit user commands such as a future
   ⌘F "Find" may set focus to the search field. Each one needs Rick's approval.)
2. **Selection never moves focus. Focus never moves selection.** A volume click
   changes `tableData`, and may prune `selectedIDs` to visible rows, but leaves
   `focusedPane` alone.
3. **One focus owner, one hierarchy.** The `@FocusState` and every `.focused` bound
   to it are in the same SwiftUI graph. No `NSHostingController`/`NSHostingView`
   is allowed between them (sensor: `VerticalSplitView` unused in Catalog/).
4. **Commands act on the focused pane.** Each verb is published as a
   `focusedValue` by the pane that can perform it: ⌘⌫ and ⌘O by files only, ⌘I by
   volumes (and later files). No hidden Buttons, no `focusedSceneValue` for
   selection verbs.
5. **No global key hooks beyond Space.** Space stays an `NSEvent` local monitor for
   now (`.onKeyPress` on a Table is suspected of eating arrows, per 776d5116). It is
   gated on `focusedPane == .files` through a reference box written only by
   `onChange(of: focusedPane)`. Revisit `.onKeyPress(.space)` once the harness
   can prove it leaves arrows alone.
6. **Paint edges stay paint.** `highlightedTargetPath` may tint a volume row. It
   must never select or focus.

---

## 5. Migration plan

Every step: tests first (red where a behaviour changes, green-and-pinned where
it doesn't), each touched function CCN ≤ 15 (the gate, scripts/complexity_gate.py,
blocks > 30), Debug build for iteration, Release for the harness run, its own
merge, and Rick's hand test before the next step. Steps 1 and 2 are the only ones
that change focus behaviour.

| # | Step | Tests written first | Expected |
|---|---|---|---|
| 0 | **Harness.** Add accessibility identifiers `catalog.volumesTable` / `catalog.filesTable` (only app change). Add a `-gauntletFixtureCatalog <json>` seam (GauntletSeams.swift) that loads synthetic records under `VS_UI_TEST`. Add `CatalogKeyboardUITests` (§6). Add a DEBUG/VS_UI_TEST-only `[keys]` log of the first-responder class chain on ↑/↓/Tab. | The suite itself. | **Red on main** in the cases listed in §6. That red is the evidence everything later is judged against. |
| 1 | **One hierarchy.** Replace `VerticalSplitView` in `CatalogView.rootSplit` (ContentView.swift:572-584) with `VSplitView`. The top pane gets `.frame(minHeight: 60, idealHeight: scanTargetsPaneAutoHeight, maxHeight: 400)`. No focus code changes yet. | Source sensor: no `VerticalSplitView(` in Catalog paths. Harness: record the arrow results again (they may change; record the new baseline). Existing Catalog* suites green. Scale: arrow-step timing on 100k synthetic rows ≤ budget (one fewer root replace per step). | Same look. Divider set by `idealHeight`. Arrows may already improve. |
| 2 | **One focus owner.** `enum CatalogPane`; `@FocusState focusedPane` in CatalogView; `.focused(equals:)` on both tables; `.defaultFocus(.files)`. **Delete** edge 4 (CatalogHelpers.swift:734-736), the `onAppear` write (:765) and `filesTableFocused` (CatalogTableState.swift:38). | Sensors from 074bacb6 (one FocusState, two `equals:` bindings, no focus assignment, one defaultFocus). Harness cases 1-2 go **green**. | ↑/↓ follow the clicked pane. |
| 3 | **Space gated on pane.** Mirror box + guard (the 074bacb6 shape). | Harness case 4 red → green. Unit: guard rejects `.volumes`, `nil`, NSText. | Space only in files. |
| 4 | **Prune hidden selection** on re-filter (`refreshRows` + `CatalogSelectionPrune`, from 074bacb6). | Logic and 100k-scale tests (exist in the reverted branch). Harness: after a volume click, ⌘⌫ is disabled or acts only on visible rows. | No ⌘⌫ on hidden rows. |
| 5 | **⌘I resolved.** Rick picks the owner (Q2). Replace the hidden Button (ScanTargetsPane.swift:918-927) with a `focusedValue` + menu item. | Sensor: no hidden ⌘I Button. Harness: ⌘I with volumes focused opens Catalog Info; with files focused it does what Rick chose. | One owner per key. |
| 6 | **Tab/⇧Tab.** Measure first. Add `.focusSection()` on each pane only if the harness shows Tab skipping or trapping. | Harness case 5. | Tab cycles volumes → search → files → inspector. |
| 7 | **"All volumes" pill** (UI wording from 074bacb6, separate from focus). | CatalogShowingSummaryTests from that branch. | — |
| 8 | **Cleanup.** If nothing else uses `VerticalSplitView` (today only ContentView.swift:573 does), move it to `.trash/`. Audit the 32 `notifyTargetsChanged()` calls for ones that only existed to push through the hosting chain. Mark them, don't remove them in this step. | Grep sensor. | Less code. |

The reverted branch (074bacb6) is not wasted. Steps 2, 3, 4 and 7 reuse its
code and tests nearly verbatim. Only its hosting assumption was wrong.

---

## 6. The keyboard test harness

**Shape.** `VideoScanUITests/CatalogKeyboardUITests.swift`, subclassing
`GauntletTestCase` (VideoScanUITests/Gauntlet/GauntletBase.swift). That gives
isolation: `VS_UI_TEST=1`, a throwaway HOME/CFFIXED_USER_HOME (:83-104), and a
screenshot on failure. Gate it with `VS_GAUNTLET=1` like the others, so it never
runs from a plain `xcodebuild test`.

**Fixture.** A synthetic catalog JSON generated by the runner: 3 volumes
(`test_volA`, `test_volB`, `test_volC`, paths under the sandbox) and 20 records
each (`test_clip_000.mov` …). It is loaded through a new `-gauntletFixtureCatalog`
seam, so there is no ffprobe and no scan, and it starts in seconds. **No real family data and
no real catalog**: `VS_UI_TEST` already blocks the real catalog path. The seam
refuses paths outside the sandbox.

**Interaction is real.** `element.click()` on a cell and `typeKey(.downArrow,
modifierFlags: [])`. No `makeFirstResponder`. That is the lesson from §2.1.
Assertions read the selected row of each table through XCUI (`isSelected`) and
the menu item's `isEnabled`. The `[keys]` log is attached on failure.

| # | Case | Assertion | On main today |
|---|---|---|---|
| 1 | click volume row 0, press ↓ | volumes selection = row 1; files table selection unchanged by the key | **fails**: edge 4 moves focus to files after the re-filter (CatalogHelpers.swift:734) |
| 2 | click file row 3, press ↓ ↓ | files selection = row 5; volume selection unchanged | passes (only because of edge 4). It is the guard that step 2 keeps it |
| 3 | click file → Catalog ▸ Move to Trash enabled; click volume → disabled; click search field → disabled | `isEnabled` per state | **fails** after the volume click: the files table still publishes its selection |
| 4 | click volume, press Space → live-preview indicator unchanged; click file, Space → toggles | preview mode flag (accessibility value on the indicator) | **fails**: monitor accepts any NSTableView (:349-353) |
| 5 | click volume, Tab ×N → files table reached; ⇧Tab returns | focus via selection highlight / `[keys]` log | unknown. Record it; this case decides step 6 |
| 6 | control: the 0cb46905 shape on a test-only branch | arrows dead in both | reproduces Rick's 10/6 report, which proves the harness can see it |

**Where it runs.** On the M5 with an unlocked console (UI tests need the
desktop; memory note on the gauntlet), or at night on the M4 inside the
declared window (midnight-10:00). Never on the M4 during Rick's hours, because it
activates the app and takes the keyboard. Release build, per build-mode policy.
Run it via the existing `scripts/run_gauntlet.sh` plan, plus a one-line plan entry.

---

## 7. Risks and open questions for Rick

**Q1. Divider auto-height.** Today the top pane grows to fit its rows until you drag
it (VerticalSplitView.swift:95-105). With `VSplitView` you get an initial
`idealHeight` and your drags, but no regrowth when rows are added later. Acceptable? If not,
we look for a SwiftUI-only way after the focus work lands. Not before.

**Q2. ⌘I has two owners** (hidden Catalog Info button vs File ▸ Import Catalog…).
Which keeps ⌘I? Finder uses ⌘I for Get Info, so the recommendation is: Catalog Info
on ⌘I (focus-scoped), Import Catalog… on ⇧⌘I or no shortcut.

**Q3. The 10/5 root question is still open:** why didn't a click on a file row make
the files NSTableView first responder? Candidates: the host boundary (most likely,
and it goes away in step 1), something in the cell views, or SwiftUI Table click
handling. Step 0's `[keys]` log answers it before step 2 starts.

**Q4. Layout direction.** Is volumes-on-top permanent, or would you like the
Finder/Mail shape (volumes as a left sidebar, `NavigationSplitView` + `.inspector`)
someday? That is a separate design pass, and the volumes table would have to slim down.

**Q5. Search field.** It is an inline TextField in the bottom pane
(CatalogToolbar.swift:538). The canonical form is `.searchable` in the window
toolbar with ⌘F. Out of scope here. Raise it only if you want it.

**Risks.**
- *Swapping the split container re-parents the tables.* State that lives in
  CatalogContent's `@State` (`tableData`, player, sheets) is rebuilt once. The
  `.onAppear` recompute (CatalogContent+Table.swift:146) covers `tableData`. Watch
  the sheet presenters in CatalogHelpers.swift:769-890. They move from host C into host
  A, which is the normal case for SwiftUI.
- *Perf.* Today every arrow step writes `highlightedTargetPath` in host A, and
  `updatePanes` then replaces both hosts' root views. In one graph SwiftUI diffs
  instead, so this should get faster, not slower. Step 1 carries a 100k timing sensor
  to prove it.
- *Gauntlet flakiness on the M4* (testmanagerd). Run on the M5 first. A red result there is
  a code signal. A red result on the M4 by day is not.
- *Unverified claims in this doc* are labelled as such: the dead-arrows
  mechanism in §2.1, the ⌘⌫ value crossing hosts, Tab across hosts, and Q3. Step 0
  exists to replace them with measurements.

**Sources.** Apple docs: FocusState ("…as the placement of focus within the
scene changes"), focusedValue(_:_:), focusedSceneValue(_:_:),
NSHostingSceneBridgingOptions, Table, Commands, FocusedValues. WWDC23 "The
SwiftUI cookbook for focus" ("Focused values enable data flow between these
different elements"). WWDC21 "SwiftUI on the Mac: Build the fundamentals" and "SwiftUI
on the Mac: The finishing touches". Cocoa Event Handling Guide, "Handling Key
Events" (key window, then menu bar, for key equivalents).

---

## Independent review (Fable, 2026-10-06): PROCEED-WITH-CHANGES

The architecture conclusion holds: two hosting roots is the boundary, and VSplitView (one graph) is the right target. Corrections the plan adopts:

1. **Mechanism.** Drop the "volume click → re-filter → selection change → edge 4 grabs focus" narrative as the proven cause. Edge 4 (`CatalogHelpers.swift:734`) only fires on a non-empty selection, and SwiftUI `Table` is not known to prune a selection when rows vanish. The simpler explanation fits both days, mirrored: **a click in one host's table does not take first responder from the other host's table** (10/5: volumes kept it after a file click; 10/6: files kept it after a volume click). Other suspects checked and cleared: no `.focusable`/`focusSection`/`onKeyPress`/window key handler; the Space monitor (`:363`) passes arrows through; `CatalogTableState` holding `@FocusState` is equivalent to a direct declaration; `notifyTargetsChanged()` cannot move focus.
2. **Harness case 1 must reproduce the real sequence:** click file row 3 → click volume row 0 → ↓. A fresh launch with no file selected would stay green on main and the ladder would lose its baseline. Step 0 logs the first responder on **mouseDown** as well as on arrows. Keep case 6 (the control branch). Look tables up by index if `.accessibilityIdentifier` doesn't reach the AX table.
3. **VSplitView step:** don't add `.frame(maxHeight: 400)`. Today's `topMaxHeight` is declared but never applied (`VerticalSplitView.swift:45, 54-75`), so capping it would be a behaviour change. Divider position isn't persisted today either (CatalogView is rebuilt per tab switch).
4. **Step 8:** `notifyTargetsChanged()` also calls `noteVolumeStatusesStale()`; don't remove call sites on the "hosting hack" rationale alone.
5. **Data risk:** **Archive ▸ Promote Selected** reads the `catalogSelectedIDs` mirror (`VideoScanApp.swift:753`, written `ContentView.swift:801`) and can act on rows a volume filter hides. Fix it in step 4 (scope it to visible, focused selection) with a pinning test, under /safety-critical.
6. **Step 4 is a behaviour change, not a pure refactor:** every row refresh (search keystroke, scan count change, purge) clears a hidden selection and stops the preview. Needs Rick's explicit OK.
