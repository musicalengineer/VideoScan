// CatalogRealityTests.swift
// THE colour of the Catalog Status band (Rick 2026-10-20): does the catalog
// reflect reality? One test per colour and per reason, the boundaries
// (7 days; the 10 % share not checked), the headline words, and the SENSOR
// that review items never move the band off green — at production scale.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Catalog reality — the band's colour")
struct CatalogRealityTests {

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400

    /// The catalog reflects reality: validated yesterday, everything checked, nothing broken or unsettled.
    var green: CatalogRealityFacts {
        CatalogRealityFacts(validation: .completed(at: now.addingTimeInterval(-day)), rowsToCheck: 14_000, rowsNotChecked: 0)
    }

    @Test("GREEN: a fresh, completed Validate, nothing broken, nothing unsettled — 'The catalog is reconciled'")
    func greenReflectsReality() {
        #expect(CatalogRealityPolicy.colour(green, now: now) == .green)
        let v = CatalogRealityPolicy.judge(green, now: now)
        #expect(v.headline == "The catalog is reconciled")
        #expect(v.reasons.isEmpty && v.reviewLine == nil)
    }

    @Test("GREEN still: exactly 7 days is fresh; a few rows not checked (under 10 %) is fine")
    func greenBoundaries() {
        var f = green
        f.validation = .completed(at: now.addingTimeInterval(-7 * day))
        f.rowsNotChecked = 1_399                          // 9.99 %
        #expect(CatalogRealityPolicy.colour(f, now: now) == .green)
    }

    @Test("YELLOW: never validated · stopped part way · overdue past 7 days · a large share not checked · unsettled rows")
    func yellowCannotFullyVouch() {
        var never = green; never.validation = .neverRan
        #expect(CatalogRealityPolicy.reasons(never, now: now) == [.neverValidated])
        var partial = green; partial.validation = .partial(at: now)
        #expect(CatalogRealityPolicy.reasons(partial, now: now) == [.validatePartial])
        var overdue = green; overdue.validation = .completed(at: now.addingTimeInterval(-7 * day - 1))
        #expect(CatalogRealityPolicy.reasons(overdue, now: now) == [.validateOverdue(lastCompleted: now.addingTimeInterval(-7 * day - 1))])
        var offline = green; offline.rowsNotChecked = 1_400                     // exactly 10 %
        #expect(CatalogRealityPolicy.reasons(offline, now: now) == [.largeShareNotChecked(notChecked: 1_400, of: 14_000)])
        var unsettled = green; unsettled.unsettled = [CatalogRealityCount(count: 4, words: "4 files changed size on disk")]
        #expect(CatalogRealityPolicy.reasons(unsettled, now: now) == [.unsettled(CatalogRealityCount(count: 4, words: "4 files changed size on disk"))])
        for f in [never, partial, overdue, offline, unsettled] {
            #expect(CatalogRealityPolicy.colour(f, now: now) == .yellow)
        }
        #expect(CatalogRealityPolicy.judge(offline, now: now).headline
                == "\(1_400.formatted()) of \(14_000.formatted()) files could not be checked (drives not connected?)")
    }

    @Test("RED: an integrity break · a failed or killed Validate · an unreadable sidecar — red beats yellow, red reasons first")
    func redLyingOrBroken() {
        var broke = green; broke.breaks = [CatalogRealityCount(count: 2, words: "2 paths have more than one live row")]
        var failed = green; failed.validation = .failed("did not finish checking files on disk (quit or crash)")
        var sidecar = green; sidecar.unreadable = ["the sound print sidecar can't be opened: not a database"]
        for f in [broke, failed, sidecar] { #expect(CatalogRealityPolicy.colour(f, now: now) == .red) }
        #expect(CatalogRealityPolicy.judge(broke, now: now).headline == "Needs attention: 2 paths have more than one live row")
        #expect(CatalogRealityPolicy.judge(failed, now: now).headline
                == "Needs attention: the last Validate Catalog did not finish checking files on disk (quit or crash) — run it again")
        var both = broke
        both.unsettled = [CatalogRealityCount(count: 9, words: "9 unsettled")]
        both.validation = .neverRan
        let reasons = CatalogRealityPolicy.reasons(both, now: now)
        #expect(reasons.first?.colour == .red && reasons.dropFirst().allSatisfy { $0.colour == .yellow })
        #expect(CatalogRealityPolicy.judge(both, now: now).headline.hasSuffix(" · 2 more"))
    }

    @Test("a zero count is no reason: an empty break or unsettled line does not colour the band")
    func zeroCountsAreNoReason() {
        var f = green
        f.breaks = [CatalogRealityCount(count: 0, words: "0 breaks")]
        f.unsettled = [CatalogRealityCount(count: 0, words: "0 unsettled")]
        #expect(CatalogRealityPolicy.colour(f, now: now) == .green)
    }

    @Test("review items: listed with counts in table order, zero counts dropped, 'N to review'; Audio Tracks, But No Sound is the caution (yellow TEXT)")
    func reviewItemsAreListed() {
        let v = CatalogRealityPolicy.judge(green, review: [
            CatalogReviewItem(kind: .missingOtherCopyPresent, count: 10),
            CatalogReviewItem(kind: .possibleSameFootage, count: 1_312),
            CatalogReviewItem(kind: .audioTracksButNoSound, count: 7),
            CatalogReviewItem(kind: .possibleReferenceMovies, count: 0),
            CatalogReviewItem(kind: .missingNoOtherCopy, count: 2),
        ], information: ["128 lineage links point at rows removed from the catalog — kept as history"], now: now)
        #expect(v.colour == .green)
        #expect(v.review.map(\.kind) == [.audioTracksButNoSound, .possibleSameFootage, .missingNoOtherCopy, .missingOtherCopyPresent])
        #expect(v.reviewCount == 1_331)
        #expect(v.reviewLine == "\(1_331.formatted()) to review")
        #expect(v.review.first?.title == "Audio Tracks, But No Sound" && v.review.first?.isCaution == true)
        #expect(v.review.dropFirst().allSatisfy { !$0.isCaution })
        #expect(v.information.count == 1, "information is said, never counted")
        #expect(CatalogReviewItem.Kind.allCases.allSatisfy { !CatalogReviewItem(kind: $0, count: 1).door.isEmpty }, "every review item has a door")
    }

    @Test("SENSOR: review items NEVER move the band off green — every kind, every count up to production scale, alone and together; nor off yellow or red")
    func reviewItemsNeverMoveTheBand() {
        let counts = [1, 2, 29, 128, 1_312, 100_000]
        for base in [green, { var f = green; f.validation = .neverRan; return f }(),
                     { var f = green; f.breaks = [CatalogRealityCount(count: 1, words: "x")]; return f }()] {
            let expected = CatalogRealityPolicy.colour(base, now: now)
            for kind in CatalogReviewItem.Kind.allCases {
                for n in counts {
                    let v = CatalogRealityPolicy.judge(base, review: [CatalogReviewItem(kind: kind, count: n)], now: now)
                    #expect(v.colour == expected, "\(kind) × \(n) moved the band to \(v.colour)")
                    #expect(v.headline == CatalogRealityPolicy.judge(base, now: now).headline)
                }
            }
            let everything = CatalogReviewItem.Kind.allCases.map { CatalogReviewItem(kind: $0, count: 100_000) }
            #expect(CatalogRealityPolicy.judge(base, review: everything, information: ["a", "b"], now: now).colour == expected)
        }
    }

    @Test("an overdue Validate says how many days; a large share says how many of how many")
    func reasonWords() {
        #expect(CatalogRealityPolicy.words(.validateOverdue(lastCompleted: now.addingTimeInterval(-10 * day)), now: now)
                == "the last Validate Catalog was 10 days ago — run it again")
        #expect(CatalogRealityPolicy.words(.neverValidated, now: now) == "Validate Catalog has not run — Catalog ▸ Validate Catalog…")
        #expect(CatalogRealityPolicy.words(.validatePartial, now: now) == "the last Validate Catalog stopped part way — run it again")
    }
}
