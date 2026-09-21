// HallieSocialShapeGuardTests.swift
// codex's replay of 2026-09-21 (binary 9818ff51) against the 2026-09-18
// baseline (93b97f2f): nine social / identity turns ran a catalog search —
// "nice to meet you" → 51 videos where someone says it, "ok" → 960, "Do
// you ever get tired?" → "10489 matching catalog items", "that was
// terrible lol" → Christmas 1990 (route=event) — and six whole-family
// tree questions were refused with "I couldn't tell who it is about".
// All fifteen answered at the baseline.
//
// Pinned here, without a model (the ASTs are the ones the translator
// returned in the replay, built by hand):
//   1. the guard itself — the nine sentences are conversation, and a
//      table of searches that must stay searches;
//   2. the app coordinator, in unknown, catalog and tree mode: a social
//      turn never executes an AST, whatever mode the session was in;
//   3. the shell, the client the replay uses;
//   4. THE SENSOR: all fifteen regression sentences plus "show me Donna
//      down the cape in the early 90s" (which must still search), each
//      with the mode the replay recorded and the AST the translator gave.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The replay rows

/// One graded row of the 2026-09-21 replay: the words, the session mode the
/// transcript recorded, what the translator returned, and what must happen.
struct HallieSocialReplayRow: Sendable, CustomStringConvertible {
    enum Expectation: Equatable, Sendable {
        /// Answered in the social lane; no AST executed.
        case social
        /// Rewritten to the whole-family tree road, with this surname.
        case familyWide(surname: String?)
        /// A real catalog search, executed as translated.
        case search
    }
    let id: String
    let question: String
    let mode: HallieMode
    let ast: ArchivistQueryAST
    let expect: Expectation
    var description: String { "\(id) “\(question)”" }
}

let hallieSocialClusterA: [HallieSocialReplayRow] = [
    .init(id: "sm010", question: "You're helpful, you know that?", mode: .catalog,
          ast: .presence(.init(keywords: ["helpful"])), expect: .social),
    .init(id: "sm012", question: "nice to meet you", mode: .catalog,
          ast: .presence(.init(keywords: ["nice to meet you"])), expect: .social),
    .init(id: "sm025", question: "Do you ever get tired?", mode: .catalog,
          ast: .presence(.init(mediaKind: .video)), expect: .social),
    .init(id: "sm028", question: "that was terrible lol", mode: .catalog,
          ast: .event(.init(keywords: ["that was terrible"])), expect: .social),
    .init(id: "ic004", question: "Are you a real person or a program?", mode: .catalog,
          ast: .presence(.init(keywords: ["real person", "program"])), expect: .social),
    .init(id: "ic011", question: "what should I call you", mode: .catalog,
          ast: .presence(.init(keywords: ["call"])), expect: .social),
    .init(id: "ic013", question: "Do you remember what we talked about yesterday?", mode: .catalog,
          ast: .event(.init(transcript: ["yesterday"])), expect: .social),
    .init(id: "ic014", question: "what can't you do", mode: .catalog,
          ast: .presence(.init(keywords: ["what", "can't", "do"])), expect: .social),
    .init(id: "ec010", question: "ok", mode: .catalog,
          ast: .presence(.init(keywords: ["ok"])), expect: .social),
]

let hallieSocialClusterB: [HallieSocialReplayRow] = [
    .init(id: "ft012", question: "how many grandchildren are there", mode: .tree,
          ast: .presence(.init(keywords: ["grandchildren"])), expect: .familyWide(surname: nil)),
    .init(id: "ft015", question: "list everyone in the family", mode: .tree,
          ast: .presence(.init(keywords: ["everyone", "family"])), expect: .familyWide(surname: nil)),
    .init(id: "bi006", question: "what do you know about the Breen family", mode: .tree,
          ast: .presence(.init(keywords: ["breen family"])), expect: .familyWide(surname: "breen")),
    .init(id: "bi014", question: "tell me what it was like growing up in this family", mode: .tree,
          ast: .presence(.init(keywords: ["growing up", "family"])), expect: .familyWide(surname: nil)),
    .init(id: "bi016", question: "what would you say our family is known for", mode: .tree,
          ast: .presence(.init(keywords: ["known for"])), expect: .familyWide(surname: nil)),
    .init(id: "lv260901-018", question: "when did the latta family come to america?", mode: .tree,
          ast: .event(.init(keywords: ["latta family", "america"])), expect: .familyWide(surname: "latta")),
]

/// The 2026-09-20 fix must keep working: Rick's cape sentence searches.
let hallieSocialStillSearches: [HallieSocialReplayRow] = [
    .init(id: "rick-cape", question: "show me Donna down the cape in the early 90s", mode: .tree,
          ast: .presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"])),
          expect: .search),
    .init(id: "rick-cape-catalog", question: "show me Donna down the cape in the early 90s", mode: .catalog,
          ast: .presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"])),
          expect: .search),
]

private let nobody: (String) -> Bool = { _ in false }

// MARK: - 1. The guard

@Suite("Hallie social shape guard")
struct HallieSocialShapeGuardTests {
    typealias Guard = HallieSocialShapeGuard

    @Test(arguments: hallieSocialClusterA)
    func aSocialSentenceWithAnUnanchoredCatalogShapeIsConversation(row: HallieSocialReplayRow) {
        let verdict = Guard.verdict(
            question: row.question, ast: row.ast, isKnownPerson: nobody, isInnerCircleName: nobody)
        #expect(verdict?.kind == .casual, Comment(rawValue: "\(row): \(String(describing: verdict))"))
    }

    /// Searches that must stay searches: a named person, a year, a place,
    /// a media word, a retrieval opener, a family word, a typed name, a
    /// persona fact, and a sentence with a content word and no "you".
    @Test(arguments: [
        ("show me Donna down the cape in the early 90s",
         ArchivistQueryAST.presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]))),
        ("what happened when someone said surprise?", .event(.init(transcript: ["surprise"]))),
        ("the cape", .presence(.init(keywords: ["cape"]))),
        ("did you find any videos of my friend", .presence(.init(keywords: ["friend"]))),
        ("when were you born", .presence(.init(keywords: ["born"]))),
        ("do you have anything from 1994", .presence(.init(yearStart: 1994, yearEnd: 1994))),
        ("what do you know about the Breen family", .presence(.init(keywords: ["breen family"]))),
        ("what do you know about the Breens", .presence(.init(keywords: ["breens"]))),
        ("the christmas tape", .presence(.init(keywords: ["christmas"]))),
        ("how many grandchildren are there", .presence(.init(keywords: ["grandchildren"]))),
        ("do you have anything at the cape", .presence(.init(place: "cape"))),
        ("can you find the birthday party", .presence(.init(keywords: ["birthday party"]))),
        ("who is in this video", .presence(.init(keywords: ["video"]))),
    ] as [(String, ArchivistQueryAST)])
    func aSearchStaysASearch(question: String, ast: ArchivistQueryAST) {
        #expect(Guard.verdict(question: question, ast: ast, isKnownPerson: nobody, isInnerCircleName: nobody) == nil,
                Comment(rawValue: question))
    }

    /// A lone inner-circle name typed in lowercase is a family question.
    @Test func aLoneInnerCircleNameIsNeverSocial() {
        let donna: (String) -> Bool = { $0.lowercased() == "donna" }
        #expect(Guard.verdict(question: "do you like donna", ast: .presence(.init(keywords: ["donna"])),
                              isKnownPerson: donna, isInnerCircleName: donna) == nil)
        #expect(Guard.verdict(question: "do you like donna", ast: .presence(.init(keywords: ["donna"])),
                              isKnownPerson: nobody, isInnerCircleName: nobody)?.kind == .casual)
    }

    /// Only a catalog shape that names nobody and no time qualifies.
    @Test func onlyUnanchoredCatalogShapesQualify() {
        #expect(Guard.isUnanchoredCatalogShape(.presence(.init(keywords: ["ok"]))))
        #expect(Guard.isUnanchoredCatalogShape(.event(.init(transcript: ["yesterday"]))))
        #expect(Guard.isUnanchoredCatalogShape(.cross(.init(keywords: ["lol"]))))
        #expect(!Guard.isUnanchoredCatalogShape(.presence(.init(people: ["donna"]))))
        #expect(!Guard.isUnanchoredCatalogShape(.presence(.init(people: [" "], yearStart: 1990))))
        #expect(!Guard.isUnanchoredCatalogShape(.presence(.init(place: "Cape Cod"))))
        #expect(!Guard.isUnanchoredCatalogShape(.event(.init(yearEnd: 1999))))
        #expect(!Guard.isUnanchoredCatalogShape(.graph(.init(people: ["donna"], operation: .biography))))
        #expect(!Guard.isUnanchoredCatalogShape(.aggregate(.init(operation: .coOccurrence, anchorPeople: ["donna"]))))
        #expect(!Guard.isUnanchoredCatalogShape(.temporal(.init(subject: "donna", operation: .age, reference: .currentSelection))))
    }

    @Test func theLogLineNamesTheShapeAndTheReason() {
        let verdict = Guard.verdict(question: "ok", ast: .presence(.init(keywords: ["ok"])),
                                    isKnownPerson: nobody, isInnerCircleName: nobody)
        let line = verdict?.logLine(question: "ok", ast: .presence(.init(keywords: ["ok"]))) ?? ""
        #expect(line.hasPrefix("[hallie-social] kept shape=presence out of the catalog: a reaction (“ok”)"),
                Comment(rawValue: line))
    }
}

// MARK: - 2. The app coordinator, and 4. the sensor

/// Routes that mean "answered without touching the archive". `.followUp`
/// is here for one row: a bare "ok" right after a catalog answer is
/// claimed, before any model, by the follow-up resolver ("I couldn't tell
/// how “ok” narrows down my last answer") — model-free and not a search,
/// and a lane that predates this fix.
private let conversationalRoutes: Set<HallieTurnExecutor.Route> = [
    .conversation, .smalltalk, .capability, .help, .followUp,
]

@Suite("Hallie social shape: the coordinator keeps social turns out of the catalog", .serialized)
struct HallieSocialShapeCoordinatorTests {
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

    /// A session in the given mode, pinned the way the replay's transcript
    /// recorded it: a biography for tree, a presence answer for catalog,
    /// nothing for unknown.
    private func memory(in mode: HallieMode) -> Exec.ConversationMemory {
        var memory = Exec.ConversationMemory()
        switch mode {
        case .tree:
            memory.record(
                intent: .init(originalQuestion: "tell me about donna",
                              ast: .graph(.init(people: ["donna"], operation: .biography))),
                result: .init(route: .graph, outcome: .answered, prose: "Donna.", basisLine: "Basis: fixture.",
                              queryDescription: "shape=graph", citations: [], catalogPersonName: nil))
            memory.force(.tree)
        case .catalog:
            memory.record(
                intent: .init(originalQuestion: "videos of donna",
                              ast: .presence(.init(people: ["donna"], mediaKind: .video))),
                result: .init(route: .presence, outcome: .answered, prose: "3 videos.", basisLine: "Basis: fixture.",
                              queryDescription: "shape=presence", citations: [], catalogPersonName: nil))
            memory.force(.catalog)
        case .unknown:
            break
        }
        #expect(memory.effectiveMode == mode)
        return memory
    }

    private func withLogCapture<T>(_ body: (InMemoryLogSink) async throws -> T) async rethrows -> T {
        let sink = InMemoryLogSink(name: "hallie-social-shape")
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        return try await body(sink)
    }

    private func run(_ row: HallieSocialReplayRow) async throws
        -> (response: HallieAppTurnCoordinator.Response, recorder: Recorder, lines: [String]) {
        let recorder = Recorder()
        let (response, lines) = try await withLogCapture { sink in
            let response = try await HallieAppTurnCoordinator.execute(
                question: row.question,
                records: [],
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                memory: memory(in: row.mode),
                dependencies: dependencies(translatorReturns: row.ast, recorder: recorder))
            return (response, sink.lines)
        }
        return (response, recorder, lines)
    }

    /// "nice to meet you" in every mode: conversation, no AST executed, the
    /// `[hallie-social]` line written — and the session's mode is left
    /// where it was.
    @Test(arguments: [HallieMode.unknown, .catalog, .tree])
    func niceToMeetYouIsConversationInEveryMode(mode: HallieMode) async throws {
        let row = HallieSocialReplayRow(
            id: "sm012", question: "nice to meet you", mode: mode,
            ast: .presence(.init(keywords: ["nice to meet you"])), expect: .social)
        let (response, recorder, lines) = try await run(row)
        #expect(recorder.asts.isEmpty, Comment(rawValue: "\(recorder.asts)"))
        #expect(response.result.route == .conversation, Comment(rawValue: response.result.prose))
        #expect(response.result.queryDescription == "conversation")
        #expect(!response.result.prose.localizedCaseInsensitiveContains("matching catalog items"))
        #expect(!response.result.prose.localizedCaseInsensitiveContains("something to look for"))
        #expect(lines.contains {
            $0.hasPrefix("[hallie-social] kept shape=presence out of the catalog: addressed to Hallie (“you”)")
        }, Comment(rawValue: lines.joined(separator: "\n")))
        var memory = memory(in: mode)
        memory.record(intent: response.executedIntent, result: response.result)
        #expect(memory.effectiveMode == mode)
    }

    /// The event shape too: "that was terrible lol" as an event AST is not
    /// a transcript search for Christmas tapes.
    @Test func aReactionReadAsAnEventIsConversation() async throws {
        let (response, recorder, lines) = try await run(hallieSocialClusterA[3])
        #expect(recorder.asts.isEmpty)
        #expect(response.result.route == .conversation, Comment(rawValue: response.result.prose))
        #expect(!response.result.basisLine.contains("read as an event question"))
        #expect(lines.contains { $0.hasPrefix("[hallie-social] kept shape=event out of the catalog: a reaction (“terrible”)") },
                Comment(rawValue: lines.joined(separator: "\n")))
    }

    /// THE SENSOR: every replay row, with the mode and AST the replay
    /// recorded. Cluster A answers socially with no AST executed; cluster B
    /// runs the whole-family tree road and never the who-is-it-about
    /// decline; the cape sentence still searches, as translated.
    @Test(arguments: hallieSocialClusterA + hallieSocialClusterB + hallieSocialStillSearches)
    func theReplayRowsAnswerAsTheyDidAtTheBaseline(row: HallieSocialReplayRow) async throws {
        let (response, recorder, lines) = try await run(row)
        let prose = response.result.prose
        switch row.expect {
        case .social:
            #expect(recorder.asts.isEmpty, Comment(rawValue: "\(row): executed \(recorder.asts)"))
            #expect(conversationalRoutes.contains(response.result.route),
                    Comment(rawValue: "\(row): route=\(response.result.route) prose=\(prose)"))
            #expect(!prose.localizedCaseInsensitiveContains("matching catalog items"), Comment(rawValue: "\(row): \(prose)"))
            #expect(!prose.localizedCaseInsensitiveContains("something to look for"), Comment(rawValue: "\(row): \(prose)"))
            #expect(!prose.localizedCaseInsensitiveContains("where someone says"), Comment(rawValue: "\(row): \(prose)"))
        case .familyWide(let surname):
            let expected = ArchivistQueryAST.graph(.init(people: [], operation: .familyTree, surname: surname))
            #expect(!prose.contains("couldn't tell who it is about"), Comment(rawValue: "\(row): \(prose)"))
            #expect(!lines.contains { $0.contains("[hallie-mode] declined") }, Comment(rawValue: "\(row): \(lines)"))
            #expect(recorder.asts == [expected], Comment(rawValue: "\(row): executed \(recorder.asts)"))
            #expect(recorder.modes == [.tree], Comment(rawValue: "\(row): \(recorder.modes)"))
            #expect(response.result.route == .graph, Comment(rawValue: "\(row): route=\(response.result.route)"))
            #expect(lines.contains { $0.hasPrefix("[hallie-mode] rewrite: read “\(row.question)” as a question about the whole family") },
                    Comment(rawValue: "\(row): \(lines.joined(separator: "\n"))"))
        case .search:
            #expect(recorder.asts == [row.ast], Comment(rawValue: "\(row): executed \(recorder.asts)"))
            #expect(recorder.modes == [.catalog], Comment(rawValue: "\(row): \(recorder.modes)"))
            #expect(response.result.route == .presence, Comment(rawValue: "\(row): route=\(response.result.route)"))
            #expect(!lines.contains { $0.hasPrefix("[hallie-social]") }, Comment(rawValue: "\(row): \(lines)"))
        }
    }
}

// MARK: - 3. The shell (the replay's client)

@Suite("Hallie social shape: the shell keeps social turns out of the catalog")
struct HallieSocialShapeShellTests {
    @Test(arguments: [
        ("nice to meet you", ArchivistQueryAST.presence(.init(keywords: ["nice to meet you"]))),
        ("ok", .presence(.init(keywords: ["ok"]))),
        ("that was terrible lol", .event(.init(keywords: ["that was terrible"]))),
        ("Do you ever get tired?", .presence(.init(mediaKind: .video))),
    ] as [(String, ArchivistQueryAST)])
    func aSocialSentenceIsAnsweredAsConversation(question: String, ast: ArchivistQueryAST) async throws {
        let harness = HallieShellCLITests.Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", question, "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let output = harness.output.joined(separator: "\n")
        #expect(harness.output.contains { $0.hasPrefix("social guard: ") }, Comment(rawValue: output))
        #expect(harness.output.contains("interpreted: conversation"), Comment(rawValue: output))
        #expect(!output.contains("shape=presence"), Comment(rawValue: output))
        #expect(!output.contains("shape=event"), Comment(rawValue: output))
        #expect(!output.localizedCaseInsensitiveContains("matching catalog items"), Comment(rawValue: output))
        #expect(!output.localizedCaseInsensitiveContains("something to look for"), Comment(rawValue: output))
        #expect(harness.mediaActions.isEmpty)
        #expect(code == 0, Comment(rawValue: "exit \(code)\n\(output)"))
    }

    /// Rick's cape sentence through the shell is still a search.
    @Test func theCapeSentenceStillSearches() async throws {
        let ast = ArchivistQueryAST.presence(
            .init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"]))
        let harness = HallieShellCLITests.Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "show me Donna down the cape in the early 90s", "--diagnostics",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let output = harness.output.joined(separator: "\n")
        #expect(!harness.output.contains { $0.hasPrefix("social guard: ") }, Comment(rawValue: output))
        #expect(output.contains("shape=presence"), Comment(rawValue: output))
    }
}
