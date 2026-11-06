// RealtimeContentAnalysisCodexTests.swift — the nine Codex findings on the
// Realtime Content Analysis viewer (codex-review-realtime-content-analysis-
// viewer-2026-11-05.md), each pinned by a test seen red on 17f7336ea first.
//
//   F1  a lane never says "banked" before applyDossier banked it; a finished
//       row says banked only when applyDossier returned true
//   F2  "captions" counts files whose captions banked, not every completion
//   F3  a successful empty transcript is "no speech", never "transcript
//       failed" — serial and pipelined, lane, note and counters
//   F4  an empty pass shows zero totals, never the previous pass's
//   F5  a journal read failure makes the tally unavailable, with the reason
//   F6  "trying": first wired to AnalysisResultsReport's rule, then DROPPED on
//       the re-review (1/2/6: no single bounded source; the Results sheet owns it)
//   F7  disk read is a per-device delta; a changed device set or a refused
//       driver read is unavailable with a reason, never a rate
//   F8  serial Whisper is timed; an untimed file never counts as 0 s
//   F9  bounded reads: an unterminated huge journal line and an oversized
//       attempts file are unavailable with a reason, never rescanned forever
// Plus the three label rules (one honest helper progress phrase; no "other
// lines"; "no speech" is its own grey tile).
//
// Driven through the REAL CaptionOrchestrator with the shared stubs
// (StubDossierRunner / StubAudioTranscriber). Synthetic names, temp folders.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private func record(_ path: String, streamType: StreamType = .videoAndAudio, duration: Double = 3) -> VideoRecord {
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.streamTypeRaw = streamType.rawValue
    r.durationSeconds = duration
    r.lifecycleStage = .cataloged
    return r
}

private func scratch(_ label: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-ca-codex-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

@MainActor
@Suite("Realtime Content Analysis — Codex findings, red first")
struct RealtimeContentAnalysisCodexTests {

    // F2
    @Test func captionsCountsOnlyFilesWhoseCaptionsBanked() async throws {
        let dir = try scratch("f2")
        let model = VideoScanModel()
        let audio = record(dir + "/talk.mp3", streamType: .videoAndAudio)   // transcript-only run: no VLM stage
        model.records = [audio]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        orch.resetLiveCounts()
        orch.liveTotal = 1
        await orch.runDossierBatchSerial(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "hello"),
                                         candidates: [audio], framesPerFile: 3, force: false, model: model,
                                         stackID: "t", started: CFAbsoluteTimeGetCurrent(), stages: [.transcript])
        let s = RealtimeAnalysisStore.inApp(from: orch)
        #expect(orch.liveCaptioned == 1, "the batch counts the file as done (unchanged)")
        #expect(s.captioned == 0, "no captions were banked: the captions tile must read 0, not the files-done count")
        #expect(s.transcribed == 1)
    }

    // F3 — serial
    @Test func aSuccessfulEmptyTranscriptIsNoSpeechInTheSerialPath() async throws {
        let dir = try scratch("f3s")
        let model = VideoScanModel()
        let quiet = record(dir + "/quiet.mov")
        model.records = [quiet]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        orch.resetLiveCounts()
        orch.liveTotal = 1
        await orch.runDossierBatchSerial(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "   \n"),
                                         candidates: [quiet], framesPerFile: 3, force: false, model: model,
                                         stackID: "t", started: CFAbsoluteTimeGetCurrent())
        let done = try #require(orch.recentActivity.first)
        #expect(done.note == "no speech", "Whisper ran and found nothing: \(String(describing: done.note))")
        #expect(!done.transcriptFailed, "not a failure")
        #expect(orch.transcriptFailures == 0)
        #expect(quiet.audioTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true, "banked as no speech (unchanged)")
        let s = RealtimeAnalysisStore.inApp(from: orch)
        #expect(s.transcriptFailures == 0 && s.transcribed == 0)
    }

    // F3 — pipelined
    @Test func aSuccessfulEmptyTranscriptIsNoSpeechInThePipelinedPath() async throws {
        let dir = try scratch("f3p")
        let model = VideoScanModel()
        let quiet = record(dir + "/quiet.mov")
        model.records = [quiet]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        await orch.runDossierBatch(runner: runner, transcriber: StubAudioTranscriber(transcriptText: ""),
                                   candidates: [quiet], framesPerFile: 3, force: false, model: model)
        let done = try #require(orch.recentActivity.first)
        #expect(done.note == "no speech", "\(String(describing: done.note))")
        #expect(!done.transcriptFailed)
        #expect(orch.transcriptFailures == 0)
    }

    // F3 — a thrown error is still a failure (the other side of the rule)
    @Test func aThrownTranscriptionIsStillAFailure() async throws {
        let dir = try scratch("f3e")
        let model = VideoScanModel()
        let bad = record(dir + "/bad.mov")
        model.records = [bad]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        await orch.runDossierBatch(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "x", failOnPath: bad.fullPath),
                                   candidates: [bad], framesPerFile: 3, force: false, model: model)
        let done = try #require(orch.recentActivity.first)
        #expect(done.note == "transcript failed" && done.transcriptFailed)
        #expect(orch.transcriptFailures == 1)
    }

    // F4
    @Test func anEmptyPassShowsZeroTotals() async throws {
        let dir = try scratch("f4")
        let model = VideoScanModel()
        let a = record(dir + "/a.mov")
        model.records = [a]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        await orch.runDossierBatch(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "hello"),
                                   candidates: [a], framesPerFile: 3, force: false, model: model)
        #expect(RealtimeAnalysisStore.inApp(from: orch).captioned == 1)
        // The next pass has nothing to do (no reachable volume, no candidate).
        model.records = []
        model.scanTargets = []
        await orch.startCatalogWideDossier(model: model, transcriber: StubAudioTranscriber(transcriptText: "hello"))
        guard case .finished(let c, let sk, let f) = orch.currentStatus else { Issue.record("\(orch.currentStatus)"); return }
        #expect(c == 0 && sk == 0 && f == 0)
        let s = RealtimeAnalysisStore.inApp(from: orch)
        #expect(s.phase == .finished)
        #expect(s.captioned == 0 && s.skipped == 0 && s.failed == 0 && s.transcribed == 0 && s.transcriptFailures == 0,
                "an empty pass shows its own totals: \(s)")
    }

    // F5
    @Test func aJournalReadFailureIsUnavailableWithTheReason() async throws {
        let dir = URL(fileURLWithPath: try scratch("f5"))
        let journal = ObservationJournal(directory: dir)
        try journal.append([try ObservationLine(subjectID: String(repeating: "a", count: 64), field: MachineEraResolver.fusedField,
                                                value: "1991-1995", by: SeatedApproach.eraA2.signer, at: 1, confidence: 0.6,
                                                evidence: [:], job: "T", unit: 0)])
        let cursor = HelperJournalCursor(directory: dir)
        let ok = await cursor.refresh()
        #expect(ok.eraFound == 1 && ok.readProblem == nil)
        let file = dir.appendingPathComponent(ok.file ?? "")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let broken = await cursor.refresh()
        #expect(broken.readProblem != nil, "the reason is said")
        #expect(broken.eraFound == 0 && broken.lines == 0, "stale counts are not shown as live: \(broken)")
    }

    // F8 — the serial path times Whisper
    @Test func serialTranscriptionIsTimed() async throws {
        let dir = try scratch("f8")
        let model = VideoScanModel()
        let a = record(dir + "/a.mov")
        model.records = [a]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        orch.resetLiveCounts()
        orch.liveTotal = 1
        await orch.runDossierBatchSerial(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "hi", delay: .milliseconds(60)),
                                         candidates: [a], framesPerFile: 3, force: false, model: model,
                                         stackID: "t", started: CFAbsoluteTimeGetCurrent())
        let done = try #require(orch.recentActivity.first)
        let whisper = try #require(done.whisperSeconds, "the serial path measures Whisper")
        #expect(whisper >= 0.05, "\(whisper)")
    }

    // F8 — an untimed file is excluded from s/file, never 0 s
    @Test func anUntimedFileNeverCountsAsZeroSeconds() {
        func out(_ v: Double?, _ w: Double?, videoOnly: Bool = false) -> RealtimeAnalysisState.Output {
            RealtimeAnalysisState.Output(id: UUID(), filename: "f", path: "/f", recordID: nil, syncedAt: Date(), vlmSeconds: v,
                                         whisperSeconds: w, note: nil, isVideoOnly: videoOnly, hasCaptions: true, hasTranscript: w != nil,
                                         transcriptFailed: false, sceneCount: 1, firstCaption: nil, transcriptExcerpt: nil)
        }
        var s = RealtimeAnalysisState.InApp()
        s.recent = [out(10, nil)]
        #expect(s.secondsPerFile == nil, "Whisper ran but was not timed: no number")
        s.recent = [out(10, nil, videoOnly: true), out(4, 2)]
        #expect(s.secondsPerFile == 8, "(10 + 6) / 2: a video-only file has no Whisper stage to time")
        s.recent = [out(nil, 2)]
        #expect(s.secondsPerFile == nil, "VLM not timed: no number")
    }

    // F9 — an unterminated huge line is bounded and unavailable
    @Test func anUnterminatedHugeLineIsUnavailableWithTheReason() async throws {
        let dir = URL(fileURLWithPath: try scratch("f9"))
        let name = ObservationJournal.fileName(for: Date())
        var bytes = Data()
        bytes.append(try ObservationLine(subjectID: String(repeating: "b", count: 64), field: MachineEraResolver.fusedField,
                                         value: "1991-1995", by: SeatedApproach.eraA2.signer, at: 1, confidence: 0.6,
                                         evidence: [:], job: "T", unit: 0).encoded)
        bytes.append(Data(repeating: 0x61, count: 2 * ObservationJournal.maxLineBytes))   // no newline: a runaway write
        try bytes.write(to: dir.appendingPathComponent(name))
        let cursor = HelperJournalCursor(directory: dir)
        let t = await cursor.refresh()
        #expect(t.readProblem?.contains("unterminated") == true, "\(String(describing: t.readProblem))")
        #expect(t.eraFound == 0, "unavailable, not partial")
    }
}

// MARK: - The rules that needed new shapes (F1 banked, F6 counter, F7, F9 attempts, labels)

@Suite("Realtime Content Analysis — Codex findings, the new rules")
struct RealtimeContentAnalysisCodexRuleTests {

    // F1: a lane's words never claim banking; a finished row claims it only on applyDossier's yes
    @Test func aLaneSaysExtractedAndARowSaysBankedOnlyWhenItWas() {
        var lane = RealtimeAnalysisState.Lane(id: UUID(), filename: "a.mov", path: "/a.mov", recordID: nil, stage: "MLXVLM",
                                               verb: "extracting scenes…", startedAt: Date(), framesPlanned: 6, clipSeconds: 41,
                                               hasCaptions: false, isVideoOnly: false)
        #expect(lane.outWords == "…")
        lane.hasCaptions = true
        #expect(lane.outWords == "scenes extracted — banks after the transcript")
        #expect(!lane.outWords.contains("banked"))
        var out = RealtimeAnalysisState.Output(id: UUID(), filename: "a.mov", path: "/a.mov", recordID: nil, syncedAt: Date(), vlmSeconds: 1,
                                               whisperSeconds: nil, note: nil, isVideoOnly: false, hasCaptions: true, hasTranscript: false,
                                               transcriptFailed: false, sceneCount: 3, firstCaption: "x", transcriptExcerpt: nil)
        #expect(out.bankWords == nil, "applyDossier said yes")
        out.banked = false
        #expect(out.bankWords == "not banked — no catalog row at this path")
        out.noSpeech = true
        #expect(out.transcriptWords == "no speech")
        out.hasTranscript = true
        #expect(out.transcriptWords == "transcript")
    }

    // F1/F2 at the source: a completion applyDossier refused banks nothing and counts nothing
    @MainActor
    @Test func aRefusedBankCountsNoCaptionsAndNoTranscript() {
        let o = CaptionOrchestrator()
        let laneID = o.beginLane(path: "/nowhere/a.mov", filename: "a.mov", isVideoOnly: false, stage: "MLXVLM", verb: "…")
        o.updateLane(laneID, hasCaptions: true)
        o.markTranscriptBanked(laneID, banked: false)
        let extraction = DossierExtraction(scenes: [SceneCaption(timestamp: 1, text: "x")], dates: [], texts: [])
        o.completeDossierLane(laneID, vlmSeconds: 1, whisperSeconds: 1, note: nil,
                              output: .from(extraction: extraction, transcript: "words", banked: false))
        #expect(o.liveCaptioned == 1, "the file is done (the batch's count is unchanged)")
        #expect(o.liveWithCaptions == 0 && o.liveTranscribed == 0, "nothing reached the catalog, nothing is counted as banked")
        #expect(o.recentActivity.first?.output?.banked == false)
    }

    // F9: a parked over-cap journal tail is not rescanned until the file changes size
    @Test func aParkedTailIsNotRescanned() async throws {
        let dir = URL(fileURLWithPath: try scratch("f9p"))
        let name = ObservationJournal.fileName(for: Date())
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x61, count: ObservationJournal.maxLineBytes + 1).write(to: url)
        let cursor = HelperJournalCursor(directory: dir)
        _ = await cursor.refresh()
        let scans = await cursor.scans
        _ = await cursor.refresh()
        _ = await cursor.refresh()
        #expect(await cursor.scans == scans, "the same size: no rescan")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))   // the runaway line ends: one unreadable line
        try handle.close()
        let t = await cursor.refresh()
        #expect(await cursor.scans == scans + 1)
        #expect(t.available && t.unreadable == 1, "\(t)")
    }

    // F7: the disk rate is per device
    @Test func aChangedDiskSetOrARefusedDriverIsNotARate() {
        typealias Disks = MachineRawCounters.DiskCounters
        let a = Disks(bytesReadByDevice: [1: 1_000_000, 2: 5_000_000])
        let b = Disks(bytesReadByDevice: [1: 3_000_000, 2: 5_000_000])
        #expect(MachineCounterReader.diskDelta(previous: a, now: b, seconds: 2).value == 1, "2 MB on disk 1 over 2 s")
        let c = Disks(bytesReadByDevice: [1: 3_000_000, 2: 5_000_000, 3: 900_000_000_000])
        #expect(MachineCounterReader.diskDelta(previous: a, now: c, seconds: 2).problem?.contains("set of disks changed") == true,
                "a disk that came carries its whole history: never summed in")
        let d = Disks(bytesReadByDevice: [1: 3_000_000])
        #expect(MachineCounterReader.diskDelta(previous: a, now: d, seconds: 2).problem?.contains("set of disks changed") == true)
        let back = Disks(bytesReadByDevice: [1: 1_000_000, 2: 4_000_000])
        #expect(MachineCounterReader.diskDelta(previous: a, now: back, seconds: 2).problem?.contains("went backwards") == true)
        #expect(MachineCounterReader.diskDelta(previous: a, now: b, seconds: 0).problem == "no time elapsed between the two samples")
        // A refused driver read is absent before any fold (readDiskReadBytes); the fold shows its words unchanged.
        let refused = MachineRawCounters(monotonicSeconds: 1, cpu: .absent("x"), gpuUtilizationPercent: .absent("x"),
                                         memoryAvailableBytes: .absent("x"), memoryTotalBytes: 1,
                                         diskRead: .absent("1 of 3 IOBlockStorageDriver entries refused their Statistics"))
        #expect(MachineCounterReader.fold(previous: nil, now: refused).diskProblem == "1 of 3 IOBlockStorageDriver entries refused their Statistics")
    }

    // Labels: one honest helper phrase
    @Test func theHelperPhraseIsOneHonestSentence() {
        typealias H = RealtimeAnalysisState.Helper
        let run = RealtimeAnalysisState.HelperJob(stateWords: "running", completedUnits: 158, totalUnits: 402, startedAt: nil)
        #expect(H.progressWords(availability: .answered, era: run, planned: 244, backoff: "full") == "running · 158 of 402 files in this run",
                "the plan size is not shown beside a run's own N of M")
        #expect(H.progressWords(availability: .answered, era: nil, planned: 244, backoff: nil) == "no run on now · 244 files planned for the next run")
        #expect(H.progressWords(availability: .answered, era: nil, planned: 0, backoff: nil) == "answered — no era job")
        #expect(H.progressWords(availability: .answered, era: run, planned: nil, backoff: "paused (thermal)") == "running · 158 of 402 files in this run · pace paused (thermal)")
        #expect(H.progressWords(availability: .disabled, era: run, planned: 1, backoff: nil) == "off in Settings")
        #expect(H.progressWords(availability: .silent("no answer"), era: nil, planned: nil, backoff: nil) == "not answering — no answer")
    }
}

// MARK: - Re-review (codex-review-re-review-…-2026-11-05.md): findings 3, 4, 5 and the "trying" tile

@MainActor
@Suite("Realtime Content Analysis — Codex re-review, red first")
struct RealtimeContentAnalysisCodexRoundTwoTests {

    private func line(_ i: Int) throws -> ObservationLine {
        try ObservationLine(subjectID: String(repeating: "c", count: 63) + String(i), field: MachineEraResolver.fusedField,
                            value: "1991-1995", by: SeatedApproach.eraA2.signer, at: Int64(i), confidence: 0.6,
                            evidence: [:], job: "T", unit: i)
    }

    // 3: the same day file truncated or replaced is rebuilt, never kept as live
    @Test func aTruncatedOrReplacedDayFileIsRebuilt() async throws {
        let dir = URL(fileURLWithPath: try scratch("r3"))
        let journal = ObservationJournal(directory: dir)
        try journal.append([try line(1)])
        let cursor = HelperJournalCursor(directory: dir)
        let first = await cursor.refresh()
        #expect(first.eraFound == 1)
        let url = dir.appendingPathComponent(try #require(first.file))
        try Data().write(to: url)                          // truncated in place (same inode)
        let truncated = await cursor.refresh()
        #expect(truncated.eraFound == 0 && truncated.lines == 0 && truncated.available, "rebuilt from the shorter file: \(truncated)")
        var replacement = Data()
        replacement.append(try line(2).encoded)
        replacement.append(try line(3).encoded)
        try replacement.write(to: url, options: .atomic)    // replaced (a new inode), longer than before
        let replaced = await cursor.refresh()
        #expect(replaced.eraFound == 2 && replaced.lines == 2 && replaced.available, "rebuilt from the new file: \(replaced)")
    }

    // 4: the finished header counts files done, not captions
    @Test func theFinishedHeadlineCountsFilesDone() async throws {
        let dir = try scratch("r4")
        let model = VideoScanModel()
        let audio = record(dir + "/talk.mp3")
        model.records = [audio]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        orch.resetLiveCounts()
        orch.liveTotal = 1
        await orch.runDossierBatchSerial(runner: runner, transcriber: StubAudioTranscriber(transcriptText: "hello"),
                                         candidates: [audio], framesPerFile: 3, force: false, model: model,
                                         stackID: "t", started: CFAbsoluteTimeGetCurrent(), stages: [.transcript])
        orch.currentStatus = .finished(captioned: orch.liveCaptioned, skipped: orch.liveSkipped, failed: orch.liveFailed)
        let s = RealtimeAnalysisStore.inApp(from: orch)
        #expect(s.done == 1 && s.captioned == 0)
        #expect(s.headline == "Finished — 1 analyzed · 0 skipped · 0 failed", "\(s.headline)")
    }

    // 5: a lane whose extraction finished but waits on the previous file's Whisper says so
    @Test func aLaneWaitingOnThePreviousTranscriptSaysSo() async throws {
        let dir = try scratch("r5")
        let model = VideoScanModel()
        let a = record(dir + "/a.mov")                                  // audio + video: a slow Whisper holds the pipeline
        let b = record(dir + "/b.mov", streamType: .videoOnly)          // video only: its scenes wait behind a's Whisper
        model.records = [a, b]
        let runner = StubDossierRunner(modelID: "stub-vlm")
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        let transcriber = StubAudioTranscriber(transcriptText: "hello", delay: .milliseconds(1_200))
        let batch = Task { await orch.runDossierBatch(runner: runner, transcriber: transcriber, candidates: [a, b],
                                                      framesPerFile: 3, force: false, model: model) }
        try await Task.sleep(for: .milliseconds(400))
        let laneB = try #require(RealtimeAnalysisStore.inApp(from: orch).lanes.first { $0.filename == "b.mov" },
                                 "b's lane is open while a's Whisper holds it: \(orch.activeLanes.map(\.filename))")
        #expect(laneB.hasCaptions, "b's extraction finished")
        #expect(laneB.verb.contains("waiting"), "the lane says it is waiting, not extracting: \(laneB.verb)")
        #expect(!laneB.showsFramesToRip, "no 'frames to rip' once the extractor is done")
        await batch.value
        #expect(orch.activeLanes.isEmpty)
    }
}

struct RealtimeContentAnalysisCodexRoundTwoSensorTests {
    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    /// Re-review 1, 2, 6 (KISS, Rick): "trying" needs a catalog read plus a full
    /// scan of every journal day file through a path that swallows read errors —
    /// not one bounded source. The tile is gone; the Results sheet owns that rule.
    @Test func theTryingTileIsGoneAndTheStoreReadsNoSecondJournalPath() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains("\"trying\""), "no 'trying' tile")
        #expect(window.contains("Results…"), "the pane points at the sheet that owns the rule")
        let store = try code("RealtimeAnalysisStore.swift")
        for gone in ["AnalysisResultsReport.inProgress(", "answeredInJournal(", "readAttempts(", "EraAttemptStore", "TryingCounter"] {
            #expect(!store.contains(gone), "no second journal/attempts reader: `\(gone)`")
        }
        #expect(try code("HelperJournalTally.swift").contains("systemFileNumber"), "the cursor watches the file's identity (re-review 3)")
    }
}

// MARK: - Sensors on the window's words (F1, F6 wiring, labels)

struct RealtimeContentAnalysisCodexSensorTests {
    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    @Test func aLaneNeverClaimsBanking() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains("captions banked"), "F1: a lane's captions exist in memory until applyDossier")
    }

    @Test func theLabelsArePlainWords() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains("\"other lines\""), "dropped: plumbing, not a fact Rick needs")
        #expect(window.contains("\"no speech\""), "no speech is its own tile")
        #expect(!window.contains("\"plan \\("), "no bare 'plan N' beside the run's N of M")
    }
}
