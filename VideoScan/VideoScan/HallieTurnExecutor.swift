// HallieTurnExecutor.swift
// Shared, UI-neutral deterministic execution for one QueryAST-v2 turn.

import Foundation
import VideoScanCore

enum HallieTurnExecutor {
    enum Route: Sendable, Equatable {
        case presence
        case temporal
        case aggregate
        case graph
        case unsupportedEvent
        case unsupportedCross
    }

    enum Outcome: Sendable, Equatable {
        case answered
        case declined
        case unsupported
        case needsClarification
    }

    enum IdentitySource: Sendable, Equatable {
        case peopleProfile
        case gedcom
    }

    enum CandidateID: Sendable, Equatable {
        case profileStableID(String)
        case gedcomPersonID(String)

        var source: IdentitySource {
            switch self {
            case .profileStableID: return .peopleProfile
            case .gedcomPersonID: return .gedcom
            }
        }
    }

    struct Candidate: Sendable, Equatable {
        let id: CandidateID
        let canonicalName: String
        let label: String
        let source: IdentitySource

        init(id: CandidateID, canonicalName: String, label: String) {
            self.id = id
            self.canonicalName = canonicalName
            self.label = label
            self.source = id.source
        }
    }

    enum ClarificationStage: Sendable, Equatable {
        case profileIdentity
        case gedcomPerson

        fileprivate func accepts(_ source: IdentitySource) -> Bool {
            switch (self, source) {
            case (.profileIdentity, .peopleProfile), (.gedcomPerson, .gedcom):
                return true
            default:
                return false
            }
        }
    }

    /// The original interaction intent survives every continuation. In
    /// particular, a clarification chip must not lose a pending play request.
    struct Intent: Sendable, Equatable {
        let originalQuestion: String
        let ast: ArchivistQueryAST
        let playAfterAnswer: Bool

        init(
            originalQuestion: String,
            ast: ArchivistQueryAST,
            playAfterAnswer: Bool = false
        ) {
            self.originalQuestion = originalQuestion
            self.ast = ast
            self.playAfterAnswer = playAfterAnswer
        }
    }

    struct Request: Sendable, Equatable {
        let intent: Intent
        fileprivate let selectedIdentity: CandidateID?

        init(intent: Intent) {
            self.intent = intent
            self.selectedIdentity = nil
        }

        fileprivate init(intent: Intent, selectedIdentity: CandidateID) {
            self.intent = intent
            self.selectedIdentity = selectedIdentity
        }
    }

    struct Clarification: Sendable, Equatable {
        let intent: Intent
        let stage: ClarificationStage
        let candidates: [Candidate]
        fileprivate let continuationToken: UUID

        fileprivate init(
            intent: Intent,
            stage: ClarificationStage,
            candidates: [Candidate],
            continuationToken: UUID
        ) {
            self.intent = intent
            self.stage = stage
            self.candidates = candidates
            self.continuationToken = continuationToken
        }
    }

    /// The only People-gallery values admitted to factual execution. Photos,
    /// notes, recognition settings, and profile filesystem paths stay outside.
    struct ProfileSnapshot: Sendable, Equatable {
        let stableID: String
        let canonicalName: String
        let aliases: [String]
        let birthdate: Date?

        init(
            stableID: String,
            canonicalName: String,
            aliases: [String] = [],
            birthdate: Date? = nil
        ) {
            self.stableID = stableID
            self.canonicalName = canonicalName
            self.aliases = aliases
            self.birthdate = birthdate
        }
    }

    /// Immutable values captured by the caller before shared execution. This
    /// deliberately contains no model, media, photo, or filesystem adapters.
    struct Context: Sendable {
        let presenceRecords: [ArchivistPresenceRecordSnapshot]
        let aggregateRecords: [ArchivistAggregateRecordSnapshot]
        /// `nil` means profile evidence could not be read. An empty array is
        /// a successful read proving that no profiles currently exist.
        let profiles: [ProfileSnapshot]?
        let graph: GedcomFamilyGraph?
        let selectedTemporalDate: ArchivistTemporalSelectionDateSnapshot?
        /// An opaque capture identity. Copying Context preserves it; invoking
        /// the initializer creates a new capture that cannot continue an old
        /// clarification even if visible stable IDs and names are unchanged.
        fileprivate let continuationToken: UUID

        init(
            presenceRecords: [ArchivistPresenceRecordSnapshot] = [],
            aggregateRecords: [ArchivistAggregateRecordSnapshot] = [],
            profiles: [ProfileSnapshot]? = [],
            graph: GedcomFamilyGraph? = nil,
            selectedTemporalDate: ArchivistTemporalSelectionDateSnapshot? = nil
        ) {
            self.presenceRecords = presenceRecords
            self.aggregateRecords = aggregateRecords
            self.profiles = profiles
            self.graph = graph
            self.selectedTemporalDate = selectedTemporalDate
            self.continuationToken = UUID()
        }
    }

    struct Citation: Sendable, Equatable {
        let recordID: UUID
        let fullPath: String
        let filename: String
        let playbackSeconds: Double?
        let bases: [ArchivistEvidenceBasis]
    }

    struct Result: Sendable, Equatable {
        let route: Route
        let outcome: Outcome
        let prose: String
        let basisLine: String
        let queryDescription: String?
        let citations: [Citation]
        let catalogPersonName: String?
        let clarification: Clarification?

        init(
            route: Route,
            outcome: Outcome,
            prose: String,
            basisLine: String,
            queryDescription: String?,
            citations: [Citation],
            catalogPersonName: String?,
            clarification: Clarification? = nil
        ) {
            self.route = route
            self.outcome = outcome
            self.prose = prose
            self.basisLine = basisLine
            self.queryDescription = queryDescription
            self.citations = citations
            self.catalogPersonName = catalogPersonName
            self.clarification = clarification
        }
    }

    struct Dependencies: Sendable {
        let executePresence: @Sendable (
            ArchivistPresenceQuery,
            [ArchivistPresenceRecordSnapshot]
        ) -> ArchivistPresenceResult
        let executeTemporal: @Sendable (
            ArchivistQueryAST.Temporal,
            ArchivistTemporalSubjectResolution,
            ArchivistTemporalSelectionDateSnapshot?
        ) -> ArchivistTemporalResult
        let executeAggregate: @Sendable (
            ArchivistAggregateQuery,
            [ArchivistAggregateRecordSnapshot],
            ArchivistAggregateIdentityCatalog
        ) -> ArchivistAggregateResult
        let executeGraph: @Sendable (
            ArchivistGraphQuery,
            ArchivistGraphInputs,
            ArchivistGraphSubjectSelection
        ) -> ArchivistGraphResult

        init(
            executePresence: @escaping @Sendable (
                ArchivistPresenceQuery,
                [ArchivistPresenceRecordSnapshot]
            ) -> ArchivistPresenceResult,
            executeTemporal: @escaping @Sendable (
                ArchivistQueryAST.Temporal,
                ArchivistTemporalSubjectResolution,
                ArchivistTemporalSelectionDateSnapshot?
            ) -> ArchivistTemporalResult,
            executeAggregate: @escaping @Sendable (
                ArchivistAggregateQuery,
                [ArchivistAggregateRecordSnapshot],
                ArchivistAggregateIdentityCatalog
            ) -> ArchivistAggregateResult,
            executeGraph: @escaping @Sendable (
                ArchivistGraphQuery,
                ArchivistGraphInputs,
                ArchivistGraphSubjectSelection
            ) -> ArchivistGraphResult
        ) {
            self.executePresence = executePresence
            self.executeTemporal = executeTemporal
            self.executeAggregate = executeAggregate
            self.executeGraph = executeGraph
        }

        static let production = Dependencies(
            executePresence: ArchivistPresenceExecutor.execute,
            executeTemporal: ArchivistTemporalExecutor.execute,
            executeAggregate: ArchivistAggregateExecutor.execute,
            executeGraph: { query, inputs, subject in
                ArchivistGraphExecutor.execute(
                    query, inputs: inputs, subject: subject)
            })
    }

    static func route(_ ast: ArchivistQueryAST) -> Route {
        switch ast {
        case .presence: return .presence
        case .temporal: return .temporal
        case .aggregate: return .aggregate
        case .graph: return .graph
        case .event: return .unsupportedEvent
        case .cross: return .unsupportedCross
        }
    }

    static func description(of ast: ArchivistQueryAST) -> String {
        switch route(ast) {
        case .presence: return "shape=presence"
        case .temporal: return "shape=temporal"
        case .aggregate: return "shape=aggregate"
        case .graph: return "shape=graph"
        case .unsupportedEvent: return "shape=event (unsupported)"
        case .unsupportedCross: return "shape=cross (unsupported)"
        }
    }

    /// Executes exactly one validated AST. Detached work receives only
    /// immutable Sendable projections and bounded executor closures.
    static func execute(
        _ ast: ArchivistQueryAST,
        context: Context
    ) async throws -> Result {
        try await execute(
            Request(intent: Intent(
                originalQuestion: "", ast: ast, playAfterAnswer: false)),
            context: context,
            dependencies: .production)
    }

    static func execute(
        _ ast: ArchivistQueryAST,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        try await execute(
            Request(intent: Intent(
                originalQuestion: "", ast: ast, playAfterAnswer: false)),
            context: context,
            dependencies: dependencies)
    }

    static func execute(
        _ request: Request,
        context: Context
    ) async throws -> Result {
        try await execute(request, context: context, dependencies: .production)
    }

    static func `continue`(
        pending: Clarification,
        selecting selectedID: CandidateID,
        context: Context
    ) async throws -> Result {
        guard pending.continuationToken == context.continuationToken,
              let candidate = pending.candidates.first(where: {
                  $0.id == selectedID
              }),
              pending.stage.accepts(selectedID.source),
              selectionIsCurrent(candidate, context: context) else {
            return invalidContinuationResult(for: pending.intent.ast)
        }
        return try await execute(
            Request(intent: pending.intent, selectedIdentity: selectedID),
            context: context)
    }

    static func execute(
        _ request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        try Task.checkCancellation()
        let ast = request.intent.ast
        switch ast {
        case .presence(let payload):
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            let query = ArchivistPresenceQuery(payload)
            let records = context.presenceRecords
            let execute = dependencies.executePresence
            let result = try await detached {
                execute(query, records)
            }
            let answer = ArchivistPresenceAnswerComposer.compose(result)
            return Result(
                route: .presence,
                outcome: result.conclusion == .present ? .answered : .declined,
                prose: answer.prose,
                basisLine: answer.basisLine,
                queryDescription: result.interpretedQuery,
                citations: normalize(result.evidence.citations),
                catalogPersonName: nil)

        case .temporal(let payload):
            guard let profiles = context.profiles else {
                return unavailableProfilesResult(route: .temporal)
            }
            let resolution = temporalResolution(
                payload.subject, profiles: profiles,
                selectedIdentity: request.selectedIdentity)
            if case .ambiguous(_, let candidates) = resolution {
                let choices = profileCandidates(candidates)
                let clarification = Clarification(
                    intent: request.intent,
                    stage: .profileIdentity,
                    candidates: choices,
                    continuationToken: context.continuationToken)
                return Result(
                    route: .temporal,
                    outcome: .needsClarification,
                    prose: "Which \(payload.subject) do you mean?",
                    basisLine: "Basis: subject resolution matched multiple People profiles.",
                    queryDescription:
                        "shape=temporal operation=age subject=\(payload.subject)",
                    citations: [],
                    catalogPersonName: nil,
                    clarification: clarification)
            }
            let result = dependencies.executeTemporal(
                payload, resolution, context.selectedTemporalDate)
            return Result(
                route: .temporal,
                outcome: result.value == nil ? .declined : .answered,
                prose: result.prose,
                basisLine: result.basisLine,
                queryDescription:
                    "shape=temporal operation=age subject=\(payload.subject)",
                citations: [],
                catalogPersonName: nil)

        case .aggregate(let payload):
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            guard let profiles = context.profiles else {
                return unavailableProfilesResult(route: .aggregate)
            }
            let query = ArchivistAggregateQuery(payload)
            let records = context.aggregateRecords
            let identities = aggregateIdentities(profiles: profiles)
            let execute = dependencies.executeAggregate
            let result = try await detached {
                execute(query, records, identities)
            }
            let answer = result.factualAnswer
            let citations = answer.rankings.flatMap(\.sampleCitations)
                .prefix(25)
                .map { normalize($0) }
            return Result(
                route: .aggregate,
                outcome: result.conclusion == .ranked ? .answered : .declined,
                prose: answer.prose,
                basisLine: answer.basisLine,
                queryDescription: result.interpretedQuery,
                citations: citations,
                catalogPersonName: nil)

        case .graph(let payload):
            guard let graph = context.graph else {
                return Result(
                    route: .graph,
                    outcome: .declined,
                    prose: "I don't have an imported family tree, so I can't answer that reliably.",
                    basisLine: "Basis: no readable GEDCOM was available.",
                    queryDescription: "shape=graph",
                    citations: [],
                    catalogPersonName: nil)
            }
            let query = ArchivistGraphQuery(payload)
            let queryDescription =
                "shape=graph operation=\(payload.operation.rawValue) "
                + "person=\(payload.people.joined(separator: ","))"
            let inputs = ArchivistGraphInputs(
                graph: graph,
                profiles: (context.profiles ?? []).map {
                    ArchivistGraphProfileSnapshot(
                        stableID: $0.stableID,
                        canonicalName: $0.canonicalName,
                        aliases: $0.aliases)
                })
            let selection: ArchivistGraphSubjectSelection
            switch request.selectedIdentity {
            case nil: selection = .unresolved
            case .profileStableID(let id): selection = .profileStableID(id)
            case .gedcomPersonID(let id): selection = .gedcomPersonID(id)
            }
            let execute = dependencies.executeGraph
            let result = try await detached {
                execute(query, inputs, selection)
            }
            if !result.ambiguityCandidates.isEmpty {
                let choices = result.ambiguityCandidates.map { candidate in
                    switch candidate.id {
                    case .profileStableID(let id):
                        return Candidate(
                            id: .profileStableID(id),
                            canonicalName: candidate.canonicalName,
                            label: candidate.label)
                    case .gedcomPersonID(let id):
                        return Candidate(
                            id: .gedcomPersonID(id),
                            canonicalName: candidate.canonicalName,
                            label: candidate.label)
                    }
                }
                let stage: ClarificationStage = choices[0].source == .peopleProfile
                    ? .profileIdentity : .gedcomPerson
                let clarification = Clarification(
                    intent: request.intent,
                    stage: stage,
                    candidates: choices,
                    continuationToken: context.continuationToken)
                return Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: result.prose,
                    basisLine: result.basisLine,
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: clarification)
            }
            return Result(
                route: .graph,
                outcome: result.conclusion == .answered ? .answered : .declined,
                prose: result.prose,
                basisLine: result.basisLine,
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: result.catalogPersonName)

        case .event:
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            return Result(
                route: .unsupportedEvent,
                outcome: .unsupported,
                prose: "Event queries are not supported yet; I did not run a broader search.",
                basisLine: "Basis: QueryAST shape=event has no deterministic executor.",
                queryDescription: nil,
                citations: [],
                catalogPersonName: nil)

        case .cross:
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            return Result(
                route: .unsupportedCross,
                outcome: .unsupported,
                prose: "Cross-evidence queries are not supported yet; I did not coerce this into presence search.",
                basisLine: "Basis: QueryAST shape=cross has no deterministic executor.",
                queryDescription: nil,
                citations: [],
                catalogPersonName: nil)
        }
    }

    private static func unavailableProfilesResult(route: Route) -> Result {
        let shape = route == .temporal ? "temporal" : "aggregate"
        return Result(
            route: route,
            outcome: .declined,
            prose: "I can't answer that reliably because People profiles are unavailable.",
            basisLine: "Basis: profile evidence could not be read.",
            queryDescription: "shape=\(shape)",
            citations: [],
            catalogPersonName: nil)
    }

    private static func invalidContinuationResult(
        for ast: ArchivistQueryAST
    ) -> Result {
        Result(
            route: route(ast),
            outcome: .declined,
            prose: "That identity choice is no longer available.",
            basisLine: "Basis: the clarification selection was stale or did not belong to this question.",
            queryDescription: description(of: ast),
            citations: [],
            catalogPersonName: nil)
    }

    /// Re-check the opaque identity against the new immutable capture. A chip
    /// may outlive a profile edit or GEDCOM reload; an ID whose meaning changed
    /// is stale even if the raw string still exists.
    private static func selectionIsCurrent(
        _ candidate: Candidate,
        context: Context
    ) -> Bool {
        switch candidate.id {
        case .profileStableID(let stableID):
            guard let profiles = context.profiles else { return false }
            let definitions = profiles.filter { $0.stableID == stableID }
            guard let first = definitions.first,
                  definitions.allSatisfy({ sameProfileMeaning($0, first) })
            else { return false }
            return PersonResolver.normalize(
                deterministicProfile(definitions).canonicalName)
                == PersonResolver.normalize(candidate.canonicalName)

        case .gedcomPersonID(let personID):
            guard let person = context.graph?.people[personID] else {
                return false
            }
            return PersonResolver.normalize(person.name)
                == PersonResolver.normalize(candidate.canonicalName)
        }
    }

    private static func detached<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async throws -> Value {
        let task = Task.detached { () throws -> Value in
            try Task.checkCancellation()
            let value = operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func temporalResolution(
        _ requested: String,
        profiles: [ProfileSnapshot],
        selectedIdentity: CandidateID?
    ) -> ArchivistTemporalSubjectResolution {
        if let selectedIdentity {
            guard case .profileStableID(let rawID) = selectedIdentity else {
                return .missing(requested: requested)
            }
            guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .missing(requested: requested) }
            let definitions = profiles.filter { $0.stableID == rawID }
            guard let first = definitions.first,
                  definitions.allSatisfy({ sameProfileMeaning($0, first) }) else {
                return .missing(requested: requested)
            }
            let profile = deterministicProfile(definitions)
            return .resolved(
                requested: requested,
                subject: .init(
                    stableID: profile.stableID,
                    canonicalName: profile.canonicalName,
                    birthdate: profile.birthdate))
        }

        let key = PersonResolver.normalize(requested)
        let grouped = Dictionary(grouping: profiles, by: \.stableID)
        var matches: [ProfileSnapshot] = []
        for stableID in grouped.keys.sorted() {
            guard let definitions = grouped[stableID],
                  let first = definitions.first else { continue }
            let participates = definitions.contains(where: {
                      ([$0.canonicalName] + $0.aliases).contains {
                          PersonResolver.normalize($0) == key
                      }
                  })
            guard participates else { continue }
            guard definitions.allSatisfy({ sameProfileMeaning($0, first) })
            else { return .missing(requested: requested) }
            matches.append(deterministicProfile(definitions))
        }
        matches.sort(by: profileOrder)
        if matches.isEmpty { return .missing(requested: requested) }
        if matches.count > 1 {
            return .ambiguous(
                requested: requested,
                candidates: matches.map {
                    .init(stableID: $0.stableID,
                          canonicalName: $0.canonicalName)
                })
        }
        let profile = matches[0]
        return .resolved(
            requested: requested,
            subject: .init(
                stableID: profile.stableID,
                canonicalName: profile.canonicalName,
                birthdate: profile.birthdate))
    }

    private static func profileCandidates(
        _ candidates: [ArchivistTemporalSubjectResolution.Candidate]
    ) -> [Candidate] {
        let nameCounts = Dictionary(grouping: candidates) {
            PersonResolver.normalize($0.canonicalName)
        }.mapValues { $0.count }
        return candidates.sorted {
            let lhs = PersonResolver.normalize($0.canonicalName)
            let rhs = PersonResolver.normalize($1.canonicalName)
            return lhs == rhs ? $0.stableID < $1.stableID : lhs < rhs
        }.map { candidate in
            let duplicate = nameCounts[PersonResolver.normalize(
                candidate.canonicalName), default: 0] > 1
            return Candidate(
                id: .profileStableID(candidate.stableID),
                canonicalName: candidate.canonicalName,
                label: duplicate
                    ? "\(candidate.canonicalName) (\(candidate.stableID))"
                    : candidate.canonicalName)
        }
    }

    private static func sameProfileMeaning(
        _ lhs: ProfileSnapshot,
        _ rhs: ProfileSnapshot
    ) -> Bool {
        PersonResolver.normalize(lhs.canonicalName)
            == PersonResolver.normalize(rhs.canonicalName)
            && Set(lhs.aliases.map { PersonResolver.normalize($0) })
                == Set(rhs.aliases.map { PersonResolver.normalize($0) })
            && lhs.birthdate == rhs.birthdate
    }

    private static func deterministicProfile(
        _ definitions: [ProfileSnapshot]
    ) -> ProfileSnapshot {
        definitions.sorted(by: profileOrder)[0]
    }

    private static func profileOrder(
        _ lhs: ProfileSnapshot,
        _ rhs: ProfileSnapshot
    ) -> Bool {
        let left = PersonResolver.normalize(lhs.canonicalName)
        let right = PersonResolver.normalize(rhs.canonicalName)
        if left != right { return left < right }
        if lhs.canonicalName != rhs.canonicalName {
            return lhs.canonicalName < rhs.canonicalName
        }
        return lhs.stableID < rhs.stableID
    }

    private static func aggregateIdentities(
        profiles: [ProfileSnapshot]
    ) -> ArchivistAggregateIdentityCatalog {
        // Only POI-backed stable identities are admitted. Unknown confirmed
        // tag spellings remain unresolved rather than becoming identities.
        ArchivistAggregateIdentityCatalog(identities: profiles.map {
            ArchivistAggregateIdentity(
                stableID: $0.stableID,
                canonicalName: $0.canonicalName,
                aliases: $0.aliases)
        })
    }

    private static func normalize(
        _ citations: [ArchivistEvidenceCitation]
    ) -> [Citation] {
        citations.map {
            Citation(
                recordID: $0.recordID,
                fullPath: $0.fullPath,
                filename: $0.filename,
                playbackSeconds: $0.playbackSeconds,
                bases: $0.bases)
        }
    }

    private static func normalize(
        _ citation: ArchivistAggregateSampleCitation
    ) -> Citation {
        Citation(
            recordID: citation.recordID,
            fullPath: citation.fullPath,
            filename: citation.filename,
            playbackSeconds: citation.playbackSeconds,
            bases: citation.bases)
    }
}
