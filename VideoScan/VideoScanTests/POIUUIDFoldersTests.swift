import Foundation
import Testing
@testable import VideoScan

// People profile folders keyed by uuid, display name = first alias
// (docs/people_uuid_folders_design.md, Rick's ruling 2026-09-12).
//
// Dimension 1 (logic) and dimension 5 (sensors) of the feature-test
// checklist. Every test works in the per-process test store
// (POIStorage.storeDir under a test host) or a private temp root; the
// migration itself is covered in POIUUIDMigrationTests.

@Suite("People uuid folders — logic", .serialized)
struct POIUUIDFoldersLogicTests {

    private func requireSandbox() throws {
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
    }

    @Test func folderNameIsTheUppercaseUUIDString() {
        let id = UUID(uuidString: "ff6c5474-ebb4-4d32-a9ef-b2d38647a146")!
        #expect(POIStorage.folderName(for: id) == "FF6C5474-EBB4-4D32-A9EF-B2D38647A146")
        #expect(POIStorage.folder(forUUID: id).lastPathComponent == "FF6C5474-EBB4-4D32-A9EF-B2D38647A146")
        #expect(POIStorage.uuid(fromFolderName: "ff6c5474-ebb4-4d32-a9ef-b2d38647a146") == id)
        #expect(POIStorage.uuid(fromFolderName: "richard") == nil)
        #expect(POIStorage.uuid(fromFolderName: "dad") == nil)
    }

    @Test func idIsTheUUID() {
        let profile = POIProfile(name: "Richard", referencePath: "")
        #expect(profile.id == profile.uuid.uuidString.uppercased())
        #expect(profile.id == POIStorage.folder(for: profile).lastPathComponent)
        var renamed = profile
        renamed.name = "Dad"
        #expect(renamed.id == profile.id, "a rename never changes the id")
        var junior = POIProfile(name: "Richard", referencePath: "")
        junior.suffix = "Jr"
        #expect(junior.id != profile.id, "two Richards are two ids")
    }

    @Test func displayNameRules() {
        #expect(POIProfile.displayName(name: "Richard", aliases: ["Rick", "Dicky"]) == "Rick")
        #expect(POIProfile.displayName(name: "Richard", aliases: ["Dad"]) == "Dad")
        #expect(POIProfile.displayName(name: "Richard", aliases: []) == "Richard")
        // A blank first alias is skipped, not shown.
        #expect(POIProfile.displayName(name: "Richard", aliases: ["", "  ", "Rick"]) == "Rick")
        #expect(POIProfile.displayName(name: "Richard", aliases: ["   "]) == "Richard")
        // Whitespace around the alias is trimmed for display only.
        #expect(POIProfile.displayName(name: "Eileen", aliases: [" Ma "]) == "Ma")
        var profile = POIProfile(name: "Eileen", referencePath: "", aliases: ["Ma", "Eileen Latta"])
        #expect(profile.displayName == "Ma")
        profile.aliases = []
        #expect(profile.displayName == "Eileen")
    }

    @Test func legacyFolderNameIsPersistedAndSurvivesASave() throws {
        try requireSandbox()
        var profile = POIProfile(name: "Audit-\(UUID().uuidString.prefix(6))", referencePath: "")
        profile.legacyFolderName = "richard"
        try profile.save()
        defer { try? FileManager.default.removeItem(at: POIStorage.folder(for: profile)) }
        let loaded = try POIProfile.load(uuid: profile.uuid)
        #expect(loaded.legacyFolderName == "richard")
        let data = try Data(contentsOf: POIStorage.profileURL(for: profile))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["legacyFolderName"] as? String == "richard")
    }

    @Test func listAllSortsByDisplayNameAfterManualOrder() throws {
        try requireSandbox()
        let tag = UUID().uuidString.prefix(6)
        var zed = POIProfile(name: "Zed-\(tag)", referencePath: "", aliases: ["Aaron-\(tag)"])
        var bob = POIProfile(name: "Bob-\(tag)", referencePath: "")
        zed.sortOrder = 5; bob.sortOrder = 5
        try zed.save(); try bob.save()
        defer {
            try? FileManager.default.removeItem(at: POIStorage.folder(for: zed))
            try? FileManager.default.removeItem(at: POIStorage.folder(for: bob))
        }
        let mine = POIProfile.listAll().filter { $0.name.hasSuffix(tag) }
        #expect(mine.map(\.displayName) == ["Aaron-\(tag)", "Bob-\(tag)"],
                "Zed shows as Aaron and therefore sorts first")
    }

    @Test func loadByNameFindsTheUUIDFolder() throws {
        try requireSandbox()
        let name = "Lookup \(UUID().uuidString.prefix(6))"
        let profile = POIProfile(name: name, referencePath: "")
        try profile.save()
        defer { try? FileManager.default.removeItem(at: POIStorage.folder(for: profile)) }
        #expect(try POIProfile.load(name: name).uuid == profile.uuid)
        #expect(try POIProfile.load(name: name.uppercased()).uuid == profile.uuid)
        // The sanitized spelling an old job descriptor recorded still resolves.
        #expect(try POIProfile.load(name: POIStorage.sanitize(name)).uuid == profile.uuid)
        #expect(throws: (any Error).self) { try POIProfile.load(name: "nobody-\(UUID().uuidString)") }
    }

    @Test func deleteMovesTheUUIDFolderToATrashFolderNamedForThePerson() throws {
        try requireSandbox()
        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("poi-uuid-trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: trash) }
        var profile = POIProfile(name: "Richard", referencePath: "", aliases: ["Dad"])
        profile.name += " \(UUID().uuidString.prefix(6))"
        try profile.save()
        let folder = POIStorage.folder(for: profile)
        try Data([1]).write(to: folder.appendingPathComponent("photo.jpg"))
        let dest = try #require(POIStorage.trashPOIFolder(uuid: profile.uuid, displayName: profile.displayName,
                                                          trashOverride: trash))
        #expect(dest.lastPathComponent.hasPrefix("POI-dad-"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("photo.jpg").path))
        #expect(POIStorage.restorePOIFolder(from: dest, uuid: profile.uuid) == .restored(folder))
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Sensors

@Suite("People uuid folders — sensors", .serialized)
struct POIUUIDFoldersSensorTests {

    private func requireSandbox() throws {
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
    }

    /// SENSOR `renameNeverMovesPhotos`: the folder, its inode and every
    /// photo byte are exactly where they were after a rename.
    @Test func renameNeverMovesPhotos() throws {
        try requireSandbox()
        var profile = POIProfile(name: "Richard \(UUID().uuidString.prefix(6))", referencePath: "")
        try profile.save()
        let folder = POIStorage.folder(for: profile)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photos: [String: Data] = [:]
        for i in 0..<12 {
            let bytes = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            photos["photo_\(i).jpg"] = bytes
            try bytes.write(to: folder.appendingPathComponent("photo_\(i).jpg"))
        }
        let inodes = try photos.keys.map { name -> (String, Int?) in
            (name, try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.systemFileNumber] as? Int)
        }
        let foldersBefore = Set(POIStorage.poiFolders(in: POIStorage.storeDir).map(\.lastPathComponent))

        profile.name = "Dad"
        profile.aliases = ["Pops"]
        _ = try profile.saveRenaming(from: "Richard")
        profile.name = "Richard Harding"
        try profile.save()

        #expect(Set(POIStorage.poiFolders(in: POIStorage.storeDir).map(\.lastPathComponent)) == foldersBefore,
                "no folder appeared or vanished")
        for (name, bytes) in photos {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == bytes)
        }
        for (name, inode) in inodes {
            #expect(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.systemFileNumber] as? Int == inode)
        }
        #expect(try POIProfile.load(uuid: profile.uuid).name == "Richard Harding")
    }

    /// SENSOR `twoProfilesWithTheSameGivenNameCoexist`: Richard Jr (Rick)
    /// and Richard Sr (Dad) — full names, distinct uuids, both listed, both
    /// photo sets intact, and Hallie's exact-name resolution picks each by
    /// alias or full name while the bare given name is honestly ambiguous.
    @Test func twoProfilesWithTheSameGivenNameCoexist() throws {
        try requireSandbox()
        let tag = String(UUID().uuidString.prefix(6))
        let given = "Richard\(tag)"
        var junior = POIProfile(name: given, referencePath: "", aliases: ["Rick\(tag)", "Dicky"])
        junior.middleName = "Harding"; junior.surname = "Breen"; junior.suffix = "Jr"
        var senior = POIProfile(name: given, referencePath: "", aliases: ["Dad\(tag)", "Dick"])
        senior.middleName = "Harding"; senior.surname = "Breen"; senior.suffix = "Sr"
        try junior.save(); try senior.save()
        let jrFolder = POIStorage.folder(for: junior), srFolder = POIStorage.folder(for: senior)
        defer {
            try? FileManager.default.removeItem(at: jrFolder)
            try? FileManager.default.removeItem(at: srFolder)
        }
        #expect(jrFolder.path != srFolder.path)
        try Data([0xAA]).write(to: jrFolder.appendingPathComponent("jr.jpg"))
        try Data([0xBB]).write(to: srFolder.appendingPathComponent("sr.jpg"))

        let listed = POIProfile.listAll().filter { $0.name == given }
        #expect(listed.count == 2)
        #expect(Set(listed.map(\.id)) == [junior.id, senior.id])
        #expect(Set(listed.map(\.displayName)) == ["Rick\(tag)", "Dad\(tag)"])
        #expect(try Data(contentsOf: jrFolder.appendingPathComponent("jr.jpg")) == Data([0xAA]))
        #expect(try Data(contentsOf: srFolder.appendingPathComponent("sr.jpg")) == Data([0xBB]))
        #expect(try POIProfile.load(uuid: junior.uuid).suffix == "Jr")
        #expect(try POIProfile.load(uuid: senior.uuid).suffix == "Sr")

        // Hallie: the People-tab claim is keyed by stable id, never by name.
        let snapshots = listed.map {
            HallieTurnExecutor.ProfileSnapshot(
                stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                birthdate: nil, kinships: [], sex: nil, uuid: $0.uuid, treeIdentity: nil,
                deathdate: nil, surname: $0.surname, maidenName: nil,
                middleName: $0.middleName, suffix: $0.suffix)
        }
        let rick = HallieTurnExecutor.PeopleTab.profile(claiming: "rick\(tag)", in: snapshots)
        #expect(rick?.stableID == junior.id)
        let dad = HallieTurnExecutor.PeopleTab.profile(claiming: "dad\(tag)", in: snapshots)
        #expect(dad?.stableID == senior.id)
        let bySuffix = HallieTurnExecutor.PeopleTab.profile(claiming: "\(given) Breen Sr", in: snapshots)
        #expect(bySuffix?.stableID == senior.id)
        let byFull = HallieTurnExecutor.PeopleTab.profile(claiming: "\(given) Harding Breen Jr", in: snapshots)
        #expect(byFull?.stableID == junior.id)
        #expect(HallieTurnExecutor.PeopleTab.profile(claiming: given, in: snapshots) == nil,
                "the bare given name is two people — ask, never guess")
    }

    /// SENSOR `displayNameIsTheFirstAlias`: the rule at the profile level,
    /// through a save/load round trip, on the exact shapes Rick uses.
    @Test func displayNameIsTheFirstAlias() throws {
        try requireSandbox()
        let shapes: [(name: String, aliases: [String], shown: String)] = [
            ("Richard", ["Rick", "Dicky", "Rich"], "Rick"),
            ("Richard", ["Dad", "Grampa Breen"], "Dad"),
            ("Eileen", ["Ma"], "Ma"),
            ("Daniel", ["Dan"], "Dan"),
            ("Donna", [], "Donna"),
        ]
        var folders: [URL] = []
        defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        for shape in shapes {
            var profile = POIProfile(name: shape.name, referencePath: "", aliases: shape.aliases)
            profile.notes = "sensor"
            try profile.save()
            folders.append(POIStorage.folder(for: profile))
            let loaded = try POIProfile.load(uuid: profile.uuid)
            #expect(loaded.displayName == shape.shown, "\(shape.name) \(shape.aliases)")
            #expect(loaded.name == shape.name, "the canonical name is untouched")
        }
    }
}
