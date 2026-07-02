// ScanMergeScopeTests.swift
// Regression suite for the LaCieWorkspace data-loss incident (2026-07-01):
// a rescan of /Volumes/LaCieWorkspace wiped all 5,694 records under the
// volume at scan START (startTarget's records.removeAll), then discovery
// came back with only 181 files, and scan completion blindly saved the
// result — silently destroying 5,586 catalog records whose files were
// still on disk.
//
// The fix moves the destructive replace from scan START to scan
// COMPLETION (VideoScanModel+ScanMerge.commitScanResults), scoped to the
// scanned root via component-boundary PathScope, and adds a mass-deletion
// tripwire (snapshot + warn before any merge that removes >20% AND >50 of
// the records under the scanned root).
//
// Red/green: emptyDiscoveryNeverPrunes FAILS before the fix (records are
// destroyed at scan start and an empty walk never brings them back) and
// PASSES after. The tripwire tests fail to compile before the fix (the
// API is new). The subtree-scope tests pass before AND after — the
// replace scope was already root-scoped (codex C2) — they are permanent
// sensors so the scope can never widen to volume-level.

import Testing
import Foundation
@testable import VideoScan

@Suite("Scan-completion catalog merge — scoped replace + tripwire")
struct ScanMergeScopeTests {

    // MARK: - Helpers

    /// Minimal cataloged record at an arbitrary path.
    private func makeRecord(path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = 1_000_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    private func makeTempDir(_ label: String) throws -> URL {
        // Canonicalize: NSTemporaryDirectory() is /var/folders/…, but the
        // walker yields realpath'd /private/var/folders/… URLs. Seeded
        // record paths must share the walker's prefix or nothing matches.
        // (URL.resolvingSymlinksInPath is no help — it STRIPS /private
        // instead of adding it; .canonicalPathKey gives the real path.)
        var dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_scanmerge_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            dir = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        return dir
    }

    // MARK: - 1. Incident replay: scan start must not destroy the catalog

    // regression: LaCieWorkspace 2026-07-01 — the destructive wipe ran at
    // scan START, so any scan whose discovery came back empty/incomplete
    // (walker skip rules, volume hiccup, abort) silently destroyed every
    // record it failed to re-find. An empty directory is the extreme case:
    // discovery finds 0 files, and the old records must SURVIVE.
    @Test @MainActor
    func emptyDiscoveryNeverPrunes() async throws {
        let dir = try makeTempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = VideoScanModel()
        let insideA = makeRecord(path: dir.appendingPathComponent("sub/a.mov").path)
        let insideB = makeRecord(path: dir.appendingPathComponent("b.mov").path)
        let outside = makeRecord(path: "/Volumes/ElsewhereVol/keep.mov")
        model.records = [insideA, insideB, outside]

        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let survivingInside = model.records.filter {
            PathScope.contains($0.fullPath, within: dir.path)
        }
        #expect(survivingInside.count == 2,
                "A scan that discovers 0 files must never prune existing records under the root (found \(survivingInside.count)/2)")
        #expect(model.records.contains { $0.fullPath == outside.fullPath },
                "Records on other volumes must be untouched")
    }

    // MARK: - 2. Subtree scan preserves same-volume records outside the root

    // Sensor (task 4a): scanning /Volumes/X/A must replace only records
    // under A — records under /Volumes/X/B (same volume, outside the
    // scanned root) are untouched. Drives the REAL pipeline: startTarget →
    // walker → probe → finalize/merge, with an on-disk fixture.
    //
    // Note: this passes before the fix too — the replace was already
    // root-scoped (codex C2). It stays as a permanent guard against any
    // future volume-keyed replace semantics.
    @Test @MainActor
    func subtreeScanPreservesSameVolumeSiblings() async throws {
        let vol = try makeTempDir("vol")
        defer { try? FileManager.default.removeItem(at: vol) }
        let subA = vol.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        // A junk-byte .mov: ffprobe will fail but the record is still
        // cataloged (extensioned damaged media stays visible).
        try Data(repeating: 0, count: 64).write(to: subA.appendingPathComponent("clip.mov"))

        let model = VideoScanModel()
        let staleA   = makeRecord(path: subA.appendingPathComponent("gone.mov").path)
        let siblingB = makeRecord(path: vol.appendingPathComponent("B/keep.mov").path)
        // Component-boundary trap: "<root>suffix" must NOT match "<root>".
        let lookalike = makeRecord(path: vol.appendingPathComponent("ABackup/keep2.mov").path)
        model.records = [staleA, siblingB, lookalike]

        let target = CatalogScanTarget(searchPath: subA.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let paths = Set(model.records.map(\.fullPath))
        #expect(paths.contains(siblingB.fullPath),
                "Same-volume record OUTSIDE the scanned root must survive a subtree scan")
        #expect(paths.contains(lookalike.fullPath),
                "Path-component boundary: scanning …/A must not touch …/ABackup")
        #expect(!paths.contains(staleA.fullPath),
                "Record under the scanned root whose file no longer exists must be pruned")
        #expect(paths.contains(subA.appendingPathComponent("clip.mov").path),
                "Freshly discovered file under the root must be cataloged")
    }

    // MARK: - 3. Full-volume scan still prunes genuinely deleted files

    // Task 4b: today's semantics for a complete scan are preserved — a
    // record whose file was deleted from disk is pruned on rescan. Real
    // pipeline, counts far below the tripwire thresholds.
    @Test @MainActor
    func fullVolumeScanPrunesDeletedFiles() async throws {
        let vol = try makeTempDir("prune")
        defer { try? FileManager.default.removeItem(at: vol) }
        try Data(repeating: 0, count: 64).write(to: vol.appendingPathComponent("still-here.mov"))

        let model = VideoScanModel()
        let deleted = makeRecord(path: vol.appendingPathComponent("deleted.mov").path)
        model.records = [deleted]

        let target = CatalogScanTarget(searchPath: vol.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let paths = Set(model.records.map(\.fullPath))
        #expect(!paths.contains(deleted.fullPath),
                "A complete scan must prune records whose files no longer exist under the root")
        #expect(paths.contains(vol.appendingPathComponent("still-here.mov").path),
                "The surviving file must be (re)cataloged")
    }

    // MARK: - 4. Merge-scope unit tests (commitScanResults directly)

    @Test @MainActor
    func commitReplacesOnlyUnderRootAtComponentBoundary() {
        let model = VideoScanModel()
        let oldA  = makeRecord(path: "/Volumes/X/A/old.mov")
        let keepB = makeRecord(path: "/Volumes/X/B/keep.mov")
        let trap  = makeRecord(path: "/Volumes/X/ABackup/trap.mov") // hasPrefix trap
        model.records = [oldA, keepB, trap]

        let fresh = makeRecord(path: "/Volumes/X/A/new.mov")
        let outcome = model.commitScanResults(
            root: "/Volumes/X/A", volName: "X",
            targetRecords: [fresh], scanWasComplete: true)

        let paths = Set(model.records.map(\.fullPath))
        #expect(paths == ["/Volumes/X/B/keep.mov", "/Volumes/X/ABackup/trap.mov", "/Volumes/X/A/new.mov"],
                "Replace must be scoped to the scanned root at a path-component boundary")
        #expect(outcome.pruned == 1 && outcome.added == 1 && !outcome.tripwireFired)
    }

    // MARK: - 5. Partial scan (abort) never prunes

    // A scan that aborted mid-probe ("volume likely unmounted") has
    // incomplete evidence: it must upsert what it re-saw and keep the rest.
    @Test @MainActor
    func partialScanUpsertsWithoutPruning() {
        let model = VideoScanModel()
        var seeds: [VideoRecord] = []
        for i in 0..<100 {
            seeds.append(makeRecord(path: "/Volumes/X/vids/clip\(i).mov"))
        }
        model.records = seeds

        // The aborted scan re-saw 5 known files (refreshed) + 2 new ones.
        var fresh = (0..<5).map { makeRecord(path: "/Volumes/X/vids/clip\($0).mov") }
        fresh.append(makeRecord(path: "/Volumes/X/vids/brand-new-1.mov"))
        fresh.append(makeRecord(path: "/Volumes/X/vids/brand-new-2.mov"))

        let outcome = model.commitScanResults(
            root: "/Volumes/X/vids", volName: "X",
            targetRecords: fresh, scanWasComplete: false)

        #expect(model.records.count == 102,
                "Partial scan: 95 unseen retained + 5 refreshed + 2 new = 102 (got \(model.records.count))")
        #expect(outcome.retainedStale == 95 && outcome.pruned == 0 && !outcome.tripwireFired,
                "Partial scans must never prune")
    }

    // MARK: - 6. Mass-deletion tripwire

    @Test func tripwireThresholds() {
        // Needs BOTH >50 records AND >20% (both strict).
        #expect(!VideoScanModel.scanMergeTripwireWouldFire(existingCount: 1000, removedCount: 51),
                "5.1% is below the 20% gate")
        #expect(!VideoScanModel.scanMergeTripwireWouldFire(existingCount: 60, removedCount: 50),
                "50 removed is not MORE than 50")
        #expect(!VideoScanModel.scanMergeTripwireWouldFire(existingCount: 255, removedCount: 51),
                "exactly 20% is not MORE than 20%")
        #expect(VideoScanModel.scanMergeTripwireWouldFire(existingCount: 254, removedCount: 51),
                "51 of 254 (20.1%) must fire")
        #expect(VideoScanModel.scanMergeTripwireWouldFire(existingCount: 5694, removedCount: 5586),
                "The LaCieWorkspace incident numbers must fire")
        #expect(!VideoScanModel.scanMergeTripwireWouldFire(existingCount: 12, removedCount: 10),
                "83% but only 10 records — small cleanups stay quiet")
    }

    // Task 4c: a mass-removal merge writes a timestamped pre-merge snapshot
    // next to catalog.json and reports the tripwire; a normal merge does
    // neither. Uses an injected CatalogStore(directory:) so nothing touches
    // the user's real Application Support.
    @Test @MainActor
    func tripwireFiresOnMassRemovalAndSnapshots() throws {
        let dir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        var seeds: [VideoRecord] = []
        for i in 0..<300 {
            seeds.append(makeRecord(path: "/Volumes/X/vids/clip\(i).mov"))
        }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)   // catalog.json to snapshot

        // "Complete" scan that only re-found 100 of 300 — incident shape.
        let fresh = (0..<100).map { makeRecord(path: "/Volumes/X/vids/clip\($0).mov") }
        let outcome = model.commitScanResults(
            root: "/Volumes/X/vids", volName: "X",
            targetRecords: fresh, scanWasComplete: true)

        #expect(outcome.tripwireFired, "Removing 200 of 300 (67%) must trip the tripwire")
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("catalog.pre-merge.") && $0.hasSuffix(".json") }
        #expect(snapshots.count == 1,
                "Exactly one pre-merge snapshot must exist next to catalog.json (found \(snapshots))")
        #expect(outcome.snapshotPath == (dir.path as NSString).appendingPathComponent(snapshots.first ?? ""),
                "Outcome must report the snapshot path")
        // Snapshot must hold the PRE-merge record count (recoverable).
        if let name = snapshots.first {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snap = try decoder.decode(CatalogSnapshot.self, from: data)
            #expect(snap.records.count == 300, "Snapshot must contain all 300 pre-merge records")
        }
        // Chosen semantics: snapshot + warn + PROCEED (scans finish
        // unattended; recovery is a file copy).
        #expect(model.records.count == 100, "The merge still proceeds after the tripwire")
    }

    @Test @MainActor
    func tripwireStaysQuietOnNormalMerge() throws {
        let dir = try makeTempDir("store2")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        var seeds: [VideoRecord] = []
        for i in 0..<300 {
            seeds.append(makeRecord(path: "/Volumes/X/vids/clip\(i).mov"))
        }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)

        // Routine rescan: 40 files genuinely deleted (13%, and under the
        // 50-record floor is irrelevant here — 40 < 50 anyway).
        let fresh = (0..<260).map { makeRecord(path: "/Volumes/X/vids/clip\($0).mov") }
        let outcome = model.commitScanResults(
            root: "/Volumes/X/vids", volName: "X",
            targetRecords: fresh, scanWasComplete: true)

        #expect(!outcome.tripwireFired, "40 of 300 removed must NOT fire the tripwire")
        #expect(outcome.snapshotPath == nil)
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("catalog.pre-merge.") }
        #expect(snapshots.isEmpty, "No pre-merge snapshot on a normal merge")
        #expect(model.records.count == 260, "Normal prune proceeds silently")
    }
}
