// ProductionShapeDossierDigestTests.swift
// GH #413 at PRODUCTION SHAPE: Rick's real catalog (a sqlite .backup copy
// in a temp folder, ProductionShapeScene), the app's real launch-time
// dossier backfill. No media file is opened.
//
// Found on 2026-11-02: 11 partialMD5 groups (82 rows) hold more than one
// whole-file digest (same size + head/tail, different interior bytes). The
// partialMD5-keyed backfill wrote the best transcript / captions / OCR text
// / OCR DATES of one content onto rows of another.
//
// The test: run the backfill on the copy, then prove every value it wrote
// came from a donor holding the SAME whole-file digest (the commit's own
// rule), and that no row without a digest was written at all. It also
// reports how many partialMD5 groups span several digests (the incident's
// shape) — the evidence the test still has teeth on this catalog.
//
// Red/green: the red is the unit suite DossierPropagationDigestIdentityTests
// (seen RED on the pre-fix code). This is the guard at production shape:
// green on the fixed code against the live copy; it would go red on any
// cross-digest write whose members disagree.
//
// ISOLATION: reads the real catalog (read-only .backup) — skipped where it is
// absent (sealed homes, other Macs); runs in scripts/run_catalog_tests.sh and
// the nightly all-tests pass on Rick's Mac. PRIVACY: counts only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape dossier backfill groups by whole-file digest (GH #413) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeDossierDigestTests {

    private struct Dossier: Equatable {
        let transcript: String
        let captions: [String]
        let ocrText: [String]
        let ocrDates: [String]
        init(_ r: VideoRecord) {
            transcript = r.audioTranscript ?? ""
            captions = r.sceneCaptions.map(\.text)
            ocrText = r.ocrText.map(\.text)
            ocrDates = r.ocrDateCandidates.map(\.text)
        }
    }

    @Test("the live copy: every value the backfill writes comes from a copy with the same whole-file digest")
    func everyWrittenValueHasASameDigestDonor() async throws {
        let shape = try await ProductionShapeScene.make("dossierdigest"); defer { shape.cleanup() }
        let model = shape.model
        let before = Dictionary(model.records.map { ($0.id, Dossier($0)) }, uniquingKeysWith: { a, _ in a })

        // The incident's shape in this catalog: partialMD5 groups holding
        // several digests.
        var digestsBySample: [String: Set<String>] = [:]
        for r in model.records where !r.partialMD5.isEmpty {
            digestsBySample[r.partialMD5, default: []].insert(VideoScanModel.contentKey(of: r) ?? "none")
        }
        let crossDigestGroups = digestsBySample.values.filter { $0.count > 1 }.count

        let written = model.backfillDossierAcrossDuplicates()
        await shape.close()

        var byKey: [String: [UUID]] = [:]
        for r in model.records { if let k = VideoScanModel.contentKey(of: r) { byKey[k, default: []].append(r.id) } }
        var noDigestWritten = 0, noDonor = 0
        for r in model.records {
            guard let old = before[r.id] else { continue }
            let now = Dossier(r)
            guard now != old else { continue }
            guard let key = VideoScanModel.contentKey(of: r) else { noDigestWritten += 1; continue }
            let donors = (byKey[key] ?? []).filter { $0 != r.id }.compactMap { before[$0] }
            let explained = (now.transcript == old.transcript || donors.contains { $0.transcript == now.transcript })
                && (now.captions == old.captions || donors.contains { $0.captions == now.captions })
                && (now.ocrText == old.ocrText || donors.contains { Set(now.ocrText).isSubset(of: Set($0.ocrText)) })
                && (now.ocrDates == old.ocrDates || donors.contains { Set(now.ocrDates).isSubset(of: Set($0.ocrDates)) })
            if !explained { noDonor += 1 }
        }
        print("dossier backfill (production shape): \(model.records.count) rows · \(written) written · "
              + "\(crossDigestGroups) partialMD5 group(s) span several digests")
        #expect(noDigestWritten == 0, "\(noDigestWritten) row(s) with no whole-file digest received a dossier")
        #expect(noDonor == 0, "\(noDonor) row(s) received a value no same-digest copy held")
    }
}
