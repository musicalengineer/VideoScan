import Foundation
import Testing
@testable import VideoScan

/// Conversation memory + the model-free pre-translation step, exercised
/// through the real executor: paging over a result set larger than one
/// citation page, media actions on cited items, refinement chains, and the
/// "as a baby" birth-year band. Everything is synthetic and deterministic.
@MainActor
@Suite("Hallie conversation memory", .serialized)
struct HallieConversationMemoryTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ path: String, people: [String], transcript: String? = nil,
        inferred: Date? = nil
    ) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "Fixture",
            inferredDate: inferred,
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: stamp) },
            transcript: transcript)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: 12))!
    }

    /// 60 Donna videos across 1990–2019 → three citation pages of 25/25/10.
    private func donnaRecords() -> [ArchivistPresenceRecordSnapshot] {
        (0..<60).map { index in
            record("/Fixture/\(1990 + index / 2)/donna_\(index).mov", people: ["Donna"])
        }
    }

    private func run(
        _ text: String,
        memory: inout HallieTurnExecutor.ConversationMemory,
        context: HallieTurnExecutor.Context,
        translated: ArchivistQueryAST? = nil
    ) async throws -> HallieTurnExecutor.Result {
        let pre = HallieTurnExecutor.preTranslation(
            question: text, playAfterAnswer: false, memory: memory,
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
        switch pre {
        case .translate(let question, _):
            let ast = try #require(translated, "\(text): unexpectedly needed translation")
            #expect(question == text)
            let intent = HallieTurnExecutor.Intent(originalQuestion: text, ast: ast)
            let result = try await HallieTurnExecutor.execute(
                HallieTurnExecutor.Request(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return result
        case .run(let intent):
            #expect(translated == nil, "\(text): resolved locally but a translation was supplied")
            let result = try await HallieTurnExecutor.execute(
                HallieTurnExecutor.Request(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return result
        case .answer(let result):
            #expect(translated == nil, "\(text): answered locally but a translation was supplied")
            memory.record(intent: nil, result: result)
            return result
        }
    }

    @Test func showMorePagesTheSameResultSetUntilExhausted() async throws {
        let context = HallieTurnExecutor.Context(presenceRecords: donnaRecords())
        var memory = HallieTurnExecutor.ConversationMemory()

        let first = try await run(
            "how many videos of donna do we have?", memory: &memory, context: context,
            translated: .presence(.init(people: ["donna"])))
        #expect(first.outcome == .answered)
        #expect(first.matchCount == 60)
        #expect(first.citations.count == 25)
        #expect(first.citations.first?.filename == "donna_0.mov")
        #expect(memory.lastResultSet?.shownCount == 25)
        #expect(memory.lastResultSet?.totalMatchCount == 60)

        let second = try await run("show more", memory: &memory, context: context)
        #expect(second.route == .presence)
        #expect(second.outcome == .answered)
        #expect(second.prose == "Here are 25 more (items 26–50 of 60).")
        #expect(second.citations.first?.filename == "donna_25.mov")
        #expect(second.citations.count == 25)
        #expect(second.basisLine.hasPrefix("Basis: continuing your last question (items 26 on); "))
        #expect(memory.lastResultSet?.shownCount == 50)

        // "play the first one" now refers to the page being shown.
        let play = try await run("play the first one", memory: &memory, context: context)
        #expect(play.route == .followUp)
        #expect(play.mediaAction?.kind == .play)
        #expect(play.mediaAction?.citations.map(\.filename) == ["donna_25.mov"])
        #expect(memory.lastResultSet?.shownCount == 50, "a media action must not disturb paging")

        let third = try await run("the rest", memory: &memory, context: context)
        #expect(third.prose == "Here are 10 more (items 51–60 of 60).")
        #expect(third.citations.count == 10)
        #expect(memory.lastResultSet?.shownCount == 60)

        let done = try await run("show more", memory: &memory, context: context)
        #expect(done.route == .followUp)
        #expect(done.outcome == .declined)
        #expect(done.prose == "That's all of them — I've already shown all 60.")
    }

    @Test func mediaActionsReferToCitedItemsAndDeclineWithoutThem() async throws {
        let context = HallieTurnExecutor.Context(presenceRecords: donnaRecords())
        var memory = HallieTurnExecutor.ConversationMemory()

        let nothing = try await run("play one of them, say the first one",
                                    memory: &memory, context: context)
        #expect(nothing.route == .followUp)
        #expect(nothing.outcome == .declined)
        #expect(nothing.prose == "Ask me for something first, then I can play one of them.")
        #expect(nothing.mediaAction == nil)

        _ = try await run("videos of donna", memory: &memory, context: context,
                          translated: .presence(.init(people: ["donna"])))
        let third = try await run("reveal number 3", memory: &memory, context: context)
        #expect(third.mediaAction == .init(
            kind: .reveal, citations: Array(memory.lastResultSet!.citations[2...2])))
        #expect(third.prose == "Revealing item 3 from my last answer: “donna_2.mov”.")

        let byYear = try await run("show me the one from 1999", memory: &memory, context: context)
        #expect(byYear.mediaAction?.kind == .show)
        #expect(byYear.mediaAction?.citations.map(\.filename) == ["donna_18.mov"])

        let outOfRange = try await run("play number 40", memory: &memory, context: context)
        #expect(outOfRange.outcome == .declined)
        #expect(outOfRange.prose == "My last answer listed 25 items, so there is no number 40.")
    }

    @Test func refinementChainsEditTheLastASTAndSayso() async throws {
        let records = donnaRecords() + [
            record("/Fixture/1994/rick_workshop.mov", people: ["Rick"]),
            record("/Fixture/1996/rick_cape.mov", people: ["Rick"]),
        ]
        let context = HallieTurnExecutor.Context(
            presenceRecords: records,
            profiles: [.init(stableID: "rick", canonicalName: "Rick")])
        var memory = HallieTurnExecutor.ConversationMemory()

        _ = try await run("how many videos of donna do we have?", memory: &memory,
                          context: context, translated: .presence(.init(people: ["donna"])))
        let nineties = try await run("and in the 90s?", memory: &memory, context: context)
        #expect(nineties.route == .presence)
        #expect(nineties.matchCount == 20)
        #expect(nineties.basisLine.hasPrefix(
            "Basis: refining: donna · 1990–1999; "))
        #expect(nineties.queryDescription == "shape=presence person=donna years=1990...1999")

        let rick = try await run("what about rick?", memory: &memory, context: context)
        #expect(rick.matchCount == 2)
        // Person names keep the typed/recovered casing since 87a21a4d.
        #expect(rick.queryDescription?.lowercased() == "shape=presence person=rick years=1990...1999")
        #expect(rick.basisLine.hasPrefix("Basis: refining: rick · 1990–1999; "))

        // The chain continues from the refined AST, not the original.
        let year = try await run("1996?", memory: &memory, context: context)
        #expect(year.matchCount == 1)
        #expect(year.citations.map(\.filename) == ["rick_cape.mov"])
    }

    @Test func agePhraseUsesTheVouchedBirthYearAndSaysWhere() async throws {
        let records = [
            record("/Fixture/timmy_a.mov", people: ["Timmy"], transcript: "peekaboo",
                   inferred: date(2006, 3, 1)),
            record("/Fixture/timmy_b.mov", people: ["Timmy"], transcript: "peekaboo",
                   inferred: date(2012, 3, 1)),
            record("/Fixture/timmy_c.mov", people: ["Timmy"], transcript: "peekaboo",
                   inferred: date(2019, 3, 1)),
            record("/Fixture/timmy_d.mov", people: ["Timmy"], transcript: "bath time",
                   inferred: date(2006, 3, 1)),
        ]
        let profiles = [HallieTurnExecutor.ProfileSnapshot(
            stableID: "timmy", canonicalName: "Timmy", birthdate: date(2005, 4, 22))]
        let context = HallieTurnExecutor.Context(presenceRecords: records, profiles: profiles)

        let baby = try await HallieTurnExecutor.execute(
            .cross(.init(people: ["timmy"], keywords: ["as a baby"], transcript: ["peekaboo"])),
            context: context)
        #expect(baby.route == .cross)
        #expect(baby.citations.map(\.filename) == ["timmy_a.mov"])
        #expect(baby.basisLine.contains(
            "using Timmy's birth year 2005 from the People profile (“as a baby” = 2005–2007)"))
        #expect(baby.queryDescription?.lowercased() == "shape=cross person=timmy years=2005...2007 keyword=peekaboo"
                || baby.queryDescription?.lowercased() == "shape=presence person=timmy years=2005...2007 keyword=peekaboo")

        let kid = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["timmy"], keywords: ["kid", "peekaboo"])),
            context: context)
        #expect(kid.citations.map(\.filename) == ["timmy_b.mov"])

        let teen = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["timmy"], keywords: ["as a teenager", "peekaboo"])),
            context: context)
        #expect(teen.citations.map(\.filename) == ["timmy_c.mov"])

        // No birth year known: the word is searched literally and the basis
        // says so — nothing is invented.
        let unknown = try await HallieTurnExecutor.execute(
            .cross(.init(people: ["timmy"], keywords: ["as a baby"], transcript: ["peekaboo"])),
            context: .init(presenceRecords: records, profiles: []))
        #expect(unknown.outcome == .declined)
        #expect(unknown.basisLine.contains(
            "I don't know timmy's birth year, so “as a baby” was searched as a word"))

        // Explicit years win over the age phrase.
        let explicit = try await HallieTurnExecutor.execute(
            .cross(.init(people: ["timmy"], yearStart: 2019, yearEnd: 2019,
                         keywords: ["baby"], transcript: ["peekaboo"])),
            context: context)
        #expect(explicit.outcome == .declined)
        #expect(!explicit.basisLine.contains("birth year"))
    }

    @Test func memoryRecordsOnlyListAnswersAndForgetsOnFreshNoEvidence() async throws {
        let context = HallieTurnExecutor.Context(presenceRecords: donnaRecords())
        var memory = HallieTurnExecutor.ConversationMemory()
        _ = try await run("videos of donna", memory: &memory, context: context,
                          translated: .presence(.init(people: ["donna"])))
        #expect(memory.lastResultSet != nil)
        #expect(memory.lastPeople == ["donna"])

        _ = try await run("videos of nobody", memory: &memory, context: context,
                          translated: .presence(.init(people: ["nobody"])))
        #expect(memory.lastResultSet == nil, "a fresh no-evidence list answer clears the referent")
        #expect(memory.lastAST == .presence(.init(people: ["nobody"])))

        let play = try await run("play it", memory: &memory, context: context)
        #expect(play.outcome == .declined)
    }
}
