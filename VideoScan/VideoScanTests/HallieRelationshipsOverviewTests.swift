import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Live miss #12 (Rick, 2026-08-29 14:40): "tell me how rick is related to
/// the people in the people tab who currently living or recently deceased"
/// came back as the People-tab ROSTER. The relationships overview answers
/// one subject against the whole tab from the kinship engine, grouped,
/// nearest first, and never falls to the roster or a catalog search.
struct HallieRelationshipsOverviewTests {
    typealias Overview = HallieRelationshipsOverview
    typealias Profile = HallieTurnExecutor.ProfileSnapshot
    typealias Tab = HallieTurnExecutor.PeopleTab

    static let rickSentence =
        "tell me how rick is related to the people in the people tab who currently living or recently deceased"

    private static func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
        Kinship(relation: relation, relativeTo: .profile(name: name))
    }

    /// Primitive rows on Rick only (the way Rick enters them): spouse Donna,
    /// sibling Tim (basis unspecified), four children, parents Dad and Ma.
    /// A row reads "Rick is the <relation> of <anchor>" — `.parent` of Matt,
    /// `.child` of Dad (same convention as KinshipFixture.family).
    /// Anna has no rows and nobody's rows point at her.
    private static let profiles: [Profile] = [
        Profile(stableID: "rick", canonicalName: "Rick", aliases: ["Dicky", "Richy"],
                kinships: [row(.spouse, "Donna"), row(.sibling, "Tim"),
                           row(.parent, "Matt"), row(.parent, "Mark"), row(.parent, "Dan"), row(.parent, "Beth"),
                           row(.child, "Dad"), row(.child, "Ma")],
                sex: .male),
        Profile(stableID: "donna", canonicalName: "Donna", sex: .female),
        Profile(stableID: "tim", canonicalName: "Tim", aliases: ["Timmy"], sex: .male),
        Profile(stableID: "matt", canonicalName: "Matt", sex: .male),
        Profile(stableID: "mark", canonicalName: "Mark", sex: .male),
        Profile(stableID: "dan", canonicalName: "Dan", sex: .male),
        Profile(stableID: "beth", canonicalName: "Beth", sex: .female),
        Profile(stableID: "dad", canonicalName: "Dad", aliases: ["Dick"], sex: .male),
        Profile(stableID: "ma", canonicalName: "Ma", aliases: ["Eileen"], sex: .female),
        Profile(stableID: "anna", canonicalName: "Anna", sex: .female),
    ]

    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Martha /Lamson/
    1 SEX F
    1 BIRT
    2 DATE 1801
    0 TRLR
    """)

    private static func context(graph: GedcomFamilyGraph? = nil, owner: String? = "Rick Breen") -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            profiles: profiles, graph: graph,
            speakers: .init(ownerName: owner, archivistName: "Hallie Mae"))
    }

    static let ownerExpected =
        "You're related to 8 of the 9 other people in the People tab. "
        + "Nearest first: Dad, Ma — your parents · Beth, Dan, Mark, Matt — your children · "
        + "Donna — your wife · Tim — your brother · Anna — no relationship recorded yet. "
        + "That's from your entries in the People tab; derived where marked."

    // MARK: Detection

    @Test func ricksSentenceAndVariantsAreTheOverviewNotTheRoster() {
        let owner: [String] = [
            Self.rickSentence,
            "how am I related to everyone in the People tab?",
            "who am I related to?",
            "list my relatives",
            "Hallie, what are my relationships to the people in the people tab",
            "who are my relatives in the People tab",
            "how are the people in the people tab related to me",
        ]
        for question in owner {
            let ask = Overview.detect(question)
            #expect(ask != nil, Comment(rawValue: question))
            #expect(!Tab.isRosterQuestion(question), Comment(rawValue: question))
        }
        // Rick typing his own name is still the owner once resolved; the
        // detector reports it as named and the answer folds it to "you".
        #expect(Overview.detect(Self.rickSentence) == Overview.Ask(subject: .named("rick")))
        #expect(Overview.detect("how am I related to everyone in the People tab?") == Overview.Ask(subject: .owner))
        #expect(Overview.detect("how is Tim related to everyone") == Overview.Ask(subject: .named("tim")))
        #expect(Overview.detect("tell me how Tim is related to the family") == Overview.Ask(subject: .named("tim")))
        #expect(Overview.detect("how I am related to everybody in the people tab") == Overview.Ask(subject: .owner))
        #expect(Overview.detect("list Tim's relatives") == Overview.Ask(subject: .named("tim")))

        // Two named people, the roster, and searches stay where they were.
        for question in ["how is Tim related to Rick?", "how am I related to you?", "who do you know?",
                         "who is in the People tab", "show me videos of everyone at the cape",
                         "list the people you know", "who is Tim?"] {
            #expect(Overview.detect(question) == nil, Comment(rawValue: question))
        }
        #expect(Tab.isRosterQuestion("who is in the People tab"))
    }

    @Test func preTranslationAnswersTheOverviewAheadOfTheRoster() {
        let context = Self.context()
        let pre = HallieTurnExecutor.preTranslation(
            question: Self.rickSentence, playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false },
            rosterAnswer: { Tab.rosterAnswer(context: context) },
            relationshipsOverview: { Overview.answer($0, context: context) })
        guard case .answer(let result) = pre else {
            Issue.record("expected a local answer, got \(pre)"); return
        }
        #expect(result.prose == Self.ownerExpected)
        #expect(!result.prose.contains("I know"))
        #expect(result.queryDescription == "shape=relationships-overview subject=rick")
    }

    // MARK: The owner's overview

    @Test func ownerOverviewIsGroupedNearestFirstWithCountAndBasis() {
        let result = Overview.answer(.init(subject: .owner), context: Self.context())
        #expect(result.route == .capability)
        #expect(result.outcome == .answered)
        #expect(result.prose == Self.ownerExpected)
        #expect(result.basisLine ==
            "Basis: People-tab relationships (10 profiles; 8 linked to Rick, 1 unrecorded); no family tree installed (local-only); no model call.")
        // Chips: the People tab, then biographies capped by HallieWhichOne.
        #expect(result.offeredActions.first == .openPeopleTab)
        let asks = result.offeredActions.dropFirst()
        #expect(asks.count == HallieWhichOne.cap)
        #expect(asks.first == .ask(question: "who is Dad?", label: "tell me about Dad"))
    }

    @Test func ricksOwnNameTypedByRickIsYou() {
        let byName = Overview.answer(.init(subject: .named("rick")), context: Self.context())
        #expect(byName.prose == Self.ownerExpected)
        // With no owner configured "rick" is still a People-tab profile —
        // answered in the third person.
        let noOwner = Overview.answer(.init(subject: .named("rick")), context: Self.context(owner: nil))
        #expect(noOwner.prose.hasPrefix("Rick is related to 8 of the 9 other people in the People tab. Nearest first: Dad, Ma — Rick's parents"))
        // "me" with no owner set is an honest decline, never a guess.
        let me = Overview.answer(.init(subject: .owner), context: Self.context(owner: nil))
        #expect(me.outcome == .declined)
        #expect(me.prose.contains("I don't know who “I” is yet"))
    }

    @Test func graphNilAndGraphPresentAgree() {
        let local = Overview.answer(.init(subject: .owner), context: Self.context(graph: nil))
        let withTree = Overview.answer(.init(subject: .owner), context: Self.context(graph: Self.tree))
        #expect(local.prose == withTree.prose)
        #expect(withTree.basisLine.contains("family tree installed"))
        #expect(!withTree.basisLine.contains("local-only"))
    }

    // MARK: Another subject

    @Test func timsPerspectiveIsDerivedFromRicksRows() {
        let result = Overview.answer(.init(subject: .named("Tim")), context: Self.context())
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("Tim is related to 8 of the 9 other people in the People tab. Nearest first: Rick — Tim's brother · "))
        #expect(result.prose.contains("Beth, Dan, Mark, Matt — Tim's nieces and nephews (derived)"))
        #expect(result.prose.contains("Donna — Tim's sister-in-law (derived)"))
        // Rick's parents are reached only through the unattested sibling
        // row: a route with the honest note, never "father"/"mother".
        #expect(result.prose.contains("Dad — brother Rick → father Dad (not attested — confirm the shared parents in the review sheet)"))
        #expect(result.prose.contains("Ma — brother Rick → mother Ma (not attested — confirm the shared parents in the review sheet)"))
        #expect(!result.prose.contains("Tim's father"))
        #expect(result.prose.contains("Anna — no relationship recorded yet"))
        // The review sheet's own ask rides along.
        #expect(result.prose.contains("Tim shares Rick's parents"))
        #expect(result.basisLine.contains("2 resting on an unattested sibling row"))
        #expect(result.queryDescription == "shape=relationships-overview subject=Tim")
    }

    @Test func unknownAndAmbiguousSubjectsAreHonest() {
        let unknown = Overview.answer(.init(subject: .named("Zed")), context: Self.context())
        #expect(unknown.outcome == .declined)
        #expect(unknown.prose.contains("I don't have a People-tab profile for “Zed”"))
        #expect(unknown.offeredActions == [.openPeopleTab])

        // "Timmy" claimed by two profiles (the real gallery's shape) asks.
        let crossed = Self.profiles + [Profile(stableID: "timmy", canonicalName: "Timmy", aliases: ["Tim"], sex: .male)]
        let context = HallieTurnExecutor.Context(
            profiles: crossed, speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        let ambiguous = Overview.answer(.init(subject: .named("Tim")), context: context)
        #expect(ambiguous.outcome == .needsClarification)
        #expect(ambiguous.prose.hasPrefix("Which Tim do you mean"))
    }

    @Test func pluralsReadNaturally() {
        #expect(Overview.plural("son") == "sons")
        #expect(Overview.plural("child") == "children")
        #expect(Overview.plural("grandchild") == "grandchildren")
        #expect(Overview.plural("wife") == "wives")
        #expect(Overview.plural("niece or nephew") == "nieces and nephews")
        #expect(Overview.plural("sister-in-law") == "sisters-in-law")
        #expect(Overview.plural("older brother") == "older brothers")
    }
}
