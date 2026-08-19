// TriageCleanedFilterTests.swift
// Logic + scale coverage for the derived "Cleaned up" triage filter
// (feature/triage-cleaned-filter, 2026-07-08).
//
// The filter is DERIVED provenance, not a stored tag: a record is
// "Cleaned up" iff `cleanupRecipeID != nil` (set by CleanupJob when it
// catalogs a recipe's output). The testable seam is
// `TriageFilter.matches(_:)` — the single predicate TriageView routes
// BOTH `filteredRecords` and the sidebar count badges through, so these
// tests pin the table contents and the badge numbers at once.
//
// Dimensions covered here (per the feature-test checklist):
//   1. Logic  — cleaned matches / non-cleaned doesn't / mixed-100 exact set,
//               plus a regression sweep over the pre-existing cases since
//               the refactor routed them through the same seam.
//   2. Scale  — the predicate is evaluated per-record in the sidebar's
//               count path (same mechanism as the sibling filters), so
//               pin a full count pass at 100k records under a budget no
//               accidentally-quadratic implementation could meet.
// No media / isolation dimensions: the predicate never opens files and
// reads no global state.

import Testing
import Foundation
@testable import VideoScan

struct TriageCleanedFilterTests {

    // MARK: Fixtures

    /// Minimal synthetic record. `cleaned: true` stamps the same
    /// provenance pair CleanupJob.catalogCleanupOutput writes.
    private func record(cleaned: Bool,
                        disposition: MediaDisposition = .unreviewed,
                        workspace: Bool = false,
                        index: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.filename = cleaned ? "clip\(index)_cleaned.mov" : "clip\(index).mov"
        r.fullPath = "/Volumes/TestVol/dir\(index % 13)/\(r.filename)"
        r.mediaDisposition = disposition
        r.workspaceActive = workspace
        if cleaned {
            r.cleanupRecipeID = "vhs-quick-clean"
            r.cleanupRecipeVersion = 1
        }
        return r
    }

    // MARK: - 1. Logic

    @Test("a record with cleanupRecipeID set matches the Cleaned up filter")
    func cleanedRecordMatches() {
        let rec = record(cleaned: true)
        #expect(TriageFilter.cleaned.matches(rec))
    }

    @Test("a record without cleanupRecipeID does not match the Cleaned up filter")
    func uncleanedRecordDoesNotMatch() {
        let rec = record(cleaned: false)
        #expect(!TriageFilter.cleaned.matches(rec))
        // A recipe version alone (inconsistent state — should never
        // happen, version is documented nil-when-id-is-nil) still does
        // not count as cleaned: the id is the provenance key.
        rec.cleanupRecipeVersion = 1
        #expect(!TriageFilter.cleaned.matches(rec))
    }

    @Test("mixed 100-record set filters to exactly the cleaned records")
    func mixedHundredExactSet() {
        // Every 7th record is cleaned; dispositions vary so the test
        // proves the cleaned predicate is orthogonal to disposition.
        let dispositions: [MediaDisposition] =
            [.unreviewed, .important, .suspectedJunk, .confirmedJunk, .recoverable]
        let records = (0..<100).map { i in
            record(cleaned: i % 7 == 0,
                   disposition: dispositions[i % dispositions.count],
                   index: i)
        }
        let expectedIDs = Set(records.filter { $0.cleanupRecipeID != nil }.map(\.id))
        #expect(expectedIDs.count == 15)   // ceil(100/7)

        let matched = records.filter { TriageFilter.cleaned.matches($0) }
        #expect(Set(matched.map(\.id)) == expectedIDs)
    }

    @Test("pre-existing filter cases are unchanged by the matches(_:) seam",
          arguments: [
            TriageFilter.all, .untriaged, .important, .suspectedJunk,
            .confirmedJunk, .recoverable, .workspace,
          ])
    func existingCasesUnchanged(filter: TriageFilter) {
        // Regression sweep: filteredRecords/countFor previously carried
        // two hand-duplicated switches; both now route through
        // matches(_:). Pin each legacy case's semantics against the
        // original inline predicates.
        let records = [
            record(cleaned: false, disposition: .unreviewed,    index: 0),
            record(cleaned: true,  disposition: .important,     index: 1),
            record(cleaned: false, disposition: .suspectedJunk, index: 2),
            record(cleaned: false, disposition: .confirmedJunk, index: 3),
            record(cleaned: true,  disposition: .recoverable,   index: 4),
            record(cleaned: false, disposition: .unreviewed, workspace: true, index: 5),
        ]

        let expected: (VideoRecord) -> Bool
        switch filter {
        case .all:           expected = { _ in true }
        case .untriaged:     expected = { $0.mediaDisposition == .unreviewed }
        case .important:     expected = { $0.mediaDisposition == .important }
        case .suspectedJunk: expected = { $0.mediaDisposition == .suspectedJunk }
        case .confirmedJunk: expected = { $0.mediaDisposition == .confirmedJunk }
        case .recoverable:   expected = { $0.mediaDisposition == .recoverable }
        case .workspace:     expected = { $0.workspaceActive }
        case .underConstruction: expected = { $0.lifecycleStage == .workbench }   // Workbench merge 2026-08-19
        case .cleaned:       expected = { $0.cleanupRecipeID != nil }
        }

        for rec in records {
            #expect(filter.matches(rec) == expected(rec),
                    "\(filter) disagreed with legacy predicate for \(rec.filename)")
        }
    }

    // MARK: - 2. Scale (100k, explicit budget)

    @Test("Cleaned up count pass over 100k records stays inside budget",
          .timeLimit(.minutes(1)))
    func countPassAt100kWithinBudget() {
        let records = (0..<100_000).map { i in
            record(cleaned: i % 250 == 0, index: i)
        }

        let start = Date()
        let count = records.filter { TriageFilter.cleaned.matches($0) }.count
        let elapsed = Date().timeIntervalSince(start)

        #expect(count == 400)
        // One linear pass over 100k plain property reads is
        // single-digit milliseconds even in a Debug build on the M1.
        // 2s is a complexity-class sensor (O(n) → O(n²) would blow
        // through it), not a micro-benchmark.
        #expect(elapsed < 2.0,
                "Cleaned count pass took \(elapsed)s at 100k records — expected well under 2s")
    }
}
