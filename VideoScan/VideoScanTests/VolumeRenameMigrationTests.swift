// VolumeRenameMigrationTests.swift
// Five-dimension coverage for the volume-rename detection + migration
// feature (feature/volume-rename-migration).
//
//   1. LOGIC — component-boundary path rewrite, the pure tier-decision
//      function (79/80/100% boundaries, UUID+0% → ask, B-only), spot-check
//      sampling/verdicts, UUID-gate behavior, detection guards, target
//      persistence update, Undo round-trip.
//   2. SCALE — 100k synthetic records through the full migration engine
//      with an explicit wall-clock budget (15 s — the honest-progress
//      threshold; measured well under it on Apple Silicon).
//   3. MEDIA MATRIX — N/A: the feature never opens/decodes media files
//      (pure catalog string work + file stats). Stated per checklist.
//   4. ISOLATION — a test-host migration never touches the machine's real
//      UserDefaults scan-target keys, and a migration against the SHARED
//      CatalogStore fail-safes (no snapshot possible → nothing rewritten).
//   5. SENSOR — end-to-end regression sensor on a synthetic two-name
//      volume fixture with real files: autodiscovery → auto-migrate →
//      dialog payload → persisted catalog shows the new paths.
//
// All volume identity comes through the two test seams
// (mountedVolumeInfoProviderForTesting / volumeRenameStatProviderForTesting)
// — no real volumes are mounted, renamed, or written. Rick's live
// Crucial2TB → CrucialX9 case is his acceptance test, not ours.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct VolumeRenameMigrationTests {

    // MARK: - Fixtures

    private let oldRoot = "/Volumes/VSTestOld2TB"
    private let newRoot = "/Volumes/VSTestNewX9"
    private let uuid = "TEST-UUID-CRUCIAL"

    private func makeRecord(fullPath: String, uuid: String,
                            size: Int64 = 1_000,
                            originVolume: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = "fixture-md5"
        r.scanContext.volumeUUID = uuid
        r.scanContext.volumeName = "VSTestOld2TB"
        r.originVolume = originVolume
        return r
    }

    private func makeOfflineTarget(_ path: String) -> CatalogScanTarget {
        let t = CatalogScanTarget(searchPath: path)
        t.isReachable = false
        return t
    }

    /// Mounted-volume seam: one renamed volume carrying the fixture UUID.
    private func mountedNewVolume(uuid: String? = nil) -> [MountedVolumeInfo] {
        [MountedVolumeInfo(root: newRoot, name: "VSTestNewX9",
                           uuid: uuid ?? self.uuid)]
    }

    /// Stat seam that answers "every rewritten path exists with the right
    /// size" — the all-clean Signal B.
    private func allCleanStat(size: Int64 = 1_000) -> @Sendable (String) -> Int64? {
        { _ in size }
    }

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeRenameTests-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Standard 5-record catalog: 3 UUID-matched under the old root, one
    /// foreign-UUID under it, one on a look-alike SIBLING volume
    /// (component-boundary trap) with the SAME uuid.
    private func seedStandardCatalog(_ model: VideoScanModel) {
        model.records = [
            makeRecord(fullPath: "\(oldRoot)/tapes/a.mov", uuid: uuid,
                       originVolume: "VSTestOld2TB"),
            makeRecord(fullPath: "\(oldRoot)/tapes/b.mov", uuid: uuid),
            makeRecord(fullPath: "\(oldRoot)/c.mov", uuid: uuid),
            makeRecord(fullPath: "\(oldRoot)/foreign.mov", uuid: "OTHER-UUID"),
            makeRecord(fullPath: "\(oldRoot)Backup/decoy.mov", uuid: uuid),
        ]
    }

    /// Model wired for the standard rename scenario. Auto pass disabled
    /// unless the test is exercising it.
    private func makeStandardModel(autoPass: Bool,
                                   store: CatalogStore? = nil) -> (VideoScanModel, CatalogScanTarget) {
        let model = VideoScanModel()
        model.volumeRenameAutoPassEnabled = autoPass
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume()] in mounted }
        model.volumeRenameStatProviderForTesting = allCleanStat()
        if let store { model.catalogStore = store }
        let target = makeOfflineTarget(oldRoot)
        model.scanTargets = [target]
        seedStandardCatalog(model)
        return (model, target)
    }

    // MARK: - 1. LOGIC: component-boundary path rewrite

    @Test
    func rewritePathPrefixHonorsComponentBoundaries() {
        // Ordinary rewrite.
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/Crucial2TB/tapes/a.mov",
            from: "/Volumes/Crucial2TB", to: "/Volumes/CrucialX9")
            == "/Volumes/CrucialX9/tapes/a.mov")
        // The Crucial2TBBackup trap: sibling volume must NOT match.
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/Crucial2TBBackup/a.mov",
            from: "/Volumes/Crucial2TB", to: "/Volumes/CrucialX9") == nil)
        // Exact-root match rewrites to the new root.
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/Crucial2TB",
            from: "/Volumes/Crucial2TB", to: "/Volumes/CrucialX9")
            == "/Volumes/CrucialX9")
        // Trailing slashes normalize away on every argument.
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/Crucial2TB/a.mov",
            from: "/Volumes/Crucial2TB/", to: "/Volumes/CrucialX9/")
            == "/Volumes/CrucialX9/a.mov")
        // Unrelated path → nil.
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/Other/a.mov",
            from: "/Volumes/Crucial2TB", to: "/Volumes/CrucialX9") == nil)
        // Match-everything roots are refused outright (data-loss footgun).
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/X/a.mov", from: "/", to: "/Volumes/Y") == nil)
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/X/a.mov", from: "", to: "/Volumes/Y") == nil)
        #expect(VideoScanModel.rewritePathPrefix(
            "/Volumes/X/a.mov", from: "/Volumes/X", to: "/") == nil)
    }

    // MARK: - 1. LOGIC: tier decision (pure function, table-driven)

    @Test
    func decideActionTiersAndBoundaries() {
        typealias M = VideoScanModel
        // UUID + all clean → auto, no drift.
        #expect(M.decideVolumeRenameAction(uuidMatched: true, sampledCount: 100, cleanCount: 100)
                == .autoMigrate(drift: false))
        // 80% boundary: exactly 80 → auto (drift), 79 → ask.
        #expect(M.decideVolumeRenameAction(uuidMatched: true, sampledCount: 100, cleanCount: 80)
                == .autoMigrate(drift: true))
        #expect(M.decideVolumeRenameAction(uuidMatched: true, sampledCount: 100, cleanCount: 79)
                == .ask(drift: true))
        // UUID + ~0% clean → reformat/restore smell → ask, never auto.
        #expect(M.decideVolumeRenameAction(uuidMatched: true, sampledCount: 25, cleanCount: 0)
                == .ask(drift: true))
        // B-only (no UUID evidence): ≥80% clean asks, never acts.
        #expect(M.decideVolumeRenameAction(uuidMatched: false, sampledCount: 25, cleanCount: 25)
                == .ask(drift: false))
        #expect(M.decideVolumeRenameAction(uuidMatched: false, sampledCount: 100, cleanCount: 80)
                == .ask(drift: true))
        // B-only below threshold → nothing.
        #expect(M.decideVolumeRenameAction(uuidMatched: false, sampledCount: 100, cleanCount: 79)
                == .none)
        // Nothing verifiable: UUID alone asks, no evidence at all → none.
        #expect(M.decideVolumeRenameAction(uuidMatched: true, sampledCount: 0, cleanCount: 0)
                == .ask(drift: false))
        #expect(M.decideVolumeRenameAction(uuidMatched: false, sampledCount: 0, cleanCount: 0)
                == .none)
    }

    // MARK: - 1. LOGIC: spot-check sampling + verdicts

    @Test
    func spotCheckSamplingIsDeterministicAndBounded() {
        let items = (0..<500).map { i in
            VolumeRenameRecordSnap(fullPath: "\(oldRoot)/f\(i).mov",
                                   volumeUUID: uuid, sizeBytes: Int64(i))
        }
        let sample1 = VideoScanModel.sampleForSpotCheck(items)
        let sample2 = VideoScanModel.sampleForSpotCheck(items)
        #expect(sample1.count == 25)
        #expect(sample1.map(\.fullPath) == sample2.map(\.fullPath),
                "Sampling must be deterministic")
        #expect(Set(sample1.map(\.fullPath)).count == 25, "Samples must be distinct")
        // Small inputs pass through whole.
        let few = Array(items.prefix(3))
        #expect(VideoScanModel.sampleForSpotCheck(few).count == 3)
    }

    @Test
    func spotCheckCountsMissingAndSizeMismatchAsDirty() {
        let samples = [
            VolumeRenameRecordSnap(fullPath: "\(oldRoot)/ok.mov", volumeUUID: uuid, sizeBytes: 100),
            VolumeRenameRecordSnap(fullPath: "\(oldRoot)/missing.mov", volumeUUID: uuid, sizeBytes: 100),
            VolumeRenameRecordSnap(fullPath: "\(oldRoot)/resized.mov", volumeUUID: uuid, sizeBytes: 100),
            VolumeRenameRecordSnap(fullPath: "\(oldRoot)/nosize.mov", volumeUUID: uuid, sizeBytes: 0),
        ]
        let disk: [String: Int64] = [
            "\(newRoot)/ok.mov": 100,       // clean
            // missing.mov absent               → dirty
            "\(newRoot)/resized.mov": 999,  // size mismatch → dirty
            "\(newRoot)/nosize.mov": 5,     // catalog size unknown → existence counts
        ]
        let (sampled, clean) = VideoScanModel.spotCheckRelocated(
            samples: samples, oldRoot: oldRoot, newRoot: newRoot,
            stat: { disk[$0] })
        #expect(sampled == 4)
        #expect(clean == 2)
    }

    // MARK: - 1. LOGIC: detection

    @Test
    func detectionFlagsRenamedOfflineVolumeByUUID() async {
        let (model, _) = makeStandardModel(autoPass: false)
        await model.rebuildVolumeRenameCandidatesNow()
        let cand = model.volumeRenameCandidate(for: oldRoot)
        #expect(cand != nil, "Offline target + UUID-matched mount must be flagged")
        guard let cand else { return }
        #expect(cand.newTargetPath == newRoot)
        #expect(cand.oldVolumeName == "VSTestOld2TB")
        #expect(cand.newVolumeName == "VSTestNewX9")
        #expect(cand.uuidMatched)
        #expect(cand.matchingRecords == 3, "Only the consensus-UUID records match")
        #expect(cand.mismatchedRecords == 1, "The foreign-UUID record is reported")
        #expect(cand.action == .autoMigrate(drift: false))
        // The sibling volume must have no candidate of its own and its
        // record must not be counted here (component boundary).
        #expect(model.volumeRenameCandidate(for: oldRoot + "Backup") == nil)
    }

    @Test
    func detectionWithoutUUIDsUsesSpotCheckAskTier() async {
        let model = VideoScanModel()
        model.volumeRenameAutoPassEnabled = false
        // Legacy catalog: no stored UUIDs anywhere.
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume(uuid: "SOME-UUID")] in mounted }
        model.volumeRenameStatProviderForTesting = allCleanStat()
        model.scanTargets = [makeOfflineTarget(oldRoot)]
        model.records = (0..<10).map { makeRecord(fullPath: "\(oldRoot)/f\($0).mov", uuid: "") }
        await model.rebuildVolumeRenameCandidatesNow()
        let cand = model.volumeRenameCandidate(for: oldRoot)
        #expect(cand != nil)
        guard let cand else { return }
        #expect(!cand.uuidMatched)
        #expect(cand.action == .ask(drift: false), "B-only evidence asks, never acts")
        #expect(cand.acceptedUUIDs.contains(""), "Legacy empty-UUID records may follow")
    }

    @Test
    func detectionRefusesAmbiguousMixedAndAbsentEvidence() async {
        // (a) TWO mounted volumes pass the B-only spot-check → ambiguous
        //     (clone next to its source) → nothing automatic.
        let model = VideoScanModel()
        model.volumeRenameAutoPassEnabled = false
        model.mountedVolumeInfoProviderForTesting = {
            [MountedVolumeInfo(root: "/Volumes/VSTestCloneA", name: "VSTestCloneA", uuid: ""),
             MountedVolumeInfo(root: "/Volumes/VSTestCloneB", name: "VSTestCloneB", uuid: "")]
        }
        model.volumeRenameStatProviderForTesting = allCleanStat()
        model.scanTargets = [makeOfflineTarget(oldRoot)]
        model.records = (0..<5).map { makeRecord(fullPath: "\(oldRoot)/f\($0).mov", uuid: "") }
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil,
                "Two look-alike volumes are ambiguous — no candidate")

        // (b) Mixed non-majority UUIDs → conflicting evidence → nothing.
        model.records = [
            makeRecord(fullPath: "\(oldRoot)/a.mov", uuid: "UUID-A"),
            makeRecord(fullPath: "\(oldRoot)/b.mov", uuid: "UUID-B"),
        ]
        model.mountedVolumeInfoProviderForTesting = {
            [MountedVolumeInfo(root: "/Volumes/VSTestNewX9", name: "VSTestNewX9", uuid: "UUID-A")]
        }
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil,
                "A 1-vs-1 UUID split is not a consensus")

        // (c) UUID consensus but no mounted volume carries it → nothing.
        model.records = [makeRecord(fullPath: "\(oldRoot)/a.mov", uuid: "UUID-A")]
        model.mountedVolumeInfoProviderForTesting = {
            [MountedVolumeInfo(root: "/Volumes/VSTestNewX9", name: "VSTestNewX9", uuid: "UNRELATED")]
        }
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil)
    }

    @Test
    func detectionSkipsReachableRetiredAndAlreadyRegisteredNewPath() async {
        // Reachable target: not a rename candidate.
        let (model, target) = makeStandardModel(autoPass: false)
        target.isReachable = true
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil)

        // Retired target: left alone.
        target.isReachable = false
        target.retiredAt = Date()
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil)

        // New path already registered as its own target: skip (two
        // targets must never collide on one path).
        target.retiredAt = nil
        model.scanTargets = [target, makeOfflineTarget(newRoot)]
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil)
    }

    @Test
    func detectionReadsNeverRecompute() async {
        let (model, _) = makeStandardModel(autoPass: false)
        await model.rebuildVolumeRenameCandidatesNow()
        let count = model.volumeRenameRecomputeCount
        for _ in 0..<200 {
            _ = model.volumeRenameCandidate(for: oldRoot)
        }
        #expect(model.volumeRenameRecomputeCount == count,
                "volumeRenameCandidate(for:) reads must never trigger recomputation")
    }

    // MARK: - 1. LOGIC: migration (UUID gate, target follow, index, snapshot)

    @Test
    func migrationRewritesOnlyGatePassingRecords() async throws {
        let dir = tempDir("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: false,
                                                store: CatalogStore(directory: dir))
        model.searchIndex.rebuild(records: model.records)
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) != nil)

        await model.userInitiatedVolumeRenameMigration(for: target)

        // Rewritten: the three UUID-matched records — fullPath, directory,
        // and the CURRENT volume name.
        let migrated = model.records.filter { $0.fullPath.hasPrefix(newRoot + "/") }
        #expect(migrated.count == 3)
        for rec in migrated {
            #expect(rec.directory.hasPrefix(newRoot),
                    "directory must follow: \(rec.directory)")
            #expect(rec.scanContext.volumeName == "VSTestNewX9")
        }
        // Historical provenance untouched.
        #expect(model.records.first { $0.fullPath == "\(newRoot)/tapes/a.mov" }?
            .originVolume == "VSTestOld2TB")
        // UUID gate: the foreign record stays at the OLD path.
        #expect(model.records.contains { $0.fullPath == "\(oldRoot)/foreign.mov" })
        // Component boundary: the sibling-volume decoy untouched.
        #expect(model.records.contains { $0.fullPath == "\(oldRoot)Backup/decoy.mov" })
        // The scan target followed and the candidate was consumed.
        #expect(target.searchPath == newRoot)
        #expect(model.volumeRenameCandidate(for: oldRoot) == nil)
        // Search index moved with the records.
        #expect(model.searchIndex.hasHaystack(for: "\(newRoot)/tapes/a.mov"))
        #expect(!model.searchIndex.hasHaystack(for: "\(oldRoot)/tapes/a.mov"))
        // The pre-migration safety snapshot exists.
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("catalog.pre-volume-rename.") }
        #expect(snapshots.count == 1)
        // The dialog payload is honest about what happened.
        let notice = try #require(model.pendingVolumeRenameNotice)
        guard case .migrated = notice.kind else {
            Issue.record("Expected a .migrated notice, got \(notice.kind)")
            return
        }
        #expect(notice.migratedCount == 3)
        #expect(notice.mismatchedCount == 1)
        #expect(notice.driftDetected == false)
    }

    @Test
    func migrationFailsSafeWithoutSnapshot() async {
        // SHARED store in a test host → snapshotCatalog returns nil →
        // the migration must refuse and change NOTHING.
        let (model, target) = makeStandardModel(autoPass: false)
        await model.rebuildVolumeRenameCandidatesNow()
        let pathsBefore = model.records.map(\.fullPath)
        let result = await model.migrateRenamedVolume(for: target)
        #expect(result == .abortedSnapshotFailed)
        #expect(model.records.map(\.fullPath) == pathsBefore,
                "No snapshot → no rewrite (fail safe)")
        #expect(target.searchPath == oldRoot)
        #expect(model.pendingVolumeRenameNotice == nil)
    }

    @Test
    func migrationAbortsWhenMountedVolumeChanged() async {
        let dir = tempDir("uuidflip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: false,
                                                store: CatalogStore(directory: dir))
        await model.rebuildVolumeRenameCandidatesNow()
        // Between detection and click, the mounted volume is replaced by
        // a different disk under the same name.
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume(uuid: "DIFFERENT")] in mounted }
        let pathsBefore = model.records.map(\.fullPath)
        let result = await model.migrateRenamedVolume(for: target)
        #expect(result == .abortedVolumeChanged)
        #expect(model.records.map(\.fullPath) == pathsBefore)
        #expect(target.searchPath == oldRoot)
    }

    // MARK: - 1. LOGIC: Undo round-trip (byte-identical restore)

    @Test
    func undoRestoresPreMigrationCatalogByteIdentically() async throws {
        let dir = tempDir("undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: false,
                                                store: CatalogStore(directory: dir))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // .sortedKeys — JSONEncoder guarantees NO key order: two encodes of
        // identical values can emit different key orders even in the same
        // process (hash-layout dependent; reproduced 2026-07-13). Canonical
        // sorted-keys encoding makes the byte comparison deterministic while
        // still pinning every field's value AND presence (delta-minimal
        // keys included) plus the records-array order. Same convention as
        // CatalogStoreAsyncSaveTests' clone-parity oracle.
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(model.records.map(VideoRecordDTO.init))

        await model.rebuildVolumeRenameCandidatesNow()
        await model.userInitiatedVolumeRenameMigration(for: target)
        let notice = try #require(model.pendingVolumeRenameNotice)
        #expect(model.records.contains { $0.fullPath.hasPrefix(newRoot + "/") })

        let undone = model.undoVolumeRenameMigration(notice)
        #expect(undone)
        let after = try encoder.encode(model.records.map(VideoRecordDTO.init))
        #expect(after == before,
                "Undo must restore the pre-migration snapshot byte-identically (canonical sorted-keys encoding)")
        #expect(target.searchPath == oldRoot, "The scan target's old path is restored")
        #expect(model.pendingVolumeRenameNotice == nil)
        // The very next detection rebuild re-finds the candidate but the
        // AUTO pass must not redo what Rick just undid.
        model.volumeRenameAutoPassEnabled = true
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) != nil,
                "Badge stays available as the manual affordance")
        #expect(model.pendingVolumeRenameNotice == nil,
                "Suppressed after Undo — no dialog nag")
        #expect(model.records.contains { $0.fullPath == "\(oldRoot)/tapes/a.mov" },
                "Auto pass must not re-migrate after Undo")
    }

    // MARK: - 1. LOGIC: auto pass + ask flow

    @Test
    func autoPassMigratesTwoSignalMatchAndRaisesDialog() async throws {
        let dir = tempDir("autopass")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: true,
                                                store: CatalogStore(directory: dir))
        await model.rebuildVolumeRenameCandidatesNow()
        // A + B(100%) → migrated without any click.
        #expect(target.searchPath == newRoot)
        #expect(model.records.filter { $0.fullPath.hasPrefix(newRoot + "/") }.count == 3)
        let notice = try #require(model.pendingVolumeRenameNotice)
        guard case .migrated = notice.kind else {
            Issue.record("Auto pass must raise the informational dialog")
            return
        }
        #expect(notice.driftDetected == false)
    }

    @Test
    func askTierRaisesDialogAndNotNowSuppressesForSession() async throws {
        let dir = tempDir("askflow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        model.volumeRenameAutoPassEnabled = true
        // Legacy catalog (no UUIDs) → B-only → ask tier.
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume(uuid: "")] in mounted }
        model.volumeRenameStatProviderForTesting = allCleanStat()
        let target = makeOfflineTarget(oldRoot)
        model.scanTargets = [target]
        model.records = (0..<6).map { makeRecord(fullPath: "\(oldRoot)/f\($0).mov", uuid: "") }

        await model.rebuildVolumeRenameCandidatesNow()
        let ask = try #require(model.pendingVolumeRenameNotice)
        #expect(ask.kind == .ask)
        #expect(target.searchPath == oldRoot, "Ask tier never migrates on its own")

        // Not Now → suppressed for the session; no re-nag on rebuild.
        model.dismissVolumeRenameNotice(ask)
        #expect(model.pendingVolumeRenameNotice == nil)
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.pendingVolumeRenameNotice == nil,
                "A dismissed ask must not re-pop")
        #expect(model.volumeRenameCandidate(for: oldRoot) != nil,
                "Badge remains as the manual affordance")

        // Accepting the (kept) ask migrates and raises the migrated
        // dialog — the no-UUID accept path.
        await model.acceptVolumeRenameAsk(ask)
        #expect(target.searchPath == newRoot)
        let done = try #require(model.pendingVolumeRenameNotice)
        guard case .migrated = done.kind else {
            Issue.record("Accepting the ask must end in the migrated dialog")
            return
        }
        #expect(done.migratedCount == 6)
    }

    @Test
    func uuidMatchWithZeroCleanSamplesAsksInsteadOfActing() async throws {
        let dir = tempDir("reformat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: true,
                                                store: CatalogStore(directory: dir))
        // Same UUID, but NOTHING checks out on disk (reformat/restore smell).
        model.volumeRenameStatProviderForTesting = { _ in nil }
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(target.searchPath == oldRoot, "UUID + 0% clean must NOT auto-migrate")
        let notice = try #require(model.pendingVolumeRenameNotice)
        #expect(notice.kind == .ask)
        #expect(notice.driftDetected)
    }

    // MARK: - 1. LOGIC: manual fallback

    @Test
    func manualCheckMigratesOnPassAndRefusesOnFail() async throws {
        let dir = tempDir("manual")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        model.volumeRenameAutoPassEnabled = false
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume(uuid: "")] in mounted }
        let target = makeOfflineTarget(oldRoot)
        model.scanTargets = [target]
        model.records = (0..<5).map { makeRecord(fullPath: "\(oldRoot)/f\($0).mov", uuid: "") }

        // FAIL first: nothing on the picked volume matches → friendly
        // refusal, nothing rewritten.
        model.volumeRenameStatProviderForTesting = { _ in nil }
        await model.manualVolumeRenameCheck(for: target, mountedRoot: newRoot)
        let refusal = try #require(model.pendingVolumeRenameNotice)
        guard case .refused = refusal.kind else {
            Issue.record("A failed spot-check must refuse, got \(refusal.kind)")
            return
        }
        #expect(target.searchPath == oldRoot)
        model.pendingVolumeRenameNotice = nil

        // PASS: files check out → migrate (user explicitly initiated).
        model.volumeRenameStatProviderForTesting = allCleanStat()
        await model.manualVolumeRenameCheck(for: target, mountedRoot: newRoot)
        #expect(target.searchPath == newRoot)
        let done = try #require(model.pendingVolumeRenameNotice)
        guard case .migrated = done.kind else {
            Issue.record("A passing manual check must migrate, got \(done.kind)")
            return
        }
        #expect(done.migratedCount == 5)
    }

    // MARK: - 1. LOGIC: drift follow-up wires to the EXISTING scan entry

    @Test
    func rescanAfterVolumeRenameInvokesExistingScanEntryPoint() async throws {
        let dir = tempDir("freshen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.volumeRenameAutoPassEnabled = false
        // Target at a REAL (empty) temp folder so startTarget can run its
        // normal lifecycle without any /Volumes dependency.
        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        let notice = VolumeRenameNotice(
            kind: .migrated(undoSnapshotPath: "/nonexistent"),
            targetID: target.id,
            oldVolumeName: "Old", newVolumeName: "New",
            oldTargetPath: oldRoot, newTargetPath: dir.path,
            migratedCount: 1, mismatchedCount: 0, driftDetected: true)
        model.pendingVolumeRenameNotice = notice
        model.rescanAfterVolumeRename(notice)
        #expect(model.pendingVolumeRenameNotice == nil)
        // startTarget either went active (normal) or refused via the
        // missing-dependency gate (machines without ffprobe) — both prove
        // the EXISTING entry point was invoked, no new scan machinery.
        #expect(target.status.isActive || model.missingDependency != nil,
                "Drift follow-up must route through startTarget")
        // Cleanup: don't leak a running scan into the next test.
        if target.status.isActive {
            model.stopTarget(target)
            _ = await target.scanTask?.value
        }
        model.missingDependency = nil
    }

    // MARK: - 2. SCALE: 100k records, explicit budget

    @Test
    func migrationOf100kRecordsStaysUnderBudget() async throws {
        let dir = tempDir("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        model.volumeRenameAutoPassEnabled = false
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume()] in mounted }
        model.volumeRenameStatProviderForTesting = allCleanStat()
        let target = makeOfflineTarget(oldRoot)
        model.scanTargets = [target]
        model.records = (0..<100_000).map {
            makeRecord(fullPath: "\(oldRoot)/decade\($0 % 8)/tape\($0).mov",
                       uuid: uuid, size: Int64(1_000 + $0))
        }
        model.searchIndex.rebuild(records: model.records)
        await model.rebuildVolumeRenameCandidatesNow()
        #expect(model.volumeRenameCandidate(for: oldRoot) != nil)

        // Budget: the standing rule requires honest visible progress for
        // ops >15 s at 100k records. The engine (plan + rewrite + search
        // index + pre-migration snapshot + saveCatalogNow to disk) must
        // stay under that threshold — measured, not assumed.
        let start = ContinuousClock.now
        let result = await model.migrateRenamedVolume(for: target)
        let elapsed = start.duration(to: .now)
        guard case .completed(let migrated, let mismatched, _) = result else {
            Issue.record("Scale migration failed: \(result)")
            return
        }
        #expect(migrated == 100_000)
        #expect(mismatched == 0)
        #expect(elapsed < .seconds(15),
                "100k-record migration took \(elapsed) — over the 15 s honest-progress budget; the feature now needs a progress UI")
    }

    // MARK: - 4. ISOLATION: real defaults + shared store are never touched

    @Test
    func migrationInTestHostNeverTouchesRealUserDefaults() async throws {
        // READ-ONLY snapshot of the machine's real persisted scan-target
        // state (never write these keys from a test — that's the exact
        // incident class of 2026-07-05).
        let defaults = UserDefaults.standard
        let targetsBefore = defaults.stringArray(forKey: VideoScanModel.savedTargetsKey)
        let phasesBefore = defaults.dictionary(forKey: VideoScanModel.savedPhasesKey) as? [String: String]

        let dir = tempDir("isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, target) = makeStandardModel(autoPass: false,
                                                store: CatalogStore(directory: dir))
        await model.rebuildVolumeRenameCandidatesNow()
        await model.userInitiatedVolumeRenameMigration(for: target)
        #expect(target.searchPath == newRoot, "Migration itself must succeed")

        #expect(defaults.stringArray(forKey: VideoScanModel.savedTargetsKey) == targetsBefore,
                "persistScanTargets must stay gated in a test host")
        #expect(defaults.dictionary(forKey: VideoScanModel.savedPhasesKey) as? [String: String] == phasesBefore,
                "persistScanDates must stay gated in a test host")
    }

    // MARK: - 5. SENSOR: end-to-end on a synthetic two-name volume fixture

    @Test
    func renameDetectionAndMigrationEndToEndSensor() async throws {
        // Synthetic "renamed volume": REAL files in a temp directory
        // standing in for /Volumes/VSTestNewX9 via a path-mapping stat.
        let diskDir = tempDir("sensor-disk")
        let storeDir = tempDir("sensor-store")
        defer {
            try? FileManager.default.removeItem(at: diskDir)
            try? FileManager.default.removeItem(at: storeDir)
        }
        let fileCount = 300
        var records: [VideoRecord] = []
        for i in 0..<fileCount {
            let name = "family_tape_\(i).mov"
            let bytes = Data(repeating: UInt8(i % 251), count: 64 + i % 32)
            try bytes.write(to: diskDir.appendingPathComponent(name))
            records.append(makeRecord(fullPath: "\(oldRoot)/\(name)", uuid: uuid,
                                      size: Int64(bytes.count)))
        }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: storeDir)
        model.volumeRenameAutoPassEnabled = true
        model.mountedVolumeInfoProviderForTesting = { [mounted = mountedNewVolume()] in mounted }
        // Map "/Volumes/VSTestNewX9/…" onto the real fixture dir and use
        // the REAL stat — this is the sensor's actual-filesystem leg.
        let diskPath = diskDir.path
        let mappedPrefix = newRoot
        model.volumeRenameStatProviderForTesting = { path in
            guard path.hasPrefix(mappedPrefix) else { return nil }
            let real = diskPath + String(path.dropFirst(mappedPrefix.count))
            return VideoScanModel.statFileSize(real)
        }
        let target = makeOfflineTarget(oldRoot)
        target.phase = .cataloged
        model.scanTargets = [target]
        model.records = records
        model.searchIndex.rebuild(records: model.records)

        // Autodiscovery → auto-migrate → dialog, in one deterministic call.
        await model.rebuildVolumeRenameCandidatesNow()

        #expect(target.searchPath == newRoot)
        #expect(target.phase == .cataloged, "Target metadata survives the move")
        #expect(model.records.allSatisfy { $0.fullPath.hasPrefix(newRoot + "/") })
        #expect(model.records.allSatisfy { $0.scanContext.volumeName == "VSTestNewX9" })
        let notice = try #require(model.pendingVolumeRenameNotice)
        guard case .migrated(let snapshotPath) = notice.kind else {
            Issue.record("Sensor expected the auto-migrated dialog")
            return
        }
        #expect(notice.migratedCount == fileCount)
        #expect(FileManager.default.fileExists(atPath: snapshotPath),
                "Undo snapshot must exist on disk")
        // Persistence leg: a fresh store instance reloads the NEW paths.
        let reloaded = CatalogStore(directory: storeDir).load()
        #expect(reloaded.count == fileCount)
        #expect(reloaded.allSatisfy { $0.fullPath.hasPrefix(newRoot + "/") },
                "The migrated catalog must be what's on disk")
    }

    // MARK: - 3. MEDIA MATRIX — intentionally absent
    //
    // This feature performs catalog string rewrites and file-size stats;
    // it never opens, decodes, or transcodes media. The media-matrix
    // dimension of the checklist is therefore N/A (stated explicitly per
    // the 2026-07-05 testing retrospective).
}
