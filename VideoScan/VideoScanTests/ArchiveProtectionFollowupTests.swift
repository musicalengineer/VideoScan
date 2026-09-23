// ArchiveProtectionFollowupTests.swift
//
// Post-merge QA of the archive-volume protection (main 17808ab7) found
// four follow-ups. This file holds the red→green tests for the first
// three; the fourth (the source sensor) lives in
// ArchiveVolumeProtectionTests.swift beside the inventory it pins.
//
//   1. Transcode deleted the file at its output name BEFORE the source
//      check and before any encode. The default destination for an
//      archived source is the archive's own year folder, so "Replace
//      Existing Transcode?" permanently deleted a catalogued file on
//      FamilyArchive — even when the encode then failed.
//   2. The archive-volume snapshot was rebuilt on the MAIN thread every
//      debounced catalog change; with FamilyArchive offline/renamed it
//      probed every mounted /Volumes root (a hung SMB server → beachball,
//      GH #104 class).
//   3. Delete Duplicates checked the archive volume by path text only.
//      A symlinked scan root / custom mount path to FamilyArchive passed.
//
// Five dimensions (CLAUDE.md):
//   Logic     — every test below
//   Scale     — 100k-record dossier refresh with a UUID designation
//   Media     — a real ffmpeg encode (lavfi → ProRes .mov) for Transcode
//   Isolation — sandbox temp dirs; task-local mount/UUID probes; the
//               Trash seam never touches the user's real Trash
//   Sensor    — ArchiveVolumeProtectionSourceSensor (exact counts)

import AppKit
import Darwin
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixtures

@MainActor
private func record(_ path: String, group: UUID? = nil,
                    disposition: DuplicateDisposition = .none) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = 1
    r.partialMD5 = "m"
    r.durationSeconds = 61
    if let group {
        r.duplicateGroupID = group
        r.duplicateDisposition = disposition
        r.duplicateConfidence = .high
    }
    return r
}

@MainActor
private func isolatedModel() -> VideoScanModel {
    let model = VideoScanModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_archfu_\(UUID().uuidString.prefix(8))", isDirectory: true)
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

@MainActor
private func designateFamilyArchive(_ model: VideoScanModel, uuid: String? = nil,
                                    at volume: String = "/Volumes/FamilyArchive") {
    model.masterArchive = MasterArchiveDesignation(
        targetPath: volume, rootPath: volume + "/Breen_Family_Archive", volumeUUID: uuid)
}

/// Counts probe calls, split by thread. `pthread_main_np` rather than
/// `Thread.isMainThread` — the latter is unavailable from async contexts.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var off = 0
    func note() {
        let onMain = pthread_main_np() != 0
        lock.withLock { if onMain { main += 1 } else { off += 1 } }
    }
    var mainThreadCalls: Int { lock.withLock { main } }
    var offMainCalls: Int { lock.withLock { off } }
}

/// A tiny real movie (2 s, 320×240, testsrc + sine) — synthetic, `test_`
/// prefixed, made by ffmpeg in the sandbox.
private func makeTestMovie(at url: URL) throws {
    let ffmpeg = ToolLocator.ffmpegPath
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error",
                   "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=2",
                   "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                   "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest", url.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

private func sha(_ path: String) -> String? { MasterArchiveTestSupport.sha256(ofFile: path) }

// MARK: - 1. Transcode never deletes first

@Suite("Archive follow-ups — Transcode never deletes an existing file", .serialized)
@MainActor
struct TranscodeArchiveFollowupTests {

    /// QA's draft, verbatim in substance: a failing job (source missing)
    /// must not have removed the file already at its output name.
    @Test func transcodeNeverRemovesAnExistingFileOnTheArchiveVolume() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("transcode"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let dir = sb.archiveVolume.appendingPathComponent("MoviesExpansion", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = try MasterArchiveTestSupport.writeBlob(at: dir.appendingPathComponent("test_x.vs.archival.mov"),
                                                              bytes: 1024, seed: 9)
        model.records = [MasterArchiveTestSupport.makeRecord(path: existing.path)]
        let src = MasterArchiveTestSupport.makeRecord(path: sb.sources.appendingPathComponent("test_missing.mov").path)
        let job = TranscodeJob(record: src, preset: .archival, outputURL: existing, model: model)
        job.start(); await job.task?.value
        #expect(FileManager.default.fileExists(atPath: existing.path))
        if case .failed = job.state {} else { Issue.record("fixture: a missing source fails — \(job.state)") }
    }

    /// A real encode whose output name is taken by a catalogued file on
    /// the archive volume: the existing bytes are untouched and the new
    /// derivative lands beside it under a free name, and the job says so.
    @Test func transcodeOntoAnOccupiedArchiveNamePublishesBesideAndKeepsTheOriginal() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("transcode-beside"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let srcURL = sb.sources.appendingPathComponent("test_src.mov")
        try makeTestMovie(at: srcURL)
        let src = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        src.durationSeconds = 2
        let dir = sb.archiveVolume.appendingPathComponent("MoviesExpansion", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: dir, record: src, preset: .editingLT)
        let existing = try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 11)
        let before = sha(existing.path)
        let existingRec = MasterArchiveTestSupport.makeRecord(path: existing.path)
        model.records = [src, existingRec]

        let job = TranscodeJob(record: src, preset: .editingLT, outputURL: target, model: model)
        job.start(); await job.task?.value

        guard case .finished(let summary) = job.state else {
            Issue.record("the encode should succeed — \(job.state)"); return
        }
        #expect(sha(existing.path) == before, "the catalogued file on the archive volume is byte-for-byte untouched")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let fresh = names.filter { $0 != target.lastPathComponent && !$0.hasPrefix(".") }
        #expect(fresh.count == 1, "the new derivative sits beside it — \(names)")
        #expect(!names.contains { $0.contains("vs-partial") }, "no partial left behind — \(names)")
        #expect(summary.contains(fresh.first ?? "<none>"), "the job names where it went — \(summary)")
        #expect(model.records.contains { $0.id == existingRec.id && $0.fullPath == existing.path },
                "the existing record is still the file at its path")
    }
}

// MARK: - 2. No archive-volume disk probe on the main thread

@Suite("Archive follow-ups — snapshot probes stay off the main thread", .serialized)
@MainActor
struct ArchiveSnapshotMainThreadTests {

    @Test("100k-record dossier refresh with a UUID designation probes nothing on main",
          .timeLimit(.minutes(1)))
    func dossierRefreshNeverProbesOnTheMainThread() async {
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let gArch = UUID(), gOther = UUID()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        catalog.append(record("/Volumes/FamilyArchive/MoviesExpansion/keeper.mov", group: gArch, disposition: .keep))
        catalog.append(record("/Volumes/CrucialX9/keeper.mov", group: gOther, disposition: .keep))
        for i in 2..<100_000 {
            let onArch = i % 2 == 0
            catalog.append(record(onArch ? "/Volumes/FamilyArchive/MoviesExpansion/copy-\(i).mov"
                                         : "/Volumes/CrucialX9/copy-\(i).mov",
                                  group: onArch ? gArch : gOther, disposition: .extraCopy))
        }
        model.records = catalog
        let counter = ProbeCounter()
        // FamilyArchive is OFFLINE (the slow path: every mount is probed).
        ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({
            counter.note(); return ["/Volumes/CrucialX9", "/Volumes/SlowSMB"]
        }) {
            MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
                counter.note()
                return path.hasPrefix("/Volumes/CrucialX9") ? "UUID-X9" : nil
            }) {
                let start = ContinuousClock.now
                model.refreshDossierCountsNow()
                let elapsed = start.duration(to: .now)
                #expect(elapsed < .seconds(2), "100k refresh exceeded 2 s: \(elapsed)")
            }
        }
        #expect(counter.mainThreadCalls == 0,
                "refreshDossierCountsNow touched the disk on the main thread \(counter.mainThreadCalls) time(s)")
        #expect(!model.deletableDupVolumes.contains { $0.path == "/Volumes/FamilyArchive" },
                "and FamilyArchive is still never offered")
    }
}

// MARK: - 3. Delete Duplicates re-checks the file's OWN volume

@Suite("Archive follow-ups — Delete Duplicates volume re-check", .serialized)
@MainActor
struct DeleteDuplicatesArchiveVolumeRecheckTests {

    /// A scan root that reaches FamilyArchive through a symlink / custom
    /// mount path: the path TEXT says boot disk, the file's own volume
    /// says FamilyArchive. Junk refuses this; Delete Duplicates must too —
    /// and must not even move the file into quarantine.
    @Test func deleteDuplicatesJobReChecksEachFilesOwnVolumeLikeJunkDoes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_archfu_dd_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<(FileHasher.segmentSize * 2)).map { UInt8($0 % 197) })
        let keeperURL = dir.appendingPathComponent("test_keeper.mov")
        let copyURL = dir.appendingPathComponent("test_copy.mov")
        FileManager.default.createFile(atPath: keeperURL.path, contents: bytes)
        FileManager.default.createFile(atPath: copyURL.path, contents: bytes)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let g = UUID()
        let keeper = record(keeperURL.path, group: g, disposition: .keep)
        let copy = record(copyURL.path, group: g, disposition: .extraCopy)
        for r in [keeper, copy] { r.sizeBytes = Int64(bytes.count); r.partialMD5 = "same" }
        model.records = [keeper, copy]
        addVerifiedArchiveFamily(to: model, keeper: keeper)
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let before = sha(copyURL.path)
        let dirPath = dir.path
        let job = await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ [] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
                path.hasPrefix(dirPath) ? "UUID-ARCH" : "BOOT"
            }) { () -> DeleteDuplicatesJob in
                #expect(model.bulkDeleteRefusal(copy) == nil, "fixture: the path text alone says clear")
                let job = DeleteDuplicatesJob(model: model, volumePath: dirPath,
                                              hooks: .live, planRoot: dir.appendingPathComponent("plans"))
                job.start()
                await job.task?.value
                return job
            }
        }
        #expect(FileManager.default.fileExists(atPath: copyURL.path), "the copy on FamilyArchive stays")
        #expect(sha(copyURL.path) == before)
        #expect(job.result.deleted == 0, "\(job.state)")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []
        #expect(!names.contains { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) },
                "nothing was moved into a quarantine folder on the archive volume — \(names)")
        #expect(copy.purgedAt == nil)
    }
}

// MARK: - Rick's ruling, 2026-09-22: "For now we won't Remove anything from FamilyArchive"

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)   // the console flushes every 0.15 s
    return model.dashboard.consoleLines.joined(separator: "\n")
}

@MainActor
private func tidyModel() -> VideoScanModel {
    let model = isolatedModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_archfu_ignored_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    model.ignoredContentStore = IgnoredContentStore(directory: dir)
    return model
}

/// A still image — the kind Tidy Catalog sets aside.
@MainActor
private func still(_ path: String, md5: String) -> VideoRecord {
    let r = record(path)
    r.ext = "CR3"
    r.streamTypeRaw = StreamType.videoOnly.rawValue
    r.partialMD5 = md5
    r.sizeBytes = 10
    return r
}

@Suite("Archive follow-ups — nothing is Removed from the archive volume", .serialized)
@MainActor
struct CatalogRemovalArchiveVolumeTests {

    private let onVolume = "/Volumes/FamilyArchive/MoviesExpansion/1994 Christmas.mov"
    private let elsewhere = "/Volumes/CrucialX10/1994 Christmas.mov"

    @Test func removeFromCatalogPurgeLeavesAnArchiveVolumeRecordAndSaysSo() async {
        let model = tidyModel()
        designateFamilyArchive(model)
        let vol = record(onVolume), other = record(elsewhere)
        model.records = [vol, other]
        #expect(model.purgeRecords(ids: [vol.id, other.id]) == 1)
        #expect(vol.purgedAt == nil, "the MoviesExpansion record stays in the catalog")
        #expect(other.purgedAt != nil, "a record on another volume is still removable")
        let text = await consoleText(model)
        #expect(text.contains("Remove: left 1 file(s) alone — they live on FamilyArchive, the Master Archive volume, which only archive actions may change."),
                "\(text)")
    }

    @Test func removeFromCatalogSetAsideLeavesAnArchiveVolumeRecordAndSaysSo() async {
        let model = tidyModel()
        designateFamilyArchive(model)
        let vol = record(onVolume), other = record(elsewhere)
        vol.partialMD5 = "a1"; other.partialMD5 = "b1"
        model.records = [vol, other]
        #expect(model.removeFromCatalog(recordIDs: [vol.id, other.id]) == 1)
        #expect(vol.setAsideReason == nil && vol.purgedAt == nil, "the MoviesExpansion record is untouched")
        #expect(other.setAsideReason != nil, "a record on another volume is still set aside")
        let text = await consoleText(model)
        #expect(text.contains("Remove from Catalog: left 1 file(s) alone — they live on FamilyArchive, the Master Archive volume"),
                "\(text)")
    }

    @Test func tidyCatalogLeavesAnArchiveVolumeRecordAndSaysSo() async {
        let model = tidyModel()
        designateFamilyArchive(model)
        let vol = still("/Volumes/FamilyArchive/MoviesExpansion/IMG_1.cr3", md5: "s1")
        let other = still("/Volumes/CrucialX10/IMG_2.cr3", md5: "s2")
        model.records = [vol, other]
        var plan = await model.computeTidyCatalogPlan()
        #expect(plan.rows.map(\.id) == [other.id], "the preview leaves the archive-volume still out")
        // A plan built before the ruling / designation still lists it:
        // Apply refuses it anyway.
        plan.rows.append(.init(id: vol.id, filename: vol.filename, fullPath: vol.fullPath,
                               sizeBytes: vol.sizeBytes, reason: .stillImage))
        #expect(model.applyTidyCatalog(plan) == 1)
        #expect(vol.setAsideReason == nil && vol.purgedAt == nil, "the MoviesExpansion still is untouched")
        #expect(other.setAsideReason != nil, "the still on another volume is set aside")
        let text = await consoleText(model)
        #expect(text.contains("Tidy Catalog: left 1 file(s) alone — they live on FamilyArchive, the Master Archive volume"),
                "\(text)")
    }
}

// MARK: - The cached snapshot: lifecycle

@Suite("Archive follow-ups — cached archive-volume snapshot", .serialized)
@MainActor
struct ArchiveVolumeSnapshotCacheTests {

    @Test func provisionalRefusesWhatItCannotProveThenTheOffMainBuildClearsIt() async {
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let counter = ProbeCounter()
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ counter.note(); return ["/Volumes/CrucialX9"] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
                counter.note()
                if path.hasPrefix("/Volumes/FamilyArchive") { return "UUID-ARCH" }
                return path.hasPrefix("/Volumes/CrucialX9") ? "UUID-X9" : nil
            }) {
                // Before any build: disk-free, refuses other /Volumes paths.
                let early = model.archiveVolumeProtection()
                #expect(model.isArchiveVolumeSnapshotFresh == false)
                #expect(early?.verdict(forPath: "/Volumes/CrucialX9/a.mov") == .unprovable, "refuse over guess while building")
                #expect(early?.verdict(forPath: "/Volumes/FamilyArchive/x.mov") == .onArchiveVolume)
                #expect(early?.verdict(forPath: "/Users/rickb/Movies/a.mov") == .clear, "the boot disk is never the /Volumes archive")
                #expect(counter.mainThreadCalls == 0)
                let built = await model.refreshArchiveVolumeSnapshot(force: true)
                #expect(model.isArchiveVolumeSnapshotFresh)
                #expect(built?.isResolved == true)
                #expect(model.archiveVolumeProtection()?.verdict(forPath: "/Volumes/CrucialX9/a.mov") == .clear)
            }
        }
        #expect(counter.mainThreadCalls == 0, "every probe ran off the main thread")
        #expect(counter.offMainCalls >= 1, "and the build really probed")
    }

    @Test func aDesignationChangeOrAVolumeRenameMakesTheSnapshotStale() async throws {
        let model = isolatedModel()
        designateFamilyArchive(model)   // no UUID: the build is exact and cheap
        await model.refreshArchiveVolumeSnapshot(force: true)
        #expect(model.isArchiveVolumeSnapshotFresh)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, model.archiveVolumeSnapshotCache.installCount < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.archiveVolumeSnapshotCache.installCount >= 2, "a rename rebuilt the snapshot")
        designateFamilyArchive(model, at: "/Volumes/OtherArchive")
        #expect(model.archiveVolumeProtection()?.label == "OtherArchive", "a new designation never reads the old snapshot")
    }

    @Test func theMountTableForTheSnapshotListsLocalVolumesOnly() {
        let all = VolumeReachability.currentMountedRoots()
        let local = VolumeReachability.currentLocalMountedRoots()
        #expect(local.contains("/"), "the boot volume is local")
        #expect(local.isSubset(of: all), "network mounts are only ever left OUT")
    }
}

// MARK: - Transcode "Replace": Trash only, only after the new file exists

@Suite("Archive follow-ups — Transcode Replace goes to the Trash", .serialized)
@MainActor
struct TranscodeReplaceTrashTests {

    /// Off the archive: Replace moves the old file to the Trash (through
    /// the seam — never the user's real Trash), and only once the new
    /// output is complete; the new file takes the name.
    @Test func replaceOffTheArchiveTrashesTheOldFileAfterTheNewOneExists() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("transcode-replace"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let srcURL = sb.sources.appendingPathComponent("test_src.mov")
        try makeTestMovie(at: srcURL)
        let src = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        src.durationSeconds = 2
        let outDir = sb.root.appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: src, preset: .editingLT)
        try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 12)
        let oldSHA = sha(target.path)
        model.records = [src, MasterArchiveTestSupport.makeRecord(path: target.path)]

        final class Seen: @unchecked Sendable { var trashed: [String] = []; var partialPresent = false }
        let seen = Seen()
        let fakeTrash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let dirPath = outDir.path
        let job = TranscodeJob(record: src, preset: .editingLT, outputURL: target, model: model, replaceExisting: true)
        await DerivativeOutputPublish.$trashItem.withValue({ url in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []
            seen.partialPresent = names.contains { $0.contains(".vs-partial.") }
            seen.trashed.append(url.path)
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }) {
            job.start()
            await job.task?.value
        }
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(seen.trashed == [target.path], "the old file went to the Trash, once")
        #expect(seen.partialPresent, "…only while the finished new output already existed")
        #expect(sha(fakeTrash.appendingPathComponent(target.lastPathComponent).path) == oldSHA, "the old bytes are intact in the Trash")
        #expect(FileManager.default.fileExists(atPath: target.path) && sha(target.path) != oldSHA, "the new file took the name")
        #expect(job.publishedURL == target.standardizedFileURL)
        #expect(summary.contains("Trash"), "\(summary)")
    }

    /// Replace chosen for a file whose path text says "boot disk" but
    /// whose OWN volume is FamilyArchive (a symlinked / custom mount
    /// path): the removal-time UUID check keeps it; nothing is trashed.
    @Test func replaceOnAFileWhoseOwnVolumeIsTheArchiveKeepsItAndPublishesBeside() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("transcode-uuid"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let srcURL = sb.sources.appendingPathComponent("test_src.mov")
        try makeTestMovie(at: srcURL)
        let src = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        src.durationSeconds = 2
        let outDir = sb.root.appendingPathComponent("FamilyArchiveLink", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: src, preset: .editingLT)
        try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 13)
        let oldSHA = sha(target.path)
        model.records = [src, MasterArchiveTestSupport.makeRecord(path: target.path)]
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let linkPath = outDir.path
        final class Calls: @unchecked Sendable { var n = 0 }
        let trashCalls = Calls()
        let job = TranscodeJob(record: src, preset: .editingLT, outputURL: target, model: model, replaceExisting: true)
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ [] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ $0.hasPrefix(linkPath) ? "UUID-ARCH" : "BOOT" }) {
                await DerivativeOutputPublish.$trashItem.withValue({ _ in trashCalls.n += 1; return nil }) {
                    job.start()
                    await job.task?.value
                }
            }
        }
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(trashCalls.n == 0, "nothing on the archive's own volume is trashed")
        #expect(sha(target.path) == oldSHA)
        #expect(job.publishedURL != target.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: job.publishedURL.path))
        #expect(summary.contains("Master Archive volume"), "\(summary)")
    }
}

// MARK: - QA round 2 (2026-09-22): a stale snapshot never writes to the catalog

@Suite("QA archfu — a stale snapshot must not re-mark an ordinary duplicate", .serialized)
@MainActor
struct ArchiveSnapshotStaleWindowQATests {

    /// QA's red test, adapted to (b): while the snapshot is stale the
    /// pair is a transient SKIP (never `.refuse`, which re-marks Review);
    /// once fresh (a) it is authorized again.
    @Test func aMountMidRunDoesNotRefuseAnOrdinaryExtraCopy() async {
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let g = UUID()
        let keeper = record("/Volumes/CrucialX10/a.mov", group: g, disposition: .keep)
        let extra = record("/Volumes/CrucialX10/a copy.mov", group: g, disposition: .extraCopy)
        model.records = [keeper, extra]
        let entry = DeleteDuplicatesPlan.Entry(id: extra.id, path: extra.fullPath, filename: extra.filename, sizeBytes: 1,
                                               keeperID: keeper.id, keeperPath: keeper.fullPath,
                                               keeperFilename: keeper.filename, keeperStamp: nil)
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ ["/Volumes/CrucialX10"] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
                if path.hasPrefix("/Volumes/FamilyArchive") { return "UUID-ARCH" }
                return path.hasPrefix("/Volumes/CrucialX10") ? "UUID-X10" : nil
            }) {
                await model.refreshArchiveVolumeSnapshot(force: true)
                guard case .authorized = model.authorizeDuplicateDeletion(entry: entry, volumePath: "/Volumes/CrucialX10",
                                                                          crossVolumeMode: false, stage: "t") else {
                    Issue.record("fixture"); return
                }
                model.noteArchiveVolumeSnapshotStale(reason: "didMount (test)")
                switch model.authorizeDuplicateDeletion(entry: entry, volumePath: "/Volumes/CrucialX10",
                                                        crossVolumeMode: false, stage: "t") {
                case .refuse(let note):
                    Issue.record("stale snapshot refused (and re-marks Review) an X10 extra copy: \(note)")
                case .skip(let note, _):
                    #expect(note.contains("refreshing"), "\(note)")
                case .authorized:
                    break
                }
                await model.refreshArchiveVolumeSnapshot()
                guard case .authorized = model.authorizeDuplicateDeletion(entry: entry, volumePath: "/Volumes/CrucialX10",
                                                                          crossVolumeMode: false, stage: "t") else {
                    Issue.record("a fresh snapshot authorizes the pair again"); return
                }
            }
        }
        #expect(extra.duplicateDisposition == .extraCopy, "never re-marked")
    }

    /// Whole job: a mount lands while a run is verifying. Sensor only —
    /// the provisional snapshot refuses only /Volumes paths and a test
    /// cannot put real files there, so this pins "a mount mid-run changes
    /// nothing" rather than reproducing the refusal.
    @Test func aMountNotificationMidRunReMarksNothing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_archfu_mount_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<(FileHasher.segmentSize * 2)).map { UInt8($0 % 193) })
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let g = UUID()
        let keeperURL = dir.appendingPathComponent("test_keeper.mov")
        FileManager.default.createFile(atPath: keeperURL.path, contents: bytes)
        let keeper = record(keeperURL.path, group: g, disposition: .keep)
        var copies: [VideoRecord] = []
        for i in 1...3 {
            let u = dir.appendingPathComponent("test_copy\(i).mov")
            FileManager.default.createFile(atPath: u.path, contents: bytes)
            copies.append(record(u.path, group: g, disposition: .extraCopy))
        }
        for r in [keeper] + copies { r.sizeBytes = Int64(bytes.count); r.partialMD5 = "same" }
        model.records = [keeper] + copies
        addVerifiedArchiveFamily(to: model, keeper: keeper)
        designateFamilyArchive(model, uuid: "UUID-ARCH")

        final class Once: @unchecked Sendable { var fired = false }
        let once = Once()
        var hooks = SignatureVerification.Hooks(shouldCancel: { Task.isCancelled })
        hooks.didReadBlock = { _ in
            guard !once.fired else { return }
            once.fired = true
            DispatchQueue.main.async {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
            }
        }
        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path, hooks: hooks,
                                      planRoot: dir.appendingPathComponent("plans"))
        // Isolation: the snapshot build and the removal-time probe read an
        // injected mount table / UUIDs, never this host's real volumes
        // (a UUID designation otherwise reads every mounted root's UUID).
        // The archive (UUID-ARCH) is not mounted; the temp dir is boot disk.
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ [] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in "BOOT-UUID" }) {
                await model.refreshArchiveVolumeSnapshot(force: true)
                job.start()
                await job.task?.value
            }
        }
        #expect(once.fired, "fixture: the mount landed mid-run")
        #expect(copies.allSatisfy { $0.duplicateDisposition != .review }, "no extra copy was re-marked Review")
        #expect(job.result.deleted == 3, "\(job.state)")
    }
}

@Suite("QA archfu — catalog removal refuses FamilyArchive only, preview matches apply", .serialized)
@MainActor
struct CatalogRemovalUnprovableQATests {

    @Test func removeFromCatalogStillRemovesAnUnprovableRecord() async {
        let model = tidyModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let share = record("/Volumes/NetworkShare/a.mov"), onArch = record("/Volumes/FamilyArchive/MoviesExpansion/b.mov")
        model.records = [share, onArch]
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ [] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in nil }) {
                await model.refreshArchiveVolumeSnapshot(force: true)
                #expect(model.bulkDeleteRefusal(share) == .archiveVolumeUnprovable, "fixture: unprovable for a bulk DELETE")
                #expect(model.purgeRecords(ids: [share.id, onArch.id]) == 1)
            }
        }
        #expect(share.purgedAt != nil, "a network-share record is not FamilyArchive — Remove works")
        #expect(onArch.purgedAt == nil)
    }

    @Test func tidyPreviewLeavesOutArchiveVolumeRowsAndTheSummaryCountsWhatWasDone() async {
        let model = tidyModel()
        designateFamilyArchive(model)
        let vol = still("/Volumes/FamilyArchive/MoviesExpansion/IMG_1.cr3", md5: "s1")
        let other = still("/Volumes/CrucialX10/IMG_2.cr3", md5: "s2")
        let other2 = still("/Volumes/CrucialX10/IMG_3.cr3", md5: "s3")
        model.records = [vol, other, other2]
        let plan = await model.computeTidyCatalogPlan()
        #expect(Set(plan.rows.map(\.id)) == [other.id, other2.id], "the preview never lists an archive-volume file")
        #expect(plan.keptOnArchiveVolume == 1)
        #expect(plan.stillCount == 2)
        // A row the apply-time re-check drops (set aside meanwhile) is not counted.
        other2.setAsideReason = "removed-by-user"
        #expect(model.applyTidyCatalog(plan) == 1)
        let text = await consoleText(model)
        #expect(text.contains("Tidy Catalog: set aside 1 file(s) — 1 photos,"), "\(text)")
    }

    @Test func whatNextNamesOnlyTheRowsItRemoved() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("whatnext"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let onArch = MasterArchiveTestSupport.makeRecord(
            path: sb.archiveVolume.appendingPathComponent("MoviesExpansion/test_gone_arch.mov").path)
        let elsewhere = MasterArchiveTestSupport.makeRecord(path: sb.sources.appendingPathComponent("test_gone_src.mov").path)
        model.records = [onArch, elsewhere]
        let n = await model.removeMissingCopiesFromCatalog(recordIDs: [onArch.id, elsewhere.id], fileExists: { _ in false })
        #expect(n == 1)
        #expect(onArch.purgedAt == nil && elsewhere.purgedAt != nil)
        let text = await consoleText(model)
        let removedLine = text.split(separator: "\n").first { $0.contains("what-next: removed") }.map(String.init) ?? ""
        #expect(removedLine.contains("test_gone_src.mov") && !removedLine.contains("test_gone_arch.mov"), "\(removedLine)")
        #expect(text.contains("what-next: left 1 missing row in the catalog — on the Master Archive volume"), "\(text)")
    }
}

@Suite("QA archfu — publish leftovers and failure wording", .serialized)
struct DerivativePublishQATests {

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_archfu_pub_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func aRenameThatFailsAfterTheTrashSaysWhereThePreviousFileIs() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let final = d.appendingPathComponent("test_x.vs.edit.mov")
        let partial = DerivativeOutputPublish.uniquePartialURL(for: final)
        try Data([1]).write(to: final); try Data([2]).write(to: partial)
        let trashDir = d.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        do {
            _ = try DerivativeOutputPublish.publish(partial: partial.path, as: final, policy: .replaceViaTrash,
                                                    archiveCheck: nil, trash: { url in
                let dest = trashDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                try FileManager.default.moveItem(at: partial, to: trashDir.appendingPathComponent("gone"))  // rename will now fail
                return dest
            })
            Issue.record("the rename should have failed")
        } catch {
            #expect(error.localizedDescription.contains("is in the Trash at \(trashDir.path)"), "\(error.localizedDescription)")
        }
    }

    @Test func stalePartialsOfThisOutputAreSweptAndNothingElse() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let out = d.appendingPathComponent("test_x.vs.edit.mov")
        let old = Date().addingTimeInterval(-48 * 3600)
        func make(_ name: String, _ date: Date) throws -> URL {
            let u = d.appendingPathComponent(name); try Data([0]).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path); return u
        }
        let stale = try make("test_x.vs.edit.abcdef12.vs-partial.mov", old)
        let fresh = try make("test_x.vs.edit.12345678.vs-partial.mov", Date())
        let otherStem = try make("test_y.vs.edit.abcdef12.vs-partial.mov", old)
        let notOurs = try make("test_x.vs.edit.notahex!.vs-partial.mov", old)
        let media = try make("test_x.vs.edit.mov", old)
        let swept = DerivativeOutputPublish.sweepStalePartials(beside: out)
        #expect(swept == [stale.lastPathComponent])
        for u in [fresh, otherStem, notOurs, media] { #expect(FileManager.default.fileExists(atPath: u.path), "\(u.lastPathComponent)") }
    }

    @Test func thePartialNameCarriesTheMarkerTheScannerSkips() throws {
        let p = DerivativeOutputPublish.uniquePartialURL(for: URL(fileURLWithPath: "/tmp/a.vs.edit.mov"))
        #expect(p.lastPathComponent.contains(DerivativeOutputPublish.partialMarker))
        #expect(p.pathExtension == "mov")
        let walker = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VideoScan/FilesystemWalker.swift"), encoding: .utf8)
        #expect(walker.contains("url.lastPathComponent.contains(\"\(DerivativeOutputPublish.partialMarker)\")"),
                "FilesystemWalker skips the same marker")
    }

    /// Reformat publishes through `.keep`: a taken name keeps BOTH files.
    @Test func keepPolicyPublishesBesideAndDeletesNothing() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let final = d.appendingPathComponent("test_r.vs.hevc.20260922-120000.mp4")
        let partial = ReformatJob.partialURL(for: final)
        try Data([1]).write(to: final); try Data([2]).write(to: partial)
        let outcome = try DerivativeOutputPublish.publish(partial: partial.path, as: final,
                                                          policy: .keep(reason: "a file already has that name"),
                                                          archiveCheck: nil, trash: { _ in Issue.record("never trashes"); return nil })
        #expect(outcome.url.lastPathComponent == "test_r.vs.hevc.20260922-120000 2.mp4")
        #expect(try Data(contentsOf: final) == Data([1]))
        #expect(try Data(contentsOf: outcome.url) == Data([2]))
    }
}
