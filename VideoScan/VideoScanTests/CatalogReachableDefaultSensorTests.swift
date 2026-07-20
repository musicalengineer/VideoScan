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
import AppKit
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

// MARK: - 4. Search-hit badge honors the reachable-only baseline
//
// The 2026-07-20 change (CatalogHelpers.computeFiltered, ~line 358): the
// toolbar's search-hit badge (`searchHitCount`) now counts only REACHABLE
// matches in the default connected-only view, and ALL matches when the
// "Show disconnected media" opt-out is on (the prior #123 semantics):
//
//     searchHitCount = showDisconnectedMedia
//         ? out.count
//         : out.filter { VolumeReachability.isReachable(path: $0.fullPath) }.count
//
// This suite pins that split by exercising the REAL wiring end-to-end. The
// search path of computeFiltered reads `model.searchIndex`, so the method
// can't be called on a bare, unseeded @EnvironmentObject view (that traps).
// Instead we mount the real CatalogContent offscreen with a live model in
// the environment; its `.onAppear { tableData = computeFiltered() }` fires
// the production badge write, which we read back through a binding-backed
// box. Same mount-and-pump technique as DashboardSubscriptionHotPathTests.
//
// C++ analogy: `searchHitCount: .constant(...)` vs a box-backed Binding is
// like passing a value vs a reference to an out-parameter — we need the
// reference so the view's write is observable after the call, the way you'd
// pass `int& out` to read back a callee's result.
//
// @MainActor: NSHostingView / NSWindow and the model are main-thread only.
@MainActor
@Suite("Reachable-Only: search-hit badge")
struct ReachableOnlyBadgeTests {

    init() { VolumeReachability.invalidateCache() }

    /// Reference cell the view's `searchHitCount` binding writes into.
    /// Seeded to -1 (an impossible badge value) so "onAppear never fired /
    /// nothing was written" fails loudly instead of masquerading as a real
    /// count. Not a class in the mounted view — just a captured box.
    @MainActor final class BadgeBox { var value = -1 }

    /// videoBearing, non-purged, non-set-aside record — survives every
    /// upstream filter so only the reachable-only badge split is under test.
    private func record(at path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    /// Mount the real CatalogContent offscreen with a live model, let its
    /// onAppear run the production computeFiltered(), and return the badge
    /// it published. Retains the window through the read.
    private func measuredBadge(records: [VideoRecord],
                               searchText: String,
                               showDisconnectedMedia: Bool) -> Int {
        let model = VideoScanModel()
        model.records = records
        // The search fast path resolves candidate fullPaths from the inverted
        // index, so the haystacks must exist for BOTH the reachable and the
        // ghost records — rebuild over exactly this set.
        model.searchIndex.rebuild(records: records)

        let box = BadgeBox()
        let view = CatalogContent(
            records: records,
            selectedIDs: .constant([]),
            sortOrder: .constant([]),
            searchText: searchText,
            searchHitCount: Binding(get: { box.value }, set: { box.value = $0 }),
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
        .environmentObject(model)
        .environmentObject(CaptionOrchestrator())
        .environmentObject(MediaFileOperationsCenter())

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderOut(nil)               // retained but offscreen
        hosting.layoutSubtreeIfNeeded()

        // Pump the main runloop until onAppear fires computeFiltered and
        // writes the badge (box leaves its -1 sentinel), with a hard cap so a
        // wiring failure can't hang the suite. The reachability answers here
        // are synchronous: non-/Volumes temp files default reachable-true and
        // a fresh /Volumes key defaults reachable-false with no probe wait, so
        // the badge is deterministic on the first write.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && box.value < 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = window   // keep alive through the read
        return box.value
    }

    /// Build a corpus with a known reachable/unreachable match split plus a
    /// non-matching decoy on each side (so the badge is a real search count,
    /// not a raw record count). Returns the records and a cleanup closure for
    /// the real temp files backing the reachable rows.
    private func makeCorpus(reachableMatches: Int,
                            unreachableMatches: Int) -> (records: [VideoRecord], cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badge_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var records: [VideoRecord] = []
        // Reachable matches: REAL temp files (reachable-true default AND a
        // truthful background probe — can never flip out mid-test).
        for i in 0..<reachableMatches {
            let url = dir.appendingPathComponent("donna_reach_\(i).mov")
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
            records.append(record(at: url.path))
        }
        // Reachable NON-match decoy — proves the badge counts search hits, not
        // every reachable row.
        let decoy = dir.appendingPathComponent("vacation_reach.mov")
        FileManager.default.createFile(atPath: decoy.path, contents: Data([0x00]))
        records.append(record(at: decoy.path))

        // Unreachable matches: fresh /Volumes keys — honestly reachable-false
        // on first query, no probe wait, no disk touch.
        let ghostRoot = "/Volumes/DefinitelyNotMounted_\(UUID().uuidString)"
        for i in 0..<unreachableMatches {
            records.append(record(at: "\(ghostRoot)/donna_ghost_\(i).mov"))
        }
        // Unreachable NON-match decoy.
        records.append(record(at: "\(ghostRoot)/vacation_ghost.mov"))

        return (records.shuffled(), { try? FileManager.default.removeItem(at: dir) })
    }

    /// DEFAULT (showDisconnectedMedia == false): the badge counts ONLY the
    /// reachable matches, not the matches sitting on an unmounted volume.
    @Test func defaultBadgeCountsOnlyReachableMatches() {
        let (records, cleanup) = makeCorpus(reachableMatches: 2, unreachableMatches: 3)
        defer { cleanup() }

        let badge = measuredBadge(records: records,
                                  searchText: "donna",
                                  showDisconnectedMedia: false)
        #expect(badge == 2,
                "Default connected-only badge must count only the 2 reachable 'donna' matches (5 total exist, 3 on an unmounted volume) — got \(badge)")
    }

    /// OPT-OUT (showDisconnectedMedia == true): the badge restores the #123
    /// cross-catalog semantics — ALL matches, reachable + unreachable.
    @Test func optOutBadgeCountsAllMatches() {
        let (records, cleanup) = makeCorpus(reachableMatches: 2, unreachableMatches: 3)
        defer { cleanup() }

        let badge = measuredBadge(records: records,
                                  searchText: "donna",
                                  showDisconnectedMedia: true)
        #expect(badge == 5,
                "Show-disconnected-media badge must count ALL 5 'donna' matches (2 reachable + 3 unreachable) — got \(badge)")
    }

    /// Both views over the SAME corpus in one test: the opt-out count must be
    /// strictly larger than the default count precisely because unreachable
    /// matches exist. Pins the DIRECTION of the split, not just two magic
    /// numbers — a regression that ignored `showDisconnectedMedia` (counting
    /// the same value both ways) trips this even if the constants drift.
    @Test func optOutStrictlyExceedsDefaultWhenUnreachableMatchesExist() {
        let (records, cleanup) = makeCorpus(reachableMatches: 2, unreachableMatches: 3)
        defer { cleanup() }

        let defaultBadge = measuredBadge(records: records,
                                         searchText: "donna",
                                         showDisconnectedMedia: false)
        let optOutBadge = measuredBadge(records: records,
                                        searchText: "donna",
                                        showDisconnectedMedia: true)
        #expect(defaultBadge == 2)
        #expect(optOutBadge == 5)
        #expect(optOutBadge > defaultBadge,
                "opt-out must reveal MORE hits than the connected-only default when matches live on an unmounted volume (default \(defaultBadge), opt-out \(optOutBadge))")
    }
}
