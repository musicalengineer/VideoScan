// AdversarialCyberBrainFindingsTests.swift
// Red tests from the first nightly adversarial review (2026-10-01, brief 1),
// kept as regression pins on CyberBrainWriter.appending:
//   06addb5d  a retracted passage is never handed back as "told"
//   61c81eab  one page URL, two documents → two sources (Core side)
// Synthetic people only.

import Foundation
import Testing
@testable import VideoScanCore

private let when = Date(timeIntervalSince1970: 1_790_000_000)
private let page = "https://records.example.invalid/results?q=synthetic"

private func research(_ text: String, title: String = "Civil birth 1878 — Example Records",
                      locator: String? = "People/U-test/Documents/BC-20260101.pdf",
                      date: String? = "1878") -> CyberBrainWriter.Testimony {
    CyberBrainWriter.Testimony(
        subjectName: "Synthia Testcase", speakerName: "Tester", text: text, kind: .event, date: when,
        origin: .researchFinding, gedcomPersonID: "@I1@",
        citation: .init(title: title, url: page, locator: locator, sourceDate: date, retrievedAt: when))
}

@Suite struct AdvRetractedResearchPassageTests {
    @Test func aRetractedPassageIsNeverReturnedAsTold() throws {
        let first = try CyberBrainWriter.appending(research("Born 1878 in Synthtown (synthetic)."), to: nil)
        let removed = try CyberBrainWriter.correcting(
            .init(itemID: first.itemID, viewedPersonID: first.personID,
                  operation: .remove(reason: .wrongInformation, detail: nil), by: "Tester", date: when),
            in: first.archive)
        // The same words from the same record, filed again later.
        let again = try CyberBrainWriter.appending(research("Born 1878 in Synthtown (synthetic)."), to: removed.archive)
        #expect(again.itemID != first.itemID, "the retracted item was handed back as told")
        let item = try #require(again.archive.people.flatMap(\.items).first { $0.id == again.itemID })
        #expect(item.status == .active)
    }

    /// Unchanged: the same ACTIVE passage twice is still one item.
    @Test func theSameActivePassageIsStillIdempotent() throws {
        let first = try CyberBrainWriter.appending(research("Born 1878 in Synthtown (synthetic)."), to: nil)
        let again = try CyberBrainWriter.appending(research("Born 1878 in Synthtown (synthetic)."), to: first.archive)
        #expect(again.itemID == first.itemID)
        #expect(again.archive == first.archive)
    }
}

@Suite struct AdvResearchSourceIdentityTests {
    @Test func twoDocumentsFromOnePageAreTwoSources() throws {
        let birth = try CyberBrainWriter.appending(research("Born 1878 (synthetic)."), to: nil)
        let marriage = try CyberBrainWriter.appending(
            research("Married 1900 (synthetic).", title: "Marriage 1900 — Example Records",
                     locator: "People/U-test/Documents/MC-20260101.pdf", date: "1900"),
            to: birth.archive)
        #expect(marriage.sourceID != birth.sourceID)
        let source = try #require(marriage.archive.sources.first { $0.id == marriage.sourceID })
        #expect(source.locator == "People/U-test/Documents/MC-20260101.pdf")
        #expect(source.title.contains("Marriage"))
        #expect(source.sourceDate?.value == "1900")
        #expect(CyberBrainWriter.researchURL(of: source) == page)
    }

    /// Two excerpts of the same cached page still share one source.
    @Test func twoExcerptsOfOnePageShareTheirSource() throws {
        let cache = "People/U-test/research/cache/abc.json"
        let a = try CyberBrainWriter.appending(research("First excerpt.", title: "Eagle, 1875", locator: cache, date: nil), to: nil)
        let b = try CyberBrainWriter.appending(research("Second excerpt.", title: "Eagle, 1875", locator: cache, date: nil), to: a.archive)
        #expect(a.sourceID == b.sourceID)
        #expect(b.archive.sources.count == 1)
    }

    /// A source written before this change (id = URL only) is reused when
    /// it describes the same document, so an old passage stays idempotent.
    @Test func aLegacyURLOnlySourceIsReusedForTheSameDocument() throws {
        let legacyID = CyberBrainWriter.researchSourceIDPrefix + CyberBrainWriter.slug(page)
        let first = try CyberBrainWriter.appending(research("Born 1878 (synthetic)."), to: nil)
        // Rewrite the archive as an older build wrote it: the URL-only id.
        let renamed = CyberBrainArchive(
            schemaVersion: first.archive.schemaVersion, archiveID: first.archive.archiveID,
            displayName: first.archive.displayName,
            people: first.archive.people.map { person in
                CyberBrainPerson(id: person.id, gedcomPersonID: person.gedcomPersonID, canonicalName: person.canonicalName,
                                 aliases: person.aliases,
                                 lifeEvents: person.lifeEvents.map { item in
                                     CyberBrainItem(id: item.id, kind: item.kind, text: item.text,
                                                    subjectPersonIDs: item.subjectPersonIDs, sourceIDs: [legacyID],
                                                    confidence: item.confidence, privacy: item.privacy,
                                                    createdAt: item.createdAt, updatedAt: item.updatedAt)
                                 })
            },
            sources: first.archive.sources.map { s in
                CyberBrainSource(id: legacyID, type: s.type, title: s.title, attribution: s.attribution,
                                 sourceDate: s.sourceDate, locator: s.locator, notes: s.notes)
            })
        try CyberBrainValidator.validate(renamed)
        let again = try CyberBrainWriter.appending(research("Born 1878 (synthetic)."), to: renamed)
        #expect(again.sourceID == legacyID)
        #expect(again.itemID == first.itemID, "no duplicate passage after the upgrade")
    }
}
