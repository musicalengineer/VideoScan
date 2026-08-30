// HallieShellCLI+Picker.swift
// The shell's side of the variations picker (HalliePronunciationPicker,
// Rick 2026-08-29). Same decisions and wording as the chat window, as a
// numbered list answered by number — no audio (the shell is what codex's
// nightly lane and Rick's `hallie` terminal see). Writes (the lexicon entry
// and the drill sheet) happen only with `--remember`, like the drill.

import Foundation
import VideoScanCore

extension HallieShellCLI {

    /// Handle the turn if a list is up and the reply is about it, or if the
    /// turn asks for the picker. Nil otherwise (a list that was stepped out
    /// of is closed quietly).
    static func pickerTurn(
        _ text: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome? {
        typealias Picker = HalliePronunciationPicker
        if var offer = state.picker {
            switch Picker.classify(text, offer: offer) {
            case .leave:
                state.picker = nil
                return nil
            case .pick(let number):
                return await pick(offer, number: number, options: options, state: &state, output: output, dependencies: dependencies)
            case .confirmHeard:
                guard let number = offer.heard else {
                    return await emitPicker(Picker.needsNumberReply(offer), state: &state, output: output, dependencies: dependencies)
                }
                return await pick(offer, number: number, options: options, state: &state, output: output, dependencies: dependencies)
            case .needsNumber:
                return await emitPicker(Picker.needsNumberReply(offer), state: &state, output: output, dependencies: dependencies)
            case .outOfRange(let number):
                return await emitPicker(Picker.outOfRangeReply(offer, number: number), state: &state, output: output, dependencies: dependencies)
            case .hear(let number):
                offer.heard = number
                state.picker = offer
                return await emitPicker(Picker.hearReply(offer, number: number) + " /\(offer.candidate(number)?.phonemes ?? "")/",
                                        state: &state, output: output, dependencies: dependencies)
            case .none:
                return await offerInShell(word: offer.word, hint: offer.hint, respellings: offer.respellings,
                                          round: offer.round + 1, fromDrill: offer.fromDrill,
                                          state: &state, output: output, dependencies: dependencies)
            }
        }

        guard let request = Picker.detectRequest(text) else { return nil }
        let typed = request.word ?? state.drill?.current?.name
        guard let typed else {
            return await emitPicker(Picker.whichNameReply(), state: &state, output: output, dependencies: dependencies)
        }
        let key = FamilyIdentityText.normalized(typed)
        guard let word = state.drill?.list.items.first(where: { $0.key == key })?.name
                ?? knownSpelling(typed, state: state, dependencies: dependencies) else { return nil }
        let fromDrill = state.drill?.list.items.contains { $0.key == key } ?? false
        let respellings = state.transientPronunciations.first {
            FamilyIdentityText.normalized($0.written) == key
        }.map { HalliePronunciationLexicon.alternatives($0.spoken) } ?? []
        return await offerInShell(word: word, hint: nil, respellings: respellings,
                                  round: 0, fromDrill: fromDrill,
                                  state: &state, output: output, dependencies: dependencies)
    }

    /// Put page `round` up as a numbered list; past the last page, ask for
    /// a spelling or a hint.
    static func offerInShell(
        word: String,
        hint: HalliePronunciationHint?,
        respellings: [String],
        round: Int,
        fromDrill: Bool,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies,
        prefix: String = ""
    ) async -> AnswerOutcome {
        typealias Picker = HalliePronunciationPicker
        guard let offer = Picker.makeOffer(
            word: word, hint: hint, respellings: respellings,
            round: round, fromDrill: fromDrill,
            gold: dependencies.loadPronunciationGold()) else {
            state.picker = nil
            var prose = prefix + (round == 0 ? Picker.cannotOfferReply(word: word) : Picker.exhaustedReply(word: word))
            if let item = state.drill?.current { prose += " Still on: \(item.name)." }
            return await emitPicker(prose, state: &state, output: output, dependencies: dependencies)
        }
        appLog.write(Picker.logLine(offered: offer))
        state.picker = offer
        return await emitPicker(prefix + Picker.shellOfferReply(offer), state: &state, output: output, dependencies: dependencies)
    }

    private static func pick(
        _ offer: HalliePronunciationPicker.Offer,
        number: Int,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        typealias Picker = HalliePronunciationPicker
        typealias Mode = HalliePronunciationDrillMode
        guard let candidate = offer.candidate(number) else {
            return await emitPicker(Picker.outOfRangeReply(offer, number: number), state: &state, output: output, dependencies: dependencies)
        }
        let word = offer.word
        let target = HallieAppTurnCoordinator.resolvePronunciationTarget(
            word: word, cyberBrain: state.cyberBrain, graph: state.graph)
        let scope: HallieTellingMode.PronunciationScope
        switch target {
        case .cyberBrainPerson(_, let name), .treePerson(let name, _, _): scope = .person(name: name)
        case .file: scope = .file
        }
        var prose = Picker.pickedReply(word: word, candidate: candidate, number: number, scope: scope)
        if options.remember {
            do {
                try dependencies.recordPronunciation(.init(word: word, saidAs: candidate.respelling, phonemes: candidate.phonemes,
                                                           target: target, origin: "picked"))
                HallieAppTurnCoordinator.logTaught(word: word, saidAs: candidate.respelling + " /\(candidate.phonemes)/")
            } catch {
                let telling = HallieTellingMode.PronunciationTelling(word: word, alternatives: [candidate.respelling])
                state.picker = offer
                return await emitPicker(HallieTellingMode.pronunciationFailureReply(telling, error: error.localizedDescription),
                                        state: &state, output: output, dependencies: dependencies)
            }
        } else {
            state.rememberPronunciation(
                word: word,
                spoken: candidate.respelling,
                phonemes: candidate.phonemes,
                origin: "picked")
            prose += " (Kept for this session only — run with --remember to save it.)"
        }
        var store = dependencies.loadDrillStore()
        let key = FamilyIdentityText.normalized(word)
        if let item = state.drill?.list.items.first(where: { $0.key == key }) {
            store.set(item, status: .taught, alternatives: [candidate.respelling], phonemes: candidate.phonemes,
                      origin: .picked, hint: offer.hint?.description)
        } else {
            store.set(name: word, status: .taught, alternatives: [candidate.respelling], phonemes: candidate.phonemes,
                      origin: .picked, hint: offer.hint?.description)
        }
        if var live = state.drill {
            live.taught += 1
            if live.current?.key == key, let index = live.index {
                live.index = live.list.nextPending(from: index + 1, store: store)
            }
            if let item = live.current {
                prose += live.current?.key == key ? " Still on: \(item.name)." : " " + Mode.putName(item)
                state.drill = live
            } else {
                prose += " " + Mode.exhaustedReply(live)
                HallieAppTurnCoordinator.logSession(live)
                state.drill = nil
            }
        }
        if options.remember {
            let manifest = PronunciationDrillManifest.build(
                list: state.drill?.list ?? PronunciationDrillList(items: []),
                lexicon: state.pronunciationLexicon(base: dependencies.loadLexicon()),
                store: store)
            do {
                try dependencies.saveDrillStore(store, manifest)
            } catch {
                appLog.write("[hallie-voice] drill: sheet NOT saved after a pick — \(error.localizedDescription)")
                prose += " (I couldn't save the sheet: \(error.localizedDescription).)"
            }
        }
        state.picker = nil
        return await emitPicker(prose, state: &state, output: output, dependencies: dependencies)
    }

    private static func emitPicker(
        _ prose: String,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: HalliePronunciationPicker.basisLine,
            queryDescription: "pronunciation picker",
            citations: [],
            catalogPersonName: nil)
        state.lastResponder = "local"
        output("interpreted: pronunciation picker (local)")
        render(result, ast: nil, context: state.identityContext,
               state: &state, output: output)
        let event = transcriptEvent(result: result, responder: "local", state: &state)
        await dependencies.recordTranscript([event])
        return .answered
    }
}
