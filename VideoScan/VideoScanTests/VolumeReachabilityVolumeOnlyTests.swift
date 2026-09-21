// VolumeReachabilityVolumeOnlyTests.swift
// 2026-09-21 — Rick: "'M4drive' was said 'not connected' in some cases
// which is weird." The boot volume is named M4drive. `isReachable(path:)`
// answers "does this FILE exist" for internal paths, so a catalog row
// whose file was moved or deleted outside the app read as "drive not
// connected". `isVolumeReachable(path:)` answers only the VOLUME question:
// an internal path with a missing file is ONLINE (the boot disk is here);
// an unmounted /Volumes/X is OFFLINE; the per-file answer is a separate
// stat the caller takes off-main.
//
// Dimensions: LOGIC (the pure mount-root key) · ISOLATION (temp dir,
// fresh UUIDs, never a real external volume) · SENSOR (`isReachable`'s
// missing-internal-file answer is unchanged — the catalog table still
// relies on it).

import Foundation
import Testing
@testable import VideoScan

@Suite("VolumeReachability — volume-only reachability (missing file ≠ offline)")
struct VolumeReachabilityVolumeOnlyTests {

    init() { VolumeReachability.invalidateCache() }

    // MARK: The pure key

    @Test("the mount-root key: /Volumes/X for external paths; the longest mounted whole-component prefix otherwise, '/' at minimum")
    func mountRootKey() {
        let roots: Set<String> = ["/", "/Volumes/LaCie", "/System/Volumes/Data", "/private/tmp/ram"]
        #expect(VolumeReachability.volumeRootKey(forPath: "/Volumes/LaCie/Family/a.mov", mountedRoots: roots) == "/Volumes/LaCie")
        #expect(VolumeReachability.volumeRootKey(forPath: "/Volumes/NotMounted/a.mov", mountedRoots: roots) == "/Volumes/NotMounted",
                "an external path keys by its /Volumes root whether or not it is mounted — the cache answers")
        #expect(VolumeReachability.volumeRootKey(forPath: "/Users/rickb/Movies/gone.mov", mountedRoots: roots) == "/")
        #expect(VolumeReachability.volumeRootKey(forPath: "/System/Volumes/Data/Users/rickb/a.mov", mountedRoots: roots) == "/System/Volumes/Data")
        #expect(VolumeReachability.volumeRootKey(forPath: "/System/Volumes/Data", mountedRoots: roots) == "/System/Volumes/Data")
        #expect(VolumeReachability.volumeRootKey(forPath: "/private/tmp/ramdisk/a.mov", mountedRoots: roots) == "/",
                "a mount root is a whole-component prefix: /private/tmp/ram is not a prefix of /private/tmp/ramdisk")
        #expect(VolumeReachability.volumeRootKey(forPath: "/private/tmp/ram/a.mov", mountedRoots: roots) == "/private/tmp/ram")
        #expect(VolumeReachability.volumeRootKey(forPath: "/anything", mountedRoots: []) == "/")
    }

    // MARK: The bug: a missing internal file is ONLINE

    @Test("an internal path whose file does not exist: the volume is reachable; the file-level answer (isReachable) still settles false — two facts")
    func missingInternalFileIsOnlineButNotThere() {
        let gone = NSTemporaryDirectory() + "__VideoScanTest_MissingInternal_\(UUID().uuidString).mov"
        #expect(!FileManager.default.fileExists(atPath: gone))
        #expect(VolumeReachability.isVolumeReachable(path: gone) == true,
                "the boot disk is here — a missing file must never read as 'drive not connected'")
        // SENSOR: the per-file API is unchanged (the catalog table relies on it).
        var fileLevel = VolumeReachability.isReachable(path: gone)
        for _ in 0..<50 {
            VolumeReachability.awaitPendingProbesForTesting()
            fileLevel = VolumeReachability.isReachable(path: gone)
            if fileLevel == false { break }
        }
        #expect(fileLevel == false, "isReachable still answers the FILE question for internal paths")
        // And the volume answer is stable across the file probe landing.
        #expect(VolumeReachability.isVolumeReachable(path: gone) == true)
    }

    @Test("an existing internal path is reachable both ways")
    func existingInternalPath() {
        #expect(VolumeReachability.isVolumeReachable(path: NSTemporaryDirectory()) == true)
        #expect(VolumeReachability.isVolumeReachable(path: "/") == true)
        #expect(VolumeReachability.isReachable(path: NSTemporaryDirectory()) == true)
    }

    @Test("an unmounted /Volumes/X is OFFLINE — the volume question is honest from the mount table on the first query")
    func unmountedExternalVolumeIsOffline() {
        let bogus = "/Volumes/__VideoScanTest_NotMounted_\(UUID().uuidString)/Family/a.mov"
        #expect(VolumeReachability.isVolumeReachable(path: bogus) == false)
        #expect(VolumeReachability.isReachable(path: bogus) == false, "same answer as the per-file API for an unmounted volume")
    }

    @Test("empty path is never reachable")
    func emptyPath() {
        #expect(VolumeReachability.isVolumeReachable(path: "") == false)
    }
}
