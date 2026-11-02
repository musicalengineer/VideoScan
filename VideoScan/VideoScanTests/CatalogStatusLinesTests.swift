// CatalogStatusLinesTests.swift
// Catalog Status answers three questions (Rick 2026-11-01): Database,
// Files, Content — one coloured line each; the menu title names the worst.
//
//   LOGIC     — the Database colour on the 24-hour boundary (23 h 59 pass →
//               green, 24 h 01 → yellow, found something → red; stopped,
//               never, before the switch → yellow; failed, unreadable → red);
//               Files (present / missing words, unsettled, large share,
//               stale, killed); Content (counts per analyzer; Embedded and
//               Inferred Dates never counted); the worst line and the title
//   TRUTH     — through the REAL report store and audit marker, a fixture
//               per state: the Database line and the Database facts' "Last
//               Validate Catalog" row read the same integrity-latest.json and
//               agree; the Files line's counts are the marker's; the snapshot
//               publishes lines built from exactly the facts and report it holds
//   ISOLATION — a garbage report or marker is red in words, never green
//   SENSOR    — the window walks no records and observes no model; the menu
//               item opens the window; the lines are built in one place

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let hour: TimeInterval = 3_600
private func d(_ date: Date) -> String { "D\(Int(date.timeIntervalSince1970))" }

@Suite("Catalog Status lines — logic")
struct CatalogStatusLinesLogicTests {

    static func passed(at: Date) -> IntegrityReportFacts {
        IntegrityReportFacts(lastCompleted: at, outcome: .ok)
    }

    @Test("Database: a pass 23 h 59 min ago is green; 24 h 01 min is yellow; found something is red")
    func databaseOnTheBoundary() {
        let green = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-(23 * hour + 59 * 60))), now: now, date: d)
        #expect(green.state == .green)
        #expect(green.words == "Integrity check passed D\(Int(now.timeIntervalSince1970 - 23 * hour - 59 * 60)) (23 h ago)")
        let exactly = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-24 * hour)), now: now, date: d)
        #expect(exactly.state == .green, "24 h exactly is still within 24 hours")
        let late = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-(24 * hour + 60))), now: now, date: d)
        #expect(late.state == .yellow)
        #expect(late.words.hasSuffix("— older than 24 hours; Check Now… runs it again"))
        var found = Self.passed(at: now.addingTimeInterval(-hour))
        found.needsDecision = 3
        found.decisionWords = "3 rows share a path"
        let red = CatalogStatusLinesPolicy.database(found, now: now, date: d)
        #expect(red.state == .red)
        #expect(red.words.contains("found 3 things to look at") && red.detail == ["3 rows share a path"])
        var broke = Self.passed(at: now.addingTimeInterval(-hour))
        broke.reality.breaks = [CatalogRealityCount(count: 1, words: "1 duplicate group holds different digests")]
        #expect(CatalogStatusLinesPolicy.database(broke, now: now, date: d).state == .red, "an integrity break is something found")
    }

    @Test("Database: stopped / never / before the switch → yellow; failed / unreadable → red; unverified gaps are said, not coloured")
    func databaseOtherStates() {
        #expect(CatalogStatusLinesPolicy.database(IntegrityReportFacts(outcome: .partial), now: now, date: d).state == .yellow)
        #expect(CatalogStatusLinesPolicy.database(IntegrityReportFacts(), now: now, date: d).state == .yellow)
        #expect(CatalogStatusLinesPolicy.database(IntegrityReportFacts(predatesSwitch: true), now: now, date: d).state == .yellow)
        #expect(CatalogStatusLinesPolicy.database(IntegrityReportFacts(outcome: .failed), now: now, date: d).state == .red)
        let bad = CatalogStatusLinesPolicy.database(IntegrityReportFacts(problem: "integrity-latest.json can't be read: damaged"), now: now, date: d)
        #expect(bad.state == .red && bad.words.contains("damaged"))
        var gaps = Self.passed(at: now.addingTimeInterval(-hour))
        gaps.unverified = 660
        gaps.unverifiedWords = "tier 1 File identity: 660 files still have only a sampled hash"
        let g = CatalogStatusLinesPolicy.database(gaps, now: now, date: d)
        #expect(g.state == .green && g.detail == ["not verified: tier 1 File identity: 660 files still have only a sampled hash"])
    }

    static func audit(_ outcome: CatalogAuditRunRecord.Outcome = .completed, finished: Date? = now.addingTimeInterval(-hour),
                      counts: [String: Int], partial: Bool = false) -> CatalogAuditRunRecord {
        CatalogAuditRunRecord(startedAt: (finished ?? now).addingTimeInterval(-60), finishedAt: finished, outcome: outcome,
                              partial: partial, counts: counts)
    }

    @Test("Files: present and missing in words; a Missing file that is missing never colours the line; unsettled, a large share, stale → yellow; killed or unreadable → red")
    func files() {
        let missing = MissingCopyCounts(noOtherCopy: 2, otherCopyPresent: 1, possibleCopyNotProven: 0)
        let clean = CatalogFreshnessFacts(audit: Self.audit(counts: ["planned": 100, "present": 97, "cameBack": 1, "gone": 2]))
        let g = CatalogStatusLinesPolicy.files(clean, missing: missing, now: now, date: d)
        #expect(g.state == .green)
        #expect(g.words.hasPrefix("98 present where the catalog says · 3 missing · checked D"))
        let changed = CatalogFreshnessFacts(audit: Self.audit(counts: ["planned": 100, "present": 96, "changed": 4]))
        let y = CatalogStatusLinesPolicy.files(changed, missing: missing, now: now, date: d)
        #expect(y.state == .yellow && y.detail.contains { $0.contains("4 files changed size on disk") })
        let offline = CatalogFreshnessFacts(audit: Self.audit(counts: ["planned": 100, "present": 80, "notAsked": 20]))
        #expect(CatalogStatusLinesPolicy.files(offline, missing: missing, now: now, date: d).state == .yellow)
        let stale = CatalogFreshnessFacts(audit: Self.audit(finished: now.addingTimeInterval(-25 * hour), counts: ["planned": 1, "present": 1]))
        #expect(CatalogStatusLinesPolicy.files(stale, missing: missing, now: now, date: d).state == .yellow)
        let killed = CatalogFreshnessFacts(audit: Self.audit(.running, finished: nil, counts: [:]))
        #expect(CatalogStatusLinesPolicy.files(killed, missing: missing, now: now, date: d).state == .red)
        let never = CatalogFreshnessFacts()
        #expect(CatalogStatusLinesPolicy.files(never, missing: missing, now: now, date: d).state == .yellow)
        let garbage = CatalogFreshnessFacts(auditProblem: "catalog-audit.json can't be read: damaged")
        #expect(CatalogStatusLinesPolicy.files(garbage, missing: missing, now: now, date: d).state == .red)
    }

    @Test("Content: counts per analyzer from the cycler stamps; Embedded and Inferred Dates never counted; grey until counted; an unreadable sound sidecar is red")
    func content() {
        var report = AnalyzeCoverageReport()
        #expect(CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil).state == .grey)
        report.computedAt = now
        report.byCycler[.embeddedDates] = AnalyzeCoverageCounts(eligible: 50, covered: 10)
        report.byCycler[.dateInference] = AnalyzeCoverageCounts(eligible: 50, covered: 0)
        let green = CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil)
        #expect(green.state == .green, "Embedded and Inferred Dates do not count")
        #expect(green.detail.last?.hasPrefix("Embedded Dates and Inferred Dates are not counted") == true)
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        report.byCycler[.soundPrints] = AnalyzeCoverageCounts(eligible: 20, covered: 8)
        let yellow = CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil)
        #expect(yellow.state == .yellow)
        #expect(yellow.words == "Not yet analyzed: Full Hashes 660 · Sound Prints 12 — nothing is running it")
        #expect(CatalogStatusLinesPolicy.content(report, soundStoreProblem: "not a database").state == .red)
    }

    @Test("RED 2026-11-01 evening: Content is green with nothing left; IN PROGRESS when work is left and something is on it; yellow only when nothing will do it")
    func contentThreeStates() {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        let idle = CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil, working: false)
        #expect(idle.state == .yellow, "work left and nothing will do it: you must act")
        let working = CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil, working: true)
        #expect(working.state == .inProgress)
        #expect(working.words.hasPrefix("In progress — not yet analyzed: Full Hashes 660"), Comment(rawValue: working.words))
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 700)
        #expect(CatalogStatusLinesPolicy.content(report, soundStoreProblem: nil, working: true).state == .green, "nothing left is green, running or not")
        // What counts as "on it": a counted analyzer running, or the helper.
        #expect(CatalogStatusLinesPolicy.contentIsWorking(running: [.fullHashes], backgroundActive: false))
        #expect(CatalogStatusLinesPolicy.contentIsWorking(running: [.sceneCaptions], backgroundActive: false))
        #expect(CatalogStatusLinesPolicy.contentIsWorking(running: [], backgroundActive: true))
        #expect(!CatalogStatusLinesPolicy.contentIsWorking(running: [.filePresence, .integrity, .embeddedDates], backgroundActive: false),
                "Validate and the uncounted analyzers do not make Content 'in progress'")
        // The title names only lines that need attention.
        func l(_ k: CatalogStatusLineKind, _ c: CatalogStatusLineState) -> CatalogStatusLine { CatalogStatusLine(kind: k, state: c, words: "") }
        #expect(CatalogStatusLines.menuTitle(CatalogStatusLines(database: l(.database, .green), files: l(.files, .green),
                                                                content: l(.content, .inProgress))) == "Catalog Status — Green…")
        #expect(CatalogStatusLines.menuTitle(CatalogStatusLines(database: l(.database, .green), files: l(.files, .yellow),
                                                                content: l(.content, .inProgress))) == "Catalog Status — Files needs attention…")
    }

    @Test("the worst line names the title: all green → Green…; red beats yellow; ties go Database, Files, Content; uncounted → Catalog Status…")
    func worstAndTitle() {
        func l(_ k: CatalogStatusLineKind, _ c: CatalogStatusLineState) -> CatalogStatusLine { CatalogStatusLine(kind: k, state: c, words: "") }
        let green = CatalogStatusLines(database: l(.database, .green), files: l(.files, .green), content: l(.content, .green))
        #expect(CatalogStatusLines.menuTitle(green) == "Catalog Status — Green…")
        #expect(green.worst == nil)
        var two = green; two.files.state = .yellow; two.content.state = .yellow
        #expect(CatalogStatusLines.menuTitle(two) == "Catalog Status — Files needs attention…")
        var red = two; red.content.state = .red; red.database.state = .yellow
        #expect(CatalogStatusLines.menuTitle(red) == "Catalog Status — Content needs attention…")
        var db = green; db.database.state = .yellow
        #expect(CatalogStatusLines.menuTitle(db) == "Catalog Status — Database needs attention…")
        var counting = green; counting.content.state = .grey
        #expect(CatalogStatusLines.menuTitle(counting) == "Catalog Status…")
        #expect(CatalogStatusLines.menuTitle(nil) == "Catalog Status…")
        #expect(CatalogStatusWords.menuTitle(CatalogFreshnessState()) == "Catalog Status…", "not computed yet")
    }
}

// MARK: - Truth, through the real files

@Suite("Catalog Status lines — truth: the same sources as the facts", .serialized)
@MainActor
struct CatalogStatusLinesTruthTests {

    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csl_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func tier(_ n: Int, at date: Date, decisions: Int = 0) -> IntegrityTier {
        IntegrityTier(tier: n, name: VerifyCatalogTiers.name(n), verifiedAt: date,
                      result: decisions > 0 ? .needsDecision(decisions) : .ok,
                      checked: 10, passed: 10 - decisions, needsDecision: decisions, summary: decisions > 0 ? "\(decisions) rows share a path" : "ok")
    }

    private static func report(_ outcome: IntegrityReport.Outcome, at date: Date, decisions: Int = 0) -> IntegrityReport {
        let id = UUID()
        var tiers = [0, 1, 3, 4].map { tier($0, at: date) } + [tier(5, at: date, decisions: decisions)]
        tiers = tiers.map { var t = $0; t.runID = t.tier == 0 ? nil : id; return t }
        tiers += [VerifyCatalogTiers.notBuilt(2, "weekly deep pass — not built yet").tier,
                  VerifyCatalogTiers.notBuilt(6, "truth sweep — not built yet").tier]
        return IntegrityReport(runID: id, startedAt: date.addingTimeInterval(-5), verifiedAt: outcome == .completed ? date : nil,
                               outcome: outcome, catalogFile: "/x/catalog.json", rowsTotal: 10, rowsLive: 10, elapsedSeconds: 5,
                               tiers: tiers, findings: [], findingsTotal: decisions)
    }

    /// The Database line from the snapshot's facts, and the Database facts' row, from ONE folder.
    private static func both(_ dir: URL) -> (line: CatalogStatusLine, row: String) {
        let catalog = dir.appendingPathComponent("catalog.json")
        let facts = CatalogFreshnessFactsReader.read(catalogFile: catalog.path)
        let line = CatalogStatusLinesPolicy.database(facts.integrity, now: now, date: d)
        let verdict = CatalogDatabaseInfoGather.integrity(catalogFile: catalog)
        let row: String
        switch CatalogDatabaseInfoLines.validate(verdict, date: d) {
        case .known(let v): row = v
        case .unknown(let why): row = "unknown — " + why
        }
        return (line, row)
    }

    @Test("TRUTH: a fixture per state — the Database line and the facts' Last Validate row read the same report and agree")
    func databaseLineAndFactsAgree() throws {
        let dir = try Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")

        // No report.
        var (line, row) = Self.both(dir)
        #expect(line.state == .yellow && row.hasPrefix("unknown — no integrity-latest.json"))

        // A clean pass 23 h 59 min ago.
        let recent = now.addingTimeInterval(-(23 * hour + 59 * 60))
        try IntegrityReportStore.write(Self.report(.completed, at: recent), besideCatalogAt: catalog, now: recent)
        (line, row) = Self.both(dir)
        #expect(line.state == .green, Comment(rawValue: line.words))
        #expect(row == "completed \(d(recent)) · nothing to decide")
        #expect(line.words.contains(d(recent)), "the same date in both")

        // A clean pass 24 h 01 min ago.
        let old = now.addingTimeInterval(-(24 * hour + 60))
        try IntegrityReportStore.write(Self.report(.completed, at: old), besideCatalogAt: catalog, now: old)
        (line, row) = Self.both(dir)
        #expect(line.state == .yellow && row == "completed \(d(old)) · nothing to decide")

        // Found something.
        try IntegrityReportStore.write(Self.report(.completed, at: recent, decisions: 3), besideCatalogAt: catalog, now: recent)
        (line, row) = Self.both(dir)
        #expect(line.state == .red && row.contains("3 need a decision"))

        // Stopped.
        try IntegrityReportStore.write(Self.report(.stopped, at: recent), besideCatalogAt: catalog, now: recent)
        (line, row) = Self.both(dir)
        #expect(line.state == .yellow && row.hasPrefix("stopped"))

        // ISOLATION: garbage.
        try Data("not json".utf8).write(to: dir.appendingPathComponent(IntegrityReportStore.latestFileName))
        (line, row) = Self.both(dir)
        #expect(line.state == .red && row.hasPrefix("unknown — ") && line.words.contains("can't be read"))
    }

    @Test("TRUTH: the Files line counts are the real marker's; the snapshot publishes lines built from exactly its facts and report")
    func filesLineAndSnapshot() throws {
        let dir = try Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json").path
        let realNow = Date()          // the snapshot judges against the clock
        let marker = CatalogAuditRunMarker()
        marker.attach(catalogFile: catalog)
        marker.noteStarted(at: realNow.addingTimeInterval(-2 * hour))
        var totals = CatalogAuditTotals()
        totals.planned = 6
        totals.add(.present, rows: 4)
        totals.add(.gone, rows: 1)
        totals.add(.cameBack, rows: 1)
        marker.noteFinished(.completed, totals: totals, marked: 2, partial: false, catalogGeneration: nil,
                            at: realNow.addingTimeInterval(-hour))
        let facts = CatalogFreshnessFactsReader.read(catalogFile: catalog)
        var report = AnalyzeCoverageReport()
        report.computedAt = realNow
        report.missingCopies = MissingCopyCounts(noOtherCopy: 1, otherCopyPresent: 0, possibleCopyNotProven: 0)
        let files = CatalogStatusLinesPolicy.files(facts, missing: report.missingCopies, now: realNow, date: d)
        #expect(files.state == .green)
        #expect(files.words.hasPrefix("5 present where the catalog says · 1 missing · checked D"))

        let snapshot = CatalogFreshnessSnapshot()
        snapshot.publish(report: report, facts: facts)
        let lines = try #require(snapshot.state.lines)
        let expected = CatalogStatusLinesPolicy.lines(facts: facts, report: report, now: realNow)
        #expect(lines == expected, "the snapshot's lines are the policy over the facts and report it holds")
        #expect(CatalogStatusWords.menuTitle(snapshot.state) == CatalogStatusLines.menuTitle(lines))
        #expect(CatalogStatusWords.menuTitle(snapshot.state) == "Catalog Status — Database needs attention…",
                "no report beside this catalog: the Database line is the worst")

        // Content with work left: yellow while idle, in progress while a counted
        // analyzer runs or the helper has a job — through the snapshot's own inputs.
        var left = report
        left.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 10, covered: 2)
        snapshot.publish(report: left, facts: facts)
        #expect(snapshot.state.lines?.content.state == .yellow)
        snapshot.setRunning([.fullHashes])
        #expect(snapshot.state.lines?.content.state == .inProgress)
        snapshot.setRunning([])
        snapshot.setBackgroundServiceActive(true)
        #expect(snapshot.state.lines?.content.state == .inProgress, "the background helper is on it")
    }
}

// MARK: - The background helper's part

@Suite("Catalog Status — the background helper counts as on it", .serialized)
@MainActor
struct BackgroundServiceActivityTests {

    static func status(_ states: [JobRunState]) -> ServiceStatus {
        let jobs = states.map { s in
            JobProgressSnapshot(id: JobRequest(kind: .noop, lane: "models", parameters: [:],
                                               resources: JobResourceProfile(peakMemoryBytes: 1, needsResidentModel: false, secondsPerUnitEstimate: 1),
                                               requestedAt: now, requestedBy: "test").id,
                                kind: .noop, lane: "models", title: "t", subtitle: "", completedUnits: 0, totalUnits: 1,
                                skippedUnits: 0, failedUnits: 0, state: s, startedAt: nil, finishedAt: nil)
        }
        return ServiceStatus(processIdentifier: 1, startedAt: now, backoff: .full, jobs: jobs, idleSeconds: 0)
    }

    @Test("LOGIC + ISOLATION: a job queued, running or paused is 'on it'; only done jobs, no answer or an unreachable helper is not")
    func isActive() {
        #expect(BackgroundServiceActivity.isActive(.success(Self.status([.running]))))
        #expect(BackgroundServiceActivity.isActive(.success(Self.status([.finished, .queued]))))
        #expect(BackgroundServiceActivity.isActive(.success(Self.status([.paused(reason: "thermal")]))))
        #expect(!BackgroundServiceActivity.isActive(.success(Self.status([.finished, .stopped, .failed(reason: "x")]))))
        #expect(!BackgroundServiceActivity.isActive(.success(Self.status([]))))
        #expect(!BackgroundServiceActivity.isActive(.failure(Refusal("VideoScan Background did not answer"))), "unreachable = not running")
        #expect(!BackgroundServiceActivity.isActive(nil), "service not enabled: never asked, not running")
    }

    @Test("the poller hands each answer to the snapshot; a disabled service is never asked over XPC")
    func pollerFeedsTheSnapshot() async throws {
        let activity = BackgroundServiceActivity()
        activity.ask = { .success(Self.status([.running])) }
        final class Box { var seen: [Bool] = [] }
        let box = Box()
        activity.start(every: 3_600) { box.seen.append($0) }
        for _ in 0..<50 where box.seen.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        activity.stop()
        #expect(box.seen == [true])
        let src = SourceTree.strippingComments(try SourceTree.appSource(named: "BackgroundServiceActivity.swift"))
        #expect(src.contains("guard BackgroundServiceRegistrar.isEnabled else { return nil }"), "asking must never start the helper")
        let app = SourceTree.strippingComments(try SourceTree.appSource(named: "VideoScanApp.swift"))
        #expect(app.contains("catalogModel?.catalogFreshness.setBackgroundServiceActive(active)"))
    }
}

// MARK: - Sensors

@Suite("Catalog Status window — sensors")
@MainActor
struct CatalogStatusWindowSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: the window walks no records and observes no model; Check Now… is the menu's Validate sheet; Reopen / Adopt only when they apply")
    func theWindow() throws {
        let w = try Self.code("CatalogStatusWindow.swift")
        for walk in ["model.records", "records.filter", "for r in records", "records.count", "@EnvironmentObject", "@ObservedObject var model"] {
            #expect(!w.contains(walk), "the window does \(walk)")
        }
        #expect(w.contains("ValidateCatalogSheet(model: model, center: center)"))
        #expect(w.contains("if cutover.canReopen || cutover.canAdopt { restore }"))
        #expect(w.contains("CatalogStatusBand("), "the band's details, the same view as Content Analysis")
        #expect(!w.contains("extension VideoScanModel"))
        let reopen = try Self.code("CatalogReopenMenuItems.swift")
        #expect(reopen.contains("if cutover.canReopen {") && reopen.contains("if cutover.canAdopt {"))
        let item = try Self.code("CatalogStatusMenuItem.swift")
        #expect(item.contains("openWindow(id: CatalogStatusWindow.sceneID)"))
        #expect(item.contains("CatalogStatusWords.menuTitle(freshness.state)"))
    }

    @Test("SENSOR: the three lines are built in ONE place, from the facts and report the band reads")
    func builtOnce() throws {
        let snap = try Self.code("CatalogFreshnessSnapshot.swift")
        #expect(snap.contains("new.lines = CatalogStatusLinesPolicy.lines(facts: facts, report: report, now: now,"))
        #expect(snap.contains("working: CatalogStatusLinesPolicy.contentIsWorking(running: running,"), "Content's 'in progress' reads the same running set")
        var count = 0
        for source in SourceTree.appSources {
            let text = SourceTree.strippingComments(try String(contentsOf: source.url, encoding: .utf8))
            count += text.components(separatedBy: "CatalogStatusLinesPolicy.lines(").count - 1
        }
        #expect(count == 1, "one call site in the app")
        let lines = try Self.code("CatalogStatusLines.swift")
        #expect(lines.contains("CatalogRealityPolicy.freshFor"), "the 24-hour constant is the reality policy's, not a copy")
        #expect(!lines.contains("24 * 3_600") && !lines.contains("86_400 *"))
    }
}
