// CatalogReachableDefaultSensorTests.swift
// Regression sensors for the "reachable-only catalog baseline" change
// (branch fix/catalog-reachable-default, 2026-07-20).
//
// Three concerns, per the CLAUDE.md 5-dimension checklist:
//   1. ESCAPED-BUG sensor — a /Volumes/* path that exists via fileExists()
//      but is NOT in the kernel mount table (a leftover stub dir or a
//      symlink like `/Volumes/M4drive -> /`) must resolve UNREACHABLE.
//      This is the bug the probe-correctness fix closes: fileExists() would
//      resurrect a disconnected drive as "connected" and defeat the filter.
//   2. FILTER DEFAULT — CatalogContent.computeFiltered() excludes records on
//      unreachable paths when showDisconnectedMedia == false, includes them
//      when true. Exercises the real View method so the flag WIRING is pinned,
//      not a re-implementation.
//   3. CONCURRENCY smoke — currentMountedRoots()/isReachable() called from many
//      threads at once never crashes and always reports "/" mounted. Sensor for
//      the getmntinfo() serialization lock (getmntinfo(3) returns a non-reentrant
//      libc static buffer; the probe queue is concurrent).
//
// Swift Testing notes for a C++ reader:
//   - `#expect(x == y)` ≈ EXPECT_EQ; it records a failure but keeps going.
//   - `@Test`/@Suite replace XCTest's method-name-prefix discovery — an
//     annotation instead of a naming convention (like GTest's TEST() macro,
//     but attached to a plain func).
//   - There is no shared setUp/tearDown fixture object; a `struct`'s `init()`
//     runs fresh per test instance, which is how we reset the shared cache.

import Testing
import Foundation
import SwiftUI
import os.lock
@testable import VideoScan

// MARK: - 1. Escaped-bug sensors (probe correctness)

@Suite("Reachable-Only: probe correctness (escaped bug)")
struct ReachableOnlyProbeCorrectnessTests {

    init() { VolumeReachability.invalidateCache() }

    /// Query until the background probe's answer is visible, converging on
    /// false. Mirrors VolumeReachabilityMountStateTests.settledReachability —
    /// a parallel suite may invalidate the shared cache between our probe
    /// landing and our re-query, re-arming the optimistic default.
    private func settled(_ path: String, attempts: Int = 50) -> Bool {
        var result = VolumeReachability.isReachable(path: path)
        for _ in 0..<attempts {
            VolumeReachability.awaitPendingProbesForTesting()
            result = VolumeReachability.isReachable(path: path)
            if result == false { break }
        }
        return result
    }

    /// Pure contract: an unknown /Volumes key with an EMPTY mount table is
    /// unreachable. No disk, no cache — just the honest default. This is the
    /// exact predicate the miss-default and the probe both consult.
    @Test func ghostVolumeDefaultIsFalse() {
        let ghost = "/Volumes/Ghost_\(UUID().uuidString)"
        #expect(VolumeReachability.defaultReachability(forKey: ghost, mountedRoots: []) == false)
        // Even with the boot root present in the table, an unrelated /Volumes
        // key is still unreachable (contains-membership, not prefix).
        #expect(VolumeReachability.defaultReachability(forKey: ghost, mountedRoots: ["/"]) == false)
    }

    /// THE escaped bug. If the host has any /Volumes entry that exists on disk
    /// (fileExists == true) but is NOT a real mount (absent from getmntinfo) —
    /// e.g. the live `/Volumes/M4drive -> /` symlink fixture — isReachable must
    /// settle to false. Under the old fileExists()-based probe this returned
    /// true and a disconnected drive rendered as connected. Portable: skips
    /// cleanly when no such stub/symlink is present.
    @Test func fileExistsStubOrSymlinkResolvesUnreachable() {
        let mounted = VolumeReachability.currentMountedRoots()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        var probed = false
        for name in names {
            let key = "/Volumes/\(name)"
            // The bug precondition: on disk per fileExists, but not a mount.
            guard FileManager.default.fileExists(atPath: key),
                  !mounted.contains(key) else { continue }
            probed = true
            #expect(settled("\(key)/some_media_\(UUID().uuidString).mov") == false,
                    "\(key) exists via fileExists but is not in the mount table — must be UNREACHABLE (this is the resurrected-drive escaped bug)")
        }
        if !probed {
            // No stub/symlink fixture on this host — nothing to assert, and
            // faking a mount is out of scope. Recorded as a skip via a known
            // expectation so the run log shows the sensor was portable.
            #expect(Bool(true), "No /Volumes stub/symlink present; escaped-bug sensor skipped on this host")
        }
    }

    /// Positive counterweight so the escaped-bug sensor can't pass by always
    /// answering false: a /Volumes root that IS in the mount table reads
    /// reachable. Skips when the host has no external/network volumes.
    @Test func genuinelyMountedVolumeIsReachable() {
        let mounted = VolumeReachability.currentMountedRoots()
        guard let realMount = mounted.first(where: { $0.hasPrefix("/Volumes/") }) else {
            #expect(Bool(true), "No /Volumes mount present; positive-path check skipped on this host")
            return
        }
        #expect(VolumeReachability.isReachable(path: "\(realMount)/anything.mov") == true,
                "\(realMount) is in the mount table — must be reachable")
    }
}

// MARK: - 2. Filter-default sensor (real computeFiltered wiring)

@Suite("Reachable-Only: computeFiltered default")
struct ReachableOnlyFilterDefaultTests {

    init() { VolumeReachability.invalidateCache() }

    /// Build a videoBearing, non-purged, non-set-aside record at `path` so it
    /// survives every upstream filter and the only thing that can drop it is
    /// the reachable-only baseline.
    private func record(at path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    /// Construct the real CatalogContent and call its computeFiltered().
    /// Empty search + empty filterByIDs/filterTargetPaths + no pairs/view
    /// filters means the method never touches the @EnvironmentObject model —
    /// so the constant bindings and unresolved environment are safe.
    private func computeFiltered(records: [VideoRecord], showDisconnectedMedia: Bool) -> [VideoRecord] {
        let view = CatalogContent(
            records: records,
            selectedIDs: .constant([]),
            sortOrder: .constant([]),
            searchText: "",
            searchHitCount: .constant(0),
            filterTargetPaths: [],
            showPairsOnly: false,
            viewFilters: [],
            showDisconnectedMedia: showDisconnectedMedia,
            showRemoved: false,
            previewImage: nil,
            previewFilename: "",
            previewOfflineVolumeName: nil,
            showInspector: .constant(false),
            onSort: { _ in },
            onSelect: { _ in },
            onClearPreview: {}
        )
        return view.computeFiltered()
    }

    @Test func defaultHidesUnreachableIncludesReachable() throws {
        // Reachable: a REAL temp file (non-/Volumes → optimistic-true default
        // AND a truthful background probe, so it can never flip out).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reachable_\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Unreachable: a fresh /Volumes key — honestly false on first query,
        // no probe wait, no disk touch.
        let ghostPath = "/Volumes/DefinitelyNotMounted_\(UUID().uuidString)/x.mov"

        let reachable = record(at: tmp.path)
        let unreachable = record(at: ghostPath)

        let filtered = computeFiltered(records: [reachable, unreachable],
                                       showDisconnectedMedia: false)
        let ids = Set(filtered.map { $0.id })
        #expect(ids.contains(reachable.id),
                "reachable temp-file record must survive the default reachable-only baseline")
        #expect(!ids.contains(unreachable.id),
                "record on an unmounted /Volumes path must be hidden by default (showDisconnectedMedia == false)")
    }

    @Test func optOutIncludesUnreachable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reachable_\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ghostPath = "/Volumes/DefinitelyNotMounted_\(UUID().uuidString)/x.mov"

        let reachable = record(at: tmp.path)
        let unreachable = record(at: ghostPath)

        let filtered = computeFiltered(records: [reachable, unreachable],
                                       showDisconnectedMedia: true)
        let ids = Set(filtered.map { $0.id })
        #expect(ids.contains(reachable.id))
        #expect(ids.contains(unreachable.id),
                "Show-disconnected-media opt-out must include records on unmounted volumes")
    }
}

// MARK: - 3. Concurrency smoke (getmntinfo serialization)

@Suite("Reachable-Only: getmntinfo concurrency")
struct ReachableOnlyConcurrencyTests {

    /// Hammer currentMountedRoots() from many threads at once. getmntinfo(3)
    /// hands back a pointer into a single non-reentrant libc static buffer it
    /// may realloc in place; without the getmntinfoLock these calls race on
    /// that buffer (torn reads / use-after-free under a concurrent realloc).
    /// The sensor: no crash, and "/" is ALWAYS present in every snapshot.
    @Test func concurrentMountTableReadsAreSafe() {
        let iterations = 500
        let allHaveRoot = OSAllocatedUnfairLock(initialState: true)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let roots = VolumeReachability.currentMountedRoots()
            if !roots.contains("/") {
                allHaveRoot.withLock { $0 = false }
            }
        }
        #expect(allHaveRoot.withLock { $0 } == true,
                "every concurrent getmntinfo snapshot must contain \"/\" — a miss implies a torn/racing read")
    }

    /// Same pressure through the public isReachable() entry point, mixing
    /// /Volumes and non-/Volumes keys (both default paths and the probe
    /// queue). Sensor is liveness: it returns without crashing.
    @Test func concurrentIsReachableIsSafe() {
        let paths = [
            "/tmp",
            "/Volumes/RaceGhost_\(UUID().uuidString)/a.mov",
            "/Volumes/RaceGhost_\(UUID().uuidString)/b.mov",
            "/private/tmp"
        ]
        DispatchQueue.concurrentPerform(iterations: 800) { i in
            _ = VolumeReachability.isReachable(path: paths[i % paths.count])
        }
        VolumeReachability.awaitPendingProbesForTesting()
        // Reaching here without a crash is the assertion; pin "/" too.
        #expect(VolumeReachability.currentMountedRoots().contains("/"))
    }
}
