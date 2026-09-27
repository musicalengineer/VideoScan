# Codex review — Catalog ⌘O (de54a7ca, merged 48708aba) — 2026-09-26

Invocation: `codex exec --sandbox read-only` (direct, first run). Tokens used: 49,632. Commands run: 5, all in scope.

Credits spent: unavailable | Finding count: 1
Verdict: merge-after-fixes

**F1 — P3: Console reports a player before actual routing is known**

`VideoScan/VideoScan/CatalogOpenCommand.swift:125`

The summary counts codec-based preferences for every selected record, but `MediaOpener.open` subsequently resolves viewer streams and excludes unreachable files. The console therefore does not reliably name the player used.

**Concrete counterexample:** In viewer mode, select an H.264/AAC MP4 available only through the master’s stream, with VLC installed. The new line reports “1 in QuickTime Player”; `MediaOpener.openResolvingForViewer` routes that stream through `openStream` to VLC. An unreachable local MP4 likewise reports “1 in QuickTime Player” although no player launches.

**Closed by 7d2a9674** — test `CatalogOpenShortcutTests` (8/8): the console line now reads "by codec: N for QuickTime Player, M for VLC (offline files are skipped by the opener)" — intent, not a receipt; the opener's own log names what launched.

**Accepted pinning test:** Inject stream and offline resolutions for otherwise QuickTime-compatible records. Assert the console reports VLC and skipped status respectively—or explicitly labels its counts as codec-based preferences rather than actual routing. Keep one `MediaOpener.open` handoff.

Other scoped checks:

- `CatalogContent+Table.swift` — read, no findings. Both gestures call `openRows`, which supplies `tableData` to the same action. IDs absent from that supplied table cannot reach the launcher. Each surviving row receives one missing-file check before the single handoff.
- `VideoScanApp.swift` — read, no findings. No competing plain ⌘O declaration in the allowed files; ⇧⌘O remains distinct. No command-group replacement shown that removes this item.
- `CatalogOpenShortcutTests.swift` — read, no findings in the existing assertions. They test the supplied-array stale-selection case, not live focus changes or retained focused closures.

Focused-value publication and menu construction add constant-time count/title work; filtering occurs on Open. Both action overloads are `@MainActor`, with synchronous callbacks and no introduced task or Sendable boundary. No concrete concurrency defect survived inspection.

Limits: repository-wide shortcut uniqueness cannot be established within the file restriction. Live focus behavior and Swift 6 compiler diagnostics were not verified. Tests were not rerun; the supplied 90-test result remains the execution evidence. No app or build was intentionally launched; the Apple git shim emitted Xcode initialization diagnostics during the requested diff read.

## Brief

Adversarial code review, SCOPED. Repo /Users/rickb/dev/VideoScan, review commit de54a7ca (merged to main as 48708aba). Use `git show de54a7ca` for the diff. Do NOT explore outside the files below; do not run the app or any xcodebuild; read-only.

Feature: File ▸ Open (⌘O) in the Catalog — Finder-style open of the selected rows through the same smart QuickTime-vs-VLC chooser as double-click.

FILES IN SCOPE:
- VideoScan/VideoScan/CatalogOpenCommand.swift (new: CatalogOpenSelection focused value, CatalogOpenMenuItem, CatalogOpenAction.open with a test seam)
- VideoScan/VideoScan/CatalogContent+Table.swift (primaryAction now calls openRows; .focusedValue(\.catalogOpenSelection …); openSelectedRows/openRows)
- VideoScan/VideoScan/VideoScanApp.swift (CatalogOpenMenuItem() in CommandGroup(after: .newItem))
- VideoScan/VideoScanTests/CatalogOpenShortcutTests.swift
Reference only (read, don't review): VideoScan/VideoScan/CatalogTrashCommand.swift (the sibling focused-value pattern), MediaOpener in CatalogHelpers.swift.

INVARIANTS TO ATTACK:
1. One path: double-click and ⌘O must reach MediaOpener.open through the same function with identical side effects (noteMissingFileForUserAction per row, then one launch). Find any divergence.
2. Focus/enable: the menu item must be disabled when the Catalog table is not focused or the selection is empty; it must never fire on a stale selection (rows filtered away or purged after selection). Look at how `count` and `perform` are captured — can `perform` run against ids no longer in `tableData`?
3. Shortcut collision: plain ⌘O must not be declared anywhere else (⇧⌘O Analyze Dashboard stays). Any SwiftUI Commands ordering issue that would shadow it?
4. Performance: nothing O(records) on every selection change or menu build (the #104 class). `tableData` filter cost on Open is acceptable; anything on `.focusedValue` evaluation is not.
5. Concurrency: the focused value closure captures — main-actor only? Any Sendable warning under Swift 6 strict concurrency?

EVIDENCE ALREADY RUN (Debug, M4 Max): 90 tests / 11 suites / 0 failures incl. CatalogOpenShortcutTests (8: exact selection in table order, one looks-moved check per row, one launch, console line, empty/stale selection no-op, title/disabled rule, source sensors for the one-path invariant).

OUTPUT: a Markdown report to stdout with this exact header line first: `Credits spent: <n or unavailable> | Finding count: <n>`; then `Verdict: merge / merge-after-fixes / hold`; then each finding as `F<n> — P<1|2|3>: <title>`, file:line, a concrete counterexample, and the pinning test you would accept. If nothing survives, say so with what you checked. Under 600 words.
