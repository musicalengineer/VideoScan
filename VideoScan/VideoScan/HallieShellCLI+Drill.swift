// HallieShellCLI+Drill.swift
// The shell's side of the name drill (HalliePronunciationDrillMode). Same
// decisions and wording as the chat window; no audio — the text loop is
// what codex's nightly lane and Rick's `hallie` terminal see. Writes (the
// lexicon entry and the sheet) happen only with `--remember`, like told
// passages: the shell is a read-only diagnostic surface by default and an
// unattended evaluation corpus must never edit Rick's pronunciations.

import Foundation
import VideoScanCore

extension HallieShellCLI {

    /// Handle the turn if it starts or continues a drill. Nil when the turn
    /// is not the drill's (the caller answers it; a running drill that was
    /// stepped out of is closed quietly).
    static func drillTurn(
        _ text: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome? {
        typealias Mode = HalliePronunciationDrillMode
        if var session = state.drill {
            var store = dependencies.loadDrillStore()
            switch Mode.classify(text, session: session) {
            case .leave:
                HallieAppTurnCoordinator.logSession(session)
                state.drill = nil
                return nil
            case .start:
                return await emit(Mode.openingReply(session, remaining: session.remaining(store: store), resumed: true),
                                  state: &state, output: output, dependencies: dependencies)
            case .unrecognized:
                // A bare "no" with no respelling: offer a few ways to say
                // the name (the picker) instead of asking for a spelling.
                if let item = session.current, HalliePronunciationPicker.isBareNo(text) {
                    return await offerInShell(word: item.name, hint: nil, respellings: [], round: 0, fromDrill: true,
                                              state: &state, output: output, dependencies: dependencies)
                }
                return await emit(Mode.unrecognizedReply(session), state: &state, output: output, dependencies: dependencies)
            case .stop:
                HallieAppTurnCoordinator.logSession(session)
                state.drill = nil
                return await emit(Mode.closingReply(session, nextName: session.current?.name),
                                  state: &state, output: output, dependencies: dependencies)
            case .judgedOk:
                guard let item = session.current else { return await end(session, state: &state, output: output, dependencies: dependencies) }
                store.set(item, status: .judgedOk)
                session.judgedOk += 1
                advance(&session, store: store)
                let note = save(store, session: session, options: options, dependencies: dependencies)
                return await step(Mode.judgedOkReply(session) + note, session: session, state: &state, output: output, dependencies: dependencies)
            case .skip:
                guard let item = session.current else { return await end(session, state: &state, output: output, dependencies: dependencies) }
                store.set(item, status: .skipped)
                session.skipped += 1
                advance(&session, store: store)
                let note = save(store, session: session, options: options, dependencies: dependencies)
                return await step(Mode.skippedReply(session) + note, session: session, state: &state, output: output, dependencies: dependencies)
            case .next:
                advance(&session, store: store)
                return await step(Mode.nextReply(session), session: session, state: &state, output: output, dependencies: dependencies)
            case .hint(let hinted):
                let key = FamilyIdentityText.normalized(hinted.word)
                guard session.current?.key == key || session.list.items.contains(where: { $0.key == key })
                        || dependencies.loadLexicon().entries.contains(where: { FamilyIdentityText.normalized($0.written) == key }) else {
                    return await emit(Mode.unrecognizedReply(session), state: &state, output: output, dependencies: dependencies)
                }
                guard let respelling = HalliePronunciationRespelling.respelling(for: hinted.word, hint: hinted.hint) else {
                    if let item = session.list.items.first(where: { $0.key == key }) {
                        store.set(item, status: store.status(for: key), hint: hinted.hint.description)
                    } else {
                        store.set(name: hinted.word, status: store.status(for: key), hint: hinted.hint.description)
                    }
                    _ = save(store, session: session, options: options, dependencies: dependencies)
                    // Not mappable: offer a few ways built from the hint.
                    let word = session.list.items.first(where: { $0.key == key })?.name
                        ?? knownSpelling(hinted.word, state: state, dependencies: dependencies) ?? hinted.word
                    return await offerInShell(word: word, hint: hinted.hint, respellings: [], round: 0, fromDrill: true,
                                              state: &state, output: output, dependencies: dependencies,
                                              prefix: "I've noted \u{201C}\(hinted.hint.description)\u{201D} for \(word). ")
                }
                return await teachInDrill(.init(word: hinted.word, alternatives: [respelling]), hint: hinted.hint, session: session,
                                          store: store, options: options, state: &state, output: output, dependencies: dependencies)
            case .teach(let correction):
                return await teachInDrill(correction, hint: nil, session: session, store: store,
                                          options: options, state: &state, output: output, dependencies: dependencies)
            }
        }

        guard Mode.detectStart(text) else { return nil }
        return await startDrill(options: options, state: &state, output: output, dependencies: dependencies)
    }

    private static func teachInDrill(
        _ correction: HalliePronunciationDrillMode.Correction,
        hint: HalliePronunciationHint?,
        session: HalliePronunciationDrillMode.Session,
        store: PronunciationDrillStore,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        typealias Mode = HalliePronunciationDrillMode
        var session = session
        var store = store
        let origin: PronunciationDrillStore.Origin = hint == nil ? .taught : .derived
                guard let word = correction.word ?? session.current?.name else {
                    return await end(session, state: &state, output: output, dependencies: dependencies)
                }
                let saidAs = HalliePronunciationLexicon.joinedAlternatives(correction.alternatives)
                let phonemes = HallieAppTurnCoordinator.derivePhonemes(alternatives: correction.alternatives, hint: hint)
                var note = ""
                if options.remember {
                    let target = HallieAppTurnCoordinator.resolvePronunciationTarget(
                        word: word, cyberBrain: state.cyberBrain, graph: state.graph)
                    do {
                        try dependencies.recordPronunciation(.init(word: word, saidAs: saidAs, phonemes: phonemes, target: target))
                        HallieAppTurnCoordinator.logTaught(word: word, saidAs: saidAs + (phonemes.map { " /\($0)/" } ?? ""))
                    } catch {
                        return await emit(
                            Mode.failedTeachReply(word: word, error: error.localizedDescription, session: session),
                            state: &state, output: output, dependencies: dependencies)
                    }
                } else {
                    note = " (Kept for this session only — run with --remember to save it.)"
                }
                let status: PronunciationDrillStatus = correction.alternatives.count > 1 ? .alternativesPending : .taught
                let key = FamilyIdentityText.normalized(word)
                if let item = session.list.items.first(where: { $0.key == key }) {
                    store.set(item, status: status, alternatives: correction.alternatives, phonemes: phonemes, origin: origin, hint: hint?.description)
                } else {
                    store.set(name: word, status: status, alternatives: correction.alternatives, phonemes: phonemes, origin: origin, hint: hint?.description)
                }
                session.taught += 1
                let movedOn = session.current?.key == key
                if movedOn { advance(&session, store: store) }
                note += save(store, session: session, options: options, dependencies: dependencies)
                return await step(
                    Mode.taughtReply(word: word, alternatives: correction.alternatives, hint: hint, session: session, movedOn: movedOn) + note,
                    session: session, state: &state, output: output, dependencies: dependencies)
    }

    /// Build the sheet and put the first pending name.
    private static func startDrill(
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        typealias Mode = HalliePronunciationDrillMode
        state.pendingClarification = nil
        let store = dependencies.loadDrillStore()
        let list = PronunciationDrillList.build(
            graph: state.graph,
            profiles: state.identityContext.profiles ?? [],
            speakers: dependencies.speakers(),
            lexicon: dependencies.loadLexicon(),
            store: store)
        var session = Mode.Session(list: list, index: nil)
        session.index = list.nextPending(from: 0, store: store)
        let resumed = store.names.values.contains { $0.status != .untested }
        guard session.current != nil else {
            return await emit(Mode.exhaustedReply(session), state: &state, output: output, dependencies: dependencies)
        }
        appLog.write("[hallie-voice] drill: started — \(list.items.count) names on the sheet, \(session.remaining(store: store)) pending\(resumed ? " (resumed)" : "")")
        state.drill = session
        return await emit(Mode.openingReply(session, remaining: session.remaining(store: store), resumed: resumed),
                          state: &state, output: output, dependencies: dependencies)
    }

    private static func advance(_ session: inout HalliePronunciationDrillMode.Session, store: PronunciationDrillStore) {
        guard let index = session.index else { return }
        session.index = session.list.nextPending(from: index + 1, store: store)
    }

    /// With --remember, persist the sheet and manifest; otherwise the sheet
    /// lives for the session only. Returns the honest note for the reply.
    private static func save(
        _ store: PronunciationDrillStore,
        session: HalliePronunciationDrillMode.Session,
        options: Options,
        dependencies: Dependencies
    ) -> String {
        guard options.remember else { return "" }
        let manifest = PronunciationDrillManifest.build(list: session.list, lexicon: dependencies.loadLexicon(), store: store)
        do {
            try dependencies.saveDrillStore(store, manifest)
            return ""
        } catch {
            appLog.write("[hallie-voice] drill: sheet NOT saved — \(error.localizedDescription)")
            return " (I couldn't save the sheet: \(error.localizedDescription).)"
        }
    }

    private static func step(
        _ prose: String,
        session: HalliePronunciationDrillMode.Session,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        if session.current == nil {
            HallieAppTurnCoordinator.logSession(session)
            state.drill = nil
        } else {
            state.drill = session
        }
        return await emit(prose, state: &state, output: output, dependencies: dependencies)
    }

    private static func end(
        _ session: HalliePronunciationDrillMode.Session,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        HallieAppTurnCoordinator.logSession(session)
        state.drill = nil
        return await emit(HalliePronunciationDrillMode.exhaustedReply(session),
                          state: &state, output: output, dependencies: dependencies)
    }

    private static func emit(
        _ prose: String,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: HalliePronunciationDrillMode.basisLine,
            queryDescription: "pronunciation drill",
            citations: [],
            catalogPersonName: nil)
        state.lastResponder = "local"
        output("interpreted: pronunciation drill (local)")
        render(result, ast: nil, context: state.identityContext,
               state: &state, output: output)
        // Not composer history: a judgement is not phrasing material.
        let event = transcriptEvent(result: result, responder: "local", state: &state)
        await dependencies.recordTranscript([event])
        return .answered
    }
}
