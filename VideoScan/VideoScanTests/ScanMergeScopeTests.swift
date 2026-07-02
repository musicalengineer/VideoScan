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

    /// Model with a DETERMINISTIC in-memory scan policy for pipeline-driving
    /// tests. VideoScanModel's default `scanOptions = .restored()` reads the
    /// developer's LIVE UserDefaults in the test host (the app is the host),
    /// so these tests silently depended on Rick's real prefs — with factory
    /// defaults (skipSmallFiles=true) the 64-byte fixtures would never be
    /// discovered and the pipeline tests would fail on any other machine.
    /// Pin the policy here, in memory only; `ScanOptions.save()` is never
    /// called, so real prefs are untouched (settings-pollution class).
    @MainActor
    private func makePipelineModel() -> VideoScanModel {
        let model = VideoScanModel()
        var opts = ScanOptions()
        opts.skipSmallFiles = false      // fixtures are tiny junk-byte files
        opts.skipChecksums = true        // speed; hashing is irrelevant here
        opts.probeExtensionless = false  // extensionless e2e lives in T3VExtensionlessSurvivalTests
        model.scanOptions = opts
        return model
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

        let model = makePipelineModel()
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

        let model = makePipelineModel()
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

        let model = makePipelineModel()
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

    // Fixture note (Fix 2, retained-invisible): complete-scan pruning is now
    // existence-checked, and an unreachable root retains everything — so the
    // scanned root must be a REAL directory and the to-be-pruned seed must
    // point at a file that genuinely does not exist under it. (The old
    // synthetic /Volumes/X root simulated a scan that can no longer happen:
    // a nonexistent root can't complete a scan.)
    @Test @MainActor
    func commitReplacesOnlyUnderRootAtComponentBoundary() throws {
        let vol = try makeTempDir("commitscope")
        defer { try? FileManager.default.removeItem(at: vol) }
        let rootA = vol.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)

        let model = VideoScanModel()
        let oldA  = makeRecord(path: rootA.appendingPathComponent("old.mov").path) // no file → genuinely gone
        let keepB = makeRecord(path: vol.appendingPathComponent("B/keep.mov").path)
        let trap  = makeRecord(path: vol.appendingPathComponent("ABackup/trap.mov").path) // hasPrefix trap
        model.records = [oldA, keepB, trap]

        let fresh = makeRecord(path: rootA.appendingPathComponent("new.mov").path)
        let outcome = model.commitScanResults(
            root: rootA.path, volName: "X",
            targetRecords: [fresh], scanWasComplete: true)

        let paths = Set(model.records.map(\.fullPath))
        #expect(paths == [keepB.fullPath, trap.fullPath, fresh.fullPath],
                "Replace must be scoped to the scanned root at a path-component boundary")
        #expect(outcome.pruned == 1 && outcome.added == 1 && !outcome.tripwireFired)
        #expect(outcome.retainedInvisible == 0)
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
        // Real on-disk scan root (see the Fix-2 fixture note above); the
        // seeded clips are never created, so the vanished 200 are all
        // genuinely gone and the tripwire must judge them.
        let vids = try makeTempDir("vids")
        defer { try? FileManager.default.removeItem(at: vids) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        var seeds: [VideoRecord] = []
        for i in 0..<300 {
            seeds.append(makeRecord(path: vids.appendingPathComponent("clip\(i).mov").path))
        }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)   // catalog.json to snapshot

        // "Complete" scan that only re-found 100 of 300 — incident shape.
        let fresh = (0..<100).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
        let outcome = model.commitScanResults(
            root: vids.path, volName: "X",
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
        let vids = try makeTempDir("vids2")   // real root, seeds never created
        defer { try? FileManager.default.removeItem(at: vids) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        var seeds: [VideoRecord] = []
        for i in 0..<300 {
            seeds.append(makeRecord(path: vids.appendingPathComponent("clip\(i).mov").path))
        }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)

        // Routine rescan: 40 files genuinely deleted (13%, and under the
        // 50-record floor is irrelevant here — 40 < 50 anyway).
        let fresh = (0..<260).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
        let outcome = model.commitScanResults(
            root: vids.path, volName: "X",
            targetRecords: fresh, scanWasComplete: true)

        #expect(!outcome.tripwireFired, "40 of 300 removed must NOT fire the tripwire")
        #expect(outcome.snapshotPath == nil)
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("catalog.pre-merge.") }
        #expect(snapshots.isEmpty, "No pre-merge snapshot on a normal merge")
        #expect(model.records.count == 260, "Normal prune proceeds silently")
    }

    // Boundary check THROUGH the merge, not just the static predicate:
    // exactly-at-threshold merges stay quiet, one-past fires and snapshots.
    // Guards the wiring (existingUnderRoot / vanished counting inside
    // commitScanResults), which tripwireThresholds cannot see.
    @Test @MainActor
    func tripwireBoundaryExactThresholdsThroughMerge() throws {
        // Sub-case: (seedCount, refoundCount, shouldFire, why)
        let cases: [(seeds: Int, refound: Int, fires: Bool, why: String)] = [
            (100, 50, false, "removes exactly 50 — not MORE than 50 records"),
            (255, 204, false, "removes 51 of 255 — exactly 20%, not MORE than 20%"),
            (254, 203, true, "removes 51 of 254 — just past both gates"),
        ]
        for c in cases {
            let dir = try makeTempDir("boundary")
            defer { try? FileManager.default.removeItem(at: dir) }
            let vids = try makeTempDir("boundaryvids")   // real root, seeds never created
            defer { try? FileManager.default.removeItem(at: vids) }
            let model = VideoScanModel()
            model.catalogStore = CatalogStore(directory: dir)
            let seeds = (0..<c.seeds).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
            model.records = seeds
            model.catalogStore.saveNow(records: seeds)

            let fresh = (0..<c.refound).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
            let outcome = model.commitScanResults(
                root: vids.path, volName: "X",
                targetRecords: fresh, scanWasComplete: true)

            #expect(outcome.tripwireFired == c.fires, "\(c.why)")
            #expect(outcome.pruned == c.seeds - c.refound)
            let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("catalog.pre-merge.") }
            #expect(snapshots.isEmpty == !c.fires,
                    "Snapshot presence must track the tripwire (\(c.why))")
        }
    }

    // MARK: - 7. Partial-scan upsert actually REPLACES same-path records

    // partialScanUpsertsWithoutPruning proves counts; this proves identity —
    // the re-seen path ends up with the FRESH record (refreshed scan-derived
    // fields, exactly one instance), never a stale duplicate pair.
    @Test @MainActor
    func partialScanUpsertReplacesSamePathRecord() {
        let model = VideoScanModel()
        let old = makeRecord(path: "/Volumes/X/vids/refreshed.mov")
        old.sizeBytes = 111
        let untouched = makeRecord(path: "/Volumes/X/vids/unseen.mov")
        model.records = [old, untouched]

        let fresh = makeRecord(path: "/Volumes/X/vids/refreshed.mov")
        fresh.sizeBytes = 222
        let outcome = model.commitScanResults(
            root: "/Volumes/X/vids", volName: "X",
            targetRecords: [fresh], scanWasComplete: false)

        let atPath = model.records.filter { $0.fullPath == old.fullPath }
        #expect(atPath.count == 1, "Upsert must never leave duplicate records at one path")
        #expect(atPath.first?.sizeBytes == 222,
                "The freshly-scanned record must WIN the upsert (got sizeBytes \(atPath.first?.sizeBytes ?? -1))")
        // `===` is reference identity — like comparing pointers in C++, not operator==.
        #expect(atPath.first === fresh, "The surviving instance must be the fresh record")
        #expect(model.records.contains { $0.fullPath == untouched.fullPath },
                "The un-re-seen record is retained on a partial scan")
        #expect(outcome.refreshed == 1 && outcome.retainedStale == 1 && outcome.pruned == 0)
    }

    // MARK: - 8. Rescan preservation survives the completion merge (pipeline)

    // RescanPreservationTests pins snapshot/apply in isolation; this pins the
    // ORDER in the real pipeline: applyPreservedFieldsAfterRescan must run
    // BEFORE commitScanResults replaces the records, or a routine same-path
    // refresh silently destroys dossier + user-curated fields (the 2026-06-07
    // dossier-dial incident class). Full pipeline: startTarget (snapshot) →
    // walker → probe → finalize (apply, then merge).
    @Test @MainActor
    func dossierAndUserFieldsSurviveSamePathRefresh() async throws {
        let dir = try makeTempDir("preserve")
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("keeper.mov").path
        // Junk bytes: ffprobe fails but extensioned damaged media is still
        // cataloged, so the path IS re-seen and replaced by the merge.
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: filePath))

        let model = makePipelineModel()
        let seed = makeRecord(path: filePath)
        seed.sizeBytes = 999_999                      // stale scan-derived value
        seed.lifecycleStage = .archived
        seed.mediaDisposition = .important
        seed.sceneCaptions = [SceneCaption(timestamp: 1.0, text: "porch summer 1985")]
        seed.detectedPeople = ["Donna"]
        seed.notes = "curated"
        model.records = [seed]

        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let refreshed = try #require(model.records.first { $0.fullPath == filePath },
                                     "Re-seen path must still be cataloged after the rescan")
        #expect(refreshed !== seed,
                "The merge must have REPLACED the record with a freshly-scanned instance")
        #expect(refreshed.sizeBytes == 64,
                "Scan-derived fields must be refreshed from disk (got \(refreshed.sizeBytes))")
        // The irreplaceable fields must have been restored onto the fresh record.
        #expect(refreshed.lifecycleStage == .archived)
        #expect(refreshed.mediaDisposition == .important)
        #expect(refreshed.sceneCaptions.first?.text == "porch summer 1985")
        #expect(refreshed.detectedPeople == ["Donna"])
        #expect(refreshed.notes == "curated")
    }

    // MARK: - 9. RESUMED scan preserves dossier + user fields (pipeline)

    // regression (testing agent, 2026-07-02): snapshotPreservedFieldsForRescan
    // was called only from startTarget — resumeTarget never snapshotted. Since
    // 0a6fd3c, resume re-verifies the FULL checkpoint list and finalize
    // performs a complete-scan replace, so a resumed-to-completion scan
    // replaced every re-seen record with a fresh probe carrying NO dossier or
    // user fields (applyPreservedFieldsAfterRescan found an empty map;
    // pendingPreservedFields is in-memory only, so a crash/relaunch → resume
    // had nothing to restore from). Mirror of test 8, driven through
    // resumeTarget instead of startTarget.
    @Test @MainActor
    func dossierAndUserFieldsSurviveResumedScan() async throws {
        let dir = try makeTempDir("resume")
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("keeper.mov").path
        // Junk bytes: ffprobe fails but extensioned damaged media is still
        // cataloged, so the path IS re-seen and replaced by the merge.
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: filePath))

        let model = makePipelineModel()
        let seed = makeRecord(path: filePath)
        seed.sizeBytes = 999_999                      // stale scan-derived value
        seed.lifecycleStage = .archived
        seed.mediaDisposition = .important
        seed.sceneCaptions = [SceneCaption(timestamp: 1.0, text: "porch summer 1985")]
        seed.notes = "curated"
        model.records = [seed]

        // Checkpoint as an interrupted scan of this root would leave it
        // (production storage, UUID temp path key — RobustScanTests convention).
        ScanCheckpointStorage.save(ScanCheckpoint(
            volumePath: dir.path,
            startedAt: Date(),
            discoveredPaths: [filePath],
            totalDiscovered: 1,
            skipChecksums: true))
        defer { ScanCheckpointStorage.delete(for: dir.path) }

        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.resumeTarget(target)
        _ = await target.scanTask?.value

        let refreshed = try #require(model.records.first { $0.fullPath == filePath },
                                     "Re-seen path must still be cataloged after the resumed scan")
        #expect(refreshed !== seed,
                "The completion merge must have REPLACED the record with a freshly-probed instance")
        #expect(refreshed.sizeBytes == 64,
                "Scan-derived fields must be refreshed from disk (got \(refreshed.sizeBytes))")
        // The irreplaceable fields must survive a resume exactly as they
        // survive a fresh startTarget rescan (RED before resumeTarget
        // snapshots preserved fields).
        #expect(refreshed.lifecycleStage == .archived)
        #expect(refreshed.mediaDisposition == .important)
        #expect(refreshed.sceneCaptions.first?.text == "porch summer 1985")
        #expect(refreshed.notes == "curated")
    }

    // MARK: - 10. Complete rescan keeps records INVISIBLE to the scan's options

    // "Not re-seen" conflates two very different things: "file deleted from
    // disk" (prune — correct) and "file invisible to this scan's options"
    // (probeExtensionless OFF here — the t3-v shape; same class as
    // skipSmallFiles, scanAudioFiles off, skip-listed subtrees). Discovery is
    // NON-EMPTY (a normal .mov sits next to the blob) so the empty-discovery
    // guard does not apply, and 1 vanished record slips far under the >50
    // tripwire floor — only a per-record existence check can save it.
    @Test @MainActor
    func completeRescanRetainsOnDiskRecordInvisibleToScanOptions() async throws {
        let dir = try makeTempDir("invisible")
        defer { try? FileManager.default.removeItem(at: dir) }
        // On disk: a normal .mov (discovery non-empty) and an extensionless
        // blob the walker cannot see while probeExtensionless is off.
        try Data(repeating: 0, count: 64).write(to: dir.appendingPathComponent("visible.mov"))
        let blobPath = dir.appendingPathComponent("rescued-noext").path
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: blobPath))

        let model = makePipelineModel()   // probeExtensionless = false
        let blobRecord = makeRecord(path: blobPath)               // file still on disk
        let deleted = makeRecord(path: dir.appendingPathComponent("deleted.mov").path) // no file
        model.records = [blobRecord, deleted]

        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let paths = Set(model.records.map(\.fullPath))
        #expect(paths.contains(blobPath),
                "Record whose file is STILL ON DISK but invisible to this scan's options must survive a complete rescan (RED pre-fix)")
        #expect(!paths.contains(deleted.fullPath),
                "Record whose file is genuinely gone must still be pruned in the same merge")
        #expect(paths.contains(dir.appendingPathComponent("visible.mov").path),
                "The visible file must be (re)cataloged")
    }

    // MARK: - 11. Unreachable root: never prune based on an unreachable disk

    // If the scan root itself is gone/unmounted at merge time, the
    // existence checks would report EVERY file as missing — a complete
    // merge would prune the lot. The root check must catch this first and
    // retain all vanished records.
    @Test @MainActor
    func unreachableRootAtMergeTimeRetainsAllVanished() throws {
        let vol = try makeTempDir("unmounted")
        defer { try? FileManager.default.removeItem(at: vol) }
        let root = vol.appendingPathComponent("gone", isDirectory: true).path // never created

        let model = VideoScanModel()
        let seeds = (0..<3).map {
            makeRecord(path: (root as NSString).appendingPathComponent("clip\($0).mov"))
        }
        model.records = seeds

        let outcome = model.commitScanResults(
            root: root, volName: "gone",
            targetRecords: [], scanWasComplete: true)

        #expect(model.records.count == 3,
                "All records under an unreachable root must be retained (got \(model.records.count)/3)")
        #expect(outcome.pruned == 0 && outcome.retainedInvisible == 3 && !outcome.tripwireFired)
    }

    // MARK: - 12. Tripwire judges only the genuinely-gone set

    // 200 of 300 vanish from a complete scan, but 150 of them are still on
    // disk (invisible to the scan's options): only 50 are genuinely gone —
    // not MORE than 50, so the tripwire stays quiet and no snapshot is
    // written. Pre-fix this merge would have pruned all 200 AND fired.
    @Test @MainActor
    func tripwireJudgesOnlyGenuinelyGoneRecords() throws {
        let dir = try makeTempDir("store3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vids = try makeTempDir("vids3")
        defer { try? FileManager.default.removeItem(at: vids) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        let seeds = (0..<300).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)

        // Files 100..<250 exist on disk but are not re-seen (invisible);
        // 250..<300 are genuinely gone; 0..<100 are re-found by the scan.
        for i in 100..<250 {
            try Data(repeating: 0, count: 64).write(to: vids.appendingPathComponent("clip\(i).mov"))
        }
        let fresh = (0..<100).map { makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path) }
        let outcome = model.commitScanResults(
            root: vids.path, volName: "X",
            targetRecords: fresh, scanWasComplete: true)

        #expect(outcome.pruned == 50 && outcome.retainedInvisible == 150)
        #expect(!outcome.tripwireFired,
                "Tripwire must judge the genuinely-gone set (50 — not MORE than 50), not all 200 vanished")
        #expect(model.records.count == 250,
                "100 fresh + 150 retained-invisible = 250 (got \(model.records.count))")
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("catalog.pre-merge.") }
        #expect(snapshots.isEmpty, "No pre-merge snapshot when the tripwire stays quiet")
    }
}
