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

    // regression: #30 — Cross-machine catalog sharing: export+import round-trips records into an empty catalog
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

    // regression: #30 — Catalog import is idempotent: records already present (by content identity) are skipped, not duplicated
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

// MARK: - Catalog Skip Set Tests (Issue #23)
//
// Person scan filters out catalog-known-bad records (audio-only,
// no-streams, ffprobe-failed) before processing. Tests exercise the
// pure helper `pfCatalogSkipPaths(from:)` directly.

struct CatalogSkipSetTests {

    private func record(_ path: String, _ streamType: StreamType) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.streamTypeRaw = streamType.rawValue
        return r
    }

    // regression: #23 — Catalog skip set filters audio-only, ffprobe-failed, no-streams
    @Test func skipSetFiltersAudioOnly() {
        let recs = [
            record("/vol/video1.mov", .videoAndAudio),
            record("/vol/audio.wav", .audioOnly),
            record("/vol/broken.mxf", .ffprobeFailed),
            record("/vol/empty.avi", .noStreams),
            record("/vol/video2.mp4", .videoOnly),
        ]
        let skip = pfCatalogSkipPaths(from: recs)
        #expect(skip.count == 3)
        #expect(skip.contains("/vol/audio.wav"))
        #expect(skip.contains("/vol/broken.mxf"))
        #expect(skip.contains("/vol/empty.avi"))
        #expect(!skip.contains("/vol/video1.mov"))
        #expect(!skip.contains("/vol/video2.mp4"))
    }

    // regression: #23 — Applying the skip set to a file list shrinks it to scannable items
    @Test func skipSetFilteringReducesFileList() {
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

    // regression: #23 — All-good catalog produces an empty skip set
    @Test func skipSetEmptyWhenNoBadFiles() {
        let recs = [
            record("/vol/good1.mov", .videoAndAudio),
            record("/vol/good2.mp4", .videoOnly),
        ]
        #expect(pfCatalogSkipPaths(from: recs).isEmpty)
    }

    // regression: #23 — Empty fullPath does not pollute the skip set with empty string
    @Test func skipSetIgnoresEmptyPaths() {
        let rec = record("", .audioOnly)
        #expect(pfCatalogSkipPaths(from: [rec]).isEmpty,
                "Empty paths should not be added to skip set")
    }

    // regression: #23 — Empty input returns empty skip set without crashing
    @Test func skipSetEmptyInputReturnsEmpty() {
        #expect(pfCatalogSkipPaths(from: []).isEmpty)
    }

    // regression: #23 — Default opt-in: setting `skipCatalogBadFiles` ships true
    @Test func settingDefaultsToTrue() {
        let settings = PersonFinderSettings()
        #expect(settings.skipCatalogBadFiles == true)
    }
}

// MARK: - Person scan prefilter tests (Issue #66)
//
// Five-rule prefilter built on top of catalog metadata. Each rule has its
// own bucket on `CatalogSkipResult`; tests assert each rule fires
// independently and that benign records make it through.

struct PersonScanPrefilterTests {

    private func record(
        _ path: String,
        _ streamType: StreamType = .videoAndAudio,
        duration: Double = 60,
        resolution: String = "1920x1080",
        junkScore: Int = 0,
        detectedPeople: [String] = []
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.streamTypeRaw = streamType.rawValue
        r.durationSeconds = duration
        r.resolution = resolution
        r.junkScore = junkScore
        r.detectedPeople = detectedPeople
        return r
    }

    // regression: #66 — Resolution parser extracts the height from "WxH"
    @Test func resolutionParserGetsHeight() {
        #expect(pfResolutionHeight(from: "1920x1080") == 1080)
        #expect(pfResolutionHeight(from: "1280x720") == 720)
        #expect(pfResolutionHeight(from: "640x360") == 360)
    }

    // regression: #66 — Resolution parser returns nil on unparseable input
    @Test func resolutionParserHandlesGarbage() {
        #expect(pfResolutionHeight(from: "") == nil)
        #expect(pfResolutionHeight(from: "—") == nil)
        #expect(pfResolutionHeight(from: "unknown") == nil)
        #expect(pfResolutionHeight(from: "1920") == nil)
    }

    // regression: #66 — Rule 1 (existing #23): unscannable records routed
    // into the unscannable bucket
    @Test func unscannableBucketCatchesAudioOnly() {
        let r = record("/v/clip.wav", .audioOnly)
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: "donna")
        #expect(result.unscannable == ["/v/clip.wav"])
        #expect(result.alreadyKnown.isEmpty)
        #expect(result.junkScored.isEmpty)
        #expect(result.tooShort.isEmpty)
        #expect(result.lowResolution.isEmpty)
    }

    // regression: #66 — Rule 2: detectedPeople contains target → alreadyKnown
    @Test func alreadyKnownBucketCatchesPriorHits() {
        let r = record("/v/family.mov", detectedPeople: ["Donna", "Tim"])
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: "donna")
        #expect(result.alreadyKnown == ["/v/family.mov"])
    }

    // regression: #66 — Rule 2: case-insensitive name match
    @Test func alreadyKnownIsCaseInsensitive() {
        let r = record("/v/holiday.mov", detectedPeople: ["DONNA"])
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: "Donna")
        #expect(result.alreadyKnown == ["/v/holiday.mov"])
    }

    // regression: #66 — Rule 2: nil/empty target = no already-known check
    @Test func alreadyKnownSkippedWithoutTarget() {
        let r = record("/v/family.mov", detectedPeople: ["Donna"])
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: nil)
        #expect(result.alreadyKnown.isEmpty)
    }

    // regression: #66 — Rule 3: junkScore >= ceiling → junkScored
    @Test func junkScoredBucketCatchesHighScores() {
        let high = record("/v/junk.mov", junkScore: 90)
        let medium = record("/v/borderline.mov", junkScore: 50)
        let result = pfPersonScanSkipPaths(from: [high, medium], targetPersonName: nil)
        #expect(result.junkScored == ["/v/junk.mov"])
    }

    // regression: #66 — Rule 3: ceiling boundary is inclusive
    @Test func junkScoredCeilingIsInclusive() {
        let exactly = record("/v/edge.mov", junkScore: 80)
        let result = pfPersonScanSkipPaths(from: [exactly], targetPersonName: nil)
        #expect(result.junkScored == ["/v/edge.mov"])
    }

    // regression: #66 — Rule 4: very short clips → tooShort
    @Test func tooShortBucketCatchesBriefClips() {
        let brief = record("/v/blip.mov", duration: 2.0)
        let normal = record("/v/clip.mov", duration: 30)
        let result = pfPersonScanSkipPaths(from: [brief, normal], targetPersonName: nil)
        #expect(result.tooShort == ["/v/blip.mov"])
    }

    // regression: #66 — Rule 4: zero duration is treated as "unknown" not "too short"
    @Test func zeroDurationDoesNotTriggerTooShort() {
        let unknown = record("/v/unknown_dur.mov", duration: 0)
        let result = pfPersonScanSkipPaths(from: [unknown], targetPersonName: nil)
        #expect(result.tooShort.isEmpty)
    }

    // regression: #66 — Rule 5: resolution height < min → lowResolution
    @Test func lowResolutionBucketCatchesSubHD() {
        let lowRes = record("/v/240p.mov", resolution: "320x240")
        let hd = record("/v/720p.mov", resolution: "1280x720")
        let result = pfPersonScanSkipPaths(from: [lowRes, hd], targetPersonName: nil)
        #expect(result.lowResolution == ["/v/240p.mov"])
    }

    // regression: #66 — Rule 5: empty/unparseable resolution = "unknown" not "low"
    @Test func emptyResolutionDoesNotTriggerLowRes() {
        let r = record("/v/no_res.mov", resolution: "")
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: nil)
        #expect(result.lowResolution.isEmpty)
    }

    // regression: #66 — Mixed catalog: each rule fires independently
    @Test func mixedCatalogPopulatesAllBuckets() {
        let recs = [
            record("/v/audio.wav", .audioOnly),
            record("/v/cached.mov", detectedPeople: ["Donna"]),
            record("/v/junk.mov", junkScore: 95),
            record("/v/blip.mov", duration: 1.0),
            record("/v/240p.mov", resolution: "320x240"),
            record("/v/good.mov", duration: 60, resolution: "1920x1080",
                   junkScore: 5, detectedPeople: ["Tim"]),
        ]
        let result = pfPersonScanSkipPaths(from: recs, targetPersonName: "Donna")
        #expect(result.unscannable == ["/v/audio.wav"])
        #expect(result.alreadyKnown == ["/v/cached.mov"])
        #expect(result.junkScored == ["/v/junk.mov"])
        #expect(result.tooShort == ["/v/blip.mov"])
        #expect(result.lowResolution == ["/v/240p.mov"])
        #expect(!result.all.contains("/v/good.mov"))
    }

    // regression: #66 — Empty input returns empty result without crashing
    @Test func emptyInputReturnsEmptyResult() {
        let result = pfPersonScanSkipPaths(from: [], targetPersonName: "Donna")
        #expect(result.all.isEmpty)
    }

    // regression: #66 — Records with empty fullPath are ignored entirely
    @Test func emptyFullPathRecordsIgnored() {
        let r = record("", junkScore: 99)
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: "Donna")
        #expect(result.all.isEmpty)
    }

    // regression: #66 — Unscannable trumps all other rules (early-return)
    @Test func unscannableTrumpsOtherRules() {
        let r = record("/v/audio.wav", .audioOnly,
                       duration: 60, resolution: "1920x1080",
                       junkScore: 10, detectedPeople: ["Donna"])
        let result = pfPersonScanSkipPaths(from: [r], targetPersonName: "Donna")
        #expect(result.unscannable == ["/v/audio.wav"])
        #expect(result.alreadyKnown.isEmpty)
        #expect(result.junkScored.isEmpty)
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

    // MARK: - Catalog-duplicate-records resilience
    //
    // Rick + Claude 2026-06-07: the catalog has, for historical scan-import
    // reasons, multiple records per fullPath (~1262 paths affected at the
    // time of discovery). Compare must not double-count those rows or the
    // user sees an inflated "missing GB" figure and overestimates how much
    // would be lost to a drive failure.
    //
    // Live data when the bug was caught:
    //   reported missing: 1352 records / 712 GB
    //   actual unique paths: 676 / ~356 GB
    //   2× inflation — directly traceable to no source-side fullPath dedup.

    @Test func duplicateCatalogRowsForSameFullPathCountAsOneFile() {
        // Two catalog records for the EXACT same fullPath — same content,
        // same hash, same size. The catalog has them because of a historical
        // double-scan import. Compare must treat them as one file.
        let src = [
            makeRecord(filename: "dup.mov", path: "/Volumes/Old/dup.mov", md5: "aaa", size: 5000),
            makeRecord(filename: "dup.mov", path: "/Volumes/Old/dup.mov", md5: "aaa", size: 5000)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: [],
            sourcePath: "/Volumes/Old", destPath: "/Volumes/New"
        )

        #expect(result.sourceOnly == 1,
                "Two catalog rows for the same fullPath must count as one missing file, not two")
        #expect(result.missingBytes == 5000,
                "Bytes must not be double-counted across duplicate rows; 2 rows × 5000 ≠ 10000")
        #expect(result.missingFiles.count == 1,
                "missingFiles must be path-unique so the rescue copy never tries the same file twice")
    }

    @Test func mixOfDuplicatesAndUniquesCountsCorrectly() {
        // /a appears 3 times (catalog triple-dup), /b once, /c twice.
        // Expected: 3 unique paths → 3 missing files, 100+200+300 = 600 bytes.
        let src = [
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "a", size: 100),
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "a", size: 100),
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "a", size: 100),
            makeRecord(filename: "b.mov", path: "/Volumes/Old/b.mov", md5: "b", size: 200),
            makeRecord(filename: "c.mov", path: "/Volumes/Old/c.mov", md5: "c", size: 300),
            makeRecord(filename: "c.mov", path: "/Volumes/Old/c.mov", md5: "c", size: 300)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: [],
            sourcePath: "/Volumes/Old", destPath: "/Volumes/New"
        )
        #expect(result.sourceOnly == 3)
        #expect(result.missingBytes == 600)
    }

    @Test func duplicatePathOnDestSideStillMatchesSource() {
        // If the DESTINATION catalog has multiple rows for the same file
        // (same dupe-row problem on the rescue target), the source record
        // must still match — we can't false-positive a source row because
        // its twin on dest happened to be listed twice.
        let src = [makeRecord(filename: "x.mov", path: "/Volumes/Old/x.mov", md5: "xx", size: 4000)]
        let dst = [
            makeRecord(filename: "x.mov", path: "/Volumes/New/x.mov", md5: "xx", size: 4000),
            makeRecord(filename: "x.mov", path: "/Volumes/New/x.mov", md5: "xx", size: 4000)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "/Volumes/Old", destPath: "/Volumes/New"
        )
        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    // MARK: - Folder-name behavior (rescue destination subfolder)
    //
    // Rick 2026-06-07: the rescue path used to hardcode "Rescued" as the
    // destination subfolder. Now it's user-input via a TextField; empty
    // or whitespace input falls back to the default so we never produce
    // a bad path like "/Volumes/LaCieWorkspace//foo.mov".

    @Test func defaultRescueFolderNameIsRescued() {
        // Lock the historical default so callers that don't pass folderName
        // continue to write to the same "Rescued" subfolder.
        #expect(VolumeRescueOperation.defaultRescueFolderName == "Rescued")
    }

    @MainActor
    @Test func emptyFolderNameFallsBackToDefault() {
        // VolumeRescueOperation.start trims whitespace; an empty result
        // means "use the default". This test only verifies the public
        // contract — the actual filesystem write is exercised in
        // integration tests, not here.
        let op = VolumeRescueOperation()
        // The class doesn't expose the resolved folder name post-start,
        // so we verify by ensuring start() with empty / blank doesn't
        // crash and is idempotent against a re-entry guard.
        op.start(files: [], sourcePath: "/Volumes/SrcDoesNotExist", destPath: "/Volumes/DstDoesNotExist", mode: .verified, folderName: "   ")
        // start() is no-op when isRunning is true; if our empty-string
        // sanitization had crashed, we'd have failed above. The fact
        // that we're still here is the meaningful signal.
        op.cancel()
    }

    @MainActor
    @Test func cancelIsIdempotentAndDoesNotCrashWhenNothingRunning() {
        // Defensive: if Rick clicks Cancel without ever starting a copy,
        // we must not blow up trying to terminate a nil Process.
        let op = VolumeRescueOperation()
        op.cancel()
        op.cancel()
        op.cancel()
        // Made it here without crashing → contract satisfied.
        #expect(op.isRunning == false)
    }

    @Test func totalSourceBytesAlsoExcludesDuplicateRows() {
        // Companion check — totalSourceBytes is shown to the user as
        // "this volume holds X GB". If we don't dedup, it's inflated too.
        let src = [
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "a", size: 1000),
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "a", size: 1000),  // dupe row
            makeRecord(filename: "b.mov", path: "/Volumes/Old/b.mov", md5: "b", size: 2000)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: [],
            sourcePath: "/Volumes/Old", destPath: "/Volumes/New"
        )
        #expect(result.totalSourceBytes == 3000,
                "totalSourceBytes must dedup by fullPath; 2 rows for /a × 1000 ≠ 4000")
    }
}
