// ReadOnlyVolumeCodex258Tests.swift
// Codex review of the delete-safety bundle (GH #258 + Read-only volumes +
// the two-drives rule), cycle #34, 2026-10-03: BLOCK, 11 findings
// (docs/reviews/codex/codex-review-delete-safety-bundle-258-2026-10-03.md).
// One pinning test (or a few) per finding, each red before its fix.
//
//   F1  a copy the run LEAVES ALONE (in use by the Angel, on a Read-only
//       folder of the cleaned drive) was counted as a survivor for another
//       copy — which main never did while it was a pending row
//   F2  a Read-only mark made through an alias / a custom mount point
//       protected only the spelling
//   F3  an import replaced an existing mark's drive identity
//   F4  a FOLDER mark was not found by UUID at removal after a remount
//   F5  Junk Delete / Move to Trash judged every file by the snapshot taken
//       before the first one
//   F6  a hold acquired during phase two's re-read was not asked at the
//       removal boundary
//   F7  a finished Prepare released its hold before the prepared set said
//       so; a batch saved by another route was not seen at a copy's turn;
//       an older disk read could overwrite a newer one
//   F8  one volume keyed two ways (UUID / device) counted as two drives
//   F9  a disk image counted as a drive
//   F10 the forecast took the drive from the path's spelling
//   F11 a sibling on a second drive was not read once three were counted
//
// Dimensions: Logic (below) · Scale N/A (every change is O(family) per row
// or O(1) per file; the 100k selection budgets are pinned in
// DeleteDuplicatesAngelHoldTests / ReadOnlyVolumeTests and re-run) · Media
// matrix N/A (synthetic bytes; no media opened beyond the planner's whole-
// file reads) · Isolation (temp catalog, ledger, plan root and Angel buffer
// per test; volume identity, mount identity and drive identity are injected
// — nothing reads the machine's drives) · Sensor (source pins at the end).
//
// Suites: ReadOnlyVolumeCodex258Tests
//
// This file: F2–F5 (the Read-only mark).

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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

@MainActor
private func dupRecord(path: String, size: Int64, group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
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
private func setAngel(_ model: VideoScanModel, prepared: Set<UUID> = [], promoted: Set<UUID> = []) {
    var summary = model.archiveAngel.recommendations
    summary.preparedIDs = prepared
    summary.promotedIDs = promoted
    summary.revision += 1
    model.archiveAngel.publishRecommendations(summary)
}

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 199) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

/// A lock-protected value a hook on a disk thread and the test can share.
private final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline, !condition() { await Task.yield() }
    #expect(condition(), "timed out waiting for: \(what)")
}

/// Two drives cannot be had in one temp folder: R "is on" drive B.
private let secondDrive: @Sendable (String, FileIdentityStamp) -> DeletionTierFacts.Drive = { path, _ in
    path.hasSuffix("/r.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
}

// MARK: - F2–F5 — Read-only volumes

@Suite("Codex #258 F2–F5 — a Read-only mark is the drive's, at every moment", .serialized)
@MainActor
struct ReadOnlyVolumeCodex258Tests {

    typealias P = ReadOnlyVolumeProtection

    /// F2: the scan target is a symlink into /Volumes/TestMarked. Marking IT
    /// must protect the drive — under its canonical path too.
    @Test func aMarkMadeThroughAnAliasProtectsTheDriveItself() async {
        let alias = "/Users/test/test_media"
        let identity: @Sendable (String) -> MountIdentity? = { path in
            if path == alias || path.hasPrefix(alias + "/") {
                return MountIdentity(resolvedPath: "/Volumes/TestMarked" + path.dropFirst(alias.count), mountPoint: "/Volumes/TestMarked")
            }
            for name in ["TestMarked", "TestOther"] where path == "/Volumes/\(name)" || path.hasPrefix("/Volumes/\(name)/") {
                return MountIdentity(resolvedPath: path, mountPoint: "/Volumes/\(name)")
            }
            return nil
        }
        let uuid: @Sendable (String) -> String? = { path in
            if path.hasPrefix(alias) || path.hasPrefix("/Volumes/TestMarked") { return "TEST-U" }
            return path.hasPrefix("/Volumes/TestOther") ? "TEST-O" : nil
        }
        await ArchiveVolumeProtection.$mountIdentityProbe.withValue(identity) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue(uuid) {
                await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ ["/Volumes/TestMarked", "/Volumes/TestOther"] }) {
                    let model = makeModel(tempDir("alias"))
                    let marked = scanTarget(alias)
                    model.scanTargets = [marked, scanTarget("/Volumes/TestMarked"), scanTarget("/Volumes/TestOther")]
                    model.setVolumeReadOnly(true, for: marked)
                    #expect(marked.readOnlyMark?.volumeUUID == "TEST-U",
                            "the mark kept no identity for the drive behind the alias: \(String(describing: marked.readOnlyMark))")
                    // Before any build (the provisional snapshot): both spellings.
                    #expect(model.bulkDeleteRefusal(forPath: "\(alias)/a.mov") != nil)
                    #expect(model.bulkDeleteRefusal(forPath: "/Volumes/TestMarked/a.mov") != nil,
                            "the drive's own path is removable while the snapshot is being built")
                    let built = await model.refreshReadOnlyVolumeSnapshot()
                    #expect(built.isBuilt)
                    #expect(model.bulkDeleteRefusal(forPath: "/Volumes/TestMarked/tapes/a.mov") != nil,
                            "marked through an alias, the drive's canonical path is still removable")
                    #expect(model.bulkDeleteRefusal(forPath: "\(alias)/tapes/a.mov") != nil)
                    #expect(model.bulkDeleteRefusal(forPath: "/Volumes/TestOther/a.mov") == nil)
                    let g = UUID()
                    let junk = dupRecord(path: "/Volumes/TestMarked/junk.mov", size: 1, group: g, disposition: .extraCopy)
                    #expect(model.excludingMasterArchiveFiles([junk], verb: "Delete Confirmed Junk").isEmpty)
                }
            }
        }
    }

    /// F2: a drive mounted at a custom mount point (not under /Volumes) is a
    /// DRIVE — its identity is kept, and it is protected where it mounts next.
    @Test func aMarkOnACustomMountPointKeepsTheDrivesIdentity() async {
        let custom = "/Users/test/mnt/custom"
        let before: @Sendable (String) -> MountIdentity? = { path in
            path == custom || path.hasPrefix(custom + "/") ? MountIdentity(resolvedPath: path, mountPoint: custom) : nil
        }
        let model = makeModel(tempDir("custom"))
        let marked = scanTarget(custom)
        model.scanTargets = [marked]
        ArchiveVolumeProtection.$mountIdentityProbe.withValue(before) {
            MasterArchiveDesignation.$volumeUUIDProbe.withValue({ $0.hasPrefix(custom) ? "TEST-C" : nil }) {
                model.setVolumeReadOnly(true, for: marked)
            }
        }
        #expect(marked.readOnlyMark?.volumeUUID == "TEST-C", "classified by the spelling, not by the mount")
        // Later: the same drive is mounted by Finder at /Volumes/TestCustom.
        let after = P.make(marks: model.readOnlyVolumeMarks, mountedRoots: { ["/Volumes/TestCustom"] },
                           probe: { $0.hasPrefix("/Volumes/TestCustom") ? "TEST-C" : nil })
        #expect(after.verdict(forPath: "/Volumes/TestCustom/a.mov") != nil, "the marked drive, mounted elsewhere, is removable")
        #expect(after.verdict(forPath: "\(custom)/a.mov") != nil, "the marked path itself stays protected")
    }

    /// F3: an import may ADD a mark; it never alters or clears the identity
    /// of a mark made on this Mac.
    @Test func anImportNeverChangesAnExistingMarksDriveIdentity() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        for imported in [String?.none, "TEST-V"] {
            let local = scanTarget("/Volumes/TestMarked")
            local.readOnlyMark = VolumeReadOnlyMark(markedAt: at, volumeUUID: "TEST-U")
            let donor = scanTarget("/Volumes/TestMarked")
            donor.readOnlyMark = VolumeReadOnlyMark(markedAt: at.addingTimeInterval(60), volumeUUID: imported)
            let snapshot = VolumeMetadataSnapshot(from: donor)
            ScanTargetPersistence.applyVolumeSnapshot(snapshot, to: local, isNewTarget: false)
            #expect(local.readOnlyMark?.volumeUUID == "TEST-U",
                    "an import carrying \(imported ?? "no identity") replaced the local mark's drive identity")
            // The original drive, remounted under another name, is still refused.
            let p = P.make(marks: [.init(searchPath: local.searchPath, volumeUUID: local.readOnlyMark?.volumeUUID)],
                           mountedRoots: { ["/Volumes/TestRenamed"] },
                           probe: { $0.hasPrefix("/Volumes/TestRenamed") ? "TEST-U" : nil })
            #expect(p.verdict(forPath: "/Volumes/TestRenamed/a.mov") != nil, "the marked drive became removable after the import")
        }
        // An import still ADDS a mark where there was none.
        let fresh = scanTarget("/Volumes/TestMarked")
        let donor = scanTarget("/Volumes/TestMarked")
        donor.readOnlyMark = VolumeReadOnlyMark(markedAt: at, volumeUUID: "TEST-V")
        ScanTargetPersistence.applyVolumeSnapshot(VolumeMetadataSnapshot(from: donor), to: fresh, isNewTarget: false)
        #expect(fresh.readOnlyMark?.volumeUUID == "TEST-V")
    }

    /// F4: a FOLDER of an external drive is marked; the drive is renamed and
    /// the rebuild has not landed. The removal-time check finds the folder
    /// by the file's own volume identity + its place on that volume.
    @Test func aMarkedFolderIsFoundByIdentityAtRemovalBeforeTheRebuildLands() {
        let provisional = P.provisional(marks: [.init(searchPath: "/Volumes/TestMarked/Clips", volumeUUID: "TEST-U")])
        #expect(!provisional.isBuilt)
        let identity: (String) -> MountIdentity? = { path in
            path.hasPrefix("/Volumes/TestRenamed") ? MountIdentity(resolvedPath: path, mountPoint: "/Volumes/TestRenamed") : nil
        }
        let probe: (String) -> String? = { $0.hasPrefix("/Volumes/TestRenamed") ? "TEST-U" : "TEST-O" }
        #expect(provisional.verdictAtRemoval(path: "/Volumes/TestRenamed/Clips/test_copy.mov", probe: probe, identity: identity) != nil,
                "the marked folder on the renamed drive is removable until the rebuild lands")
        #expect(provisional.verdictAtRemoval(path: "/Volumes/TestRenamed/clips/sub/test_copy.mov", probe: probe, identity: identity) != nil)
        #expect(provisional.verdictAtRemoval(path: "/Volumes/TestRenamed/Other/test_copy.mov", probe: probe, identity: identity) == nil,
                "only the marked folder — not the rest of the drive")
        #expect(provisional.verdictAtRemoval(path: "/Volumes/TestRenamed/ClipsOld/test_copy.mov", probe: probe, identity: identity) == nil)
        #expect(provisional.verdictAtRemoval(path: "/Volumes/TestElse/Clips/test_copy.mov", probe: probe, identity: identity) == nil,
                "another drive's folder of the same name")
    }

    /// F2: where the mark's new knowledge is stored — additive. Settings
    /// and bundles written before the fields existed still decode, and a
    /// mark that never learned where it lives is protected as it was.
    @Test func whatTheMarkLearnedIsStoredAdditively() throws {
        let key = "test.codex258.readonly.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let learned = scanTarget("/Users/test/test_media")
        learned.readOnlyMark = VolumeReadOnlyMark(markedAt: at, volumeUUID: "TEST-U", resolvedPath: "/Volumes/TestMarked",
                                                  mountPoint: "/Volumes/TestMarked")
        let plain = scanTarget("/Volumes/TestPlain")
        plain.readOnlyMark = VolumeReadOnlyMark(markedAt: at, volumeUUID: "TEST-P")
        ScanTargetPersistence.persistReadOnlyMarks([learned, plain], key: key)
        let back = ScanTargetPersistence.readOnlyMarks(forKey: key)
        #expect(back[learned.searchPath] == learned.readOnlyMark && back[plain.searchPath] == plain.readOnlyMark)
        // An entry written before the fields existed.
        UserDefaults.standard.set([plain.searchPath: ["markedAt": at, "volumeUUID": "TEST-P"]], forKey: key)
        #expect(ScanTargetPersistence.readOnlyMarks(forKey: key)[plain.searchPath]
                == VolumeReadOnlyMark(markedAt: at, volumeUUID: "TEST-P", resolvedPath: nil, mountPoint: nil))

        // The bundle's volume snapshot: round trip, and an older bundle.
        let data = try JSONEncoder().encode(VolumeMetadataSnapshot(from: learned))
        let decoded = try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: data)
        #expect(decoded.readOnlyResolvedPath == "/Volumes/TestMarked" && decoded.readOnlyMountPoint == "/Volumes/TestMarked")
        let fresh = scanTarget(learned.searchPath)
        ScanTargetPersistence.applyVolumeSnapshot(decoded, to: fresh)
        #expect(fresh.readOnlyMark == learned.readOnlyMark, "an import ADDS the mark whole where there was none")
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["readOnlyResolvedPath"] = nil
        json["readOnlyMountPoint"] = nil
        let older = try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.readOnlyMarkedAt != nil && older.readOnlyResolvedPath == nil && older.readOnlyMountPoint == nil)

        // The protection built from what the mark learned: both spellings,
        // and — a different drive mounted where the marked one was — both
        // of the mark's own spellings say so.
        let mark = P.Mark(searchPath: learned.searchPath, volumeUUID: "TEST-U", resolvedPath: "/Volumes/TestMarked",
                          mountPoint: "/Volumes/TestMarked")
        let displaced = P.make(marks: [mark], mountedRoots: { ["/Volumes/TestMarked", "/Volumes/TestMoved"] },
                               probe: { $0.hasPrefix("/Volumes/TestMoved") ? "TEST-U" : ($0.hasPrefix("/Volumes/TestMarked") ? "TEST-Z" : nil) })
        #expect(displaced.verdict(forPath: "/Volumes/TestMarked/a.mov") == .readOnlyDifferentDrive("test_media"))
        #expect(displaced.verdict(forPath: "/Users/test/test_media/a.mov") == .readOnlyDifferentDrive("test_media"))
        #expect(displaced.verdict(forPath: "/Volumes/TestMoved/a.mov") == .readOnly("test_media"), "the drive itself, found by its identity")
        // A mark made while its drive was away learns its real place at the
        // build, when the spelling resolves (protected by path).
        let late = P.make(marks: [.init(searchPath: "/Users/test/late_link", volumeUUID: nil)], mountedRoots: { [] }, probe: { _ in nil },
                          identity: { $0 == "/Users/test/late_link" ? MountIdentity(resolvedPath: "/Volumes/TestLate/media", mountPoint: "/Volumes/TestLate") : nil },
                          networkRoots: { [] })
        #expect(late.verdict(forPath: "/Volumes/TestLate/media/a.mov") != nil && late.verdict(forPath: "/Volumes/TestLate/other/a.mov") == nil)
        // A "/Volumes/X" that resolves onto the boot disk is an unmounted
        // volume's leftover folder: nothing is learned from it.
        let leftover = ArchiveVolumeProtection.$mountIdentityProbe.withValue({ MountIdentity(resolvedPath: $0, mountPoint: "/") }) {
            MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in "TEST-BOOT" }) {
                VideoScanModel.readOnlyMark(forPath: "/Volumes/TestAway", isReachable: true, now: at)
            }
        }
        #expect(leftover == VolumeReadOnlyMark(markedAt: at, volumeUUID: nil))
    }

    /// Sensors for F2, F3 and F5.
    @Test func theFixesAreWhereTheyMustBe() throws {
        let ro = try SourceTree.appSource(named: "ReadOnlyVolumeProtection.swift")
        #expect(ro.contains("guard let id = ArchiveVolumeProtection.mountIdentityProbe(searchPath) else {"),
                "the mark no longer resolves where its path really lives")
        #expect(ro.contains("if !onBootDisk { mark.volumeUUID = MasterArchiveDesignation.volumeUUID(forPath: id.resolvedPath) }"),
                "drive-or-folder is decided by the spelling again")
        #expect(ro.contains("let byIdentity = entries.filter { $0.volumeUUID != nil }"),
                "the removal-time identity check skips marked folders again")
        let persistence = try SourceTree.appSource(named: "ScanTargetPersistence.swift")
        #expect(persistence.contains("if let local = t.readOnlyMark {") && persistence.contains("t.readOnlyMark = imported"),
                "an import may only ADD a mark")
        // 2026-10-09: one TURN per file — the loop calls junkTurn for each
        // file, and junkTurn reads the Read-only marks afresh before that
        // file's disk half, which asks them at the removal.
        let junk = try SourceTree.appSource(named: "VideoScanModel+JunkDelete.swift")
        let loop = try #require(junk.range(of: "for (rec, decided) in zip(requested, pending) {"))
        #expect(junk[loop.upperBound...].contains("await junkTurn(rec, guard: fileGuard, disk: disk)"),
                "the per-file turn left the loop")
        let turn = try #require(junk.range(of: "private func junkTurn("))
        let hop = try #require(junk.range(of: "disk.run(path: path, protections: protections, catalogBytes: catalogBytes)",
                                          range: turn.upperBound..<junk.endIndex))
        // The archive too, since codex delete-engines F3 (2026-10-09).
        let perTurn = String(junk[turn.upperBound..<hop.lowerBound])
        #expect(perTurn.contains("readOnlyVolumes: readOnlyVolumeProtection()"),
                "the Read-only marks are read once for the whole batch again")
        #expect(perTurn.contains("let archiveVolume = archiveVolumeProtection()"),
                "the Master Archive is read once for the whole batch again")
        #expect(junk.contains("readOnlyVolumes.verdictAtRemoval(path: path, probe: uuidProbe)"))
        #expect(try SourceTree.appSource(named: "VideoScanModel+TrashSelection.swift").contains("deleteConfirmedJunk("),
                "Move to Trash shares Junk Delete's loop")
    }

    /// F5: the drive is marked Read only WHILE Delete Confirmed Junk is
    /// working through its files — the files not yet removed stay.
    @Test func markingADriveReadOnlyMidRunProtectsTheFilesNotYetRemoved() async throws {
        let dir = tempDir("midrun"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let target = scanTarget(dir.path)
        model.scanTargets = [target]
        func junk(_ name: String) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes.prefix(1_024)))
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = name
            r.directory = dir.path
            r.sizeBytes = 1_024
            r.durationSeconds = 61
            r.mediaDisposition = .confirmedJunk
            return r
        }
        let first = junk("first.mov"), second = junk("second.mov")
        model.records = [first, second]

        let inFirstRemoval = Shared(false)
        let release = DispatchSemaphore(value: 0)
        let fileGuard = VideoScanModel.JunkDeletionGuard(
            authorize: { _ in nil }, beforeRemoval: { _ in nil },
            remove: { url in
                if url.lastPathComponent == "first.mov" {
                    inFirstRemoval.value = true
                    release.wait()
                }
                try FileManager.default.removeItem(at: url)
            })
        let run = Task { @MainActor in await model.deleteConfirmedJunk([first, second], mode: .permanent, guard: fileGuard) }
        await waitUntil("the first file's removal") { inFirstRemoval.value }
        model.setVolumeReadOnly(true, for: target)
        release.signal()
        let result = await run.value

        #expect(FileManager.default.fileExists(atPath: second.fullPath), "a file was removed from a drive already marked Read only")
        #expect(!second.isPurged && result.succeeded == 1 && result.refused.count == 1, "\(result.succeeded) removed, \(result.refused.count) refused")
        #expect(result.refused.first?.reason.contains("which you marked Read only") == true, Comment(rawValue: result.refused.first?.reason ?? ""))
    }
}
