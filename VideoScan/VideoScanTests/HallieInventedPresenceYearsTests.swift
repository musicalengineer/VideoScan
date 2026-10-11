// HallieInventedPresenceYearsTests.swift
//
// Demo probe 2026-10-09: "show me videos with <First>" arrived from the
// translator as person=<first> year=2025 and the answer opened with
// "I don't see anything from 2025…". The temporal lane already drops a year
// the question never said; the presence lane now does too — conservatively.
//
// Synthetic names only. Five dimensions: 1 logic (drop / keep), 2 scale n/a,
// 3 media n/a, 4 isolation (in-memory records), 5 sensor — a year the reader
// DID say, a decade word, an age word and a refinement re-run all keep it.
//
// C++ analogy: `#expect` is EXPECT_TRUE that also prints sub-expressions.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie — a year the question never says is not a presence constraint", .serialized)
struct HallieInventedPresenceYearsTests {
    typealias Exec = HallieTurnExecutor

    private static let carolPath = "/Synthetic/1999/visit.mov"

    private func context() async -> Exec.Context {
        let rec = VideoRecord()
        rec.fullPath = Self.carolPath
        rec.directory = "/Synthetic/1999"
        rec.filename = "visit.mov"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.confirmedByUserPeople = [
            ConfirmedTag(name: "Carol", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let snapshots = await ArchivistPresenceRecordSnapshot.capture([rec])
        return Exec.Context(presenceRecords: snapshots, profiles: [], graph: nil,
                            speakers: .none, mode: .catalog)
    }

    private func ask(_ question: String, year: Int) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: question,
                ast: .presence(.init(people: ["Carol"], yearStart: year, yearEnd: year,
                                     mediaKind: .video)))),
            context: await context())
    }

    /// RED before the fix: "I don't see anything from 2025, but I have 1 video…"
    @Test func anInventedYearIsDroppedAndTheTaggedVideoIsFound() async throws {
        let r = try await ask("show me videos with Carol", year: 2025)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.fullPath) == [Self.carolPath], Comment(rawValue: r.prose))
        #expect(!r.prose.contains("2025"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("never mentions"), Comment(rawValue: r.basisLine))
    }

    /// Sensor: a year the reader said is the reader's constraint.
    @Test func aYearTheQuestionSaysIsKept() async throws {
        let r = try await ask("show me videos with Carol from 2025", year: 2025)
        #expect(r.outcome != .answered, Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("never mentions"), Comment(rawValue: r.basisLine))
    }

    @Test func timeAndAgeWordsKeepTheTranslatorsYears() {
        let keeps = [
            "videos of Carol in the nineties", "Carol last Christmas", "Carol as a baby",
            "Carol when she was young", "videos of Carol from '99", "this year's videos of Carol",
            "Carol in nineteen ninety", "videos of Carol from 1999",
        ]
        for q in keeps {
            #expect(HallieInventedPresenceYears.questionMentionsTime(q), Comment(rawValue: q))
        }
        let drops = ["show me videos with Carol", "Carol at Thanksgiving",
                     "videos of Carol and Dana together", "who is with Carol?"]
        for q in drops {
            #expect(!HallieInventedPresenceYears.questionMentionsTime(q), Comment(rawValue: q))
        }
    }
}
