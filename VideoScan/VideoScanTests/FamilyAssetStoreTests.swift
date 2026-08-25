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

    // MARK: Photos import hardening (codex #663, 2026-08-25)

    private func personFolder(_ store: FamilyAssetStore) throws -> URL {
        try store.folderForPhotoRequest(person: FamilyAssetPerson(name: "Judson Lamb", birthYear: 1846))
    }

    private func pngBytes(_ base: URL, width: Int = 48, height: Int = 48) throws -> Data {
        let scratch = base.appendingPathComponent("scratch-\(UUID().uuidString).png")
        try writePNG(to: scratch, width: width, height: height)
        return try Data(contentsOf: scratch)
    }

    @Test func oversizedPhotoIsRejectedBeforeAnyWrite() throws {
        let (base, store) = try temporaryStore()
        let folder = try personFolder(store)
        let huge = Data(count: FamilyAssetStore.maxImportBytes + 1)
        #expect(throws: FamilyAssetStore.StoreError.imageTooLarge(bytes: huge.count)) {
            try store.importPersonPhoto(huge, fileExtension: "jpg", into: folder)
        }
        #expect(try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!fileManager.fileExists(atPath: store.cacheRoot.appendingPathComponent("import-staging").path),
                "no staging file is ever created (the symlink-swap window is gone)")
        _ = base
    }

    @Test func truncatedImageFailsForcedDecodeAndNeverLands() throws {
        let (base, store) = try temporaryStore()
        let folder = try personFolder(store)
        let whole = try pngBytes(base, width: 256, height: 256)
        #expect(FamilyAssetImageValidator.isVerifiedImageData(whole))
        // Header intact, pixel data cut: ImageIO STILL reports one complete
        // frame (measured 2026-08-25), so only the container check catches it.
        let truncated = whole.prefix(whole.count / 3)
        #expect(!FamilyAssetImageValidator.isVerifiedImageData(Data(truncated)))
        #expect(!FamilyAssetImageValidator.isVerifiedImageData(Data(whole.dropLast(12))),
                "missing IEND = not whole")
        #expect(!FamilyAssetImageValidator.isVerifiedImageData(Data("not an image at all, just text".utf8)))
        #expect(throws: (any Error).self) {
            try store.importPersonPhoto(Data(truncated), fileExtension: "png", into: folder)
        }
        #expect(try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty)
        // Same rule at display time for a file already in the folder.
        let planted = folder.appendingPathComponent("cut.png")
        try Data(truncated).write(to: planted)
        #expect(FamilyAssetImageValidator.revalidatedURL(planted) == nil)
    }

    @Test func importNeverFollowsAPlantedSymlinkAndNeverOverwrites() throws {
        let (base, store) = try temporaryStore()
        var clocked = store
        let fixed = Date(timeIntervalSince1970: 1_756_140_000)   // 2026-08-25 ~13:20 ET
        clocked.importClock = { fixed }
        let folder = try personFolder(clocked)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let predicted = folder.appendingPathComponent(
            "\(folder.lastPathComponent)-from-Photos-\(f.string(from: fixed)).png")
        let outside = base.appendingPathComponent("outside-the-archive.png")
        try fileManager.createSymbolicLink(at: predicted, withDestinationURL: outside)

        let landed = try clocked.importPersonPhoto(try pngBytes(base), fileExtension: "png", into: folder)
        #expect(!fileManager.fileExists(atPath: outside.path), "the link's target must never be written")
        #expect(landed.lastPathComponent.hasSuffix("-2.png"), "the taken name is skipped, not replaced")
        let values = try landed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        #expect(values.isRegularFile == true && values.isSymbolicLink != true)
        // A second import at the same instant is again a new file.
        let again = try clocked.importPersonPhoto(try pngBytes(base), fileExtension: "png", into: folder)
        #expect(again.lastPathComponent.hasSuffix("-3.png"))
    }

    /// codex #675: the folder itself swapped for a symlink AFTER
    /// revalidation and BEFORE the write. The clock hook runs exactly in
    /// that window, so the test performs the swap there; the fd walk must
    /// refuse (ELOOP) and the link's target must stay untouched.
    @Test func parentFolderSwappedForSymlinkMidImportIsRefused() throws {
        let (base, store) = try temporaryStore()
        let folder = try personFolder(store)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var racing = store
        let fm = fileManager
        racing.importClock = {
            try? fm.removeItem(at: folder)
            try? fm.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
            return Date(timeIntervalSince1970: 1_756_140_000)
        }
        #expect(throws: FamilyAssetStore.StoreError.unsafeDirectory(folder)) {
            try racing.importPersonPhoto(try pngBytes(base), fileExtension: "png", into: folder)
        }
        #expect(try fileManager.contentsOfDirectory(atPath: elsewhere.path).isEmpty,
                "nothing was written through the swapped-in link")
    }

    @Test func nonEEXISTCreateErrorsSurfaceImmediately() throws {
        let (base, store) = try temporaryStore()
        let folder = try personFolder(store)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        do {
            _ = try store.importPersonPhoto(try pngBytes(base), fileExtension: "png", into: folder)
            Issue.record("expected a permission failure")
        } catch FamilyAssetStore.StoreError.createFailed(_, let errno) {
            #expect(errno == EACCES, "the FIRST meaningful errno, not a 50-deep suffix walk")
        }
    }

    @Test func jpegAndHEICStructureChecksMatchRealEncoders() throws {
        func encode(_ type: UTType) throws -> Data {
            let context = try #require(CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let out = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(
                out, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            return out as Data
        }
        for type in [UTType.jpeg, .heic] {
            let whole = try encode(type)
            #expect(FamilyAssetImageValidator.isVerifiedImageData(whole), "\(type.identifier)")
            #expect(!FamilyAssetImageValidator.isVerifiedImageData(Data(whole.dropLast(7))),
                    "\(type.identifier) with the tail cut is not whole")
        }
    }

    @Test func importAcceptsExactlyWhatDiscoveryWillShow() throws {
        let (base, store) = try temporaryStore()
        let folder = try personFolder(store)
        let bytes = try pngBytes(base)
        for ext in ["tif", "tiff", "gif", "bmp", "pdf"] {
            #expect(throws: (any Error).self, "\(ext) is not discoverable, so it must not be importable") {
                try store.importPersonPhoto(bytes, fileExtension: ext, into: folder)
            }
        }
        let landed = try store.importPersonPhoto(bytes, fileExtension: "PNG", into: folder)
        #expect(store.revalidatedImageURL(landed) != nil, "what was imported is what the store shows")
    }

    // MARK: Group folders (Rick 2026-08-25)

    @Test func groupFolderNamesAreRecognisedAndTokenised() {
        #expect(FamilyAssetStore.groupFolderTokens("RickDonnaBreenFamily") == ["rick", "donna", "breen"])
        #expect(FamilyAssetStore.groupFolderTokens("Rick_and_Donna") == ["rick", "donna"])
        #expect(FamilyAssetStore.groupFolderTokens("Breen_Family") == ["breen"])
        #expect(FamilyAssetStore.groupFolderTokens("Judson_Lamb") == nil, "a person folder is not a group")
        #expect(FamilyAssetStore.groupFolderTokens("Family") == nil, "a marker alone names nobody")
    }

    @Test func groupFolderMatchesFirstNameOrDiminutivePlusSurname() {
        let g = "RickDonnaBreenFamily"
        #expect(FamilyAssetStore.groupFolderMatches(g, person: "Rick Breen"))
        #expect(FamilyAssetStore.groupFolderMatches(g, person: "Richard Harding Breen Jr"), "rick → richard")
        #expect(FamilyAssetStore.groupFolderMatches(g, person: "Donna Breen"))
        #expect(!FamilyAssetStore.groupFolderMatches(g, person: "Donna Elaine Hudson"), "maiden surname is not in the folder")
        #expect(!FamilyAssetStore.groupFolderMatches(g, person: "John Breen"))
        #expect(!FamilyAssetStore.groupFolderMatches(g, person: "Rick"), "a lone first name is never enough")
        #expect(FamilyAssetStore.groupFolderMatches("Breen_Family", person: "John Breen"), "surname-only group")
        #expect(!FamilyAssetStore.groupFolderMatches("Breen_Family", person: "Judson Lamb"))
    }

    @Test func groupPhotosFollowAPersonsOwnPhotos() throws {
        let (base, store) = try temporaryStore()
        let own = try store.folderForPhotoRequest(person: FamilyAssetPerson(name: "Rick Breen"))
        try writePNG(to: own.appendingPathComponent("portrait.png"))
        let group = store.peopleDirectory.appendingPathComponent("RickDonnaBreenFamily", isDirectory: true)
        try writePNG(to: group.appendingPathComponent("SouthEastMontana1995.png"))
        let rick = store.photoURLs(for: FamilyAssetPerson(name: "Rick Breen"))
        #expect(rick.map(\.lastPathComponent) == ["portrait.png", "SouthEastMontana1995.png"])
        let donna = store.photoURLs(for: FamilyAssetPerson(name: "Donna Breen"))
        #expect(donna.map(\.lastPathComponent) == ["SouthEastMontana1995.png"], "no own folder, group still shows")
        #expect(store.photoURLs(for: FamilyAssetPerson(name: "Judson Lamb")).isEmpty)
        _ = base
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
