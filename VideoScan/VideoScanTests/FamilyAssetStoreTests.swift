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
                root: base.appendingPathComponent("archive/Family Tree", isDirectory: true),
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
        #expect(roots.assets.path == "/Volumes/FamilyArchive/Family Tree")
        #expect(roots.thumbnailCache.path == "/tmp/Application Support/VideoScan/family-tree/thumbs")

        let fallback = FamilyAssetStore.productionRoots(
            masterArchiveRoot: nil,
            applicationSupportRoot: support)
        #expect(fallback.assets.path == "/tmp/Application Support/VideoScan/family-tree/assets")
        #expect(fallback.thumbnailCache == roots.thumbnailCache)
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
        #expect(folder.lastPathComponent == "David McGill Photos")
        #expect(fileManager.fileExists(atPath: folder.path))

        let idFolder = try store.folderForPhotoRequest(
            person: FamilyAssetPerson(gedcomID: "@I7@", name: "David McGill"))
        #expect(idFolder.lastPathComponent == "@I7@")

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
