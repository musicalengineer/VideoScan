import Testing
import Foundation
@testable import VideoScanCore

// "How is A related to B?" over a synthetic four-generation tree (no real
// family data — 2026-08-03 privacy policy). Pins the 2026-08-18 fix for
// Hallie's failed softball "how am I related to you?": the path is found in
// either direction, named with generation counts and sex-aware words, and
// the spoken route reads from A's point of view.
struct GedcomRelationshipPathTests {

    /// Hattie + Sam Hill → daughter Grace Hill (m. Peter Stone) → sons Al Stone
    /// (m. Mae Lake) and Bob Stone → Al's son Rick Stone (m. Dawn Field) →
    /// Tim Stone. Bob's daughter Cara → Dee. Dawn's parents Hal + Ivy Field,
    /// brother Fay Field. Zed Solo is unconnected.
    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hattie /Hill/
    1 SEX F
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Sam /Hill/
    1 SEX M
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Grace /Hill/
    1 SEX F
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Peter /Stone/
    1 SEX M
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Al /Stone/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F3@
    0 @I6@ INDI
    1 NAME Mae /Lake/
    1 SEX F
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Bob /Stone/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F4@
    0 @I8@ INDI
    1 NAME Rick /Stone/
    1 SEX M
    1 FAMC @F3@
    1 FAMS @F5@
    0 @I9@ INDI
    1 NAME Dawn /Field/
    1 SEX F
    1 FAMC @F6@
    1 FAMS @F5@
    0 @I10@ INDI
    1 NAME Tim /Stone/
    1 SEX M
    1 FAMC @F5@
    0 @I11@ INDI
    1 NAME Cara /Stone/
    1 SEX F
    1 FAMC @F4@
    1 FAMS @F7@
    0 @I12@ INDI
    1 NAME Dee /Stone/
    1 SEX F
    1 FAMC @F7@
    0 @I13@ INDI
    1 NAME Hal /Field/
    1 SEX M
    1 FAMS @F6@
    0 @I14@ INDI
    1 NAME Ivy /Field/
    1 SEX F
    1 FAMS @F6@
    0 @I15@ INDI
    1 NAME Fay /Field/
    1 SEX M
    1 FAMC @F6@
    0 @I16@ INDI
    1 NAME Zed /Solo/
    1 SEX M
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I1@
    1 CHIL @I3@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I3@
    1 CHIL @I5@
    1 CHIL @I7@
    0 @F3@ FAM
    1 HUSB @I5@
    1 WIFE @I6@
    1 CHIL @I8@
    0 @F4@ FAM
    1 HUSB @I7@
    1 CHIL @I11@
    0 @F5@ FAM
    1 HUSB @I8@
    1 WIFE @I9@
    1 CHIL @I10@
    0 @F6@ FAM
    1 HUSB @I13@
    1 WIFE @I14@
    1 CHIL @I9@
    1 CHIL @I15@
    0 @F7@ FAM
    1 WIFE @I11@
    1 CHIL @I12@
    0 TRLR
    """

    private let graph = GedcomFamilyGraph(gedcomText: Self.tree)

    private func person(_ first: String) -> GedcomFamilyGraph.Person {
        graph.people(matching: first)[0]
    }

    /// (relation word, spoken route) from A to B, or nil when unrelated.
    private func relate(_ a: String, _ b: String) -> (String?, String)? {
        guard let path = graph.relationshipPath(from: person(a), to: person(b)) else {
            return nil
        }
        let described = graph.describe(path)
        return (described.relation, described.route)
    }

    // MARK: The reported question: owner → archivist = great-grandmother

    @Test func greatGrandmotherWithSpokenRoute() {
        let result = relate("Rick", "Hattie")
        #expect(result?.0 == "great-grandmother")
        #expect(result?.1 == "father's mother's mother")
    }

    @Test func directionReversalNamesTheDescendant() {
        let result = relate("Hattie", "Rick")
        #expect(result?.0 == "great-grandson")
        #expect(result?.1 == "daughter's son's son")
        #expect(relate("Hattie", "Tim")?.0 == "great-great-grandson")
        #expect(relate("Tim", "Sam")?.0 == "great-great-grandfather")
    }

    @Test func parentsGrandparentsAndSpouses() {
        #expect(relate("Rick", "Al")?.0 == "father")
        #expect(relate("Al", "Rick")?.0 == "son")
        #expect(relate("Rick", "Grace")?.0 == "grandmother")
        #expect(relate("Rick", "Dawn")?.0 == "wife")
        #expect(relate("Dawn", "Rick")?.0 == "husband")
        #expect(relate("Rick", "Dawn")?.1 == "wife")
    }

    @Test func siblingsAuntsUnclesNiecesNephews() {
        #expect(relate("Dawn", "Fay")?.0 == "brother")
        #expect(relate("Rick", "Bob")?.0 == "uncle")
        #expect(relate("Bob", "Rick")?.0 == "nephew")
        #expect(relate("Tim", "Bob")?.0 == "great-uncle")
        #expect(relate("Bob", "Tim")?.0 == "great-nephew")
    }

    @Test func cousinsWithDegreeAndRemoval() {
        #expect(relate("Rick", "Cara")?.0 == "first cousin")
        #expect(relate("Rick", "Cara")?.1 == "father's mother's son's daughter"
                || relate("Rick", "Cara")?.1 == "father's father's son's daughter")
        #expect(relate("Rick", "Dee")?.0 == "first cousin once removed")
        #expect(relate("Dee", "Rick")?.0 == "first cousin once removed")
        #expect(relate("Tim", "Dee")?.0 == "second cousin")
    }

    @Test func inLawsAreOneAffinalHopAtEitherEnd() {
        #expect(relate("Rick", "Hal")?.0 == "father-in-law")
        #expect(relate("Rick", "Ivy")?.0 == "mother-in-law")
        #expect(relate("Rick", "Fay")?.0 == "brother-in-law")
        #expect(relate("Peter", "Mae")?.0 == "daughter-in-law")
        #expect(relate("Mae", "Peter")?.0 == "father-in-law")
        #expect(relate("Hal", "Rick")?.0 == "son-in-law")
    }

    @Test func unnamedShapesFallBackToTheRouteOnly() {
        // Fay → Hattie crosses a marriage in the MIDDLE of the path; English
        // has no word for it, so relation is nil and the route still reads.
        let result = relate("Fay", "Hattie")
        #expect(result != nil)
        #expect(result?.0 == nil)
        #expect(result?.1.contains("husband") == true)
    }

    @Test func noPathAndSamePersonReturnNil() {
        #expect(relate("Rick", "Zed") == nil)
        #expect(graph.relationshipPath(from: person("Rick"), to: person("Rick")) == nil)
    }

    @Test func depthCapBoundsTheSearch() {
        // Rick → Hattie is three hops; a cap of two must fail honestly.
        #expect(graph.relationshipPath(from: person("Rick"), to: person("Hattie"), maxDepth: 2) == nil)
        #expect(graph.relationshipPath(from: person("Rick"), to: person("Hattie"), maxDepth: 3) != nil)
    }

    @Test func auditTrailCarriesGedcomIDsForEveryHop() {
        let path = graph.relationshipPath(from: person("Rick"), to: person("Hattie"))
        #expect(path?.auditTrail == "Rick Stone (@I8@) → father Al Stone (@I5@) → mother Grace Hill (@I3@) → mother Hattie Hill (@I1@)")
        #expect(path?.hopCount == 3)
    }
}
