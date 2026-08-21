import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// "Let me tell you about Dad Breen" through the real shell and the real
/// chat coordinator, with the CyberBrain write injected (Rick, 2026-08-21).
/// The promises: every statement is kept verbatim and attributed; nothing
/// is written without --remember in the shell; a question ends the telling
/// and is answered normally; what was just told is findable in the same
/// session.
@MainActor
@Suite("Hallie listens and remembers", .serialized)
struct HallieTellingIntegrationTests {

    private final class Recorder: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var testimonies: [CyberBrainWriter.Testimony] = []
        var translatedQuestions: [String] = []
        var events: [HallieTranscriptEvent] = []
        var contexts: [HallieTurnExecutor.Context] = []
        var translations: [ArchivistQueryAST]
        var writeRoot: URL?
        var cyberBrain: CyberBrainIndex?

        init(inputs: [String], translations: [ArchivistQueryAST] = []) {
            self.inputs = inputs
            self.translations = translations
        }

        func nextInput() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }

        func shellDependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: { .loaded([]) },
                loadGraph: { _ in nil },
                loadCyberBrain: { [self] in cyberBrain },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    guard !translations.isEmpty else {
                        throw HallieShellCLI.ParseError.emptyValue("no translation")
                    }
                    return .init(ast: translations.removeFirst(),
                                 responderHost: "fixture-translator")
                },
                executeTurn: { _, _ in
                    HallieTurnExecutor.Result(
                        route: .presence, outcome: .declined,
                        prose: "fixture decline", basisLine: "fixture",
                        queryDescription: nil, citations: [], catalogPersonName: nil)
                },
                executeRequest: { [self] _, context in
                    contexts.append(context)
                    return HallieTurnExecutor.Result(
                        route: .presence, outcome: .declined,
                        prose: "fixture decline", basisLine: "fixture",
                        queryDescription: nil, citations: [], catalogPersonName: nil)
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] in events.append(contentsOf: $0) },
                recordTestimony: { [self] testimony in
                    testimonies.append(testimony)
                    guard let writeRoot else { return nil }
                    let receipt = try CyberBrainWriter.record(testimony, rootURL: writeRoot)
                    return try CyberBrainIndex(archive: receipt.archive)
                },
                speakers: { .init(ownerName: "Rick", archivistName: "Hallie") })
        }
    }

    private func runShell(_ recorder: Recorder, remember: Bool) async -> Int32 {
        var arguments = ["--hallie", "--catalog", "/isolated/catalog.json"]
        if remember { arguments.append("--remember") }
        let options = try! HallieShellCLI.parse(arguments: arguments)
        return await HallieShellCLI.run(
            options: options, input: recorder.nextInput,
            output: { recorder.output.append($0) },
            dependencies: recorder.shellDependencies())
    }

    // MARK: - Shell

    @Test func shellKeepsEveryStatementVerbatimAttributedToTheSpeaker() async throws {
        let recorder = Recorder(inputs: [
            "Let me tell you about Dad Breen, Rick's dad",
            "He repaired typewriters for a living.",
            "He was a Marine in the Second World War.",
            "that's all",
            ":quit",
        ])
        _ = await runShell(recorder, remember: true)

        #expect(recorder.translatedQuestions.isEmpty, "listening never calls the model")
        let biography = recorder.testimonies.filter { $0.kind == .biography }
        #expect(biography.map(\.text) == [
            "He repaired typewriters for a living.",
            "He was a Marine in the Second World War.",
        ])
        #expect(biography.allSatisfy { $0.subjectName == "Dad Breen" && $0.speakerName == "Rick" })
        let notes = recorder.testimonies.filter { $0.kind == .note }
        #expect(notes.map(\.text) == ["Dad Breen is Rick's dad."], "the relation is a note, never an alias")
        #expect(recorder.output.contains("Oh, tell me all about Dad Breen — I'll remember it. Where and when was he born?"))
        #expect(recorder.output.contains {
            $0 == "Thank you. I've kept 2 things you told me about Dad Breen — marked as told by Rick today, to be verified. Ask me about him any time."
        }, "\(recorder.output)")
        let assistant = recorder.events.filter { $0.kind == .assistant }
        #expect(assistant.count == 4)
        #expect(assistant.allSatisfy { $0.route == "telling" && $0.outcome == "answered" })
    }

    @Test func shellWithoutRememberWritesNothingAndSaysSo() async throws {
        let recorder = Recorder(inputs: [
            "let me tell you about Dad Breen",
            "He repaired typewriters for a living.",
            "I'm done",
            ":quit",
        ])
        _ = await runShell(recorder, remember: false)

        #expect(recorder.testimonies.isEmpty, "the read-only shell must not write Rick's CyberBrain")
        #expect(recorder.output.contains { $0.contains("for this session only") && $0.contains("read-only") })
    }

    @Test func aQuestionMidTellingEndsItAndIsAnsweredNormally() async throws {
        let recorder = Recorder(
            inputs: [
                "let me tell you about Dad Breen",
                "He repaired typewriters for a living.",
                "show me Donna",
                "He also loved fishing.",
                ":quit",
            ],
            translations: [.presence(.init(people: ["Donna"])), .presence(.init(people: ["Donna"]))])
        _ = await runShell(recorder, remember: true)

        #expect(recorder.translatedQuestions.first == "show me Donna")
        // After the question the telling is over: later text is an ordinary
        // turn (here the follow-up resolver reads "also" as a refinement of
        // the Donna search), never testimony.
        #expect(recorder.testimonies.map(\.text) == ["He repaired typewriters for a living."])
        #expect(recorder.output.contains("I'll keep what you told me about Dad Breen."))
    }

    @Test func whatWasJustToldIsFindableInTheSameShellSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder(
            inputs: [
                "let me tell you about Dad Breen, Rick's dad",
                "He repaired typewriters for a living.",
                "that's all",
                "show me Donna",
                ":quit",
            ],
            translations: [.presence(.init(people: ["Donna"]))])
        recorder.writeRoot = root
        _ = await runShell(recorder, remember: true)

        let context = try #require(recorder.contexts.last)
        guard case .resolved(let person) = context.cyberBrain?.resolve("Dad Breen") ?? .notFound else {
            Issue.record("the session's CyberBrain must be refreshed after a write"); return
        }
        let evidence = context.cyberBrain!.evidence(for: person.id, privacyCeiling: .family)
        #expect(evidence.map(\.text) == ["He repaired typewriters for a living.", "Dad Breen is Rick's dad."])
        #expect(evidence.allSatisfy { $0.confidence == .probable })
        // And it is really on disk, readable by the strict loader.
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(reloaded.people.map(\.canonicalName) == ["Dad Breen"])
        #expect(reloaded.sources.first?.attribution == "Rick")
    }

    @Test func sheAsksForTheNameWhenOnlyARelationWasGiven() async throws {
        let recorder = Recorder(inputs: [
            "let me tell you about my dad",
            "He repaired typewriters for a living.",
            "Richard Breen",
            "He was a Marine.",
            "that's all",
            ":quit",
        ])
        _ = await runShell(recorder, remember: true)

        #expect(recorder.output.contains("Oh, please do — I'd love to hear about my dad. What was his name?"))
        #expect(recorder.output.contains("I'll keep that. Before I write it down properly — what was his name?"))
        let biography = recorder.testimonies.filter { $0.kind == .biography }
        #expect(biography.map(\.text) == ["He repaired typewriters for a living.", "He was a Marine."])
        #expect(biography.allSatisfy { $0.subjectName == "Richard Breen" })
        #expect(recorder.testimonies.filter { $0.kind == .note }.map(\.text) == ["Richard Breen is my dad."])
    }

    // MARK: - Chat coordinator

    private func coordinatorDependencies(_ recorder: Recorder) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { [recorder] question, _, _ in
                recorder.translatedQuestions.append(question)
                return .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture")
            },
            loadProfiles: { nil },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            recordTestimony: { [recorder] in recorder.testimonies.append($0) },
            loadSpeakers: { .init(ownerName: "Rick", archivistName: "Hallie") },
            executeRequest: { _, _ in
                HallieTurnExecutor.Result(
                    route: .presence, outcome: .declined,
                    prose: "fixture decline", basisLine: "fixture",
                    queryDescription: nil, citations: [], catalogPersonName: nil)
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    @Test func coordinatorCarriesTheTellingAcrossTurnsAndAlwaysWrites() async throws {
        let recorder = Recorder(inputs: [])
        let deps = coordinatorDependencies(recorder)
        let referent = HallieAppTurnCoordinator.CapturedReferent(recordID: nil, temporalDate: nil)
        func turn(_ text: String, telling: HallieTellingMode.Session?) async throws -> HallieAppTurnCoordinator.Response {
            try await HallieAppTurnCoordinator.execute(
                question: text, records: [], referent: referent,
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                telling: telling, dependencies: deps)
        }

        let opened = try await turn("Let me tell you about Dad Breen, Rick's dad", telling: nil)
        #expect(opened.result.route == .telling)
        #expect(opened.result.prose == "Oh, tell me all about Dad Breen — I'll remember it. Where and when was he born?")
        #expect(opened.telling != nil)

        let kept = try await turn("He repaired typewriters for a living.", telling: opened.telling)
        #expect(kept.result.prose == "I've written that down. Who were his parents — and did he have brothers or sisters?")
        #expect(recorder.testimonies.map(\.text) == ["Dad Breen is Rick's dad.", "He repaired typewriters for a living."])

        let closed = try await turn("that's all", telling: kept.telling)
        #expect(closed.telling == nil)
        #expect(closed.result.prose == "Thank you. I've kept one thing you told me about Dad Breen — marked as told by Rick today, to be verified. Ask me about him any time.")
        #expect(recorder.translatedQuestions.isEmpty)

        let question = try await turn("show me Donna", telling: opened.telling)
        #expect(question.result.route == .presence, "a question mid-telling is answered, not kept")
        #expect(question.telling == nil)
        #expect(recorder.translatedQuestions == ["show me Donna"])
    }
}
