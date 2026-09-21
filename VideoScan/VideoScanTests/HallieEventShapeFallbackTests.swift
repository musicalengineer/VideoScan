// HallieEventShapeFallbackTests.swift
// Rick, 2026-09-20 evening: "getting a lot of these: 'Event queries are not
// supported yet; I did not run a broader search.'" — six live turns from
// hallie-conversation-2026-09-20.jsonl, all person + place + era asks the
// local translator returned as shape=event. The executor refused them in
// every mode, and in tree mode the gate refused the shape outright.
//
// Pinned here:
//   1. an event AST executes on the presence path and returns the SAME
//      catalog hits as the presence AST built by hand, with a basis line
//      that says it was read as an event — never "not supported";
//   2. an event with nothing to search for asks for the specifics;
//   3. in tree mode a media ask switches the turn to the catalog and runs
//      (with the `[hallie-mode] switched tree→catalog` line), while "show
//      me X in the family tree" still goes to the tree.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func tag(_ name: String) -> ConfirmedTag {
    ConfirmedTag(name: name, confirmedAt: confirmedAt)
}

private func day(_ year: Int, _ month: Int = 7, _ dayOfMonth: Int = 4) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone, year: year, month: month, day: dayOfMonth, hour: 12))!
}

/// A small catalog: Donna at the Cape in 1991 and 1996, Donna elsewhere in
/// 1992, Timmy at the Cape in 1991, Ellen Ronan in 1988.
private let fixtureRecords: [ArchivistPresenceRecordSnapshot] = [
    .init(fullPath: "/isolated/1991/donna_cape_1991.mov",
          dateCreated: day(1991), confirmedPeople: [tag("Donna")],
          resolvedDate: day(1991), userPlace: "Cape Cod"),
    .init(fullPath: "/isolated/1996/donna_cape_1996.mov",
          dateCreated: day(1996), confirmedPeople: [tag("Donna")],
          resolvedDate: day(1996), userPlace: "Cape Cod"),
    .init(fullPath: "/isolated/1992/donna_kitchen_1992.mov",
          dateCreated: day(1992), confirmedPeople: [tag("Donna")],
          transcript: "surprise! happy birthday", transcriptModel: "fixture-whisper",
          resolvedDate: day(1992)),
    .init(fullPath: "/isolated/1991/timmy_cape_1991.mov",
          dateCreated: day(1991), confirmedPeople: [tag("Timmy")],
          resolvedDate: day(1991), userPlace: "Cape Cod"),
    .init(fullPath: "/isolated/1988/ellen_ronan_1988.mov",
          dateCreated: day(1988), confirmedPeople: [tag("Ellen Ronan")],
          resolvedDate: day(1988)),
]

/// One of Rick's live turns: the words, what the translator returned, and
/// the presence AST a correct translation would have produced.
struct HallieEventShapeLiveTurn: Sendable, CustomStringConvertible {
    let question: String
    let event: ArchivistQueryAST.Event
    let presence: ArchivistQueryAST.Presence
    /// A file the search must find, so "equivalent" is never "both empty".
    let mustCite: String
    var description: String { question }
}

let hallieEventShapeRickSix: [HallieEventShapeLiveTurn] = [
    HallieEventShapeLiveTurn(question: "show me videos of donna down the cape in the 90s",
             event: .init(people: ["donna"], yearStart: 1990, yearEnd: 1999, mediaKind: .video, keywords: ["cape"]),
             presence: .init(people: ["donna"], yearStart: 1990, yearEnd: 1999, mediaKind: .video, keywords: ["cape"]),
             mustCite: "/isolated/1991/donna_cape_1991.mov"),
    HallieEventShapeLiveTurn(question: "show me Donna down the cape in the early 90s",
             event: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]),
             presence: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]),
             mustCite: "/isolated/1991/donna_cape_1991.mov"),
    // The translator's other reading of the same words: the place spoken.
    HallieEventShapeLiveTurn(question: "show me Donna down the cape in the early 90s",
             event: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, transcript: ["cape"]),
             presence: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]),
             mustCite: "/isolated/1991/donna_cape_1991.mov"),
    HallieEventShapeLiveTurn(question: "show me Donna down the cape in the early 90s",
             event: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["down the cape"], transcript: []),
             presence: .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["down the cape"]),
             mustCite: "/isolated/1991/donna_cape_1991.mov"),
    HallieEventShapeLiveTurn(question: "show me videos of donna down the cape",
             event: .init(people: ["donna"], mediaKind: .video, keywords: ["cape"]),
             presence: .init(people: ["donna"], mediaKind: .video, keywords: ["cape"]),
             mustCite: "/isolated/1996/donna_cape_1996.mov"),
    HallieEventShapeLiveTurn(question: "show me ellen ronan",
             event: .init(people: ["ellen ronan"]),
             presence: .init(people: ["ellen ronan"]),
             mustCite: "/isolated/1988/ellen_ronan_1988.mov"),
]

@Suite("Hallie event shape fallback")
struct HallieEventShapeFallbackTests {
    typealias Exec = HallieTurnExecutor

    private func run(_ ast: ArchivistQueryAST, question: String) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(originalQuestion: question, ast: ast)),
            context: .init(presenceRecords: fixtureRecords),
            dependencies: .production)
    }

    @Test func eventRoutesToTheEventExecutorAndIsDescribedAsSuch() {
        let ast = ArchivistQueryAST.event(.init(people: ["donna"]))
        #expect(Exec.route(ast) == .event)
        #expect(Exec.description(of: ast) == "shape=event")
        #expect(Exec.label(Exec.Route.event) == "event")
        #expect(Exec.needsPresenceRecords(ast))
        #expect(HallieShellCLI.route(ast) == .event)
    }

    /// Each of Rick's six: the event AST finds exactly what the hand-built
    /// presence AST finds, says so in the basis, and never says "not
    /// supported".
    @Test(arguments: hallieEventShapeRickSix)
    func anEventIsExecutedAsThePresenceSearchItIs(turn: HallieEventShapeLiveTurn) async throws {
        let event = try await run(.event(turn.event), question: turn.question)
        let presence = try await run(.presence(turn.presence), question: turn.question)

        #expect(presence.outcome == .answered, Comment(rawValue: presence.prose))
        #expect(presence.citations.map(\.fullPath).contains(turn.mustCite),
                Comment(rawValue: "\(presence.citations.map(\.fullPath))"))

        #expect(event.route == .event)
        #expect(event.outcome == .answered, Comment(rawValue: event.prose))
        #expect(event.citations == presence.citations)
        #expect(event.matchCount == presence.matchCount)
        #expect(event.prose == presence.prose)
        #expect(event.offeredActions == presence.offeredActions)
        #expect(event.retryOffer == presence.retryOffer)
        #expect(event.queryDescription == presence.queryDescription)
        #expect(!event.prose.localizedCaseInsensitiveContains("not supported"))
        #expect(!event.basisLine.localizedCaseInsensitiveContains("no deterministic executor"))

        // The basis is the presence basis with the event note in front.
        let note = Exec.eventBasisNote(turn.event)
        #expect(note.hasPrefix("read as an event question; searched the catalog for "), Comment(rawValue: note))
        #expect(event.basisLine == "Basis: " + note + "; " + presence.basisLine.dropFirst("Basis: ".count),
                Comment(rawValue: event.basisLine))
    }

    @Test func theEventNoteNamesPeopleWordsAndYears() {
        #expect(Exec.eventBasisNote(.init(people: ["donna"], yearStart: 1990, yearEnd: 1999, keywords: ["cape"]))
                == "read as an event question; searched the catalog for donna with “cape” in 1990–1999")
        #expect(Exec.eventBasisNote(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, transcript: ["cape"]))
                == "read as an event question; searched the catalog for donna with “cape” in 1990–1993")
        #expect(Exec.eventBasisNote(.init(people: ["ellen ronan"]))
                == "read as an event question; searched the catalog for ellen ronan")
        #expect(Exec.eventBasisNote(.init(keywords: ["christmas"], transcript: ["surprise"]))
                == "read as an event question; searched the catalog for “christmas”, “surprise”")
        #expect(Exec.eventBasisNote(.init(people: ["rick", "donna"], yearStart: 2006, yearEnd: 2006))
                == "read as an event question; searched the catalog for rick and donna in 2006")
        #expect(Exec.eventBasisNote(.init(yearStart: 1980)) == "read as an event question; searched the catalog for from 1980")
    }

    /// Spoken terms are keyword constraints, exactly as cross treats them:
    /// proven by the transcript, and the basis names it.
    @Test func spokenTermsOfAnEventAreSearchedAsWords() async throws {
        let event = try await run(.event(.init(people: ["donna"], transcript: ["surprise"])),
                                  question: "what happened when donna said surprise")
        let cross = try await run(.cross(.init(people: ["donna"], transcript: ["surprise"])),
                                  question: "what happened when donna said surprise")
        #expect(event.outcome == .answered, Comment(rawValue: event.prose))
        #expect(event.citations.map(\.fullPath) == ["/isolated/1992/donna_kitchen_1992.mov"])
        #expect(event.citations == cross.citations)
        let bases = try #require(event.citations.first?.bases)
        #expect(bases.contains { if case .transcriptMention = $0 { return true } else { return false } })
    }

    /// Blank strings are not search terms; a media kind alone is not a
    /// search.
    @Test func thePresenceQueryDropsBlanksAndEmptyLists() {
        let presence = Exec.presenceQuery(forEvent: .init(
            people: [" donna ", ""], yearStart: 1990, keywords: ["", " cape"], transcript: [" "]))
        #expect(presence == .init(people: ["donna"], yearStart: 1990, keywords: ["cape"]))
        #expect(Exec.presenceQuery(forEvent: .init(mediaKind: .video, keywords: [], transcript: [""]))
                == .init(mediaKind: .video))
        #expect(!Exec.eventIsActionable(.init()))
        #expect(!Exec.eventIsActionable(.init(mediaKind: .video)))
        #expect(!Exec.eventIsActionable(.init(people: [""], keywords: [" "])))
        #expect(Exec.eventIsActionable(.init(yearEnd: 1999)))
        #expect(Exec.eventIsActionable(.init(transcript: ["surprise"])))
    }

    /// An event with nothing to look for asks for the specifics — never
    /// "not supported", never a search of the whole catalog.
    @Test func anEmptyEventAsksForTheSpecifics() async throws {
        for payload in [ArchivistQueryAST.Event(), .init(mediaKind: .video), .init(people: [], keywords: [""])] {
            let result = try await run(.event(payload), question: "show me")
            #expect(result.route == .event)
            #expect(result.outcome == .declined)
            #expect(result.citations.isEmpty)
            #expect(result.matchCount == nil)
            #expect(result.prose.hasSuffix("Who or what should I look for, and roughly when?"),
                    Comment(rawValue: result.prose))
            #expect(!result.prose.localizedCaseInsensitiveContains("not supported"))
            #expect(result.basisLine == "Basis: the translator returned an event with no people, words or years; no catalog query was performed.")
        }
    }

    /// The route is a catalog route everywhere the others are: the answer
    /// plan lists it, memory moves to catalog mode and keeps the result
    /// set for "and the newest?", provenance cites the catalog.
    @Test func theEventRouteIsACatalogRouteForMemoryPlanAndProvenance() async throws {
        let turn = hallieEventShapeRickSix[0]
        let result = try await run(.event(turn.event), question: turn.question)
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.route == .event)

        var memory = Exec.ConversationMemory()
        let intent = Exec.Intent(originalQuestion: turn.question, ast: .event(turn.event))
        memory.record(intent: intent, result: result)
        #expect(memory.mode == .catalog)
        #expect(memory.lastResultSet?.ast == .event(turn.event))
        #expect(memory.catalog.lastQuery == .event(turn.event))
        #expect(memory.lastProvenance != nil)
        #expect(ArchivistFollowUpResolver.isPageable(.event(turn.event)))
    }
}

@MainActor
@Suite("Hallie event shape: tree-mode gate switches to the catalog", .serialized)
struct HallieEventShapeModeGateTests {
    typealias Exec = HallieTurnExecutor

    private final class Recorder: @unchecked Sendable {
        var asts: [ArchivistQueryAST] = []
        var modes: [HallieMode] = []
    }

    private func dependencies(
        translatorReturns ast: ArchivistQueryAST, recorder: Recorder
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in .init(ast: ast, responderHost: "fixture-host") },
            loadProfiles: { [] },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            loadSpeakers: { .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil) },
            executeRequest: { request, context in
                recorder.asts.append(request.intent.ast)
                recorder.modes.append(context.mode)
                return try await Exec.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await Exec.continue(pending: clarification, selecting: selectedID, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    /// A session in tree mode: a biography was the last answer AND the
    /// user pinned the tree (pill / ":mode"), so the classifier's verdict
    /// for the next sentence is tree whatever its words — the arrival the
    /// gate must handle. (Without the pin, "show me videos of …" is an
    /// explicit catalog cue and never reaches tree mode at all.)
    private func treeMemory() -> Exec.ConversationMemory {
        var memory = Exec.ConversationMemory()
        memory.record(
            intent: .init(originalQuestion: "tell me about donna",
                          ast: .graph(.init(people: ["donna"], operation: .biography))),
            result: .init(route: .graph, outcome: .answered, prose: "Donna.", basisLine: "Basis: fixture.",
                          queryDescription: "shape=graph", citations: [], catalogPersonName: nil))
        memory.force(.tree)
        #expect(memory.mode == .tree)
        #expect(memory.effectiveMode == .tree)
        return memory
    }

    private func withLogCapture<T>(_ body: (InMemoryLogSink) async throws -> T) async rethrows -> T {
        let sink = InMemoryLogSink(name: "hallie-event-gate")
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        return try await body(sink)
    }

    /// Rick's turn as it happened: tree mode, translator says event. It
    /// runs — in the catalog — and the session follows it there.
    @Test func treeModePlusShowMeVideosOfDonnaDownTheCapeRunsInTheCatalog() async throws {
        let event = ArchivistQueryAST.event(.init(people: ["donna"], mediaKind: .video, keywords: ["cape"]))
        let recorder = Recorder()
        var memory = treeMemory()
        let (response, lines) = try await withLogCapture { sink in
            let response = try await HallieAppTurnCoordinator.execute(
                question: "show me videos of donna down the cape",
                records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                memory: memory,
                dependencies: dependencies(translatorReturns: event, recorder: recorder))
            return (response, sink.lines)
        }
        #expect(recorder.asts == [event], Comment(rawValue: "\(recorder.asts)"))
        #expect(recorder.modes == [.catalog], Comment(rawValue: "\(recorder.modes)"))
        #expect(response.result.route == .event, Comment(rawValue: response.result.prose))
        // No records in this fixture: an honest evidence decline, executed.
        #expect(response.result.outcome == .declined, Comment(rawValue: response.result.prose))
        #expect(!response.result.prose.localizedCaseInsensitiveContains("not supported"))
        #expect(response.result.queryDescription != nil)
        #expect(response.result.basisLine.contains("read “show me videos of donna down the cape” as a catalog search (“videos”)"),
                Comment(rawValue: response.result.basisLine))
        #expect(response.result.basisLine.contains("read as an event question; searched the catalog for donna with “cape”"),
                Comment(rawValue: response.result.basisLine))
        #expect(lines.contains("[hallie-mode] switched tree→catalog for shape=event"), Comment(rawValue: lines.joined(separator: "\n")))
        #expect(!lines.contains { $0.contains("[hallie-mode] declined") })
        memory.record(intent: response.executedIntent, result: response.result)
        #expect(memory.mode == .catalog)
    }

    /// No media noun at all — the retrieval verb carries it, for a presence
    /// AST this time, and the log names the shape.
    @Test func treeModePlusShowMeDonnaDownTheCapeInTheEarly90sSwitchesForAPresenceShape() async throws {
        let presence = ArchivistQueryAST.presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]))
        let recorder = Recorder()
        let (response, lines) = try await withLogCapture { sink in
            let response = try await HallieAppTurnCoordinator.execute(
                question: "show me Donna down the cape in the early 90s",
                records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                memory: treeMemory(),
                dependencies: dependencies(translatorReturns: presence, recorder: recorder))
            return (response, sink.lines)
        }
        #expect(recorder.asts == [presence], Comment(rawValue: "\(recorder.asts)"))
        #expect(recorder.modes == [.catalog])
        #expect(response.result.route == .presence)
        #expect(lines.contains("[hallie-mode] switched tree→catalog for shape=presence"), Comment(rawValue: lines.joined(separator: "\n")))
    }

    /// The road that must stay: "show me ellen ronan in the family tree"
    /// names the tree, so nothing about it is a catalog search — whichever
    /// step claims it (a local tree route before translation, or the gate's
    /// biography rewrite after; HallieModeGateTests pins the gate half).
    @Test func treeModeStillReadsShowMeXInTheFamilyTreeAsATreeQuestion() async throws {
        let recorder = Recorder()
        let (response, lines) = try await withLogCapture { sink in
            let response = try await HallieAppTurnCoordinator.execute(
                question: "show me ellen ronan in the family tree",
                records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                memory: treeMemory(),
                dependencies: dependencies(
                    translatorReturns: .presence(.init(people: ["ellen ronan"], keywords: ["family", "tree"])),
                    recorder: recorder))
            return (response, sink.lines)
        }
        let catalogShapes = recorder.asts.filter { Exec.needsPresenceRecords($0) }
        #expect(catalogShapes.isEmpty, Comment(rawValue: "\(recorder.asts)"))
        #expect(!recorder.modes.contains(.catalog), Comment(rawValue: "\(recorder.modes)"))
        #expect(![Exec.Route.presence, .cross, .event].contains(response.result.route),
                Comment(rawValue: "\(response.result.route): \(response.result.prose)"))
        #expect(!lines.contains { $0.contains("switched tree→catalog") }, Comment(rawValue: lines.joined(separator: "\n")))
    }
}
