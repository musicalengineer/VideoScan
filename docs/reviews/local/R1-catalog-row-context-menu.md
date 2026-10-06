# R1 report: Catalog row context menu + table state (GH #281)

**Night of 2026-10-05, M4, local.** Branch `refactor/r1-catalog-table`, based on `fa56f078`.
Owner: `refactor` agent. **Not merged and not pushed.** Next: qa review, then Rick's morning spot test.
Brief: `docs/briefs/local/R1-catalog-row-context-menu.md`. Extra input: §4 of
`docs/reviews/qa/refactoring_assessment_2026_09_13.md`. I used its "explicit action plans"
direction (menu decisions as plain data), and I added its preservation suites to every run.

## Commits (each one built and green before the next)

| # | SHA | What | Kind |
|---|-----|------|------|
| 1 | `835065cf` | Move the row menus and their menu-only handlers out of `CatalogContent+Table.swift` into `CatalogRowContextMenu.swift`, `+Audio.swift` and `+Actions.swift` | pure move |
| 2 | `31ca5581` | `CatalogRowMenuSelection`: the selection split and the choice of menu as plain data, with tests | simplify |
| 3 | `e0daa204` | Split `rowContextMenu` into per-section builders (`+FileOps.swift`, `+Organize.swift`); remove the `swiftlint:disable` | mechanical cut |
| 4 | `497e4e9c` | `CatalogRowMenuText` / `CatalogRowMenuRules`: labels, alert wording and enable rules as pure functions, with tests | simplify |
| 5 | `96291653` | `CatalogTableState`: rows snapshot, badge revision and `@FocusState` gathered in one DynamicProperty | state move |
| 6 | (this report) | docs | |

Review tip: `git show -w --color-moved=dimmed-zebra <sha>`. Commits 1 and 3 are almost entirely moved lines.

## Before / after numbers

### lizard (CCN / NLOC)

| Function | Before (`fa56f078`) | After |
|---|---|---|
| `rowContextMenu` | **CCN 81, 489 NLOC**, 746 lines, `swiftlint:disable:next` | **CCN 6, 21 NLOC** (dispatch only) |
| largest new menu builder | — | `peopleItems` CCN 8 / 50 NLOC; `removeAndDeleteItems` CCN 4 / 51 NLOC |
| `audioLifecycleMenuItems` (moved, body untouched apart from C4 labels) | CCN 11 / 74 | CCN 9 / 68 |
| highest CCN in any touched file | 81 | 14 (`filenameTooltip`, untouched) |
| highest NLOC in any touched function | 489 | 68 |

All 21 new or moved menu builders are at CCN ≤ 12 and ≤ 68 NLOC, which meets the brief's target of ≤ 15 / ≤ 80.
The `swiftlint:disable:next cyclomatic_complexity function_body_length` is gone. SwiftLint
reports nothing on any new file.

### Files (wc -l)

| File | Before | After |
|---|---|---|
| `CatalogContent+Table.swift` | 1,949 | **668** (file_length warning gone) |
| `CatalogHelpers.swift` | 1,862 | 1,851 (still over: see "What's left") |
| `CatalogRowContextMenu.swift` | — | 375 |
| `CatalogRowContextMenu+FileOps.swift` | — | 302 |
| `CatalogRowContextMenu+Organize.swift` | — | 366 |
| `CatalogRowContextMenu+Audio.swift` | — | 176 |
| `CatalogRowContextMenu+Actions.swift` | — | 240 |
| `CatalogRowMenuPlan.swift` | — | 145 |
| `CatalogTableState.swift` | — | 64 |

### Type-check time (Release, `-debug-time-function-bodies`, M4)

| Function | Before | After |
|---|---|---|
| `rowContextMenu` | **151.3 ms** | 5.9 ms |
| slowest single menu builder | 151.3 ms | 9.7 ms (`audioLifecycleMenuItems`) |
| `tableWithCatalogTriggers` / `…FilterTriggers` / `…SearchTriggers` stages | 0.3 / 1.0 / 2.8 ms | 0.3 / 1.1 / 2.9 ms |

**Goal 4 (break up the `tableWithCatalogTriggers` modifier chain): not done, because there is
nothing left to fix.** The 21.7 s figure dates from before the stage-0 R2 split (2026-09-29).
Each stage now type-checks in under 3 ms, and further splitting would only add churn.

## Tests

The brief's set is all `Catalog*` test files, the seven named sensors, the whole-tree sensors
that could see moved code (NotesAuthorship, ArchiveAngelBoundary, AtomicFilePublish,
BackupAttestation, FixityStampVolumeIdentity, ArchiveIndexLineSplit, SourceTree), CleanupScale,
JunkDeletion and MediaOpener, plus the codex §4 preservation suites (DeleteVolumeCatalogPlan,
CatalogPurge and CatalogStorageTotals, which the Catalog* glob already covers, and
ScanTargetRecordFacts). Every run used Release, `ENABLE_TESTABILITY=YES`, `-only-testing`
by suite and its own `.derivedData`.

| Run | Swift Testing | XCTest | Result |
|---|---|---|---|
| Baseline `fa56f078` | 867 tests / 130 suites | 48 | green (2 known issues) |
| after C1 (move) | 867 / 130 | 48 | green |
| after C2 | 875 / 131 | 48 | green |
| after C3 (split) | 875 / 131 | 48 | green |
| after C4 | 887 / 133 | 48 | green |
| after C5 | **890 / 135** | 48 | green |
| **Full `VideoScanTests` target at branch head** | **10,318 tests / 1,530 suites** | 140 (4 skipped) | **green**, 11 known issues, 1,232 s |

23 new tests:
- `CatalogRowMenuSelectionTests` (8): disjoint subsets, removed > set-aside > superseded
  precedence, the pureActive gate, the minimal menus, mixed selections, anchor precedence,
  the nil case, and a 100k select-all scale budget.
- `CatalogRowMenuTextTests` (5): golden strings at 0, 1 and N, and a check that "Remove" is
  never worded as "Delete".
- `CatalogRowMenuRulesTests` (7): truth tables over every StreamType, plus a 100k scale budget.
- `CatalogTableStateTests` (3): a single-home sensor, a .focused / .defaultFocus sensor, and a
  live focus probe.

**Red-green:** each new test was shown to go red under a targeted mutation, then the mutation
was reverted:
- swapped the if-chain order → `anchorPrecedenceFollowsTheOldIfChain` red
- "Files" → "files" → `pluralLabelsCountExactly` red
- dropped `running` from cleanupBlocked → `cleanupNeedsAPicture…` red
- removed `.defaultFocus` → `theTableStillBindsAndDefaultsToTheFlag` red
- removed the nested `.focused` in the probe → `nestedFocusStateBehavesLikeDirect` red, while
  the direct-FocusState control still passed

Note from my own process: my first baseline was contaminated. I moved files while the test
binary was running, and the source sensors read files at run time. I re-ran the baseline
cleanly at `fa56f078` (numbers above). Lesson: never edit the tree during a run.

## Sensor changes (none weakened; each repointed sensor was shown red after the move)

| Sensor | Change |
|---|---|
| `MediaFileOperationsWindowForwarderTests.userStartSites` | `CatalogContent+Table.swift`: 9 → **0**, still pinned at zero. New entries: `CatalogRowContextMenu.swift` 0, `+FileOps` 1 (compare), `+Organize` 1 (Find and Tag), `+Audio` 3 (verify audio ×2, verify video), `+Actions` 4 (analyze ×2, reformat ×2). The total stays 9. |
| `ReadOnlyVolumeTests.everyBulkRemoveVerbAsksTheGate` | `recordsBulkVerbsMayRemove(activeRecs)` is now read from `CatalogRowContextMenu.swift` |
| `CatalogTrashShortcutTests.shortcutSharesTheTrashRoutine` | The row menu's `deleteConfirmedJunk(targets, mode: .toTrash)` is read from the menu file. **Added:** no `.onKeyPress(` in the menu file either. The table-file checks are unchanged. |
| `VerifyVideoMenuSensorTests` (in VerifyVideoJobTests) | The three verify sensors read `+Audio.swift`. `trimMasterMenuItemStaysRetired` reads the table file plus **every** `CatalogRowContextMenu*.swift`, found by a glob through SourceTree. *Correction after the QA review:* this line first claimed full coverage, but the hand-kept list missed `+FileOps` and `+Organize`. The fix and the guard test `trimMasterSensorCoversEveryRowMenuFile` (glob floor ≥ 5; +FileOps, +Organize and the table file covered; the retirement note is read) landed in the follow-up commit. The guard was red against the old list and red with the glob mutated to drop +Organize; it is green now. All 7 VerifyVideo* suites (19 tests) are green in Release. |
| `CleanupScaleTests` | **Stronger:** it times the production `CatalogRowMenuRules.cleanupBlocked` instead of a hand-kept copy of the expression. |

Red check after the move (C1): mutating each pinned guard in its new file turned all four
repointed sensors red: ForwardSensor, ReadOnlyVolumeSensor, CatalogTrashShortcut and
VerifyVideoMenuSensor.

## Menu parity

**Method:** I expanded the new section builders in call order and diffed them against the old
full-menu body (`fa56f078` `CatalogContent+Table.swift` lines 557–1256), comparing stripped,
non-blank lines. After C3 the only differences were:
1. `let transcodeRunning = fileOpsCenter.jobs.contains {…}` moved up into
   `fileOperationItems`, because Transcode and the Archive Angel items both read it. It is a
   pure read, still done once per menu open.
2. `if pureActive {` became `if selection.pureActive {`
3. continuation lines of the new multi-line call sites.

C4 then replaced each count ternary with a `CatalogRowMenuText` call. The golden tests pin
those calls to the old literals.

Full-menu order (active or mixed selection), unchanged:

| Section | Items (in order) | Builder |
|---|---|---|
| Open | Reveal in Finder / Reveal in Finder (offline) · Open in QuickTime Player · Open in VLC | `openItems` |
| — | Divider | |
| File ops | Combine This Pair…¹ · Compare These Two Files…¹ ² | `pairItems` |
| | Extract Facial Frames… · Extract Frames… · Find Matching Audio…³ · Find Missing Audio…³ · Find Matching Video…⁴ | `extractAndMatchItems` |
| | Analyze / Analyze N Files | `analyzeItem` |
| | Transcode ▸ (For Editing… · For Archival… ▸ Access Copy / Preservation Master) · Clean Up Video ▸ (recipes…) | `transcodeAndCleanupMenus` |
| | Promote to Archive · Archive Angel items · Remove from Catalog (keep files) · Verify Audio · Verify Video · Audio Info… · Repair Damaged Audio · Link Repaired Copy… · Sounds Good — Confirm Repair | `archiveAndVerifyItems` → existing builders |
| | Transcribe Audio · Generate Scene Captions | `transcriptionItems` |
| Organize (pure-active only) | Divider · Rename… · Divider · Tag ▸ | `renameAndDispositionItems` |
| | Tags ▸ | `workflowTagsMenu` |
| | Show in People Tab ▸ · People ▸ | `peopleItems` |
| | Mark as Family Music… · Unmark | `familyMusicItems` |
| | Find and Tag ▸ · Notes… | `findAndTagAndNotesItems` |
| | Find Online Copy (N) ▸ · All Matches (N) ▸ | `duplicateMatchItems` |
| | Find A/V Pair · Find Online Version | `findCopyItems` |
| | Divider · Show in Archive · Find Similar Footage… · Show this file's journey · Copy Path | `navigationItems` |
| — | Divider | |
| Remove / delete | Remove (N) from Catalog · Delete File / Delete N Files ▸ (Move to Trash · Delete Permanently…) | `removeAndDeleteItems` |
| Mixed restore | Restore (N) to Catalog · Put (N) Back in Catalog · Restore (N) Original(s) (Un-supersede) | `restoreItems` |

¹ pure-active only · ² exactly two rows · ³ video-only rows (Missing Audio: unpaired only) · ⁴ audio-only rows.
The removed, set-aside and superseded minimal menus are unchanged in body; they now use the
same shared label functions.

**Data-risk path (delete / trash):** moved with identical semantics. The scope is still exactly
`deletableRecs = model.recordsBulkVerbsMayRemove(activeRecs)`, taken once at right-click
time. It is never derived from any cached display, per codex §4. Both `deleteConfirmedJunk`
calls, the confirm alert flow and `reportDeleteResult` are untouched. Only the alert's two
strings moved into `CatalogRowMenuText`. `targets[0].filename` became
`targets.first?.filename ?? ""`; it is read only when count == 1, so the value is the same.
Nothing in this path had to stay where it was.

## API / visibility changes (the riskier part of a refactor)

- `private` → internal because of cross-file calls (single-module app; the 2026-06-11 split
  did the same): `rowContextMenu`, `audioLifecycleMenuItems`, `requestAnalyze(forAll:)`,
  `requestAnalyze(for:)`, `configureTranscode`, `repairAudio`, `repairVideo`,
  `reportDeleteResult`, `onlineCopyMenu`.
- New internal types: `CatalogRowMenuSelection`, `CatalogRowMenuText`, `CatalogRowMenuRules`
  and `CatalogTableState`.
- `CatalogContent`'s memberwise init gains a defaulted `tableState:` parameter. No caller
  passes it.
- `tableData`, `angelBadgeRevision` and `filesTableFocused` are now forwarding computed
  properties, with the same names at every site. The two projected-binding sites read
  `tableState.$filesTableFocused`.

## Focus (goal 3): behavior not changed, but flagged for the spot test

`@FocusState filesTableFocused` now lives inside a `DynamicProperty`. SwiftUI treats a
DynamicProperty like a member struct, and the commit's probe test shows that a nested
FocusState moves AppKit first responder to the target field just as a direct one does. The
probe has a control, and it goes red when the binding is removed. It is disabled on GitHub
runners. Even so, this is the one commit to revert on its own (`96291653`) if ↑/↓ or the
default focus is off in the morning.

## Morning spot test for Rick (Release build)

1. Open Catalog. Without clicking, press ↓ and ↑: the **files** table moves (default focus).
   Click a file, then ↑/↓ walk the files.
2. Right-click one online video file. Check each section:
   - Reveal, QuickTime and VLC open it.
   - Verify Audio / Verify Video start jobs in the MFO window.
   - Rename… opens the sheet.
   - Tag ▸ Important sets the star.
   - Tags ▸ Custom Tag… opens.
   - Notes… opens.
   - Show this file's journey opens.
   - Promote to Archive is present (greyed if it is already archived).
3. On a scratch test file: Delete File ▸ Move to Trash. The file is in the Finder Trash and
   the row is gone.
4. Select 3 files and right-click. You should see "Analyze 3 Files", "Remove 3 from Catalog"
   and "Delete 3 Files"; Rename… / Tag ▸ are present because the selection is pure-active.
5. Turn on Show Removed. Select one removed row plus two normal rows and right-click: the
   full menu, without Rename / Tag, plus "Restore to Catalog" at the bottom. Right-click
   only the removed row: Restore + Reveal only.

## Leads I found but did NOT act on (behavior-preserving rule; for the Manager to route to bug-fix / performance)

1. **O(selection × records) on right-click (perf, latent).**
   `rowContextMenu` builds `selectedRecs` with
   `ids.compactMap { id in records.first { $0.id == id } }`. With a select-all of 100k rows
   that is about 10¹⁰ comparisons. `model.record(forID:)` (O(1)) exists. This is pre-existing
   and unchanged; it needs a perf fix plus a SCALE sensor.
2. **O(records) duplicate-group scan per right-click.** `duplicateMatchItems` runs
   `records.filter { $0.duplicateGroupID == rec.duplicateGroupID }`, once per right-click on
   a pure-active row. This is pre-existing.
3. **The anchor row is `ids.first` of a `Set<UUID>`**, so on a multi-select the single-row
   items (Rename…, Notes…, Combine, Extract…, Transcode) act on an arbitrary row of the
   selection, not necessarily the one under the pointer. This is pre-existing; it is
   behavior, so it is not mine to change.
4. Three "`_` on a Void result" compiler warnings moved with the code
   (`_ = fileOpsCenter.startedByUser {…}`). I left them as they were because the forwarder
   sensor counts that exact text.

## What's left (propose-later)

- **CatalogHelpers.swift is still 1,851 lines and ~1,016 type-body lines.** The remaining
  ~28 sheet / target @States for the row menu (rename, notes, custom tag, journey, footage,
  family music, rip-frames, transcode, cleanup, verify-audio, missing-audio) could be gathered
  into a `CatalogRowMenuPresentation` DynamicProperty, the same way as `CatalogTableState`.
  That is many `$binding` call sites, so it belongs in its own reviewed step.
- `computeFiltered` (CCN 26 in lizard, 20 in SwiftLint; 87 lines) is untouched. It is the
  next hotspot in CatalogHelpers.
- The volume-pane focus owner (`enum Pane`) now has one place to go (`CatalogTableState`).
  Note that the volume table lives in CatalogView, so a cross-pane owner may need to move
  this state up one level.
- Goal 4: none needed (see the measurements above).
