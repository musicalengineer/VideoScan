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
