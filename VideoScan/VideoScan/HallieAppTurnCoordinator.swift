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

    struct TurnInterpretation: Sendable {
        let value: HallieTurnInterpretation
        let responderHost: String
    }

    struct SocialReply: Sendable {
        let value: HallieSocialConversation.Reply
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

        /// The same pending question over a subset of its own choices
        /// (a typed reply that fits several). Nil if the subset is not
        /// drawn from this clarification.
        func narrowed(to subset: [HallieTurnExecutor.Candidate]) -> PendingClarification? {
            guard let narrowed = clarification.narrowed(to: subset) else { return nil }
            return PendingClarification(
                clarification: narrowed, context: context,
                responderHost: responderHost, capturedReferentID: capturedReferentID,
                composition: composition)
        }
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
        /// The listening session to carry into the next turn while a family
        /// member is telling Hallie about someone; nil otherwise.
        var telling: HallieTellingMode.Session? = nil
        /// The name drill in progress ("let's practice names",
        /// HalliePronunciationDrillMode) to carry into the next turn; nil
        /// when none, or when this turn ended it.
        var drill: HalliePronunciationDrillMode.Session? = nil
        /// The variations picker's offer ("here are a few ways to say
        /// Latta", HalliePronunciationPicker) to carry into the next turn;
        /// nil when none, or when this turn resolved or dropped it.
        var picker: HalliePronunciationPicker.Offer? = nil
        /// When set, the voice says THIS instead of `prose`: text that
        /// already carries misaki `[Word](/phonemes/)` overrides (the offer
        /// spoken candidate by candidate). `pickerSpeechFallback` is the
        /// same for the Apple voice, which cannot read the override syntax.
        var pickerSpeech: String? = nil
        var pickerSpeechFallback: String? = nil
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
        let interpretTurn: @Sendable (
            String, [String], String
        ) async throws -> TurnInterpretation
        let composeConversation: @Sendable (
            HallieConversationKind,
            String,
            [HallieGroundedComposer.HistoryTurn],
            [String],
            String
        ) async -> SocialReply
        let loadProfiles: @Sendable () -> [HallieTurnExecutor.ProfileSnapshot]?
        let loadGraph: @Sendable () -> GedcomFamilyGraph?
        /// The pulls behind a compiled tree this version refused (live
        /// miss #8); consulted only when `loadGraph` returned nil. Default
        /// = none, so tests without a store never see a recompile offer.
        let loadNeedsRecompile: @Sendable () -> [URL]
        let loadCyberBrain: @Sendable () -> CyberBrainIndex?
        /// Durably record one told passage (HallieTellingMode). The default
        /// records nothing so tests never touch the real CyberBrain; live
        /// writes through CyberBrainWriter.
        let recordTestimony: @Sendable (CyberBrainWriter.Testimony) throws -> Void
        /// Durably record a photo caption ("this photo is me and Donna",
        /// 2026-08-26). Default records nothing; live writes through
        /// CyberBrainWriter.
        let recordPhotoCaption: @Sendable (CyberBrainWriter.PhotoCaption) throws -> Void
        /// Durably keep how a name is said ("Nathaniel is pronounced …",
        /// 2026-08-26). Default records nothing; live writes through
        /// CyberBrainWriter.setPronunciation or pronunciations.json.
        let recordPronunciation: @Sendable (PronunciationWrite) throws -> Void
        /// The name drill's sheet (2026-08-29): the judged status per name,
        /// loaded once per drill turn and saved explicitly after a change.
        /// Defaults keep everything in memory so tests never touch
        /// Hallie/pronunciation-drill.json; live reads and writes it.
        let loadDrillStore: @Sendable () -> PronunciationDrillStore
        let saveDrillStore: @Sendable (PronunciationDrillStore, PronunciationDrillManifest) throws -> Void
        /// What the voice currently has (people → file → shipped), so the
        /// sheet leaves out names already taught. Default = shipped table.
        let loadLexicon: @Sendable () -> HalliePronunciationLexicon
        /// Misaki's optional exemplar table for picker hints such as
        /// "rhymes with data". Injectable so tests and headless installs
        /// never depend on this Mac's helper bundle.
        let loadPronunciationGold: @Sendable () -> MisakiGoldLexicon
        /// Mark a photo as NOT showing a tree person (photo, GEDCOM ID,
        /// noted by, caption). Default does nothing; live writes the
        /// `.notof.json` sidecar through FamilyAssetStore.
        let excludePhoto: @Sendable (URL, String, String?, String?) throws -> Void
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
            interpretTurn: (@Sendable (
                String, [String], String
            ) async throws -> TurnInterpretation)? = nil,
            composeConversation: (@Sendable (
                HallieConversationKind,
                String,
                [HallieGroundedComposer.HistoryTurn],
                [String],
                String
            ) async -> SocialReply)? = nil,
            loadProfiles: @escaping @Sendable () -> [HallieTurnExecutor.ProfileSnapshot]?,
            loadGraph: @escaping @Sendable () -> GedcomFamilyGraph?,
            loadNeedsRecompile: @escaping @Sendable () -> [URL] = { [] },
            loadCyberBrain: @escaping @Sendable () -> CyberBrainIndex? = { nil },
            recordTestimony: @escaping @Sendable (CyberBrainWriter.Testimony) throws -> Void = { _ in },
            recordPhotoCaption: @escaping @Sendable (CyberBrainWriter.PhotoCaption) throws -> Void = { _ in },
            recordPronunciation: @escaping @Sendable (PronunciationWrite) throws -> Void = { _ in },
            loadDrillStore: @escaping @Sendable () -> PronunciationDrillStore = { PronunciationDrillStore() },
            saveDrillStore: @escaping @Sendable (PronunciationDrillStore, PronunciationDrillManifest) throws -> Void = { _, _ in },
            loadLexicon: @escaping @Sendable () -> HalliePronunciationLexicon = { .shipped },
            loadPronunciationGold: @escaping @Sendable () -> MisakiGoldLexicon = { .empty },
            excludePhoto: @escaping @Sendable (URL, String, String?, String?) throws -> Void = { _, _, _, _ in },
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
            self.interpretTurn = interpretTurn ?? { question, hosts, model in
                let translation = try await translateAST(question, hosts, model)
                return TurnInterpretation(
                    value: .archive(translation.ast),
                    responderHost: translation.responderHost)
            }
            self.composeConversation = composeConversation ?? {
                kind, question, history, _, _ in
                let reply = await HallieSocialConversation.reply(
                    kind: kind, question: question, history: history,
                    modelCall: { _, _ in
                        throw NLTranslatorError.unreachable(
                            "no social conversation model configured")
                    })
                return SocialReply(value: reply, responderHost: localResponder)
            }
            self.loadProfiles = loadProfiles
            self.loadGraph = loadGraph
            self.loadNeedsRecompile = loadNeedsRecompile
            self.loadCyberBrain = loadCyberBrain
            self.recordTestimony = recordTestimony
            self.recordPhotoCaption = recordPhotoCaption
            self.recordPronunciation = recordPronunciation
            self.loadDrillStore = loadDrillStore
            self.saveDrillStore = saveDrillStore
            self.loadLexicon = loadLexicon
            self.loadPronunciationGold = loadPronunciationGold
            self.excludePhoto = excludePhoto
            self.loadSpeakers = loadSpeakers
            self.executeRequest = executeRequest
            self.continueTurn = continueTurn
            self.resolveBiographyPhoto = resolveBiographyPhoto
            self.composeAnswer = composeAnswer
        }

        private static let productionApplicationSupportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first

        static let live = makeLive(
            productionApplicationSupportRoot,
            HallieLiveAssetStoreFactory {
                FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
            })

        /// Production dependencies with injectable write roots for the
        /// viewer sensor. The app's singleton uses the same roots/stores as
        /// before; tests supply temporary ones and never name real support.
        static let makeLive: @Sendable (URL?, HallieLiveAssetStoreFactory) -> Dependencies = { applicationSupportRoot, makeAssetStore in
            let roots = HallieLiveDependencyRoots(
                applicationSupportRoot: applicationSupportRoot)
            return Dependencies(
            startLocalBrain: { hosts in
                _ = try await OllamaLocalServerBootstrap.shared
                    .ensureRunning(for: hosts)
                return OllamaLocalServerBootstrap
                    .routeLocalEndpointsToLoopback(hosts)
            },
            translateAST: { question, hosts, modelName in
                let responder = HallieLiveResponderBox()
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
            interpretTurn: { question, hosts, modelName in
                let responder = HallieLiveResponderBox()
                var template = OllamaQueryTranslator()
                template.model = modelName
                let translator = OllamaFailoverTranslator(
                    hosts: hosts,
                    template: template,
                    onResponder: { responder.set($0) })
                let value = try await translator.interpretTurn(question)
                return TurnInterpretation(
                    value: value,
                    responderHost: responder.value ?? "unknown")
            },
            composeConversation: { kind, question, history, hosts, modelName in
                let responder = HallieLiveResponderBox()
                var template = OllamaQueryTranslator()
                template.model = modelName
                let fleet = OllamaFailoverTranslator(
                    hosts: OllamaLocalServerBootstrap
                        .routeLocalEndpointsToLoopback(hosts),
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
                        ? (responder.value ?? "unknown") : localResponder)
            },
            loadProfiles: {
                switch HallieShellCLI.loadProfilesReadOnly() {
                case .loaded(let profiles):
                    return profiles.map {
                        HallieTurnExecutor.ProfileSnapshot(
                            stableID: $0.id,
                            canonicalName: $0.name,
                            aliases: $0.aliases,
                            birthdate: $0.birthdate, note: $0.notes,
                            kinships: $0.kinships, sex: $0.sex, uuid: $0.uuid,
                            treeIdentity: $0.treeIdentity)
                    }
                case .unavailable:
                    return nil
                }
            },
            loadGraph: {
                // Promoted artifact only, one decode per process (codex #792).
                FamilyGraphSharedCache.shared.graph(
                    for: FamilyAssetConfigurationCenter.shared.snapshot(),
                    store: .app)
            },
            loadNeedsRecompile: {
                FamilyGraphSharedCache.shared.needsRecompile(
                    for: FamilyAssetConfigurationCenter.shared.snapshot(),
                    store: .app)
            },
            loadCyberBrain: {
                guard let root = roots.cyberBrain else { return nil }
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
            recordTestimony: { testimony in
                try ViewerWriteGuard.check("HallieAppTurnCoordinator.recordTestimony")
                guard let root = roots.cyberBrain else {
                    throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
                }
                let receipt = try CyberBrainWriter.record(testimony, rootURL: root)
                appLog.write("Hallie: kept testimony \(receipt.itemID) about \(receipt.canonicalName) (told by \(testimony.speakerName))")
            },
            recordPhotoCaption: { caption in
                try ViewerWriteGuard.check("HallieAppTurnCoordinator.recordPhotoCaption")
                guard let root = roots.cyberBrain else {
                    throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
                }
                let receipt = try CyberBrainWriter.record(caption: caption, rootURL: root)
                appLog.write("Hallie: kept photo caption \(receipt.itemID) for \(caption.subjects.count) people (\(caption.photoPath))")
            },
            recordPronunciation: { write in
                try recordPronunciationLive(
                    write, cyberBrainRootURL: roots.cyberBrain,
                    fileURL: roots.pronunciationFile)
            },
            loadDrillStore: {
                roots.drillFile.map { PronunciationDrillStore.load(from: $0) }
                    ?? PronunciationDrillStore()
            },
            saveDrillStore: { store, manifest in
                try ViewerWriteGuard.check("HallieAppTurnCoordinator.saveDrillStore")
                guard let drillFile = roots.drillFile else {
                    throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
                }
                try store.save(to: drillFile, manifest: manifest)
            },
            loadLexicon: {
                guard let pronunciationFile = roots.pronunciationFile else { return .shipped }
                if ViewerModeCenter.shared.isViewer,
                   !FileManager.default.fileExists(atPath: pronunciationFile.path) {
                    ViewerWriteGuard.refuse("HallieAppTurnCoordinator.loadLexiconDefault")
                    return .shipped
                }
                return HalliePronunciationLexicon.resolved(
                    fileURL: pronunciationFile,
                    cyberBrainRootURL: roots.cyberBrain)
            },
            loadPronunciationGold: { .shared },
            excludePhoto: { photo, gedcomID, notedBy, caption in
                try ViewerWriteGuard.check("HallieAppTurnCoordinator.excludePhoto")
                let store = makeAssetStore()
                let sidecar = try store.excludePhoto(
                    photo, from: gedcomID, notedBy: notedBy, caption: caption)
                appLog.write("Hallie: photo marked not-of \(gedcomID) → \(sidecar.path)")
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
        telling: HallieTellingMode.Session? = nil,
        drill: HalliePronunciationDrillMode.Session? = nil,
        picker: HalliePronunciationPicker.Offer? = nil,
        dependencies: Dependencies = .live
    ) async throws -> Response {
        try Task.checkCancellation()

        // The variations picker ("here are a few ways to say Latta",
        // 2026-08-29) owns a number / "none of these" while its offer is
        // up, and "say Latta a few ways" opens it. Anything else steps out
        // of it (the drill or ordinary answering takes the turn).
        if let handled = pickerResponse(
            question: question, picker: picker, drill: drill, telling: telling,
            referent: referent, dependencies: dependencies) {
            return handled
        }
        // The name drill ("let's practice names", 2026-08-29) owns the turn
        // while it runs: judgements, corrections, skip, stop. A question
        // steps out of it and falls through.
        if let handled = drillResponse(
            question: question, drill: drill, telling: telling,
            referent: referent, dependencies: dependencies) {
            return handled
        }
        // "Nathaniel is pronounced …" is one word, one respelling; it is
        // kept and confirmed even mid-interview (the session rides through).
        if let handled = pronunciationResponse(
            question: question, telling: telling,
            referent: referent, dependencies: dependencies) {
            return handled
        }
        // Listening comes first: while a family member is telling Hallie
        // about someone, the turn is theirs to classify; a question ends
        // the telling and falls through to ordinary answering.
        if let handled = tellingResponse(
            question: question, telling: telling,
            referent: referent, dependencies: dependencies) {
            return handled
        }
        // "This photo is me and my family" right after a photo was shown is
        // a caption (and maybe a correction), never a search (2026-08-26).
        if let handled = photoCaptionResponse(
            question: question, memory: memory,
            referent: referent, dependencies: dependencies) {
            return handled
        }

        let repair = HallieSpellingRecovery.repairRequestOpener(question)
        let routingQuestion = repair.text
        if let original = repair.originalWord,
           let replacement = repair.replacementWord {
            appLog.write(
                "Hallie: repaired request opener “\(original)” → “\(replacement)”")
        }

        // Identity sources are loaded lazily and off-main, only if the
        // resolver actually needs to ask "is 'matt' a person?".
        // Catalog-wide counts ("how many are archived") are answered from a
        // snapshot of the records this turn already holds; computed only
        // when the question is one of those (O(records), milliseconds).
        let catalogStats = HallieCatalogStats.detect(routingQuestion) != nil
            ? HallieCatalogStats.compute(records: records) : nil
        let preTranslation = try await preTranslationOffMain(
            question: routingQuestion, playAfterAnswer: playAfterAnswer,
            memory: memory, catalogStats: catalogStats, dependencies: dependencies)
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
            let certainConversation = try await definitelyGeneralOffMain(
                question: effectiveQuestion, dependencies: dependencies)
            let interpretation: TurnInterpretation
            if let kind = certainConversation {
                interpretation = TurnInterpretation(
                    value: .conversation(kind), responderHost: localResponder)
            } else {
                interpretation = try await dependencies.interpretTurn(
                    effectiveQuestion, effectiveHosts, modelName)
            }
            try Task.checkCancellation()
            switch interpretation.value {
            case .archive(let ast):
                intent = HallieTurnExecutor.Intent(
                    originalQuestion: question,
                    ast: ast,
                    playAfterAnswer: wantsPlay)
                responderHost = interpretation.responderHost

            case .conversation(let kind):
                let requiresArchive = try await conversationRequiresArchiveOffMain(
                    question: effectiveQuestion,
                    kind: kind,
                    dependencies: dependencies)
                try Task.checkCancellation()
                if requiresArchive {
                    // False-social is the dangerous direction. Retry with the
                    // archive-only schema rather than letting free text answer
                    // a private-person or evidence question.
                    let translation = try await dependencies.translateAST(
                        effectiveQuestion, effectiveHosts, modelName)
                    intent = HallieTurnExecutor.Intent(
                        originalQuestion: question,
                        ast: translation.ast,
                        playAfterAnswer: wantsPlay)
                    responderHost = translation.responderHost
                } else {
                    let social = await dependencies.composeConversation(
                        kind, routingQuestion, history, effectiveHosts, modelName)
                    try Task.checkCancellation()
                    let result = HallieSocialConversation.result(for: social.value)
                    return Response(
                        result: result,
                        responderHost: social.responderHost,
                        biographyPhoto: nil,
                        capturedReferentID: referent.recordID,
                        citations: [],
                        pendingClarification: nil,
                        playAfterAnswer: false,
                        executedIntent: nil)
                }
            }
        }
        let composition = Composition(
            enabled: composeWithModel,
            hosts: composeHosts,
            modelName: modelName,
            // Factual phrasing gets the current typed plan only. Social
            // history belongs exclusively to composeConversation above; it
            // must never bleed an uncited chat sentence into archive prose.
            history: [])

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
        catalogStats: HallieCatalogStats? = nil,
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
                let graph = dependencies.loadGraph()
                let context = HallieTurnExecutor.Context(
                    profiles: dependencies.loadProfiles(),
                    graph: graph,
                    needsRecompile: graph == nil ? dependencies.loadNeedsRecompile() : [],
                    cyberBrain: dependencies.loadCyberBrain(),
                    // Owner binding (2026-08-24 live spot-test): without it
                    // "trace MY maternal line" asks "whose line?" in the app
                    // while the shell answers. Same source as the full path.
                    speakers: dependencies.loadSpeakers())
                loaded = context
                return context
            }
            return HallieTurnExecutor.preTranslation(
                question: question,
                playAfterAnswer: playAfterAnswer,
                memory: memory,
                isKnownPerson: { name in
                    HallieTurnExecutor.isKnownPerson(name, context: sources())
                },
                catalogStats: catalogStats,
                rosterAnswer: { HallieTurnExecutor.PeopleTab.rosterAnswer(context: sources()) },
                lineageAnswer: { HallieLineageAnswer.answer($0, context: sources()) },
                relationshipsOverview: { HallieRelationshipsOverview.answer($0, context: sources()) },
                researchAnswer: { HallieResearchQuestion.answer($0, context: sources()) })
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func conversationRequiresArchiveOffMain(
        question: String,
        kind: HallieConversationKind,
        dependencies: Dependencies
    ) async throws -> Bool {
        let worker = Task.detached(priority: .userInitiated) {
            () throws -> Bool in
            try Task.checkCancellation()
            let context = HallieTurnExecutor.Context(
                profiles: dependencies.loadProfiles(),
                graph: dependencies.loadGraph(),
                cyberBrain: dependencies.loadCyberBrain())
            return HallieConversationGuard.requiresArchive(
                question,
                kind: kind,
                isKnownPerson: {
                    HallieTurnExecutor.isKnownPerson($0, context: context)
                })
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func definitelyGeneralOffMain(
        question: String,
        dependencies: Dependencies
    ) async throws -> HallieConversationKind? {
        let worker = Task.detached(priority: .userInitiated) {
            () throws -> HallieConversationKind? in
            try Task.checkCancellation()
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
            return HallieConversationGuard.definitelyGeneral(
                question,
                isKnownPerson: {
                    HallieTurnExecutor.isKnownPerson($0, context: sources())
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
        case .temporal, .graph, .unsupportedEvent, .followUp, .capability,
             .help, .smalltalk, .conversation, .telling, .reset:
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
            var needsRecompile: [URL] = []
            let cyberBrain: CyberBrainIndex?
            switch route {
            case .temporal, .aggregate:
                profiles = dependencies.loadProfiles()
                graph = nil
                cyberBrain = nil
            case .graph:
                profiles = dependencies.loadProfiles()
                graph = dependencies.loadGraph()
                if graph == nil { needsRecompile = dependencies.loadNeedsRecompile() }
                cyberBrain = dependencies.loadCyberBrain()
            case .presence, .cross:
                // People + CyberBrain provide the closed vocabulary for safe
                // spelling recovery ("rick brren" → profile tag "Rick").
                // GEDCOM is larger and remains age-phrase-only here.
                profiles = dependencies.loadProfiles()
                // A photo ask needs the tree too: the portrait / photography
                // floor path resolves the person there (+PhotoAsk).
                graph = needsBirthYear || HallieTurnExecutor.isPhotoAsk(ast)
                    ? dependencies.loadGraph() : nil
                cyberBrain = dependencies.loadCyberBrain()
            case .unsupportedEvent, .followUp, .capability, .help, .smalltalk,
                 .conversation, .telling, .reset:
                profiles = []
                graph = nil
                cyberBrain = nil
            }
            // Derivable-but-unconfirmed identities (2026-08-29): an unpinned
            // profile the deriver is CERTAIN about bridges for this turn,
            // and the answer says "(taking Rick as …)". Pinned / stale /
            // colliding pins are untouched — they still fail closed.
            var assumed: [String: String] = [:]
            var bridgedProfiles = profiles
            if route == .graph, let graph, let snapshots = profiles {
                let speakers = dependencies.loadSpeakers()
                let result = TreeIdentityDeriver.assumingCertainPins(
                    snapshots: snapshots, graph: graph,
                    ownerName: speakers.ownerName,
                    ownerFamilySearchID: speakers.ownerFamilySearchID)
                bridgedProfiles = result.snapshots
                assumed = result.assumed
            }
            let context = HallieTurnExecutor.Context(
                presenceRecords: presenceRecords,
                aggregateRecords: aggregateRecords,
                profiles: bridgedProfiles,
                graph: graph,
                needsRecompile: needsRecompile,
                cyberBrain: cyberBrain,
                selectedTemporalDate: selectedDate,
                speakers: dependencies.loadSpeakers(),
                assumedTreeBridges: assumed)
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
                    for line in HallieGroundedComposer.droppedLogLines(outcome.dropped, plan: plan) {
                        appLog.write(line)
                    }
                    for line in HallieGroundedComposer.verifyLogLines(outcome, plan: plan) {
                        appLog.write(line)
                    }
                }
            }
            try Task.checkCancellation()

            let photo: ArchivistBiographyPhoto?
            if result.clarification == nil,
               case .graph(let payload) = ast,
               payload.operation == .biography,
               let canonicalName = result.catalogPersonName {
                photo = dependencies.resolveBiographyPhoto(canonicalName)
                if photo == nil, result.outcome == .answered {
                    var assets = FamilyAssetConfigurationCenter.shared
                        .snapshot().makeStore()
                    if let graph = context.graph {
                        // Identity-aware group folders (2026-08-26): who
                        // "Rick" in RickDonnaBreenFamily is — the owner, by
                        // FamilySearch ID / CyberBrain / People-tab aliases —
                        // never a same-first-name relative. Published so the
                        // lineage and tree cards share the same reading.
                        let directory = FamilyAssetIdentityDirectory(
                            graph: graph, speakers: context.speakers,
                            cyberBrain: context.cyberBrain, profiles: context.profiles)
                        assets.identity = directory
                        FamilyAssetConfigurationCenter.shared.publishIdentity(directory)
                    }
                    let graphMatches = context.graph?.people.values.filter {
                        $0.name.compare(
                            canonicalName,
                            options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    } ?? []
                    // One decision for the picture beside a biography
                    // (HallieBiographyPhotoOffer): the family's file, the
                    // folder card, or nothing for someone who predates
                    // photography (Rick 2026-08-26).
                    let decision = HallieBiographyPhotoOffer.decide(
                        canonicalName: canonicalName, graphMatches: graphMatches, assets: assets)
                    if !decision.attachments.isEmpty {
                        result = result.adding(attachments: decision.attachments)
                    }
                    if let note = decision.suppressedNote {
                        appLog.write("[hallie] photo offer suppressed: \(canonicalName) (\(note))")
                    }
                    if let error = decision.folderError {
                        // Photo presentation is optional.  Preserve the
                        // grounded biography and record why no request card
                        // was offered; never reinterpret the failed write.
                        appLog.write("Hallie: photo request unavailable for \(canonicalName): \(error)")
                    }
                }
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
