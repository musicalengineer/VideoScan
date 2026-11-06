// ProductionShapeContentLeftTests.swift — "88 left to analyze" at PRODUCTION
// SHAPE (Rick 2026-11-06): Rick's real catalog (a sqlite `.backup` copy in a
// temp folder, ProductionShapeScene), the app's real coverage projection and
// the dossier batch's real per-file skip rule. No media is decoded; the batch's
// DRM probe (header only) is replaced by "not protected".
//
// On the 17:50 copy the count read 80 left after Detect Duplicates: 70 archived
// rows the extractor could not decode (68 whose bytes are flagged needs-reformat
// on an In Triage copy) and 10 files analyzed without a transcript. Invariants,
// true of ANY real catalog:
//   (a) no file counted left for a dossier stage has its content flagged
//       needs-reformat on any copy (the 68: red before the fix);
//   (b) no dossier-stamped file is counted left for a dossier stage (the 10);
//   (c) every reachable file counted left for a dossier stage is one the batch's
//       skip rule would analyze (`dossierSkipReason` == nil), and every file the
//       rule would analyze with a video or audio stream is counted left.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`). PRIVACY: messages carry counts only, never paths.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape Content left: the count is what the batch would analyze — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeContentLeftTests {

    static let dossierStages: [AnalyzeCycler] = [.sceneCaptions, .ocr, .transcribe]

    @Test("the live copy: nothing counted left is undecodable content or already analyzed, and the count's files are the batch's")
    func theCountIsTheBatch() async throws {
        let shape = try await ProductionShapeScene.make("contentleft"); defer { shape.cleanup() }
        let model = shape.model
        let mounted = VolumeReachability.currentMountedRoots()
        let scope = AnalysisScope()
        let byPath = Dictionary(model.records.map { ($0.fullPath, $0) }, uniquingKeysWith: { a, _ in a })
        let unreadable = UnreadableContentIndex(records: model.records)
        let inputs = AnalyzeCoverageCalculator.project(model.records)

        var countedLeft = Set<String>()
        for input in inputs {
            let one = AnalyzeCoverageCalculator.compute(inputs: [input], volumes: [], mountedRoots: mounted, scope: scope)
            if Self.dossierStages.contains(where: { one.counts($0).remaining > 0 }) { countedLeft.insert(input.fullPath) }
        }

        var undecodableLeft = 0, stampedLeft = 0
        for path in countedLeft {
            guard let r = byPath[path] else { continue }
            if unreadable.contains(r) || r.needsReformat { undecodableLeft += 1 }
            if r.dossierProcessedAt != nil { stampedLeft += 1 }
        }

        // The batch's own rule, file by file (no decode, no write: the skip
        // reason only; the DRM probe is replaced).
        let orch = CaptionOrchestrator(runnerFactory: { StubDossierRunner(modelID: "stub-prodshape") })
        orch.drmProbe = { _ in false }
        orch.dossierUnreadable = unreadable
        var batchWould = Set<String>()
        for r in model.records where !(r.isPurged || r.isSetAside || r.isSuperseded)
            && pfMetadataCandidateIsEligible(r, admitting: LifecycleStage.dossierStages)
            && scope.includes(streamTypeRaw: r.streamTypeRaw, filename: r.filename)
            && Self.reachable(r.fullPath, mounted) {
            let stream = r.streamType
            guard stream == .videoAndAudio || stream == .videoOnly || stream == .audioOnly else { continue }
            if await orch.dossierSkipReason(r, force: false) == nil { batchWould.insert(r.fullPath) }
        }
        await shape.close()

        let reachableLeft = countedLeft.filter { Self.reachable($0, mounted) }
        print("content left (production shape): \(countedLeft.count) counted left for a dossier stage "
              + "(\(reachableLeft.count) reachable now) · the batch would analyze \(batchWould.count) · "
              + "\(unreadable.digests.count) undecodable content(s)")
        #expect(undecodableLeft == 0, "\(undecodableLeft) file(s) counted left whose bytes are flagged needs-reformat")
        #expect(stampedLeft == 0, "\(stampedLeft) dossier-stamped file(s) counted left")
        #expect(reachableLeft.subtracting(batchWould).isEmpty,
                "\(reachableLeft.subtracting(batchWould).count) counted left that the batch would skip")
        #expect(batchWould.subtracting(countedLeft).isEmpty,
                "\(batchWould.subtracting(countedLeft).count) the batch would analyze that the count does not show")
    }

    /// The count's own reachability for a path with no scan target: a
    /// /Volumes path is reachable iff its volume is mounted.
    static func reachable(_ path: String, _ mounted: Set<String>) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return true }
        let name = path.dropFirst(9).prefix { $0 != "/" }
        return mounted.contains("/Volumes/" + name) && FileManager.default.fileExists(atPath: path)
    }
}
