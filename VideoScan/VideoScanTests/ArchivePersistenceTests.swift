import Testing
import Foundation
@testable import VideoScan

// MARK: - ArchivePersistenceTests
//
// Regression coverage for the data-loss class where ArchiveView mutated
// VideoRecord class instances directly (`rec.archiveStage = .archived`)
// without triggering a catalog save. The mutation lived only in memory
// and was lost on app quit unless an unrelated path happened to fire
// saveCatalogDebounced first — observed symptom was archived files
// "sometimes there, sometimes gone" across sessions, e.g. DonnaRock.mov.
//
// Same family as the two HIGH-severity persistence bugs hardened in
// commit 3b798d9. Resolved by adding model-level helpers
// (setArchiveStage / addBackup) that bundle the mutation with a save.

@MainActor
struct ArchivePersistenceTests {

    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_archive_persistence_\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func makeRecord(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        r.partialMD5 = name.uppercased()
        return r
    }

    private func makeModelWithScratchStore(at dir: URL) throws -> VideoScanModel {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        // Narrow-gate test isolation: swap the catalogStore on this specific
        // instance so saves land in scratch instead of being short-circuited
        // by the shared singleton's XCTest gate.
        model.catalogStore = CatalogStore(directory: dir)
        return model
    }

    // MARK: - setArchiveStage helper

    @Test
    func setArchiveStageMutatesAndPersists() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModelWithScratchStore(at: dir)
        let rec = makeRecord("donna_rock.mov")
        model.records = [rec]

        model.setArchiveStage(.archived, for: [rec])
        #expect(rec.archiveStage == .archived)

        // Force the debounced write through immediately.
        // No explicit save call — the helper itself must persist. If this
        // reload comes back empty, the helper forgot to call saveCatalogNow.
        let reload = CatalogStore(directory: dir).load()
        #expect(reload.count == 1)
        #expect(reload.first?.archiveStage == .archived,
                "archiveStage must survive save/load roundtrip — if this fails, setArchiveStage forgot to call saveCatalogDebounced")
    }

    @Test
    func setArchiveStageAppliesToAllRecords() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModelWithScratchStore(at: dir)
        let recs = [makeRecord("a.mov"), makeRecord("b.mov"), makeRecord("c.mov")]
        model.records = recs

        model.setArchiveStage(.backedUp, for: recs)

        let reload = CatalogStore(directory: dir).load()
        #expect(reload.count == 3)
        #expect(reload.allSatisfy { $0.archiveStage == .backedUp })
    }

    // MARK: - addBackup helper

    @Test
    func addBackupAppendsEntryAndPersists() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModelWithScratchStore(at: dir)
        let rec = makeRecord("family_xmas.mov")
        model.records = [rec]

        let entry = BackupEntry(name: "LTA_Crucial", kind: .local, date: Date())
        model.addBackup(entry, to: [rec])

        let reload = CatalogStore(directory: dir).load()
        let loaded = try #require(reload.first)
        #expect(loaded.backupDestinations.count == 1)
        #expect(loaded.backupDestinations.first?.name == "LTA_Crucial")
        #expect(loaded.archiveStage == .backedUp,
                "addBackup must auto-advance archiveStage to at least .backedUp")
    }

    @Test
    func addBackupDedupsBySameName() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModelWithScratchStore(at: dir)
        let rec = makeRecord("vacation.mov")
        model.records = [rec]

        let entry1 = BackupEntry(name: "iCloud", kind: .cloud, date: Date())
        let entry2 = BackupEntry(name: "iCloud", kind: .cloud, date: Date().addingTimeInterval(60))
        model.addBackup(entry1, to: [rec])
        model.addBackup(entry2, to: [rec])

        let reload = CatalogStore(directory: dir).load()
        #expect(reload.first?.backupDestinations.count == 1,
                "Same-name entries must dedup — appending a duplicate would clutter the UI")
    }

    @Test
    func addBackupDoesNotDowngradeAdvancedStage() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModelWithScratchStore(at: dir)
        let rec = makeRecord("priceless.mov")
        rec.archiveStage = .archived       // already fully archived
        model.records = [rec]

        let entry = BackupEntry(name: "Breen's NAS", kind: .offsite, date: Date())
        model.addBackup(entry, to: [rec])

        let reload = CatalogStore(directory: dir).load()
        #expect(reload.first?.archiveStage == .archived,
                "addBackup must not downgrade an already-Archived record back to .backedUp")
    }
}
