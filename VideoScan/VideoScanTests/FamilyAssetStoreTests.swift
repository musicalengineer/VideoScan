import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoScan

@Suite("Family asset store", .serialized)
struct FamilyAssetStoreTests {
    private let fileManager = FileManager.default

    private func temporaryStore() throws -> (base: URL, store: FamilyAssetStore) {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("FamilyAssetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return (
            base,
            FamilyAssetStore(
                root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true)))
    }

    private func writePNG(to url: URL) throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try png.write(to: url)
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func productionRootsPreferMasterArchiveAndKeepCacheInApplicationSupport() {
        let archive = URL(fileURLWithPath: "/Volumes/FamilyArchive", isDirectory: true)
        let support = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        let roots = FamilyAssetStore.productionRoots(
            masterArchiveRoot: archive,
            applicationSupportRoot: support)
        #expect(roots.assets.path == "/Volumes/FamilyArchive/40_Family_Tree")
        #expect(roots.thumbnailCache.path == "/tmp/Application Support/VideoScan/family-tree/thumbs")

        let fallback = FamilyAssetStore.productionRoots(
            masterArchiveRoot: nil,
            applicationSupportRoot: support)
        #expect(fallback.assets.path == "/tmp/Application Support/VideoScan/family-tree/assets")
        #expect(fallback.thumbnailCache == roots.thumbnailCache)
    }

    @Test func productionAuthorityNeverFallsBackFromUnavailableMaster() {
        let support = URL(fileURLWithPath: "/tmp/FamilyAssetSupport", isDirectory: true)
        let master = URL(fileURLWithPath: "/Volumes/ExpectedArchive", isDirectory: true)

        let fallback = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: nil,
            masterIsSafelyAvailable: true,
            readOnly: false,
            applicationSupportRoot: support)
        #expect(fallback.access == .readWrite)
        #expect(fallback.roots.assets.path.hasSuffix("family-tree/assets"))

        let offline = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: master,
            masterIsSafelyAvailable: false,
            readOnly: false,
            applicationSupportRoot: support)
        #expect(offline.access == .unavailable)
        #expect(offline.roots.assets.path == "/Volumes/ExpectedArchive/40_Family_Tree")

        let viewer = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: master,
            masterIsSafelyAvailable: true,
            readOnly: true,
            applicationSupportRoot: support)
        #expect(viewer.access == .readOnly)
        #expect(viewer.roots.assets == offline.roots.assets)
    }

    @Test func legacyGEDCOMIsReadOnlyFallbackOnlyWithoutMasterArchive() throws {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("LegacyGEDCOMFallback-\(UUID())", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let support = base.appendingPathComponent("support", isDirectory: true)
        let legacy = support.appendingPathComponent(
            "VideoScan/family-tree/originals", isDirectory: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("0 HEAD\n0 @I1@ INDI\n1 NAME Legacy /Person/\n0 TRLR\n".utf8)
            .write(to: legacy.appendingPathComponent("legacy.ged"))

        let fallback = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: nil,
            masterIsSafelyAvailable: true,
            readOnly: true,
            applicationSupportRoot: support)
        #expect(fallback.gedcomDirectory()
            == legacy.standardizedFileURL.resolvingSymlinksInPath())
        #expect(fallback.loadFamilyGraph()?.people["@I1@"]?.name == "Legacy Person")

        // Once the new convention contains any regular GEDCOM candidate it
        // is authoritative, even when malformed; loader diagnostics should
        // report that file instead of silently changing trees.
        let preferred = fallback.roots.assets.appendingPathComponent(
            "GEDCOM", isDirectory: true)
        try fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: preferred.appendingPathComponent("new.ged"))
        #expect(fallback.gedcomDirectory() == preferred.standardizedFileURL)
        #expect(fallback.loadFamilyGraph() == nil)

        let master = base.appendingPathComponent("archive", isDirectory: true)
        let designated = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: master,
            masterIsSafelyAvailable: true,
            readOnly: true,
            applicationSupportRoot: support)
        #expect(designated.legacyGEDCOMDirectory == nil)
        #expect(designated.gedcomDirectory().path
            == master.appendingPathComponent("40_Family_Tree/GEDCOM").path)
    }

    @Test func crestLookupIsCaseAndDiacriticInsensitiveAndContentVerified() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        try writePNG(to: store.crestsDirectory.appendingPathComponent("Bréen.PNG"))
        try Data("not an image".utf8).write(
            to: store.crestsDirectory.appendingPathComponent("Hudson.png"))

        #expect(store.crestURL(surname: "BREEN")?.lastPathComponent == "Bréen.PNG")
        #expect(store.crestURL(surname: "Hudson") == nil)
        #expect(store.crestURL(surname: "Latta") == nil)
        #expect(store.crests().map(\.surname) == ["Bréen"])
    }

    @Test func gedcomIDFolderWinsAndNameIsOnlyAFallback() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let idFolder = store.peopleDirectory.appendingPathComponent("@I42@", isDirectory: true)
        let nameFolder = store.peopleDirectory.appendingPathComponent("Dávid McGill", isDirectory: true)
        try writePNG(to: idFolder.appendingPathComponent("z.png"))
        try writePNG(to: nameFolder.appendingPathComponent("A.PNG"))

        let urls = store.photoURLs(for: FamilyAssetPerson(
            gedcomID: "@i42@",
            name: "DAVID MCGILL"))
        #expect(urls.map(\.lastPathComponent) == ["z.png"])
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "DAVID MCGILL"))
            .map(\.lastPathComponent) == ["A.PNG"])
    }

    @Test func deployedPersonFolderConventionMatchesPunctuationYearAndID() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        try writePNG(to: store.peopleDirectory
            .appendingPathComponent("Mary_OConnor", isDirectory: true)
            .appendingPathComponent("portrait.png"))
        try writePNG(to: store.peopleDirectory
            .appendingPathComponent("Mary_Strayhorn_b1754", isDirectory: true)
            .appendingPathComponent("older.png"))
        try writePNG(to: store.peopleDirectory
            .appendingPathComponent("Mary_Strayhorn_b1800", isDirectory: true)
            .appendingPathComponent("younger.png"))
        try writePNG(to: store.peopleDirectory
            .appendingPathComponent(
                "Mary_Strayhorn_b1754_I342486912729", isDirectory: true)
            .appendingPathComponent("identified.png"))

        #expect(store.photoURLs(for: FamilyAssetPerson(name: "Mary O'Connor"))
            .map(\.lastPathComponent) == ["portrait.png"])
        #expect(store.photoURLs(for: FamilyAssetPerson(
            name: "Mary Strayhorn", birthYear: 1800))
            .map(\.lastPathComponent) == ["younger.png"])
        #expect(store.photoURLs(for: FamilyAssetPerson(
            gedcomID: "@I342486912729@",
            name: "Mary Strayhorn",
            birthYear: 1754))
            .map(\.lastPathComponent) == ["identified.png"])
        #expect(store.photoURLs(for: FamilyAssetPerson(
            name: "Mary Strayhorn")).isEmpty)
    }

    @Test func multiplePersonImagesHaveDeterministicOrder() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let folder = store.peopleDirectory
            .appendingPathComponent("Mary_OConnor", isDirectory: true)
        try writePNG(to: folder.appendingPathComponent("z.png"))
        try writePNG(to: folder.appendingPathComponent("A.png"))
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "Mary O'Connor"))
            .map(\.lastPathComponent) == ["A.png", "z.png"])
    }

    @Test func poisonedEntriesAreRejectedAndLookupNeverRecurses() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let person = store.peopleDirectory.appendingPathComponent("David McGill", isDirectory: true)
        try writePNG(to: person.appendingPathComponent("good.png"))
        try Data("plain text".utf8).write(to: person.appendingPathComponent("fake.jpg"))
        let nested = person.appendingPathComponent("nested", isDirectory: true)
        try writePNG(to: nested.appendingPathComponent("hidden.png"))
        let outside = base.appendingPathComponent("outside.png")
        try writePNG(to: outside)
        try fileManager.createSymbolicLink(
            at: person.appendingPathComponent("linked.png"),
            withDestinationURL: outside)

        let urls = store.photoURLs(for: FamilyAssetPerson(name: "david mcgill"))
        #expect(urls.map(\.lastPathComponent) == ["good.png"])

        let linkedFolder = store.peopleDirectory.appendingPathComponent("Alias Person")
        try fileManager.createSymbolicLink(at: linkedFolder, withDestinationURL: person)
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "Alias Person")).isEmpty)
    }

    @Test func folderCreationFlattensTraversalAndRejectsEmptyIdentity() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let folder = try store.folderForPhotoRequest(
            person: FamilyAssetPerson(name: "../David: McGill\\Photos"))
        #expect(folder.deletingLastPathComponent() == store.peopleDirectory)
        #expect(folder.lastPathComponent == "David_McGillPhotos")
        #expect(fileManager.fileExists(atPath: folder.path))

        let idFolder = try store.folderForPhotoRequest(
            person: FamilyAssetPerson(gedcomID: "@I7@", name: "David McGill"))
        #expect(idFolder.lastPathComponent == "David_McGill")

        #expect(throws: FamilyAssetStore.StoreError.invalidPerson) {
            try store.folderForPhotoRequest(
                person: FamilyAssetPerson(gedcomID: "../I7", name: "David McGill"))
        }

        #expect(store.photoURLs(for: FamilyAssetPerson(
            gedcomID: "../I7", name: "David McGill")).isEmpty)

        #expect(throws: FamilyAssetStore.StoreError.invalidPerson) {
            try store.folderForPhotoRequest(person: FamilyAssetPerson(name: ".."))
        }
    }

    @Test func duplicatePhotoRequestFoldersUseBirthYearThenGEDCOMID() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        _ = try store.folderForPhotoRequest(person: FamilyAssetPerson(name: "Mary Strayhorn"))
        let year = try store.folderForPhotoRequest(person: FamilyAssetPerson(
            name: "Mary Strayhorn", birthYear: 1754))
        #expect(year.lastPathComponent == "Mary_Strayhorn_b1754")

        let collision = try store.folderForPhotoRequest(person: FamilyAssetPerson(
            gedcomID: "@I342486912729@",
            name: "Mary Strayhorn",
            birthYear: 1754))
        #expect(collision.lastPathComponent
            == "Mary_Strayhorn_b1754_I342486912729")
    }

    @Test func symlinkedStoreDirectoriesAreNeverReadOrWritten() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try writePNG(to: outside.appendingPathComponent("Breen.png"))
        try fileManager.createDirectory(at: store.root, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: store.crestsDirectory,
            withDestinationURL: outside)

        #expect(store.crestURL(surname: "Breen") == nil)
        #expect(throws: FamilyAssetStore.StoreError.self) {
            try store.ensureCrestsDirectory()
        }
    }

    @Test func importedCrestIsCopiedAndDoesNotSilentlyReplace() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let source = base.appendingPathComponent("source.png")
        try writePNG(to: source)
        let imported = try store.importCrest(from: source, surname: "Breen")
        #expect(imported.lastPathComponent == "Breen.png")
        #expect(store.crestURL(surname: "breen") == imported)

        #expect(throws: FamilyAssetStore.StoreError.self) {
            try store.importCrest(from: source, surname: "BRÉEN")
        }
    }

    @Test func returnedImageMustBeRevalidatedAfterReplacement() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let image = store.peopleDirectory
            .appendingPathComponent("David McGill", isDirectory: true)
            .appendingPathComponent("portrait.png")
        try writePNG(to: image)
        let resolved = try #require(store.photoURLs(
            for: FamilyAssetPerson(name: "David McGill")).first)
        #expect(store.revalidatedImageURL(resolved) != nil)
        try fileManager.removeItem(at: image)
        try Data("replaced".utf8).write(to: image)
        #expect(store.revalidatedImageURL(resolved) == nil)
    }

    @Test func unavailableMasterNeverFallsBackOrWritesAndReadOnlyStillReads() throws {
        let (base, writable) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        try writePNG(to: writable.crestsDirectory.appendingPathComponent("Breen.png"))

        let unavailable = FamilyAssetStore(
            root: writable.root,
            cacheRoot: writable.cacheRoot,
            access: .unavailable)
        #expect(unavailable.crestURL(surname: "Breen") == nil)
        #expect(throws: FamilyAssetStore.StoreError.sourceUnavailable) {
            try unavailable.folderForPhotoRequest(person: FamilyAssetPerson(name: "David"))
        }

        let readOnly = FamilyAssetStore(
            root: writable.root,
            cacheRoot: writable.cacheRoot,
            access: .readOnly)
        #expect(readOnly.crestURL(surname: "Breen") != nil)
        #expect(throws: FamilyAssetStore.StoreError.readOnly) {
            try readOnly.folderForPhotoRequest(person: FamilyAssetPerson(name: "David"))
        }
    }

    @Test func normalizationCollisionsFailClosed() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        try writePNG(to: store.crestsDirectory.appendingPathComponent("Breen.png"))
        try writePNG(to: store.crestsDirectory.appendingPathComponent("Bréen.jpg"))
        #expect(store.crestURL(surname: "BREEN") == nil)

        try writePNG(to: store.peopleDirectory
            .appendingPathComponent("Renée", isDirectory: true)
            .appendingPathComponent("one.png"))
        try writePNG(to: store.peopleDirectory
            .appendingPathComponent("Renee", isDirectory: true)
            .appendingPathComponent("two.png"))
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "renee")).isEmpty)
    }

    @Test func thumbnailDecodeIsPixelBounded() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let image = store.crestsDirectory.appendingPathComponent("Breen.png")
        try writePNG(to: image, width: 1600, height: 800)
        let thumbnail = try #require(store.makeThumbnail(for: image, maxPixelSize: 120))
        #expect(thumbnail.width <= 120)
        #expect(thumbnail.height <= 120)
        #expect(thumbnail.width == 120)
        #expect(thumbnail.height == 60)
    }
}
