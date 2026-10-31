// CatalogSearchKeystrokeBudgetTests.swift
// GH #123 PRs B + D — the settled-keystroke BUDGET at 100k (checklist
// dimension 2), split out of CatalogSearchBudgetSensorTests for GH #385.
//
// Why a suite of its own (GH #385, 2026-10-26): this is a WALL-CLOCK
// product number — the main-thread latency of one settled keystroke over a
// Rick-shaped 100k catalog, which Rick feels as wall time. It measures the
// host as much as the code: the M1's Release gauntlet regression stage
// failed three of its budgets with no change to the search. So it is tagged
// `.scale`, assigned to the gauntlet's PERFORMANCE stage (not regression),
// and the 2 AM Mac Studio nightly runs it strict (VIDEOSCAN_TIMING_STRICT=1).
// The correctness half — yearRange cache agreement, badge semantics,
// volume-filter reorder invariance — stays in CatalogSearchBudgetSensorTests
// and runs everywhere.
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
//
// Memory: the 100k corpus and its index (≈ the bench's, a few hundred MB
// at most), built once for the one test.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("CatalogSearch keystroke budget at 100k", .tags(.scale), .serialized)
struct CatalogSearchKeystrokeBudgetTests {

    typealias S = CatalogSearchBudgetSensorTests

    @Test func settledKeystrokeBudgetAt100k() throws {
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
                                          // — but that touches the fast-path core
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
            _ = S.settledPass(corpus, index, query)
            let loadBefore = TimingBudget.sampleLoad()
            var times: [Double] = []
            var lastBadge = 0
            for _ in 0..<5 {
                let t = clock.measure {
                    lastBadge = S.settledPass(corpus, index, query).badge
                }
                times.append(S.ms(t))
            }
            let settled = S.median(times)
            print(String(format: "[#123-sensor] q='%@' settled_ms=%.1f budget_ms=%.0f badge=%d",
                         query, settled, budget, lastBadge))
            #if !DEBUG
            // Strict only where the lane pins VIDEOSCAN_TIMING_STRICT=1 (the 2 AM nightly; Rick 2026-10-31); in a busy full
            // battery a miss within 3× is a known issue (GH #208: 85 ms alone
            // vs this 165 ms budget, failed only under battery load).
            expectWithinTimingBudget("100k settled keystroke '\(query)' (median of 5)",
                                     measured: .milliseconds(settled), budget: .milliseconds(budget),
                                     loadBefore: loadBefore)
            #else
            _ = loadBefore
            #endif
        }
    }
}
