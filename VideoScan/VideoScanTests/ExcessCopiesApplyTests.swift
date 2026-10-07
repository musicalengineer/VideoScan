// ExcessCopiesApplyTests.swift
// "Delete excess copies", Tier 1 — the run, end to end on a sandbox
// promote (docs/design/delete_excess_copies_2026_10_06.md + C05 + Rick's
// decisions 2026-10-07). A real Promote makes the fixity-verified archive
// file; byte-identical copies of the source sit in `Sources/copies`. The
// lane's file operation is the tests' `removeFile` seam, which moves the
// file into a sandbox "Trash" folder — the real Trash is never touched —
// while the catalog / ledger still record the lane's one mode, `.toTrash`.
//
// Pins (each must name its outcome; none reports success unless the file
// is in the Trash):
//   * the last copy outside the archive → the archive file is read in full
//     in this job, even with a stamp that reproduces (C05-F1);
//   * archive bit rot under a reproducing stamp → archive copy changed,
//     nothing moved (C05-F1's own scenario);
//   * forecast == run; never more than the forecast (amendment 4);
//   * the copy changed, the archive changed, a hold added mid-job → held;
//   * viewer mode, a Read-only drive, an Archive backup drive, a network
//     mount → refused, nothing moved;
//   * a sampled-hash-only candidate whose bytes differ → never moved;
//   * Trash only: lifecycle .trashed, a copyTrashed ledger line, never
//     copyDeleted;
//   * ISOLATION: a damaged Keep list holds everything (unknown means keep).
//
// ISOLATION: sandbox model, ledger, archive root and UserDefaults suite; no
// real volume, no real prefs, no real Trash.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Excess copies — the run", .serialized)
@MainActor
struct ExcessCopiesApplyTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord
        let copy: VideoRecord
        let archive: VideoRecord
        let copiesDir: URL
        let trashDir: URL
        let defaults: UserDefaults
        let suiteName: String

        var env: VideoScanModel.ExcessLaneEnvironment {
            .init(isNetworkMount: { _ in false }, keepDefaults: defaults)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            sb.cleanup()
        }
    }

    static let hash = "v1:test-excess-a"
    static let seconds = 60.0

    /// Source A promoted to the archive; A2 a byte-identical copy in
    /// `Sources/copies`. Both are outside the archive, both match the
    /// archive file by `v1:` hash + size, both are 60 s like the archive.
    private func fixture(_ label: String) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox("excess_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_excess_a.mov"),
                                                       bytes: 48 * 1024, seed: 11)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1995")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA), "fixture: promote made an archive copy")
        try #require(archive.archiveFixity != nil, "fixture: the archive file carries its read-back digest")
        MasterArchiveTestSupport.unlockTree(sb.root)   // the tests tamper with it, as bit rot would

        let copies = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let a2 = copies.appendingPathComponent("test_excess_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let recA2 = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1995")
        model.records.append(recA2)
        for r in [recA, recA2, archive] { r.contentHash = Self.hash; r.durationSeconds = Self.seconds }
        try #require(recA.starRating == 3, "fixture: Promote raised the source to ★★★ — and that is not a hold")
        let trash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let suite = "test_excess_\(label)_\(UUID().uuidString.prefix(8))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return Fixture(sb: sb, model: model, source: recA, copy: recA2, archive: archive,
                       copiesDir: copies, trashDir: trash, defaults: defaults, suiteName: suite)
    }

    /// The file operation: into the sandbox "Trash", counted.
    final class Mover: @unchecked Sendable {
        private let lock = NSLock()
        private var moved: [String] = []
        let trash: URL
        init(trash: URL) { self.trash = trash }
        func move(_ url: URL) throws {
            let dest = trash.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            lock.lock(); moved.append(url.path); lock.unlock()
        }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return moved }
    }

    final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        func opens(of p: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == p }.count }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    private func hooks(_ mover: Mover, opens: OpenCounter? = nil,
                       beforeMutation: (@MainActor (String) -> Void)? = nil) -> VideoScanModel.PruneVerifyHooks {
        var h = VideoScanModel.PruneVerifyHooks(shouldCancel: { false })
        h.didOpen = opens.map { counter in { counter.add($0) } }
        h.beforeMutation = beforeMutation
        h.removeFile = { try mover.move($0) }
        return h
    }

    private func exists(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    /// A scan-target change makes the drive snapshots provisional (and the
    /// gate refuses "cannot prove this drive is not the archive" meanwhile —
    /// safe, and transient). Let the rebuilds land, as they do in the app.
    private func addTarget(_ t: CatalogScanTarget, to model: VideoScanModel) async {
        model.scanTargets.append(t)
        _ = await model.refreshArchiveVolumeSnapshot(force: true)
        await model.refreshReadOnlyVolumeSnapshot()
    }

    /// Same byte count, different bytes — a stat-size check cannot see it.
    private func rewriteSameSize(_ path: String, seed: UInt64) throws {
        let size = Int((try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int64 ?? 0)
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: size, seed: seed)
    }

    /// A stored whole-file fixity on the archive record whose stamp
    /// reproduces NOW and whose digest is `digest` — what a past Verify
    /// Archive Copies leaves (and what bit rot would leave unchanged).
    private func stampArchive(_ f: Fixture, digest: String) throws {
        let fixity = try #require(ContentFixity.captured(path: f.archive.fullPath, digest: digest,
                                                         byteCount: f.archive.sizeBytes))
        f.archive.contentFixity = fixity
    }

    // MARK: Forecast == run, Trash only

    @Test("forecast == run: exactly the offered copies go, to the Trash, and the archive file stays")
    func forecastEqualsRun() async throws {
        let f = try await fixture("forecast"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offeredIDs == [f.source.id, f.copy.id], "\(plan)")
        #expect(plan.items.count == 1 && plan.items[0].leavesArchiveOnly, "the dialog must say archive-only")
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(out.trashed == 2 && out.held.isEmpty && out.failed.isEmpty, "\(out)")
        #expect(Set(mover.paths) == Set(plan.offered.map(\.fullPath)), "moved == forecast")
        #expect(exists(f.archive), "the archive file is never touched")
        #expect(f.copy.lifecycleStage == .trashed && f.source.lifecycleStage == .trashed, "Trash only")
        await f.model.mediaLedger.waitForPendingWrites()
        let kinds = f.model.mediaLedger.allEvents().map(\.event)
        #expect(kinds.filter { $0 == .copyTrashed }.count == 2, "\(kinds)")
        #expect(!kinds.contains(.copyDeleted), "never a permanent delete")
        #expect(kinds.contains(.approval))
    }

    @Test("never more than the forecast: a copy that appears after it is left alone")
    func neverExceedsTheForecast() async throws {
        let f = try await fixture("exceed"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        let late = f.copiesDir.appendingPathComponent("test_excess_a_late.mov")
        try FileManager.default.copyItem(atPath: f.copy.fullPath, toPath: late.path)
        let recLate = MasterArchiveTestSupport.makeRecord(path: late.path)
        recLate.contentHash = Self.hash; recLate.durationSeconds = Self.seconds
        f.model.records.append(recLate)
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(out.trashed == 2, "\(out)")
        #expect(FileManager.default.fileExists(atPath: late.path), "not in the forecast → never moved")
    }

    // MARK: C05-F1 — the last copy: read the archive file in full

    @Test("last copy outside the archive: the archive file is read in full even when its stamp reproduces")
    func lastCopyReadsTheArchiveInFull() async throws {
        let f = try await fixture("lastcopy"); defer { f.cleanup() }
        try stampArchive(f, digest: try #require(f.archive.archiveFixity?.digest))
        let plan = await f.model.excessCopiesPlan(env: f.env)
        let opens = OpenCounter()
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(Mover(trash: f.trashDir), opens: opens))
        #expect(out.trashed == 2, "\(out)")
        #expect(opens.opens(of: f.archive.fullPath) == 1, "read in full ONCE in this job, not trusted on its stamp")
        #expect(out.archiveReads == 1)
    }

    @Test("bit rot under a reproducing stamp: archive copy changed — nothing moved (C05-F1)")
    func bitRotInTheArchiveHoldsEverything() async throws {
        let f = try await fixture("bitrot"); defer { f.cleanup() }
        let good = try #require(f.archive.archiveFixity?.digest)
        let plan = await f.model.excessCopiesPlan(env: f.env)
        // A flipped sector: the bytes change, and the stored stamp is made
        // to reproduce (bit rot changes neither size nor times).
        try rewriteSameSize(f.archive.fullPath, seed: 99)
        try stampArchive(f, digest: good)
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
        #expect(out.held.count == 2 && out.held.allSatisfy { $0.contains("archive copy changed") }, "\(out.held)")
        #expect(exists(f.source) && exists(f.copy))
    }

    /// Give a copy its own stored whole-file digest (= the archive's), so it
    /// is PROVEN to match — only such a copy counts as staying (QA MAJOR 2).
    private func proveByDigest(_ r: VideoRecord, _ f: Fixture) throws {
        let digest = try #require(f.archive.archiveFixity?.digest)
        r.contentFixity = try #require(ContentFixity.captured(path: r.fullPath, digest: digest, byteCount: r.sizeBytes))
        try #require(VideoScanModel.excessWholeDigest(r) != nil, "fixture: the copy is digest-proven")
    }

    @Test("QA MAJOR 1: a survivor the sheet showed that drops out of the catalog holds the move — never a silent archive-only")
    func aShownSurvivorDroppedFromTheCatalogHoldsTheMove() async throws {
        let f = try await fixture("dropped"); defer { f.cleanup() }
        try proveByDigest(f.copy, f)
        let ro = CatalogScanTarget(searchPath: f.copiesDir.path)
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        await addTarget(ro, to: f.model)
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offeredIDs == [f.source.id])
        #expect(plan.items.first?.leavesArchiveOnly == false, "the sheet said a copy stays")
        // The survivor leaves the catalog (Remove from Catalog, a rescan) — its file is still there.
        f.model.records.removeAll { $0.id == f.copy.id }
        let opens = OpenCounter()
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover, opens: opens))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
        #expect(exists(f.source))
        #expect(out.held.contains { $0.contains("would stay") }, "\(out.held)")
    }

    @Test("QA MINOR 4: Keep never writes over a damaged Keep list")
    func keepDoesNotRepairADamagedList() async throws {
        let f = try await fixture("keepdamaged"); defer { f.cleanup() }
        f.defaults.set(42, forKey: ExcessKeepStore.key)
        #expect(ExcessKeepStore(defaults: f.defaults).keep([f.copy.id]) == false, "refused")
        #expect(f.defaults.object(forKey: ExcessKeepStore.key) as? Int == 42, "the damaged value is left for a person to look at")
        #expect(await f.model.excessCopiesPlan(env: f.env).offeredCount == 0, "and the lane still offers nothing")
    }

    @Test("a copy that stays (Read-only drive) is re-checked at the move; gone → held, nothing of its family moved")
    func aSurvivorThatLeavesHoldsTheMove() async throws {
        let f = try await fixture("survivor"); defer { f.cleanup() }
        try proveByDigest(f.copy, f)
        let ro = CatalogScanTarget(searchPath: f.copiesDir.path)
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        await addTarget(ro, to: f.model)
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offeredIDs == [f.source.id], "the Read-only copy is never offered")
        #expect(!plan.items[0].leavesArchiveOnly, "the Read-only copy stays outside the archive")
        // The survivor vanishes after the forecast.
        try FileManager.default.removeItem(atPath: f.copy.fullPath)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(Mover(trash: f.trashDir)))
        #expect(out.trashed == 0, "\(out)")
        #expect(exists(f.source))
    }

    // MARK: Changes between forecast and move

    @Test("the copy changed after the forecast → held, not the same bytes; the archive changed → held, archive copy changed")
    func changesAfterTheForecast() async throws {
        let f = try await fixture("changed"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        try rewriteSameSize(f.copy.fullPath, seed: 5)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(Mover(trash: f.trashDir)))
        #expect(out.trashed == 1, "the unchanged source still goes — \(out)")
        #expect(out.held.contains { $0.contains("test_excess_a.mov") && $0.contains("not the same bytes") }, "\(out.held)")
        #expect(exists(f.copy))

        let g = try await fixture("archchanged"); defer { g.cleanup() }
        let plan2 = await g.model.excessCopiesPlan(env: g.env)
        try rewriteSameSize(g.archive.fullPath, seed: 6)
        let out2 = await g.model.applyExcess(shown: plan2, env: g.env, hooks: hooks(Mover(trash: g.trashDir)))
        #expect(out2.trashed == 0 && out2.held.count == 2, "\(out2)")
        #expect(exists(g.source) && exists(g.copy))
    }

    @Test("a hold added mid-job (a Keep tag after the read) → held at the move, nothing moved")
    func aHoldAddedMidJob() async throws {
        let f = try await fixture("midhold"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        let copy = f.copy
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover, beforeMutation: { path in
            if path == copy.fullPath { copy.tags = ["Keep"] }
        }))
        #expect(out.held.contains { $0.contains("you tagged it Keep") }, "\(out.held)")
        #expect(exists(f.copy) && !mover.paths.contains(f.copy.fullPath))
    }

    // MARK: Refusals

    @Test("viewer mode: refused — nothing moved")
    func viewerModeRefused() async throws {
        let f = try await fixture("viewer"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        f.model.isReadOnly = true
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty)
        #expect(exists(f.source) && exists(f.copy))
    }

    @Test("a Read-only drive marked after the forecast → held; an Archive backup drive → never offered")
    func readOnlyAndBackupDrives() async throws {
        let f = try await fixture("readonly"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        let ro = CatalogScanTarget(searchPath: f.copiesDir.path)
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        await addTarget(ro, to: f.model)
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(!mover.paths.contains(f.copy.fullPath) && exists(f.copy), "\(out)")
        #expect(out.held.contains { $0.contains("Read only") }, "\(out.held)")

        let g = try await fixture("backup"); defer { g.cleanup() }
        let bk = CatalogScanTarget(searchPath: g.copiesDir.path)
        bk.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil, isArchiveBackup: true)
        await addTarget(bk, to: g.model)
        let plan2 = await g.model.excessCopiesPlan(env: g.env)
        #expect(!plan2.offeredIDs.contains(g.copy.id))
        #expect(plan2.items.first?.leftAlone.first { $0.id == g.copy.id }?.reason == ExcessCopiesPlan.backupDriveReason)
    }

    @Test("a network mount: never offered; one that appears at the move → held, nothing moved")
    func networkMountRefused() async throws {
        let f = try await fixture("network"); defer { f.cleanup() }
        let copyPath = f.copy.fullPath
        let netEnv = VideoScanModel.ExcessLaneEnvironment(isNetworkMount: { $0 == copyPath }, keepDefaults: f.defaults)
        let plan = await f.model.excessCopiesPlan(env: netEnv)
        #expect(!plan.offeredIDs.contains(f.copy.id))
        #expect(plan.items.first?.leftAlone.first { $0.id == f.copy.id }?.reason == ExcessCopiesPlan.networkReason)

        // At the move: the probe says "network" only once the read is done.
        let flag = Flag()
        let lateEnv = VideoScanModel.ExcessLaneEnvironment(isNetworkMount: { flag.isSet && $0 == copyPath },
                                                           keepDefaults: f.defaults)
        let plan2 = await f.model.excessCopiesPlan(env: lateEnv)
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan2, env: lateEnv, hooks: hooks(mover, beforeMutation: { _ in flag.set() }))
        #expect(exists(f.copy) && !mover.paths.contains(copyPath), "\(out)")
        #expect(out.held.contains { $0.contains("network") }, "\(out.held)")
    }

    @Test("a sampled-hash-only candidate whose bytes differ is offered as a candidate and never moved")
    func sampledOnlyCandidateNeverMovedWithoutAMatchingRead() async throws {
        let f = try await fixture("sampled"); defer { f.cleanup() }
        let fake = f.copiesDir.appendingPathComponent("test_excess_lookalike.mov")
        try MasterArchiveTestSupport.writeBlob(at: fake, bytes: Int(f.copy.sizeBytes), seed: 4242)
        let recFake = MasterArchiveTestSupport.makeRecord(path: fake.path)
        recFake.contentHash = Self.hash; recFake.durationSeconds = Self.seconds   // same v1 key, same size
        f.model.records.append(recFake)
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offered.first { $0.id == recFake.id }?.proof == .sampled, "a candidate, not proof")
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(FileManager.default.fileExists(atPath: fake.path) && !mover.paths.contains(fake.path))
        #expect(out.held.contains { $0.contains("test_excess_lookalike.mov") && $0.contains("not the same bytes") }, "\(out.held)")
    }

    // MARK: Isolation — a damaged Keep list

    @Test("POISONED Keep list: nothing offered, and a plan shown before the damage moves nothing")
    func poisonedKeepListHoldsEverything() async throws {
        let f = try await fixture("poison"); defer { f.cleanup() }
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offeredCount == 2)
        f.defaults.set(42, forKey: ExcessKeepStore.key)
        #expect(await f.model.excessCopiesPlan(env: f.env).offeredCount == 0)
        let mover = Mover(trash: f.trashDir)
        let out = await f.model.applyExcess(shown: plan, env: f.env, hooks: hooks(mover))
        #expect(out.trashed == 0 && mover.paths.isEmpty, "\(out)")
        #expect(exists(f.source) && exists(f.copy))
    }

    @Test("Keep in the lane holds a copy (remembered in the suite, never the real prefs)")
    func keepInTheLane() async throws {
        let f = try await fixture("keep"); defer { f.cleanup() }
        ExcessKeepStore(defaults: f.defaults).keep([f.copy.id])
        let plan = await f.model.excessCopiesPlan(env: f.env)
        #expect(plan.offeredIDs == [f.source.id])
        #expect(plan.items[0].leftAlone.first?.reason == "you chose Keep for it")
    }
}
