import AppKit
import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie standalone shell", .serialized)
struct HallieShellCLITests {
    private final class Harness {
        var inputs: [String]
        var output: [String] = []
        var loadedURLs: [URL] = []
        var translatedQuestions: [String] = []
        var translationOptions: [HallieShellCLI.Options] = []
        var mediaActions: [HallieShellCLI.MediaAction] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        var readCount = 0
        var records: [VideoRecord]
        var profiles: [POIProfile]
        var profileLoadResult: HallieShellCLI.ProfileLoadResult?
        var graph: GedcomFamilyGraph?
        var cyberBrain: CyberBrainIndex?
        var translations: [ArchivistQueryAST]
        var translationError: Error?
        var unavailableMediaPaths: Set<String> = []
        var mediaActionShouldSucceed = true
        var executeTurn: @Sendable (
            ArchivistQueryAST,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result = HallieTurnExecutor.execute
        var executeRequest: (@Sendable (
            HallieTurnExecutor.Request,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result)?
        var continueTurn: (@Sendable (
            HallieTurnExecutor.Clarification,
            HallieTurnExecutor.CandidateID,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result)?

        init(
            inputs: [String] = [], records: [VideoRecord] = [],
            profiles: [POIProfile] = [], graph: GedcomFamilyGraph? = nil,
            translations: [ArchivistQueryAST] = []
        ) {
            self.inputs = inputs
            self.records = records
            self.profiles = profiles
            self.graph = graph
            self.translations = translations
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { [self] url in
                    loadedURLs.append(url)
                    return records
                },
                loadProfiles: { [self] in
                    profileLoadResult ?? .loaded(profiles)
                },
                loadGraph: { [self] _ in graph },
                loadCyberBrain: { [self] in cyberBrain },
                translateAST: { [self] question, options in
                    translatedQuestions.append(question)
                    translationOptions.append(options)
                    if let translationError { throw translationError }
                    guard !translations.isEmpty else {
                        throw HarnessError.missingTranslation
                    }
                    return .init(ast: translations.removeFirst(),
                                 responderHost: "fixture-translator")
                },
                executeTurn: executeTurn,
                executeRequest: executeRequest,
                continueTurn: continueTurn,
                mediaURLIsAvailable: { [self] url in
                    !unavailableMediaPaths.contains(url.path)
                },
                tryPerformMediaAction: { [self] action in
                    mediaActions.append(action)
                    return mediaActionShouldSucceed
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                })
        }

        func nextInput() -> String? {
            readCount += 1
            return inputs.isEmpty ? nil : inputs.removeFirst()
        }
    }

    private enum HarnessError: LocalizedError {
        case missingTranslation
        case refusedByTranslator

        var errorDescription: String? {
            switch self {
            case .missingTranslation: "test did not supply a translation"
            case .refusedByTranslator: "translator refused unsupported evidence"
            }
        }
    }

    private enum ActiveResetMode: CaseIterable {
        case telling
        case drill
        case picker
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var blockingContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var hasStarted = false

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasStarted {
                    lock.unlock()
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func blockUntilCancelled() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    hasStarted = true
                    let waiters = startWaiters
                    startWaiters.removeAll()
                    if isCancelled {
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                        continuation.resume()
                    } else {
                        blockingContinuation = continuation
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                    }
                }
            } onCancel: {
                lock.lock()
                isCancelled = true
                let continuation = blockingContinuation
                blockingContinuation = nil
                lock.unlock()
                continuation?.resume()
            }
        }

        var observedCancellation: Bool {
            lock.withLock { isCancelled }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    private func record(
        _ path: String, confirmed: [String] = [],
        caption: (Double, String)? = nil
    ) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = confirmed.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 1))
        }
        if let caption {
            value.sceneCaptions = [
                SceneCaption(timestamp: caption.0, text: caption.1),
            ]
            value.sceneCaptionModel = "fixture-captioner"
        }
        return value
    }

    private func citedAnswer(path: String) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .presence,
            outcome: .answered,
            prose: "fixture answer",
            basisLine: "fixture basis",
            queryDescription: "shape=presence",
            citations: [
                .init(
                    recordID: UUID(), fullPath: path,
                    filename: (path as NSString).lastPathComponent,
                    playbackSeconds: nil, bases: []),
            ],
            catalogPersonName: nil)
    }

    private func conversationState(
        with mode: ActiveResetMode
    ) -> HallieShellCLI.Session {
        var state = HallieShellCLI.Session(
            records: [], profiles: [], graph: nil, cyberBrain: nil,
            model: "fixture-model", runID: "reset-run")
        state.transcriptSequence = 41
        let prior = citedAnswer(path: "/isolated/Donna/Cape.mov")
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "Was Donna there?",
            ast: .presence(.init(people: ["Donna"])))
        state.memory.record(
            intent: intent, result: prior, question: "Was Donna there?")
        state.citations = prior.citations
        state.selectedRecordID = prior.citations.first?.recordID
        state.remember(question: "Was Donna there?", answer: prior.prose)
        state.rememberSocial(question: "Hello", answer: "Hello, Rick.")
        let context = state.identityContext
        state.pendingClarification = .init(
            value: HallieTurnExecutor.makeClarification(
                intent: intent,
                stage: .profileIdentity,
                candidates: [
                    .init(
                        id: .profileStableID("donna"),
                        canonicalName: "Donna", label: "Donna"),
                ],
                context: context),
            context: context)
        switch mode {
        case .telling:
            state.telling = HallieTellingMode.Session(opening: .init(
                subject: "Dad Breen", relation: "Rick's dad", pronoun: .he,
                firstStatement: nil))
        case .drill:
            state.drill = HalliePronunciationDrillMode.Session(
                list: PronunciationDrillList(items: []), index: nil)
        case .picker:
            state.picker = HalliePronunciationPicker.Offer(
                word: "Latta", candidates: [])
        }
        return state
    }

    private func source(named filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var onePixelPNG: Data {
        // Real decoded 1x1 PNG, not merely a filename-shaped byte blob.
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    // MARK: - Option grammar

    @Test func parsesDefaultsAndEverySupportedOption() throws {
        let defaults = try HallieShellCLI.parse(arguments: ["--hallie"])
        #expect(defaults.once == nil)
        #expect(!defaults.hosts.isEmpty)

        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/tmp/hallie-catalog.json",
            "--host", "ollama-one.local,ollama-two.local",
            "--model", "fixture-model", "--gedcom", "/tmp/family.ged",
            "--once", "Was Donna there?", "--no-actions",
            "--log-run-id", "fixture-run", "--diagnostics",
        ])

        #expect(options.catalogURL.path == "/tmp/hallie-catalog.json")
        #expect(options.hosts.count == 2)
        #expect(options.hosts[0].contains("ollama-one.local"))
        #expect(options.hosts[1].contains("ollama-two.local"))
        #expect(options.model == "fixture-model")
        #expect(options.gedcomURL?.path == "/tmp/family.ged")
        #expect(options.once == "Was Donna there?")
        #expect(!options.allowActions)
        #expect(options.diagnostics)
        #expect(options.logRunID == "fixture-run")
    }

    @Test func rejectsUnknownMissingAndEmptyOptions() {
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--catalog"])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--model", "   "])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--host", ",,"])
        }
        #expect(throws: HallieShellCLI.ParseError.self) {
            _ = try HallieShellCLI.parse(arguments: ["--write-catalog"])
        }
    }

    @Test func onlyDeployedGEDCOMLayoutConfersPhotoAuthority() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieGEDCOMAuthority-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let master = base.appendingPathComponent("Breen_Family_Archive", isDirectory: true)
        let gedcom = master
            .appendingPathComponent("40_Family_Tree/GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gedcom, withIntermediateDirectories: true)
        let file = gedcom.appendingPathComponent("family.ged")
        try Data("0 HEAD\n0 TRLR\n".utf8).write(to: file)

        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM: file) == master)
        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM: gedcom) == master)
        #expect(HallieShellCLI.masterArchiveRoot(containingGEDCOM:
            base.appendingPathComponent("unrelated/family.ged")) == nil)
    }

    @Test func catalogHeaderProbeReadsMasterWithoutDecodingRecords() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieCatalogHeader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let catalog = base.appendingPathComponent("catalog.json")
        let json = """
        {"version":6,"generation":12,"savedAt":"2026-08-23T01:31:09Z","savedFromHost":"fixture","masterArchive":{"targetPath":"/Volumes/FamilyArchive","rootPath":"/Volumes/FamilyArchive/Breen_Family_Archive","volumeUUID":"fixture-uuid","designatedAt":"2026-08-21T00:28:35Z"},"records":[{"intentionally":"not a VideoRecord"}]}
        """
        try Data(json.utf8).write(to: catalog)

        let designation = try #require(
            HallieShellCLI.masterArchiveDesignation(catalogURL: catalog))
        #expect(designation.targetPath == "/Volumes/FamilyArchive")
        #expect(designation.rootPath
            == "/Volumes/FamilyArchive/Breen_Family_Archive")
        #expect(designation.volumeUUID == "fixture-uuid")

        let missingMarker = base.appendingPathComponent("missing.json")
        try Data("{}".utf8).write(to: missingMarker)
        #expect(HallieShellCLI.masterArchiveDesignation(
            catalogURL: missingMarker) == nil)
    }

    // MARK: - Interactive and once modes

    @Test func helpSessionAndQuitCommandsDoNotTranslateOrOpenMedia() async throws {
        let harness = Harness(inputs: [":help", ":session", ":quit"])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/isolated/catalog.json",
        ])
        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.readCount == 3)
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains(HallieShellCLI.help))
        #expect(harness.output.contains { $0.hasPrefix("session: ")
            && $0.contains("· 0 citations") })
        #expect(harness.output.contains("Goodbye."))
        #expect(harness.output.contains { $0.contains("standalone family librarian") })
        #expect(harness.output.contains {
            $0 == "Archive ready — 0 catalog items, read-only."
        })
        #expect(!harness.output.contains { $0.contains("/isolated/catalog.json") })
    }

    @Test func onceTranslatesExactlyOnceAndNeverReadsInteractiveInput() async throws {
        let harness = Harness(
            inputs: ["this must remain unread"],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Donna there?",
        ])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.translatedQuestions == ["Was Donna there?"])
        #expect(harness.readCount == 0)
        #expect(harness.inputs == ["this must remain unread"])
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains("Hallie is thinking…"))
    }

    @Test func normalConversationHidesDiagnosticsButLogRetainsThem() async throws {
        for diagnostics in [false, true] {
            let path = "/isolated/archive/Donna-Cape.mov"
            let harness = Harness(
                translations: [.presence(.init(people: ["Donna"]))])
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            var arguments = ["--hallie", "--once", "Show me Donna"]
            if diagnostics { arguments.append("--diagnostics") }
            let options = try HallieShellCLI.parse(arguments: arguments)

            _ = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(harness.output.contains("fixture answer"))
            #expect(harness.output.contains("fixture basis") == diagnostics)
            #expect(harness.output.contains("query: shape=presence") == diagnostics)
            #expect(harness.output.contains { $0.contains(path) } == diagnostics)
            let transcriptAnswer = try #require(harness.transcriptEvents.last)
            #expect(transcriptAnswer.basisLine == "fixture basis")
            #expect(transcriptAnswer.queryDescription == "shape=presence")
            #expect(transcriptAnswer.mediaEvidence.first?.fullPath == path)
        }
    }

    @Test func noActionsBlocksRequestedPlaybackAndStampsTheRunID() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "play videos of Donna", "--no-actions",
            "--log-run-id", "safe-eval-run",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.contains("Media actions are off."))
        #expect(harness.transcriptEvents.allSatisfy {
            $0.runID == "safe-eval-run"
        })
    }

    @Test func colonResetStartsANewLoggedSessionAndClearsSequence() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            inputs: ["Was Donna there?", ":reset", ":quit"],
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--log-run-id", "reset-run",
        ])

        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.transcriptEvents.count == 3)
        let firstSession = harness.transcriptEvents[0].sessionID
        let reset = harness.transcriptEvents[2]
        #expect(reset.kind == .system)
        #expect(reset.text == ":reset")
        #expect(reset.sessionID != firstSession)
        #expect(reset.sequence == 1)
        #expect(reset.runID == "reset-run")
        #expect(reset.basisLine
            == "Conversation memory, citations, history, and active modes cleared.")
    }

    @Test func resetSessionClearsEveryActiveConversationMode() {
        var state = HallieShellCLI.Session(
            records: [], profiles: [], graph: nil, cyberBrain: nil,
            model: "fixture-model", runID: "reset-run")
        let previousSessionID = state.transcriptSessionID
        state.transcriptSequence = 41
        state.telling = HallieTellingMode.Session(opening: .init(
            subject: "Dad Breen", relation: "Rick's dad", pronoun: .he,
            firstStatement: nil))
        state.drill = HalliePronunciationDrillMode.Session(
            list: PronunciationDrillList(items: []), index: nil)
        state.picker = HalliePronunciationPicker.Offer(
            word: "Latta", candidates: [])

        let reset = HallieShellCLI.resetSession(&state)

        #expect(state.telling == nil)
        #expect(state.drill == nil)
        #expect(state.picker == nil)
        #expect(state.transcriptSessionID != previousSessionID)
        #expect(state.transcriptSequence == 1)
        #expect(reset.sessionID == state.transcriptSessionID)
        #expect(reset.sequence == 1)
        #expect(reset.runID == "reset-run")
        #expect(reset.basisLine
            == "Conversation memory, citations, history, and active modes cleared.")
    }

    @Test func naturalResetPreemptsEveryActiveConversationMode() async {
        for mode in ActiveResetMode.allCases {
            let harness = Harness()
            var state = conversationState(with: mode)
            let sessionID = state.transcriptSessionID
            var output: [String] = []

            let outcome = await HallieShellCLI.answer(
                "start over",
                options: HallieShellCLI.Options(),
                state: &state,
                output: { output.append($0) },
                dependencies: harness.dependencies())

            #expect(outcome.exitCode == HallieShellCLI.ExitCode.success.rawValue)
            #expect(state.telling == nil, "\(mode)")
            #expect(state.drill == nil, "\(mode)")
            #expect(state.picker == nil, "\(mode)")
            #expect(state.pendingClarification == nil, "\(mode)")
            #expect(state.citations.isEmpty, "\(mode)")
            #expect(state.selectedRecordID == nil, "\(mode)")
            #expect(state.memory == HallieTurnExecutor.ConversationMemory(), "\(mode)")
            #expect(state.history.isEmpty, "\(mode)")
            #expect(state.socialHistory.isEmpty, "\(mode)")
            #expect(state.lastResponder == "none", "\(mode)")
            // Natural reset stays in the logged session; only `:reset`
            // renews the ID and restarts its sequence.
            #expect(state.transcriptSessionID == sessionID, "\(mode)")
            #expect(state.transcriptSequence == 43, "\(mode)")
            #expect(harness.transcriptEvents.map(\.sequence) == [42, 43], "\(mode)")
            #expect(harness.transcriptEvents.allSatisfy {
                $0.sessionID == sessionID
            }, "\(mode)")
            #expect(harness.transcriptEvents.last?.route == "reset", "\(mode)")
            #expect(output == [ArchivistConversationCommand.resetReply], "\(mode)")
            #expect(harness.translatedQuestions.isEmpty, "\(mode)")
        }
    }

    @Test func onceRecordsExactQuestionAndBoundedAnswerEvidence() async throws {
        let item = record("/isolated/Donna/Cape.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: [item],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--model", "fixture-model",
            "--once", "Was Donna there?",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.transcriptEvents.count == 2)
        let user = harness.transcriptEvents[0]
        let answer = harness.transcriptEvents[1]
        #expect(user.kind == .user)
        #expect(user.text == "Was Donna there?")
        #expect(user.sequence == 1)
        #expect(answer.kind == .assistant)
        #expect(answer.sequence == 2)
        #expect(answer.sessionID == user.sessionID)
        #expect(answer.model == "fixture-model")
        #expect(answer.responder == "fixture-translator")
        #expect(answer.route == "presence")
        #expect(answer.outcome == "answered")
        #expect(answer.mediaEvidence.map(\.recordID) == [item.id])
    }

    @Test func translatorFailureAssertsNoFactAndPerformsNoMediaAction() async throws {
        let harness = Harness()
        harness.translationError = HarnessError.refusedByTranslator
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Invent something",
        ])

        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains {
            $0.contains("I didn't search the archive or open anything")
        })
        #expect(!harness.output.contains { $0.contains("I found") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.interpretationFailed.rawValue)
    }

    @Test func clarificationNumberAndExactNameDoNotRetranslate() async throws {
        for reply in ["2", "Timothy Breen"] {
            let profiles = [
                POIProfile(
                    name: "Tim Breen", referencePath: "/isolated/tim-a",
                    aliases: ["Timmy"],
                    birthdate: Date(timeIntervalSince1970: 0)),
                POIProfile(
                    name: "Timothy Breen", referencePath: "/isolated/tim-z",
                    aliases: ["Timmy"],
                    birthdate: Date(timeIntervalSince1970: 946_684_800)),
            ]
            let ast = ArchivistQueryAST.temporal(.init(
                subject: "Timmy", operation: .age,
                reference: .explicitYear(2020)))
            let harness = Harness(
                inputs: ["How old was Timmy in 2020?", reply, ":quit"],
                profiles: profiles, translations: [ast])
            let continuations = LockedCounter()
            harness.executeRequest = { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            }
            harness.continueTurn = { pending, selectedID, context in
                continuations.increment()
                return try await HallieTurnExecutor.continue(
                    pending: pending, selecting: selectedID, context: context)
            }
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--catalog", "/isolated/catalog.json",
            ])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.success.rawValue)
            #expect(harness.translatedQuestions
                    == ["How old was Timmy in 2020?"])
            #expect(continuations.value == 1)
            #expect(harness.output.contains { $0 == "choices:" })
            #expect(harness.output.contains("  1. Tim Breen"))
            #expect(harness.output.contains("  2. Timothy Breen"))
            #expect(harness.output.contains { $0.contains("Timothy Breen") })
            #expect(harness.output.contains { $0.contains("years old") })
            #expect(harness.mediaActions.isEmpty)
        }
    }

    @Test func cancelAbandonsPendingClarificationWithoutContinuation() async throws {
        let profiles = [
            POIProfile(name: "Tim Breen", referencePath: "/isolated/tim-a",
                       aliases: ["Timmy"]),
            POIProfile(name: "Timothy Breen", referencePath: "/isolated/tim-z",
                       aliases: ["Timmy"]),
        ]
        let ast = ArchivistQueryAST.temporal(.init(
            subject: "Timmy", operation: .age,
            reference: .explicitYear(2020)))
        let harness = Harness(
            inputs: ["How old was Timmy?", ":cancel", ":session", ":quit"],
            profiles: profiles, translations: [ast])
        let continuations = LockedCounter()
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            return try await HallieTurnExecutor.continue(
                pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", "/isolated/catalog.json",
        ])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions == ["How old was Timmy?"])
        #expect(continuations.value == 0)
        #expect(harness.output.contains(
            "Clarification cancelled; I won't guess."))
        #expect(harness.output.contains { $0.contains("pending none") })
    }

    // MARK: - Typed routing boundary

    @Test func allSixASTShapesHaveClosedExplicitRoutes() {
        let cases: [(ArchivistQueryAST, HallieShellCLI.Route)] = [
            (.presence(.init(people: ["Donna"])), .presence),
            (.temporal(.init(subject: "Donna", operation: .age,
                             reference: .explicitYear(2000))), .temporal),
            (.aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"])), .aggregate),
            (.graph(.init(people: ["Donna"], operation: .biography)), .graph),
            (.event(.init(keywords: ["birthday"])), .unsupportedEvent),
            (.cross(.init(people: ["Donna"], transcript: ["birthday"])), .cross),
        ]
        for (ast, expected) in cases {
            #expect(HallieShellCLI.route(ast) == expected)
        }
    }

    @Test func fourSupportedShapesExecuteThroughOnceMode() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        0 TRLR
        """)
        let cases: [(ArchivistQueryAST, String)] = [
            (.presence(.init(people: ["Donna"])), "shape=presence"),
            (.temporal(.init(subject: "Donna", operation: .age,
                             reference: .explicitYear(2000))), "shape=temporal"),
            (.aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"])), "shape=aggregate"),
            (.graph(.init(people: ["Alex River"], operation: .biography)),
             "shape=graph"),
        ]

        for (ast, shape) in cases {
            let harness = Harness(graph: graph, translations: [ast])
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--once", "fixture question", "--diagnostics",
            ])
            _ = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(harness.translatedQuestions == ["fixture question"])
            #expect(harness.output.contains { $0.contains(shape) })
            #expect(!harness.output.contains { $0.contains("not supported") })
            #expect(harness.output.contains("interpreted by fixture-translator"))
        }
    }

    @Test func eventIsDeclinedBySharedTurnWithoutMediaAction() async throws {
        let ast = ArchivistQueryAST.event(.init(keywords: ["first birthday"]))
        let harness = Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "fixture question", "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains { $0.contains("not supported") })
        #expect(harness.output.contains { $0.contains("did not run a broader search") })
        #expect(harness.output.contains { $0.contains("QueryAST shape=") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.unsupportedShape.rawValue)
    }

    /// Cross now runs on the deterministic presence executor: with no
    /// matching evidence it declines on evidence (exit 3), never as an
    /// unsupported shape, and never opens media.
    @Test func crossExecutesDeterministicallyAndDeclinesOnNoEvidence() async throws {
        let ast = ArchivistQueryAST.cross(.init(people: ["Donna"], keywords: ["red bike"]))
        let harness = Harness(translations: [ast])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "fixture question", "--diagnostics",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.contains { $0.contains("shape=cross") })
        #expect(!harness.output.contains { $0.contains("not supported") })
        #expect(harness.mediaActions.isEmpty)
        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
    }

    @Test func unsupportedRoutesRenderSharedResultWithoutShellOverride() async throws {
        for (ast, route) in [
            (ArchivistQueryAST.event(.init(keywords: ["birthday"])),
             HallieTurnExecutor.Route.unsupportedEvent),
        ] {
            let harness = Harness(translations: [ast])
            harness.executeTurn = { _, _ in
                HallieTurnExecutor.Result(
                    route: route,
                    outcome: .unsupported,
                    prose: "SENTINEL shared unsupported prose",
                    basisLine: "SENTINEL shared unsupported basis",
                    queryDescription: nil,
                    citations: [],
                    catalogPersonName: nil)
            }
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--once", "fixture question", "--diagnostics",
            ])

            let code = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.unsupportedShape.rawValue)
            #expect(harness.output.contains("SENTINEL shared unsupported prose"))
            #expect(harness.output.contains("SENTINEL shared unsupported basis"))
            #expect(!harness.output.contains {
                $0.contains("not supported by the headless shell")
            })
            #expect(!harness.output.contains {
                $0.contains("no deterministic shell executor")
            })
            #expect(harness.mediaActions.isEmpty)
        }
    }

    // MARK: - Citation and media safety

    @Test func citationsAreBoundedAndRetainPlaybackCoordinates() async throws {
        let records = (0..<40).map { index in
            record("/isolated/archive/clip-\(index).mov", confirmed: ["Donna"],
                   caption: (Double(index) + 0.25, "Donna waves"))
        }
        let harness = Harness(
            records: records,
            translations: [.presence(.init(people: ["Donna"], keywords: ["waves"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--once", "Where is Donna waving?",
        ])

        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        let citationRows = harness.output.filter {
            $0.hasPrefix("  ") && $0.contains(". clip-")
        }
        #expect(citationRows.count == ArchivistPresenceExecutor.maxCitations)
        #expect(citationRows.first?.contains("clip-0.mov @ 0.2s") == true)
        #expect(citationRows.first?.contains("/isolated/archive/clip-0.mov") == true)
    }

    @Test func invalidIndexesNeverOpenMediaAndValidCommandsAreExplicit() async throws {
        let value = record("/isolated/archive/donna.mov", confirmed: ["Donna"])
        let harness = Harness(
            inputs: ["Was Donna there?", ":play 0", ":play 2", ":select 1",
                     ":play 1", ":reveal 1", ":quit"],
            records: [value],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.mediaActions == [
            .play(URL(fileURLWithPath: value.fullPath)),
            .reveal(URL(fileURLWithPath: value.fullPath)),
        ])
        #expect(harness.output.filter { $0.hasPrefix("No such citation") }.count == 2)
        #expect(harness.output.contains("selected 1: donna.mov"))
    }

    @Test func askingSelectingAndListingNeverImplicitlyOpenMedia() async throws {
        let harness = Harness(
            inputs: ["Was Donna there?", ":select 1", ":list", ":quit"],
            records: [record("/isolated/archive/donna.mov", confirmed: ["Donna"])],
            translations: [.presence(.init(people: ["Donna"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.mediaActions.isEmpty)
    }

    @Test func unavailableCitationNeverClaimsPlayOrRevealAndReturnsMediaFailure() async throws {
        for command in [":play 1", ":reveal 1"] {
            let path = "/offline/archive/missing.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command],
                translations: [.presence(.init(people: ["Donna"]))])
            harness.unavailableMediaPaths = [path]
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
            #expect(harness.mediaActions.isEmpty)
            #expect(harness.output.contains {
                $0.contains("unavailable or unreadable")
            })
            #expect(!harness.output.contains("opening missing.mov"))
            #expect(!harness.output.contains("revealing missing.mov"))
        }
    }

    @Test func refusedMediaActionNeverClaimsSuccessAndReturnsMediaFailure() async throws {
        for command in [":play 1", ":reveal 1"] {
            let path = "/isolated/available.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command],
                translations: [.presence(.init(people: ["Donna"]))])
            harness.mediaActionShouldSucceed = false
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
            #expect(harness.mediaActions.count == 1)
            #expect(harness.output.contains {
                $0.contains("system refused")
                    && $0.contains("no media action was completed")
            })
            #expect(!harness.output.contains("opening available.mov"))
            #expect(!harness.output.contains("revealing available.mov"))
        }
    }

    @Test func availableCitationReportsSuccessOnlyAfterMediaActionSucceeds() async throws {
        for (command, expectedAction, successLine) in [
            (":play 1",
             HallieShellCLI.MediaAction.play(
                URL(fileURLWithPath: "/isolated/available.mov")),
             "opening available.mov"),
            (":reveal 1",
             HallieShellCLI.MediaAction.reveal(
                URL(fileURLWithPath: "/isolated/available.mov")),
             "revealing available.mov"),
        ] {
            let path = "/isolated/available.mov"
            let harness = Harness(
                inputs: ["Was Donna there?", command, ":quit"],
                translations: [.presence(.init(people: ["Donna"]))])
            let answer = citedAnswer(path: path)
            harness.executeTurn = { _, _ in answer }
            let options = try HallieShellCLI.parse(arguments: ["--hallie"])

            let code = await HallieShellCLI.run(
                options: options, input: harness.nextInput,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies())

            #expect(code == HallieShellCLI.ExitCode.success.rawValue)
            #expect(harness.mediaActions == [expectedAction])
            #expect(harness.output.contains(successLine))
        }
    }

    @Test func biographyPrintsCyberBrainClaimAndRelativeSource() async throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let source = CyberBrainSource(
            id: "source.cape",
            type: .firstPerson,
            title: "Cape memories",
            attribution: "Donna Breen",
            locator: "sources/donna-cape.txt")
        let item = CyberBrainItem(
            id: "bio.cape",
            kind: .biography,
            text: "Donna remembers the Cape as a central family gathering place.",
            subjectPersonIDs: ["person.donna"],
            sourceIDs: [source.id],
            confidence: .confirmed,
            privacy: .family,
            createdAt: instant,
            updatedAt: instant)
        let harness = Harness(translations: [.graph(.init(
            people: ["Donna"], operation: .biography))])
        harness.cyberBrain = try CyberBrainIndex(archive: .init(
            archiveID: "breen",
            displayName: "Breen Family CyberBrain",
            people: [.init(
                id: "person.donna",
                canonicalName: "Donna Breen",
                aliases: ["Donna"],
                biographyPassages: [item])],
            sources: [source]))

        let code = await HallieShellCLI.run(
            options: .init(once: "Tell me about Donna", diagnostics: true),
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.output.contains(where: {
            $0.contains("central family gathering place")
        }))
        #expect(harness.output.contains("knowledge sources:"))
        #expect(harness.output.contains(
            "  1. Cape memories — Donna Breen [sources/donna-cape.txt]"))
    }

    @Test func biographyPrintsVerifiedPhotoButOpensOnlyOnExplicitCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-biography-photo-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("portrait.png")
        try onePixelPNG.write(to: photo)

        var profile = POIProfile(name: "Alex River", referencePath: root.path)
        profile.coverImageFilename = photo.lastPathComponent
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1 JAN 1900
        0 TRLR
        """)
        let harness = Harness(
            inputs: ["Tell me about Alex River", ":photo", ":open-photo",
                     ":reveal-photo", ":quit"],
            profiles: [profile], graph: graph,
            translations: [.graph(.init(
                people: ["Alex River"], operation: .biography))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])

        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.output.filter { $0 == "photo: \(photo.path)" }.count == 1,
                "the attachment path appears only after the explicit :photo command")
        #expect(harness.mediaActions == [.play(photo), .reveal(photo)],
                "answering and :photo are presentation-only; only explicit open commands act")
    }

    @Test func biographyPhotoRejectsTraversalAbsoluteSymlinkAmbiguityAndNoCover() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-photo-safety-\(UUID().uuidString)",
                                    isDirectory: true)
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(
            at: references, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = references.appendingPathComponent("regular.png")
        try onePixelPNG.write(to: regular)
        let symlink = references.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: regular)

        func profile(_ name: String = "Alex River", cover: String?) -> POIProfile {
            var value = POIProfile(name: name, referencePath: references.path)
            value.coverImageFilename = cover
            return value
        }

        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: regular.lastPathComponent)])?.fileURL == regular)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: "../regular.png")]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: regular.path)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: symlink.lastPathComponent)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: regular.lastPathComponent),
                       profile(cover: regular.lastPathComponent)]) == nil)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile(cover: nil)]) == nil)

        let corrupt = references.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        #expect(ArchivistBiographyPhoto.resolve(
            personName: "Alex River",
            profiles: [profile(cover: corrupt.lastPathComponent)]) == nil)
    }

    @Test func biographyPhotoDownsamplesAndRevalidatesBeforeUse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-photo-downsample-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let formats: [(String, NSBitmapImageRep.FileType)] = [
            ("large.png", .png), ("large.jpg", .jpeg),
        ]
        for (filename, format) in formats {
            let url = root.appendingPathComponent(filename)
            let data = try #require(bitmap.representation(
                using: format, properties: [:]))
            try data.write(to: url)
            var profile = POIProfile(name: "Alex River", referencePath: root.path)
            profile.coverImageFilename = filename
            let attachment = try #require(ArchivistBiographyPhoto.resolve(
                personName: "Alex River", profiles: [profile]))
            let thumbnail = try #require(attachment.makeThumbnail(maxPixelSize: 64))
            #expect(max(thumbnail.width, thumbnail.height) <= 64)
        }

        var profile = POIProfile(name: "Alex River", referencePath: root.path)
        profile.coverImageFilename = "replace.png"
        let replace = root.appendingPathComponent("replace.png")
        try onePixelPNG.write(to: replace)
        let attachment = try #require(ArchivistBiographyPhoto.resolve(
            personName: "Alex River", profiles: [profile]))
        try FileManager.default.removeItem(at: replace)
        try FileManager.default.createSymbolicLink(
            at: replace, withDestinationURL: root.appendingPathComponent("large.png"))
        #expect(attachment.revalidatedURL() == nil)
        #expect(attachment.makeThumbnail(maxPixelSize: 64) == nil)
    }

    // MARK: - Scale, isolation, and production wiring sensors

    @Test func oneHundredThousandRecordOnceModeSnapshotsAndDispatchesWithinBudget() async throws {
        let repeated = record("/isolated/scale/repeated.mov", confirmed: ["Donna"])
        let harness = Harness(
            records: Array(repeating: repeated, count: 100_000),
            translations: [.presence(.init(people: ["Nobody"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Nobody there?",
        ])

        let started = ContinuousClock.now
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        let elapsed = ContinuousClock.now - started

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.output.contains("Archive ready — 100000 catalog items, read-only."))
        #expect(elapsed < .seconds(4),
                "shell snapshot + typed dispatch took \(elapsed) for 100k records")
    }

    @Test func injectedFilesAndPoisonedDefaultsCannotRedirectReadOnlySession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.json")
        let sentinel = Data("READ-ONLY-SENTINEL".utf8)
        try sentinel.write(to: catalog)

        let poisonKey = OllamaEndpoints.hostsKey
        let priorHosts = UserDefaults.standard.object(forKey: poisonKey)
        UserDefaults.standard.set("poison.invalid", forKey: poisonKey)
        defer {
            if let priorHosts {
                UserDefaults.standard.set(priorHosts, forKey: poisonKey)
            } else {
                UserDefaults.standard.removeObject(forKey: poisonKey)
            }
        }

        let harness = Harness(
            records: [record("/isolated/media/test.mov")],
            profiles: [POIProfile(name: "Fixture Person", referencePath: root.path)],
            graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"),
            translations: [.presence(.init(people: ["Nobody"]))])
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--catalog", catalog.path,
            "--host", "isolated-translator.local",
            "--gedcom", root.appendingPathComponent("fixture.ged").path,
            "--once", "Was Nobody there?",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.loadedURLs == [catalog])
        #expect(harness.translationOptions.first?.hosts
                == ["isolated-translator.local"])
        #expect(try Data(contentsOf: catalog) == sentinel,
                "the shell must never rewrite even its explicitly loaded catalog")
        #expect(harness.mediaActions.isEmpty)
    }

    @Test func cancellationReachesInjectedTurnSeamAndPerformsNoMediaAction() async throws {
        let probe = CancellationProbe()
        let harness = Harness(
            translations: [.presence(.init(people: ["Donna"]))])
        harness.executeTurn = { _, _ in
            await probe.blockUntilCancelled()
            try Task.checkCancellation()
            throw CancellationError()
        }
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", "Was Donna there?",
        ])

        let task = Task {
            await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())
        }
        await probe.waitUntilStarted()
        task.cancel()
        let code = await task.value

        #expect(probe.observedCancellation)
        #expect(code == HallieShellCLI.ExitCode.interpretationFailed.rawValue)
        #expect(harness.mediaActions.isEmpty)
        #expect(!harness.output.contains { $0.contains("I found") })
    }

    @Test func productionProfileLoaderFailsClosedForUnreadableAndCorruptProfiles() async throws {
        func profileURL(in root: URL) throws -> URL {
            let folder = root.appendingPathComponent("VideoScan/POI/Fixture",
                                                      isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("profile.json")
        }

        let corruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-corrupt-profile-\(UUID().uuidString)",
                                    isDirectory: true)
        let unreadableRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-unreadable-profile-\(UUID().uuidString)",
                                    isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: corruptRoot)
            try? FileManager.default.removeItem(at: unreadableRoot)
        }

        let corruptURL = try profileURL(in: corruptRoot)
        try Data("not valid profile JSON".utf8).write(to: corruptURL)
        let corrupt = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: corruptRoot)
        guard case .unavailable(.profileCorrupt(let reportedCorruptPath))
                = corrupt else {
            Issue.record("corrupt production profile must make evidence unavailable")
            return
        }
        #expect(reportedCorruptPath == corruptURL.path)

        let missingURL = try profileURL(in: unreadableRoot)
        let unreadable = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: unreadableRoot)
        guard case .unavailable(.profileUnreadable(let reportedUnreadablePath))
                = unreadable else {
            Issue.record("unreadable production profile must make evidence unavailable")
            return
        }
        #expect(reportedUnreadablePath == missingURL.path)

        let harness = Harness(translations: [.temporal(.init(
            subject: "Donna", operation: .age,
            reference: .explicitYear(2000)))])
        harness.profileLoadResult = corrupt
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--once", "How old was Donna in 2000?",
        ])
        let code = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.noEvidence.rawValue)
        #expect(harness.output.contains {
            $0.contains("People profiles are unavailable")
        })
        #expect(harness.output.contains {
            $0 == "Basis: profile evidence could not be read."
        })
        #expect(harness.mediaActions.isEmpty)
    }

    /// Media matrix is intentionally N/A for ordinary shell questions: the
    /// shell handles catalog metadata only. The command tests pin that media
    /// reaches AppKit solely through explicit :play or :reveal commands.
    @Test func productionSourceHasNoCatalogWriterOrImplicitMediaPath() throws {
        let shell = try source(named: "HallieShellCLI.swift")
        let compactShell = shell.filter { !$0.isWhitespace }
        #expect(!shell.contains("CatalogStore("))
        #expect(!shell.contains("saveNow("))
        #expect(!shell.contains("scheduleSave("))
        #expect(shell.contains("case \":select\", \":play\", \":reveal\":"))
        #expect(compactShell.contains("dependencies.mediaURLIsAvailable(url)"))
        #expect(compactShell.contains("dependencies.tryPerformMediaAction(action)"))
        #expect(shell.contains("case mediaFailure"))
        #expect(shell.contains("case mediaUnavailable = 6"))
    }

    @Test func mainRoutesHallieBeforeSwiftUIAndShellUsesTypedTranslator() throws {
        let main = try source(named: "main.swift")
        // The shell's rendering lives in a sibling extension file; the
        // source sensors below cover both.
        let shell = try source(named: "HallieShellCLI.swift")
            + source(named: "HallieShellCLI+Render.swift")
        let hallieBranch = try #require(main.range(of: "if isHallieShell"))
        let appMain = try #require(main.range(of: "VideoScanApp.main()",
                                             options: .backwards))

        #expect(hallieBranch.lowerBound < appMain.lowerBound,
                "--hallie must route before the normal SwiftUI app entry")
        #expect(main.contains("HallieShellCLI.parse("))
        #expect(main.contains("HallieShellCLI.run(options:"))
        #expect(shell.contains("translator.translateAST(question)"))
        #expect(!shell.contains("translator.translate(question)"),
                "the shell must not fall back to the v1 translator")
        #expect(shell.contains("if let pending = state.pendingClarification"))
        #expect(shell.contains("dependencies.continueTurn("))
        #expect(shell.contains("case \":cancel\":"))
        #expect(shell.contains("Reply with a number or exact name"))
    }
}
