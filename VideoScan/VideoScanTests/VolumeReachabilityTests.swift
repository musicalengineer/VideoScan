import Testing
@testable import VideoScan

@Suite("VolumeReachability Extended")
struct VolumeReachabilityExtendedTests {

    // MARK: - volumeName(forPath:)

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
        #expect(name == "")
    }

    // MARK: - cacheKey(forPath:) — via isReachable behavior

    @Test func volumesMountShareCacheKey() {
        // Two files on same /Volumes mount should produce the same volume name
        let a = VolumeReachability.volumeName(forPath: "/Volumes/Seagate2TB/a.mov")
        let b = VolumeReachability.volumeName(forPath: "/Volumes/Seagate2TB/sub/b.mov")
        #expect(a == b)
        #expect(a == "Seagate2TB")
    }

    // MARK: - isNetworkVolume / parseRemoteServer

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
        #expect(server == "")
    }
}
