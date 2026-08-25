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

    /// Rick 2026-08-25: byte-identical originals on OTHER volumes are
    /// archived by content, not by the path the promote read. Pinned at
    /// scale so the fallback stays O(1) per lookup.
    @Test("content-level archived: hash and High dup-group fallbacks; Medium/no-hash never", .timeLimit(.minutes(1)))
    func contentLevelArchivedFallback() {
        let model = VideoScanModel()
        var records: [VideoRecord] = []
        var groups: [UUID] = []
        for i in 0..<50_000 {
            let src = VideoRecord()
            src.filename = "clip_\(i).mkv"; src.fullPath = "/Volumes/Projects/staging/clip_\(i).mkv"
            src.streamTypeRaw = StreamType.videoAndAudio.rawValue
            let group = UUID(); groups.append(group)
            src.duplicateGroupID = group; src.duplicateConfidence = .high
            src.duplicateReasons = "hash+filename+duration"
            let copy = VideoRecord()
            copy.filename = src.filename
            copy.fullPath = "/Volumes/Archive/Breen_Family_Archive/30_Video/1984/x_" + src.filename
            copy.derivedFrom = src.id; copy.derivationKind = ArchivePromotion.derivationKind
            copy.contentHash = "v1:hash\(i)"
            let original = VideoRecord()      // the MediaExpansion twin: no promote link
            original.filename = src.filename; original.fullPath = "/Volumes/MediaExpansion/clip_\(i).mkv"
            original.streamTypeRaw = StreamType.videoAndAudio.rawValue
            original.duplicateGroupID = group; original.duplicateConfidence = .high
            original.duplicateReasons = "hash+filename+duration+resolution"
            records += [src, copy, original]
        }
        // Negative controls.
        let medium = VideoRecord(); medium.fullPath = "/Volumes/X/m.mkv"
        medium.duplicateGroupID = groups[0]; medium.duplicateConfidence = .medium; medium.duplicateReasons = "hash+duration"
        let noHash = VideoRecord(); noHash.fullPath = "/Volumes/X/n.mkv"
        noHash.duplicateGroupID = groups[1]; noHash.duplicateConfidence = .high; noHash.duplicateReasons = "filename+duration"
        let byHash = VideoRecord(); byHash.fullPath = "/Volumes/X/h.mkv"; byHash.contentHash = "v1:hash7"
        records += [medium, noHash, byHash]
        model.records = records

        let t0 = CFAbsoluteTimeGetCurrent()
        var notYet = 0
        for r in records where !model.isArchiveCopy(r) { if model.pfNotYetArchived(r) { notYet += 1 } }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(notYet == 2, "only the Medium and the no-hash controls remain to-do (got \(notYet))")
        #expect(!model.pfNotYetArchived(byHash), "segmented content hash equal to an archive copy's = archived")
        #expect(model.pfNotYetArchived(medium) && model.pfNotYetArchived(noHash))
        #expect(model.archivePromotionIndex.rebuildCount == 1)
        #expect(ms < 2_000, "150k lookups took \(Int(ms)) ms")
        // Engines keep the strict promote link.
        #expect(model.masterArchiveCopy(of: records[2]) == nil && model.archivedCopy(of: records[2]) != nil)
    }
}
