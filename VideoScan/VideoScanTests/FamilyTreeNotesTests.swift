import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Archivist Notes pane (feature/family-tree-notes-and-nav, 2026-08-26).
// Dimensions per the feature-test checklist:
//   Logic     — resolution by gedcomPersonID link, by alias (namedLike),
//               ambiguity attaches to nobody, attribution captions
//   Round-trip — add a note through a temp CyberBrain, reload from disk,
//               Hallie's index resolves it; a told-me item shows up
//   Isolation — the model reads ONLY the injected brain directory
//   Scale     — 16k-person graph + 500-item brain: resolver build < 50 ms,
//               per-selection lookup microseconds

// MARK: - Fixtures

private let treeGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Richard Hardin /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 4 MAR 1929
1 FAMS @F1@
0 @I2@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @F1@
0 @I3@ INDI
1 NAME Richard Hardin /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
0 @I4@ INDI
1 NAME Frederick Burton /Lamb/
1 SEX M
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
0 TRLR
"""

private func treeGraph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: treeGedcom) }

private let aug21 = ISO8601DateFormatter().date(from: "2026-08-21T15:00:00Z")!
private let aug26 = ISO8601DateFormatter().date(from: "2026-08-26T15:00:00Z")!

private func item(_ id: String, _ text: String, person: String, source: String,
                  kind: CyberBrainItem.Kind = .biography,
                  confidence: CyberBrainItem.Confidence = .probable,
                  privacy: CyberBrainItem.Privacy = .family,
                  date: Date = aug21) -> CyberBrainItem {
    CyberBrainItem(id: id, kind: kind, text: text, subjectPersonIDs: [person],
                   sourceIDs: [source], confidence: confidence, privacy: privacy,
                   createdAt: date, updatedAt: date)
}

private let toldSource = CyberBrainSource(
    id: "source.told-by-rick.2026-08-21", type: .familyWitness,
    title: "Told to Hallie by Rick, 2026-08-21", attribution: "Rick")

/// A brain with: Eileen linked by pointer; "Dad Breen" told-me person whose
/// alias pins Sr; "Fred Lamb" reachable only through the diminutive table;
/// "Richard Breen" (no suffix) which fits BOTH Jr and Sr.
private func brainArchive() -> CyberBrainArchive {
    CyberBrainArchive(
        archiveID: "family", displayName: "Test brain",
        people: [
            CyberBrainPerson(
                id: "person.eileen", gedcomPersonID: "@I2@", canonicalName: "Mom",
                biographyPassages: [item("bio.eileen", "She taught fourth grade.", person: "person.eileen", source: toldSource.id)]),
            CyberBrainPerson(
                id: "person.dad-breen", canonicalName: "Dad Breen",
                aliases: ["Richard Hardin Breen Sr"],
                biographyPassages: [item("told.dad-breen.2026-08-21", "He repaired typewriters for forty years.",
                                         person: "person.dad-breen", source: toldSource.id)]),
            CyberBrainPerson(
                id: "person.fred", canonicalName: "Fred Lamb",
                anecdotes: [item("anec.fred", "Fred kept bees.", person: "person.fred",
                                 source: toldSource.id, kind: .anecdote, privacy: .private)]),
            CyberBrainPerson(
                id: "person.ambiguous", canonicalName: "Richard Breen",
                notes: [item("note.amb", "Which Richard?", person: "person.ambiguous",
                             source: toldSource.id, kind: .note)]),
        ],
        sources: [toldSource])
}

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FamilyTreeNotes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Resolver (pure)

@Suite("Family tree notes — resolver")
struct FamilyTreeNotesResolverTests {

    @Test func linkedPointerAliasAndDiminutiveAllResolveAmbiguityDoesNot() throws {
        let resolver = FamilyTreeNotesResolver(
            index: try CyberBrainIndex(archive: brainArchive()), graph: treeGraph())

        // (1) gedcomPersonID link.
        #expect(resolver.notes(forGedcomID: "@I2@").map(\.text) == ["She taught fourth grade."])
        // (2) alias "Richard Hardin Breen Sr" → only Sr; the told-me item lands here.
        let sr = resolver.notes(forGedcomID: "@I1@")
        #expect(sr.map(\.id) == ["told.dad-breen.2026-08-21"])
        #expect(sr.first?.attribution.hasPrefix("Told to Hallie by Rick · Aug 21") == true)
        // (3) "Fred Lamb" → Frederick Burton Lamb through the diminutive table.
        #expect(resolver.notes(forGedcomID: "@I4@").map(\.text) == ["Fred kept bees."])
        #expect(resolver.notes(forGedcomID: "@I4@").first?.privacy == .private)
        // (4) "Richard Breen" fits Jr AND Sr → attached to neither.
        #expect(resolver.notes(forGedcomID: "@I3@").isEmpty)
        #expect(!sr.contains { $0.id == "note.amb" })
        #expect(resolver.ambiguousPersonIDs == ["person.ambiguous"])
    }

    @Test func nameIndexMatchesTheLinearMatcherExactly() {
        let graph = treeGraph()
        let index = GedcomFamilyGraph.NameIndex(graph: graph)
        for typed in ["Rick Breen", "Rick Breen Jr", "Richard Hardin Breen Sr", "Fred Lamb",
                      "Eileen", "lamb", "Jr", "nobody here", "", "Breen Richard"] {
            #expect(index.people(namedLike: typed).map(\.id) == graph.people(namedLike: typed).map(\.id),
                    "namedLike(\(typed))")
        }
    }

    @Test func attributionCaptions() {
        let told = item("a", "x", person: "p", source: toldSource.id)
        #expect(FamilyTreeNote.attributionLine(item: told, source: toldSource, now: aug26) == "Told to Hallie by Rick · Aug 21")
        let noteSource = CyberBrainSource(id: "s", type: .profileNote, title: "Family Tree notes (Rick)", attribution: "Rick")
        let note = item("b", "y", person: "p", source: "s", kind: .note, date: aug26)
        #expect(FamilyTreeNote.attributionLine(item: note, source: noteSource, now: aug26) == "Archivist note · Aug 26")
        // A different year spells it out.
        let old = item("c", "z", person: "p", source: "s",
                       date: ISO8601DateFormatter().date(from: "2024-03-02T12:00:00Z")!)
        #expect(FamilyTreeNote.attributionLine(item: old, source: nil, now: aug26) == "Family record · Mar 2, 2024")
    }
}

// MARK: - Writer + model round-trip

@Suite("Family tree notes — add note round-trip")
@MainActor
struct FamilyTreeNotesRoundTripTests {

    private func model(root: URL?) -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            cyberBrainRootURL: root,
            noteAuthor: "Rick")
        model.install(graph: treeGraph())
        model.loadCyberBrainNow()
        return model
    }

    @Test func addingANoteCreatesALinkedPersonAndHallieCanAnswerFromIt() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        #expect(model.selectedNotes.isEmpty)
        #expect(model.notesStatus?.contains("not been told") == true)

        model.select("@I3@")
        try model.addNote("Grew up in Braintree; Berklee 2004.", date: aug26)

        // Pane refreshed from the writer's receipt, no reload.
        #expect(model.selectedNotes.count == 1)
        let note = try #require(model.selectedNotes.first)
        #expect(note.text == "Grew up in Braintree; Berklee 2004.")
        #expect(note.kind == .note)
        #expect(note.confidence == .confirmed)
        #expect(note.privacy == .family)
        #expect(note.attribution == "Archivist note · " + FamilyTreeNote.shortDate(aug26))
        #expect(model.notesStatus == nil)
        // Not on the father's card.
        model.select("@I1@")
        #expect(model.selectedNotes.isEmpty)

        // On disk: strict loader accepts it; person carries the pointer;
        // Hallie's own resolver finds him by name and sees the item.
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        let person = try #require(reloaded.people.first { $0.gedcomPersonID == "@I3@" })
        #expect(person.canonicalName == "Richard Hardin Breen Jr")
        #expect(person.notes.count == 1)
        let source = try #require(reloaded.sources.first { $0.id == person.notes[0].sourceIDs[0] })
        #expect(source.type == .profileNote)
        #expect(source.title == "Family Tree notes (Rick)")
        let index = try CyberBrainIndex(archive: reloaded)
        guard case .resolved(let found) = index.resolve("Richard Hardin Breen Jr") else {
            Issue.record("Hallie cannot resolve the new person"); return
        }
        #expect(index.evidence(for: found.id, privacyCeiling: .family).map(\.text)
                == ["Grew up in Braintree; Berklee 2004."])

        // Second note on the same person reuses the record (no duplicate
        // person) and the previous file went to backups/.
        model.select("@I3@")
        try model.addNote("Second note.", date: aug26)
        let again = try CyberBrainLoader(rootURL: root).load()
        #expect(again.people.filter { $0.gedcomPersonID == "@I3@" }.count == 1)
        #expect(again.people.first { $0.gedcomPersonID == "@I3@" }?.notes.count == 2)
        let backups = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("backups").path)) ?? []
        #expect(backups.count == 1)
        #expect(model.selectedNotes.count == 2)
        model.select("@I1@")
        #expect(model.selectedNotes.isEmpty)
    }

    @Test func toldMeItemAppearsWithAttributionAndNoteLinksTheExistingPerson() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Rick told Hallie about Dad Breen in the chat window.
        let told = CyberBrainWriter.Testimony(
            subjectName: "Dad Breen", subjectAliases: ["Richard Hardin Breen Sr"],
            speakerName: "Rick", text: "He repaired typewriters for forty years.", date: aug21)
        _ = try CyberBrainWriter.record(told, rootURL: root)

        let model = model(root: root)
        model.select("@I1@")
        #expect(model.selectedNotes.map(\.text) == ["He repaired typewriters for forty years."])
        #expect(model.selectedNotes.first?.attribution == "Told to Hallie by Rick · " + FamilyTreeNote.shortDate(aug21))
        #expect(model.selectedNotes.first?.confidence == .probable)

        // A tree note about the same record links the EXISTING "Dad Breen"
        // person (pointer set) rather than creating a second one.
        try model.addNote("Marine, Pacific theater.", date: aug26)
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(reloaded.people.count == 1)
        #expect(reloaded.people[0].gedcomPersonID == "@I1@")
        #expect(reloaded.people[0].canonicalName == "Dad Breen")
        #expect(model.selectedNotes.count == 2)
        // Newest first.
        #expect(model.selectedNotes.first?.text == "Marine, Pacific theater.")
    }

    @Test func sameNameDifferentPointerNeverMerges() throws {
        // Brain already has "Richard Hardin Breen" linked to Sr; a note on Jr
        // with the identical spelling must create a separate linked person.
        var archive = CyberBrainArchive(
            archiveID: "family", displayName: "t",
            people: [CyberBrainPerson(id: "person.sr", gedcomPersonID: "@I1@", canonicalName: "Richard Hardin Breen")],
            sources: [])
        let receipt = try CyberBrainWriter.appending(
            CyberBrainWriter.Testimony(subjectName: "Richard Hardin Breen", speakerName: "Rick",
                                       text: "About Jr.", kind: .note, date: aug26,
                                       origin: .familyTreeNote, gedcomPersonID: "@I3@"),
            to: archive)
        archive = receipt.archive
        #expect(receipt.createdPerson)
        #expect(archive.people.count == 2)
        #expect(archive.people.first { $0.gedcomPersonID == "@I3@" }?.notes.first?.text == "About Jr.")
        #expect(archive.people.first { $0.gedcomPersonID == "@I1@" }?.items.isEmpty == true)
        // Conversation testimony is unchanged: still probable, still "told." ids.
        let spoken = try CyberBrainWriter.appending(
            CyberBrainWriter.Testimony(subjectName: "Richard Hardin Breen", speakerName: "Rick",
                                       text: "Spoken.", date: aug26, gedcomPersonID: "@I1@"),
            to: archive)
        #expect(spoken.itemID.hasPrefix("told."))
        #expect(spoken.personID == "person.sr")
        #expect(spoken.archive.people.first { $0.id == "person.sr" }?.items.first?.confidence == .probable)
    }

    @Test func modelWithoutABrainDirectoryNeverReadsTheRealOne() throws {
        let model = model(root: nil)
        model.select("@I1@")
        #expect(model.selectedNotes.isEmpty)
        #expect(model.notesStatus?.contains("configured") == true)
        #expect(throws: CyberBrainWriter.WriteError.self) { try model.addNote("x") }
    }

    @Test func emptyNoteIsRefusedAndLeavesTheFileAlone() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        model.select("@I1@")
        #expect(throws: CyberBrainWriter.WriteError.emptyText) { try model.addNote("   \n") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cyberbrain.json").path))
    }
}

// MARK: - Scale

@Suite("Family tree notes — scale")
@MainActor
struct FamilyTreeNotesScaleTests {

    @Test func sixteenThousandPeopleAndFiveHundredItemsResolveFast() throws {
        var text = "0 HEAD\n"
        let givens = ["John", "Mary", "William", "Margaret", "Robert", "Elizabeth", "James", "Ann"]
        let surnames = ["Breen", "Latta", "Lamb", "Hudson", "Parker", "Scale"]
        for i in 1...16_000 {
            text += "0 @I\(i)@ INDI\n1 NAME \(givens[i % givens.count]) \(i) /\(surnames[i % surnames.count])/\n1 SEX M\n"
        }
        text += "0 TRLR\n"
        let graph = GedcomFamilyGraph(gedcomText: text)
        #expect(graph.people.count == 16_000)

        // 100 brain people × 5 items = 500 items; half linked by pointer,
        // half by a name that is unique in the tree ("Mary 1234 Latta").
        var people: [CyberBrainPerson] = []
        for n in 0..<100 {
            let treeID = 1 + n * 137
            let treePerson = graph.people["@I\(treeID)@"]!
            let personID = "person.\(n)"
            let items = (0..<5).map {
                item("item.\(n).\($0)", "Fact \($0) about \(treePerson.name)", person: personID, source: toldSource.id)
            }
            people.append(CyberBrainPerson(
                id: personID,
                gedcomPersonID: n % 2 == 0 ? treePerson.id : nil,
                canonicalName: treePerson.name,
                biographyPassages: items))
        }
        let index = try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "family", displayName: "scale", people: people, sources: [toldSource]))

        let nameIndex = GedcomFamilyGraph.NameIndex(graph: graph)   // once per graph
        let start = ContinuousClock.now
        let resolver = FamilyTreeNotesResolver(index: index, graph: graph, nameIndex: nameIndex)
        let buildElapsed = ContinuousClock.now - start
        #expect(buildElapsed < .milliseconds(50), "resolver build took \(buildElapsed)")

        let lookupStart = ContinuousClock.now
        var total = 0
        for n in 0..<100 { total += resolver.notes(forGedcomID: "@I\(1 + n * 137)@").count }
        for i in stride(from: 2, to: 16_000, by: 97) { total += resolver.notes(forGedcomID: "@I\(i)@").count }
        let lookupElapsed = ContinuousClock.now - lookupStart
        #expect(total >= 500)
        #expect(lookupElapsed < .milliseconds(50), "260 selections took \(lookupElapsed)")
        #expect(resolver.ambiguousPersonIDs.isEmpty)
    }
}

// MARK: - "Said as" chips (2026-08-26)

@Suite("Family tree notes — said-as chips")
struct FamilyTreePronunciationChipTests {

    @Test func nameWordsDropSuffixesInitialsAndDuplicates() {
        #expect(FamilyTreePronunciationChips.nameWords("Richard Hardin Breen Jr") == ["Richard", "Hardin", "Breen"])
        #expect(FamilyTreePronunciationChips.nameWords("Nathaniel J. McGill III") == ["Nathaniel", "McGill"])
        #expect(FamilyTreePronunciationChips.nameWords("Edith (Latta) Breen, Breen") == ["Edith", "Latta", "Breen"])
        #expect(FamilyTreePronunciationChips.nameWords("   ").isEmpty)
    }

    @Test func chipsShowThePersonsOwnEntryElseTheInheritedOne() {
        let people = [CyberBrainPerson(id: "p", canonicalName: "Nathaniel McGill",
                                       pronunciations: ["nathaniel": "nah-THAN-yel"])]
        let chips = FamilyTreePronunciationChips.make(
            name: "Nathaniel Edith McGill Jr", people: people, fallback: .shipped)
        #expect(chips.map(\.word) == ["Nathaniel", "Edith", "McGill"])
        #expect(chips[0].saidAs == "nah-THAN-yel")
        #expect(chips[0].inherited == "nuh-THAN-yul")
        #expect(chips[0].isSet && chips[0].effective == "nah-THAN-yel")
        #expect(chips[1].saidAs == nil && chips[1].inherited == "EE-dith" && !chips[1].isSet)
        #expect(chips[2].effective == "muh-GILL")
        // A word nobody has an entry for: no hint at all (identity entries
        // like Breen → Breen count as "no hint").
        let breen = FamilyTreePronunciationChips.make(name: "Rick Breen", people: [], fallback: .shipped)
        #expect(breen.map(\.effective) == [nil, nil])
    }
}

@Suite("Family tree notes — said-as round-trip")
@MainActor
struct FamilyTreePronunciationRoundTripTests {

    @Test func settingAPronunciationMintsTheLinkedPersonAndTheVoiceLayerSeesIt() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            cyberBrainRootURL: root, noteAuthor: "Rick", pronunciationFallback: { .shipped })
        model.install(graph: treeGraph())
        model.loadCyberBrainNow()

        // Chips appear before any brain exists.
        model.select("@I2@")
        #expect(model.selectedPronunciations.map(\.word) == ["Eileen", "Latta"])
        #expect(model.selectedPronunciations[1].inherited == "LAT-uh")
        #expect(!model.selectedPronunciations[1].isSet)

        try model.setPronunciation(word: "Latta", saidAs: "LAH-tuh")
        #expect(model.selectedPronunciations[1].saidAs == "LAH-tuh")
        #expect(model.selectedNotes.isEmpty)   // a pronunciation is not a note

        // On disk: linked person, no passages, the table; strict loader OK.
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        let person = try #require(reloaded.people.first { $0.gedcomPersonID == "@I2@" })
        #expect(person.canonicalName == "Eileen Latta")
        #expect(person.items.isEmpty)
        #expect(person.pronunciations == ["Latta": "LAH-tuh"])

        // The voice layer built from that directory says it the new way.
        let layer = HalliePronunciationLexicon.personLayer(people: reloaded.people)
        #expect(layer.apply(to: "Eileen Latta's").spoken == "Eileen LAH-tuh's")

        // Removing clears the table but keeps the person.
        try model.setPronunciation(word: "latta", saidAs: nil)
        #expect(!model.selectedPronunciations[1].isSet)
        #expect(try CyberBrainLoader(rootURL: root).load().people.first { $0.gedcomPersonID == "@I2@" }?.pronunciations == nil)

        // Another person is untouched.
        model.select("@I1@")
        #expect(model.selectedPronunciations.allSatisfy { !$0.isSet })
    }
}

extension FamilyTreePronunciationRoundTripTests {

    /// QA 2026-08-26: the fallback lexicon was captured once at init, so
    /// the inspector's `inherited` hint went stale after a file-level
    /// telling. It is now computed on every refresh.
    @Test func inheritedChipFollowsTheFileLayerAfterAFileLevelTelling() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Hallie/pronunciations.json")
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            cyberBrainRootURL: root, noteAuthor: "Rick",
            pronunciationFallback: { .merged([.load(from: fileURL, log: nil), .shipped]) })
        // Init wrote nothing: the default file appears on the first
        // refresh (install selects a root person), not before.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        model.install(graph: treeGraph())
        model.loadCyberBrainNow()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        model.select("@I2@")
        #expect(model.selectedPronunciations[1].word == "Latta")
        #expect(model.selectedPronunciations[1].inherited == "LAT-uh")

        // "Say Latta as LAH-tuh" told to Hallie for a name several people
        // carry lands in pronunciations.json, on nobody's record.
        try HalliePronunciationLexicon.setFileEntry(written: "Latta", spoken: "LAH-tuh", url: fileURL, log: nil)
        model.select("@I1@")
        model.select("@I2@")
        #expect(model.selectedPronunciations[1].inherited == "LAH-tuh")
        #expect(!model.selectedPronunciations[1].isSet)   // inherited, not the person's own
    }
}
