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

    // MARK: Elliptical refinement

    @Test func yearRefinementsReplaceTheYearFields() throws {
        let cases: [(String, ClosedRange<Int>)] = [
            ("and in the 90s?", 1990...1999),
            ("what about the 1980s", 1980...1989),
            ("how about 1994?", 1994...1994),
            ("in the 90s?", 1990...1999),
            ("1994?", 1994...1994),
            ("and from 1990 to 1995", 1990...1995),
            ("and the early 90s", 1990...1993),
            ("what about the late eighties?", 1987...1989),
            ("or 2004", 2004...2004),
        ]
        for (text, years) in cases {
            guard case .refine(let ast, let replaced) = resolve(text) else {
                Issue.record("\(text): expected refine, got \(resolve(text))")
                continue
            }
            #expect(replaced == .years(years), Comment(rawValue: text))
            guard case .presence(let payload) = ast else {
                Issue.record("\(text): shape changed"); continue
            }
            #expect(payload.people == ["donna"], Comment(rawValue: text))
            #expect(payload.mediaKind == .video, Comment(rawValue: text))
            #expect(payload.yearStart == years.lowerBound, Comment(rawValue: text))
            #expect(payload.yearEnd == years.upperBound, Comment(rawValue: text))
        }
    }

    @Test func personAndKeywordRefinementsReplaceTheirFields() {
        guard case .refine(.presence(let matt), let replacedMatt) = resolve("what about matt?") else {
            Issue.record("what about matt: \(resolve("what about matt?"))"); return
        }
        #expect(replacedMatt == .person("matt"))
        #expect(matt.people == ["matt"])
        #expect(matt.mediaKind == .video)

        guard case .refine(.presence(let cape), let replacedCape) = resolve("and the cape?") else {
            Issue.record("and the cape: \(resolve("and the cape?"))"); return
        }
        #expect(replacedCape == .keyword("cape"))
        #expect(cape.people == ["donna"])
        #expect(cape.keywords == ["cape"])

        // Bare unknown word without a lead is not confidently a refinement.
        #expect(resolve("cape?") == .none)
        // Bare known person without a lead is.
        #expect(resolve("matt?") == .refine(
            .presence(.init(people: ["matt"], mediaKind: .video)),
            replaced: .person("matt")))
    }

    @Test func refinementRespectsTheShapeOfThePreviousQuestion() {
        let graph = Resolver.Snapshot(
            ast: .graph(.init(people: ["donna"], operation: .kinship, relation: .father)),
            items: [])
        #expect(resolve("what about rick?", snapshot: graph) == .refine(
            .graph(.init(people: ["rick"], operation: .kinship, relation: .father)),
            replaced: .person("rick")))
        #expect(resolve("and in the 90s?", snapshot: graph) == .declineNotRefinable(
            reason: "a family-tree question doesn't take a year"))

        let temporal = Resolver.Snapshot(
            ast: .temporal(.init(subject: "timmy", operation: .age,
                                 reference: .currentSelection)),
            items: [])
        #expect(resolve("what about 1998?", snapshot: temporal) == .refine(
            .temporal(.init(subject: "timmy", operation: .age,
                            reference: .explicitYear(1998))),
            replaced: .years(1998...1998)))
        #expect(resolve("and rick?", snapshot: temporal) == .refine(
            .temporal(.init(subject: "rick", operation: .age,
                            reference: .currentSelection)),
            replaced: .person("rick")))

        let aggregate = Resolver.Snapshot(
            ast: .aggregate(.init(operation: .coOccurrence, anchorPeople: ["donna"])),
            items: [])
        #expect(resolve("what about matt?", snapshot: aggregate) == .refine(
            .aggregate(.init(operation: .coOccurrence, anchorPeople: ["matt"])),
            replaced: .person("matt")))
        #expect(resolve("and the cape?", snapshot: aggregate) == .declineNotRefinable(
            reason: "a who-appears-with question only takes a person"))
    }

    @Test func refinementWithoutAPreviousQuestionDeclinesOrDefers() {
        #expect(resolve("and in the 90s?", snapshot: nil) == .declineNoPriorResult(nil))
        #expect(resolve("what about matt?", snapshot: nil) == .declineNoPriorResult(nil))
        // A bare scope phrase with nothing to refine goes to the translator.
        #expect(resolve("in the 90s?", snapshot: nil) == .none)
        #expect(resolve("1994?", snapshot: nil) == .none)
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
}
