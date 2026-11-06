// RealtimeAnalysisStateTests.swift — the Realtime Content Analysis window's
// in-app pane (Analyze/Realtime/RealtimeAnalysisState.swift, the one mapping
// in RealtimeAnalysisStore.inApp(from:)).
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH   every number the pane shows equals the orchestrator's own counter
//           or lane field at that moment: phase, N / M, current file, the
//           orchestrator's ETA, the five done counts, each lane (stage, verb,
//           frames to rip, clip length, catalog id), each finished file with
//           the words it banked. Driven through the REAL CaptionOrchestrator
//           (its lane and completion API, its progress publisher).
//   LOGIC   s/file is the mean over the recent files the orchestrator timed;
//           the words (ETA, clip length, elapsed); the helper pane from one
//           XPC answer (disabled, silent, answered).
//   SCALE / MEDIA N/A: values only; no media opened. ISOLATION: no defaults, no paths.
// Synthetic names only.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Realtime Content Analysis — the in-app pane is the orchestrator's own numbers")
struct RealtimeAnalysisStateTests {

    @Test func inAppMirrorsTheOrchestrator() throws {
        let o = CaptionOrchestrator()
        let idle = RealtimeAnalysisStore.inApp(from: o)
        #expect(idle.phase == .idle)
        #expect(idle.lanes.isEmpty && idle.recent.isEmpty)
        #expect(idle.total == 0 && idle.currentIndex == 0)
        #expect(idle.etaSeconds == nil)
        #expect(!idle.isWorking, "idle says idle: nothing pulses")

        // A batch in flight: progress through the real publisher (it computes the ETA).
        o.resetLiveCounts()
        o.liveTotal = 100
        let started = CFAbsoluteTimeGetCurrent() - 370   // 37 files in 370 s → 10 s/file → 630 s left
        o.applyProgressNow(idx: 37, total: 100, currentFile: "Holiday_1990_Part2.mov", started: started, now: CFAbsoluteTimeGetCurrent())
        o.liveCaptioned = 37
        o.liveWithCaptions = 29
        o.liveTranscribed = 22
        o.liveNoSpeech = 3
        o.transcriptFailures = 5
        o.liveFailed = 1
        o.liveSkipped = 7
        o.currentVolumePrefix = "/Volumes/Tapes"
        let recordID = UUID()
        let laneID = o.beginLane(path: "/Volumes/Tapes/Holiday_1990_Part2.mov", filename: "Holiday_1990_Part2.mov",
                                 isVideoOnly: false, stage: "MLXVLM", verb: "extracting scenes…",
                                 recordID: recordID, framesPlanned: 6, clipSeconds: 41)
        o.updateLane(laneID, hasCaptions: true)

        let s = RealtimeAnalysisStore.inApp(from: o)
        #expect(s.phase == .analyzing)
        #expect(s.currentIndex == o.liveCurrentIndex && s.currentIndex == 37)
        #expect(s.total == o.liveTotal && s.total == 100)
        #expect(s.currentFile == "Holiday_1990_Part2.mov")
        guard case .running(_, _, let eta) = o.currentStatus else { Issue.record("the orchestrator is running"); return }
        #expect(s.etaSeconds == eta, "the ETA is the orchestrator's, never a second estimate")
        let etaValue = try #require(eta)
        #expect(etaValue > 600 && etaValue < 660, "the orchestrator's linear ETA: \(etaValue)")
        #expect(s.done == 37, "files done = liveCaptioned (the batch's own count)")
        #expect(s.captioned == 29, "captions = files whose captions banked (liveWithCaptions), never files done — Codex F2")
        #expect(s.noSpeech == 3 && s.transcribed == 22 && s.transcriptFailures == 5 && s.failed == 1 && s.skipped == 7)
        #expect(s.volumePrefix == "/Volumes/Tapes")
        #expect(s.isWorking, "a lane exists: the dot may pulse")
        let lane = try #require(s.lanes.first)
        #expect(s.lanes.count == o.activeLanes.count && s.lanes.count == 1)
        #expect(lane.id == laneID)
        #expect(lane.filename == "Holiday_1990_Part2.mov" && lane.stage == "MLXVLM" && lane.verb == "extracting scenes…")
        #expect(lane.framesPlanned == 6 && lane.clipSeconds == 41 && lane.recordID == recordID)
        #expect(lane.hasCaptions && !lane.isVideoOnly && !lane.isTranscribing)

        // The stage flips to Whisper in place (one lane per file).
        o.updateLane(laneID, stage: "Whisper", verb: "transcribing audio…")
        #expect(RealtimeAnalysisStore.inApp(from: o).lanes.first?.isTranscribing == true)

        // Paused / stopping / finished follow the orchestrator's state exactly.
        o.paused = true
        #expect(RealtimeAnalysisStore.inApp(from: o).phase == .paused)
        o.paused = false
        o.currentStatus = .cancelling
        #expect(RealtimeAnalysisStore.inApp(from: o).phase == .stopping)
        o.currentStatus = .finished(captioned: 29, skipped: 7, failed: 1)
        let finished = RealtimeAnalysisStore.inApp(from: o)
        #expect(finished.phase == .finished)
        #expect(finished.done == 29 && finished.skipped == 7 && finished.failed == 1, "a finished pass shows its own terminal counts (Codex F4)")
    }

    @Test func completionCarriesTheBankedWords() throws {
        let o = CaptionOrchestrator()
        let recordID = UUID()
        let laneID = o.beginLane(path: "/Volumes/Tapes/a.mov", filename: "a.mov", isVideoOnly: false,
                                 stage: "MLXVLM", verb: "extracting scenes…", recordID: recordID, framesPlanned: 3, clipSeconds: 12)
        o.updateLane(laneID, hasCaptions: true)
        o.markTranscriptBanked(laneID, banked: true)
        #expect(o.liveTranscribed == 1, "the ✓ and the batch count move together")
        let extraction = DossierExtraction(scenes: [SceneCaption(timestamp: 1, text: "family around a tree, a dog"),
                                                    SceneCaption(timestamp: 7, text: "a child opens a box")], dates: [], texts: [])
        o.completeDossierLane(laneID, vlmSeconds: 8.5, whisperSeconds: 3.25, note: nil,
                              output: .from(extraction: extraction, transcript: "  …open that one next…\nokay  ", banked: true))
        let s = RealtimeAnalysisStore.inApp(from: o)
        #expect(s.lanes.isEmpty, "the lane closed")
        #expect(s.done == o.liveCaptioned && s.done == 1 && s.captioned == o.liveWithCaptions && s.captioned == 1)
        let out = try #require(s.recent.first)
        #expect(s.recent.count == o.recentActivity.count && s.recent.count == 1)
        #expect(out.recordID == recordID && out.filename == "a.mov")
        #expect(out.hasCaptions && out.hasTranscript && !out.transcriptFailed)
        #expect(out.sceneCount == 2)
        #expect(out.firstCaption == "family around a tree, a dog")
        #expect(out.transcriptExcerpt == "…open that one next… okay", "trimmed, one line")
        #expect(out.vlmSeconds == 8.5 && out.whisperSeconds == 3.25)
        #expect(s.secondsPerFile == 11.75)
    }

    @Test func theOutputWordsAreBoundedAndNeverEmpty() {
        let long = String(repeating: "x", count: 500)
        let cut = CompletedOutput.cut(long)
        #expect(cut.count == CompletedOutput.maxChars + 1 && cut.hasSuffix("…"))
        let out = CompletedOutput.from(extraction: .empty, transcript: "   \n  ", banked: true)
        #expect(out.sceneCount == 0 && out.firstCaption == nil && out.transcriptExcerpt == nil, "whitespace is no transcript")
        #expect(CompletedOutput.from(extraction: .empty, transcript: nil, banked: false).transcriptExcerpt == nil)
    }

    @Test func secondsPerFileIsTheMeanOfTheRecentFiles() {
        var s = RealtimeAnalysisState.InApp()
        #expect(s.secondsPerFile == nil, "nothing finished: no number")
        func out(_ v: Double?, _ w: Double?) -> RealtimeAnalysisState.Output {
            RealtimeAnalysisState.Output(id: UUID(), filename: "f", path: "/f", recordID: nil, syncedAt: Date(), vlmSeconds: v,
                                         whisperSeconds: w, note: nil, isVideoOnly: false, hasCaptions: true, hasTranscript: w != nil,
                                         transcriptFailed: false, sceneCount: 1, firstCaption: nil, transcriptExcerpt: nil)
        }
        s.recent = [out(10, 5), out(3, nil), out(nil, nil)]
        #expect(s.secondsPerFile == 15, "only the fully timed file counts; a file with an untimed stage is left out, never 0 s (Codex F8)")
        #expect(s.timedCount == 1)
        #expect(RealtimeAnalysisState.secondsPerFileWords(s.secondsPerFile, over: s.timedCount) == "15.0 s/file (last 1)")
        #expect(RealtimeAnalysisState.secondsPerFileWords(nil, over: 0) == "— s/file")
    }

    @Test func theWords() {
        #expect(RealtimeAnalysisState.etaWords(nil) == "ETA —")
        #expect(RealtimeAnalysisState.etaWords(30) == "ETA under a minute")
        #expect(RealtimeAnalysisState.etaWords(600) == "ETA 10 min")
        #expect(RealtimeAnalysisState.etaWords(7200) == "ETA 2.0 h")
        #expect(RealtimeAnalysisState.clipWords(0).isEmpty)
        #expect(RealtimeAnalysisState.clipWords(41) == "41 s of media")
        #expect(RealtimeAnalysisState.clipWords(125) == "2 min 5 s of media")
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(RealtimeAnalysisState.elapsedWords(since: t0, now: t0.addingTimeInterval(9)) == "9s")
        #expect(RealtimeAnalysisState.elapsedWords(since: t0, now: t0.addingTimeInterval(125)) == "2m 5s")
        #expect(RealtimeAnalysisState.elapsedWords(since: t0, now: t0.addingTimeInterval(-5)) == "0s", "never negative")
    }

    @Test func theHelperPaneFromOneAnswer() throws {
        let signer = SeatedApproach.eraA2.signer
        let previous = RealtimeAnalysisState.Helper()
        let off = RealtimeAnalysisStore.helper(from: nil, enabled: false, seatedSigner: signer, previous: previous)
        #expect(off.availability == .disabled && off.era == nil && off.planned == nil)
        #expect(off.modelShortName == MachineEraResolver.modelShortName(by: signer))

        let silent = RealtimeAnalysisStore.helper(from: nil, enabled: true, seatedSigner: signer, previous: previous)
        #expect(silent.availability == .silent("no answer"))
        let refused = RealtimeAnalysisStore.helper(from: .failure(Refusal("the helper is not running")), enabled: true,
                                                   seatedSigner: signer, previous: previous)
        #expect(refused.availability == .silent("the helper is not running"))

        let started = Date(timeIntervalSince1970: 1_793_925_000)
        let era = VideoScanCore.JobProgressSnapshot(id: JobID(), kind: .era, lane: "era", title: "Machine era", subtitle: "unit 37 of 100",
                                      completedUnits: 37, totalUnits: 100, skippedUnits: 0, failedUnits: 0,
                                      state: .running, startedAt: started, finishedAt: nil)
        let status = ServiceStatus(processIdentifier: 42, startedAt: started, backoff: .full, jobs: [era], idleSeconds: 0,
                                   planned: [JobKind.era.rawValue: 402])
        let answered = RealtimeAnalysisStore.helper(from: .success(status), enabled: true, seatedSigner: signer, previous: previous)
        #expect(answered.availability == .answered)
        let job = try #require(answered.era)
        #expect(job.stateWords == "running" && job.completedUnits == 37 && job.totalUnits == 100 && job.startedAt == started)
        #expect(answered.planned == 402)
        #expect(answered.backoffWords == BackoffState.full.words)

        // No era job in the answer: said, not invented.
        let none = ServiceStatus(processIdentifier: 42, startedAt: started, backoff: .full, jobs: [], idleSeconds: 3)
        #expect(RealtimeAnalysisStore.helper(from: .success(none), enabled: true, seatedSigner: signer, previous: previous).era == nil)
    }

    @Test func theMachinePaneFoldsSamplesAndBoundsItsHistory() {
        var m = RealtimeAnalysisState.Machine()
        #expect(m.cpu.words == "—" && m.cpu.problem != nil, "nothing sampled: a dash with a reason")
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<70 {
            m.apply(MachineSample(cpuBusyPercent: Double(i), cpuProblem: nil, gpuUtilizationPercent: nil, gpuProblem: "no GPU",
                                  memoryUsedGB: 38.2, memoryTotalGB: 96, memoryProblem: nil,
                                  diskReadMBPerSecond: 210, diskProblem: nil), at: t0.addingTimeInterval(Double(i)))
        }
        #expect(m.cpu.history.count == RealtimeAnalysisState.Reading.historyCap, "bounded ring")
        #expect(m.cpu.history.first == 10 && m.cpu.history.last == 69, "oldest dropped first")
        #expect(m.cpu.words == "69%")
        #expect(m.gpu.value == nil && m.gpu.history.isEmpty && m.gpu.words == "—" && m.gpu.tooltip.hasSuffix("— no GPU"))
        #expect(m.memory.words == "38.2 GB" && m.memoryTotalGB == 96)
        #expect(m.diskRead.words == "210 MB/s")
        #expect(m.sampledAt == t0.addingTimeInterval(69))
        #expect(m.cpu.tooltip == MachineCounterSource.cpu, "the source is the tooltip")
    }
}
