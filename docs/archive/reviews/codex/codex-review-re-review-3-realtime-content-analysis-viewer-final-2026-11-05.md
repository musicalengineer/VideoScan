# Codex review — Re-review 3: Realtime Content Analysis viewer (final)

- Range: `b1709f7a3..origin/feat/realtime-ca-viewer`
- Credits spent: unavailable
- Tokens: 148012
- Finding count: 3
- Verdict: block
- Run: 2026-11-06T03:54:19Z (cycle #252, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3  
Verdict: block — one normal-use P0 remains; the other findings are a poisoned-state edge case and a coverage gap.

Reviewed `b1709f7a3..71acb3cf0`. **No data-loss or new persistence-write path found.**

1. **P0 — “Caption Videos” produces captions while the viewer reports zero.**  
   [RealtimeAnalysisStore.swift:128](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeAnalysisStore.swift:128), [RealtimeContentAnalysisWindow.swift:135](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/RealtimeContentAnalysisWindow.swift:135). **Checklist: TRUE, TESTED.**

   **Normal-use reproduction:** open Realtime, then select a volume’s **Caption Videos** command. That command uses the same orchestrator’s `startCaptioning → runBatch`. This path saves captions and increments `liveCaptioned`, but never populates `liveWithCaptions`, lanes, or completion history. Consequently, the viewer says “Between files” during inference and retains **0 captions** after successful writeback.

   **Regression:** extend `CaptionOrchestratorTests.writebackHappensPerFile` to require `RealtimeAnalysisStore.inApp(from: orch).captioned == 2`. Hold the caption runner mid-call and require an active-work representation. Existing viewer tests exercise dossier paths only. This is a true visible P0, without poisoned state.

2. **P2 — A FIFO blocks the journal refresh before its regular-file check.**  
   [HelperJournalTally.swift:176](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Analyze/Realtime/HelperJournalTally.swift:176). **Checklist: PERFORMANCE, TESTED.**

   **Edge-case reproduction:** make the newest `*.jsonl` entry a FIFO with no writer. `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` blocks before `fstat` can reject it. The helper refresh never returns unavailable; previously displayed helper information can remain indefinitely. The main sampling loop continues.

   **Regression:** require prompt refusal of a FIFO, protected by a subprocess timeout. The existing nonregular-file test covers a symlink only. Add `O_NONBLOCK` before checking `S_IFREG`.

3. **P2 — The actual “no speech” counter lacks a regression assertion.**  
   [CaptionOrchestrator+DossierSteps.swift:249](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScan/Media/CaptionOrchestrator+DossierSteps.swift:249), [RealtimeContentAnalysisCodexTests.swift:92](/Users/rickb/dev/VideoScan-wt/realtime-ca/VideoScan/VideoScanTests/RealtimeContentAnalysisCodexTests.swift:92). **Checklist: TESTED.**

   The serial and pipelined empty-transcript tests verify wording and failure flags, but neither requires `noSpeech == 1`. The mapping test manually assigns `liveNoSpeech = 3`. Removing the production increment therefore escapes these assertions.

   **Regression:** assert the published count after actual empty-transcript completion in both paths, and zero after refused banking and an empty subsequent pass. This is a coverage gap, not an observed incorrect count.

Earlier fixes have these **source-review** results:

| Prior invariant | Closure evidence |
|---|---|
| Premature banking and caption counts | Banking propagation and refused-bank/completion tests; missing caption-only engine coverage is finding 1. |
| No speech versus failure | Serial/pipelined wording tests and thrown-error control; counter coverage is finding 3. |
| Empty-pass totals and finished header | Reset paths and rendered-headline regression present. |
| Trying stale/unbounded/error-swallowing reader | Tile and reader removed; removal sensor present; Core matches base. |
| Journal truncation, replacement and same-length rewrite | Byte-zero re-fold with targeted tests. |
| Unknown before first read | Unknown/unavailable initialization and delayed-XPC test present. |
| Waiting lanes, including empty extraction | Explicit `extractionDone` and both waiting regressions present. |
| Disk changes, missing Whisper timing, GPU refusals | Targeted arithmetic, timing and mixed-entry tests present. |
| Huge/nonregular journal reads | Regular-file cap and symlink tests present; FIFO refusal remains incomplete. |

Read-only behavior, `AnalyzeRunner` routing, `MachineCounters.swift`, `CaptionPipelineTypes.swift`, panel/MFO entry points, and additive banking changes: **read, no additional findings**.

**Tests executed: 0.** Targeted `xcodebuild test` exited 74 because the sandbox denied DerivedData/package-cache writes. Historical RED/GREEN claims were not independently verified; the proposed regressions above were not executed. Inspection followed direct captioning callers to establish finding 1. No files changed.

Credits spent: unavailable | Finding count: 3  
Verdict: block

## Brief

# Codex brief: the Realtime Content Analysis viewer (feat/realtime-ca-viewer, 71acb3cf0)

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

This is a re-review. You blocked 17f7336ea on nine findings (captions banked shown before banking; captioned counting files with no captions; no speech shown as transcript failed; an empty pass showing the previous totals; stale helper counts on a read failure; trying including files with a verdict; disk rates across a changed device set; missing Whisper timing as 0 s; unbounded journal/attempts reads). Commit 71acb3cf0 closes them (new TranscriptOutcome, CompletedOutput.banked, liveWithCaptions/liveNoSpeech, TryingCounter via AnalysisResultsReport.inProgress, per-device disk deltas, byte caps). Verify each closes with a test that goes red without the fix, then attack the new code.

Round 3: you then blocked 2b25fbf7c on six (trying stale/unbounded/swallowed errors; truncated day file; finished header; waiting lane). 71acb3cf0 DROPS the trying tile and its second journal reader (Core back to base), watches inode+size in HelperJournalCursor, renders the header from files done, and shows a waiting state. Verify closure, then attack what remains.

Pass 4: 71acb3cf0 answers your third pass (re-fold the day file from byte 0 each refresh with O_NOFOLLOW + S_IFREG + a byte-capped read loop; unknown/reading until the first read; an explicit extractionDone; any refused GPU entry → unavailable). This is the FINAL pass before Rick decides: rank findings strictly, mark which are true P0 (a false fact a user can see in normal use) vs edge cases.
