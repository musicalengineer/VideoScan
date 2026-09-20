// FamilyDocumentStoreTests.swift
// Certificates and other papers on a Family Tree person (Rick, 2026-09-20:
// "right click add docs on a person … BC, DC, MC, Other then allow an
// upload of a png, jpg, or pdf. This should be stored as such in the
// database.").
//
// Five dimensions (docs/testing_retrospective_2026_07_05.md):
//   Logic     — import PNG/JPG/PDF, sidecar round trip, kind naming, no
//               overwrite, every refusal, missing-file drop, removal to .trash
//   Scale     — 500 documents listed under a budget
//   Media     — N/A (no media files are opened; PDFs/images are the fixtures)
//   Isolation — sandbox roots only; a sensor pins that no test touches the
//               real family-tree/assets
//   Sensor    — the sidecar schema (key set + kind codes) is frozen

import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import VideoScan

@Suite("Family documents — store", .serialized)
struct FamilyDocumentStoreTests {
    private let fileManager = FileManager.default

    // MARK: Sandbox

    private struct Sandbox {
        let base: URL
        let store: FamilyAssetStore
        let sources: URL
    }

    private func sandbox(access: FamilyAssetStore.Access = .readWrite,
                         clock: Date? = nil) throws -> Sandbox {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("FamilyDocumentStoreTests-\(UUID().uuidString)", isDirectory: true)
        let sources = base.appendingPathComponent("sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        var store = FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
            access: access)
        if let clock { store.importClock = { clock } }
        return Sandbox(base: base, store: store, sources: sources)
    }

    private let mary = FamilyAssetPerson(gedcomID: "@I428@", name: "Mary C O'Connor",
                                         birthYear: 1861, familySearchID: "LZ7X-ABC")

    /// 2026-09-20 10:15:00 UTC — the stamp is rendered in the local zone,
    /// so tests assert on the prefix and the `-2` suffix, not the digits.
    private let fixedClock = Date(timeIntervalSince1970: 1_789_726_500)

    // MARK: Fixtures (tiny, valid, made in-process)

    private func imageData(type: UTType) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pdfData() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return try #require(document.dataRepresentation())
    }

    private func write(_ data: Data, named name: String, in sandbox: Sandbox) throws -> URL {
        let url = sandbox.sources.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    private func documentsDir(_ folder: URL) -> URL {
        FamilyAssetStore.documentsFolder(in: folder)
    }

    private func sidecarRows(in folder: URL) throws -> [[String: Any]] {
        let url = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Logic — import

    @Test func importsPNGJPGAndPDFIntoTheDocumentsFolderAndListsThem() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        #expect(folder.deletingLastPathComponent() == sb.store.peopleDirectory)
        #expect(folder.lastPathComponent.contains("LZ7X-ABC"))

        let png = try write(try imageData(type: .png), named: "Mary_BC_scan.png", in: sb)
        let jpg = try write(try imageData(type: .jpeg), named: "Mary DC.jpg", in: sb)
        let pdf = try write(try pdfData(), named: "marriage.pdf", in: sb)

        let a = try sb.store.importPersonDocument(from: png, kind: .birth, note: "  From Ireland  ", into: folder, for: mary)
        let b = try sb.store.importPersonDocument(from: jpg, kind: .death, note: "", into: folder, for: mary)
        let c = try sb.store.importPersonDocument(from: pdf, kind: .marriage, note: "Parish copy", into: folder, for: mary)

        for (doc, ext) in [(a, "png"), (b, "jpg"), (c, "pdf")] {
            let url = try #require(doc.fileURL)
            #expect(url.deletingLastPathComponent() == documentsDir(folder))
            #expect(url.pathExtension == ext)
            #expect(fileManager.fileExists(atPath: url.path))
            let bytes = try Data(contentsOf: url)
            #expect(bytes.count == doc.byteCount)
            #expect(FamilyAssetStore.sha256Hex(bytes) == doc.sha256)
        }
        #expect(a.originalFilename == "Mary_BC_scan.png")
        #expect(a.note == "From Ireland")
        #expect(b.note.isEmpty)

        let listed = sb.store.documents(for: mary)
        #expect(listed.count == 3)
        #expect(Set(listed.map(\.id)) == [a.id, b.id, c.id])
        #expect(listed.allSatisfy { $0.fileURL != nil })
        // Photo discovery is untouched by the new folder: nothing under
        // Documents/ shows up as a portrait.
        #expect(sb.store.photoURLs(for: mary).isEmpty)
    }

    @Test func fileNamesCarryTheKindCodeAndStamp() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "x.pdf", in: sb)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: fixedClock)

        for kind in PersonDocumentKind.allCases {
            let doc = try sb.store.importPersonDocument(from: pdf, kind: kind, note: "", into: folder)
            #expect(doc.filename == "\(kind.rawValue)-\(stamp).pdf")
        }
        #expect(PersonDocumentKind.birth.rawValue == "BC")
        #expect(PersonDocumentKind.death.rawValue == "DC")
        #expect(PersonDocumentKind.marriage.rawValue == "MC")
        #expect(PersonDocumentKind.other.rawValue == "Other")
        #expect(PersonDocumentKind.birth.displayName == "Birth certificate")
        #expect(PersonDocumentKind.marriage.displayName == "Marriage certificate")
    }

    @Test func aSecondImportInTheSameSecondNeverOverwritesItGetsDashTwo() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let one = try write(try imageData(type: .png), named: "one.png", in: sb)
        let first = try sb.store.importPersonDocument(from: one, kind: .birth, note: "", into: folder)
        let second = try sb.store.importPersonDocument(from: one, kind: .birth, note: "", into: folder)
        #expect(second.filename == first.filename.replacingOccurrences(of: ".png", with: "-2.png"))
        let firstURL = try #require(first.fileURL)
        let secondURL = try #require(second.fileURL)
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == Data(contentsOf: secondURL))
        #expect(sb.store.documents(for: mary).count == 2)
    }

    @Test func logsOneLineWithKindPersonKeyFileAndSize() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        var lines: [String] = []
        let lock = NSLock()
        PersonDocumentLog.shared.setExtraSink { line in lock.withLock { lines.append(line) } }
        defer { PersonDocumentLog.shared.setExtraSink(nil) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        let doc = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder, for: mary)
        let added = lock.withLock { lines }
        #expect(added.count == 1)
        let line = try #require(added.first)
        #expect(line.hasPrefix("[tree] added Birth certificate for Mary C O'Connor (LZ7X-ABC) — \(doc.filename), "))
        #expect(line.hasSuffix("KB") || line.hasSuffix("bytes") || line.hasSuffix("MB"))
    }

    // MARK: Logic — refusals (negative)

    @Test func refusesExtensionsOutsidePNGJPGPDF() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let txt = try write(Data("hello".utf8), named: "note.txt", in: sb)
        let heic = try write(try imageData(type: .png), named: "photo.heic", in: sb)
        let none = try write(try pdfData(), named: "certificate", in: sb)
        for url in [txt, heic, none] {
            #expect(throws: FamilyAssetStore.DocumentError.unsupportedType(url.pathExtension.lowercased())) {
                try sb.store.importPersonDocument(from: url, kind: .other, note: "", into: folder)
            }
        }
        #expect(!fileManager.fileExists(atPath: documentsDir(folder).path))
        #expect(sb.store.documents(for: mary).isEmpty)
    }

    @Test func refusesBytesThatAreNotTheClaimedType() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let textAsPDF = try write(Data("This is not a PDF, it is a note.".utf8), named: "fake.pdf", in: sb)
        let headerOnlyPDF = try write(Data("%PDF-1.4 and nothing else".utf8), named: "stub.pdf", in: sb)
        let jpegAsPNG = try write(try imageData(type: .jpeg), named: "really-jpeg.png", in: sb)
        let pngAsJPG = try write(try imageData(type: .png), named: "really-png.jpg", in: sb)
        let truncatedPNG = try write(try imageData(type: .png).dropLast(12), named: "cut.png", in: sb)
        for url in [textAsPDF, headerOnlyPDF, jpegAsPNG, pngAsJPG, truncatedPNG] {
            #expect(throws: FamilyAssetStore.DocumentError.notTheClaimedType(url.pathExtension)) {
                try sb.store.importPersonDocument(from: url, kind: .other, note: "", into: folder)
            }
        }
        #expect(!fileManager.fileExists(atPath: documentsDir(folder).path))
    }

    @Test func refusesAnOversizeFileBeforeReadingIt() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        // A sparse file: the size is what the check sees, no bytes are
        // materialised, and the test does not write 48 MB.
        let big = sb.sources.appendingPathComponent("huge.pdf")
        #expect(fileManager.createFile(atPath: big.path, contents: Data("%PDF-".utf8)))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FamilyAssetStore.maxImportBytes) + 1)
        try handle.close()
        #expect(throws: FamilyAssetStore.DocumentError.tooLarge(bytes: FamilyAssetStore.maxImportBytes + 1)) {
            try sb.store.importPersonDocument(from: big, kind: .other, note: "", into: folder)
        }
        #expect(!fileManager.fileExists(atPath: documentsDir(folder).path))
    }

    @Test func refusesASymlinkedPersonFolderAndFoldersOutsidePeople() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let real = try sb.store.folderForPhotoRequest(person: mary)
        let link = sb.store.peopleDirectory.appendingPathComponent("Mary_Link", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)
        let elsewhere = sb.base.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        for folder in [link, elsewhere] {
            #expect(throws: FamilyAssetStore.StoreError.unsafeDirectory(folder)) {
                try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
            }
        }
        #expect(!fileManager.fileExists(atPath: documentsDir(real).path))
        #expect(sb.store.documents(inPersonFolder: link).isEmpty)
    }

    @Test func refusesASymlinkedSourceFile() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let real = try write(try pdfData(), named: "bc.pdf", in: sb)
        let alias = sb.sources.appendingPathComponent("alias.pdf")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: real)
        #expect(throws: FamilyAssetStore.DocumentError.sourceUnreadable("alias.pdf")) {
            try sb.store.importPersonDocument(from: alias, kind: .birth, note: "", into: folder)
        }
    }

    @Test func refusesReadOnlyAndUnavailableArchives() throws {
        let writable = try sandbox()
        defer { try? fileManager.removeItem(at: writable.base) }
        let folder = try writable.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: writable)

        let readOnly = FamilyAssetStore(root: writable.store.root, cacheRoot: writable.store.cacheRoot,
                                        access: .readOnly)
        #expect(throws: FamilyAssetStore.StoreError.readOnly) {
            try readOnly.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        }
        let unavailable = FamilyAssetStore(root: writable.store.root, cacheRoot: writable.store.cacheRoot,
                                           access: .unavailable)
        #expect(throws: FamilyAssetStore.StoreError.sourceUnavailable) {
            try unavailable.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        }
        #expect(!fileManager.fileExists(atPath: documentsDir(folder).path))

        // Reads: read-only still lists, unavailable never does.
        let doc = try writable.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        #expect(readOnly.documents(for: mary).map(\.id) == [doc.id])
        #expect(unavailable.documents(for: mary).isEmpty)
        #expect(throws: FamilyAssetStore.StoreError.readOnly) {
            try readOnly.removeDocument(doc, from: folder)
        }
        let stillThere = try #require(doc.fileURL)
        #expect(fileManager.fileExists(atPath: stillThere.path))
    }

    // MARK: Logic — listing and removal

    @Test func aRowWhoseFileIsGoneIsDroppedAndLoggedOnce() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        var lines: [String] = []
        let lock = NSLock()
        PersonDocumentLog.shared.setExtraSink { line in lock.withLock { lines.append(line) } }
        defer { PersonDocumentLog.shared.setExtraSink(nil) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        let kept = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        let lost = try sb.store.importPersonDocument(from: pdf, kind: .death, note: "", into: folder)
        // Simulate Rick tidying in Finder (the store itself never deletes).
        try fileManager.removeItem(at: #require(lost.fileURL))
        lock.withLock { lines.removeAll() }

        #expect(sb.store.documents(for: mary).map(\.id) == [kept.id])
        #expect(sb.store.documents(for: mary).map(\.id) == [kept.id])
        #expect(sb.store.documents(for: mary).map(\.id) == [kept.id])
        let missing = lock.withLock { lines.filter { $0.contains("missing on disk") } }
        #expect(missing.count == 1)
        #expect(missing.first?.contains(lost.filename) == true)
        // The sidecar is not rewritten by a read: the row is still there
        // for Rick to restore the file against.
        #expect(try sidecarRows(in: folder).count == 2)
    }

    @Test func removalMovesTheFileToDotTrashAndUnlistsIt() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        var lines: [String] = []
        let lock = NSLock()
        PersonDocumentLog.shared.setExtraSink { line in lock.withLock { lines.append(line) } }
        defer { PersonDocumentLog.shared.setExtraSink(nil) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let png = try write(try imageData(type: .png), named: "bc.png", in: sb)
        let doc = try sb.store.importPersonDocument(from: png, kind: .birth, note: "", into: folder)
        let file = try #require(doc.fileURL)

        try sb.store.removeDocument(doc, for: mary)
        let trash = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsTrashFolderName, isDirectory: true)
        #expect(!fileManager.fileExists(atPath: file.path))
        #expect(fileManager.fileExists(atPath: trash.appendingPathComponent(doc.filename).path))
        #expect(sb.store.documents(for: mary).isEmpty)
        #expect(try sidecarRows(in: folder).isEmpty)
        #expect(lock.withLock { lines }.contains { $0.hasPrefix("[tree] removed Birth certificate for Mary C O'Connor (LZ7X-ABC) — \(doc.filename) moved to Documents/.trash/") })

        // Gone from the list → a second remove says so, and nothing in
        // .trash is touched.
        #expect(throws: FamilyAssetStore.DocumentError.notInArchive(doc.filename)) {
            try sb.store.removeDocument(doc, from: folder)
        }

        // Same clock → the next import reuses the freed name; removing IT
        // must not overwrite what is already in .trash.
        let again = try sb.store.importPersonDocument(from: png, kind: .birth, note: "", into: folder)
        #expect(again.filename == doc.filename)
        try sb.store.removeDocument(again, from: folder)
        let trashed = try fileManager.contentsOfDirectory(atPath: trash.path).sorted()
        #expect(trashed.count == 2)
        #expect(trashed.contains(doc.filename))
        #expect(trashed.contains { $0.contains("-trashed-") })
    }

    @Test func aDamagedSidecarListsNothingAndIsNeverRewrittenByARead() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        _ = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        let sidecar = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        try Data("{ not json".utf8).write(to: sidecar)
        #expect(sb.store.documents(for: mary).isEmpty)
        #expect(try Data(contentsOf: sidecar) == Data("{ not json".utf8))
        // And an import refuses to guess: the new file is parked in .trash
        // rather than listed against a list it cannot read.
        #expect(throws: FamilyAssetStore.DocumentError.sidecarUnreadable(FamilyAssetStore.documentsSidecarName)) {
            try sb.store.importPersonDocument(from: pdf, kind: .death, note: "", into: folder)
        }
        let trash = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsTrashFolderName)
        #expect((try? fileManager.contentsOfDirectory(atPath: trash.path))?.count == 1)
    }

    // MARK: Sensor — sidecar schema frozen

    @Test func sidecarSchemaIsFrozen() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        let doc = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "n", into: folder)

        let frozen: Set<String> = ["id", "kind", "filename", "originalFilename", "addedAt", "note", "sha256", "byteCount"]
        #expect(PersonDocument.sidecarKeys == frozen)
        let rows = try sidecarRows(in: folder)
        #expect(rows.count == 1)
        #expect(Set(rows[0].keys) == frozen)
        #expect(rows[0]["kind"] as? String == "BC")
        #expect(rows[0]["id"] as? String == doc.id.uuidString)
        #expect((rows[0]["addedAt"] as? String)?.contains("T") == true) // ISO-8601
        #expect(Set(PersonDocumentKind.allCases.map(\.rawValue)) == ["BC", "DC", "MC", "Other"])

        // Round trip through the app's decoder: identical row.
        let decoded = try FamilyAssetStore.sidecarDecoder.decode(
            [PersonDocument].self,
            from: Data(contentsOf: documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName)))
        var expected = doc
        expected.fileURL = nil
        #expect(decoded.count == 1)
        #expect(decoded[0].id == expected.id)
        #expect(decoded[0].sha256 == expected.sha256)
        #expect(abs(decoded[0].addedAt.timeIntervalSince(expected.addedAt)) < 1)
    }

    // MARK: Scale

    @Test func listingFiveHundredDocumentsStaysUnderBudget() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let dir = documentsDir(folder)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try pdfData()
        var rows: [PersonDocument] = []
        for i in 0..<500 {
            let name = "Other-20260920-\(String(format: "%06d", i)).pdf"
            try bytes.write(to: dir.appendingPathComponent(name))
            rows.append(PersonDocument(id: UUID(), kind: .other, filename: name, originalFilename: "\(i).pdf",
                                       addedAt: Date(timeIntervalSince1970: Double(i)), note: "",
                                       sha256: FamilyAssetStore.sha256Hex(bytes), byteCount: bytes.count))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: dir.appendingPathComponent(FamilyAssetStore.documentsSidecarName))

        let clock = ContinuousClock()
        var listed: [PersonDocument] = []
        let elapsed = clock.measure { listed = sb.store.documents(for: mary) }
        #expect(listed.count == 500)
        #expect(listed.first?.filename == "Other-20260920-000499.pdf") // newest first
        #expect(elapsed < .seconds(2), "500 rows took \(elapsed)")
    }

    // MARK: Isolation

    @Test func everySandboxIsOutsideTheRealArchive() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let real = FamilyAssetConfigurationCenter.shared.snapshot().roots.assets.path
        #expect(!sb.store.root.path.hasPrefix(real))
        #expect(!sb.store.peopleDirectory.path.contains("Library/Application Support/VideoScan"))
        #expect(sb.store.root.path.hasPrefix(sb.base.standardizedFileURL.resolvingSymlinksInPath().path)
                || sb.store.root.path.hasPrefix(sb.base.path))
    }
}


// MARK: - Model cache

/// The tree model reads a person's documents ONCE per selection (off the
/// main actor), serves the memo on re-select, and drops it on add/remove.
/// Isolation: the compiled-store Sandbox for the tree, a temp store for
/// the documents; the model is given that store explicitly (an injected
/// model never sees the real People/ folder).
@Suite("Family documents — tree model cache", .serialized)
struct FamilyDocumentModelTests {
    private typealias Sandbox = FamilyGraphCompiledStoreTests.Sandbox
    private static let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func hit() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func pdfData() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return try #require(document.dataRepresentation())
    }

    @Test @MainActor func documentsAreReadOncePerSelectionAndInvalidatedOnChange() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write("0 HEAD\n0 @I1@ INDI\n1 NAME Eileen /Latta/\n0 @I2@ INDI\n1 NAME Barry /Latta/\n0 TRLR\n")
        let store = FamilyAssetStore(
            root: box.root.appendingPathComponent("assets/40_Family_Tree", isDirectory: true),
            cacheRoot: box.root.appendingPathComponent("cache", isDirectory: true))
        let eileen = FamilyAssetPerson(gedcomID: "@I1@", name: "Eileen Latta")
        let folder = try store.folderForPhotoRequest(person: eileen)
        let source = box.root.appendingPathComponent("bc.pdf")
        try pdfData().write(to: source)
        _ = try store.importPersonDocument(from: source, kind: .birth, note: "", into: folder)

        let reads = Counter()
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals,
                                        documentStoreProvider: { reads.hit(); return store })
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        #expect(model.isLive)

        model.select("@I1@")
        await waitUntil("Eileen's document") { model.selectedDocuments.count == 1 }
        await waitUntil("Eileen's chip count") { model.documentCount(for: "@I1@") == 1 }
        #expect(model.selectedDocuments.first?.kind == .birth)
        let afterFirst = reads.count
        #expect(afterFirst >= 1)

        // Away and back: the memo answers, the store is not asked again.
        model.select("@I2@")
        await waitUntil("Barry's (empty) list") { model.selectedDocuments.isEmpty }
        let afterBarry = reads.count
        model.select("@I1@")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedDocuments.count == 1)
        #expect(reads.count == afterBarry, "re-selecting Eileen must be a cache hit")

        // A change for Eileen drops her memo and re-reads.
        _ = try store.importPersonDocument(from: source, kind: .death, note: "", into: folder)
        #expect(model.selectedDocuments.count == 1)
        let revision = model.documentsRevision
        model.noteDocumentsChanged(for: "@I1@")
        #expect(model.documentsRevision == revision &+ 1)
        await waitUntil("Eileen's second document") { model.selectedDocuments.count == 2 }
        #expect(model.documentCount(for: "@I1@") == 2)
        #expect(reads.count > afterBarry)
    }

    @Test @MainActor func anInjectedModelWithoutAStoreReadsNothing() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write("0 HEAD\n0 @I1@ INDI\n1 NAME Eileen /Latta/\n0 TRLR\n")
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals)
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        model.select("@I1@")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedDocuments.isEmpty)
        #expect(model.documentCount(for: "@I1@") == 0)
        #expect(model.documentStoreProvider() == nil)
    }
}
