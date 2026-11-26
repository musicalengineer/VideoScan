// ProductionShapeWholeFileIdentityTests.swift
// GH #523 at PRODUCTION SHAPE: Rick's real catalog (a sqlite .backup copy in
// a temp folder, ProductionShapeScene), the app's real launch. No media file
// is opened.
//
// What it measures, counts only (privacy):
//   * rule 2 — the (undated recipient, dated donor) pairs the old SAMPLE rule
//     (equal contentHash, else partialMD5 + size) would let share a date, and
//     how many of them the whole-file digest rule refuses (different digest,
//     or no digest on either side) — "how many shares change";
//   * the #1413 unwind — propagated dates already stored whose origin has a
//     DIFFERENT whole-file digest (unwound by the fixed rule, sidecar kept)
//     and those whose origin or recipient was never fully hashed (kept);
//   * Bucket E — live rows with a sample witness on another volume but no
//     whole-file-digest witness (Migrate now copies them instead of skipping).
// And asserts: after the app's own catch-up pass on the copy, every date the
// pass PROPAGATED came from a donor with the same whole-file digest.
//
// Red/green: the red is WholeFileIdentityTests (seen RED on the pre-fix code).
//
// ISOLATION: reads the real catalog (read-only .backup) — skipped where it is
// absent (sealed homes, other Macs). Writes only to the copy.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape: same content is the whole-file digest (GH #523) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeWholeFileIdentityTests {

    @Test("the live copy: how many sample-rule shares the digest rule refuses; every date the pass propagates has a same-digest donor")
    func sharesChangeAndEveryPropagationIsProven() async throws {
        let shape = try await ProductionShapeScene.make("identity523"); defer { shape.cleanup() }
        let model = shape.model
        let records = model.records
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Rule 2 pairs under the sample rule, bucketed by partialMD5 + size.
        var bySample: [String: [VideoRecord]] = [:]
        for r in records where VideoScanModel.isEligibleForDateInference(r) && !r.partialMD5.isEmpty && r.sizeBytes > 0 {
            bySample["\(r.partialMD5)|\(r.sizeBytes)", default: []].append(r)
        }
        var samplePairs = 0, refusedDifferent = 0, refusedNoDigest = 0
        for group in bySample.values where group.count > 1 {
            let donors = group.filter(VideoScanModel.canDonateInferredDate)
            for rec in group where rec.userDate == nil && !VideoScanModel.hasSettledInferredDate(rec) {
                guard donors.contains(where: { $0 !== rec && VideoScanModel.haveSampledSameContent($0, rec) }) else { continue }
                samplePairs += 1
                if donors.contains(where: { $0 !== rec && VideoScanModel.haveVerifiedSameContent($0, rec) }) { continue }
                if VideoScanModel.contentKey(of: rec) == nil
                    || donors.allSatisfy({ VideoScanModel.contentKey(of: $0) == nil }) { refusedNoDigest += 1 } else { refusedDifferent += 1 }
            }
        }

        // Stored propagated dates: proven wrong vs unproven.
        var storedPropagated = 0, provenWrong = 0, unproven = 0
        for r in records where VideoScanModel.isPropagatedInferredDate(r) {
            storedPropagated += 1
            guard let origin = VideoScanModel.originDonor(of: r, byID: byID) else { continue }
            if VideoScanModel.wholeFileDigestsDiffer(origin, r) { provenWrong += 1 }
            else if !VideoScanModel.haveVerifiedSameContent(origin, r) { unproven += 1 }
        }

        // Bucket E: a sample witness elsewhere, no digest witness.
        var witnessesBySample: [String: Int] = [:], witnessesByDigest: [String: Int] = [:]
        for r in records where r.isLiveRelocateWitness {
            if !r.partialMD5.isEmpty { witnessesBySample["\(r.partialMD5)|\(r.sizeBytes)", default: 0] += 1 }
            if let d = CatalogCommit.digest(of: r) { witnessesByDigest["\(d)|\(r.sizeBytes)", default: 0] += 1 }
        }
        var bucketELost = 0
        for r in records where r.isLiveRelocateWitness && !r.partialMD5.isEmpty {
            let sampleOthers = (witnessesBySample["\(r.partialMD5)|\(r.sizeBytes)"] ?? 1) - 1
            let digestOthers = CatalogCommit.digest(of: r).map { (witnessesByDigest["\($0)|\(r.sizeBytes)"] ?? 1) - 1 } ?? 0
            if sampleOthers > 0, digestOthers == 0 { bucketELost += 1 }
        }

        // The app's own pass on the copy: every NEW propagation is proven.
        let before = Dictionary(records.compactMap { r in r.inferredDateSource.map { (r.id, $0) } },
                                uniquingKeysWith: { a, _ in a })
        let pass = model.catchUpInferredDates(trigger: "prodshape-523")
        var unprovenWrites = 0
        for r in model.records where VideoScanModel.isPropagatedInferredDate(r) && before[r.id] != r.inferredDateSource {
            let prefix = VideoScanModel.InferredDateSource.propagatedPrefix
            guard let source = r.inferredDateSource, let id = UUID(uuidString: String(source.dropFirst(prefix.count))),
                  let donor = byID[id], VideoScanModel.haveVerifiedSameContent(donor, r) else { unprovenWrites += 1; continue }
        }
        await shape.close()

        print("whole-file identity (production shape): \(records.count) rows · rule-2 sample pairs \(samplePairs) → "
              + "refused \(refusedDifferent) (different digest) + \(refusedNoDigest) (no digest) · stored propagated "
              + "\(storedPropagated): \(provenWrong) proven wrong (unwound at next launch), \(unproven) unproven (kept) · "
              + "Bucket E rows that now copy instead of skip: \(bucketELost) · this pass propagated \(pass.propagated)")
        #expect(unprovenWrites == 0, "\(unprovenWrites) date(s) propagated this pass without a same-digest donor")
    }

}
