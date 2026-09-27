// ArchiveRefileScaleTests.swift
// SCALE (feature-test checklist item 2) for Refile's Misfiled list: 100k
// archived records. The main-actor half (capturing the candidates) and the
// off-main half (manifest read + the rule) each run inside a load-aware
// budget, and the views read the result in O(1) — nothing O(records) in a
// view body (the list is the model's published dictionary).

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Refile — scale", .serialized)
@MainActor
struct ArchiveRefileScaleTests {

    @Test("the rule over 100k candidates is under a load-aware budget", .timeLimit(.minutes(2)))
    func ruleAtScale() {
        var cands: [ArchiveRefile.Candidate] = []
        cands.reserveCapacity(100_000)
        var rel = Set<String>()
        for i in 0..<100_000 {
            let path = "30_Video/1960-1969/1964/1964-xx-xx_test_clip_\(i).mov"
            rel.insert(path)
            cands.append(.init(rowID: UUID(), copyID: UUID(), copyRelPath: path,
                               streamTypeRaw: StreamType.videoAndAudio.rawValue,
                               copyFilename: (path as NSString).lastPathComponent, ext: "mov",
                               originalFilename: "test_clip_\(i).mov",
                               originalUserDate: i % 10 == 0 ? "1984" : "1964", originalUserDateConfidence: "known",
                               copyUserDate: "1964", copyUserDateConfidence: "known",
                               embeddedCreationDate: nil, originMake: nil, originModel: nil, originEncoder: nil,
                               inferredRecordDate: nil, inferredDateConfidence: nil, inferredDateRange: nil))
        }
        let clock = ContinuousClock()
        var found: [ArchiveRefile.Finding] = []
        let elapsed = clock.measure {
            found = ArchiveRefile.findings(candidates: cands, manifestRelPaths: rel)
        }
        #expect(found.count == 10_000)
        print("[refile-scale] rule over 100k: \(elapsed)")
        let budget = PerformanceLane.loadAwareDebugCeiling(.seconds(6))
        #expect(elapsed < budget, "100k evaluations took \(elapsed) — budget \(budget)")
    }

    @Test("100k archived records: main-actor capture + off-main manifest read + rule, under budget", .timeLimit(.minutes(3)))
    func modelRefreshAtScale() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("refile_scale")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let root = sb.archiveRoot.path

        var records: [VideoRecord] = []
        records.reserveCapacity(110_000)
        var manifest = MasterArchiveLayout.manifestHeader + "\n"
        manifest.reserveCapacity(25 << 20)
        for i in 0..<100_000 {
            let src = VideoRecord()
            src.filename = "test_clip_\(i).mov"
            src.fullPath = "/Volumes/test_Src/test_clip_\(i).mov"
            src.streamTypeRaw = StreamType.videoAndAudio.rawValue
            src.userDate = i % 20 == 0 ? "1984" : "1964"
            src.userDateConfidence = "known"
            let rel = "30_Video/1960-1969/1964/1964-xx-xx_test_clip_\(i).mov"
            let copy = VideoRecord()
            copy.filename = (rel as NSString).lastPathComponent
            copy.fullPath = (root as NSString).appendingPathComponent(rel)
            copy.streamTypeRaw = StreamType.videoAndAudio.rawValue
            copy.ext = "mov"
            copy.derivedFrom = src.id
            copy.derivationKind = ArchivePromotion.derivationKind
            copy.userDate = "1964"
            copy.userDateConfidence = "known"
            records.append(src)
            records.append(copy)
            manifest += ArchiveManifestCSV.line(for: .init(
                promotedAt: Date(timeIntervalSince1970: 1_780_000_000), archiveRelPath: rel, sha256: "00",
                sizeBytes: 1, originalPath: src.fullPath, originalVolume: "test_Src", recordID: copy.id,
                sourceRecordID: src.id, recordDate: "1964-xx-xx", dateConfidence: "user-known",
                people: [], starRating: 3))
        }
        try Data(manifest.utf8).write(to: sb.manifestURL)
        model.records = records

        // Main-actor half: the refresh captures in slices and yields between
        // them, so what matters is ONE slice (the longest the UI waits).
        let clock = ContinuousClock()
        _ = model.record(forID: records[0].id)   // the id index, built once per version, outside the slice
        let chunk = VideoScanModel.misfiledCaptureChunk
        var sliceCount = 0
        let slice = clock.measure {
            sliceCount = model.archiveMisfiledCandidates(root: root, in: records[0..<(chunk * 2)]).count
        }
        #expect(sliceCount == chunk, "every other record is a copy")
        print("[refile-scale] one main-actor slice (\(chunk * 2) records, \(chunk) copies): \(slice)")
        let sliceBudget = PerformanceLane.loadAwareDebugCeiling(.milliseconds(150))
        #expect(slice < sliceBudget, "one capture slice took \(slice) — budget \(sliceBudget)")
        var captured = 0
        let capture = clock.measure { captured = model.archiveMisfiledCandidates(root: root).count }
        #expect(captured == 100_000)
        print("[refile-scale] main-actor capture of 100k (sum of slices): \(capture)")

        // The whole refresh, off-main work included.
        let total = await clock.measure {
            model.refreshArchiveMisfiled(reason: "scale", force: true)
            await RefileFixture.settle(model)
        }
        #expect(model.archiveMisfiled.count == 5_000)
        print("[refile-scale] whole refresh over 100k: \(total)")
        #expect(model.archiveMisfiled.note == nil)
        let totalBudget = PerformanceLane.loadAwareDebugCeiling(.seconds(20))
        #expect(total < totalBudget, "Misfiled refresh over 100k took \(total) — budget \(totalBudget)")

        // Views read O(1).
        let reads = clock.measure {
            for r in records { _ = model.misfiledBadgeText(for: r) }
        }
        #expect(reads < PerformanceLane.loadAwareDebugCeiling(.seconds(1)), "200k badge reads took \(reads)")
    }
}
