import Foundation
import Testing
@testable import VideoScanCore

/// Rick 2026-09-29, Donna's demo: Hallie said "The imported family tree
/// records …" before every fact — "so mechanistic and repetitive". The
/// telling now names the source once and groups the facts.
@Suite("Hallie biography — family-tree facts told once, naturally")
struct CyberBrainTreeTellingTests {
    typealias Fact = CyberBrainAnswerPlan.TreeFact

    private func latta(sex: String = "M") -> [Fact] {
        [.init(kind: .birth, date: "11 September 1835", subjectSex: sex),
         .init(kind: .death, date: "30 June 1898", subjectSex: sex),
         .init(kind: .parents, names: ["John C. Latta", "Priscilla Eldridge Shaw"], subjectSex: sex),
         .init(kind: .spouse, names: ["Cathrine Black Ralston"], subjectSex: sex),
         .init(kind: .children, names: ["William Latta", "Mary Latta", "John Latta"], subjectSex: sex)]
    }

    @Test func johnRobertLattaReadsLikeAPerson() {
        #expect(CyberBrainTreeTelling.sentences(latta(), subject: "John Robert Latta") ==
            "According to the family tree, John Robert Latta was born on 11 September 1835 and died on 30 June 1898. "
            + "His parents were John C. Latta and Priscilla Eldridge Shaw. He married Cathrine Black Ralston. "
            + "His children were William Latta, Mary Latta and John Latta.")
    }

    @Test func pronounsFollowTheRecordedSexAndFallBackToTheName() {
        let her = CyberBrainTreeTelling.sentences(latta(sex: "F"), subject: "Ellen Breen")
        #expect(her.contains("Her parents were") && her.contains("She married"))
        let unknown = CyberBrainTreeTelling.sentences(latta(sex: ""), subject: "Pat Lee")
        #expect(unknown.contains("Pat Lee's parents were") && unknown.contains("Pat Lee married"))
        #expect(!unknown.contains(" He ") && !unknown.contains(" She "))
    }

    @Test func aYearIsNeverReadAsADayAndQualifiedDatesStayVerbatim() {
        #expect(CyberBrainTreeTelling.onOrIn("1835") == "in 1835")
        #expect(CyberBrainTreeTelling.onOrIn("MAR 1835") == "in MAR 1835")
        #expect(CyberBrainTreeTelling.onOrIn("12 MAR 1920") == "on 12 MAR 1920")
        #expect(CyberBrainTreeTelling.onOrIn("March 1835") == "in March 1835")
        // Qualified dates are evidence: told verbatim, never re-interpreted.
        #expect(CyberBrainTreeTelling.onOrIn("ABT 1835") == "ABT 1835")
        #expect(CyberBrainTreeTelling.onOrIn("BEF 1900") == "BEF 1900")
        #expect(CyberBrainTreeTelling.onOrIn("BET 1830 AND 1835") == "BET 1830 AND 1835")
    }

    @Test func withNoDatesTheFirstFactCarriesTheAttribution() {
        let facts: [Fact] = [.init(kind: .parents, names: ["A Smith"], subjectSex: "M"),
                             .init(kind: .spouse, names: ["B Jones", "C Brown"], subjectSex: "M")]
        #expect(CyberBrainTreeTelling.sentences(facts, subject: "D Smith") ==
            "According to the family tree, his recorded parent was A Smith. He married B Jones and C Brown.")
    }

    /// SENSOR: a composed biography names the family tree ONCE, keeps the
    /// evidence sentences intact on the claims, and lets family notes follow.
    @Test func theComposedBiographySaysFamilyTreeOnce() {
        let sid = "gedcom:@I23@"
        var claims: [CyberBrainAnswerPlan.Claim] = latta().enumerated().map { i, f in
            .init(id: "\(sid):\(i)", text: "The imported family tree records fact \(i).", evidenceIDs: [sid],
                  confidence: .confirmed, treeFact: f)
        }
        claims.append(.init(id: "note.1", text: "According to Barry Latta, JR Latta was at Fort Wagner.",
                            evidenceIDs: ["source.notes"], confidence: .confirmed))
        let plan = CyberBrainAnswerPlan(subject: "John Robert Latta", answerState: .answered, claims: claims)
        let prose = CyberBrainDeterministicComposer.compose(plan)
        #expect(prose.components(separatedBy: "family tree").count - 1 == 1, "\(prose)")
        #expect(!prose.contains("The imported family tree records"))
        #expect(prose.contains("The family's notes add: According to Barry Latta, JR Latta was at Fort Wagner."))
        #expect(plan.claims[0].text == "The imported family tree records fact 0.", "evidence text unchanged")
    }

    @Test func aPlanEncodedBeforeTreeFactsStillDecodes() throws {
        let old = #"{"id":"c1","text":"t","evidenceIDs":["e"],"confidence":"confirmed"}"#
        let claim = try JSONDecoder().decode(CyberBrainAnswerPlan.Claim.self, from: Data(old.utf8))
        #expect(claim.treeFact == nil && claim.text == "t")
    }
}
