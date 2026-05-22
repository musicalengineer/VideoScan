import Testing
import Foundation
@testable import VideoScan

@Suite("VolumeReachability Extended")
struct VolumeReachabilityExtendedTests {

    // MARK: - volumeName(forPath:) path-based fallback

    @Test func externalVolumePath() {
        let name = VolumeReachability.volumeName(forPath: "/Volumes/MyBook3Terabytes/Movies/clip.mov")
        #expect(name == "MyBook3Terabytes")
    }

    @Test func externalVolumeDeepPath() {
        let name = VolumeReachability.volumeName(forPath: "/Volumes/LaCieWorkspace/Family/2024/summer.mov")
        #expect(name == "LaCieWorkspace")
    }

    @Test func userHomePath() {
        let name = VolumeReachability.volumeName(forPath: "/Users/rickb/Movies/Timmy-1992-part2.m4v")
        #expect(name == "rickb")
    }

    @Test func userHomeDeepPath() {
        let name = VolumeReachability.volumeName(forPath: "/Users/rickb/Documents/Archive/old.avi")
        #expect(name == "rickb")
    }

    @Test func otherSystemPath() {
        let name = VolumeReachability.volumeName(forPath: "/private/tmp/scratch.mov")
        #expect(name == "private")
    }

    @Test func optPath() {
        let name = VolumeReachability.volumeName(forPath: "/opt/media/test.mp4")
        #expect(name == "opt")
    }

    @Test func rootLevelFile() {
        let name = VolumeReachability.volumeName(forPath: "/file.mov")
        #expect(name == "/")
    }

    @Test func emptyPath() {
        let name = VolumeReachability.volumeName(forPath: "")
        #expect(name.isEmpty)
    }

    @Test func volumesMountShareCacheKey() {
        let a = VolumeReachability.volumeName(forPath: "/Volumes/Seagate2TB/a.mov")
        let b = VolumeReachability.volumeName(forPath: "/Volumes/Seagate2TB/sub/b.mov")
        #expect(a == b)
        #expect(a == "Seagate2TB")
    }

    // MARK: - parseRemoteServer

    @Test func smbServerParsing() {
        let server = VolumeReachability.parseRemoteServer(fsType: "smbfs", mntFromName: "//rickb@nas.local/share")
        #expect(server == "nas.local")
    }

    @Test func smbNoUser() {
        let server = VolumeReachability.parseRemoteServer(fsType: "smbfs", mntFromName: "//fileserver/videos")
        #expect(server == "fileserver")
    }

    @Test func nfsServerParsing() {
        let server = VolumeReachability.parseRemoteServer(fsType: "nfs", mntFromName: "nfshost:/export/media")
        #expect(server == "nfshost")
    }

    @Test func afpWithScheme() {
        let server = VolumeReachability.parseRemoteServer(fsType: "afpfs", mntFromName: "afp://user@timecapsule/Data")
        #expect(server == "timecapsule")
    }

    @Test func webdavParsing() {
        let server = VolumeReachability.parseRemoteServer(fsType: "webdav", mntFromName: "https://cloud.example.com/dav")
        #expect(server == "cloud.example.com")
    }

    @Test func localFSReturnsEmptyServer() {
        let server = VolumeReachability.parseRemoteServer(fsType: "apfs", mntFromName: "/dev/disk1s1")
        #expect(server.isEmpty)
    }
}

// MARK: - VideoRecord.volumeName with ScanContext

@Suite("VideoRecord Volume Name")
struct VideoRecordVolumeNameTests {

    @Test func storedVolumeNameTakesPrecedence() {
        let rec = VideoRecord()
        rec.fullPath = "/Users/rickb/Movies/Timmy-1992-part2.m4v"
        rec.scanContext.volumeName = "Macintosh HD"
        #expect(rec.volumeName == "Macintosh HD")
    }

    @Test func fallsBackToPathParsingWhenNoStoredName() {
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/LaCieWorkspace/clip.mov"
        #expect(rec.scanContext.volumeName.isEmpty)
        #expect(rec.volumeName == "LaCieWorkspace")
    }

    @Test func fallsBackForUserPathWithoutStoredName() {
        let rec = VideoRecord()
        rec.fullPath = "/Users/rickb/Movies/Timmy-1992-part2.m4v"
        #expect(rec.volumeName == "rickb")
    }

    @Test func storedNameWorksForExternalVolume() {
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/MyBook3Terabytes/family/clip.mov"
        rec.scanContext.volumeName = "MyBook3Terabytes"
        #expect(rec.volumeName == "MyBook3Terabytes")
    }

    @Test func storedNameOverridesPathParsing() {
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/disk3s1/media/clip.mov"
        rec.scanContext.volumeName = "Family Archive"
        #expect(rec.volumeName == "Family Archive")
    }
}

// MARK: - ScanContext capture

@Suite("ScanContext Capture")
struct ScanContextCaptureTests {

    @Test func capturePopulatesVolumeName() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanctx_test_\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ctx = ScanContext.capture(for: tmp)
        #expect(!ctx.volumeName.isEmpty)
        #expect(!ctx.scanHost.isEmpty)
    }

    @Test func captureVolumeNameMatchesResourceValues() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanctx_cmp_\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expected = (try? tmp.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
        let ctx = ScanContext.capture(for: tmp)
        #expect(ctx.volumeName == expected)
    }

    @Test func roundTripThroughJSON() throws {
        var ctx = ScanContext()
        ctx.scanHost = "TestMac"
        ctx.volumeName = "Macintosh HD"
        ctx.volumeMountType = "apfs"

        let encoder = JSONEncoder()
        let data = try encoder.encode(ctx)
        let decoded = try JSONDecoder().decode(ScanContext.self, from: data)

        #expect(decoded.volumeName == "Macintosh HD")
        #expect(decoded.scanHost == "TestMac")
        #expect(decoded.volumeMountType == "apfs")
    }

    @Test func legacyJSONWithoutVolumeNameDecodesCleanly() throws {
        let json = """
        {"scanHost":"OldMac","volumeUUID":"ABC-123","volumeMountType":"apfs"}
        """
        let decoded = try JSONDecoder().decode(ScanContext.self, from: Data(json.utf8))
        #expect(decoded.volumeName.isEmpty)
        #expect(decoded.scanHost == "OldMac")
    }
}
