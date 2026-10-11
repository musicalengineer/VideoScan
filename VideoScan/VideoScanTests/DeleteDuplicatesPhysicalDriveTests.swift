// DeleteDuplicatesPhysicalDriveTests.swift
// "Different drives" means different PHYSICAL devices (Rick's ruling relayed
// 2026-10-03, after the codex #258 round found FamilyArchive and Projects —
// two volumes of ONE RAID — would count as two drives). The two-drives rule
// promises a person that one device failing cannot take every copy; two
// volumes of one device do not keep that promise.
//
// And the F5 class for the other bulk verbs: Workbench Discard asks the
// Read-only gate for each file at the moment it goes; Prune Apply, Junk
// Delete's sheet and Transcode's Replace Existing are pinned as already
// asking there.
//
// Dimensions: Logic (below) · Scale N/A (one lookup per volume per run,
// cached; nothing per record) · Media matrix N/A (synthetic bytes) ·
// Isolation (temp catalog and ledger; drive identity injected through
// `DuplicateDrives.identityOverride`; the Trash step injected) · Sensor
// (source pins at the end of each suite).
//
// Suites: DeleteDuplicatesPhysicalDriveTests · BulkVerbRemovalBoundaryTests

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_physdrive_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func scanTarget(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    return t
}

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 197) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// Volume A (st_dev 7) and volume B (st_dev 8, everything under `mnt/`).
/// `sameDevice`: both are volumes of ONE physical device; else two devices.
private func twoVolumes(sameDevice: Bool) -> @Sendable (String) -> DuplicateDrives.Identity? {
    { path in
        path.contains("/mnt/")
            ? .init(device: 8, kind: .physical, physicalDevice: sameDevice ? "test-raid" : "test-other", deviceLabel: "Test RAID")
            : .init(device: 7, kind: .physical, physicalDevice: "test-raid", deviceLabel: "Test RAID")
    }
}

@Suite("Delete Duplicates — a drive is a PHYSICAL device, not a volume", .serialized)
@MainActor
struct DeleteDuplicatesPhysicalDriveTests {

    struct Rig {
        let dir: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Volume A: keeper (verified), the copy to go, `near` (a verified
    /// Review sibling). Volume B (`mnt/`): `far`, a Review sibling —
    /// verified or not.
    private func makeRig(_ label: String, farVerified: Bool = true) -> Rig {
        let dir = tempDir(label)
        let mnt = dir.appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let group = UUID()
        func record(_ url: URL, _ disposition: DuplicateDisposition, verified: Bool) -> VideoRecord {
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = url.lastPathComponent
            r.directory = url.deletingLastPathComponent().path
            r.sizeBytes = Int64(fileSize)
            r.partialMD5 = "same"
            r.durationSeconds = 61
            r.duplicateGroupID = group
            r.duplicateDisposition = disposition
            r.duplicateConfidence = .high
            if verified { r.contentFixity = ContentFixity.captured(path: url.path, digest: fileDigest, byteCount: Int64(fileSize)) }
            return r
        }
        let model = makeModel(dir)
        model.scanTargets = [scanTarget(dir.path)]
        let keeper = record(dir.appendingPathComponent("keeper.mov"), .keep, verified: true)
        let copy = record(dir.appendingPathComponent("copy.mov"), .extraCopy, verified: false)
        model.records = [keeper, copy, record(dir.appendingPathComponent("near.mov"), .review, verified: true),
                         record(mnt.appendingPathComponent("far.mov"), .review, verified: farVerified)]
        return Rig(dir: dir, model: model, keeper: keeper, copy: copy)
    }

    private func run(_ rig: Rig) -> DeletionTierFacts {
        DeletionTierFacts.gather(rig.model.deletionTierCandidates(record: rig.copy, keeper: rig.keeper), digest: fileDigest)
    }

    /// The finding: three verified copies on TWO VOLUMES of ONE device are
    /// on one drive → the Trash. On two devices → an outright delete.
    @Test func twoVolumesOfOnePhysicalDeviceAreOneDrive() {
        let rig = makeRig("one"); defer { rig.cleanup() }
        let one = DuplicateDrives.$identityOverride.withValue(twoVolumes(sameDevice: true)) { run(rig) }
        #expect(one.remainingVerifiedCopies == 3, "fixture: keeper + near + far (\(one.summary))")
        #expect(one.distinctDriveCount == 1, "two volumes of one device counted as \(one.distinctDriveCount) drives: \(one.countedDrives)")
        #expect(DeletionTierDecision.decide(facts: one).tier == .trash)
        let two = DuplicateDrives.$identityOverride.withValue(twoVolumes(sameDevice: false)) { run(rig) }
        #expect(two.remainingVerifiedCopies == 3 && two.distinctDriveCount == 2)
        #expect(DeletionTierDecision.decide(facts: two).tier == .trash)
    }

    /// The forecast and the steward's proof count drives the same way.
    @Test func theForecastAndTheStewardCountPhysicalDevicesAsTheRunDoes() throws {
        for sameDevice in [true, false] {
            let rig = makeRig("equal"); defer { rig.cleanup() }
            try DuplicateDrives.$identityOverride.withValue(twoVolumes(sameDevice: sameDevice)) {
                let expected: DeletionTier = .trash
                #expect(DeletionTierDecision.decide(facts: run(rig)).tier == expected)
                let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path).bucket(for: rig.copy.id)
                #expect(forecast == .trash, "the forecast says \(String(describing: forecast)); the run \(expected)")
                let inputs = StewardCaseBuilder.project(rig.model.records, protection: rig.model.stewardProtectionRule())
                let queue = StewardCaseBuilder.build(inputs: inputs, volumes: AnalyzeCoverageCalculator.volumeFacts(rig.model.scanTargets),
                                                     mountedRoots: ["/"], alsoCleanUpWorkingCopies: false)
                let card = try #require(queue.cases.first { $0.kind == .reclaimGroup })
                let prepared = try #require(StewardEvidenceBuilder.prepare(model: rig.model, for: card))
                let question = try #require(prepared.questions.first { $0.copyID == rig.copy.id })
                let proof = StewardEvidenceBuilder.proof(question)
                #expect(proof.tier == expected && proof.remaining == 3, "the card says \(String(describing: proof.tier)); the run \(expected)")
            }
        }
    }

    /// Keep one (2026-10-09): no sibling is read to reach a second drive —
    /// on one device or two — and the forecast says the Trash either way.
    @Test func noSiblingIsReadForASecondDriveOnEitherDevice() {
        for sameDevice in [true, false] {
            let rig = makeRig("read", farVerified: false); defer { rig.cleanup() }
            DuplicateDrives.$identityOverride.withValue(twoVolumes(sameDevice: sameDevice)) {
                var candidates = rig.model.deletionTierCandidates(record: rig.copy, keeper: rig.keeper)
                let reads = SiblingProver.prove(&candidates, digest: fileDigest,
                                                allowance: .init(goal: SiblingProver.Allowance.goal,
                                                                 readablePaths: Set(candidates.otherCopies.map(\.path))),
                                                hooks: .live)
                #expect(reads.isEmpty, "\(sameDevice ? "one device" : "two devices"): \(reads.count) sibling read(s)")
                let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path)
                #expect(forecast.bucket(for: rig.copy.id) == .trash)
            }
        }
    }

    /// The reason NAMES the physical devices, so the ledger shows what the
    /// count rests on — and, on one device, which of its volumes.
    @Test func theReasonNamesThePhysicalDevicesAndTheirVolumes() {
        let dir = tempDir("words"); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["keeper.mov", "s1.mov", "s2.mov"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(fileBytes))
        }
        var c = DeletionTierCandidates()
        c.keeperPath = dir.appendingPathComponent("keeper.mov").path
        c.keeperLabel = "keeper"
        c.otherCopies = ["s1.mov", "s2.mov"].map {
            let path = dir.appendingPathComponent($0).path
            return .init(path: path, fixity: ContentFixity.captured(path: path, digest: fileDigest, byteCount: Int64(fileSize)), label: $0)
        }
        typealias Drive = DeletionTierFacts.Drive
        // One RAID, two of its volumes; then the same plus a second device.
        let raid = DeletionTierFacts.gather(c, digest: fileDigest) { path, _ in
            Drive(key: "disk:raid", label: path.hasSuffix("s2.mov") ? "TestProjects" : "TestArchive", model: "Test RAID")
        }
        #expect(raid.distinctDriveCount == 1 && raid.countedDrives.first?.name == "Test RAID [TestArchive, TestProjects]")
        let trash = DeletionTierDecision.decide(facts: raid)
        #expect(trash.tier == .trash)
        #expect(trash.reason.hasPrefix("to the Trash (3 verified remain: "), Comment(rawValue: trash.reason))
        #expect(trash.reason.contains(" — on 1 drive (Test RAID [TestArchive, TestProjects])"), Comment(rawValue: trash.reason))

        let two = DeletionTierFacts.gather(c, digest: fileDigest) { path, _ in
            path.hasSuffix("s1.mov") ? Drive(key: "disk:lacie", label: "TestLaCie", model: "Test d2")
                : Drive(key: "disk:raid", label: path.hasSuffix("s2.mov") ? "TestProjects" : "TestArchive", model: "Test RAID")
        }
        let permanent = DeletionTierDecision.decide(facts: two)
        #expect(permanent.tier == .trash, "Trash only: two devices are said, not rewarded")
        #expect(permanent.reason.contains("3 verified remain: keeper, s1.mov, s2.mov — on 2 drives (Test RAID [TestArchive, TestProjects] · TestLaCie)"),
                Comment(rawValue: permanent.reason))
        // One volume on one device: said as before, nothing added.
        let plain = DeletionTierFacts.gather(c, digest: fileDigest) { _, _ in Drive(key: "disk:x", label: "TestLaCie") }
        #expect(plain.summary.hasSuffix(" — on 1 drive"), Comment(rawValue: plain.summary))
        // At the boundary a dropped copy takes its VOLUME out of the name.
        try? Data([9]).write(to: dir.appendingPathComponent("s2.mov"))
        #expect(two.recheck().distinctDriveCount == 2 && raid.recheck().remainingVerifiedCopies == 2)
    }

    /// What DiskArbitration's description means, and the key built from it.
    @Test func theKeyIsThePhysicalDevicePath() {
        typealias D = DuplicateDrives
        let archive = D.identity(device: 23, model: "Test RAID", deviceProtocol: "SAS", devicePath: "IOService:/test/raid@0")
        let projects = D.identity(device: 24, model: "Test RAID", deviceProtocol: "SAS", devicePath: "IOService:/test/raid@0")
        let lacie = D.identity(device: 25, model: "Test d2", deviceProtocol: "USB", devicePath: "IOService:/test/usb@1")
        #expect(archive.kind == .physical && archive.deviceLabel == "Test RAID")
        #expect(D.key(for: archive) == D.key(for: projects), "two volumes of one device must share ONE key")
        #expect(D.key(for: archive) != D.key(for: lacie) && D.key(for: archive).hasPrefix("disk:") && D.key(for: archive).count == 17)
        // No device path: it cannot be told apart from a sibling volume — unknown, never a drive.
        #expect(D.identity(device: 26, model: "Test d2", deviceProtocol: "USB", devicePath: nil).kind == .unknown)
        #expect(D.identity(device: 26, model: "Test d2", deviceProtocol: "USB", devicePath: "").kind == .unknown)
        #expect(D.identity(device: 27, model: "Disk Image", deviceProtocol: "Virtual Interface", devicePath: "IOService:/test/image").kind == .diskImage)
        // A test's identity (no device given): the volume number stands in.
        #expect(D.key(for: .init(device: 7, kind: .physical)) == "dev:7")
        #expect(D.key(for: .init(device: 7, kind: .network, physicalDevice: "net://server/share"))
                != D.key(for: .init(device: 8, kind: .network, physicalDevice: "net://server/other")))
    }

    /// One DiskArbitration lookup per volume per run.
    @Test func theVolumeLookupIsCachedForTheRun() {
        var cache = DuplicateDrives.VolumeCache()
        var asked = 0
        func lookup(_ key: String) -> DuplicateDrives.Identity {
            cache.identity(for: key) { asked += 1; return .init(device: 7, kind: .physical, physicalDevice: "p") }
        }
        _ = lookup("7|/dev/disk7s1"); _ = lookup("7|/dev/disk7s1"); _ = lookup("7|/dev/disk7s1")
        #expect(asked == 1 && cache.lookups == 1)
        _ = lookup("7|/dev/disk9s1")
        #expect(asked == 2, "a device node handed to another volume is asked about again")
        cache.removeAll()
        _ = lookup("7|/dev/disk7s1")
        #expect(asked == 3 && cache.entries.count == 1)
    }

    /// On THIS machine: the boot volume and the user-data volume are two
    /// volumes (two st_dev) of one internal device — one drive. (Where the
    /// disk is virtual — a CI runner — neither is a drive at all.)
    @Test func theBootVolumeAndTheDataVolumeAreOneDrive() {
        var root = stat(), home = stat()
        guard stat("/", &root) == 0, stat(NSHomeDirectory(), &home) == 0 else { return }
        let a = DuplicateDrives.liveIdentityCached(forPath: "/", device: UInt64(root.st_dev), volumeUUID: VolumeIdentity.uuid(forPath: "/"))
        let b = DuplicateDrives.liveIdentityCached(forPath: NSHomeDirectory(), device: UInt64(home.st_dev),
                                             volumeUUID: VolumeIdentity.uuid(forPath: NSHomeDirectory()))
        #expect(a.kind != .network && b.kind != .network)
        if a.kind == .physical, b.kind == .physical {
            #expect(a.physicalDevice != nil && DuplicateDrives.key(for: a) == DuplicateDrives.key(for: b),
                    "two volumes of the internal disk counted as two drives")
        }
    }

    @Test func theSourcesKeyByDeviceAndTheInvariantSaysSo() throws {
        let drives = try SourceTree.appCode(named: "DeleteDuplicatesDrives.swift")
        #expect(drives.contains("devicePath: description[kDADiskDescriptionDevicePathKey as String] as? String)"))
        #expect(drives.contains("DeletionTierFacts.Drive(key: key(for: identity),"), "a drive is keyed by the volume again")
        #expect(drives.contains("guard let devicePath, !devicePath.isEmpty else { return Identity(device: device, kind: .unknown) }"))
        #expect(drives.contains("return Identity(device: device, kind: .network, physicalDevice: \"net:\" + mount.node)"),
                "a network share is one drive per server + share")
        #expect(try SourceTree.appCode(named: "DeleteDuplicatesJob.swift").contains("DuplicateDrives.resetVolumeCache()"))
        #expect(try SourceTree.appCode(named: "VideoScanModel+ArchiveVolumeSnapshot.swift").contains("DuplicateDrives.resetVolumeCache()"))
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("A \"drive\" is a PHYSICAL DEVICE") && invariants.contains("are ONE drive"))
        #expect(invariants.contains("a hardware RAID presents as ONE device and counts as one drive")
                && invariants.contains("redundancy is NOT a second drive"))
    }
}

// MARK: - The F5 class: every bulk verb asks at the moment a file goes

@Suite("Bulk remove verbs — the Read-only gate is asked when each file goes", .serialized)
@MainActor
struct BulkVerbRemovalBoundaryTests {

    /// Workbench Discard: the file's OWN volume is the marked drive (mounted
    /// under a name the snapshot never saw — the path says nothing). The
    /// removal-time check must stop it, as it does for every other verb.
    @Test func discardAsksTheFilesOwnVolumeBeforeItTrashesIt() async {
        let dir = tempDir("discard"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let marked = scanTarget("/Volumes/TestMarked")
        marked.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: "TEST-U")
        model.scanTargets = [marked, scanTarget(dir.path)]
        func item(_ name: String) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = name
            r.directory = dir.path
            r.sizeBytes = 3
            return r
        }
        let onMarkedDrive = item("on-marked.mov"), free = item("free.mov")
        model.records = [onMarkedDrive, free]
        var trashed: [String] = []
        let count = MasterArchiveDesignation.$volumeUUIDProbe.withValue({ $0.hasSuffix("on-marked.mov") ? "TEST-U" : "TEST-FREE" }) {
            ArchiveVolumeProtection.$mountIdentityProbe.withValue({ _ in nil }) {
                model.discardWorkbench([onMarkedDrive, free]) { trashed.append($0.lastPathComponent) }
            }
        }
        #expect(trashed == ["free.mov"], "a file on the Read-only drive went to the Trash: \(trashed)")
        #expect(count == 1 && !onMarkedDrive.isPurged && onMarkedDrive.lifecycleStage != .trashed && free.isPurged)
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce
        #expect(model.dashboard.consoleLines.joined(separator: "\n")
            .contains("Discard: left 1 file(s) alone — they live on TestMarked, which you marked Read only."))
    }

    /// Transcode's Replace Existing: the publish itself asks the removal
    /// check for the file it would Trash (pinned; it already did).
    @Test func transcodeReplaceAsksAtThePublish() throws {
        let dir = tempDir("publish"); defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_x.vs.edit.mov")
        let partial = DerivativeOutputPublish.uniquePartialURL(for: final)
        try Data([1]).write(to: final)
        try Data([2]).write(to: partial)
        let readOnly = ReadOnlyVolumeProtection.provisional(marks: [.init(searchPath: dir.path, volumeUUID: nil)])
        let check = ArchiveRemovalCheck(protection: nil, probe: { _ in nil }, identity: { _ in nil }, readOnly: readOnly)
        let trashCalls = Counter()
        let outcome = try DerivativeOutputPublish.publish(partial: partial.path, as: final, policy: .replaceViaTrash,
                                                          archiveCheck: check, trash: { _ in trashCalls.bump(); return nil })
        #expect(trashCalls.value == 0 && (try? Data(contentsOf: final)) == Data([1]), "the existing file on a Read-only drive was replaced")
        guard case .publishedBeside(_, _, let reason) = outcome else {
            Issue.record("expected the new output beside the kept file, got \(outcome)")
            return
        }
        #expect(reason.contains("which you marked Read only"), Comment(rawValue: reason))
    }

    /// Sensors: each bulk remove verb's removal site asks the gate there.
    @Test func everyBulkVerbAsksTheGateWhereTheFileGoes() throws {
        // Workbench Discard: the removal-time check, per file, before the Trash.
        let discard = try SourceTree.appCode(named: "VideoScanModel+Workbench.swift")
        let loop = try #require(discard.range(of: "for rec in recs {"))
        let trash = try #require(discard.range(of: "if (try? trash(url)) != nil", range: loop.upperBound..<discard.endIndex))
        #expect(String(discard[loop.upperBound..<trash.lowerBound]).contains("if let held = archiveRemovalCheck()?.bulkRefusal(forPath: rec.fullPath) {"),
                "Discard no longer asks the gate for each file before it trashes it")
        // Junk Delete's sheet and Prune Apply both move files ONLY through
        // deleteConfirmedJunk, whose loop re-reads the marks for every file.
        // The sheet runs its FROZEN set (design R1, 2026-10-09).
        #expect(try SourceTree.appCode(named: "JunkDeleteAction.swift").contains("await model.trashFrozenJunk(snapshot)"))
        #expect(try SourceTree.appCode(named: "VideoScanModel+JunkTrashSnapshot.swift")
                    .contains("await deleteConfirmedJunk(snapshot.items.map(\\.record), mode: .toTrash, guard: fileGuard)"))
        let prune = try SourceTree.appCode(named: "VideoScanModel+PruneApply.swift")
        #expect(prune.contains("let result = await deleteConfirmedJunk([rec], mode: mode, guard: fileGuard)"))
        #expect(prune.contains("if let refusal = bulkDeleteRefusal(rec, volume: archiveVolume) {"), "each copy is asked at its turn too")
        for file in ["JunkDeleteAction.swift", "VideoScanModel+JunkTrashSnapshot.swift", "VideoScanModel+PruneApply.swift", "VideoScanModel+Workbench.swift"] {
            let text = try SourceTree.appCode(named: file)
            #expect(!text.contains("removeItem(") && !text.contains("FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil"),
                    "\(file) removes a media file on its own")
        }
        let junk = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        // Asked again for EVERY file, at its turn, on the main actor.
        #expect(junk.contains("readOnlyVolumes: readOnlyVolumeProtection()"))
        #expect(junk.contains("let archiveVolume = archiveVolumeProtection()"), "the archive too, per file (codex F3)")
        #expect(junk.contains("disk.run(path: path, protections: protections, catalogBytes: catalogBytes)"))
        // Transcode's Replace Existing: policy and check are taken AT the
        // publish, and the publish asks the check for the file it would Trash.
        let transcode = try SourceTree.appCode(named: "TranscodeJob.swift")
        #expect(transcode.contains("partial: partialPath, final: outputURL, policy: existingFilePolicy(),\n                archiveCheck: model?.archiveRemovalCheck(), trash: DerivativeOutputPublish.trashItem)"))
        #expect(try SourceTree.appCode(named: "DerivativeOutputPublish.swift").contains("} else if let note = archiveCheck?.refusalNote(forPath: final.path) {"))
    }
}
