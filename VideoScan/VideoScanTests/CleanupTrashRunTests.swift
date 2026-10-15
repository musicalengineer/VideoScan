// CleanupTrashRunTests.swift
// Triage ▸ Cleanup v1 — the MOVE on real files, end to end: the catalog
// projection, the disk probe, the plan, the frozen selection and the job
// through the one Trash engine (the test host's scratch Trash).
//
// Dimensions:
//   LOGIC      a copy moves and its keeper stays; junk moves; the run's
//              outcomes and markers.
//   ISOLATION  poisoned state — a stored digest that lies, a keeper rewritten
//              after the plan, a target replaced, junk unmarked or changed,
//              the keeper's drive gone mid-run (never re-elected), a stop
//              before the first turn — every one HELD or CANCELLED, named,
//              and its row never stamped. Real-FS aliases: a hard link, a
//              symlinked folder, a case-only spelling.
//   SENSOR     (CleanupTrashSensorTests) the source never trashes itself.
// Media matrix: CleanupTrashMediaMatrixTests.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Cleanup — the run on real files", .serialized)
@MainActor
struct CleanupTrashRunTests {

    typealias S = CleanupTrashSandbox

    private func bytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// keep/<name> and extra/<name> with the same bytes; keep/ outranks extra/.
    private func copyPair(_ sb: S, name: String = "test_clip.mov",
                          data: Data? = nil) throws -> (model: VideoScanModel, keep: VideoRecord, extra: VideoRecord) {
        let payload = data ?? bytes(64 * 1024, seed: 1)
        let k = try sb.write("keep/\(name)", payload)
        let e = try sb.write("extra/\(name)", payload)
        let model = sb.model(keepFirst: ["keep", "extra"])
        let keep = try S.record(k), extra = try S.record(e)
        model.records = [keep, extra]
        return (model, keep, extra)
    }

    // MARK: Copies

    @Test("an extra copy is proven, moved to the Trash and marked; the keeper is untouched")
    func copyMoves() async throws {
        let sb = try S("copy")
        defer { sb.cleanup() }
        let (model, keep, extra) = try copyPair(sb)
        let digest = try #require(S.sha256(path: keep.fullPath))
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.map(\.target.id) == [extra.id], "\(plan.leftAloneSorted.map(\.reason.words))")
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))

        #expect(job.items.map(\.outcome) == [.moved], "\(job.items.map(\.reason))")
        #expect(job.state == .finished(summary: job.totals.line))
        #expect(!FileManager.default.fileExists(atPath: extra.fullPath))
        #expect(extra.removal?.state == .inTrash && extra.removal?.reason == .duplicate)
        let trash = try #require(extra.removal?.trashPath)
        #expect(S.sha256(path: trash) == digest, "the Trash holds the original bytes")
        try? FileManager.default.removeItem(atPath: trash)
        #expect(S.sha256(path: keep.fullPath) == digest)
        #expect(keep.removal == nil)
        #expect(model.records.count == 2, "rows are never deleted")
    }

    @Test("a copy of a file the archive holds: proven against the archived file, moved; the archived file is untouched and was never a target")
    func archiveCoveredCopyMoves() async throws {
        let sb = try S("archivecovered")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        // Sources/ outranks everything in the precedence list: the archive
        // file must still be the copy that stays.
        let model = sb.model(keepFirst: ["Sources"])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let payload = bytes(96 * 1024, seed: 11)
        let archived = try sb.write("Archive/\(ma.archiveRoot.lastPathComponent)/30_Video/test_master.mov", payload)
        let source = try sb.write("Sources/VHS/test_master.mov", payload)
        let ra = try S.record(archived), rs = try S.record(source)
        ra.derivationKind = ArchivePromotion.derivationKind   // a promoted copy (see junkOnArchiveVolume's note)
        model.records = [rs, ra]
        #expect(model.bulkDeleteRefusal(ra) == .archiveTree, "fixture: the archive file is inside the tree")
        let digest = try #require(S.sha256(path: archived.path))

        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.isEmpty, "\(plan.leftAloneSorted.map(\.reason.words))")
        #expect(plan.archiveCovered.map(\.target.id) == [rs.id])
        #expect(plan.archiveCovered.first?.keeper.path == ra.fullPath)
        #expect(plan.leftAlone.isEmpty)

        // The lane's tick box off: nothing runs.
        #expect(CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false, includeArchiveCovered: false).isEmpty)

        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.moved], "\(job.items.map(\.reason))")
        #expect(job.items.map(\.id) == [rs.id])
        #expect(rs.removal?.state == .inTrash && rs.removal?.reason == .duplicate)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(S.sha256(path: archived.path) == digest, "the archived file is byte for byte what it was")
        #expect(ra.removal == nil && ra.lifecycleStage != .trashed)
        if let t = rs.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }
    }

    @Test("an archive-covered copy whose keeper stopped being the archive's file after the plan — held, by name")
    func archiveCoveredKeeperNoLongerArchived() async throws {
        let sb = try S("archivecoveredheld")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: ["Sources"])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let payload = bytes(8_192, seed: 12)
        let archived = try sb.write("Archive/\(ma.archiveRoot.lastPathComponent)/30_Video/test_m.mov", payload)
        let source = try sb.write("Sources/VHS/test_m.mov", payload)
        let ra = try S.record(archived), rs = try S.record(source)
        ra.derivationKind = ArchivePromotion.derivationKind
        model.records = [rs, ra]
        let plan = await model.buildCleanupPlan()
        #expect(plan.archiveCovered.map(\.target.id) == [rs.id], "fixture")
        // After the plan the keeper is no longer the archive's file (the
        // sandbox's designation is spelled /var/…, its files /private/var/…,
        // so the promoted-copy stamp was what named it).
        ra.derivationKind = nil
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held], "\(job.items.map(\.reason))")
        #expect(job.items.first?.reason.contains("no longer a file of the Master Archive") == true, "\(job.items.map(\.reason))")
        #expect(rs.removal == nil && FileManager.default.fileExists(atPath: source.path))
    }

    @Test("POISON: a stored digest that lies — the fresh reads differ, the file is held and its row never stamped")
    func lyingDigestHeld() async throws {
        let sb = try S("lie")
        defer { sb.cleanup() }
        let k = try sb.write("keep/test_a.mov", bytes(4_096, seed: 1))
        let e = try sb.write("extra/test_a.mov", bytes(4_096, seed: 2))
        let model = sb.model(keepFirst: ["keep", "extra"])
        let keep = try S.record(k), extra = try S.record(e, digest: S.sha256(try Data(contentsOf: k)))
        model.records = [keep, extra]
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 1, "the stored hashes say copy — the fresh reads decide")
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held])
        #expect(job.items.first?.reason.contains("bytes differ") == true, "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: e.path))
        #expect(extra.removal == nil && extra.lifecycleStage != .trashed, "a held file's row is never stamped")
        #expect(job.bytesRead == 2 * 4_096, "codex r1 P2-5: both files were read in full, once each — \(job.bytesRead)")
    }

    @Test("the keeper rewritten after the plan (same size) — held")
    func keeperRewrittenHeld() async throws {
        let sb = try S("keeperrewrite")
        defer { sb.cleanup() }
        let (model, keep, extra) = try copyPair(sb)
        let plan = await model.buildCleanupPlan()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: keep.fullPath))
        try handle.write(contentsOf: Data([0xFF, 0xEE]))
        try handle.close()
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held], "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: extra.fullPath))
        #expect(extra.removal == nil)
    }

    @Test("codex r1 P1-1: the keeper's folder went to a Trash and a symlink took its place after the plan — held, the extra copy stays")
    func keeperAncestryThroughTrashSymlinkHeld() async throws {
        let sb = try S("ancestry")
        defer { sb.cleanup() }
        let (model, keep, extra) = try copyPair(sb)
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 1)
        // Finder-style: keep/ lands in a .Trashes folder; a link keeps the old spelling alive.
        let trashed = sb.root.appendingPathComponent(".Trashes/501/keep", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sb.root.appendingPathComponent("keep"), to: trashed)
        try FileManager.default.createSymbolicLink(at: sb.root.appendingPathComponent("keep"), withDestinationURL: trashed)
        #expect(FileManager.default.fileExists(atPath: keep.fullPath), "fixture: the keeper's old path still resolves, through the link")
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held], "\(job.items.map(\.reason))")
        #expect(job.items.first?.reason.contains("link") == true || job.items.first?.reason.contains("Trash") == true, "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: extra.fullPath) && extra.removal == nil)
    }

    @Test("codex r1 P1-1: ticked FamilyArchive junk whose folder moved INTO the archive tree (symlink left behind) — held")
    func junkAncestryIntoArchiveTreeHeld() async throws {
        let sb = try S("junkancestry")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: [])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let junk = try S.record(try sb.write("Archive/Loose/test_j.mov", bytes(64, seed: 6)), junk: true)
        model.records = [junk]
        let plan = await model.buildCleanupPlan()
        #expect(plan.archiveJunk.map(\.id) == [junk.id], "fixture: listed for the tick box")
        // Loose/ moves into the archive tree; a link keeps the old spelling alive.
        let inTree = ma.archiveRoot.appendingPathComponent("Loose", isDirectory: true)
        try FileManager.default.moveItem(at: sb.root.appendingPathComponent("Archive/Loose"), to: inTree)
        try FileManager.default.createSymbolicLink(at: sb.root.appendingPathComponent("Archive/Loose"), withDestinationURL: inTree)
        #expect(FileManager.default.fileExists(atPath: junk.fullPath), "fixture: the old path still resolves, through the link")
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: true))
        #expect(job.items.map(\.outcome) == [.held], "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: inTree.appendingPathComponent("test_j.mov").path) && junk.removal == nil)
    }

    @Test("the extra copy replaced by an identical new file after the plan — held (not the file planned)")
    func targetReplacedHeld() async throws {
        let sb = try S("replaced")
        defer { sb.cleanup() }
        let (model, _, extra) = try copyPair(sb)
        let plan = await model.buildCleanupPlan()
        let data = try Data(contentsOf: URL(fileURLWithPath: extra.fullPath))
        try FileManager.default.removeItem(atPath: extra.fullPath)
        try data.write(to: URL(fileURLWithPath: extra.fullPath))
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held])
        #expect(job.items.first?.reason.contains("not the file Cleanup planned") == true, "\(job.items.map(\.reason))")
        #expect(extra.removal == nil)
    }

    @Test("ISOLATION: the keeper's drive goes away mid-run — every copy of it is held, none is promoted to keeper")
    func keeperGoneNeverReElected() async throws {
        let sb = try S("keepergone")
        defer { sb.cleanup() }
        let payload = bytes(8_192, seed: 3)
        let k = try sb.write("keep/test_b.mov", payload)
        let e1 = try sb.write("extra1/test_b.mov", payload)
        let e2 = try sb.write("extra2/test_b.mov", payload)
        let model = sb.model(keepFirst: ["keep", "extra1"])
        let recs = try [k, e1, e2].map { try S.record($0) }
        model.records = recs
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 2)
        #expect(Set(plan.copies.map(\.keeper.id)) == [recs[0].id])
        // "Unplug" the keeper's drive: its folder is gone from where it was.
        try FileManager.default.moveItem(at: sb.root.appendingPathComponent("keep"), to: sb.root.appendingPathComponent("away"))
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held, .held], "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: e1.path) && FileManager.default.fileExists(atPath: e2.path),
                "neither remaining copy was moved — no new keeper was elected")
        #expect(recs.allSatisfy { $0.removal == nil })
    }

    @Test("ISOLATION: the extra copy's own drive goes away mid-run — held, untouched")
    func targetDriveGone() async throws {
        let sb = try S("targetgone")
        defer { sb.cleanup() }
        let (model, _, extra) = try copyPair(sb)
        let plan = await model.buildCleanupPlan()
        try FileManager.default.moveItem(at: sb.root.appendingPathComponent("extra"), to: sb.root.appendingPathComponent("away"))
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held], "\(job.items.map(\.reason))")
        #expect(extra.removal == nil, "an unreachable file is never marked missing by Cleanup's proof")
        #expect(job.bytesRead == 64 * 1024, "codex r1 P2-5: an early hold is credited only the keeper's read — \(job.bytesRead)")
    }

    private func threeCopies(_ sb: S) throws -> (model: VideoScanModel, extras: [VideoRecord]) { try cleanupThreeCopies(sb) }
    nonisolated private static func onMainAndWait(_ action: @escaping @MainActor () -> Void) { cleanupOnMainAndWait(action) }

    @Test("QA (a): Stop mid-batch after one move — the moved row is stamped, the in-flight file and the rest are CANCELLED (not held), state Stopped; real catalog save")
    func stopMidBatch() async throws {
        let sb = try S("stopmid")
        defer { sb.cleanup() }
        let (model, extras) = try threeCopies(sb)
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 3)
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        // The run takes the copies in the selection's order (plan groups
        // are sorted by digest, not by path).
        let inOrder = selection.copies.compactMap { c in extras.first { $0.id == c.target.id } }
        #expect(inOrder.count == 3)
        let job = CleanupTrashJob(model: model, selection: selection)   // production save path
        let second = inOrder[1].fullPath
        job.proofStartedForTesting = { path in
            // Stop lands while the second copy's proof is about to read.
            guard path == second else { return }
            Self.onMainAndWait { job.cancel() }
        }
        job.start()
        await job.task?.value
        #expect(job.items.map(\.outcome) == [.moved, .cancelled, .cancelled], "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        #expect(job.items.map(\.id) == inOrder.map(\.id))
        #expect(job.state == .cancelled)
        #expect(job.subtitle.hasPrefix("Stopped — "))
        #expect(inOrder[0].removal?.state == .inTrash, "the file that moved is stamped")
        #expect(inOrder[1].removal == nil && inOrder[2].removal == nil)
        #expect(FileManager.default.fileExists(atPath: inOrder[1].fullPath) && FileManager.default.fileExists(atPath: inOrder[2].fullPath))
        #expect(job.totals[.cancelled] == 2 && job.totals[.held] == 0)
        if let t = inOrder[0].removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }
    }

    @Test("codex r1 P2-6: viewer protection switching on MID-RUN — the engine's preflight refusals still land in the totals and the receipt as held")
    func engineRefusalMidRunIsCounted() async throws {
        let sb = try S("refusal")
        defer { sb.cleanup() }
        let (model, extras) = try threeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let job = CleanupTrashJob(model: model, selection: selection)
        job.saveCatalogForTesting = { true }
        let first = selection.copies[0].target.path
        job.proofStartedForTesting = { path in
            guard path == first else { return }
            Self.onMainAndWait { model.isReadOnly = true }   // the catalog becomes a viewer's mid-run
        }
        job.start()
        await job.task?.value
        model.isReadOnly = false
        #expect(job.items.map(\.outcome) == [.moved, .held, .held], "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        #expect(job.items.dropFirst().allSatisfy { $0.reason.contains("read-only viewer") }, "\(job.items.map(\.reason))")
        #expect(job.totals[.held] == 2 && job.totals.done == 3)
        let receipt = try #require(job.receiptURL)
        let rows = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").dropFirst()
        #expect(rows.count == 3, "one receipt row per requested file: \(rows)")
        #expect(rows.filter { $0.hasPrefix("held,") }.count == 2)
        #expect(extras.allSatisfy { $0.removal == nil || $0.removal?.state == .inTrash })
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("QA (b): Pause mid-read — the file being checked finishes, nothing else starts until Resume, bytes counted once")
    func pauseMidRead() async throws {
        let sb = try S("pausemid")
        defer { sb.cleanup() }
        let (model, extras) = try threeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let job = CleanupTrashJob(model: model, selection: selection)
        job.saveCatalogForTesting = { true }
        let first = selection.copies[0].target.path   // the run's first file
        job.proofStartedForTesting = { path in
            guard path == first else { return }
            Self.onMainAndWait { job.pause() }
        }
        job.start()
        // The first file completes under Pause; the run then waits.
        var waited = 0
        while (job.items.count < 1 || !job.isPaused) && waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(job.items.map(\.outcome) == [.moved], "\(job.items.map(\.outcome))")
        #expect(job.isPaused && job.state == .running)
        try await Task.sleep(for: .milliseconds(500))
        #expect(job.items.count == 1, "nothing starts while paused")
        job.resume()
        await job.task?.value
        #expect(job.items.map(\.outcome) == [.moved, .moved, .moved])
        #expect(job.bytesRead == selection.bytesToRead, "each copy's two reads counted exactly once")
        #expect(job.fraction == 1 && job.state == .finished(summary: job.totals.line))
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("Stop before the first turn: every file is cancelled, nothing moves, nothing is stamped")
    func stopBeforeFirstTurn() async throws {
        let sb = try S("stop")
        defer { sb.cleanup() }
        let (model, keep, extra) = try copyPair(sb)
        let j = try sb.write("junk/test_j.mov", bytes(100, seed: 9))
        let junk = try S.record(j, junk: true)
        model.records.append(junk)
        let plan = await model.buildCleanupPlan()
        let job = CleanupTrashJob(model: model, selection: CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        job.saveCatalogForTesting = { true }
        job.start()
        job.cancel()
        await job.task?.value
        #expect(job.items.count == 2)
        #expect(job.items.allSatisfy { $0.outcome == .cancelled }, "\(job.items.map(\.outcome))")
        #expect(job.state == .cancelled)
        #expect([keep, extra, junk].allSatisfy { $0.removal == nil && FileManager.default.fileExists(atPath: $0.fullPath) })
    }

    @Test("QA P2-1: the page is released by the job's STATE — a refused job, an early failure, a cancel — never only by the happy path")
    func storeReleasedOnEveryExit() async throws {
        let sb = try S("release")
        defer { sb.cleanup() }
        let (model, _, _) = try copyPair(sb)
        let store = CleanupStore()
        await store.refresh(model: model)?.value
        // Refused before any work (a second run was already going).
        let sel = try #require(store.beginRun())
        #expect(store.isRunning)
        let refused = CleanupTrashJob(model: model, selection: sel)
        refused.refuseToStart(reason: "Cleanup is already running — nothing moved.")
        store.watch(refused, model: model)
        #expect(!store.isRunning, "a refused job must release the page")
        #expect(store.lastRun == "Cleanup is already running — nothing moved.")
        // Watched BEFORE it ends, then an early failure inside run().
        await store.refresh(model: model)?.value
        let sel2 = try #require(store.beginRun())
        model.isReadOnly = true
        let early = CleanupTrashJob(model: model, selection: sel2)
        store.watch(early, model: model)
        #expect(store.isRunning)
        early.start()
        await early.task?.value
        #expect(!store.isRunning, "an early finish(failed:) must release the page")
        #expect(early.wasRefused)
        model.isReadOnly = false
    }

    @Test("codex r1 P2-4: the page's 'Last run' is the run's OUTCOME line, never an earlier progress message; a failed save keeps its warning")
    func lastRunIsTheOutcome() async throws {
        let sb = try S("lastrun")
        defer { sb.cleanup() }
        let (model, _, _) = try copyPair(sb)
        let store = CleanupStore()
        await store.refresh(model: model)?.value
        let sel = try #require(store.beginRun())
        let job = CleanupTrashJob(model: model, selection: sel)
        job.saveCatalogForTesting = { true }
        store.watch(job, model: model)
        job.start()
        await job.task?.value
        #expect(store.lastRun == job.totals.line, "\(String(describing: store.lastRun))")
        #expect(store.lastRun?.hasPrefix("moved 1 ") == true)

        let sb2 = try S("lastrunfail")
        defer { sb2.cleanup() }
        let (model2, _, _) = try copyPair(sb2)
        let store2 = CleanupStore()
        await store2.refresh(model: model2)?.value
        let sel2 = try #require(store2.beginRun())
        let job2 = CleanupTrashJob(model: model2, selection: sel2)
        job2.saveCatalogForTesting = { false }
        store2.watch(job2, model: model2)
        job2.start()
        await job2.task?.value
        #expect(store2.lastRun?.contains("not confirmed") == true, "\(String(describing: store2.lastRun))")
    }

    @Test("QA P2-2: checkpoint batches are bound by files AND by bytes to read, in order, none lost")
    func batches() {
        let gb: Int64 = 1 << 30
        // 45 small files: by count.
        let small = CleanupTrashJob.batches(Array(0..<45), maxFiles: 20, maxBytes: 40 * gb) { _ in 2 * 1_000_000 }
        #expect(small.map(\.count) == [20, 20, 5])
        #expect(small.flatMap { $0 } == Array(0..<45))
        // 50 GB files (100 GB to read each): one per batch, never zero.
        let huge = CleanupTrashJob.batches(Array(0..<3), maxFiles: 20, maxBytes: 40 * gb) { _ in 100 * gb }
        #expect(huge.map(\.count) == [1, 1, 1])
        // Mixed: 15 GB each → 2 per batch (30 GB), the third would pass 40 GB.
        let mixed = CleanupTrashJob.batches(Array(0..<5), maxFiles: 20, maxBytes: 40 * gb) { _ in 15 * gb }
        #expect(mixed.map(\.count) == [2, 2, 1])
        #expect(CleanupTrashJob.batches([Int](), maxFiles: 20, maxBytes: 40 * gb) { _ in 1 }.isEmpty)
        #expect(CleanupTrashJob.checkpointBytes == 40 * gb && CleanupTrashJob.checkpointFiles == 20)
    }

    @Test("ISOLATION: a catalog save that is not confirmed stops the run after its batch; the rest are cancelled, untouched")
    func unconfirmedSaveStops() async throws {
        let sb = try S("savefail")
        defer { sb.cleanup() }
        let model = sb.model(keepFirst: ["keep", "extra"])
        var extras: [VideoRecord] = []
        for i in 0..<30 {
            let payload = Data("clip \(i) ".utf8) + bytes(512, seed: UInt8(i))
            let k = try sb.write("keep/test_\(i).mov", payload)
            let e = try sb.write("extra/test_\(i).mov", payload)
            model.records.append(try S.record(k))
            let rec = try S.record(e)
            model.records.append(rec)
            extras.append(rec)
        }
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 30)
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)) {
            $0.saveCatalogForTesting = { false }
        }
        #expect(job.totals[.moved] == CleanupTrashJob.checkpointFiles, "\(job.totals.line)")
        #expect(job.totals[.cancelled] == 30 - CleanupTrashJob.checkpointFiles)
        if case .failed = job.state {} else { Issue.record("an unconfirmed save ends Failed, not \(job.state)") }
        let cancelled = Set(job.items.filter { $0.outcome == .cancelled }.map(\.id))
        for rec in extras where cancelled.contains(rec.id) {
            #expect(rec.removal == nil && FileManager.default.fileExists(atPath: rec.fullPath))
        }
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("dry run 2026-10-12: a record's hand marks — a Reconcile note + originalFullPath count for nothing; a star, confirmed people, a typed date and a human note line count")
    func handMarksFromARecord() {
        let stamped = VideoRecord()
        stamped.userNotes = "Reconcile 2026-09-20T10:00:00Z: source file not found\nffprobe: Unsupported codec with id 98314"
        stamped.originalFullPath = "/Volumes/LaCieWorkspace/old/a.mov"
        stamped.tags = ["donna"]
        #expect(VideoScanModel.handMarks(stamped) == .none)
        let hand = VideoRecord()
        hand.starRating = 1
        hand.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        hand.userDate = "1992"
        hand.userNotes = "Cape Cod, the porch"
        #expect(VideoScanModel.handMarks(hand) == CleanupHandMarks(stars: 1, confirmedPeople: 1, hasDate: true, noteLines: 1))
        #expect(VideoScanModel.handMarks(hand).lacking(in: VideoScanModel.handMarks(stamped)) == "stars, confirmed people, a date, notes")
    }

    // MARK: Junk

    @Test("QA P2-3 + codex r1 P1-2: a junk file gone is 'missing' ONLY once its ORIGINAL drive (by volume UUID) is proven mounted; a swapped or absent drive is a hold")
    func junkDriveUnpluggedOrSwappedIsHeld() throws {
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/X/test_j.mov"
        rec.filename = "test_j.mov"
        rec.mediaDisposition = .confirmedJunk
        rec.sizeBytes = 64
        let identity = CleanupTrashFixture.stamp(inode: 5, size: 64)   // planned on volume "ABCD"
        let frozen = FrozenJunkFiles(VideoScanModel.JunkTrashSnapshot(items: [
            .init(record: rec, path: rec.fullPath, identity: identity, bytes: 64, plan: .toMove),
        ]))
        // No mount at X: HOLD, with the drive named.
        let unplugged = CleanupProof.verifyJunk(path: rec.fullPath, frozen: frozen, reserved: [], volumeUUIDNow: { _ in nil })
        #expect(unplugged?.contains("isn't connected") == true, "\(String(describing: unplugged))")
        // Another disk mounted as X (disk B): the file is not there — but this is not A. HOLD.
        let swapped = CleanupProof.verifyJunk(path: rec.fullPath, frozen: frozen, reserved: [], volumeUUIDNow: { _ in "WXYZ" })
        #expect(swapped?.contains("different drive") == true, "\(String(describing: swapped))")
        // The original disk is mounted at X and the file is not there: nil — the engine's own "already missing".
        #expect(CleanupProof.verifyJunk(path: rec.fullPath, frozen: frozen, reserved: [], volumeUUIDNow: { _ in "ABCD" }) == nil)
        // A planned identity with no volume UUID can never prove the drive: hold.
        let noUUID = FileIdentityStamp(device: 7, inode: 5, size: 64, mtimeNs: 1, ctimeNs: 2, volumeUUID: nil)
        let frozenNoUUID = FrozenJunkFiles(VideoScanModel.JunkTrashSnapshot(items: [
            .init(record: rec, path: rec.fullPath, identity: noUUID, bytes: 64, plan: .toMove),
        ]))
        #expect(CleanupProof.verifyJunk(path: rec.fullPath, frozen: frozenNoUUID, reserved: [], volumeUUIDNow: { _ in "ABCD" }) != nil)
        // A boot-disk path never asks about a mount.
        var asked = false
        let internalRec = "/Users/rickb/Movies/test_gone.mov"
        let frozen2 = FrozenJunkFiles(VideoScanModel.JunkTrashSnapshot(items: [
            .init(record: rec, path: internalRec, identity: identity, bytes: 64, plan: .toMove),
        ]))
        #expect(CleanupProof.verifyJunk(path: internalRec, frozen: frozen2, reserved: [], volumeUUIDNow: { _ in asked = true; return nil }) == nil)
        #expect(!asked)
        // The real probes: a made-up name is not mounted and has no UUID.
        let madeUp = "/Volumes/NoSuchDrive-\(UUID().uuidString.prefix(6))/x.mov"
        #expect(!CleanupDiskProbe.isMountPresent(forPath: madeUp))
        #expect(CleanupDiskProbe.mountVolumeUUID(forPath: madeUp) == nil)
    }

    @Test("codex r1 P1-2: a planned identity is matched by volume UUID + inode at execution — device/inode reuse on another volume is held")
    func plannedIdentityKeepsTheVolumeUUID() {
        let planned = CleanupTrashFixture.stamp(device: 7, inode: 5, size: 64)   // volume "ABCD"
        let sameDisk = FileIdentityStamp(device: 9, inode: 5, size: 64, mtimeNs: 1, ctimeNs: 2, volumeUUID: "ABCD")   // remounted: new st_dev
        let otherDisk = FileIdentityStamp(device: 7, inode: 5, size: 64, mtimeNs: 1, ctimeNs: 2, volumeUUID: "WXYZ")  // dev/inode reused
        let unknown = FileIdentityStamp(device: 7, inode: 5, size: 64, mtimeNs: 1, ctimeNs: 2, volumeUUID: nil)
        #expect(CleanupProof.plannedFileProblem(planned: planned, now: sameDisk) == nil, "same volume, remounted")
        #expect(CleanupProof.plannedFileProblem(planned: planned, now: otherDisk) != nil, "another volume reusing dev+inode")
        #expect(CleanupProof.plannedFileProblem(planned: planned, now: unknown) != nil)
        #expect(CleanupProof.plannedFileProblem(planned: unknown, now: unknown) != nil, "a plan with no volume identity never proves")
        // …and the copy lane's byte comparison asks the same question.
        let k = ContentFixity(digest: "d", byteCount: 64, stamp: CleanupTrashFixture.stamp(device: 7, inode: 1, size: 64))
        let e = ContentFixity(digest: "d", byteCount: 64, stamp: otherDisk)
        #expect(CleanupProof.sameBytes(extra: e, keeper: k, planned: planned) != nil)
        let eSame = ContentFixity(digest: "d", byteCount: 64, stamp: sameDisk)
        #expect(CleanupProof.sameBytes(extra: eSame, keeper: k, planned: planned) == nil)
    }

    @Test("junk you marked moves and is marked In the Trash (reason junk)")
    func junkMoves() async throws {
        let sb = try S("junk")
        defer { sb.cleanup() }
        let model = sb.model(keepFirst: [])
        let j = try sb.write("junk/test_j.mov", bytes(500, seed: 4))
        let junk = try S.record(j, junk: true)
        model.records = [junk]
        let plan = await model.buildCleanupPlan()
        #expect(plan.junk.map(\.id) == [junk.id])
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.moved])
        #expect(junk.removal?.state == .inTrash && junk.removal?.reason == .junk)
        if let t = junk.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }
    }

    @Test("junk unmarked or changed after the plan — held, untouched")
    func junkRechecked() async throws {
        let sb = try S("junkcheck")
        defer { sb.cleanup() }
        let model = sb.model(keepFirst: [])
        let a = try sb.write("junk/test_a.mov", bytes(500, seed: 5))
        let b = try sb.write("junk/test_b.mov", bytes(500, seed: 6))
        let ra = try S.record(a, junk: true), rb = try S.record(b, junk: true)
        model.records = [ra, rb]
        let plan = await model.buildCleanupPlan()
        #expect(plan.junk.count == 2)
        ra.mediaDisposition = .unreviewed
        let h = try FileHandle(forWritingTo: b)
        try h.seekToEnd()
        try h.write(contentsOf: Data([1]))
        try h.close()
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.items.map(\.outcome) == [.held, .held], "\(job.items.map(\.reason))")
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        #expect(ra.removal == nil && rb.removal == nil)
    }

    @Test("an unticked file is not in the run")
    func untickedStays() async throws {
        let sb = try S("untick")
        defer { sb.cleanup() }
        let (model, _, extra) = try copyPair(sb)
        let plan = await model.buildCleanupPlan()
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [extra.id], includeArchiveJunk: false))
        #expect(job.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: extra.fullPath) && extra.removal == nil)
    }

    // MARK: Real-FS aliases (the probe)

    @Test("a hard link, a symlinked folder and a case-only spelling are never removed")
    func realAliases() async throws {
        let sb = try S("alias")
        defer { sb.cleanup() }
        let payload = bytes(4_096, seed: 7)
        let k = try sb.write("keep/test_c.mov", payload)
        let e = try sb.write("extra/test_c.mov", payload)
        let hard = sb.root.appendingPathComponent("extra/test_c_hardlink.mov")
        try FileManager.default.linkItem(at: e, to: hard)
        try FileManager.default.createSymbolicLink(at: sb.root.appendingPathComponent("linked"),
                                                   withDestinationURL: sb.root.appendingPathComponent("keep"))
        let viaLink = sb.root.appendingPathComponent("linked/test_c.mov")
        let caseVariant = sb.root.appendingPathComponent("keep/TEST_C.MOV")
        let model = sb.model(keepFirst: ["keep", "extra", "linked"])
        var recs = try [k, e, hard, viaLink].map { try S.record($0) }
        if FileManager.default.fileExists(atPath: caseVariant.path) {   // case-insensitive volume
            recs.append(try S.record(caseVariant))
        }
        model.records = recs
        if case .throughLink(let real) = CleanupDiskProbe.facts(for: viaLink.path) {
            #expect(real?.inode == FileIdentityStamp.capture(path: k.path)?.inode, "the alias carries its real file's identity (codex r2 F3)")
        } else {
            Issue.record("a path through a linked folder must read as throughLink")
        }
        let plan = await model.buildCleanupPlan()
        let targets = Set(plan.copies.map(\.target.path))
        #expect(!targets.contains(hard.path) && !targets.contains(e.path), "the hard-linked pair is ambiguous: \(targets)")
        #expect(!targets.contains(viaLink.path) && !targets.contains(caseVariant.path) && !targets.contains(k.path))
    }

    @Test("codex r2 F3: an UNHASHED alias through a linked folder still makes the canonical file ambiguous")
    func unhashedAliasThroughLinkedFolder() async throws {
        let sb = try S("linkalias")
        defer { sb.cleanup() }
        let (model, keep, extra) = try copyPair(sb)
        try FileManager.default.createSymbolicLink(at: sb.root.appendingPathComponent("linked"),
                                                   withDestinationURL: sb.root.appendingPathComponent("extra"))
        let alias = try S.record(sb.root.appendingPathComponent("linked/test_clip.mov"))
        alias.contentFixity = nil   // never hashed: not a candidate, but another name for the extra copy
        model.records.append(alias)
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.isEmpty, "the extra copy has another active name — \(plan.copies.map(\.target.path))")
        #expect(plan.leftAlone[.sameFileAsAnotherRow]?.files == 1, "\(plan.leftAloneSorted.map(\.reason.words))")
        #expect(plan.leftAlone[.throughLink] == nil, "the unhashed alias is not a candidate, so it is not 'left alone' either")
        #expect(keep.removal == nil && extra.removal == nil)
    }

    // MARK: FamilyArchive junk — the per-run tick box (Rick 2026-10-12, option b)

    @Test("FamilyArchive junk: listed apart; moves ONLY when ticked; the archive tree never; the box resets")
    func familyArchiveJunkTickBox() async throws {
        let sb = try S("fajunk")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: [])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let loose = try sb.write("Archive/MoviesExpansion/test_loop.aif", bytes(300, seed: 8))
        let inTree = try sb.write("Archive/\(ma.archiveRoot.lastPathComponent)/test_tree.mov", bytes(300, seed: 9))
        let rl = try S.record(loose, junk: true), rt = try S.record(inTree, junk: true)
        // The sandbox's designation is spelled "/var/…" and its files
        // "/private/var/…", so the tree is named by the promoted-copy stamp
        // (the gate's other half of "in the archive tree").
        rt.derivationKind = ArchivePromotion.derivationKind
        model.records = [rl, rt]
        #expect(model.bulkDeleteRefusal(rl) == .archiveVolume, "fixture: elsewhere on the archive volume")
        #expect(model.bulkDeleteRefusal(rt) == .archiveTree, "fixture: inside the archive tree")

        let plan = await model.buildCleanupPlan()
        #expect(plan.junk.isEmpty)
        #expect(plan.archiveJunk.map(\.id) == [rl.id], "\(plan.leftAloneSorted.map(\.reason.words))")

        // Tick box OFF: nothing from FamilyArchive is in the run.
        #expect(CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false).isEmpty)

        // Tick box ON: the listed file moves; the tree file was never listed.
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: true))
        #expect(job.items.map(\.outcome) == [.moved], "\(job.items.map(\.reason))")
        #expect(rl.removal?.state == .inTrash)
        #expect(FileManager.default.fileExists(atPath: inTree.path) && rt.removal == nil)
        if let t = rl.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }

    }

    @Test("the page's FamilyArchive box is off by default, lists the files, and turns itself off when a run begins")
    func storeTickBoxResets() async throws {
        let sb = try S("fabox")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: [])
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let fa = try S.record(try sb.write("Archive/Loose/test_fa.mov", bytes(64, seed: 1)), junk: true)
        let other = try S.record(try sb.write("Elsewhere/test_other.mov", bytes(64, seed: 2)), junk: true)
        model.records = [fa, other]
        let store = CleanupStore()
        await store.refresh(model: model)?.value
        #expect(!store.includeArchiveJunk, "off by default")
        #expect(store.plan?.archiveJunk.map(\.id) == [fa.id], "the box lists the exact files")
        #expect(store.numbers.archiveJunk.files == 0 && store.numbers.junk.files == 1)
        store.includeArchiveJunk = true
        #expect(store.numbers.archiveJunk.files == 1)
        let taken = try #require(store.beginRun())
        #expect(taken.archiveJunk.map(\.id) == [fa.id], "this run carries the ticked files")
        #expect(!store.includeArchiveJunk, "and the box is off again for the next run")
        #expect(store.beginRun() == nil, "one run at a time")
    }

    @Test("QA (c): FamilyArchive junk on a drive ALSO marked Read only — not listed for the tick box, and the engine's waiver holds it 'you marked Read only'")
    func waiverVersusReadOnlyMark() async throws {
        let sb = try S("waiverro")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: [])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let archiveTarget = try #require(model.scanTargets.first { VideoScanModel.samePath($0.searchPath, ma.archiveVolume.path) })
        // Rick marks the drive Read only (the app's own mark: realpath + mount, no persistence).
        archiveTarget.readOnlyMark = VideoScanModel.readOnlyMark(forPath: archiveTarget.searchPath, isReachable: true, now: Date())
        let junk = try S.record(try sb.write("Archive/Loose/test_ro.mov", bytes(64, seed: 5)), junk: true)
        model.records = [junk]
        #expect(model.bulkDeleteRefusal(junk) == .archiveVolume, "fixture: the gate answers the archive half first")
        #expect(model.readOnlyVolumeRefusal(forPath: junk.fullPath, effect: .removesFiles) != nil, "fixture: …and the Read-only half has its say")

        // The page: never offered through the tick box; left alone with the Read-only words.
        let plan = await model.buildCleanupPlan()
        #expect(plan.archiveJunk.isEmpty && plan.junk.isEmpty)
        let reasons = plan.leftAlone.keys.map(\.words)
        #expect(reasons.contains { $0.contains("you marked Read only") }, "\(reasons)")

        // The engine, even when a caller insists on the waiver: held, with the Read-only words.
        var g = VideoScanModel.JunkDeletionGuard(authorize: { _ in nil }, beforeRemoval: { _ in nil })
        g.archiveVolumeJunkWaiver = [junk.id]
        let result = await model.deleteConfirmedJunk([junk], mode: .toTrash, reason: .junk, guard: g)
        #expect(result.items.map(\.outcome.kind) == [.held])
        #expect(result.refused.first?.reason.contains("you marked Read only") == true, "\(result.refused.map(\.reason))")
        #expect(junk.removal == nil && FileManager.default.fileExists(atPath: junk.fullPath))
    }

    @Test("the engine's waiver lifts ONLY .archiveVolume, ONLY for the listed rows")
    func engineWaiverIsNarrow() async throws {
        let sb = try S("waiver")
        defer {
            MasterArchiveTestSupport.unlockTree(sb.root)
            sb.cleanup()
        }
        let ma = MasterArchiveTestSupport.Sandbox(root: sb.root, sources: try sb.folder("Sources"),
                                                  archiveVolume: try sb.folder("Archive"))
        let model = sb.model(keepFirst: [])
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: ma)
        await model.refreshArchiveVolumeSnapshot(force: true)
        let listed = try S.record(try sb.write("Archive/Loose/test_listed.mov", bytes(64, seed: 1)), junk: true)
        let unlisted = try S.record(try sb.write("Archive/Loose/test_unlisted.mov", bytes(64, seed: 2)), junk: true)
        let tree = try S.record(try sb.write("Archive/\(ma.archiveRoot.lastPathComponent)/test_t.mov", bytes(64, seed: 3)), junk: true)
        tree.derivationKind = ArchivePromotion.derivationKind   // an archive copy (see the test above)
        // In the archive root folder by NAME only (its spelling hides it
        // from the tree check): the waiver's second net still holds it.
        let byName = try S.record(try sb.write("Archive/\(ma.archiveRoot.lastPathComponent)/1990s/test_n.mov",
                                               bytes(64, seed: 4)), junk: true)
        model.records = [listed, unlisted, tree, byName]
        #expect(model.bulkDeleteRefusal(tree) == .archiveTree && model.bulkDeleteRefusal(listed) == .archiveVolume)
        var g = VideoScanModel.JunkDeletionGuard(authorize: { _ in nil }, beforeRemoval: { _ in nil })
        g.archiveVolumeJunkWaiver = [listed.id, tree.id, byName.id]
        let result = await model.deleteConfirmedJunk([listed, unlisted, tree, byName], mode: .toTrash, reason: .junk, guard: g)
        #expect(result.items.map(\.outcome.kind) == [.moved, .held, .held, .held], "\(result.items.map(\.outcome))")
        #expect(unlisted.removal == nil && tree.removal == nil && byName.removal == nil)
        if let t = listed.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }
    }
}
