// FamilyTreeDocumentsPanelTests.swift
// The inspector's Documents panel as a person-records list (Rick,
// 2026-10-01): grouping by kind, the year and source site of a document
// filed through Record Finder, the confirmed-findings count, and the
// research read staying off the view body.
//
// Dimensions (docs/testing_retrospective_2026_07_05.md):
//   Logic     — group order, newest-first inside a group, empty groups
//               dropped; year/site only from the matching Record Finder
//               finding (a hand-added document gets neither; a note that
//               names another site is not trusted); confirmed count
//   Scale     — 500 rows × 500 findings derived under a budget
//   Media     — N/A (no media is opened; URLs only)
//   Isolation — dossiers live in a temp People root; a missing or damaged
//               dossier gives the empty result, never an error
//   Sensor    — the panel reads the dossier only inside Task.detached
// Synthetic people only (public repo).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let panelGedcom = """
0 HEAD
0 @I1@ INDI
1 NAME Synthetic /Testperson/
1 SEX F
1 BIRT
2 DATE 1861
1 DEAT
2 DATE 1930
1 _FSFTID TEST-123
0 TRLR
"""

@Suite("Family documents — panel")
struct FamilyTreeDocumentsPanelTests {

    private let owner = FamilyAssetPerson(gedcomID: "@I1@", name: "Synthetic Testperson",
                                          birthYear: 1861, familySearchID: "TEST-123")
    private let folderName = "Synthetic_Testperson_b1861_TEST-123"

    private func row(_ kind: PersonDocumentKind, _ file: String, added: TimeInterval,
                     note: String = "", root: URL = URL(fileURLWithPath: "/tmp/panel-tests/40_Family_Tree")) -> PersonDocumentRow {
        var document = PersonDocument(id: UUID(), kind: kind, filename: file, originalFilename: "orig-\(file)",
                                      addedAt: Date(timeIntervalSince1970: added), note: note,
                                      sha256: "00", byteCount: 10)
        document.fileURL = root.appendingPathComponent("People/\(folderName)/Documents/\(file)")
        return PersonDocumentRow(document: document, ownerID: "@I1@", owner: owner)
    }

    private func subject() throws -> ResearchSubject {
        let graph = GedcomFamilyGraph(gedcomText: panelGedcom)
        return ResearchSubject(person: try #require(graph.people["@I1@"]))
    }

    private func filedFinding(_ file: String, year: String?, site: String, verdict: ResearchVerdict = .unreviewed) -> ResearchFinding {
        ResearchFinding(source: .recordFinder, title: "Civil birth\(year.map { " \($0)" } ?? "") — \(site) (District)",
                        date: year, excerpt: "x", url: "https://example.org/\(file)",
                        retrievedAt: Date(timeIntervalSince1970: 0), verdict: verdict,
                        documentPath: "People/\(folderName)/Documents/\(file)", idSeed: "sha256:\(file)")
    }

    // MARK: Logic — grouping

    @Test func groupsFollowTheKindOrderAndKeepNewestFirst() {
        let rows = [row(.other, "Other-3.pdf", added: 30), row(.census, "CEN-1.pdf", added: 29),
                    row(.birth, "BC-2.pdf", added: 28), row(.military, "MIL-1.pdf", added: 27),
                    row(.birth, "BC-1.pdf", added: 26), row(.death, "DC-1.pdf", added: 25)]
        let groups = PersonDocumentsResearch.grouped(rows)
        #expect(groups.map(\.kind) == [.birth, .death, .military, .census, .other], "no Marriage group: none filed")
        #expect(groups.first?.rows.map(\.document.filename) == ["BC-2.pdf", "BC-1.pdf"])
        #expect(PersonDocumentsResearch.displayOrder(rows).map(\.document.filename)
                == ["BC-2.pdf", "BC-1.pdf", "DC-1.pdf", "MIL-1.pdf", "CEN-1.pdf", "Other-3.pdf"])
        #expect(PersonDocumentsResearch.grouped([]).isEmpty)
    }

    // MARK: Logic — year, site, confirmed count

    @Test func aRecordFinderDocumentGetsItsYearAndSiteAHandAddedOneGetsNeither() throws {
        let filed = row(.birth, "BC-20261001-101500.pdf", added: 2,
                        note: "irishgenealogy.ie: Civil birth 1904, District. https://example.org/x")
        let byHand = row(.death, "DC-20260920-101500.pdf", added: 1, note: "From Aunt's shoebox: a copy")
        var dossier = ResearchDossier(subject: try subject())
        _ = dossier.addFiled(filedFinding("BC-20261001-101500.pdf", year: "1904", site: "irishgenealogy.ie",
                                          verdict: .confirmed))
        dossier.findings.append(ResearchFinding(source: .findAGrave, title: "Grave", date: nil, excerpt: "",
                                                url: "https://example.org/g", retrievedAt: Date(), verdict: .confirmed))
        dossier.findings.append(ResearchFinding(source: .wikipedia, title: "Page", date: nil, excerpt: "",
                                                url: "https://example.org/w", retrievedAt: Date(), verdict: .wrong))

        let derived = PersonDocumentsResearch.derive(rows: [filed, byHand], dossier: dossier)
        #expect(derived.details[filed.document.id] == PersonDocumentDetails(year: "1904", site: "irishgenealogy.ie"))
        #expect(derived.details[byHand.document.id] == nil)
        #expect(derived.confirmedFindings == 2)
    }

    @Test func aNoteNamingAnotherSiteIsNotTrustedButTheYearStill() throws {
        let filed = row(.census, "CEN-20261001-101500.pdf", added: 1, note: "My notes: something else")
        var dossier = ResearchDossier(subject: try subject())
        _ = dossier.addFiled(filedFinding("CEN-20261001-101500.pdf", year: "1911", site: "Census of Ireland 1901 / 1911"))
        let details = PersonDocumentsResearch.derive(rows: [filed], dossier: dossier).details[filed.document.id]
        #expect(details?.year == "1911")
        #expect(details?.site == nil)
    }

    @Test func aFindingForAnotherFolderOrFileDoesNotMatch() throws {
        let filed = row(.birth, "BC-1.pdf", added: 1, note: "site.example: Civil birth")
        var dossier = ResearchDossier(subject: try subject())
        var other = filedFinding("BC-1.pdf", year: "1904", site: "site.example")
        other.documentPath = "People/Someone_Else_TEST-999/Documents/BC-1.pdf"
        _ = dossier.addFiled(other)
        #expect(PersonDocumentsResearch.derive(rows: [filed], dossier: dossier).details.isEmpty)
        #expect(PersonDocumentsResearch.derive(rows: [filed], dossier: nil) == .empty)
    }

    @Test func yearAndSiteParsing() {
        #expect(PersonDocumentsResearch.year(in: "1904") == "1904")
        #expect(PersonDocumentsResearch.year(in: "1875-05-12") == "1875")
        #expect(PersonDocumentsResearch.year(in: "abt 1875") == nil)
        #expect(PersonDocumentsResearch.year(in: nil) == nil)
        #expect(PersonDocumentsResearch.site(note: "a.b: Civil birth", findingTitle: "Civil birth — a.b") == "a.b")
        #expect(PersonDocumentsResearch.site(note: "no colon here", findingTitle: "x — no colon here") == nil)
    }

    @Test func researchSummaryWords() {
        #expect(FamilyTreeDocumentsPanel.researchSummary(confirmed: 0) == "Research: none confirmed yet")
        #expect(FamilyTreeDocumentsPanel.researchSummary(confirmed: 1) == "Research: 1 confirmed finding")
        #expect(FamilyTreeDocumentsPanel.researchSummary(confirmed: 3) == "Research: 3 confirmed findings")
    }

    // MARK: Isolation — a temp People root only

    @Test func loadReadsTheDossierAndAMissingOrDamagedOneIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsPanelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchStore(peopleRoot: root)
        let filed = row(.birth, "BC-1.pdf", added: 1, note: "site.example: Civil birth 1904")
        #expect(PersonDocumentsResearch.load(rows: [filed], researchKey: "TEST-123", store: store) == .empty)

        var dossier = ResearchDossier(subject: try subject())
        _ = dossier.addFiled(filedFinding("BC-1.pdf", year: "1904", site: "site.example", verdict: .confirmed))
        try store.saveDossier(dossier)
        let loaded = PersonDocumentsResearch.load(rows: [filed], researchKey: "TEST-123", store: store)
        #expect(loaded.confirmedFindings == 1)
        #expect(loaded.details[filed.document.id]?.site == "site.example")
        #expect(PersonDocumentsResearch.load(rows: [filed], researchKey: nil, store: store) == .empty)

        try Data("{ not json".utf8).write(to: try store.dossierURL(key: "TEST-123"))
        #expect(PersonDocumentsResearch.load(rows: [filed], researchKey: "TEST-123", store: store) == .empty)
    }

    // MARK: Scale

    @Test func fiveHundredRowsAgainstFiveHundredFindingsStayUnderBudget() throws {
        var rows: [PersonDocumentRow] = []
        var dossier = ResearchDossier(subject: try subject())
        for i in 0..<500 {
            let file = "BC-\(i).pdf"
            rows.append(row(.birth, file, added: Double(i), note: "site\(i).example: Civil birth"))
            _ = dossier.addFiled(filedFinding(file, year: "\(1800 + i % 200)", site: "site\(i).example"))
        }
        let clock = ContinuousClock()
        var derived = PersonDocumentsResearch.empty
        let elapsed = clock.measure { derived = PersonDocumentsResearch.derive(rows: rows, dossier: dossier) }
        #expect(derived.details.count == 500)
        #expect(elapsed < .seconds(2), "500 × 500 took \(elapsed)")
    }

    // MARK: Sensor — no dossier read in the view body

    @Test func thePanelReadsTheDossierOnlyInsideADetachedTask() throws {
        let source = try SourceTree.appSource(named: "FamilyTreeDocumentsUI.swift")
        #expect(!source.contains("loadDossier("), "the panel must not read a dossier directly")
        let load = try #require(source.range(of: "PersonDocumentsResearch.load("))
        let detached = try #require(source.range(of: "Task.detached(priority: .utility)"))
        #expect(detached.lowerBound < load.lowerBound, "the read is inside the detached task")
        #expect(source.components(separatedBy: "PersonDocumentsResearch.load(").count - 1 == 1)
    }
}
