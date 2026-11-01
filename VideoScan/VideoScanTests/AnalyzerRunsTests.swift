// AnalyzerRunsTests.swift
// Content Analysis gains the three analyzers that left the Catalog menu
// (Rick 2026-11-01): Embedded Dates, Full Hashes, Sound Fingerprints — what
// each does in one sentence, how long from the last run's pace and the
// count left, Run / Pause on the existing engines; Split Duplicate Groups
// by Full Hash runs by itself when a Full Hashes run reaches 100 %.
//
//   LOGIC     — the 100 % rule as a table; the estimate's words
//   ISOLATION — a poisoned or empty pace record reads "not run yet"; a run
//               with no files or no time records nothing
//   TRUTH     — a REAL Full Hashes run through the MFO center: the center
//               tells the follow-up once, the pace is recorded from the
//               job's own totals, the split runs once; a second run with
//               nothing to hash, and a run with a drive away, never split
//   SENSOR    — the default split is the retired menu item's call; the App
//               attaches it; the rows show the sentence and the estimate;
//               no `extension VideoScanModel` in the new file

import Foundation
import Testing
@testable import VideoScan

@Suite("Content Analysis analyzers — logic and words")
struct AnalyzerRunsLogicTests {

    typealias E = AnalyzerRunFollowUp.Ending

    static func ending(_ kind: E.Kind = .fullHashes, ok: Bool = true, scoped: Bool = false,
                       planned: Int = 10, hashed: Int = 10) -> E {
        E(kind: kind, succeeded: ok, scoped: scoped, planned: planned, hashed: hashed, resolved: planned, seconds: 5, unresolved: [:])
    }

    @Test("LOGIC: only a whole-catalog Full Hashes run that finished with every planned file hashed is 100 %")
    func oneHundredPercentRule() {
        #expect(AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending()))
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending(ok: false)), "stopped or failed")
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending(scoped: true)), "held rows only")
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending(planned: 0, hashed: 0)), "nothing to hash this run")
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending(hashed: 9)), "one file unreadable or its drive away")
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(Self.ending(.soundPrints)))
        var offline = Self.ending()
        offline.unresolved = ["drive not connected": 1]
        #expect(!AnalyzerRunFollowUp.reachesOneHundredPercent(offline), "Codex #189: an offline lane is not 100 %")
        #expect(AnalyzerRunFollowUp.noSplitReason(offline) == "no automatic split: 1 file(s) not hashed (1 drive not connected) — it runs when a Full Hashes run hashes every file it set out to")
        #expect(AnalyzerRunFollowUp.noSplitReason(Self.ending()) == nil)
    }

    @Test("LOGIC: how long — nothing left · not run yet · minutes · hours · days, at the last run's pace")
    func howLongWords() {
        #expect(AnalyzerRunWords.howLong(remaining: 0, rate: nil) == "How long: nothing left to do")
        #expect(AnalyzerRunWords.howLong(remaining: 660, rate: nil) == "How long: not run yet — 660 files left")
        let tenSecondsEach = AnalyzerRunRate(files: 30, seconds: 300, finishedAt: Date())
        #expect(AnalyzerRunWords.howLong(remaining: 660, rate: tenSecondsEach)
                == "How long: about 1 h 50 min for 660 files left, at the last run's pace (6 files a minute)")
        #expect(AnalyzerRunWords.howLong(remaining: 1, rate: tenSecondsEach) == "How long: under a minute for 1 file left, at the last run's pace (6 files a minute)")
        #expect(AnalyzerRunWords.duration(12 * 60) == "about 12 min")
        #expect(AnalyzerRunWords.duration(3 * 3_600) == "about 3 h")
        #expect(AnalyzerRunWords.duration(4 * 86_400) == "about 4 days")
        #expect(AnalyzerRunWords.pace(AnalyzerRunRate(files: 400, seconds: 100, finishedAt: Date())) == "4 files a second")
        #expect(AnalyzerRunWords.pace(AnalyzerRunRate(files: 3, seconds: 3_600, finishedAt: Date())) == "3 files an hour")
        for c in AnalyzerRunRates.analyzers { #expect(AnalyzerRunWords.sentence(c)?.hasSuffix(".") == true) }
        #expect(AnalyzerRunWords.sentence(.duplicates) == nil)
        #expect(AnalyzerRunRates.analyzers == [.fullHashes, .soundPrints, .embeddedDates])
    }

    @Test("LOGIC: the row's estimate stays quiet while the analyzer runs (its MFO line says it) and on other rows")
    func rowWordsOnlyForTheThreeAndOnlyWhenIdle() {
        let rate = AnalyzerRunRate(files: 10, seconds: 10, finishedAt: Date())
        #expect(AnalyzePanelView.howLongWords(.fullHashes, remaining: 5, rate: rate, isRunning: true).isEmpty)
        #expect(AnalyzePanelView.howLongWords(.duplicates, remaining: 5, rate: rate, isRunning: false).isEmpty)
        #expect(AnalyzePanelView.howLongWords(.embeddedDates, remaining: 5, rate: nil, isRunning: false) == "How long: not run yet — 5 files left")
    }

    @Test("ISOLATION: a poisoned pace record reads as none; a run with no files or no time records nothing")
    func poisonedAndEmptyRates() throws {
        let suite = "test.analyzerRuns.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("not json".utf8), forKey: AnalyzerRunRates.key(.fullHashes))
        #expect(AnalyzerRunRates.read(.fullHashes, defaults: d) == nil)
        AnalyzerRunRates.record(.soundPrints, files: 0, seconds: 10, defaults: d)
        AnalyzerRunRates.record(.soundPrints, files: 10, seconds: 0, defaults: d)
        AnalyzerRunRates.record(.soundPrints, files: 10, seconds: .infinity, defaults: d)
        #expect(AnalyzerRunRates.read(.soundPrints, defaults: d) == nil)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        AnalyzerRunRates.record(.embeddedDates, files: 12, seconds: 3, finishedAt: at, defaults: d)
        #expect(AnalyzerRunRates.read(.embeddedDates, defaults: d) == AnalyzerRunRate(files: 12, seconds: 3, finishedAt: at))
        #expect(AnalyzerRunRates.readAll(defaults: d).keys.sorted { $0.rawValue < $1.rawValue } == [.embeddedDates])
    }
}

@Suite("Content Analysis analyzers — a real Full Hashes run through the center", .serialized)
@MainActor
struct AnalyzerRunsFollowUpTests {

    /// Two different files in one duplicate group, a center with the follow-up attached.
    private func setUp(_ label: String) throws -> (sb: ShowAgainSandbox, center: MediaFileOperationsCenter,
                                                   followUp: AnalyzerRunFollowUp, defaults: UserDefaults, suite: String,
                                                   splits: SplitCounter) {
        let sb = try ShowAgainSandbox.make(label)
        let group = UUID()
        let a = try sb.record("a.mov", bytes: 4_000, stage: .none)
        let b = try sb.record("b.mov", bytes: 5_000, stage: .none)
        a.duplicateGroupID = group
        b.duplicateGroupID = group
        let center = MediaFileOperationsCenter()
        let suite = "test.analyzerRuns.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let followUp = AnalyzerRunFollowUp()
        followUp.defaults = defaults
        let splits = SplitCounter()
        followUp.split = { _, _ in splits.n += 1 }
        followUp.attach(center: center, model: sb.model)
        followUp.attach(center: center, model: sb.model)    // a second onAppear: still one observer
        return (sb, center, followUp, defaults, suite, splits)
    }

    @MainActor final class SplitCounter { var n = 0 }

    private func run(_ center: MediaFileOperationsCenter, _ model: VideoScanModel,
                     online: (@Sendable (String) -> Bool)? = nil) async -> FullHashBackfillJob {
        let job = FullHashBackfillJob(model: model, marker: nil)
        job.tickMilliseconds = 20
        if let online { job.volumeOnline = online }
        center.add(job)
        job.start()
        await job.task?.value
        // The center's terminal check hops one main-actor turn.
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return job
    }

    @Test("TRUTH: a run that hashes every planned file records its pace and splits once; a second run with nothing to hash does not split")
    func oneHundredPercentSplitsOnce() async throws {
        let s = try setUp("fhb_followup"); defer { s.sb.cleanup(); s.defaults.removePersistentDomain(forName: s.suite) }
        let heard = SplitCounter()
        s.center.onJobTerminal.append { _ in heard.n += 1 }

        let first = await run(s.center, s.sb.model)
        #expect(first.totals[.hashed] == 2 && first.totals.planned == 2, Comment(rawValue: first.totals.line))
        #expect(heard.n == 1, "the center tells its observers exactly once per job")
        #expect(s.splits.n == 1, "100 % → Split Duplicate Groups by Full Hash runs")
        let rate = try #require(AnalyzerRunRates.read(.fullHashes, defaults: s.defaults))
        #expect(rate.files == first.totals.done && rate.seconds > 0, "the pace is the job's own totals over its own clock")

        let second = await run(s.center, s.sb.model)
        #expect(second.totals.planned == 0)
        #expect(s.splits.n == 1, "nothing hashed this run — no second split")
        #expect(heard.n == 2)
    }

    @Test("RED Codex #189 P2-1: one lane online and hashed, one lane offline — the planned files all hashed, yet the run never splits, and the log says why")
    func oneLaneOfflineNeverSplits() async throws {
        let s = try setUp("fhb_followup_mixed"); defer { s.sb.cleanup(); s.defaults.removePersistentDomain(forName: s.suite) }
        let offlineRoot = "/Volumes/FHBFollowUpOffline_\(UUID().uuidString.prefix(8))"
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/away.mov"; away.filename = "away.mov"; away.sizeBytes = 3_000
        away.directory = offlineRoot
        s.sb.model.records.append(away)
        let job = await run(s.center, s.sb.model, online: { !$0.hasPrefix(offlineRoot) })
        #expect(job.totals[.driveNotConnected] == 1 && job.totals[.hashed] == 2 && job.totals.planned == 2,
                Comment(rawValue: job.totals.line))
        #expect(s.splits.n == 0, "a file the job set out to hash is still unhashed — no split")
        let why = try #require(s.followUp.lastNoSplitReason)
        #expect(why.contains("1 file(s) not hashed") && why.contains("drive not connected"), Comment(rawValue: why))
    }

    @Test("ISOLATION: a run with a drive away never reaches 100 % and never splits")
    func driveAwayNeverSplits() async throws {
        let s = try setUp("fhb_followup_away"); defer { s.sb.cleanup(); s.defaults.removePersistentDomain(forName: s.suite) }
        let job = await run(s.center, s.sb.model, online: { _ in false })
        #expect(job.totals[.hashed] == 0)
        #expect(s.splits.n == 0)
    }
}

@Suite("Content Analysis analyzers — the automatic split's OUTCOME on catalog.sqlite", .serialized)
@MainActor
struct AnalyzerRunsSplitOutcomeTests {

    @Test("RED Codex #189 P2-2: the split's OUTCOME says rows before · rows after · where the difference went, from the store and the commit's result")
    func outcomeCarriesRowAccounting() async throws {
        let scene = try CutoverScene.make("ar_split_outcome", healthyRows: 5); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let g = UUID()
        let members = try (0..<3).map { try scene.bulk($0) }
        for (i, r) in members.enumerated() {
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 600
            r.timecode = "00:00:00:00"
            r.resolution = "720x480"
            r.videoCodec = ["ffv1", "h264", "dvvideo"][i]
            r.duplicateGroupID = g
            r.duplicateConfidence = .high
            r.duplicateDisposition = i == 0 ? .keep : .extraCopy
            r.duplicateReasons = "timecode+duration+resolution"
            r.duplicateGroupCount = 3
            r.dupAnalyzedAt = Date(timeIntervalSince1970: 1_760_850_000)
        }
        #expect(model.saveCatalogNow())
        let url = try #require(model.catalogCutover.databaseURL)
        guard case .known(let rows) = CatalogDatabaseInfoReader.read(at: url).records else {
            Issue.record("the store's row count is unreadable"); return
        }
        // The production split closure — the one the follow-up runs at 100 %.
        AnalyzerRunFollowUp().split(MediaFileOperationsCenter(), model)
        let outcome = try #require(scene.sandbox.catalogLogText().split(separator: "\n")
            .last { $0.contains("Split duplicate groups: OUTCOME") }.map(String.init))
        #expect(outcome.contains("rows before \(rows.formatted()) · rows after \(rows.formatted()) · difference 0"), Comment(rawValue: outcome))
        #expect(outcome.contains("the commit wrote 3 row(s)"), Comment(rawValue: outcome))
    }
}

@Suite("Content Analysis analyzers — sensors")
@MainActor
struct AnalyzerRunsSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: the automatic split is the retired menu item's call; the App attaches it once; the center tells it at the terminal guard")
    func theSplitIsTheOneEngine() throws {
        let runs = try Self.code("AnalyzerRuns.swift")
        #expect(runs.contains("center.splitDuplicateGroupsKeepingSameFootage(model: model)"))
        #expect(!runs.contains("splitDuplicateGroupsByFullDigest(") && !runs.contains("extension VideoScanModel"))
        #expect(try Self.code("VideoScanApp.swift").contains("analyzerFollowUp.attach(center: fileOpsCenter, model: catalogModel)"))
        let center = try Self.code("MediaFileOperations.swift")
        let guardAt = try #require(center.range(of: "terminalLogged.insert(job.id)")).upperBound
        let tell = try #require(center.range(of: "for observer in onJobTerminal { observer(job) }")).lowerBound
        #expect(guardAt < tell, "observers run after the exactly-once guard")
        #expect(center.components(separatedBy: "for observer in onJobTerminal").count == 2, "one call site")
    }

    @Test("SENSOR: Run on the three rows is the engine the menu items started; the rows carry the sentence and the estimate")
    func theRowsAndTheEngines() throws {
        let runner = try Self.code("AnalyzeRunner.swift")
        #expect(runner.contains("_ = c.startFullHashBackfill(model: model, marker: model.fullHashResumeMarker)"))
        #expect(runner.contains("_ = c.startAudioFingerprintBackfill(model: model)"))
        #expect(runner.contains("let r = await model.runEmbeddedDateBackfill(pathPrefix: volume)"))
        #expect(runner.contains("AnalyzerRunRates.record(.embeddedDates,"))
        let panel = try Self.code("AnalyzePanelView.swift")
        #expect(panel.contains("sentence: AnalyzerRunWords.sentence(cycler) ?? \"\""))
        #expect(panel.contains("s.rates = AnalyzerRunRates.readAll()"), "sampled on the tick, never in the body")
        #expect(panel.contains("Text(facts.howLong)") && panel.contains("Text(facts.sentence)"))
    }
}
