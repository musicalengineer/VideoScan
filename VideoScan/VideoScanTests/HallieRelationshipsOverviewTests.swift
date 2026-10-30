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
            rosterAnswer: { scope in Tab.rosterAnswer(context: context, scope: scope) },
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
        // Derived parents rank as one-hop rows (parent < sibling), the same
        // order Rick's own overview uses.
        #expect(result.prose.hasPrefix("Tim is related to 8 of the 9 other people in the People tab. Nearest first: Dad, Ma — Tim's parents (derived: full siblings share parents) · Rick — Tim's brother · "),
                Comment(rawValue: result.prose))
        #expect(result.prose.contains("Beth, Dan, Mark, Matt — Tim's nieces and nephews (derived)"))
        #expect(result.prose.contains("Donna — Tim's sister-in-law (derived)"))
        // Rick's parents are Tim's: FULL SIBLINGS SHARE PARENTS (one policy,
        // codex #984) — the word, marked with the SAME rule the kinship
        // route and the biography quote; never "not attested".
        #expect(result.prose.contains("Dad, Ma — Tim's parents (derived: full siblings share parents)"),
                Comment(rawValue: result.prose))
        #expect(!result.prose.contains("not attested"), Comment(rawValue: result.prose))
        #expect(!result.prose.contains("assumed"), Comment(rawValue: result.prose))
        #expect(!result.prose.contains("Tim shares Rick's parents"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("Anna — no relationship recorded yet"))
        #expect(result.basisLine.contains("2 derived: full siblings share parents"), Comment(rawValue: result.basisLine))
        #expect(!result.basisLine.contains("unattested"), Comment(rawValue: result.basisLine))
        #expect(!result.basisLine.contains("Relationship warning"), Comment(rawValue: result.basisLine))
        #expect(result.queryDescription == "shape=relationships-overview subject=Tim")
    }

    @Test func unknownAndAmbiguousSubjectsAreHonest() {
        let unknown = Overview.answer(.init(subject: .named("Zed")), context: Self.context())
        #expect(unknown.outcome == .declined)
        #expect(unknown.prose.contains("I don't have a People-tab profile for “Zed”"))
        #expect(unknown.offeredActions == [.openPeopleTab])

        // Two profiles genuinely NAMED Tim still ask. (A cross-alias pair
        // — brother "Tim" aliasing "Timmy", son "Timmy" aliasing "Tim" —
        // no longer does: exact name wins, 2026-09-03.)
        let crossed = Self.profiles + [Profile(stableID: "tim-2", canonicalName: "Tim", sex: .male)]
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

    // MARK: answer — characterization (2026-10-29, before the split)
    //
    // The early answers no test above reaches (unreadable / empty tab, an
    // owner with no profile or two, a name nobody or two profiles claim,
    // the owner's own name typed, a tab of one) and the third-person
    // phrasing, each pinned as the unchanged CCN 32 answer produced it.

    private static let twoTims: [Profile] = [
        Profile(stableID: "tim1", canonicalName: "Tim", aliases: ["Timothy"], sex: .male),
        Profile(stableID: "tim2", canonicalName: "Tim", aliases: ["Timmy"], sex: .male),
    ]

    /// (outcome, prose, basis, queryDescription, offeredActions.count) per case.
    private static let expectedEarly: [String: (HallieTurnExecutor.Outcome, String, String, String, Int)] = [
        "unreadable": (.declined, "I couldn't read the People tab just now, so I can't work out who is related to whom.",
                 "Basis: People profiles were unreadable; no model call.",
                 "shape=relationships-overview subject=owner", 0),
        "empty": (.declined, "The People tab is empty so far — add people there, record their relationships, and I'll lay them out.",
                 "Basis: People profiles (0); no model call.",
                 "shape=relationships-overview subject=owner", 1),
        "owner-none": (.declined, "I know you're Zed Quill, but there's no People-tab profile by that name — add one and record your relationships there, and I'll lay them out.",
                 "Basis: owner “Zed Quill”; People profiles (10) — none claims that name; no model call.",
                 "shape=relationships-overview subject=owner", 1),
        "owner-two": (.needsClarification, "Which Tim do you mean — Tim (tim1) or Tim (tim2)?",
                 "Basis: “Tim” is claimed by 2 People-tab profiles; nothing was looked up.",
                 "shape=relationships-overview subject=owner", 2),
        "named-none": (.declined, "I don't have a People-tab profile for “Zed”, so I can't lay out their relationships. Add one there and I'll know the name.",
                 "Basis: People profiles (10) — none claims “zed”; no model call.",
                 "shape=relationships-overview subject=zed", 1),
        "named-two": (.needsClarification, "Which Tim do you mean — Tim (tim1) or Tim (tim2)?",
                 "Basis: “tim” is claimed by 2 People-tab profiles; nothing was looked up.",
                 "shape=relationships-overview subject=tim", 2),
        "owner-typed-full": (.answered, "You're related to 8 of the 9 other people in the People tab. Nearest first: Dad, Ma — your parents · Beth, Dan, Mark, Matt — your children · Donna — your wife · Tim — your brother · Anna — no relationship recorded yet. That's from your entries in the People tab; derived where marked.",
                 "Basis: People-tab relationships (10 profiles; 8 linked to Rick, 1 unrecorded); no family tree installed (local-only); no model call.",
                 "shape=relationships-overview subject=rick breen", 7),
        "owner-typed-surname": (.declined, "I don't have a People-tab profile for “Breen”, so I can't lay out their relationships. Add one there and I'll know the name.",
                 "Basis: People profiles (10) — none claims “breen”; no model call.",
                 "shape=relationships-overview subject=breen", 1),
        "only-one": (.declined, "You're the only person in the People tab so far, so there's nobody to relate you to yet.",
                 "Basis: People profiles (1); no model call.",
                 "shape=relationships-overview subject=owner", 1),
        "third-person": (.answered, "Tim is related to 8 of the 9 other people in the People tab. Nearest first: Dad, Ma — Tim's parents (derived: full siblings share parents) · Rick — Tim's brother · Beth, Dan, Mark, Matt — Tim's nieces and nephews (derived) · Donna — Tim's sister-in-law (derived) · Anna — no relationship recorded yet. That's from the entries in the People tab; derived where marked.",
                 "Basis: People-tab relationships (10 profiles; 8 linked to Tim, 1 unrecorded; 5 derived; 2 derived: full siblings share parents); no family tree installed (local-only); no model call.",
                 "shape=relationships-overview subject=tim", 7),
    ]

    @Test func earlyAnswersAndThirdPersonPhrasing() {
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")
        let cases: [(String, Overview.Ask, HallieTurnExecutor.Context)] = [
            ("unreadable", .init(subject: .owner), .init(profiles: nil, speakers: speakers)),
            ("empty", .init(subject: .owner), .init(profiles: [], speakers: speakers)),
            ("owner-none", .init(subject: .owner), .init(profiles: Self.profiles, speakers: .init(ownerName: "Zed Quill", archivistName: nil))),
            ("owner-two", .init(subject: .owner), .init(profiles: Self.twoTims, speakers: .init(ownerName: "Tim", archivistName: nil))),
            ("named-none", .init(subject: .named("zed")), Self.context()),
            ("named-two", .init(subject: .named("tim")), .init(profiles: Self.twoTims, speakers: speakers)),
            ("owner-typed-full", .init(subject: .named("rick breen")), Self.context()),
            ("owner-typed-surname", .init(subject: .named("breen")), Self.context()),
            ("only-one", .init(subject: .owner), .init(profiles: [Self.profiles[0]], speakers: speakers)),
            ("third-person", .init(subject: .named("tim")), Self.context()),
        ]
        #expect(cases.count == Self.expectedEarly.count)
        for (label, ask, context) in cases {
            let r = Overview.answer(ask, context: context)
            guard let want = Self.expectedEarly[label] else {
                Issue.record("no expectation for \(label)"); continue
            }
            #expect(r.outcome == want.0, Comment(rawValue: label))
            #expect(r.prose == want.1, Comment(rawValue: label))
            #expect(r.basisLine == want.2, Comment(rawValue: label))
            #expect(r.queryDescription == want.3, Comment(rawValue: label))
            #expect(r.offeredActions.count == want.4, Comment(rawValue: label))
            #expect(r.route == .capability, Comment(rawValue: label))
        }
    }
}
