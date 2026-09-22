// DeleteDuplicatesOfferShadowTests.swift — an un-actionable plan never
// hides a plan that owes a put-back (reviewer G1, 2026-09-21), and a
// Discard of a row whose recorded quarantine folder is already empty does
// not claim a file is still there (G2). Fixtures in temp dirs only.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func qaTempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_qared_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func qaWrite(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }
private func qaSHA(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}
private let qaBlock = FileHasher.segmentSize
private let qaSize = qaBlock * 3

@MainActor private func qaModel(_ home: URL) -> VideoScanModel {
    let m = VideoScanModel()
    m.catalogStore = CatalogStore(directory: home.appendingPathComponent("catalog", isDirectory: true))
    m.mediaLedger = MediaLedger(directory: home.appendingPathComponent("ledger", isDirectory: true))
    return m
}
@MainActor private func qaRecord(_ path: String, group: UUID, _ d: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path; r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = Int64(qaSize); r.partialMD5 = "same"; r.durationSeconds = 61
    r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
    return r
}
private final class QAProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var action: (@Sendable () -> Void)?
    func onFirstQuarantineBlock(_ a: @escaping @Sendable () -> Void) { lock.withLock { action = a } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(shouldCancel: { Task.isCancelled }, didReadBlock: { [self] label in
            guard label == "quarantine" else { return }
            let a: (@Sendable () -> Void)? = lock.withLock { guard !fired else { return nil }; fired = true; return action }
            a?()
        })
    }
}
private func qaQuarantineFolders(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

/// keeper (stored fixity → single-read path) + one extra + verified archive
/// family (3 copies remain → permanent tier). Plans/catalog live OUTSIDE
/// the "volume" so the volume can go away by rename.
@MainActor private struct QARig {
    let home: URL, dir: URL, root: URL
    let model: VideoScanModel
    let keeper: VideoRecord, copy: VideoRecord
    let bytes: [UInt8]
    init(_ label: String, copyBytes: [UInt8]? = nil) {
        home = qaTempDir(label + "-home"); dir = qaTempDir(label + "-volume")
        root = home.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<qaSize).map { UInt8($0 % 191) }
        let k = dir.appendingPathComponent("keeper.mov"); qaWrite(k, bytes)
        let c = dir.appendingPathComponent("copy1.mov"); qaWrite(c, copyBytes ?? bytes)
        let g = UUID()
        model = qaModel(home)
        keeper = qaRecord(k.path, group: g, .keep)
        keeper.contentFixity = ContentFixity.captured(path: k.path, digest: qaSHA(k), byteCount: Int64(qaSize))
        copy = qaRecord(c.path, group: g, .extraCopy)
        model.records = [keeper, copy]
        _ = addVerifiedArchiveFamily(to: model, keeper: keeper)
    }
    var offline: URL { URL(fileURLWithPath: dir.path + "-offline") }
    func cleanup() {
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: offline)
        try? FileManager.default.removeItem(at: home)
    }
    /// A plan whose row is still `.pending` on disk while its file already
    /// sits in the derived quarantine folder: the crash landed after the
    /// single-read path's move and during its hash, before the ticket save.
    func unjournaledCrash() throws -> (plan: DeleteDuplicatesPlan, qfile: URL) {
        let e = DeleteDuplicatesPlan.Entry(id: copy.id, path: copy.fullPath, filename: copy.filename, sizeBytes: copy.sizeBytes,
                                           keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                           keeperStamp: FileIdentityStamp.capture(path: keeper.fullPath))
        let plan = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [e])
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        let q = dir.appendingPathComponent(DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: copy.id),
                                           isDirectory: true)
        try FileManager.default.createDirectory(at: q, withIntermediateDirectories: false)
        let qfile = q.appendingPathComponent(copy.filename)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: copy.fullPath), to: qfile)
        return (plan, qfile)
    }
}

@MainActor private func qaConsole(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce
    return model.dashboard.consoleLines.joined(separator: "\n")
}

/// An older plan (one untouched pending row) on drive X, saved to `root`.
@MainActor private func qaAwayPlan(root: URL, catalog: String) throws -> (plan: DeleteDuplicatesPlan, x: URL) {
    let x = qaTempDir("shadow-X")
    let xFile = x.appendingPathComponent("x.mov"); qaWrite(xFile, [1, 2, 3])
    let xe = DeleteDuplicatesPlan.Entry(id: UUID(), path: xFile.path, filename: "x.mov", sizeBytes: 3,
                                        keeperID: UUID(), keeperPath: x.appendingPathComponent("k.mov").path,
                                        keeperFilename: "k.mov")
    let older = DeleteDuplicatesPlan(createdAt: Date().addingTimeInterval(-3600), volumePath: x.path,
                                     catalogLocation: catalog,
                                     crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [xe])
    try DeleteDuplicatesPlanStore.save(older, root: root)
    return (older, x)
}

@Suite("Delete Duplicates — an un-actionable plan never hides one that owes a put-back", .serialized)
@MainActor
struct DeleteDuplicatesOfferShadowTests {

    /// G1 (reviewer, 2026-09-21) — VideoScanModel+Duplicates.swift
    /// `checkForUnfinishedDeleteDuplicatesPlans`. An older suspended plan on
    /// drive X (unplugged, or dead) can be neither Resumed nor Discarded; it
    /// used to be offered first (oldest-only) and so hid a NEWER plan whose
    /// file a crash left in quarantine on the present drive. RED on main
    /// 02685f92 (the reviewer's original asserted the older plan was offered
    /// first, then that Discard's refusal would surface the newer — it never
    /// did). Now: the newer plan is offered at once; the away plan is left on
    /// disk untouched and offered again when X returns.
    @Test func olderPlanOnAnAwayDriveDoesNotHideANewerPlanOwingAPutBack() async throws {
        let rig = QARig("shadow"); defer { rig.cleanup() }
        let (older, x) = try qaAwayPlan(root: rig.root, catalog: rig.model.catalogStore.fileLocation)
        defer { try? FileManager.default.removeItem(at: x) }
        let olderURL = DeleteDuplicatesPlanStore.planURL(for: older.id, root: rig.root)
        let olderBytes = try Data(contentsOf: olderURL)
        let xAway = URL(fileURLWithPath: x.path + "-away")
        try FileManager.default.moveItem(at: x, to: xAway)                           // X unplugged
        defer { try? FileManager.default.removeItem(at: xAway) }
        let (newer, qfile) = try rig.unjournaledCrash()                              // crash mid-hash here

        let launch = qaModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == newer.id,
                "the plan owing \(qfile.lastPathComponent) a put-back must be offered, not the plan X blocks")
        let console = await qaConsole(launch)
        #expect(console.contains("1 more on a drive that is not connected waits until it returns"), "\(console)")
        #expect(try Data(contentsOf: olderURL) == olderBytes, "the away plan is left on disk untouched")

        // The newer plan is actionable: Discard runs Resume's recovery → put back.
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(FileManager.default.fileExists(atPath: rig.copy.fullPath), "the quarantined file is back at its path")
        #expect(!FileManager.default.fileExists(atPath: qfile.path))
        let left = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).map(\.id)
        #expect(left == [older.id], "only the away plan is still unfinished: \(left)")
        // Only away plans left: the oldest is still offered so the user hears of it; Discard refuses, nothing changes.
        #expect(launch.pendingDeleteDuplicatesResume?.id == older.id)
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(try Data(contentsOf: olderURL) == olderBytes, "Discard refused while X is away — plan unchanged")

        // X returns: offered again, actionable.
        try FileManager.default.moveItem(at: xAway, to: x)
        let later = qaModel(rig.home)
        later.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(later.pendingDeleteDuplicatesResume?.id == older.id, "offered again once its drive is back")
    }

    /// G1 — ordering among actionable plans is unchanged: an away plan
    /// OLDER than two present plans is skipped, and the present ones are
    /// still offered oldest first.
    @Test func awayPlanIsSkippedAndPresentPlansStayOldestFirst() async throws {
        let home = qaTempDir("order"); defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("plans", isDirectory: true)
        let model = qaModel(home)
        let (away, x) = try qaAwayPlan(root: root, catalog: model.catalogStore.fileLocation)
        try FileManager.default.removeItem(at: x)
        func present(_ name: String, age: TimeInterval) throws -> DeleteDuplicatesPlan {
            let v = home.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
            var p = DeleteDuplicatesPlan(volumePath: v.path, catalogLocation: model.catalogStore.fileLocation,
                                         crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                         entries: [DeleteDuplicatesPlan.Entry(id: UUID(), path: v.appendingPathComponent("x.mov").path,
                                                                              filename: "x.mov", sizeBytes: 1, keeperID: UUID(),
                                                                              keeperPath: "/k", keeperFilename: "k")])
            p.createdAt = Date().addingTimeInterval(-age)
            try DeleteDuplicatesPlanStore.save(p, root: root)
            return p
        }
        let mid = try present("Mid", age: 1_800), young = try present("Young", age: 60)
        model.checkForUnfinishedDeleteDuplicatesPlans(root: root)
        #expect(model.pendingDeleteDuplicatesResume?.id == mid.id)
        let console = await qaConsole(model)
        #expect(console.contains("1 more unfinished run will be offered after it, oldest first"), "\(console)")
        #expect(console.contains("1 more on a drive that is not connected waits until it returns"), "\(console)")
        model.discardPendingDeleteDuplicatesPlan(root: root)
        #expect(model.pendingDeleteDuplicatesResume?.id == young.id)
        model.discardPendingDeleteDuplicatesPlan(root: root)
        #expect(model.pendingDeleteDuplicatesResume?.id == away.id, "only the away plan is left — still offered")
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in }).map(\.id) == [away.id])
    }

    /// G2 (nit) — Discard: a `.verified` row whose recorded quarantine
    /// folder EXISTS but is EMPTY (the file was unlinked just before a
    /// crash, after the ticket save). On a reachable drive nothing is owed:
    /// the plan is discarded and filed; it no longer says "not discarded —
    /// 1 file is still in quarantine". The empty folder is left on disk.
    @Test func discardClosesAnEmptyRecordedQuarantineFolderOnAReachableDrive() async throws {
        let rig = QARig("g2here"); defer { rig.cleanup() }
        var (plan, qfile) = try rig.unjournaledCrash()
        let stamp = try #require(FileIdentityStamp.capture(path: qfile.path))
        plan.setQuarantined(rig.copy.id, directory: qfile.deletingLastPathComponent().path, stamp: stamp)
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        try FileManager.default.removeItem(at: qfile)                                 // unlinked, then the crash
        let launch = qaModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "precondition: offered")
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)

        let console = await qaConsole(launch)
        #expect(!DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id },
                "nothing is owed — the plan is filed. Console:\n\(console)")
        #expect(!console.contains("still in quarantine"), "\(console)")
        #expect(console.contains("is empty — nothing to put back"), "\(console)")
        #expect(console.contains("discarded the unfinished run"), "\(console)")
        #expect(FileManager.default.fileExists(atPath: qfile.deletingLastPathComponent().path),
                "the empty folder is not removed by Discard")
    }

    /// G2 — the other half: the SAME row on a drive that is not reachable
    /// (mount point lingering as a directory, not in the mount table) stays
    /// owed. Pinned at the shared helper with an injected mount table, since
    /// Discard itself refuses outright while the drive is away.
    @Test func anEmptyRecordedFolderOnAnUnreachableDriveStaysOwed() async throws {
        let rig = QARig("g2away"); defer { rig.cleanup() }
        var (plan, qfile) = try rig.unjournaledCrash()
        let stamp = try #require(FileIdentityStamp.capture(path: qfile.path))
        plan.setQuarantined(rig.copy.id, directory: qfile.deletingLastPathComponent().path, stamp: stamp)
        try FileManager.default.removeItem(at: qfile)
        let volumesRoot = rig.dir.deletingLastPathComponent().path + "/"             // rig.dir is "under /Volumes/"

        var awayRow = plan.entries[0]
        let closedAway = DeleteDuplicatesJob.closeEmptyRecordedQuarantine(
            &awayRow, volumePath: rig.dir.path, volumeName: plan.volumeName,
            mountedRoots: [], volumesRoot: volumesRoot)                               // not in the mount table
        #expect(closedAway == nil)
        #expect(awayRow.quarantineDirectory == plan.entries[0].quarantineDirectory, "unreachable drive: still owed")
        #expect(awayRow.quarantinedStamp != nil)

        var hereRow = plan.entries[0]
        let closedHere = DeleteDuplicatesJob.closeEmptyRecordedQuarantine(
            &hereRow, volumePath: rig.dir.path, volumeName: plan.volumeName,
            mountedRoots: [rig.dir.path], volumesRoot: volumesRoot)                   // mounted
        #expect(closedHere == qfile.deletingLastPathComponent().lastPathComponent)
        #expect(hereRow.quarantineDirectory == nil && hereRow.quarantinedStamp == nil)

        // A folder that still HOLDS the file is never closed, reachable or not.
        qaWrite(qfile, rig.bytes)
        var heldRow = plan.entries[0]
        #expect(DeleteDuplicatesJob.closeEmptyRecordedQuarantine(
            &heldRow, volumePath: rig.dir.path, volumeName: plan.volumeName,
            mountedRoots: [rig.dir.path], volumesRoot: volumesRoot) == nil)
        #expect(heldRow.quarantineDirectory != nil)
    }

    /// G2, same pattern in Resume: the empty recorded folder is closed at
    /// the re-check, so the row skipped as "gone before the crash" is not
    /// left stranded and the finished plan is filed rather than offered
    /// for a Put Back of nothing.
    @Test func resumeClosesAnEmptyRecordedQuarantineFolder() async throws {
        let rig = QARig("g2resume"); defer { rig.cleanup() }
        var (plan, qfile) = try rig.unjournaledCrash()
        let stamp = try #require(FileIdentityStamp.capture(path: qfile.path))
        plan.setQuarantined(rig.copy.id, directory: qfile.deletingLastPathComponent().path, stamp: stamp)
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        try FileManager.default.removeItem(at: qfile)
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan).entries[0]
        #expect(row.quarantineDirectory == nil, "row \(row.status): \(row.note)")
        #expect(!row.needsRecovery)
        #expect(!DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id })
    }
}
