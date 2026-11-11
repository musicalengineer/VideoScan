// ProductionShapePromoteSoundGateTests.swift
// The Promote sound gate at PRODUCTION SHAPE (Rick 2026-11-10): Rick's real
// catalog (a sqlite `.backup` copy in a temp folder, ProductionShapeScene)
// and the gate's real tag rule over every live row.
// No media file is opened, no decode runs, nothing is written.
//
// The gate reads nothing stored about a file's sound (it always measures),
// so the one stored input is the owner's tag. The invariants, true of ANY
// real catalog:
//   (a) the “Silent — checked” tag is honoured for a row's own fingerprint
//       and refused for any other digest;
//   (b) the rule is O(1) per row: the whole live catalog in under 2 s.
// It also prints how many rows carry the tag, and how many carry a stored
// sound verdict the gate will NOT use — every Promote measures.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`, with the reason). The copy needs live rows, else it
// FAILS ("lost its teeth"). PRIVACY: messages carry counts only, never paths
// or filenames. Written 2026-11-10 and NOT run on the dev machine: the
// fleet runs it.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape Promote sound gate — the owner's tag on the live catalog — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapePromoteSoundGateTests {

    typealias G = PromoteSoundGate

    @Test("the owner's tag binds to each row's own digest and never crosses to another; O(1) per row")
    func theTagOnTheLiveCatalog() async throws {
        let shape = try await ProductionShapeScene.make("promote_sound_gate"); defer { shape.cleanup() }
        let live = shape.model.records.filter { !($0.isPurged || $0.isSetAside || $0.isSuperseded) }
        try #require(!live.isEmpty, "lost its teeth: the copy has no live rows")

        let other = String(repeating: "f", count: 64)
        var withVerdict = 0, tagged = 0, tagCrossed = 0, tagRefusedOwn = 0, untaggedAccepted = 0
        let start = Date()
        for r in live {
            if !r.audioVerifyStatus.isEmpty { withVerdict += 1 }
            let isTagged = WorkflowTags.contains(r.tags, G.ownerTag)
            let own = G.mark(tags: r.tags, storedFixity: r.contentFixity, provenDigest: r.contentFixity?.digest ?? other,
                             recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes)
            if !isTagged {
                if own != .absent { untaggedAccepted += 1 }
                continue
            }
            tagged += 1
            guard let fixity = r.contentFixity else { continue }
            if own != .accepted { tagRefusedOwn += 1 }
            if G.mark(tags: r.tags, storedFixity: fixity, provenDigest: other,
                      recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes) != .notTiedToTheseBytes { tagCrossed += 1 }
        }
        let elapsed = -start.timeIntervalSinceNow
        await shape.close()

        print("promote sound gate, production shape: \(live.count) live row(s); \(tagged) tagged “Silent — checked”; "
              + "\(withVerdict) with a stored sound verdict the gate does not read; \(String(format: "%.2f", elapsed))s")
        #expect(untaggedAccepted == 0, "\(untaggedAccepted) row(s) without the tag were treated as tagged")
        #expect(tagRefusedOwn == 0, "\(tagRefusedOwn) tagged row(s) were not accepted for their own digest")
        #expect(tagCrossed == 0, "\(tagCrossed) tagged row(s) carried the tag across to a different digest")
        #expect(elapsed < 2.0, "the rule took \(String(format: "%.2f", elapsed))s over \(live.count) rows — no longer O(1) per row")
    }
}
