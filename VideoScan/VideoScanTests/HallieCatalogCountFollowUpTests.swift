// HallieCatalogCountFollowUpTests.swift
// The sticky count scope (design §3.5): a decade REPLACES the previous
// decade (pinned against applyCumulative too), the whole-catalog scope
// maps to every record, an intervening tree question or an unrelated list
// clears the scope, the count-only phrasing, and the scale dimension — a
// count re-run over 100,000 presence snapshots inside a stated budget.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie catalog count follow-up", .serialized)
struct HallieCatalogCountFollowUpTests {
    typealias Exec = HallieTurnExecutor
    typealias Memory = Exec.ConversationMemory
    typealias Count = HallieCatalogCountFollowUp
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ path: String, people: [String] = ["Donna"]) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path, directory: (path as NSString).deletingLastPathComponent,
            volumeName: "Fixture", inferredDate: nil,
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: stamp) }, transcript: nil)
    }

    private var wholeCatalog: Memory {
        var memory = Memory()
        memory.record(intent: nil, result: .init(
            route: .aggregate, outcome: .answered, prose: "18 files.", basisLine: "Basis: fixture.",
            queryDescription: "catalog-stats total", citations: [], catalogPersonName: nil,
            refinableQuery: .wholeCatalog))
        #expect(memory.catalog.countScope == .wholeCatalog)
        return memory
    }

    private func countedQuery(_ ast: ArchivistQueryAST, question: String = "how many videos of donna", count: Int = 3) -> Memory {
        var memory = Memory()
        memory.record(intent: .init(originalQuestion: question, ast: ast),
                      result: .init(route: .presence, outcome: .answered, prose: "\(count).", basisLine: "Basis: fixture.",
                                    queryDescription: "shape=presence", citations: [], catalogPersonName: nil, matchCount: count))
        #expect(memory.catalog.countScope == .query(ast))
        return memory
    }

    // MARK: Logic

    @Test func aDecadeFragmentAfterAWholeCatalogCountIsACountOfThatDecade() throws {
        let intent = try #require(Count.detect("How many of those are from the 90s?", memory: wholeCatalog))
        #expect(intent.ast == .presence(.init(yearStart: 1990, yearEnd: 1999)))
        #expect(intent.countOnly)
        #expect(intent.refinementNote == "refining: 1990–1999")
        #expect(intent.refinementChange == "from the 1990s")
        #expect(intent.refinementChain == .init(terms: [], yearLabel: "1990–1999"))
    }

    @Test func theNextDecadeReplacesThePreviousOne() throws {
        let nineties = ArchivistQueryAST.presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1999))
        let memory = countedQuery(nineties, question: "how many of those are from the 90s")
        let intent = try #require(Count.detect("and how many from the 80s", memory: memory))
        #expect(intent.ast == .presence(.init(people: ["donna"], yearStart: 1980, yearEnd: 1989)),
                "the 80s REPLACE the 90s; they never intersect to nothing")
        #expect(intent.refinementChain == .init(terms: ["donna"], yearLabel: "1980–1989"))
        // The same rule the refinement lane applies (ListFields years are scalar).
        let cumulative = ArchivistFollowUpResolver.applyCumulative(
            [.years(1980...1989, label: "1980–1989")], to: nineties, previousChain: nil)
        #expect(cumulative == .refine(.presence(.init(people: ["donna"], yearStart: 1980, yearEnd: 1989)),
                                      chain: .init(terms: ["donna"], yearLabel: "1980–1989"),
                                      whatChanged: "Narrowed to 1980–1989"))
    }

    @Test func singleYearsRangesAndBareFragments() throws {
        #expect(try #require(Count.detect("what about 2005", memory: wholeCatalog)).ast
                == .presence(.init(yearStart: 2005, yearEnd: 2005)))
        #expect(try #require(Count.detect("1990 to 1995?", memory: wholeCatalog)).ast
                == .presence(.init(yearStart: 1990, yearEnd: 1995)))
        #expect(try #require(Count.detect("and the 80s?", memory: wholeCatalog)).refinementChange == "from the 1980s")
        #expect(Count.label(for: 1990...1995) == "1990–1995")
        #expect(Count.label(for: 1994...1994) == "1994")
        #expect(Count.label(for: 2000...2009) == "the 2000s")
    }

    @Test func notAContinuationOfTheCount() {
        // No scope in memory.
        #expect(Count.detect("how many from the 90s", memory: Memory()) == nil)
        // A person or topic word is the refinement lane's business.
        #expect(Count.detect("and donna in the 90s", memory: wholeCatalog) == nil)
        #expect(Count.detect("how many from the 90s at christmas", memory: wholeCatalog) == nil)
        // A list ask, not a count.
        #expect(Count.detect("show me the ones from the 90s", memory: wholeCatalog) == nil)
        // No year phrase at all.
        #expect(Count.detect("how many of those", memory: wholeCatalog) == nil)
    }

    @Test func anInterveningTreeQuestionOrUnrelatedListClearsTheScope() {
        var memory = wholeCatalog
        memory.record(intent: .init(originalQuestion: "tell me about rick",
                                    ast: .graph(.init(people: ["rick"], operation: .biography))),
                      result: .init(route: .graph, outcome: .answered, prose: "Rick.", basisLine: "Basis: fixture.",
                                    queryDescription: nil, citations: [], catalogPersonName: "Rick"))
        #expect(memory.catalog.countScope == nil)
        #expect(Count.detect("and the 80s?", memory: memory) == nil)

        var other = wholeCatalog
        other.record(intent: .init(originalQuestion: "videos of donna", ast: .presence(.init(people: ["donna"]))),
                     result: .init(route: .presence, outcome: .answered, prose: "3.", basisLine: "Basis: fixture.",
                                   queryDescription: nil, citations: [], catalogPersonName: nil, matchCount: 3))
        #expect(other.catalog.countScope == nil)
        #expect(Count.detect("and the 80s?", memory: other) == nil)
    }

    // MARK: Phrasing

    @Test func countOnlyPhrasesTheNumberAndCitesAHandful() async throws {
        let records = (0..<6).map { record("/Fixture/198\($0)/donna_80s_\($0).mov") }
            + (0..<8).map { record("/Fixture/199\($0)/donna_90s_\($0).mov") }
        let context = Exec.Context(presenceRecords: records)
        let memory = wholeCatalog
        let intent = try #require(Count.detect("how many of those are from the 90s?", memory: memory))
        let result = try await Exec.execute(.init(intent: intent), context: context)
        #expect(result.route == .presence)
        #expect(result.outcome == .answered)
        #expect(result.matchCount == 8)
        #expect(result.prose == "8 catalog items from the 1990s.", Comment(rawValue: result.prose))
        #expect(result.citations.count == 5, "a count cites at most a handful")
        #expect(result.basisLine.hasPrefix("Basis: refining: 1990–1999; "), Comment(rawValue: result.basisLine))

        let none = try #require(Count.detect("and the 2010s?", memory: memory))
        let empty = try await Exec.execute(.init(intent: none), context: context)
        #expect(empty.outcome == .declined)
        #expect(empty.prose == "Nothing from the 2010s.", Comment(rawValue: empty.prose))
    }

    // MARK: Scale — 100,000 snapshots

    @Test func aCountReRunOverOneHundredThousandSnapshotsStaysWithinBudget() async throws {
        // Digit-free file names: the path-year scanner reads any 4-digit
        // run as a year, so "clip_1995" would count as 1995 too.
        func letters(_ n: Int) -> String {
            var n = n, out = ""
            repeat { out.append(Character(UnicodeScalar(97 + n % 26)!)); n /= 26 } while n > 0
            return out
        }
        let records = (0..<100_000).map { index in
            record("/Fixture/\(1980 + index % 40)/clip_\(letters(index)).mov", people: index % 3 == 0 ? ["Donna"] : ["Rick"])
        }
        let context = Exec.Context(presenceRecords: records)
        let intent = try #require(Count.detect("how many of those are from the 90s?", memory: wholeCatalog))
        let start = Date()
        let result = try await Exec.execute(.init(intent: intent), context: context)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.matchCount == 25_000, Comment(rawValue: "\(String(describing: result.matchCount))"))
        #expect(result.citations.count <= 5)
        // Budget: one presence pass over 100k snapshots, well under the
        // 4 s the presence executor's own scale tests allow.
        #expect(elapsed < 4.0, Comment(rawValue: "100k count re-run took \(elapsed)s"))
    }
}
