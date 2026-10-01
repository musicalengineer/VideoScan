import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// GH #230 Phase A — "I found a record" filing (a DATA-WRITE path).
//
// Every named outcome has a test, and none is reported as success:
//   filed       — unread (document + dossier) and read (+ CyberBrain, cited)
//   refused     — duplicate SHA-256, wrong magic bytes, oversized, bad URL,
//                 bad year, read-only / unavailable archive, damaged dossier,
//                 confirmed without words, confirmed without a CyberBrain
//   rolledBack  — CyberBrain write fails → document in Documents/.trash, its
//                 row gone, dossier exactly as before, no CyberBrain file
// Plus: an existing file name is never overwritten (the store's O_EXCL
// writer takes "-2"); a rolled-back file can be filed again; the log has a
// START and an OUTCOME and never the person's name, the URL or the words;
// the filer source never reaches for a GEDCOM writer.
//
// Dimensions: Logic (above) · Scale n/a (one file per action) · Media n/a
// (PDF/PNG fixtures made in-process) · Isolation (sandbox roots only, a
// poisoned dossier, an unavailable archive) · Sensor (outcome names, log
// privacy, no GEDCOM writer). Synthetic people only.

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var all: [String] { lock.withLock { stored } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private struct BrainDown: Error, LocalizedError {
    var errorDescription: String? { "disk full (simulated)" }
}

private let treeGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Honora /Fenlane/
1 SEX F
1 BIRT
2 DATE 1878
2 PLAC Skibbereen, County Cork, Ireland
1 DEAT
2 DATE 1935
1 _FSFTID ZZZZ-901
0 TRLR
"""

@Suite("Record Finder — I found a record (filing)", .serialized)
struct RecordFinderFilingTests {
    private let fm = FileManager.default
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Sandbox {
        let base: URL
        let store: FamilyAssetStore
        let research: ResearchStore
        let brain: URL
        let sources: URL
        let subject: ResearchSubject
        let person: FamilyAssetPerson
    }

    private func sandbox(access: FamilyAssetStore.Access = .readWrite, clock: Date? = nil) throws -> Sandbox {
        let base = fm.temporaryDirectory.appendingPathComponent("RecordFinderFiling-\(UUID().uuidString)", isDirectory: true)
        let sources = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        var store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
                                     access: access)
        if let clock { store.importClock = { clock } }
        let graph = GedcomFamilyGraph(gedcomText: treeGedcom)
        let record = try #require(graph.people["@I1@"])
        return Sandbox(base: base, store: store, research: ResearchStore(peopleRoot: store.peopleDirectory),
                       brain: base.appendingPathComponent("brain", isDirectory: true), sources: sources,
                       subject: ResearchSubject(person: record), person: FamilyAssetPerson(record))
    }

    /// A small valid PDF; `width` varies the bytes so two files differ.
    private func pdf(width: CGFloat = 200) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: 300)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: width / 2, height: 20))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func write(_ data: Data, _ name: String, in sb: Sandbox) throws -> URL {
        let url = sb.sources.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func submission(_ file: URL, read: Bool = false, url: String = "https://www.irishgenealogy.ie/view?record_id=TEST123",
                            year: String = "1878", words: String = "") -> FoundRecordSubmission {
        FoundRecordSubmission(file: file, siteID: "ie.irishgenealogy.civil-church",
                              siteTitle: "irishgenealogy.ie", recordType: .birth, year: year,
                              district: "Skibbereen", recordID: "TEST123", pageURL: url,
                              transcription: words, confirmedRead: read)
    }

    private func filer(_ sb: Sandbox, lines: Lines = Lines(),
                       record: (@Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt)?? = nil,
                       calls: Counter = Counter()) -> RecordFinderFiler {
        let brain = sb.brain
        let defaultRecord: @Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt = { t in
            calls.bump()
            return try CyberBrainWriter.record(t, rootURL: brain)
        }
        let now = fixedNow
        return RecordFinderFiler(assetStore: sb.store, assetPerson: sb.person, researchStore: sb.research,
                                 subject: sb.subject, speakerName: "Tester",
                                 record: record ?? defaultRecord,
                                 log: { lines.add($0) }, now: { now })
    }

    private func brainFile(_ sb: Sandbox) -> URL {
        sb.brain.appendingPathComponent(CyberBrainLoader.defaultFilename)
    }

    // MARK: filed

    @Test func anUnreadRecordIsFiledButHallieIsNotTold() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let lines = Lines(), calls = Counter()
        let file = try write(try pdf(), "downloaded.pdf", in: sb)
        let outcome = await filer(sb, lines: lines, calls: calls).file(submission(file))
        guard case .filed(let filename, let findingID, let told) = outcome else {
            Issue.record("expected filed, got \(outcome)"); return
        }
        #expect(told == nil)
        #expect(calls.value == 0, "unread → the CyberBrain is not written")
        #expect(!fm.fileExists(atPath: brainFile(sb).path))
        let docs = sb.store.documents(for: sb.person)
        try #require(docs.count == 1)
        #expect(docs[0].filename == filename)
        #expect(docs[0].kind == .birth)
        #expect(docs[0].note.contains("irishgenealogy.ie: Civil birth 1878, Skibbereen, record TEST123"))
        let dossier = try #require(try sb.research.loadDossier(key: sb.subject.key))
        let finding = try #require(dossier.findings.first { $0.id == findingID })
        #expect(finding.source == .recordFinder)
        #expect(finding.verdict == .unreviewed)
        #expect(finding.url == "https://www.irishgenealogy.ie/view?record_id=TEST123")
        #expect(finding.documentPath?.hasPrefix("People/") == true)
        #expect(finding.documentPath?.hasSuffix("/Documents/\(filename)") == true)
        #expect(lines.all.first?.hasPrefix("[record-finder] START") == true)
        #expect(lines.all.last?.hasPrefix("[record-finder] OUTCOME filed") == true)
    }

    @Test func aReadRecordIsToldToHallieWithItsCitation() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let calls = Counter()
        let file = try write(try pdf(), "cert.pdf", in: sb)
        let words = "Born 1878 at Skibbereen to a labourer and his wife (synthetic test words)."
        let outcome = await filer(sb, calls: calls).file(submission(file, read: true, words: words))
        guard case .filed(_, let findingID, let told?) = outcome else {
            Issue.record("expected filed and told, got \(outcome)"); return
        }
        #expect(calls.value == 1)
        let archive = try CyberBrainLoader(rootURL: sb.brain).load()
        let person = try #require(archive.people.first)
        #expect(person.gedcomPersonID == "@I1@")
        let item = try #require(person.lifeEvents.first { $0.id == told })
        #expect(item.text == words)
        #expect(item.confidence == .confirmed)
        let source = try #require(archive.sources.first { item.sourceIDs.contains($0.id) })
        #expect(source.type == .officialRecord)
        #expect(CyberBrainWriter.researchURL(of: source) == "https://www.irishgenealogy.ie/view?record_id=TEST123")
        let dossier = try #require(try sb.research.loadDossier(key: sb.subject.key))
        let finding = try #require(dossier.findings.first { $0.id == findingID })
        #expect(finding.verdict == .confirmed)
        #expect(finding.toldItemID == told)
        #expect(source.locator == finding.documentPath, "the citation points at the filed document")
        #expect(source.notes?.contains("retrieved") == true)
    }

    // MARK: refused — nothing written

    @Test func theSameFileTwiceIsRefused() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let bytes = try pdf()
        let first = try write(bytes, "a.pdf", in: sb)
        let second = try write(bytes, "renamed copy.pdf", in: sb)
        #expect(await filer(sb).file(submission(first)).isSuccess)
        let before = try sb.research.loadDossier(key: sb.subject.key)
        let outcome = await filer(sb).file(submission(second, url: "https://www.irishgenealogy.ie/view?record_id=OTHER"))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("already filed"))
        #expect(sb.store.documents(for: sb.person).count == 1)
        #expect(try sb.research.loadDossier(key: sb.subject.key) == before)
    }

    /// The SHA-256 check covers documents filed by ANY route — here the
    /// plain "Add document…" import, which leaves no research finding, so
    /// only the document-level check can say no.
    @Test func aFileAlreadyAddedAsADocumentIsRefused() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let bytes = try pdf(width: 321)
        let added = try write(bytes, "added-by-hand.pdf", in: sb)
        let folder = try sb.store.folderForPhotoRequest(person: sb.person)
        _ = try sb.store.importPersonDocument(from: added, kind: .birth, note: "", into: folder, for: sb.person)
        let again = try write(bytes, "downloaded-again.pdf", in: sb)
        let outcome = await filer(sb).file(submission(again))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("already filed") && why.contains("BC-"), "names the existing document: \(why)")
        #expect(sb.store.documents(for: sb.person).count == 1)
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil, "nothing written to the research file")
    }

    @Test func wrongMagicBytesAreRefusedBeforeAnyFolderIsMade() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let fake = try write(Data("This is text, not a PDF.".utf8), "record.pdf", in: sb)
        let pngLie = try write(try pdf(), "record.png", in: sb)
        for file in [fake, pngLie] {
            let outcome = await filer(sb).file(submission(file))
            guard case .refused = outcome else { Issue.record("expected refused for \(file.lastPathComponent), got \(outcome)"); continue }
        }
        let people = (try? fm.contentsOfDirectory(atPath: sb.store.peopleDirectory.path)) ?? []
        #expect(people.isEmpty, "refusals come before the person folder is created: \(people)")
    }

    @Test func anOversizedFileIsRefusedWithoutBeingRead() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let big = sb.sources.appendingPathComponent("huge.pdf")
        #expect(fm.createFile(atPath: big.path, contents: Data("%PDF-1.7\n".utf8)))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FamilyAssetStore.maxImportBytes + 1))   // sparse
        try handle.close()
        let start = Date()
        let outcome = await filer(sb).file(submission(big))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("MB"))
        #expect(Date().timeIntervalSince(start) < 2, "the size is checked before any byte is read")
        #expect(sb.store.documents(for: sb.person).isEmpty)
    }

    @Test func badFieldsAreRefused() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let file = try write(try pdf(), "r.pdf", in: sb)
        let cases: [FoundRecordSubmission] = [
            submission(file, url: "not a url"),
            submission(file, url: "file:///etc/passwd"),
            submission(file, year: "19x4"),
            submission(file, year: "2999"),
            submission(file, read: true, words: "   "),
            FoundRecordSubmission(file: file, siteID: nil, siteTitle: "  ", recordType: .other, year: "",
                                  district: "", recordID: "", pageURL: "https://example.invalid/r",
                                  transcription: "", confirmedRead: false),
        ]
        for s in cases {
            let outcome = await filer(sb).file(s)
            guard case .refused = outcome else { Issue.record("expected refused for \(s), got \(outcome)"); continue }
        }
        #expect(sb.store.documents(for: sb.person).isEmpty)
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil)
    }

    @Test func confirmedWithoutACyberBrainIsRefused() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let file = try write(try pdf(), "r.pdf", in: sb)
        let noBrain: (@Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt)? = nil
        let outcome = await filer(sb, record: .some(noBrain)).file(submission(file, read: true, words: "Words."))
        guard case .refused = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(sb.store.documents(for: sb.person).isEmpty)
        // Unread, the same filing is fine without a CyberBrain.
        #expect(await filer(sb, record: .some(noBrain)).file(submission(file)).isSuccess)
    }

    @Test func aReadOnlyOrUnavailableArchiveIsRefused() async throws {
        for access in [FamilyAssetStore.Access.readOnly, .unavailable] {
            let sb = try sandbox(access: access)
            defer { try? fm.removeItem(at: sb.base) }
            let file = try write(try pdf(), "r.pdf", in: sb)
            let outcome = await filer(sb).file(submission(file, read: true, words: "Words."))
            guard case .refused = outcome else { Issue.record("expected refused for \(access), got \(outcome)"); continue }
            #expect(!fm.fileExists(atPath: sb.store.peopleDirectory.path), "\(access): nothing created")
            #expect(!fm.fileExists(atPath: brainFile(sb).path))
        }
    }

    @Test func aDamagedDossierIsRefusedAndLeftExactlyAsItWas() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let dossierURL = try sb.research.dossierURL(key: sb.subject.key)
        try fm.createDirectory(at: dossierURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let poison = Data("{ this is not a dossier".utf8)
        try poison.write(to: dossierURL)
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb).file(submission(file))
        guard case .refused = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(try Data(contentsOf: dossierURL) == poison, "a damaged research file is never replaced")
        #expect(sb.store.documents(for: sb.person).isEmpty)
    }

    // MARK: never overwrite

    @Test func anExistingFileNameIsNeverOverwritten() async throws {
        let sb = try sandbox(clock: fixedNow)
        defer { try? fm.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: sb.person)
        let documents = FamilyAssetStore.documentsFolder(in: folder)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let squatter = documents.appendingPathComponent("BC-\(f.string(from: fixedNow)).pdf")
        let original = Data("someone else's bytes".utf8)
        try original.write(to: squatter)
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb).file(submission(file))
        guard case .filed(let filename, _, _) = outcome else { Issue.record("expected filed, got \(outcome)"); return }
        #expect(filename == "BC-\(f.string(from: fixedNow))-2.pdf")
        #expect(try Data(contentsOf: squatter) == original, "the existing file is untouched")
    }

    // MARK: rolledBack — no half-state

    @Test func aCyberBrainFailureLeavesNoHalfState() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        // A prior dossier with one search finding must come back exactly.
        var prior = ResearchDossier(subject: sb.subject)
        prior.merge(fresh: [ResearchFinding(source: .chroniclingAmerica, title: "p", date: nil, excerpt: "e",
                                            url: "https://example.invalid/p", retrievedAt: fixedNow)], at: fixedNow)
        try sb.research.saveDossier(prior)
        let lines = Lines()
        let failing: @Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt = { _ in throw BrainDown() }
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb, lines: lines, record: .some(failing)).file(submission(file, read: true, words: "Words."))
        guard case .rolledBack(let why) = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }
        #expect(!outcome.isSuccess)
        #expect(why.contains("disk full"))
        #expect(why.contains(".trash"))
        // The document: off the list, file in Documents/.trash, not deleted.
        #expect(sb.store.documents(for: sb.person).isEmpty)
        let folder = try #require(sb.store.personFolders(for: sb.person).first)
        let trash = FamilyAssetStore.documentsFolder(in: folder)
            .appendingPathComponent(FamilyAssetStore.documentsTrashFolderName)
        let trashed = try fm.contentsOfDirectory(atPath: trash.path)
        #expect(trashed.count == 1 && trashed[0].hasPrefix("BC-"))
        // The dossier: exactly as before. The CyberBrain: never created.
        #expect(try sb.research.loadDossier(key: sb.subject.key) == prior)
        #expect(!fm.fileExists(atPath: brainFile(sb).path))
        #expect(lines.all.last?.contains("OUTCOME rolledBack (cyberbrain-failed)") == true)
        // And the same file can be filed again once the brain is back.
        #expect(await filer(sb).file(submission(file, read: true, words: "Words.")).isSuccess)
    }

    /// QA P3-4: with no prior research file, a rollback leaves no
    /// dossier.json at all (it used to leave an empty one).
    @Test func aCyberBrainFailureWithNoPriorDossierLeavesNoDossierFile() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let failing: @Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt = { _ in throw BrainDown() }
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb, record: .some(failing)).file(submission(file, read: true, words: "Words."))
        guard case .rolledBack = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil, "no research file is left behind")
    }

    // MARK: sensors

    @Test func theLogNeverCarriesTheNameTheURLOrTheWords() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let lines = Lines()
        let words = "SECRET-TRANSCRIPTION-WORDS"
        let file = try write(try pdf(), "r.pdf", in: sb)
        _ = await filer(sb, lines: lines).file(submission(file, read: true, words: words))
        _ = await filer(sb, lines: lines).file(submission(file, read: true, words: words))   // refused duplicate
        let text = lines.all.joined(separator: "\n")
        #expect(lines.all.count == 4, "START + OUTCOME per filing: \(lines.all)")
        for secret in ["Honora", "Fenlane", "irishgenealogy.ie/view", "TEST123", words] {
            #expect(!text.contains(secret), "log leaked \(secret)")
        }
        #expect(text.contains(sb.subject.key))
    }

    @Test func outcomesAreNamedAndOnlyFiledIsSuccess() {
        #expect(RecordFilingOutcome.filed(documentFilename: "a", findingID: "b", toldItemID: nil).isSuccess)
        #expect(!RecordFilingOutcome.refused("x").isSuccess)
        #expect(!RecordFilingOutcome.rolledBack("x").isSuccess)
        #expect(!RecordFilingOutcome.mixedState("x").isSuccess)
        #expect(FoundRecordType.census.documentKind == .other)
        #expect(FoundRecordType.marriage.documentKind == .marriage)
        #expect(FoundRecordType.baptism.documentKind == .other, "a baptism entry is not a birth certificate")
    }

    // MARK: QA 2026-10-01

    /// P3-3: a failed document undo says where the file actually is.
    @Test func aFailedUndoSaysWhereTheFileIs() {
        let stuck = RecordFinderFiler.undoFailureMessage(why: "W", filename: "BC-1.pdf", stillInDocuments: true, error: "E")
        #expect(stuck.contains("could NOT be moved") && stuck.contains("still filed"))
        let moved = RecordFinderFiler.undoFailureMessage(why: "W", filename: "BC-1.pdf", stillInDocuments: false, error: "E")
        #expect(moved.contains("was moved to Documents/.trash") && moved.contains("documents.json could not"))
        #expect(!moved.contains("could NOT be moved"))
    }

    /// P1-1: an 8,000-character limit at the door and a 600-character cut
    /// inside meant Hallie got a truncated "confirmed" fact.
    @Test func aLongTranscriptionReachesHallieWhole() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let words = String(repeating: "Synthetic register line, witnesses named. ", count: 50)
            .trimmingCharacters(in: .whitespaces)
        #expect(words.count > ResearchFinding.maxExcerptLength)
        let file = try write(try pdf(), "long.pdf", in: sb)
        let outcome = await filer(sb).file(submission(file, read: true, words: words))
        guard case .filed(_, let findingID, let told?) = outcome else { Issue.record("got \(outcome)"); return }
        let archive = try CyberBrainLoader(rootURL: sb.brain).load()
        let item = try #require(archive.people.flatMap(\.lifeEvents).first { $0.id == told })
        #expect(item.text == words, "Hallie must get every word Rick typed")
        let finding = try #require(try sb.research.loadDossier(key: sb.subject.key)?.findings.first { $0.id == findingID })
        #expect(finding.attestationText == words)
    }

    /// P2-1: an open Research pane saved its whole in-memory dossier and
    /// erased a record filed after it loaded.
    @MainActor
    @Test func anOpenResearchPaneDoesNotEraseARecordFiledMeanwhile() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        var prior = ResearchDossier(subject: sb.subject)
        let search = ResearchFinding(source: .chroniclingAmerica, title: "p", date: nil, excerpt: "e",
                                     url: "https://example.invalid/p", retrievedAt: fixedNow)
        prior.merge(fresh: [search], at: fixedNow)
        try sb.research.saveDossier(prior)
        let pane = ResearchPersonModel(subject: sb.subject, store: sb.research,
                                       fetcher: FixtureResearchFetcher(fixtures: [], retrievedAt: fixedNow),
                                       speakerName: "Tester", record: { _ in throw BrainDown() })
        pane.load()
        let file = try write(try pdf(), "r.pdf", in: sb)
        guard case .filed(_, let findingID, _) = await filer(sb).file(submission(file)) else {
            Issue.record("filing failed"); return
        }
        pane.setVerdict(.plausible, for: search.id)        // the pane saves
        let onDisk = try #require(try sb.research.loadDossier(key: sb.subject.key))
        #expect(onDisk.findings.contains { $0.id == findingID }, "the filed record survived the pane's save")
        #expect(onDisk.findings.first { $0.id == search.id }?.verdict == .plausible)
        #expect(pane.findings.contains { $0.id == findingID }, "the pane now shows it too")
    }

    /// P2-2: confirming an untranscribed filed record in Research must not
    /// send the placeholder to Hallie as a confirmed fact.
    @Test func confirmingAnUntranscribedFiledRecordInResearchDoesNotTellHallieThePlaceholder() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let file = try write(try pdf(), "r.pdf", in: sb)
        guard case .filed(_, let findingID, _) = await filer(sb).file(submission(file)) else {
            Issue.record("filing failed"); return
        }
        var finding = try #require(try sb.research.loadDossier(key: sb.subject.key)?.findings.first { $0.id == findingID })
        finding.verdict = .confirmed
        #expect(throws: ResearchAttestation.AttestationError.self) {
            try ResearchAttestation.testimony(for: finding, subject: sb.subject, speakerName: "Tester", date: fixedNow)
        }
        finding.lore = "Rick's own words after reading it."
        let testimony = try ResearchAttestation.testimony(for: finding, subject: sb.subject,
                                                          speakerName: "Tester", date: fixedNow)
        #expect(testimony.text == "Rick's own words after reading it.")
    }

    /// P2-3: a record removed in the inspector could never be filed again.
    @Test func aRecordRemovedInTheInspectorCanBeFiledAgain() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let calls = Counter()
        let file = try write(try pdf(), "r.pdf", in: sb)
        guard case .filed(_, let findingID, let told?) = await filer(sb, calls: calls)
            .file(submission(file, read: true, words: "Words.")) else { Issue.record("filing failed"); return }
        let filed = try #require(sb.store.documents(for: sb.person).first)
        try sb.store.removeDocument(filed, for: sb.person)
        #expect(sb.store.documents(for: sb.person).isEmpty)

        let again = await filer(sb, calls: calls).file(submission(file, read: true, words: "Words."))
        guard case .filed(let newName, let againID, let againTold) = again else { Issue.record("got \(again)"); return }
        #expect(againID == findingID, "the same finding, re-attached")
        #expect(againTold == told, "Hallie was already told; she is not told twice")
        #expect(calls.value == 1)
        let dossier = try #require(try sb.research.loadDossier(key: sb.subject.key))
        #expect(dossier.findings.filter { $0.source == .recordFinder }.count == 1)
        let finding = try #require(dossier.findings.first { $0.id == findingID })
        #expect(finding.documentPath?.hasSuffix("/Documents/\(newName)") == true)
        #expect(finding.verdict == .confirmed && finding.toldItemID == told)
        #expect(sb.store.documents(for: sb.person).count == 1)
    }

    /// P3-2: an unreadable documents.json in the person's folder is refused
    /// BEFORE anything is written (it used to write, then trash the file).
    @Test func anUnreadableDocumentListIsRefusedBeforeAnyWrite() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let folder = try sb.store.folderForPhotoRequest(person: sb.person)
        let documents = FamilyAssetStore.documentsFolder(in: folder)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let sidecar = documents.appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        let garbage = Data("[{ damaged".utf8)
        try garbage.write(to: sidecar)
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb).file(submission(file))
        guard case .refused = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(try Data(contentsOf: sidecar) == garbage)
        #expect(!fm.fileExists(atPath: documents.appendingPathComponent(FamilyAssetStore.documentsTrashFolderName).path),
                "nothing was written, so nothing was trashed")
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil)
    }

    // MARK: Codex review #18 (2026-10-01)

    /// F2: a pane's untouched lore draft went stale when another pane saved
    /// newer lore, and Tell Hallie auto-committed the stale draft over it.
    @MainActor
    @Test func aStaleLoreDraftNeverOverwritesNewerLore() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        var prior = ResearchDossier(subject: sb.subject)
        let search = ResearchFinding(source: .chroniclingAmerica, title: "p", date: nil, excerpt: "e",
                                     url: "https://example.invalid/p", retrievedAt: fixedNow)
        prior.merge(fresh: [search], at: fixedNow)
        prior.setLore("original", for: search.id)
        try sb.research.saveDossier(prior)
        let a = pane(sb), b = pane(sb)
        a.load()
        b.load()
        b.editLore("revised", for: search.id)               // pane B: a real edit, committed
        b.commitLore(for: search.id)
        a.setVerdict(.confirmed, for: search.id)            // pane A never touched the lore
        #expect(a.loreDrafts[search.id] == "revised", "an untouched draft follows the disk")
        #expect(a.tellHallie() == 1)
        let onDisk = try #require(try sb.research.loadDossier(key: sb.subject.key))
        #expect(onDisk.findings.first { $0.id == search.id }?.lore == "revised", "B's newer lore survives A")
        let told = try CyberBrainLoader(rootURL: sb.brain).load().people.flatMap(\.lifeEvents)
        #expect(told.map(\.text) == ["revised"], "Hallie is told the current lore")
    }

    /// F2, the other side: a draft the user DID edit is still committed by
    /// Tell Hallie (that is what the auto-commit is for).
    @MainActor
    @Test func anEditedLoreDraftIsCommittedByTellHallie() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        var prior = ResearchDossier(subject: sb.subject)
        let search = ResearchFinding(source: .chroniclingAmerica, title: "p", date: nil, excerpt: "e",
                                     url: "https://example.invalid/p", retrievedAt: fixedNow)
        prior.merge(fresh: [search], at: fixedNow)
        prior.setVerdict(.confirmed, for: search.id)
        try sb.research.saveDossier(prior)
        let a = pane(sb)
        a.load()
        a.editLore("typed but never submitted", for: search.id)
        #expect(a.tellHallie() == 1)
        let onDisk = try #require(try sb.research.loadDossier(key: sb.subject.key))
        #expect(onDisk.findings.first { $0.id == search.id }?.lore == "typed but never submitted")
    }

    /// F3 (codex's drafted red test): the re-attach rollback restored the
    /// preparation snapshot's verdict over a verdict saved after filing
    /// began. It must take back only what THIS transaction wrote.
    @Test func reattachRollbackPreservesANewerVerdict() async throws {
        let sb = try sandbox()
        defer { try? fm.removeItem(at: sb.base) }
        let file = try write(try pdf(), "record.pdf", in: sb)

        guard case .filed(_, let id, _) = await filer(sb).file(submission(file)) else {
            Issue.record("initial filing failed")
            return
        }
        let firstPath = try #require(try sb.research.loadDossier(key: sb.subject.key)?.findings.first { $0.id == id }?.documentPath)
        let document = try #require(sb.store.documents(for: sb.person).first)
        try sb.store.removeDocument(document, for: sb.person)

        let research = sb.research, key = sb.subject.key
        let failing: @Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt = { _ in
            try research.update(key: key) { $0?.setVerdict(.wrong, for: id) }
            throw BrainDown()
        }
        let outcome = await filer(sb, record: .some(failing))
            .file(submission(file, read: true, words: "Synthetic passage."))
        guard case .rolledBack = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }

        let back = try #require(try sb.research.loadDossier(key: sb.subject.key))
        let finding = try #require(back.findings.first { $0.id == id })
        #expect(finding.verdict == .wrong, "the verdict saved meanwhile is not this filing's to undo")
        #expect(finding.fullText == nil, "the words this filing wrote are taken back")
        #expect(finding.documentPath == firstPath, "the document path this filing wrote is taken back")
    }

    /// A store whose import clock damages documents.json AFTER both filer
    /// prechecks pass (the import calls it after validating the bytes,
    /// before writing). Optionally a regular FILE squats on `.trash`.
    private func damagedListDuringImport(_ sb: Sandbox, blockTrash: Bool) throws -> (Sandbox, URL) {
        var store = sb.store
        let folder = try store.folderForPhotoRequest(person: sb.person)
        let documents = FamilyAssetStore.documentsFolder(in: folder)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        if blockTrash {
            try Data("not a folder".utf8).write(to: documents.appendingPathComponent(FamilyAssetStore.documentsTrashFolderName))
        }
        let sidecar = documents.appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        let fired = Counter()
        let now = fixedNow
        store.importClock = {
            if fired.value == 0 {
                fired.bump()
                try? Data("[{ damaged".utf8).write(to: sidecar)
            }
            return now
        }
        return (Sandbox(base: sb.base, store: store, research: sb.research, brain: sb.brain,
                        sources: sb.sources, subject: sb.subject, person: sb.person), documents)
    }

    private func pdfs(in directory: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
    }

    /// F4: the import wrote the PDF, found the list damaged, moved the PDF
    /// to .trash and threw — and the filer said "refused" (nothing written).
    @Test func aListDamagedDuringImportIsRolledBackWithTheFileInTrash() async throws {
        let (sb, documents) = try damagedListDuringImport(try sandbox(), blockTrash: false)
        defer { try? fm.removeItem(at: sb.base) }
        let lines = Lines()
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb, lines: lines).file(submission(file))
        guard case .rolledBack(let why) = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }
        let trashed = pdfs(in: documents.appendingPathComponent(FamilyAssetStore.documentsTrashFolderName))
        #expect(trashed.count == 1)
        #expect(pdfs(in: documents).isEmpty, "nothing is left in Documents/")
        if let name = trashed.first { #expect(why.contains(".trash/\(name)"), "says where the file went: \(why)") }
        #expect(try Data(contentsOf: documents.appendingPathComponent(FamilyAssetStore.documentsSidecarName))
                == Data("[{ damaged".utf8), "the damaged list is never rewritten")
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil)
        #expect(lines.all.last?.contains("OUTCOME rolledBack") == true)
    }

    /// F4: same, but the move to .trash fails — the PDF is left in
    /// Documents/, unlisted. That is a mixed state, and it says where.
    @Test func aListDamagedDuringImportWithTrashBlockedIsMixedStateAndNamesTheFile() async throws {
        let (sb, documents) = try damagedListDuringImport(try sandbox(), blockTrash: true)
        defer { try? fm.removeItem(at: sb.base) }
        let file = try write(try pdf(), "r.pdf", in: sb)
        let outcome = await filer(sb).file(submission(file))
        guard case .mixedState(let why) = outcome else { Issue.record("expected mixedState, got \(outcome)"); return }
        let left = pdfs(in: documents)
        #expect(left.count == 1, "the file really is still in Documents/")
        if let name = left.first { #expect(why.contains("Documents/\(name)"), "says where the file is: \(why)") }
        #expect(try sb.research.loadDossier(key: sb.subject.key) == nil)
    }

    @MainActor
    private func pane(_ sb: Sandbox) -> ResearchPersonModel {
        let brain = sb.brain
        let now = fixedNow
        return ResearchPersonModel(subject: sb.subject, store: sb.research,
                                   fetcher: FixtureResearchFetcher(fixtures: [], retrievedAt: now),
                                   speakerName: "Tester",
                                   record: { try CyberBrainWriter.record($0, rootURL: brain) },
                                   now: { now })
    }

    @Test func theFilerNeverReachesForTheGEDCOM() async throws {
        let text = try SourceTree.appSource(named: "RecordFinderFiling.swift")
        for forbidden in ["GedcomWriter", "GEDCOMWriter", "FamilyTreeGedcomWriter", ".ged\"", "PersonFactOverlayStore"] {
            #expect(!text.contains(forbidden), "the bring-back must not touch \(forbidden)")
        }
    }
}
