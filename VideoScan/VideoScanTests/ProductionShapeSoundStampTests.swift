// ProductionShapeSoundStampTests.swift
// GH #416 at PRODUCTION SHAPE: Rick's real catalog (a sqlite `.backup` copy
// in a temp folder, ProductionShapeScene), the app's real planner and the
// real commit door. No media file is opened and no decode runs.
//
// The target rows: live rows whose whole-file digest is their ARCHIVE fixity
// (no content fixity) — the 50 the job re-read every run before the fix,
// because their stamp was keyed on the sampled "v1:" hash, the commit landed
// it "unchanged", `sound_prints` stayed without it and the next plan named
// every one again.
//
// Invariants, true of ANY real catalog (rewritten 2026-11-06: the first
// version required unstamped archive rows in the live copy, a one-time state
// — Fingerprint Sound has since stamped all of them and the nightly went red
// on the Ultra with "none planned — nothing to prove"):
//   (a) AS IT IS: a target row is planned exactly when it has no current
//       stamp and has not given up, and every stamp it carries is keyed on
//       its full SHA-256 and stored in `sound_prints` (a v1-keyed stamp, the
//       #416 bug, fails here);
//   (b) WITH THE TARGETS' PRINTS REMOVED from the copy (their `sound_prints`
//       and `sound_attempts` rows, so the planner needs them again): each
//       planned target's stamp, keyed on `item.key` exactly as
//       `AudioFingerprintBackfillJob.record` keys it, lands through
//       `applyAudioFingerprintStamp` + `saveCatalogAcknowledged`; after a
//       relaunch every digest is in `sound_prints` and none is planned again;
//       stamping them all a second time changes no `sound_prints` row.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`, with the reason). The copy needs ≥ 1 target row, else it
// FAILS ("lost its teeth"). PRIVACY: messages carry counts only, never paths
// or filenames.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape sound stamps on the live catalog's archive copies (GH #416) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeSoundStampTests {

    /// Live rows whose stored full digest is their archive fixity.
    static func targets(_ model: VideoScanModel) -> [VideoRecord] {
        model.records.filter {
            AudioFingerprintBackfillPlanner.isActive($0) && $0.contentFixity == nil && $0.archiveFixity != nil
                && VideoScanModel.storedFullDigest($0) != nil
        }
    }

    static func hex(_ digest: String) -> String { String(digest.dropFirst("sha256:".count)) }

    /// `sound_prints` as "digest|outcome|complete|landmarks|bytes" (the stamp's
    /// facts; `computed_at` is when, not what).
    static func prints(_ db: URL) throws -> Set<String> {
        Set(try sqliteTable(db, "SELECT digest, outcome, complete, landmarks, blob_bytes FROM sound_prints")
            .map { $0.joined(separator: "|") })
    }

    @Test("#416 as it is: an archive-fixity row is planned exactly when it has no current stamp and has not given up, and every stamp it carries is its full SHA-256 in sound_prints")
    func thePlanSkipsExactlyTheStoredStamps() async throws {
        let shape = try await ProductionShapeScene.make("sound416_asis"); defer { shape.cleanup() }
        let targets = Self.targets(shape.model)
        let planned = Set(shape.model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).map(\.id))
        let stored = Set(try sqliteTable(shape.db, "SELECT digest FROM sound_prints").map { $0[0] })
        await shape.close()
        try #require(!targets.isEmpty, "lost its teeth: the copy has no live row whose digest is its archive fixity")

        var current = 0, gaveUp = 0, stampedButPlanned = 0, neededButSkipped = 0, notStored = 0
        for r in targets {
            let digests = AudioFingerprintBackfillPlanner.digests(of: r)
            let isCurrent = r.audioFingerprint?.describes(sizeBytes: r.sizeBytes, digests: digests,
                                                          headerHasAudio: !r.audioCodec.isEmpty) == true
            // Judged on the row's OWN stored full digest too, not only the
            // planner's key list: the #416 bug was a key list without it.
            let ownKey = VideoScanModel.storedFullDigest(r).map(AudioFingerprintStamp.fullDigest)
            let isCurrentByOwnKey = ownKey.map {
                r.audioFingerprint?.describes(sizeBytes: r.sizeBytes, digests: [$0], headerHasAudio: !r.audioCodec.isEmpty) == true
            } ?? false
            let isGivenUp = AudioFingerprintBackfillPlanner.gaveUp(r, digests: digests) != nil
            if isCurrent { current += 1 } else if isGivenUp { gaveUp += 1 }
            if isCurrent || isCurrentByOwnKey, planned.contains(r.id) { stampedButPlanned += 1 }
            if !isCurrent, !isGivenUp, !planned.contains(r.id) { neededButSkipped += 1 }
            if let stamp = r.audioFingerprint,
               !AudioFingerprintStamp.isFullDigest(stamp.contentDigest) || !stored.contains(Self.hex(stamp.contentDigest)) {
                notStored += 1
            }
        }
        print("#416 production shape (as it is): \(targets.count) archive-fixity row(s): \(current) stamped, \(gaveUp) given up, "
              + "\(targets.count - current - gaveUp) to plan")
        #expect(stampedButPlanned == 0, "\(stampedButPlanned) row(s) with a current stamp are planned again")
        #expect(neededButSkipped == 0, "\(neededButSkipped) row(s) with no stamp and no give-up are missing from the plan")
        #expect(notStored == 0, "\(notStored) row(s) carry a stamp that is not a full SHA-256 in sound_prints")
    }

    @Test("#416: every archive-fixity row's stamp lands in sound_prints through the commit door, the next plan skips it, and stamping again changes nothing")
    func archiveFixityRowsStampDurably() async throws {
        // The targets' prints and tries, removed from the COPY before launch:
        // the planner needs them again, however far the live catalog has got.
        let archiveDigests = "SELECT f.content_digest FROM files f JOIN archive_copies a ON a.file_id = f.id"
        let shape = try await ProductionShapeScene.make("sound416") { db in
            // A catalog this build has not opened yet has no sound_attempts table
            // (schema 14: the M4's viewer copy, 2026-11-07 … 11-09, where this test
            // died on "no such table"). No table, no tries to remove.
            let hasTries = try !sqliteTable(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sound_attempts'").isEmpty
            try sqliteExecute(db, ["DELETE FROM sound_prints WHERE digest IN (\(archiveDigests))"]
                              + (hasTries ? ["DELETE FROM sound_attempts WHERE digest IN (\(archiveDigests))"] : []))
        }
        defer { shape.cleanup() }
        let model = shape.model
        let targets = Set(Self.targets(model).map(\.id))
        let items = model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).filter { targets.contains($0.id) }
        guard !targets.isEmpty, !items.isEmpty else {
            await shape.close()
            try #require(!targets.isEmpty, "lost its teeth: the copy has no live row whose digest is its archive fixity")
            Issue.record("\(targets.count) archive-fixity row(s) with their prints removed, none planned")
            return
        }

        func stampAll(_ m: VideoScanModel) -> Int {
            var written = 0
            for item in items {
                let stamp = AudioFingerprintStamp(contentDigest: item.key.contentDigest, sizeBytes: item.sizeBytes,
                                                  outcome: .fingerprinted, analyzedSeconds: 60, complete: true,
                                                  landmarks: 1, bytes: 8)
                if m.applyAudioFingerprintStamp(stamp, to: item) == .written { written += 1 }
            }
            return written
        }
        var digests: Set<String> = []
        for item in items {
            #expect(AudioFingerprintStamp.isFullDigest(item.key.contentDigest), "the planned key is a full SHA-256")
            digests.insert(Self.hex(item.key.contentDigest))
        }
        #expect(stampAll(model) == items.count, "every planned row took its stamp")
        #expect(await model.saveCatalogAcknowledged(), "the acknowledged save")

        let fresh = try await shape.relaunchedModel()
        let replanned = Set(fresh.audioFingerprintBackfillPlan().lanes.flatMap(\.items).map(\.id)).intersection(targets)
        let printsOnce = try Self.prints(shape.db)
        let again = stampAll(fresh)
        let savedAgain = await fresh.saveCatalogAcknowledged()
        await ProductionShapeScene.close(fresh)
        let printsTwice = try Self.prints(shape.db)

        let stored = Set(printsOnce.map { String($0.prefix { $0 != "|" }) })
        let missing = digests.subtracting(stored)
        #expect(missing.isEmpty, "\(missing.count) of \(digests.count) stamped digest(s) are not in sound_prints after relaunch")
        #expect(replanned.isEmpty, "\(replanned.count) of \(items.count) stamped row(s) are planned again after relaunch")
        #expect(again == items.count && savedAgain, "the second stamping: \(again) of \(items.count) written, saved \(savedAgain)")
        #expect(printsTwice == printsOnce,
                "stamping again changed sound_prints: \(printsOnce.subtracting(printsTwice).count) row(s) gone or changed, \(printsTwice.subtracting(printsOnce).count) new")
        print("#416 production shape: \(items.count) archive-fixity row(s) stamped, \(digests.count) digest(s); "
              + "\(digests.count - missing.count) in sound_prints after relaunch; \(replanned.count) planned again; "
              + "second stamping left \(printsTwice.count) sound_prints row(s) as they were")
    }
}
