// HallieShellCLI.swift
// Headless, read-only interactive access to Hallie's QueryAST-v2 pipeline.

import AppKit
import Foundation
import VideoScanCore

enum HallieShellCLI {
    struct Options: Equatable {
        var catalogURL: URL = defaultCatalogURL
        var hosts: [String] = OllamaEndpoints.defaultHosts
        var model = HallieBrain.defaultModel
        var gedcomURL: URL?
        var once: String?
        /// `--compose`: let the model phrase composable answers (verified,
        /// facts locked). OFF by default in the shell — it is a diagnostic
        /// surface and the templated wording is the reference output.
        var compose = false
        /// Print routes, evidence bases, responder hosts, full paths, and
        /// other QA metadata. Normal conversation keeps these in the log.
        var diagnostics = false
        /// `--remember`: let "let me tell you about …" write attributed,
        /// unverified passages to the family's CyberBrain. OFF by default:
        /// the shell is a read-only diagnostic surface and unattended
        /// evaluation corpora must never write into Rick's real knowledge
        /// file. Hallie still listens without it and says so at the end.
        var remember = false
        /// Hard safety gate for unattended evaluation. Answers still report
        /// the requested action, but no file is opened or revealed.
        var allowActions = true
        /// Optional label stamped onto every transcript event from this shell.
        var logRunID: String?
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
        case presence, temporal, aggregate, graph, cross, record
        case unsupportedEvent
        case followUp, capability
        case help, smalltalk, conversation, telling, reset
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

    enum AnswerOutcome {
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

    struct TurnInterpretation {
        let value: HallieTurnInterpretation
        let responderHost: String
    }

    struct SocialReply {
        let value: HallieSocialConversation.Reply
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
        /// Publish the read-only archive authority before GEDCOM/cards load.
        /// Injected as a no-op so unit tests never inspect the real catalog
        /// designation or mutate the process-wide presentation snapshot.
        var configureFamilyAssets: (Options) -> Void
        var loadProfiles: () -> ProfileLoadResult
        var loadGraph: (URL?) -> GedcomFamilyGraph?
        /// The pulls behind a compiled tree this version refused (live
        /// miss #8); consulted only when `loadGraph` returned nil for the
        /// default (promoted-artifact) path. Default = none.
        var loadNeedsRecompile: (URL?) -> [URL]
        var loadCyberBrain: () -> CyberBrainIndex?
        var translateAST: (String, Options) async throws -> Translation
        var interpretTurn: (String, Options) async throws -> TurnInterpretation
        var composeConversation: @Sendable (
            HallieConversationKind,
            String,
            [HallieGroundedComposer.HistoryTurn],
            Options
        ) async -> SocialReply
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
        /// Durably record one told passage and return the refreshed index.
        /// The default records nothing (nil) so tests and evaluation runs
        /// never touch the real CyberBrain; production writes through
        /// CyberBrainWriter only when `--remember` was given.
        var recordTestimony: (CyberBrainWriter.Testimony) throws -> CyberBrainIndex?
        /// Who "I" is, for attribution. Injected so tests never read prefs.
        var speakers: () -> HallieTurnExecutor.Speakers
        /// The name drill (2026-08-29): keep a taught pronunciation, and the
        /// sheet's load/save. Defaults record nothing and keep the sheet in
        /// memory; production writes only with `--remember`.
        var recordPronunciation: (HallieAppTurnCoordinator.PronunciationWrite) throws -> Void
        var loadDrillStore: () -> PronunciationDrillStore
        var saveDrillStore: (PronunciationDrillStore, PronunciationDrillManifest) throws -> Void
        var loadLexicon: () -> HalliePronunciationLexicon
        var loadPronunciationGold: () -> MisakiGoldLexicon

        init(
            loadCatalog: @escaping (URL) -> [VideoRecord]?,
            configureFamilyAssets: @escaping (Options) -> Void = { _ in },
            loadProfiles: @escaping () -> ProfileLoadResult,
            loadGraph: @escaping (URL?) -> GedcomFamilyGraph?,
            loadNeedsRecompile: @escaping (URL?) -> [URL] = { _ in [] },
            loadCyberBrain: @escaping () -> CyberBrainIndex? = { nil },
            translateAST: @escaping (String, Options) async throws -> Translation,
            interpretTurn: ((String, Options) async throws -> TurnInterpretation)? = nil,
            composeConversation: (@Sendable (
                HallieConversationKind,
                String,
                [HallieGroundedComposer.HistoryTurn],
                Options
            ) async -> SocialReply)? = nil,
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
            },
            recordTestimony: @escaping (CyberBrainWriter.Testimony) throws -> CyberBrainIndex? = { _ in nil },
            speakers: @escaping () -> HallieTurnExecutor.Speakers = {
                HallieTurnExecutor.Speakers.fromDefaults()
            },
            recordPronunciation: @escaping (HallieAppTurnCoordinator.PronunciationWrite) throws -> Void = { _ in },
            loadDrillStore: @escaping () -> PronunciationDrillStore = { PronunciationDrillStore() },
            saveDrillStore: @escaping (PronunciationDrillStore, PronunciationDrillManifest) throws -> Void = { _, _ in },
            loadLexicon: @escaping () -> HalliePronunciationLexicon = { .shipped },
            loadPronunciationGold: @escaping () -> MisakiGoldLexicon = { .empty }
        ) {
            self.recordTestimony = recordTestimony
            self.speakers = speakers
            self.recordPronunciation = recordPronunciation
            self.loadDrillStore = loadDrillStore
            self.saveDrillStore = saveDrillStore
            self.loadLexicon = loadLexicon
            self.loadPronunciationGold = loadPronunciationGold
            self.loadCatalog = loadCatalog
            self.configureFamilyAssets = configureFamilyAssets
            self.loadProfiles = loadProfiles
            self.loadGraph = loadGraph
            self.loadNeedsRecompile = loadNeedsRecompile
            self.loadCyberBrain = loadCyberBrain
            self.translateAST = translateAST
            self.interpretTurn = interpretTurn ?? { question, options in
                let translation = try await translateAST(question, options)
                return TurnInterpretation(
                    value: .archive(translation.ast),
                    responderHost: translation.responderHost)
            }
            self.composeConversation = composeConversation ?? {
                kind, question, history, _ in
                let reply = await HallieSocialConversation.reply(
                    kind: kind, question: question, history: history,
                    modelCall: { _, _ in
                        throw NLTranslatorError.unreachable(
                            "no social conversation model configured")
                    })
                return SocialReply(value: reply, responderHost: "local")
            }
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
                configureFamilyAssets: { configureFamilyAssetsReadOnly(options: $0) },
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
                    // Default path = the promoted artifact only, cached
                    // for the life of the shell process (codex #792).
                    return FamilyGraphSharedCache.shared.graph(
                        for: FamilyAssetConfigurationCenter.shared.snapshot(),
                        store: .production)
                },
                loadNeedsRecompile: { requested in
                    // An explicit --gedcom file or folder is parsed, never
                    // compiled: nothing to recompile there.
                    guard requested == nil else { return [] }
                    return FamilyGraphSharedCache.shared.needsRecompile(
                        for: FamilyAssetConfigurationCenter.shared.snapshot(),
                        store: .production)
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
                interpretTurn: { question, options in
                    let responder = LockedString()
                    var template = OllamaQueryTranslator()
                    template.model = options.model
                    let translator = OllamaFailoverTranslator(
                        hosts: options.hosts,
                        template: template,
                        onResponder: { responder.set($0) })
                    let value = try await translator.interpretTurn(question)
                    return TurnInterpretation(
                        value: value,
                        responderHost: responder.value ?? "unknown")
                },
                composeConversation: { kind, question, history, options in
                    let responder = LockedString()
                    var template = OllamaQueryTranslator()
                    template.model = options.model
                    let fleet = OllamaFailoverTranslator(
                        hosts: options.hosts,
                        template: template,
                        onResponder: { responder.set($0) })
                    let reply = await HallieSocialConversation.reply(
                        kind: kind, question: question, history: history,
                        modelCall: { system, user in
                            try await fleet.composePlainText(
                                system: system, user: user)
                        })
                    return SocialReply(
                        value: reply,
                        responderHost: reply.composedByModel
                            ? (responder.value ?? "unknown") : "local")
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
                },
                recordTestimony: { testimony in
                    guard let root = FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask).first?.appendingPathComponent(
                            "VideoScan/cyberbrain", isDirectory: true) else {
                        throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
                    }
                    let receipt = try CyberBrainWriter.record(testimony, rootURL: root)
                    return try CyberBrainIndex(archive: receipt.archive)
                },
                recordPronunciation: { write in
                    try HallieAppTurnCoordinator.recordPronunciationLive(write)
                },
                loadDrillStore: { PronunciationDrillStore.load() },
                saveDrillStore: { store, manifest in try store.save(manifest: manifest) },
                loadLexicon: {
                    HalliePronunciationLexicon.resolved(
                        allowDefaultWrite: !ViewerModeCenter.shared.isViewer)
                },
                loadPronunciationGold: { .shared })
        }
    }

    private final class LockedString: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?
        var value: String? { lock.withLock { storage } }
        func set(_ value: String) { lock.withLock { storage = value } }
    }

    /// Give the standalone shell the same immutable, read-only asset
    /// authority as the app without constructing `VideoScanModel`.
    /// Explicit GEDCOM paths inside the deployed archive layout win;
    /// otherwise the catalog's small deterministic header supplies the
    /// persisted Master Archive designation.
    static func configureFamilyAssetsReadOnly(options: Options) {
        if let explicitRoot = masterArchiveRoot(containingGEDCOM: options.gedcomURL) {
            FamilyAssetConfigurationCenter.shared.publish(
                masterArchiveRoot: explicitRoot,
                masterIsSafelyAvailable: FileManager.default.fileExists(
                    atPath: explicitRoot.path),
                readOnly: true)
            return
        }

        guard let designation = masterArchiveDesignation(
            catalogURL: options.catalogURL) else {
            FamilyAssetConfigurationCenter.shared.publish(
                masterArchiveRoot: nil,
                masterIsSafelyAvailable: true,
                readOnly: true)
            return
        }
        let root = URL(fileURLWithPath: designation.rootPath, isDirectory: true)
        let online = FileManager.default.fileExists(atPath: root.path)
        let identityMatches: Bool
        if let expected = designation.volumeUUID {
            identityMatches = MasterArchiveDesignation.volumeUUID(
                forPath: designation.targetPath) == expected
        } else {
            identityMatches = true
        }
        FamilyAssetConfigurationCenter.shared.publish(
            masterArchiveRoot: root,
            masterIsSafelyAvailable: online && identityMatches,
            readOnly: true)
    }

    /// Recognize only `<Master>/40_Family_Tree/GEDCOM[/file.ged]`.
    /// An arbitrary user-supplied GEDCOM remains usable for relationships,
    /// but cannot confer authority over neighboring files as rich media.
    static func masterArchiveRoot(containingGEDCOM requested: URL?) -> URL? {
        guard let requested else { return nil }
        let resolved = requested.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolved.path, isDirectory: &isDirectory)
        let gedcomDirectory = exists && isDirectory.boolValue
            ? resolved : resolved.deletingLastPathComponent()
        guard gedcomDirectory.lastPathComponent == "GEDCOM" else { return nil }
        let familyTree = gedcomDirectory.deletingLastPathComponent()
        guard familyTree.lastPathComponent == "40_Family_Tree" else { return nil }
        let master = familyTree.deletingLastPathComponent()
        return master.pathComponents.count > 1 ? master : nil
    }

    /// Current catalog writers put metadata before the large records array.
    /// Decode only that bounded header instead of allocating a second copy
    /// of thousands of `VideoRecord`s during shell startup.
    static func masterArchiveDesignation(
        catalogURL: URL,
        probeBytes: Int = CatalogSnapshot.probeWindowBytes
    ) -> MasterArchiveDesignation? {
        guard probeBytes > 0,
              let handle = try? FileHandle(forReadingFrom: catalogURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: probeBytes),
              let marker = data.range(of: Data(",\"records\":".utf8)) else {
            return nil
        }
        var header = data[..<marker.lowerBound]
        header.append(0x7D) // `}` closes the bounded top-level header.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CatalogSnapshot.self, from: Data(header)))?
            .masterArchive
    }

    static let usage = """
    Usage: VideoScan --hallie [--catalog PATH] [--host HOST[,HOST...]]
                     [--model MODEL] [--gedcom PATH] [--once QUESTION] [--compose]
                     [--no-actions] [--log-run-id ID] [--remember] [--diagnostics]
    """

    static let help = """
    Commands: :help, :quit, :cancel, :reset, :session, :list, :select N, :select <filename>,
              :play N, :reveal N,
              :photo, :open-photo, :reveal-photo
    :reset forgets the current conversation and starts a new logged session.
    Say "let me tell you about <someone>" and Hallie listens and remembers
    (saved to the family CyberBrain only with --remember).
    """

    static func parse(arguments: [String]) throws -> Options {
        var result = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--hallie" { index += 1; continue }
            if argument == "--compose" { result.compose = true; index += 1; continue }
            if argument == "--diagnostics" {
                result.diagnostics = true
                index += 1
                continue
            }
            if argument == "--no-actions" {
                result.allowActions = false
                index += 1
                continue
            }
            if argument == "--remember" { result.remember = true; index += 1; continue }
            guard ["--catalog", "--host", "--model", "--gedcom", "--once",
                   "--log-run-id"]
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
            case "--log-run-id": result.logRunID = value
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
        case .record: return .record
        case .unsupportedEvent: return .unsupportedEvent
        case .followUp: return .followUp
        case .capability: return .capability
        case .help: return .help
        case .smalltalk: return .smalltalk
        case .conversation: return .conversation
        case .telling: return .telling
        case .reset: return .reset
        }
    }

    /// Runs without constructing VideoScanModel, CatalogStore, or a SwiftUI
    /// scene. The catalog is decoded once and never mutated or saved.
    static func run(
        options: Options,
        input: (() -> String?)? = nil,
        output: @escaping (String) -> Void = {
            print($0)
            fflush(stdout)
        },
        dependencies: Dependencies = .production
    ) async -> Int32 {
        output(options.diagnostics
            ? "Hallie Mae — headless read-only shell"
            : "Hallie Mae — standalone family librarian")
        if options.diagnostics {
            output("opening catalog read-only: \(options.catalogURL.path)")
        }
        guard let records = dependencies.loadCatalog(options.catalogURL) else {
            output("error: cannot read catalog at \(options.catalogURL.path)")
            return ExitCode.catalogUnavailable.rawValue
        }
        dependencies.configureFamilyAssets(options)
        let profiles: [POIProfile]?
        switch dependencies.loadProfiles() {
        case .loaded(let values): profiles = values
        case .unavailable: profiles = nil
        }
        let graph = dependencies.loadGraph(options.gedcomURL)
        let needsRecompile = graph == nil ? dependencies.loadNeedsRecompile(options.gedcomURL) : []
        let cyberBrain = dependencies.loadCyberBrain()
        var state = Session(
            records: records,
            profiles: profiles,
            graph: graph,
            needsRecompile: needsRecompile,
            cyberBrain: cyberBrain,
            speakers: dependencies.speakers(),
            model: options.model,
            runID: options.logRunID)

        if options.diagnostics {
            output("catalog: \(records.count) records · \(options.catalogURL.path)")
            if let runID = state.runID { output("run-id: \(runID)") }
            output("session-id: \(state.transcriptSessionID.uuidString)")
        } else {
            output("Archive ready — \(records.count) catalog items, read-only.")
        }
        if !options.allowActions {
            output(options.diagnostics
                ? "actions: disabled (--no-actions); no media will be opened or revealed"
                : "Media actions are off.")
        }
        if let once = options.once {
            let outcome = await answer(
                once, options: options, state: &state,
                output: output, dependencies: dependencies)
            return outcome.exitCode
        }
        output(options.diagnostics
            ? help
            : "Type :help for commands; :quit to leave.")
        var terminalInput = HallieTerminalLineReader()
        while true {
            let raw: String?
            if let input {
                output("hallie> ")
                raw = input()
            } else {
                raw = terminalInput.readLine(prompt: "hallie> ")
            }
            guard let raw else { return 0 }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(":") {
                switch await handleCommand(
                    line, options: options, state: &state, output: output,
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
        /// Live miss #8: the refused generation's pulls when `graph` is nil
        /// only because this version refused it; empty otherwise.
        var needsRecompile: [URL] = []
        /// Rebuilt after every testimony write so "tell me about Dad Breen"
        /// answers from what was just said.
        var cyberBrain: CyberBrainIndex?
        /// Captured once from the injected dependency. Every turn and render
        /// in this session uses the same identity; process defaults are never
        /// consulted again.
        let speakers: HallieTurnExecutor.Speakers
        let model: String
        var runID: String?
        var transcriptSessionID = UUID()
        var transcriptSequence: UInt64 = 0
        var presenceSnapshots: [ArchivistPresenceRecordSnapshot]?
        var aggregateSnapshots: [ArchivistAggregateRecordSnapshot]?
        var citations: [HallieTurnExecutor.Citation] = []
        var knowledgeCitations: [HallieTurnExecutor.KnowledgeCitation] = []
        var selectedRecordID: UUID?
        var biographyPhoto: ArchivistBiographyPhoto?
        var lastResponder = "none"
        var pendingClarification: PendingClarification?
        /// Non-nil while a family member is telling Hallie about someone.
        var telling: HallieTellingMode.Session?
        /// Non-nil while the name drill runs ("let's practice names").
        var drill: HalliePronunciationDrillMode.Session?
        /// Non-nil while the variations picker has a numbered list up.
        var picker: HalliePronunciationPicker.Offer?
        /// No-`--remember` teaches live here for this interactive session.
        /// This layer is never written and is discarded by `:reset`.
        var transientPronunciations: [HalliePronunciationLexicon.Entry] = []
        /// Catalog-wide numbers, computed once per session on first use.
        var catalogStats: HallieCatalogStats?
        /// Conversation memory: the last result set / AST for follow-ups
        /// ("play the first one", "show more", "and in the 90s?").
        var memory = HallieTurnExecutor.ConversationMemory()
        /// Recent (question, displayed answer) pairs offered to the composer
        /// for continuity — text only, bounded.
        var history: [HallieGroundedComposer.HistoryTurn] = []
        /// Only conversation-lane turns. Archive answers never enter the
        /// free-text social prompt, and social text never enters a factual
        /// composition prompt.
        var socialHistory: [HallieGroundedComposer.HistoryTurn] = []

        mutating func remember(question: String, answer: String) {
            history.append(.init(user: question, assistant: answer))
            if history.count > HallieGroundedComposer.historyTurns {
                history.removeFirst(history.count - HallieGroundedComposer.historyTurns)
            }
        }

        mutating func rememberSocial(question: String, answer: String) {
            socialHistory.append(.init(user: question, assistant: answer))
            if socialHistory.count > HallieSocialConversation.maximumHistoryTurns {
                socialHistory.removeFirst(
                    socialHistory.count - HallieSocialConversation.maximumHistoryTurns)
            }
        }

        func record(_ id: UUID) -> VideoRecord? { records.first { $0.id == id } }

        func pronunciationLexicon(base: HalliePronunciationLexicon) -> HalliePronunciationLexicon {
            HalliePronunciationLexicon.merged([
                HalliePronunciationLexicon(entries: transientPronunciations),
                base,
            ])
        }

        mutating func rememberPronunciation(
            word: String,
            spoken: String,
            phonemes: String?,
            origin: String
        ) {
            let key = FamilyIdentityText.normalized(word)
            transientPronunciations.removeAll {
                FamilyIdentityText.normalized($0.written) == key
            }
            transientPronunciations.insert(
                .init(written: word, spoken: spoken, phonemes: phonemes, origin: origin),
                at: 0)
        }

        var identityContext: HallieTurnExecutor.Context {
            HallieTurnExecutor.Context(
                profiles: profiles?.map {
                    HallieTurnExecutor.ProfileSnapshot(
                        stableID: $0.id, canonicalName: $0.name,
                        aliases: $0.aliases, birthdate: $0.birthdate, note: $0.notes,
                        kinships: $0.kinships, sex: $0.sex, uuid: $0.uuid,
                        treeIdentity: $0.treeIdentity, deathdate: $0.deathdate)
                },
                graph: graph,
                needsRecompile: needsRecompile,
                cyberBrain: cyberBrain,
                // Same captured owner binding the full path uses (2026-08-22):
                // "trace the family back to Ireland" needs to know whose family.
                speakers: speakers)
        }
    }

    static func answer(
        _ question: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies,
        recordUserTurn: Bool = true
    ) async -> AnswerOutcome {
        // The transcript pairs each assistant turn with the most recent
        // user turn by text (scripts/hallie_eval.py). A split question
        // records the FULL line here, once; each clause below passes
        // `recordUserTurn: false`, so the transcript reads
        //   user(full question), assistant(clause 1), assistant(clause 2)
        // and the harness can find its own question again.
        if recordUserTurn {
            let userEvent = transcriptEvent(
                kind: .user, text: question, state: &state)
            await dependencies.recordTranscript([userEvent])
        }

        // CONJUNCTION (Rick, 2026-09-01). "who was Martha Lamson and do we
        // have any videos of her" is two questions; the AST holds one shape,
        // so today one clause silently wins and the other is discarded.
        // HallieQuestionSplitter returns nil for everything it is not sure
        // about, so this fires only on a genuine cross-shape conjunction.
        //
        // Recursing through `answer` on purpose: the second clause then runs
        // against the conversation memory the FIRST clause just wrote, so a
        // pronoun the splitter could not bind statically still finds a
        // subject. Termination is safe — split() returns nil for a single
        // question, so a clause never splits again.
        //
        // Set VIDEOSCAN_HALLIE_SPLIT=0 to compare against the old behaviour
        // without rebuilding (HallieQuestionSplitter.isEnabled — the same
        // switch the chat window and the web bridge consult).
        if HallieQuestionSplitter.isEnabled,
           let clauses = HallieQuestionSplitter.split(question) {
            var outcome: AnswerOutcome = .declined
            for clause in clauses {
                outcome = await answer(clause, options: options, state: &state,
                                       output: output, dependencies: dependencies,
                                       recordUserTurn: false)
                // A which-one is pending: the next clause would be consumed
                // as a REPLY to it ("who is Tim's brother and how old is
                // Tim" → "Which tim do you mean?" → "I need one of the
                // listed names or numbers", eval 2026-09-01). Stop here —
                // the reader's choice resumes only this clause. Same rule
                // as the chat window's askLocally and the web bridge.
                if state.pendingClarification != nil { break }
            }
            return outcome
        }
        // A reset is a control-plane turn, not modal input. Detect it before
        // the picker / drill / telling owners: otherwise "start over" can be
        // consumed as a drill correction or as the end of a telling session.
        // Other finish words ("stop", "that's all") remain modal turns.
        if ArchivistConversationCommand.detect(question) == .reset {
            return await completeLocalAnswer(
                HallieTurnExecutor.commandResult(.reset),
                question: question,
                identity: state.identityContext,
                options: options,
                state: &state,
                output: output,
                dependencies: dependencies)
        }
        // The variations picker owns a number / "none of these" while its
        // list is up, and "say Latta a few ways" opens it (HallieShellCLI+Picker).
        if let outcome = await pickerTurn(
                question, options: options, state: &state,
                output: output, dependencies: dependencies) {
            return outcome
        }
        // The name drill owns the turn while it runs; a question steps out
        // of it and is answered below (HallieShellCLI+Drill).
        if let outcome = await drillTurn(
                question, options: options, state: &state,
                output: output, dependencies: dependencies) {
            return outcome
        }
        // "pronounce X like Y", hints, and "how do you say X" are answered
        // from the lexicon (HallieShellCLI+Pronunciation) — never searched.
        if let outcome = await pronunciationTurn(
                question, options: options, state: &state,
                output: output, dependencies: dependencies) {
            return outcome
        }
        // Listening comes first: while someone is telling Hallie about a
        // person, every turn is theirs to classify (a statement to keep,
        // "that's all", or a question that ends the telling). An explicit
        // "let me tell you about …" also wins over a pending clarification.
        if state.telling != nil,
           let outcome = await continueTelling(
                question, options: options, state: &state,
                output: output, dependencies: dependencies) {
            return outcome
        }
        if let opening = HallieTellingMode.detectOpening(question) {
            state.pendingClarification = nil
            return await beginTelling(
                opening, options: options, state: &state,
                output: output, dependencies: dependencies)
        }
        if let pending = state.pendingClarification {
            // A discriminator that fits several of the choices narrows the
            // list; one that fits nobody is said and the same question
            // stays open (same wording as the chat window, 2026-08-29).
            switch HallieTurnExecutor.clarificationReply(question, from: pending.value.candidates) {
            case .narrowed(let subset, let discriminator):
                let narrowed = pending.value.narrowed(to: subset) ?? pending.value
                state.pendingClarification = Session.PendingClarification(
                    value: narrowed, context: pending.context)
                return await reaskClarification(
                    narrowed,
                    preface: HallieTurnExecutor.narrowedClarificationPreface(
                        count: narrowed.candidates.count, discriminator: discriminator),
                    state: &state, output: output, dependencies: dependencies)
            case .unmatched(let discriminator):
                return await reaskClarification(
                    pending.value,
                    preface: HallieTurnExecutor.unmatchedClarificationPreface(discriminator),
                    state: &state, output: output, dependencies: dependencies)
            case .selected, .notASelection:
                break
            }
            // A clarifying question must expire when the person changes the
            // subject. Before this, a pending clarification was cleared only
            // by :cancel, so one "which Tim did you mean?" swallowed every
            // later turn — 25 in a row in the 2026-08-21 eval. The selector
            // below is still THE selector; the policy only decides what a
            // NON-selection means (ask again vs follow the person).
            let decision = HallieClarificationPolicy.decide(
                reply: question,
                candidates: pending.value.candidates.map(\.label),
                select: { reply in
                    clarificationSelection(reply, from: pending.value.candidates)
                        .map(String.init(describing:))
                })
            if HallieRepairTurn.isRepair(question) {
                // A complaint about the which-one list itself ("those people
                // are from the 1300s"): the question stays pending and the
                // repair reply (pre-translation) re-asks it, narrowed; a
                // typed name / year / number afterwards still selects.
            } else if decision == .abandon {
                state.pendingClarification = nil
                output(HallieClarificationPolicy.abandonNote)
                // fall through: answer THIS question as a fresh turn
            } else {
                return await continueClarification(
                    question,
                    pending: pending,
                    options: options,
                    state: &state,
                    output: output,
                    dependencies: dependencies)
            }
        }
        let repair = HallieSpellingRecovery.repairRequestOpener(question)
        let routingQuestion = repair.text
        if let original = repair.originalWord,
           let replacement = repair.replacementWord {
            appLog.write(
                "Hallie shell: repaired request opener “\(original)” → “\(replacement)”")
            if options.diagnostics {
                output("corrected: \(original) → \(replacement)")
            }
        }
        do {
            state.biographyPhoto = nil
            // Model-free step first: capability questions, follow-ups on the
            // last answer, refinements, local family-tree shapes.
            let identity = state.identityContext
            if HallieCatalogStats.detect(routingQuestion) != nil, state.catalogStats == nil {
                state.catalogStats = HallieCatalogStats.compute(records: state.records)
            }
            // The selected row and its resolved date, captured once for the
            // whole turn (the pre-translation lane and the executor context
            // must agree on which date "this" is).
            let selectedRecord = state.selectedRecordID.flatMap(state.record)
            let selectedDate = selectedRecord.flatMap(temporalSelectionDate)
            let pre = HallieTurnExecutor.preTranslation(
                question: routingQuestion,
                playAfterAnswer: false,
                memory: state.memory,
                isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: identity) },
                catalogStats: state.catalogStats,
                rosterAnswer: { HallieTurnExecutor.PeopleTab.rosterAnswer(context: identity) },
                lineageAnswer: { HallieLineageAnswer.answer($0, context: identity) },
                relationshipsOverview: { HallieRelationshipsOverview.answer($0, context: identity) },
                researchAnswer: { HallieResearchQuestion.answer($0, context: identity) },
                selectedRecord: selectedRecord.map {
                    HallieTurnExecutor.SelectedRecord(recordID: $0.id, date: selectedDate)
                })
            let intent: HallieTurnExecutor.Intent
            switch pre {
            case .answer(let result):
                return await completeLocalAnswer(
                    result,
                    question: question,
                    identity: identity,
                    options: options,
                    state: &state,
                    output: output,
                    dependencies: dependencies)
            case .run(let local):
                state.lastResponder = "local"
                intent = local
                if options.diagnostics {
                    output("interpreted: \(HallieTurnExecutor.description(of: local.ast)) (local)")
                }
            case .translate(let effectiveQuestion, let wantsPlay):
                // Anti-hallucination boundary: the translator receives exactly
                // the user's question. Catalog, profile, GEDCOM, and citations
                // stay local.
                output(options.diagnostics
                    ? "Hallie is interpreting that question…"
                    : "Hallie is thinking…")
                let interpretation: TurnInterpretation
                if let kind = HallieConversationGuard.definitelyGeneral(
                    effectiveQuestion,
                    isKnownPerson: {
                        HallieTurnExecutor.isKnownPerson($0, context: identity)
                    }) {
                    interpretation = TurnInterpretation(
                        value: .conversation(kind), responderHost: "local")
                } else {
                    interpretation = try await dependencies.interpretTurn(
                        effectiveQuestion, options)
                }
                switch interpretation.value {
                case .archive(let ast):
                    state.lastResponder = interpretation.responderHost
                    if options.diagnostics {
                        output("interpreted: \(HallieTurnExecutor.description(of: ast))")
                    }
                    intent = HallieTurnExecutor.Intent(
                        originalQuestion: question,
                        ast: ast,
                        playAfterAnswer: wantsPlay)

                case .conversation(let kind):
                    // A model classification never gets the last word on the
                    // safety boundary. Known people and archive language are
                    // retranslated with the archive-only schema.
                    if HallieConversationGuard.requiresArchive(
                        effectiveQuestion,
                        kind: kind,
                        isKnownPerson: {
                            HallieTurnExecutor.isKnownPerson($0, context: identity)
                        }) {
                        let translation = try await dependencies.translateAST(
                            effectiveQuestion, options)
                        state.lastResponder = translation.responderHost
                        if options.diagnostics {
                            output("interpreted: \(HallieTurnExecutor.description(of: translation.ast))")
                        }
                        intent = HallieTurnExecutor.Intent(
                            originalQuestion: question,
                            ast: translation.ast,
                            playAfterAnswer: wantsPlay)
                    } else {
                        let social = await dependencies.composeConversation(
                            kind, routingQuestion, state.socialHistory, options)
                        state.lastResponder = social.responderHost
                        let result = HallieSocialConversation.result(for: social.value)
                        state.memory.record(intent: nil, result: result)
                        if options.diagnostics { output("interpreted: conversation") }
                        render(result, ast: nil, context: identity, state: &state,
                               diagnostics: options.diagnostics, output: output)
                        if options.diagnostics {
                            output("interpreted by \(state.lastResponder)")
                        }
                        state.rememberSocial(
                            question: question, answer: result.prose)
                        let event = transcriptEvent(
                            result: result,
                            responder: state.lastResponder,
                            state: &state)
                        await dependencies.recordTranscript([event])
                        return .answered
                    }
                }
            }

            var recordScope: HallieTurnExecutor.RecordScope = .noSelection
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
            case .record:
                // ONE record, resolved here (selection or named file); the
                // executor never sees the catalog. No catalog-wide snapshot.
                recordScope = await captureRecordScope(
                    for: intent.ast, question: intent.originalQuestion, state: state)
            case .temporal, .graph, .unsupportedEvent, .followUp, .capability,
                 .help, .smalltalk, .conversation, .telling, .reset:
                break
            }

            let profiles = state.profiles?.map {
                HallieTurnExecutor.ProfileSnapshot(
                    stableID: $0.id,
                    canonicalName: $0.name,
                    aliases: $0.aliases,
                    birthdate: $0.birthdate, note: $0.notes,
                    kinships: $0.kinships, sex: $0.sex, uuid: $0.uuid,
                    treeIdentity: $0.treeIdentity, deathdate: $0.deathdate)
            }
            let context = HallieTurnExecutor.Context(
                presenceRecords: state.presenceSnapshots ?? [],
                aggregateRecords: state.aggregateSnapshots ?? [],
                profiles: profiles,
                graph: state.graph,
                needsRecompile: state.needsRecompile,
                cyberBrain: state.cyberBrain,
                selectedTemporalDate: selectedDate,
                recordScope: recordScope,
                speakers: state.speakers)
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
                diagnostics: options.diagnostics,
                output: output)
            if options.diagnostics {
                output("interpreted by \(state.lastResponder)")
            }
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
                    output: output, dependencies: dependencies,
                    allowActions: options.allowActions)
            }
            switch result.outcome {
            case .answered, .repaired: return .answered
            case .declined: return .declined
            case .unsupported: return .unsupported
            case .needsClarification: return .declined
            case .failed: return .declined   // a save that did not happen is not an answer
            }
        } catch {
            state.citations = []
            let diagnostic = String(reflecting: error)
            appLog.write("Hallie shell interpretation failed — \(diagnostic)")
            let message = HallieHelperFailure.message(for: error)
            output(message)
            if options.diagnostics
                || ProcessInfo.processInfo.environment["HALLIE_DEBUG_ERRORS"] == "1" {
                output("diagnostic: \(diagnostic)")
            }
            let event = transcriptEvent(
                kind: .error,
                text: message,
                basisLine: HallieHelperFailure.basisLine,
                outcome: "interpretation-failed",
                state: &state)
            await dependencies.recordTranscript([event])
            return .interpretationFailed
        }
    }

    private static func completeLocalAnswer(
        _ result: HallieTurnExecutor.Result,
        question: String,
        identity: HallieTurnExecutor.Context,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        state.lastResponder = "local"
        // "start over" clears memory; other local answers leave it.
        state.memory.record(intent: nil, result: result, question: question)
        if options.diagnostics {
            output("interpreted: \(HallieTurnExecutor.label(result.route))")
        }
        render(result, ast: nil, context: identity, state: &state,
               diagnostics: options.diagnostics, output: output)
        state.remember(question: question, answer: result.prose)
        if result.route == .smalltalk || result.route == .conversation {
            state.rememberSocial(question: question, answer: result.prose)
        }
        if result.route == .reset { clearConversation(&state) }
        let outcome = performMediaAction(
            result.mediaAction, output: output,
            dependencies: dependencies,
            allowActions: options.allowActions)
        let event = transcriptEvent(
            result: result, responder: "local", state: &state)
        await dependencies.recordTranscript([event])
        if outcome == .mediaFailure { return .declined }
        switch result.outcome {
        case .answered, .repaired: return .answered
        case .declined, .needsClarification, .failed: return .declined
        case .unsupported: return .unsupported
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
        // The typed plan is the complete factual context. Conversation
        // history is intentionally excluded so uncited social prose cannot
        // bleed into a catalog/tree answer.
        let outcome = await dependencies.composeAnswer(plan, [], options)
        // Parity with the app: the same verifier/coverage lines go to
        // stderr so a shell run can be diffed against the app log.
        for line in HallieGroundedComposer.droppedLogLines(outcome.dropped, plan: plan)
            + HallieGroundedComposer.verifyLogLines(outcome, plan: plan) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
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
                diagnostics: options.diagnostics,
                output: output)
            let event = transcriptEvent(
                result: result,
                responder: state.lastResponder,
                state: &state)
            await dependencies.recordTranscript([event])
            switch result.outcome {
            case .answered, .repaired: return .answered
            case .declined, .needsClarification, .failed: return .declined
            case .unsupported: return .unsupported
            }
        } catch {
            state.citations = []
            let diagnostic = String(reflecting: error)
            appLog.write("Hallie shell continuation failed — \(diagnostic)")
            output("I couldn't continue that choice just now. Please try again.")
            if options.diagnostics
                || ProcessInfo.processInfo.environment["HALLIE_DEBUG_ERRORS"] == "1" {
                output("diagnostic: \(diagnostic)")
            }
            let event = transcriptEvent(
                kind: .error,
                text: "I couldn't continue that choice just now. Please try again.",
                basisLine: "No catalog query or media action was performed.",
                outcome: "interpretation-failed",
                state: &state)
            await dependencies.recordTranscript([event])
            return .interpretationFailed
        }
    }

    /// Re-ask the pending which-one with a preface, transcribed like any
    /// other clarification turn. No continuation runs.
    private static func reaskClarification(
        _ clarification: HallieTurnExecutor.Clarification,
        preface: String,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        let text = preface + "Which person do you mean?"
        output(text)
        printClarification(clarification, output: output)
        let event = transcriptEvent(
            kind: .assistant,
            text: text,
            basisLine: "The reply did not select exactly one stable identity.",
            outcome: "needs-clarification",
            offeredActions: clarification.candidates.map(\.label),
            state: &state)
        await dependencies.recordTranscript([event])
        return .declined
    }

    private static func clarificationSelection(
        _ reply: String,
        from candidates: [HallieTurnExecutor.Candidate]
    ) -> HallieTurnExecutor.CandidateID? {
        // Shared matcher: numbers, exact names, "born in 1785", older/
        // younger, ordinals (HallieClarificationReply.swift).
        HallieTurnExecutor.clarificationSelection(reply, from: candidates)
    }

    private static func handleCommand(
        _ line: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> CommandOutcome {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        switch parts.first?.lowercased() {
        case ":quit", ":q": output("Goodbye."); return .quit
        case ":help": output(help)
        case ":reset":
            let event = resetSession(&state)
            output("reset: conversation forgotten")
            if options.diagnostics {
                output("session-id: \(state.transcriptSessionID.uuidString)")
            }
            await dependencies.recordTranscript([event])
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
            let voice = HallieNeuralSpeechDiagnostics.shared.snapshot()
            output("session: \(state.transcriptSessionID.uuidString) · \(state.citations.count) citations · selected \(selected) · responder \(state.lastResponder) · pending \(pending) · neural failures \(voice.failureCount) · retry recoveries \(voice.retryRecoveryCount)")
            if let detail = voice.lastFailure {
                output("neural voice last failure: \(detail)")
            }
        case ":photo":
            if let photo = state.biographyPhoto {
                output("photo: \(photo.fileURL.path)")
            } else {
                output("No biography photo is available for the last answer.")
            }
        case ":open-photo", ":reveal-photo":
            guard options.allowActions else {
                output(actionsDisabledNotice)
                return .continueSession
            }
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
        case ":select" where parts.count >= 2 && Int(parts[1]) == nil:
            // ":select Christmas_1994_etc.mkv" — by filename fragment, not
            // by citation number, so a harness (or a person who knows the
            // file) can select without asking first. Mirrors ":select N":
            // the only state the numeric form sets is selectedRecordID; the
            // temporal date is derived from it on every turn.
            let needle = parts.dropFirst().joined(separator: " ")
            guard let match = selectRecord(matchingFilename: needle, in: state.records) else {
                output("no file matches “\(needle)”")
                return .continueSession
            }
            state.selectedRecordID = match.id
            output("selected \(match.filename) (\(catalogYear(of: match).map(String.init) ?? "undated"))")
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
            } else if !options.allowActions {
                output("\(actionsDisabledNotice) (\(citation.filename))")
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

    static let actionsDisabledNotice =
        "media actions are disabled (--no-actions); nothing was opened"

    static func clearConversation(_ state: inout Session) {
        state.citations = []
        state.knowledgeCitations = []
        state.selectedRecordID = nil
        state.biographyPhoto = nil
        state.pendingClarification = nil
        state.telling = nil
        state.drill = nil
        state.picker = nil
        state.transientPronunciations = []
        state.memory.reset()
        state.history = []
        state.socialHistory = []
        state.lastResponder = "none"
    }

    static func resetSession(_ state: inout Session) -> HallieTranscriptEvent {
        clearConversation(&state)
        state.transcriptSessionID = UUID()
        state.transcriptSequence = 0
        return transcriptEvent(
            kind: .system,
            text: ":reset",
            basisLine: "Conversation memory, citations, history, and active modes cleared.",
            state: &state)
    }

    /// The record `:select <text>` means: the resolver's exact tiers first
    /// (full path, filename, stem, unique whole-token match — the same
    /// rules a question's file name gets, 2026-09-02), then the original
    /// FIRST-substring rule as the last fallback so every corpus `select`
    /// value written for it ("christmas_1994", "xmas") still selects the
    /// same file. An ambiguous exact tier also falls back to the substring
    /// rule: `:select` is a harness command and must stay deterministic.
    static func selectRecord(
        matchingFilename needle: String,
        in records: [VideoRecord]
    ) -> VideoRecord? {
        let key = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if case .resolved(let record) = ArchivistRecordReferenceResolver.resolve(
            file: needle, in: records) {
            return record
        }
        return records.first { $0.filename.lowercased().contains(key) }
    }

    /// The year the Catalog shows for a record (RecordDateResolver: user
    /// date, embedded date, dossier inference, filename) — NOT the catalog
    /// creation stamp, which for a transcode is the transcode's date.
    static func catalogYear(of record: VideoRecord) -> Int? {
        let resolution = RecordDateResolver.resolve(
            userDate: record.userDate,
            userDateConfidence: record.userDateConfidence,
            embeddedCreationDate: record.embeddedCreationDate,
            originMake: record.originMake,
            originModel: record.originModel,
            originEncoder: record.originEncoder,
            inferredRecordDate: record.inferredRecordDate,
            inferredDateConfidence: record.inferredDateConfidence,
            filename: record.filename.isEmpty ? nil : record.filename)
        guard resolution.precision <= .year else { return nil }
        return resolution.year
    }

    /// The selected record's date for temporal questions: the Catalog's
    /// shared ranking (RecordDateResolver — the year `:select` prints)
    /// first, the legacy inference/stamp chain only when it has nothing.
    /// Until 2026-09-01 this preferred the catalog creation stamp, which
    /// for a transcode is the transcode's date ("how old is Donna" → 66).
    /// The record scope for a `record` turn: the selection or the named file,
    /// resolved once against the session's records (2026-09-02).
    /// `.noSelection` for every other shape. A named file that ties among
    /// same-named files is a which-one unless the question said "this
    /// video" and the `:select`ed row is one of them (codex #987 item 5).
    static func captureRecordScope(
        for ast: ArchivistQueryAST,
        question: String,
        state: Session
    ) async -> HallieTurnExecutor.RecordScope {
        guard case .record(let payload) = ast else { return .noSelection }
        let resolution = ArchivistRecordReferenceResolver.resolve(
            payload.reference,
            selectedRecordID: state.selectedRecordID,
            records: state.records,
            recordForID: state.record,
            deictic: ArchivistRecordQuestion.mentionsSelection(question))
        return await HallieTurnExecutor.RecordScope(resolution)
    }

    static func temporalSelectionDate(
        _ record: VideoRecord
    ) -> ArchivistTemporalSelectionDateSnapshot? {
        ArchivistTemporalSelectionDateSnapshot.resolvedCatalogDate(record: record)
            ?? ArchivistTemporalSelectionDateSnapshot.legacyFallback(record: record)
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
