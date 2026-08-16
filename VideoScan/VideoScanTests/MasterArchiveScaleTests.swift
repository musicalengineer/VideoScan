// MasterArchiveScaleTests.swift
// SCALE dimension (feature-test checklist item 2): 100k synthetic records
// with 5k promoted pairs; `masterArchiveCopy(of:)` / `promotionSource(of:)`
// / the two Show-menu predicates must be O(1) per call after ONE index
// rebuild per catalog mutation, inside an explicit time budget. Also pins
// that a mutation (revision bump) triggers exactly one more rebuild.

import Foundation
import Testing
@testable import VideoScan

@Suite("Master Archive — scale")
@MainActor
struct MasterArchiveScaleTests {

    @Test("100k records: 100k masterArchiveCopy lookups + filters under budget, one index rebuild", .timeLimit(.minutes(1)))
    func lookupsAtScale() {
        let model = VideoScanModel()
        var records: [VideoRecord] = []
        records.reserveCapacity(105_000)
        var sources: [VideoRecord] = []
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "/Volumes/Src/clip_\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            records.append(r)
            if i % 20 == 0 { sources.append(r) }   // 5,000 promoted
        }
        for s in sources {
            let c = VideoRecord()
            c.filename = s.filename
            c.fullPath = "/Volumes/Archive/Breen_Family_Archive/30_Video/Undated/xxxx-xx-xx_" + s.filename
            c.derivedFrom = s.id
            c.derivationKind = ArchivePromotion.derivationKind
            records.append(c)
        }
        model.records = records
        let index = model.archivePromotionIndex

        let t0 = CFAbsoluteTimeGetCurrent()
        var hits = 0
        for r in records where !model.isArchiveCopy(r) {
            if model.masterArchiveCopy(of: r) != nil { hits += 1 }
        }
        let lookupMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(hits == 5_000)
        #expect(index.rebuildCount == 1, "one rebuild for 100k lookups (was \(index.rebuildCount))")
        #expect(lookupMs < 1_500, "100k lookups took \(Int(lookupMs)) ms — budget 1.5 s incl. one O(n) rebuild")

        // Reverse direction + predicates: still no rebuild.
        let t1 = CFAbsoluteTimeGetCurrent()
        var reverse = 0, notYet = 0, has = 0
        for r in records {
            if model.promotionSource(of: r) != nil { reverse += 1 }
            if model.pfNotYetArchived(r) { notYet += 1 }
            if model.pfHasMasterCopy(r) { has += 1 }
        }
        let predMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        #expect(reverse == 5_000)
        #expect(has == 5_000)
        #expect(notYet == 95_000)
        #expect(index.rebuildCount == 1)
        #expect(predMs < 1_500, "predicates over 105k records took \(Int(predMs)) ms")

        // A mutation announcement invalidates ONCE.
        model.noteCatalogRecordsMutated()
        _ = model.masterArchiveCopy(of: sources[0])
        _ = model.masterArchiveCopy(of: sources[1])
        #expect(index.rebuildCount == 2)
    }

    @Test("buildPromotePlan is O(selection): 2,000-record plan against a 100k catalog under budget", .timeLimit(.minutes(1)))
    func planAtScale() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("scaleplan")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        // Use a real (temp) directory so reachability is true without /Volumes.
        let base = sb.sources.path
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "\(base)/clip_\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.sizeBytes = 1_000
            records.append(r)
        }
        model.records = records
        let ids = records.prefix(2_000).map(\.id)
        let t0 = CFAbsoluteTimeGetCurrent()
        let plan = try #require(model.buildPromotePlan(recordIDs: ids))
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(plan.entries.count == 2_000)
        #expect(plan.totalBytes == 2_000_000)
        #expect(ms < 2_000, "plan for 2k of 100k took \(Int(ms)) ms")
    }
}
