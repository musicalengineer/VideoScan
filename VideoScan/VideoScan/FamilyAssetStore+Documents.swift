// FamilyAssetStore+Documents.swift
// Certificates and other papers filed against a Family Tree person
// (Rick, 2026-09-20: "For some people I can find the birth certificate or
// other certificates such as Death. Can we have a right click add docs on
// a person in the family tree … BC, DC, MC, Other then allow an upload of
// a png, jpg, or pdf. This should be stored as such in the database." He
// had just found Mary C O'Connor's birth certificate from Ireland.)
//
// WHERE THEY LAND. Beside the person's photos, one level down:
//
//     People/<Given_Surname[_bYYYY][_FSID]>/Documents/<KIND>-<yyyyMMdd-HHmmss>[-n].<ext>
//     People/<…>/Documents/documents.json          ← the sidecar (the "database")
//     People/<…>/Documents/.trash/<file>            ← removed files, never rm'd
//
// KIND is the short code Rick used (BC / DC / MC / Other). The sidecar is
// an array of `PersonDocument`, written atomically through
// `AtomicFilePublish` like every other sidecar in the app. The person's
// folder is the same one photos go to — the FamilySearch-ID folder when
// the record has an ID — so documents are keyed to the tree the same way
// photos are and survive a GEDCOM re-pull that renumbers @I pointers.
// Nothing here writes to the GEDCOM.
//
// HARDENING mirrors `importPersonPhoto` exactly: write access required;
// the folder must be a live `People/` child (no symlinks); the extension
// is allow-listed; the size is checked BEFORE the bytes are read; the
// bytes are validated in memory BEFORE anything touches disk (images via
// FamilyAssetImageValidator, PDFs via PDFKit + the `%PDF-` header); the
// write is descriptor-anchored and never overwrites (a same-second import
// gets `-2`); the file on disk is re-read and its size + SHA-256 compared
// with what was validated; removal moves to `.trash`, never deletes.
//
// MEMORY. Worst case per import: one `Data` of ≤ `maxImportBytes` (48 MB)
// held while PDFKit/ImageIO parse it (PDFKit may map about as much again),
// then a second ≤ 48 MB read for the post-write verification — the first
// is released before the second is taken. Nothing is cached. Listing a
// person reads one small JSON (capped at 8 MB) per folder and stats each
// named file; the bytes of the documents themselves are never read.

import Foundation
import CryptoKit
import PDFKit
import os
import VideoScanCore

private let documentLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "tree")

/// What a paper IS. The raw values are the codes Rick asked for and the
/// filename prefix on disk; they are also the sidecar's `kind` value, so
/// they must never be renamed (a rename would orphan every existing entry).
enum PersonDocumentKind: String, Codable, CaseIterable, Sendable {
    case birth = "BC"
    case death = "DC"
    case marriage = "MC"
    case other = "Other"

    /// "Birth certificate" — the log line and the detail panel.
    var displayName: String {
        switch self {
        case .birth: return "Birth certificate"
        case .death: return "Death certificate"
        case .marriage: return "Marriage certificate"
        case .other: return "Other document"
        }
    }

    /// "Birth" — the segmented picker in the Add sheet.
    var shortLabel: String {
        switch self {
        case .birth: return "Birth"
        case .death: return "Death"
        case .marriage: return "Marriage"
        case .other: return "Other"
        }
    }
}

/// One row of `documents.json`. The persisted key set is FROZEN by
/// `FamilyDocumentStoreTests` (the schema sensor): add a key only with a
/// default so older sidecars still decode, and never rename one.
///
/// `fileURL` is resolved at read time and is deliberately NOT in
/// `CodingKeys` — the sidecar records the filename relative to its own
/// folder so the whole People/ tree can move between volumes.
struct PersonDocument: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: PersonDocumentKind
    /// Name on disk inside `Documents/` (`BC-20260920-101500.pdf`).
    let filename: String
    /// What the file was called when Rick chose it (`Mary_OConnor_BC.pdf`).
    let originalFilename: String
    let addedAt: Date
    var note: String
    /// Hex SHA-256 of the bytes as validated and written.
    let sha256: String
    let byteCount: Int
    /// Where the file is right now; nil on a freshly decoded row.
    var fileURL: URL? = nil

    // Swift's `CodingKeys` ≈ the explicit field list a C++ serializer
    // would carry: a property missing from it (fileURL) is skipped by the
    // synthesized encode/decode and must have a default.
    enum CodingKeys: String, CodingKey {
        case id, kind, filename, originalFilename, addedAt, note, sha256, byteCount
    }

    /// The persisted keys, for the schema sensor.
    static let sidecarKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

extension PersonDocument.CodingKeys: CaseIterable {}

/// One inspector row: a document PLUS who it was read for. The owner
/// travels with the row so an action taken on it (Remove) goes to the
/// person and folder the row came from, whatever is selected by the time
/// the confirmation lands (codex review 1593 #9, 2026-09-20: A's
/// certificate could be removed from B's inspector and logged as B's).
struct PersonDocumentRow: Identifiable, Equatable, Sendable {
    let document: PersonDocument
    /// The tree person id the row was read for.
    let ownerID: String
    let owner: FamilyAssetPerson

    var id: UUID { document.id }

    /// The People/ folder whose `Documents/documents.json` lists this row
    /// (the file is `<folder>/Documents/<filename>`). Nil only for a row
    /// without a resolved file, which no listing produces.
    var personFolder: URL? {
        document.fileURL?.deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// One line per action to the app log (Rick reads it) and the model log
/// (os_log, name kept private). `missing(_:)` reports each vanished file
/// ONCE per process — a listing runs on every selection change, and the
/// same absent file must not fill the log.
///
/// `@unchecked Sendable` + NSLock ≈ a class with a mutex around its
/// members; Swift cannot prove the lock discipline so we vouch for it.
final class PersonDocumentLog: @unchecked Sendable {
    static let shared = PersonDocumentLog()

    private let lock = NSLock()
    private var reportedMissing: Set<String> = []
    private var extraSink: ((String) -> Void)?

    /// Test seam: every line also goes here. Set to nil to detach.
    func setExtraSink(_ sink: ((String) -> Void)?) {
        lock.withLock { extraSink = sink }
    }

    /// Forget which files were already reported (tests).
    func resetMissing() {
        lock.withLock { reportedMissing.removeAll() }
    }

    func write(_ line: String, privateName: String? = nil) {
        if let privateName {
            documentLog.notice("\(line.replacingOccurrences(of: privateName, with: "<name>"), privacy: .public) [\(privateName, privacy: .private)]")
        } else {
            documentLog.notice("\(line, privacy: .public)")
        }
        appLog.write(line)
        let sink = lock.withLock { extraSink }
        sink?(line)
    }

    /// Log the first time only. Returns true when the line was written.
    @discardableResult
    func missing(_ url: URL, folder: String) -> Bool {
        let fresh = lock.withLock { reportedMissing.insert(url.path).inserted }
        guard fresh else { return false }
        write("[tree] document \(url.lastPathComponent) listed in \(folder)/Documents/documents.json is missing on disk — dropped from the listing")
        return true
    }
}

extension FamilyAssetStore {

    // MARK: Constants

    /// png / jpg / jpeg / pdf — what Rick asked for, and every one of them
    /// has a byte-level check below. Narrower on purpose than
    /// `allowedDocumentExtensions` (the folder-discovery list, which
    /// admits txt/rtf/doc that cannot be verified by content).
    static let allowedPersonDocumentExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf"]
    static let documentsFolderName = "Documents"
    static let documentsSidecarName = "documents.json"
    static let documentsTrashFolderName = ".trash"
    /// A sidecar bigger than this is not ours (500 entries ≈ 150 KB).
    static let maxDocumentSidecarBytes = 8 << 20

    /// Everything that can go wrong that `StoreError` does not already say.
    /// Messages are the plain words the Add sheet shows.
    enum DocumentError: LocalizedError, Equatable {
        case unsupportedType(String)
        case notTheClaimedType(String)
        case tooLarge(bytes: Int)
        case sourceUnreadable(String)
        case notInArchive(String)
        case sidecarUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext):
                let shown = ext.isEmpty ? "that file" : ".\(ext)"
                return "Choose a PNG, JPG or PDF file — \(shown) isn’t one of those."
            case .notTheClaimedType(let ext):
                return "That file isn’t a valid \(ext.uppercased()) — its contents don’t read as one."
            case .tooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "That document is %.0f MB; the archive accepts documents up to %d MB.",
                              mb, FamilyAssetStore.maxImportBytes / 1_048_576)
            case .sourceUnreadable(let name):
                return "Couldn’t read \(name). Choose a regular file, not an alias or folder."
            case .notInArchive(let name):
                return "\(name) is no longer listed for this person."
            case .sidecarUnreadable(let name):
                return "The document list \(name) is damaged; nothing was changed."
            }
        }
    }

    // MARK: Paths

    /// `<person folder>/Documents`.
    static func documentsFolder(in personFolder: URL) -> URL {
        personFolder.appendingPathComponent(documentsFolderName, isDirectory: true)
    }

    // MARK: Import

    /// File a document for a person. `folder` is the person's own People/
    /// folder (`folderForPhotoRequest(person:)` on the write side). `person`
    /// is only for the log line.
    ///
    /// Returns the sidecar row with `fileURL` filled in.
    @discardableResult
    func importPersonDocument(from source: URL,
                              kind: PersonDocumentKind,
                              note: String,
                              into folder: URL,
                              for person: FamilyAssetPerson? = nil) throws -> PersonDocument {
        try requireWriteAccess()
        guard let target = revalidatedPhotoRequestFolder(folder) else {
            throw StoreError.unsafeDirectory(folder)
        }
        let src = URL(fileURLWithPath: source.path, isDirectory: false)
        let ext = src.pathExtension.lowercased()
        guard Self.allowedPersonDocumentExtensions.contains(ext) else {
            throw DocumentError.unsupportedType(ext)
        }
        // A regular file, not a link or a folder — and its SIZE before a
        // single byte is read, so an oversize pick never becomes 48 MB+
        // of Data in this process.
        guard let values = try? src.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DocumentError.sourceUnreadable(src.lastPathComponent)
        }
        if let size = values.fileSize, size > Self.maxImportBytes {
            throw DocumentError.tooLarge(bytes: size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: src)
        } catch {
            throw DocumentError.sourceUnreadable(src.lastPathComponent)
        }
        guard data.count <= Self.maxImportBytes else {
            throw DocumentError.tooLarge(bytes: data.count)
        }
        // Validate the BYTES, in memory, before anything touches disk —
        // and against the CLAIMED type: a .pdf that is really text, or a
        // .png that is really a JPEG, is refused here.
        guard Self.isVerifiedDocumentData(data, fileExtension: ext) else {
            throw DocumentError.notTheClaimedType(ext)
        }
        let digest = Self.sha256Hex(data)

        let documentsDir = Self.documentsFolder(in: target)
        try ensureSafeDirectory(documentsDir)
        let when = importClock()
        let stem = kind.rawValue + "-" + Self.stamp(when)
        // Same descriptor-anchored, O_EXCL, never-overwrite writer as
        // photos; only EEXIST advances to `-2`.
        let written = try writePersonPhotoData(data, stem: stem, ext: ext, into: documentsDir)

        // Re-verify what landed: same length, same hash, regular file.
        guard let back = Self.regularFileData(at: written),
              back.count == data.count,
              Self.sha256Hex(back) == digest else {
            do {
                try Self.moveToTrash(written, in: documentsDir, fileManager: fileManager, at: when)
            } catch {
                // Behaviour unchanged (the import still fails with EIO); the
                // orphan is now named in the log instead of silently left.
                PersonDocumentLog.shared.write(
                    "[tree] document \(written.lastPathComponent) failed its read-back check and could not be moved "
                    + "to .trash (\(error.localizedDescription)); it is left in \(documentsDir.lastPathComponent)/ unlisted")
            }
            throw StoreError.createFailed(written.lastPathComponent, errno: EIO)
        }

        var document = PersonDocument(
            id: UUID(),
            kind: kind,
            filename: written.lastPathComponent,
            originalFilename: src.lastPathComponent,
            addedAt: when,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            sha256: digest,
            byteCount: data.count)
        do {
            try Self.sidecarLock.withLock {
                var entries = try readDocumentSidecar(in: documentsDir)
                entries.append(document)
                try writeDocumentSidecar(entries, in: documentsDir)
            }
        } catch {
            // The file is on disk but unlisted: park it in .trash so the
            // archive never holds an orphan, then say why.
            do {
                try Self.moveToTrash(written, in: documentsDir, fileManager: fileManager, at: when)
            } catch let trashError {
                // Behaviour unchanged (the sidecar error is still thrown);
                // the orphan is now named in the log instead of silently left.
                PersonDocumentLog.shared.write(
                    "[tree] document \(written.lastPathComponent) could not be listed (\(error.localizedDescription)) "
                    + "and could not be moved to .trash (\(trashError.localizedDescription)); it is left in "
                    + "\(documentsDir.lastPathComponent)/ unlisted")
            }
            throw error
        }
        document.fileURL = written
        PersonDocumentLog.shared.write(
            "[tree] added \(kind.displayName) for \(Self.logSubject(person, folder: target)) — "
            + "\(document.filename), \(Self.displayBytes(data.count))",
            privateName: person?.name)
        return document
    }

    // MARK: Listing

    /// Every document filed for this person, newest first, across the same
    /// folders `photoURLs` reads (FamilySearch-ID folder, then name/alias
    /// folders). A row whose file is gone is dropped and logged once.
    func documents(for person: FamilyAssetPerson) -> [PersonDocument] {
        guard access != .unavailable else { return [] }
        var out: [PersonDocument] = []
        var seen: Set<UUID> = []
        for folder in personFolders(for: person) {
            for document in documents(inPersonFolder: folder) where seen.insert(document.id).inserted {
                out.append(document)
            }
        }
        return out.sorted {
            $0.addedAt == $1.addedAt ? $0.filename < $1.filename : $0.addedAt > $1.addedAt
        }
    }

    /// The documents listed in ONE person folder's sidecar, each with its
    /// `fileURL` resolved and re-checked (regular file, not a link,
    /// directly inside `Documents/`).
    func documents(inPersonFolder folder: URL) -> [PersonDocument] {
        guard access != .unavailable else { return [] }
        let fresh = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        guard fresh.deletingLastPathComponent() == peopleDirectory, isSafeDirectory(fresh) else { return [] }
        let documentsDir = Self.documentsFolder(in: fresh)
        guard isSafeDirectory(documentsDir) else { return [] }
        let entries: [PersonDocument]
        do {
            entries = try readDocumentSidecar(in: documentsDir)
        } catch {
            PersonDocumentLog.shared.write(
                "[tree] could not read \(fresh.lastPathComponent)/Documents/\(Self.documentsSidecarName) — "
                + "\(error.localizedDescription); showing no documents for that folder")
            return []
        }
        return entries.compactMap { entry in
            guard Self.isPlainFilename(entry.filename) else {
                PersonDocumentLog.shared.missing(
                    documentsDir.appendingPathComponent(entry.filename), folder: fresh.lastPathComponent)
                return nil
            }
            let url = documentsDir.appendingPathComponent(entry.filename, isDirectory: false).standardizedFileURL
            guard url.deletingLastPathComponent() == documentsDir,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                PersonDocumentLog.shared.missing(url, folder: fresh.lastPathComponent)
                return nil
            }
            var resolved = entry
            resolved.fileURL = url
            return resolved
        }
    }

    // MARK: Removal

    /// Take a document off the person's list and move its file to
    /// `Documents/.trash/` (never deleted — Rick can put it back in Finder).
    func removeDocument(_ document: PersonDocument,
                        from folder: URL,
                        for person: FamilyAssetPerson? = nil) throws {
        try requireWriteAccess()
        guard let target = revalidatedPhotoRequestFolder(folder) else {
            throw StoreError.unsafeDirectory(folder)
        }
        let documentsDir = Self.documentsFolder(in: target)
        guard isSafeDirectory(documentsDir) else {
            throw StoreError.unsafeDirectory(documentsDir)
        }
        let when = importClock()
        try Self.sidecarLock.withLock {
            var entries = try readDocumentSidecar(in: documentsDir)
            guard let index = entries.firstIndex(where: { $0.id == document.id }) else {
                throw DocumentError.notInArchive(document.filename)
            }
            let entry = entries[index]
            guard Self.isPlainFilename(entry.filename) else {
                throw DocumentError.notInArchive(entry.filename)
            }
            let file = documentsDir.appendingPathComponent(entry.filename, isDirectory: false).standardizedFileURL
            guard file.deletingLastPathComponent() == documentsDir else {
                throw DocumentError.notInArchive(entry.filename)
            }
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true {
                try Self.moveToTrash(file, in: documentsDir, fileManager: fileManager, at: when)
            }
            // A file already gone is still an entry to drop.
            entries.remove(at: index)
            try writeDocumentSidecar(entries, in: documentsDir)
        }
        PersonDocumentLog.shared.write(
            "[tree] removed \(document.kind.displayName) for \(Self.logSubject(person, folder: target)) — "
            + "\(document.filename) moved to Documents/\(Self.documentsTrashFolderName)/",
            privateName: person?.name)
    }

    /// Same, deriving the person folder from the row's resolved `fileURL`.
    func removeDocument(_ document: PersonDocument, for person: FamilyAssetPerson? = nil) throws {
        guard let url = document.fileURL else {
            throw DocumentError.notInArchive(document.filename)
        }
        let folder = url.deletingLastPathComponent().deletingLastPathComponent()
        try removeDocument(document, from: folder, for: person)
    }

    // MARK: Validation

    /// The bytes are whole and are what the extension claims. PNG/JPEG go
    /// through the image validator (container trailer + forced decode) AND
    /// a magic check so a .png holding JPEG bytes is refused; PDF needs the
    /// `%PDF-` header and a PDFKit parse with at least one page.
    static func isVerifiedDocumentData(_ data: Data, fileExtension: String) -> Bool {
        switch fileExtension.lowercased() {
        case "png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                && FamilyAssetImageValidator.isVerifiedImageData(data)
        case "jpg", "jpeg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
                && FamilyAssetImageValidator.isVerifiedImageData(data)
        case "pdf":
            return isVerifiedPDFData(data)
        default:
            return false
        }
    }

    static func isVerifiedPDFData(_ data: Data) -> Bool {
        guard data.count >= 8, data.starts(with: Array("%PDF-".utf8)) else { return false }
        // `autoreleasepool` ≈ scope-exit release for the ObjC objects PDFKit
        // allocates while parsing; without it a 48 MB parse lingers until
        // the caller's pool drains.
        return autoreleasepool {
            guard let document = PDFDocument(data: data) else { return false }
            return document.pageCount >= 1
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sidecar

    /// One process-wide lock around every read-modify-write of a
    /// `documents.json`: two imports for one person at once must not lose
    /// each other's row. AtomicFilePublish already keeps the FILE whole;
    /// this keeps the LIST whole.
    private static let sidecarLock = NSLock()

    private func readDocumentSidecar(in documentsDir: URL) throws -> [PersonDocument] {
        let sidecar = URL(fileURLWithPath: documentsDir
            .appendingPathComponent(Self.documentsSidecarName).path, isDirectory: false)
        guard fileManager.fileExists(atPath: sidecar.path) else { return [] }
        guard let values = try? sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maxDocumentSidecarBytes else {
            throw DocumentError.sidecarUnreadable(Self.documentsSidecarName)
        }
        do {
            let data = try Data(contentsOf: sidecar)
            return try Self.sidecarDecoder.decode([PersonDocument].self, from: data)
        } catch {
            throw DocumentError.sidecarUnreadable(Self.documentsSidecarName)
        }
    }

    private func writeDocumentSidecar(_ entries: [PersonDocument], in documentsDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sidecar = documentsDir.appendingPathComponent(Self.documentsSidecarName, isDirectory: false)
        do {
            // fullFsync: a certificate list is exactly the sidecar "you
            // would hate to lose"; createIntermediates false so a folder
            // that vanished under us is an error, not silently recreated.
            try AtomicFilePublish.write(try encoder.encode(entries), to: sidecar,
                                        durability: .fullFsync, createIntermediates: false)
        } catch {
            throw StoreError.createFailed(Self.documentsSidecarName, errno: errno)
        }
    }

    // MARK: Helpers

    /// `Documents/.trash/<name>` — a same-named file already there gets a
    /// stamp suffix; nothing is ever replaced. `rename(2)` underneath
    /// (`moveItem`), not `replaceItemAt` (see AtomicFilePublish).
    private static func moveToTrash(_ file: URL, in documentsDir: URL,
                                    fileManager: FileManager, at when: Date) throws {
        let trash = documentsDir.appendingPathComponent(documentsTrashFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: trash.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  let values = try? trash.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                throw StoreError.unsafeDirectory(trash)
            }
        } else {
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: false)
        }
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var destination = trash.appendingPathComponent(file.lastPathComponent, isDirectory: false)
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            suffix += 1
            let name = "\(stem)-trashed-\(stamp(when))-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            destination = trash.appendingPathComponent(name, isDirectory: false)
            guard suffix < 100 else { throw StoreError.createFailed(name, errno: EEXIST) }
        }
        try fileManager.moveItem(at: file, to: destination)
    }

    private static func regularFileData(at url: URL) -> Data? {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        guard let values = try? fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return try? Data(contentsOf: fresh)
    }

    /// A single path component with no separators or traversal.
    static func isPlainFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func displayBytes(_ count: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(count))
    }

    /// "Mary C O'Connor (LZ7X-ABC)" / the folder name when no person is known.
    private static func logSubject(_ person: FamilyAssetPerson?, folder: URL) -> String {
        guard let person else { return folder.lastPathComponent }
        let key = person.familySearchID ?? person.gedcomID
        return key.map { "\(person.name) (\($0))" } ?? person.name
    }
}
