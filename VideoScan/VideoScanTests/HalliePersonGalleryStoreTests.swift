// HalliePersonGalleryStoreTests.swift
// The store side of "show all photos of X" (2026-09-10): the read-side
// alias-folder rule (pure, no disk), TIFF admitted, documents listed with
// sidecars excluded, and the write side still refusing an ambiguous name.
// Fixtures live in a temp directory; no real path, no model.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoScan
import VideoScanCore

@Suite("Person gallery — store", .serialized)
struct HalliePersonGalleryStoreTests {
    private let fileManager = FileManager.default

    private func temporaryStore() throws -> (base: URL, store: FamilyAssetStore) {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("test_PersonGallery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true)))
    }

    private func writeImage(to url: URL, type: UTType) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeText(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static let christopher = FamilyAssetPerson(
        gedcomID: "@I342486919751@", name: "Christopher O'Connor", birthYear: nil)

    private func identity(aliases: [String]) -> FamilyAssetIdentityDirectory {
        FamilyAssetIdentityDirectory(
            members: [.init(gedcomID: Self.christopher.gedcomID!,
                            givenTokens: ["christopher"], surnameTokens: ["oconnor"],
                            suffix: nil, aliasTokens: ["dennis"], aliasNames: aliases)],
            ownerGedcomID: nil)
    }

    // MARK: Pure rule

    @Test func aliasFoldersMatchByNameOrAliasAndADisagreeingYearDoesNot() {
        let folders = ["Christopher_OConnor", "Christopher_Dennis_OConnor", "Mary_OConnor",
                       "Christopher_OConnor_b1901", "Christopher_OConnor_I999",
                       "RickDonnaBreenFamily"]
        // Name + alias, no birth year on the record: the bare folder, the
        // alias folder, and the ONE dated folder (no year to disagree
        // with). The folder pinned to another record (_I999) is never his.
        let read = FamilyAssetStore.readFolderNames(
            for: Self.christopher, aliases: ["Christopher Dennis O'Connor"], among: folders)
        #expect(read == ["Christopher_OConnor", "Christopher_OConnor_b1901", "Christopher_Dennis_OConnor"])

        // A birth year that disagrees with the folder's excludes it.
        let born1850 = FamilyAssetPerson(gedcomID: "@I1@", name: "Christopher O'Connor", birthYear: 1850)
        #expect(FamilyAssetStore.readFolderNames(for: born1850, aliases: ["Christopher Dennis O'Connor"], among: folders)
                == ["Christopher_OConnor", "Christopher_Dennis_OConnor"])
        // A year that agrees includes it.
        let born1901 = FamilyAssetPerson(gedcomID: "@I1@", name: "Christopher O'Connor", birthYear: 1901)
        #expect(FamilyAssetStore.readFolderNames(for: born1901, aliases: [], among: folders)
                == ["Christopher_OConnor", "Christopher_OConnor_b1901"])
        // The record's own pointer suffix wins regardless of the name.
        let pinned = FamilyAssetPerson(gedcomID: "@I999@", name: "Somebody Else")
        #expect(FamilyAssetStore.readFolderNames(for: pinned, aliases: [], among: folders)
                == ["Christopher_OConnor_I999"])
        // Two dated folders with different years and no year on the
        // record: neither is chosen (they are two people).
        let twoYears = ["Mary_OConnor_b1850", "Mary_OConnor_b1901"]
        #expect(FamilyAssetStore.readFolderNames(
            for: FamilyAssetPerson(name: "Mary O'Connor"), aliases: [], among: twoYears).isEmpty)
        // Two bare same-name folders: ambiguous, none.
        #expect(FamilyAssetStore.readFolderNames(
            for: FamilyAssetPerson(name: "Mary O'Connor"), aliases: [], among: ["Mary_OConnor", "Mary O'Connor"]).isEmpty)
        // No aliases, no directory: name only.
        #expect(FamilyAssetStore.readFolderNames(for: Self.christopher, aliases: [], among: folders)
                == ["Christopher_OConnor", "Christopher_OConnor_b1901"])
    }

    // MARK: On disk

    @Test func aliasFolderPhotosTIFFAndDocumentsAreListedAndSidecarsAreNot() throws {
        let (base, plain) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        var store = plain
        let people = store.peopleDirectory
        try writeImage(to: people.appendingPathComponent("Christopher_OConnor/ChristopherOConnor-restored.png"), type: .png)
        try writeImage(to: people.appendingPathComponent("Christopher_Dennis_OConnor/PaOConnorBritishArmy.png"), type: .png)
        try writeImage(to: people.appendingPathComponent("Christopher_Dennis_OConnor/PaOConnorBritishArmy2x scale.tif"), type: .tiff)
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Christopher_Dennis_OConnor/British_Army_discharge.pdf"))
        try writeText("notes", to: people.appendingPathComponent("Christopher_OConnor/Family_notes.txt"))
        try writeText("{\"file\":\"x/y.png\",\"chosenAt\":\"2026-01-01T00:00:00Z\",\"source\":\"t\"}",
                      to: people.appendingPathComponent("Christopher_OConnor/chosen-photo.json"))
        try writeText("{\"notOf\":[]}", to: people.appendingPathComponent("Christopher_OConnor/ChristopherOConnor-restored.png.notof.json"))
        try writeText("junk", to: people.appendingPathComponent("Christopher_OConnor/thumbs.db"))
        // A symlinked "document" is never listed.
        try fileManager.createSymbolicLink(
            at: people.appendingPathComponent("Christopher_OConnor/link.pdf"),
            withDestinationURL: people.appendingPathComponent("Christopher_Dennis_OConnor/British_Army_discharge.pdf"))

        // Without the alias the second folder is invisible (today's rule).
        #expect(plain.photoURLs(for: Self.christopher).map(\.lastPathComponent) == ["ChristopherOConnor-restored.png"])
        #expect(plain.documentURLs(for: Self.christopher).map(\.lastPathComponent) == ["Family_notes.txt"])

        store.identity = identity(aliases: ["Christopher Dennis O'Connor"])
        let photos = store.photoURLs(for: Self.christopher).map(\.lastPathComponent)
        #expect(photos == ["ChristopherOConnor-restored.png", "PaOConnorBritishArmy.png", "PaOConnorBritishArmy2x scale.tif"])
        let documents = store.documentURLs(for: Self.christopher).map(\.lastPathComponent)
        #expect(documents == ["Family_notes.txt", "British_Army_discharge.pdf"])
        #expect(store.personFolders(for: Self.christopher).map(\.lastPathComponent)
                == ["Christopher_OConnor", "Christopher_Dennis_OConnor"])

        // TIFF passes the validator by header + ImageIO, and a truncated
        // TIFF (no readable directory) does not.
        let tif = people.appendingPathComponent("Christopher_Dennis_OConnor/PaOConnorBritishArmy2x scale.tif")
        let tifData = try Data(contentsOf: tif)
        #expect(FamilyAssetImageValidator.isStructurallyComplete(tifData))
        #expect(FamilyAssetImageValidator.isVerifiedImageData(tifData))
        #expect(!FamilyAssetImageValidator.isVerifiedImageData(tifData.prefix(11)))
        #expect(FamilyAssetImageValidator.revalidatedURL(tif) != nil)

        // The WRITE side is unchanged: one unambiguous folder or refuse.
        // Christopher's own name folder is unique, so it is returned; a
        // name shared by two bare folders is refused.
        #expect(try store.folderForPhotoRequest(person: Self.christopher).lastPathComponent == "Christopher_OConnor")
        try fileManager.createDirectory(at: people.appendingPathComponent("Mary_OConnor"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: people.appendingPathComponent("Mary_O'Connor"), withIntermediateDirectories: true)
        let mary = FamilyAssetPerson(name: "Mary O'Connor")
        #expect(throws: FamilyAssetStore.StoreError.invalidPerson) {
            try store.folderForPhotoRequest(person: mary)
        }
        #expect(store.personFolders(for: mary).isEmpty)
    }

    @Test func documentsComeFromGroupFoldersToo() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let people = store.peopleDirectory
        try writeText("hello", to: people.appendingPathComponent("Rick_and_Donna_Breen/wedding_program.pdf"))
        try writeImage(to: people.appendingPathComponent("Donna_Breen/portrait.png"), type: .png)
        let donna = FamilyAssetPerson(name: "Donna Breen")
        #expect(store.documentURLs(for: donna).map(\.lastPathComponent) == ["wedding_program.pdf"])
        #expect(store.personFolders(for: donna).map(\.lastPathComponent) == ["Donna_Breen"])
        // Unavailable archive: nothing, never a fallback.
        let offline = FamilyAssetStore(root: store.root, cacheRoot: store.cacheRoot, access: .unavailable)
        #expect(offline.documentURLs(for: donna).isEmpty)
        #expect(offline.personFolders(for: donna).isEmpty)
    }


    // MARK: One identity rule for every folder source (codex #1298, 2026-09-11)

    /// The reviewer's exact case: subject @I1@ Mary O'Connor, and the ONLY
    /// folder is `Mary_OConnor_I2/` — another record's, pinned by pointer.
    /// A sole name match must not attribute I2's papers to I1, on any read
    /// path, and the write side must not file I1's request into I2's folder.
    @Test func anotherRecordsPointerFolderIsNeverReadForThisRecord() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let people = store.peopleDirectory
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Mary_OConnor_I2/certificate.pdf"))
        try writeImage(to: people.appendingPathComponent("Mary_OConnor_I2/portrait.png"), type: .png)

        let i1 = FamilyAssetPerson(gedcomID: "@I1@", name: "Mary O'Connor")
        #expect(store.documentURLs(for: i1).isEmpty)
        #expect(store.photoURLs(for: i1).isEmpty)
        #expect(store.personFolders(for: i1).isEmpty)
        #expect(store.chosenPhotoFolder(for: i1) == nil)
        // A person with NO pointer cannot claim a pointer-pinned folder either.
        let unknown = FamilyAssetPerson(name: "Mary O'Connor")
        #expect(store.documentURLs(for: unknown).isEmpty)
        #expect(store.photoURLs(for: unknown).isEmpty)
        // The folder's own record reads it.
        let i2 = FamilyAssetPerson(gedcomID: "@I2@", name: "Mary O'Connor")
        #expect(store.documentURLs(for: i2).map(\.lastPathComponent) == ["certificate.pdf"])
        #expect(store.photoURLs(for: i2).map(\.lastPathComponent) == ["portrait.png"])
        #expect(store.personFolders(for: i2).map(\.lastPathComponent) == ["Mary_OConnor_I2"])
        // Write side: I1's request gets its own pointer-suffixed folder.
        let requested = try store.folderForPhotoRequest(person: i1)
        #expect(requested.lastPathComponent != "Mary_OConnor_I2")
        #expect(requested.lastPathComponent.hasSuffix("I1"))
    }

    @Test func aConflictingBirthYearFolderIsNotRead() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let people = store.peopleDirectory
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Mary_OConnor_b1904/baptism.pdf"))
        try writeImage(to: people.appendingPathComponent("Mary_OConnor_b1904/portrait.png"), type: .png)

        let born1905 = FamilyAssetPerson(gedcomID: "@I1@", name: "Mary O'Connor", birthYear: 1905)
        #expect(store.documentURLs(for: born1905).isEmpty)
        #expect(store.photoURLs(for: born1905).isEmpty)
        #expect(store.personFolders(for: born1905).isEmpty)
        #expect(store.chosenPhotoFolder(for: born1905) == nil)
        let born1904 = FamilyAssetPerson(gedcomID: "@I3@", name: "Mary O'Connor", birthYear: 1904)
        #expect(store.documentURLs(for: born1904).map(\.lastPathComponent) == ["baptism.pdf"])
        #expect(store.photoURLs(for: born1904).map(\.lastPathComponent) == ["portrait.png"])
        // No year on the record and one dated folder: readable (unchanged).
        let undated = FamilyAssetPerson(gedcomID: "@I4@", name: "Mary O'Connor")
        #expect(store.personFolders(for: undated).map(\.lastPathComponent) == ["Mary_OConnor_b1904"])
        // The write side never files a b.1905 request into the b.1904 folder.
        #expect(try store.folderForPhotoRequest(person: born1905).lastPathComponent != "Mary_OConnor_b1904")
    }

    /// A malformed NON-EMPTY pointer (one `safeGEDCOMIDComponent` rejects)
    /// is corrupt identity data: every read path returns nothing, even
    /// with a perfectly matching bare name folder on disk. Note `@I1` is
    /// well-formed by the store's rule (`@`, letters, digits are allowed;
    /// it keys to `I1`) — the malformed shapes carry a space or a slash.
    @Test func aMalformedGEDCOMIDReadsNothingAndNeverFallsBackToTheName() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let people = store.peopleDirectory
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Mary_OConnor/certificate.pdf"))
        try writeImage(to: people.appendingPathComponent("Mary_OConnor/portrait.png"), type: .png)

        for bad in ["@I 1@", "@I1@/..", "I1\u{0}"] {
            let person = FamilyAssetPerson(gedcomID: bad, name: "Mary O'Connor")
            let why = Comment(rawValue: "id \(bad.debugDescription) must be malformed and read nothing")
            #expect(FamilyAssetStore.hasMalformedGEDCOMID(person), why)
            #expect(store.documentURLs(for: person).isEmpty, why)
            #expect(store.photoURLs(for: person).isEmpty, why)
            #expect(store.personFolders(for: person).isEmpty, why)
            #expect(store.chosenPhotoFolder(for: person) == nil, why)
            #expect(FamilyAssetStore.readFolderNames(for: person, aliases: [], among: ["Mary_OConnor"]).isEmpty, why)
            #expect(throws: FamilyAssetStore.StoreError.invalidPerson) {
                try store.folderForPhotoRequest(person: person)
            }
        }
        // The same name with a sound pointer, or none, still reads the folder.
        #expect(store.documentURLs(for: FamilyAssetPerson(gedcomID: "@I1@", name: "Mary O'Connor"))
                    .map(\.lastPathComponent) == ["certificate.pdf"])
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "Mary O'Connor"))
                    .map(\.lastPathComponent) == ["portrait.png"])
    }

    // MARK: Two same-name folders, neither this record's (codex #1369, 2026-09-12)

    /// The reviewer's fixture: TWO `Mary_OConnor…` folders on disk, one
    /// pinned to another record (`_I2`), one dated to a different year
    /// (`_b1904`). For @I1@ born 1905 neither is hers, on every read
    /// path — the resolver's "sole name match" must never enter the
    /// gallery ahead of the identity rule, and an alias spelling cannot
    /// rescue a folder that rule refuses.
    @Test func twoSameNameFoldersWithAConflictingPointerAndYearNeverEnterTheGallery() throws {
        let (base, plain) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        var store = plain
        let people = store.peopleDirectory
        try writeImage(to: people.appendingPathComponent("Mary_OConnor_I2/portrait.png"), type: .png)
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Mary_OConnor_I2/certificate.pdf"))
        try writeImage(to: people.appendingPathComponent("Mary_OConnor_b1904/baptism.png"), type: .png)
        try writeText("%PDF-1.4\n%%EOF\n", to: people.appendingPathComponent("Mary_OConnor_b1904/baptism.pdf"))

        let born1905 = FamilyAssetPerson(gedcomID: "@I1@", name: "Mary O'Connor", birthYear: 1905)
        #expect(store.personFolders(for: born1905).isEmpty)
        #expect(store.photoURLs(for: born1905).isEmpty)
        #expect(store.documentURLs(for: born1905).isEmpty)
        #expect(store.chosenPhotoFolder(for: born1905) == nil)
        #expect(store.cardPhotoURL(for: born1905) == nil)
        #expect(store.originalPhotoURL(for: born1905) == nil)

        // An identity directory that spells her name as an alias changes nothing.
        store.identity = FamilyAssetIdentityDirectory(
            members: [.init(gedcomID: "@I1@", givenTokens: ["mary"], surnameTokens: ["oconnor"],
                            suffix: nil, aliasTokens: [], aliasNames: ["Mary O'Connor", "Mary OConnor"])],
            ownerGedcomID: nil)
        #expect(store.personFolders(for: born1905).isEmpty)
        #expect(store.photoURLs(for: born1905).isEmpty)
        #expect(store.documentURLs(for: born1905).isEmpty)

        // No year on the record: the dated folder is readable (nothing to
        // disagree with); the other record's folder still never is.
        let undated = FamilyAssetPerson(gedcomID: "@I1@", name: "Mary O'Connor")
        #expect(store.personFolders(for: undated).map(\.lastPathComponent) == ["Mary_OConnor_b1904"])
        #expect(store.photoURLs(for: undated).map(\.lastPathComponent) == ["baptism.png"])
        #expect(store.documentURLs(for: undated).map(\.lastPathComponent) == ["baptism.pdf"])

        // Each folder's own record reads exactly its own — the pointer
        // wins over a year that would otherwise disagree.
        let i2 = FamilyAssetPerson(gedcomID: "@I2@", name: "Mary O'Connor", birthYear: 1905)
        #expect(store.personFolders(for: i2).map(\.lastPathComponent) == ["Mary_OConnor_I2"])
        #expect(store.photoURLs(for: i2).map(\.lastPathComponent) == ["portrait.png"])
        #expect(store.documentURLs(for: i2).map(\.lastPathComponent) == ["certificate.pdf"])

        // Write side: b.1905 is filed into neither.
        let requested = try store.folderForPhotoRequest(person: born1905)
        #expect(!["Mary_OConnor_I2", "Mary_OConnor_b1904"].contains(requested.lastPathComponent))
    }

    /// An unsafe NON-EMPTY pointer rejects outright — it never degrades to
    /// the name, an alias folder, the FamilySearch-ID folder, or a group
    /// folder, however well those match (codex #1369 finding 2).
    @Test func anUnsafePointerRejectsAndNeverDegradesToNameAliasOrGroupFolders() throws {
        let (base, plain) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        var store = plain
        let people = store.peopleDirectory
        try writeImage(to: people.appendingPathComponent("Christopher_OConnor/portrait.png"), type: .png)
        try writeImage(to: people.appendingPathComponent("Christopher_Dennis_OConnor/army.png"), type: .png)
        try writeText("notes", to: people.appendingPathComponent("Christopher_Dennis_OConnor/notes.txt"))
        // `Oconnor`, one CamelCase hump: `groupFolderTokens` would split
        // `OConnor` into `o` + `connor` and match no one.
        try writeImage(to: people.appendingPathComponent("Christopher_and_Mary_Oconnor/wedding.png"), type: .png)
        try writeImage(to: people.appendingPathComponent("KWC1-ABC/chosen.png"), type: .png)
        // The fixture does match this name by the group rule.
        #expect(store.groupPhotoURLs(for: FamilyAssetPerson(name: "Christopher O'Connor"))
                    .map(\.lastPathComponent) == ["wedding.png"])

        for bad in ["@I 1@", "@I1@/..", "I1\u{0}", "../I1"] {
          for withDirectory in [false, true] {
            let person = FamilyAssetPerson(gedcomID: bad, name: "Christopher O'Connor",
                                           birthYear: nil, familySearchID: "KWC1-ABC")
            store.identity = withDirectory ? FamilyAssetIdentityDirectory(
                members: [.init(gedcomID: bad, givenTokens: ["christopher"], surnameTokens: ["oconnor"],
                                suffix: nil, aliasTokens: ["dennis"], aliasNames: ["Christopher Dennis O'Connor"])],
                ownerGedcomID: nil) : nil
            let why = Comment(rawValue: "id \(bad.debugDescription) (directory: \(withDirectory)) must reject, not degrade")
            #expect(FamilyAssetStore.hasMalformedGEDCOMID(person), why)
            #expect(store.personFolders(for: person).isEmpty, why)
            #expect(store.photoURLs(for: person).isEmpty, why)
            #expect(store.documentURLs(for: person).isEmpty, why)
            #expect(store.groupPhotoURLs(for: person).isEmpty, why)
            #expect(store.chosenPhotoFolder(for: person) == nil, why)
            #expect(store.cardPhotoURL(for: person) == nil, why)
            #expect(store.originalPhotoURL(for: person) == nil, why)
            #expect(throws: FamilyAssetStore.StoreError.invalidPerson, why) {
                try store.folderForPhotoRequest(person: person)
            }
          }
        }
        // The same record with a sound pointer reads all of it.
        let sound = FamilyAssetPerson(gedcomID: "@I1@", name: "Christopher O'Connor",
                                      birthYear: nil, familySearchID: "KWC1-ABC")
        store.identity = FamilyAssetIdentityDirectory(
            members: [.init(gedcomID: "@I1@", givenTokens: ["christopher"], surnameTokens: ["oconnor"],
                            suffix: nil, aliasTokens: ["dennis"], aliasNames: ["Christopher Dennis O'Connor"])],
            ownerGedcomID: nil)
        #expect(store.personFolders(for: sound).map(\.lastPathComponent)
                == ["KWC1-ABC", "Christopher_OConnor", "Christopher_Dennis_OConnor"])
        #expect(Array(store.photoURLs(for: sound).map(\.lastPathComponent).prefix(3))
                == ["chosen.png", "portrait.png", "army.png"])
    }
}
