import Foundation
import Testing
@testable import VideoScanCore

/// Synthetic, in-memory contracts established before the writer decomposition.
struct CyberBrainWriterCharacterizationTests {
    private var date: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2026, month: 8, day: 21, hour: 12))!
    }

    private func archive(_ people: [CyberBrainPerson], sources: [CyberBrainSource] = []) -> CyberBrainArchive {
        .init(archiveID: "synthetic", displayName: "Synthetic archive", people: people, sources: sources)
    }

    private func testimony(name: String, pointer: String? = nil, aliases: [String] = []) -> CyberBrainWriter.Testimony {
        .init(subjectName: name, subjectAliases: aliases, speakerName: " Witness ",
              text: "  Exact words.\n", date: date, gedcomPersonID: pointer)
    }

    @Test func pointerWinsOverNameAndConflictingPointersStaySeparate() throws {
        let linked = CyberBrainPerson(id: "person.linked", gedcomPersonID: "@I1@", canonicalName: "Alex River")
        let namesake = CyberBrainPerson(id: "person.namesake", gedcomPersonID: "@I2@", canonicalName: "Sam Brook")
        let original = archive([linked, namesake])
        let receipt = try CyberBrainWriter.appending(testimony(name: "Sam Brook", pointer: "@I1@"), to: original)
        #expect(receipt.personID == "person.linked")
        #expect(!receipt.createdPerson)
        #expect(receipt.archive.people[1] == namesake)
        #expect(receipt.itemID == "told.linked.2026-08-21")
        #expect(receipt.sourceID == "source.told-by-witness.2026-08-21")

        let separate = try CyberBrainWriter.appending(testimony(name: "Alex River", pointer: "@I3@"), to: original)
        #expect(separate.createdPerson)
        #expect(separate.personID == "person.alex-river.i3")
        #expect(Array(separate.archive.people.prefix(2)) == original.people)
        #expect(separate.archive.people.last?.gedcomPersonID == "@I3@")
    }

    @Test func allPersonFieldsSurviveLinkingCaptionAndPronunciation() throws {
        let source = CyberBrainSource(id: "source.original", type: .familyWitness, title: "Synthetic witness")
        func item(_ kind: CyberBrainItem.Kind) -> CyberBrainItem {
            .init(id: "original.\(kind.rawValue)", kind: kind, text: "Original \(kind.rawValue)",
                  subjectPersonIDs: ["person.alex"], sourceIDs: [source.id],
                  confidence: .confirmed, privacy: .family, createdAt: date, updatedAt: date)
        }
        let person = CyberBrainPerson(
            id: "person.alex", profileStableID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            canonicalName: "Alex River", aliases: ["Al"], terminology: ["Grandparent"],
            biographyPassages: [item(.biography)], anecdotes: [item(.anecdote)],
            lifeEvents: [item(.event)], notes: [item(.note)], pronunciations: ["Alex": "AL-ex"])
        let first = try CyberBrainWriter.appending(
            testimony(name: "Al", pointer: "@I42@", aliases: [" al ", "ALEX RIVER", " Lex ", "lex"]),
            to: archive([person], sources: [source]))
        let caption = CyberBrainWriter.PhotoCaption(
            subjects: [.init(name: "Alex River")], speakerName: "Witness", text: "At the bench.",
            photoPath: "/synthetic/People/Alex/bench.jpg", date: date)
        let second = try CyberBrainWriter.appending(caption: caption, to: first.archive)
        let third = try CyberBrainWriter.settingPronunciation(
            personID: person.id, word: "River", saidAs: " RIV-er ", in: second.archive)
        let expected = CyberBrainPerson(
            id: person.id, gedcomPersonID: "@I42@", profileStableID: person.profileStableID,
            canonicalName: "Alex River", aliases: ["Al", "Lex"], terminology: ["Grandparent"],
            biographyPassages: person.biographyPassages + [CyberBrainItem(
                id: "told.alex.2026-08-21", kind: .biography, text: "Exact words.",
                subjectPersonIDs: [person.id], sourceIDs: ["source.told-by-witness.2026-08-21"],
                confidence: .probable, privacy: .family, createdAt: date, updatedAt: date)],
            anecdotes: person.anecdotes, lifeEvents: person.lifeEvents,
            notes: person.notes + [CyberBrainItem(
                id: "caption.alex.2026-08-21", kind: .note, text: "At the bench.",
                subjectPersonIDs: [person.id],
                sourceIDs: ["source.photo.alex-bench-jpg", "source.told-by-witness.2026-08-21"],
                confidence: .probable, privacy: .family, createdAt: date, updatedAt: date)],
            pronunciations: ["Alex": "AL-ex", "River": "RIV-er"])
        #expect(third.archive.people == [expected])
        #expect(third.archive.archiveID == "synthetic")
        #expect(third.archive.displayName == "Synthetic archive")
        #expect(third.archive.sources.first == source)
        #expect(third.archive.sources.last?.locator == "People/Alex/bench.jpg")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try CyberBrainWriter.encode(third.archive)
        #expect(try decoder.decode(CyberBrainArchive.self, from: encoded) == third.archive)
        #expect(String(decoding: encoded, as: UTF8.self).contains("People/Alex/bench.jpg"))
    }

    @Test func captionCapsMentionsBeforeDeduplicationAndStoresOneSharedItem() throws {
        let names = ["Alex River", "Alex River", "Sam Brook", "Jo Vale", "Pat Glen", "Lee Hill", "Kim Lake", "Ash Wood", "Excluded Person"]
        let caption = CyberBrainWriter.PhotoCaption(
            subjects: names.map { .init(name: $0) }, speakerName: "Witness", text: "A picnic.",
            photoPath: "/synthetic/picnic.jpg", date: date)
        let receipt = try CyberBrainWriter.appending(caption: caption, to: nil)
        let ids = ["person.alex-river", "person.sam-brook", "person.jo-vale", "person.pat-glen",
                   "person.lee-hill", "person.kim-lake", "person.ash-wood"]
        #expect(receipt.archive.people.map(\.id) == ids)
        #expect(receipt.archive.people.flatMap(\.items).count == 1)
        #expect(receipt.archive.people.first?.notes.first?.subjectPersonIDs == ids)
        #expect(receipt.createdPerson)
        #expect(receipt.personID == ids[0])
        #expect(receipt.itemID == "caption.alex-river.2026-08-21")
    }

    @Test func repeatedResearchDoesNotLinkOrRenameAnUnlinkedPerson() throws {
        let citation = CyberBrainWriter.Testimony.Citation(
            title: "Synthetic record", url: "https://records.example.invalid/one", retrievedAt: date)
        let original = try CyberBrainWriter.appending(.init(
            subjectName: "Alex River", speakerName: "Witness", text: "An exact finding.",
            date: date, origin: .researchFinding, citation: citation), to: nil)
        let retry = try CyberBrainWriter.appending(.init(
            subjectName: "Alex River", subjectAliases: ["Al"], speakerName: "Witness",
            text: "An exact finding.", date: date, origin: .researchFinding,
            gedcomPersonID: "@I42@", citation: citation), to: original.archive)
        #expect(retry.archive == original.archive)
        #expect(retry.itemID == original.itemID)
        #expect(retry.archive.people[0].gedcomPersonID == nil)
        #expect(retry.archive.people[0].aliases.isEmpty)
        #expect(!retry.createdPerson)
    }

    @Test func validationErrorPriorityRemainsStable() {
        #expect(throws: CyberBrainWriter.WriteError.emptyText) {
            try CyberBrainWriter.appending(.init(subjectName: "", speakerName: "", text: " ", date: date), to: nil)
        }
        #expect(throws: CyberBrainWriter.WriteError.emptySubject) {
            try CyberBrainWriter.appending(testimony(name: " "), to: nil)
        }
        #expect(throws: CyberBrainWriter.WriteError.ioFailure("a research finding needs a citation with a URL")) {
            try CyberBrainWriter.appending(.init(subjectName: "Alex River", speakerName: "Witness",
                text: "A finding.", date: date, origin: .researchFinding), to: nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appendAtOneHundredThousandItemsPreservesHistoryWithinBudget() throws {
        let source = CyberBrainSource(id: "source.original", type: .familyWitness, title: "Synthetic witness")
        let instant = date
        let items = (0..<100_000).map { index in
            CyberBrainItem(id: "item.\(index)", kind: .note, text: "Synthetic note \(index)",
                           subjectPersonIDs: ["person.alex"], sourceIDs: [source.id],
                           confidence: .probable, privacy: .family, createdAt: instant, updatedAt: instant)
        }
        let person = CyberBrainPerson(id: "person.alex", canonicalName: "Alex River", notes: items)
        let original = archive([person], sources: [source])
        var receipt: CyberBrainWriter.Receipt?
        // Synchronous CPU time excludes scheduling delays from other test suites.
        // Ten seconds is a broad regression ceiling for index+validate+append.
        let elapsed = try TimingBudget.measureThreadCPUTime {
            receipt = try CyberBrainWriter.appending(testimony(name: "Alex River"), to: original)
        }
        let result = try #require(receipt)
        #expect(result.archive.people[0].notes == items)
        #expect(result.archive.people[0].biographyPassages.count == 1)
        #expect(result.archive.people[0].items.count == 100_001)
        #expect(result.itemID == "told.alex.2026-08-21")
        #expect(elapsed < .seconds(10), "100k-item append exceeded its CPU budget: \(elapsed)")
        print("[cyberbrain-writer-scale] 100k-item append: \(elapsed) CPU (budget 10s)")
    }
}
