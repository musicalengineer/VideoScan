// CatalogSearchBudgetSensorTests.swift
// GH #123 PRs B + D — scale sensors (checklist dimensions 2 + 5) for the
// settled-keystroke cost and the correctness contracts the fixes lean on.
//
// Reuses CatalogSearchProfileBench's Rick-shaped 100k corpus generator so
// the sensors measure the same population the diagnosis measured. The
// bench file itself stays UNCHANGED (it is the before/after yardstick);
// budgets live here.
//
// What a "settled keystroke" costs after PR B: ONE scan —
// CatalogContent.computeFiltered() searches the badge base
// (purge → set-aside) and derives the toolbar badge count from the same
// pass (the toolbar's duplicate debouncer+scan is gone). The sensor
// measures exactly that shape.
//
// Budgets (Release only — a Debug run is not a perf measurement, so the
// timing assertions compile out):
//   * 50 ms  — word-fast-path queries and yearRange queries (PR D moved
//     yearRange from 952 ms/pass to set-membership). This is the
//     search_profile_2026-07-20.md sensor-spec budget.
//   * 165 ms — INTERIM budget for linear-regime queries (partial words,
//     phrases, infix-defeated needles). The linear memmem scan over 100k
//     multi-KB haystacks costs ~60-75 ms/pass on the M4 Max and PR B
//     already halved it (one pass, not two); getting it under 50 ms
//     requires moving the scan off the main actor (PR C, deliberately
//     deferred to reviewed daylight work) or the fast-path union (PR E).
//     TODO(#123 PR C): tighten every budget below to 50 ms once the
//     off-main snapshot filter lands.

import Testing
import Foundation
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
    /// Sections: (1) main-thread budget per settled keystroke,
    /// (2) yearRange cache agreement vs the canonical matcher,
    /// (3) badge == old-toolbar-scan semantics + volume-reorder
    /// invariance (the PR B risk called out in the diagnosis).
    @Test func settledKeystrokeBudgetAndAgreementAt100k() throws {
        let clock = ContinuousClock()
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        let index = CatalogSearchIndex()
        index.rebuild(records: corpus)

        // (query, budget ms) — see header for the two-tier rationale.
        let budgets: [(String, Double)] = [
            ("donna", 50),                // word fast-path
            ("mark dan grampa", 50),      // word fast-path, 3-token AND
            ("1990s", 50),                // yearRange — PR D's precomputed sets
            ("donna 1990s", 165),         // MIXED substring+yearRange: any yearRange
                                          // token bails tryIndexLookup, so the whole
                                          // query walks the linear matcher (~60 ms
                                          // measured post-D). Candidate follow-up:
                                          // resolve substring tokens via the index,
                                          // then year-set-check only the candidates
                                          // — but that touches the fast-path core,
                                          // so it stays out of this overnight fix
                                          // (PR C moves it off-main regardless).
            ("1993", 165),                // linear (infix-defeated) — interim, see header
            ("christmas", 165),           // linear (infix-defeated)
            ("mov", 165),                 // linear (infix of "imovie")
            ("elev", 165),                // linear (partial word)
            ("\"cape cod\"", 165),        // linear (phrase)
        ]

        for (query, budget) in budgets {
            // Warm-up pass (first-use eligibility scans are memoized —
            // production pays them once per query string, then settles).
            _ = Self.settledPass(corpus, index, query)
            var times: [Double] = []
            var lastBadge = 0
            for _ in 0..<5 {
                let t = clock.measure {
                    lastBadge = Self.settledPass(corpus, index, query).badge
                }
                times.append(Self.ms(t))
            }
            let settled = Self.median(times)
            print(String(format: "[#123-sensor] q='%@' settled_ms=%.1f budget_ms=%.0f badge=%d",
                         query, settled, budget, lastBadge))
            #if !DEBUG
            #expect(settled <= budget,
                    "settled keystroke for '\(query)' took \(settled) ms — budget \(budget) ms at 100k records")
            #endif
        }

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
