// CatalogCommitterFailFastTests.swift
// Corner-case matrix (Rick, 2026-10-21), the COMMITTER's reaction to a write
// the store refuses for lack of space (cases 1 and 2 at the app's surface).
// The failure is injected at our seam — `FaultyRepository` refuses the write
// with SQLite's disk-full words — so this pins OUR logic, not the engine:
//
//   Case 1  the refusal is shown with the disk's words; the edit stays
//           pending in memory (changedRecordCount); fail-fast: the committer
//           blocks at once — a second save, the timer, a job's acknowledged
//           save and a person's removal-marker request are all refused
//           WITHOUT another write being tried; space returning does not
//           unblock it silently; Catalog ▸ Reopen does, and then the same
//           edit lands and reloads.
//   Case 2  a job's checkpoint save (commitAcknowledged) after the disk
//           filled answers false, so the job can report it; its earlier
//           checkpoint stays in catalog.sqlite.
//
// Five dimensions: LOGIC (above) · SCALE (the 100k disk-pressure case lives
// in Core: CatalogWriteCornerDiskTests) · MEDIA N/A · ISOLATION (CutoverScene
// sandbox; the committer is built over the scene's own catalog.sqlite) ·
// SENSOR (writesAttempted pins "no silent retry").

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private struct CommitterWorld {
    let scene: CutoverScene
    let repository: FaultyRepository
    let committer: CatalogCommitter
    let records: RecordsBox
    let lines: LinesBox

    final class RecordsBox { var value: [VideoRecord] = [] }
    final class LinesBox { var value: [String] = [] }

    static func make(_ label: String) async throws -> CommitterWorld {
        let scene = try CutoverScene.make(label)
        try await scene.importCatalog()
        let loaded = try await scene.sqliteLoad()
        let repository = FaultyRepository(GRDBCatalogRepository(host: "corner-committer"))
        guard case .readWrite = await repository.open(at: scene.databaseURL) else {
            throw CutoverFailure(words: "the scene's catalog.sqlite did not open read-write")
        }
        let designation = try await repository.read { try $0.masterArchiveJSON() }
        let records = RecordsBox()
        records.value = loaded.records
        let lines = LinesBox()
        let committer = CatalogCommitter(
            repository: repository, storedDesignationJSON: designation,
            input: { CatalogCommitter.Input(records: records.value, designation: CatalogCommitter.designation(fromJSON: designation),
                                            clearAuthorized: false, holdReason: nil, holdOwner: nil) },
            sink: { lines.value.append($0) })
        committer.adoptBaseline(loaded.records)
        return CommitterWorld(scene: scene, repository: repository, committer: committer, records: records, lines: lines)
    }

    func record(_ shape: PoisonedCatalogFixture.Shape) throws -> VideoRecord {
        try #require(records.value.first { $0.id.uuidString == PoisonedCatalogFixture.id(shape) })
    }

    func close() async {
        await repository.close()
        scene.cleanup()
    }
}

@Suite("Catalog committer fail-fast — a disk-full refusal blocks at once, keeps the edits, and lands them after Reopen", .serialized)
@MainActor
struct CatalogCommitterFailFastTests {

    @Test("case 1: disk full at COMMIT — the disk's words, the edit pending, no silent retry by any door, Reopen then lands the same edit")
    func diskFullBlocksThenReopenLands() async throws {
        let world = try await CommitterWorld.make("corner_failfast")
        do {
            let committer = world.committer
            try world.record(.healthy).userNotes = "kept through a full disk"
            world.repository.writeFault = diskFullWords

            #expect(committer.commitNow() == false)
            #expect(world.repository.writesAttempted == 1)
            let blocked = try #require(committer.blockedReason, "a disk-full refusal did not block the committer")
            #expect(blocked.contains("disk is full"), Comment(rawValue: blocked))
            #expect(world.lines.value.contains { $0.contains("REFUSED via quit") && $0.contains("disk is full") }, "\(world.lines.value)")
            #expect(committer.changedRecordCount() == 1, "the edit must still be pending in memory")

            // Fail-fast: nothing tries the store again on its own.
            #expect(committer.commitNow() == false)
            #expect(await committer.commitAcknowledged(owner: nil) == false, "a job's checkpoint save must answer false")
            let marker = committer.markerWillChange(try world.record(.healthy), kind: .request)
            #expect(marker?.contains("can't save") == true, "a person's Trash request must be refused with words: \(String(describing: marker))")
            committer.scheduleCommit(after: .milliseconds(10))
            try await Task.sleep(for: .milliseconds(300))
            #expect(world.repository.writesAttempted == 1, "fail-fast: the store was asked again without a Reopen")

            // Space comes back — still blocked until a person reopens.
            world.repository.writeFault = nil
            #expect(committer.commitNow() == false)
            #expect(world.repository.writesAttempted == 1, "space returning must not unblock silently")

            await committer.reopen(at: world.scene.databaseURL)
            #expect(committer.blockedReason == nil)
            #expect(committer.commitNow())
            #expect(committer.changedRecordCount() == 0)
            #expect(try await world.scene.reloaded(.healthy).userNotes == "kept through a full disk")
        } catch {
            await world.close(); throw error
        }
        await world.close()
    }

    @Test("case 2: a job's checkpoints — the first lands, the one after the disk filled answers false (the job can report it), the first stays")
    func jobCheckpointAfterDiskFills() async throws {
        let world = try await CommitterWorld.make("corner_failfast_job")
        do {
            let committer = world.committer
            try world.record(.healthy).userNotes = "checkpoint 1"
            #expect(await committer.commitAcknowledged(owner: nil), "the first checkpoint lands")
            world.repository.writeFault = diskFullWords
            try world.record(.healthy).userNotes = "checkpoint 2"
            #expect(await committer.commitAcknowledged(owner: nil) == false, "the job must be told its checkpoint did not land")
            #expect(committer.blockedReason?.contains("disk is full") == true)
            #expect(try await world.scene.reloaded(.healthy).userNotes == "checkpoint 1", "the earlier checkpoint stays; the refused one is not half-written")
        } catch {
            await world.close(); throw error
        }
        await world.close()
    }
}
