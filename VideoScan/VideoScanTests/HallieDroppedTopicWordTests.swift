// HallieDroppedTopicWordTests.swift
// Live, three times (2026-09-22, 09-24, 09-25 20:33): "Christmas videos from
// 2006" arrived from the local translator as `shape=presence year=2006` —
// "Christmas" dropped — and Hallie answered "There are 864 catalog items
// from 2006". True and cited, but a different question (ledger shape #1).
//
// Pinned: a curated holiday/event/place word (ArchivistKeywordAliases) the
// reader said is put back into the catalog query and named in the basis;
// never when an AST term already covers it (by alias), when the question
// negates, on a refinement re-run, or when the word is part of a name.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func day(_ year: Int, _ month: Int = 7, _ dayOfMonth: Int = 4) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone, year: year, month: month, day: dayOfMonth, hour: 12))!
}

/// 2006: one Christmas video and two others; 2007: another Christmas.
private let records: [ArchivistPresenceRecordSnapshot] = [
    .init(fullPath: "/isolated/2006/ChristmasDay2006-38mins.mov",
          dateCreated: day(2006, 12, 25), confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: confirmedAt)],
          resolvedDate: day(2006, 12, 25)),
    .init(fullPath: "/isolated/2006/DonnaRock&Piano.mov",
          dateCreated: day(2006), confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: confirmedAt)],
          resolvedDate: day(2006)),
    .init(fullPath: "/isolated/2006/Untitled-video-only.mov",
          dateCreated: day(2006), confirmedPeople: [],
          resolvedDate: day(2006)),
    .init(fullPath: "/isolated/1993/Cape-1993-archive.mkv",
          dateCreated: day(1993), confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: confirmedAt)],
          resolvedDate: day(1993)),
    .init(fullPath: "/isolated/2007/Christmas2007.mov",
          dateCreated: day(2007, 12, 25), confirmedPeople: [],
          resolvedDate: day(2007, 12, 25)),
]

@Suite("Hallie dropped topic word")
struct HallieDroppedTopicWordTests {
    typealias Exec = HallieTurnExecutor

    private func run(_ intent: Exec.Intent) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: intent),
            context: .init(presenceRecords: records),
            dependencies: .production)
    }

    private func paths(_ result: Exec.Result) -> Set<String> {
        Set(result.citations.map(\.fullPath))
    }

    /// Rick's turn, exactly as the translator returned it on 09-22/09-25.
    @Test func christmasVideosFrom2006KeepsChristmas() async throws {
        let result = try await run(.init(
            originalQuestion: "Christmas videos from 2006",
            ast: .presence(.init(yearStart: 2006, yearEnd: 2006, mediaKind: .video))))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(paths(result) == ["/isolated/2006/ChristmasDay2006-38mins.mov"],
                Comment(rawValue: "\(paths(result))"))
        #expect(result.matchCount == 1)
        #expect(result.basisLine.contains("“christmas”"), Comment(rawValue: result.basisLine))
    }

    /// The same drop on the cross and event shapes.
    @Test func crossAndEventShapesKeepTheWordToo() async throws {
        let cross = try await run(.init(
            originalQuestion: "christmas videos from 2006",
            ast: .cross(.init(yearStart: 2006, yearEnd: 2006, mediaKind: .video))))
        #expect(paths(cross) == ["/isolated/2006/ChristmasDay2006-38mins.mov"])
        let event = try await run(.init(
            originalQuestion: "show me christmas in 2006",
            ast: .event(.init(yearStart: 2006, yearEnd: 2006))))
        #expect(paths(event) == ["/isolated/2006/ChristmasDay2006-38mins.mov"])
    }

    /// Control: no topic word in the question → the year-only search stands.
    @Test func aYearOnlyQuestionIsUnchanged() async throws {
        let result = try await run(.init(
            originalQuestion: "videos from 2006",
            ast: .presence(.init(yearStart: 2006, yearEnd: 2006, mediaKind: .video))))
        #expect(result.matchCount == 3)
        #expect(!result.basisLine.contains("translator left"))
    }

    /// An alias already in the AST covers the group: nothing added twice.
    @Test func anAliasInTheASTCoversTheWord() {
        #expect(HallieDroppedTopicWord.missing(
            question: "christmas videos from 2006", people: [], terms: ["xmas"]).isEmpty)
        #expect(HallieDroppedTopicWord.missing(
            question: "show me Donna down the cape in the early 90s",
            people: ["donna"], terms: ["down the cape"]).isEmpty)
        #expect(HallieDroppedTopicWord.missing(
            question: "christmas morning 1991", people: [], terms: ["christmas morning"]).isEmpty)
    }

    @Test func theMissingWordIsReportedInQuestionOrder() {
        #expect(HallieDroppedTopicWord.missing(
            question: "Christmas videos from 2006", people: [], terms: []) == ["christmas"])
        #expect(HallieDroppedTopicWord.missing(
            question: "donna down the cape on her birthday", people: ["donna"], terms: [])
            == ["cape", "birthday"])
    }

    /// "not christmas" / "without" / "n't": the word may be the exclusion.
    @Test func aNegatedQuestionIsLeftAlone() async throws {
        #expect(HallieDroppedTopicWord.missing(
            question: "videos from 2006 that aren't christmas", people: [], terms: []).isEmpty)
        #expect(HallieDroppedTopicWord.missing(
            question: "2006 videos without christmas", people: [], terms: []).isEmpty)
        let result = try await run(.init(
            originalQuestion: "videos from 2006 but not christmas",
            ast: .presence(.init(yearStart: 2006, yearEnd: 2006, mediaKind: .video))))
        #expect(result.matchCount == 3)
    }

    /// A refinement re-runs the previous AST on purpose ("drop christmas").
    @Test func aRefinementIsLeftAlone() async throws {
        let result = try await run(.init(
            originalQuestion: "drop christmas",
            ast: .presence(.init(yearStart: 2006, yearEnd: 2006, mediaKind: .video)),
            refinementNote: "refining: 2006 without christmas"))
        #expect(result.matchCount == 3)
        #expect(!result.basisLine.contains("translator left"))
    }

    /// A word inside a person's name is the name, not a topic.
    @Test func aWordInsideANameIsNotATopic() {
        #expect(HallieDroppedTopicWord.missing(
            question: "videos of grace lake", people: ["grace lake"], terms: []).isEmpty)
    }

    /// Clean replay 2026-09-25 (ollama 0.34.4), five of Rick's cape asks:
    /// "find donna down the cape in the 90s" → people=[Donna, cape] →
    /// "I don't have any videos tagged with Donna and cape yet." A curated
    /// place/occasion word in the PEOPLE slot is a topic, unless it is an
    /// inner-circle name.
    @Test func aPlaceWordInThePeopleSlotIsSearchedAsAPlace() async throws {
        // The live tree has a Cape family, so "cape" passes for a known
        // surname and the unknown-name demotion keeps it as a person.
        let tree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME John /Cape/
        1 SEX M
        0 TRLR
        """)
        let result = try await Exec.execute(
            .init(intent: .init(originalQuestion: "find donna down the cape in the 90s",
                                ast: .presence(.init(people: ["Donna", "cape"])))),
            context: .init(presenceRecords: records, graph: tree),
            dependencies: .production)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(paths(result) == ["/isolated/1993/Cape-1993-archive.mkv"], Comment(rawValue: "\(paths(result))"))
        #expect(result.basisLine.contains("“cape”"), Comment(rawValue: result.basisLine))
    }

    @Test func topicPeopleAreOnlyCuratedWords() {
        #expect(HallieDroppedTopicWord.isTopicWord("cape"))
        #expect(HallieDroppedTopicWord.isTopicWord("Christmas"))
        #expect(HallieDroppedTopicWord.isTopicWord("down the cape"))
        #expect(!HallieDroppedTopicWord.isTopicWord("Donna"))
        #expect(!HallieDroppedTopicWord.isTopicWord("Grace Lake"))
    }
}
