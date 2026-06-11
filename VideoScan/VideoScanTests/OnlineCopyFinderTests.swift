import Testing
import Foundation
@testable import VideoScan

// MARK: - OnlineCopyFinderTests
//
// Locks in the strict same-content identity behind "Find Online
// Version" and "Show Migrated…". The dangerous regressions here are
// false positives — a "copy" that isn't the same content (wrong UMID
// semantics, hash collision across sizes) would send Rick to the
// wrong file, which is worse than finding nothing.

struct OnlineCopyFinderTests {

    private func record(path: String,
                        md5: String = "",
                        size: Int64 = 0,
                        umid: String = "",
                        streamType: String = "video+audio",
                        dupGroup: UUID? = nil,
                        purged: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.sizeBytes = size
        r.materialPackageUMID = umid
        r.streamTypeRaw = streamType
        r.duplicateGroupID = dupGroup
        if purged { r.purgedAt = Date() }
        return r
    }

    // MARK: Per-record matching

    @Test func hashAndSizeMatchFindsCopy() {
        let a = record(path: "/Volumes/Maxtor750/clip05.mov", md5: "abc", size: 100)
        let b = record(path: "/Volumes/LaCie/clip05.mov", md5: "abc", size: 100)
        let copies = OnlineCopyFinder(records: [a, b]).sameContentCopies(of: a)
        #expect(copies.map(\.id) == [b.id])
    }

    @Test func hashMatchWithDifferentSizeIsNotACopy() {
        let a = record(path: "/Volumes/Maxtor750/clip.mov", md5: "abc", size: 100)
        let b = record(path: "/Volumes/LaCie/clip.mov", md5: "abc", size: 999)
        #expect(OnlineCopyFinder(records: [a, b]).sameContentCopies(of: a).isEmpty)
    }

    @Test func emptyHashesNeverMatchEachOther() {
        // Two unhashed records with equal sizes must not pair up — an
        // empty MD5 is "unknown", not an identity.
        let a = record(path: "/Volumes/A/x.mov", size: 100)
        let b = record(path: "/Volumes/B/y.mov", size: 100)
        #expect(OnlineCopyFinder(records: [a, b]).sameContentCopies(of: a).isEmpty)
    }

    @Test func umidMatchRequiresSameStreamType() {
        // Avid MXF: audio and video files of one clip share the
        // material package UMID. The audio sibling is NOT a copy.
        let video = record(path: "/Volumes/A/clip_v.mxf", umid: "U1", streamType: "video-only")
        let audio = record(path: "/Volumes/A/clip_a.mxf", umid: "U1", streamType: "audio-only")
        let videoCopy = record(path: "/Volumes/B/clip_v.mxf", umid: "U1", streamType: "video-only")
        let copies = OnlineCopyFinder(records: [video, audio, videoCopy])
            .sameContentCopies(of: video)
        #expect(copies.map(\.id) == [videoCopy.id])
    }

    @Test func duplicateGroupMembershipCounts() {
        let g = UUID()
        let a = record(path: "/Volumes/A/clip.mov", dupGroup: g)
        let b = record(path: "/Volumes/B/clip_copy.mov", dupGroup: g)
        let unrelated = record(path: "/Volumes/B/other.mov", dupGroup: UUID())
        let copies = OnlineCopyFinder(records: [a, b, unrelated]).sameContentCopies(of: a)
        #expect(copies.map(\.id) == [b.id])
    }

    @Test func tiersDedupeAndHashOutranksGroup() {
        // Same record reachable via hash AND dup-group → appears once,
        // and a hash-tier match sorts ahead of a group-only match.
        let g = UUID()
        let a = record(path: "/Volumes/A/clip.mov", md5: "abc", size: 100, dupGroup: g)
        let hashAndGroup = record(path: "/Volumes/Z/clip.mov", md5: "abc", size: 100, dupGroup: g)
        let groupOnly = record(path: "/Volumes/B/clip_reenc.mov", dupGroup: g)
        let copies = OnlineCopyFinder(records: [a, hashAndGroup, groupOnly])
            .sameContentCopies(of: a)
        #expect(copies.map(\.id) == [hashAndGroup.id, groupOnly.id])
    }

    @Test func purgedRecordsExcludedBothSides() {
        let a = record(path: "/Volumes/A/clip.mov", md5: "abc", size: 100)
        let purgedCopy = record(path: "/Volumes/B/clip.mov", md5: "abc", size: 100, purged: true)
        let finder = OnlineCopyFinder(records: [a, purgedCopy])
        #expect(finder.sameContentCopies(of: a).isEmpty)
        #expect(finder.sameContentCopies(of: purgedCopy).isEmpty)
    }

    // MARK: Migration report

    private func report(records: [VideoRecord],
                        prefix: String = "/Volumes/Old/",
                        online: Set<String> = []) -> OnlineCopyFinder.MigrationReport {
        OnlineCopyFinder(records: records).migrationReport(
            volumePathPrefix: prefix,
            isOnline: { path in online.contains(where: { path.hasPrefix($0) }) },
            volumeLabel: { path in
                // "/Volumes/X/..." → "X"
                path.split(separator: "/").dropFirst().first.map(String.init) ?? "?"
            }
        )
    }

    @Test func fullyMigratedVolume() {
        let a = record(path: "/Volumes/Old/a.mov", md5: "h1", size: 1)
        let b = record(path: "/Volumes/Old/b.mov", md5: "h2", size: 2)
        let aCopy = record(path: "/Volumes/New/a.mov", md5: "h1", size: 1)
        let bCopy = record(path: "/Volumes/New/b.mov", md5: "h2", size: 2)
        let r = report(records: [a, b, aCopy, bCopy], online: ["/Volumes/New/"])
        #expect(r.total == 2)
        #expect(r.migrated == 2)
        #expect(r.migratedOnlineNow == 2)
        #expect(r.isFullyMigrated)
        #expect(r.unmigratedIDs.isEmpty)
        #expect(r.destinations == [.init(volumeLabel: "New", recordCount: 2, isOnline: true)])
    }

    @Test func unmigratedFilesAreReportedByID() {
        let a = record(path: "/Volumes/Old/a.mov", md5: "h1", size: 1)
        let orphan = record(path: "/Volumes/Old/lost.mov", md5: "h9", size: 9)
        let aCopy = record(path: "/Volumes/New/a.mov", md5: "h1", size: 1)
        let r = report(records: [a, orphan, aCopy], online: ["/Volumes/New/"])
        #expect(r.total == 2)
        #expect(r.migrated == 1)
        #expect(!r.isFullyMigrated)
        #expect(r.unmigratedIDs == [orphan.id])
    }

    @Test func copyOnSameVolumeDoesNotCountAsMigrated() {
        // A duplicate sitting on the SAME dying disk is not a migration.
        let a = record(path: "/Volumes/Old/a.mov", md5: "h1", size: 1)
        let sameDisk = record(path: "/Volumes/Old/backup/a.mov", md5: "h1", size: 1)
        let r = report(records: [a, sameDisk])
        #expect(r.total == 2)
        #expect(r.migrated == 0)
        #expect(Set(r.unmigratedIDs) == Set([a.id, sameDisk.id]))
    }

    @Test func offlineDestinationCountsAsMigratedButNotUsableNow() {
        let a = record(path: "/Volumes/Old/a.mov", md5: "h1", size: 1)
        let coldCopy = record(path: "/Volumes/Shelf/a.mov", md5: "h1", size: 1)
        let r = report(records: [a, coldCopy], online: [])
        #expect(r.migrated == 1)
        #expect(r.migratedOnlineNow == 0)
        #expect(r.destinations == [.init(volumeLabel: "Shelf", recordCount: 1, isOnline: false)])
    }

    @Test func destinationsSortOnlineFirstThenByCount() {
        let a = record(path: "/Volumes/Old/a.mov", md5: "h1", size: 1)
        let b = record(path: "/Volumes/Old/b.mov", md5: "h2", size: 2)
        let aShelf = record(path: "/Volumes/Shelf/a.mov", md5: "h1", size: 1)
        let bShelf = record(path: "/Volumes/Shelf/b.mov", md5: "h2", size: 2)
        let aNew = record(path: "/Volumes/New/a.mov", md5: "h1", size: 1)
        let r = report(records: [a, b, aShelf, bShelf, aNew], online: ["/Volumes/New/"])
        // New is online → first despite Shelf holding more copies.
        #expect(r.destinations.map(\.volumeLabel) == ["New", "Shelf"])
        #expect(r.migratedOnlineNow == 1)
    }

    @Test func emptyVolumeIsNotFullyMigrated() {
        // total == 0 must not read as "all safe" — there's nothing to
        // be safe. isFullyMigrated requires total > 0.
        let r = report(records: [record(path: "/Volumes/Other/x.mov")])
        #expect(r.total == 0)
        #expect(!r.isFullyMigrated)
    }
}
