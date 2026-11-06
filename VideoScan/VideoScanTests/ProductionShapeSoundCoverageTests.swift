// ProductionShapeSoundCoverageTests.swift
// GH #442 at PRODUCTION SHAPE: Rick's real catalog (a sqlite `.backup` copy
// in a temp folder, ProductionShapeScene), the band's real projection and
// the real planner. No media file is opened, nothing is written.
//
// The invariant, true of ANY real catalog: for every live row the band's
// Sound Prints verdict IS the planner's — covered exactly when the planner
// skips it as stamped or given up, applicable exactly when the planner can
// key it — and the band's "N without a sound print" (every drive treated as
// connected) equals the number of files Fingerprint Sound would read.
// Set-aside rows are hidden from the band by design (every cycler drops
// them) while the job still prints them for Cleanup's matching; the count
// comparison leaves them out and says how many there were.
//
// On 2026-11-06 at 17:12 the live band said 9 while the job planned 0: on
// this copy both rules already agreed row by row (the 9 was a stale band,
// pinned by SoundPrintCoverageTruthTests' SENSOR test), but three stale
// stamps the band counted as done had been planned at 17:05 — the class
// this test keeps out.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`, with the reason). The copy needs live rows, else it
// FAILS ("lost its teeth"). PRIVACY: messages carry counts only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape sound coverage — the band and the planner agree on the live catalog (GH #442) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeSoundCoverageTests {

    @Test("#442 as it is: every live row's band verdict is the planner's, and the band's count is the job's plan")
    func theBandIsThePlanOnTheLiveCatalog() async throws {
        let shape = try await ProductionShapeScene.make("gh442_soundcov"); defer { shape.cleanup() }
        let model = shape.model
        let live = model.records.filter { !($0.isPurged || $0.isSetAside || $0.isSuperseded) }
        let setAside = model.records.filter { $0.isSetAside && !$0.isPurged && !$0.isSuperseded }.count
        let plan = model.audioFingerprintBackfillPlan()
        let setAsideIDs = Set(model.records.filter(\.isSetAside).map(\.id))
        let plannedLive = plan.lanes.flatMap(\.items).filter { !setAsideIDs.contains($0.id) }.count
        var mismatched = 0, observed = 0, needed = 0
        for r in live {
            let input = AnalyzeCoverageInput(record: r)
            let need = AudioFingerprintBackfillPlanner.need(r)
            let plannerObserved: Bool, plannerApplies: Bool
            switch need {
            case .stamped, .gaveUp: plannerObserved = true; plannerApplies = true
            case .needed: plannerObserved = false; plannerApplies = true
            case .noDigest, .inactive: plannerObserved = false; plannerApplies = false
            }
            if input.soundObserved != plannerObserved || input.soundApplies != plannerApplies { mismatched += 1 }
            if plannerObserved { observed += 1 }
            if case .needed = need { needed += 1 }
        }
        // Every drive connected: the band's "left" is every planned file.
        let roots = Set(live.compactMap { r -> String? in
            guard r.fullPath.hasPrefix("/Volumes/") else { return nil }
            return "/Volumes/" + r.fullPath.dropFirst(9).prefix { $0 != "/" }
        })
        let report = AnalyzeCoverageCalculator.compute(inputs: AnalyzeCoverageCalculator.project(model.records),
                                                       volumes: [], mountedRoots: roots, scope: AnalysisScope())
        await shape.close()
        try #require(!live.isEmpty, "lost its teeth: the copy has no live row")
        print("#442 production shape: \(live.count) live row(s): \(observed) observed, \(needed) to read, "
              + "\(plannedLive) planned (+\(setAside) set aside, planned but hidden from the band)")
        #expect(mismatched == 0, "\(mismatched) live row(s) where the band's sound verdict is not the planner's")
        #expect(report.counts(.soundPrints).remaining == plannedLive,
                "band says \(report.counts(.soundPrints).remaining) without a sound print; the job would read \(plannedLive)")
        #expect(report.soundGaveUp == live.filter { AudioFingerprintBackfillPlanner.gaveUp($0) != nil }.count)
    }
}
