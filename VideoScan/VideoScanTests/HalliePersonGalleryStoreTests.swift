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
}
