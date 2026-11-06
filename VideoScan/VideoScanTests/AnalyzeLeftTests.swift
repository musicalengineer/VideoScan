// AnalyzeLeftTests.swift — "88 left to analyze" that Update never touched
// (Rick 2026-11-06) and the Realtime window's "Analyze the N left".
//
// What the 88 were (production shape, a `.backup` copy of the live catalog,
// 17:50): after Detect Duplicates had run, 80 files —
//   * 70 Archived rows with no dossier: 68 Avid MXF copies whose SAME BYTES
//     are flagged needs-reformat on their In Triage copy (decode fails), plus
//     2 archived masters the extractor cannot open. An archived row is
//     read-only to analysis, so the failure was never flagged on it: every
//     batch tried them again, failed, and Content counted them "left";
//   * 10 files the dossier pass analyzed without a transcript (VLM-only
//     stack, or the transcript failed). The batch treats a stamped file as
//     analyzed and never transcribes it again; Content counted Transcribe left.
//
// The fix — ONE rule for the count and the batch (rule 4):
//   * DossierPoolStatus(record, unreadable:) — awaiting reformat when the row
//     OR another copy of the same content (whole-file SHA-256) is flagged; the
//     coverage pass and the batch skip both read it;
//   * Transcribe is covered by a transcript OR the dossier stamp (the batch's
//     own "already analyzed"); the rest is said apart, never "left".
//
// Dimensions (rule 8):
//   LOGIC     the rule, the plan, the store's run (START / steps / OUTCOME / Stop)
//   TRUTH     the count equals what the real batch analyzes (set equality through
//             startCatalogWideDossier); the button's N equals the Content line's N
//   SCALE     the index + projection at 100k rows inside a budget
//   ISOLATION sandboxes, injected sources, no defaults, poisoned evidence (a
//             flagged row with no digest never matches)
//   SENSOR    AnalyzeLeftSensorTests — the window calls the store, the store's
//             step is AnalyzeRunner.runNow, the batch skip reads DossierPoolStatus
//   MEDIA     N/A — no media is decoded (the stub runner stands in); the matrix
//             of stream shapes (A/V, video-only, audio-only, photo) is in the truth table.
// Synthetic names only.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private enum LeftFixtures {
    static func digest(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// Every NON-dossier content analyzer satisfied, so a file is "left" only
    /// for its dossier work (the truth test compares against the dossier batch).
    static func settleOthers(_ r: VideoRecord, digest: String) {
        r.sizeBytes = 100
        r.contentFixity = ContentFixity(digest: digest, byteCount: r.sizeBytes,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: r.sizeBytes, mtimeNs: 0),
                                        computedAt: Date())
        r.audioFingerprint = AudioFingerprintStamp(computedAt: Date(), contentDigest: "sha256:" + digest, sizeBytes: r.sizeBytes,
                                                   outcome: .fingerprinted, analyzedSeconds: 3, complete: true,
                                                   landmarks: 10, bytes: 80)
        r.dupAnalyzedAt = Date()
        r.contentHash = "test-signature-" + digest.prefix(6)
    }

    static func report(_ model: VideoScanModel) -> AnalyzeCoverageReport {
        AnalyzeCoverageCalculator.compute(inputs: AnalyzeCoverageCalculator.project(model.records),
                                          volumes: AnalyzeCoverageCalculator.volumeFacts(model.scanTargets),
                                          mountedRoots: [], scope: AnalysisScope())
    }

    /// The paths the Content count says have at least one counted analysis left.
    static func leftPaths(_ model: VideoScanModel) -> Set<String> {
        let volumes = AnalyzeCoverageCalculator.volumeFacts(model.scanTargets)
        let inputs = AnalyzeCoverageCalculator.project(model.records)
        return Set(inputs.filter {
            AnalyzeCoverageCalculator.compute(inputs: [$0], volumes: volumes, mountedRoots: [], scope: AnalysisScope())
                .contentFiles.remaining > 0
        }.map(\.fullPath))
    }
}

// MARK: - The rule (Part 1: red before the fix)

@MainActor
@Suite("Content left — the count and the batch share one rule (Rick 2026-11-06, 88 left)", .serialized)
struct AnalyzeLeftRuleTests {

    typealias F = DossierAdmissionFixtures
    fileprivate typealias L = LeftFixtures

    /// RED before: the archived copy counted "left" (Scene Captions + OCR)
    /// although its bytes are flagged needs-reformat on the live copy.
    @Test("an archived copy of content flagged needs-reformat elsewhere is not left; it is said apart as cannot-decode")
    func unreadableContentIsNotLeft() throws {
        let sb = try F.Sandbox("left-unreadable"); defer { sb.cleanup() }
        let live = sb.record("test_tape.mxf", stage: .reviewing)
        live.needsReformat = true
        let archived = sb.record("test_tape_copy.mxf", stage: .archived)
        for r in [live, archived] { L.settleOthers(r, digest: L.digest("a")) }
        sb.model.records = [live, archived]

        let report = L.report(sb.model)
        #expect(report.contentFiles.remaining == 0, "left: \(report.contentFiles.remaining)")
        #expect(report.counts(.sceneCaptions).remaining == 0 && report.counts(.ocr).remaining == 0)
        #expect(report.cannotDecode == 2, "both copies are said apart: \(report.cannotDecode)")
        let line = CatalogStatusLinesPolicy.content(report)
        #expect(line.state == .green, "\(line.words)")
        #expect(line.detail.contains(CatalogStatusLinesPolicy.cannotDecodeWords(2)), "\(line.detail)")
    }

    /// RED before: Transcribe counted the stamped file "left" for ever.
    @Test("a file the dossier pass analyzed without a transcript is not left; it is said apart")
    func analyzedWithoutTranscriptIsNotLeft() throws {
        let sb = try F.Sandbox("left-notranscript"); defer { sb.cleanup() }
        let r = sb.record("test_party.mov", stage: .cataloged)
        L.settleOthers(r, digest: L.digest("b"))
        r.dossierProcessedAt = Date()
        r.dossierProcessedBy = "stub-vlm"
        sb.model.records = [r]

        let report = L.report(sb.model)
        #expect(report.counts(.transcribe).remaining == 0, "Transcribe left: \(report.counts(.transcribe).remaining)")
        #expect(report.counts(.transcribe).secondary == 1)
        #expect(report.contentFiles.remaining == 0)
        #expect(CatalogStatusLinesPolicy.content(report).detail.contains(CatalogStatusLinesPolicy.noTranscriptWords(1)))
    }

    /// RED before: the batch decoded (and failed on) the archived copy every pass.
    @Test("the batch skips an archived copy whose bytes are flagged needs-reformat on another copy; an explicit single-file Analyze still tries it")
    func batchSkipsUnreadableContent() async throws {
        let sb = try F.Sandbox("left-batchskip"); defer { sb.cleanup() }
        let live = sb.record("test_tape.mxf", stage: .reviewing)
        live.needsReformat = true
        let archived = sb.record("test_tape_copy.mxf", stage: .archived)
        let fine = sb.record("test_fine.mov", stage: .cataloged)
        for r in [live, archived] { L.settleOthers(r, digest: L.digest("c")) }
        L.settleOthers(fine, digest: L.digest("d"))
        sb.model.records = [live, archived, fine]

        let runner = UnreadableDossierRunner(unreadable: ["test_tape.mxf", "test_tape_copy.mxf"])
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await runner.callCount("test_tape_copy.mxf") == 0, "never decoded by a batch")
        #expect(await runner.callCount("test_fine.mov") == 1)
        #expect(orch.liveSkipNeedsReformat == 2, "both copies skipped as needs-reformat: \(orch.liveSkipNeedsReformat)")

        // Explicit per-file intent still retries it (the needs-reformat rule's own escape).
        _ = await orch.startAnalyzing(volumePrefix: archived.fullPath, model: sb.model, transcriber: nil)
        #expect(await runner.callCount("test_tape_copy.mxf") == 1)
    }

    /// ISOLATION / poisoned evidence: a flagged row with no full digest, or a
    /// digest covering another size, never makes a stranger "unreadable".
    @Test("a flagged row without a usable full digest is never evidence about another file")
    func noDigestNoEvidence() throws {
        let sb = try F.Sandbox("left-nodigest"); defer { sb.cleanup() }
        let flagged = sb.record("test_flagged.mov", stage: .reviewing)
        flagged.needsReformat = true                         // no digest at all
        let shortRead = sb.record("test_short.mov", stage: .reviewing)
        shortRead.needsReformat = true
        shortRead.sizeBytes = 100
        shortRead.contentFixity = ContentFixity(digest: L.digest("e"), byteCount: 50,   // covers another size
                                                stamp: FileIdentityStamp(device: 1, inode: 1, size: 50, mtimeNs: 0))
        let other = sb.record("test_other.mov", stage: .archived)
        L.settleOthers(other, digest: L.digest("e"))
        let index = UnreadableContentIndex(records: [flagged, shortRead, other])
        #expect(index.digests.isEmpty, "\(index.digests.count)")
        #expect(DossierPoolStatus(other, unreadable: index) == .admitted)
        // A dossier on the flagged copy means it WAS decoded: no evidence either.
        let decoded = sb.record("test_decoded.mov", stage: .reviewing)
        decoded.needsReformat = true
        decoded.dossierProcessedAt = Date()
        L.settleOthers(decoded, digest: L.digest("e"))
        #expect(UnreadableContentIndex(records: [decoded, other]).digests.isEmpty)
    }
}

// MARK: - TRUTH: the count equals what Analyze does

@MainActor
@Suite("Content left — truth: the count's files are exactly the files the batch analyzes", .serialized)
struct AnalyzeLeftTruthTests {

    typealias F = DossierAdmissionFixtures
    fileprivate typealias L = LeftFixtures

    @Test("Content's N left == the files startCatalogWideDossier hands the extractor, file for file")
    func countEqualsBatch() async throws {
        let sb = try F.Sandbox("left-truth"); defer { sb.cleanup() }
        var records: [VideoRecord] = []
        func add(_ name: String, _ stage: LifecycleStage, _ c: Character, stream: StreamType = .videoAndAudio,
                 _ shape: (VideoRecord) -> Void = { _ in }) {
            let r = sb.record(name, stage: stage)
            r.streamTypeRaw = stream.rawValue
            L.settleOthers(r, digest: L.digest(c))
            shape(r)
            records.append(r)
        }
        add("test_new.mov", .cataloged, "1")                                          // left, analyzed
        add("test_videoonly.mxf", .reviewing, "2", stream: .videoOnly)                // left, analyzed
        add("test_archived_new.mov", .archived, "3")                                  // left, analyzed (read-only text)
        add("test_done.mov", .cataloged, "4") { $0.dossierProcessedAt = Date(); $0.audioTranscript = "hello"; $0.audioTranscriptDate = Date() }
        add("test_done_notranscript.mov", .reviewing, "5") { $0.dossierProcessedAt = Date() }
        add("test_flagged.mxf", .reviewing, "6") { $0.needsReformat = true }
        add("test_flagged_copy.mxf", .archived, "6")                                  // same bytes as the flagged one
        add("test_junk.mov", .cataloged, "7") { $0.mediaDisposition = .confirmedJunk }
        add("test_drm.m4v", .cataloged, "8") { $0.drmProtected = true }
        add("test_trashed.mov", .trashed, "9")
        add("test_song.mp3", .cataloged, "a", stream: .audioOnly)                      // out of the default scope
        add("test_still.jpg", .cataloged, "b", stream: .videoOnly)                     // a photo: never a candidate
        sb.model.records = records

        let counted = LeftFixtures.leftPaths(sb.model)
        let report = L.report(sb.model)
        #expect(report.contentFiles.remaining == counted.count)

        let stub = StubDossierRunner(modelID: "stub-truth")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)
        let analyzed = Set(await stub.pathsCalled())

        let names = { (s: Set<String>) in s.map { ($0 as NSString).lastPathComponent }.sorted() }
        #expect(counted == analyzed, "count \(names(counted)) vs batch \(names(analyzed))")
        #expect(names(counted) == ["test_archived_new.mov", "test_new.mov", "test_videoonly.mxf"])
        // And after the batch, nothing it could do is left.
        #expect(L.report(sb.model).contentFiles.remaining == 0)
    }

    @Test("the button's N is the Content line's N, and its title says it")
    func buttonNumberIsTheContentNumber() {
        var report = AnalyzeCoverageReport()
        report.computedAt = Date()
        report.contentFiles = AnalyzeCoverageCounts(eligible: 6_218, covered: 6_138)
        report.byCycler[.sceneCaptions] = AnalyzeCoverageCounts(eligible: 3_420, covered: 3_350)
        report.byCycler[.ocr] = AnalyzeCoverageCounts(eligible: 3_420, covered: 3_350)
        report.byCycler[.transcribe] = AnalyzeCoverageCounts(eligible: 2_036, covered: 2_026)
        let plan = AnalyzeLeftPlan.make(report)
        let line = CatalogStatusLinesPolicy.content(report)
        #expect(line.words == "80 left to analyze")
        #expect(plan.files == 80)
        #expect(plan.buttonTitle == "Analyze the 80 left")
        #expect(line.words.hasPrefix(plan.files.formatted() + " "), "the same number on both")

        // A hand-built report with no per-file tally counts pairs on both.
        report.contentFiles = AnalyzeCoverageCounts()
        let pairs = AnalyzeLeftPlan.make(report)
        #expect(CatalogStatusLinesPolicy.content(report).words == "\(pairs.files.formatted()) left to analyze")

        // Nothing left: the button says so and is disabled (the state's rule).
        let empty = AnalyzeLeftPlan.make({ var r = AnalyzeCoverageReport(); r.computedAt = Date(); return r }())
        #expect(empty.isEmpty && empty.buttonTitle == "Nothing left to analyze")
        var state = RealtimeAnalysisState()
        state.left = empty
        #expect(state.showsAnalyzeLeft && !state.canAnalyzeLeft)
    }
}

// MARK: - The plan (pure)

@Suite("Analyze the N left — the plan")
struct AnalyzeLeftPlanTests {

    private func report(_ build: (inout AnalyzeCoverageReport) -> Void) -> AnalyzeCoverageReport {
        var r = AnalyzeCoverageReport()
        r.computedAt = Date()
        build(&r)
        return r
    }

    @Test("one step per analyzer with work, registry order; the dossier engine once per drive that holds its work")
    func stepsPerAnalyzerAndDrive() {
        let r = report { r in
            r.contentFiles = AnalyzeCoverageCounts(eligible: 10, covered: 4)
            r.byCycler[.duplicates] = AnalyzeCoverageCounts(eligible: 10, covered: 8)
            r.byCycler[.sceneCaptions] = AnalyzeCoverageCounts(eligible: 6, covered: 3)
            r.byCycler[.transcribe] = AnalyzeCoverageCounts(eligible: 6, covered: 5)
            r.byCycler[.fileSignatures] = AnalyzeCoverageCounts(eligible: 10, covered: 9)
            r.byVolume[.sceneCaptions] = ["/Volumes/TestB": AnalyzeCoverageCounts(eligible: 3, covered: 1),
                                          "/Volumes/TestA": AnalyzeCoverageCounts(eligible: 3, covered: 2),
                                          "/Volumes/TestDone": AnalyzeCoverageCounts(eligible: 3, covered: 3)]
            r.byVolume[.transcribe] = ["/Volumes/TestC": AnalyzeCoverageCounts(eligible: 1, covered: 0)]
        }
        let plan = AnalyzeLeftPlan.make(r)
        #expect(plan.files == 6)
        #expect(plan.steps == [.init(cycler: .duplicates, volume: nil),
                               .init(cycler: .sceneCaptions, volume: "/Volumes/TestA"),
                               .init(cycler: .sceneCaptions, volume: "/Volumes/TestB"),
                               .init(cycler: .sceneCaptions, volume: "/Volumes/TestC"),
                               .init(cycler: .fileSignatures, volume: nil)])
        #expect(plan.breakdown == "Detect Duplicates 2 · Scene Captions 3 · Transcribe 1 · File Signatures 1")
    }

    @Test("dossier work under no scan target → one catalog-wide step, as Update runs it")
    func otherRootIsCatalogWide() {
        let r = report { r in
            r.contentFiles = AnalyzeCoverageCounts(eligible: 2, covered: 0)
            r.byCycler[.ocr] = AnalyzeCoverageCounts(eligible: 2, covered: 0)
            r.byVolume[.ocr] = [AnalyzeCoverageCalculator.otherRoot: AnalyzeCoverageCounts(eligible: 1, covered: 0),
                                "/Volumes/TestA": AnalyzeCoverageCounts(eligible: 1, covered: 0)]
        }
        #expect(AnalyzeLeftPlan.make(r).steps == [.init(cycler: .sceneCaptions, volume: nil)])
    }

    @Test("a report not counted yet plans nothing")
    func notCountedYet() {
        var r = AnalyzeCoverageReport()
        r.byCycler[.ocr] = AnalyzeCoverageCounts(eligible: 2, covered: 0)
        #expect(AnalyzeLeftPlan.make(r).isEmpty)
    }

    @Test("scale: the plan from a 100k-file report with 500 drives stays O(analyzers + drives)")
    func scale() {
        let r = report { r in
            r.contentFiles = AnalyzeCoverageCounts(eligible: 100_000, covered: 50_000)
            r.byCycler[.sceneCaptions] = AnalyzeCoverageCounts(eligible: 100_000, covered: 50_000)
            var vols: [String: AnalyzeCoverageCounts] = [:]
            for i in 0..<500 { vols["/Volumes/Test\(i)"] = AnalyzeCoverageCounts(eligible: 200, covered: 100) }
            r.byVolume[.sceneCaptions] = vols
        }
        let start = Date()
        for _ in 0..<20 { _ = AnalyzeLeftPlan.make(r) }
        #expect(Date().timeIntervalSince(start) < 1.0, "20 plans over 500 drives")
        #expect(AnalyzeLeftPlan.make(r).steps.count == 500)
    }
}

// MARK: - SCALE: the shared rule at 100k rows

@MainActor
@Suite("Content left — scale: the unreadable index and the projection at 100k rows")
struct AnalyzeLeftScaleTests {

    @Test("100k rows (1k flagged, 1k archived copies of them): index + projection + compute inside the budget")
    func hundredThousand() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Users/test/Movies/test_\(i).mov"
            r.filename = "test_\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.sizeBytes = 100
            let d = String(format: "%064lx", i < 2_000 ? i % 1_000 : i)
            r.contentFixity = ContentFixity(digest: d, byteCount: 100, stamp: FileIdentityStamp(device: 1, inode: UInt64(i), size: 100, mtimeNs: 0))
            r.lifecycleStage = i < 1_000 ? .reviewing : (i < 2_000 ? .archived : .cataloged)
            r.needsReformat = i < 1_000
            records.append(r)
        }
        let start = Date()
        let inputs = AnalyzeCoverageCalculator.project(records)
        let report = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [], mountedRoots: [], scope: AnalysisScope())
        let seconds = Date().timeIntervalSince(start)
        #expect(seconds < 10, "Debug budget: \(seconds) s")
        #expect(report.cannotDecode == 2_000, "\(report.cannotDecode)")
        #expect(report.counts(.sceneCaptions).remaining == 98_000)
    }
}

// MARK: - The store: Analyze the N left (Part 2)

private final class LeftProbe: @unchecked Sendable {
    var notes: [String] = []
    var steps: [AnalyzeLeftPlan.Step] = []
    var running: Set<AnalyzeCycler> = []
    var dequeued: [String] = []
    var stops = 0
    var inApp = RealtimeAnalysisState.InApp()
    var plan = AnalyzeLeftPlan()
    var now = Date(timeIntervalSince1970: 1_793_925_000)
}

@MainActor
private func leftStore(_ p: LeftProbe) -> RealtimeAnalysisStore {
    let sources = RealtimeAnalysisStore.Sources(
        inApp: { p.inApp },
        helperEnabled: { false },
        helperStatus: { .failure(Refusal("off")) },
        journal: { HelperJournalTally() },
        machine: { MachineSample(cpuBusyPercent: nil, cpuProblem: "test", gpuUtilizationPercent: nil, gpuProblem: "test",
                                 memoryUsedGB: nil, memoryTotalGB: 0, memoryProblem: "test", diskReadMBPerSecond: nil, diskProblem: "test") },
        journalWords: { nil },
        note: { p.notes.append($0) },
        pause: {},
        resume: {},
        stop: { p.stops += 1 },
        seatedSigner: SeatedApproach.eraA2.signer,
        now: { p.now },
        left: { p.plan },
        runStep: { p.steps.append($0) },
        isRunning: { p.running.contains($0) },
        dequeue: { p.dequeued.append($0) })
    return RealtimeAnalysisStore(sources: sources)
}

private func plan80() -> AnalyzeLeftPlan {
    var r = AnalyzeCoverageReport()
    r.computedAt = Date()
    r.contentFiles = AnalyzeCoverageCounts(eligible: 100, covered: 20)
    r.byCycler[.duplicates] = AnalyzeCoverageCounts(eligible: 100, covered: 99)
    r.byCycler[.sceneCaptions] = AnalyzeCoverageCounts(eligible: 90, covered: 10)
    r.byVolume[.sceneCaptions] = ["/Volumes/TestA": AnalyzeCoverageCounts(eligible: 40, covered: 0),
                                  "/Volumes/TestB": AnalyzeCoverageCounts(eligible: 50, covered: 10)]
    return AnalyzeLeftPlan.make(r)
}

@MainActor
@Suite("Analyze the N left — the store starts the panel's engines, logs START / OUTCOME, and Stop means stop", .serialized)
struct AnalyzeLeftStoreTests {

    @Test("pressing it starts every step once through runStep, with ONE START line naming N")
    func startsEachStepOnce() async {
        let p = LeftProbe(); p.plan = plan80()
        let s = leftStore(p)
        await s.refreshNow()
        #expect(s.state.canAnalyzeLeft && s.state.left.buttonTitle == "Analyze the 80 left")
        let started = s.analyzeTheLeft()
        #expect(started == p.plan)
        #expect(p.steps == p.plan.steps, "\(p.steps)")
        #expect(p.notes.filter { $0.contains("— START —") }.count == 1)
        #expect(p.notes.contains { $0.contains("START — 80 file(s) left") && $0.contains("(realtime window)") })
        #expect(s.state.leftRunActive && !s.state.showsAnalyzeLeft, "hidden while its run is on")
        // A second press while running starts nothing.
        _ = s.analyzeTheLeft()
        #expect(p.steps.count == p.plan.steps.count)
        #expect(p.notes.last?.contains("not started") == true)
    }

    @Test("refused and logged when nothing is left or an engine is already running")
    func refusals() async {
        let p = LeftProbe()
        let s = leftStore(p)
        await s.refreshNow()
        #expect(!s.state.canAnalyzeLeft)
        _ = s.analyzeTheLeft()
        #expect(p.steps.isEmpty && p.notes.last?.contains("nothing left to analyze") == true)

        p.plan = plan80()
        p.running = [.sceneCaptions]                      // a pass started elsewhere
        await s.refreshNow()
        #expect(!s.state.showsAnalyzeLeft)
        _ = s.analyzeTheLeft()
        #expect(p.steps.isEmpty && p.notes.last?.contains("already running") == true)

        p.running = []
        p.inApp.phase = .analyzing                       // the window's own engine is on
        await s.refreshNow()
        #expect(!s.state.showsAnalyzeLeft)
    }

    @Test("ONE OUTCOME line once every engine it started has been idle for the settle time")
    func outcomeWhenIdle() async {
        let p = LeftProbe(); p.plan = plan80()
        let s = leftStore(p)
        await s.refreshNow()
        _ = s.analyzeTheLeft()
        p.running = [.sceneCaptions]
        p.now = p.now.addingTimeInterval(1); await s.refreshNow()
        p.now = p.now.addingTimeInterval(60); await s.refreshNow()
        #expect(!p.notes.contains { $0.contains("OUTCOME") }, "still running")
        p.running = []
        p.now = p.now.addingTimeInterval(1); await s.refreshNow()
        #expect(!p.notes.contains { $0.contains("OUTCOME") }, "inside the settle window (a queue hand-off)")
        p.now = p.now.addingTimeInterval(RealtimeAnalysisStore.settleSeconds); await s.refreshNow()
        #expect(p.notes.filter { $0.contains("— OUTCOME —") }.count == 1)
        #expect(p.notes.last?.contains("80 were left at START") == true)
        #expect(!s.state.leftRunActive && s.state.showsAnalyzeLeft)
        p.now = p.now.addingTimeInterval(10); await s.refreshNow()
        #expect(p.notes.filter { $0.contains("OUTCOME") }.count == 1, "once")
    }

    @Test("Stop during the run stops the engine AND takes this run's still-queued drives out of the queue")
    func stopMeansStop() async {
        let p = LeftProbe(); p.plan = plan80()
        let s = leftStore(p)
        await s.refreshNow()
        _ = s.analyzeTheLeft()
        s.stopAnalysis()
        #expect(p.stops == 1)
        #expect(p.dequeued == ["/Volumes/TestA", "/Volumes/TestB"])
        // Outside a run, Stop is the plain Stop.
        let q = LeftProbe()
        let t = leftStore(q)
        t.stopAnalysis()
        #expect(q.stops == 1 && q.dequeued.isEmpty)
    }
}

// MARK: - Sensors (read the source)

struct AnalyzeLeftSensorTests {

    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    @Test("the window's button calls the store; the store's step is AnalyzeRunner.runNow (no second path to an engine)")
    func theWindowCallsTheRunner() throws {
        let window = try code("RealtimeContentAnalysisWindow.swift")
        #expect(window.contains("Button { store.analyzeTheLeft() }"))
        #expect(window.contains(".disabled(!state.canAnalyzeLeft)"))
        let store = try code("RealtimeAnalysisStore.swift")
        #expect(store.contains("runStep: { step in runner.runNow(step.cycler, volume: step.volume, source: Self.source) }"))
        for second in ["enqueueAnalyze(", "startAnalyzing(", "startCatalogWideDossier(", "analyzeDuplicates(",
                       "startFullHashBackfill(", "startAudioFingerprintBackfill(", "runContentHashBackfill("] {
            #expect(!store.contains(second), "rule 4: the store never starts an engine itself: `\(second)`")
        }
        #expect(store.contains("AnalyzeLeftPlan.make(model?.analyzeCoverageSnapshot.report"), "N is the cached report's (O(1), no records walk)")
    }

    @Test("the batch skip and both coverage counts read DossierPoolStatus with the unreadable index")
    func oneRule() throws {
        let steps = try code("CaptionOrchestrator+DossierSteps.swift")
        #expect(steps.contains("DossierPoolStatus(record, unreadable: dossierUnreadable) == .awaitingReformat"))
        #expect(!steps.contains("dossierRetriesNeedsReformat, record.needsReformat"), "the old private rule is gone")
        #expect(try code("AnalyzeCoverage.swift").contains("DossierPoolStatus(r, unreadable: unreadable)"))
        #expect(try code("DossierDashboardView+Coverage.swift").contains("DossierPoolStatus(r, unreadable: unreadable)"))
        #expect(try code("CaptionOrchestrator+Dossier.swift").contains("dossierUnreadable = retryNeedsReformat ? .none : UnreadableContentIndex(records: model.records)"))
    }
}
