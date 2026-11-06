// RealtimeContentAnalysisTests.swift — the Realtime Content Analysis window
// (Analyze/Realtime/RealtimeAnalysisStore.swift, RealtimeContentAnalysisWindow.swift).
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC    the store's tick: in-app copy, machine sample, the helper refresh
//            on its cadence and off the main actor; publishes are equality-
//            gated; the helper's availability words are logged once; the try
//            counts are the seated signer's; Pause / Resume / Stop reach the
//            injected engine once per click; stop() ends the loop.
//   SENSOR   RealtimeContentAnalysisSensorTests: no `extension VideoScanModel`,
//            no records walk, the journal / attempts / log are never written,
//            the kernel and the file reads run off the main actor, both doors
//            open the ONE controller, the dossier is the ONE loader, Pause /
//            Stop are AnalyzeRunner's (the panel's engine), ≤ 2 Hz, no yellow,
//            the orchestrator's new counter is reset with the others.
//   MOCKUP   RealtimeContentAnalysisMockupTests renders the real view from
//            fixtures (idle · mid-run · error/unknown) through ImageRenderer;
//            with VIDEOSCAN_MOCKUP_DIR set the PNGs are written there
//            (.scratch only, never git). Synthetic names only.
//   SCALE    the view reads one small value; the sensor pins "no records".
//   MEDIA N/A. ISOLATION: injected sources, temp folders, no defaults.

import AppKit
import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

/// Core's EraAttempt has no public memberwise init (the job writes it); a test
/// builds one the way the store replays it: from its JSON line.
private func attempt(tries: Int, reason: String) -> EraAttempt {
    let json = "{\"tries\":\(tries),\"lastReason\":\"\(reason)\",\"lastAt\":1}"
    return try! JSONDecoder().decode(EraAttempt.self, from: Data(json.utf8))
}

/// The injected sources' state. Test-only: the tests write it from the main
/// actor and the store's detached helper refresh reads it while the test
/// awaits that refresh, so there is never a concurrent writer.
private final class Probe: @unchecked Sendable {
    var notes: [String] = []
    var statusCalls = 0
    var pauses = 0, resumes = 0, stops = 0
    var enabled = false
    var reply: Result<ServiceStatus, Refusal> = .failure(Refusal("the helper is not running"))
    var inApp = RealtimeAnalysisState.InApp()
    var tally = HelperJournalTally()
    var attempts: Result<EraAttemptSnapshot, Refusal> = .success(EraAttemptSnapshot())
    var machine = MachineSample(cpuBusyPercent: 40, cpuProblem: nil, gpuUtilizationPercent: 94, gpuProblem: nil,
                                memoryUsedGB: 38.2, memoryTotalGB: 96, memoryProblem: nil, diskReadMBPerSecond: 210, diskProblem: nil)
    var now = Date(timeIntervalSince1970: 1_793_925_000)
    var journalWords: String? = "Background: 3 journal lines waiting · 0 refused"
}

@MainActor
private func store(_ p: Probe, tick: Duration = .milliseconds(500), helperEvery: Duration = .seconds(5)) -> RealtimeAnalysisStore {
    let sources = RealtimeAnalysisStore.Sources(
        inApp: { p.inApp },
        helperEnabled: { p.enabled },
        helperStatus: { p.statusCalls += 1; return p.reply },
        journal: { p.tally },
        attempts: { p.attempts },
        machine: { p.machine },
        journalWords: { p.journalWords },
        note: { p.notes.append($0) },
        pause: { p.pauses += 1 },
        resume: { p.resumes += 1 },
        stop: { p.stops += 1 },
        seatedSigner: SeatedApproach.eraA2.signer,
        now: { p.now })
    return RealtimeAnalysisStore(sources: sources, tick: tick, helperEvery: helperEvery)
}

// MARK: - Logic

@MainActor
@Suite("Realtime Content Analysis — the store")
struct RealtimeAnalysisStoreTests {

    @Test func aTickCopiesTheSourcesAndPublishesOnlyOnChange() async throws {
        let p = Probe()
        p.inApp.phase = .analyzing
        p.inApp.captioned = 29
        // No kernel number this tick: every counter is a reason, so the sparklines have no new point.
        let sample = p.machine
        p.machine = MachineSample(cpuProblem: "no", gpuProblem: "no", memoryProblem: "no", diskProblem: "no")
        let s = store(p)
        await s.refreshNow(waitForHelper: true)
        #expect(s.publishes == 1 && s.ticks == 1)
        #expect(s.state.inApp.captioned == 29 && s.state.inApp.phase == .analyzing)
        #expect(s.state.machine.gpu.words == "—" && s.state.machine.gpu.problem == "no" && s.state.machine.sampledAt == p.now)
        #expect(s.state.helper.availability == .disabled, "off in Settings")
        #expect(p.statusCalls == 0, "a disabled helper is never asked — asking would start it")
        #expect(s.state.helper.journalWords == p.journalWords)

        await s.refreshNow(waitForHelper: true)
        #expect(s.publishes == 1 && s.ticks == 2, "nothing moved: nothing published")

        p.inApp.captioned = 30
        await s.refreshNow(waitForHelper: true)
        #expect(s.publishes == 2 && s.state.inApp.captioned == 30)

        // A kernel number is a new point on its sparkline: a real sample always moves the history.
        p.machine = sample
        await s.refreshNow(waitForHelper: true)
        #expect(s.publishes == 3 && s.state.machine.gpu.words == "94%" && s.state.machine.gpu.history == [94])
        await s.refreshNow(waitForHelper: true)
        #expect(s.publishes == 4 && s.state.machine.gpu.history == [94, 94], "same value, one more sample")
    }

    @Test func theHelperIsAskedOnItsCadenceAndItsWordsAreLoggedOnce() async throws {
        let p = Probe()
        p.enabled = true
        let s = store(p, helperEvery: .seconds(5))
        await s.refreshNow(waitForHelper: true)
        #expect(p.statusCalls == 1)
        #expect(s.state.helper.availability == .silent("the helper is not running"))
        #expect(p.notes.filter { $0.contains("did not answer") }.count == 1)

        p.now = p.now.addingTimeInterval(1)
        await s.refreshNow(waitForHelper: true)
        #expect(p.statusCalls == 1, "1 s later: not asked again")
        #expect(p.notes.filter { $0.contains("did not answer") }.count == 1, "the same words are not logged twice")

        p.now = p.now.addingTimeInterval(5)
        let started = Date(timeIntervalSince1970: 1_793_925_000)
        let era = VideoScanCore.JobProgressSnapshot(id: JobID(), kind: .era, lane: "era", title: "Machine era", subtitle: "", completedUnits: 3,
                                      totalUnits: 10, skippedUnits: 0, failedUnits: 0, state: .running, startedAt: started, finishedAt: nil)
        p.reply = .success(ServiceStatus(processIdentifier: 1, startedAt: started, backoff: .full, jobs: [era], idleSeconds: 0))
        await s.refreshNow(waitForHelper: true)
        #expect(p.statusCalls == 2, "5 s later: asked")
        #expect(s.state.helper.availability == .answered && s.state.helper.era?.completedUnits == 3)
        #expect(p.notes.filter { $0 == "VideoScan Background answered" }.count == 1)
    }

    @Test func theTryCountsAreTheSeatedSignersAndAnUnreadableLogSaysSo() async throws {
        let p = Probe()
        let seated = SeatedApproach.eraA2.signer
        p.attempts = .success(EraAttemptSnapshot(entries: [
            "\(seated) d1": attempt(tries: 2, reason: "no frame"),
            "\(seated) d2": attempt(tries: 1, reason: "timeout"),
            "machine:other/era-v1@r1 d3": attempt(tries: 3, reason: "x"),
        ]))
        let s = store(p)
        await s.refreshNow(waitForHelper: true)
        #expect(s.state.helper.triesInProgress == 2 && s.state.helper.triesProblem == nil)

        p.attempts = .failure(Refusal("era: the try counts at /x/era.jsonl are unreadable (line 3 is not a try record)"))
        p.now = p.now.addingTimeInterval(6)
        await s.refreshNow(waitForHelper: true)
        #expect(s.state.helper.triesInProgress == nil)
        #expect(s.state.helper.triesProblem?.contains("line 3 is not a try record") == true)
    }

    @Test func theTallyLandsInTheState() async throws {
        let p = Probe()
        p.tally.file = "2026-11-06.jsonl"
        p.tally.eraFound = 22
        p.tally.eraNone = 7
        p.tally.gaveUp = 2
        let s = store(p)
        await s.refreshNow(waitForHelper: true)
        #expect(s.state.helper.tally == p.tally)
    }

    @Test func pauseResumeStopReachTheEngineOncePerClick() async {
        let p = Probe()
        let s = store(p)
        s.pause(); s.resume(); s.stopAnalysis()
        #expect(p.pauses == 1 && p.resumes == 1 && p.stops == 1)
    }

    @Test func startTicksAndStopEndsTheLoop() async throws {
        let p = Probe()
        let s = store(p, tick: .milliseconds(20))
        s.start()
        #expect(s.state.openedAt == p.now)
        #expect(p.notes.first == "opened")
        try await Task.sleep(for: .milliseconds(150))
        #expect(s.ticks >= 2, "the loop ticks: \(s.ticks)")
        s.stop()
        let at = s.ticks
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.ticks == at, "stopped: no more ticks")
        #expect(p.notes.last == "closed")
        s.stop()
        #expect(p.notes.filter { $0 == "closed" }.count == 1, "idempotent")
    }
}

// MARK: - Sensors (read the source)

struct RealtimeContentAnalysisSensorTests {

    private let module = ["RealtimeAnalysisState.swift", "MachineCounters.swift", "HelperJournalTally.swift",
                          "RealtimeAnalysisStore.swift", "RealtimeContentAnalysisWindow.swift"]

    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records", "for rec in records",
                                "records.reduce", "records.first", "records.count", "records.contains"]

    @Test func noModelExtensionAndNoRecordsWork() throws {
        for file in module {
            let src = try code(file)
            #expect(!src.contains("extension VideoScanModel"), "rule 12: \(file)")
            for walk in recordsWalks { #expect(!src.contains(walk), "\(file) walks records: `\(walk)`") }
        }
        // The view reads the store only — never the model or the orchestrator.
        let view = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!view.contains("@EnvironmentObject") && !view.contains("orchestrator."), "the view observes one store")
    }

    @Test func theHelpersFilesAreReadAndNeverWritten() throws {
        for file in module {
            let src = try code(file)
            for forbidden in ["EraAttemptStore(", "record(digest", "clear(digest", ".append(lines", "journal.append", "markApplied",
                              "appendRefused", "sealAbandonedTail", "FileHandle(forWritingTo", "write(to:", "writeBlocking",
                              "SELECT ", "INSERT", "UPDATE ", "DELETE", "commit(as"] {
                #expect(!src.contains(forbidden), "\(file) must stay read-only: `\(forbidden)`")
            }
        }
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("AnalysisResultsReport.readAttempts(stateRoot: stateRoot)"), "the try counts through the read-only snapshot")
        #expect(store.contains("EraPlanner.journalDirectory(stateRoot: stateRoot)"), "the journal folder is the helper's own")
        let tally = try code("HelperJournalTally.swift")
        #expect(tally.contains("journal.read(file: newest, from: tally.bytesRead"), "the applier's own reader, incrementally")
    }

    @Test func theKernelAndTheFilesAreReadOffTheMainActor() throws {
        #expect(try code("MachineCounters.swift").contains("actor MachineCounterReader"))
        #expect(try code("HelperJournalTally.swift").contains("actor HelperJournalCursor"))
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("Task.detached(priority: .utility)"), "the helper refresh is a detached task")
        #expect(store.contains("tick: Duration = .milliseconds(500)"), "≤ 2 Hz")
        #expect(store.contains("guard next != state else { return }"), "equality-gated publishes")
    }

    @Test func bothDoorsOpenTheOneWindowAndTheDossierIsTheOneLoader() throws {
        let door = "RealtimeContentAnalysisWindowController.shared.show(model: model, orchestrator: orchestrator, source:"
        #expect(try code("AnalyzePanelView.swift").contains(door + " \"panel\")"), "the Content Analysis panel's Realtime…")
        #expect(try code("MediaFileOperationsWindow.swift").contains(door + " \"mfo-row\")"), "the Analyze row's context menu")
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(window.components(separatedBy: "RealtimeAnalysisStore.production(").count == 2, "one store per window, built once")
        #expect(window.contains("FileDossierView(fileID: output.recordID, loader: loader)"), "the dossier through its view")
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("dossiers: FileDossierLoader.production(model: model)"), "the one dossier door (rule 4)")
        #expect(!window.contains("FileDossierLoader(") && !store.contains("FileDossierLoader("), "never a second loader")
    }

    @Test func pauseAndStopAreThePanelsEngine() throws {
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("AnalyzeRunner(model: model, orchestrator: orchestrator, center: nil)"))
        for call in ["runner.pause(.sceneCaptions)", "runner.resume(.sceneCaptions)", "runner.stop(.sceneCaptions)"] {
            #expect(store.contains(call), "rule 4: \(call)")
        }
        #expect(!store.contains("orchestrator.pause()") && !store.contains("orchestrator.cancel()"), "never a second path to the engine")
    }

    @Test func machineInferenceIsGreyAndBlueAndEraNoneIsNeverAnEra() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(!window.contains(".yellow"), "DECISIONS 2026-11-03: never yellow")
        let start = try #require(window.range(of: "private var helperPane: some View"))
        let end = try #require(window.range(of: "private var helperJournalWords"))
        let helperOnly = String(window[start.lowerBound..<end.lowerBound])
        for colour in [".green", ".red", ".orange", ".cyan", ".purple"] {
            #expect(!helperOnly.contains(colour), "the helper pane is grey and blue only: `\(colour)`")
        }
        let tally = try code("HelperJournalTally.swift")
        #expect(tally.contains("case .eraNone: return \"no usable era\""), "DECISIONS 2026-11-01")
    }

    @Test func theNewCounterIsResetWithTheOthersAndCountedAtBothBankingSites() throws {
        #expect(try code("CaptionOrchestrator+Activity.swift").contains("liveTranscribed = 0"), "resetLiveCounts")
        let dossier = try code("CaptionOrchestrator+Dossier.swift")
        #expect(dossier.components(separatedBy: "markTranscriptBanked(laneID)").count == 3, "the pipelined and the serial path")
        #expect(!dossier.contains("updateLane(laneID, hasTranscript: true)"), "no banking site bypasses the count")
        #expect(dossier.components(separatedBy: "recordID: plan.record.id").count == 3, "both lanes carry the catalog id")
    }
}

// MARK: - Mockups (the real view, rendered from fixtures)

@MainActor
@Suite("Realtime Content Analysis — the view renders each state (mockups)")
struct RealtimeContentAnalysisMockupTests {

    private static func midRun() -> RealtimeAnalysisState.InApp {
        var s = RealtimeAnalysisState.InApp()
        s.phase = .analyzing
        s.currentIndex = 37
        s.total = 100
        s.currentFile = "Holiday_1990_Part2.mov"
        s.etaSeconds = 617
        s.volumePrefix = "/Volumes/Tapes"
        s.captioned = 29; s.transcribed = 22; s.transcriptFailures = 5; s.failed = 1; s.skipped = 7
        let t = Date(timeIntervalSince1970: 1_793_925_000)
        s.lanes = [
            .init(id: UUID(), filename: "Holiday_1990_Part2.mov", path: "/Volumes/Tapes/Holiday_1990_Part2.mov", recordID: UUID(),
                  stage: "MLXVLM", verb: "extracting scenes…", startedAt: t.addingTimeInterval(-6), framesPlanned: 6, clipSeconds: 41,
                  hasCaptions: false, isVideoOnly: false),
            .init(id: UUID(), filename: "Beach_Day_1987.mov", path: "/Volumes/Tapes/Beach_Day_1987.mov", recordID: UUID(),
                  stage: "Whisper", verb: "transcribing audio…", startedAt: t.addingTimeInterval(-19), framesPlanned: 6, clipSeconds: 128,
                  hasCaptions: true, isVideoOnly: false),
        ]
        func out(_ name: String, _ ago: Double, caption: String?, excerpt: String?, scenes: Int, videoOnly: Bool = false) -> RealtimeAnalysisState.Output {
            .init(id: UUID(), filename: name, path: "/Volumes/Tapes/\(name)", recordID: UUID(), syncedAt: t.addingTimeInterval(-ago),
                  vlmSeconds: 8.4, whisperSeconds: excerpt == nil ? nil : 3.1, note: excerpt == nil && !videoOnly ? "transcript failed" : nil,
                  isVideoOnly: videoOnly, hasCaptions: scenes > 0, hasTranscript: excerpt != nil, transcriptFailed: excerpt == nil && !videoOnly,
                  sceneCount: scenes, firstCaption: caption, transcriptExcerpt: excerpt)
        }
        s.recent = [
            out("Birthday_Candles_1992.mov", 12, caption: "a group of people around a table with a cake and lit candles", excerpt: "okay everybody, ready? one, two, three…", scenes: 6),
            out("Garden_Spring_1989.mov", 40, caption: "a person kneeling by flower beds in a backyard, a dog nearby", excerpt: nil, scenes: 6),
            out("Parade_Main_Street.mov", 71, caption: "a marching band on a street lined with people", excerpt: "…here they come…", scenes: 5),
            out("Silent_Super8_Reel3.mov", 95, caption: "a child on a swing in a park", excerpt: nil, scenes: 4, videoOnly: true),
        ]
        return s
    }

    private func render(_ label: String, _ p: Probe, samples: Int) async throws -> CGImage {
        let s = store(p)
        for i in 0..<samples {
            p.machine.cpuBusyPercent = 30 + 30 * sin(Double(i) / 4)
            p.machine.gpuUtilizationPercent = 60 + 35 * sin(Double(i) / 3 + 1)
            p.machine.diskReadMBPerSecond = 120 + 90 * sin(Double(i) / 5 + 2)
            p.now = p.now.addingTimeInterval(0.5)
            await s.refreshNow(waitForHelper: true)
        }
        let renderer = ImageRenderer(content: RealtimeContentAnalysisContent(store: s).panes.frame(width: 900, alignment: .top))
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(label) rendered")
        #expect(image.width == 1800 && image.height > 1000, "\(label): \(image.width)×\(image.height)")
        // Ink on the page: a ScrollView renders blank through ImageRenderer (seen 11/05), so prove pixels, not just a size.
        let ink = Self.inkFraction(image)
        #expect(ink > 0.01, "\(label): \(Int(ink * 1000)) ‰ of the pixels are not background")
        if let dir = ProcessInfo.processInfo.environment["VIDEOSCAN_MOCKUP_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(label).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// The share of pixels that differ from the top-left (background) pixel.
    private static func inkFraction(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else { return 0 }
        let row = image.bytesPerRow
        var ink = 0
        var seen = 0
        let bg = (data[0], data[1], data[2])
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let i = y * row + x * 4
                seen += 1
                if abs(Int(data[i]) - Int(bg.0)) > 24 || abs(Int(data[i + 1]) - Int(bg.1)) > 24 || abs(Int(data[i + 2]) - Int(bg.2)) > 24 { ink += 1 }
            }
        }
        return seen > 0 ? Double(ink) / Double(seen) : 0
    }

    @Test func idle() async throws {
        let p = Probe()
        p.machine = MachineSample(cpuBusyPercent: nil, cpuProblem: MachineSample.firstSample, gpuUtilizationPercent: 3, gpuProblem: nil,
                                  memoryUsedGB: 21.4, memoryTotalGB: 96, memoryProblem: nil, diskReadMBPerSecond: nil, diskProblem: MachineSample.firstSample)
        p.tally.file = "2026-11-06.jsonl"
        _ = try await render("idle", p, samples: 1)
    }

    @Test func midRun() async throws {
        let p = Probe()
        p.inApp = Self.midRun()
        p.enabled = true
        let started = Date(timeIntervalSince1970: 1_793_920_000)
        let era = VideoScanCore.JobProgressSnapshot(id: JobID(), kind: .era, lane: "era", title: "Machine era", subtitle: "", completedUnits: 158,
                                      totalUnits: 402, skippedUnits: 0, failedUnits: 0, state: .running, startedAt: started, finishedAt: nil)
        p.reply = .success(ServiceStatus(processIdentifier: 2098, startedAt: started, backoff: .full, jobs: [era], idleSeconds: 0,
                                         planned: [JobKind.era.rawValue: 244]))
        p.tally.file = "2026-11-06.jsonl"
        p.tally.eraFound = 22; p.tally.eraNone = 7; p.tally.gaveUp = 2; p.tally.other = 131
        p.tally.latest = [
            .init(id: "a", at: 1_793_925_466, kind: .gaveUp, words: "gave up — gave up after 3 tries: 6 of 6 frames would not decode (ffmpeg: ffmpeg exited 0 and wrote no frame)"),
            .init(id: "b", at: 1_793_925_401, kind: .eraFound, words: "era found — early 1990s (1991–1995)"),
            .init(id: "c", at: 1_793_925_380, kind: .eraNone, words: "no usable era"),
            .init(id: "d", at: 1_793_925_322, kind: .eraFound, words: "era found — 1980s (1984–1989)"),
        ]
        p.attempts = .success(EraAttemptSnapshot(entries: Dictionary(uniqueKeysWithValues: (0..<3).map {
            ("\(SeatedApproach.eraA2.signer) d\($0)", attempt(tries: 1, reason: "r")) })))
        _ = try await render("mid-run", p, samples: 40)
    }

    @Test func errorAndUnknown() async throws {
        let p = Probe()
        var s = Self.midRun()
        s.phase = .paused
        s.lanes = []
        s.etaSeconds = nil
        p.inApp = s
        p.enabled = true
        p.reply = .failure(Refusal("XPC: the connection was invalidated (the helper is not running)"))
        p.machine = MachineSample(cpuBusyPercent: 12, cpuProblem: nil, gpuUtilizationPercent: nil,
                                  gpuProblem: "IOAccelerator has no PerformanceStatistics[\"Device Utilization %\"]",
                                  memoryUsedGB: nil, memoryProblem: "host_statistics64 failed", diskReadMBPerSecond: nil,
                                  diskProblem: "the byte counter went backwards (a disk came or went)")
        p.machine.memoryTotalGB = 96
        p.tally.file = "2026-11-06.jsonl"
        p.tally.eraFound = 3; p.tally.unreadable = 2; p.tally.torn = true
        p.attempts = .failure(Refusal("era: the try counts at …/attempts/era.jsonl are unreadable (line 7 is not a try record) — the job is refused rather than give files up or retry them blind"))
        p.journalWords = "Background: 0 journal lines waiting · 2 refused"
        _ = try await render("error-unknown", p, samples: 3)
    }
}
