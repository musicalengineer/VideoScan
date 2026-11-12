// CatalogStatusLinesTests.swift
// Catalog Status answers three questions (Rick 2026-11-01): Database,
// Files, Content — one coloured line each; the menu title names the worst.
//
//   LOGIC     — the Database colour on the 7-day backstop (6 d 23 h 59 pass →
//               green, 7 d 01 min → yellow, found something → red; stopped,
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
private let week: TimeInterval = 7 * 86_400
private func d(_ date: Date) -> String { "D\(Int(date.timeIntervalSince1970))" }

@Suite("Catalog Status lines — logic")
struct CatalogStatusLinesLogicTests {

    static func passed(at: Date) -> IntegrityReportFacts {
        IntegrityReportFacts(lastCompleted: at, outcome: .ok)
    }

    @Test("Database: a pass 23 h 59 min ago and 25 h ago is green; exactly 7 days is green; 7 d 01 min is yellow; found something is red")
    func databaseOnTheBoundary() {
        let green = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-(23 * hour + 59 * 60))), now: now, date: d)
        #expect(green.state == .green)
        #expect(green.words == "Integrity check passed D\(Int(now.timeIntervalSince1970 - 23 * hour - 59 * 60)) (23 h ago)")
        // The 11/07 regression: 24 h passing alone no longer turns it yellow.
        let dayOld = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-25 * hour)), now: now, date: d)
        #expect(dayOld.state == .green, "25 h old is within the 7-day backstop: \(dayOld.words)")
        let exactly = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-week)), now: now, date: d)
        #expect(exactly.state == .green, "7 days exactly is still within the backstop")
        let late = CatalogStatusLinesPolicy.database(Self.passed(at: now.addingTimeInterval(-(week + 60))), now: now, date: d)
        #expect(late.state == .yellow)
        #expect(late.words.hasPrefix("Yellow: the last integrity check passed") && late.words.hasSuffix("— older than 7 days. Fix: Check Now… runs it again"),
                Comment(rawValue: late.words))
        // RED 2026-11-02 (flipped): a decision count alone never colours the
        // line — 19 measured-silence files have no clearing verb (DECISIONS
        // 2026-10-20 "N to review never changes the colour", restored).
        var found = Self.passed(at: now.addingTimeInterval(-hour))
        found.needsDecision = 19
        found.decisionWords = "19 headers say sound the print never heard"
        let notRed = CatalogStatusLinesPolicy.database(found, now: now, date: d)
        #expect(notRed.state == .green, "needsDecision > 0 and no break: green when fresh (got \(notRed.state))")
        #expect(!notRed.words.contains("headers") && !notRed.words.contains("to look at") && notRed.detail.isEmpty, Comment(rawValue: notRed.words))
        found.lastCompleted = now.addingTimeInterval(-(week + 60))
        #expect(CatalogStatusLinesPolicy.database(found, now: now, date: d).state == .yellow, "…and yellow only when stale")
        var broke = Self.passed(at: now.addingTimeInterval(-hour))
        broke.reality.breaks = [CatalogRealityCount(count: 1, words: "1 duplicate group holds different digests")]
        #expect(CatalogStatusLinesPolicy.database(broke, now: now, date: d).state == .red, "an integrity break is red")
    }

    @Test("RED 2026-11-02: a tier-5 constraint break is red and the line says why and how — 'Red: <cause> — checked …' then 'Fix: <verb>'; several breaks count and list each 'Why:'; the verb is the rule's own")
    func databaseRedNamesTheBreakAndItsFix() {
        var one = Self.passed(at: now.addingTimeInterval(-hour))
        let matt = "event \"Matt\": a member points at a row that no longer exists (id:0D3F5A2B-1C4E-4F6A-9B8C)"
        one.reality.breaks = [CatalogRealityCount(count: 1, words: CatalogConstraints.Rule.eventMembersExist.words(count: 1),
                                                  fix: CatalogConstraints.Rule.eventMembersExist.fix)]
        one.reality.breakDetails = [matt]
        let red = CatalogStatusLinesPolicy.database(one, now: now, date: d)
        #expect(red.state == .red)
        #expect(red.words == "Red: \(matt) — checked D\(Int(now.timeIntervalSince1970 - hour)) (1 h ago)", Comment(rawValue: red.words))
        #expect(red.detail == ["Fix: \(CatalogConstraints.Rule.eventMembersExist.fix)"], Comment(rawValue: red.detail.joined(separator: " | ")))
        #expect(red.detail[0].hasPrefix("Fix: no verb yet — the folder lists only members whose row exists"), "honest: no door reaches a member whose row is gone")
        #expect(red.detail[0].hasSuffix("then Check Now…"), "Check Now… closes every fix")
        // Two rules, three findings: the words count the rules; each kept finding is a Why; one Fix per rule.
        var several = one
        several.reality.breaks = [CatalogRealityCount(count: 2, words: CatalogConstraints.Rule.oneLiveRowPerPath.words(count: 2),
                                                      fix: CatalogConstraints.Rule.oneLiveRowPerPath.fix),
                                  CatalogRealityCount(count: 1, words: CatalogConstraints.Rule.eventMembersExist.words(count: 1),
                                                      fix: CatalogConstraints.Rule.eventMembersExist.fix)]
        several.reality.breakDetails = ["a.mov: 2 rows share the path /a.mov", "b.mov: 2 rows share the path /a.mov", matt]
        let many = CatalogStatusLinesPolicy.database(several, now: now, date: d)
        #expect(many.state == .red)
        #expect(many.words.hasPrefix("Red: 2 paths have more than one live row · 1 event members point at nothing — checked D"), Comment(rawValue: many.words))
        #expect(many.detail == ["Why: a.mov: 2 rows share the path /a.mov", "Why: b.mov: 2 rows share the path /a.mov", "Why: \(matt)",
                                "Fix: \(CatalogConstraints.Rule.oneLiveRowPerPath.fix)", "Fix: \(CatalogConstraints.Rule.eventMembersExist.fix)"],
                Comment(rawValue: many.detail.joined(separator: " | ")))
        // A break with no fix named still gets the generic verb, never a bare count.
        var bare = one
        bare.reality.breaks = [CatalogRealityCount(count: 1, words: "catalog.json changed without a new generation")]
        bare.reality.breakDetails = []
        #expect(CatalogStatusLinesPolicy.database(bare, now: now, date: d).detail == ["Fix: \(CatalogConstraints.Rule.defaultFix)"])
        // Every coloured state reads "<Colour>: <cause>. Fix: <verb>" — one verb, the same one on every yellow.
        for facts in [IntegrityReportFacts(outcome: .partial), IntegrityReportFacts(), IntegrityReportFacts(predatesSwitch: true)] {
            let y = CatalogStatusLinesPolicy.database(facts, now: now, date: d)
            #expect(y.state == .yellow && y.words.hasPrefix("Yellow: ") && y.words.contains("Fix: Check Now…"), Comment(rawValue: y.words))
        }
        let failed = CatalogStatusLinesPolicy.database(IntegrityReportFacts(outcome: .failed), now: now, date: d)
        #expect(failed.words == "Red: the last integrity check failed. Fix: Check Now… runs it again")
        let unreadable = CatalogStatusLinesPolicy.database(IntegrityReportFacts(problem: "integrity-latest.json can't be read: damaged"), now: now, date: d)
        #expect(unreadable.words.hasPrefix("Red: ") && unreadable.words.contains("Fix: Check Now…"), Comment(rawValue: unreadable.words))
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
        // The 11/07 regression: a day old is green; only past the 7-day backstop is it stale.
        let dayOld = CatalogFreshnessFacts(audit: Self.audit(finished: now.addingTimeInterval(-25 * hour), counts: ["planned": 1, "present": 1]))
        #expect(CatalogStatusLinesPolicy.files(dayOld, missing: missing, now: now, date: d).state == .green)
        let stale = CatalogFreshnessFacts(audit: Self.audit(finished: now.addingTimeInterval(-(week + 60)), counts: ["planned": 1, "present": 1]))
        #expect(CatalogStatusLinesPolicy.files(stale, missing: missing, now: now, date: d).state == .yellow)
        let killed = CatalogFreshnessFacts(audit: Self.audit(.running, finished: nil, counts: [:]))
        #expect(CatalogStatusLinesPolicy.files(killed, missing: missing, now: now, date: d).state == .red)
        let never = CatalogFreshnessFacts()
        #expect(CatalogStatusLinesPolicy.files(never, missing: missing, now: now, date: d).state == .yellow)
        let garbage = CatalogFreshnessFacts(auditProblem: "catalog-audit.json can't be read: damaged")
        #expect(CatalogStatusLinesPolicy.files(garbage, missing: missing, now: now, date: d).state == .red)
    }

    // 2026-11-03 (Rick): Content is never yellow or red; the grey words are
    // "N left to analyze"; the sidecar moved to the Database line (Catalog).
    @Test("Content: counts per analyzer from the cycler stamps; Embedded and Inferred Dates never counted; grey until counted; work left is grey 'N left to analyze', never yellow")
    func content() {
        var report = AnalyzeCoverageReport()
        #expect(CatalogStatusLinesPolicy.content(report).state == .grey)
        #expect(CatalogStatusLinesPolicy.content(report).words == "Counting…")
        report.computedAt = now
        report.byCycler[.embeddedDates] = AnalyzeCoverageCounts(eligible: 50, covered: 10)
        report.byCycler[.dateInference] = AnalyzeCoverageCounts(eligible: 50, covered: 0)
        let green = CatalogStatusLinesPolicy.content(report)
        #expect(green.state == .green, "Embedded and Inferred Dates do not count")
        #expect(green.words == "Up to date")
        #expect(green.detail.last?.hasPrefix("Embedded Dates and Inferred Dates are not counted") == true)
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        report.byCycler[.soundPrints] = AnalyzeCoverageCounts(eligible: 20, covered: 8)
        report.contentFiles = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        let grey = CatalogStatusLinesPolicy.content(report)
        #expect(grey.state == .grey, "work left, nothing running it: normal, not an alarm")
        #expect(grey.words == "660 left to analyze", Comment(rawValue: grey.words))
        #expect(grey.detail.contains("Not yet analyzed: Full Hashes 660 · Sound Prints 12"))
        #expect(grey.detail.first == CatalogStatusLinesPolicy.countsFiles(660), "the window says what N counts")
    }

    @Test("Content is green with nothing left; IN PROGRESS (blue) 'Analyzing N of M files' when work is left and something is on it; grey otherwise (2026-11-03: never yellow)")
    func contentThreeStates() {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        report.contentFiles = AnalyzeCoverageCounts(eligible: 700, covered: 40)
        let idle = CatalogStatusLinesPolicy.content(report, working: false)
        #expect(idle.state == .grey, "work left and nothing on it: grey, never yellow (Rick 2026-11-03)")
        let working = CatalogStatusLinesPolicy.content(report, working: true)
        #expect(working.state == .inProgress)
        #expect(working.words == "Analyzing 40 of 700 files", Comment(rawValue: working.words))
        report.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 700, covered: 700)
        report.contentFiles = AnalyzeCoverageCounts(eligible: 700, covered: 700)
        #expect(CatalogStatusLinesPolicy.content(report, working: true).state == .green, "nothing left is green, running or not")
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
        // 2026-11-03: Content is never the worst line — the title names Database or Files only.
        var red = two; red.content.state = .red; red.database.state = .yellow
        #expect(CatalogStatusLines.menuTitle(red) == "Catalog Status — Database needs attention…")
        var db = green; db.database.state = .yellow
        #expect(CatalogStatusLines.menuTitle(db) == "Catalog Status — Database needs attention…")
        var counting = green; counting.content.state = .grey
        #expect(CatalogStatusLines.menuTitle(counting) == "Catalog Status — Green…", "Content's grey (work left) is normal")
        var offline = green; offline.files.state = .grey
        #expect(CatalogStatusLines.menuTitle(offline) == "Catalog Status…", "a Catalog line not decided yet")
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
        switch CatalogDatabaseInfoLines.validate(verdict, date: d, now: now) {
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

        // A clean pass 7 d 01 min ago (past the backstop).
        let old = now.addingTimeInterval(-(week + 60))
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

    /// Rick's live catalog, 2026-11-02 10:41: 19 tier-3 measured-silence
    /// findings (written as decisions by the build of the day) and one
    /// tier-5 event member pointing at nothing — the line was red "found 20
    /// things to look at" and could never go green. Through the REAL
    /// report store and facts reader, a poisoned report of that shape.
    @Test("RED 2026-11-02 TRUTH: 19 silence findings + 1 event member with NO row → the Database line is red for the member alone, names the event and the verb; the same member REMOVED on purpose (history) → green when fresh with the facts listed under it, yellow when stale; the facts' Last Validate row never counts the silence; the chip and the Analyze menu's first row follow")
    func silenceNeverColoursTheDatabaseLine() throws {
        let dir = try Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        let recent = now.addingTimeInterval(-hour)
        let matt = "event \"Matt\": a member points at a row that no longer exists (id:0D3F5A2B-1C4E-4F6A-9B8C)"
        let history = "event \"Matt\": a member points at a file removed from the catalog (696791735db208e3390a35c6) — kept as history"
        // The file check's record beside it (completed, clean), so the band's one Validate outcome is "completed".
        let marker = CatalogAuditRunMarker()
        marker.attach(catalogFile: catalog.path)
        marker.noteStarted(at: recent.addingTimeInterval(-60))
        var totals = CatalogAuditTotals()
        totals.planned = 6
        totals.add(.present, rows: 6)
        marker.noteFinished(.completed, totals: totals, marked: 0, partial: false, catalogGeneration: nil, at: recent)
        func band(_ facts: CatalogFreshnessFacts) -> CatalogFreshnessState {
            CatalogFreshnessState.judged(rows: [], reality: CatalogRealityFactsBuilder.inputs(facts: facts, missing: MissingCopyCounts()), now: now)
        }
        func poisoned(at date: Date, member: Bool, removed: Bool = false) -> IntegrityReport {
            var r = Self.report(.completed, at: date)
            // The old shape: tier 3 counted the 19 as decisions, and so did each finding.
            var silence = (0..<19).map { i in
                IntegrityFinding(tier: 3, rule: VerifyCatalogTiers.silentPrintRule, recordID: UUID(), filename: "clip\(i).mov",
                                 words: "the header says Video+Audio, but the sound print heard nothing (silent)", needsDecision: true)
            }
            // …and the new shape too (information): both read the same.
            silence[0].needsDecision = false
            var t3 = r.tiers[2]; t3.result = .needsDecision(18); t3.needsDecision = 18; t3.summary = "18 headers say sound the print never heard"
            r.tiers[2] = t3
            r.findings = silence
            if member {
                var t5 = r.tiers[4]
                if removed {
                    t5.result = .couldNotCheck(1); t5.couldNotCheck = 1; t5.catalogFileUnchecked = 0
                    t5.summary = "1 event members point at files removed from the catalog — kept as history · every other relation holds (10 rows)"
                } else {
                    t5.result = .needsDecision(1); t5.needsDecision = 1; t5.summary = "1 event members point at nothing"
                }
                r.tiers[4] = t5
                r.findings.append(IntegrityFinding(tier: 5, rule: CatalogConstraints.Rule.eventMembersExist.rawValue, recordID: nil,
                                                   filename: nil, words: removed ? history : matt, needsDecision: !removed))
            }
            r.findingsTotal = r.findings.count
            return r
        }
        // A member with no row and no tombstone: a real break — red, cause and verb.
        try IntegrityReportStore.write(poisoned(at: recent, member: true), besideCatalogAt: catalog, now: recent)
        var (line, row) = Self.both(dir)
        #expect(line.state == .red)
        #expect(line.words == "Red: \(matt) — checked \(d(recent)) (1 h ago)", Comment(rawValue: line.words))
        #expect(line.detail == ["Fix: \(CatalogConstraints.Rule.eventMembersExist.fix)"], Comment(rawValue: line.detail.joined(separator: " | ")))
        #expect(!line.words.contains("headers") && !line.words.contains("to look at") && !line.detail.joined().contains("silen"),
                "the silence never colours the line nor rides in its red words")
        #expect(row == "completed \(d(recent)) · 1 needs a decision", "the facts row counts the member, never the silence: \(row)")
        var facts = CatalogFreshnessFactsReader.read(catalogFile: catalog.path)
        #expect(facts.integrity.reality.review.contains(CatalogReviewItem(kind: .audioTracksButNoSound, count: 19)), "the 19 are a review item, not a colour")
        func l(_ k: CatalogStatusLineKind, _ c: CatalogStatusLineState) -> CatalogStatusLine { CatalogStatusLine(kind: k, state: c, words: "") }
        #expect(CatalogStatusLines.menuTitle(CatalogStatusLines(database: line, files: l(.files, .green), content: l(.content, .green)))
                == "Catalog Status — Database needs attention…")
        var state = band(facts)
        #expect(state.summary.colour == .red, "the band relays the same break")
        var computed = AnalyzeCoverageReport(); computed.computedAt = now
        #expect(CatalogStatusLinesPolicy.lines(facts: facts, report: computed, now: now).catalog.words == "Unhealthy",
                "the strip's Catalog indicator relays the same break")
        #expect(CatalogAnalyzeMenu.summaryTitle(state).hasPrefix("Needs attention: 1 event members point at nothing"), Comment(rawValue: CatalogAnalyzeMenu.summaryTitle(state)))

        // Rick's actual catalog (11/02): the member was REMOVED on purpose — history. Green, the facts listed under it.
        try IntegrityReportStore.write(poisoned(at: recent, member: true, removed: true), besideCatalogAt: catalog, now: recent)
        (line, row) = Self.both(dir)
        #expect(line.state == .green, Comment(rawValue: line.words))
        #expect(line.words == "Integrity check passed \(d(recent)) (1 h ago)")
        // Tier 5's could-not-check (its informational findings) is the facts' "unverified" line, as before;
        // then the facts the check recorded, in their own words — said, never coloured.
        #expect(line.detail == ["not verified: tier 5 Relations and constraints: 1 event members point at files removed from the catalog — kept as history · every other relation holds (10 rows)",
                                "19 files have a silent audio track (measured)",
                                "1 event members point at files removed from the catalog — kept as history"],
                Comment(rawValue: line.detail.joined(separator: " | ")))
        #expect(row == "completed \(d(recent)) · 1 unverified", Comment(rawValue: row))
        facts = CatalogFreshnessFactsReader.read(catalogFile: catalog.path)
        state = band(facts)
        #expect(state.summary.colour == .green,
                "the band goes green with the line: \(state.summary.colour) / \(state.reality.reasons)")
        #expect(CatalogStatusLinesPolicy.lines(facts: facts, report: computed, now: now).catalog.words == "Synced",
                "the strip's Catalog indicator goes green with the line")
        #expect(CatalogAnalyzeMenu.summaryTitle(state) == "The catalog is reconciled")
        #expect(state.reality.information.contains("1 event members point at files removed from the catalog — kept as history"))
        #expect(CatalogStatusLines.menuTitle(CatalogStatusLines(database: line, files: l(.files, .green), content: l(.content, .green)))
                == "Catalog Status — Green…")

        // Yellow when stale, naming the one verb; the facts still listed.
        let old = now.addingTimeInterval(-(week + 60))
        try IntegrityReportStore.write(poisoned(at: old, member: true, removed: true), besideCatalogAt: catalog, now: old)
        (line, _) = Self.both(dir)
        #expect(line.state == .yellow)
        #expect(line.words == "Yellow: the last integrity check passed \(d(old)) (7 days ago) — older than 7 days. Fix: Check Now… runs it again",
                Comment(rawValue: line.words))
        #expect(line.detail.contains("19 files have a silent audio track (measured)"), Comment(rawValue: line.detail.joined(separator: " | ")))
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

        // Content with work left: grey while idle (never yellow, 2026-11-03), in
        // progress while a counted analyzer runs or the helper RUNS a job that
        // feeds one (Codex 11/03 F2 — the input is that verdict, not "any job").
        var left = report
        left.byCycler[.fullHashes] = AnalyzeCoverageCounts(eligible: 10, covered: 2)
        left.contentFiles = AnalyzeCoverageCounts(eligible: 10, covered: 2)
        snapshot.publish(report: left, facts: facts)
        #expect(snapshot.state.lines?.content.state == .grey)
        #expect(snapshot.state.lines?.content.words == "8 left to analyze")
        snapshot.setRunning([.fullHashes])
        #expect(snapshot.state.lines?.content.state == .inProgress)
        snapshot.setRunning([])
        snapshot.setBackgroundServiceActive(true)
        #expect(snapshot.state.lines?.content.state == .inProgress, "a helper job that feeds a counted analyzer is on it")
    }
}

// MARK: - The background helper's part

@Suite("Catalog Status — the background helper counts as on it only when it can move the count", .serialized)
@MainActor
struct BackgroundServiceActivityTests {

    static func status(_ states: [JobRunState], kind: JobKind = .noop) -> ServiceStatus {
        let jobs = states.map { s in
            JobProgressSnapshot(id: JobRequest(kind: kind, lane: "models", parameters: [:],
                                               resources: JobResourceProfile(peakMemoryBytes: 1, needsResidentModel: false, secondsPerUnitEstimate: 1),
                                               requestedAt: now, requestedBy: "test").id,
                                kind: kind, lane: "models", title: "t", subtitle: "", completedUnits: 0, totalUnits: 1,
                                skippedUnits: 0, failedUnits: 0, state: s, startedAt: nil, finishedAt: nil)
        }
        return ServiceStatus(processIdentifier: 1, startedAt: now, backoff: .full, jobs: jobs, idleSeconds: 0)
    }

    @Test("LOGIC + ISOLATION (Codex 11/03 F2): no job kind the helper runs today feeds a counted analyzer — running, queued, paused, era or noop, none is 'on it'")
    func isActive() {
        for kind in [JobKind.noop, .era] {
            #expect(!BackgroundServiceActivity.isActive(.success(Self.status([.running], kind: kind))), "\(kind)")
            #expect(!BackgroundServiceActivity.isActive(.success(Self.status([.finished, .queued], kind: kind))))
            #expect(!BackgroundServiceActivity.isActive(.success(Self.status([.paused(reason: "thermal")], kind: kind))))
        }
        #expect(!BackgroundServiceActivity.isActive(.success(Self.status([.finished, .stopped, .failed(reason: "x")]))))
        #expect(!BackgroundServiceActivity.isActive(.success(Self.status([]))))
        #expect(!BackgroundServiceActivity.isActive(.failure(Refusal("VideoScan Background did not answer"))), "unreachable = not running")
        #expect(!BackgroundServiceActivity.isActive(nil), "service not enabled: never asked, not running")
    }

    @Test("the poller hands each answer to the snapshot; a disabled service is never asked over XPC")
    func pollerFeedsTheSnapshot() async throws {
        let activity = BackgroundServiceActivity()
        activity.ask = { .success(Self.status([.running], kind: .era)) }
        final class Box { var seen: [BackgroundServiceActivity.Reading] = [] }
        let box = Box()
        activity.start(every: 3_600) { box.seen.append($0) }
        for _ in 0..<50 where box.seen.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        activity.stop()
        #expect(box.seen.map(\.active) == [false], "an era job does not move the counted analyzers")
        #expect(box.seen.first?.eraLine?.hasPrefix("Machine era: 0 of 1 files (VideoScan Background — running)") == true, "\(box.seen)")
        let src = SourceTree.strippingComments(try SourceTree.appSource(named: "BackgroundServiceActivity.swift"))
        #expect(src.contains("guard BackgroundServiceRegistrar.isEnabled else { return nil }"), "asking must never start the helper")
        let app = SourceTree.strippingComments(try SourceTree.appSource(named: "VideoScanApp.swift"))
        #expect(app.contains("catalogModel?.catalogFreshness.setBackgroundServiceActive(reading.active)"))
        #expect(app.contains("catalogModel?.catalogFreshness.setBackgroundEraLine(reading.eraLine)"))
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
        #expect(lines.contains("CatalogRealityPolicy.freshFor"), "the backstop constant is the reality policy's, not a copy")
        #expect(lines.contains("CatalogRealityPolicy.freshForWords"), "and so are its words")
        #expect(!lines.contains("24 * 3_600") && !lines.contains("86_400 *"))
        #expect(!lines.contains("older than 24 hours") && !lines.contains("older than 7 days"), "the words come from freshForWords")
    }
}
