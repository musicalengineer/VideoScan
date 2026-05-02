import Testing
import Foundation
@testable import VideoScan

// MARK: - Catalog Import/Export Tests

@MainActor
struct CatalogImportExportTests {

    private func makeRec(name: String, md5: String, size: Int64, duration: Double = 10) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.partialMD5 = md5
        r.sizeBytes = size
        r.durationSeconds = duration
        r.streamTypeRaw = "Video+Audio"
        r.fullPath = "/Volumes/RemoteDrive/\(name)"
        return r
    }

    @Test func exportThenImportIntoEmptyCatalogAddsEverything() throws {
        let source = VideoScanModel()
        source.records = []
        source.records = [
            makeRec(name: "a.mov", md5: "AAAA", size: 100),
            makeRec(name: "b.mov", md5: "BBBB", size: 200)
        ]

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try source.exportCatalog(to: tmp)

        let dest = VideoScanModel()
        dest.records = []
        let result = try dest.importCatalog(from: tmp)

        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(dest.records.count == 2)
        #expect(dest.records.allSatisfy { !$0.sourceHost.isEmpty })
    }

    @Test func importSkipsRecordsAlreadyPresentByContentIdentity() throws {
        let source = VideoScanModel()
        source.records = [
            makeRec(name: "shared.mov", md5: "SAME", size: 500),
            makeRec(name: "new.mov", md5: "NEW", size: 700)
        ]

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try source.exportCatalog(to: tmp)

        let dest = VideoScanModel()
        let existing = makeRec(name: "shared.mov", md5: "SAME", size: 500)
        existing.fullPath = "/Volumes/LocalDrive/shared.mov"
        dest.records = [existing]

        let result = try dest.importCatalog(from: tmp)

        #expect(result.added == 1)
        #expect(result.skipped == 1)
        #expect(dest.records.count == 2)
        #expect(dest.records.contains { $0.fullPath == "/Volumes/LocalDrive/shared.mov" })
        #expect(dest.records.contains { $0.partialMD5 == "NEW" })
    }
}

// MARK: - ScanContext Tests

struct ScanContextTests {

    @Test func defaultsAreEmpty() {
        let ctx = ScanContext()
        #expect(ctx.scanHost.isEmpty)
        #expect(ctx.volumeUUID.isEmpty)
        #expect(ctx.volumeMountType.isEmpty)
        #expect(ctx.remoteServerName.isEmpty)
        #expect(ctx.scannedAt == nil)
        #expect(ctx.isPopulated == false)
        #expect(ctx.isRemoteMount == false)
    }

    @Test func isPopulatedFlipsOnAnyField() {
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        #expect(ctx.isPopulated == true)

        ctx = ScanContext()
        ctx.volumeUUID = "ABCD-1234"
        #expect(ctx.isPopulated == true)

        ctx = ScanContext()
        ctx.volumeMountType = "apfs"
        #expect(ctx.isPopulated == true)
    }

    @Test func isRemoteMountDetectsNetworkFilesystems() {
        for fs in ["smbfs", "nfs", "afpfs", "webdav"] {
            var ctx = ScanContext()
            ctx.volumeMountType = fs
            #expect(ctx.isRemoteMount == true, "\(fs) should be remote")
        }
        for fs in ["apfs", "hfs", "msdos", "exfat", ""] {
            var ctx = ScanContext()
            ctx.volumeMountType = fs
            #expect(ctx.isRemoteMount == false, "\(fs) should be local")
        }
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        ctx.volumeUUID = "A8F2-1234-5678-9ABC"
        ctx.volumeMountType = "smbfs"
        ctx.remoteServerName = "macpro.local"
        ctx.scannedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(ctx)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(ScanContext.self, from: data)

        #expect(round == ctx)
    }

    @Test func decodeFromEmptyJSONYieldsDefaults() throws {
        let data = Data("{}".utf8)
        let ctx = try JSONDecoder().decode(ScanContext.self, from: data)
        #expect(ctx == ScanContext())
    }

    // MARK: parseRemoteServer

    @Test func parseRemoteServerSMB() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//macpro.local/FamilyMedia") == "macpro.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//rick@macpro.local/share") == "macpro.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//DOMAIN;user@host/share") == "host")
    }

    @Test func parseRemoteServerNFS() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "nfs", mntFromName: "nas.local:/export/media") == "nas.local")
    }

    @Test func parseRemoteServerAFP() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "afp://oldserver.local/Share") == "oldserver.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "afp://rick@oldserver.local/Share") == "oldserver.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "//oldserver.local/Share") == "oldserver.local")
    }

    @Test func parseRemoteServerWebDAV() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "webdav", mntFromName: "https://cloud.example.com/dav/files") == "cloud.example.com")
    }

    @Test func parseRemoteServerLocalReturnsEmpty() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "apfs", mntFromName: "/dev/disk3s1").isEmpty)
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "hfs", mntFromName: "/dev/disk4").isEmpty)
    }

    // MARK: capture (integration)

    @Test func captureForLocalTempDirectoryPopulatesContext() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ScanContext.capture(for: tmp)

        #expect(!ctx.scanHost.isEmpty)
        #expect(ctx.isRemoteMount == false)
        #expect(!ctx.volumeMountType.isEmpty)
        #expect(ctx.remoteServerName == "")
        #expect(ctx.scannedAt != nil)
        #expect(ctx.isPopulated == true)
    }
}

// MARK: - Catalog Skip Set Tests

struct CatalogSkipSetTests {

    @Test func skipSetFiltersAudioOnly() async {
        let rec1 = VideoRecord()
        rec1.fullPath = "/vol/video1.mov"
        rec1.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let rec2 = VideoRecord()
        rec2.fullPath = "/vol/audio.wav"
        rec2.streamTypeRaw = StreamType.audioOnly.rawValue

        let rec3 = VideoRecord()
        rec3.fullPath = "/vol/broken.mxf"
        rec3.streamTypeRaw = StreamType.ffprobeFailed.rawValue

        let rec4 = VideoRecord()
        rec4.fullPath = "/vol/empty.avi"
        rec4.streamTypeRaw = StreamType.noStreams.rawValue

        let rec5 = VideoRecord()
        rec5.fullPath = "/vol/video2.mp4"
        rec5.streamTypeRaw = StreamType.videoOnly.rawValue

        var skip = Set<String>()
        for rec in [rec1, rec2, rec3, rec4, rec5] {
            switch rec.streamType {
            case .audioOnly, .noStreams, .ffprobeFailed:
                if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
            case .videoAndAudio, .videoOnly:
                break
            }
        }

        #expect(skip.count == 3)
        #expect(skip.contains("/vol/audio.wav"))
        #expect(skip.contains("/vol/broken.mxf"))
        #expect(skip.contains("/vol/empty.avi"))
        #expect(!skip.contains("/vol/video1.mov"))
        #expect(!skip.contains("/vol/video2.mp4"))
    }

    @Test func skipSetFilteringReducesFileList() async {
        let allFiles = [
            "/vol/video1.mov",
            "/vol/audio.wav",
            "/vol/broken.mxf",
            "/vol/video2.mp4",
            "/vol/empty.avi"
        ]
        let skipSet: Set<String> = ["/vol/audio.wav", "/vol/broken.mxf", "/vol/empty.avi"]

        var filtered = allFiles
        filtered.removeAll { skipSet.contains($0) }

        #expect(filtered.count == 2)
        #expect(filtered.contains("/vol/video1.mov"))
        #expect(filtered.contains("/vol/video2.mp4"))
    }

    @Test func skipSetEmptyWhenNoBadFiles() async {
        let rec1 = VideoRecord()
        rec1.fullPath = "/vol/good1.mov"
        rec1.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let rec2 = VideoRecord()
        rec2.fullPath = "/vol/good2.mp4"
        rec2.streamTypeRaw = StreamType.videoOnly.rawValue

        var skip = Set<String>()
        for rec in [rec1, rec2] {
            switch rec.streamType {
            case .audioOnly, .noStreams, .ffprobeFailed:
                if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
            case .videoAndAudio, .videoOnly:
                break
            }
        }

        #expect(skip.isEmpty)
    }

    @Test func skipSetIgnoresEmptyPaths() async {
        let rec = VideoRecord()
        rec.fullPath = ""
        rec.streamTypeRaw = StreamType.audioOnly.rawValue

        var skip = Set<String>()
        switch rec.streamType {
        case .audioOnly, .noStreams, .ffprobeFailed:
            if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
        case .videoAndAudio, .videoOnly:
            break
        }

        #expect(skip.isEmpty, "Empty paths should not be added to skip set")
    }

    @Test func settingDefaultsToTrue() {
        let settings = PersonFinderSettings()
        #expect(settings.skipCatalogBadFiles == true)
    }
}

// MARK: - Volume Compare Tests

struct VolumeCompareTests {

    private func makeRecord(filename: String, path: String, md5: String, size: Int64, streamType: StreamType = .videoAndAudio) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = filename
        rec.fullPath = path
        rec.partialMD5 = md5
        rec.sizeBytes = size
        rec.streamTypeRaw = streamType.rawValue
        return rec
    }

    @Test func identicalFilesAreAlreadySafe() {
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "abc123", size: 1000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "abc123", size: 1000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func renamedFileMatchesByHash() {
        let src = [makeRecord(filename: "original.mov", path: "/Volumes/Old/original.mov", md5: "abc123", size: 5000)]
        let dst = [makeRecord(filename: "renamed.mov", path: "/Volumes/New/renamed.mov", md5: "abc123", size: 5000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func uniqueFileIsMissing() {
        let src = [
            makeRecord(filename: "shared.mov", path: "/Volumes/Old/shared.mov", md5: "aaa", size: 1000),
            makeRecord(filename: "unique.mov", path: "/Volumes/Old/unique.mov", md5: "bbb", size: 2000)
        ]
        let dst = [makeRecord(filename: "shared.mov", path: "/Volumes/New/shared.mov", md5: "aaa", size: 1000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 1)
        #expect(result.missingFiles.first?.filename == "unique.mov")
        #expect(result.missingBytes == 2000)
    }

    @Test func fallbackMatchesByNameAndSize() {
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "", size: 3000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "xyz", size: 3000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func differentSizeSameNameIsMissing() {
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "aaa", size: 3000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "bbb", size: 5000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.sourceOnly == 1, "Same filename but different size+hash should be missing")
    }

    @Test func emptyDestinationMeansAllMissing() {
        let src = [
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "x", size: 100),
            makeRecord(filename: "b.mov", path: "/Volumes/Old/b.mov", md5: "y", size: 200)
        ]
        let result = VolumeComparer.compare(sourceRecords: src, destRecords: [], sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.sourceOnly == 2)
        #expect(result.missingBytes == 300)
    }

    // MARK: - Audit mode

    @Test func auditMode_fileFoundOnAnyDestinationIsSafe() {
        let src = [
            makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/MacPro/B.mov", md5: "b2", size: 200)
        ]
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/Backup/B.mov", md5: "b2", size: 200)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.isAuditMode == true)
        #expect(result.alreadySafeCount == 2)
        #expect(result.sourceOnly == 0)
        #expect(result.destLabel == "any other cataloged volume")
    }

    @Test func auditMode_fileOnNoOtherVolumeIsFlagged() {
        let src = [
            makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "C.mov", path: "/Volumes/MacPro/C.mov", md5: "c3", size: 300)
        ]
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.sourceOnly == 1)
        #expect(result.missingFiles.first?.filename == "C.mov")
        #expect(result.missingBytes == 300)
    }

    @Test func auditMode_sameFileOnMultipleDestsCountsOnceAsSafe() {
        let src = [makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100)]
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "A.mov", path: "/Volumes/Backup/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "A.mov", path: "/Volumes/Archive/A.mov", md5: "a1", size: 100)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.alreadySafeCount == 1, "Safe count follows source side, not dest multiplicity")
        #expect(result.sourceOnly == 0)
    }

    @Test func auditMode_defaultsPreserveNonAuditBehavior() {
        let src = [makeRecord(filename: "A.mov", path: "/Volumes/Old/A.mov", md5: "a1", size: 100)]
        let dst = [makeRecord(filename: "A.mov", path: "/Volumes/New/A.mov", md5: "a1", size: 100)]
        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst,
                                            sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.isAuditMode == false)
        #expect(result.destLabel == "New", "Label defaults to the last path component of destPath")
        #expect(result.alreadySafeCount == 1)
    }

    // MARK: - Multi-source / multi-dest

    private func recordsUnder(_ paths: [String], from all: [VideoRecord]) -> [VideoRecord] {
        all.filter { rec in paths.contains(where: { rec.fullPath.hasPrefix($0) }) }
    }

    @Test func multiSource_sameMachineDuplicatesDoNotCountAsBackup() {
        let allRecords = [
            makeRecord(filename: "precious.mov", path: "/Volumes/InternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/ExternalRaid/precious.mov", md5: "p1", size: 1000)
        ]
        let macProVolumes = ["/Volumes/InternalRaid", "/Volumes/ExternalRaid"]

        let src = recordsUnder(macProVolumes, from: allRecords)
        let dst = allRecords.filter { rec in
            !macProVolumes.contains(where: { rec.fullPath.hasPrefix($0) })
        }
        #expect(dst.isEmpty, "No off-MacPro records means nothing can count as backup")

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid, ExternalRaid", destPath: "",
            destLabel: "any volume outside the source set", isAuditMode: true
        )

        #expect(result.sourceOnly == 2, "Both copies should flag as missing — neither is off-MacPro")
        #expect(result.alreadySafeCount == 0)
    }

    @Test func multiSource_backupOnOffMachineVolumeCountsAsSafe() {
        let allRecords = [
            makeRecord(filename: "precious.mov", path: "/Volumes/InternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/ExternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/MyBook3TB/precious.mov", md5: "p1", size: 1000)
        ]
        let macProVolumes = ["/Volumes/InternalRaid", "/Volumes/ExternalRaid"]

        let src = recordsUnder(macProVolumes, from: allRecords)
        let dst = allRecords.filter { rec in
            !macProVolumes.contains(where: { rec.fullPath.hasPrefix($0) })
        }

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid, ExternalRaid", destPath: "",
            destLabel: "any volume outside the source set", isAuditMode: true
        )

        #expect(result.sourceOnly == 0, "Both MacPro copies are safe — MyBook has a copy")
        #expect(result.alreadySafeCount == 2)
    }

    @Test func multiDest_checkAgainstExplicitBackupSet() {
        let allRecords = [
            makeRecord(filename: "A.mov", path: "/Volumes/InternalRaid/A.mov", md5: "a", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/InternalRaid/B.mov", md5: "b", size: 200),
            makeRecord(filename: "C.mov", path: "/Volumes/InternalRaid/C.mov", md5: "c", size: 300),

            makeRecord(filename: "A.mov", path: "/Volumes/MacStudio/A.mov", md5: "a", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/MyBook3TB/B.mov", md5: "b", size: 200),
            makeRecord(filename: "C.mov", path: "/Volumes/SomeOtherDrive/C.mov", md5: "c", size: 300)
        ]
        let srcVols = ["/Volumes/InternalRaid"]
        let dstVols = ["/Volumes/MacStudio", "/Volumes/MyBook3TB"]

        let src = recordsUnder(srcVols, from: allRecords)
        let dst = recordsUnder(dstVols, from: allRecords)

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid", destPath: "",
            destLabel: "MacStudio, MyBook3TB", isAuditMode: true
        )

        #expect(result.sourceOnly == 1, "C.mov has no copy on the declared backup set")
        #expect(result.missingFiles.first?.filename == "C.mov")
        #expect(result.alreadySafeCount == 2)
    }
}
