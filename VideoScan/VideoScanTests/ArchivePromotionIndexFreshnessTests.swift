// ArchivePromotionIndexFreshnessTests.swift
// GH #481 item 1: the archive promotion index behind the Show filters
// "Not Yet Archived" / "Has Master Copy" (VideoScanModel+MasterArchive,
// `promotionIndexVersion`) was keyed on (records.count,
// volumeAggregatesRevision). Two real writers change facts that index reads
// on an EXISTING row and bump neither:
//   1. Analyze Duplicates (`analyzeDuplicates`) — stamps `duplicateGroupID`
//      in place and announces through `.videoScanCatalogMutated`, which
//      saves (debounced) but never touches volumeAggregatesRevision. The
//      index's dup-group → archive-copy map then misses the new group.
//   2. The full-file hash writer (`storeContentFixity` — Check Copies, the
//      full-hash backfill, Delete Duplicates' keeper read), followed by the
//      job's own catalog save. An archive copy without `archiveFixity` is
//      known to the index by its `contentFixity`; the write gives it one and
//      the index never hears.
// Both rows are evaluated fresh at query time; only the copy side of the
// index went stale, so the filter showed a row as Not Yet Archived (or
// without a master copy) until some unrelated bulk mutation.
// RED before the fix; the fix keys the index on `catalogMutationRevision`
// (bumped by records.didSet, every save and notifyVolumeAggregatesStale).

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive promotion index — fresh after in-place writers (GH #481)", .serialized)
@MainActor
struct ArchivePromotionIndexFreshnessTests {

    private static let stamp = FileIdentityStamp(device: 1, inode: 7, size: 5_000, mtimeNs: 1)

    private func clip(_ name: String, dir: String, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.partialMD5 = md5
        r.sizeBytes = 5_000
        r.durationSeconds = 60
        r.isPlayable = "Yes"
        return r
    }

    /// The promoted copy as Promote leaves it, minus the segmented
    /// signature (a probe that skipped hashing): nothing but the promote
    /// link and a dup group can tie a sibling to it.
    private func archiveCopy(of source: VideoRecord) -> VideoRecord {
        let c = VideoRecord()
        c.filename = "1994-07-04_Picnic.mov"
        c.fullPath = "/Volumes/Archive/Breen_Family_Archive/30_Video/1994/" + c.filename
        c.directory = "/Volumes/Archive/Breen_Family_Archive/30_Video/1994"
        c.streamTypeRaw = StreamType.videoAndAudio.rawValue
        c.sizeBytes = source.sizeBytes
        c.derivedFrom = source.id
        c.derivationKind = ArchivePromotion.derivationKind
        c.archiveFixity = ArchiveFixity(digest: String(repeating: "a", count: 64), verifiedAt: Date(),
                                        sizeBytes: source.sizeBytes)
        return c
    }

    @Test("regression #481: Analyze Duplicates groups a sibling with a promoted source — Not Yet Archived drops it at once")
    func analyzeDuplicatesRefreshesNotYetArchived() async {
        let model = VideoScanModel()
        let source = clip("picnic.mov", dir: "/Volumes/Projects/staging", md5: "picnic")
        let sibling = clip("picnic.mov", dir: "/Volumes/MediaExpansion/tapes", md5: "picnic")
        let copy = archiveCopy(of: source)
        model.records = [source, sibling, copy]

        // The filter has been drawn once: the index is built, the sibling is
        // honestly still to do (no group ties it to anything archived yet).
        #expect(model.pfNotYetArchived(sibling), "fixture: before analysis the sibling is not archived")
        #expect(!model.pfNotYetArchived(source), "fixture: the promoted source is archived")
        let countBefore = model.records.count
        let revisionBefore = model.volumeAggregatesRevision

        await model.analyzeDuplicates()

        // The real writer did what the fixture needs, and moved neither old key.
        #expect(sibling.duplicateGroupID != nil && sibling.duplicateGroupID == source.duplicateGroupID,
                "fixture: Analyze Duplicates grouped the sibling with the promoted source")
        #expect(sibling.duplicateConfidence == .high && sibling.duplicateReasons.contains("hash"),
                "fixture: High confidence on a hash reason (\(sibling.duplicateReasons))")
        #expect(model.records.count == countBefore && model.volumeAggregatesRevision == revisionBefore,
                "the writer bumps neither records.count nor volumeAggregatesRevision — the old key's blind spot")

        #expect(!model.pfNotYetArchived(sibling),
                "the sibling's content is archived through its group; the filter must say so now, not after an unrelated bulk mutation (RED: stale index)")
    }

    @Test("regression #481: a full-file hash stored on an archive copy (then saved) makes Has Master Copy true at once")
    func storedCopyFixityRefreshesHasMasterCopy() {
        let model = VideoScanModel()
        let digest = String(repeating: "b", count: 64)
        let sibling = clip("tape12.mov", dir: "/Volumes/MediaExpansion/tapes", md5: "t12")
        sibling.contentFixity = ContentFixity(digest: digest, byteCount: sibling.sizeBytes, stamp: Self.stamp)
        // An archive copy whose archive fixity is gone (a rescan that could
        // not carry it, or a Verify that cleared it) and whose source row is
        // gone: the index can know it by digest only once it has a hash.
        let copy = VideoRecord()
        copy.filename = "1991_tape12.mov"
        copy.fullPath = "/Volumes/Archive/Breen_Family_Archive/30_Video/1991/" + copy.filename
        copy.streamTypeRaw = StreamType.videoAndAudio.rawValue
        copy.sizeBytes = sibling.sizeBytes
        copy.derivedFrom = UUID()
        copy.derivationKind = ArchivePromotion.derivationKind
        model.records = [sibling, copy]

        #expect(!model.pfHasMasterCopy(sibling), "fixture: no copy is known by this digest yet")
        let countBefore = model.records.count
        let revisionBefore = model.volumeAggregatesRevision

        // The real writer (Check Copies / full-hash backfill / Delete
        // Duplicates keeper read), then the save every one of those jobs
        // makes at its checkpoint.
        let written = model.storeContentFixity(recordID: copy.id, path: copy.fullPath,
                                               fixity: ContentFixity(digest: digest, byteCount: copy.sizeBytes,
                                                                     stamp: Self.stamp))
        model.saveCatalogDebounced()
        #expect(written, "fixture: the writer stored the hash")
        #expect(model.records.count == countBefore && model.volumeAggregatesRevision == revisionBefore,
                "the writer + save bump neither records.count nor volumeAggregatesRevision")

        #expect(model.pfHasMasterCopy(sibling),
                "the copy now proves this content by whole-file SHA-256; Has Master Copy must say so now (RED: stale index)")
        #expect(!model.pfNotYetArchived(sibling))
    }

    @Test("the honest key costs one rebuild per mutation, not one per lookup")
    func oneRebuildPerMutation() {
        let model = VideoScanModel()
        let source = clip("a.mov", dir: "/Volumes/P", md5: "a")
        let copy = archiveCopy(of: source)
        var rows = [source, copy]
        for i in 0..<1_000 { rows.append(clip("x\(i).mov", dir: "/Volumes/P", md5: "x\(i)")) }
        model.records = rows
        let index = model.archivePromotionIndex
        let before = index.rebuildCount
        for r in rows { _ = model.pfNotYetArchived(r); _ = model.pfHasMasterCopy(r) }
        #expect(index.rebuildCount == before + 1, "one rebuild for 2,002 lookups")
        model.saveCatalogDebounced()
        model.saveCatalogDebounced()
        for r in rows { _ = model.pfNotYetArchived(r) }
        #expect(index.rebuildCount == before + 2, "a burst of saves, then lookups: exactly one more rebuild")
    }
}
