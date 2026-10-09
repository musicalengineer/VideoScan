// ReadOnlyVolumeTests.swift
// "Read only" volumes (Rick 2026-10-03): "select a volume and mark it Read
// only as a way to keep it off the delete list. Just a safety feature."
//
// A read-only volume is one where VideoScan's bulk verbs never remove,
// trash, move out or replace a file — through the ONE gate
// (`bulkDeleteRefusal`). Its files STILL COUNT as surviving copies.
//
// Dimensions: Logic (the snapshot's identity rules, the gate, each verb) ·
// Scale (100k selection with a marked drive, the selection's 2 s budget) ·
// Media matrix N/A (no media opened; synthetic bytes) · Isolation (every
// verb is run against a POISONED state — the volume marked Read only — on
// temp files; per-test defaults keys; nothing reads the machine's drives:
// UUID probes are injected) · Sensor (every bulk remove verb goes through
// the gate; the gate has the read-only half).
//
// Suites: ReadOnlyVolumeSnapshotTests · ReadOnlyVolumeGateTests ·
//         ReadOnlyVolumeSettingsTests · ReadOnlyVolumeSensorTests

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_readonly_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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
private func target(_ path: String, readOnly: Bool = false, uuid: String? = nil) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    if readOnly { t.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(timeIntervalSince1970: 1_790_000_000), volumeUUID: uuid) }
    return t
}

@MainActor
private func dupRecord(path: String, size: Int64 = 1, group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private let fileSize = FileHasher.segmentSize * 2

// MARK: - The snapshot (pure; UUID probes injected)

@Suite("Read-only volumes — which paths are protected, and whose drive it is")
struct ReadOnlyVolumeSnapshotTests {

    typealias P = ReadOnlyVolumeProtection

    private func make(_ marks: [P.Mark], mounted: [String: String]) -> P {
        P.make(marks: marks, mountedRoots: { Array(mounted.keys).sorted() }, probe: { mounted[$0] })
    }

    @Test func theMarkedDriveAtItsNameIsProtectedAndItsNeighboursAreNot() {
        let p = make([.init(searchPath: "/Volumes/SanDisk", volumeUUID: "AAA")], mounted: ["/Volumes/SanDisk": "AAA", "/Volumes/X9": "BBB"])
        #expect(p.verdict(forPath: "/Volumes/SanDisk/tapes/a.mov") == .readOnly("SanDisk"))
        #expect(p.verdict(forPath: "/volumes/sandisk/a.mov") == .readOnly("SanDisk"), "the volume is case-insensitive")
        #expect(p.verdict(forPath: "/Volumes/SanDisk/../SanDisk/a.mov") == .readOnly("SanDisk"))
        #expect(p.verdict(forPath: "/System/Volumes/Data/Volumes/SanDisk/a.mov") == .readOnly("SanDisk"), "the firmlink spelling")
        #expect(p.verdict(forPath: "/Volumes/SanDisk2/a.mov") == nil, "a drive whose name merely starts the same")
        #expect(p.verdict(forPath: "/Volumes/X9/a.mov") == nil && p.verdict(forPath: "/Users/x/Movies/a.mov") == nil)
        #expect(p.isBuilt && !p.isEmpty)
        #expect(P.none.verdict(forPath: "/Volumes/SanDisk/a.mov") == nil && P.none.isEmpty)
    }

    /// Unmounted: the catalog's rows still carry the marked path — refused
    /// by string, with no disk access at all (the provisional snapshot too).
    @Test func anUnmountedReadOnlyDriveStaysProtected() {
        let marks: [P.Mark] = [.init(searchPath: "/Volumes/SanDisk", volumeUUID: "AAA")]
        let away = make(marks, mounted: ["/Volumes/X9": "BBB"])
        #expect(away.verdict(forPath: "/Volumes/SanDisk/a.mov") == .readOnly("SanDisk"))
        #expect(away.verdict(forPath: "/Volumes/X9/a.mov") == nil)
        let provisional = P.provisional(marks: marks)
        #expect(!provisional.isBuilt)
        #expect(provisional.verdict(forPath: "/Volumes/SanDisk/a.mov") == .readOnly("SanDisk"),
                "nothing reads ‘not read-only’ because a build is late")
    }

    /// The flag follows the DRIVE: the same disk mounted under another name
    /// is protected there — and at its marked name.
    @Test func theMarkedDriveMountedUnderAnotherNameIsProtectedThere() {
        let p = make([.init(searchPath: "/Volumes/SanDisk", volumeUUID: "AAA")], mounted: ["/Volumes/SanDisk 1": "AAA", "/Volumes/X9": "BBB"])
        #expect(p.verdict(forPath: "/Volumes/SanDisk 1/a.mov") == .readOnly("SanDisk"))
        #expect(p.verdict(forPath: "/Volumes/SanDisk/a.mov") == .readOnly("SanDisk"))
        #expect(p.verdict(forPath: "/Volumes/X9/a.mov") == nil)
    }

    /// A DIFFERENT drive mounted under the marked name does not inherit the
    /// flag silently: paths there are still left alone, with their own words.
    @Test func aDifferentDriveUnderTheMarkedNameIsRefusedInItsOwnWords() {
        let p = make([.init(searchPath: "/Volumes/SanDisk", volumeUUID: "AAA")], mounted: ["/Volumes/SanDisk": "ZZZ", "/Volumes/Old": "AAA"])
        #expect(p.verdict(forPath: "/Volumes/SanDisk/a.mov") == .readOnlyDifferentDrive("SanDisk"))
        #expect(p.verdict(forPath: "/Volumes/Old/a.mov") == .readOnly("SanDisk"), "the marked drive itself, found by its identity")
        #expect(VideoScanModel.readOnlyRefusalNote(.readOnlyDifferentDrive("SanDisk"))
                == "is under SanDisk, which you marked Read only — a different drive is mounted there now, so it is left alone")
        #expect(VideoScanModel.readOnlyRefusalNote(.readOnly("SanDisk")) == "lives on SanDisk, which you marked Read only")
    }

    /// No UUID on the mark (the drive was away when it was marked, or it
    /// reports none): the path is the whole identity.
    @Test func aMarkWithNoIdentityProtectsItsPath() {
        let p = make([.init(searchPath: "/Volumes/NoUUID", volumeUUID: nil)], mounted: ["/Volumes/NoUUID": "QQQ"])
        #expect(p.verdict(forPath: "/Volumes/NoUUID/a.mov") == .readOnly("NoUUID"))
    }

    /// A scan target that is a FOLDER: the folder is protected — on the
    /// renamed mount too — never the rest of the volume.
    @Test func aMarkedFolderProtectsTheFolderOnly() {
        let sub = make([.init(searchPath: "/Volumes/LaCie/Tapes", volumeUUID: "AAA")], mounted: ["/Volumes/LaCie 1": "AAA"])
        #expect(sub.verdict(forPath: "/Volumes/LaCie/Tapes/a.mov") == .readOnly("LaCie"))
        #expect(sub.verdict(forPath: "/Volumes/LaCie 1/Tapes/a.mov") == .readOnly("LaCie"))
        #expect(sub.verdict(forPath: "/Volumes/LaCie/Other/a.mov") == nil && sub.verdict(forPath: "/Volumes/LaCie 1/Other/a.mov") == nil)
        #expect(sub.verdict(forPath: "/Volumes/LaCie/TapesOld/a.mov") == nil)
        // On the boot disk: the folder; the UUID (shared by every boot file) is not kept.
        let boot = make([.init(searchPath: "/Users/someone/Movies", volumeUUID: "BOOT")], mounted: [:])
        #expect(boot.verdict(forPath: "/Users/someone/Movies/a.mov") == .readOnly("Movies"))
        #expect(boot.verdict(forPath: "/Users/someone/Music/a.mov") == nil)
        #expect(boot.entries.first?.volumeUUID == nil)
        // "/" is never a mark.
        #expect(make([.init(searchPath: "/", volumeUUID: nil)], mounted: [:]).isEmpty)
    }

    /// N1008-T-Archive-F6: a marked FOLDER, the file on the marked drive
    /// (its UUID reads U) under a mount name the snapshot never saw, and the
    /// file's place on that drive cannot be read (identity nil) — where on
    /// the drive it sits is unknown, so it is refused, never guessed clear.
    @Test func aMarkedFolderOnTheMarkedDriveWithAnUnknownPlaceIsRefused() {
        let p = make([.init(searchPath: "/Volumes/LaCie/Tapes", volumeUUID: "UUU")], mounted: [:])
        let none: (String) -> MountIdentity? = { _ in nil }
        #expect(p.verdict(forPath: "/Volumes/LaCie 1/Tapes/a.mov") == nil, "fixture: the string verdict alone must not decide")
        #expect(p.verdictAtRemoval(path: "/Volumes/LaCie 1/Tapes/a.mov", probe: { _ in "UUU" }, identity: none) != nil)
        // Another drive (UUID proven different) is still cleared.
        #expect(p.verdictAtRemoval(path: "/Volumes/LaCie 1/Tapes/a.mov", probe: { _ in "VVV" }, identity: none) == nil)
    }

    /// The last word at removal: the file's OWN volume identity — the marked
    /// drive mounted since the snapshot, under a name it never saw.
    @Test func atRemovalTheFilesOwnVolumeIdentityIsAsked() {
        let p = make([.init(searchPath: "/Volumes/SanDisk", volumeUUID: "AAA")], mounted: [:])
        let none: (String) -> MountIdentity? = { _ in nil }
        #expect(p.verdictAtRemoval(path: "/Volumes/Surprise/a.mov", probe: { _ in "AAA" }, identity: none) == .readOnly("SanDisk"))
        #expect(p.verdictAtRemoval(path: "/Volumes/Surprise/a.mov", probe: { _ in "BBB" }, identity: none) == nil)
        #expect(p.verdictAtRemoval(path: "/Volumes/SanDisk/a.mov", probe: { _ in nil }, identity: none) == .readOnly("SanDisk"))
        // A symlinked parent that really lives on the marked drive.
        let viaLink = p.verdictAtRemoval(path: "/Users/x/link/a.mov", probe: { _ in nil },
                                         identity: { $0 == "/Users/x/link/a.mov" ? MountIdentity(resolvedPath: "/Volumes/SanDisk/real/a.mov", mountPoint: "/Volumes/SanDisk") : nil })
        #expect(viaLink == .readOnly("SanDisk"))
        // The removal check carries it, with or without a Master Archive.
        let check = ArchiveRemovalCheck(protection: nil, probe: { _ in nil }, identity: { _ in nil }, readOnly: p)
        #expect(check.refusal(forPath: "/Volumes/SanDisk/a.mov")?.note == "lives on SanDisk, which you marked Read only")
        #expect(check.refusal(forPath: "/Volumes/SanDisk/a.mov")?.transient == false)
        // MORE CONSERVATIVE since codex #258 r5-4: a file whose own drive
        // identity cannot be read (no UUID, no mount) is not cleared while a
        // mark carries a UUID — it may be the marked drive under a new name.
        // A drive proven to be another one by its UUID still is.
        #expect(check.refusal(forPath: "/Volumes/X9/a.mov")?.leavesAlone == true)
        #expect(check.refusal(forPath: "/Volumes/X9/a.mov")?.note.contains("could not read this drive's identity") == true)
        let other = ArchiveRemovalCheck(protection: nil, probe: { _ in "BBB" }, identity: { _ in nil }, readOnly: p)
        #expect(other.refusal(forPath: "/Volumes/X9/a.mov") == nil)
    }
}

// MARK: - The gate and every verb behind it (poisoned state: the volume is marked)

@Suite("Read-only volumes — no bulk verb removes anything there", .serialized)
@MainActor
struct ReadOnlyVolumeGateTests {

    @Test func theGateRefusesAMarkedVolumeWithOrWithoutAMasterArchive() async {
        let model = makeModel(tempDir("gate"))
        model.scanTargets = [target("/Volumes/SanDisk", readOnly: true), target("/Volumes/X9")]
        let g = UUID()
        let onRO = dupRecord(path: "/Volumes/SanDisk/a.mov", group: g, disposition: .extraCopy)
        let onRW = dupRecord(path: "/Volumes/X9/a.mov", group: g, disposition: .extraCopy)
        #expect(model.masterArchive == nil)
        #expect(model.bulkDeleteRefusal(onRO) == .readOnlyVolume("SanDisk"))
        #expect(model.bulkDeleteRefusal(forPath: "/Volumes/SanDisk/new.mov") == .readOnlyVolume("SanDisk"))
        #expect(model.bulkDeleteRefusal(onRW) == nil)
        // A catalog-only removal touches no file: not refused.
        #expect(model.bulkDeleteRefusal(onRO, effect: .catalogRemoval) == nil && model.bulkDeleteRefusal(onRO, effect: .catalogOnly) == nil)
        #expect(model.recordsBulkVerbsMayRemove([onRO, onRW]).map(\.id) == [onRW.id])
        #expect(model.excludingMasterArchiveFiles([onRO, onRW], verb: "Delete Confirmed Junk").map(\.id) == [onRW.id])
        #expect(VideoScanModel.readOnlyVolumeRefusalLine(verb: "Delete Confirmed Junk", count: 1, volume: "SanDisk")
                == "Delete Confirmed Junk: left 1 file(s) alone — they live on SanDisk, which you marked Read only.")
        let console = await consoleText(model)
        #expect(console.contains("Delete Confirmed Junk: left 1 file(s) alone — they live on SanDisk, which you marked Read only."))
        #expect(!console.contains("/Volumes/SanDisk/a.mov"), "the refusal line names the volume, never a media path")

        // With a Master Archive designated, both halves speak.
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                       rootPath: "/Volumes/FamilyArchive/Test_Family_Archive", volumeUUID: nil)
        #expect(model.bulkDeleteRefusal(onRO) == .readOnlyVolume("SanDisk"))
        #expect(model.bulkDeleteRefusal(forPath: "/Volumes/FamilyArchive/loose/a.mov") == .archiveVolume)
        // Allow changes again → an ordinary drive.
        model.scanTargets[0].readOnlyMark = nil
        #expect(model.bulkDeleteRefusal(onRO) == nil)
    }

    @Test func deleteDuplicatesNeverSelectsOrOffersAReadOnlyDrive() {
        let model = makeModel(tempDir("dupsel"))
        model.scanTargets = [target("/Volumes/SanDisk", readOnly: true), target("/Volumes/X9")]
        let g = UUID(), h = UUID()
        model.records = [dupRecord(path: "/Volumes/SanDisk/keeper.mov", group: g, disposition: .keep),
                         dupRecord(path: "/Volumes/SanDisk/copy.mov", group: g, disposition: .extraCopy),
                         dupRecord(path: "/Volumes/X9/keeper.mov", group: h, disposition: .keep),
                         dupRecord(path: "/Volumes/X9/copy.mov", group: h, disposition: .extraCopy)]
        let selection = model.duplicateDeletionSelection(onVolume: "/Volumes/SanDisk")
        #expect(selection.targets.isEmpty && selection.skippedCount == 1)
        #expect(selection.skippedReasons.map(\.reason) == ["on SanDisk, which you marked Read only"])
        #expect(model.volumesWithDeletableDuplicates().map(\.path) == ["/Volumes/X9"], "the read-only drive is not on the delete list")
        #expect(model.readOnlyVolumeNamesForPicker == ["SanDisk"], "…and the picker lists it, not choosable")
        #expect(VolumeReadOnlyText.pickerRow("SanDisk") == "SanDisk — Read only: nothing here is ever removed")
        #expect(model.deleteDuplicatesForecast(onVolume: "/Volumes/SanDisk").total.files == 0)
    }

    private struct Rig {
        let dir: URL
        let ro: URL
        let rw: URL
        let model: VideoScanModel
        let digest: String
        let bytes: [UInt8]
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Two "drives" (folders with their own scan targets): `ro` and `rw`.
    private func makeRig(_ label: String) -> Rig {
        let dir = tempDir(label)
        let ro = dir.appendingPathComponent("ro", isDirectory: true), rw = dir.appendingPathComponent("rw", isDirectory: true)
        for d in [ro, rw] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let bytes = (0..<fileSize).map { UInt8($0 % 191) }
        let model = makeModel(dir)
        model.scanTargets = [target(ro.path), target(rw.path)]
        return Rig(dir: dir, ro: ro, rw: rw, model: model,
                   digest: SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }

    private func file(_ rig: Rig, _ url: URL, group: UUID, _ disposition: DuplicateDisposition, evidence: Bool = true) -> VideoRecord {
        FileManager.default.createFile(atPath: url.path, contents: Data(rig.bytes))
        let r = dupRecord(path: url.path, size: Int64(fileSize), group: group, disposition: disposition)
        if evidence { r.contentFixity = ContentFixity.captured(path: url.path, digest: rig.digest, byteCount: Int64(fileSize)) }
        return r
    }

    /// The whole job on a drive marked Read only: nothing is planned,
    /// nothing is removed. And marked AFTER the plan was made: every row is
    /// left alone at its turn — not refused, not re-marked Review.
    @Test func deleteDuplicatesRemovesNothingOnAReadOnlyDrive() async throws {
        let rig = makeRig("dupjob"); defer { rig.cleanup() }
        let g = UUID()
        let keeper = file(rig, rig.ro.appendingPathComponent("keeper.mov"), group: g, .keep)
        let copy = file(rig, rig.ro.appendingPathComponent("copy.mov"), group: g, .extraCopy)
        rig.model.records = [keeper, copy]
        addVerifiedArchiveFamily(to: rig.model, keeper: keeper, in: rig.rw)
        let hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)

        // Planned while the drive still allowed changes…
        let plan = try #require(await rig.model.prepareDuplicateDeletion(onVolume: rig.ro.path))
        #expect(plan.entries.map(\.id) == [copy.id], "fixture: an ordinary deletable copy")
        // …then marked Read only.
        rig.model.setVolumeReadOnly(true, for: rig.model.scanTargets[0])
        #expect(rig.model.scanTargets[0].readOnlyMark != nil && rig.model.isVolumeReadOnly(rig.model.scanTargets[0]))
        let name = rig.ro.lastPathComponent
        let resumed = DeleteDuplicatesJob(model: rig.model, resuming: plan, hooks: hooks, planRoot: rig.dir.appendingPathComponent("plans"))
        resumed.start()
        await resumed.task?.value
        let row = try #require(resumed.plan?.entries.first)
        #expect(row.status == .skipped && row.note == "left alone — lives on \(name), which you marked Read only", "\(row.status): \(row.note)")
        #expect(copy.duplicateDisposition == .extraCopy, "left alone is not a refusal")

        // A fresh run plans nothing there.
        let fresh = DeleteDuplicatesJob(model: rig.model, volumePath: rig.ro.path, hooks: hooks, planRoot: rig.dir.appendingPathComponent("plans2"))
        fresh.start()
        await fresh.task?.value
        #expect(fresh.plan?.entries.isEmpty == true && fresh.result.deleted == 0 && fresh.result.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: copy.fullPath) && FileManager.default.fileExists(atPath: keeper.fullPath))
        #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash").path))
        #expect(rig.model.records.contains { $0 === copy })
    }

    /// Read-only is NOT "ignore": a copy on the read-only drive still counts
    /// as a surviving copy when ANOTHER drive is cleaned up.
    @Test func aCopyOnAReadOnlyDriveStillCountsWhenAnotherDriveIsCleanedUp() async throws {
        let rig = makeRig("counts"); defer { rig.cleanup() }
        rig.model.scanTargets[0].readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        let g = UUID()
        let keeper = file(rig, rig.rw.appendingPathComponent("keeper.mov"), group: g, .keep)
        let copy = file(rig, rig.rw.appendingPathComponent("copy.mov"), group: g, .extraCopy, evidence: false)
        let onReadOnly = file(rig, rig.ro.appendingPathComponent("sibling.mov"), group: g, .review)
        rig.model.records = [keeper, copy, onReadOnly]

        let candidates = rig.model.deletionTierCandidates(record: copy, keeper: keeper)
        #expect(candidates.otherCopies.map(\.recordID) == [onReadOnly.id])
        #expect(DeletionTierFacts.gather(candidates, digest: rig.digest).remainingVerifiedCopies == 2,
                "keeper + the copy on the read-only drive")
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.rw.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir),
                                      planRoot: rig.dir.appendingPathComponent("plans"))
        job.start()
        await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("sibling sibling.mov on ") == true)
        #expect(FileManager.default.fileExists(atPath: onReadOnly.fullPath), "the read-only drive's copy is never touched")
    }

    /// Move to Trash / ⌘⌫ and Delete Confirmed Junk (both modes), and the
    /// Workbench's Discard: nothing leaves a Read-only drive; the row stays.
    @Test func moveToTrashJunkDeleteAndDiscardLeaveAReadOnlyDriveAlone() async throws {
        let rig = makeRig("verbs"); defer { rig.cleanup() }
        rig.model.scanTargets[0].readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        func plain(_ url: URL) -> VideoRecord {
            FileManager.default.createFile(atPath: url.path, contents: Data(rig.bytes))
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = url.lastPathComponent
            r.directory = url.deletingLastPathComponent().path
            r.sizeBytes = Int64(fileSize)
            r.durationSeconds = 61
            r.mediaDisposition = .confirmedJunk
            return r
        }
        let a = plain(rig.ro.appendingPathComponent("a.mov")), b = plain(rig.ro.appendingPathComponent("b.mov"))
        let c = plain(rig.ro.appendingPathComponent("c.mov")), d = plain(rig.ro.appendingPathComponent("d.mov"))
        rig.model.records = [a, b, c, d]

        let trashed = await rig.model.trashSelectedRecords([a])
        #expect(trashed.succeeded == 0)
        #expect(rig.model.catalogTrashPlan(for: [a]).toTrash.isEmpty)
        let toTrash = await rig.model.deleteConfirmedJunk([b], mode: .toTrash)
        let permanent = await rig.model.deleteConfirmedJunk([c], mode: .permanent)
        #expect(toTrash.succeeded == 0 && toTrash.attempted == 0 && permanent.succeeded == 0 && permanent.attempted == 0)
        #expect(rig.model.discardWorkbench([d]) == 0)
        for r in [a, b, c, d] {
            #expect(FileManager.default.fileExists(atPath: r.fullPath), "\(r.filename) left a Read-only drive")
            #expect(!r.isPurged && r.lifecycleStage != .trashed)
        }
        let name = rig.ro.lastPathComponent
        let console = await consoleText(rig.model)
        for verb in ["Move to Trash", "Delete Confirmed Junk", "Discard"] {
            #expect(console.contains("\(verb): left 1 file(s) alone — they live on \(name), which you marked Read only."), "\(verb)")
        }
        // The same verbs on the drive that allows changes still work.
        let free = plain(rig.rw.appendingPathComponent("free.mov"))
        rig.model.records.append(free)
        #expect(rig.model.bulkDeleteRefusal(free) == nil)
    }

    /// The last word on the disk thread: Delete Confirmed Junk's own loop
    /// asks the read-only snapshot again for each file.
    @Test func theRemovalTimeCheckRefusesAFileOnAReadOnlyDrive() {
        let p = ReadOnlyVolumeProtection.make(marks: [.init(searchPath: "/Volumes/SanDisk", volumeUUID: nil)],
                                              mountedRoots: { [] }, probe: { _ in nil })
        let verdict = p.verdictAtRemoval(path: "/Volumes/SanDisk/a.mov", probe: { _ in nil }, identity: { _ in nil })
        #expect(verdict.map(VideoScanModel.readOnlyRefusalNote) == "lives on SanDisk, which you marked Read only")
    }

    /// The steward: no Reclaim card for a Read-only drive; its copies are
    /// "never offered", and the set's card says how many and why.
    @Test func theStewardNeverOffersCopiesOnAReadOnlyDrive() throws {
        let model = makeModel(tempDir("steward"))
        model.scanTargets = [target("/Volumes/SanDisk", readOnly: true), target("/Volumes/X9")]
        let g = UUID()
        let keeper = dupRecord(path: "/Volumes/X9/keeper.mov", size: 100, group: g, disposition: .keep)
        let free = dupRecord(path: "/Volumes/X9/free.mov", size: 100, group: g, disposition: .extraCopy)
        let ro1 = dupRecord(path: "/Volumes/SanDisk/one.mov", size: 100, group: g, disposition: .extraCopy)
        let ro2 = dupRecord(path: "/Volumes/SanDisk/two.mov", size: 100, group: g, disposition: .extraCopy)
        model.records = [keeper, free, ro1, ro2]
        #expect(model.stewardProtectionRule()(ro1) == .readOnlyDrive)
        let inputs = StewardCaseBuilder.project(model.records, protection: model.stewardProtectionRule())
        let queue = StewardCaseBuilder.build(inputs: inputs, volumes: [], mountedRoots: ["/"], alsoCleanUpWorkingCopies: true)
        #expect(queue.cases.filter { $0.kind == .reclaimDrive }.map(\.driveLabel) == ["X9"], "no card for the Read-only drive")
        let set = try #require(queue.cases.first { $0.kind == .reclaimGroup })
        #expect(set.payoffBytes == 100 && set.protectedCopies == 0)
        #expect(set.readOnlyNotes == ["2 copies on SanDisk are never offered — it is Read only."])
        let row = try #require(set.copies.first { $0.id == ro1.id })
        #expect(row.standing == .protected(.readOnlyDrive))
        #expect(StewardStandingWords.words(for: row, proof: nil) == "On a drive you marked Read only — never offered.")
        #expect(StewardStandingWords.readOnlyFooter(count: 1, drive: "SanDisk") == "1 copy on SanDisk is never offered — it is Read only.")
    }

    /// 100k records, one drive marked Read only: the selection on another
    /// drive stays within its existing budget (a few string checks per row).
    @Test("100k selection with a Read-only drive stays within the selection budget", .timeLimit(.minutes(1)))
    func selectionScale100k() {
        let model = makeModel(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_readonly_scale"))
        model.scanTargets = [target("/Volumes/ScaleRO", readOnly: true), target("/Volumes/ScaleRW"), target("/Volumes/Other1"),
                             target("/Volumes/Other2"), target("/Volumes/Other3")]
        let g = UUID(), h = UUID()
        var catalog: [VideoRecord] = [dupRecord(path: "/Volumes/ScaleRW/keeper.mov", group: g, disposition: .keep),
                                      dupRecord(path: "/Volumes/ScaleRO/keeper.mov", group: h, disposition: .keep)]
        catalog.reserveCapacity(100_000)
        for i in 2..<100_000 {
            catalog.append(i % 2 == 0
                ? dupRecord(path: "/Volumes/ScaleRW/copy-\(i).mov", group: g, disposition: .extraCopy)
                : dupRecord(path: "/Volumes/ScaleRO/copy-\(i).mov", group: h, disposition: .extraCopy))
        }
        model.records = catalog
        // Each pass against the selection's own existing budget
        // (DeleteDuplicatesSafetyTests.planningScale100k: one pass, 2 s).
        let clock = ContinuousClock()
        let load = TimingBudget.sampleLoad()
        var t0 = clock.now
        let rw = model.duplicateDeletionSelection(onVolume: "/Volumes/ScaleRW")
        let rwTime = t0.duration(to: clock.now)
        t0 = clock.now
        let ro = model.duplicateDeletionSelection(onVolume: "/Volumes/ScaleRO")
        let roTime = t0.duration(to: clock.now)
        t0 = clock.now
        let menu = model.volumesWithDeletableDuplicates()
        let menuTime = t0.duration(to: clock.now)
        print("[readonly-scale] selection rw \(rwTime) · ro \(roTime) · menu \(menuTime)")
        #expect(rw.targets.count == 49_999 && ro.targets.isEmpty && ro.skippedCount == 49_999)
        #expect(menu.map(\.path) == ["/Volumes/ScaleRW"])
        for (name, time) in [("the selection on the drive that allows changes", rwTime),
                             ("the selection on the Read-only drive", roTime), ("the menu count", menuTime)] {
            // GH #208 judge (2026-10-05): CI's hosted runner measured 6.8 s
            // against 2 s × 3; strict on a quiet M4, a known issue within 3×
            // when busy or hosted, a failure beyond.
            expectWithinTimingBudget("100k Read-only scale — \(name)", measured: time,
                                     budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
        }
    }
}

// MARK: - The switch and where it is stored

@Suite("Read-only volumes — the switch, its storage, the viewer", .serialized)
@MainActor
struct ReadOnlyVolumeSettingsTests {

    @Test func theSwitchMarksAndUnmarksAndSaysSo() async {
        let dir = tempDir("switch"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let t = target(dir.path)
        model.scanTargets = [t]
        #expect(!model.isVolumeReadOnly(t) && model.hasNoReadOnlyVolumeMarks && model.readOnlyVolumeProtection().isEmpty)
        model.setVolumeReadOnly(true, for: t)
        #expect(t.readOnlyMark != nil && t.readOnlyMark?.volumeUUID == nil, "a folder of the boot disk keeps no volume identity")
        #expect(model.isVolumeReadOnly(t) && !model.isReadOnlyByRule(t))
        #expect(model.bulkDeleteRefusal(forPath: dir.appendingPathComponent("a.mov").path) == .readOnlyVolume(dir.lastPathComponent))
        // The built snapshot lands and says the same.
        let built = await model.refreshReadOnlyVolumeSnapshot()
        #expect(built.isBuilt && built.verdict(forPath: dir.appendingPathComponent("a.mov").path) == .readOnly(dir.lastPathComponent))
        model.setVolumeReadOnly(false, for: t)
        #expect(t.readOnlyMark == nil && model.bulkDeleteRefusal(forPath: dir.appendingPathComponent("a.mov").path) == nil)
        let console = await consoleText(model)
        #expect(console.contains("is marked Read only — VideoScan will never delete, move or rewrite files on it; its files still count as copies when other drives are cleaned up."))
        #expect(console.contains("allows changes again."))
        #expect(console.contains("— START"))
    }

    /// A mount, an unmount or a rename makes the built snapshot stale: the
    /// gate goes on answering (by path) while it is rebuilt.
    @Test func aMountChangeNeverOpensAWindow() async {
        let model = makeModel(tempDir("stale"))
        model.scanTargets = [target("/Volumes/SanDisk", readOnly: true)]
        _ = await model.refreshReadOnlyVolumeSnapshot()
        #expect(model.readOnlyVolumeProtection().isBuilt)
        model.noteArchiveVolumeSnapshotStale(reason: "test: a drive was mounted")
        let now = model.readOnlyVolumeProtection()
        #expect(!now.isBuilt, "the provisional snapshot answers while the rebuild runs")
        #expect(model.bulkDeleteRefusal(forPath: "/Volumes/SanDisk/a.mov") == .readOnlyVolume("SanDisk"))
    }

    /// The Master Archive's volume is read-only BY RULE: shown on, not the
    /// person's to change, and it carries no mark.
    @Test func theMasterArchiveVolumeIsReadOnlyByRule() {
        let model = makeModel(tempDir("rule"))
        let archive = target("/Volumes/FamilyArchive"), other = target("/Volumes/X9")
        archive.role = .archive
        model.scanTargets = [archive, other]
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                       rootPath: "/Volumes/FamilyArchive/Test_Family_Archive", volumeUUID: nil)
        #expect(model.isReadOnlyByRule(archive) && model.isVolumeReadOnly(archive) && archive.readOnlyMark == nil)
        #expect(!model.isReadOnlyByRule(other) && !model.isVolumeReadOnly(other), "everything else allows changes by default")
        #expect(model.readOnlyVolumeNamesForPicker == ["FamilyArchive"])
        #expect(VolumeReadOnlyText.byRuleLabel == "Read only — the Master Archive")
        #expect(VolumeReadOnlyText.toggleLabel == "Read only")
        #expect(VolumeReadOnlyText.caption == "VideoScan will never delete, move or rewrite files on this drive. Its files still count as copies when other drives are cleaned up.")
        #expect(VolumeReadOnlyText.reclaimableNotice == "This drive is Read only — nothing here is ever removed.")
        #expect(VolumeReadOnlyText.menuTitle(isMarked: false) == "Mark Read Only" && VolumeReadOnlyText.menuTitle(isMarked: true) == "Allow Changes")
    }

    /// The viewer (a read-only catalog) cannot change the mark — and the
    /// gate's answer does not depend on viewer mode.
    @Test func viewerModeCannotChangeTheMarkAndDoesNotChangeTheGate() {
        let model = makeModel(tempDir("viewer"))
        let marked = target("/Volumes/SanDisk", readOnly: true), plain = target("/Volumes/X9")
        model.scanTargets = [marked, plain]
        model.isReadOnly = true
        model.setVolumeReadOnly(false, for: marked)
        model.setVolumeReadOnly(true, for: plain)
        #expect(marked.readOnlyMark != nil && plain.readOnlyMark == nil)
        #expect(model.bulkDeleteRefusal(forPath: "/Volumes/SanDisk/a.mov") == .readOnlyVolume("SanDisk"))
        #expect(model.bulkDeleteRefusal(forPath: "/Volumes/X9/a.mov") == nil)
    }

    /// Stored with the other volume settings (UserDefaults, keyed by the
    /// target's path): additive — settings saved before the field existed
    /// restore with every volume allowing changes.
    @Test func theMarkIsSavedWithTheVolumeSettingsAndOlderSettingsStillRestore() throws {
        let token = UUID().uuidString
        func key(_ name: String) -> String { "test.readonly.\(token).\(name)" }
        let keys = ["targets", "dates", "phases", "roles", "trust", "fs", "tech", "year", "cap", "notes", "retAt", "retRsn", "retWit", "ro"]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: key($0)) } }
        func persist(_ targets: [CatalogScanTarget], readOnlyKey: String?) {
            ScanTargetPersistence.persistPaths(targets, key: key("targets"))
            ScanTargetPersistence.persistMetadata(
                targets, savedDatesKey: key("dates"), savedPhasesKey: key("phases"), savedRolesKey: key("roles"),
                savedTrustKey: key("trust"), savedFilesystemKey: key("fs"), savedMediaTechKey: key("tech"),
                savedPurchaseYearKey: key("year"), savedCapacityKey: key("cap"), savedNotesKey: key("notes"),
                savedRetiredAtKey: key("retAt"), savedRetiredReasonKey: key("retRsn"), savedRetiredWitnessesKey: key("retWit"),
                savedReadOnlyKey: readOnlyKey)
        }
        func restore(readOnlyKey: String?) -> [CatalogScanTarget] {
            ScanTargetPersistence.restore(
                existing: [], savedTargetsKey: key("targets"), savedDatesKey: key("dates"), savedPhasesKey: key("phases"),
                savedRolesKey: key("roles"), savedTrustKey: key("trust"), savedFilesystemKey: key("fs"),
                savedMediaTechKey: key("tech"), savedPurchaseYearKey: key("year"), savedCapacityKey: key("cap"),
                savedNotesKey: key("notes"), savedRetiredAtKey: key("retAt"), savedRetiredReasonKey: key("retRsn"),
                savedRetiredWitnessesKey: key("retWit"), savedReadOnlyKey: readOnlyKey)
        }
        let marked = target("/Volumes/ReadOnlyTest-\(token)", readOnly: true, uuid: "AAA-111")
        let plain = target("/Volumes/PlainTest-\(token)")

        // Settings written BEFORE the field existed: no key at all.
        persist([marked, plain], readOnlyKey: nil)
        #expect(UserDefaults.standard.object(forKey: key("ro")) == nil)
        #expect(restore(readOnlyKey: key("ro")).allSatisfy { $0.readOnlyMark == nil }, "older settings: every volume allows changes")
        #expect(restore(readOnlyKey: nil).count == 2, "a caller that does not know the field still restores")

        // Round trip.
        persist([marked, plain], readOnlyKey: key("ro"))
        let back = restore(readOnlyKey: key("ro"))
        #expect(back.map(\.searchPath) == [marked.searchPath, plain.searchPath])
        #expect(back[0].readOnlyMark == marked.readOnlyMark && back[1].readOnlyMark == nil)
        // Only marked volumes have an entry; unmarking removes it.
        #expect((UserDefaults.standard.dictionary(forKey: key("ro")) ?? [:]).keys.sorted() == [marked.searchPath])
        marked.readOnlyMark = nil
        persist([marked, plain], readOnlyKey: key("ro"))
        #expect(restore(readOnlyKey: key("ro")).allSatisfy { $0.readOnlyMark == nil })
        // A damaged entry is still a mark (refuse over guess).
        UserDefaults.standard.set([plain.searchPath: ["markedAt": "not a date"]], forKey: key("ro"))
        #expect(restore(readOnlyKey: key("ro"))[1].readOnlyMark == VolumeReadOnlyMark(markedAt: .distantPast, volumeUUID: nil))
        #expect(VideoScanModel.savedReadOnlyKey == "VideoScan.scanTargetReadOnly")
    }

    /// The bundle's volume snapshot: additive fields; an older bundle
    /// decodes; importing can set the mark and never clears one made here.
    @Test func theBundleSnapshotCarriesTheMarkAndNeverClearsOne() throws {
        let marked = target("/Volumes/SanDisk", readOnly: true, uuid: "AAA-111")
        let data = try JSONEncoder().encode(VolumeMetadataSnapshot(from: marked))
        let decoded = try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: data)
        #expect(decoded.readOnlyMarkedAt == marked.readOnlyMark?.markedAt && decoded.readOnlyVolumeUUID == "AAA-111")
        let fresh = target("/Volumes/SanDisk")
        ScanTargetPersistence.applyVolumeSnapshot(decoded, to: fresh)
        #expect(fresh.readOnlyMark == marked.readOnlyMark)

        // An older bundle (no fields) decodes, and does not clear a local mark.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["readOnlyMarkedAt"] = nil
        json["readOnlyVolumeUUID"] = nil
        let old = try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.readOnlyMarkedAt == nil)
        let local = target("/Volumes/SanDisk", readOnly: true, uuid: "AAA-111")
        ScanTargetPersistence.applyVolumeSnapshot(old, to: local, isNewTarget: false)
        #expect(local.readOnlyMark != nil, "an imported older bundle un-protected a drive")
    }
}

// MARK: - Sensors

@Suite("Read-only volumes — every bulk remove verb goes through the one gate")
struct ReadOnlyVolumeSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func theGateHasTheReadOnlyHalfAndIsItsOnlyDoor() throws {
        let gate = try code("VideoScanModel+MasterArchive.swift")
        #expect(gate.contains("return readOnlyVolumeRefusal(forPath: path, effect: effect)"), "the gate no longer asks the read-only half")
        #expect(gate.contains("guard effect == .removesFiles, !hasNoReadOnlyVolumeMarks else { return nil }"))
        #expect(gate.contains("switch readOnlyVolumeProtection().verdict(forPath: path) {"))
        #expect(gate.contains("guard masterArchive != nil || !hasNoReadOnlyVolumeMarks, !recs.isEmpty else { return recs }"),
                "the offer-side filters must not return early when only a read-only mark exists")
        // Nobody else decides "is this path on a read-only volume" for a
        // main-actor verb: the string verdict is asked in the gate only.
        for (relative, url) in SourceTree.appSources where !relative.hasSuffix("VideoScanModel+MasterArchive.swift")
            && !relative.hasSuffix("ReadOnlyVolumeProtection.swift") {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("readOnlyVolumeProtection().verdict("), "\(relative) asks the read-only snapshot itself")
        }
        // The removal-time check carries the read-only snapshot to the disk thread.
        let snapshot = try code("VideoScanModel+ArchiveVolumeSnapshot.swift")
        #expect(snapshot.contains("guard protection != nil || !readOnly.isEmpty else { return nil }"))
        #expect(snapshot.contains("readOnly: readOnly)") && snapshot.contains("noteReadOnlyVolumeSnapshotStale()"))
        let check = try code("ArchiveVolumeProtection.swift")
        #expect(check.contains("switch readOnly.verdictAtRemoval(path: path, probe: probe, identity: identity) {"))
    }

    /// Each verb that removes, trashes or replaces a media file, and the
    /// gate call it makes. A new bulk remove verb must be added here — and
    /// to the gate.
    @Test func everyBulkRemoveVerbAsksTheGate() throws {
        let verbs: [(file: String, calls: [String])] = [
            ("VideoScanModel+Duplicates.swift", ["bulkDeleteRefusal(rec, volume: archiveVolume)",
                                                 "excludingMasterArchiveFiles(selection.targets, verb: \"Delete Duplicates\")"]),
            ("DeleteDuplicatesJob.swift", ["archiveCheck: model.archiveRemovalCheck()", "check.refusal(forPath: item.path)",
                                           "archiveCheck?.refusal(forPath: ticket.quarantinedPath)"]),
            ("DeleteDuplicatesForecast.swift", ["bulkDeleteRefusal(r, volume: archiveVolume)"]),
            ("VideoScanModel+JunkDelete.swift", ["excludingMasterArchiveFiles(requested, verb: \"Delete Confirmed Junk\")",
                                                 "readOnlyVolumes.verdictAtRemoval(path: path, probe: uuidProbe)"]),
            ("JunkDeleteAction.swift", ["model.excludingMasterArchiveFiles("]),
            ("VideoScanModel+TrashSelection.swift", ["self.bulkDeleteRefusal($0, volume: archiveVolume)"]),
            ("VideoScanModel+PruneApply.swift", ["bulkDeleteRefusal(rec, volume: archiveVolume)"]),
            ("VideoScanModel+Workbench.swift", ["excludingMasterArchiveFiles(requested, verb: \"Discard\")"]),
            ("TranscodeJob.swift", ["model.bulkDeleteRefusal(forPath: path)", "archiveCheck: model?.archiveRemovalCheck()"]),
            ("CatalogRowContextMenu.swift", ["model.recordsBulkVerbsMayRemove(activeRecs)"]),   // row menu (R1: was CatalogContent+Table.swift)
            ("VideoScanModel+Steward.swift", ["self.bulkDeleteRefusal(r, volume: archiveDrive)"]),
        ]
        for verb in verbs {
            let src = try code(verb.file)
            for call in verb.calls {
                #expect(src.contains(call), "\(verb.file) no longer goes through the gate: `\(call)`")
            }
        }
    }

    /// The switch is in the editor, the row's menu, the row and the card;
    /// the Reclaimable card gives way to the notice; the picker lists the
    /// drive as not choosable. No O(records) work in any of them.
    @Test func theSwitchIsWhereThePersonLooksForIt() throws {
        let editor = try code("VolumesWindow+Editor.swift")
        #expect(editor.contains("set: { model.setVolumeReadOnly($0, for: target) }") && editor.contains("VolumeReadOnlyText.caption"))
        #expect(editor.contains(".disabled(byRule || model.isReadOnly)") && editor.contains("volumeEditor.readOnlyToggle"))
        let window = try code("VolumesWindow.swift")
        #expect(window.contains("VolumeReadOnlyText.menuTitle(isMarked: target.readOnlyMark != nil)"))
        #expect(window.contains("volumeRow.readOnlyBadge") && window.contains("Image(systemName: \"lock.fill\")"))
        let pane = try code("VolumeDetailPane.swift")
        #expect(pane.contains("if model.isVolumeReadOnly(target) {") && pane.contains("VolumeReadOnlyText.reclaimableNotice"))
        #expect(pane.contains("chip(VolumeReadOnlyText.chip, color: .gray, icon: \"lock.fill\")"))
        let picker = try code("DeleteDuplicatesVolumePicker.swift")
        #expect(picker.contains("VolumeReadOnlyText.pickerRow(name)"))
        #expect(try code("DeleteDuplicatesFlow.swift").contains("readOnlyVolumeNames: model.readOnlyVolumeNamesForPicker"))
        #expect(try code("StewardCardView.swift").contains("ForEach(item.readOnlyNotes, id: \\.self)"))
    }
}
