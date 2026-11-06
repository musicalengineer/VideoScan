# Codex review — Realtime Content Analysis viewer

- Range: `b1709f7a3..origin/feat/realtime-ca-viewer`
- Credits spent: unavailable
- Tokens: 127104
- Finding count: 9
- Verdict: block
- Run: 2026-11-06T02:34:45Z (cycle #247, tools/codex_review.py)

## Codex answer

Reviewed `b1709f7a3..17f7336ea`. Paths below are relative to `VideoScan/VideoScan/`. P0 follows the repository’s explicit classification of unverified UI facts.

1. **P0 — “Captions banked” appears before banking.**  
   `Analyze/Realtime/RealtimeContentAnalysisWindow.swift:463` and `:475`. The lane’s `hasCaptions` becomes true immediately after extraction, before waiting for the previous Whisper task and before `applyDossier`. A fresh record therefore shows “captions banked” while its captions exist only in memory.  
   **Regression needed:** suspend Whisper after extraction; assert the catalog remains unchanged and the viewer does not claim banking. **Checklist: TRUE, TESTED.**

2. **P0 — “Captioned” counts files that produced no captions.**  
   `Analyze/Realtime/RealtimeContentAnalysisWindow.swift:228`. This reads `liveCaptioned`, which `CaptionOrchestrator+DossierSteps.swift:230` increments unconditionally on completion. A transcript-only run, audio-only file, or empty extraction increases “captioned.”  
   **Regression needed:** complete a transcript-only file with `.empty` extraction; expect zero captioned. Existing tests only exercise a completion containing scenes. **Checklist: TRUE, TESTED.**

3. **P0 — Successful “no speech” becomes “transcript failed.”**  
   `Analyze/Realtime/RealtimeContentAnalysisWindow.swift:516`. A transcriber returning `""` successfully is banked as “no speech” by `applyDossier`, but the orchestrator supplies `hasTranscript == false` and the note “transcript failed.” The new viewer displays that note unchanged.  
   **Regression needed:** drive both serial and pipelined completion with a successful empty transcript; distinguish it from a thrown transcription error. **Checklist: TRUE, TESTED.**

4. **P0 — An empty pass displays the preceding pass’s totals.**  
   `Analyze/Realtime/RealtimeAnalysisStore.swift:123`. The mapping discards `.finished`’s associated counts and copies the live counters instead. Both dossier entry points can return `.finished(captioned: 0, skipped: 0, failed: 0)` before resetting those counters when there are no candidates. The viewer then attributes previous results to “Done this pass.”  
   **Regression needed:** finish a nonempty pass, then an empty pass; expect zero terminal totals. **Checklist: TRUE, TESTED.**

5. **P0 — Journal read failures display numbers and hide the reason.**  
   `Analyze/Realtime/RealtimeContentAnalysisWindow.swift:290` and `:325`. `HelperJournalCursor` retains the filename and previous counts when reading throws. The tiles still display those counts, while `helperJournalWords` checks `readProblem` only when no filename exists. A first-read failure displays zero; a subsequent failure displays stale totals without its error.  
   **Regression needed:** read successfully, then make that day file unreadable; expect unavailable totals and the reason. Repeat with an initially unreadable file. **Checklist: TRUE, TESTED.**

6. **P0 — “Trying” includes files already given a verdict.**  
   `Analyze/Realtime/RealtimeAnalysisStore.swift:255`. Counting attempt entries alone ignores the documented crash interval between journal append and attempt clearing (`EraJob.swift:241`). Such a file remains “trying” despite an existing verdict. The existing results report explicitly excludes these entries using journal/catalog evidence.  
   **Regression needed:** retain one attempt entry alongside its completed verdict; expect zero trying. **Checklist: TRUE, TESTED.**

7. **P0 — Disk rates can include historical bytes or incomplete device totals.**  
   `Analyze/Realtime/MachineCounters.swift:135` and `:228`. Rates subtract aggregate counters without retaining device identities. Attaching a previously active disk adds its historical counter to the next interval. Individual refused statistics reads are also silently omitted whenever another driver succeeds. Neither case reliably becomes “—” with a reason.  
   **Regression needed:** change the driver set between samples, and refuse one driver’s statistics; require an unavailable interval rather than an aggregate rate. **Checklist: TRUE, TESTED.**

8. **P0 — Missing transcription timing is reported as zero elapsed time.**  
   `Analyze/Realtime/RealtimeAnalysisState.swift:101`. `secondsPerFile` substitutes zero for absent durations. The serial pipeline always records `whisperSeconds: nil`, including successful transcript-only work (`CaptionOrchestrator+Dossier.swift:786`). A lengthy transcription can consequently contribute approximately `0.0 s/file`.  
   **Regression needed:** time a serial transcription and verify the displayed duration includes it, or remains unavailable. The existing mean test explicitly accepts incomplete timings. **Checklist: TRUE, TESTED.**

9. **P1 — Helper reads lack a bounded-work guarantee for oversized input.**  
   `Analyze/Realtime/HelperJournalTally.swift:148` and `RealtimeAnalysisStore.swift:253`. The journal budget limits completed lines, not bytes: one enormous unterminated line is scanned to EOF and rescanned on subsequent refreshes. Attempts snapshots load the entire file into memory every refresh. Neither path imposes a byte/time limit that returns unavailable with a reason.  
   **Regression needed:** oversized unterminated journal and attempts fixtures; assert bounded reads, bounded memory, and explicit unavailability. **Checklist: PERFORMANCE, TESTED.**

Scoped changes read, no findings: `AnalyzePanelView.swift`, `MediaFileOperationsWindow.swift`, `AnalyzeJob.swift`, `CaptionOrchestrator.swift`, `CaptionOrchestrator+Activity.swift`, and `CaptionPipelineTypes.swift`. No new catalog/journal/attempt/checkpoint writes found; controls delegate through `AnalyzeRunner`.

Inspected 38 added test declarations; six read-only source checks passed. **Zero Swift tests executed:** the checkout is at the base SHA and the enforced filesystem sandbox is read-only. The regression cases above are proposed, not observed RED tests. Review followed direct dependencies only.

Credits spent: unavailable | Finding count: 9  
Verdict: block

## Brief

# Codex brief: the Realtime Content Analysis viewer (feat/realtime-ca-viewer, 17f7336ea)

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
