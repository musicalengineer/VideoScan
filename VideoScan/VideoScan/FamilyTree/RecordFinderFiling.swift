// RecordFinderFiling.swift
// GH #230 Phase A — the "I found a record" bring-back.
//
// The workflow in one sentence (Rick's words, docs/irish_records_design):
// "file the record I downloaded against this person, and once I've read it,
// tell Hallie what it says."
//
// THIS IS A DATA-WRITE PATH (safety-critical discipline). It writes three
// things, in this order, and the order is the design:
//
//   1. the downloaded PDF/PNG/JPG as a person document — through
//      `FamilyAssetStore.importPersonDocument`, which already validates the
//      bytes against the claimed type, writes O_EXCL (never overwrites),
//      re-reads and re-hashes what landed, and keeps `documents.json`;
//   2. one `.recordFinder` finding in the person's research dossier
//      (People/<key>/research/dossier.json) — the record's URL, site,
//      transcription and Rick's verdict, so an unread record can be
//      confirmed and told later from the Research pane;
//   3. ONLY when Rick ticks "I've read it and it is this person": one
//      CyberBrain item with one `.officialRecord` source (URL, retrieval
//      date, locator = the filed document), confidence `confirmed`.
//
// Every check that can say no runs BEFORE the first write (refuse over
// guess): fields, write access, viewer mode, the file's type/size/magic
// bytes, its SHA-256 against every document already filed for the person,
// the dossier being readable, the same record not already filed, and a
// CyberBrain being configured when one will be written. Then each write is
// PROVED (re-listed / re-loaded) before the next starts. A failure after a
// write undoes the earlier writes — the document moves to Documents/.trash
// (never deleted), the dossier is put back as it was — and the outcome says
// which. The GEDCOM is never touched.
//
// Outcomes are named, and only `.filed` is success:
//   .filed       everything requested landed and was proved
//   .refused     nothing was written
//   .rolledBack  something was written and has been undone (where it went)
//   .mixedState  something is left that could not be undone (what, where)
//
// Logging: one START and one OUTCOME line through the app log sink
// (catalog.log / videoscan.log), naming the subject KEY (FamilySearch ID or
// the U- hash), the document's file name, its SHA-256 prefix and the finding
// id — never the person's name, the URL or the transcription.
//
// Memory: the duplicate check streams the file through SHA-256 in 1 MB
// chunks; the import itself holds one ≤ 48 MB Data while validating (see
// FamilyAssetStore+Documents). Nothing is cached.
//
// C++ readers: `struct` with `let` closures ≈ a small object holding
// std::function members (dependency injection for tests); `NSLock.withLock`
// ≈ std::lock_guard around the block; `Result<T, E>` ≈ std::expected.

import CryptoKit
import Foundation
import VideoScanCore

// MARK: - What Rick found

/// The kind of record. Decides the document code on disk (BC/DC/MC/Other)
/// and the words in the citation.
enum FoundRecordType: String, CaseIterable, Sendable, Codable {
    case birth, baptism, marriage, death, burial, census, military, will, valuation, other

    var label: String {
        switch self {
        case .birth: return "Civil birth"
        case .baptism: return "Baptism"
        case .marriage: return "Marriage"
        case .death: return "Civil death"
        case .burial: return "Burial"
        case .census: return "Census return"
        case .military: return "Military service record"
        case .will: return "Will or probate"
        case .valuation: return "Valuation or tithe"
        case .other: return "Other record"
        }
    }

    /// Only certificates get the certificate codes; a baptism register
    /// entry is not a birth certificate, so it is filed as Other with its
    /// label in the note.
    var documentKind: PersonDocumentKind {
        switch self {
        case .birth: return .birth
        case .marriage: return .marriage
        case .death: return .death
        case .baptism, .burial, .census, .military, .will, .valuation, .other: return .other
        }
    }
}

/// Everything the "I found a record" sheet collects. Plain values only.
struct FoundRecordSubmission: Sendable, Equatable {
    /// The downloaded file (PDF / PNG / JPG).
    let file: URL
    /// Record Finder site id when it came from one of the menu's links.
    let siteID: String?
    /// "irishgenealogy.ie", "Census of Ireland 1901 / 1911", … (required).
    let siteTitle: String
    let recordType: FoundRecordType
    /// Four-digit year of the event, or empty.
    let year: String
    /// Registration district, parish, DED — free text, may be empty.
    let district: String
    /// The archive's own record id, may be empty.
    let recordID: String
    /// Web address of the record page (required, http/https).
    let pageURL: String
    /// What the record says, in Rick's words. Required when telling Hallie.
    let transcription: String
    /// "I've read this record and it is this person" — the ONLY way the
    /// CyberBrain is written and the only way confidence is `confirmed`.
    let confirmedRead: Bool
}

/// The four ways a filing can end. Only `.filed` is success.
enum RecordFilingOutcome: Equatable, Sendable {
    case filed(documentFilename: String, findingID: String, toldItemID: String?)
    case refused(String)
    case rolledBack(String)
    case mixedState(String)

    var isSuccess: Bool { if case .filed = self { return true }; return false }

    /// What the sheet shows.
    var message: String {
        switch self {
        case .filed(let file, _, let told):
            return told == nil
                ? "Filed as \(file). When you've read it, mark it Confirmed in Research… and tell Hallie."
                : "Filed as \(file) and told Hallie (confirmed)."
        case .refused(let why): return why
        case .rolledBack(let why): return "Nothing was kept: \(why)"
        case .mixedState(let why): return "Needs attention: \(why)"
        }
    }
}

// MARK: - The filer

struct RecordFinderFiler {
    let assetStore: FamilyAssetStore
    let assetPerson: FamilyAssetPerson
    let researchStore: ResearchStore
    let subject: ResearchSubject
    let speakerName: String
    /// Writes one testimony to the CyberBrain; nil when no CyberBrain is
    /// configured (then a confirmed filing is refused up front).
    let record: (@Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt)?
    let log: @Sendable (String) -> Void
    let now: @Sendable () -> Date

    init(assetStore: FamilyAssetStore, assetPerson: FamilyAssetPerson, researchStore: ResearchStore,
         subject: ResearchSubject, speakerName: String,
         record: (@Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt)?,
         log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.assetStore = assetStore
        self.assetPerson = assetPerson
        self.researchStore = researchStore
        self.subject = subject
        self.speakerName = speakerName
        self.record = record
        self.log = log
        self.now = now
    }

    static let maxTranscriptionLength = 8_000
    static let hashChunkBytes = 1 << 20

    /// One filing at a time, process-wide: "one editor, one writer". The
    /// duplicate check and the import must not interleave with another
    /// filing of the same file.
    private static let filingLock = NSLock()

    /// File it. Synchronous and blocking (file I/O + PDF parse): call it
    /// off the main actor.
    func file(_ submission: FoundRecordSubmission) -> RecordFilingOutcome {
        Self.filingLock.withLock { fileLocked(submission) }
    }

    // MARK: The transaction

    private func fileLocked(_ s: FoundRecordSubmission) -> RecordFilingOutcome {
        log("[record-finder] START file \(s.recordType.rawValue) record for \(subject.key) — "
            + ".\(s.file.pathExtension.lowercased()), site \(s.siteID ?? "other"), "
            + "tell Hallie \(s.confirmedRead ? "yes" : "no")")

        // ---- Refusals: nothing has been written yet. ----
        let pre: Prepared
        switch prepare(s) {
        case .failure(let refusal): return finish(.refused(refusal.message), code: refusal.code)
        case .success(let prepared): pre = prepared
        }

        // ---- Write 1: the document, proved. ----
        let filed: FiledDocument
        switch writeDocument(s, pre) {
        case .failure(let stop): return finish(stop.outcome, code: stop.code)
        case .success(let document): filed = document
        }

        // ---- Write 2: the finding in the dossier, proved. ----
        var finding = ResearchFinding(
            source: .recordFinder, title: pre.findingTitle, date: pre.year, excerpt: pre.excerpt,
            url: pre.pageURL, retrievedAt: pre.when,
            verdict: s.confirmedRead ? .confirmed : .unreviewed,
            documentPath: filed.archivePath, idSeed: "sha256:" + pre.sha256)
        var dossier = pre.priorDossier ?? ResearchDossier(subject: subject)
        if let stop = writeFinding(finding, into: &dossier, pre: pre, filed: filed) {
            return finish(stop.outcome, code: stop.code)
        }
        guard s.confirmedRead else {
            return finish(.filed(documentFilename: filed.document.filename, findingID: finding.id, toldItemID: nil),
                          code: "filed", detail: filed.document, sha: pre.sha256)
        }

        // ---- Write 3: the CyberBrain (only after Rick read it). ----
        let receipt: CyberBrainWriter.Receipt
        switch tellHallie(finding, pre: pre, filed: filed) {
        case .failure(let stop): return finish(stop.outcome, code: stop.code)
        case .success(let told): receipt = told
        }

        // ---- Write 4: remember that Hallie was told. ----
        finding.toldItemID = receipt.itemID
        dossier.markTold(id: finding.id, itemID: receipt.itemID)
        do {
            try researchStore.saveDossier(dossier)
        } catch {
            return finish(.mixedState("Hallie was told (item \(receipt.itemID)) and the document is filed as "
                                      + "\(filed.document.filename), but the research file could not record that "
                                      + "Hallie was told — do not press Tell Hallie for this record again "
                                      + "(\(error.localizedDescription))."), code: "told-unrecorded")
        }
        return finish(.filed(documentFilename: filed.document.filename, findingID: finding.id,
                             toldItemID: receipt.itemID),
                      code: "filed", detail: filed.document, sha: pre.sha256)
    }

    /// Why the transaction stopped after it began, with the log code.
    struct Stop: Error {
        let outcome: RecordFilingOutcome
        let code: String
    }

    /// The document as filed and proved.
    struct FiledDocument {
        let document: PersonDocument
        let folder: URL
        /// `People/<folder>/Documents/<file>` — the CyberBrain locator.
        let archivePath: String
    }

    /// Write 1. The person's folder may be created here (an empty
    /// People/<…>/ directory — harmless, and the only side effect before the
    /// document itself).
    private func writeDocument(_ s: FoundRecordSubmission, _ pre: Prepared) -> Result<FiledDocument, Stop> {
        let folder: URL
        do {
            folder = try assetStore.folderForPhotoRequest(person: assetPerson)
        } catch {
            return .failure(Stop(outcome: .refused(error.localizedDescription), code: "folder"))
        }
        let document: PersonDocument
        do {
            document = try assetStore.importPersonDocument(
                from: s.file, kind: s.recordType.documentKind, note: pre.note, into: folder, for: assetPerson)
        } catch let error as FamilyAssetStore.DocumentError {
            return .failure(Stop(outcome: .refused(error.localizedDescription), code: "import-refused"))
        } catch let error as FamilyAssetStore.StoreError where error == .readOnly || error == .sourceUnavailable {
            return .failure(Stop(outcome: .refused(error.localizedDescription), code: "read-only"))
        } catch {
            // The store's own post-write checks failed; it moved what it
            // wrote to Documents/.trash (or logged that it could not).
            return .failure(Stop(outcome: .rolledBack("the archive refused the write after it began "
                                                      + "(\(error.localizedDescription)); anything written was "
                                                      + "moved to Documents/.trash"), code: "import-failed"))
        }
        // Prove it: the same bytes we hashed, listed in documents.json.
        let listed = assetStore.documents(inPersonFolder: folder).first { $0.id == document.id }
        guard document.sha256 == pre.sha256, document.byteCount == pre.byteCount,
              let landedURL = listed?.fileURL, FileManager.default.fileExists(atPath: landedURL.path) else {
            return .failure(Stop(outcome: undoDocument(document, folder: folder,
                                                       why: "the file changed while it was being filed, or could not be found after writing"),
                                 code: "document-unproved"))
        }
        return .success(FiledDocument(document: document, folder: folder,
                                      archivePath: CyberBrainWriter.photoLocator(landedURL.path)))
    }

    /// Write 2. Nil on success (dossier saved and read back).
    private func writeFinding(_ finding: ResearchFinding, into dossier: inout ResearchDossier,
                              pre: Prepared, filed: FiledDocument) -> Stop? {
        guard dossier.addFiled(finding) else {
            // Checked in prepare(); under the lock this cannot change, so
            // this is belt and braces.
            return Stop(outcome: undoDocument(filed.document, folder: filed.folder, why: "this record is already filed"),
                        code: "duplicate-finding")
        }
        do {
            try researchStore.saveDossier(dossier)
            guard let back = try researchStore.loadDossier(key: subject.key),
                  back.findings.contains(where: { $0.id == finding.id }) else {
                throw ResearchStore.StoreError.ioFailure("the research file did not read back")
            }
            return nil
        } catch {
            return undoAll(pre: pre, filed: filed,
                           why: "the research file could not be saved (\(error.localizedDescription))",
                           code: "dossier-failed")
        }
    }

    /// Write 3. The testimony for a CONFIRMED finding through the injected
    /// CyberBrain writer; any failure undoes writes 1 and 2.
    private func tellHallie(_ finding: ResearchFinding, pre: Prepared,
                            filed: FiledDocument) -> Result<CyberBrainWriter.Receipt, Stop> {
        guard let record else {
            // prepare() refused this already; kept so the type system agrees.
            return .failure(undoAll(pre: pre, filed: filed, why: "no CyberBrain is configured", code: "no-cyberbrain"))
        }
        do {
            let testimony = try ResearchAttestation.testimony(
                for: finding, subject: subject, speakerName: speakerName, date: pre.when)
            return .success(try record(testimony))
        } catch {
            return .failure(undoAll(pre: pre, filed: filed,
                                    why: "Hallie's knowledge file could not be written (\(error.localizedDescription))",
                                    code: "cyberbrain-failed"))
        }
    }

    // MARK: Refusal checks

    struct Refusal: Error, Equatable {
        /// Short machine word for the log ("duplicate-document").
        let code: String
        /// Plain words for the sheet.
        let message: String
    }

    /// Everything decided before the first write.
    struct Prepared {
        let sha256: String
        let byteCount: Int
        let pageURL: String
        let year: String?
        let note: String
        let findingTitle: String
        let excerpt: String
        let priorDossier: ResearchDossier?
        let when: Date
    }

    /// The checked, trimmed fields of a submission.
    struct Fields {
        let site: String
        let pageURL: String
        let year: String
        let transcription: String
    }

    /// The checked file: its streamed SHA-256 and size.
    struct CheckedFile {
        let sha256: String
        let byteCount: Int
    }

    func prepare(_ s: FoundRecordSubmission) -> Result<Prepared, Refusal> {
        let fields: Fields
        switch checkFields(s) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let checked): fields = checked
        }
        // Where it may be written.
        do {
            try assetStore.requireWriteAccess()
            try ViewerWriteGuard.check("RecordFinderFiler.file")
        } catch {
            return .failure(Refusal(code: "read-only", message: error.localizedDescription))
        }
        let file: CheckedFile
        switch checkFile(s.file) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let checked): file = checked
        }
        // Already filed for this person? (Same bytes in any of their folders.)
        if let existing = assetStore.documents(for: assetPerson).first(where: { $0.sha256 == file.sha256 }) {
            return .failure(Refusal(
                code: "duplicate-document",
                message: "This exact file is already filed for \(assetPerson.name) as \(existing.filename) "
                    + "(\(existing.kind.displayName.lowercased()), added \(FamilyTreeNote.shortDate(existing.addedAt)))."))
        }
        // The dossier must be readable — a damaged one is never replaced.
        let prior: ResearchDossier?
        do {
            prior = try researchStore.loadDossier(key: subject.key)
        } catch {
            return .failure(Refusal(code: "dossier-unreadable",
                                    message: "The research file for \(assetPerson.name) can't be read "
                                        + "(\(error.localizedDescription)); nothing was changed."))
        }
        let findingID = ResearchFinding.makeID(source: .recordFinder, url: "sha256:" + file.sha256)
        if prior?.findings.contains(where: { $0.id == findingID }) == true {
            return .failure(Refusal(code: "duplicate-finding",
                                    message: "This record is already filed for \(assetPerson.name)."))
        }
        return .success(describe(s, fields: fields, file: file, prior: prior))
    }

    /// Site, URL, year and words — pure.
    func checkFields(_ s: FoundRecordSubmission) -> Result<Fields, Refusal> {
        func no(_ code: String, _ message: String) -> Result<Fields, Refusal> {
            .failure(Refusal(code: code, message: message))
        }
        let site = s.siteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { return no("site", "Say which site the record came from.") }
        let pageURL = s.pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: pageURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else {
            return no("url", "Paste the web address of the record page (it starts with https://).")
        }
        let year = s.year.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now())
        if !year.isEmpty {
            guard year.count == 4, let y = Int(year), (1500...currentYear).contains(y) else {
                return no("year", "The year should be four digits, like 1904.")
            }
        }
        let transcription = s.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcription.count <= Self.maxTranscriptionLength else {
            return no("transcription-long",
                      "The transcription is longer than \(Self.maxTranscriptionLength) characters — keep it to what the record says.")
        }
        if s.confirmedRead {
            guard !transcription.isEmpty else {
                return no("transcription-empty",
                          "Type what the record says before telling Hallie — she only repeats what you wrote.")
            }
            guard record != nil else {
                return no("no-cyberbrain",
                          "Hallie's knowledge file isn't set up on this Mac, so she can't be told. Untick \"I've read it\" to file the record only.")
            }
        }
        return .success(Fields(site: site, pageURL: pageURL, year: year, transcription: transcription))
    }

    /// A regular file of an allowed type, within the size cap (checked
    /// before any byte is read), whose first bytes are what its extension
    /// claims; then its SHA-256, streamed.
    func checkFile(_ file: URL) -> Result<CheckedFile, Refusal> {
        let source = URL(fileURLWithPath: file.path, isDirectory: false)
        let ext = source.pathExtension.lowercased()
        guard FamilyAssetStore.allowedPersonDocumentExtensions.contains(ext) else {
            return .failure(Refusal(code: "type", message: FamilyAssetStore.DocumentError.unsupportedType(ext).localizedDescription))
        }
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            return .failure(Refusal(code: "unreadable",
                                    message: FamilyAssetStore.DocumentError.sourceUnreadable(source.lastPathComponent).localizedDescription))
        }
        guard size <= FamilyAssetStore.maxImportBytes else {
            return .failure(Refusal(code: "too-large", message: FamilyAssetStore.DocumentError.tooLarge(bytes: size).localizedDescription))
        }
        guard size > 0, Self.hasPlausibleMagic(source, fileExtension: ext),
              let digest = Self.streamedSHA256(of: source) else {
            return .failure(Refusal(code: "magic", message: FamilyAssetStore.DocumentError.notTheClaimedType(ext).localizedDescription))
        }
        return .success(CheckedFile(sha256: digest, byteCount: size))
    }

    /// The words that go with it: document note, finding title and excerpt.
    private func describe(_ s: FoundRecordSubmission, fields: Fields, file: CheckedFile,
                          prior: ResearchDossier?) -> Prepared {
        var where_: [String] = []
        let district = s.district.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = s.recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !district.isEmpty { where_.append(district) }
        if !recordID.isEmpty { where_.append("record \(recordID)") }
        let what = s.recordType.label + (fields.year.isEmpty ? "" : " \(fields.year)")
        let place = where_.joined(separator: ", ")
        let findingTitle = "\(what) — \(fields.site)" + (place.isEmpty ? "" : " (\(place))")
        let note = "\(fields.site): \(what)" + (place.isEmpty ? "" : ", \(place)") + ". \(fields.pageURL)"
        let excerpt = fields.transcription.isEmpty
            ? "Filed \(s.recordType.label.lowercased()) record from \(fields.site); not yet transcribed."
            : fields.transcription
        return Prepared(sha256: file.sha256, byteCount: file.byteCount, pageURL: fields.pageURL,
                        year: fields.year.isEmpty ? nil : fields.year, note: note,
                        findingTitle: findingTitle, excerpt: excerpt, priorDossier: prior, when: now())
    }

    // MARK: Undo

    /// Undo writes 1 and 2: dossier back as it was, document to .trash.
    private func undoAll(pre: Prepared, filed: FiledDocument, why: String, code: String) -> Stop {
        let restored = restoreDossier(pre.priorDossier)
        let undone = undoDocument(filed.document, folder: filed.folder, why: why)
        return Stop(outcome: combine(undone, dossierRestored: restored), code: code)
    }

    /// Move the just-filed document to Documents/.trash and drop its row.
    private func undoDocument(_ document: PersonDocument, folder: URL, why: String) -> RecordFilingOutcome {
        do {
            try assetStore.removeDocument(document, from: folder, for: assetPerson)
            return .rolledBack("\(why). The file was moved to Documents/\(FamilyAssetStore.documentsTrashFolderName)/\(document.filename).")
        } catch {
            return .mixedState("\(why). The document \(document.filename) could NOT be moved to Documents/.trash "
                               + "(\(error.localizedDescription)); it is still listed for this person — remove it from the inspector.")
        }
    }

    /// Put the dossier back as it was before this filing. With no prior
    /// dossier, the restored file is an empty one (nothing is ever deleted).
    private func restoreDossier(_ prior: ResearchDossier?) -> Bool {
        do {
            try researchStore.saveDossier(prior ?? ResearchDossier(subject: subject))
            return true
        } catch {
            return false
        }
    }

    private func combine(_ outcome: RecordFilingOutcome, dossierRestored: Bool) -> RecordFilingOutcome {
        guard !dossierRestored else { return outcome }
        let tail = " The research file could not be put back; it lists this record although the document is gone — "
            + "remove the finding in Research…"
        switch outcome {
        case .rolledBack(let why), .mixedState(let why): return .mixedState(why + tail)
        default: return outcome
        }
    }

    // MARK: Log

    private func finish(_ outcome: RecordFilingOutcome, code: String,
                        detail: PersonDocument? = nil, sha: String? = nil) -> RecordFilingOutcome {
        let kind: String
        switch outcome {
        case .filed: kind = "filed"
        case .refused: kind = "refused"
        case .rolledBack: kind = "rolledBack"
        case .mixedState: kind = "MIXED STATE"
        }
        var line = "[record-finder] OUTCOME \(kind) (\(code)) for \(subject.key)"
        if case .filed(let file, let findingID, let told) = outcome {
            line += " — Documents/\(file)"
            if let sha { line += " sha256 \(sha.prefix(12))" }
            if let bytes = detail?.byteCount { line += ", \(FamilyAssetStore.displayBytes(bytes))" }
            line += "; finding \(findingID); CyberBrain item \(told ?? "none (not yet read)")"
            line += ". Revert: Remove the document in the Family Tree inspector (moves to Documents/.trash)"
            if told != nil { line += "; the CyberBrain keeps a backup of the previous file under backups/" }
        } else if case .mixedState = outcome {
            line += " — see the sheet's message; files are named there"
        }
        log(line)
        return outcome
    }

    // MARK: Helpers

    /// SHA-256 of a file read in 1 MB chunks — memory stays at one chunk.
    static func streamedSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: hashChunkBytes) ?? Data() }
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first bytes match the extension (PNG / JPEG / %PDF-). The full
    /// validation (decode / PDFKit parse) happens inside the import, still
    /// before anything is written.
    static func hasPlausibleMagic(_ url: URL, fileExtension: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8) else { return false }
        switch fileExtension {
        case "png": return head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "jpg", "jpeg": return head.starts(with: [0xFF, 0xD8, 0xFF])
        case "pdf": return head.starts(with: Array("%PDF-".utf8))
        default: return false
        }
    }
}
