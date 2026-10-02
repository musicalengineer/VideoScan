// FamilyDocumentStoreTests.swift
// Certificates and other papers on a Family Tree person (Rick, 2026-09-20:
// "right click add docs on a person … BC, DC, MC, Other then allow an
// upload of a png, jpg, or pdf. This should be stored as such in the
// database.").
//
// Five dimensions (docs/practices/testing_retrospective_2026_07_05.md):
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
        // QA 2026-10-01 P3-1: the app log names the person by KEY, never by
        // name (os_log keeps the name private as before).
        #expect(line.hasPrefix("[tree] added Birth certificate for LZ7X-ABC — \(doc.filename), "), "\(line)")
        #expect(!line.contains("Mary"), "\(line)")
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
        #expect(lock.withLock { lines }.contains { $0.hasPrefix("[tree] removed Birth certificate for LZ7X-ABC — \(doc.filename) moved to Documents/.trash/") })
        #expect(!lock.withLock { lines }.joined().contains("Mary"), "QA P3-1: no names in the app log")

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
        // rather than listed against a list it cannot read — and the error
        // says so (codex review #18 F4: it used to be a bare
        // sidecarUnreadable, indistinguishable from "nothing written").
        let failure = #expect(throws: FamilyAssetStore.DocumentImportFailure.self) {
            try sb.store.importPersonDocument(from: pdf, kind: .death, note: "", into: folder)
        }
        #expect((failure?.underlying as? FamilyAssetStore.DocumentError)
                == .sidecarUnreadable(FamilyAssetStore.documentsSidecarName))
        let trash = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsTrashFolderName)
        let trashed = (try? fileManager.contentsOfDirectory(atPath: trash.path)) ?? []
        #expect(trashed.count == 1)
        if case .movedToTrash(let url) = failure?.rollback {
            #expect(trashed == [url.lastPathComponent], "the failure names where the file went")
        } else {
            Issue.record("expected movedToTrash, got \(String(describing: failure?.rollback))")
        }
    }

    /// Reflection review F3 (2026-09-21): when the rollback's move to
    /// .trash itself fails, the orphan used to be left behind by a silent
    /// `try?`. Behaviour is unchanged (same error thrown, file left in
    /// place) — but the log now names the file and why.
    @Test func aFailedRollbackIsLoggedNotSilent() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let lock = NSLock()
        var lines: [String] = []
        PersonDocumentLog.shared.setExtraSink { line in lock.withLock { lines.append(line) } }
        defer { PersonDocumentLog.shared.setExtraSink(nil) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        _ = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        let docs = documentsDir(folder)
        try Data("{ not json".utf8).write(to: docs.appendingPathComponent(FamilyAssetStore.documentsSidecarName))
        // A FILE where .trash should be: the rollback's move refuses.
        try Data("x".utf8).write(to: docs.appendingPathComponent(FamilyAssetStore.documentsTrashFolderName))
        let before = Set(try fileManager.contentsOfDirectory(atPath: docs.path))
        let failure = #expect(throws: FamilyAssetStore.DocumentImportFailure.self) {
            try sb.store.importPersonDocument(from: pdf, kind: .death, note: "", into: folder)
        }
        #expect((failure?.underlying as? FamilyAssetStore.DocumentError)
                == .sidecarUnreadable(FamilyAssetStore.documentsSidecarName))
        let orphans = Set(try fileManager.contentsOfDirectory(atPath: docs.path)).subtracting(before)
        #expect(orphans.count == 1, "behaviour unchanged: the orphan stays where it was written")
        if case .leftInDocuments = failure?.rollback {
            #expect(orphans == [failure?.filename ?? ""], "the failure names the file left behind")
        } else {
            Issue.record("expected leftInDocuments, got \(String(describing: failure?.rollback))")
        }
        let logged = lock.withLock { lines }.filter { $0.contains("could not be moved to .trash") }
        #expect(logged.count == 1)
        if let orphan = orphans.first { #expect(logged.first?.contains(orphan) == true) }
    }

    /// Codex review #18 F5: the missing-file and unreadable-list diagnostics
    /// named the person's FOLDER, and a folder name is a person's name. They
    /// carry the person key now, and a damaged list is reported once, not on
    /// every listing (each selection change lists).
    @Test func diagnosticLogsNeverNameThePersonFolderAndAreNotRepeated() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        var lines: [String] = []
        let lock = NSLock()
        PersonDocumentLog.shared.setExtraSink { line in lock.withLock { lines.append(line) } }
        defer { PersonDocumentLog.shared.setExtraSink(nil) }
        PersonDocumentLog.shared.resetMissing()
        let synthetic = FamilyAssetPerson(gedcomID: "@I77@", name: "Synthetic Test Person")
        let folder = try sb.store.folderForPhotoRequest(person: synthetic)
        try #require(folder.lastPathComponent.contains("Synthetic_Test_Person"))

        let pdf = try write(try pdfData(), named: "bc.pdf", in: sb)
        let doc = try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder, for: synthetic)
        try fileManager.removeItem(at: #require(doc.fileURL))
        _ = sb.store.documents(for: synthetic)                 // missing file
        _ = sb.store.documents(inPersonFolder: folder)        // the folder-only entry point too

        let sidecar = documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        try Data("{ not json".utf8).write(to: sidecar)
        for _ in 0..<3 { _ = sb.store.documents(for: synthetic) }
        _ = sb.store.documents(inPersonFolder: folder)

        let captured = lock.withLock { lines }
        #expect(captured.contains { $0.contains("missing on disk") && $0.contains(doc.filename) })
        let unreadable = captured.filter { $0.contains("could not read") }
        #expect(unreadable.count == 1, "a damaged list is reported once: \(unreadable)")
        for line in captured {
            #expect(!line.contains("Synthetic_Test_Person") && !line.contains("Synthetic Test Person"),
                    "a diagnostic named the person: \(line)")
        }
        #expect(captured.contains { $0.contains("missing on disk") && $0.contains("@I77@") },
                "the missing-file line carries the person key")
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
        // MIL, CEN and DNA added 2026-10-01 (additive); the four original
        // codes never change.
        #expect(Set(PersonDocumentKind.allCases.map(\.rawValue)) == ["BC", "DC", "MC", "MIL", "CEN", "DNA", "Other"])
        #expect(PersonDocumentKind.allCases == [.birth, .death, .marriage, .military, .census, .dna, .other],
                "declaration order is the inspector's group order")
        // DNA screenshots name living matches: the one private-by-default kind.
        #expect(PersonDocumentKind.allCases.filter(\.isPrivate) == [.dna])

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

    // MARK: Compatibility — the kind codes (2026-10-01)

    /// A sidecar exactly as the 2026-09-20 build wrote it (only BC/DC/MC/
    /// Other, no extra keys) still lists every row.
    @Test func aSidecarWrittenBeforeMilitaryAndCensusStillLoads() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let dir = documentsDir(folder)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try pdfData()
        let sha = FamilyAssetStore.sha256Hex(bytes)
        var json: [String] = []
        for (i, code) in ["BC", "DC", "MC", "Other"].enumerated() {
            let name = "\(code)-20260920-10150\(i).pdf"
            try bytes.write(to: dir.appendingPathComponent(name))
            json.append("""
            {"addedAt":"2026-09-20T10:15:0\(i)Z","byteCount":\(bytes.count),"filename":"\(name)",\
            "id":"\(UUID().uuidString)","kind":"\(code)","note":"","originalFilename":"\(i).pdf","sha256":"\(sha)"}
            """)
        }
        try Data("[\(json.joined(separator: ","))]".utf8)
            .write(to: dir.appendingPathComponent(FamilyAssetStore.documentsSidecarName))

        let listed = sb.store.documents(for: mary)
        #expect(listed.count == 4)
        #expect(Set(listed.map(\.kind)) == [.birth, .death, .marriage, .other])
        #expect(listed.allSatisfy { $0.unrecognizedKindCode == nil })
    }

    /// A code this build does not know (written by a newer one) reads as
    /// Other — the rest of the list is NOT lost — and survives a rewrite of
    /// the list (an import beside it) unchanged.
    @Test func anUnknownKindCodeReadsAsOtherAndIsWrittenBackUnchanged() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let dir = documentsDir(folder)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try pdfData()
        let name = "WILL-20300101-000000.pdf"
        try bytes.write(to: dir.appendingPathComponent(name))
        let futureID = UUID()
        let row = """
        [{"addedAt":"2030-01-01T00:00:00Z","byteCount":\(bytes.count),"filename":"\(name)",\
        "id":"\(futureID.uuidString)","kind":"WILL","note":"from a newer build","originalFilename":"w.pdf",\
        "sha256":"\(FamilyAssetStore.sha256Hex(bytes))"}]
        """
        try Data(row.utf8).write(to: dir.appendingPathComponent(FamilyAssetStore.documentsSidecarName))

        let listed = sb.store.documents(for: mary)
        let future = try #require(listed.first { $0.id == futureID })
        #expect(future.kind == .other)
        #expect(future.unrecognizedKindCode == "WILL")

        // Rewrite the list: import a military record beside it.
        let pdf = try write(bytes, named: "mil.pdf", in: sb)
        let added = try sb.store.importPersonDocument(from: pdf, kind: .military, note: "", into: folder)
        #expect(added.filename.hasPrefix("MIL-"))
        let rows = try sidecarRows(in: folder)
        #expect(rows.count == 2)
        #expect(rows.first { $0["id"] as? String == futureID.uuidString }?["kind"] as? String == "WILL",
                "the newer build's code was written back unchanged")
        // On disk the military row says "Other" (older builds read it) and
        // carries its real kind in the optional `category` key.
        let milRow = rows.first { $0["id"] as? String == added.id.uuidString }
        #expect(milRow?["kind"] as? String == "Other")
        #expect(milRow?["category"] as? String == "MIL")
        #expect(Set(rows.flatMap { $0.keys })
                    .isSubset(of: PersonDocument.sidecarKeys.union(PersonDocument.optionalSidecarKeys)),
                "no keys beyond the frozen set and `category`")
    }

    // MARK: Compatibility — older builds read what this build writes

    /// FROZEN LEGACY READER: `PersonDocumentKind` and `PersonDocument`
    /// copied VERBATIM (names prefixed `Legacy`, doc comments trimmed) from
    /// main at 41cba21b (FamilyAssetStore+Documents.swift), the last build
    /// before MIL/CEN/DNA. Synthesized Codable, decoded the way that build's
    /// `FamilyAssetStore.sidecarDecoder` did (plain JSONDecoder, ISO-8601
    /// dates). Never edit this to make a test pass: it IS the old build.
    private enum LegacyPersonDocumentKind: String, Codable, CaseIterable, Sendable {
        case birth = "BC"
        case death = "DC"
        case marriage = "MC"
        case other = "Other"
    }

    private struct LegacyPersonDocument: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: LegacyPersonDocumentKind
        let filename: String
        let originalFilename: String
        let addedAt: Date
        var note: String
        let sha256: String
        let byteCount: Int
        var fileURL: URL? = nil

        enum CodingKeys: String, CodingKey {
            case id, kind, filename, originalFilename, addedAt, note, sha256, byteCount
        }
    }

    private static let legacySidecarDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// File one document of every kind with THIS build, then read the list
    /// with the frozen pre-2026-10-01 reader.
    private func newFormatSidecar(_ sb: Sandbox) throws -> (folder: URL, data: Data, ids: [PersonDocumentKind: UUID]) {
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        var ids: [PersonDocumentKind: UUID] = [:]
        for kind in PersonDocumentKind.allCases {
            let pdf = try write(try pdfData(), named: "\(kind.rawValue).pdf", in: sb)
            ids[kind] = try sb.store.importPersonDocument(from: pdf, kind: kind, note: "", into: folder).id
        }
        let data = try Data(contentsOf: documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName))
        return (folder, data, ids)
    }

    @Test func theFrozenLegacyReaderLoadsEveryRowOfANewFormatList() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let (_, data, ids) = try newFormatSidecar(sb)

        // The old build's whole-list decode must not throw: a throw is what
        // it reports as "damaged" (hides the list, refuses filing).
        let legacy = try Self.legacySidecarDecoder.decode([LegacyPersonDocument].self, from: data)
        #expect(legacy.count == PersonDocumentKind.allCases.count)
        func legacyKind(_ kind: PersonDocumentKind) -> LegacyPersonDocumentKind? {
            legacy.first { $0.id == ids[kind] }?.kind
        }
        #expect(legacyKind(.birth) == .birth)
        #expect(legacyKind(.death) == .death)
        #expect(legacyKind(.marriage) == .marriage)
        for kind in [PersonDocumentKind.military, .census, .dna, .other] {
            #expect(legacyKind(kind) == .other, "\(kind.rawValue) must read as Other in an older build")
        }
        // Every `kind` on disk is one the old enum knows.
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(raw.allSatisfy { PersonDocumentKind.legacyCodes.contains($0["kind"] as? String ?? "") })
    }

    @Test func thisBuildRecoversTheRealKindsFromTheSameList() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let (_, _, ids) = try newFormatSidecar(sb)
        let listed = sb.store.documents(for: mary)
        #expect(listed.count == PersonDocumentKind.allCases.count)
        for kind in PersonDocumentKind.allCases {
            #expect(listed.first { $0.id == ids[kind] }?.kind == kind)
        }
        #expect(sb.store.documentSidecarIsReadable(inPersonFolder: try sb.store.folderForPhotoRequest(person: mary)))
    }

    /// An older build that rewrites the list (an import or removal there)
    /// drops `category`. The generated file name still says DNA-/MIL-/CEN-,
    /// so this build recovers the kind — a DNA row stays private.
    @Test func aListRewrittenByAnOlderBuildKeepsItsKindsByFileName() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let (folder, data, ids) = try newFormatSidecar(sb)
        let legacy = try Self.legacySidecarDecoder.decode([LegacyPersonDocument].self, from: data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rewritten = try encoder.encode(legacy)
        let rawRewritten = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [[String: Any]])
        #expect(rawRewritten.allSatisfy { $0["category"] == nil }, "the old build drops category")
        try rewritten.write(to: documentsDir(folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName))

        let listed = sb.store.documents(for: mary)
        for kind in PersonDocumentKind.allCases {
            #expect(listed.first { $0.id == ids[kind] }?.kind == kind, "\(kind.rawValue) lost after an old rewrite")
        }
        #expect(listed.first { $0.id == ids[.dna] }?.kind.isPrivate == true)
        #expect(PersonDocumentKind.newKind(fromFilename: "Other-20260920-101500.pdf") == nil)
        #expect(PersonDocumentKind.newKind(fromFilename: "BC-20260920-101500.pdf") == nil)
        #expect(PersonDocumentKind.newKind(fromFilename: "Mary_DNA.png") == nil)
    }

    /// A `category` a NEWER build invents reads as the row's `kind` and is
    /// written back unchanged.
    @Test func anUnknownCategoryIsKeptAndWrittenBack() throws {
        let sb = try sandbox(clock: fixedClock)
        defer { try? fileManager.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: mary)
        let dir = documentsDir(folder)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try pdfData()
        let name = "Other-20300101-000000.pdf"
        try bytes.write(to: dir.appendingPathComponent(name))
        let futureID = UUID()
        let row = """
        [{"addedAt":"2030-01-01T00:00:00Z","byteCount":\(bytes.count),"category":"WILL","filename":"\(name)",\
        "id":"\(futureID.uuidString)","kind":"Other","note":"","originalFilename":"w.pdf",\
        "sha256":"\(FamilyAssetStore.sha256Hex(bytes))"}]
        """
        try Data(row.utf8).write(to: dir.appendingPathComponent(FamilyAssetStore.documentsSidecarName))
        let future = try #require(sb.store.documents(for: mary).first { $0.id == futureID })
        #expect(future.kind == .other)
        #expect(future.unrecognizedCategory == "WILL")

        let pdf = try write(bytes, named: "bc.pdf", in: sb)
        try sb.store.importPersonDocument(from: pdf, kind: .birth, note: "", into: folder)
        let rows = try sidecarRows(in: folder)
        let back = rows.first { $0["id"] as? String == futureID.uuidString }
        #expect(back?["kind"] as? String == "Other")
        #expect(back?["category"] as? String == "WILL")
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

