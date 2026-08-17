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
        case cyberBrain
    }

    enum CandidateID: Sendable, Equatable {
        case profileStableID(String)
        case gedcomPersonID(String)
        case cyberBrainPersonID(String)

        var source: IdentitySource {
            switch self {
            case .profileStableID: return .peopleProfile
            case .gedcomPersonID: return .gedcom
            case .cyberBrainPersonID: return .cyberBrain
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
        case cyberBrainPerson

        fileprivate func accepts(_ source: IdentitySource) -> Bool {
            switch (self, source) {
            case (.profileIdentity, .peopleProfile), (.gedcomPerson, .gedcom),
                 (.cyberBrainPerson, .cyberBrain):
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
        let cyberBrain: CyberBrainIndex?
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
            cyberBrain: CyberBrainIndex? = nil,
            selectedTemporalDate: ArchivistTemporalSelectionDateSnapshot? = nil
        ) {
            self.presenceRecords = presenceRecords
            self.aggregateRecords = aggregateRecords
            self.profiles = profiles
            self.graph = graph
            self.cyberBrain = cyberBrain
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

    struct KnowledgeCitation: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let attribution: String?
        let locator: String?
    }

    struct Result: Sendable, Equatable {
        let route: Route
        let outcome: Outcome
        let prose: String
        let basisLine: String
        let queryDescription: String?
        let citations: [Citation]
        let knowledgeCitations: [KnowledgeCitation]
        let catalogPersonName: String?
        let clarification: Clarification?

        init(
            route: Route,
            outcome: Outcome,
            prose: String,
            basisLine: String,
            queryDescription: String?,
            citations: [Citation],
            knowledgeCitations: [KnowledgeCitation] = [],
            catalogPersonName: String?,
            clarification: Clarification? = nil
        ) {
            self.route = route
            self.outcome = outcome
            self.prose = prose
            self.basisLine = basisLine
            self.queryDescription = queryDescription
            self.citations = citations
            self.knowledgeCitations = knowledgeCitations
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
            // CyberBrain answers only when it knows the requested identity.
            // A `nil` here means CyberBrain has no opinion, and the turn
            // continues on the pre-existing profiles + GEDCOM path exactly
            // as it would with no CyberBrain installed.
            if payload.operation == .biography,
               let cyberBrain = context.cyberBrain,
               let result = try await executeCyberBrainBiography(
                   payload: payload,
                   request: request,
                   context: context,
                   index: cyberBrain) {
                return result
            }
            // Kinship / birth / death get the SAME alias bridge as biography:
            // a CyberBrain nickname ("rick") resolves to its GEDCOM pointer,
            // ambiguity yields the same distinct-label chips, and the typed
            // continuation lands here again. `nil` = CyberBrain has no
            // opinion; fall through to the profiles + GEDCOM path.
            if payload.operation != .biography,
               let cyberBrain = context.cyberBrain,
               let result = try await executeCyberBrainBridgedGraph(
                   payload: payload,
                   request: request,
                   context: context,
                   index: cyberBrain,
                   dependencies: dependencies) {
                return result
            }
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
            case .cyberBrainPersonID:
                return invalidContinuationResult(for: ast)
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

    /// The privacy ceiling the app grants its own Family Archivist. Every
    /// planner call names it explicitly so the boundary is visible here, not
    /// buried in a Core default.
    static let appPrivacyCeiling: CyberBrainItem.Privacy = .private

    /// Returns `nil` when CyberBrain does not know the requested identity so
    /// the caller falls through to the profiles + GEDCOM path. That path owns
    /// nickname → profile → GEDCOM bridging, profile ambiguity/conflict
    /// handling, and `.profileStableID` / `.gedcomPersonID` continuations;
    /// CyberBrain must not shadow it with a weaker name-only GEDCOM lookup.
    private static func executeCyberBrainBiography(
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        index: CyberBrainIndex
    ) async throws -> Result? {
        guard let requestedName = payload.people.first else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I need a person's name before I can build a biography.",
                basisLine: "Basis: no biography subject was supplied.",
                queryDescription: "shape=graph operation=biography",
                citations: [],
                catalogPersonName: nil)
        }
        let graph = context.graph
        let privacyCeiling = appPrivacyCeiling
        let cyberBrainKnowsName: Bool
        if case .notFound = index.resolve(requestedName) {
            cyberBrainKnowsName = false
        } else {
            cyberBrainKnowsName = true
        }
        let plan: CyberBrainAnswerPlan
        switch request.selectedIdentity {
        case nil:
            guard cyberBrainKnowsName else { return nil }
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    personName: requestedName,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .cyberBrainPersonID(let personID):
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    personID: personID,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .gedcomPersonID(let personID):
            // A GEDCOM chip offered by the profiles + GEDCOM path continues
            // there. If CyberBrain does know the name (a chip from another
            // origin), the typed pointer is honored directly — never
            // re-resolved through display text.
            guard cyberBrainKnowsName else { return nil }
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    gedcomPersonID: personID,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .profileStableID:
            return nil
        }

        let queryDescription =
            "shape=graph operation=biography person=\(requestedName)"
        let knowledgeCitations = plan.sourceCitations.map {
            KnowledgeCitation(
                id: $0.id,
                title: $0.title,
                attribution: $0.attribution,
                locator: $0.locator)
        }
        if plan.answerState == .ambiguous {
            let choices = plan.ambiguityCandidates.map { candidate -> Candidate in
                if candidate.source == .gedcom {
                    // Same-name family-tree people (Sr./Jr.) need labels the
                    // user can tell apart; mirror the graph path's
                    // birth/death or pointer suffix.
                    let label = graph?.people[candidate.id].map {
                        ArchivistBiographyPolicy.disambiguationCandidate(
                            for: $0).label
                    } ?? "\(candidate.canonicalName) (\(candidate.id))"
                    return Candidate(
                        id: .gedcomPersonID(candidate.id),
                        canonicalName: candidate.canonicalName,
                        label: label)
                }
                return Candidate(
                    id: .cyberBrainPersonID(candidate.id),
                    canonicalName: candidate.canonicalName,
                    label: cyberBrainLabel(candidate, plan: plan,
                                           index: index, graph: graph))
            }
            let stage: ClarificationStage = choices.first?.source == .gedcom
                ? .gedcomPerson : .cyberBrainPerson
            return Result(
                route: .graph,
                outcome: .needsClarification,
                prose: CyberBrainDeterministicComposer.compose(plan),
                basisLine: "Basis: identity was not resolved; no biography claims were selected.",
                queryDescription: queryDescription,
                citations: [],
                knowledgeCitations: knowledgeCitations,
                catalogPersonName: nil,
                clarification: Clarification(
                    intent: request.intent,
                    stage: stage,
                    candidates: choices,
                    continuationToken: context.continuationToken))
        }

        let answered = plan.answerState == .answered
            || plan.answerState == .disputed
        return Result(
            route: .graph,
            outcome: answered ? .answered : .declined,
            prose: CyberBrainDeterministicComposer.compose(plan),
            basisLine: knowledgeCitations.isEmpty
                ? "Basis: Breen Family CyberBrain; no supporting source was selected."
                : "Basis: Breen Family CyberBrain; \(knowledgeCitations.count) supporting source\(knowledgeCitations.count == 1 ? "" : "s").",
            queryDescription: queryDescription,
            citations: [],
            knowledgeCitations: knowledgeCitations,
            catalogPersonName: answered ? plan.subject : nil)
    }

    /// Non-biography graph operations (kinship, birth, death) routed through
    /// CyberBrain identity resolution and then answered by the deterministic
    /// GEDCOM executor by pointer. Returns `nil` when CyberBrain does not know
    /// the name (or knows it but has no family-tree link), so the caller
    /// continues on the profiles + GEDCOM path unchanged.
    private static func executeCyberBrainBridgedGraph(
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        index: CyberBrainIndex,
        dependencies: Dependencies
    ) async throws -> Result? {
        // Multi-subject and empty-name validation belongs to the graph
        // executor; only a single, non-blank name is bridged here.
        guard payload.people.count == 1,
              let requestedName = payload.people.first?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedName.isEmpty,
              let graph = context.graph else {
            return nil
        }
        let queryDescription =
            "shape=graph operation=\(payload.operation.rawValue) "
            + "person=\(payload.people.joined(separator: ","))"

        let person: CyberBrainPerson
        switch request.selectedIdentity {
        case nil:
            switch index.resolve(requestedName) {
            case .notFound:
                return nil
            case .resolved(let resolved):
                guard resolved.gedcomPersonID.flatMap({ graph.people[$0] })
                        != nil else {
                    return nil
                }
                person = resolved
            case .ambiguous(let people):
                let linked = people.filter {
                    $0.gedcomPersonID.flatMap { graph.people[$0] } != nil
                }
                guard !linked.isEmpty else { return nil }
                let choices = linked.map { candidate in
                    Candidate(
                        id: .cyberBrainPersonID(candidate.id),
                        canonicalName: candidate.canonicalName,
                        label: bridgedLabel(candidate, among: linked,
                                            graph: graph))
                }
                return Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: "Which \(requestedName) do you mean?",
                    basisLine: "Basis: Breen Family CyberBrain knows more than one person by that name; no family fact was selected.",
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: Clarification(
                        intent: request.intent,
                        stage: .cyberBrainPerson,
                        candidates: choices,
                        continuationToken: context.continuationToken))
            }
        case .cyberBrainPersonID(let personID):
            guard let selected = index.person(id: personID) else {
                return invalidContinuationResult(for: request.intent.ast)
            }
            person = selected
        case .gedcomPersonID, .profileStableID:
            return nil
        }

        guard let gedcomID = person.gedcomPersonID,
              let gedcomPerson = graph.people[gedcomID] else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I know \(person.canonicalName) from the family archive, but they aren't linked to the imported family tree, so I can't answer that reliably.",
                basisLine: "Basis: Breen Family CyberBrain identity without a GEDCOM link; family tree not consulted.",
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil)
        }

        let query = ArchivistGraphQuery(payload)
        let inputs = ArchivistGraphInputs(
            graph: graph, profiles: [] as [ArchivistGraphProfileSnapshot])
        let execute = dependencies.executeGraph
        let result = try await detached {
            execute(query, inputs, .gedcomPersonID(gedcomID))
        }
        // Prepend the identity bridge to the executor's own basis line so the
        // answer states how "rick" became a GEDCOM person, mirroring the
        // profile-bridge wording on the profiles + GEDCOM path.
        let bridge = "Breen Family CyberBrain identity “"
            + requestedName + "” → “" + person.canonicalName + "” → GEDCOM “"
            + gedcomPerson.name + "”; "
        var basis = result.basisLine
        for prefix in ["Basis: ", "Checked: "] where basis.hasPrefix(prefix) {
            basis = prefix + bridge + basis.dropFirst(prefix.count)
            break
        }
        return Result(
            route: .graph,
            outcome: result.conclusion == .answered ? .answered : .declined,
            prose: result.prose,
            basisLine: basis,
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: result.catalogPersonName)
    }

    /// Chip label for a CyberBrain candidate. Same-name people (Sr./Jr.)
    /// get the linked GEDCOM birth/death detail, mirroring the graph path's
    /// disambiguation labels; without a family-tree link the stable ID is
    /// appended. Shared by the biography and kinship/birth/death routes so
    /// the two clarifications read identically.
    private static func bridgedLabel(
        _ candidate: CyberBrainPerson,
        among candidates: [CyberBrainPerson],
        graph: GedcomFamilyGraph?
    ) -> String {
        let key = PersonResolver.normalize(candidate.canonicalName)
        let duplicates = candidates.filter {
            PersonResolver.normalize($0.canonicalName) == key
        }.count
        guard duplicates > 1 else { return candidate.canonicalName }
        if let gedcomID = candidate.gedcomPersonID,
           let person = graph?.people[gedcomID] {
            let detail = ArchivistBiographyPolicy
                .disambiguationCandidate(for: person).label
            // Keep the CyberBrain canonical name in front so the chip still
            // reads as the person the archive knows.
            if detail.hasPrefix(person.name), detail.count > person.name.count {
                return candidate.canonicalName
                    + String(detail.dropFirst(person.name.count))
            }
            return detail
        }
        return "\(candidate.canonicalName) (\(candidate.id))"
    }

    /// Biography-route wrapper over `bridgedLabel` for planner candidates.
    private static func cyberBrainLabel(
        _ candidate: CyberBrainAnswerPlan.Candidate,
        plan: CyberBrainAnswerPlan,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph?
    ) -> String {
        let people = plan.ambiguityCandidates
            .filter { $0.source == .cyberBrain }
            .compactMap { index.person(id: $0.id) }
        guard let person = index.person(id: candidate.id) else {
            return "\(candidate.canonicalName) (\(candidate.id))"
        }
        return bridgedLabel(person, among: people, graph: graph)
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

        case .cyberBrainPersonID(let personID):
            guard let person = context.cyberBrain?.person(id: personID) else {
                return false
            }
            return PersonResolver.normalize(person.canonicalName)
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
