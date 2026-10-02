// AdversarialReview20261001Tests.swift
// Red tests drafted by the first nightly adversarial review (2026-10-01,
// range 9ed39299..05c2b9a5), run red first, then kept as regression pins.
//   61c81eab  two records from one page each cite their own document
//   86953af8  re-filing tells Hallie what the sheet says
//   31bd2de8  the filer's OUTCOME line never carries the name, in any case
// Synthetic people only (public repo).

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private enum AdvFixture {
    static let gedcom = """
    0 HEAD
    1 SOUR AdvReview
    0 @I1@ INDI
    1 NAME Synthia /Testcase/
    1 SEX F
    1 BIRT
    2 DATE 1878
    2 PLAC Synthtown, Testshire, Ireland
    1 _FSFTID ZZZZ-902
    0 TRLR
    """

    static func pdf(width: CGFloat) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: 300)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: width / 2, height: 20))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

private final class AdvLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var all: [String] { lock.withLock { stored } }
}

// MARK: - 61c81eab

@Suite(.serialized) struct AdvFiledRecordSourceTests {
    @Test func twoRecordsFromOnePageEachCiteTheirOwnDocument() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AdvF1-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let record = try #require(GedcomFamilyGraph(gedcomText: AdvFixture.gedcom).people["@I1@"])
        let research = ResearchStore(peopleRoot: store.peopleDirectory)
        let subject = ResearchSubject(person: record)
        let brain = base.appendingPathComponent("brain", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let filer = RecordFinderFiler(
            assetStore: store, assetPerson: FamilyAssetPerson(record), researchStore: research,
            subject: subject, speakerName: "Tester",
            record: { try CyberBrainWriter.record($0, rootURL: brain) },
            log: { _ in }, now: { now })
        let page = "https://records.example.invalid/results?q=synthetic"
        func submit(_ name: String, width: CGFloat, _ type: FoundRecordType, _ year: String,
                    _ words: String) throws -> FoundRecordSubmission {
            let file = downloads.appendingPathComponent(name)
            try AdvFixture.pdf(width: width).write(to: file)
            return FoundRecordSubmission(file: file, siteID: nil, siteTitle: "Example Records",
                                         recordType: type, year: year, district: "Synthtown",
                                         recordID: "", pageURL: page, transcription: words,
                                         confirmedRead: true)
        }
        let birth = try submit("birth.pdf", width: 200, .birth, "1878", "Born 1878 in Synthtown (synthetic).")
        let marriage = try submit("marriage.pdf", width: 260, .marriage, "1900", "Married 1900 in Synthtown (synthetic).")
        guard case .filed(_, _, let birthItem?) = await filer.file(birth) else {
            Issue.record("first filing failed"); return
        }
        guard case .filed(_, let marriageID, let marriageItem?) = await filer.file(marriage) else {
            Issue.record("second filing failed"); return
        }
        #expect(birthItem != marriageItem)
        let dossier = try #require(try research.loadDossier(key: subject.key))
        let finding = try #require(dossier.findings.first(where: { $0.id == marriageID }))
        let archive = try CyberBrainLoader(rootURL: brain).load()
        let item = try #require(archive.people.flatMap(\.items).first(where: { $0.id == marriageItem }))
        let source = try #require(archive.sources.first(where: { item.sourceIDs.contains($0.id) }))
        #expect(source.locator == finding.documentPath,
                "the marriage passage cites \(source.locator ?? "nil") instead of its own document")
        #expect(source.title.contains("Marriage"), "cited as: \(source.title)")
        // The birth passage still cites the birth document.
        let birthEntry = try #require(archive.people.flatMap(\.items).first(where: { $0.id == birthItem }))
        let birthSource = try #require(archive.sources.first(where: { birthEntry.sourceIDs.contains($0.id) }))
        #expect(birthSource.title.contains("Civil birth"), "cited as: \(birthSource.title)")
        #expect(birthSource.id != source.id)
        // The page URL is still readable from both (Hallie's "from research").
        #expect(CyberBrainWriter.researchURL(of: source) == page)
        #expect(CyberBrainWriter.researchURL(of: birthSource) == page)
    }
}

// MARK: - 86953af8

@Suite(.serialized) struct AdvReattachTellsTheSubmissionTests {
    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CyberBrainWriter.Testimony] = []
        func add(_ t: CyberBrainWriter.Testimony) { lock.withLock { items.append(t) } }
        var last: CyberBrainWriter.Testimony? { lock.withLock { items.last } }
    }

    @Test func reFilingToCorrectTheRecordTellsHallieWhatTheSheetSays() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AdvF2-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let record = try #require(GedcomFamilyGraph(gedcomText: AdvFixture.gedcom).people["@I1@"])
        let person = FamilyAssetPerson(record)
        let research = ResearchStore(peopleRoot: store.peopleDirectory)
        let subject = ResearchSubject(person: record)
        let brain = base.appendingPathComponent("brain", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let told = Told()
        let filer = RecordFinderFiler(
            assetStore: store, assetPerson: person, researchStore: research,
            subject: subject, speakerName: "Tester",
            record: { t in told.add(t); return try CyberBrainWriter.record(t, rootURL: brain) },
            log: { _ in }, now: { now })
        let file = downloads.appendingPathComponent("record.pdf")
        try AdvFixture.pdf(width: 200).write(to: file)
        func submission(_ type: FoundRecordType, _ year: String, _ words: String, read: Bool) -> FoundRecordSubmission {
            FoundRecordSubmission(file: file, siteID: nil, siteTitle: "Example Records", recordType: type,
                                  year: year, district: "", recordID: "",
                                  pageURL: "https://records.example.invalid/view?id=42",
                                  transcription: words, confirmedRead: read)
        }
        // 1. Filed unread under the default type and a mistyped year.
        guard case .filed(_, let findingID, _) = await filer.file(submission(.birth, "1877", "", read: false)) else {
            Issue.record("first filing failed"); return
        }
        // 2. A working note typed in the Research pane while it was unread.
        try research.update(key: subject.key) { $0?.setLore("Unsure this is her (synthetic note).", for: findingID) }
        // 3. Removed in the inspector, filed again as what it really is, read.
        let document = try #require(store.documents(for: person).first)
        try store.removeDocument(document, for: person)
        let words = "Baptised 1878 in Synthtown (synthetic)."
        guard case .filed(_, let againID, _?) = await filer.file(submission(.baptism, "1878", words, read: true)) else {
            Issue.record("re-filing failed"); return
        }
        #expect(againID == findingID, "re-attached")
        let testimony = try #require(told.last)
        #expect(testimony.text == words, "Hallie was told: \(testimony.text)")
        #expect(testimony.citation?.title.contains("Baptism") == true,
                "cited as: \(testimony.citation?.title ?? "nil")")
        #expect(testimony.citation?.sourceDate == "1878")
        // The lore stays in the dossier (it is Rick's), it just isn't told as the record.
        let dossier = try #require(try research.loadDossier(key: subject.key))
        #expect(dossier.findings.first(where: { $0.id == findingID })?.lore == "Unsure this is her (synthetic note).")
    }
}

// MARK: - 31bd2de8

@Suite(.serialized) struct AdvFilerLogNameTests {
    @Test func theOutcomeLineNeverCarriesTheNameInAnyCase() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AdvF3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let record = try #require(GedcomFamilyGraph(gedcomText: AdvFixture.gedcom).people["@I1@"])
        let brain = base.appendingPathComponent("brain", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let lines = AdvLines()
        let subject = ResearchSubject(person: record)
        let filer = RecordFinderFiler(
            assetStore: store, assetPerson: FamilyAssetPerson(record),
            researchStore: ResearchStore(peopleRoot: store.peopleDirectory),
            subject: subject, speakerName: "Tester",
            record: { try CyberBrainWriter.record($0, rootURL: brain) },
            log: { lines.add($0) }, now: { now })
        let file = downloads.appendingPathComponent("r.pdf")
        try AdvFixture.pdf(width: 200).write(to: file)
        let outcome = await filer.file(FoundRecordSubmission(
            file: file, siteID: nil, siteTitle: "Example Records", recordType: .birth, year: "1878",
            district: "", recordID: "", pageURL: "https://records.example.invalid/view?id=42",
            transcription: "Born 1878 (synthetic).", confirmedRead: true))
        guard case .filed(_, _, _?) = outcome else { Issue.record("expected filed and told, got \(outcome)"); return }
        let text = lines.all.joined(separator: "\n").lowercased()
        #expect(!text.contains("synthia"), "log: \(text)")
        #expect(!text.contains("testcase"), "log: \(text)")
        #expect(text.contains(subject.key.lowercased()), "the key names the subject: \(text)")
    }
}
