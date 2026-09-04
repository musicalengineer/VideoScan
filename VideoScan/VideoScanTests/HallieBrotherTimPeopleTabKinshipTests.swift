// HallieBrotherTimPeopleTabKinshipTests.swift
//
// THE LIVE FAILURE, 2026-09-04 18:51:37Z, the evening before Rick demoed
// Hallie to his brother Tim (session 8D5D6499, route=graph,
// outcome=declined, queryDescription "kinship-apposition: Richard Harding
// Breen Jr brother Tim"):
//
//   Rick:   tell me about my brother tim
//   Hallie: "The family tree doesn't record a brother for Richard Harding
//            Breen Jr, so I can't check for a Tim."
//
// while "who is Tim" answered fully from his People profile in the same
// session. She resolved "my brother" through the GEDCOM alone. The GEDCOM
// is a FamilySearch import with no siblings for Rick at all — it is also
// wrong about both his parents' dates — and the People tab holds the
// answer twice over: Rick's profile carries sibling→Tim, sibling→Ellen,
// sibling→Beth, and Tim's own note opens "Tim is Rick's younger brother."
//
// Rick's ruling, 2026-09-04: "The people tab should be the source for the
// immediate contemporary people in the people tab."
//
// Five dimensions (feature-test checklist):
//   1. Logic     — the four live questions plus the tree-only control.
//   2. Scale     — n/a here: the overlay is bounded by the PROFILE count
//                  (tens); FamilyKinshipTests owns the 500-profile budget.
//   3. Media     — n/a (no media files opened).
//   4. Isolation — every profile is an in-memory fixture; nothing reads
//                  ~/Library/Application Support, UserDefaults or the real
//                  POI store.
//   5. Sensor    — `aBrotherNamedFredIsStillDeclined…` is the safety pin:
//                  a kinship phrase naming someone who is NOT that relative
//                  must never become an answer about a namesake.
//
// The GEDCOM fixture is synthetic (2026-08-03 privacy policy) and mirrors
// the real shape: Rick with both parents and NO recorded siblings, plus a
// tree-only branch (Walter and Nora) and a tree-only Fred who is nobody's
// brother.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 12 MAR 1928
1 DEAT
2 DATE 25 JUN 2008
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
1 FAMS @F1@
0 @I4@ INDI
1 NAME Fred /Breen/
1 SEX M
1 BIRT
2 DATE 1901
1 FAMC @F2@
0 @I5@ INDI
1 NAME Walter /Breen/
1 SEX M
1 BIRT
2 DATE 1903
1 FAMC @F2@
0 @I6@ INDI
1 NAME Nora /Breen/
1 SEX F
1 BIRT
2 DATE 1906
1 FAMC @F2@
0 @I7@ INDI
1 NAME Albert /Breen/
1 SEX M
1 FAMS @F2@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 CHIL @I4@
1 CHIL @I5@
1 CHIL @I6@
0 TRLR
"""

@Suite("Hallie — 'tell me about my brother tim': the People tab resolves speaker kinship", .serialized)
struct HallieBrotherTimPeopleTabKinshipTests {
    typealias Exec = HallieTurnExecutor
    typealias A = HallieKinshipApposition

    private let graph = GedcomFamilyGraph(gedcomText: tree)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    /// Rick's People tab as it actually stands (verified in
    /// ~/Library/Application Support/VideoScan/POI/rick/profile.json,
    /// 2026-09-04): three sibling rows stored ON Rick's own profile.
    private static let profiles: [Exec.ProfileSnapshot] = [
        .init(stableID: "rick", canonicalName: "Rick",
              aliases: ["Dicky", "Rich", "Richy", "Richard"],
              birthdate: date(1959, 3, 4),
              kinships: [
                Kinship(relation: .sibling, relativeTo: .profile(name: "Tim")),
                Kinship(relation: .sibling, relativeTo: .profile(name: "Ellen")),
                Kinship(relation: .sibling, relativeTo: .profile(name: "Beth")),
              ],
              sex: .male,
              treeIdentity: .familySearchID("GVQV-NW3")),
        .init(stableID: "tim", canonicalName: "Tim", aliases: [],
              birthdate: date(1960, 6, 21),
              note: "Tim is Rick's younger brother. He worked at Lee Machine.",
              sex: .male),
        .init(stableID: "ellen", canonicalName: "Ellen", birthdate: date(1961, 12, 2),
              sex: .female),
        .init(stableID: "beth", canonicalName: "Beth", birthdate: date(1962, 2, 25),
              sex: .female),
    ]

    private var context: Exec.Context {
        Exec.Context(profiles: Self.profiles, graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }

    /// The same context with EVERY relationship row removed — the "People
    /// tab knows nothing" control, which must behave exactly as main did.
    private var contextWithoutRows: Exec.Context {
        Exec.Context(
            profiles: Self.profiles.map {
                Exec.ProfileSnapshot(
                    stableID: $0.stableID, canonicalName: $0.canonicalName,
                    aliases: $0.aliases, birthdate: $0.birthdate, note: $0.note,
                    kinships: [], sex: $0.sex, uuid: nil,
                    treeIdentity: $0.treeIdentity)
            },
            graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            archivistPersonName: nil))
    }

    private func run(_ question: String, in context: Exec.Context? = nil) async throws -> Exec.Result {
        let context = context ?? self.context
        switch Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) }
        ) {
        case .run(let intent):
            return try await Exec.execute(.init(intent: intent), context: context)
        case .answer(let result):
            return result
        case .translate:
            Issue.record("“\(question)” went to the model translator")
            throw CancellationError()
        }
    }

    // MARK: - The demo question

    /// THE live failure. Named for it.
    @Test func tellMeAboutMyBrotherTimNoLongerDeclinesForLackOfATreeSibling() async throws {
        let r = try await run("tell me about my brother tim")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("doesn't record a brother"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("can't check for a Tim"), Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Tim is your brother."), Comment(rawValue: r.prose))
        // Answered about Tim with what the People profile holds — the same
        // facts "who is Tim" speaks.
        #expect(r.prose.contains("21 June 1960") || r.prose.contains("June 21, 1960")
                || r.prose.lowercased().contains("1960"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Lee Machine"), Comment(rawValue: r.prose))
        // The basis names the People tab as the source of the relationship.
        #expect(r.basisLine.contains("People tab relationship"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("Rick's profile"), Comment(rawValue: r.basisLine))
    }

    /// The parse itself is unchanged — the defect was never in the parser.
    @Test func theDemoQuestionStillParsesAsAnApposition() {
        let q = A.parse("tell me about my brother tim")
        #expect(q?.possessor == nil)
        #expect(q?.kin == .single(.brother))
        #expect(q?.name == "Tim")
        // And the People tab can express it, so the overlay is consulted.
        #expect(q?.overlayRelation?.relation == .sibling)
        #expect(q?.overlayRelation?.sex == .male)
        // A great-grand ask and a sided ask cannot be a typed row: the tree
        // alone answers those, exactly as before.
        #expect(A.parse("rick's great great great grandpa john")?.overlayRelation == nil)
        #expect(A.parse("rick's maternal grandmother edith")?.overlayRelation == nil)
    }

    // MARK: - Kinship alone

    /// "tell me about my brother" and "who are my sisters" reach the graph
    /// route as a bare kinship (the apposition shape needs a trailing
    /// name). This is the AST the live session produced —
    /// `shape=graph operation=kinship person=Rick Breen relation=brother`.
    private func kinshipTurn(_ relation: ArchivistQueryAST.Graph.Relation,
                             in context: Exec.Context? = nil) async throws -> Exec.Result {
        let context = context ?? self.context
        return try await Exec.execute(
            .init(intent: .init(originalQuestion: "my \(relation.rawValue)",
                                ast: .graph(.init(people: ["me"], operation: .kinship,
                                                  relation: relation)))),
            context: context)
    }

    @Test func tellMeAboutMyBrotherNamesTim() async throws {
        let r = try await kinshipTurn(.brother)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Tim"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("doesn't record"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("People tab relationship"), Comment(rawValue: r.basisLine))
    }

    @Test func whoAreMySistersNamesEllenAndBeth() async throws {
        let r = try await kinshipTurn(.sister)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Ellen"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Beth"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Tim"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("People tab relationship"), Comment(rawValue: r.basisLine))
    }

    /// Two men could be "my brother Tim" — one from each store. The union
    /// asks which one; it never silently prefers a store.
    @Test func aTimInEachStoreAsksWhichOne() async throws {
        let treeWithABrother = GedcomFamilyGraph(gedcomText: tree
            .replacingOccurrences(of: "1 CHIL @I1@", with: "1 CHIL @I1@\n1 CHIL @I8@")
            .replacingOccurrences(of: "0 @F1@ FAM", with: """
            0 @I8@ INDI
            1 NAME Tim /Breen/
            1 SEX M
            1 BIRT
            2 DATE 1971
            1 FAMC @F1@
            0 @F1@ FAM
            """))
        let context = Exec.Context(
            profiles: Self.profiles, graph: treeWithABrother,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            archivistPersonName: nil))
        let r = try await run("tell me about my brother tim", in: context)
        #expect(r.outcome == .needsClarification, Comment(rawValue: r.prose))
        #expect(r.prose.contains("2 brothers named Tim"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Tim Breen (b. 1971)"), Comment(rawValue: r.prose))
        #expect(r.offeredActions.count == 2)
    }

    // MARK: - NEGATIVE: a declined relationship must not become the wrong person

    /// SENSOR. "Fred" is a real man in the tree — and nobody's brother. The
    /// People tab records one brother, Tim. The answer must name the set
    /// and stop; it must NEVER become a biography of the tree's Fred.
    @Test func aBrotherNamedFredIsStillDeclinedAndNeverBecomesTheTreesFred() async throws {
        let r = try await run("tell me about my brother fred")
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose.contains("I don't find a Fred there"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Tim"), Comment(rawValue: r.prose))
        // Nothing about the tree's Fred Breen leaked into the answer.
        #expect(!r.prose.contains("1901"), Comment(rawValue: r.prose))
        #expect(r.catalogPersonName != "Fred Breen")
        #expect(r.queryDescription?.contains("→ Fred") != true, Comment(rawValue: r.queryDescription ?? ""))
    }

    /// A relation NEITHER store records: today's honest decline, unchanged.
    @Test func aRelationNeitherStoreRecordsKeepsTheHonestDecline() async throws {
        let r = try await run("tell me about my daughter sarah")
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose == "The family tree doesn't record a daughter for Richard Harding Breen Jr, so I can't check for a Sarah.",
                Comment(rawValue: r.prose))
    }

    /// The pre-fix behaviour, pinned: with the rows removed, the decline is
    /// word for word what Rick saw on 2026-09-04.
    @Test func withNoPeopleTabRowsTheOldDeclineIsUnchanged() async throws {
        let r = try await run("tell me about my brother tim", in: contextWithoutRows)
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose == "The family tree doesn't record a brother for Richard Harding Breen Jr, so I can't check for a Tim.",
                Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("People tab relationship"), Comment(rawValue: r.basisLine))
    }

    // MARK: - Tree-only people are untouched

    @Test func aTreeOnlyPersonAnswersFromTheTreeExactlyAsBefore() async throws {
        let r = try await run("walter's sister nora")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Nora Breen (b. 1906) is Walter’s sister."),
                Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("People tab relationship"), Comment(rawValue: r.basisLine))
    }

    @Test func aTreeOnlyNameThatIsNotThatRelativeStillDeclines() async throws {
        let r = try await run("walter's sister agnes")
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Nora Breen"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("I don't find an Agnes there"), Comment(rawValue: r.prose))
    }

    // MARK: - The seam itself

    @Test func theOverlayIsOnlyConsultedWhenItHoldsARowForTheRelation() throws {
        let rick = try #require(graph.people["@I1@"])
        let brother = try #require(A.parse("my brother tim"))
        #expect(HallieLineageAnswer.peopleTabApposition(brother, subject: rick, context: context) != nil)
        // No row for this relation → nil, and the tree walk stands alone.
        let daughter = try #require(A.parse("my daughter sarah"))
        #expect(HallieLineageAnswer.peopleTabApposition(daughter, subject: rick, context: context) == nil)
        // No rows at all → nil.
        #expect(HallieLineageAnswer.peopleTabApposition(
            brother, subject: rick, context: contextWithoutRows) == nil)
    }
}
