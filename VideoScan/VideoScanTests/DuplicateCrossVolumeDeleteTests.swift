import Foundation
import Testing
@testable import VideoScan

// MARK: - "Also clean up working copies" (2026-08-18)
//
// Rick-approved opt-in, DEFAULT OFF (vocabulary per AMPAS Digital Dilemma
// / NDSA / PBCore: an asset has copies; the copy on the most reliable
// drive is its master; working copies are ephemeral). When ON, Delete
// Duplicates on <volume> also removes working copies there whose master
// (the elected keeper) is on a DIFFERENT drive that is online, not
// retired, known, and ranked strictly HIGHER than <volume> — reusing the
// election's VolumeRank, never a second ordering. Everything else
// (byte-for-byte verify right before remove, carry-over on the verified
// outcome, refusal notes, Master Archive exclusion) is unchanged.
//
// Dimensions: Logic (eligibility matrix), Sensor (OFF == pre-existing
// same-drive-only, byte-for-byte; delete path unchanged), Isolation
// (settings never touch real prefs), Scale (100k selection linear).

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

@MainActor
private func dupRecord(path: String, size: Int64 = 1, group: UUID,
                       disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "m"
    r.durationSeconds = 61.0
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

@MainActor
private func target(_ path: String, role: VolumeRole = .workspace,
                    reachable: Bool = true, retired: Bool = false) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = role
    t.isReachable = reachable
    if retired { t.retiredAt = Date() }
    return t
}

private func facts(role: VolumeRole = .workspace, reachable: Bool = true,
                   retired: Bool = false, master: Bool = false) -> DuplicateKeeperPolicy.VolumeFacts {
    DuplicateKeeperPolicy.VolumeFacts(role: role, isReachable: reachable, isRetired: retired, isMasterArchive: master)
}

// MARK: - Eligibility matrix (pure policy)

@Suite("Cross-volume delete — eligibility matrix")
struct DuplicateCrossVolumeEligibilityTests {

    /// Rick's seed order with the SSD (CrucialX9) as the chosen drive.
    private let policy = DuplicateKeeperPolicy(
        precedence: DuplicateKeeperSettings.defaultPrecedence,
        facts: [
            "/Volumes/FamilyArchive": facts(role: .archive, master: true),
            "/Volumes/LaCieWorkspace": facts(),
            "/Volumes/CrucialX10": facts(),
            "/Volumes/CrucialX9": facts(),
            "/Volumes/Shelf": facts(reachable: false),
            "/Volumes/OldBook": facts(reachable: false, retired: true),
            "/Volumes/Bak": facts(role: .backup),
        ])

    private func verdict(keeperVol: String, here: String = "CrucialX9") -> DuplicateKeeperPolicy.CrossVolumeVerdict {
        policy.crossVolumeVerdict(extraPath: "/Volumes/\(here)", volumeRoot: "/Volumes/\(here)",
                                  keeperPath: "/Volumes/\(keeperVol)/a.mov", keeperRoot: "/Volumes/\(keeperVol)")
    }

    @Test func keeperOnlineHigherRankedIsEligible() {
        #expect(verdict(keeperVol: "LaCieWorkspace") == .eligible)
        #expect(verdict(keeperVol: "CrucialX10") == .eligible, "one step up the list is still strictly higher")
        #expect(verdict(keeperVol: "FamilyArchive") == .eligible, "Master Archive keeper is the best case")
    }

    @Test func keeperLowerRankedIsNotEligible() {
        #expect(verdict(keeperVol: "CrucialX9", here: "CrucialX10") == .keeperNotHigherRanked)
        #expect(verdict(keeperVol: "Bak") == .keeperNotHigherRanked, "unlisted backup role ranks below a listed SSD")
    }

    @Test func keeperOnSameVolumeIsSameVolumeNotCross() {
        #expect(verdict(keeperVol: "CrucialX9") == .sameVolume)
    }

    @Test func keeperOfflineOrRetiredIsNeverEligible() {
        #expect(verdict(keeperVol: "Shelf") == .keeperOffline)
        #expect(verdict(keeperVol: "OldBook") == .keeperRetired)
        // Even if the shelf drive were listed FIRST.
        let listedShelf = DuplicateKeeperPolicy(
            precedence: ["Shelf", "CrucialX9"],
            facts: ["/Volumes/Shelf": facts(reachable: false), "/Volumes/CrucialX9": facts()])
        #expect(listedShelf.crossVolumeVerdict(extraPath: "/Volumes/CrucialX9", volumeRoot: "/Volumes/CrucialX9",
                                               keeperPath: "/Volumes/Shelf/a.mov", keeperRoot: "/Volumes/Shelf") == .keeperOffline)
    }

    @Test func keeperOnUnknownVolumeIsNotEligibleWhenHereIsListed() {
        #expect(verdict(keeperVol: "MysteryDrive") == .keeperVolumeUnknown)
    }

    /// QA major 1: an unknown master drive is refused UNCONDITIONALLY —
    /// even when "here" is unlisted/unknown too. Deletion never trusts a
    /// drive the app knows nothing about.
    @Test func unknownKeeperVolumeIsRefusedEvenWhenHereIsUnlisted() {
        let p = DuplicateKeeperPolicy(precedence: [], facts: [:])
        #expect(p.crossVolumeVerdict(extraPath: "/Volumes/A", volumeRoot: "/Volumes/A",
                                     keeperPath: "/Volumes/B/a.mov", keeperRoot: "/Volumes/B") == .keeperVolumeUnknown)
        // Known-but-unlisted master (a scan target) with an unknown "here":
        // still compared by precedence, not refused for unknown-ness.
        let q = DuplicateKeeperPolicy(precedence: [], facts: ["/Volumes/B": facts(role: .workspace)])
        #expect(q.crossVolumeVerdict(extraPath: "/Volumes/A", volumeRoot: "/Volumes/A",
                                     keeperPath: "/Volumes/B/a.mov", keeperRoot: "/Volumes/B") == .eligible,
                "workspace (50) outranks an unknown/unassigned here (30)")
    }

    /// QA minor 2: a stale offline/retired flag on the drive BEING CLEANED
    /// must not let a lower-listed master qualify — the comparison is by
    /// precedence position only.
    @Test func staleOfflineFlagOnHereDoesNotPromoteLowerListedKeeper() {
        let p = DuplicateKeeperPolicy(
            precedence: ["Here", "Lower"],
            facts: ["/Volumes/Here": facts(reachable: false, retired: true),   // stale flags
                    "/Volumes/Lower": facts()])
        #expect(p.crossVolumeVerdict(extraPath: "/Volumes/Here", volumeRoot: "/Volumes/Here",
                                     keeperPath: "/Volumes/Lower/a.mov", keeperRoot: "/Volumes/Lower") == .keeperNotHigherRanked)
        // And a genuinely higher-listed master is still eligible despite
        // "here" being flagged offline.
        let q = DuplicateKeeperPolicy(
            precedence: ["Upper", "Here"],
            facts: ["/Volumes/Here": facts(reachable: false), "/Volumes/Upper": facts()])
        #expect(q.crossVolumeVerdict(extraPath: "/Volumes/Here", volumeRoot: "/Volumes/Here",
                                     keeperPath: "/Volumes/Upper/a.mov", keeperRoot: "/Volumes/Upper") == .eligible)
    }

    /// The verdict's ordering IS the election's ordering (VolumeRank is
    /// what ElectionKey is built from).
    @Test func verdictReusesElectionVolumeRank() {
        let lacie = VideoRecord(); lacie.fullPath = "/Volumes/LaCieWorkspace/a.mov"
        let x9 = VideoRecord(); x9.fullPath = "/Volumes/CrucialX9/a.mov"
        let kL = policy.electionKey(for: lacie, technicalScore: 0)
        let kX = policy.electionKey(for: x9, technicalScore: 0)
        let rL = policy.volumeRank(forPath: lacie.fullPath)
        let rX = policy.volumeRank(forPath: x9.fullPath)
        #expect((kL.availability, kL.precedence) == (rL.availability, rL.precedence))
        #expect((kX.availability, kX.precedence) == (rX.availability, rX.precedence))
        #expect(rL > rX)
    }
}

// MARK: - Model selection + delete path

@Suite(.serialized)
@MainActor
struct DuplicateCrossVolumeDeleteTests {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DupCross-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two "drives" as subfolders of the temp dir, registered as scan
    /// targets so volumeRoot()/facts resolve, with the keeper drive
    /// listed ABOVE the extra drive in the precedence list.
    private struct Rig {
        let dir: URL
        let model: VideoScanModel
        let keeperVol: URL   // "/…/RaidLike"
        let extraVol: URL    // "/…/SsdLike"
    }

    private func makeRig() -> Rig {
        let dir = tempDir()
        let keeperVol = dir.appendingPathComponent("RaidLike", isDirectory: true)
        let extraVol = dir.appendingPathComponent("SsdLike", isDirectory: true)
        try? FileManager.default.createDirectory(at: keeperVol, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: extraVol, withIntermediateDirectories: true)
        let model = makeModel(dir)
        model.scanTargets = [target(keeperVol.path), target(extraVol.path)]
        // Absolute-path list entries: keeper drive first (higher).
        model.duplicateKeeperSettings.volumePrecedence = [keeperVol.path, extraVol.path]
        return Rig(dir: dir, model: model, keeperVol: keeperVol, extraVol: extraVol)
    }

    /// Default OFF: an extra whose keeper is on another drive is skipped
    /// with the legacy reason, exactly as before — nothing deleted.
    @Test func toggleOffKeepsSameDriveOnlyBehaviour() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let bytes = (0..<10_000).map { UInt8($0 % 13) }
        let k = rig.keeperVol.appendingPathComponent("a.mov"); write(k, bytes)
        let e = rig.extraVol.appendingPathComponent("a copy.mov"); write(e, bytes)
        let g = UUID()
        rig.model.records = [dupRecord(path: k.path, size: 10_000, group: g, disposition: .keep),
                             dupRecord(path: e.path, size: 10_000, group: g, disposition: .extraCopy)]
        #expect(rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies == false, "DEFAULT OFF")

        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.isEmpty)
        #expect(sel.skippedCount == 1)
        #expect(sel.crossVolumeMode == false)
        #expect(sel.summaryLine == "0 same-drive extras")
        #expect(rig.model.volumesWithDeletableDuplicates().isEmpty)

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 0 && result.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: e.path))
    }

    /// ON + identical bytes + keeper on the higher-ranked online drive:
    /// the extra is removed and its human metadata lands on the keeper.
    @Test func toggleOnDeletesEligibleCrossVolumeExtraAndCarriesOver() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let bytes = (0..<20_000).map { UInt8($0 % 17) }
        let k = rig.keeperVol.appendingPathComponent("Reel.mov"); write(k, bytes)
        let e = rig.extraVol.appendingPathComponent("Reel copy.mov"); write(e, bytes)
        let g = UUID()
        let keeper = dupRecord(path: k.path, size: 20_000, group: g, disposition: .keep)
        let extra = dupRecord(path: e.path, size: 20_000, group: g, disposition: .extraCopy)
        extra.starRating = 3
        extra.userNotes = "from the SSD"
        extra.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        rig.model.records = [keeper, extra]

        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.count == 1 && sel.crossVolumeCount == 1 && sel.sameVolumeCount == 0)
        #expect(sel.crossVolumeKeeperVolumes == ["RaidLike"])
        #expect(sel.summaryLine == "0 same-drive extras + 1 working copy whose master is on RaidLike")
        #expect(sel.confirmationText(volumeName: "SsdLike")
                == "Remove 1 extra copy on SsdLike: 0 same-drive extras + 1 working copy whose master is on RaidLike. Masters are never touched.")
        #expect(rig.model.volumesWithDeletableDuplicates().map(\.count) == [1])

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: e.path))
        #expect(FileManager.default.fileExists(atPath: k.path))
        #expect(keeper.starRating == 3)
        #expect(keeper.userNotes == "from the SSD")
        #expect(keeper.confirmedByUserPeople.map(\.name) == ["Donna"])
        #expect(rig.model.records.count == 1)
    }

    /// ON but the pair is NOT identical: refused, nothing deleted, nothing
    /// carried — the byte-verify gate is unchanged by the mode.
    @Test func toggleOnRefusedNonIdenticalCrossVolumePairCarriesNothing() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let k = rig.keeperVol.appendingPathComponent("a.mov"); write(k, [UInt8](repeating: 1, count: 4_000))
        let e = rig.extraVol.appendingPathComponent("b.mov"); write(e, [UInt8](repeating: 2, count: 4_000))
        let g = UUID()
        let keeper = dupRecord(path: k.path, size: 4_000, group: g, disposition: .keep)
        let extra = dupRecord(path: e.path, size: 4_000, group: g, disposition: .extraCopy)
        extra.starRating = 3
        rig.model.records = [keeper, extra]

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: e.path))
        #expect(keeper.starRating == 0)
        #expect(extra.duplicateDisposition == .review)
    }

    /// ON, but the keeper's drive is LOWER-ranked (list reversed): the
    /// extra is skipped with the family-language reason.
    @Test func toggleOnSkipsWhenKeeperDriveRanksLower() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        rig.model.duplicateKeeperSettings.volumePrecedence = [rig.extraVol.path, rig.keeperVol.path]
        let g = UUID()
        rig.model.records = [dupRecord(path: rig.keeperVol.appendingPathComponent("a.mov").path, group: g, disposition: .keep),
                             dupRecord(path: rig.extraVol.appendingPathComponent("a.mov").path, group: g, disposition: .extraCopy)]
        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.isEmpty)
        #expect(sel.skippedReasons.map(\.reason) == [DuplicateKeeperPolicy.CrossVolumeVerdict.keeperNotHigherRanked.reason])
    }

    /// ON, keeper drive unplugged / retired: skipped, never a target.
    @Test func toggleOnSkipsOfflineAndRetiredKeeperDrives() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g = UUID()
        rig.model.records = [dupRecord(path: rig.keeperVol.appendingPathComponent("a.mov").path, group: g, disposition: .keep),
                             dupRecord(path: rig.extraVol.appendingPathComponent("a.mov").path, group: g, disposition: .extraCopy)]

        rig.model.scanTargets[0].isReachable = false
        var sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.isEmpty)
        #expect(sel.skippedReasons.first?.reason == DuplicateKeeperPolicy.CrossVolumeVerdict.keeperOffline.reason)

        rig.model.scanTargets[0].retiredAt = Date()
        sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.isEmpty)
        #expect(sel.skippedReasons.first?.reason == DuplicateKeeperPolicy.CrossVolumeVerdict.keeperRetired.reason)
    }

    /// Same-drive extras are still targets alongside cross-drive ones, and
    /// the summary reports the split.
    @Test func mixedSameAndCrossVolumeSummary() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g1 = UUID(), g2 = UUID()
        rig.model.records = [
            dupRecord(path: rig.keeperVol.appendingPathComponent("x.mov").path, group: g1, disposition: .keep),
            dupRecord(path: rig.extraVol.appendingPathComponent("x.mov").path, group: g1, disposition: .extraCopy),
            dupRecord(path: rig.extraVol.appendingPathComponent("y.mov").path, group: g2, disposition: .keep),
            dupRecord(path: rig.extraVol.appendingPathComponent("y copy.mov").path, group: g2, disposition: .extraCopy),
            dupRecord(path: rig.extraVol.appendingPathComponent("y copy 2.mov").path, group: g2, disposition: .extraCopy),
        ]
        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.sameVolumeCount == 2 && sel.crossVolumeCount == 1)
        #expect(sel.summaryLine == "2 same-drive extras + 1 working copy whose master is on RaidLike")
        #expect(sel.confirmationText(volumeName: "SsdLike")
                == "Remove 3 extra copies on SsdLike: 2 same-drive extras + 1 working copy whose master is on RaidLike. Masters are never touched.")
    }

    /// QA test (a): a cross batch > 20% of the volume's records (here 1 of
    /// 1 = 100%) writes a catalog.pre-dup-crossvolume snapshot first.
    @Test func crossBatchOverThresholdWritesSnapshot() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let bytes = (0..<8_000).map { UInt8($0 % 11) }
        let k = rig.keeperVol.appendingPathComponent("a.mov"); write(k, bytes)
        let e = rig.extraVol.appendingPathComponent("a copy.mov"); write(e, bytes)
        let g = UUID()
        rig.model.records = [dupRecord(path: k.path, size: 8_000, group: g, disposition: .keep),
                             dupRecord(path: e.path, size: 8_000, group: g, disposition: .extraCopy)]

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 1)
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: rig.dir.path))?
            .filter { $0.hasPrefix("catalog.pre-dup-crossvolume.") && $0.hasSuffix(".json") } ?? []
        #expect(snaps.count == 1, "expected one pre-dup-crossvolume snapshot, got \(snaps)")
    }

    /// QA test (a): snapshot failure drops the cross-drive part; same-drive
    /// extras still proceed. (Store read-only ⇒ writeSnapshot returns false.)
    @Test func snapshotFailureDropsCrossPartSameDriveProceeds() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        rig.model.catalogStore.isReadOnly = true      // snapshot cannot be written
        let bytes = (0..<8_000).map { UInt8($0 % 11) }
        let k = rig.keeperVol.appendingPathComponent("a.mov"); write(k, bytes)
        let cross = rig.extraVol.appendingPathComponent("a copy.mov"); write(cross, bytes)
        let sameK = rig.extraVol.appendingPathComponent("b.mov"); write(sameK, bytes)
        let sameE = rig.extraVol.appendingPathComponent("b copy.mov"); write(sameE, bytes)
        let g1 = UUID(), g2 = UUID()
        rig.model.records = [
            dupRecord(path: k.path, size: 8_000, group: g1, disposition: .keep),
            dupRecord(path: cross.path, size: 8_000, group: g1, disposition: .extraCopy),
            dupRecord(path: sameK.path, size: 8_000, group: g2, disposition: .keep),
            dupRecord(path: sameE.path, size: 8_000, group: g2, disposition: .extraCopy),
        ]
        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.crossVolumeCount == 1 && sel.sameVolumeCount == 1)

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 1, "only the same-drive extra")
        #expect(result.skipped == 1, "the dropped working copy is reported as skipped (codex E)")
        #expect(FileManager.default.fileExists(atPath: cross.path), "cross-drive working copy retained")
        #expect(!FileManager.default.fileExists(atPath: sameE.path))
        #expect(FileManager.default.fileExists(atPath: k.path) && FileManager.default.fileExists(atPath: sameK.path))
    }

    /// QA test (b): a copy that lives in the Master Archive is never a
    /// working copy — skipped with the "Master Archive file" reason in ON
    /// mode, and the menu count agrees with the alert count (0).
    @Test func masterArchiveCopyIsSkippedInOnModeAndMenuAgrees() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let archiveRoot = rig.extraVol.appendingPathComponent("Breen_Family_Archive", isDirectory: true)
        rig.model.masterArchive = MasterArchiveDesignation(targetPath: rig.extraVol.path, rootPath: archiveRoot.path)
        let g = UUID()
        rig.model.records = [
            dupRecord(path: rig.keeperVol.appendingPathComponent("a.mov").path, group: g, disposition: .keep),
            dupRecord(path: archiveRoot.appendingPathComponent("1990s/a.mov").path, group: g, disposition: .extraCopy),
        ]
        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.isEmpty)
        #expect(sel.skippedReasons.map(\.reason) == [WorkingCopyCleanupText.reasonMasterArchiveFile])
        #expect(rig.model.volumesWithDeletableDuplicates().isEmpty, "menu count must equal alert count")
    }

    /// QA test (c): the master made unreadable AFTER planning → the
    /// byte-verify refuses, nothing deleted, nothing carried.
    @Test func unreadableMasterAfterSelectionRefusesAndCarriesNothing() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        rig.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let bytes = (0..<8_000).map { UInt8($0 % 11) }
        let k = rig.keeperVol.appendingPathComponent("a.mov"); write(k, bytes)
        let e = rig.extraVol.appendingPathComponent("a copy.mov"); write(e, bytes)
        let g = UUID()
        let keeper = dupRecord(path: k.path, size: 8_000, group: g, disposition: .keep)
        let extra = dupRecord(path: e.path, size: 8_000, group: g, disposition: .extraCopy)
        extra.starRating = 3
        rig.model.records = [keeper, extra]
        let sel = rig.model.duplicateDeletionSelection(onVolume: rig.extraVol.path)
        #expect(sel.targets.count == 1)
        // Planning is done and says "eligible"; now the master goes unreadable.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: k.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: k.path) }

        let result = await rig.model.deleteDuplicates(onVolume: rig.extraVol.path)
        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: e.path))
        #expect(keeper.starRating == 0, "nothing carried")
        #expect(extra.duplicateDisposition == .review)
    }

    /// Settings isolation: all duplicate-keeper settings round-trip through
    /// INJECTED defaults only; the model never reads/writes the real plist.
    @Test func toggleSettingRoundTripsInjectedDefaultsOnly() throws {
        let name = "DupCrossSettings-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        defer { d.removePersistentDomain(forName: name) }

        let realKeys = [
            DuplicateKeeperSettings.precedenceKey,
            DuplicateKeeperSettings.workingCopyCleanupKey,
            DuplicateKeeperSettings.lastElectionKey,
        ]
        let standard = UserDefaults.standard
        var originalValues: [String: Any] = [:]
        for key in realKeys {
            if let value = standard.object(forKey: key) {
                originalValues[key] = value
            }
        }
        defer {
            for key in realKeys {
                if let value = originalValues[key] {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }

        func realSnapshot() -> NSDictionary {
            var values: [String: Any] = [:]
            for key in realKeys {
                if let value = standard.object(forKey: key) {
                    values[key] = value
                }
            }
            return NSDictionary(dictionary: values)
        }

        let realBefore = realSnapshot()
        #expect(DuplicateKeeperSettings.restored(from: d) == DuplicateKeeperSettings())

        let token = UUID().uuidString
        var injected = DuplicateKeeperSettings()
        injected.volumePrecedence = ["TestA-\(token)", "TestB-\(token)"]
        injected.alsoCleanUpWorkingCopies = true
        injected.lastElectionDescriptor = "injected-election-\(token)"
        injected.save(to: d)
        #expect(DuplicateKeeperSettings.restored(from: d) == injected,
                "every setting must round-trip through the named suite")
        #expect(realBefore.isEqual(to: realSnapshot() as! [AnyHashable: Any]),
                "injected save changed a real duplicate-keeper preference")

        // Poison every real key with a non-default, run-unique value. The
        // model must still initialize from its test-host seed, then refuse
        // to write its own distinct values back to these poisoned keys.
        standard.set(["Poison-\(token)"], forKey: DuplicateKeeperSettings.precedenceKey)
        standard.set(true, forKey: DuplicateKeeperSettings.workingCopyCleanupKey)
        standard.set("poison-election-\(token)", forKey: DuplicateKeeperSettings.lastElectionKey)
        let poisonBeforeModel = realSnapshot()

        let model = VideoScanModel()
        #expect(model.duplicateKeeperSettings == DuplicateKeeperSettings(),
                "test-host model must use seed settings, never real preferences")
        model.duplicateKeeperSettings.volumePrecedence = ["Model-\(token)"]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = false
        model.duplicateKeeperSettings.lastElectionDescriptor = "model-election-\(token)"
        model.saveDuplicateKeeperSettings()
        #expect(poisonBeforeModel.isEqual(to: realSnapshot() as! [AnyHashable: Any]),
                "test-host model save changed a poisoned real preference")
    }

    /// The exact UI strings Rick specified — all in WorkingCopyCleanupText.
    @Test func exactLabelCaptionAndReasons() {
        #expect(WorkingCopyCleanupText.toggleLabel == "Also clean up working copies")
        #expect(WorkingCopyCleanupText.caption(volume: "CrucialX9")
                == "Removes copies on CrucialX9 whose asset already has a verified master on a more reliable drive. Files must match byte-for-byte; stars, people and notes move to the master.")
        #expect(WorkingCopyCleanupText.confirmation(total: 5, volume: "CrucialX9", sameDrive: 3, workingCopies: 2, masterVolumes: ["FamilyArchive", "LaCieWorkspace"])
                == "Remove 5 extra copies on CrucialX9: 3 same-drive extras + 2 working copies whose master is on FamilyArchive, LaCieWorkspace. Masters are never touched.")
        #expect(WorkingCopyCleanupText.logSummary(volume: "CrucialX9", detail: "x").hasPrefix("Working-copy cleanup on CrucialX9: "))
        #expect(WorkingCopyCleanupText.logRemoved(path: "/a", masterPath: "/b") == "[WORKING-COPY] removed /a — master /b")
        #expect(WorkingCopyCleanupText.reasonMasterOffline == "master offline")
        #expect(WorkingCopyCleanupText.reasonMasterNotMoreReliable == "master not more reliable")
        #expect(WorkingCopyCleanupText.reasonMasterRetired == "master retired")
        #expect(WorkingCopyCleanupText.reasonMasterArchiveFile == "Master Archive file")
    }

    /// Scale: 100k records, toggle ON, half the extras cross-drive —
    /// selection stays linear (per-keeper-root memo), budget 2 s.
    @Test("100k cross-volume selection stays linear", .timeLimit(.minutes(1)))
    func selectionScale100k() {
        let model = makeModel(URL(fileURLWithPath: NSTemporaryDirectory()))
        model.scanTargets = [target("/Volumes/LaCieWorkspace"), target("/Volumes/CrucialX9")]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        let gSame = UUID(), gCross = UUID()
        catalog.append(dupRecord(path: "/Volumes/CrucialX9/keeper.mov", group: gSame, disposition: .keep))
        catalog.append(dupRecord(path: "/Volumes/LaCieWorkspace/keeper.mov", group: gCross, disposition: .keep))
        for i in 2..<100_000 {
            catalog.append(dupRecord(path: "/Volumes/CrucialX9/copy-\(i).mov",
                                     group: i % 2 == 0 ? gSame : gCross, disposition: .extraCopy))
        }
        model.records = catalog

        let start = ContinuousClock.now
        let sel = model.duplicateDeletionSelection(onVolume: "/Volumes/CrucialX9")
        let menu = model.volumesWithDeletableDuplicates()
        let elapsed = start.duration(to: .now)

        #expect(sel.targets.count == 99_998)
        #expect(sel.sameVolumeCount == 49_999 && sel.crossVolumeCount == 49_999)
        #expect(menu.first?.count == 99_998)
        #expect(elapsed < .seconds(2), "100k cross-volume selection exceeded 2 s: \(elapsed)")
    }
}
