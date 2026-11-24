import Testing
import Foundation
@testable import VideoScan

/// Mount notifications are system-wide: Rick's running app heard every disk image the testbed
/// attached and logged "Volume mounted: diskfull-mnt-…" into his catalog.log (11/18–11/23).
/// A drive a person attaches appears under /Volumes; an image a tool or test attaches at its own
/// mount point (hdiutil -mountpoint <folder>) does not, and gets no line.
@Suite("Volume mount log — only drives under /Volumes")
struct VolumeMountLogTests {

    @Test func aDriveUnderVolumesIsLogged() {
        let line = VolumeMountLog.line(for: URL(fileURLWithPath: "/Volumes/Grandma Tapes"))
        #expect(line == "Volume mounted: Grandma Tapes (not auto-added — use Add Scan Target to catalog)")
    }

    @Test func theAppsOwnRAMDiskIsStillLogged() {
        #expect(VolumeMountLog.line(for: URL(fileURLWithPath: "/Volumes/VideoScan_Temp")) != nil)
    }

    @Test(arguments: [
        "/private/var/folders/93/x/T/VideoScanCoreTests/diskfull-mnt-EFB2F1C4",   // CatalogDiskFullTests
        "/Users/rickb/Library/Caches/videoscan-runall/runs/r1/home/tmp/VideoScanTests",
        "/private/tmp/combine/mnt",                                                // CombineOutputPublishTests
        "/Volumes/X10/scratch/mnt",                                                // a mount point INSIDE a drive
        "/Volumes",
    ])
    func anImageMountedAtItsOwnFolderIsNotLogged(path: String) {
        #expect(VolumeMountLog.line(for: URL(fileURLWithPath: path)) == nil, "\(path)")
    }

    @Test func dotSegmentsCannotDisguiseAFolderAsADrive() {
        #expect(VolumeMountLog.line(for: URL(fileURLWithPath: "/Volumes/../tmp/diskfull-mnt-1")) == nil)
    }
}
