// TypecheckSplitTextTests.swift
// Characterization tests for the text helpers pulled out of slow-to-type-
// check SwiftUI bodies (nightly run 36121118356, 2026-09-26). Each oracle is
// the ORIGINAL inline expression, copied verbatim, so a drift in wording or
// punctuation between the old body and the new helper turns red here.

import Foundation
import Testing
@testable import VideoScan

@Suite("Type-check splits keep the same words")
@MainActor
struct TypecheckSplitTextTests {

    // MARK: Buffer hygiene entry line (VoiceOver label)

    private func entry(companions: [String]) -> ArchiveAngelBufferHygiene.EntryLine {
        ArchiveAngelBufferHygiene.EntryLine(id: UUID(), filename: "1994 Xmas.mov", statusText: "Ready to review",
                                            status: .ready, isBufferShort: false, sizeBytes: 1_234_567_890,
                                            companions: companions)
    }

    /// The pre-split inline expression, verbatim.
    private func originalLabel(_ entry: ArchiveAngelBufferHygiene.EntryLine) -> String {
        "\(entry.filename), \(entry.statusText), \(MediaBytes.display(entry.sizeBytes))"
            + (entry.companions.isEmpty ? "" : ", companions: " + entry.companions.joined(separator: ", "))
    }

    @Test("entry accessibility label — no companions, one, several")
    func entryAccessibilityLabel() {
        for companions in [[], ["access"], ["access", "lossless", "balanced"]] {
            let e = entry(companions: companions)
            #expect(ArchiveAngelBufferHygieneCard.entryAccessibilityLabel(e) == originalLabel(e))
        }
    }

    // MARK: Show Copies location summary

    private func rep(instanceCount: Int, sizeBytes: Int64) -> CopyRepresentation {
        let instances: [CopyInstance] = (0..<instanceCount).map { i in
            CopyInstance(id: UUID(), fullPath: "/Volumes/V\(i)/a.mov", filename: "a.mov", sizeBytes: sizeBytes,
                         isReachable: true, isRetired: false, isMasterArchive: false, isArchiveCopy: false,
                         byteCluster: nil)
        }
        return CopyRepresentation(signature: "DV 720×480", role: .originalSource, instances: instances,
                                  recommendedInstanceID: instances.first?.id, reason: "why",
                                  videoCodec: "dvvideo", audioCodec: "pcm_s16le", container: "mov",
                                  resolution: "720x480", frameRate: "29.97", durationSeconds: 60,
                                  sizeBytes: sizeBytes)
    }

    @Test("representation location summary — singular and plural")
    func locationSummary() {
        for count in [1, 2, 7] {
            let r = rep(instanceCount: count, sizeBytes: 13_000_000_000)
            // The pre-split inline string, verbatim.
            let original = "\(r.instances.count) location\(r.instances.count == 1 ? "" : "s") · \(CatalogStorageTotals.displaySize(r.sizeBytes))"
            #expect(ArchiveAngelShowCopiesView.locationSummary(r) == original)
        }
    }

    // MARK: Move-to-Trash empty state

    @Test("prune detail empty-state text — queued wins, then active, then done")
    func pruneEmptyMessage() {
        for isQueued in [false, true] {
            for isActive in [false, true] {
                // The pre-split inline ternary, verbatim.
                let original: String = isQueued
                    ? "Waiting its turn — nothing is checked or moved until the batch before finishes. Every copy is checked when this batch starts."
                    : (isActive ? "Working out what may go…" : "Nothing was moved.")
                #expect(PruneApplyDetailView.emptyMessageText(isQueued: isQueued, isActive: isActive) == original)
            }
        }
    }
}
