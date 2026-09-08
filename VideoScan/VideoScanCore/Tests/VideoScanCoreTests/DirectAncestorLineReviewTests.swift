import Testing
@testable import VideoScanCore

/// Synthetic graph-boundary sensors. These establish traversal correctness,
/// not historical validity or the policy for alternative parent families.
struct DirectAncestorLineReviewTests {
    private func graph(_ records: String) -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: "0 HEAD\n" + records + "\n0 TRLR\n")
    }

    @Test func cycleTerminatesWithoutInventingAnAncestor() throws {
        let tree = graph("""
        0 @A@ INDI
        1 NAME Alpha /Example/
        1 FAMC @FA@
        0 @B@ INDI
        1 NAME Beta /Example/
        1 FAMC @FB@
        0 @C@ INDI
        1 NAME Unrelated /Example/
        0 @FA@ FAM
        1 HUSB @B@
        1 CHIL @A@
        0 @FB@ FAM
        1 HUSB @A@
        1 CHIL @B@
        """)
        let start = try #require(tree.people["@A@"])
        let unrelated = try #require(tree.people["@C@"])
        #expect(tree.directAncestorLine(from: start, to: unrelated) == nil)
        #expect(tree.directAncestorLine(from: start, to: start) == nil)
    }

    @Test func shorterMaternalPathWinsOverLongerPaternalPath() throws {
        let tree = graph("""
        0 @A@ INDI
        1 NAME Anchor /Example/
        1 FAMC @F1@
        0 @B@ INDI
        1 NAME Father /Example/
        1 FAMC @F2@
        0 @C@ INDI
        1 NAME Mother /Example/
        1 FAMC @F3@
        0 @D@ INDI
        1 NAME Intermediate /Example/
        1 FAMC @F4@
        0 @T@ INDI
        1 NAME Target /Example/
        0 @F1@ FAM
        1 HUSB @B@
        1 WIFE @C@
        1 CHIL @A@
        0 @F2@ FAM
        1 HUSB @D@
        1 CHIL @B@
        0 @F3@ FAM
        1 HUSB @T@
        1 CHIL @C@
        0 @F4@ FAM
        1 HUSB @T@
        1 CHIL @D@
        """)
        let start = try #require(tree.people["@A@"])
        let target = try #require(tree.people["@T@"])
        let result = try #require(tree.directAncestorLine(from: start, to: target))
        #expect(result.generations == 2)
        #expect(result.chain.map(\.id) == ["@A@", "@C@", "@T@"])
        #expect(tree.directAncestorLine(from: start, to: target, maxGenerations: 1) == nil)
        let atLimit = try #require(tree.directAncestorLine(
            from: start, to: target, maxGenerations: 2))
        #expect(atLimit.chain.map(\.id) == result.chain.map(\.id))
        #expect(tree.directAncestorLine(from: target, to: start) == nil)
    }
}
