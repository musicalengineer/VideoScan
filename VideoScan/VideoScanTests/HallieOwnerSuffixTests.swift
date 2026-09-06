import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Live, 2026-09-06, mid spot-test:
///
///   Q: tell me about my dad
///   A: Richard Harding Breen Jr was born 4 March 1959 [c1].
///   basis: 'my dad' = Richard (Richard Harding Breen Sr), father of Rick
///          Breen in the People tab relationships … date from the People tab
///          profile "Rick"
///
/// Richard Harding Breen Jr is Rick. The kinship rebind resolved the FATHER
/// correctly — the basis says so — and the graph executor's owner pin then
/// overwrote him with the speaker's own record, because
/// `isOwnerSpelling` discarded the generational suffix from both sides and
/// "Rick" expands to "Richard".
///
/// The suffix is the only thing in a name that distinguishes a father from
/// a son, and this family has both.
@Suite("A generational suffix is never noise")
struct HallieOwnerSuffixTests {

    private let owner = "Rick Breen"          // as configured: no suffix
    private let ownerRecord = "Richard Harding Breen Jr"   // as the tree has him

    // MARK: the bug

    @Test func theFathersNameIsNotTheOwnersSpelling() {
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "Richard Breen Sr", owner: owner, ownerTreeName: ownerRecord))
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "Richard Harding Breen Sr", owner: owner, ownerTreeName: ownerRecord))
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "richard breen senior", owner: owner, ownerTreeName: ownerRecord))
    }

    // MARK: what must keep working

    /// The case this tolerance was built for. Rick's configured name has no
    /// suffix; his RECORD is Junior; "richard breen jr" is him.
    @Test func theOwnersOwnFormalNameWithHisSuffixStillMatches() {
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "richard breen jr", owner: owner, ownerTreeName: ownerRecord))
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "richard breen junior", owner: owner, ownerTreeName: ownerRecord),
            "junior and jr are one claim, not two")
    }

    /// The owner's FULL tree name, middle name and all, does NOT match — and
    /// that is pre-existing behaviour this change did not touch. Every typed
    /// token must appear in the CONFIGURED owner name ("Rick Breen"), and
    /// "harding" does not. Recorded here because it is not obvious and
    /// because it matters:
    ///
    /// It is also the entire reason "when was my dad born" answered
    /// correctly on 2026-09-06 while "tell me about my dad" did not. That
    /// turn bound "Richard Harding Breen Sr" through the GEDCOM branch, the
    /// middle name broke the owner match, and the pin never fired. The right
    /// answer came out of a near miss.
    ///
    /// Failing closed here is safe: the subject falls to `.unresolved` and
    /// ordinary resolution finds the person by name. Widening it would be a
    /// separate change with its own risk, and nothing today needs it.
    @Test func theOwnersFullTreeNameIsNotRecognisedAndThatIsUnchanged() {
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "Richard Harding Breen Jr", owner: owner, ownerTreeName: ownerRecord))
        // Same before the suffix rule existed — the middle name, not the suffix.
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "Richard Harding Breen Jr", owner: owner))
    }

    /// A name with no suffix says nothing about generation, so the rest of
    /// the rule decides — exactly as before this change.
    @Test func anUnsuffixedNameIsJudgedTheWayItAlwaysWas() {
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "rick", owner: owner, ownerTreeName: ownerRecord))
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "Rick Breen", owner: owner, ownerTreeName: ownerRecord))
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "richard breen", owner: owner, ownerTreeName: ownerRecord))
        // And the refusals that were already right stay right.
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "breen", owner: owner, ownerTreeName: ownerRecord))
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "dick", owner: owner, ownerTreeName: ownerRecord),
            "two diminutives of one formal name are two people")
    }

    /// No pinned record, no opinion. Callers without a tree pin behave
    /// exactly as they did before — the parameter defaults to nil.
    @Test func withoutAPinnedRecordTheSuffixIsNotJudged() {
        #expect(HallieOwnerResolver.isOwnerSpelling("richard breen jr", owner: owner))
        #expect(HallieOwnerResolver.isOwnerSpelling("richard breen sr", owner: owner),
                "no pin means no evidence about generation; unchanged behaviour")
    }

    /// An owner record that carries no suffix of its own cannot rule on
    /// anyone else's.
    @Test func anOwnerRecordWithoutASuffixRulesOnNothing() {
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "richard breen jr", owner: owner, ownerTreeName: "Richard Harding Breen"))
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "richard breen sr", owner: owner, ownerTreeName: "Richard Harding Breen"))
    }

    /// The reverse family: an owner who IS the Senior must not answer to
    /// Junior's name.
    @Test func theRuleIsSymmetric() {
        #expect(!HallieOwnerResolver.isOwnerSpelling(
            "Richard Breen Jr", owner: "Richard Breen", ownerTreeName: "Richard Harding Breen Sr"))
        #expect(HallieOwnerResolver.isOwnerSpelling(
            "Richard Breen Sr", owner: "Richard Breen", ownerTreeName: "Richard Harding Breen Sr"))
    }
}
