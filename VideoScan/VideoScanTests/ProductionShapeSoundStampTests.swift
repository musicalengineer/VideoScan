// ProductionShapeSoundStampTests.swift
// GH #416 at PRODUCTION SHAPE: Rick's real catalog (a sqlite `.backup` copy
// in a temp folder, ProductionShapeScene), the app's real planner and the
// real commit door. No media file is opened and no decode runs: each live
// row whose whole-file digest is its ARCHIVE fixity (the 50 the job re-read
// every run) gets the stamp the job would write for its planned item —
// keyed on `item.key`, exactly as `AudioFingerprintBackfillJob.record` keys
// it — through `applyAudioFingerprintStamp` and `saveCatalogAcknowledged`.
// Then a NEW model launches on the copy and the test reads `sound_prints`,
// the reloaded stamps and the next plan.
//
// Red before the fix: the items were keyed on the sampled "v1:" hash, the
// commit landed them "unchanged", `sound_prints` stayed without them and
// the next plan named every one again.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`). The copy needs ≥ 1 such row, else it FAILS ("lost its
// teeth"). PRIVACY: messages carry counts only, never paths or filenames.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape sound stamps on the live catalog's archive copies (GH #416) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeSoundStampTests {

    @Test("#416: every archive-fixity row's stamp lands in sound_prints through the commit door and the next plan skips it")
    func archiveFixityRowsStampDurably() async throws {
        let shape = try await ProductionShapeScene.make("sound416"); defer { shape.cleanup() }
        let model = shape.model
        let targets = Set(model.records.filter {
            AudioFingerprintBackfillPlanner.isActive($0) && $0.contentFixity == nil && $0.archiveFixity != nil
                && VideoScanModel.storedFullDigest($0) != nil
        }.map(\.id))
        try #require(!targets.isEmpty, "lost its teeth: the copy has no live row whose digest is its archive fixity")
        let items = model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).filter { targets.contains($0.id) }
        try #require(!items.isEmpty, "fixture: \(targets.count) archive-fixity row(s), none planned — nothing to prove")

        var digests: Set<String> = []
        for item in items {
            #expect(AudioFingerprintStamp.isFullDigest(item.key.contentDigest), "the planned key is a full SHA-256")
            let stamp = AudioFingerprintStamp(contentDigest: item.key.contentDigest, sizeBytes: item.sizeBytes,
                                              outcome: .fingerprinted, analyzedSeconds: 60, complete: true,
                                              landmarks: 1, bytes: 8)
            #expect(model.applyAudioFingerprintStamp(stamp, to: item) == .written)
            digests.insert(String(item.key.contentDigest.dropFirst("sha256:".count)))
        }
        #expect(await model.saveCatalogAcknowledged(), "the acknowledged save")

        let fresh = try await shape.relaunchedModel()
        let replanned = Set(fresh.audioFingerprintBackfillPlan().lanes.flatMap(\.items).map(\.id)).intersection(targets)
        await ProductionShapeScene.close(fresh)
        let stored = Set(try sqliteTable(shape.db, "SELECT digest FROM sound_prints").map { $0[0] })
        let missing = digests.subtracting(stored)
        #expect(missing.isEmpty, "\(missing.count) of \(digests.count) stamped digest(s) are not in sound_prints after relaunch")
        #expect(replanned.isEmpty, "\(replanned.count) of \(items.count) stamped row(s) are planned again after relaunch")
        print("#416 production shape: \(items.count) archive-fixity row(s) stamped, \(digests.count) digest(s); "
              + "\(digests.count - missing.count) in sound_prints after relaunch; \(replanned.count) planned again")
    }
}
