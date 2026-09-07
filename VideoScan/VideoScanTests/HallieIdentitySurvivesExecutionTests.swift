import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// B5 and B7 from Rick's 2026-09-05 red-team, pinned at the seam where each
/// actually broke. Both are consequences of the SAME data change: Rick's
/// surname adoption on 2026-09-04 made "Richard" his father's canonical name
/// while it was already Rick's own alias.
///
/// The failures, quoted from ~/Library/Logs/VideoScan/Hallie/
/// hallie-conversation-2026-09-05.jsonl:
///
///   [301] "show me videos of my dad"
///         → I looked for videos of Richard with "dad" and found nothing.
///   [459] "when was my dad born"
///         → Richard Harding Breen Jr was born 4 March 1959.   (that is RICK)
@Suite("A resolved identity survives execution")
struct HallieIdentitySurvivesExecutionTests {
    typealias Kin = HallieTurnExecutor.SpeakerKinship

    /// Rick's live People tab, reduced to the collision. Dad's profile is
    /// canonically "Richard" (Rick renamed it on 2026-09-04) with the family
    /// name fields filled in; Rick's own profile lists "Richard" among its
    /// aliases, which is the whole problem.
    private static func people() -> [ArchivistGraphProfileSnapshot] {
        [
            ArchivistGraphProfileSnapshot(
                stableID: "richard", canonicalName: "Richard",
                aliases: ["Dad", "Dad Breen"],
                sex: .male,
                surname: "Breen", middleName: "Harding", suffix: "Sr"),
            ArchivistGraphProfileSnapshot(
                stableID: "rick", canonicalName: "Rick",
                aliases: ["Richard", "Dicky"],
                kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard"))],
                sex: .male,
                surname: "Breen", middleName: "Harding", suffix: "Jr"),
        ]
    }

    private static func overlay() -> FamilyKinshipOverlay {
        FamilyKinshipOverlay(snapshots: people())
    }

    private let rick = HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie Mae")

    // MARK: the collision itself

    /// The precondition for everything below. If this stops being ambiguous
    /// the tests still pass but they stop testing anything, so assert it.
    @Test func theBareGivenNameIsGenuinelyAmbiguous() {
        let resolver = PersonResolver(people: Self.people().map {
            ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases,
                             fullNameForms: $0.fullNameForms)
        })
        // Exact-name-wins means Dad claims it by NAME and Rick only by alias,
        // so the resolver does pick Dad — but the string alone carries no
        // suffix, and the GEDCOM route downstream has no such rule.
        #expect(resolver.resolve("Richard") == .resolved(canonicalName: "Richard"))
        // The full names, in contrast, each name exactly one person.
        #expect(resolver.resolve("Richard Breen Sr") == .resolved(canonicalName: "Richard"))
        #expect(resolver.resolve("Richard Breen Jr") == .resolved(canonicalName: "Rick"))
    }

    /// codex #1114-2: full-name forms reach the overlay's resolver. Without
    /// this the fix below has no unambiguous spelling to reach for.
    @Test func theOverlayResolverKnowsFullNameForms() {
        let overlay = Self.overlay()
        let nodes = overlay.nodes(claiming: "Richard Breen Sr", ownerName: "Rick")
        #expect(nodes.count == 1, "the full name must resolve to exactly one vertex")
        #expect(overlay.nodes(claiming: "Richard Harding Breen Sr", ownerName: "Rick").count == 1)
    }

    // MARK: B7 — the identity that was thrown away

    @Test func myDadBindsTheUnambiguousNameNotTheBareGivenName() {
        let bound = Kin.rebind(
            people: ["my dad"], question: "show me videos of my dad",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.failure == nil)
        #expect(bound.people == ["Richard Breen Sr"],
                Comment(rawValue: "\(bound.people)"))
        // Never the bare given name again: that string means Dad AND Rick.
        #expect(!bound.people.contains("Richard"))
    }

    /// The bound spelling has to survive a ROUND TRIP — binding a name
    /// nothing downstream can resolve would trade a wrong answer for no
    /// answer, which is not an improvement.
    @Test func theBoundNameResolvesBackToTheSamePerson() {
        let overlay = Self.overlay()
        let bound = Kin.rebind(
            people: ["my dad"], question: "videos of my dad",
            speakers: rick, graph: nil, kinshipOverlay: overlay)
        let name = try! #require(bound.people.first)
        let nodes = overlay.nodes(claiming: name, ownerName: "Rick")
        #expect(nodes == [.profile(stableID: "richard")], Comment(rawValue: "\(nodes)"))
    }

    /// A profile with no surname has no fuller name to reach for, and must
    /// behave exactly as it did before this change.
    @Test func aPersonWithNoSurnameStillBindsTheirShortName() {
        let plain: [ArchivistGraphProfileSnapshot] = [
            ArchivistGraphProfileSnapshot(stableID: "dad", canonicalName: "Dad", sex: .male),
            ArchivistGraphProfileSnapshot(
                stableID: "rick", canonicalName: "Rick",
                kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Dad"))],
                sex: .male),
        ]
        let bound = Kin.rebind(
            people: ["my dad"], question: "videos of my dad",
            speakers: rick, graph: nil,
            kinshipOverlay: FamilyKinshipOverlay(snapshots: plain))
        #expect(bound.people == ["Dad"], Comment(rawValue: "\(bound.people)"))
    }

    // MARK: B5 — the kin word spent twice

    @Test func aResolvedKinshipPhraseIsRecordedAsSpent() {
        let bound = Kin.rebind(
            people: ["my dad"], question: "show me videos of my dad",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.consumedKinPhrase?.word == "dad")
        #expect(bound.consumedKinPhrase?.phrase == "my dad")
        #expect(bound.spentKeyword("dad"))
        #expect(bound.spentKeyword("Dad"), "case folds like the keyword matcher")
        #expect(bound.spentKeyword("my dad"))
        // A real content word is never mistaken for the spent term.
        #expect(!bound.spentKeyword("typewriters"))
        #expect(!bound.spentKeyword("golf"))
    }

    /// Nothing is marked spent when no kinship phrase was resolved, so an
    /// ordinary question's keywords are untouched.
    @Test func anOrdinaryQuestionSpendsNoKeyword() {
        let bound = Kin.rebind(
            people: ["Tim"], question: "show me videos of Tim golfing",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.consumedKinPhrase == nil)
        #expect(!bound.spentKeyword("golf"))
        #expect(!bound.spentKeyword("dad"))
    }

    /// A kinship phrase that FAILS to resolve must not mark its word spent —
    /// the search still needs it, and dropping it would silently widen the
    /// query after telling the user nothing.
    @Test func anUnresolvedKinshipPhraseSpendsNothing() {
        let strangers = FamilyKinshipOverlay(snapshots: [
            ArchivistGraphProfileSnapshot(stableID: "rick", canonicalName: "Rick", sex: .male),
        ])
        let bound = Kin.rebind(
            people: ["my dad"], question: "show me videos of my dad",
            speakers: rick, graph: nil, kinshipOverlay: strangers)
        #expect(bound.consumedKinPhrase == nil)
        #expect(!bound.spentKeyword("dad"))
    }
}

/// B6 from the same red-team. Live 2026-09-05, row 914:
///
///   "show me videos of Dad"
///   → spelling recovery “dad” → People profile “Richard”; no one in the
///     catalog is tagged “Richard”, so I searched it as a place or word;
///     25 cited of 123 matching catalog items.
///   → I took “dad” to mean Richard. 123 videos: 22 where someone says
///     “Richard” …
///
/// A hundred and twenty-three videos of OTHER people saying his given name,
/// offered as videos of Rick's father.
@Suite("A person in the People tab is never searched as a word")
struct HallieFamilyIsNotAWordTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// One record that mentions "Richard" in its path and is tagged with
    /// somebody else entirely — the shape that produced the 123.
    private static func records() -> [ArchivistPresenceRecordSnapshot] {
        [
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Christmas/Richard-and-the-boys-1990.mov",
                directory: "/Volumes/X/Christmas", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Volumes/X/Cape/beach.mov",
                directory: "/Volumes/X/Cape", volumeName: "X",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)]),
        ]
    }

    private static func context() -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            presenceRecords: records(),
            profiles: [
                .init(stableID: "donna", canonicalName: "Donna"),
                .init(stableID: "richard", canonicalName: "Richard",
                      aliases: ["Dad"], surname: "Breen", suffix: "Sr"),
            ])
    }

    @Test func anUntaggedFamilyMemberIsDeclinedNotWordSearched() async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "show me videos of Dad",
                                ast: .presence(.init(people: ["Richard"])))),
            context: Self.context())
        #expect(result.outcome == .declined, Comment(rawValue: result.prose))
        #expect(!result.basisLine.contains("searched it as a place or word"),
                Comment(rawValue: result.basisLine))
        // And above all: never the file that merely has his name in its path.
        #expect(!result.citations.contains { $0.filename.contains("Richard-and-the-boys") },
                Comment(rawValue: "\(result.citations.map(\.filename))"))
    }

    /// Reached by an alias, the answer is the same — "Dad" is him too.
    @Test func theSameHoldsWhenTheFamilyMemberIsNamedByAnAlias() async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "show me videos of Dad",
                                ast: .presence(.init(people: ["Dad"])))),
            context: Self.context())
        #expect(!result.basisLine.contains("searched it as a place or word"),
                Comment(rawValue: result.basisLine))
    }

    /// And by a full name, now that those resolve.
    @Test func theSameHoldsForAFullName() async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "show me videos of Richard Breen Sr",
                                ast: .presence(.init(people: ["Richard Breen Sr"])))),
            context: Self.context())
        #expect(!result.basisLine.contains("searched it as a place or word"),
                Comment(rawValue: result.basisLine))
    }

    /// The Franklin case must keep working: a name only the TREE knows can
    /// still be the place on the box, and New England spells its towns and
    /// its families the same way.
    @Test func aNameOnlyTheTreeKnowsIsStillRetriedAsAPlace() {
        let context = Self.context()
        #expect(HallieTurnExecutor.isPeopleTabPerson("Richard", context: context))
        #expect(HallieTurnExecutor.isPeopleTabPerson("Dad", context: context))
        #expect(HallieTurnExecutor.isPeopleTabPerson("Richard Breen Sr", context: context))
        #expect(!HallieTurnExecutor.isPeopleTabPerson("Franklin", context: context))
        #expect(!HallieTurnExecutor.isPeopleTabPerson("Hudson", context: context))
    }
}

/// The overlay the LIVE turn builds, as opposed to the one the tests above
/// build by hand.
///
/// This suite exists because the B7 fix shipped broken. Every unit test
/// passed, because each constructed its overlay directly and passed the
/// family-name fields. `kinshipOverlay(context:)` — the only builder
/// production uses — did not, so at runtime the overlay had no full names to
/// reach for and went on binding the contested given name. Rick saw it on
/// the first question after the build:
///
///   basis: 'my dad' = Richard, father of Rick Breen in the People tab
///
/// where it should have said Richard Breen Sr. Testing the seam is not
/// testing the route.
@Suite("The overlay the live turn actually builds")
struct HallieProductionOverlayTests {

    /// Rick's real collision, in the shape `Context` carries.
    private static func profiles() -> [HallieTurnExecutor.ProfileSnapshot] {
        [
            .init(stableID: "richard", canonicalName: "Richard",
                  aliases: ["Dad", "Grampa Breen", "Dick", "Dad Breen"],
                  kinships: [], sex: .male,
                  surname: "Breen", middleName: "Harding", suffix: "Sr"),
            .init(stableID: "rick", canonicalName: "Rick",
                  aliases: ["Dicky", "Richy", "Rich", "Richard"],
                  kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard"))],
                  sex: .male),
        ]
    }

    private static func context() -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(profiles: profiles())
    }

    @Test func theProductionBuilderCarriesTheFamilyNameFields() throws {
        let overlay = try #require(HallieTurnExecutor.kinshipOverlay(context: Self.context()))
        // If the name fields did not cross this builder, the full name
        // resolves to nobody and unambiguousName has nothing to reach for.
        #expect(overlay.nodes(claiming: "Richard Breen Sr", ownerName: "Rick").count == 1,
                "the production builder must pass surname/suffix through")
    }

    /// The end-to-end assertion, in the words Rick reads on screen.
    @Test func myDadBindsTheFullNameThroughTheProductionBuilder() throws {
        let overlay = try #require(HallieTurnExecutor.kinshipOverlay(context: Self.context()))
        let bound = HallieTurnExecutor.SpeakerKinship.rebind(
            people: ["my dad"], question: "show me videos of my dad",
            speakers: .init(ownerName: "Rick", archivistName: "Hallie Mae"),
            graph: nil, kinshipOverlay: overlay)
        #expect(bound.people == ["Richard Breen Sr"], Comment(rawValue: "\(bound.people)"))
        #expect(bound.people != ["Richard"], "the contested given name must never survive")
    }

    /// A profile with no surname is unaffected — the field simply is not there
    /// to carry, and behaviour is what it always was.
    @Test func aFamilyWithNoSurnamesBehavesAsBefore() throws {
        let plain: [HallieTurnExecutor.ProfileSnapshot] = [
            .init(stableID: "dad", canonicalName: "Dad", sex: .male),
            .init(stableID: "rick", canonicalName: "Rick",
                  kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Dad"))],
                  sex: .male),
        ]
        let overlay = try #require(
            HallieTurnExecutor.kinshipOverlay(context: .init(profiles: plain)))
        let bound = HallieTurnExecutor.SpeakerKinship.rebind(
            people: ["my dad"], question: "videos of my dad",
            speakers: .init(ownerName: "Rick", archivistName: "Hallie Mae"),
            graph: nil, kinshipOverlay: overlay)
        #expect(bound.people == ["Dad"])
    }
}

/// Live regression, 2026-09-06 17:20, reported by Rick mid-spot-test:
///
///   Q: show me videos of my dad
///   A: I can't work out who "my dad" is without the family tree, and no
///      family tree is loaded.
///
/// It had worked an hour earlier. Cause: adding `fullNameForms` to the
/// overlay's resolver (B7) also added them to `PersonResolver.spellingEntries`,
/// which is the FUZZY spelling-recovery pool. Rick's owner name is "Rick
/// Breen" and his profile carries no surname, so the exact index misses and
/// recovery runs — now against "Richard Breen", "Richard Breen Sr" and the
/// rest of his father's forms.
@Suite("The owner still resolves after full names entered the resolver")
struct HallieOwnerResolutionRegressionTests {

    /// Rick's live shape exactly: Dad surnamed and suffixed, Rick with
    /// neither, and "Richard" on both.
    private static func live() -> [ArchivistGraphProfileSnapshot] {
        [
            .init(stableID: "richard", canonicalName: "Richard",
                  aliases: ["Dad", "Grampa Breen", "Dick", "Dad Breen"],
                  sex: .male,
                  surname: "Breen", middleName: "Harding", suffix: "Sr"),
            .init(stableID: "rick", canonicalName: "Rick",
                  aliases: ["Dicky", "Richy", "Rich", "Richard"],
                  kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard"))],
                  sex: .male),
        ]
    }

    @Test func theOwnerNameResolvesToTheOwnerNotToHisFather() {
        let overlay = FamilyKinshipOverlay(snapshots: Self.live())
        let owners = overlay.nodes(claiming: "Rick Breen", ownerName: "Rick Breen")
        #expect(owners == [.profile(stableID: "rick")],
                Comment(rawValue: "\(owners)"))
    }

    /// The end-to-end shape Rick actually typed.
    @Test func videosOfMyDadStillResolvesThroughThePeopleTab() {
        let bound = HallieTurnExecutor.SpeakerKinship.rebind(
            people: ["my dad"], question: "show me videos of my dad",
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            graph: nil,
            kinshipOverlay: FamilyKinshipOverlay(snapshots: Self.live()))
        #expect(bound.failure == nil, Comment(rawValue: bound.failure ?? ""))
        #expect(bound.people == ["Richard Breen Sr"], Comment(rawValue: "\(bound.people)"))
    }

    /// A full name is an EXACT-match affordance. It must never widen fuzzy
    /// recovery — guessing that "Rick Breen" means "Richard Breen" is
    /// precisely the wrong-person answer the forms were added to prevent.
    @Test func fullNamesAreExactAffordancesNotFuzzyCandidates() {
        let resolver = PersonResolver(people: Self.live().map {
            ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases,
                             fullNameForms: $0.fullNameForms)
        })
        #expect(resolver.resolve("Richard Breen Sr") == .resolved(canonicalName: "Richard"),
                "exact full-name matching must keep working")
        // The requirement is NOT that "Rick Breen" resolves here — it is
        // that it never resolves to somebody ELSE. `.unknown` is the right
        // answer for a spelling no profile claims: `nodes(claiming:)` then
        // takes the owner path (HallieOwnerResolver.isOwnerSpelling → first
        // token → "Rick"), which is where an owner name carrying a surname
        // the profile lacks is supposed to be handled. Asserting
        // `.resolved("Rick")` here would be asserting that fuzzy recovery
        // guesses well, which is the very thing that caused this bug.
        #expect(resolver.resolve("Rick Breen") != .resolved(canonicalName: "Richard"),
                "the owner must never be recovered onto his father")
        if case .resolved(let who) = resolver.resolve("Rick Breen") {
            #expect(who == "Rick", Comment(rawValue: "resolved to \(who)"))
        }
    }
}

/// Live, 2026-09-06 evening. Rick's first question of the session:
///
///   Q: tell me about my dad
///   A: I wasn't sure which person you meant — Richard Breen Sr or dad?
///      Ask about one of them and I'll look them up.
///   queryDescription: shape=graph operation=birth person=Richard Breen Sr,dad
///   outcome: declined   offeredActions: []
///
/// The rebind resolved his father correctly and left a SECOND entry behind.
/// The translator had emitted both the phrase and the bare kin word —
/// `people = ["my dad", "dad"]` — slot 0 became "Richard Breen Sr" and "dad"
/// rode along. Two people is not one person, so the graph route declined,
/// and because a decline is not a clarification it registered no pending
/// question (`offeredActions: []`). Rick answered "Richard Breen Sr" into
/// nothing, and the refinement path took his reply as a search term against
/// an unrelated catalog query two turns back.
@Suite("One relative resolved once means one entry")
struct HallieKinDuplicateEntryTests {
    typealias Kin = HallieTurnExecutor.SpeakerKinship

    private static func overlay() -> FamilyKinshipOverlay {
        FamilyKinshipOverlay(snapshots: [
            .init(stableID: "richard", canonicalName: "Richard",
                  aliases: ["Dad", "Dad Breen"], sex: .male,
                  surname: "Breen", middleName: "Harding", suffix: "Sr"),
            .init(stableID: "rick", canonicalName: "Rick",
                  aliases: ["Dicky", "Richard"],
                  kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard"))],
                  sex: .male),
        ])
    }

    private let rick = HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie Mae")

    /// The exact list the translator produced.
    @Test func thePhraseAndTheBareKinWordCollapseToOnePerson() {
        let bound = Kin.rebind(
            people: ["my dad", "dad"], question: "tell me about my dad",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.people == ["Richard Breen Sr"], Comment(rawValue: "\(bound.people)"))
    }

    /// Every shape the translator has produced for one relative.
    @Test func anyMixtureOfWaysToNameTheSameRelativeCollapses() {
        for people in [["my dad", "dad"], ["dad", "my dad"], ["me", "dad"],
                       ["my dad", "Dad"], ["Rick", "my dad"], ["my dad"], ["dad"], []] {
            let bound = Kin.rebind(
                people: people, question: "tell me about my dad",
                speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
            #expect(bound.people == ["Richard Breen Sr"],
                    Comment(rawValue: "\(people) → \(bound.people)"))
        }
    }

    /// A DIFFERENT person named alongside the relative must survive: "videos
    /// of my dad and Donna" is two people on purpose.
    @Test func someoneElseInTheSameQuestionIsNotSweptUp() {
        let bound = Kin.rebind(
            people: ["my dad", "Donna"], question: "videos of my dad and Donna",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.people.contains("Richard Breen Sr"), Comment(rawValue: "\(bound.people)"))
        #expect(bound.people.contains("Donna"), Comment(rawValue: "\(bound.people)"))
        #expect(bound.people.count == 2, Comment(rawValue: "\(bound.people)"))
    }

    /// And a question with no kinship phrase is untouched.
    @Test func aQuestionWithoutARelativeIsLeftAlone() {
        let bound = Kin.rebind(
            people: ["Donna", "Tim"], question: "videos of Donna and Tim",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.people == ["Donna", "Tim"])
    }
}

/// codex #1156, 2026-09-07. The dedupe that closed Rick's "my dad"/"dad"
/// duplicate swept too wide: it removed EVERY remaining owner-name and
/// speaker-pronoun entry, so a question that asked for two people came back
/// with one.
///
///   people = ["my dad", "Rick"], owner Rick, "videos of my dad and Rick"
///   → ["Richard Breen Sr"]        — Rick, independently requested, deleted
///
/// The sweep is right for "tell me about my dad", where "me" is an artifact of
/// "tell me" and never a subject. What separates the two is the conjunction
/// between them, so that is what `requestedAlongside` tests.
@Suite("An independently requested speaker survives the kin dedupe")
struct HallieKinConjunctionSurvivalTests {
    typealias Kin = HallieTurnExecutor.SpeakerKinship

    private static func overlay() -> FamilyKinshipOverlay {
        FamilyKinshipOverlay(snapshots: [
            .init(stableID: "richard", canonicalName: "Richard",
                  aliases: ["Dad", "Dad Breen"], sex: .male,
                  surname: "Breen", middleName: "Harding", suffix: "Sr"),
            .init(stableID: "rick", canonicalName: "Rick",
                  aliases: ["Dicky", "Richard"],
                  kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard"))],
                  sex: .male),
        ])
    }

    private let rick = HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie Mae")

    /// codex's first case: the owner asked for BY NAME beside the relative.
    @Test func theOwnerNamedBesideTheRelativeSurvives() {
        let bound = Kin.rebind(
            people: ["my dad", "Rick"], question: "videos of my dad and Rick",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.people.contains("Richard Breen Sr"), Comment(rawValue: "\(bound.people)"))
        #expect(bound.people.contains("Rick"), Comment(rawValue: "\(bound.people)"))
        #expect(bound.people.count == 2, Comment(rawValue: "\(bound.people)"))
    }

    /// codex's second case: the same, asked with a pronoun.
    @Test func theSpeakerPronounNamedBesideTheRelativeSurvives() {
        let bound = Kin.rebind(
            people: ["my dad", "me"], question: "videos of my dad and me",
            speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
        #expect(bound.people.contains("Richard Breen Sr"), Comment(rawValue: "\(bound.people)"))
        #expect(bound.people.count == 2, Comment(rawValue: "\(bound.people)"))
    }

    /// Order must not matter, and neither should the comma or ampersand forms.
    @Test func eitherOrderAndEitherConjunctionKeepsBoth() {
        for question in ["videos of Rick and my dad", "videos of my dad and Rick",
                         "videos of my dad & Rick", "videos of Rick, and my dad"] {
            let bound = Kin.rebind(
                people: ["my dad", "Rick"], question: question,
                speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
            #expect(bound.people.count == 2, Comment(rawValue: "\(question) → \(bound.people)"))
        }
    }

    /// THE ORIGINAL BUG STAYS FIXED. No conjunction, so the speaker mention is
    /// grammar and the relative collapses to exactly one entry.
    @Test func theOriginalDuplicateStillCollapses() {
        for people in [["my dad", "dad"], ["dad", "my dad"], ["me", "dad"],
                       ["my dad", "Dad"], ["Rick", "my dad"], ["my dad"], ["dad"]] {
            let bound = Kin.rebind(
                people: people, question: "tell me about my dad",
                speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
            #expect(bound.people == ["Richard Breen Sr"],
                    Comment(rawValue: "\(people) → \(bound.people)"))
        }
    }

    /// codex #1163(A): the OWNER LISTED FIRST. `slotIndex` took whichever of
    /// pronoun/phrase/kin-word/owner-name came first in the list, so this
    /// people order overwrote Rick with the resolved father before the
    /// preservation filter in `bind` ever ran. The order of the people list
    /// must not decide who survives.
    @Test func theOwnerListedBeforeTheRelativeIsNotOverwritten() {
        for people in [["Rick", "my dad"], ["my dad", "Rick"]] {
            let bound = Kin.rebind(
                people: people, question: "videos of Rick and my dad",
                speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
            #expect(bound.people.contains("Richard Breen Sr"),
                    Comment(rawValue: "\(people) → \(bound.people)"))
            #expect(bound.people.contains("Rick"),
                    Comment(rawValue: "\(people) → \(bound.people)"))
            #expect(bound.people.count == 2, Comment(rawValue: "\(people) → \(bound.people)"))
        }
    }

    /// codex #1163(B): ordinary terminal punctuation. The adjacency test pads
    /// with spaces, so "my dad and Rick?" ended the haystack with "rick?" and
    /// the preservation silently switched off for anyone who types a question
    /// mark.
    @Test func terminalPunctuationDoesNotDisablePreservation() {
        for question in ["videos of my dad and Rick?", "videos of my dad and Rick.",
                         "videos of my dad and Rick!", "videos of Rick and my dad?"] {
            let bound = Kin.rebind(
                people: ["my dad", "Rick"], question: question,
                speakers: rick, graph: nil, kinshipOverlay: Self.overlay())
            #expect(bound.people.count == 2, Comment(rawValue: "\(question) → \(bound.people)"))
        }
        #expect(Kin.requestedAlongside("me", phrase: "my dad",
                                       in: "videos of my dad and me.") == true)
    }

    /// The adjacency test is on WORD boundaries: "me" must not be found inside
    /// "someone", or the sweep silently stops working for the common case.
    @Test func theConjunctionTestRespectsWordBoundaries() {
        #expect(Kin.requestedAlongside("me", phrase: "my dad",
                                       in: "videos of my dad and someone") == false)
        #expect(Kin.requestedAlongside("me", phrase: "my dad",
                                       in: "videos of my dad and me") == true)
        #expect(Kin.requestedAlongside("rick", phrase: "my dad",
                                       in: "tell me about my dad") == false)
        #expect(Kin.requestedAlongside("rick", phrase: "my dad",
                                       in: "my dad and rick at the beach") == true)
    }
}
