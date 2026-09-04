// HallieProfileNoteAndChildCountTests.swift
// Two defects Rick found on 2026-09-04, hours before showing Hallie to his
// brother Tim, with their late father as the subject.
//
//  1. A People-profile NOTE was dropped for anyone bridged to the family
//     tree. "who is Tim" (no tree record) quoted Tim's note with the
//     profile route's attribution and hedge; "tell me about Dad" (bridged)
//     went down HallieBiographyCard, which is built from the GEDCOM alone,
//     and everything Rick had typed about his father — the Marine Corps,
//     the typewriters, the bus — was silently gone.
//
//  2. "He had 1 recorded child, Richard Harding Breen Jr." was said to that
//     man's SON, and the very next sentence named three more children from
//     the People tab. The tree's count was stated as the truth. Rick's
//     father had five children; Michael is in neither source, so no total
//     the archive can stand behind exists.
//
// Dimensions: LOGIC (card wording per source combination); ISOLATION
// (synthetic GEDCOM text + profile snapshots — no files, no defaults, no
// model); SENSORS (the exact live sentences pinned, and a standing check
// that the card never sums the two sources).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixture

// Synthetic tree (2026-08-03 privacy policy): only the FamilySearch IDs of
// the two Richards are the real ones, so the pins can be read against the
// live tree. Dad's record lists ONE child; the People tab knows three more.
private let treeText = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @D@
0 @D@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 22 FEB 1929
2 PLAC Boston, Suffolk, Massachusetts
1 DEAT
2 DATE 22 JUN 2008
2 PLAC Brockton, Plymouth, Massachusetts
1 FAMS @FD@
1 _FSFTID G2S4-JF4
0 @E@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @FD@
0 @R@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @FD@
1 _FSFTID GVQV-NW3
0 @FD@ FAM
1 HUSB @D@
1 WIFE @E@
1 CHIL @R@
0 TRLR
"""

private let graph = GedcomFamilyGraph(gedcomText: treeText)

private typealias Profile = HallieTurnExecutor.ProfileSnapshot
private typealias Executor = HallieTurnExecutor
private typealias Kin = HallieBiographyCard.PeopleTabKin

/// Rick's father's note, exactly as it stands in his People profile on
/// 2026-09-04 — misspellings and all. Hallie must quote it, never correct
/// it and never treat it as a fact.
let dadsRealNote = "Rick\u{2019}s father was born in 1929, served in the US Marine Corp "
    + "and was a typewiriter repairman and bus driver and a beloved father to his "
    + "chidlren. He was easy going in temperment. His wife was Eileen Lata Breen and "
    + "they married in 1956, then had 5 children."

/// Tim's note is quoted by the PROFILE route today; this pins that the
/// bridged fix left the unbridged wording alone.
private let timsNote = "Tim is Rick\u{2019}s younger brother. As a boy, he liked sports "
    + "and did well in baseball."

private func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
    Kinship(relation: relation, relativeTo: .profile(name: name))
}

/// Rick's People-tab rows as Rick enters them (a row reads "Rick is the
/// <relation> of <anchor>"): three siblings, and a child of Dad. Dad's
/// three extra children are the overlay's inference from those rows.
private func profiles(dadNote: String = dadsRealNote) -> [Profile] {
    [
        Profile(stableID: "rick", canonicalName: "Rick",
                kinships: [row(.sibling, "Tim"), row(.sibling, "Ellen"),
                           row(.sibling, "Beth"), row(.child, "Dad")],
                sex: .male, uuid: UUID(), treeIdentity: .familySearchID("GVQV-NW3")),
        Profile(stableID: "dad", canonicalName: "Dad", note: dadNote,
                sex: .male, uuid: UUID(), treeIdentity: .familySearchID("G2S4-JF4")),
        Profile(stableID: "tim", canonicalName: "Tim", note: timsNote,
                sex: .male, uuid: UUID()),
        Profile(stableID: "ellen", canonicalName: "Ellen", sex: .female, uuid: UUID()),
        Profile(stableID: "beth", canonicalName: "Beth", sex: .female, uuid: UUID()),
    ]
}

private func context(_ profiles: [Profile]) -> Executor.Context {
    Executor.Context(
        profiles: profiles, graph: graph,
        speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
}

private func ask(_ name: String, _ operation: ArchivistQueryAST.Graph.Operation,
                 context: Executor.Context) async throws -> Executor.Result {
    try await Executor.execute(
        .graph(.init(people: [name], operation: operation)), context: context)
}

private func person(_ id: String) -> GedcomFamilyGraph.Person { graph.people[id]! }

/// A People-tab child row, already bridged or not.
private func child(_ name: String, _ term: String, gedcomID: String? = nil) -> Kin.Relative {
    .init(name: name, term: term, evidenceID: "uuid:\(name.lowercased())", gedcomID: gedcomID)
}

// MARK: - Defect 1: the note reaches a bridged subject

@Suite("Hallie — a bridged subject's People-tab note")
struct HallieBridgedProfileNoteTests {

    /// THE LIVE MISS. "tell me about Dad" said nothing about the Marine
    /// Corps; now it quotes the note in the profile route's own words, with
    /// the profile route's own hedge, and the tree sentences are untouched.
    @Test func aBridgedSubjectsNoteIsQuotedWithTheSameAttributionAndHedge() async throws {
        let r = try await ask("Dad", .biography, context: context(profiles()))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("The note on the profile says: \u{201C}Rick\u{2019}s father was born in 1929, "
                                 + "served in the US Marine Corp"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("\u{201D} — that's a note, not something I've verified."),
                Comment(rawValue: r.prose))
        // The verified tree sentences are exactly what they were.
        #expect(r.prose.hasPrefix(
            "Richard Harding Breen Sr (Dad in the People tab) was born 22 February 1929 in "
            + "Boston, Suffolk, Massachusetts and died 22 June 2008 in Brockton, Plymouth, "
            + "Massachusetts. He was married to Eileen Latta."), Comment(rawValue: r.prose))
        // And the note is said LAST, after everything the tree vouches for.
        let noteStart = try #require(r.prose.range(of: "The note on the profile says:"))
        #expect(r.prose[noteStart.lowerBound...].contains("family tree includes") == false,
                Comment(rawValue: r.prose))
    }

    /// The note is PROVENANCE, never a claim: Swift writes it, Swift
    /// appends it after verification, and the verifier is never asked to
    /// prove it against the tree. Same seam the assumed-bridge aside uses.
    @Test func theNoteIsNeverACitedFact() async throws {
        let r = try await ask("Dad", .biography, context: context(profiles()))
        let plan = try #require(r.answerPlan)
        for claim in plan.claims {
            #expect(!claim.text.contains("note on the profile"), Comment(rawValue: claim.text))
            #expect(!claim.text.contains("Marine Corp"), Comment(rawValue: claim.text))
        }
        #expect((plan.provenanceNote ?? "").contains("The note on the profile says:"),
                Comment(rawValue: plan.provenanceNote ?? "nil"))
        // The basis line still says only what the tree and the rows say.
        #expect(!r.basisLine.contains("Marine"), Comment(rawValue: r.basisLine))
    }

    @Test func anEmptyOrWhitespaceNoteAppendsNothingAndLeavesNoDanglingPunctuation() async throws {
        for note in ["", "   ", " \n\t "] {
            let r = try await ask("Dad", .biography, context: context(profiles(dadNote: note)))
            #expect(!r.prose.contains("note on the profile"), Comment(rawValue: r.prose))
            #expect(!r.prose.contains("\u{201C}"), Comment(rawValue: r.prose))
            #expect(r.prose.hasSuffix("."), Comment(rawValue: r.prose))
            #expect(!r.prose.contains("  "), Comment(rawValue: r.prose))
            #expect(r.prose == r.prose.trimmingCharacters(in: .whitespacesAndNewlines),
                    Comment(rawValue: r.prose))
            #expect(r.answerPlan?.provenanceNote == nil,
                    Comment(rawValue: r.answerPlan?.provenanceNote ?? "nil"))
        }
    }

    /// Tim has no tree record, so he never went through the biography card
    /// and his answer must be bit-for-bit what it was before this change.
    @Test func anUnbridgedProfileIsAnsweredExactlyAsBefore() async throws {
        let r = try await ask("Tim", .biography, context: context(profiles()))
        #expect(r.prose.hasPrefix("Tim is one of the people in the People tab."),
                Comment(rawValue: r.prose))
        #expect(r.prose.contains("The note on the profile says: \u{201C}\(timsNote)\u{201D} "
                                 + "— that's a note, not something I've verified."),
                Comment(rawValue: r.prose))
        #expect(r.prose.contains("I couldn't match Tim to a record in the family tree I have."),
                Comment(rawValue: r.prose))
        // Said once, not twice: the graph route must not also append it.
        #expect(r.prose.components(separatedBy: "note on the profile").count == 2,
                Comment(rawValue: r.prose))
    }
}

// MARK: - Defect 2: the child sentence never states a count the archive can't stand behind

@Suite("Hallie biography card — honest child counts")
struct HallieHonestChildCountTests {

    /// THE LIVE MISS, end to end: the tree's one child and the People tab's
    /// three, in one sentence, each attributed to the source that holds it.
    @Test func theTreeCountIsSaidAsTheTreesWhenThePeopleTabKnowsMore() async throws {
        let r = try await ask("Dad", .biography, context: context(profiles()))
        #expect(r.prose.contains(
            "The family tree records one child for him, Richard Harding Breen Jr; "
            + "the People tab adds Beth and Ellen as daughters and Tim as a son."),
                Comment(rawValue: r.prose))
        // SENSOR: the retired wording, in any of its forms, must not return.
        #expect(!r.prose.contains("had 1 recorded child"), Comment(rawValue: r.prose))
        #expect(!r.prose.lowercased().contains("recorded child"), Comment(rawValue: r.prose))
        // SENSOR: the two sources are never summed. The tree says one, the
        // People tab adds three, and Michael is in neither — so "four" (and
        // any other total) is a number the archive cannot stand behind.
        for total in ["four children", "4 children", "4 recorded", "five children"] {
            #expect(!r.prose.contains(total), Comment(rawValue: "\(total) in: \(r.prose)"))
        }
    }

    /// The card alone, so the wording is pinned without the overlay.
    @Test func theSameSentenceIsBuiltByTheCardItself() {
        let kin = Kin(profileName: "Dad", profileStableID: "dad",
                      children: [child("Beth", "daughter"), child("Ellen", "daughter"),
                                 child("Tim", "son")],
                      storedOn: ["Rick"])
        let card = HallieBiographyCard.card(for: person("@D@"), in: graph, peopleTab: kin)
        #expect(card.prose.contains(
            "The family tree records one child for him, Richard Harding Breen Jr; "
            + "the People tab adds Beth and Ellen as daughters and Tim as a son."),
                Comment(rawValue: card.prose))
        // One claim, citing both sources, promising every name it says.
        let claim = try? #require(card.plan.claims.first { $0.text.contains("The family tree records") })
        #expect(claim?.requiredPersonNames.contains("Richard Harding Breen Jr") == true)
        for name in ["Beth", "Ellen", "Tim"] {
            #expect(claim?.requiredPersonNames.contains(name) == true, Comment(rawValue: name))
        }
        #expect(claim?.evidenceIDs.contains("@R@") == true)
        #expect(claim?.evidenceIDs.contains("uuid:tim") == true)
    }

    /// The two sources AGREE (the People tab's only child is the tree's, by
    /// its bridge): say it plainly, with no supplement clause and no
    /// double-counting.
    @Test func whenBothSourcesAgreeTheSentenceIsPlain() {
        let kin = Kin(profileName: "Dad", profileStableID: "dad",
                      children: [child("Rick", "son", gedcomID: "@R@")],
                      storedOn: ["Rick"])
        let card = HallieBiographyCard.card(for: person("@D@"), in: graph, peopleTab: kin)
        #expect(card.prose.contains(
            "The family tree records one child for him, Richard Harding Breen Jr."),
                Comment(rawValue: card.prose))
        #expect(!card.prose.contains("the People tab adds"), Comment(rawValue: card.prose))
        #expect(!card.prose.contains("In the People tab:"), Comment(rawValue: card.prose))
        #expect(!card.prose.contains("two children"), Comment(rawValue: card.prose))
    }

    /// No People-tab supplement at all (nobody in the People tab is this
    /// person): the plain sentence again, and the subject is named in full
    /// when the children sentence happens to lead the card.
    @Test func noPeopleTabSupplementReadsPlainly() {
        let card = HallieBiographyCard.card(for: person("@D@"), in: graph)
        #expect(card.prose.contains(
            "The family tree records one child for him, Richard Harding Breen Jr."),
                Comment(rawValue: card.prose))
        #expect(!card.prose.contains("People tab"), Comment(rawValue: card.prose))
        // Eileen's card opens with the children sentence (she has no
        // recorded dates and no parents here), so it must name her in full.
        let eileen = HallieBiographyCard.card(for: person("@E@"), in: graph)
        #expect(eileen.prose.hasPrefix("Eileen Latta was married to Richard Harding Breen Sr. "
                                       + "The family tree records one child for her, "
                                       + "Richard Harding Breen Jr."),
                Comment(rawValue: eileen.prose))
    }

    /// Several tree children read as a plain, attributed count.
    @Test func severalTreeChildrenAreCountedInWords() {
        let manyText = treeText.replacingOccurrences(of: "0 @FD@ FAM", with: """
            0 @R2@ INDI
            1 NAME Michael /Breen/
            1 SEX M
            1 FAMC @FD@
            0 @R3@ INDI
            1 NAME Ellen /Breen/
            1 SEX F
            1 FAMC @FD@
            0 @FD@ FAM
            """)
            .replacingOccurrences(of: "1 CHIL @R@", with: "1 CHIL @R@\n1 CHIL @R2@\n1 CHIL @R3@")
        let many = GedcomFamilyGraph(gedcomText: manyText)
        let card = HallieBiographyCard.card(for: many.people["@D@"]!, in: many)
        #expect(card.prose.contains("The family tree records three children for him, "),
                Comment(rawValue: card.prose))
        #expect(!card.prose.contains("recorded children"), Comment(rawValue: card.prose))
    }

    /// The tree records NO children: unchanged from before — the People tab
    /// speaks for itself and no count is stated either way.
    @Test func noTreeChildrenKeepsThePeopleTabSentenceAsItWas() {
        let kin = Kin(profileName: "Rick", profileStableID: "rick",
                      children: [child("Matt", "son")], storedOn: ["Rick"])
        let card = HallieBiographyCard.card(for: person("@R@"), in: graph, peopleTab: kin)
        #expect(card.prose.contains("In the People tab: Matt — son."), Comment(rawValue: card.prose))
        #expect(!card.prose.contains("The family tree records"), Comment(rawValue: card.prose))
    }
}
