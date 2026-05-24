// VolumeReachabilityMountStateTests.swift
// Pins the mount-state-vs-file-existence semantics of
// `VolumeReachability.isReachable(path:)` after the italics-flicker fix.
//
// Before the fix, isReachable() stat'ed the SPECIFIC FILE path and cached
// the result PER VOLUME — so a Verify/Scan pass walking thousands of files
// kept overwriting the cached volume bit with whichever file happened to
// be last. That flipped catalog row italics ~rapidly during scans.
//
// These tests use /tmp (always mounted, /tmp is on the boot volume so its
// "volume root" is /private — see VolumeReachability.cacheKey) and a
// known-mounted `/Volumes/X` if one is available.

import Testing
import Foundation
@testable import VideoScan

@Suite("VolumeReachability Mount-State Semantics")
struct VolumeReachabilityMountStateTests {

    /// Sanity: cache invalidation between tests so independent runs don't
    /// inherit stale entries from earlier suites.
    init() {
        VolumeReachability.invalidateCache()
    }

    // MARK: - /Volumes paths: cached value reflects the VOLUME, not the file

    @Test func volumesPathReturnsTrueForMissingFileOnMountedVolume() {
        // Pick a known-mounted volume. Boot volume mount exists at the root
        // ("/"), but /Volumes/<X> volumes only exist if the test host has
        // external drives mounted. Use any existing /Volumes entry; skip
        // gracefully if none mounted (CI VMs typically have none).
        guard let volRoot = anyMountedVolumesRoot() else {
            // No external volumes mounted — skip rather than fake the test.
            return
        }

        let fakeFile = "\(volRoot)/__nonexistent_\(UUID().uuidString).bin"
        let result = VolumeReachability.isReachable(path: fakeFile)
        #expect(result == true,
                "Mount is present, so isReachable should return true even when the specific file does not exist (volume-bit, not file-bit). volRoot=\(volRoot)")
    }

    @Test func volumesPathReturnsTrueForExistingFileOnMountedVolume() {
        guard let volRoot = anyMountedVolumesRoot() else { return }

        // The root itself always exists when the volume is mounted; this
        // proves we don't break the obvious "file present" case.
        let result = VolumeReachability.isReachable(path: volRoot)
        #expect(result == true)
    }

    @Test func unmountedVolumeReturnsFalse() {
        // Synthesise an obviously-unmounted volume path.
        let bogus = "/Volumes/__VideoScanTest_DefinitelyNotMounted_\(UUID().uuidString)"
        let result = VolumeReachability.isReachable(path: bogus)
        #expect(result == false)
    }

    @Test func unmountedVolumeWithSubpathReturnsFalse() {
        let bogus = "/Volumes/__VideoScanTest_DefinitelyNotMounted_\(UUID().uuidString)/sub/dir/file.mov"
        let result = VolumeReachability.isReachable(path: bogus)
        #expect(result == false)
    }

    @Test func bugReproSubpathDoesNotPoisonVolumeBit() {
        // This is the actual bug regression: ask about a file that is NOT
        // present on a volume that IS mounted, then ask about the volume
        // root. Pre-fix, the first call's "missing file" answer would be
        // cached under the volume key, poisoning the volume-root question.
        guard let volRoot = anyMountedVolumesRoot() else { return }

        VolumeReachability.invalidateCache()
        let fakeFile = "\(volRoot)/__nonexistent_\(UUID().uuidString).bin"

        let firstAnswer  = VolumeReachability.isReachable(path: fakeFile)
        let secondAnswer = VolumeReachability.isReachable(path: volRoot)

        #expect(firstAnswer == true,
                "Missing-file query should still return true (mount is what matters)")
        #expect(secondAnswer == true,
                "Volume root must still be reachable after a missing-file query — this was the original flicker bug")
    }

    // MARK: - Non-/Volumes paths: fall back to file-existence

    @Test func nonVolumesExistingPathReturnsTrue() {
        // /tmp is symlinked to /private/tmp and is always present on macOS.
        let result = VolumeReachability.isReachable(path: "/tmp")
        #expect(result == true)
    }

    @Test func nonVolumesMissingPathReturnsFalse() {
        let result = VolumeReachability.isReachable(path: "/tmp/__VideoScanTest_DoesNotExist_\(UUID().uuidString)")
        #expect(result == false)
    }

    @Test func emptyPathReturnsFalse() {
        #expect(VolumeReachability.isReachable(path: "") == false)
    }

    // MARK: - TTL caching behaviour

    @Test func repeatedCallsWithinTTLAreCached() {
        // We can't easily observe "no syscall happened" from a unit test,
        // but we can observe stability: two adjacent calls return the same
        // answer even if a phantom file appears/disappears between them.
        guard let volRoot = anyMountedVolumesRoot() else { return }
        VolumeReachability.invalidateCache()

        let first  = VolumeReachability.isReachable(path: volRoot)
        let second = VolumeReachability.isReachable(path: "\(volRoot)/__ghost_\(UUID().uuidString)")
        let third  = VolumeReachability.isReachable(path: volRoot)

        #expect(first == true)
        #expect(second == true)
        #expect(third == true)
        #expect(first == second)
        #expect(second == third)
    }

    @Test func invalidateCacheForcesRefresh() {
        guard let volRoot = anyMountedVolumesRoot() else { return }
        _ = VolumeReachability.isReachable(path: volRoot)
        VolumeReachability.invalidateCache()
        // After invalidation, the next call must produce a fresh answer.
        // We assert it's still true (volume is still mounted).
        let after = VolumeReachability.isReachable(path: volRoot)
        #expect(after == true)
    }

    // MARK: - Helpers

    /// Find any currently-mounted `/Volumes/<X>` directory. Returns nil if
    /// the test host has no external/network volumes (typical CI).
    private func anyMountedVolumesRoot() -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in contents {
            // Skip the boot volume symlink ("Macintosh HD" → /) — that
            // resolves to / and is a different code path.
            let path = "/Volumes/\(name)"
            let resolved = (path as NSString).resolvingSymlinksInPath
            if resolved == "/" { continue }
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
