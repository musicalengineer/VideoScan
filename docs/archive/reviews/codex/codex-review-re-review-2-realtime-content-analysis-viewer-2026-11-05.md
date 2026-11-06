# Codex review — Re-review 2: Realtime Content Analysis viewer

- Range: `b1709f7a3..origin/feat/realtime-ca-viewer`
- Credits spent: unavailable
- Tokens: 143883
- Finding count: 5
- Verdict: block
- Run: 2026-11-06T03:25:50Z (cycle #250, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — two prior invariants remain partially open, with three additional truth/isolation failures.

Reviewed `b1709f7a3..ceedb17e2`. Priorities follow the repository’s P0 rule for unsupported displayed facts. **Swift behavior tests executed: 0**; execution failed with `permissionDenied`. Regressions below are test specifications, not claimed RED runs.

1. **P0 — A truncated-and-regrown journal retains obsolete counts.** [HelperJournalTally.swift:178](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/HelperJournalTally.swift:178). **Checklist: TRUE, TESTED.**  
   After counting one era, truncate the same file and rewrite it to its previous length before the next refresh. The inode is unchanged and `size < bytesRead` is false. Reading from the old offset reaches EOF; the old era remains available indefinitely.  
   **Regression:** extend `aTruncatedOrReplacedDayFileIsRebuilt`: overwrite through the same file handle with an equally long malformed line. Require refusal or rebuilt counts (`eraFound == 0`, `unreadable == 1`). The current test refreshes while the file is still empty, missing this case.

2. **P0 — Helper counts display zero before any evidence is read.** [RealtimeAnalysisState.swift:192](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisState.swift:192), [HelperJournalTally.swift:71](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/HelperJournalTally.swift:71). **Checklist: TRUE, TESTED.**  
   The initial tally has zero counts and `available == true`. Opening the window therefore displays three zeros before the journal answers. Its initial status also says “off in Settings” without checking Settings. Because the refresh awaits XPC before reading the journal, this can persist through the 30-second XPC deadline.  
   **Regression:** suspend the first helper response with injected sources; inspect the published state before releasing it. Require unknown/loading counts and availability. Existing tests inspect after `waitForHelper: true`.

3. **P0 — An empty extraction still shows frames awaiting extraction while waiting.** [RealtimeAnalysisState.swift:62](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisState.swift:62). **Checklist: TRUE, TESTED.**  
   Hold file A’s Whisper, then finish video-only file B’s extraction with zero scenes. B correctly says “waiting,” but `hasCaptions == false` makes `showsFramesToRip` remain true. The finished extractor still displays “N frames to rip.” Extraction completion cannot be inferred from nonempty output.  
   **Regression:** parameterize `aLaneWaitingOnThePreviousTranscriptSaysSo` with an empty extraction; require `showsFramesToRip == false`. Its current fixture requires captions.

4. **P0 — A refused GPU entry is silently omitted from the displayed utilization.** [MachineCounters.swift:224](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/MachineCounters.swift:224). **Checklist: TRUE, TESTED.**  
   With two accelerator entries, one reporting 20% and the other refusing `PerformanceStatistics`, the reader returns 20% without a problem. It cannot establish the intended maximum across accelerators. The disk reader now rejects this equivalent partial-read case; the GPU reader does not.  
   **Regression:** exercise the enumeration with one successful and one refused entry; require `.absent(reason)`. Existing injected-counter tests begin after this information has already been discarded.

5. **P1 — The journal byte cap does not bound the actual reader.** [HelperJournalTally.swift:185](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/HelperJournalTally.swift:185). **Checklist: PERFORMANCE, TESTED.**  
   A poisoned day-file symlink to `/dev/zero` passes the size check. `ObservationJournal.read` follows it and reads until newline or EOF, neither of which arrives. The helper refresh never returns unavailable, and cancellation does not interrupt that synchronous loop. I verified that this host’s `/dev/zero` permits seeking and reading; I did not start the unbounded scan.  
   **Regression:** require prompt refusal of a nonregular journal target, with a subprocess timeout protecting the test. Enforce the byte budget on reads themselves. Existing oversized-tail tests use finite regular files.

The earlier fixes have these source-review results:

| Earlier findings | Closure evidence |
|---|---|
| Premature banking; captions counting every completion | Corrected wording, `banked` propagation and caption counters; corresponding wording/refused-bank/count tests present. |
| No speech confused with failure | Serial and pipelined regressions plus thrown-error control present. |
| Empty-pass stale totals | Reset paths corrected; `anEmptyPassShowsZeroTotals` present. |
| Read-error stale tally | Exception path corrected and tested; broader invalidation remains finding 1. |
| Trying includes verdicts; stale cache; swallowed errors; second unbounded reader | Tile and reader removed; removal sensor present; **Core matches base**. |
| Disk device changes/refusals | Per-device deltas and refusal tests present. |
| Missing Whisper timing | Serial timing and incomplete-timing exclusion tests present. |
| Huge journal/attempt reads | Attempts reader removed; finite-tail protections tested; finding 5 remains. |
| Finished header | Uses `done`; rendered-headline regression present. |
| Waiting lane | Nonempty extraction corrected and tested; empty extraction remains finding 3. |

Read-only behavior and Pause/Resume/Stop through `AnalyzeRunner`: **read, no findings**. The additive banking/activity changes, `CaptionPipelineTypes.swift`, `AnalyzePanelView.swift`, `AnalyzeJob.swift`, and MFO context-menu addition: **read, no additional findings**.

Inspection stayed within the scoped changes, tests and direct dependencies. No files changed. Historical RED/GREEN claims could not be independently verified in this read-only session.

Credits spent: unavailable | Finding count: 5  
Verdict: block

## Brief

# Codex brief: the Realtime Content Analysis viewer (feat/realtime-ca-viewer, ceedb17e2)

Range: b1709f7a3..origin/feat/realtime-ca-viewer. A new read-only window showing the content analyzer at work:
`Analyze/Realtime/{RealtimeAnalysisState,RealtimeAnalysisStore,MachineCounters,HelperJournalTally,RealtimeContentAnalysisWindow}.swift`,
plus additive lane/completion fields in `Media/CaptionOrchestrator*.swift` / `CaptionPipelineTypes.swift`, a button in
`Analyze/AnalyzePanelView.swift`, a context-menu item in `MediaOps/MediaFileOperationsWindow.swift`, `MediaOps/AnalyzeJob.swift`.
Rick's rule for this window: nothing faked — every number, line and moving graph is driven by a real counter.

Verify:
- TRUTH: each on-screen number equals its source (orchestrator counters and lanes, the helper's journal and attempts
  files, Mach/IOKit samples). Anything that can show a value with no evidence, a stale value as live, an idle stage as
  busy, a failure as success, `era.none` as an era, "no speech" vs "transcript failed" confused.
- READ-ONLY: the window and HelperJournalTally can never write the catalog, the journal, attempts or checkpoints; the
  orchestrator changes are additive and cannot change what gets banked.
- Pause/Resume/Stop go through the panel's one engine (AnalyzeRunner); no second code path.
- Performance/isolation: no O(records) work in view bodies or on the main actor; ≤2 Hz; a poisoned/huge journal or a
  refused IOKit read degrades to "—" with a reason.
- COVERAGE: behaviour with no test that would go red if it broke.

Output contract: one finding per failing invariant with file:line, scenario, P0–P3, checklist item. End with
`Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`.

This is a re-review. You blocked 17f7336ea on nine findings (captions banked shown before banking; captioned counting files with no captions; no speech shown as transcript failed; an empty pass showing the previous totals; stale helper counts on a read failure; trying including files with a verdict; disk rates across a changed device set; missing Whisper timing as 0 s; unbounded journal/attempts reads). Commit ceedb17e2 closes them (new TranscriptOutcome, CompletedOutput.banked, liveWithCaptions/liveNoSpeech, TryingCounter via AnalysisResultsReport.inProgress, per-device disk deltas, byte caps). Verify each closes with a test that goes red without the fix, then attack the new code.

Round 3: you then blocked 2b25fbf7c on six (trying stale/unbounded/swallowed errors; truncated day file; finished header; waiting lane). ceedb17e2 DROPS the trying tile and its second journal reader (Core back to base), watches inode+size in HelperJournalCursor, renders the header from files done, and shows a waiting state. Verify closure, then attack what remains.
