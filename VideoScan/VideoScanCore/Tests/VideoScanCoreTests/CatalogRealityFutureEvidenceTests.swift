// CatalogRealityFutureEvidenceTests.swift — Codex sweep 2026-11-09 (P0 F1):
// a Validate dated in the future is no proof; the band is not green on it.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Catalog reality — a future-dated Validate is no proof (Codex sweep 11/09 F1)")
struct CatalogRealityFutureEvidenceTests {

    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("RED: completed tomorrow → yellow 'Needs validation', words say dated in the future; 4 min of skew is still green")
    func futureValidate() {
        let tomorrow = CatalogRealityFacts(validation: .completed(at: now.addingTimeInterval(86_400)), rowsToCheck: 10, rowsNotChecked: 0)
        #expect(CatalogRealityPolicy.colour(tomorrow, now: now) == .yellow)
        let reasons = CatalogRealityPolicy.reasons(tomorrow, now: now)
        #expect(reasons.count == 1)
        if let r = reasons.first {
            #expect(r.shortWords == "Needs validation")
            #expect(CatalogRealityPolicy.words(r, now: now).contains("dated in the future"))
        }
        let skew = CatalogRealityFacts(validation: .completed(at: now.addingTimeInterval(240)), rowsToCheck: 10, rowsNotChecked: 0)
        #expect(CatalogRealityPolicy.colour(skew, now: now) == .green)
    }

    @Test("RED (re-review F1): a fully covered freshness row dated tomorrow is not current")
    func freshnessRowFutureIsNotCurrent() {
        var row = FreshnessRow(kind: "integrity", title: "Integrity", eligible: 10, covered: 10, offline: 0,
                               lastCompleted: now.addingTimeInterval(86_400), lastOutcome: .ok)
        row.cadence = .seconds(CatalogRealityPolicy.freshFor)
        #expect(FreshnessPolicy.staleness(row, now: now) != nil, "a row dated tomorrow judged current")
        row.lastCompleted = now.addingTimeInterval(-3_600)
        #expect(FreshnessPolicy.staleness(row, now: now) == nil, "an hour ago is current")
    }
}
