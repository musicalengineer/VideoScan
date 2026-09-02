import Foundation
import Testing
@testable import VideoScan

/// Matrix for the pure follow-up resolver: every "normal human" phrasing from
/// Rick's demo to Donna (2026-08-17) plus the negatives that must NOT be
/// treated as follow-ups. No executor, no model, no I/O.
@Suite("Family Archivist follow-up resolver")
struct ArchivistFollowUpResolverTests {
    typealias Resolver = ArchivistFollowUpResolver
    typealias Item = ArchivistFollowUpResolver.Snapshot.Item

    private static let donnaAST = ArchivistQueryAST.presence(
        .init(people: ["donna"], mediaKind: .video))

    private static let items: [Item] = [
        Item(filename: "Cape-1992-archive.mkv",
             fullPath: "/Volumes/LaCie/Cape-1992-archive.mkv", years: [1992]),
        Item(filename: "CapeCod_June_1997.mp4",
             fullPath: "/Volumes/LaCie/CapeCod_June_1997.mp4", years: [1997]),
        Item(filename: "donna_birthday.mov",
             fullPath: "/Volumes/LaCie/1998/donna_birthday.mov", years: [1998]),
    ]

    private static let withResults = Resolver.Snapshot(
        ast: donnaAST, items: items, shownCount: 3, totalMatchCount: 3)
    private static let withMoreResults = Resolver.Snapshot(
        ast: donnaAST, items: items, shownCount: 25, totalMatchCount: 52)
    private static let knownPeople: Set<String> = ["matt", "rick", "donna", "timmy"]

    private func resolve(
        _ text: String,
        snapshot: Resolver.Snapshot? = ArchivistFollowUpResolverTests.withResults
    ) -> Resolver.Resolution {
        Resolver.resolve(text, snapshot: snapshot) {
            Self.knownPeople.contains($0.lowercased())
        }
    }

    // MARK: Media actions on the last answer

    @Test(arguments: [
        ("play one of them, say the first one", Resolver.MediaVerb.play, [0]),
        ("play it", .play, [0]),
        ("play that one", .play, [0]),
        ("Play the first one", .play, [0]),
        ("play", .play, [0]),
        ("watch the second one", .play, [1]),
        ("play number 3", .play, [2]),
        ("play #2", .play, [1]),
        ("play the 3rd one", .play, [2]),
        ("play the last one", .play, [2]),
        ("ok play the first video", .play, [0]),
        ("please play the first clip", .play, [0]),
        ("play them", .play, [0, 1, 2]),
        ("play all of them", .play, [0, 1, 2]),
        ("reveal it", .reveal, [0]),
        ("reveal the second one", .reveal, [1]),
        ("show it in the finder", .reveal, [0]),
        ("show me the first one", .show, [0]),
        ("show me number 2", .show, [1]),
        ("open the last one", .show, [2]),
        ("play the one from 1997", .play, [1]),
        ("play the birthday one", .play, [2]),
        ("show me the cape one", .show, [0]),
        ("play the one from 1992", .play, [0]),
    ])
    func referentsResolveAgainstTheLastAnswer(
        text: String, verb: Resolver.MediaVerb, indices: [Int]
    ) {
        #expect(resolve(text) == .mediaAction(verb: verb, indices: indices), Comment(rawValue: text))
    }

    @Test func outOfRangeAndMissingReferentsDeclineHonestly() {
        #expect(resolve("play number 7") == .declineOutOfRange(requested: 7, available: 3))
        #expect(resolve("play the fifth one") == .declineOutOfRange(requested: 5, available: 3))
        #expect(resolve("play the one from 1985") == .declineNoMatchingItem("1985"))
    }

    @Test func withoutAPriorAnswerBareReferentsDeclineAndContentSearches() {
        #expect(resolve("play one of them, say the first one", snapshot: nil)
                == .declineNoPriorResult(.play))
        #expect(resolve("play it", snapshot: nil) == .declineNoPriorResult(.play))
        #expect(resolve("play", snapshot: nil) == .declineNoPriorResult(.play))
        #expect(resolve("show me the first one", snapshot: nil) == .declineNoPriorResult(.show))
        #expect(resolve("reveal it", snapshot: nil) == .declineNoPriorResult(.reveal))
        // Content the last answer cannot satisfy is a fresh question.
        #expect(resolve("play donna at christmas", snapshot: nil)
                == .searchThenPlay("donna at christmas"))
        #expect(resolve("Play Donna at Christmas") == .searchThenPlay("Donna at Christmas"))
        #expect(resolve("show me donna in 1994") == .none)
        #expect(resolve("show donna's family tree videos") == .none)
    }

    // MARK: Paging

    @Test(arguments: [
        "show more", "more", "more please", "next", "the rest", "show me the rest",
        "any more?", "what else", "keep going", "show me more",
        "show more results",
    ])
    func pagingPhrasesPageWhenThereIsMore(text: String) {
        #expect(resolve(text, snapshot: Self.withMoreResults) == .nextPage, Comment(rawValue: text))
    }

    @Test func pagingIsHonestAboutTheEnd() {
        #expect(resolve("show more") == .declineNothingMore(total: 3))
        #expect(resolve("show more", snapshot: nil) == .declineNoPriorResult(nil))
        let graphSnapshot = Resolver.Snapshot(
            ast: .graph(.init(people: ["donna"], operation: .biography)),
            items: [], shownCount: 0, totalMatchCount: 1)
        #expect(resolve("show more", snapshot: graphSnapshot)
                == .declineNotRefinable(reason: "that answer isn't a list I can page through"))
    }

    // MARK: Cumulative refinement (Rick 2026-08-17)

    private typealias Chain = ArchivistFollowUpResolver.Chain

    /// Rick's exact chain: "show me rick" → "playing guitar" → "in westford"
    /// → "around 2005". Every step keeps the prior constraints (AND), the
    /// chain in the basis grows, and the answer says what changed.
    @Test func ricksChainNarrowsCumulatively() throws {
        let rick = ArchivistQueryAST.presence(.init(people: ["rick"]))
        var snapshot = Resolver.Snapshot(ast: rick, items: [], chain: nil)

        guard case .refine(let step1, let chain1, let changed1) =
                resolve("playing guitar", snapshot: snapshot) else {
            Issue.record("playing guitar: \(resolve("playing guitar", snapshot: snapshot))"); return
        }
        #expect(step1 == .presence(.init(people: ["rick"], keywords: ["guitar"])))
        #expect(chain1.description == "rick + guitar")
        #expect(changed1 == "Narrowed to Guitar")
        snapshot = Resolver.Snapshot(ast: step1, items: [], chain: chain1)

        guard case .refine(let step2, let chain2, let changed2) =
                resolve("in westford", snapshot: snapshot) else {
            Issue.record("in westford: \(resolve("in westford", snapshot: snapshot))"); return
        }
        #expect(step2 == .presence(.init(people: ["rick"], keywords: ["guitar", "westford"])))
        #expect(chain2.description == "rick + guitar + westford")
        #expect(changed2 == "Narrowed to Westford")
        snapshot = Resolver.Snapshot(ast: step2, items: [], chain: chain2)

        guard case .refine(let step3, let chain3, let changed3) =
                resolve("around 2005", snapshot: snapshot) else {
            Issue.record("around 2005: \(resolve("around 2005", snapshot: snapshot))"); return
        }
        #expect(step3 == .presence(.init(
            people: ["rick"], yearStart: 2004, yearEnd: 2006, keywords: ["guitar", "westford"])))
        #expect(chain3.description == "rick + guitar + westford · around 2005")
        #expect(changed3 == "Narrowed to around 2005")
        snapshot = Resolver.Snapshot(ast: step3, items: [], chain: chain3)

        // A person joins the chain; a comparative lead swaps instead.
        guard case .refine(let step4, let chain4, let changed4) =
                resolve("with donna", snapshot: snapshot) else {
            Issue.record("with donna: \(resolve("with donna", snapshot: snapshot))"); return
        }
        #expect(step4 == .presence(.init(
            people: ["rick", "donna"], yearStart: 2004, yearEnd: 2006,
            keywords: ["guitar", "westford"])))
        #expect(chain4.description == "rick + guitar + westford + donna · around 2005")
        #expect(changed4 == "Added Donna")
        snapshot = Resolver.Snapshot(ast: step4, items: [], chain: chain4)

        guard case .refine(let step5, let chain5, let changed5) =
                resolve("matt instead of rick", snapshot: snapshot) else {
            Issue.record("instead: \(resolve("matt instead of rick", snapshot: snapshot))"); return
        }
        #expect(step5 == .presence(.init(
            people: ["matt", "donna"], yearStart: 2004, yearEnd: 2006,
            keywords: ["guitar", "westford"])))
        #expect(chain5.description == "guitar + westford + donna + matt · around 2005")
        #expect(changed5 == "Switched to Matt")

        // A fully formed question after the chain starts fresh (translator).
        #expect(resolve("who is donna", snapshot: snapshot) == .none)
        #expect(resolve("show me donna at christmas", snapshot: snapshot) == .none)
        // A person plus other content with no lead is a new question too.
        #expect(resolve("donna at christmas", snapshot: snapshot) == .none)
        #expect(resolve("matt in 2005", snapshot: snapshot) == .none)
    }

    @Test(arguments: [
        // fragment, expected people, expected keywords, expected years, chain, what changed
        ("playing guitar", ["donna"], ["guitar"], nil, "donna + guitar", "Narrowed to Guitar"),
        ("guitar", ["donna"], ["guitar"], nil, "donna + guitar", "Narrowed to Guitar"),
        ("in westford", ["donna"], ["westford"], nil, "donna + westford", "Narrowed to Westford"),
        ("at the cape", ["donna"], ["cape"], nil, "donna + cape", "Narrowed to Cape"),
        ("down the cape", ["donna"], ["cape"], nil, "donna + cape", "Narrowed to Cape"),
        ("cape?", ["donna"], ["cape"], nil, "donna + cape", "Narrowed to Cape"),
        ("and the cape?", ["donna"], ["cape"], nil, "donna + cape", "Narrowed to Cape"),
        ("saying peekaboo", ["donna"], ["peekaboo"], nil, "donna + peekaboo", "Narrowed to Peekaboo"),
        ("riding the red bike", ["donna"], ["red bike"], nil, "donna + red bike", "Narrowed to Red Bike"),
        ("in 2005", ["donna"], nil, 2005...2005, "donna · 2005", "Narrowed to 2005"),
        ("2005", ["donna"], nil, 2005...2005, "donna · 2005", "Narrowed to 2005"),
        ("around 2005", ["donna"], nil, 2004...2006, "donna · around 2005", "Narrowed to around 2005"),
        ("about 2005", ["donna"], nil, 2004...2006, "donna · around 2005", "Narrowed to around 2005"),
        ("circa 2005", ["donna"], nil, 2004...2006, "donna · around 2005", "Narrowed to around 2005"),
        ("in the 90s", ["donna"], nil, 1990...1999, "donna · 1990–1999", "Narrowed to 1990–1999"),
        ("and in the 90s?", ["donna"], nil, 1990...1999, "donna · 1990–1999", "Narrowed to 1990–1999"),
        ("the early 90s", ["donna"], nil, 1990...1993, "donna · 1990–1993", "Narrowed to 1990–1993"),
        ("from 1990 to 1995", ["donna"], nil, 1990...1995, "donna · 1990–1995", "Narrowed to 1990–1995"),
        ("in westford around 2005", ["donna"], ["westford"], 2004...2006,
         "donna + westford · around 2005", "Narrowed to Westford, around 2005"),
        ("with matt", ["donna", "matt"], nil, nil, "donna + matt", "Added Matt"),
        ("and matt", ["donna", "matt"], nil, nil, "donna + matt", "Added Matt"),
        ("matt?", ["donna", "matt"], nil, nil, "donna + matt", "Added Matt"),
        ("what about matt?", ["matt"], nil, nil, "matt", "Switched to Matt"),
        ("how about rick", ["rick"], nil, nil, "rick", "Switched to Rick"),
        ("just rick", ["rick"], nil, nil, "rick", "Switched to Rick"),
        ("matt instead", ["matt"], nil, nil, "matt", "Switched to Matt"),
        ("with matt at the cape", ["donna", "matt"], ["cape"], nil,
         "donna + matt + cape", "Added Matt; narrowed to Cape"),
        ("what about christmas?", ["donna"], ["christmas"], nil, "donna + christmas", "Switched to Christmas"),
        ("or 2004", ["donna"], nil, 2004...2004, "donna · 2004", "Narrowed to 2004"),
        ("what about the late eighties?", ["donna"], nil, 1987...1989, "donna · 1987–1989", "Narrowed to 1987–1989"),
        ("how about 1994?", ["donna"], nil, 1994...1994, "donna · 1994", "Narrowed to 1994"),
    ] as [(String, [String]?, [String]?, ClosedRange<Int>?, String, String)])
    func fragmentsRefineTheDonnaQuestionCumulatively(
        text: String, people: [String]?, keywords: [String]?, years: ClosedRange<Int>?,
        chain: String, changed: String
    ) {
        let resolution = resolve(text)
        guard case .refine(.presence(let payload), let resultChain, let whatChanged) = resolution else {
            Issue.record("\(text): expected refine, got \(resolution)"); return
        }
        #expect(payload.people == people, Comment(rawValue: text))
        #expect(payload.keywords == keywords, Comment(rawValue: text))
        #expect(payload.yearStart == years?.lowerBound, Comment(rawValue: text))
        #expect(payload.yearEnd == years?.upperBound, Comment(rawValue: text))
        #expect(payload.mediaKind == .video, Comment(rawValue: text))
        #expect(resultChain.description == chain, Comment(rawValue: text))
        #expect(whatChanged == changed, Comment(rawValue: text))
    }

    @Test func refinementIsCumulativeAcrossPeopleTopicsAndYears() {
        // Starting from a chain that already has a topic and a year, a year
        // replaces the year, a topic adds, a person adds.
        let base = ArchivistQueryAST.presence(.init(
            people: ["donna"], yearStart: 1990, yearEnd: 1999, keywords: ["cape"]))
        let snapshot = Resolver.Snapshot(
            ast: base, items: [], chain: Chain(terms: ["donna", "cape"], yearLabel: "1990–1999"))
        #expect(resolve("1994", snapshot: snapshot) == .refine(
            .presence(.init(people: ["donna"], yearStart: 1994, yearEnd: 1994, keywords: ["cape"])),
            chain: Chain(terms: ["donna", "cape"], yearLabel: "1994"),
            whatChanged: "Narrowed to 1994"))
        #expect(resolve("christmas", snapshot: snapshot) == .refine(
            .presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1999,
                            keywords: ["cape", "christmas"])),
            chain: Chain(terms: ["donna", "cape", "christmas"], yearLabel: "1990–1999"),
            whatChanged: "Narrowed to Christmas"))
        #expect(resolve("and timmy", snapshot: snapshot) == .refine(
            .presence(.init(people: ["donna", "timmy"], yearStart: 1990, yearEnd: 1999,
                            keywords: ["cape"])),
            chain: Chain(terms: ["donna", "cape", "timmy"], yearLabel: "1990–1999"),
            whatChanged: "Added Timmy"))
        // Subtractive: drop a person, refuse to drop a topic that way.
        #expect(resolve("without donna", snapshot: snapshot) == .refine(
            .presence(.init(yearStart: 1990, yearEnd: 1999, keywords: ["cape"])),
            chain: Chain(terms: ["cape"], yearLabel: "1990–1999"),
            whatChanged: "Dropped Donna"))
        #expect(resolve("instead of donna", snapshot: snapshot) == .refine(
            .presence(.init(yearStart: 1990, yearEnd: 1999, keywords: ["cape"])),
            chain: Chain(terms: ["cape"], yearLabel: "1990–1999"),
            whatChanged: "Dropped Donna"))
        #expect(resolve("without rick", snapshot: snapshot)
                == .declineNotRefinable(reason: "Rick isn't part of the question"))
        // Duplicates are said honestly.
        #expect(resolve("and donna", snapshot: snapshot)
                == .declineNotRefinable(reason: "Donna is already part of the question"))
        #expect(resolve("at the cape", snapshot: snapshot)
                == .declineNotRefinable(reason: "“cape” is already part of the question"))
    }

    @Test func agePhraseFragmentClearsYearsAndKeepsTheKeyword() {
        let timmy = ArchivistQueryAST.presence(.init(
            people: ["timmy"], yearStart: 2010, yearEnd: 2015, keywords: ["peekaboo"]))
        let snapshot = Resolver.Snapshot(ast: timmy, items: [])
        #expect(resolve("as a baby", snapshot: snapshot) == .refine(
            .presence(.init(people: ["timmy"], keywords: ["peekaboo", "as a baby"])),
            chain: Chain(terms: ["timmy", "peekaboo"], yearLabel: "as a baby"),
            whatChanged: "Narrowed to as a baby"))
        // An explicit year afterwards replaces the age band.
        let banded = ArchivistQueryAST.presence(.init(
            people: ["timmy"], keywords: ["peekaboo", "as a baby"]))
        #expect(resolve("in 2006", snapshot: Resolver.Snapshot(
            ast: banded, items: [], chain: Chain(terms: ["timmy", "peekaboo"], yearLabel: "as a baby")))
            == .refine(
                .presence(.init(people: ["timmy"], yearStart: 2006, yearEnd: 2006, keywords: ["peekaboo"])),
                chain: Chain(terms: ["timmy", "peekaboo"], yearLabel: "2006"),
                whatChanged: "Narrowed to 2006"))
    }

    @Test func runawayAndNonsenseFragmentsAreDeclinedHonestly() {
        // A fragment that is only filler cannot be a refinement.
        #expect(resolve("hmm?") == .declineUninterpretable("hmm"))
        #expect(resolve("and then") == .declineUninterpretable("and then"))
        #expect(resolve("ok") == .declineUninterpretable("ok"))
        // The AST list bound stops a runaway chain.
        let full = ArchivistQueryAST.presence(.init(
            people: ["donna"], keywords: ["a1", "b2", "c3", "d4", "e5", "f6"]))
        guard case .declineNotRefinable(let reason) =
                resolve("westford", snapshot: Resolver.Snapshot(ast: full, items: [])) else {
            Issue.record("expected the chain cap"); return
        }
        #expect(reason.contains("at most 6"))
        // Dropping the only constraint leaves nothing to search for.
        #expect(resolve("without donna", snapshot: Resolver.Snapshot(
            ast: .presence(.init(people: ["donna"])), items: []))
            == .declineNotRefinable(reason: "that would leave nothing to search for"))
    }

    @Test func refinementRespectsTheShapeOfThePreviousQuestion() {
        let graph = Resolver.Snapshot(
            ast: .graph(.init(people: ["donna"], operation: .kinship, relation: .father)),
            items: [])
        #expect(resolve("what about rick?", snapshot: graph) == .refine(
            .graph(.init(people: ["rick"], operation: .kinship, relation: .father)),
            chain: Chain(terms: ["rick"]), whatChanged: "Switched to Rick"))
        #expect(resolve("and in the 90s?", snapshot: graph) == .declineNotRefinable(
            reason: "a family-tree question doesn't take a year"))
        // Bare unknown word after a non-list answer still goes to the model.
        #expect(resolve("cape?", snapshot: graph) == .none)

        let temporal = Resolver.Snapshot(
            ast: .temporal(.init(subject: "timmy", operation: .age,
                                 reference: .currentSelection)),
            items: [])
        #expect(resolve("what about 1998?", snapshot: temporal) == .refine(
            .temporal(.init(subject: "timmy", operation: .age,
                            reference: .explicitYear(1998))),
            chain: Chain(terms: ["timmy"], yearLabel: "1998"), whatChanged: "Narrowed to 1998"))
        #expect(resolve("and rick?", snapshot: temporal) == .refine(
            .temporal(.init(subject: "rick", operation: .age,
                            reference: .currentSelection)),
            chain: Chain(terms: ["rick"]), whatChanged: "Added Rick"))

        let aggregate = Resolver.Snapshot(
            ast: .aggregate(.init(operation: .coOccurrence, anchorPeople: ["donna"])),
            items: [])
        #expect(resolve("what about matt?", snapshot: aggregate) == .refine(
            .aggregate(.init(operation: .coOccurrence, anchorPeople: ["matt"])),
            chain: Chain(terms: ["matt"]), whatChanged: "Switched to Matt"))
        #expect(resolve("and the cape?", snapshot: aggregate) == .declineNotRefinable(
            reason: "a who-appears-with question only takes a person"))
    }

    /// Eval 2026-09-01: "and her husband?" after "did she have kids"
    /// (graph kinship children for Martha Lamson). "and" was a lead, "her"
    /// filler, and "husband" a KNOWN PERSON because the tree has five
    /// people with Husband in the name — so the refiner replaced the
    /// person and kept relation = children: "Which Husband do you mean?".
    /// A fragment carrying a third-person pronoun is about the last
    /// answer's subject and belongs to the pronoun rewrite, never here.
    @Test func aPronounFragmentIsNeverARefinement() {
        let kids = Resolver.Snapshot(
            ast: .graph(.init(people: ["martha lamson"], operation: .kinship, relation: .children)),
            items: [])
        let treeHasAHusband: (String) -> Bool = { name in
            ["martha lamson", "husband", "rick"].contains(name.lowercased())
        }
        #expect(Resolver.resolve("and her husband?", snapshot: kids, isKnownPerson: treeHasAHusband) == .none)
        #expect(Resolver.resolve("and his kids", snapshot: kids, isKnownPerson: treeHasAHusband) == .none)
        #expect(Resolver.resolve("her parents", snapshot: kids, isKnownPerson: treeHasAHusband) == .none)
        #expect(Resolver.resolve("what about their children", snapshot: kids, isKnownPerson: treeHasAHusband) == .none)
        // The same fragments against a LIST answer are not refinements either.
        #expect(resolve("and her husband?") == .none)
        #expect(resolve("and him at the cape") == .none)
        // A named person still refines as before.
        #expect(Resolver.resolve("what about rick?", snapshot: kids, isKnownPerson: treeHasAHusband) == .refine(
            .graph(.init(people: ["rick"], operation: .kinship, relation: .children)),
            chain: Chain(terms: ["rick"]), whatChanged: "Switched to Rick"))
        // A lone pronoun with nothing beside it keeps the old honest decline.
        #expect(resolve("and her?") == .declineUninterpretable("and her"))
    }

    @Test func refinementWithoutAPreviousQuestionDeclinesOrDefers() {
        #expect(resolve("and in the 90s?", snapshot: nil) == .declineNoPriorResult(nil))
        #expect(resolve("what about matt?", snapshot: nil) == .declineNoPriorResult(nil))
        // A bare scope phrase with nothing to refine goes to the translator.
        #expect(resolve("in the 90s?", snapshot: nil) == .none)
        #expect(resolve("1994?", snapshot: nil) == .none)
        #expect(resolve("playing guitar", snapshot: nil) == .none)
        #expect(resolve("in westford", snapshot: nil) == .none)
    }

    @Test func yearAndAgeExtractionReadHumanFragments() {
        func years(_ text: String) -> String {
            guard let hit = Resolver.extractYears(from: Resolver.normalizedWords(text)) else {
                return "nil"
            }
            return "\(hit.range.lowerBound)-\(hit.range.upperBound)|\(hit.label)|"
                + hit.remaining.joined(separator: " ")
        }
        #expect(years("around 2005") == "2004-2006|around 2005|")
        #expect(years("2005 ish") == "2004-2006|around 2005|")
        #expect(years("2005 or so") == "2004-2006|around 2005|")
        #expect(years("in westford around 2005") == "2004-2006|around 2005|in westford")
        #expect(years("the late 80s at the cape") == "1987-1989|1987–1989|the at the cape")
        #expect(years("from 1990 to 1995") == "1990-1995|1990–1995|from")
        #expect(years("the 90's") == "1990-1999|1990–1999|the")
        #expect(years("cape") == "nil")

        func age(_ words: [String]) -> String {
            guard let hit = Resolver.extractAgeBand(from: words) else { return "nil" }
            return hit.keyword + "|" + hit.remaining.joined(separator: " ")
        }
        #expect(age(["as", "a", "baby"]) == "as a baby|")
        #expect(age(["as", "a", "kid", "at", "the", "cape"]) == "as a kid|at the cape")
        #expect(age(["cape"]) == "nil")
    }

    @Test(arguments: [
        "count how many videos of donna we have?",
        "who was donna's great grandmother on her maternal side?",
        "and rick's father?",
        "and who is matt?",
        "show timmy as a baby saying peekaboo",
        "how old was timmy in 1998?",
        "who appears most often with donna?",
        "can we change donna's biography?",
        "show me videos of donna from 1992 to 1995",
        "videos of nobody",
        "christmas videos",
        "cape videos from 1994",
        "donna at christmas",
    ])
    func realQuestionsAreNeverMistakenForFollowUps(text: String) {
        #expect(resolve(text) == .none, Comment(rawValue: text))
    }

    // MARK: Local family-tree shapes

    @Test func familyTreeSentencesBuildTheGraphASTLocally() {
        #expect(resolve("show donna's family tree") == .localQuery(
            .graph(.init(people: ["donna"], operation: .familyTree))))
        #expect(resolve("show ricks family tree") == .localQuery(
            .graph(.init(people: ["ricks"], operation: .familyTree))))
        #expect(resolve("get me the family tree for the breens") == .localQuery(
            .graph(.init(people: [], operation: .familyTree, surname: "breens"))))
        #expect(resolve("show family tree") == .localQuery(
            .graph(.init(people: [], operation: .familyTree))))
        #expect(resolve("show me the family tree") == .localQuery(
            .graph(.init(people: [], operation: .familyTree))))
        #expect(resolve("open the breen family tree") == .localQuery(
            .graph(.init(people: ["breen"], operation: .familyTree))))
        #expect(resolve("show me the family tree of donna") == .localQuery(
            .graph(.init(people: ["donna"], operation: .familyTree))))
        #expect(resolve("show me donna's ancestry") == .localQuery(
            .graph(.init(people: ["donna"], operation: .familyTree))))
        // Extra content is a different question.
        #expect(resolve("who is in donna's family tree?") == .none)
        #expect(resolve("show family tree videos from 1994") == .none)
    }

    // MARK: Year expressions

    @Test func yearExpressionsCoverHumanPhrasing() {
        func years(_ text: String) -> ClosedRange<Int>? {
            Resolver.yearExpression(Resolver.normalizedWords(text))
        }
        #expect(years("1994") == 1994...1994)
        #expect(years("90s") == 1990...1999)
        #expect(years("1990s") == 1990...1999)
        #expect(years("nineties") == 1990...1999)
        #expect(years("early 90s") == 1990...1993)
        #expect(years("mid 90s") == 1994...1996)
        #expect(years("late 90s") == 1997...1999)
        #expect(years("1990 to 1995") == 1990...1995)
        #expect(years("1990-1995") == 1990...1995)
        #expect(years("1995 to 1990") == nil)
        #expect(years("cape") == nil)
        #expect(years("1850") == nil)
    }

    // MARK: "and the newest?" (2026-09-02)

    @Test(arguments: [
        ("and the newest?", Resolver.DateOrder.newestFirst, 1, nil as Resolver.MediaVerb?),
        ("the most recent one?", .newestFirst, 1, nil),
        ("and the most recent one", .newestFirst, 1, nil),
        ("what's the latest one", .newestFirst, 1, nil),
        ("and the oldest?", .oldestFirst, 1, nil),
        ("the earliest one", .oldestFirst, 1, nil),
        ("which is the oldest", .oldestFirst, 1, nil),
        ("the second newest", .newestFirst, 2, nil),
        ("the third oldest one", .oldestFirst, 3, nil),
        ("show me the newest one", .newestFirst, 1, .show),
        ("play the earliest one", .oldestFirst, 1, .play),
        ("play the latest one", .newestFirst, 1, .play),
    ]) func superlativesReRunTheLastQuestionInDateOrder(
        text: String, order: Resolver.DateOrder, ordinal: Int, verb: Resolver.MediaVerb?
    ) {
        #expect(resolve(text) == .dateOrdered(order: order, ordinal: ordinal, verb: verb), Comment(rawValue: text))
        // The same words with no memory still resolve the same way: the
        // client decides whether there is anything to sort.
        #expect(resolve(text, snapshot: nil) == .dateOrdered(order: order, ordinal: ordinal, verb: verb), Comment(rawValue: text))
    }

    @Test func superlativesWithOtherContentAreNotFollowUps() {
        // A person or topic beside the superlative is a fresh question.
        #expect(resolve("the newest of donna") != .dateOrdered(order: .newestFirst, ordinal: 1, verb: nil))
        #expect(resolve("newest videos at the cape") != .dateOrdered(order: .newestFirst, ordinal: 1, verb: nil))
        // "the last one" is still the last CITED item, not the newest.
        #expect(resolve("play the last one") == .mediaAction(verb: .play, indices: [2]))
        // A bare "recent" / "old" is too loose to be a superlative.
        #expect(resolve("the old one") != .dateOrdered(order: .oldestFirst, ordinal: 1, verb: nil))
        #expect(resolve("and the recent one") != .dateOrdered(order: .newestFirst, ordinal: 1, verb: nil))
        // Contradictory ends are not a follow-up.
        #expect(resolve("the newest and the oldest") == .none)
    }

    @Test func requestedPositionReadsTheOrdinalOfAMediaPhrase() {
        #expect(Resolver.requestedPosition(in: "ok show me the second one").ordinal == 2)
        #expect(Resolver.requestedPosition(in: "play number 3").ordinal == 3)
        #expect(Resolver.requestedPosition(in: "play the last one").wantsLast)
        #expect(Resolver.requestedPosition(in: "show it").ordinal == nil)
    }
}
