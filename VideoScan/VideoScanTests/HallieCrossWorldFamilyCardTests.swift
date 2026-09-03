// HallieCrossWorldFamilyCardTests.swift
// LIVE MISS #16 (Rick, 2026-08-29 17:27): "tell me about rick's family
// tree, his brothers, sisters, parents, and grandparents." → a tree-only
// card that listed FIVE grandparents (Mary Catherine O'Connor AND Mary
// O'Connor — Eileen Latta carries two FAMC lines on FamilySearch) and said
// nothing about siblings (Tim is a People-tab sibling row; the living are
// not on FamilySearch). Plus #18/#19 the same evening: "who is Rick's
// dad?" → "known as Dad" (no tree name, no dates, Dad unpinned), and
// "what is Dad's name and his birthdate?" → "can't trace father for Dad".
//
// Dimensions: LOGIC (detector, card, flag, deriver fixpoint, overlay
// vitals, property ask); ISOLATION (synthetic GEDCOM text + profile
// snapshots, no files, no defaults, no model); SENSORS (the exact live
// sentences pinned). The GEDCOM is synthetic (2026-08-03 privacy policy):
// only the FamilySearch IDs of the two Richards / Eileen / the two Marys
// are the real ones, so the flag sentence can be read against the live
// tree.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let treeText = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
1 _VS_ROOT @I10@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
2 PLAC Boston, Suffolk, Massachusetts
1 FAMC @F1@
1 FAMS @F5@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 22 FEB 1929
2 PLAC Albany, New York
1 DEAT
2 DATE 1 JUL 2008
1 FAMS @F1@
1 FAMC @F2@
1 _FSFTID G2S4-JF4
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
1 FAMS @F1@
1 FAMC @F3@
1 FAMC @F4@
1 _FSFTID G2CR-R4H
0 @I5@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 FAMS @F4@
1 FAMC @F6@
1 _FSFTID GNZ5-428
0 @I6@ INDI
1 NAME David McGill /Latta/ Sr
1 SEX M
1 FAMS @F3@
1 _FSFTID LX9M-WJG
0 @I7@ INDI
1 NAME Mary Catherine /O'Connor/
1 SEX F
1 FAMS @F3@
1 FAMC @F6@
1 _FSFTID G89Q-34N
0 @I8@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMS @F2@
0 @I9@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 FAMS @F2@
0 @I10@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMS @F5@
1 _FSFTID DONN-A03
0 @I14@ INDI
1 NAME Patrick /O'Connor/
1 SEX M
1 FAMS @F6@
0 @I40@ INDI
1 NAME Richard /Breen/
1 SEX M
1 BIRT
2 DATE 1929
1 _FSFTID RICH-C0Z
0 @I20@ INDI
1 NAME Isaac /Rice/
1 SEX M
1 FAMC @F20@
0 @I21@ INDI
1 NAME Matthew /Rice/
1 SEX M
1 FAMS @F20@
1 FAMC @F21@
0 @I22@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 FAMS @F20@
1 FAMC @F22@
0 @I23@ INDI
1 NAME Edmund /Rice/
1 SEX M
1 FAMS @F21@
0 @I24@ INDI
1 NAME Thomasine /Frost/
1 SEX F
1 FAMS @F21@
0 @I25@ INDI
1 NAME Barnaby /Lamson/
1 SEX M
1 FAMS @F22@
0 @I26@ INDI
1 NAME Mary /Ayer/
1 SEX F
1 FAMS @F22@
0 @I30@ INDI
1 NAME Step /Child/
1 SEX M
1 FAMC @F30@
1 FAMC @F31@
0 @I31@ INDI
1 NAME Amos /Child/
1 SEX M
1 FAMS @F30@
0 @I32@ INDI
1 NAME Zeke /Foster/
1 SEX M
1 FAMS @F31@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I8@
1 WIFE @I9@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I6@
1 WIFE @I7@
1 CHIL @I3@
0 @F4@ FAM
1 WIFE @I5@
1 CHIL @I3@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I10@
0 @F6@ FAM
1 HUSB @I14@
1 CHIL @I5@
1 CHIL @I7@
0 @F20@ FAM
1 HUSB @I21@
1 WIFE @I22@
1 CHIL @I20@
0 @F21@ FAM
1 HUSB @I23@
1 WIFE @I24@
1 CHIL @I21@
0 @F22@ FAM
1 HUSB @I25@
1 WIFE @I26@
1 CHIL @I22@
0 @F30@ FAM
1 HUSB @I31@
1 CHIL @I30@
0 @F31@ FAM
1 HUSB @I32@
1 CHIL @I30@
0 TRLR
"""

private let graph = GedcomFamilyGraph(gedcomText: treeText)

private typealias Profile = HallieTurnExecutor.ProfileSnapshot
private typealias Executor = HallieTurnExecutor

private func date(_ y: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = 6; c.day = 15
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
    Kinship(relation: relation, relativeTo: .profile(name: name))
}

/// Rick's People-tab rows the way Rick enters them (a row reads "Rick is
/// the <relation> of <anchor>"): sibling Tim, spouse Donna, child of Dad
/// and Ma, parent of Matt. Nobody else has rows.
private func profiles(rickPin: String? = "GVQV-NW3", dadPin: String? = nil,
                      dadAliases: [String] = ["Dick", "Dad Breen"],
                      maAliases: [String] = ["Eileen"]) -> [Profile] {
    [
        Profile(stableID: "rick", canonicalName: "Rick", aliases: ["Dicky", "Rich"],
                kinships: [row(.sibling, "Tim"), row(.spouse, "Donna"),
                           row(.child, "Dad"), row(.child, "Ma"), row(.parent, "Matt")],
                sex: .male, uuid: UUID(), treeIdentity: rickPin.map { .familySearchID($0) }),
        Profile(stableID: "tim", canonicalName: "Tim", aliases: ["Timmy"], sex: .male, uuid: UUID()),
        Profile(stableID: "donna", canonicalName: "Donna", sex: .female, uuid: UUID(),
                treeIdentity: .familySearchID("DONN-A03")),
        Profile(stableID: "dad", canonicalName: "Dad", aliases: dadAliases, birthdate: date(1929),
                sex: .male, uuid: UUID(), treeIdentity: dadPin.map { .familySearchID($0) }),
        Profile(stableID: "ma", canonicalName: "Ma", aliases: maAliases, birthdate: date(1930),
                sex: .female, uuid: UUID()),
        Profile(stableID: "matt", canonicalName: "Matt", sex: .male, uuid: UUID()),
    ]
}

private func context(_ profiles: [Profile], ownerFSID: String? = nil,
                     assumed: [String: String] = [:]) -> Executor.Context {
    Executor.Context(
        profiles: profiles, graph: graph,
        speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                        ownerFamilySearchID: ownerFSID),
        assumedTreeBridges: assumed)
}

private func ask(_ name: String, _ operation: ArchivistQueryAST.Graph.Operation,
                 relation: ArchivistQueryAST.Graph.Relation? = nil,
                 context: Executor.Context) async throws -> Executor.Result {
    try await Executor.execute(
        .graph(.init(people: [name], operation: operation, relation: relation)),
        context: context)
}

private let liveSentence =
    "tell me about rick's family tree, his brothers, sisters, parents, and grandparents."

/// Rick's 2026-09-02 ruling: the duplicate is never a SENTENCE any more —
/// prose names the primary family's mother only; this is the basis note.
/// (The fixture's two Marys carry no birth year, so no "b. 1905" here.)
private let flagNote =
    "(another record for her mother, Mary O'Connor, exists in the tree — same parents; treated as the same person)"
private let retiredFlagSentence = "The tree records two mothers"

// MARK: - Detector

@Suite("Cross-world family card — detector")
struct HallieCrossWorldFamilyCardDetectorTests {
    typealias Q = HallieLineageQuestion

    @Test func ricksLiveSentenceIsThePersonTreeCard() {
        #expect(Q.detect(liveSentence) == .personTree(person: "Rick"))
        let pre = Executor.preTranslation(
            question: liveSentence, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in true },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context(profiles())) })
        #expect(pre == .run(Executor.Intent(
            originalQuestion: liveSentence,
            ast: .graph(.init(people: ["Rick"], operation: .familyTree)))))
    }

    @Test func shortFormsAndTheOwner() {
        #expect(Q.detect("show me rick's family tree") == .personTree(person: "Rick"))
        #expect(Q.detect("Rick Breen's family tree") == .personTree(person: "Rick Breen"))
        #expect(Q.detect("tell me about donna's family tree and her parents") == .personTree(person: "Donna"))
        #expect(Q.detect("my family tree") == .personTree(person: nil))
        #expect(Q.detect("show me my family tree, parents and grandparents") == .personTree(person: nil))
    }

    @Test func otherTreeShapesKeepTheirOwners() {
        #expect(Q.detect("show the family tree for the latta family") == .surnameTree(surname: "latta"))
        #expect(Q.detect("the hudson family tree") == .surnameTree(surname: "hudson"))
        #expect(Q.detect("the family tree from rick breen all the way back to 1600")
                == .ancestorLine(person: "Rick Breen", line: .both, generations: Q.yearBoundGenerations, untilYear: 1600))
        // Depth words are not the card's categories.
        #expect(Q.personTreeQuestion(in: "rick's family tree back 3 generations") == nil)
        #expect(Q.personTreeQuestion(in: "his family tree") == nil)
        #expect(Q.personTreeQuestion(in: "the family's tree") == nil)
        #expect(Q.detect("center the family tree on martha lamson") == .centerTree(person: "Martha Lamson"))
    }
}

// MARK: - The card

@Suite("Cross-world family card — People-tab kin")
struct HallieCrossWorldFamilyCardTests {

    /// Rick pinned (the tree's Jr) + Tim as a sibling row on Rick: the card
    /// says the tree has no siblings and names Tim from the People tab,
    /// cited to the rows, and adds Matt as a People-tab child (the tree
    /// records none). Donna is in the tree, so no People-tab spouse line.
    @Test func pinnedSubjectGetsPeopleTabSiblingsAndChildren() async throws {
        let r = try await ask("Rick", .familyTree, context: context(profiles()))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("In the People tab: Tim — brother."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("The tree records no siblings for him."), Comment(rawValue: r.prose))
        #expect(r.prose.contains("In the People tab: Matt — son."), Comment(rawValue: r.prose))
        // Rick is living (born 1959, no death): present tense (2026-09-01).
        #expect(r.prose.contains("He is married to Donna Hudson."), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Donna — wife"))
        #expect(r.prose.hasPrefix("Richard Harding Breen Jr (Rick in the People tab) was born 4 March 1959 in Boston, Suffolk, Massachusetts."),
                Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("People tab relationships (stored on Rick's profile)"), Comment(rawValue: r.basisLine))
        // The sibling claim cites the subject's record and Tim's profile identity.
        let plan = try #require(r.answerPlan)
        let sibling = try #require(plan.claims.first { $0.text == "In the People tab: Tim — brother." })
        #expect(sibling.evidenceIDs.first == "@I1@")
        #expect(sibling.evidenceIDs.count == 2)
        #expect(sibling.evidenceIDs[1].hasPrefix("uuid:") || sibling.evidenceIDs[1].hasPrefix("profile:"))
        // Same card for the biography ask.
        #expect(try await ask("Rick", .biography, context: context(profiles())).prose == r.prose)
    }

    /// The owner chain (FamilySearch ID setting) selects the record before
    /// any profile is consulted; the pinned profile on that record still
    /// brings its rows.
    @Test func ownerSelectedSubjectStillBridgesToTheProfile() async throws {
        let r = try await ask("Rick", .familyTree, context: context(profiles(), ownerFSID: "GVQV-NW3"))
        #expect(r.prose.contains("In the People tab: Tim — brother."), Comment(rawValue: r.prose))
    }

    /// Asked by the tree's own spelling with Rick's profile UNPINNED, no
    /// bridge exists — nothing from the People tab is attached, even
    /// though a Tim row sits on Rick's profile. Never invented.
    @Test func unbridgedSubjectHasNoPeopleTabLine() async throws {
        let r = try await ask("Richard Harding Breen Jr", .familyTree, context: context(profiles(rickPin: nil)))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("People tab"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Tim"))
        #expect(!r.basisLine.contains("People tab"))
        #expect(r.prose.hasPrefix("Richard Harding Breen Jr was born"))
    }

    @Test func treeOnlyPersonIsUnchanged() async throws {
        let r = try await ask("Isaac Rice", .familyTree, context: context(profiles()))
        // This fixture's Isaac has no dates and nobody dated around him, so
        // LifeStatus (2026-09-01) reads him as living — "is the child of".
        #expect(r.prose == "Isaac Rice is the child of Martha Lamson and Matthew Rice; "
                + "his recorded grandparents were Barnaby Lamson, Edmund Rice, Mary Ayer and Thomasine Frost. "
                + "His family tree includes 6 recorded ancestors across 2 generations.", Comment(rawValue: r.prose))
        #expect(r.offeredActions == [.openFamilyTree(personName: "Isaac Rice")])
    }
}

// MARK: - Duplicate-parent flag

@Suite("Cross-world family card — duplicate parent flag")
struct HallieDuplicateParentFlagTests {

    /// Rick's 2026-09-02 ruling reversed the pre-ruling expectation here:
    /// this test used to pin FIVE grandparents and a "two mothers"
    /// sentence in the prose. Now: four grandparents, no such sentence,
    /// the note in the basis, and the duplicate chip still offered.
    @Test func eileensDuplicateMotherIsFoldedOnRicksCardAndTheChipStays() async throws {
        let r = try await ask("Rick", .familyTree, context: context(profiles()))
        #expect(r.prose.contains("his recorded grandparents were David McGill Latta Sr, George Breen, Mary Catherine O'Connor and Muriel Lamb."),
                Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Mary O'Connor,"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains(retiredFlagSentence), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains(" For Eileen Latta: \(flagNote)"), Comment(rawValue: r.basisLine))
        #expect(r.offeredActions == [
            .openFamilyTree(personName: "Richard Harding Breen Jr"),
            .showPossibleDuplicate(personID: "@I3@", personName: "Eileen Latta"),
        ])
        #expect(Executor.offerLabel(.showPossibleDuplicate(personID: "@I3@", personName: "Eileen Latta"))
                == "Show possible duplicate in Family Tree")
        let plan = try #require(r.answerPlan)
        #expect(!plan.claims.contains { $0.text.contains(retiredFlagSentence) })
    }

    @Test func theNoteIsInTheBasisOfEileensOwnCard() async throws {
        let r = try await ask("Eileen Latta", .biography, context: context(profiles()))
        #expect(r.prose.contains("child of David McGill Latta Sr and Mary Catherine O'Connor"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Mary O'Connor,"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains(retiredFlagSentence), Comment(rawValue: r.prose))
        #expect(r.basisLine.hasSuffix(" \(flagNote)"), Comment(rawValue: r.basisLine))
        #expect(r.offeredActions == [.showPossibleDuplicate(personID: "@I3@", personName: "Eileen Latta")])
        let flags = HallieBiographyCard.dataQualityFlags(for: graph.people["@I3@"]!, in: graph)
        #expect(flags.count == 1)
        #expect(flags[0].role == "mothers")
        #expect(flags[0].looksLikeDuplicate)
        #expect(flags[0].parents.map(\.id) == ["@I6@", "@I7@", "@I5@"])
        #expect(flags[0].evidenceIDs == ["@I3@", "@I6@", "@I7@", "@I5@"])
        #expect(flags[0].text == flagNote)
    }

    @Test func twoParentsFourGrandparentsRaiseNothing() async throws {
        #expect(HallieBiographyCard.dataQualityFlags(for: graph.people["@I20@"]!, in: graph).isEmpty)
        #expect(HallieBiographyCard.dataQualityFlags(for: graph.people["@I2@"]!, in: graph).isEmpty)
        let r = try await ask("Isaac Rice", .familyTree, context: context(profiles()))
        #expect(!r.prose.contains("The tree records"))
        #expect(!r.basisLine.contains("another record"), Comment(rawValue: r.basisLine))
        #expect(!r.offeredActions.contains { if case .showPossibleDuplicate = $0 { return true } else { return false } })
    }

    /// Two fathers with unrelated names: a genuine second family. Prose
    /// names the first (GEDCOM order breaks the tie); the basis says a
    /// second family is recorded and to ask about it by name.
    @Test func unrelatedNamesAreFlaggedWithoutTheDuplicateReading() async throws {
        let flags = HallieBiographyCard.dataQualityFlags(for: graph.people["@I30@"]!, in: graph)
        #expect(flags.count == 1)
        #expect(!flags[0].looksLikeDuplicate)
        #expect(flags[0].role == "fathers")
        #expect(flags[0].text == "A second parent family is recorded (father Zeke Foster, @I32@); ask about it by name.")
        let r = try await ask("Step Child", .kinship, relation: .father, context: context(profiles()))
        #expect(r.prose == "Step Child's father: Amos Child.", Comment(rawValue: r.prose))
        #expect(r.basisLine.hasSuffix(" A second parent family is recorded (father Zeke Foster, @I32@); ask about it by name."),
                Comment(rawValue: r.basisLine))
    }

    /// "who are eileen's parents" — two people, not three; the fold note
    /// rides in the basis.
    @Test func eileensParentsAreTwoPeople() async throws {
        let r = try await ask("Eileen Latta", .kinship, relation: .parents, context: context(profiles()))
        #expect(r.prose == "Eileen Latta's parents: David McGill Latta Sr, Mary Catherine O'Connor.", Comment(rawValue: r.prose))
        #expect(r.basisLine.hasSuffix(" \(flagNote)"), Comment(rawValue: r.basisLine))
        let m = try await ask("Eileen Latta", .kinship, relation: .mother, context: context(profiles()))
        #expect(m.prose == "Eileen Latta's mother: Mary Catherine O'Connor.", Comment(rawValue: m.prose))
        #expect(m.basisLine.hasSuffix(" \(flagNote)"), Comment(rawValue: m.basisLine))
    }
}

// MARK: - Dad: derived pin, tree name + vitals, property ask

@Suite("Cross-world — Dad through Rick's rows")
struct HallieCrossWorldDadTests {

    /// Rick derives from the owner setting in pass 1; in pass 2 Rick's
    /// "child of Dad" row reaches a pinned record, so "Dad" (alias Dick →
    /// every Richard: Sr AND the cousin Richard Breen b. 1929, ambiguous by
    /// name and birth alone) settles on Jr's one recorded father, and "Ma"
    /// on his mother. Tim has no record and is never assumed.
    @Test func assumedPinsReachAFixpointThroughRicksRows() {
        // Pass 1 alone cannot settle Dad: two compatible Richards.
        let cold = TreeIdentityDeriver(
            graph: graph, subjects: profiles(rickPin: nil).map(TreeIdentitySubject.init),
            ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        #expect(cold.derive(TreeIdentitySubject(profiles().first { $0.stableID == "dad" }!)).certainCandidate == nil)

        let out = TreeIdentityDeriver.assumingCertainPins(
            snapshots: profiles(rickPin: nil), graph: graph,
            ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        #expect(out.assumed["@I1@"] == "Rick as Richard Harding Breen Jr")
        #expect(out.assumed["@I2@"] == "Dad as Richard Harding Breen Sr")
        #expect(out.assumed["@I3@"] == "Ma as Eileen Latta")
        #expect(out.snapshots.first { $0.stableID == "dad" }?.treeIdentity == .familySearchID("G2S4-JF4"))
        #expect(out.snapshots.first { $0.stableID == "tim" }?.treeIdentity == nil)
        #expect(out.snapshots.first { $0.stableID == "matt" }?.treeIdentity == nil)
    }

    /// No name evidence at all ("Ma" with only "Ma Breen"): the rows alone
    /// decide, and the reason says so; the People tab would still ask.
    @Test func rowsAloneDeriveWhenTheNameSaysNothing() {
        let snapshots = profiles(rickPin: "GVQV-NW3", maAliases: ["Ma Breen"])
        let deriver = TreeIdentityDeriver(
            graph: graph, subjects: snapshots.map(TreeIdentitySubject.init),
            ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        let verdict = deriver.derive(TreeIdentitySubject(snapshots.first { $0.stableID == "ma" }!))
        #expect(verdict == .certain(TreeIdentityCandidate(graph.people["@I3@"]!), reason: .kinshipToPinned))
        #expect(!verdict.isAutoAcceptable)
        // Without Rick pinned there is nothing to reason from.
        let cold = TreeIdentityDeriver(
            graph: graph, subjects: profiles(rickPin: nil, maAliases: ["Ma Breen"]).map(TreeIdentitySubject.init),
            ownerName: nil, ownerFamilySearchID: nil)
        #expect(cold.derive(TreeIdentitySubject(snapshots.first { $0.stableID == "ma" }!)).certainCandidate == nil)
    }

    /// "who is Rick's dad?" with Dad bridged: the tree's name and dates,
    /// the People-tab name as the alias, both sources in the basis.
    @Test func ricksFatherIsAnsweredWithTheTreeNameAndVitals() async throws {
        let r = try await ask("Rick", .kinship, relation: .father,
                              context: context(profiles(dadPin: "G2S4-JF4")))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose == "Rick's father: Richard Harding Breen Sr (Dad in the People tab), born 22 February 1929 in Albany, New York, died 1 July 2008.",
                Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("stored on Rick's profile"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("GEDCOM: Richard Harding Breen Sr @I2@"), Comment(rawValue: r.basisLine))
        // Unbridged Dad: the People-tab name alone, as before.
        let plain = try await ask("Rick", .kinship, relation: .father, context: context(profiles()))
        #expect(plain.prose == "Rick's father: Dad.", Comment(rawValue: plain.prose))
    }

    /// The bridge assumed for the turn is said out loud.
    @Test func anAssumedBridgeIsSaidInTheAnswer() async throws {
        let out = TreeIdentityDeriver.assumingCertainPins(
            snapshots: profiles(rickPin: nil), graph: graph,
            ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        let r = try await ask("Rick", .kinship, relation: .father,
                              context: context(out.snapshots, ownerFSID: "GVQV-NW3", assumed: out.assumed))
        #expect(r.prose.hasPrefix("Rick's father: Richard Harding Breen Sr (Dad in the People tab), born 22 February 1929"), Comment(rawValue: r.prose))
        #expect(r.prose.contains(" (taking "), Comment(rawValue: r.prose))
        #expect(r.prose.hasSuffix("Dad as Richard Harding Breen Sr)"), Comment(rawValue: r.prose))
    }

    @Test func propertyAskDetector() {
        #expect(HalliePropertyAsk.detect("what is Dad's name and his birthdate?") == "Dad")
        #expect(HalliePropertyAsk.detect("What's Ma's birthday") == "Ma")
        #expect(HalliePropertyAsk.detect("tell me grampa breen's full name") == "Grampa Breen")
        #expect(HalliePropertyAsk.detect("what is my name") == "me")
        #expect(HalliePropertyAsk.detect("who is Rick's dad?") == nil)
        #expect(HalliePropertyAsk.detect("what is my dad's name") == nil)
        #expect(HalliePropertyAsk.detect("what is rick's dad's name") == nil)
        #expect(HalliePropertyAsk.detect("what is his name") == nil)
        #expect(HalliePropertyAsk.detect("show me dad's photo") == nil)
        #expect(HalliePropertyAsk.detect("videos of dad's birthday") == nil)
    }

    /// The exact live sentence becomes a biography ask about Dad; with Dad
    /// bridged the card leads with both names and the recorded dates.
    @Test func dadsNameAndBirthdateIsABiographyOfDad() async throws {
        let live = "what is Dad's name and his birthdate?"
        let pre = Executor.preTranslation(
            question: live, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { PersonResolver.normalize($0) == "dad" })
        #expect(pre == .run(Executor.Intent(
            originalQuestion: live, ast: .graph(.init(people: ["Dad"], operation: .biography)))))
        let r = try await ask("Dad", .biography, context: context(profiles(dadPin: "G2S4-JF4")))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Richard Harding Breen Sr (Dad in the People tab) was born 22 February 1929 in Albany, New York and died 1 July 2008."),
                Comment(rawValue: r.prose))
        // Jr is in the tree as Sr's child, so no People-tab child line.
        #expect(r.prose.contains("He had 1 recorded child, Richard Harding Breen Jr."), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Rick — son"))
        // A stranger's possessive is not routed.
        let stranger = Executor.preTranslation(
            question: live, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false })
        if case .run = stranger { Issue.record("unknown subject must not become a biography ask") }
    }
}
