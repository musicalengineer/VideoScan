import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Hallie shape for Research Person (2026-08-29): "what do we know about X
// from research" / "research on X" cites ONLY confirmed research
// attestations. Dimensions: detection logic (positive and negative),
// answer composition + citations, the unconfirmed-never-cited promise,
// identity (ambiguity, tree bridge), and the pre-translation wiring.

private let treeGedcom = """
0 HEAD
0 @I1@ INDI
1 NAME David McGill /Latta/ Sr
1 SEX M
1 BIRT
2 DATE 1847
1 DEAT
2 DATE 1921
1 _FSFTID KWCJ-7B2
0 @I2@ INDI
1 NAME Eileen /Latta/
1 SEX F
0 TRLR
"""

private let aug29 = ISO8601DateFormatter().date(from: "2026-08-29T15:00:00Z")!
private let fetched = ISO8601DateFormatter().date(from: "2026-08-29T14:00:00Z")!

private func subject() -> ResearchSubject {
    ResearchSubject(person: GedcomFamilyGraph(gedcomText: treeGedcom).people["@I1@"]!)
}

private func finding(_ url: String, title: String, date: String?, lore: String) -> ResearchFinding {
    var f = ResearchFinding(source: .chroniclingAmerica, title: title, date: date, excerpt: "excerpt",
                            url: url, retrievedAt: fetched)
    f.verdict = .confirmed
    f.lore = lore
    return f
}

/// A brain with two confirmed research items, one told-me passage, and
/// one research-sourced item that is NOT confirmed (hand-edited to
/// probable) — the last two must never be cited by this shape.
private func brain() throws -> CyberBrainIndex {
    let s = subject()
    let first = try ResearchAttestation.testimony(
        for: finding("https://chroniclingamerica.loc.gov/lccn/sn1/1875-05-12/ed-1/seq-3/",
                     title: "Berkshire County Eagle.", date: "1875-05-12",
                     lore: "He bought the paper mill on the north branch in 1875."),
        subject: s, speakerName: "Rick", date: aug29)
    let second = try ResearchAttestation.testimony(
        for: finding("https://www.findagrave.com/memorial/1/david-latta", title: "David McGill Latta Sr",
                     date: "1847–1921", lore: "Buried at Pine Grove, Dalton."),
        subject: s, speakerName: "Rick", date: aug29.addingTimeInterval(60))
    let told = CyberBrainWriter.Testimony(
        subjectName: "David McGill Latta Sr", speakerName: "Rick",
        text: "Grandpa said he was a stern man.", date: aug29, origin: .conversation,
        gedcomPersonID: "@I1@")
    var archive = try CyberBrainWriter.appending(first, to: nil).archive
    archive = try CyberBrainWriter.appending(second, to: archive).archive
    archive = try CyberBrainWriter.appending(told, to: archive).archive
    // Unconfirmed research-sourced item: same source as the first, but probable.
    let person = archive.people[0]
    let source = archive.sources.first { $0.id.hasPrefix(CyberBrainWriter.researchSourceIDPrefix) }!
    let unconfirmed = CyberBrainItem(
        id: "research.hand-edited", kind: .event, text: "UNCONFIRMED research text",
        subjectPersonIDs: [person.id], sourceIDs: [source.id], confidence: .probable,
        privacy: .family, createdAt: aug29, updatedAt: aug29)
    let patched = CyberBrainPerson(
        id: person.id, gedcomPersonID: person.gedcomPersonID, profileStableID: person.profileStableID,
        canonicalName: person.canonicalName, aliases: person.aliases, terminology: person.terminology,
        biographyPassages: person.biographyPassages, anecdotes: person.anecdotes,
        lifeEvents: person.lifeEvents + [unconfirmed], notes: person.notes,
        pronunciations: person.pronunciations)
    let final = CyberBrainArchive(schemaVersion: archive.schemaVersion, archiveID: archive.archiveID,
                                  displayName: archive.displayName, people: [patched], sources: archive.sources)
    try CyberBrainValidator.validate(final)
    return try CyberBrainIndex(archive: final)
}

@Suite("Hallie — research question shape")
struct HallieResearchQuestionTests {

    @Test func detectsTheDesignedPhrasingsAndExtractsTheName() {
        let cases: [(String, String)] = [
            ("what do we know about David McGill Latta from research", "David Mcgill Latta"),
            ("What do we know about David Latta from the research?", "David Latta"),
            ("research on David Latta", "David Latta"),
            ("Hallie, what research do we have on David Latta?", "David Latta"),
            ("what did the research find about david latta", "David Latta"),
            ("show me the research on David Latta please", "David Latta"),
            ("what does research say about David Latta", "David Latta"),
            ("any research on Eileen Latta", "Eileen Latta"),
        ]
        for (question, name) in cases {
            #expect(HallieResearchQuestion.detect(question)?.personName == name, Comment(rawValue: question))
        }
    }

    @Test func doesNotFireOnOrdinaryQuestions() {
        for question in [
            "tell me about David Latta", "who is David Latta", "show me David Latta in 1975",
            "research", "what do we know about David Latta", "research on him",
            "how do I research a person", "did David Latta do research",
        ] {
            #expect(HallieResearchQuestion.detect(question) == nil, Comment(rawValue: question))
        }
    }

    @Test func citesOnlyConfirmedResearchItemsNewestFirst() throws {
        let context = HallieTurnExecutor.Context(
            graph: GedcomFamilyGraph(gedcomText: treeGedcom), cyberBrain: try brain())
        let ask = try #require(HallieResearchQuestion.detect("what do we know about David Latta from research"))
        let result = HallieResearchQuestion.answer(ask, context: context)
        #expect(result.outcome == .answered)
        #expect(result.route == .graph)
        #expect(result.prose.hasPrefix("From research on David McGill Latta Sr, 2 confirmed findings:"))
        #expect(result.prose.contains("1. Buried at Pine Grove, Dalton. [David McGill Latta Sr, 1847–1921 — confirmed by Rick]"))
        #expect(result.prose.contains("2. He bought the paper mill on the north branch in 1875. [Berkshire County Eagle., 1875-05-12 — confirmed by Rick]"))
        // Never: the told-me passage, the unconfirmed research item.
        #expect(!result.prose.contains("stern man"))
        #expect(!result.prose.contains("UNCONFIRMED"))
        #expect(result.knowledgeCitations.count == 2)
        #expect(result.knowledgeCitations.allSatisfy { $0.id.hasPrefix(CyberBrainWriter.researchSourceIDPrefix) })
        #expect(result.knowledgeCitations.map(\.locator).contains(
            ResearchStore.relativeCachePath(key: "KWCJ-7B2", pageURL: "https://www.findagrave.com/memorial/1/david-latta")))
        #expect(result.basisLine.contains("confirmed only"))
        #expect(result.basisLine.contains("unconfirmed research is never cited"))
        #expect(!result.basisLine.contains("research.hand-edited"))
        #expect(result.queryDescription == "shape=research person=David Latta")
        #expect(result.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "David McGill Latta Sr")])
    }

    @Test func nothingConfirmedDeclinesHonestlyAndOffersTheTree() throws {
        let context = HallieTurnExecutor.Context(
            graph: GedcomFamilyGraph(gedcomText: treeGedcom), cyberBrain: try brain())
        let ask = try #require(HallieResearchQuestion.detect("research on Eileen Latta"))
        let result = HallieResearchQuestion.answer(ask, context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("I don't have any confirmed research on Eileen Latta yet."))
        #expect(result.prose.contains("Research Person…"))
        #expect(result.knowledgeCitations.isEmpty)
        #expect(result.offeredActions == [.openFamilyTreePerson(personID: "@I2@", personName: "Eileen Latta")])

        // Unknown name, no tree: says so.
        let bare = HallieResearchQuestion.answer(
            try #require(HallieResearchQuestion.detect("research on Nobody Here")),
            context: HallieTurnExecutor.Context(graph: nil, cyberBrain: nil))
        #expect(bare.outcome == .declined)
        #expect(bare.prose.contains("I don't have a family tree loaded"))
    }

    @Test func ambiguousNameAsksWhichOne() throws {
        let twoDavids = treeGedcom.replacingOccurrences(of: "1 NAME Eileen /Latta/", with: "1 NAME David /Latta/")
        let context = HallieTurnExecutor.Context(graph: GedcomFamilyGraph(gedcomText: twoDavids), cyberBrain: nil)
        let result = HallieResearchQuestion.answer(
            try #require(HallieResearchQuestion.detect("research on David Latta")), context: context)
        #expect(result.outcome == .needsClarification)
        #expect(result.prose.contains("More than one person is called David Latta"))
        #expect(result.knowledgeCitations.isEmpty)
    }

    @Test func preTranslationRoutesTheShapeBeforeTheTranslator() throws {
        let context = HallieTurnExecutor.Context(
            graph: GedcomFamilyGraph(gedcomText: treeGedcom), cyberBrain: try brain())
        let pre = HallieTurnExecutor.preTranslation(
            question: "what do we know about David Latta from research",
            playAfterAnswer: false,
            memory: HallieTurnExecutor.ConversationMemory(),
            isKnownPerson: { _ in true },
            researchAnswer: { HallieResearchQuestion.answer($0, context: context) })
        guard case .answer(let result) = pre else { Issue.record("expected a local answer"); return }
        #expect(result.queryDescription == "shape=research person=David Latta")
        #expect(result.outcome == .answered)

        // Without the closure the question falls through untouched.
        let without = HallieTurnExecutor.preTranslation(
            question: "what do we know about David Latta from research",
            playAfterAnswer: false,
            memory: HallieTurnExecutor.ConversationMemory(),
            isKnownPerson: { _ in true })
        if case .answer(let r) = without { #expect(r.queryDescription != "shape=research person=David Latta") }
    }
}
