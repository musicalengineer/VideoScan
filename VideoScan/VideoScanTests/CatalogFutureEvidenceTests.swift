// CatalogFutureEvidenceTests.swift — Codex sweep 2026-11-09 (cycle #261,
// "catalog check scheduling", P0 F1): a check record dated in the FUTURE (a
// copied record, a clock that stepped back) is no proof. Before the fix the
// Database and Files lines took a negative age as fresh (green), and the
// daily scheduler took the OLDER of the two steps' dates before its own
// future test, so one future-dated step hid behind the other and the slot
// read as "finished" — no check ran.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let hour: TimeInterval = 3_600

@Suite("Catalog Status — future-dated evidence is no proof (Codex sweep 11/09 F1)")
struct CatalogFutureEvidenceTests {

    private static func d(_ date: Date) -> String { "D\(Int(date.timeIntervalSince1970))" }

    @Test("RED: an integrity pass dated tomorrow is not green; a few minutes of clock skew still is")
    func databaseFutureDated() {
        let tomorrow = CatalogStatusLinesPolicy.database(IntegrityReportFacts(lastCompleted: now.addingTimeInterval(24 * hour), outcome: .ok),
                                                         now: now, date: Self.d)
        #expect(tomorrow.state == .yellow, Comment(rawValue: tomorrow.words))
        #expect(tomorrow.words.contains("dated in the future"), Comment(rawValue: tomorrow.words))
        let skew = CatalogStatusLinesPolicy.database(IntegrityReportFacts(lastCompleted: now.addingTimeInterval(4 * 60), outcome: .ok),
                                                     now: now, date: Self.d)
        #expect(skew.state == .green, Comment(rawValue: skew.words))
    }

    @Test("RED: a completed, all-present file check dated tomorrow is not green")
    func filesFutureDated() {
        let record = CatalogAuditRunRecord(startedAt: now.addingTimeInterval(23 * hour), finishedAt: now.addingTimeInterval(24 * hour),
                                           outcome: .completed, partial: false, counts: ["planned": 10, "present": 10])
        let line = CatalogStatusLinesPolicy.files(CatalogFreshnessFacts(audit: record), missing: MissingCopyCounts(), now: now, date: Self.d)
        #expect(line.state == .yellow, Comment(rawValue: line.words))
        #expect(line.words.contains("dated in the future"), Comment(rawValue: line.words))
    }

    @Test("RED: one step dated in the future never hides behind the other — no finished check, so the 03:30 slot is due")
    func schedulerSeesEachStep() {
        var nyc = Calendar(identifier: .gregorian)
        nyc.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let five = nyc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 5)) ?? now
        func row(_ date: Date) -> FreshnessRow {
            FreshnessRow(kind: "k", title: "t", eligible: 1, covered: 1, offline: 0, lastCompleted: date, lastOutcome: .ok)
        }
        let files = row(five.addingTimeInterval(-hour))          // 04:00 today
        let integrity = row(five.addingTimeInterval(24 * hour))  // tomorrow
        for (f, i) in [(files, integrity), (integrity, files)] {
            let last = DailyFileCheckPolicy.lastFinished(files: f, integrity: i, now: five)
            #expect(last == nil, "a future-dated step is no finished check (got \(String(describing: last)))")
            let decision = DailyFileCheckPolicy.decide(.init(now: five, lastFinished: last, busy: nil, idleSeconds: 0,
                                                             launchLookOwed: false, lastStarted: nil), calendar: nyc)
            #expect(decision == .start(.slot))
        }
    }
}
