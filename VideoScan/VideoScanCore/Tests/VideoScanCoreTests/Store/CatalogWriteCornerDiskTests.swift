// CatalogWriteCornerDiskTests.swift
// Corner-case matrix (Rick, 2026-10-21: "we MUST have tests for those
// boundary/corner cases"), the DISK half: how OUR repository + CatalogCommit
// react when the volume under catalog.sqlite fills. Not a test of SQLite:
// every assertion is about what our store says, what it leaves on disk, and
// what the caller can still do. The disk image pattern is CatalogDiskFullTests'
// (`DiskImageVolume`, `CommitSession` — reused, not edited).
//
//   Case 1  disk full at COMMIT — refused with the disk's words; integrity ok;
//           the edits are still pending in memory; the same edits land once
//           space returns; the high-water witnesses are NOT ahead of the
//           database after the refusal (GH #338 — known issue at `.nearlyFull`).
//   Case 2  disk full half-way through a multi-commit job — the earlier
//           commits stay, the failed one rolls back whole, the caller is told.
//   Floor   fail-fast (Rick's scope note): a commit on a volume with almost
//           no space left should be refused BEFORE SQLite runs out — there is
//           no floor in the store today (known issue, pending).
//   SCALE   100k rows committed under disk pressure: on a full disk the
//           refusal is fail-fast (pending — today ~2 min, the whole body runs
//           first); once space returns the edits land within a budget.
//   Case 8  WAL growth: N/A (Rick's scope note, 2026-10-21 — don't test
//           SQLite). Our code reads no WAL size and has no threshold; the one
//           thing it does about the WAL, close's TRUNCATE checkpoint, is
//           pinned by CatalogCloseCheckpointTests.
//
// Five dimensions: LOGIC (the outcomes) · SCALE (100k) · MEDIA N/A (no media
// opened) · ISOLATION (a throwaway hdiutil image under the test's temp folder;
// nothing touches Application Support) · SENSOR (the 100k budgets).
//
// For Rick: `withKnownIssue { … }` ≈ a gtest EXPECT that is allowed to fail and
// is reported as "known"; when the bug is fixed the block stops failing and
// the TEST fails ("known issue was not recorded") so the wrapper gets removed.
// `.serialized` = run the cases one at a time (one disk image at a time).

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog write corners — disk full at COMMIT, mid-job, below the floor, 100k under pressure", .serialized)
struct CatalogWriteCornerDiskTests {

    typealias Depth = CatalogDiskFullTests.Depth

    // MARK: - Case 1

    @Test("case 1: disk full at COMMIT — refused with the disk's words, integrity ok, edits still pending, witnesses not ahead, edits land once space returns",
          .timeLimit(.minutes(3)), arguments: Depth.allCases)
    func diskFullAtCommit(_ depth: Depth) async throws {
        let scene = try ImporterScene.make(healthyRows: 120)
        defer { scene.remove() }
        _ = try #require(await scene.run().outcome.reconciliation)
        let volume = try DiskImageVolume.attach(megabytes: 32, under: scene.directory)
        defer { volume.detach() }
        let database = try volume.copyCatalog(from: scene.databaseFolder)

        var session = try await CommitSession.open(database)
        _ = try await session.commitNotes("c1-before")
        let before = await session.generation
        let stored = try CatalogDiskFullTests.noteCount(database, "c1-before")
        try #require(stored > 0)

        let ballast = try volume.fill(leavingFree: depth.leaveFreeBytes)
        let outcome = await session.commitNotesOutcome("c1-during")
        guard case .refused(let words, _) = outcome else {
            Issue.record("\(depth): a commit on a full disk was not refused: \(outcome.brief)")
            return
        }
        // Our words carry the disk's.
        #expect(CatalogDiskFullTests.namesTheDisk(words), "\(depth): \(words)")
        // integrity_check after the refusal (the store's own close does not run here).
        #expect(try CatalogHardKillTests.integrityCheck(database) == ["ok"], "\(depth)")
        #expect(try CatalogDiskFullTests.storedGeneration(database) == before, "\(depth)")
        #expect(try CatalogDiskFullTests.noteCount(database, "c1-during") == 0, "\(depth): part of a refused commit is stored")
        // The edits are still pending: memory holds them, the database does not.
        #expect(session.records.allSatisfy { $0.userNotes == "c1-during" }, "\(depth): the caller's edits were lost")

        // GH #338: the witnesses must not be ahead of the database after a refused COMMIT.
        let sidecar = CatalogHighWater.read(besideDatabaseAt: database)
        let ledger = CatalogHighWaterLedger.read(besideDatabaseAt: database)
        let witnessesAhead = sidecar != .value(before) || ledger != .value(before)
        if depth == .nearlyFull {
            withKnownIssue("GH #338: SQLITE_FULL at COMMIT after phase 1 leaves catalog.highwater(.log) at g+1") {
                #expect(!witnessesAhead, "\(depth): sidecar \(sidecar), log \(ledger), database \(before)")
            }
        } else {
            #expect(!witnessesAhead, "\(depth): sidecar \(sidecar), log \(ledger), database \(before)")
        }

        // Space returns: the same edits (reuseEdits) land.
        try FileManager.default.removeItem(at: ballast)
        var retried = await session.commitNotesOutcome("c1-during", reuseEdits: true)
        if case .refused = retried {
            // Today at .nearlyFull the session refuses its own retry (#338);
            // the app's answer is Reopen. A reopen that comes back read-only
            // is the #338 symptom the test above already tracks.
            await session.close()
            session = try await CommitSession.open(database, requireReadWrite: false)
            if case .readOnly = session.opened, case .value(let mark) = CatalogHighWater.read(besideDatabaseAt: database) {
                _ = await session.repository.adopt(toHighWater: mark)
            }
            retried = await session.commitNotesOutcome("c1-during", reuseEdits: false)
        }
        #expect(retried.isCommitted, "\(depth): the retained edits did not land once space returned: \(retried.brief)")
        await session.close()
        #expect(try CatalogDiskFullTests.noteCount(database, "c1-during") == stored, "\(depth)")
        #expect(try CatalogHardKillTests.integrityCheck(database) == ["ok"], "\(depth)")
    }

    // MARK: - Case 2

    @Test("case 2: disk full half-way through a 4-commit job — commits 1–2 stay, commit 3 is refused whole with the disk's words, integrity ok",
          .timeLimit(.minutes(3)))
    func diskFullMidJob() async throws {
        let scene = try ImporterScene.make(healthyRows: 200)
        defer { scene.remove() }
        _ = try #require(await scene.run().outcome.reconciliation)
        let volume = try DiskImageVolume.attach(megabytes: 32, under: scene.directory)
        defer { volume.detach() }
        let database = try volume.copyCatalog(from: scene.databaseFolder)
        let session = try await CommitSession.open(database)

        let slices = Self.slices(session.records, into: 4)
        let start = await session.generation
        var outcomes: [CatalogCommit.Outcome] = []
        var ballast: URL?
        for (index, slice) in slices.enumerated() {
            if index == 2 { ballast = try volume.fill(leavingFree: 0) }   // the disk fills half-way
            outcomes.append(await Self.commit(slice, note: "job-\(index)", on: session.repository))
        }
        await session.close()
        #expect(outcomes[0].isCommitted && outcomes[1].isCommitted, "\(outcomes.map(\.brief))")
        guard case .refused(let words, _) = outcomes[2] else {
            Issue.record("commit 3 on a full disk was not refused: \(outcomes[2].brief)"); return
        }
        #expect(CatalogDiskFullTests.namesTheDisk(words), Comment(rawValue: words))
        #expect(!outcomes[3].isCommitted, "commit 4 on the still-full disk landed: \(outcomes[3].brief)")
        #expect(try CatalogDiskFullTests.storedGeneration(database) == start + 2, "exactly the first two commits stay")
        #expect(try CatalogDiskFullTests.noteCount(database, "job-0") == slices[0].count)
        #expect(try CatalogDiskFullTests.noteCount(database, "job-1") == slices[1].count)
        #expect(try CatalogDiskFullTests.noteCount(database, "job-2") == 0, "the failed commit rolled back whole")
        #expect(try CatalogDiskFullTests.noteCount(database, "job-3") == 0)
        #expect(try CatalogHardKillTests.integrityCheck(database) == ["ok"])
        if let ballast { try? FileManager.default.removeItem(at: ballast) }
    }

    // MARK: - Fail fast: below the floor

    /// The free space under which a catalog write should refuse BEFORE it
    /// runs out mid-transaction. Pending: the store has no floor at all.
    static let intendedFloorBytes = 16 * 1024 * 1024

    @Test("fail-fast: a commit on a volume below the free-space floor is refused with words before SQLite runs out (pending — no floor today)",
          .timeLimit(.minutes(3)))
    func belowTheFloorRefuses() async throws {
        let scene = try ImporterScene.make(healthyRows: 20)
        defer { scene.remove() }
        _ = try #require(await scene.run().outcome.reconciliation)
        let volume = try DiskImageVolume.attach(megabytes: 32, under: scene.directory)
        defer { volume.detach() }
        let database = try volume.copyCatalog(from: scene.databaseFolder)
        let session = try await CommitSession.open(database)
        _ = try volume.fill(leavingFree: 2 * 1024 * 1024)
        try #require(volume.freeBytes() < Self.intendedFloorBytes)
        let outcome = await session.commitNotesOutcome("below-floor")
        await session.close()
        print("[corner-disk] below the floor (\(volume.freeBytes()) B free): \(outcome.brief)")
        withKnownIssue("pending: the catalog store has no free-space floor — it writes until SQLITE_FULL") {
            guard case .refused(let words, _) = outcome else {
                Issue.record("a commit with \(volume.freeBytes()) B free (floor \(Self.intendedFloorBytes) B) was not refused: \(outcome.brief)")
                return
            }
            #expect(words.lowercased().contains("free space"), Comment(rawValue: words))
        }
    }

    // MARK: - Scale: 100k rows under disk pressure

    /// Fail-fast intent: a full disk is known before 100k rows are written.
    static let failFastRefusalBudget: Duration = .seconds(10)
    /// Today's sensor: the whole body runs, THEN phase 1 finds no space.
    /// Measured 2026-10-21 (M4, Debug, load 5→67): 117 s. Catches a collapse.
    static let refusalCeiling: Duration = .seconds(300)
    static let landBudget: Duration = .seconds(120)

    @Test("SCALE: 100k rows — on a full disk the commit is refused (fail-fast within 10 s: pending; today < 300 s), integrity ok; once space returns the same 100k edits land within 120 s",
          .timeLimit(.minutes(10)))
    func hundredThousandUnderPressure() async throws {
        let scene = try ImporterScene.make(healthyRows: 100_000)
        defer { scene.remove() }
        _ = try #require(await scene.run().outcome.reconciliation)
        let dbBytes = Self.folderBytes(scene.databaseFolder)
        // Room for the catalog, a WAL of every page and the ballast's slack.
        let megabytes = max(64, Int(dbBytes * 4 / 1_048_576) + 64)
        let volume = try DiskImageVolume.attach(megabytes: megabytes, under: scene.directory)
        defer { volume.detach() }
        let database = try volume.copyCatalog(from: scene.databaseFolder)
        var session = try await CommitSession.open(database)
        try #require(session.records.count >= 100_000, "loaded \(session.records.count)")
        let before = await session.generation

        let ballast = try volume.fill(leavingFree: 0)
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var start = clock.now
        let refused = await session.commitNotesOutcome("scale-under-pressure")
        let refusal = clock.now - start
        print("[corner-disk] 100k on a full disk: \(refusal) → \(refused.brief) (\(TimingBudget.loadDescription()))")
        guard case .refused(let words, _) = refused else {
            Issue.record("100k commit on a full disk was not refused: \(refused.brief)"); return
        }
        #expect(CatalogDiskFullTests.namesTheDisk(words), Comment(rawValue: words))
        #expect(refusal < Self.refusalCeiling, "SENSOR: the 100k refusal took \(refusal)")
        withKnownIssue("pending (draft issue): a full disk is found only at phase 1, after the whole 100k-row body ran — on the main actor in the app (writeBlocking)") {
            #expect(refusal < Self.failFastRefusalBudget, "a full-disk refusal of 100k rows took \(refusal)")
        }
        #expect(try CatalogDiskFullTests.storedGeneration(database) == before)
        #expect(try CatalogHardKillTests.integrityCheck(database) == ["ok"])

        try FileManager.default.removeItem(at: ballast)
        start = clock.now
        var landed = await session.commitNotesOutcome("scale-under-pressure", reuseEdits: true)
        if case .refused = landed {
            await session.close()
            session = try await CommitSession.open(database, requireReadWrite: false)
            landed = await session.commitNotesOutcome("scale-under-pressure", reuseEdits: false)
        }
        let landing = clock.now - start
        await session.close()
        print("[corner-disk] 100k after space returned: \(landing) → committed=\(landed.isCommitted)")
        #expect(landed.isCommitted, "\(landed.brief)")
        expectWithinTimingBudget("100k commit after space returned", measured: landing, budget: Self.landBudget, loadBefore: load)
        #expect(try CatalogDiskFullTests.noteCount(database, "scale-under-pressure") >= 100_000)
    }

    // MARK: - Helpers

    static func slices(_ records: [VideoRecord], into count: Int) -> [[VideoRecord]] {
        let size = max(1, records.count / count)
        return (0..<count).map { index in
            let lower = index * size
            let upper = index == count - 1 ? records.count : min(records.count, lower + size)
            return Array(records[lower..<upper])
        }
    }

    /// One commit of `slice` with `note` set on each record (what a job's checkpoint save does).
    static func commit(_ slice: [VideoRecord], note: String, on repository: GRDBCatalogRepository) async -> CatalogCommit.Outcome {
        for record in slice { record.userNotes = note }
        let items = slice.map { record -> CatalogCommit.Item in
            let snapshot = VideoRecordDTO(record)
            return CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        }
        return await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: items), on: repository)
    }

    static func folderBytes(_ folder: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }
}

extension CatalogCommit.Outcome {
    /// The case and its words, without the per-row results (100k rows print badly).
    var brief: String {
        switch self {
        case .committed(let generation, let rows): return "committed(generation \(generation), \(rows.count) rows)"
        case .nothingWritten(let rows): return "nothingWritten(\(rows.count) rows)"
        case .refused(let words, let rows): return "refused(\(words), \(rows.count) rows)"
        case .generationMismatch(let expected, let found): return "generationMismatch(expected \(expected), found \(found))"
        }
    }
}
