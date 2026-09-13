// HallieCatalogSuperlativeTests.swift
// Design §3.5 step 5 — "play the longest video in the archive" (eval
// cs030) is a LOCAL ordered run: detector shapes, the turn resolved
// without the translator in catalog mode on the presence route, a
// deterministic tie order by path, the size key for "the biggest file",
// the last list as the scope when the archive is not named, and a 100k
// scale sensor for the sort. Media matrix: N/A — nothing here opens a
// media file; playback stays behind the clients' perform/play gates.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let emptyTree = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
0 TRLR
"""

@Suite("Catalog superlative (design §3.5 step 5)")
struct HallieCatalogSuperlativeTests {
    typealias Exec = HallieTurnExecutor
    typealias Ask = HallieCatalogSuperlative.Ask
    private let graph = GedcomFamilyGraph(gedcomText: emptyTree)
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixture

    private func record(
        _ path: String, people: [String] = [], duration: Double? = nil, size: Int64? = nil
    ) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "Fixture",
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: stamp) },
            durationSeconds: duration,
            sizeBytes: size)
    }

    /// Three videos of different lengths and sizes (deliberately NOT in
    /// path order), one with neither.
    private var records: [ArchivistPresenceRecordSnapshot] {
        [
            record("/Fixture/1994/medium.mov", people: ["Donna"], duration: 1_800, size: 2_000_000_000),
            record("/Fixture/1990/long.mov", people: ["Donna"], duration: 3_600, size: 900_000_000),
            record("/Fixture/1999/short.mov", people: ["Rick"], duration: 45, size: 5_000_000_000),
            record("/Fixture/2001/unprobed.mov", people: ["Donna"]),
        ]
    }

    private func context(_ records: [ArchivistPresenceRecordSnapshot]) -> Exec.Context {
        .init(presenceRecords: records, profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    private func classified(
        _ q: String, memory: Exec.ConversationMemory = .init(), context: Exec.Context
    ) -> Exec.Classified {
        Exec.preTranslationClassified(
            question: q, playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) },
            catalogStats: nil,
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) },
            identity: Exec.nameIdentity { context })
    }

    /// One locally resolved turn: the chain must answer with `.run`, never
    /// ask for the translator; then execute and record.
    private func runLocally(
        _ q: String, memory: inout Exec.ConversationMemory, context: Exec.Context
    ) async throws -> (intent: Exec.Intent, result: Exec.Result, verdict: HallieModeClassifier.Verdict) {
        let turn = classified(q, memory: memory, context: context)
        guard case .run(let intent) = turn.decision else {
            throw TestFailure("\(q): expected a local run, got \(turn.decision)")
        }
        let result = try await Exec.execute(.init(intent: intent), context: context)
        memory.record(intent: intent, result: result)
        return (intent, result, turn.verdict)
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Detector

    @Test func detectorReadsTheShapesAndNothingElse() {
        #expect(HallieCatalogSuperlative.detect("play the longest video in the archive")
                == Ask(order: .longest, ordinal: 1, verb: .play, mediaKind: .video, scoped: true))
        #expect(HallieCatalogSuperlative.detect("What is the biggest file in the collection?")
                == Ask(order: .largest, ordinal: 1, verb: nil, mediaKind: nil, scoped: true))
        #expect(HallieCatalogSuperlative.detect("what's the smallest clip of the whole library")
                == Ask(order: .smallest, ordinal: 1, verb: nil, mediaKind: .video, scoped: true))
        #expect(HallieCatalogSuperlative.detect("show me the shortest one")
                == Ask(order: .shortest, ordinal: 1, verb: .show, mediaKind: nil, scoped: false))
        #expect(HallieCatalogSuperlative.detect("ok play the second longest clip please")
                == Ask(order: .longest, ordinal: 2, verb: .play, mediaKind: .video, scoped: false))
        #expect(HallieCatalogSuperlative.detect("find the oldest recording in our archive")
                == Ask(order: .oldest, ordinal: 1, verb: .show, mediaKind: .video, scoped: true))
        // Not this shape: the follow-up resolver's own date lane, a person
        // as the scope, content words, a plain search.
        #expect(HallieCatalogSuperlative.detect("and the newest?") == nil)
        #expect(HallieCatalogSuperlative.detect("the longest") == nil)
        #expect(HallieCatalogSuperlative.detect("the longest video of donna") == nil)
        #expect(HallieCatalogSuperlative.detect("play the longest video from the wedding") == nil)
        #expect(HallieCatalogSuperlative.detect("videos of donna in the archive") == nil)
        #expect(HallieCatalogSuperlative.detect("who has the longest name in the family tree") == nil)
    }

    // MARK: cs030 — local, catalog mode, presence route, play honoured

    @Test func playTheLongestVideoInTheArchiveResolvesLocally() async throws {
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let (intent, result, verdict) = try await runLocally(
            "play the longest video in the archive", memory: &memory, context: context)
        #expect(verdict.mode == .catalog)
        #expect(intent.playAfterAnswer, "the play verb rides through playAfterAnswer")
        #expect(intent.order?.order == .longest)
        #expect(intent.order?.scope == .list(.presence(.init(mediaKind: .video)), anyOfPeople: false))
        #expect(intent.refinementNote == "every video in the catalog sorted by length (longest first)")
        #expect(result.route == .presence, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose == "The longest of the 4 matches for every video in the catalog is long.mov (1h 00m 00s). "
                + "(1 file with no running time isn't in that order.)", Comment(rawValue: result.prose))
        #expect(result.citations.map(\.filename) == ["long.mov", "medium.mov", "short.mov"],
                "the citations are the ordered list, unprobed files set aside")
        #expect(result.matchCount == 3)
        #expect(result.basisLine.contains("ordered by the Catalog's probed running time; 1 without one set aside"),
                Comment(rawValue: result.basisLine))
        #expect(memory.mode == .catalog)
        #expect(memory.effectiveMode == .catalog)
    }

    @Test func theBiggestFileSortsBySizeOverTheWholeCatalog() async throws {
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let (intent, result, _) = try await runLocally(
            "what is the biggest file in the collection", memory: &memory, context: context)
        #expect(!intent.playAfterAnswer)
        #expect(intent.order?.order == .largest)
        #expect(intent.order?.scope == .wholeCatalog)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.hasPrefix("The largest of the 4 matches for everything in the catalog is short.mov ("),
                Comment(rawValue: result.prose))
        #expect(result.citations.map(\.filename) == ["short.mov", "medium.mov", "long.mov"])
    }

    @Test func theShortestAndTheSecondLongestPickTheOtherEnds() async throws {
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let shortest = try await runLocally("show me the shortest video in the archive", memory: &memory, context: context)
        #expect(shortest.result.prose.hasPrefix("The shortest of the 4 matches for every video in the catalog is short.mov (45s)."),
                Comment(rawValue: shortest.result.prose))
        #expect(!shortest.intent.playAfterAnswer)
        let second = try await runLocally("play the second longest video in the archive", memory: &memory, context: context)
        #expect(second.result.prose.hasPrefix("The second longest of the 4 matches for every video in the catalog is medium.mov (30m 00s)."),
                Comment(rawValue: second.result.prose))
    }

    // MARK: Ties and honesty

    @Test func tiesAreBrokenByPathWhateverTheInputOrder() async throws {
        let tied = [
            record("/Fixture/c.mov", duration: 600),
            record("/Fixture/a.mov", duration: 600),
            record("/Fixture/b.mov", duration: 600),
        ]
        let context = context(tied)
        var memory = Exec.ConversationMemory()
        let first = try await runLocally("play the longest video in the archive", memory: &memory, context: context)
        #expect(first.result.outcome == .answered)
        #expect(first.result.prose == "The 3 matches for every video in the catalog are all the same running time (10m 00s), "
                + "so there's no longest among them — first by name is a.mov.", Comment(rawValue: first.result.prose))
        #expect(first.result.citations.map(\.filename) == ["a.mov", "b.mov", "c.mov"])
        let second = try await runLocally("play the second longest video in the archive", memory: &memory, context: context)
        #expect(second.result.prose.contains("second by name is b.mov"), Comment(rawValue: second.result.prose))
        // Same durations, reversed input → same order out.
        let reversedContext = self.context(Array(tied.reversed()))
        var other = Exec.ConversationMemory()
        let again = try await runLocally("play the longest video in the archive", memory: &other, context: reversedContext)
        #expect(again.result.citations.map(\.filename) == ["a.mov", "b.mov", "c.mov"])
    }

    @Test func nothingProbedDeclinesHonestly() async throws {
        let context = context([record("/Fixture/x.mov"), record("/Fixture/y.mov")])
        var memory = Exec.ConversationMemory()
        let turn = try await runLocally("what's the longest video in the archive", memory: &memory, context: context)
        #expect(turn.result.outcome == .declined)
        #expect(turn.result.prose == "2 matched every video in the catalog, but none of them has a running time I can put in order.",
                Comment(rawValue: turn.result.prose))
        let past = try await runLocally("play the fifth longest video in the archive", memory: &memory, context: self.context(records))
        #expect(past.result.outcome == .declined)
        #expect(past.result.prose.hasPrefix("Only 3 of those have a running time, so there's no fifth longest one."),
                Comment(rawValue: past.result.prose))
    }

    // MARK: Without the archive named, the last list is the scope

    @Test func withoutTheArchiveNamedTheLastListIsSorted() async throws {
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let list = Exec.Intent(originalQuestion: "videos of donna",
                               ast: .presence(.init(people: ["Donna"])))
        let listed = try await Exec.execute(.init(intent: list), context: context)
        #expect(listed.outcome == .answered, Comment(rawValue: listed.prose))
        memory.record(intent: list, result: listed)
        let (intent, result, _) = try await runLocally("which is the longest one", memory: &memory, context: context)
        #expect(intent.refinementNote == "the last question sorted by length (longest first)")
        #expect(intent.order?.scope == .list(.presence(.init(people: ["Donna"])), anyOfPeople: false))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.hasPrefix("The longest of the 3 matches for Donna is long.mov (1h 00m 00s)."),
                Comment(rawValue: result.prose))
        // Naming the archive overrides the remembered list.
        let whole = try await runLocally("and the longest one in the whole archive?", memory: &memory, context: context)
        #expect(whole.intent.order?.scope == .wholeCatalog)
        #expect(whole.result.prose.hasPrefix("The longest of the 4 matches for everything in the catalog is long.mov"),
                Comment(rawValue: whole.result.prose))
    }

    // MARK: The existing date lane is untouched

    @Test func andTheNewestStillTakesTheFollowUpResolversLane() async throws {
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let list = Exec.Intent(originalQuestion: "videos of donna",
                               ast: .presence(.init(people: ["Donna"])))
        let listed = try await Exec.execute(.init(intent: list), context: context)
        memory.record(intent: list, result: listed)
        let (intent, result, _) = try await runLocally("and the newest?", memory: &memory, context: context)
        #expect(intent.refinementNote == "the last question sorted by date (newest first)")
        #expect(intent.order?.order == .newest)
        #expect(result.prose.hasPrefix("The newest of the 3 matches for Donna is unprobed.mov (2001)."),
                Comment(rawValue: result.prose))
    }

    // MARK: Scale — 100k matches sorted under budget

    @Test func sortingOneHundredThousandMatchesStaysUnderBudget() async throws {
        // Deterministic pseudo-random durations (LCG) so the sensor never
        // flakes; a 0.1% slice unprobed so the set-aside path is exercised.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        let n = 100_000
        var all: [ArchivistPresenceExecutor.DatedMatch] = []
        all.reserveCapacity(n)
        var longest = -1.0
        for i in 0..<n {
            let duration: Double? = i % 1000 == 0 ? nil : Double(next() % 36_000)
            if let duration { longest = max(longest, duration) }
            all.append(ArchivistPresenceExecutor.DatedMatch(
                citation: ArchivistEvidenceCitation(
                    recordID: UUID(), fullPath: "/Scale/\(i % 97)/clip_\(i).mov",
                    filename: "clip_\(i).mov", playbackSeconds: nil, bases: []),
                date: nil, durationSeconds: duration, sizeBytes: Int64(next() % 5_000_000_000)))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let (byLength, unkeyed) = Exec.ordered(all, by: .longest)
        let (bySize, _) = Exec.ordered(all, by: .smallest)
        let elapsed = clock.now - start
        #expect(unkeyed == 100)
        #expect(byLength.count == n - 100)
        #expect(byLength.first?.durationSeconds == longest)
        #expect(bySize.count == n)
        #expect(bySize.first!.sizeBytes! <= bySize.last!.sizeBytes!)
        #expect(elapsed < .seconds(4), "two 100k sorts took \(elapsed) (budget 4 s)")

        // End to end through the executor: 100k snapshots, one turn. Unique
        // durations, so the pick is the value and not the path tie-break.
        let records = (0..<n).map { i in
            record("/Scale/\(i % 97)/clip_\(i).mov", duration: Double(i) + 1)
        }
        let context = context(records)
        var memory = Exec.ConversationMemory()
        let turnStart = clock.now
        let turn = try await runLocally("play the longest video in the archive", memory: &memory, context: context)
        let turnElapsed = clock.now - turnStart
        #expect(turn.result.outcome == .answered, Comment(rawValue: turn.result.prose))
        #expect(turn.result.prose.contains("is clip_99999.mov (27h 46m 40s)"), Comment(rawValue: turn.result.prose))
        #expect(turnElapsed < .seconds(6), "the 100k ordered turn took \(turnElapsed) (budget 6 s)")
    }
}
