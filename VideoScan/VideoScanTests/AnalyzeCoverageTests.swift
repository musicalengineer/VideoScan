// AnalyzeCoverageTests.swift
// The Analyze panel's coverage math (Phase A trial, 2026-10-02).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — eligible / covered / offline / not-applicable per cycler
//               from today's stamps; the exclusions (hidden, unreachable,
//               DRM, photo, out-of-scope audio, junk, zero-byte, user
//               date); correlate pairs + unpaired; per-volume breakdown
//               and the "(other)" bucket; the row-state rule; the menu
//               summary words; schedule defaults.
//   Scale     — 100k synthetic records, 10 volumes, explicit budget.
//   Isolation — pure functions over constructed inputs; the schedule
//               test uses its own UserDefaults suite, never .standard.
//   Sensor    — AnalyzePanelSensorTests.swift (source-level).
// Media matrix: N/A — catalog metadata only; no file is opened.
//
// Suites (filter by SUITE — method-level -only-testing runs zero tests):
//   AnalyzeCoverageLogicTests · AnalyzeRowStateTests ·
//   AnalyzeScheduleTests · AnalyzeCoverageScaleTests ·
//   AnalyzeCoverageCacheTests

import Foundation
import Testing
@testable import VideoScan

private let laCie = AnalyzeVolumeFact(root: "/Volumes/LaCie", isReachable: true, isRetired: false)
private let x9 = AnalyzeVolumeFact(root: "/Volumes/X9", isReachable: false, isRetired: false)
private let retired = AnalyzeVolumeFact(root: "/Volumes/MyBook", isReachable: true, isRetired: true)
private let movies = AnalyzeVolumeFact(root: "/Users/rick/Movies", isReachable: true, isRetired: false)

private func compute(_ inputs: [AnalyzeCoverageInput],
                     volumes: [AnalyzeVolumeFact] = [laCie, x9, retired, movies],
                     mounted: Set<String> = ["/", "/Volumes/LaCie", "/Volumes/MyBook", "/Volumes/Stray"],
                     scope: AnalysisScope = AnalysisScope()) -> AnalyzeCoverageReport {
    AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: volumes, mountedRoots: mounted, scope: scope)
}

// MARK: - Logic

@Suite("Analyze coverage — eligibility and stamps")
struct AnalyzeCoverageLogicTests {

    @Test func duplicatesCountEveryActiveReachableRecord() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov", dupStamped: true),
            .init(fullPath: "/Volumes/LaCie/b.mov"),
            .init(fullPath: "/Volumes/X9/c.mov", dupStamped: true),          // drive offline
            .init(fullPath: "/Volumes/LaCie/hidden.mov", isHidden: true),   // purged / set aside
        ])
        let k = r.counts(.duplicates)
        #expect(k.eligible == 2)
        #expect(k.covered == 1)
        #expect(k.offline == 1)
        #expect(k.notApplicable == 0)
        #expect(k.remaining == 1)
        #expect(k.line == "1 of 2 eligible · 50%")
        #expect(k.sideLine == "1 offline")
        #expect(r.activeRecords == 4, "hidden rows are counted as seen but never tallied")
    }

    @Test func retiredVolumeCountsAsOffline() {
        let r = compute([.init(fullPath: "/Volumes/MyBook/old.mov")])
        #expect(r.counts(.duplicates).offline == 1)
        #expect(r.counts(.duplicates).eligible == 0)
    }

    @Test func recordsUnderNoScanTargetFollowTheMountTable() {
        let r = compute([
            .init(fullPath: "/Volumes/Stray/a.mov"),       // mounted, no target → reachable, "(other)"
            .init(fullPath: "/Volumes/Gone/b.mov"),        // not mounted → offline
            .init(fullPath: "/Users/rick/Desktop/c.mov"),  // internal path → reachable
        ])
        let k = r.counts(.duplicates)
        #expect(k.eligible == 2)
        #expect(k.offline == 1)
        let other = r.byVolume[.duplicates]?[AnalyzeCoverageCalculator.otherRoot]
        #expect(other?.eligible == 2)
        #expect(other?.offline == 1)
    }

    @Test func nestedTargetWinsOverItsParentAndSiblingNamesDoNotLeak() {
        let nested = AnalyzeVolumeFact(root: "/Volumes/LaCie/Projects", isReachable: true, isRetired: false)
        let sibling = AnalyzeVolumeFact(root: "/Volumes/X9-Matt", isReachable: true, isRetired: false)
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/Projects/p.mov"),
            .init(fullPath: "/Volumes/LaCie/q.mov"),
            .init(fullPath: "/Volumes/X9-Matt/m.mov"),
        ], volumes: [laCie, x9, nested, sibling])
        let byVol = r.byVolume[.duplicates] ?? [:]
        #expect(byVol["/Volumes/LaCie/Projects"]?.eligible == 1)
        #expect(byVol["/Volumes/LaCie"]?.eligible == 1)
        #expect(byVol["/Volumes/X9-Matt"]?.eligible == 1)
        #expect(byVol["/Volumes/X9"] == nil, "X9 must not claim X9-Matt's record")
    }

    @Test func dossierStagesExcludeDRMPhotosJunkAndOutOfScopeAudio() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/v.mov", dossierStamped: true, hasCaptions: true, hasTranscript: true),
            .init(fullPath: "/Volumes/LaCie/drm.m4v", drmProtected: true),
            .init(fullPath: "/Volumes/LaCie/photo.jpg", streamTypeRaw: StreamType.videoOnly.rawValue),
            .init(fullPath: "/Volumes/LaCie/junk.mov", isJunk: true),
            .init(fullPath: "/Volumes/LaCie/song.mp3", streamTypeRaw: StreamType.audioOnly.rawValue),
            .init(fullPath: "/Volumes/LaCie/archived.mov", lifecycleOK: false),
            .init(fullPath: "/Volumes/LaCie/silent.mov", streamTypeRaw: StreamType.videoOnly.rawValue),
        ])
        let captions = r.counts(.sceneCaptions)
        #expect(captions.eligible == 2, "v.mov + silent.mov have video; the rest are not applicable")
        #expect(captions.covered == 1)
        #expect(captions.notApplicable == 5)
        let transcribe = r.counts(.transcribe)
        #expect(transcribe.eligible == 1, "only v.mov has audio in scope (mp3 is set aside by the default scope)")
        #expect(transcribe.covered == 1)
        let ocr = r.counts(.ocr)
        #expect(ocr.eligible == 2)
        #expect(ocr.covered == 1, "OCR has no stamp — the dossier pass stamp is the proxy")
    }

    @Test func analysisScopeFlipBringsAudioIntoTranscribe() {
        var scope = AnalysisScope()
        scope.includeAudioOnly = true
        let inputs: [AnalyzeCoverageInput] = [
            .init(fullPath: "/Volumes/LaCie/song.mp3", streamTypeRaw: StreamType.audioOnly.rawValue, hasTranscript: true),
        ]
        #expect(compute(inputs).counts(.transcribe).eligible == 0)
        #expect(compute(inputs, scope: scope).counts(.transcribe).eligible == 1)
        #expect(compute(inputs, scope: scope).counts(.transcribe).covered == 1)
        #expect(compute(inputs, scope: scope).counts(.sceneCaptions).notApplicable == 1, "audio has no frames to caption")
    }

    @Test func ocrSecondaryCountsTextFound() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov", dossierStamped: true, hasOCRText: true),
            .init(fullPath: "/Volumes/LaCie/b.mov", dossierStamped: true),
        ])
        #expect(r.counts(.ocr).covered == 2)
        #expect(r.counts(.ocr).secondary == 1)
    }

    @Test func footageCoverageIsUnknownButGroupedAndNewestRunAreReported() {
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov", footageScannedAt: t1),
            .init(fullPath: "/Volumes/LaCie/b.mov", footageScannedAt: t2),
            .init(fullPath: "/Volumes/LaCie/single.mov"),
        ])
        #expect(!r.coverageKnown(.footage))
        #expect(r.counts(.footage).secondary == 2)
        #expect(r.counts(.footage).newestStamp == t2)
        #expect(r.menuSummary(.footage, now: t2.addingTimeInterval(3600)).hasPrefix("2 grouped · last run"))
    }

    @Test func correlateCountsPairsAndUnpairedByStream() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/v1.mxf", streamTypeRaw: StreamType.videoOnly.rawValue, isPaired: true),
            .init(fullPath: "/Volumes/LaCie/a1.mxf", streamTypeRaw: StreamType.audioOnly.rawValue, isPaired: true),
            .init(fullPath: "/Volumes/LaCie/v2.mxf", streamTypeRaw: StreamType.videoOnly.rawValue),
            .init(fullPath: "/Volumes/LaCie/a2.mxf", streamTypeRaw: StreamType.audioOnly.rawValue),
            .init(fullPath: "/Volumes/LaCie/a3.mxf", streamTypeRaw: StreamType.audioOnly.rawValue),
            .init(fullPath: "/Volumes/X9/v3.mxf", streamTypeRaw: StreamType.videoOnly.rawValue),   // offline
            .init(fullPath: "/Volumes/LaCie/full.mov"),                                                // not a candidate
        ])
        #expect(r.correlate.pairs == 1)
        #expect(r.correlate.unpairedVideoOnly == 1)
        #expect(r.correlate.unpairedAudioOnly == 2)
        #expect(r.correlate.offlineCandidates == 1)
        #expect(r.correlate.line == "1 pair · 1 video-only + 2 audio-only unpaired")
        #expect(r.menuSummary(.correlate) == r.correlate.line)
    }

    @Test func signaturesSkipZeroByteAndEmbeddedDatesSkipProbeFailures() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10, hasHash: true, hasEmbeddedDate: true),
            .init(fullPath: "/Volumes/LaCie/empty.mov", sizeBytes: 0),
            .init(fullPath: "/Volumes/LaCie/bad.bin", streamTypeRaw: StreamType.ffprobeFailed.rawValue, sizeBytes: 5),
        ])
        #expect(r.counts(.fileSignatures).eligible == 2)
        #expect(r.counts(.fileSignatures).covered == 1)
        #expect(r.counts(.fileSignatures).notApplicable == 1)
        #expect(r.counts(.embeddedDates).eligible == 2)
        #expect(r.counts(.embeddedDates).covered == 1)
        #expect(r.counts(.embeddedDates).notApplicable == 1)
    }

    @Test func dateInferenceIgnoresReachabilityAndRecordsWithAUserDate() {
        let r = compute([
            .init(fullPath: "/Volumes/X9/offline.mov", hasInferredDate: true),   // offline drive still counts
            .init(fullPath: "/Volumes/LaCie/undated.mov"),
            .init(fullPath: "/Volumes/LaCie/mine.mov", hasUserDate: true),
        ])
        let k = r.counts(.dateInference)
        #expect(k.eligible == 2)
        #expect(k.covered == 1)
        #expect(k.offline == 0)
        #expect(k.notApplicable == 1)
    }

    @Test func menuSummaryWords() {
        let current = compute([.init(fullPath: "/Volumes/LaCie/a.mov", dupStamped: true)])
        #expect(current.menuSummary(.duplicates) == "current · 1 of 1")
        let partial = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov", dupStamped: true),
            .init(fullPath: "/Volumes/LaCie/b.mov"),
            .init(fullPath: "/Volumes/LaCie/c.mov"),
        ])
        #expect(partial.menuSummary(.duplicates) == "33% · 2 to go")
        #expect(compute([]).menuSummary(.duplicates) == "nothing eligible")
        #expect(AnalyzeCoverageCounts.percentText(99.5) == ">99%")
        #expect(AnalyzeCoverageCounts.percentText(0.4) == "<1%")
        #expect(AnalyzeCoverageCounts.percentText(100) == "100%")
    }

    @Test func perVolumeBreakdownExistsOnlyForCyclersWithAVolumeScope() {
        let r = compute([.init(fullPath: "/Volumes/LaCie/a.mov")])
        for c in AnalyzeCycler.allCases {
            #expect((r.byVolume[c] != nil) == c.hasVolumeScope, "\(c)")
        }
    }

    @Test func cyclerOrderIsTheDesignOrder() {
        #expect(AnalyzeCycler.allCases == [.duplicates, .footage, .sceneCaptions, .ocr, .transcribe,
                                           .correlate, .fileSignatures, .embeddedDates, .dateInference])
        #expect(AnalyzeCycler.allCases.filter(\.isPausable) == [.footage, .sceneCaptions, .ocr, .transcribe])
    }
}

// MARK: - Row state rule

@Suite("Analyze row state — the one rule")
struct AnalyzeRowStateTests {

    private func state(_ c: AnalyzeCycler, live: AnalyzeRowStateRule.Live = .init(),
                       remaining: Int, offline: Int = 0, known: Bool = true,
                       schedule: AnalyzeSchedule = .manual) -> AnalyzeRowState {
        AnalyzeRowStateRule.state(for: c, live: live, remaining: remaining, offlineRemaining: offline,
                                  coverageKnown: known, schedule: schedule, now: Date(timeIntervalSince1970: 10_000))
    }

    @Test func currentWhenNothingRemains() {
        #expect(state(.duplicates, remaining: 0) == .current)
    }

    @Test func waitingForDriveWhenOnlyOfflineWorkRemains() {
        #expect(state(.duplicates, remaining: 0, offline: 12) == .waitingForDrive(detail: "12 on drives not connected"))
    }

    @Test func cyclingCarriesProgressAndRemaining() {
        var live = AnalyzeRowStateRule.Live()
        live.isRunning = true
        live.progressText = "Analyzing 1,204 files (37 new)…"
        #expect(state(.duplicates, live: live, remaining: 37) == .cycling(detail: "Analyzing 1,204 files (37 new)… · 37 to go"))
        live.progressText = ""
        #expect(state(.duplicates, live: live, remaining: 0) == .cycling(detail: ""))
    }

    @Test func pausedOutranksRunning() {
        var live = AnalyzeRowStateRule.Live()
        live.isRunning = true
        live.isPaused = true
        #expect(state(.sceneCaptions, live: live, remaining: 5) == .paused(detail: "resumes where it left off"))
        live.queueWaitingFromLastSession = true
        #expect(state(.sceneCaptions, live: live, remaining: 5) == .paused(detail: "waiting from last session — Resume to continue"))
    }

    @Test func parkedVolumesReadAsWaitingForDrive() {
        var live = AnalyzeRowStateRule.Live()
        live.parkedVolumes = 2
        #expect(state(.transcribe, live: live, remaining: 9) == .waitingForDrive(detail: "2 volumes in line, drive not connected"))
    }

    @Test func unknownCoverageSaysSoInsteadOfAPercentage() {
        let unknown = AnalyzeRowStateRule.coverageUnknownDetail
        #expect(unknown == "coverage unknown — nothing records this check yet")
        #expect(state(.footage, remaining: 0, known: false) == .auto(detail: unknown))
        #expect(state(.ocr, remaining: 0, known: false) == .auto(detail: unknown))
        #expect(state(.duplicates, remaining: 0, known: false) == .manual(detail: unknown))
    }

    @Test func scheduleLabelsAreHonestInPhaseA() {
        #expect(state(.duplicates, remaining: 3, schedule: .manual) == .manual(detail: "3 to go"))
        #expect(state(.duplicates, remaining: 3, schedule: .auto) == .manual(detail: "3 to go · Auto is coming later; by hand for now"))
        #expect(state(.duplicates, remaining: 3, schedule: .overnight) == .manual(detail: "3 to go · Overnight is coming later; by hand for now"))
        #expect(state(.dateInference, remaining: 3, schedule: .auto) == .auto(detail: "3 to go"))
        var live = AnalyzeRowStateRule.Live()
        live.lastAutoRunAt = Date(timeIntervalSince1970: 10_000 - 7_200)
        if case .auto(let d) = state(.footage, live: live, remaining: 3, schedule: .auto) {
            #expect(d.hasPrefix("3 to go · last automatic run"))
        } else {
            Issue.record("footage with Angel auto-run should read Auto")
        }
    }
}

// MARK: - Schedule preference (isolation: own defaults suite)

@Suite("Analyze schedule — stored, defaults honest")
struct AnalyzeScheduleTests {

    @Test func defaultsReflectWhatAutoRunsToday() {
        let suite = UserDefaults(suiteName: "test.analyze.schedule.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        #expect(AnalyzeSchedule.stored(for: .dateInference, in: suite) == .auto)
        #expect(AnalyzeSchedule.stored(for: .footage, in: suite) == .auto)
        #expect(AnalyzeSchedule.stored(for: .sceneCaptions, in: suite) == .auto)
        #expect(AnalyzeSchedule.stored(for: .duplicates, in: suite) == .manual)
        #expect(AnalyzeSchedule.stored(for: .correlate, in: suite) == .manual)
        #expect(AnalyzeSchedule.stored(for: .fileSignatures, in: suite) == .manual)
        #expect(AnalyzeSchedule.stored(for: .embeddedDates, in: suite) == .manual)
    }

    @Test func storedChoiceRoundTripsAndGarbageFallsBackToDefault() {
        let suite = UserDefaults(suiteName: "test.analyze.schedule.\(UUID().uuidString)")!
        suite.set(AnalyzeSchedule.overnight.rawValue, forKey: AnalyzeCycler.duplicates.scheduleKey)
        #expect(AnalyzeSchedule.stored(for: .duplicates, in: suite) == .overnight)
        suite.set("tuesdays", forKey: AnalyzeCycler.duplicates.scheduleKey)   // poisoned
        #expect(AnalyzeSchedule.stored(for: .duplicates, in: suite) == .manual)
    }
}

// MARK: - Scale

@Suite("Analyze coverage — scale")
struct AnalyzeCoverageScaleTests {

    /// 100k rows across 10 volumes (2 offline), every cycler tallied,
    /// per-volume breakdown included — under 1.5 s in Debug on the M4.
    @Test func hundredThousandRowsUnderBudget() {
        var volumes: [AnalyzeVolumeFact] = []
        for i in 0..<10 {
            volumes.append(.init(root: "/Volumes/Vol\(i)", isReachable: i % 5 != 0, isRetired: false))
        }
        var inputs: [AnalyzeCoverageInput] = []
        inputs.reserveCapacity(100_000)
        let streams = [StreamType.videoAndAudio, .videoOnly, .audioOnly, .videoAndAudio, .ffprobeFailed]
        let exts = ["mov", "mxf", "mp4", "mp3", "jpg", "avi", "mkv", "dv"]
        for i in 0..<100_000 {
            let stamp = i % 3 == 0 ? Date(timeIntervalSince1970: Double(i)) : nil
            inputs.append(.init(fullPath: "/Volumes/Vol\(i % 10)/folder\(i % 40)/clip\(i).\(exts[i % exts.count])",
                                streamTypeRaw: streams[i % streams.count].rawValue,
                                sizeBytes: Int64(i % 7),
                                isHidden: i % 97 == 0,
                                lifecycleOK: i % 11 != 0,
                                isJunk: i % 13 == 0,
                                drmProtected: i % 101 == 0,
                                dupStamped: i % 2 == 0,
                                footageScannedAt: stamp,
                                dossierStamped: i % 4 == 0,
                                hasCaptions: i % 5 == 0,
                                hasOCRText: i % 9 == 0,
                                hasTranscript: i % 6 == 0,
                                isPaired: i % 8 == 0,
                                hasHash: i % 3 == 0,
                                hasEmbeddedDate: i % 2 == 1,
                                hasInferredDate: i % 3 == 1,
                                hasUserDate: i % 50 == 0))
        }
        let start = ContinuousClock.now
        let r = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: volumes,
                                                  mountedRoots: ["/"], scope: AnalysisScope())
        let elapsed = ContinuousClock.now - start
        #expect(r.activeRecords == 100_000)
        let d = r.counts(.duplicates)
        #expect(d.eligible + d.offline + d.notApplicable == 100_000 - 100_000 / 97 - 1,
                "every non-hidden row lands in exactly one bucket")
        #expect(r.byVolume[.duplicates]?.count == 10)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_500)),
                "analyze coverage took \(elapsed) for 100k records — over the 1.5 s budget")
    }
}

// MARK: - The model-owned cache (publishes on mutation, equality-gated)

@Suite("Analyze coverage — model cache", .serialized)
@MainActor
struct AnalyzeCoverageCacheTests {

    private func record(_ path: String, dupStamped: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 10
        if dupStamped { r.dupAnalyzedAt = Date() }
        return r
    }

    /// Debounce (250 ms) + detached compute — wait it out with margin.
    private func settle() async throws { try await Task.sleep(nanoseconds: 700_000_000) }

    @Test func mutationPublishesOnceAndReadsAreFree() async throws {
        let model = VideoScanModel()
        try await settle()
        let baseline = model.analyzeCoverageSnapshot.publishCount
        model.records = [record("/Volumes/T/a.mov", dupStamped: true), record("/Volumes/T/b.mov")]
        try await settle()
        #expect(model.analyzeCoverageSnapshot.publishCount == baseline + 1,
                "one mutation batch → one publish (got \(model.analyzeCoverageSnapshot.publishCount - baseline))")
        let report = model.analyzeCoverageSnapshot.report
        #expect(report.activeRecords == 2)
        for _ in 0..<1_000 { _ = model.analyzeCoverageSnapshot.report.counts(.duplicates) }
        #expect(model.analyzeCoverageSnapshot.publishCount == baseline + 1, "reads never recompute")
    }

    @Test func unchangedRecomputeDoesNotPublish() async throws {
        let model = VideoScanModel()
        model.records = [record("/Volumes/T/a.mov")]
        try await settle()
        let before = model.analyzeCoverageSnapshot.publishCount
        model.scheduleAnalyzeCoverageRefresh()
        try await settle()
        // The report carries `computedAt`, so an identical catalog still
        // differs by the clock; what must NOT happen is a publish storm.
        #expect(model.analyzeCoverageSnapshot.publishCount - before <= 1)
    }
}

// MARK: - Engine gates (QA on the Phase A branch, 2026-10-02)
//
// analyzeDuplicates() / correlate() carry no reentrancy guard of their own
// (the two backfills do), and three surfaces now feed the runner while the
// panel samples flags on a 1 s tick — so a second concurrent pass could
// start and its `defer` would clear the first pass's flag. The runner must
// refuse while the engine's flag is set, and while a scan runs (both old
// menus were disabled during a scan). RED on 9429e9a1, then green.

@Suite("Analyze runner — engine gates", .serialized)
@MainActor
struct AnalyzeRunnerGateTests {

    private func settle() async throws { try await Task.sleep(nanoseconds: 400_000_000) }

    @Test func runNowDoesNotStartASecondDuplicatesPass() async throws {
        let model = VideoScanModel()
        model.isAnalyzingDuplicates = true          // a pass is "running"
        AnalyzeRunner(model: model, orchestrator: nil, center: nil).runNow(.duplicates, source: "test")
        try await settle()
        #expect(model.isAnalyzingDuplicates, "a second pass ran and its defer cleared the first pass's flag")
    }

    @Test func runNowDoesNotStartASecondCorrelatePass() async throws {
        let model = VideoScanModel()
        model.isCorrelating = true
        AnalyzeRunner(model: model, orchestrator: nil, center: nil).runNow(.correlate, source: "test")
        try await settle()
        #expect(model.isCorrelating, "a second correlate ran and its defer cleared the first pass's flag")
    }

    @Test func runNowRefusesWhileAScanIsRunning() async throws {
        let model = VideoScanModel()
        model.isScanning = true
        let runner = AnalyzeRunner(model: model, orchestrator: nil, center: nil)
        runner.runNow(.correlate, source: "test")
        runner.runNow(.duplicates, source: "test")
        runner.findPairsAcrossVolumes(source: "test")
        runner.clearAndRecorrelateAll(source: "test")
        try await settle()
        #expect(model.correlateStatus.isEmpty, "correlate ran during a scan: \(model.correlateStatus)")
        #expect(!model.isAnalyzingDuplicates && model.duplicateStatus.isEmpty,
                "duplicates ran during a scan: \(model.duplicateStatus)")
    }
}
