// ProductionShapePromoteSoundGateTests.swift
// The Promote sound gate at PRODUCTION SHAPE (Rick 2026-11-10): Rick's real
// catalog (a sqlite `.backup` copy in a temp folder, ProductionShapeScene)
// and the gate's real rule over every live row's STORED sound verdict.
// No media file is opened, no decode runs, nothing is written.
//
// The invariants, true of ANY real catalog:
//   (a) no row whose stored verdict says damaged, silent, no audio stream or
//       surround — or has no date, or no whole-file fingerprint — can be
//       reused as a pass, even granting the best case for everything the
//       job checks on disk (the fingerprint still describes the file and the
//       proven digest equals it);
//   (b) the owner's “Silent — checked” tag is honoured for a row's own
//       fingerprint and refused for any other digest;
//   (c) the rule is O(1) per row: the whole live catalog in under 2 s.
// It also prints how many rows a Promote would measure rather than reuse —
// the time cost of the gate on this catalog, as a number.
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

@Suite("Production-shape Promote sound gate — stored verdicts on the live catalog — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapePromoteSoundGateTests {

    typealias G = PromoteSoundGate

    @Test("no stored refusal, surround, undated or unfingerprinted verdict is reusable as a pass; the tag binds to the row's own digest; O(1) per row")
    func storedVerdictsOnTheLiveCatalog() async throws {
        let shape = try await ProductionShapeScene.make("promote_sound_gate"); defer { shape.cleanup() }
        let live = shape.model.records.filter { !($0.isPurged || $0.isSetAside || $0.isSuperseded) }
        try #require(!live.isEmpty, "lost its teeth: the copy has no live rows")

        let other = String(repeating: "f", count: 64)
        var withVerdict = 0, reusable = 0, wronglyReusable = 0, tagged = 0, tagCrossed = 0, tagRefusedOwn = 0
        let start = Date()
        for r in live {
            let digest = r.contentFixity?.digest ?? ""
            if !r.audioVerifyStatus.isEmpty { withVerdict += 1 }
            // The best case for everything the job checks on disk.
            let stored = G.storedPass(status: r.audioVerifyStatus, note: r.audioVerifyNote, checkedAt: r.audioVerifyDate,
                                      fixity: r.contentFixity, fixityVouchesNow: true, provenDigest: digest)
            if stored != nil {
                reusable += 1
                let note = r.audioVerifyNote.lowercased()
                let mustMeasure = r.audioVerifyStatus != "ok" || r.audioVerifyDate == nil || r.contentFixity == nil
                    || note.contains("silent") || note.contains("no audio stream") || note.contains("surround")
                    || note.contains("damaged")
                    || (r.audioVerifyDate.map { $0 <= (r.contentFixity?.computedAt ?? .distantFuture) } ?? true)
                if mustMeasure { wronglyReusable += 1 }
            }
            if WorkflowTags.contains(r.tags, G.ownerTag), let fixity = r.contentFixity {
                tagged += 1
                if G.mark(tags: r.tags, storedFixity: fixity, provenDigest: fixity.digest,
                          recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes) != .accepted { tagRefusedOwn += 1 }
                if G.mark(tags: r.tags, storedFixity: fixity, provenDigest: other,
                          recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes) != .notTiedToTheseBytes { tagCrossed += 1 }
            }
        }
        let elapsed = -start.timeIntervalSinceNow
        await shape.close()

        print("promote sound gate, production shape: \(live.count) live row(s); \(withVerdict) with a stored sound verdict; "
              + "\(reusable) reusable as a pass at best; \(live.count - reusable) would be measured at Promote; "
              + "\(tagged) tagged “Silent — checked” with a fingerprint; \(String(format: "%.2f", elapsed))s")
        #expect(wronglyReusable == 0, "\(wronglyReusable) row(s) with a refusal, surround, undated or unbound verdict were reusable as a pass")
        #expect(tagRefusedOwn == 0, "\(tagRefusedOwn) tagged row(s) were not accepted for their own digest")
        #expect(tagCrossed == 0, "\(tagCrossed) tagged row(s) carried the tag across to a different digest")
        #expect(elapsed < 2.0, "the rule took \(String(format: "%.2f", elapsed))s over \(live.count) rows — no longer O(1) per row")
    }
}
