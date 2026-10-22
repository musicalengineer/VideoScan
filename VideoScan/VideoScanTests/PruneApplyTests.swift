// PruneApplyTests.swift
// The one prune plan, end to end on a sandbox promote
// (docs/design/pruneplan_simple_2026-10-21.md). A real Promote makes the
// fixity-verified archive file; the source keeps the promote's whole-file
// digest; a byte-identical copy in `Sources/copies` is given its own digest.
// The file operation is the tests' `removeFile` seam — a sandbox "Trash" —
// while the catalog and ledger record the one mode, `.toTrash`.
//
// Invariants pinned here (I1–I9 in the design):
//   I1 both files read in full in this batch, both match — stamps never stand in;
//   I2 archive volume / Read only / Archive backup / network / offline: never moved;
//   I3 Trash only (the ledger never says copyDeleted);
//   I4 every outcome named, a hold is never success;
//   I5 a row that changed between the list and the move is held;
//   I6 a version or a name-alike never reaches pruneOneCopy;
//   I7 one copyTrashed per file moved, one approval per batch;
//   I8 an offered copy's digest key IS the archive's (notes/stars/tags are keyed by it).
// ISOLATION: a poisoned archive digest, an unverified archive, a digest
// mismatch at the move — held, never trashed. Sandbox model, ledger, archive
// root; no real volume, no real Trash.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Prune — one plan, both files read, Trash only", .serialized)
@MainActor
struct PruneApplyTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord
        let copy: VideoRecord
        let archive: VideoRecord
        let copiesDir: URL
        let trashDir: URL
        var batch: Set<UUID> { [source.id] }
        var digest: String { archive.archiveFixity?.digest.lowercased() ?? "" }
    }

    /// Source A promoted; A2 a byte-identical copy in `Sources/copies` with
    /// its own whole-file digest. Both are offered against the archive file.
    static func fixture(_ label: String) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_a.mov"),
                                                       bytes: 48 * 1024, seed: 11)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1995")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA), "fixture: promote made an archive copy")
        MasterArchiveTestSupport.unlockTree(sb.root)   // the tests tamper with it, as bit rot would
        let digest = try #require(archive.archiveFixity?.digest.lowercased())
        try #require(CatalogCommit.digest(of: recA) == digest, "fixture: Promote bound the source's digest")

        let copies = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let a2 = copies.appendingPathComponent("test_prune_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let recA2 = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1995")
        let copyFixity = try #require(ContentFixity.captured(path: a2.path, digest: digest, byteCount: recA2.sizeBytes))
        recA2.contentFixity = copyFixity
        model.records.append(recA2)
        let trash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return Fixture(sb: sb, model: model, source: recA, copy: recA2, archive: archive, copiesDir: copies, trashDir: trash)
    }

    /// The file operation: into the sandbox "Trash", counted.
    final class Mover: @unchecked Sendable {
        private let lock = NSLock()
        private var moved: [String] = []
        let trash: URL
        init(trash: URL) { self.trash = trash }
        func move(_ url: URL) throws {
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent))
            lock.lock(); moved.append(url.path); lock.unlock()
        }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return moved }
    }

    /// Thread-safe tally of the paths opened for a full read.
    final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        func opens(of p: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == p }.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    static func hooks(_ mover: Mover, opens: OpenCounter? = nil,
                      beforeMutation: (@MainActor (String) -> Void)? = nil) -> VideoScanModel.PruneVerifyHooks {
        var h = VideoScanModel.PruneVerifyHooks(shouldCancel: { false })
        h.didOpen = opens.map { counter in { counter.add($0) } }
        h.beforeMutation = beforeMutation
        h.removeFile = { try mover.move($0) }
        h.isNetworkMount = { _ in false }
        return h
    }

    private func exists(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    /// Same byte count, different bytes — a size check cannot see it.
    private func rewriteSameSize(_ path: String, seed: UInt64) throws {
        let size = Int((try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int64 ?? 0)
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: size, seed: seed)
    }

    private func plan(_ f: Fixture, batch: Set<UUID>? = nil) async -> PrunePlan {
        await f.model.prunePlan(batch: batch ?? f.batch).shown()
    }

    private func apply(_ f: Fixture, _ shown: PrunePlan, selected: Set<UUID>,
                       hooks: VideoScanModel.PruneVerifyHooks) async -> VideoScanModel.PruneApplyOutcome {
        await f.model.applyPrune(shown: shown, selected: selected, batch: f.batch, batchID: "test-batch", hooks: hooks)
    }

    private func events(_ f: Fixture) async -> [MediaLedgerEvent] {
        await f.model.mediaLedger.waitForPendingWrites()
        return f.model.mediaLedger.allEvents()
    }

    // MARK: The default — everything identical offered and checked

    @Test("R1: the source and its byte-identical copy are offered; the archive file is never a row")
    func identicalCopiesAreOffered() async throws {
        let f = try await Self.fixture("offered"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        #expect(shown.offeredIDs == [f.source.id, f.copy.id], "\(shown)")
        #expect(shown.items.count == 1 && shown.items[0].id == f.archive.id)
        #expect(!shown.items[0].rows.contains { $0.id == f.archive.id })
        #expect(shown.adviceSentence(after: shown.offeredIDs)?.hasPrefix("1 file will exist only in the Master Archive") == true)
        // The Tidy lane sees the same plan, catalog-wide.
        let catalog = await f.model.prunePlan(batch: nil)
        #expect(catalog.offeredIDs == shown.offeredIDs)
    }

    @Test("I3 + I7: exactly the checked copies go, to the Trash; one copyTrashed each, one approval for the batch")
    func checkedCopiesGoToTheTrash() async throws {
        let f = try await Self.fixture("run"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover))
        #expect(out.trashed == 2 && out.held.isEmpty && out.failed.isEmpty, "\(out)")
        #expect(Set(mover.paths) == [f.source.fullPath, f.copy.fullPath])
        #expect(exists(f.archive), "the archive file is never touched")
        #expect(f.copy.lifecycleStage == .trashed && f.source.lifecycleStage == .trashed, "Trash only")
        let kinds = await events(f).map(\.event)
        #expect(kinds.filter { $0 == .copyTrashed }.count == 2, "\(kinds)")
        #expect(kinds.filter { $0 == .approval }.count == 1, "\(kinds)")
        #expect(!kinds.contains(.copyDeleted), "never a permanent delete")
        let approval = try #require(await events(f).first { $0.event == .approval })
        #expect(approval.detail[MediaLedgerEvent.Detail.count] == "2" && approval.detail[MediaLedgerEvent.Detail.action] == "trash")
        #expect(approval.detail[MediaLedgerEvent.Detail.barOverride] == nil, "no bar, no override")
    }

    @Test("SELECTION IS THE TRUTH: an unchecked copy stays; nothing checked moves nothing")
    func uncheckedCopiesStay() async throws {
        let f = try await Self.fixture("unchecked"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let mover = Mover(trash: f.trashDir)
        let none = await apply(f, shown, selected: [], hooks: Self.hooks(mover))
        #expect(none.trashed == 0 && mover.paths.isEmpty)
        let one = await apply(f, shown, selected: [f.copy.id], hooks: Self.hooks(mover))
        #expect(one.trashed == 1 && mover.paths == [f.copy.fullPath], "\(one)")
        #expect(exists(f.source), "unchecked → untouched")
    }

    // MARK: I1 — both full reads, this batch

    @Test("I1: the archive file is read in full once per batch, each copy once — a reproducing stamp never stands in")
    func bothFilesAreReadInFullEveryBatch() async throws {
        let f = try await Self.fixture("i1"); defer { f.sb.cleanup() }
        // A past Verify left a stamp on the archive that reproduces NOW; the
        // source carries Promote's stamp. Neither may replace a read.
        let archiveStamp = try #require(ContentFixity.captured(path: f.archive.fullPath, digest: f.digest,
                                                               byteCount: f.archive.sizeBytes))
        f.archive.contentFixity = archiveStamp
        let shown = await plan(f)
        let opens = OpenCounter()
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover, opens: opens))
        #expect(out.trashed == 2 && out.archiveReads == 1 && out.verified == 2, "\(out)")
        #expect(opens.opens(of: f.archive.fullPath) == 1, "once per batch: \(opens.all)")
        #expect(opens.opens(of: f.source.fullPath) == 1 && opens.opens(of: f.copy.fullPath) == 1, "\(opens.all)")
        // A second batch reads the archive file again.
        let g = try await Self.fixture("i1b"); defer { g.sb.cleanup() }
        let shownG = await plan(g)
        let opensG = OpenCounter()
        _ = await apply(g, shownG, selected: [g.copy.id], hooks: Self.hooks(Mover(trash: g.trashDir), opens: opensG))
        _ = await apply(g, shownG, selected: [g.source.id], hooks: Self.hooks(Mover(trash: g.trashDir), opens: opensG))
        #expect(opensG.opens(of: g.archive.fullPath) == 2, "a new batch never reuses another batch's read: \(opensG.all)")
    }

    @Test("I1 ISOLATION: archive bit rot under a reproducing stamp → every copy held 'archive copy changed', the archive read once, nothing moved")
    func archiveBitRotHoldsEverything() async throws {
        let f = try await Self.fixture("bitrot"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        try rewriteSameSize(f.archive.fullPath, seed: 505)
        let archiveStamp = try #require(ContentFixity.captured(path: f.archive.fullPath, digest: f.digest,
                                                               byteCount: f.archive.sizeBytes))
        f.archive.contentFixity = archiveStamp
        let opens = OpenCounter()
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover, opens: opens))
        #expect(out.trashed == 0 && mover.paths.isEmpty && out.held.count == 2, "\(out)")
        #expect(out.held.allSatisfy { $0.contains("archive copy changed") }, "\(out.held)")
        #expect(opens.opens(of: f.archive.fullPath) == 1, "a failed archive read is not repeated: \(opens.all)")
        #expect(opens.opens(of: f.copy.fullPath) == 0, "no copy is read against a changed archive")
        #expect(exists(f.source) && exists(f.copy))
    }

    @Test("ISOLATION: a copy rewritten after the list (its stored digest still claims a match) → read, mismatched, held")
    func aDigestMismatchAtTheMoveIsHeld() async throws {
        let f = try await Self.fixture("mismatch"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        try rewriteSameSize(f.copy.fullPath, seed: 77)
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: [f.copy.id], hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
        #expect(out.held.first?.contains(PruneReason.mismatchAtMove.text) == true, "\(out.held)")
        #expect(exists(f.copy) && f.copy.removal == nil)
    }

    @Test("ISOLATION: a poisoned archive digest offers nothing, and a list shown before the poison moves nothing")
    func aPoisonedArchiveDigestHoldsEverything() async throws {
        let f = try await Self.fixture("poison"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let fixity = try #require(f.archive.archiveFixity)
        f.archive.archiveFixity = ArchiveFixity(digest: String(repeating: "e", count: 64), verifiedAt: fixity.verifiedAt,
                                                sizeBytes: fixity.sizeBytes)
        let now = await plan(f)
        #expect(now.offeredIDs.isEmpty, "\(now)")
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty && out.held.count == 2, "\(out)")
        #expect(exists(f.source) && exists(f.copy))
    }

    @Test("ISOLATION: an archive file with no verified fixity offers nothing — its copies are listed 'not verified yet'")
    func anUnverifiedArchiveOffersNothing() async throws {
        let f = try await Self.fixture("unverified"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        f.archive.archiveFixity = nil
        let now = await plan(f)
        #expect(now.offeredIDs.isEmpty)
        #expect(now.items.first?.archive.reason == .archiveUnverified)
        #expect(now.items.first?.rows.first { $0.id == f.source.id }?.reason == .archiveUnverified, "\(now)")
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
    }

    // MARK: I5 — changed between the list and the move

    @Test("I5: a row moved in the catalog, a new A/V pair half, or a copy that appears after the list — held or untouched")
    func changesBetweenTheListAndTheMoveHold() async throws {
        let f = try await Self.fixture("i5"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let late = f.copiesDir.appendingPathComponent("test_prune_a_late.mov")
        try FileManager.default.copyItem(atPath: f.copy.fullPath, toPath: late.path)
        let recLate = MasterArchiveTestSupport.makeRecord(path: late.path)
        recLate.contentFixity = ContentFixity.captured(path: late.path, digest: f.digest, byteCount: recLate.sizeBytes)
        f.model.records.append(recLate)
        f.copy.fullPath = f.copy.fullPath + ".moved"      // the catalog row now points elsewhere
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs.union([recLate.id]), hooks: Self.hooks(mover))
        #expect(out.trashed == 1 && mover.paths == [f.source.fullPath], "\(out)")
        #expect(out.held.contains { $0.contains("changed since the list was shown") }, "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: late.path), "not on the list → never moved")
    }

    @Test("I5: a row rebuilt between its read and its move (same id, new instance) is held at the guard")
    func aRebuiltRowIsHeldAtTheGuard() async throws {
        let f = try await Self.fixture("rebuilt"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let mover = Mover(trash: f.trashDir)
        let copyID = f.copy.id
        let out = await apply(f, shown, selected: [copyID], hooks: Self.hooks(mover, beforeMutation: { _ in
            guard let i = f.model.records.firstIndex(where: { $0.id == copyID }) else { return }
            let clone = VideoRecord(id: copyID)
            clone.filename = f.model.records[i].filename
            clone.fullPath = f.model.records[i].fullPath
            clone.sizeBytes = f.model.records[i].sizeBytes
            clone.contentFixity = f.model.records[i].contentFixity
            f.model.records[i] = clone
        }))
        #expect(out.trashed == 0 && mover.paths.isEmpty && out.held.first?.contains("rebuilt") == true, "\(out)")
    }

    @Test("codex P2 (I5): the copy's CATALOG digest changed between its read and its move (same row, path and bytes) → held, kept")
    func aCatalogDigestChangeAtTheMoveIsHeld() async throws {
        let f = try await Self.fixture("digest_at_move"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let mover = Mover(trash: f.trashDir)
        let copy = f.copy
        let out = await apply(f, shown, selected: [copy.id], hooks: Self.hooks(mover, beforeMutation: { _ in
            copy.contentFixity = ContentFixity.captured(path: copy.fullPath, digest: String(repeating: "d", count: 64),
                                                        byteCount: copy.sizeBytes)
        }))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
        #expect(out.held.first?.contains("the catalog's record of this copy changed") == true, "\(out.held)")
        #expect(exists(copy) && copy.removal == nil)
    }

    @Test("I5: the copy or the archive file changed on disk between the read and the move → held by the re-stat")
    func aStampChangeAtTheMoveIsHeld() async throws {
        let f = try await Self.fixture("restat"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let mover = Mover(trash: f.trashDir)
        let copyPath = f.copy.fullPath, archivePath = f.archive.fullPath
        let out = await apply(f, shown, selected: [f.copy.id], hooks: Self.hooks(mover, beforeMutation: { _ in
            _ = try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: copyPath), bytes: 48 * 1024, seed: 11)
        }))
        #expect(out.trashed == 0 && out.held.first?.contains("changed on disk since it was read") == true, "\(out)")
        let g = try await Self.fixture("restat_archive"); defer { g.sb.cleanup() }
        let shownG = await plan(g)
        let gArchive = g.archive.fullPath
        let outG = await apply(g, shownG, selected: [g.copy.id], hooks: Self.hooks(Mover(trash: g.trashDir), beforeMutation: { _ in
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: gArchive)
        }))
        #expect(outG.trashed == 0 && outG.held.first?.contains("archive copy changed since it was read") == true, "\(outG)")
        _ = archivePath
    }

    // MARK: I2 — never listed, never moved

    @Test("I2: a byte-identical copy on the archive volume is never listed; forced through, it is never moved")
    func theArchiveVolumeIsNeverListedOrMoved() async throws {
        let f = try await Self.fixture("archvol"); defer { f.sb.cleanup() }
        let expansion = f.sb.archiveVolume.appendingPathComponent("MoviesExpansion", isDirectory: true)
        try FileManager.default.createDirectory(at: expansion, withIntermediateDirectories: true)
        let x = expansion.appendingPathComponent("test_prune_a.mov")
        try FileManager.default.copyItem(atPath: f.copy.fullPath, toPath: x.path)
        let recX = MasterArchiveTestSupport.makeRecord(path: x.path)
        recX.contentFixity = ContentFixity.captured(path: x.path, digest: f.digest, byteCount: recX.sizeBytes)
        f.model.records.append(recX)
        let shown = await plan(f)
        #expect(!shown.items.flatMap(\.rows).contains { $0.id == recX.id }, "FamilyArchive is never listed")
        // A stale / forged list that offers it anyway.
        let forged = PrunePlan.build([
            PruneSnapshot(id: f.archive.id, filename: f.archive.filename, fullPath: f.archive.fullPath,
                          digest: f.digest, isArchive: true, derivedFrom: f.source.id),
            PruneSnapshot(id: recX.id, filename: recX.filename, fullPath: recX.fullPath, digest: f.digest)])
        #expect(forged.offeredIDs == [recX.id], "fixture: the forged list offers it")
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, forged, selected: [recX.id], hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty && FileManager.default.fileExists(atPath: x.path), "\(out)")
        // And at the copy's own turn, the one bulk-delete gate refuses it.
        let item = VideoScanModel.PruneItem(copyID: recX.id, filename: recX.filename, path: recX.fullPath,
                                            sizeBytes: recX.sizeBytes, archiveID: f.archive.id, archivePath: f.archive.fullPath,
                                            archiveFilename: f.archive.filename, archiveDigest: f.digest)
        let one = await f.model.pruneOneCopy(item, batch: VideoScanModel.PruneBatchState(), hooks: Self.hooks(mover))
        guard case .held = one.result else { Issue.record("\(one)"); return }
        #expect(FileManager.default.fileExists(atPath: x.path))
    }

    @Test("I2: Read only and Archive backup drives are 'drive is protected'; offline is 'drive not connected'; a network drive at the move is held")
    func protectedDrivesAreNeverMoved() async throws {
        let f = try await Self.fixture("readonly"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        let ro = CatalogScanTarget(searchPath: f.copiesDir.path)
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        f.model.scanTargets.append(ro)
        _ = await f.model.refreshArchiveVolumeSnapshot(force: true)
        await f.model.refreshReadOnlyVolumeSnapshot()
        let now = await plan(f)
        #expect(now.items.first?.rows.first { $0.id == f.copy.id }?.reason == .driveProtected, "\(now)")
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: [f.copy.id], hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty && FileManager.default.fileExists(atPath: f.copy.fullPath), "\(out)")

        let g = try await Self.fixture("backup"); defer { g.sb.cleanup() }
        let bk = CatalogScanTarget(searchPath: g.copiesDir.path)
        bk.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil, isArchiveBackup: true)
        g.model.scanTargets.append(bk)
        _ = await g.model.refreshArchiveVolumeSnapshot(force: true)
        await g.model.refreshReadOnlyVolumeSnapshot()
        let gp = await plan(g)
        #expect(gp.items.first?.rows.first { $0.id == g.copy.id }?.reason == .driveProtected, "\(gp)")

        let h = try await Self.fixture("offline"); defer { h.sb.cleanup() }
        let copyID = h.copy.id
        let off = await h.model.prunePlan(batch: h.batch, isOnline: { $0.id != copyID })
        #expect(off.items.first?.rows.first { $0.id == copyID }?.reason == .driveOffline)

        let n = try await Self.fixture("network"); defer { n.sb.cleanup() }
        let shownN = await plan(n)
        let netPath = n.copy.fullPath
        var hooks = Self.hooks(Mover(trash: n.trashDir))
        hooks.isNetworkMount = { $0 == netPath }
        let outN = await apply(n, shownN, selected: [n.copy.id], hooks: hooks)
        #expect(outN.trashed == 0 && outN.held.first?.contains("network") == true, "\(outN)")
    }

    @Test("viewer mode never deletes")
    func readOnlyViewersNeverDelete() async throws {
        let f = try await Self.fixture("viewer"); defer { f.sb.cleanup() }
        let shown = await plan(f)
        f.model.isReadOnly = true
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: shown.offeredIDs, hooks: Self.hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty)
    }

    // MARK: I6 — versions and name-alikes never reach the move

    @Test("I6: a trimmed version and a same-name copy are listed with their reason, and a check on them is never read or moved")
    func versionsAndNameAlikesNeverReachTheMove() async throws {
        let f = try await Self.fixture("i6"); defer { f.sb.cleanup() }
        let v = try MasterArchiveTestSupport.writeBlob(at: f.copiesDir.appendingPathComponent("test_prune_a_trimmed.mov"),
                                                       bytes: 20 * 1024, seed: 8)
        let recV = MasterArchiveTestSupport.makeRecord(path: v.path)
        recV.derivedFrom = f.source.id; recV.derivationKind = "trim"
        let versionFixity = try #require(ContentFixity.captured(path: v.path, digest: String(repeating: "c", count: 64),
                                                                byteCount: recV.sizeBytes))
        recV.contentFixity = versionFixity
        let nameDir = f.sb.sources.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: nameDir, withIntermediateDirectories: true)
        let n = try MasterArchiveTestSupport.writeBlob(at: nameDir.appendingPathComponent(f.archive.filename), bytes: 1024, seed: 3)
        let recN = MasterArchiveTestSupport.makeRecord(path: n.path)
        f.model.records.append(contentsOf: [recV, recN])
        let shown = await plan(f)
        let rows = shown.items.flatMap(\.rows)
        #expect(rows.first { $0.id == recV.id }?.reason == .version, "\(rows)")
        #expect(rows.first { $0.id == recN.id }?.reason == .notHashed, "\(rows)")
        let prepared = VideoScanModel.pruneTargets(shown: shown, selected: [recV.id, recN.id], fresh: shown)
        #expect(prepared.items.isEmpty && prepared.held.count == 2, "\(prepared.held)")
        let opens = OpenCounter()
        let mover = Mover(trash: f.trashDir)
        let out = await apply(f, shown, selected: [recV.id, recN.id], hooks: Self.hooks(mover, opens: opens))
        #expect(out.trashed == 0 && mover.paths.isEmpty && opens.all.isEmpty, "never read, never moved: \(out)")
    }

    // MARK: I8 — the digest key is the archive's

    @Test("I8: every offered copy carries the archive file's digest key (notes, stars and tags are keyed by it); a copy with a note still goes and its note is not on a different key")
    func offeredCopiesShareTheArchiveDigestKey() async throws {
        let f = try await Self.fixture("i8"); defer { f.sb.cleanup() }
        f.copy.userNotes = "Grandpa's 1952 Christmas"
        f.copy.starRating = 3
        f.copy.tags = ["keepsake"]
        let shown = await plan(f)
        let archiveKey = CatalogCommit.digest(of: f.archive)
        #expect(archiveKey != nil)
        for id in shown.offeredIDs {
            #expect(CatalogCommit.digest(of: try #require(f.model.record(forID: id))) == archiveKey, "\(id)")
        }
        // A copy whose digest key differs from the archive's is never offered.
        f.copy.contentFixity = ContentFixity.captured(path: f.copy.fullPath, digest: String(repeating: "d", count: 64),
                                                      byteCount: f.copy.sizeBytes)
        let now = await plan(f)
        #expect(!now.offeredIDs.contains(f.copy.id))
    }

    // MARK: I4 — named outcomes

    @Test("I4: only a failure AT THE MOVE is an error; a hold is a decision, never success")
    func whichCopyResultsAreErrors() {
        typealias R = VideoScanModel.PruneCopyResult
        #expect(R.failed("permission denied").errorText == "permission denied")
        #expect(R.alreadyMissing.errorText != nil)
        #expect(R.skippedOffline.errorText != nil)
        #expect(R.held("changed").errorText == nil)
        #expect(R.trashed(bytes: 1).errorText == nil)
        var o = VideoScanModel.PruneApplyOutcome()
        let item = VideoScanModel.PruneItem(copyID: UUID(), filename: "x.mov", path: "/x", sizeBytes: 1, archiveID: UUID(),
                                            archivePath: "/a", archiveFilename: "a", archiveDigest: "d")
        o.absorb(.held("its archive copy changed"), item: item)
        #expect(o.trashed == 0 && o.held == ["x.mov — its archive copy changed"])
        #expect(o.summary.hasPrefix("Moved 0 copies to the Trash") && o.summary.contains("1 held back"), "\(o.summary)")
    }

    @Test("the sheet: Apply needs a selection, once, never while re-planning, never on a viewer")
    func applyIsOfferedOnlyWithSomethingChecked() {
        #expect(ArchivedWhatNextSheet.canApply(selectedCount: 1, applying: false, readOnly: false))
        #expect(!ArchivedWhatNextSheet.canApply(selectedCount: 0, applying: false, readOnly: false))
        #expect(!ArchivedWhatNextSheet.canApply(selectedCount: 1, applying: true, readOnly: false))
        #expect(!ArchivedWhatNextSheet.canApply(selectedCount: 1, applying: false, readOnly: true))
        #expect(!ArchivedWhatNextSheet.canApply(selectedCount: 1, applying: false, readOnly: false, reloading: true))
    }

    // MARK: Media matrix — the read is content-agnostic; every container goes the same way

    @Test("media matrix: an identical copy of each container is read in full and moved", arguments: ["mp4", "mov", "mkv", "mxf", "avi"])
    func everyContainerIsReadAndMoved(ext: String) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_matrix_\(ext)"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_matrix.\(ext)"),
                                                       bytes: 24 * 1024, seed: 21)
        let rec = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1980")
        model.records = [rec]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        await job.completionTask?.value
        let shown = await model.prunePlan(batch: [rec.id]).shown()
        #expect(shown.offeredIDs == [rec.id], "\(ext): \(shown)")
        let trash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let opens = OpenCounter()
        let out = await model.applyPrune(shown: shown, selected: [rec.id], batch: [rec.id], batchID: "m",
                                         hooks: Self.hooks(Mover(trash: trash), opens: opens))
        #expect(out.trashed == 1 && opens.opens(of: a.path) == 1, "\(ext): \(out)")
    }

    // MARK: Scale — the plan for 100k records, off the main actor, within budget

    @Test("SCALE: prunePlan over 100k records (1k archive files, a tenth of the rest identical) stays within budget, built off the main actor",
          .timeLimit(.minutes(1)))
    func planScale100k() async throws {
        let model = VideoScanModel()
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 1_000, mtimeNs: 1)
        func hex(_ n: Int) -> String { String(format: "%064x", n) }
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<1_000 {
            let a = VideoRecord()
            a.filename = "a_\(i).mov"; a.fullPath = "/Volumes/FamilyArchive/Archive/a_\(i).mov"
            a.sizeBytes = 1_000
            a.derivationKind = VideoRecord.archivePromotionDerivationKind
            a.archiveFixity = ArchiveFixity(digest: hex(i), verifiedAt: Date(), sizeBytes: 1_000)
            recs.append(a)
        }
        for i in 0..<99_000 {
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"; r.fullPath = "/Volumes/T\(i % 9)/clip_\(i).mov"
            r.sizeBytes = 1_000
            let d = i % 10 == 0 ? hex(i % 1_000) : hex(1_000_000 + i)
            r.contentFixity = ContentFixity(digest: d, byteCount: 1_000, stamp: stamp, computedAt: Date())
            recs.append(r)
        }
        model.records = recs
        let started = Date()
        let plan = await model.prunePlan(batch: nil, isOnline: { _ in true },
                                         disk: .init(isMissing: { _ in false }, isNetwork: { _ in false }))
        let elapsed = Date().timeIntervalSince(started)
        #expect(plan.offeredCount == 9_900, "\(plan.offeredCount)")
        #expect(plan.shown().rowCount == PrunePlan.maxRows)
        #expect(elapsed < 10, "100k records took \(elapsed)s")
    }
}
