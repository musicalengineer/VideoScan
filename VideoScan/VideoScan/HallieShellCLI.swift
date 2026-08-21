// HallieShellCLI.swift
// Headless, read-only interactive access to Hallie's QueryAST-v2 pipeline.

import AppKit
import Foundation
import VideoScanCore

enum HallieShellCLI {
    struct Options: Equatable {
        var catalogURL: URL = defaultCatalogURL
        var hosts: [String] = OllamaEndpoints.defaultHosts
        var model = "qwen3.6:35b-a3b-nvfp4"
        var gedcomURL: URL?
        var once: String?
        /// `--compose`: let the model phrase composable answers (verified,
        /// facts locked). OFF by default in the shell — it is a diagnostic
        /// surface and the templated wording is the reference output.
        var compose = false
    }

    enum ParseError: LocalizedError, Equatable {
        case missingValue(String)
        case unknownOption(String)
        case emptyValue(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let option): return "missing value for \(option)"
            case .unknownOption(let option): return "unknown Hallie option: \(option)"
            case .emptyValue(let option): return "empty value for \(option)"
            }
        }
    }

    enum Route: Equatable {
        case presence, temporal, aggregate, graph, cross
        case unsupportedEvent
        case followUp, capability
        case help, smalltalk, reset
    }

    enum MediaAction: Equatable {
        case play(URL)
        case reveal(URL)
    }

    enum ExitCode: Int32 {
        case success = 0
        case catalogUnavailable = 2
        case noEvidence = 3
        case unsupportedShape = 4
        case interpretationFailed = 5
        case mediaUnavailable = 6
    }

    private enum AnswerOutcome {
        case answered, declined, unsupported, interpretationFailed

        var exitCode: Int32 {
            switch self {
            case .answered: ExitCode.success.rawValue
            case .declined: ExitCode.noEvidence.rawValue
            case .unsupported: ExitCode.unsupportedShape.rawValue
            case .interpretationFailed: ExitCode.interpretationFailed.rawValue
            }
        }
    }

    enum CommandOutcome {
        case continueSession
        case quit
        case mediaFailure
    }

    struct Translation {
        let ast: ArchivistQueryAST
        let responderHost: String
    }

    enum ProfileLoadFailure: LocalizedError, Sendable, Equatable {
        case applicationSupportUnavailable
        case directoryUnreadable(String)
        case profileUnreadable(String)
        case profileCorrupt(String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "application support directory is unavailable"
            case .directoryUnreadable(let path):
                return "People profile directory is unreadable: \(path)"
            case .profileUnreadable(let path):
                return "People profile is unreadable: \(path)"
            case .profileCorrupt(let path):
                return "People profile is corrupt: \(path)"
            }
        }
    }

    enum ProfileLoadResult {
        case loaded([POIProfile])
        case unavailable(ProfileLoadFailure)
    }

    struct Dependencies {
        var loadCatalog: (URL) -> [VideoRecord]?
        var loadProfiles: () -> ProfileLoadResult
        var loadGraph: (URL?) -> GedcomFamilyGraph?
        var loadCyberBrain: () -> CyberBrainIndex?
        var translateAST: (String, Options) async throws -> Translation
        var executeTurn: @Sendable (
            ArchivistQueryAST,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        var executeRequest: @Sendable (
            HallieTurnExecutor.Request,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        var continueTurn: @Sendable (
            HallieTurnExecutor.Clarification,
            HallieTurnExecutor.CandidateID,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        var mediaURLIsAvailable: (URL) -> Bool
        var tryPerformMediaAction: (MediaAction) -> Bool
        var performMediaAction: (MediaAction) -> Void
        /// Injected as a no-op so unit tests never touch Rick's real log.
        var recordTranscript: ([HallieTranscriptEvent]) async -> Void
        /// Phrase an approved plan; only consulted with `--compose` and only
        /// for composable plans. The default returns the template.
        var composeAnswer: @Sendable (
            HallieAnswerPlan, [HallieGroundedComposer.HistoryTurn], Options
        ) async -> HallieGroundedComposer.Outcome

        init(
            loadCatalog: @escaping (URL) -> [VideoRecord]?,
            loadProfiles: @escaping () -> ProfileLoadResult,
            loadGraph: @escaping (URL?) -> GedcomFamilyGraph?,
            loadCyberBrain: @escaping () -> CyberBrainIndex? = { nil },
            translateAST: @escaping (String, Options) async throws -> Translation,
            executeTurn: @escaping @Sendable (
                ArchivistQueryAST,
                HallieTurnExecutor.Context
            ) async throws -> HallieTurnExecutor.Result,
            executeRequest: (@Sendable (
                HallieTurnExecutor.Request,
                HallieTurnExecutor.Context
            ) async throws -> HallieTurnExecutor.Result)? = nil,
            continueTurn: (@Sendable (
                HallieTurnExecutor.Clarification,
                HallieTurnExecutor.CandidateID,
                HallieTurnExecutor.Context
            ) async throws -> HallieTurnExecutor.Result)? = nil,
            mediaURLIsAvailable: @escaping (URL) -> Bool = { _ in true },
            tryPerformMediaAction: ((MediaAction) -> Bool)? = nil,
            performMediaAction: @escaping (MediaAction) -> Void,
            recordTranscript: @escaping ([HallieTranscriptEvent]) async -> Void = { _ in },
            composeAnswer: @escaping @Sendable (
                HallieAnswerPlan, [HallieGroundedComposer.HistoryTurn], Options
            ) async -> HallieGroundedComposer.Outcome = { plan, _, _ in
                .template(plan, note: "template: no composer configured")
            }
        ) {
            self.loadCatalog = loadCatalog
            self.loadProfiles = loadProfiles
            self.loadGraph = loadGraph
            self.loadCyberBrain = loadCyberBrain
            self.translateAST = translateAST
            self.executeTurn = executeTurn
            self.executeRequest = executeRequest ?? { request, context in
                try await executeTurn(request.intent.ast, context)
            }
            self.continueTurn = continueTurn ?? { pending, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: pending, selecting: selectedID, context: context)
            }
            self.mediaURLIsAvailable = mediaURLIsAvailable
            self.tryPerformMediaAction = tryPerformMediaAction ?? { action in
                performMediaAction(action)
                return true
            }
            self.performMediaAction = performMediaAction
            self.recordTranscript = recordTranscript
            self.composeAnswer = composeAnswer
        }

        static var production: Dependencies {
            Dependencies(
                loadCatalog: { FileBackedCatalogSource.loadRecords(from: $0) },
                loadProfiles: { loadProfilesReadOnly() },
                loadGraph: { requested in
                    let fm = FileManager.default
                    if let requested {
                        var isDirectory: ObjCBool = false
                        guard fm.fileExists(atPath: requested.path,
                                            isDirectory: &isDirectory) else { return nil }
                        return isDirectory.boolValue
                            ? FamilyGraphFileLoader(originalsDirectory: requested).loadNewest()
                            : GedcomFamilyGraph(fileURL: requested)
                    }
                    let directory = fm.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first?
                        .appendingPathComponent("VideoScan/family-tree/originals")
                    return directory.flatMap {
                        FamilyGraphFileLoader(originalsDirectory: $0).loadNewest()
                    }
                },
                loadCyberBrain: {
                    guard let root = FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask).first?.appendingPathComponent(
                            "VideoScan/cyberbrain", isDirectory: true) else {
                        return nil
                    }
                    return try? CyberBrainIndex(
                        archive: CyberBrainLoader(rootURL: root).load())
                },
                translateAST: { question, options in
                    let responder = LockedString()
                    var template = OllamaQueryTranslator()
                    template.model = options.model
                    let translator = OllamaFailoverTranslator(
                        hosts: options.hosts,
                        template: template,
                        onResponder: { responder.set($0) })
                    let ast = try await translator.translateAST(question)
                    return Translation(ast: ast,
                                       responderHost: responder.value ?? "unknown")
                },
                executeTurn: HallieTurnExecutor.execute,
                executeRequest: { request, context in
                    try await HallieTurnExecutor.execute(
                        request, context: context)
                },
                continueTurn: { pending, selectedID, context in
                    try await HallieTurnExecutor.continue(
                        pending: pending,
                        selecting: selectedID,
                        context: context)
                },
                mediaURLIsAvailable: { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: url.path, isDirectory: &isDirectory)
                        && !isDirectory.boolValue
                        && FileManager.default.isReadableFile(atPath: url.path)
                },
                tryPerformMediaAction: { action in
                    switch action {
                    case .play(let url):
                        return NSWorkspace.shared.open(url)
                    case .reveal(let url):
                        return NSWorkspace.shared.selectFile(
                            url.path, inFileViewerRootedAtPath: "")
                    }
                },
                performMediaAction: { action in
                    switch action {
                    case .play(let url): NSWorkspace.shared.open(url)
                    case .reveal(let url):
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                },
                recordTranscript: { events in
                    await HallieConversationRecorder.shared.append(events)
                },
                composeAnswer: { plan, history, options in
                    var template = OllamaQueryTranslator()
                    template.model = options.model
                    let fleet = OllamaFailoverTranslator(
                        hosts: options.hosts, template: template)
                    let composer = HallieGroundedComposer(
                        personaName: HallieCompositionSettings.personaName(),
                        modelCall: { system, user in
                            try await fleet.composePlainText(system: system, user: user)
                        })
                    return await composer.compose(plan: plan, history: history)
                })
        }
    }

    private final class LockedString: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?
        var value: String? { lock.withLock { storage } }
        func set(_ value: String) { lock.withLock { storage = value } }
    }

    static let usage = """
    Usage: VideoScan --hallie [--catalog PATH] [--host HOST[,HOST...]]
                     [--model MODEL] [--gedcom PATH] [--once QUESTION] [--compose]
    """

    static let help = """
    Commands: :help, :quit, :cancel, :session, :list, :select N, :play N, :reveal N,
              :photo, :open-photo, :reveal-photo
    Media opens only after an explicit :play or :reveal command.
    """

    static func parse(arguments: [String]) throws -> Options {
        var result = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--hallie" { index += 1; continue }
            if argument == "--compose" { result.compose = true; index += 1; continue }
            guard ["--catalog", "--host", "--model", "--gedcom", "--once"]
                .contains(argument) else { throw ParseError.unknownOption(argument) }
            guard index + 1 < arguments.count else {
                throw ParseError.missingValue(argument)
            }
            let value = arguments[index + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ParseError.emptyValue(argument) }
            switch argument {
            case "--catalog": result.catalogURL = URL(fileURLWithPath: value)
            case "--host":
                let hosts = OllamaEndpoints.parse(value)
                guard !hosts.isEmpty else { throw ParseError.emptyValue(argument) }
                result.hosts = hosts
            case "--model": result.model = value
            case "--gedcom": result.gedcomURL = URL(fileURLWithPath: value)
            case "--once": result.once = value
            default: break
            }
            index += 2
        }
        return result
    }

    static func route(_ ast: ArchivistQueryAST) -> Route {
        switch HallieTurnExecutor.route(ast) {
        case .presence: return .presence
        case .temporal: return .temporal
        case .aggregate: return .aggregate
        case .graph: return .graph
        case .cross: return .cross
        case .unsupportedEvent: return .unsupportedEvent
        case .followUp: return .followUp
        case .capability: return .capability
        case .help: return .help
        case .smalltalk: return .smalltalk
        case .reset: return .reset
        }
    }

    /// Runs without constructing VideoScanModel, CatalogStore, or a SwiftUI
    /// scene. The catalog is decoded once and never mutated or saved.
    static func run(
        options: Options,
        input: @escaping () -> String? = { readLine() },
        output: @escaping (String) -> Void = {
            print($0)
            fflush(stdout)
        },
        dependencies: Dependencies = .production
    ) async -> Int32 {
        output("Hallie Mae — headless read-only shell")
        output("opening catalog read-only: \(options.catalogURL.path)")
        guard let records = dependencies.loadCatalog(options.catalogURL) else {
            output("error: cannot read catalog at \(options.catalogURL.path)")
            return ExitCode.catalogUnavailable.rawValue
        }
        let profiles: [POIProfile]?
        switch dependencies.loadProfiles() {
        case .loaded(let values): profiles = values
        case .unavailable: profiles = nil
        }
        let graph = dependencies.loadGraph(options.gedcomURL)
        let cyberBrain = dependencies.loadCyberBrain()
        var state = Session(
            records: records,
            profiles: profiles,
            graph: graph,
            cyberBrain: cyberBrain,
            model: options.model)

        output("catalog: \(records.count) records · \(options.catalogURL.path)")
        if let once = options.once {
            let outcome = await answer(
                once, options: options, state: &state,
                output: output, dependencies: dependencies)
            return outcome.exitCode
        }
        output(help)
        while true {
            output("hallie> ")
            guard let raw = input() else { return 0 }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(":") {
                switch handleCommand(
                    line, state: &state, output: output,
                    dependencies: dependencies) {
                case .continueSession: break
                case .quit: return ExitCode.success.rawValue
                case .mediaFailure: return ExitCode.mediaUnavailable.rawValue
                }
                continue
            }
            _ = await answer(line, options: options, state: &state,
                             output: output, dependencies: dependencies)
        }
    }

    struct Session {
        struct PendingClarification {
            let value: HallieTurnExecutor.Clarification
            let context: HallieTurnExecutor.Context
        }

        let records: [VideoRecord]
        let profiles: [POIProfile]?
        let graph: GedcomFamilyGraph?
        let cyberBrain: CyberBrainIndex?
        let model: String
        let transcriptSessionID = UUID()
        var transcriptSequence: UInt64 = 0
        var presenceSnapshots: [ArchivistPresenceRecordSnapshot]?
        var aggregateSnapshots: [ArchivistAggregateRecordSnapshot]?
        var citations: [HallieTurnExecutor.Citation] = []
        var knowledgeCitations: [HallieTurnExecutor.KnowledgeCitation] = []
        var selectedRecordID: UUID?
        var biographyPhoto: ArchivistBiographyPhoto?
        var lastResponder = "none"
        var pendingClarification: PendingClarification?
        /// Conversation memory: the last result set / AST for follow-ups
        /// ("play the first one", "show more", "and in the 90s?").
        var memory = HallieTurnExecutor.ConversationMemory()
        /// Recent (question, displayed answer) pairs offered to the composer
        /// for continuity — text only, bounded.
        var history: [HallieGroundedComposer.HistoryTurn] = []

        mutating func remember(question: String, answer: String) {
            history.append(.init(user: question, assistant: answer))
            if history.count > HallieGroundedComposer.historyTurns {
                history.removeFirst(history.count - HallieGroundedComposer.historyTurns)
            }
        }

        func record(_ id: UUID) -> VideoRecord? { records.first { $0.id == id } }

        var identityContext: HallieTurnExecutor.Context {
            HallieTurnExecutor.Context(
                profiles: profiles?.map {
                    HallieTurnExecutor.ProfileSnapshot(
                        stableID: $0.id, canonicalName: $0.name,
                        aliases: $0.aliases, birthdate: $0.birthdate)
                },
                graph: graph,
                cyberBrain: cyberBrain)
        }
    }

    private static func answer(
        _ question: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        let userEvent = transcriptEvent(
            kind: .user, text: question, state: &state)
        await dependencies.recordTranscript([userEvent])
        if let pending = state.pendingClarification {
            return await continueClarification(
                question,
                pending: pending,
                options: options,
                state: &state,
                output: output,
                dependencies: dependencies)
        }
        do {
            state.biographyPhoto = nil
            // Model-free step first: capability questions, follow-ups on the
            // last answer, refinements, local family-tree shapes.
            let identity = state.identityContext
            let pre = HallieTurnExecutor.preTranslation(
                question: question,
                playAfterAnswer: false,
                memory: state.memory,
                isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: identity) })
            let intent: HallieTurnExecutor.Intent
            switch pre {
            case .answer(let result):
                state.lastResponder = "local"
                // "start over" clears memory; other local answers leave it.
                state.memory.record(intent: nil, result: result)
                output("interpreted: \(HallieTurnExecutor.label(result.route))")
                render(result, ast: nil, context: identity, state: &state,
                       output: output)
                state.remember(question: question, answer: result.prose)
                let outcome = performMediaAction(
                    result.mediaAction, output: output, dependencies: dependencies)
                let event = transcriptEvent(
                    result: result, responder: "local", state: &state)
                await dependencies.recordTranscript([event])
                if outcome == .mediaFailure { return .declined }
                switch result.outcome {
                case .answered: return .answered
                case .declined, .needsClarification: return .declined
                case .unsupported: return .unsupported
                }
            case .run(let local):
                state.lastResponder = "local"
                intent = local
                output("interpreted: \(HallieTurnExecutor.description(of: local.ast)) (local)")
            case .translate(let effectiveQuestion, let wantsPlay):
                // Anti-hallucination boundary: the translator receives exactly
                // the user's question. Catalog, profile, GEDCOM, and citations
                // stay local.
                output("Hallie is interpreting that question…")
                let translation = try await dependencies.translateAST(
                    effectiveQuestion, options)
                state.lastResponder = translation.responderHost
                output("interpreted: \(HallieTurnExecutor.description(of: translation.ast))")
                intent = HallieTurnExecutor.Intent(
                    originalQuestion: question,
                    ast: translation.ast,
                    playAfterAnswer: wantsPlay)
            }

            switch HallieTurnExecutor.route(intent.ast) {
            case .presence, .cross:
                if state.presenceSnapshots == nil {
                    state.presenceSnapshots = await ArchivistPresenceRecordSnapshot
                        .capture(state.records)
                }
            case .aggregate:
                if state.aggregateSnapshots == nil {
                    state.aggregateSnapshots = await ArchivistAggregateRecordSnapshot
                        .capture(state.records)
                }
            case .temporal, .graph, .unsupportedEvent, .followUp, .capability, .help, .smalltalk, .reset:
                break
            }

            let profiles = state.profiles?.map {
                HallieTurnExecutor.ProfileSnapshot(
                    stableID: $0.id,
                    canonicalName: $0.name,
                    aliases: $0.aliases,
                    birthdate: $0.birthdate)
            }
            let selectedDate = state.selectedRecordID
                .flatMap(state.record)
                .flatMap(temporalSelectionDate)
            let context = HallieTurnExecutor.Context(
                presenceRecords: state.presenceSnapshots ?? [],
                aggregateRecords: state.aggregateSnapshots ?? [],
                profiles: profiles,
                graph: state.graph,
                cyberBrain: state.cyberBrain,
                selectedTemporalDate: selectedDate,
                speakers: HallieTurnExecutor.Speakers.fromDefaults())
            let request = HallieTurnExecutor.Request(intent: intent)
            var result = try await dependencies.executeRequest(request, context)
            state.memory.record(intent: intent, result: result)
            result = await phrase(result, question: question, options: options,
                                  state: &state, dependencies: dependencies)

            render(
                result,
                ast: intent.ast,
                context: context,
                state: &state,
                output: output)
            output("interpreted by \(state.lastResponder)")
            state.remember(question: question, answer: result.prose)
            let assistantEvent = transcriptEvent(
                result: result,
                responder: state.lastResponder,
                state: &state)
            await dependencies.recordTranscript([assistantEvent])
            // "play donna at christmas": the search ran; now play the first
            // available citation, honestly reporting when none is.
            if intent.playAfterAnswer, result.outcome == .answered,
               result.clarification == nil, !result.citations.isEmpty {
                _ = performMediaAction(
                    .init(kind: .play, citations: result.citations),
                    output: output, dependencies: dependencies)
            }
            switch result.outcome {
            case .answered: return .answered
            case .declined: return .declined
            case .unsupported: return .unsupported
            case .needsClarification: return .declined
            }
        } catch {
            state.citations = []
            output("I couldn't safely interpret that question: \(error.localizedDescription)")
            output("No catalog query or media action was performed.")
            let event = transcriptEvent(
                kind: .error,
                text: "I couldn't safely interpret that question: "
                    + error.localizedDescription,
                basisLine: "No catalog query or media action was performed.",
                outcome: "interpretation-failed",
                state: &state)
            await dependencies.recordTranscript([event])
            return .interpretationFailed
        }
    }

    /// Plan → phrase → verify for the shell, only with `--compose` and only
    /// for composable plans; prints who phrased the answer.
    private static func phrase(
        _ result: HallieTurnExecutor.Result,
        question: String,
        options: Options,
        state: inout Session,
        dependencies: Dependencies
    ) async -> HallieTurnExecutor.Result {
        guard options.compose else { return result }
        let plan = HallieAnswerPlan.derive(from: result)
        guard plan.isComposable else { return result }
        let outcome = await dependencies.composeAnswer(plan, state.history, options)
        return result.applying(outcome)
    }

    private static func continueClarification(
        _ reply: String,
        pending: Session.PendingClarification,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        guard let selectedID = clarificationSelection(
            reply, from: pending.value.candidates) else {
            output("I need one of the listed names or numbers so I don't guess.")
            printClarification(pending.value, output: output)
            let event = transcriptEvent(
                kind: .assistant,
                text: "I need one of the listed names or numbers so I don't guess.",
                basisLine: "The reply did not select exactly one stable identity.",
                outcome: "needs-clarification",
                offeredActions: pending.value.candidates.map(\.label),
                state: &state)
            await dependencies.recordTranscript([event])
            return .declined
        }
        do {
            state.pendingClarification = nil
            var result = try await dependencies.continueTurn(
                pending.value, selectedID, pending.context)
            state.memory.record(intent: pending.value.intent, result: result)
            result = await phrase(result, question: reply, options: options,
                                  state: &state, dependencies: dependencies)
            state.remember(question: reply, answer: result.prose)
            render(
                result,
                ast: pending.value.intent.ast,
                context: pending.context,
                state: &state,
                output: output)
            let event = transcriptEvent(
                result: result,
                responder: state.lastResponder,
                state: &state)
            await dependencies.recordTranscript([event])
            switch result.outcome {
            case .answered: return .answered
            case .declined, .needsClarification: return .declined
            case .unsupported: return .unsupported
            }
        } catch {
            state.citations = []
            output("I couldn't continue that identity choice: \(error.localizedDescription)")
            output("No catalog query or media action was performed.")
            let event = transcriptEvent(
                kind: .error,
                text: "I couldn't continue that identity choice: "
                    + error.localizedDescription,
                basisLine: "No catalog query or media action was performed.",
                outcome: "interpretation-failed",
                state: &state)
            await dependencies.recordTranscript([event])
            return .interpretationFailed
        }
    }

    private static func clarificationSelection(
        _ reply: String,
        from candidates: [HallieTurnExecutor.Candidate]
    ) -> HallieTurnExecutor.CandidateID? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), candidates.indices.contains(number - 1) {
            return candidates[number - 1].id
        }
        let key = PersonResolver.normalize(trimmed)
        let matches = candidates.filter {
            PersonResolver.normalize($0.label) == key
                || PersonResolver.normalize($0.canonicalName) == key
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    private static func handleCommand(
        _ line: String,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) -> CommandOutcome {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        switch parts.first?.lowercased() {
        case ":quit", ":q": output("Goodbye."); return .quit
        case ":help": output(help)
        case ":cancel":
            if state.pendingClarification != nil {
                state.pendingClarification = nil
                output("Clarification cancelled; I won't guess.")
            } else {
                output("No clarification is pending.")
            }
        case ":session":
            let selected = state.selectedRecordID?.uuidString ?? "none"
            let pending = state.pendingClarification == nil ? "none" : "identity"
            output("session: \(state.citations.count) citations · selected \(selected) · responder \(state.lastResponder) · pending \(pending)")
        case ":photo":
            if let photo = state.biographyPhoto {
                output("photo: \(photo.fileURL.path)")
            } else {
                output("No biography photo is available for the last answer.")
            }
        case ":open-photo", ":reveal-photo":
            guard let photo = state.biographyPhoto else {
                output("No biography photo is available for the last answer.")
                return .mediaFailure
            }
            guard let verifiedURL = photo.revalidatedURL() else {
                state.biographyPhoto = nil
                output("The biography photo changed or is no longer a verified image.")
                return .mediaFailure
            }
            guard dependencies.mediaURLIsAvailable(verifiedURL) else {
                output("The biography photo is unavailable or unreadable; no media action was performed.")
                return .mediaFailure
            }
            let action: MediaAction = parts[0].lowercased() == ":open-photo"
                ? .play(verifiedURL) : .reveal(verifiedURL)
            guard dependencies.tryPerformMediaAction(action) else {
                output("The system refused the media action; nothing was opened.")
                return .mediaFailure
            }
            output(parts[0].lowercased() == ":open-photo"
                   ? "opening \(photo.fileURL.lastPathComponent)"
                   : "revealing \(photo.fileURL.lastPathComponent)")
        case ":list": printCitations(state.citations, output: output)
        case ":select", ":play", ":reveal":
            guard parts.count == 2, let number = Int(parts[1]),
                  state.citations.indices.contains(number - 1) else {
                output("No such citation. Use :list, then choose 1...\(state.citations.count).")
                return .continueSession
            }
            let citation = state.citations[number - 1]
            if parts[0].lowercased() == ":select" {
                state.selectedRecordID = citation.recordID
                output("selected \(number): \(citation.filename)")
            } else {
                let url = URL(fileURLWithPath: citation.fullPath)
                guard dependencies.mediaURLIsAvailable(url) else {
                    output("\(citation.filename) is unavailable or unreadable; no media action was performed.")
                    return .mediaFailure
                }
                let isPlay = parts[0].lowercased() == ":play"
                let action: MediaAction = isPlay ? .play(url) : .reveal(url)
                guard dependencies.tryPerformMediaAction(action) else {
                    output("The system refused to \(isPlay ? "open" : "reveal") \(citation.filename); no media action was completed.")
                    return .mediaFailure
                }
                output(isPlay
                    ? "opening \(citation.filename)"
                    : "revealing \(citation.filename)")
            }
        default: output("Unknown command. Type :help.")
        }
        return .continueSession
    }

    private static func temporalSelectionDate(
        _ record: VideoRecord
    ) -> ArchivistTemporalSelectionDateSnapshot? {
        if let inferred = record.inferredRecordDate {
            return .dossierInferred(
                recordID: record.id,
                fullPath: record.fullPath,
                date: inferred,
                confidence: record.inferredDateConfidence)
        }
        if let created = record.dateCreatedRaw {
            return .catalogCreation(
                recordID: record.id,
                fullPath: record.fullPath,
                date: created)
        }
        if let modified = record.dateModifiedRaw {
            return .fileModification(
                recordID: record.id,
                fullPath: record.fullPath,
                date: modified)
        }
        return nil
    }

    private static var defaultCatalogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("VideoScan/catalog.json")
    }

    /// The app's normal POI loader may perform a one-time legacy migration.
    /// A read-only shell must not do that implicitly, so enumerate and decode
    /// only the already-current POI folders without creating or rewriting
    /// anything.
    static func loadProfilesReadOnly(
        applicationSupportURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first,
        fileManager: FileManager = .default
    ) -> ProfileLoadResult {
        guard let applicationSupportURL else {
            return .unavailable(.applicationSupportUnavailable)
        }
        let root = applicationSupportURL
            .appendingPathComponent("VideoScan/POI", isDirectory: true)
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path, isDirectory: &rootIsDirectory) else {
            return .loaded([])
        }
        guard rootIsDirectory.boolValue else {
            return .unavailable(.directoryUnreadable(root.path))
        }

        let folders: [URL]
        do {
            folders = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            return .unavailable(.directoryUnreadable(root.path))
        }

        var profiles: [POIProfile] = []
        for folder in folders {
            // Directory enumeration may canonicalize /var to /private/var.
            // Diagnostics retain the caller's spelling so paths are stable
            // and directly comparable to the URL the caller supplied.
            let reportedFolder = root.appendingPathComponent(
                folder.lastPathComponent, isDirectory: true)
            let reportedProfileURL = reportedFolder
                .appendingPathComponent("profile.json")
            let isDirectory: Bool
            do {
                isDirectory = try folder.resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                return .unavailable(.directoryUnreadable(reportedFolder.path))
            }
            guard isDirectory else { continue }

            let profileURL = folder.appendingPathComponent("profile.json")
            let data: Data
            do {
                data = try Data(contentsOf: profileURL)
            } catch {
                return .unavailable(.profileUnreadable(reportedProfileURL.path))
            }
            var profile: POIProfile
            do {
                profile = try JSONDecoder().decode(POIProfile.self, from: data)
            } catch {
                return .unavailable(.profileCorrupt(reportedProfileURL.path))
            }
            profile.referencePath = folder.path
            profiles.append(profile)
        }

        return .loaded(profiles.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }
}
