// RecordFinderFiling.swift
// GH #230 Phase A — the "I found a record" bring-back.
//
// The workflow in one sentence (Rick's words, docs/research/irish_records_design_2026-09-30.md):
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
//      Rick's WHOLE transcription and his verdict, so an unread record can
//      be confirmed and told later from the Research pane;
//   3. ONLY when Rick ticks "I've read it and it is this person": one
//      CyberBrain item with one `.officialRecord` source (URL, retrieval
//      date, locator = the filed document), confidence `confirmed`.
//
// Every check that can say no runs BEFORE the first write (refuse over
// guess): fields, write access, viewer mode, the file's type/size/magic
// bytes, every documents.json of the person being readable, the file's
// SHA-256 against every document already filed for them, the dossier being
// readable, and a CyberBrain being configured when one will be written.
// Then each write is PROVED (re-listed / re-loaded) before the next starts.
//
// The dossier is shared with the Research pane (and any second window), so
// it is NEVER saved from a copy: every write here is a read-modify-write
// under ResearchStore's per-key lock (`update(key:)`, QA 2026-10-01 P2-1).
// Undo works the same way — it takes back only THIS filing's change from
// what is on disk now, and retires a dossier.json this filing itself
// created if nothing else was added to it meanwhile. "This filing's
// change" is recorded INSIDE the locked write that made it (the value
// found and the value written, per field), and a field is put back only
// while it still holds the value written — another writer's later edit is
// never undone (codex review 2026-10-02 F1/F2).
//
// A failure after a write undoes the earlier writes — the document moves to
// Documents/.trash (never deleted), this finding comes off the dossier —
// and the outcome says which. The GEDCOM is never touched.
//
// Re-attach (QA P2-3): the finding's id is the file's SHA-256, so filing the
// same file again after its document was removed in the inspector finds the
// old finding. It is re-attached to the new document (documentPath updated);
// its verdict, lore and told state are kept, and Hallie is not told twice.
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
// Concurrency: one filing at a time through an async gate (an actor queue —
// a waiting filer SUSPENDS instead of blocking a cooperative thread, QA
// P3-7). The per-key dossier lock is held only for a single small JSON
// read + write.
//
// Memory: the duplicate check streams the file through SHA-256 in 1 MB
// chunks; the import itself holds one ≤ 48 MB Data while validating (see
// FamilyAssetStore+Documents). Nothing is cached.
//
// C++ readers: `struct` with `let` closures ≈ a small object holding
// std::function members (dependency injection for tests); `actor` ≈ a class
// whose methods run one at a time; `Result<T, E>` ≈ std::expected.

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
    /// label in the note. Census returns and military service records
    /// have their own codes (CEN / MIL) since 2026-10-01, so the inspector
    /// can group them.
    var documentKind: PersonDocumentKind {
        switch self {
        case .birth: return .birth
        case .marriage: return .marriage
        case .death: return .death
        case .census: return .census
        case .military: return .military
        case .baptism, .burial, .will, .valuation, .other: return .other
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
                : "Filed as \(file); Hallie knows what it says (confirmed)."
        case .refused(let why): return why
        case .rolledBack(let why): return "Nothing was kept: \(why)"
        case .mixedState(let why): return "Needs attention: \(why)"
        }
    }
}

/// One filing at a time without blocking a thread: callers queue on an
/// actor and are resumed in order. (C++: a mutex whose waiters are
/// coroutines that suspend rather than threads that block.)
actor RecordFilingGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
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

    /// "One editor, one writer": the duplicate check and the import must not
    /// interleave with another filing of the same file.
    static let gate = RecordFilingGate()

    /// File it. The work itself is synchronous file I/O (+ a PDF parse);
    /// call from a background task (the sheet uses Task.detached).
    func file(_ submission: FoundRecordSubmission) async -> RecordFilingOutcome {
        await Self.gate.enter()
        let outcome = fileLocked(submission)
        await Self.gate.leave()
        return outcome
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

        // ---- Write 2: the finding in the dossier (read-modify-write), proved. ----
        let fresh = ResearchFinding(
            source: .recordFinder, title: pre.findingTitle, date: pre.year, excerpt: pre.excerpt,
            url: pre.pageURL, retrievedAt: pre.when,
            verdict: s.confirmedRead ? .confirmed : .unreviewed,
            documentPath: filed.archivePath, idSeed: "sha256:" + pre.sha256,
            fullText: pre.transcription)
        let stored: ResearchFinding
        let wrote: FindingWrite
        switch writeFinding(fresh, confirmedRead: s.confirmedRead, pre: pre, filed: filed) {
        case .failure(let stop): return finish(stop.outcome, code: stop.code)
        case .success(let written): (stored, wrote) = (written.finding, written.write)
        }
        let code = pre.reattach == nil ? "filed" : "re-attached"
        // Unread, or already told before (a re-attach): nothing more to write.
        guard s.confirmedRead, stored.toldItemID == nil else {
            return finish(.filed(documentFilename: filed.document.filename, findingID: stored.id,
                                 toldItemID: stored.toldItemID),
                          code: code, detail: filed.document, sha: pre.sha256)
        }

        // ---- Write 3: the CyberBrain (only after Rick read it). ----
        let receipt: CyberBrainWriter.Receipt
        switch tellHallie(stored, pre: pre, filed: filed, wrote: wrote) {
        case .failure(let stop): return finish(stop.outcome, code: stop.code)
        case .success(let told): receipt = told
        }

        // ---- Write 4: remember that Hallie was told. ----
        do {
            try researchStore.update(key: subject.key) { onDisk in onDisk?.markTold(id: stored.id, itemID: receipt.itemID) }
        } catch {
            return finish(.mixedState("Hallie was told (item \(receipt.itemID)) and the document is filed as "
                                      + "\(filed.document.filename), but the research file could not record that "
                                      + "Hallie was told (\(error.localizedDescription)). Pressing Tell Hallie again "
                                      + "is safe: the same words from the same record are not recorded twice."),
                          code: "told-unrecorded")
        }
        return finish(.filed(documentFilename: filed.document.filename, findingID: stored.id,
                             toldItemID: receipt.itemID),
                      code: code, detail: filed.document, sha: pre.sha256)
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
        // The target folder's list too (it may be a folder prepare() did not
        // see yet): refuse rather than write a file that cannot be listed.
        guard assetStore.documentSidecarIsReadable(inPersonFolder: folder) else {
            return .failure(Stop(outcome: .refused(Self.unreadableListMessage), code: "document-list-unreadable"))
        }
        let document: PersonDocument
        do {
            document = try assetStore.importPersonDocument(
                from: s.file, kind: s.recordType.documentKind, note: pre.note, into: folder, for: assetPerson)
        } catch let failure as FamilyAssetStore.DocumentImportFailure {
            // The document WAS written, then the import failed (codex review
            // #18 F4). Report what is on disk now, not what was hoped.
            let outcome = Self.importFailureOutcome(failure, documentsDir: FamilyAssetStore.documentsFolder(in: folder))
            return .failure(Stop(outcome: outcome, code: "import-failed"))
        } catch let error as FamilyAssetStore.DocumentError {
            // Validation: thrown before any byte of the document is written.
            return .failure(Stop(outcome: .refused(error.localizedDescription), code: "import-refused"))
        } catch let error as FamilyAssetStore.StoreError where error == .readOnly || error == .sourceUnavailable {
            return .failure(Stop(outcome: .refused(error.localizedDescription), code: "read-only"))
        } catch {
            // Anything else comes from before or inside the O_EXCL write,
            // which removes its own partial file: no document was kept.
            return .failure(Stop(outcome: .refused("The archive could not write the document "
                                                   + "(\(error.localizedDescription)); nothing was filed."),
                                 code: "import-write-failed"))
        }
        // Prove it: the same bytes we hashed, listed in documents.json.
        let listed = assetStore.documents(inPersonFolder: folder, for: assetPerson).first { $0.id == document.id }
        guard document.sha256 == pre.sha256, document.byteCount == pre.byteCount,
              let landedURL = listed?.fileURL, FileManager.default.fileExists(atPath: landedURL.path) else {
            return .failure(Stop(outcome: undoDocument(document, folder: folder,
                                                       why: "the file changed while it was being filed, or could not be found after writing"),
                                 code: "document-unproved"))
        }
        return .success(FiledDocument(document: document, folder: folder,
                                      archivePath: CyberBrainWriter.photoLocator(landedURL.path)))
    }

    /// One field write 2 changed: the value it FOUND there and the value it
    /// WROTE, both taken inside the same locked change (codex review
    /// 2026-10-02 F2 — the old undo restored the prepare-time snapshot, so
    /// a verdict saved between prepare and the write was lost). Undo puts
    /// `previous` back only while the field still holds `written`.
    /// (C++: an undo record {old, new} applied compare-and-swap style.)
    struct FieldWrite<Value: Equatable>: Equatable {
        let previous: Value
        let written: Value
    }

    /// Exactly what write 2 put on a RE-ATTACHED finding (codex review #18
    /// F3). A verdict or words saved by the Research pane after this write
    /// are someone else's, and are kept. Nil members were not written.
    struct ReattachWrite: Equatable {
        let documentPath: FieldWrite<String?>
        let verdict: FieldWrite<ResearchVerdict>?
        let fullText: FieldWrite<String?>?
    }

    /// What write 2 did, recorded inside the locked change that did it.
    enum FindingWrite: Equatable {
        /// Nothing reached the change (the read failed first).
        case none
        /// A new finding, exactly as it reads back from disk
        /// (`ResearchStore.asStored`). Undo removes it only while the
        /// finding on disk still EQUALS this (codex review 2026-10-02 F1:
        /// lore or a verdict saved on it meanwhile used to be deleted).
        case inserted(ResearchFinding)
        /// An existing finding pointed at the new document.
        case reattached(ReattachWrite)
    }

    /// The finding as stored, plus what was written.
    struct WrittenFinding {
        let finding: ResearchFinding
        let write: FindingWrite
    }

    /// Write 2, under the per-key lock: add the finding — or, re-attaching,
    /// point the existing finding at the new document. Proved by reading
    /// the file back. Returns the finding as stored.
    private func writeFinding(_ fresh: ResearchFinding, confirmedRead: Bool, pre: Prepared,
                              filed: FiledDocument) -> Result<WrittenFinding, Stop> {
        let subject = self.subject
        let reattaching = pre.reattach != nil
        // Set inside the (synchronous, non-escaping) change closure, before
        // the save — so even a save whose read-back fails knows what it
        // may have written, and the "previous" values are the ones on disk
        // under the lock, not the prepare() snapshot.
        var wrote = FindingWrite.none
        do {
            try researchStore.update(key: subject.key) { onDisk in
                var dossier = onDisk ?? ResearchDossier(subject: subject)
                if let index = dossier.findings.firstIndex(where: { $0.id == fresh.id }) {
                    guard reattaching else { throw Refusal(code: "duplicate-finding", message: "this record is already filed") }
                    var found = dossier.findings[index]
                    let path = FieldWrite(previous: found.documentPath, written: fresh.documentPath)
                    found.documentPath = fresh.documentPath
                    var verdict: FieldWrite<ResearchVerdict>?
                    var words: FieldWrite<String?>?
                    if confirmedRead, found.toldItemID == nil {
                        verdict = FieldWrite(previous: found.verdict, written: .confirmed)
                        found.verdict = .confirmed
                        if let text = fresh.fullText {
                            words = FieldWrite(previous: found.fullText, written: text)
                            found.fullText = text
                        }
                    }
                    dossier.findings[index] = found
                    wrote = .reattached(ReattachWrite(documentPath: path, verdict: verdict, fullText: words))
                } else {
                    let landing = try ResearchStore.asStored(fresh)
                    guard dossier.addFiled(fresh) else { throw Refusal(code: "duplicate-finding", message: "this record is already filed") }
                    wrote = .inserted(landing)
                }
                onDisk = dossier
            }
            guard let back = try researchStore.loadDossier(key: subject.key),
                  let stored = back.findings.first(where: { $0.id == fresh.id }),
                  stored.documentPath == fresh.documentPath else {
                throw ResearchStore.StoreError.ioFailure("the research file did not read back")
            }
            return .success(WrittenFinding(finding: stored, write: wrote))
        } catch let refusal as Refusal {
            // Nothing was written to the dossier; only the document to undo.
            return .failure(Stop(outcome: undoDocument(filed.document, folder: filed.folder, why: refusal.message),
                                 code: refusal.code))
        } catch {
            return .failure(undoAll(pre: pre, findingID: fresh.id, filed: filed, wrote: wrote,
                                    why: "the research file could not be saved (\(error.localizedDescription))",
                                    code: "dossier-failed"))
        }
    }

    /// Write 3. The testimony for a CONFIRMED finding through the injected
    /// CyberBrain writer; any failure undoes writes 1 and 2.
    private func tellHallie(_ finding: ResearchFinding, pre: Prepared,
                            filed: FiledDocument, wrote: FindingWrite) -> Result<CyberBrainWriter.Receipt, Stop> {
        guard let record else {
            // prepare() refused this already; kept so the type system agrees.
            return .failure(undoAll(pre: pre, findingID: finding.id, filed: filed, wrote: wrote,
                                    why: "no CyberBrain is configured", code: "no-cyberbrain"))
        }
        do {
            let testimony = try ResearchAttestation.testimony(
                for: finding, subject: subject, speakerName: speakerName, date: pre.when)
            return .success(try record(testimony))
        } catch {
            return .failure(undoAll(pre: pre, findingID: finding.id, filed: filed, wrote: wrote,
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
        /// Rick's words, whole; empty when he typed none.
        let transcription: String
        let note: String
        let findingTitle: String
        let excerpt: String
        /// A dossier.json existed before this filing (undo never retires it).
        let priorExisted: Bool
        /// The finding filed earlier for these same bytes whose document has
        /// since been removed — to be re-attached, not duplicated.
        let reattach: ResearchFinding?
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

    static let unreadableListMessage =
        "This person's document list (Documents/documents.json) is damaged, so nothing was filed. "
        + "Repair or move that file in Finder, then try again."

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
        // Every list of this person's documents must be readable: a damaged
        // one would hide a duplicate and make the import write-then-trash.
        if assetStore.personFolders(for: assetPerson).contains(where: { !assetStore.documentSidecarIsReadable(inPersonFolder: $0) }) {
            return .failure(Refusal(code: "document-list-unreadable", message: Self.unreadableListMessage))
        }
        // Already filed for this person? (Same bytes in any of their folders.)
        if let existing = assetStore.documents(for: assetPerson).first(where: { $0.sha256 == file.sha256 }) {
            return .failure(Refusal(
                code: "duplicate-document",
                message: "This exact file is already filed for \(assetPerson.name) as \(existing.filename) "
                    + "(\(existing.kind.inlineName), added \(FamilyTreeNote.shortDate(existing.addedAt)))."))
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
        // Same bytes filed before, but no document holds them any more (the
        // duplicate check above passed): re-attach that finding.
        let findingID = ResearchFinding.makeID(source: .recordFinder, url: "sha256:" + file.sha256)
        let reattach = prior?.findings.first { $0.id == findingID }
        return .success(describe(s, fields: fields, file: file, priorExisted: prior != nil, reattach: reattach))
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
                          priorExisted: Bool, reattach: ResearchFinding?) -> Prepared {
        var where_: [String] = []
        let district = s.district.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = s.recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !district.isEmpty { where_.append(district) }
        if !recordID.isEmpty { where_.append("record \(recordID)") }
        let what = s.recordType.label + (fields.year.isEmpty ? "" : " \(fields.year)")
        let place = where_.joined(separator: ", ")
        let findingTitle = "\(what) — \(fields.site)" + (place.isEmpty ? "" : " (\(place))")
        let note = "\(fields.site): \(what)" + (place.isEmpty ? "" : ", \(place)") + ". \(fields.pageURL)"
        // The excerpt is the capped display text; the WHOLE words travel in
        // `fullText` (QA P1-1).
        let excerpt = fields.transcription.isEmpty
            ? "Filed \(s.recordType.label.lowercased()) record from \(fields.site); not yet transcribed."
            : fields.transcription
        return Prepared(sha256: file.sha256, byteCount: file.byteCount, pageURL: fields.pageURL,
                        year: fields.year.isEmpty ? nil : fields.year, transcription: fields.transcription,
                        note: note, findingTitle: findingTitle, excerpt: excerpt,
                        priorExisted: priorExisted, reattach: reattach, when: now())
    }

    // MARK: Undo

    /// Undo writes 1 and 2: this filing's change comes off the dossier ON
    /// DISK (not a stale copy written back), the document goes to .trash.
    private func undoAll(pre: Prepared, findingID: String, filed: FiledDocument, wrote: FindingWrite,
                         why: String, code: String) -> Stop {
        let restored = restoreDossier(pre: pre, findingID: findingID, wrote: wrote)
        let undone = undoDocument(filed.document, folder: filed.folder, why: why)
        return Stop(outcome: combine(undone, dossier: restored), code: code)
    }

    /// How the dossier undo ended.
    enum DossierRestore: Equatable {
        /// This filing's change is off the dossier (or never landed).
        case restored
        /// The NEW finding was changed by another writer after this filing
        /// wrote it, so it was left exactly as it is now.
        case keptChangedFinding
        /// The research file could not be rewritten.
        case failed
    }

    /// Take back exactly this filing's change, under the per-key lock,
    /// from what is on disk NOW (not a stale copy written back):
    ///   • a NEW finding is removed only while it still equals exactly what
    ///     this filing wrote; changed meanwhile (lore, verdict…) it is
    ///     someone else's work and stays → `.keptChangedFinding` (codex
    ///     review 2026-10-02 F1);
    ///   • a RE-ATTACHED finding gets back, per field, the value write 2
    ///     found there — only while the field still holds the value write 2
    ///     put there (codex review #18 F3; 2026-10-02 F2: the "found" value
    ///     is captured under the same lock as the write, not at prepare()).
    /// Whatever else is on disk (another window's verdicts, a run's
    /// findings) is kept. A dossier.json this filing created is retired if
    /// it is otherwise empty (QA P3-4).
    private func restoreDossier(pre: Prepared, findingID: String, wrote: FindingWrite) -> DossierRestore {
        // Write 2 never ran (its read failed first): nothing of this
        // filing is in the file, so there is nothing to take back — and
        // the file is not touched (adversarial review 2026-10-02 F3).
        if wrote == .none { return .restored }
        let subject = self.subject
        var kept = false
        do {
            try researchStore.update(key: subject.key) { onDisk in
                guard var dossier = onDisk else { return }
                if let index = dossier.findings.firstIndex(where: { $0.id == findingID }) {
                    switch wrote {
                    case .none:
                        break
                    case .inserted(let mine):
                        if dossier.findings[index] == mine {
                            dossier.findings.remove(at: index)
                        } else {
                            kept = true
                        }
                    case .reattached(let write):
                        var found = dossier.findings[index]
                        if found.documentPath == write.documentPath.written {
                            found.documentPath = write.documentPath.previous
                        }
                        if let verdict = write.verdict, found.verdict == verdict.written {
                            found.verdict = verdict.previous
                        }
                        if let words = write.fullText, found.fullText == words.written {
                            found.fullText = words.previous
                        }
                        dossier.findings[index] = found
                    }
                }
                onDisk = (!pre.priorExisted && dossier == ResearchDossier(subject: subject)) ? nil : dossier
            }
            return kept ? .keptChangedFinding : .restored
        } catch {
            return .failed
        }
    }

    /// Move the just-filed document to Documents/.trash and drop its row.
    private func undoDocument(_ document: PersonDocument, folder: URL, why: String) -> RecordFilingOutcome {
        do {
            try assetStore.removeDocument(document, from: folder, for: assetPerson)
            return .rolledBack("\(why). The file was moved to Documents/\(FamilyAssetStore.documentsTrashFolderName)/\(document.filename).")
        } catch {
            let inPlace = FileManager.default.fileExists(
                atPath: FamilyAssetStore.documentsFolder(in: folder).appendingPathComponent(document.filename).path)
            return .mixedState(Self.undoFailureMessage(why: why, filename: document.filename,
                                                       stillInDocuments: inPlace,
                                                       error: error.localizedDescription))
        }
    }

    /// An import that wrote its file and then failed: `.rolledBack` only
    /// when the file is provably out of Documents/ and in .trash where the
    /// store said; otherwise `.mixedState`, naming where the file is.
    static func importFailureOutcome(_ failure: FamilyAssetStore.DocumentImportFailure,
                                     documentsDir: URL) -> RecordFilingOutcome {
        let fm = FileManager.default
        let why = "the archive refused the write after it began (\(failure.underlying.localizedDescription))"
        let inDocuments = fm.fileExists(atPath: documentsDir.appendingPathComponent(failure.filename).path)
        let trash = FamilyAssetStore.documentsTrashFolderName
        switch failure.rollback {
        case .movedToTrash(let destination) where !inDocuments && fm.fileExists(atPath: destination.path):
            return .rolledBack("\(why). The file was moved to Documents/\(trash)/\(destination.lastPathComponent).")
        case .leftInDocuments(let reason) where inDocuments:
            return .mixedState("\(why). The document Documents/\(failure.filename) could NOT be moved to "
                               + "Documents/\(trash) (\(reason)); it is still there but NOT listed for this person. "
                               + "Move it out in Finder before filing again.")
        default:
            return .mixedState("\(why). The document \(failure.filename) "
                               + (inDocuments ? "is still in Documents/ but NOT listed"
                                              : "is not in Documents/ or where it was expected in Documents/\(trash)")
                               + "; check that folder in Finder.")
        }
    }

    /// The words for a document undo that failed, saying where the file IS
    /// (QA P3-3: the move can succeed while the list rewrite fails).
    static func undoFailureMessage(why: String, filename: String, stillInDocuments: Bool, error: String) -> String {
        if stillInDocuments {
            return "\(why). The document \(filename) could NOT be moved to Documents/.trash (\(error)); "
                + "it is still filed for this person — remove it from the inspector."
        }
        return "\(why). The document \(filename) was moved to Documents/.trash, but documents.json could not "
            + "be rewritten (\(error)); the inspector will report it as missing and drop it from the list."
    }

    private func combine(_ outcome: RecordFilingOutcome, dossier: DossierRestore) -> RecordFilingOutcome {
        let tail: String
        switch dossier {
        case .restored:
            return outcome
        case .failed:
            tail = " The research file could not be put back: it still lists this record although its document "
                + "was removed. Filing the same file again re-attaches it."
        case .keptChangedFinding:
            tail = " The research file still lists this record: it was changed after it was filed (lore or a "
                + "verdict saved elsewhere), so it was left as it is now, although its document was removed. "
                + "Filing the same file again re-attaches it."
        }
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
