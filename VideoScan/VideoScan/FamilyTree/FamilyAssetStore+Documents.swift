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
// KIND is the short code Rick used (BC / DC / MC / Other; MIL, CEN and DNA
// for military, census and DNA records since 2026-10-01 — DNA is private by
// default, see `PersonDocumentKind.isPrivate`). The sidecar is
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
///
/// Declaration order is the inspector's group order (Birth, Death,
/// Marriage, Military, Census, DNA, Other). MIL, CEN and DNA were added
/// 2026-10-01 and are FORWARD-COMPATIBLE on disk: the sidecar's `kind`
/// only ever holds a code the pre-2026-10-01 decoder knows (BC/DC/MC/
/// Other), and the new kinds travel in an extra optional `category` key
/// that older builds ignore (see `PersonDocument`'s Codable). The FILE NAME
/// still carries the real code (`DNA-20261001-101500.png`) — a second,
/// independent record of the kind that survives an older build rewriting
/// the list without `category`.
enum PersonDocumentKind: String, Codable, CaseIterable, Sendable {
    case birth = "BC"
    case death = "DC"
    case marriage = "MC"
    case military = "MIL"
    case census = "CEN"
    /// DNA results — usually Ancestry screenshots, which name LIVING
    /// matches. PRIVATE by default (`isPrivate`).
    case dna = "DNA"
    case other = "Other"

    /// True for a kind whose contents are private by default (Rick,
    /// 2026-10-01: DNA screenshots list living matches by name). A private
    /// document:
    ///   • is never listed by "Show me some memories…" (FamilyTreeMemories);
    ///   • is never sent to Hallie / the CyberBrain automatically — any
    ///     future automatic reader of person documents must skip it;
    ///   • carries a lock badge in the inspector's Documents panel;
    ///   • is NEVER publishable — GH #244 (future public web access) must
    ///     exclude it whatever else is shared.
    var isPrivate: Bool { self == .dna }

    /// The four codes every build since 2026-09-20 can decode. Only these
    /// are ever written to the sidecar's `kind` key.
    static let legacyCodes: Set<String> = ["BC", "DC", "MC", "Other"]

    /// True for a kind an older build can read straight from `kind`.
    var isLegacy: Bool { Self.legacyCodes.contains(rawValue) }

    /// The kind a generated file name announces ("DNA-20261001-…" → .dna),
    /// for the NEW kinds only. Older builds never generate those prefixes,
    /// so this cannot misread a hand-named or legacy file.
    static func newKind(fromFilename filename: String) -> PersonDocumentKind? {
        guard let dash = filename.firstIndex(of: "-"),
              let kind = PersonDocumentKind(rawValue: String(filename[..<dash])),
              !kind.isLegacy else { return nil }
        return kind
    }

    /// "Birth certificate" — the log line and the detail panel.
    var displayName: String {
        switch self {
        case .birth: return "Birth certificate"
        case .death: return "Death certificate"
        case .marriage: return "Marriage certificate"
        case .military: return "Military record"
        case .census: return "Census record"
        case .dna: return "DNA result"
        case .other: return "Other document"
        }
    }

    /// "birth certificate", "DNA result" — the display name inside a
    /// sentence (an acronym keeps its capitals).
    var inlineName: String {
        self == .dna ? displayName : displayName.lowercased()
    }

    /// "Birth" — the segmented picker in the Add sheet and the inspector's
    /// group headings.
    var shortLabel: String {
        switch self {
        case .birth: return "Birth"
        case .death: return "Death"
        case .marriage: return "Marriage"
        case .military: return "Military"
        case .census: return "Census"
        case .dna: return "DNA"
        case .other: return "Other"
        }
    }

    /// SF Symbol for a row whose thumbnail is not ready (or not wanted).
    var symbolName: String {
        switch self {
        case .birth: return "figure.and.child.holdinghands"
        case .death: return "leaf"
        case .marriage: return "heart"
        case .military: return "shield"
        case .census: return "list.bullet.rectangle"
        case .dna: return "person.line.dotted.person"
        case .other: return "doc.text"
        }
    }
}

/// One row of `documents.json`. The REQUIRED key set is FROZEN by
/// `FamilyDocumentStoreTests` (the schema sensor): add a key only as an
/// optional one so older sidecars still decode, and never rename one. The
/// one optional key so far is `category` (2026-10-01), present only on
/// rows of a new kind; the frozen legacy reader in the tests proves the
/// pre-2026-10-01 decoder ignores it.
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
    /// The sidecar's `kind` code when this build does not know it (a newer
    /// build wrote something other than a legacy code); `kind` then reads
    /// `.other`. Kept so that rewriting the list (an import or a removal
    /// beside it) does not lose it — but written back in `category`, NEVER
    /// in `kind`: the frozen pre-2026-10-01 reader rejects an unknown `kind`
    /// and with it the WHOLE list (codex review 2026-10-02 F4).
    var unrecognizedKindCode: String? = nil
    /// Likewise for a `category` value this build does not know.
    var unrecognizedCategory: String? = nil

    // Swift's `CodingKeys` ≈ the explicit field list a C++ serializer
    // would carry. encode/decode are written out below (in an extension, so
    // the memberwise initializer survives).
    enum CodingKeys: String, CodingKey {
        case id, kind, filename, originalFilename, addedAt, note, sha256, byteCount
        /// Optional (2026-10-01): the real kind of a MIL/CEN/DNA row whose
        /// `kind` says "Other" for the benefit of older builds.
        case category
    }

    /// The REQUIRED persisted keys, for the schema sensor (frozen).
    static let sidecarKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
        .subtracting(optionalSidecarKeys)
    /// Keys a row may carry in addition (older builds ignore them).
    static let optionalSidecarKeys: Set<String> = [CodingKeys.category.stringValue]
}

extension PersonDocument.CodingKeys: CaseIterable {}

// Hand-written Codable (C++: a deserializer with a versioned fallback).
// ON DISK `kind` is always a legacy code (BC/DC/MC/Other) so that a build
// from before 2026-10-01 — whose synthesized decoder ignores unknown keys
// but rejects an unknown `kind` — reads every row. A new kind is written as
// kind "Other" + category "MIL"/"CEN"/"DNA". Reading recovers the kind from,
// in order: `category`; `kind`; and, for a row an older build rewrote
// without `category`, the generated file name's prefix ("DNA-…"), so a DNA
// row stays private even then. Unknown values are kept and written back,
// always in `category` (codex review 2026-10-02 F4): `kind` on disk is
// BC/DC/MC/Other on EVERY write path, whatever was read. When a row carries
// more than `category` can hold, what decides the row's kind wins — an
// unknown category, else a known new kind (DNA stays private), else the
// unknown kind code. Such a row only comes from a build that broke the
// "legacy codes in `kind`" contract.
extension PersonDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .kind)
        let category = try c.decodeIfPresent(String.self, forKey: .category)
        let filename = try c.decode(String.self, forKey: .filename)
        let fromCode = PersonDocumentKind(rawValue: code)
        let fromCategory = category.flatMap(PersonDocumentKind.init(rawValue:))
        let kind = fromCategory
            ?? (fromCode == .other || fromCode == nil ? PersonDocumentKind.newKind(fromFilename: filename) : nil)
            ?? fromCode
            ?? .other
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  kind: kind,
                  filename: filename,
                  originalFilename: try c.decode(String.self, forKey: .originalFilename),
                  addedAt: try c.decode(Date.self, forKey: .addedAt),
                  note: try c.decode(String.self, forKey: .note),
                  sha256: try c.decode(String.self, forKey: .sha256),
                  byteCount: try c.decode(Int.self, forKey: .byteCount),
                  fileURL: nil,
                  unrecognizedKindCode: fromCode == nil ? code : nil,
                  unrecognizedCategory: category != nil && fromCategory == nil ? category : nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        // Only a code the legacy enum decodes, ever.
        try c.encode(kind.isLegacy ? kind.rawValue : PersonDocumentKind.other.rawValue, forKey: .kind)
        if let category = unrecognizedCategory ?? (kind.isLegacy ? nil : kind.rawValue) ?? unrecognizedKindCode {
            try c.encode(category, forKey: .category)
        }
        try c.encode(filename, forKey: .filename)
        try c.encode(originalFilename, forKey: .originalFilename)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(note, forKey: .note)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(byteCount, forKey: .byteCount)
    }
}

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
    /// Diagnostics already written once (a damaged list, keyed by its path,
    /// size and modification date — so a list damaged AGAIN is reported).
    private var reportedOnce: Set<String> = []
    private var extraSink: ((String) -> Void)?

    /// Test seam: every line also goes here. Set to nil to detach.
    func setExtraSink(_ sink: ((String) -> Void)?) {
        lock.withLock { extraSink = sink }
    }

    /// Forget which files and diagnostics were already reported (tests).
    func resetMissing() {
        lock.withLock {
            reportedMissing.removeAll()
            reportedOnce.removeAll()
        }
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
    /// `subject` is the person KEY (`FamilyAssetStore.logSubject`), never a
    /// folder name — a People/ folder is named after the person (codex
    /// review #18 F5). The folder goes to os_log only, marked private.
    @discardableResult
    func missing(_ url: URL, subject: String, privateFolder: String) -> Bool {
        let fresh = lock.withLock { reportedMissing.insert(url.path).inserted }
        guard fresh else { return false }
        write("[tree] document \(url.lastPathComponent) listed in Documents/documents.json for \(subject) "
              + "is missing on disk — dropped from the listing", privateName: privateFolder)
        return true
    }

    /// Write `line` the first time `key` is seen in this process (tests:
    /// `resetMissing`). Returns true when the line was written.
    @discardableResult
    func once(_ key: String, _ line: String, privateName: String? = nil) -> Bool {
        let fresh = lock.withLock { reportedOnce.insert(key).inserted }
        guard fresh else { return false }
        write(line, privateName: privateName)
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

    /// An import that failed AFTER its file was written into `Documents/`
    /// (codex review #18 F4). Every other import error is thrown before a
    /// byte of the document exists (validation), or by the O_EXCL writer,
    /// which unlinks its own partial file. This one says what became of the
    /// written file, so a caller reports what is on disk rather than
    /// "nothing was changed". (C++: an exception type carrying the rollback
    /// result, instead of a bare error code.)
    struct DocumentImportFailure: LocalizedError {
        enum Rollback: Equatable {
            /// Moved to `Documents/.trash/<name>` (the URL is where it went).
            case movedToTrash(URL)
            /// Could not be moved; still at `Documents/<filename>`, unlisted.
            case leftInDocuments(reason: String)
        }
        /// The name it was written under, inside `Documents/`.
        let filename: String
        let rollback: Rollback
        /// Why the import failed after the write (read-back mismatch, the
        /// list could not be read or written).
        let underlying: any Error

        var errorDescription: String? {
            let why = underlying.localizedDescription
            switch rollback {
            case .movedToTrash(let url):
                return "\(why) The file was moved to Documents/\(FamilyAssetStore.documentsTrashFolderName)/\(url.lastPathComponent)."
            case .leftInDocuments(let reason):
                return "\(why) The file Documents/\(filename) could not be moved to "
                    + "Documents/\(FamilyAssetStore.documentsTrashFolderName) (\(reason)); it is still there, not listed."
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
            throw rollBackWrittenDocument(written, in: documentsDir, at: when,
                                          because: StoreError.createFailed(written.lastPathComponent, errno: EIO),
                                          logWhy: "failed its read-back check")
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
            // archive never holds an orphan, then say why — and where it is.
            throw rollBackWrittenDocument(written, in: documentsDir, at: when, because: error,
                                          logWhy: "could not be listed (\(error.localizedDescription))")
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
            for document in documents(inPersonFolder: folder, for: person) where seen.insert(document.id).inserted {
                out.append(document)
            }
        }
        return out.sorted {
            $0.addedAt == $1.addedAt ? $0.filename < $1.filename : $0.addedAt > $1.addedAt
        }
    }

    /// The documents listed in ONE person folder's sidecar, each with its
    /// `fileURL` resolved and re-checked (regular file, not a link,
    /// directly inside `Documents/`). `person` names the diagnostics by key;
    /// without one they carry an opaque folder reference, never its name.
    func documents(inPersonFolder folder: URL, for person: FamilyAssetPerson? = nil) -> [PersonDocument] {
        guard access != .unavailable else { return [] }
        let fresh = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        guard fresh.deletingLastPathComponent() == peopleDirectory, isSafeDirectory(fresh) else { return [] }
        let documentsDir = Self.documentsFolder(in: fresh)
        guard isSafeDirectory(documentsDir) else { return [] }
        let subject = Self.logSubject(person, folder: fresh)
        let entries: [PersonDocument]
        do {
            entries = try readDocumentSidecar(in: documentsDir)
        } catch {
            // Every selection change lists the person: report a damaged
            // list once per state of the file, not once per listing.
            let sidecar = documentsDir.appendingPathComponent(Self.documentsSidecarName)
            let values = try? sidecar.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "unreadable|\(sidecar.path)|\(values?.fileSize ?? -1)|"
                + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            PersonDocumentLog.shared.once(
                key,
                "[tree] could not read Documents/\(Self.documentsSidecarName) for \(subject) — "
                + "\(error.localizedDescription); showing no documents from that folder until it is repaired",
                privateName: fresh.lastPathComponent)
            return []
        }
        return entries.compactMap { entry in
            guard Self.isPlainFilename(entry.filename) else {
                PersonDocumentLog.shared.missing(
                    documentsDir.appendingPathComponent(entry.filename), subject: subject,
                    privateFolder: fresh.lastPathComponent)
                return nil
            }
            let url = documentsDir.appendingPathComponent(entry.filename, isDirectory: false).standardizedFileURL
            guard url.deletingLastPathComponent() == documentsDir,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                PersonDocumentLog.shared.missing(url, subject: subject, privateFolder: fresh.lastPathComponent)
                return nil
            }
            var resolved = entry
            resolved.fileURL = url
            return resolved
        }
    }

    /// False when the person folder HAS a `Documents/documents.json` that
    /// cannot be read (damaged, oversized, a link). A missing list is fine.
    /// The "I found a record" filer asks this before writing anything, so a
    /// damaged list is a refusal rather than a write-then-trash.
    func documentSidecarIsReadable(inPersonFolder folder: URL) -> Bool {
        let documentsDir = Self.documentsFolder(in: folder)
        let sidecar = documentsDir.appendingPathComponent(Self.documentsSidecarName)
        guard fileManager.fileExists(atPath: sidecar.path) else { return true }
        return (try? readDocumentSidecar(in: documentsDir)) != nil
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

    /// Undo an import's own write: move the file it just wrote to .trash
    /// and return the failure describing where the file now is. A move that
    /// fails is logged (file name only) and reported as left in Documents/.
    private func rollBackWrittenDocument(_ written: URL, in documentsDir: URL, at when: Date,
                                         because error: any Error, logWhy: String) -> DocumentImportFailure {
        do {
            let trashed = try Self.moveToTrash(written, in: documentsDir, fileManager: fileManager, at: when)
            return DocumentImportFailure(filename: written.lastPathComponent, rollback: .movedToTrash(trashed),
                                         underlying: error)
        } catch let trashError {
            PersonDocumentLog.shared.write(
                "[tree] document \(written.lastPathComponent) \(logWhy) and could not be moved to .trash "
                + "(\(trashError.localizedDescription)); it is left in \(documentsDir.lastPathComponent)/ unlisted")
            return DocumentImportFailure(filename: written.lastPathComponent,
                                         rollback: .leftInDocuments(reason: trashError.localizedDescription),
                                         underlying: error)
        }
    }

    /// `Documents/.trash/<name>` — a same-named file already there gets a
    /// stamp suffix; nothing is ever replaced. `rename(2)` underneath
    /// (`moveItem`), not `replaceItemAt` (see AtomicFilePublish). Returns
    /// where the file went.
    @discardableResult
    private static func moveToTrash(_ file: URL, in documentsDir: URL,
                                    fileManager: FileManager, at when: Date) throws -> URL {
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
        return destination
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

    /// "LZ7X-ABC" — the person's KEY (FamilySearch ID, else GEDCOM pointer),
    /// never their name: the app log is not the place for family names (QA
    /// 2026-10-01 P3-1; the os_log line still carries the name as private).
    /// A folder name can contain a name too, so it is never used: without a
    /// key the subject is an opaque reference to the folder (the first 8
    /// hex digits of the SHA-256 of its name) — stable across lines, so one
    /// folder's diagnostics can be told apart, and meaningless on its own.
    /// The os_log copy of each line carries the folder name as private.
    static func logSubject(_ person: FamilyAssetPerson?, folder: URL) -> String {
        if let key = person?.familySearchID ?? person?.gedcomID, !key.isEmpty { return key }
        let ref = sha256Hex(Data(folder.lastPathComponent.utf8)).prefix(8)
        return "a person with no ID (folder ref \(ref))"
    }
}
