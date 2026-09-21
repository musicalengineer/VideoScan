// HallieDadBreenAgeAtDeathTests.swift
//
// THE LIVE FAILURE, 2026-09-21 17:52:15Z (session 7B52B1A4, Rick, app):
//
//   Rick:   how old was dad breen when he passed?
//   Hallie: "Richard was 64–65 years old during 1994, depending on the
//            date [c1]."
//           Basis: Richard's People profile birthdate 1929-02-21; the
//           question supplied year 1994 without a month/day.
//
// (The ledger's first reading — a Matthew Rice biography — was a row from
// codex's replay session 1603DC26 interleaved in the shared transcript;
// Rick's own turn is the one above. The People-tab alias "Dad Breen" DID
// resolve to Richard Breen Sr.)
//
// Two defects, both in the temporal lane:
//   1. There was no age-AT-DEATH ask. "when he passed" was read as a plain
//      age, so the executor needed a reference date and used whatever the
//      AST carried.
//   2. The AST carried `explicitYear(1994)` — a year the question never
//      mentioned (the translator invented it) — and the executor trusted it.
//
// The People tab is the source of truth for the inner circle (Rick,
// 2026-09-04). Dad Breen: b. 21 Feb 1929, d. 25 Jun 2008 → 79.
//
// Five dimensions (feature-test checklist):
//   1. Logic     — the live AST, the honest AST, Ma Breen, a living person,
//                  "would be today", "in 1994" (a year the question DID say).
//   2. Scale     — n/a: bounded by the profile count (tens).
//   3. Media     — n/a (no media files opened).
//   4. Isolation — in-memory fixtures only; nothing reads App Support,
//                  UserDefaults or the real POI store.
//   5. Sensor    — the tree holds a same-surname stranger AND a Matthew Rice,
//                  and the People tab holds TWO Richard Breens; neither the
//                  stranger nor the second Richard may ever win over the
//                  alias "Dad Breen". A person with no recorded death never
//                  gets an age at death.
//
// The GEDCOM fixture is synthetic (2026-08-03 privacy policy). Its date for
// Dad is deliberately WRONG (12 MAR 1928, as the real FamilySearch import
// is) so a tree-sourced answer is visible as 80, not 79.

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
1 _FSFTID G2S4-JF4
1 BIRT
2 DATE 12 MAR 1928
1 DEAT
2 DATE 25 JUN 2008
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 _FSFTID G2CR-R4H
1 BIRT
2 DATE 31 AUG 1930
1 DEAT
2 DATE 3 MAR 2023
1 FAMS @F1@
0 @I4@ INDI
1 NAME Richard /Breen/
1 SEX M
1 BIRT
2 DATE 1901
1 DEAT
2 DATE 1960
0 @I5@ INDI
1 NAME Matthew /Rice/
1 SEX M
1 BIRT
2 DATE 28 FEB 1629
1 DEAT
2 DATE BEF 29 NOV 1717
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 TRLR
"""

@Suite("Hallie — 'how old was dad breen when he passed': age at death from the People tab", .serialized)
struct HallieDadBreenAgeAtDeathTests {
    typealias Exec = HallieTurnExecutor

    private let graph = GedcomFamilyGraph(gedcomText: tree)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private static let dadUUID = UUID(uuidString: "FF6C5474-EBB4-4D32-A9EF-B2D38647A146")!
    private static let rickUUID = UUID(uuidString: "71393E0E-0000-4000-8000-000000000001")!
    private static let maUUID = UUID(uuidString: "11892D85-0000-4000-8000-000000000002")!

    /// Rick's People tab as it stands on 2026-09-21 (POI/*/profile.json):
    /// TWO profiles named "Richard" with surname Breen; the alias is what
    /// tells them apart.
    private static let profiles: [Exec.ProfileSnapshot] = [
        .init(stableID: "dad", canonicalName: "Richard",
              aliases: ["Dad Breen", "Grampa Breen", "Dick"],
              birthdate: date(1929, 2, 21),
              kinships: [Kinship(relation: .parent, relativeTo: .profile(id: rickUUID))],
              sex: .male, uuid: dadUUID,
              treeIdentity: .familySearchID("G2S4-JF4"),
              deathdate: date(2008, 6, 25),
              surname: "Breen", middleName: "Harding", suffix: "Sr"),
        .init(stableID: "rick", canonicalName: "Richard",
              aliases: ["Dicky", "Rick"],
              birthdate: date(1959, 3, 4),
              kinships: [
                Kinship(relation: .child, relativeTo: .profile(id: dadUUID)),
                Kinship(relation: .child, relativeTo: .profile(id: maUUID)),
              ],
              sex: .male, uuid: rickUUID,
              treeIdentity: .familySearchID("GVQV-NW3"),
              surname: "Breen", middleName: "Harding", suffix: "Jr"),
        .init(stableID: "ma", canonicalName: "Eileen",
              aliases: ["Ma", "Ma Breen", "Eileen", "Gramma Breen"],
              birthdate: date(1930, 8, 31),
              kinships: [Kinship(relation: .parent, relativeTo: .profile(id: rickUUID))],
              sex: .female, uuid: maUUID,
              treeIdentity: .familySearchID("G2CR-R4H"),
              deathdate: date(2023, 3, 3),
              surname: "Breen", maidenName: "Latta", middleName: "Marie"),
    ]

    private var context: Exec.Context {
        Exec.Context(profiles: Self.profiles, graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                     archivistPersonName: nil),
                     mode: .tree)
    }

    private func temporal(
        _ question: String, subject: String,
        reference: ArchivistQueryAST.Temporal.Reference = .currentSelection
    ) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: question,
                ast: .temporal(.init(subject: subject, operation: .age, reference: reference)))),
            context: context)
    }

    // MARK: - The live turn

    /// THE live failure, with the AST the model actually produced: the
    /// subject "dad breen" and an INVENTED explicit year 1994.
    @Test func theLiveTurnAnswersSeventyNineFromThePeopleTab() async throws {
        let r = try await temporal(
            "how old was dad breen when he passed?", subject: "dad breen",
            reference: .explicitYear(1994))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("79"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2008"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1994"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("64"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("65"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Matthew Rice"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1629"), Comment(rawValue: r.prose))
        // The People tab is cited, not the tree (whose date would give 80).
        #expect(r.basisLine.contains("People profile"), Comment(rawValue: r.basisLine))
        #expect(!r.prose.contains("80"), Comment(rawValue: r.prose))
    }

    /// The same question with an honest translator (no reference at all).
    @Test func theHonestASTAnswersTheSame() async throws {
        let r = try await temporal(
            "how old was dad breen when he passed?", subject: "dad breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("79"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2008"), Comment(rawValue: r.prose))
    }

    /// "died", "passed away", "at his death" — the same ask.
    @Test func everyDeathWordingIsAnAgeAtDeathAsk() {
        typealias T = ArchivistTemporalExecutor
        #expect(T.detectAsk(in: "how old was dad breen when he passed?") == .ageAtDeath)
        #expect(T.detectAsk(in: "how old was Dad when he died") == .ageAtDeath)
        #expect(T.detectAsk(in: "what age did Ma Breen pass") == .ageAtDeath)
        #expect(T.detectAsk(in: "how old was ma breen when she passed away?") == .ageAtDeath)
        #expect(T.detectAsk(in: "how old was dad at his death") == .ageAtDeath)
        #expect(T.detectAsk(in: "what was dad's age at death") == .ageAtDeath)
        // Unchanged asks — including a death that is somebody ELSE's:
        // "how old was Donna when my dad died" asks Donna's age, not Donna's
        // age at death (ArchivistTemporalExecutorTests pins the answer).
        #expect(T.detectAsk(in: "how old was Donna when my dad died") == .age)
        #expect(T.detectAsk(in: "how old was Ma when Dad died") == .age)
        #expect(T.detectAsk(in: "how old was dad breen in 1994?") == .age)
        #expect(T.detectAsk(in: "how old is timmy") == .age)
        #expect(T.detectAsk(in: "were the boys born yet") == .bornYet)
        #expect(T.detectAsk(in: "how old would dad have been in 1994") == .wouldHaveBeen)
    }

    @Test func maBreenWasNinetyTwo() async throws {
        let r = try await temporal(
            "what age did Ma Breen pass", subject: "ma breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("92"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2023"), Comment(rawValue: r.prose))
    }

    // MARK: - Sensors: who "dad breen" must never become

    /// The second Richard Breen (Rick, b. 1959) never wins over the alias.
    @Test func theSecondRichardBreenNeverWinsOverTheAlias() async throws {
        let r = try await temporal(
            "how old was dad breen when he passed?", subject: "dad breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1959"), Comment(rawValue: r.prose))
        #expect(!r.prose.lowercased().contains("don't have a death date"), Comment(rawValue: r.prose))
        #expect(!r.prose.lowercased().contains("which"), Comment(rawValue: r.prose))
    }

    /// The tree's same-surname stranger (Richard Breen b. 1901, d. 1960)
    /// and Matthew Rice never win over a People-tab alias.
    @Test func aTreeStrangerNeverWinsOverThePeopleAlias() async throws {
        let r = try await temporal(
            "how old was dad breen when he passed?", subject: "dad breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1901"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1960"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("59"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Rice"), Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("family tree"), Comment(rawValue: r.basisLine))
    }

    /// "dad" alone, in Rick's session, is still Dad Breen — through Rick's
    /// own People-tab row ("child of Dad"), never a tree-wide name scan.
    @Test func bareDadInRicksSessionIsDadBreen() async throws {
        let r = try await temporal(
            "how old was dad when he passed?", subject: "dad")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("79"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2008"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1959"), Comment(rawValue: r.prose))
    }

    /// Someone with no recorded death never gets an age at death — an
    /// honest "nothing on file says so", not a number.
    @Test func aLivingPersonHasNoAgeAtDeath() async throws {
        let r = try await temporal(
            "how old was rick when he passed?", subject: "rick")
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose.lowercased().contains("death date"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("67"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("79"), Comment(rawValue: r.prose))
    }

    /// A name that is nobody on the People tab and nobody unique in the
    /// tree is never answered as someone else.
    @Test func anUnknownNameIsNeverAnsweredAsSomeoneElse() async throws {
        let r = try await temporal(
            "how old was uncle breen when he passed?", subject: "uncle breen")
        #expect(r.outcome != .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("79"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Rice"), Comment(rawValue: r.prose))
    }

    // MARK: - The invented year

    /// A year the question never said is not a reference: "how old was dad
    /// breen?" with a translator-invented 1994 asks for a year instead of
    /// answering 64–65.
    @Test func aYearTheQuestionNeverSaidIsIgnored() async throws {
        let r = try await temporal(
            "how old was dad breen?", subject: "dad breen",
            reference: .explicitYear(1994))
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("64"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1994"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("1994"), Comment(rawValue: r.basisLine))
    }

    /// A refined follow-up inherits its year from the previous turn on
    /// purpose ("what about Rick?" after "how old was dad breen in 1994"):
    /// the guard is for translator-fresh turns only.
    @Test func aRefinedFollowUpKeepsTheInheritedYear() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "what about rick?",
                ast: .temporal(.init(subject: "rick", operation: .age, reference: .explicitYear(1994))),
                refinementNote: "refining: age in 1994",
                refinementChange: "to Rick")),
            context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("34") && r.prose.contains("35"), Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("never mentions"), Comment(rawValue: r.basisLine))
    }

    /// A year the question DID say still works exactly as before.
    @Test func aYearTheQuestionSaidStillCounts() async throws {
        let r = try await temporal(
            "how old was dad breen in 1994?", subject: "dad breen",
            reference: .explicitYear(1994))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("64"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("65"), Comment(rawValue: r.prose))
    }

    // MARK: - "would be today"

    @Test func howOldWouldDadBreenBeTodayCountsToTodayAndSaysHePassed() async throws {
        let r = try await temporal(
            "how old would dad breen be today?", subject: "dad breen")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("would be"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("2008"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("79"), Comment(rawValue: r.prose))
        // 1929 → at least 97 on any day from 2026-02-21 on.
        let years = r.prose.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        #expect(years.contains(where: { $0 >= 97 && $0 < 130 }), Comment(rawValue: r.prose))
    }

    // MARK: - The session stays where the gate kept it

    /// The gate keeps a tree-mode session on an age question; the answer
    /// must say so, or memory derives catalog from the route and the
    /// transcript records `mode=catalog` (Rick's live row did).
    @Test func anAgeQuestionInTreeModeStaysInTreeMode() async throws {
        let r = try await temporal(
            "how old was dad breen when he passed?", subject: "dad breen")
        #expect(r.mode == .tree)
        // A catalog / unknown session is unchanged: nil, derived from the route.
        let catalogContext = Exec.Context(
            profiles: Self.profiles, graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            archivistPersonName: nil),
            mode: .catalog)
        let c = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "how old was dad breen when he passed?",
                ast: .temporal(.init(subject: "dad breen", operation: .age, reference: .currentSelection)))),
            context: catalogContext)
        #expect(c.mode == nil)
        #expect(c.prose.contains("79"), Comment(rawValue: c.prose))
    }

    // MARK: - "when did X die" (graph route, People-tab precedence)

    @Test func whenDidDadBreenDieComesFromThePeopleTab() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "when did dad breen die?",
                ast: .graph(.init(people: ["dad breen"], operation: .death)))),
            context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("2008"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1717"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1960"), Comment(rawValue: r.prose))
    }
}
