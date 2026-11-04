// CatalogStatusSplitTests.swift — the totals strip's two indicators (Rick
// 2026-11-03, DECISIONS "two indicators, Catalog and Content"):
//
//   ● Catalog: Synced | Stale | Unhealthy | Unknown
//   ● Content: Up to date | N left to analyze | Analyzing N of M files
//
//   LOGIC     — every Catalog state → its word and colour (Database + Files,
//               worst of the two; grey beats green; a running check turns
//               Stale into Unknown, never Unhealthy); every Content state;
//               Content NEVER yellow or red (seen red on origin/main); the
//               sound print sidecar is Catalog red (seen red on origin/main);
//               a drive away is grey and named, back again is yellow
//   TRUTH     — through the REAL coverage calculator: N is files (a file with
//               two analyses left counts once), M is connected files; the
//               drive names are the pass's own tally; the snapshot's
//               indicators are the policy over exactly its facts and report
//   ISOLATION — uncomputed → both grey ("Unknown" / "Counting…"); a garbage
//               file-check record is Catalog red while Content stays its own
//   SCALE     — 100k rows: the per-file tally agrees with the per-analyzer
//               counts and stays inside the coverage pass's budget
//   SENSOR    — two buttons on the strip, each its own click target; the strip
//               observes the snapshot only; the Content builder holds no
//               yellow or red at all
//
// Media matrix: not applicable (no media is read; words over counts).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private func d(_ date: Date) -> String { "D\(Int(date.timeIntervalSince1970))" }

private func audit(_ counts: [String: Int], finished: Date = now.addingTimeInterval(-3_600)) -> CatalogAuditRunRecord {
    CatalogAuditRunRecord(startedAt: finished.addingTimeInterval(-60), finishedAt: finished,
                          outcome: .completed, partial: false, counts: counts)
}

private func computed(_ edit: (inout AnalyzeCoverageReport) -> Void = { _ in }) -> AnalyzeCoverageReport {
    var r = AnalyzeCoverageReport()
    r.computedAt = now
    edit(&r)
    return r
}

@Suite("Catalog Status split — logic")
struct CatalogStatusSplitLogicTests {

    static var freshFacts: CatalogFreshnessFacts {
        CatalogFreshnessFacts(audit: audit(["planned": 3, "present": 3]),
                              integrity: IntegrityReportFacts(lastCompleted: now.addingTimeInterval(-3_600), outcome: .ok))
    }

    @Test("RED 2026-11-03: work left and nothing running it is NOT yellow — Content is never yellow or red")
    func contentIsNeverYellow() {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        let lines = CatalogStatusLinesPolicy.lines(facts: Self.freshFacts, report: report, now: now)
        #expect(lines.content.state != .yellow && lines.content.state != .red, "got \(lines.content.state): \(lines.content.words)")
        // The sweep: every input the Content line reads, and every fact it must ignore.
        let poisoned = [Self.freshFacts, CatalogFreshnessFacts(), CatalogFreshnessFacts(soundStoreProblem: "not a database"),
                        CatalogFreshnessFacts(integrity: IntegrityReportFacts(outcome: .failed)),
                        CatalogFreshnessFacts(auditProblem: "catalog-audit.json can't be read: damaged")]
        let reports = [AnalyzeCoverageReport(), report, computed { $0.contentFiles = AnalyzeCoverageCounts(eligible: 10, covered: 0, offline: 5) },
                       computed { $0.byCycler[.transcribe] = AnalyzeCoverageCounts(eligible: 3, covered: 0)
                                  $0.contentFiles = AnalyzeCoverageCounts(eligible: 3, covered: 0) }]
        for f in poisoned { for r in reports { for working in [false, true] {
            let c = CatalogStatusLinesPolicy.lines(facts: f, report: r, now: now, working: working).content
            #expect(![.yellow, .red].contains(c.state), "Content went \(c.state): \(c.words)")
        } } }
    }

    @Test("RED 2026-11-03: the sound print sidecar that can't be opened is Catalog red (the Database line), never Content")
    func sidecarIsCatalogRed() {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        var facts = Self.freshFacts
        facts.soundStoreProblem = "the fingerprint file is not a database (damaged or replaced): /x"
        let lines = CatalogStatusLinesPolicy.lines(facts: facts, report: report, now: now)
        #expect(lines.database.state == .red, "got \(lines.database.state): \(lines.database.words)")
        #expect(lines.content.state != .red, "got \(lines.content.state): \(lines.content.words)")
        #expect(lines.catalog.state == .red && lines.catalog.words == "Unhealthy")
        #expect(lines.database.words.hasPrefix("Red: the sound print sidecar (\(AudioFingerprintStore.fileName)) can't be opened — the fingerprint file is not a database"),
                Comment(rawValue: lines.database.words))
        #expect(lines.database.words.contains("Fix: no fix yet"), "no verb repairs it — said honestly")
        #expect(lines.database.detail.first?.hasPrefix("Integrity check: Integrity check passed") == true, "the check's own verdict is kept beneath")
        #expect(lines.catalog.why == ["Database: \(lines.database.words)"])
        // A red check keeps its words; the sidecar rides beneath.
        let both = CatalogStatusLinesPolicy.database(IntegrityReportFacts(outcome: .failed), soundStoreProblem: "x", now: now, date: d)
        #expect(both.words == "Red: the last integrity check failed. Fix: Check Now… runs it again")
        #expect(both.detail.contains(CatalogStatusLinesPolicy.soundStoreWords("x")))
    }

    static func lines(_ db: CatalogStatusLineState, _ files: CatalogStatusLineState, checking: Bool = false) -> CatalogStatusLines {
        CatalogStatusLines(database: CatalogStatusLine(kind: .database, state: db, words: "db \(db)"),
                           files: CatalogStatusLine(kind: .files, state: files, words: "files \(files)"),
                           content: CatalogStatusLine(kind: .content, state: .grey, words: "3 left to analyze"),
                           checking: checking)
    }

    @Test("LOGIC: Catalog is the worst of Database and Files — Synced / Stale / Unhealthy / Unknown, exactly; grey beats green; a running check makes Stale Unknown and leaves red and green alone")
    func catalogEveryState() {
        let table: [(CatalogStatusLineState, CatalogStatusLineState, Bool, CatalogStatusLineState, String)] = [
            (.green, .green, false, .green, "Synced"),
            (.yellow, .green, false, .yellow, "Stale"),
            (.green, .yellow, false, .yellow, "Stale"),
            (.red, .yellow, false, .red, "Unhealthy"),
            (.green, .red, false, .red, "Unhealthy"),
            (.green, .grey, false, .grey, "Unknown"),
            (.yellow, .grey, false, .yellow, "Stale"),
            (.yellow, .green, true, .grey, "Unknown"),
            (.red, .green, true, .red, "Unhealthy"),
            (.green, .green, true, .green, "Synced"),
        ]
        for (db, files, checking, state, words) in table {
            let c = Self.lines(db, files, checking: checking).catalog
            #expect(c.state == state && c.words == words, "\(db)+\(files) checking \(checking) → \(c.state) \(c.words)")
        }
        #expect(Self.lines(.green, .green).catalog.why.isEmpty, "green's lead is the database facts, in the window")
        #expect(Self.lines(.yellow, .green).catalog.why == ["Database: db yellow"])
        #expect(Self.lines(.yellow, .green, checking: true).catalog.why.first?.hasPrefix("Checking… Validate Catalog is running") == true,
                "grey says what is happening, so the user knows to wait")
        #expect(Self.lines(.green, .grey).catalog.why == ["Files: files grey"])
        #expect(CatalogStatusLinesPolicy.catalogIsChecking(running: [.integrity]))
        #expect(CatalogStatusLinesPolicy.catalogIsChecking(running: [.filePresence]))
        #expect(!CatalogStatusLinesPolicy.catalogIsChecking(running: [.fullHashes, .soundPrints, .ocr]))
    }

    @Test("LOGIC: Content reads Up to date (green) · N left to analyze (grey) · Analyzing N of M files (blue) · Counting… (grey), and says what N counts")
    func contentEveryState() {
        func c(_ r: AnalyzeCoverageReport, working: Bool = false) -> CatalogStatusIndicator {
            CatalogStatusLinesPolicy.lines(facts: Self.freshFacts, report: r, now: now, working: working).contentIndicator
        }
        #expect(c(AnalyzeCoverageReport()).state == .grey && c(AnalyzeCoverageReport()).words == "Counting…")
        #expect(c(computed()).state == .green && c(computed()).words == "Up to date")
        let left = computed {
            $0.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 1_200, covered: 10)
            $0.byCycler[.transcribe] = AnalyzeCoverageCounts(eligible: 1_200, covered: 1_100)
            $0.contentFiles = AnalyzeCoverageCounts(eligible: 1_200, covered: 10)
        }
        #expect(c(left).state == .grey && c(left).words == "1,190 left to analyze", Comment(rawValue: c(left).words))
        #expect(c(left).why.first == "1,190 counts files on connected drives with at least one counted analysis left")
        #expect(c(left, working: true).state == .inProgress && c(left, working: true).words == "Analyzing 10 of 1,200 files")
        // A report with no per-file tally says it counts pairs — never a file count it does not hold.
        let pairs = computed { $0.byCycler[.ocr] = AnalyzeCoverageCounts(eligible: 5, covered: 2) }
        #expect(c(pairs).words == "3 left to analyze" && c(pairs).why.first?.contains("analyzer-file pairs") == true)
        #expect(c(pairs, working: true).words == "Analyzing — 3 left to analyze")
    }

    @Test("LOGIC: a large share on drives not connected is grey and names the drives still away; all back → yellow Check Now…; could not check → yellow")
    func filesGreyWhileADriveIsAway() {
        let facts = CatalogFreshnessFacts(audit: audit(["planned": 100, "present": 70, "notAsked": 30]))
        let away = CatalogStatusLinesPolicy.files(facts, missing: MissingCopyCounts(), offline: ["/Volumes/X9": 28, "/Volumes/Y": 2], now: now, date: d)
        #expect(away.state == .grey)
        #expect(away.words == "Unknown: 30 of 100 files were on drives not connected at the last check — not connected now: /Volumes/X9 (28 files) · /Volumes/Y (2 files). Fix: connect them, then Check Now…",
                Comment(rawValue: away.words))
        let back = CatalogStatusLinesPolicy.files(facts, missing: MissingCopyCounts(), offline: [:], now: now, date: d)
        #expect(back.state == .yellow && back.words.hasSuffix("every drive is connected now. Fix: Check Now… runs Validate Catalog"), Comment(rawValue: back.words))
        let unread = CatalogFreshnessFacts(audit: audit(["planned": 100, "present": 70, "couldNotCheck": 30]))
        #expect(CatalogStatusLinesPolicy.files(unread, missing: MissingCopyCounts(), offline: ["/Volumes/X9": 1], now: now, date: d).state == .yellow)
        // Every coloured Files line names its fix.
        for f in [CatalogFreshnessFacts(), unread, CatalogFreshnessFacts(auditProblem: "damaged"),
                  CatalogFreshnessFacts(audit: audit(["planned": 1, "present": 1], finished: now.addingTimeInterval(-90_000)))] {
            let l = CatalogStatusLinesPolicy.files(f, missing: MissingCopyCounts(), now: now, date: d)
            #expect(l.state.needsAttention && l.words.contains("Fix: "), Comment(rawValue: l.words))
        }
    }
}

// MARK: - Truth, through the real coverage pass

@Suite("Catalog Status split — truth")
@MainActor
struct CatalogStatusSplitTruthTests {

    static func input(_ path: String, hash: Bool = true, transcript: Bool = true) -> AnalyzeCoverageInput {
        AnalyzeCoverageInput(fullPath: path, dupStamped: true, dossierStamped: true, hasCaptions: true, hasTranscript: transcript,
                             hasHash: true, hasFullDigest: hash, hasSoundStamp: true)
    }

    static func report() -> AnalyzeCoverageReport {
        let inputs = [input("/Volumes/A/done.mov"), input("/Volumes/A/nohash.mov", hash: false),
                      input("/Volumes/A/two.mov", hash: false, transcript: false), input("/Volumes/B/away.mov", hash: false)]
        return AnalyzeCoverageCalculator.compute(inputs: inputs,
                                                 volumes: [AnalyzeVolumeFact(root: "/Volumes/A", isReachable: true, isRetired: false),
                                                           AnalyzeVolumeFact(root: "/Volumes/B", isReachable: false, isRetired: false)],
                                                 mountedRoots: ["/"], scope: AnalysisScope(), now: now)
    }

    @Test("TRUTH: N counts files (a file with two analyses left counts once), M the connected files; the offline drive is the pass's own tally")
    func perFileCountsFromTheCalculator() {
        let r = Self.report()
        #expect(r.contentFiles.eligible == 3 && r.contentFiles.covered == 1 && r.contentFiles.offline == 1, "\(r.contentFiles)")
        let pairs = AnalyzeCoverageReport.contentAnalyzers.reduce(0) { $0 + r.counts($1).remaining }
        #expect(pairs == 3, "2 full hashes + 1 transcript: three pairs, two files")
        #expect(r.offlineFilesByRoot == ["/Volumes/B": 1])
        let facts = CatalogStatusSplitLogicTests.freshFacts
        #expect(CatalogStatusLinesPolicy.lines(facts: facts, report: r, now: now).contentIndicator.words == "2 left to analyze")
        #expect(CatalogStatusLinesPolicy.lines(facts: facts, report: r, now: now, working: true).contentIndicator.words == "Analyzing 1 of 3 files")
        #expect(CatalogStatusLinesPolicy.lines(facts: facts, report: r, now: now).content.detail.contains("1 file on drives not connected is not counted"))
        var changed = r; changed.contentFiles.covered = 2
        #expect(changed != r, "a per-file change is a publish (equality gate)")
    }

    @Test("TRUTH: the snapshot publishes indicators built from exactly its facts and report; a running Validate makes a stale Catalog Unknown")
    func snapshotIndicators() {
        let snapshot = CatalogFreshnessSnapshot()
        let quiet = CatalogStatusIndicators(snapshot.state)
        #expect(quiet.catalog.state == .grey && quiet.catalog.words == "Unknown" && quiet.content.words == "Counting…",
                "ISOLATION: nothing counted yet → both grey")
        let r = Self.report()
        let facts = CatalogFreshnessFacts()      // never checked: Stale
        snapshot.publish(report: r, facts: facts)
        let ind = CatalogStatusIndicators(snapshot.state)
        let expected = CatalogStatusIndicators(CatalogStatusLinesPolicy.lines(facts: facts, report: r, now: Date()))
        #expect(ind == expected)
        #expect(ind.catalog.words == "Stale" && ind.content.words == "2 left to analyze")
        snapshot.setRunning([.integrity, .filePresence])
        #expect(CatalogStatusIndicators(snapshot.state).catalog.words == "Unknown", "Checking… — wait for it")
        snapshot.setRunning([.fullHashes])
        #expect(CatalogStatusIndicators(snapshot.state).catalog.words == "Stale")
        #expect(CatalogStatusIndicators(snapshot.state).content.words == "Analyzing 1 of 3 files")
    }

    @Test("ISOLATION: a garbage file-check record is Catalog Unhealthy; Content keeps its own state")
    func poisonedRecordDoesNotLeak() {
        let facts = CatalogFreshnessFacts(auditProblem: "catalog-audit.json can't be read: damaged")
        let lines = CatalogStatusLinesPolicy.lines(facts: facts, report: Self.report(), now: now, working: true)
        #expect(lines.catalog.words == "Unhealthy")
        #expect(lines.contentIndicator.state == .inProgress)
    }
}

// MARK: - Scale

@Suite("Catalog Status split — scale")
struct CatalogStatusSplitScaleTests {

    @Test("SCALE: 100k rows — the per-file tally sits between the largest and the sum of the per-analyzer counts, the drive tally sums to the offline rows, inside the coverage budget")
    func hundredThousandRows() {
        let volumes = (0..<10).map { AnalyzeVolumeFact(root: "/Volumes/Vol\($0)", isReachable: $0 % 5 != 0, isRetired: false) }
        var inputs: [AnalyzeCoverageInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            inputs.append(AnalyzeCoverageInput(fullPath: "/Volumes/Vol\(i % 10)/f\(i % 40)/clip\(i).mov", sizeBytes: Int64(i % 7),
                                               dupStamped: i % 2 == 0, dossierStamped: i % 4 == 0, hasCaptions: i % 5 == 0,
                                               hasTranscript: i % 6 == 0, hasHash: i % 3 == 0, hasFullDigest: i % 9 == 0,
                                               hasSoundStamp: i % 2 == 1))
        }
        let start = ContinuousClock.now
        let r = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: volumes, mountedRoots: ["/"], scope: AnalysisScope(), now: now)
        let elapsed = ContinuousClock.now - start
        let remaining = AnalyzeCoverageReport.contentAnalyzers.map { r.counts($0).remaining }
        #expect(r.contentFiles.remaining >= remaining.max() ?? 0 && r.contentFiles.remaining <= remaining.reduce(0, +))
        #expect(r.contentFiles.eligible + r.contentFiles.offline + r.contentFiles.notApplicable == 100_000)
        #expect(r.offlineFilesByRoot.values.reduce(0, +) == 20_000, "Vol0 and Vol5 are away: 2 × 10,000")
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_500)), "coverage with the per-file tally took \(elapsed)")
    }
}

// MARK: - Sensors

@Suite("Catalog Status split — sensors")
@MainActor
struct CatalogStatusSplitSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: two indicators on the strip, each its own click target, observing the snapshot only")
    func twoIndicatorsTwoDoors() throws {
        let chip = try Self.code("CatalogStatusChip.swift")
        #expect(chip.contains("@ObservedObject var freshness: CatalogFreshnessSnapshot"))
        #expect(chip.components(separatedBy: "@ObservedObject").count - 1 == 1, "one observed value")
        for forbidden in ["VideoScanModel", "@EnvironmentObject", "records", "AnalyzeCoverageCalculator", "CatalogStatusLinesPolicy"] {
            #expect(!chip.contains(forbidden), "the strip holds \(forbidden)")
        }
        #expect(chip.contains("identifier: \"catalog.statusChip.catalog\", action: openCatalogStatus"))
        #expect(chip.contains("identifier: \"catalog.statusChip.content\", action: openContentAnalysis"))
        #expect(chip.contains("openWindow(id: CatalogStatusWindow.sceneID)"))
        #expect(chip.contains("AnalyzeWindowOpener.open(using: openWindow, source: \"status-chip\")"))
        #expect(chip.contains("pill: false,"), "Content never earns a pill")
        let footer = try Self.code("VolumeTableTotalsFooter.swift")
        #expect(footer.contains("CatalogStatusChip(freshness: freshness)"))
    }

    @Test("SENSOR: the Content builder holds no yellow and no red; the window leads with the Catalog indicator and reuses the database facts")
    func contentHasNoAlarmColours() throws {
        let lines = try Self.code("CatalogStatusLines.swift")
        let body = String(lines[try #require(lines.range(of: "static func content(_ report: AnalyzeCoverageReport")).lowerBound...])
        #expect(!body.contains(".yellow") && !body.contains(".red"), "Content can never be an alarm (Rick 2026-11-03)")
        #expect(!body.contains("soundStoreProblem"), "the sidecar is Catalog's")
        let window = try Self.code("CatalogStatusWindow.swift")
        #expect(window.contains("CatalogStatusIndicators(freshness.state).catalog"))
        #expect(window.contains("CatalogStatusWindowWords.basics(info.lines)"), "green's basics are the facts model's own rows")
    }
}

// MARK: - Codex 11/03 F2 + reviewer red: the helper's era job never claims counted progress

/// The era job as the helper reports it, in each state.
@MainActor
private func eraOnly(_ state: JobRunState, waiting: String? = nil) -> Result<ServiceStatus, Refusal> {
    var job = BackgroundServiceStoreTests.eraJob(state, done: 120, total: 4_709)
    job.waiting = waiting
    return .success(BackgroundServiceStoreTests.serviceStatus(jobs: [job]))
}

@Suite("Catalog Status split — reviewer reds (2026-11-03)")
@MainActor
struct CatalogStatusSplitReviewTests {

    /// Lifted from the review-1103 worktree. Adapted: `backgroundActive` is now
    /// the helper's real status through BackgroundServiceActivity's rule (the
    /// fix moved the decision there), not a bare `true`.
    @Test("TRUE: the helper's era job never moves N — from the helper alone the Content line must not claim 'Analyzing N of M files'")
    func helperAloneDoesNotClaimCountedProgress() {
        // Machine era has no AnalyzeCycler at all; N and M count the seven stamped analyzers.
        #expect(!AnalyzeCycler.allCases.contains { $0.rawValue.lowercased().contains("era") })
        let report = computed {
            $0.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
            $0.contentFiles = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        }
        let working = CatalogStatusLinesPolicy.contentIsWorking(running: [], backgroundActive: BackgroundServiceActivity.isActive(eraOnly(.running)))
        let line = CatalogStatusLinesPolicy.lines(facts: CatalogStatusSplitLogicTests.freshFacts, report: report, now: now,
                                                  working: working).content
        #expect(line.words != "Analyzing 40 of 700 files", "\(line.words)")
    }
}

@Suite("Catalog Status split — what the helper may claim (Codex 11/03 F2)")
@MainActor
struct CatalogStatusBackgroundClaimTests {

    @Test("RED 11/03 F2: an era job running, queued, user-paused or waiting never lights 'Analyzing'; its own line rides under Content")
    func eraOnlyThroughTheSnapshot() {
        let snapshot = CatalogFreshnessSnapshot()
        snapshot.publish(report: CatalogStatusSplitTruthTests.report(), facts: CatalogStatusSplitLogicTests.freshFacts)
        let cases: [(JobRunState, String?, String)] = [
            (.running, nil, "Machine era: 120 of 4,709 files (VideoScan Background — running)"),
            (.queued, nil, "Machine era: 120 of 4,709 files (VideoScan Background — queued)"),
            (.paused(reason: "user"), nil, "Machine era: 120 of 4,709 files (VideoScan Background — paused (user))"),
            (.running, EraJob.deferWords, "Machine era: 120 of 4,709 files (VideoScan Background — waiting — \(EraJob.deferWords))"),
        ]
        for (state, waiting, eraWords) in cases {
            let reading = BackgroundServiceActivity.Reading(eraOnly(state, waiting: waiting))
            snapshot.setBackgroundServiceActive(reading.active)
            snapshot.setBackgroundEraLine(reading.eraLine)
            let content = CatalogStatusIndicators(snapshot.state).content
            #expect(content.state == .grey, "\(state): \(content.words)")
            #expect(content.words == "2 left to analyze", "\(state): \(content.words)")
            #expect(content.why.first == eraWords, "\(content.why)")
        }
        snapshot.setBackgroundEraLine(nil)
        #expect(!(CatalogStatusIndicators(snapshot.state).content.why.first ?? "").hasPrefix("Machine era"), "no job, no line")
    }

    @Test("RED Codex closing #1: a PAUSED local Full Hashes job is not 'on it' — Content must not keep claiming 'Analyzing'")
    func pausedLocalJobIsNotWorking() async throws {
        let sb = try ShowAgainSandbox.make("paused_fullhash"); defer { sb.cleanup() }
        for i in 0..<40 { try sb.live("clip\(i).mov", bytes: 200_000) }
        let center = MediaFileOperationsCenter()
        let job = center.startFullHashBackfill(model: sb.model, marker: nil)
        #expect(CatalogFreshnessSnapshot.jobRunning(in: center).contains(.fullHashes), "running: on it")
        job.pause()
        #expect(job.isPaused && job.state.isActive)
        #expect(!CatalogFreshnessSnapshot.jobRunning(in: center).contains(.fullHashes), "paused: nothing moves the count")
        #expect(!CatalogStatusLinesPolicy.contentIsWorking(running: CatalogFreshnessSnapshot.jobRunning(in: center), backgroundActive: false))
        job.cancel()
        await job.task?.value
    }

    @Test("RED Codex closing-2 #1: a PAUSED dossier batch with nothing in flight is not 'on it' — Content returns to 'N left'")
    func pausedDossierIsNotWorking() async throws {
        let snapshot = CatalogFreshnessSnapshot()
        let dossier = DossierDashboardSnapshot()
        snapshot.observeDossier(dossier)
        var r = CatalogStatusSplitTruthTests.report()
        r.byCycler[.ocr] = AnalyzeCoverageCounts(eligible: 3, covered: 1)
        snapshot.publish(report: r, facts: CatalogStatusSplitLogicTests.freshFacts)
        var active = DossierDashboardState()
        active.statusIsActive = true
        dossier.publish(active)
        for _ in 0..<40 where !snapshot.state.isRunning(.ocr) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(CatalogStatusIndicators(snapshot.state).content.words.hasPrefix("Analyzing"))
        active.paused = true
        dossier.publish(active)                               // paused, no lane in flight
        for _ in 0..<40 where snapshot.state.isRunning(.ocr) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!snapshot.state.isRunning(.ocr), "paused and drained: nothing moves")
        #expect(CatalogStatusIndicators(snapshot.state).content.words == "2 left to analyze")
    }

    @Test("F2 LOGIC: only a RUNNING, not-waiting job of a kind that feeds a counted analyzer is active — none does today")
    func activityRule() {
        #expect(BackgroundServiceActivity.feedsCountedAnalyzers.isEmpty)
        #expect(!BackgroundServiceActivity.isActive(eraOnly(.running)))
        #expect(!BackgroundServiceActivity.isActive(nil))
        #expect(!BackgroundServiceActivity.isActive(.failure(Refusal("down"))))
        #expect(BackgroundServiceActivity.eraLine(eraOnly(.finished)) == nil, "a finished job is not shown")
    }
}

@Suite("Catalog Status — transitions reach the log once (Codex 11/03 F6)")
@MainActor
struct CatalogStatusTransitionLogTests {

    @Test("RED 11/03 F6: unreadable report → still unreadable → passed = exactly two [catalog-status] lines")
    func failureRepeatRecovery() {
        let snapshot = CatalogFreshnessSnapshot()
        var said: [String] = []
        snapshot.note = { said.append($0) }
        let report = computed { $0.activeRecords = 3 }
        let bad = CatalogFreshnessFacts(audit: audit(["planned": 3, "present": 3]),
                                        integrity: IntegrityReportFacts(problem: "integrity-latest.json can't be read: damaged"))
        snapshot.publish(report: report, facts: bad)
        snapshot.publish(report: report, facts: bad)
        snapshot.setRunning([.duplicates]); snapshot.setRunning([])     // recomputes, same verdict
        snapshot.publish(report: report, facts: CatalogStatusSplitLogicTests.freshFacts)
        let database = said.filter { $0.hasPrefix("Database:") }
        #expect(database.count == 2, "\(said)")
        #expect(database.first?.hasPrefix("Database: Unhealthy (Red: the last integrity check's report can't be read") == true, "\(said)")
        #expect(database.last?.hasPrefix("Database: Unhealthy → Synced (Integrity check passed") == true, "\(said)")
    }

    @Test("RED Codex closing #4: under a red integrity check, the sound sidecar's failure appearing and clearing is logged")
    func sidecarUnderRedIntegrity() {
        let snapshot = CatalogFreshnessSnapshot()
        var said: [String] = []
        snapshot.note = { said.append($0) }
        let report = computed { $0.activeRecords = 3 }
        let audit = audit(["planned": 3, "present": 3])
        let failed = IntegrityReportFacts(problem: "integrity-latest.json can't be read: damaged")
        snapshot.publish(report: report, facts: CatalogFreshnessFacts(audit: audit, integrity: failed))
        let before = said.count
        snapshot.publish(report: report, facts: CatalogFreshnessFacts(audit: audit, soundStoreProblem: "disk I/O error", integrity: failed))
        #expect(said.count == before + 1, "\(said)")
        #expect(said.last?.contains("disk I/O error") == true, "\(said)")
        snapshot.publish(report: report, facts: CatalogFreshnessFacts(audit: audit, integrity: failed))
        #expect(said.count == before + 2, "\(said)")
        #expect(said.last?.hasPrefix("Database: Unhealthy") == true, "\(said)")
    }

    @Test("RED Codex closing-2 #2: a failed check AND an unreadable sidecar arriving together — the log names both causes")
    func bothCausesTogether() {
        for startHealthy in [false, true] {
            let snapshot = CatalogFreshnessSnapshot()
            var said: [String] = []
            snapshot.note = { said.append($0) }
            let report = computed { $0.activeRecords = 3 }
            let audit = audit(["planned": 3, "present": 3])
            if startHealthy { snapshot.publish(report: report, facts: CatalogStatusSplitLogicTests.freshFacts) }
            snapshot.publish(report: report, facts: CatalogFreshnessFacts(audit: audit, soundStoreProblem: "disk I/O error",
                                                                          integrity: IntegrityReportFacts(problem: "damaged report")))
            let database = said.filter { $0.hasPrefix("Database:") }.joined(separator: "\n")
            #expect(database.contains("damaged report") && database.contains("disk I/O error"), "healthy first \(startHealthy): \(said)")
        }
    }

    @Test("RED Codex closing-3: a different drive is a cause change; a count crossing a thousands separator is not")
    func causeKeepsNamesDropsCounts() {
        typealias C = CatalogStatusTransitions
        #expect(C.cause("Unknown: 30 of 30 files — not connected now: /Volumes/X8 (30 files)")
                != C.cause("Unknown: 30 of 30 files — not connected now: /Volumes/X9 (30 files)"), "X8 → X9 is a different drive")
        #expect(C.cause("Analyzing 999 of 2,000 files") == C.cause("Analyzing 1,000 of 2,000 files"), "a count is not a cause")
        #expect(C.cause("checked 2 Nov 10:41 (45 min ago)") == C.cause("checked 2 Nov 11:41 (1 h ago)"), "an age is not a cause")
        #expect(C.cause("sidecar can't be opened — disk I/O error") != C.cause("sidecar can't be opened — no such file"))
    }

    @Test("F6: a ticking count or age is not a change; a new cause is")
    func causeNotCounts() {
        let a = CatalogStatusLine(kind: .content, state: .grey, words: "12 left to analyze")
        let b = CatalogStatusLine(kind: .content, state: .grey, words: "11 left to analyze")
        let db = CatalogStatusLine(kind: .database, state: .green, words: "Integrity check passed 2 Nov 10:41 (1 h ago)")
        let db2 = CatalogStatusLine(kind: .database, state: .green, words: "Integrity check passed 2 Nov 11:41 (2 h ago)")
        let files = CatalogStatusLine(kind: .files, state: .yellow, words: "Yellow: files not checked yet")
        let files2 = CatalogStatusLine(kind: .files, state: .yellow, words: "Yellow: 3 present — older than 24 hours")
        let old = CatalogStatusLines(database: db, files: files, content: a)
        #expect(CatalogStatusTransitions.lines(old: old, new: CatalogStatusLines(database: db2, files: files, content: b)).isEmpty)
        #expect(CatalogStatusTransitions.lines(old: old, new: CatalogStatusLines(database: db2, files: files2, content: b))
                == ["Files: Stale — now: Yellow: 3 present — older than 24 hours"])
        #expect(CatalogStatusTransitions.lines(old: nil, new: old) == ["Files: Stale (Yellow: files not checked yet)",
                                                                      "Content: Left to analyze (12 left to analyze)"],
                "a first judgement says only what is not green")
    }

    @Test("F6: wiring — the app hands the snapshot the one catalog-status sink")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/App/VideoScanApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        #expect(text.contains("catalogModel.catalogFreshness.note = { [weak catalogModel] in catalogModel?.catalogStatusNote($0) }"))
    }
}

@Suite("Catalog Database Info — unknown facts reach the log once (Codex 11/03 F6)")
struct CatalogDatabaseInfoUnknownLogTests {
    static func row(_ label: String, _ value: String, known: Bool) -> CatalogDatabaseInfoLine {
        CatalogDatabaseInfoLine(label: label, value: value, source: "", known: known)
    }

    @Test("appear → same → clear = two lines, each naming the database")
    func appearSameClear() {
        let unknown = [Self.row("Size", "unknown — no file at /x", known: false), Self.row("Schema", "Schema 16", known: true)]
        let first = CatalogDatabaseInfoModel.unknownChanges(was: [:], now: unknown, database: "/x/catalog.sqlite")
        #expect(first == "Catalog Database Info (/x/catalog.sqlite) — Size: unknown — no file at /x")
        let was = ["Size": "unknown — no file at /x"]
        #expect(CatalogDatabaseInfoModel.unknownChanges(was: was, now: unknown, database: "/x/catalog.sqlite") == nil)
        let known = [Self.row("Size", "1 MB", known: true)]
        #expect(CatalogDatabaseInfoModel.unknownChanges(was: was, now: known, database: "/x/catalog.sqlite")
                == "Catalog Database Info (/x/catalog.sqlite) — Size: known again")
    }
}
