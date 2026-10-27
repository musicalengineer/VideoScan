// CatalogSearchBudgetSensorTests.swift
// GH #123 PRs B + D — scale sensors (checklist dimension 5) for the
// correctness contracts the settled-keystroke fixes lean on, at 100k.
//
// Reuses CatalogSearchProfileBench's Rick-shaped 100k corpus generator so
// the sensors check the same population the diagnosis measured. The
// bench file itself stays UNCHANGED (it is the before/after yardstick).
//
// What a "settled keystroke" costs after PR B: ONE scan —
// CatalogContent.computeFiltered() searches the badge base
// (purge → set-aside) and derives the toolbar badge count from the same
// pass (the toolbar's duplicate debouncer+scan is gone). `settledPass`
// below is exactly that shape.
//
// The wall-clock BUDGETS moved to CatalogSearchKeystrokeBudgetTests
// (GH #385, 2026-10-26): they measure the host as much as the code (the
// M1's Release gauntlet regression stage failed three of them with no
// change to the search), so they run in the performance stage and the
// nightly. This suite stays in the regression stage and runs everywhere.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("CatalogSearchBudgetSensors", .serialized)
struct CatalogSearchBudgetSensorTests {

    // MARK: - Production-path analog (post-PR-B shape)

    /// CatalogContent.computeFiltered()'s search path AFTER PR B:
    /// purge → set-aside → ONE searchIndex.filter over the badge base;
    /// the badge count is the same pass's result count. (No volume
    /// filter / view chips / filterByIDs — defaults, like Rick's spot
    /// test.) Keep in lock-step with CatalogHelpers.computeFiltered().
    static func settledPass(
        _ records: [VideoRecord],
        _ index: CatalogSearchIndex,
        _ query: String
    ) -> (rows: [VideoRecord], badge: Int) {
        var out = pfApplyPurgeFilter(records, showRemoved: false)
        out = pfApplySetAsideFilter(out, showSetAside: false)
        // Superseded filter (GH #132) — third sibling, lock-step with
        // computeFiltered().
        out = pfApplySupersededFilter(out, showSuperseded: false)
        guard !query.isEmpty else { return (out, 0) }
        out = index.filter(records: out, query: query)
        return (out, out.count)
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }

    // MARK: - The scale sensor (100k, Rick-shaped)

    /// One big test so the 100k corpus + index build happen once.
    /// Sections: (1) yearRange cache agreement vs the canonical matcher,
    /// (2) badge == old-toolbar-scan semantics + volume-reorder
    /// invariance (the PR B risk called out in the diagnosis).
    @Test func settledKeystrokeAgreementAt100k() throws {
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        let index = CatalogSearchIndex()
        index.rebuild(records: corpus)

        // ---- yearRange cache agreement (PR D) ----
        // The precomputed year sets MUST reproduce the canonical
        // pfRecordFilenameOrPersonMatch results exactly, at scale, for
        // every yearRange token form (decade shorthand, wildcard,
        // year:, decade:, mixed with substrings).
        for q in ["1990s", "199x", "year:1991..1995", "decade:1990", "donna 1990s"] {
            let viaIndex = Self.settledPass(corpus, index, q).rows.map(\.fullPath)
            let base = pfApplySetAsideFilter(
                pfApplyPurgeFilter(corpus, showRemoved: false), showSetAside: false)
            let canonical = base.filter { pfRecordFilenameOrPersonMatch($0, query: q) }
                .map(\.fullPath)
            #expect(viaIndex == canonical,
                    "index vs canonical disagree for '\(q)': \(viaIndex.count) vs \(canonical.count) rows")
        }

        // ---- badge semantics (PR B) ----
        // The badge derived from the table pass must equal what the old
        // toolbar scan (searchIndex.count over pfSearchBadgeBase)
        // computed — that's the "badge base must keep matching
        // pfSearchBadgeBase semantics" risk from the diagnosis.
        for q in ["donna", "1993", "1990s", "donna 1990s"] {
            let derived = Self.settledPass(corpus, index, q).badge
            // kindFacet .everything = the pre-#124 base; settledPass
            // applies no facet, so the two sides stay comparable. The
            // facet layer itself is pinned by MediaKindFacetTests.
            let oldToolbarScan = index.count(
                records: pfSearchBadgeBase(corpus, showRemoved: false, showSetAside: false,
                                           showSuperseded: false, kindFacet: .everything),
                query: q)
            #expect(derived == oldToolbarScan,
                    "PR B badge for '\(q)' (\(derived)) != old toolbar scan (\(oldToolbarScan))")
        }

        // ---- volume-filter reorder invariance (PR B) ----
        // computeFiltered now searches BEFORE the volume prefix filter
        // (so the badge keeps pfSearchBadgeBase semantics) where it used
        // to search after. Same rows either way — pinned here.
        let prefixes = ["/Volumes/LaCie8TB"]
        for q in ["donna", "1993", "1990s"] {
            let base = pfApplySetAsideFilter(
                pfApplyPurgeFilter(corpus, showRemoved: false), showSetAside: false)
            let searchThenVolume = index.filter(records: base, query: q)
                .filter { pfRecordOnSelectedVolume($0, prefixes: prefixes) }
                .map(\.fullPath)
            let volumeThenSearch = index.filter(
                records: base.filter { pfRecordOnSelectedVolume($0, prefixes: prefixes) },
                query: q)
                .map(\.fullPath)
            #expect(searchThenVolume == volumeThenSearch,
                    "filter-order change altered rows for '\(q)'")
            // And the badge must NOT shrink when a volume filter is
            // active — it counts over the pre-volume base by contract.
            let badgeWithVolume = index.filter(records: base, query: q).count
            #expect(badgeWithVolume >= searchThenVolume.count)
        }
    }

    // MARK: - Small-n logic checks (run everywhere, fast)

    /// Empty query publishes badge 0 and returns the full base — the
    /// toolbar hides the badge, but a stale non-zero count must never
    /// linger in the binding.
    @Test func emptyQueryYieldsZeroBadge() {
        let recs = (0..<20).map { i -> VideoRecord in
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.directory = "/Volumes/T/d"
            r.fullPath = r.directory + "/" + r.filename
            return r
        }
        let index = CatalogSearchIndex()
        index.rebuild(records: recs)
        let (rows, badge) = Self.settledPass(recs, index, "")
        #expect(rows.count == recs.count)
        #expect(badge == 0)
    }

    /// Badge counts rows the purge/set-aside toggles hide — pinning the
    /// 2026-07-15 QA fix through the PR B rewiring: hidden rows must not
    /// inflate the count.
    @Test func badgeRespectsPurgeAndSetAsideBase() {
        let recs = (0..<30).map { i -> VideoRecord in
            let r = VideoRecord()
            r.filename = "donna\(i).mov"
            r.directory = "/Volumes/T/d"
            r.fullPath = r.directory + "/" + r.filename
            if i < 10 { r.purgedAt = Date() }               // hidden by default
            if i >= 20 { r.setAsideReason = "music" }       // hidden by default
            return r
        }
        let index = CatalogSearchIndex()
        index.rebuild(records: recs)
        let (_, badgeDefault) = Self.settledPass(recs, index, "donna")
        #expect(badgeDefault == 10, "purged + set-aside rows must not count")
        // Show Removed on: purged rows join the base (mirrors
        // computeFiltered's showRemoved=true path).
        var out = pfApplyPurgeFilter(recs, showRemoved: true)
        out = pfApplySetAsideFilter(out, showSetAside: false)
        #expect(index.filter(records: out, query: "donna").count == 20)
    }
}
