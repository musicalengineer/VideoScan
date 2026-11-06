# Codex review — Re-review: Realtime Content Analysis viewer

- Range: `b1709f7a3..origin/feat/realtime-ca-viewer`
- Credits spent: unavailable
- Tokens: 142818
- Finding count: 6
- Verdict: block
- Run: 2026-11-06T03:08:49Z (cycle #249, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 6  
Verdict: block — “Trying” remains unreliable, journal reads remain unbounded through a second path, and three displays still misstate their sources.

Reviewed `b1709f7a3..2b25fbf7c`. Priorities follow the repository’s P0 rule for facts presented without valid evidence. Reproductions below are test specifications, **not executed RED tests**: Xcode exited 74 before running tests because the read-only sandbox denied build/package directories.

1. **P0 — “Trying” stays stale after a verdict arrives.** [RealtimeAnalysisStore.swift:375](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisStore.swift:375). **Checklist: TRUE, TESTED.**  
   The cache key includes attempts, but neither journal nor catalog changes. Count one unanswered attempt, then append its verdict without clearing the attempt—the crash window this fix explicitly supports. Subsequent refreshes return cached `1` indefinitely instead of `0`.  
   Regression: extend `tryingExcludesAFileWithAVerdictAndReadsOnlyOnChange` by inserting `d2` into `v.answered` without changing `v.snapshot`; expect the next count to be zero. The existing test instead requires no second verdict read.

2. **P0 — A refused journal read becomes a confident “Trying” count.** [RealtimeAnalysisStore.swift:103](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisStore.swift:103). **Checklist: TRUE, TESTED.**  
   `EraPlanner.answeredInJournal` calls `ObservationJournal.subjects`, whose line 577 suppresses read errors with `try?` and returns a partial set. With one attempt and its unapplied verdict in an unreadable journal file, the viewer reports `trying = 1`, without a refusal.  
   Regression: make that scratch journal unreadable before the first count; expect `.failure` and a dash with a reason. The existing refusal test injects an attempts failure and never exercises this production path.

3. **P0 — Truncating the current journal preserves its old counts as live.** [HelperJournalTally.swift:167](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/HelperJournalTally.swift:167). **Checklist: TRUE, TESTED.**  
   The cursor resets only when the filename changes or a previous read failed. After counting one era, truncate the same scratch day file to zero. The negative size delta passes the cap check; reading beyond EOF succeeds; `available` remains true and `eraFound` remains `1`.  
   Regression: refresh, truncate, refresh; require unavailable or a correctly rebuilt zero tally. Existing tests cover permission failure and a different day filename, not truncation/replacement.

4. **P0 — The finished header counts captions as analyzed files.** [RealtimeContentAnalysisWindow.swift:74](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeContentAnalysisWindow.swift:74). **Checklist: TRUE, TESTED.**  
   Complete one transcript-only file successfully. The new mapping correctly produces `done = 1`, `captioned = 0`, `transcribed = 1`, but the header renders **“Finished — 0 analyzed.”** It reads `inApp.captioned` instead of `inApp.done`.  
   Regression: extend `captionsCountsOnlyFilesWhoseCaptionsBanked` to verify the actual finished-header wording. Its current assertions stop at the state mapping.

5. **P0 — A finished VLM stage remains displayed as extracting while waiting.** [RealtimeContentAnalysisWindow.swift:440](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeContentAnalysisWindow.swift:440), source [CaptionOrchestrator+Dossier.swift:476](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Media/CaptionOrchestrator+Dossier.swift:476). **Checklist: TRUE, TESTED.**  
   Run an audio/video file with slow Whisper, followed by a video-only file whose extraction finishes quickly. The latter updates only `hasCaptions`, then awaits the preceding Whisper at line 490. Throughout that wait, the viewer still says **“MLXVLM extracting scenes…”** and **“N frames to rip.”**  
   Regression: hold the first transcription with a continuation, finish the second extraction, and inspect the second lane before releasing Whisper. Require a waiting/completed-stage description. No supplied test covers this interval.

6. **P1 — “Trying” bypasses the journal byte cap entirely.** [RealtimeAnalysisStore.swift:103](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisStore.swift:103). **Checklist: PERFORMANCE, TESTED.**  
   `answeredInJournal → subjects` scans every day file from offset zero, without a byte budget or cancellation check. The cap in `HelperJournalCursor` does not constrain this separate read. One attempt plus an old gigabyte-sized unterminated journal triggers that entire scan; changed attempts trigger it again. The helper refresh cannot publish until it finishes.  
   Regression: exercise the production “Trying” reader with a small current journal and an oversized older file; require bounded refusal. Existing cap tests exercise only `HelperJournalCursor` and the attempts file.

The nine earlier findings have this closure status from source inspection:

| Earlier finding | Closure evidence |
|---|---|
| F1: premature banking claim | Lane wording and `banked` propagation corrected; wording/refused-bank tests present. |
| F2: captions counted all completions | Tile corrected and regression present; finished header remains wrong in finding 4. |
| F3: no speech treated as failure | Serial/pipelined regressions and thrown-error control present; source fix looks correct. |
| F4: empty-pass stale totals | Reset paths corrected; `anEmptyPassShowsZeroTotals` covers catalog-wide entry. |
| F5: stale tally after read failure | Exception case corrected and tested; cursor invalidation gap remains in finding 3. |
| F6: trying includes verdicts | **Not closed:** findings 1–2. |
| F7: disk device-set changes | Per-device deltas and refusal tests present; source fix looks correct. |
| F8: missing Whisper timing | Serial timing and incomplete-timing exclusion tests present; source fix looks correct. |
| F9: unbounded reads | Cursor/attempt caps tested; **not closed:** finding 6. |

`MachineCounters.swift`, `RealtimeAnalysisState.swift`, the additive activity/completion bookkeeping, `CaptionPipelineTypes.swift`, `AnalyzePanelView.swift`, `AnalyzeJob.swift`, and the MFO context-menu addition: **read, no additional findings**. Read-only behavior and Pause/Resume/Stop routing through `AnalyzeRunner`: **read, no findings**. Inspection stayed within scoped changes and their direct dependencies; no files were edited.

The commit reports 191 passing related tests. This review independently executed **0 tests**, so its historical RED/GREEN claims remain unverified here.

Credits spent: unavailable | Finding count: 6  
Verdict: block

## Brief

# Codex brief: the Realtime Content Analysis viewer (feat/realtime-ca-viewer, 2b25fbf7c)

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

This is a re-review. You blocked 17f7336ea on nine findings (captions banked shown before banking; captioned counting files with no captions; no speech shown as transcript failed; an empty pass showing the previous totals; stale helper counts on a read failure; trying including files with a verdict; disk rates across a changed device set; missing Whisper timing as 0 s; unbounded journal/attempts reads). Commit 2b25fbf7c closes them (new TranscriptOutcome, CompletedOutput.banked, liveWithCaptions/liveNoSpeech, TryingCounter via AnalysisResultsReport.inProgress, per-device disk deltas, byte caps). Verify each closes with a test that goes red without the fix, then attack the new code.
