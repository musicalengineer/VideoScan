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
    }

    struct Response: Sendable {
        let result: HallieTurnExecutor.Result
        let responderHost: String
        let biographyPhoto: ArchivistBiographyPhoto?
        let capturedReferentID: UUID?
        let citations: [HallieTurnExecutor.Citation]
        let pendingClarification: PendingClarification?
        let playAfterAnswer: Bool
    }

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
        let executeRequest: @Sendable (
            HallieTurnExecutor.Request, HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        let continueTurn: @Sendable (
            HallieTurnExecutor.Clarification,
            HallieTurnExecutor.CandidateID,
            HallieTurnExecutor.Context
        ) async throws -> HallieTurnExecutor.Result
        let resolveBiographyPhoto: @Sendable (String) -> ArchivistBiographyPhoto?

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

    /// Translate the exact user question, capture only the record projection
    /// required by its route, then execute through the same core as the shell.
    /// No literal-search fallback exists on this path.
    @MainActor
    static func execute(
        question: String,
        records: [VideoRecord],
        referent: CapturedReferent,
        hosts: [String],
        modelName: String,
        playAfterAnswer: Bool = false,
        dependencies: Dependencies = .live
    ) async throws -> Response {
        try Task.checkCancellation()
        let effectiveHosts: [String]
        do {
            effectiveHosts = try await dependencies.startLocalBrain(hosts)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Demand-start is an optimization, not the fleet gatekeeper. A
            // local executable/startup failure must still allow an already-up
            // remote host to answer through the established failover path.
            appLog.write("Hallie: local Ollama demand-start failed; trying configured fleet — \(error.localizedDescription)")
            effectiveHosts = hosts
        }
        try Task.checkCancellation()
        let translation = try await dependencies.translateAST(
            question, effectiveHosts, modelName)
        try Task.checkCancellation()

        let context = try await captureContext(
            route: HallieTurnExecutor.route(translation.ast),
            records: records,
            selectedDate: referent.temporalDate,
            dependencies: dependencies)
        let request = HallieTurnExecutor.Request(intent: .init(
            originalQuestion: question,
            ast: translation.ast,
            playAfterAnswer: playAfterAnswer))
        return try await runOffMain(
            ast: translation.ast,
            responderHost: translation.responderHost,
            capturedReferentID: referent.recordID,
            context: context,
            playAfterAnswer: playAfterAnswer,
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
        dependencies: Dependencies = .live
    ) async throws -> Response {
        try await runOffMain(
            ast: pending.clarification.intent.ast,
            responderHost: pending.responderHost,
            capturedReferentID: pending.capturedReferentID,
            context: pending.context,
            playAfterAnswer: pending.clarification.intent.playAfterAnswer,
            dependencies: dependencies) {
                try await dependencies.continueTurn(
                    pending.clarification,
                    candidateID,
                    pending.context)
            }
    }

    @MainActor
    private static func captureContext(
        route: HallieTurnExecutor.Route,
        records: [VideoRecord],
        selectedDate: ArchivistTemporalSelectionDateSnapshot?,
        dependencies: Dependencies
    ) async throws -> HallieTurnExecutor.Context {
        let presenceRecords: [ArchivistPresenceRecordSnapshot]
        let aggregateRecords: [ArchivistAggregateRecordSnapshot]
        switch route {
        case .presence:
            presenceRecords = await ArchivistPresenceRecordSnapshot.capture(
                records)
            aggregateRecords = []
        case .aggregate:
            presenceRecords = []
            aggregateRecords = await ArchivistAggregateRecordSnapshot.capture(
                records)
        case .temporal, .graph, .unsupportedEvent, .unsupportedCross:
            presenceRecords = []
            aggregateRecords = []
        }
        try Task.checkCancellation()

        let worker = Task.detached(priority: .userInitiated) {
            () throws -> HallieTurnExecutor.Context in
            try Task.checkCancellation()
            let profiles: [HallieTurnExecutor.ProfileSnapshot]?
            let graph: GedcomFamilyGraph?
            switch route {
            case .temporal, .aggregate:
                profiles = dependencies.loadProfiles()
                graph = nil
            case .graph:
                profiles = dependencies.loadProfiles()
                graph = dependencies.loadGraph()
            case .presence, .unsupportedEvent, .unsupportedCross:
                profiles = []
                graph = nil
            }
            let context = HallieTurnExecutor.Context(
                presenceRecords: presenceRecords,
                aggregateRecords: aggregateRecords,
                profiles: profiles,
                graph: graph,
                selectedTemporalDate: selectedDate)
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
        ast: ArchivistQueryAST,
        responderHost: String,
        capturedReferentID: UUID?,
        context: HallieTurnExecutor.Context,
        playAfterAnswer: Bool,
        dependencies: Dependencies,
        operation: @escaping @Sendable () async throws
            -> HallieTurnExecutor.Result
    ) async throws -> Response {
        let worker = Task.detached(priority: .userInitiated) {
            () async throws -> Response in
            try Task.checkCancellation()
            let result = try await operation()
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
                    capturedReferentID: capturedReferentID)
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
                    && playAfterAnswer)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
