import Foundation
import Testing
@testable import VideoScan

/// Pins the actual POIProfile -> storage transaction boundary, beyond helper tests.
/// Since 2026-09-12 the folder is keyed by uuid: a rename is a profile.json
/// write, the folder never moves, and two people may share a short name.
@Suite("People profile rename integration", .serialized)
struct POIProfileRenameIntegrationTests {
    private func sandboxStem() throws -> String {
        // Refuse to run against the live People store, even under a misconfigured harness.
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
        return "test-poi-rename-\(UUID().uuidString)"
    }

    @Test func renameKeepsFolderUUIDBiographyAndCoverBytes() throws {
        let stem = try sandboxStem()
        var profile = POIProfile(name: stem + " dad", referencePath: "")
        let folder = POIStorage.folder(for: profile)
        defer { try? FileManager.default.removeItem(at: folder) }
        profile.notes = "The corrected biography must survive."
        profile.coverImageFilename = "portrait.tiff"
        try profile.save()
        let bytes = Data([0x49, 0x49, 0x2A, 0x00, 1, 2, 3])
        try bytes.write(to: folder.appendingPathComponent("portrait.tiff"))
        let inode = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.systemFileNumber] as? Int

        profile.name = "Richard"
        profile.suffix = "Sr"
        #expect(try profile.saveRenaming(from: stem + " dad") == nil)

        let loaded = try POIProfile.load(uuid: profile.uuid)
        #expect(loaded.name == "Richard")
        #expect(loaded.uuid == profile.uuid)
        #expect(loaded.notes == profile.notes)
        #expect(loaded.referencePath == folder.path, "the folder did not move")
        #expect((try? FileManager.default.attributesOfItem(atPath: folder.path))?[.systemFileNumber] as? Int == inode)
        let coverFilename = try #require(loaded.coverImageFilename)
        #expect(try Data(contentsOf: folder.appendingPathComponent(coverFilename)) == bytes)
        // Exactly one folder for this person, and nothing was retired.
        let mine = POIStorage.poiFolders(in: POIStorage.storeDir).filter { $0.lastPathComponent == profile.id }
        #expect(mine.count == 1)
    }

    @Test func directSaveRejectsAnotherPersonInTheSameFolder() throws {
        let stem = try sandboxStem()
        var father = POIProfile(name: stem, referencePath: "")
        father.suffix = "Sr"
        father.notes = "Father's biography"
        try father.save()
        let folder = POIStorage.folder(for: father)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: POIStorage.profileURL(for: father))

        // A different uuid aimed at the father's folder is a different
        // person: the file store refuses before a byte is written.
        var son = POIProfile(name: stem, referencePath: folder.path)
        son.suffix = "Jr"
        #expect(throws: POIProfileFileStore.Failure.differentPerson) {
            _ = try POIProfileFileStore.save(id: son.uuid, destination: folder,
                                             retire: { _ in }, write: { _, _ in })
        }
        #expect(try Data(contentsOf: POIStorage.profileURL(for: father)) == before)
        #expect(try POIProfile.load(uuid: father.uuid).uuid == father.uuid)
    }

    @Test func twoPeopleWithOneShortNameSaveIntoTwoFolders() throws {
        let stem = try sandboxStem()
        var father = POIProfile(name: stem, referencePath: "")
        father.suffix = "Sr"
        var son = POIProfile(name: stem, referencePath: "")
        son.suffix = "Jr"
        try father.save()
        try son.save()
        defer {
            try? FileManager.default.removeItem(at: POIStorage.folder(for: father))
            try? FileManager.default.removeItem(at: POIStorage.folder(for: son))
        }
        #expect(POIStorage.folder(for: father).path != POIStorage.folder(for: son).path)
        let listed = POIProfile.listAll().filter { $0.name == stem }
        #expect(Set(listed.map(\.uuid)) == [father.uuid, son.uuid])
        #expect(try POIProfile.load(uuid: father.uuid).suffix == "Sr")
        #expect(try POIProfile.load(uuid: son.uuid).suffix == "Jr")
    }
}
