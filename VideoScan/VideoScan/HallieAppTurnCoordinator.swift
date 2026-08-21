// HallieAppTurnCoordinator.swift
// App-only bridge from the floating chat window to QueryAST-v2 and the
// UI-neutral HallieTurnExecutor. Filesystem evidence stays off MainActor;
// catalog objects are projected into immutable snapshots in bounded batches.

import Foundation

enum HallieAppTurnCoordinator {
    struct Translation: Sendable {
        let ast: ArchivistQueryAST
        let responderHost: String
    }

    struct CapturedReferent: Sendable {
        let recordID: UUID?
        let temporalDate: ArchivistTemporalSelectionDateSnapshot?
    }

    /// A clarification keeps the exact immutable evidence context used by
    /// the original turn. Selecting a stable ID never re-translates the text,
    /// re-resolves an alias, or changes which Catalog row "this" meant.
    struct PendingClarification: Sendable {
        let clarification: HallieTurnExecutor.Clarification
        let context: HallieTurnExecutor.Context
        let responderHost: String
        let capturedReferentID: UUID?
        /// The phrasing settings of the original turn, so a continued
        /// answer is phrased (or not) exactly as the first would have been.
        let composition: Composition
    }

    /// Whether and with what this turn's answer may be phrased by the model.
    /// `enabled == false` (the default) never calls the composer.
    struct Composition: Sendable {
        let enabled: Bool
        let hosts: [String]
        let modelName: String
        let history: [HallieGroundedComposer.HistoryTurn]

        static let off = Composition(
            enabled: false, hosts: [], modelName: "", history: [])

        init(enabled: Bool, hosts: [String], modelName: String,
             history: [HallieGroundedComposer.HistoryTurn]) {
            self.enabled = enabled
            self.hosts = hosts
            self.modelName = modelName
            self.history = history
        }
    }

    struct Response: Sendable {
        let result: HallieTurnExecutor.Result
        let responderHost: String
        let biographyPhoto: ArchivistBiographyPhoto?
        let capturedReferentID: UUID?
        let citations: [HallieTurnExecutor.Citation]
        let pendingClarification: PendingClarification?
        let playAfterAnswer: Bool
        /// The intent that was executed, for conversation memory. Nil for
        /// answers that ran no query (capability, follow-up media action,
        /// follow-up declines).
        let executedIntent: HallieTurnExecutor.Intent?
    }

    /// The responder label for turns that never reached a model.
    static let localResponder = "local (no model)"

    struct Dependencies: Sendable {
        /// Starts a local endpoint when appropriate and returns the effective
        /// routing order. Production rewrites this Mac's hostname to loopback
        /// so a loopback-only Ollama is reusable; remote hosts are unchanged.
        let startLocalBrain: @Sendable ([String]) async throws -> [String]
        let translateAST: @Sendable (
            String, [String], String
        ) async throws -> Translation
        let loadProfiles: @Sendable () -> [HallieTurnExecutor.ProfileSnapshot]?
        let loadGraph: @Sendable () -> GedcomFamilyGraph?
        let loadCyberBrain: @Sendable () -> CyberBrainIndex?
        /// Who "I" and "you" are (2026-08-18): the owner's name and the
        /// archivist's name from the `archivist.*` settings.
        let loadSpeakers: @Sendable () -> HallieTurnExecutor.Speakers
        let executeRequest: @Sendable (
            HallieTurnExecutor.Request, HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        let continueTurn: @Sendable (
            HallieTurnExecutor.Clarification,
            HallieTurnExecutor.CandidateID,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        let resolveBiographyPhoto: @Sendable (String) -> ArchivistBiographyPhoto?
        /// Phrase an approved plan (plan, history, hosts, model) → outcome.
        /// The default never phrases; production wires HallieGroundedComposer
        /// over the translator's Ollama transport. Only called for
        /// composable plans (never help / capability / small talk / reset /
        /// declines / clarifications).
        let composeAnswer: @Sendable (
            HallieAnswerPlan, [HallieGroundedComposer.HistoryTurn], [String], String
        ) async -> HallieGroundedComposer.Outcome

        init(
            startLocalBrain: @escaping @Sendable ([String]) async throws -> [String],
            translateAST: @escaping @Sendable (String, [String], String) async throws -> Translation,
            loadProfiles: @escaping @Sendable () -> [HallieTurnExecutor.ProfileSnapshot]?,
            loadGraph: @escaping @Sendable () -> GedcomFamilyGraph?,
            loadCyberBrain: @escaping @Sendable () -> CyberBrainIndex? = { nil },
            loadSpeakers: @escaping @Sendable () -> HallieTurnExecutor.Speakers = {
                HallieTurnExecutor.Speakers.fromDefaults()
            },
            executeRequest: @escaping @Sendable (
                HallieTurnExecutor.Request, HallieTurnExecutor.Context
            ) async throws -> HallieTurnExecutor.Result,
            continueTurn: @escaping @Sendable (
                HallieTurnExecutor.Clarification,
                HallieTurnExecutor.CandidateID,
                HallieTurnExecutor.Context
            ) async throws -> HallieTurnExecutor.Result,
            resolveBiographyPhoto: @escaping @Sendable (String) -> ArchivistBiographyPhoto?,
            composeAnswer: @escaping @Sendable (
                HallieAnswerPlan, [HallieGroundedComposer.HistoryTurn], [String], String
            ) async -> HallieGroundedComposer.Outcome = { plan, _, _, _ in
                .template(plan, note: "template: no composer configured")
            }
        ) {
            self.startLocalBrain = startLocalBrain
            self.translateAST = translateAST
            self.loadProfiles = loadProfiles
            self.loadGraph = loadGraph
            self.loadCyberBrain = loadCyberBrain
            self.loadSpeakers = loadSpeakers
            self.executeRequest = executeRequest
            self.continueTurn = continueTurn
            self.resolveBiographyPhoto = resolveBiographyPhoto
            self.composeAnswer = composeAnswer
        }

        static let live = Dependencies(
            startLocalBrain: { hosts in
                _ = try await OllamaLocalServerBootstrap.shared
                    .ensureRunning(for: hosts)
                return OllamaLocalServerBootstrap
                    .routeLocalEndpointsToLoopback(hosts)
            },
            translateAST: { question, hosts, modelName in
                let responder = ResponderBox()
                var template = OllamaQueryTranslator()
                template.model = modelName
                let translator = OllamaFailoverTranslator(
                    hosts: hosts,
                    template: template,
                    onResponder: { responder.set($0) })
                let ast = try await translator.translateAST(question)
                return Translation(
                    ast: ast,
                    responderHost: responder.value ?? "unknown")
            },
            loadProfiles: {
                switch HallieShellCLI.loadProfilesReadOnly() {
                case .loaded(let profiles):
                    return profiles.map {
                        HallieTurnExecutor.ProfileSnapshot(
                            stableID: $0.id,
                            canonicalName: $0.name,
                            aliases: $0.aliases,
                            birthdate: $0.birthdate)
                    }
                case .unavailable:
                    return nil
                }
            },
            loadGraph: {
                let directory = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask).first?
                    .appendingPathComponent(
                        "VideoScan/family-tree/originals", isDirectory: true)
                return directory.flatMap {
                    FamilyGraphFileLoader(
                        originalsDirectory: $0).loadNewest()
                }
            },
            loadCyberBrain: {
                guard let root = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask).first?.appendingPathComponent(
                        "VideoScan/cyberbrain", isDirectory: true) else {
                    return nil
                }
                do {
                    return try CyberBrainIndex(
                        archive: CyberBrainLoader(rootURL: root).load())
                } catch CyberBrainError.missingArchive {
                    return nil
                } catch {
                    appLog.write("Hallie: CyberBrain unavailable — \(error.localizedDescription)")
                    return nil
                }
            },
            executeRequest: { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification,
                    selecting: selectedID,
                    context: context)
            },
            resolveBiographyPhoto: { canonicalName in
                guard case .loaded(let profiles) =
                        HallieShellCLI.loadProfilesReadOnly() else { return nil }
                return ArchivistBiographyPhoto.resolve(
                    personName: canonicalName,
                    profiles: profiles)
            },
            composeAnswer: { plan, history, hosts, modelName in
                // Same fleet, same model, same probe/failover walk as
                // translation; loopback-routed so an already-running local
                // Ollama is reused without a demand-start.
                var template = OllamaQueryTranslator()
                template.model = modelName
                let fleet = OllamaFailoverTranslator(
                    hosts: OllamaLocalServerBootstrap
                        .routeLocalEndpointsToLoopback(hosts),
                    template: template)
                let composer = HallieGroundedComposer(
                    personaName: HallieCompositionSettings.personaName(),
                    modelCall: { system, user in
                        try await fleet.composePlainText(system: system, user: user)
                    })
                return await composer.compose(plan: plan, history: history)
            })
    }

    /// `NSLock` here is the C++ equivalent of a tiny mutex-protected string.
    /// Ollama failover may report its responder from a non-main callback.
    private final class ResponderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?

        func set(_ value: String) {
            lock.withLock { storage = value }
        }

        var value: String? {
            lock.withLock { storage }
        }
    }

    /// Resolve the question against conversation memory FIRST (no model),
    /// then translate the exact user question if nothing local applied,
    /// capture only the record projection required by the route, and execute
    /// through the same core as the shell. No literal-search fallback exists.
    @MainActor
    static func execute(
        question: String,
        records: [VideoRecord],
        referent: CapturedReferent,
        hosts: [String],
        modelName: String,
        playAfterAnswer: Bool = false,
        memory: HallieTurnExecutor.ConversationMemory = .init(),
        composeWithModel: Bool = false,
        history: [HallieGroundedComposer.HistoryTurn] = [],
        dependencies: Dependencies = .live
    ) async throws -> Response {
        try Task.checkCancellation()

        // Identity sources are loaded lazily and off-main, only if the
        // resolver actually needs to ask "is 'matt' a person?".
        let preTranslation = try await preTranslationOffMain(
            question: question, playAfterAnswer: playAfterAnswer,
            memory: memory, dependencies: dependencies)
        try Task.checkCancellation()

        let intent: HallieTurnExecutor.Intent
        let responderHost: String
        // Phrasing rides on the fleet the turn used: the demand-started /
        // loopback-routed hosts after a translation, the configured list for
        // a locally-resolved turn.
        var composeHosts = hosts
        switch preTranslation {
        case .answer(let result):
            // Help, capability, small talk, reset, follow-up actions and
            // declines: fixed wording by design; the composer is never asked.
            return Response(
                result: result,
                responderHost: localResponder,
                biographyPhoto: nil,
                capturedReferentID: referent.recordID,
                citations: Array(result.citations.prefix(25)),
                pendingClarification: nil,
                playAfterAnswer: false,
                executedIntent: nil)

        case .run(let local):
            intent = local
            responderHost = localResponder

        case .translate(let effectiveQuestion, let wantsPlay):
            let effectiveHosts: [String]
            do {
                effectiveHosts = try await dependencies.startLocalBrain(hosts)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Demand-start is an optimization, not the fleet gatekeeper. A
                // local executable/startup failure must still allow an
                // already-up remote host to answer through the established
                // failover path.
                appLog.write("Hallie: local Ollama demand-start failed; trying configured fleet — \(error.localizedDescription)")
                effectiveHosts = hosts
            }
            composeHosts = effectiveHosts
            try Task.checkCancellation()
            let translation = try await dependencies.translateAST(
                effectiveQuestion, effectiveHosts, modelName)
            try Task.checkCancellation()
            intent = HallieTurnExecutor.Intent(
                originalQuestion: question,
                ast: translation.ast,
                playAfterAnswer: wantsPlay)
            responderHost = translation.responderHost
        }
        let composition = Composition(
            enabled: composeWithModel,
            hosts: composeHosts,
            modelName: modelName,
            history: history)

        let context = try await captureContext(
            ast: intent.ast,
            records: records,
            selectedDate: referent.temporalDate,
            dependencies: dependencies)
        let request = HallieTurnExecutor.Request(intent: intent)
        return try await runOffMain(
            intent: intent,
            responderHost: responderHost,
            capturedReferentID: referent.recordID,
            context: context,
            playAfterAnswer: intent.playAfterAnswer,
            composition: composition,
            dependencies: dependencies) {
                try await dependencies.executeRequest(request, context)
            }
    }

    /// Continue a typed ambiguity with the stable ID offered by the shared
    /// executor. The captured context and original intent remain unchanged;
    /// a second clarification stage is returned the same way as the first.
    static func `continue`(
        pending: PendingClarification,
        selecting candidateID: HallieTurnExecutor.CandidateID,
        history: [HallieGroundedComposer.HistoryTurn]? = nil,
        dependencies: Dependencies = .live
    ) async throws -> Response {
        let composition = history.map {
            Composition(enabled: pending.composition.enabled,
                        hosts: pending.composition.hosts,
                        modelName: pending.composition.modelName,
                        history: $0)
        } ?? pending.composition
        return try await runOffMain(
            intent: pending.clarification.intent,
            responderHost: pending.responderHost,
            capturedReferentID: pending.capturedReferentID,
            context: pending.context,
            playAfterAnswer: pending.clarification.intent.playAfterAnswer,
            composition: composition,
            dependencies: dependencies) {
                try await dependencies.continueTurn(
                    pending.clarification,
                    candidateID,
                    pending.context)
            }
    }

    private static func preTranslationOffMain(
        question: String,
        playAfterAnswer: Bool,
        memory: HallieTurnExecutor.ConversationMemory,
        dependencies: Dependencies
    ) async throws -> HallieTurnExecutor.PreTranslation {
        let worker = Task.detached(priority: .userInitiated) {
            () throws -> HallieTurnExecutor.PreTranslation in
            try Task.checkCancellation()
            // Lazy identity sources: nothing is read from disk unless the
            // resolver asks about a name.
            var loaded: HallieTurnExecutor.Context?
            func sources() -> HallieTurnExecutor.Context {
                if let loaded { return loaded }
                let context = HallieTurnExecutor.Context(
                    profiles: dependencies.loadProfiles(),
                    graph: dependencies.loadGraph(),
                    cyberBrain: dependencies.loadCyberBrain())
                loaded = context
                return context
            }
            return HallieTurnExecutor.preTranslation(
                question: question,
                playAfterAnswer: playAfterAnswer,
                memory: memory,
                isKnownPerson: { name in
                    HallieTurnExecutor.isKnownPerson(name, context: sources())
                })
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    @MainActor
    private static func captureContext(
        ast: ArchivistQueryAST,
        records: [VideoRecord],
        selectedDate: ArchivistTemporalSelectionDateSnapshot?,
        dependencies: Dependencies
    ) async throws -> HallieTurnExecutor.Context {
        let route = HallieTurnExecutor.route(ast)
        let presenceRecords: [ArchivistPresenceRecordSnapshot]
        let aggregateRecords: [ArchivistAggregateRecordSnapshot]
        switch route {
        case .presence, .cross:
            presenceRecords = await ArchivistPresenceRecordSnapshot.capture(
                records)
            aggregateRecords = []
        case .aggregate:
            presenceRecords = []
            aggregateRecords = await ArchivistAggregateRecordSnapshot.capture(
                records)
        case .temporal, .graph, .unsupportedEvent, .followUp, .capability, .help, .smalltalk, .reset:
            presenceRecords = []
            aggregateRecords = []
        }
        try Task.checkCancellation()

        // "as a baby" needs a birth year: presence/cross turns that carry an
        // age phrase load the identity sources too; plain ones do not.
        let needsBirthYear = HallieTurnExecutor.needsBirthYearSources(ast)
        let worker = Task.detached(priority: .userInitiated) {
            () throws -> HallieTurnExecutor.Context in
            try Task.checkCancellation()
            let profiles: [HallieTurnExecutor.ProfileSnapshot]?
            let graph: GedcomFamilyGraph?
            let cyberBrain: CyberBrainIndex?
            switch route {
            case .temporal, .aggregate:
                profiles = dependencies.loadProfiles()
                graph = nil
                cyberBrain = nil
            case .graph:
                profiles = dependencies.loadProfiles()
                graph = dependencies.loadGraph()
                cyberBrain = dependencies.loadCyberBrain()
            case .presence, .cross:
                if needsBirthYear {
                    profiles = dependencies.loadProfiles()
                    graph = dependencies.loadGraph()
                    cyberBrain = dependencies.loadCyberBrain()
                } else {
                    profiles = []
                    graph = nil
                    cyberBrain = nil
                }
            case .unsupportedEvent, .followUp, .capability, .help, .smalltalk, .reset:
                profiles = []
                graph = nil
                cyberBrain = nil
            }
            let context = HallieTurnExecutor.Context(
                presenceRecords: presenceRecords,
                aggregateRecords: aggregateRecords,
                profiles: profiles,
                graph: graph,
                cyberBrain: cyberBrain,
                selectedTemporalDate: selectedDate,
                speakers: route == .graph ? dependencies.loadSpeakers() : .none)
            try Task.checkCancellation()
            return context
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runOffMain(
        intent: HallieTurnExecutor.Intent,
        responderHost: String,
        capturedReferentID: UUID?,
        context: HallieTurnExecutor.Context,
        playAfterAnswer: Bool,
        composition: Composition,
        dependencies: Dependencies,
        operation: @escaping @Sendable () async throws
            -> HallieTurnExecutor.Result
    ) async throws -> Response {
        let ast = intent.ast
        let worker = Task.detached(priority: .userInitiated) {
            () async throws -> Response in
            try Task.checkCancellation()
            var result = try await operation()
            try Task.checkCancellation()

            // Plan → phrase → verify, only after the deterministic answer is
            // complete and only for composable plans. The composer bounds its
            // own latency and returns the template on any failure, so this
            // await never blocks a ready answer past the budget.
            if composition.enabled {
                let plan = HallieAnswerPlan.derive(from: result)
                if plan.isComposable {
                    let outcome = await dependencies.composeAnswer(
                        plan, composition.history,
                        composition.hosts, composition.modelName)
                    result = result.applying(outcome)
                    appLog.write("Hallie: phrased \(HallieTurnExecutor.label(result.route))/\(HallieTurnExecutor.label(result.outcome)) by \(outcome.composedBy.rawValue) (\(outcome.note); dropped \(outcome.dropped.count))")
                }
            }
            try Task.checkCancellation()

            let photo: ArchivistBiographyPhoto?
            if result.clarification == nil,
               case .graph(let payload) = ast,
               payload.operation == .biography,
               let canonicalName = result.catalogPersonName {
                photo = dependencies.resolveBiographyPhoto(canonicalName)
            } else {
                photo = nil
            }

            let pending = result.clarification.map {
                PendingClarification(
                    clarification: $0,
                    context: context,
                    responderHost: responderHost,
                    capturedReferentID: capturedReferentID,
                    composition: composition)
            }
            return Response(
                result: result,
                responderHost: responderHost,
                biographyPhoto: photo,
                capturedReferentID: capturedReferentID,
                citations: Array(result.citations.prefix(25)),
                pendingClarification: pending,
                playAfterAnswer: result.outcome == .answered
                    && result.clarification == nil
                    && playAfterAnswer,
                executedIntent: intent)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
