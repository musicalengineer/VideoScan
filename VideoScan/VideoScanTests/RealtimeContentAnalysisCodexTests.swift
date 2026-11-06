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
//   F6  "trying" uses AnalysisResultsReport's one rule (a verdict excludes)
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

    // F6: the one rule, and read only when the tries changed
    @Test func tryingExcludesAFileWithAVerdictAndReadsOnlyOnChange() async throws {
        let signer = SeatedApproach.eraA2.signer
        final class Verdicts: @unchecked Sendable { var answered: Set<String> = ["d1"]; var snapshot = EraAttemptSnapshot() }
        let v = Verdicts()
        let line = #"{"tries":1,"lastReason":"r","lastAt":1}"#
        let one = try JSONDecoder().decode(EraAttempt.self, from: Data(line.utf8))
        v.snapshot = EraAttemptSnapshot(entries: ["\(signer) d1": one, "\(signer) d2": one, "machine:other@r1 d3": one])
        let counter = TryingCounter(signer: signer, readAttempts: { .success(v.snapshot) },
                                    answered: { s in s.attempts(signer: signer).keys.filter { !v.answered.contains($0) }.count })
        #expect(try await counter.count().get() == 1, "d1 has a verdict (the crash window between journal append and attempt clear)")
        #expect(try await counter.count().get() == 1)
        #expect(await counter.reads == 1, "unchanged tries: no second catalog/journal read")
        v.snapshot = EraAttemptSnapshot(entries: ["\(signer) d2": one])
        #expect(try await counter.count().get() == 1)
        #expect(await counter.reads == 2, "changed tries: read again")
        v.snapshot = EraAttemptSnapshot()
        #expect(try await counter.count().get() == 0)
        #expect(await counter.reads == 2, "no tries: nothing to read")
        let refused = TryingCounter(signer: signer, readAttempts: { .failure(Refusal("unreadable")) }, answered: { _ in 0 })
        guard case .failure(let r) = await refused.count() else { Issue.record("a refused attempts log is a refusal"); return }
        #expect(r.words == "unreadable")
    }

    // F9: an attempts file over the cap is refused with the size in the words
    @Test func anOversizedAttemptsFileIsRefusedNotRead() throws {
        let root = URL(fileURLWithPath: try scratch("f9a"))
        let url = EraAttemptStore.url(stateRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = try FileHandle(forWritingTo: { FileManager.default.createFile(atPath: url.path, contents: nil); return url }())
        try handle.truncate(atOffset: UInt64(TryingCounter.attemptsFileCap + 1))   // a sparse file: the size is the fact
        try handle.close()
        guard case .failure(let r) = TryingCounter.readAttempts(stateRoot: root) else { Issue.record("over the cap must refuse"); return }
        #expect(r.words.contains("over the window's 32 MB cap") && r.words.contains("32 MB,"), "\(r.words)")
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

// MARK: - Sensors on the window's words (F1, F6 wiring, labels)

struct RealtimeContentAnalysisCodexSensorTests {
    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    @Test func aLaneNeverClaimsBanking() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains("captions banked"), "F1: a lane's captions exist in memory until applyDossier")
    }

    @Test func tryingIsTheReportsOneRule() throws {
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("AnalysisResultsReport.inProgress("), "F6: one rule, the Results sheet's")
    }

    @Test func theLabelsArePlainWords() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains("\"other lines\""), "dropped: plumbing, not a fact Rick needs")
        #expect(window.contains("\"no speech\""), "no speech is its own tile")
        #expect(!window.contains("\"plan \\("), "no bare 'plan N' beside the run's N of M")
    }
}
