import Foundation
import Testing
@testable import VideoScan

/// Pins the actual POIProfile -> storage transaction boundary, beyond helper tests.
@Suite("People profile rename integration", .serialized)
struct POIProfileRenameIntegrationTests {
    private func sandboxNames() throws -> (String, String) {
        // Refuse to run against the live People store, even under a misconfigured harness.
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
        let stem = "test-poi-rename-\(UUID().uuidString)"
        return (stem + "-dad", stem + "-richard")
    }

    @Test func equivalentFolderRenameKeepsUUIDBiographyAndCoverBytes() throws {
        let (oldName, _) = try sandboxNames()
        // Use an in-place spelling change here: production must NOT retire a
        // folder when both spellings sanitize to the exact same location.
        let spaced = oldName + " breen"
        let equivalent = oldName + "_breen"
        let folder = POIStorage.folder(for: spaced)
        defer { try? FileManager.default.removeItem(at: folder) }
        var profile = POIProfile(name: spaced, referencePath: folder.path)
        profile.notes = "The corrected biography must survive."
        profile.coverImageFilename = "portrait.tiff"
        try profile.save()
        let bytes = Data([0x49, 0x49, 0x2A, 0x00, 1, 2, 3])
        try bytes.write(to: folder.appendingPathComponent("portrait.tiff"))
        profile.name = equivalent
        #expect(try profile.saveRenaming(from: spaced) == nil)
        let loaded = try POIProfile.load(name: equivalent)
        #expect(loaded.uuid == profile.uuid)
        #expect(loaded.notes == profile.notes)
        #expect(loaded.referencePath == folder.path)
        #expect(try Data(contentsOf: folder.appendingPathComponent(loaded.coverImageFilename!)) == bytes)
    }

    @Test func directSaveRejectsAnotherPersonEvenWithDifferentSuffix() throws {
        let (name, _) = try sandboxNames()
        let folder = POIStorage.folder(for: name)
        defer { try? FileManager.default.removeItem(at: folder) }
        var father = POIProfile(name: name, referencePath: folder.path)
        father.suffix = "Sr"
        father.notes = "Father's biography"
        try father.save()
        let before = try Data(contentsOf: POIStorage.profileURL(for: name))
        var son = POIProfile(name: name, referencePath: folder.path)
        son.suffix = "Jr"
        #expect(throws: (any Error).self) { try son.save() }
        #expect(try Data(contentsOf: POIStorage.profileURL(for: name)) == before)
        #expect(try POIProfile.load(name: name).uuid == father.uuid)
    }
}
