// HallieShellCLI+Pronunciation.swift
// Shell parity for the chat window's pronunciation turns (2026-08-29):
// "pronounce McGill like MahGill or MicGill" (teach), "Latta should be
// pronounced with a short a on the La" (hint), and "tell me latta
// pronounciations" / "how do you say McGill" (question). Same wording as
// HallieAppTurnCoordinator+Pronunciation; no audio. Writes happen only
// with `--remember`; questions are read-only and always answered from the
// lexicon and the drill sheet — never a catalog search.

import Foundation
import VideoScanCore

extension HallieShellCLI {

    static func pronunciationTurn(
        _ text: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome? {
        if let told = HallieTellingMode.detectPronunciation(text) {
            return await teachOneOff(word: told.word, alternatives: told.alternatives, hint: nil,
                                     options: options, state: &state, output: output, dependencies: dependencies)
        }
        if let query = HalliePronunciationQuery.detect(text) {
            return await answerQuery(query, state: &state, output: output, dependencies: dependencies)
        }
        if let hinted = HallieTellingMode.detectPronunciationHint(text),
           knownSpelling(hinted.word, state: state, dependencies: dependencies) != nil {
            if let respelling = HalliePronunciationRespelling.respelling(
                for: hinted.word, hint: hinted.hint,
                gold: dependencies.loadPronunciationGold()) {
                return await teachOneOff(word: hinted.word, alternatives: [respelling], hint: hinted,
                                         options: options, state: &state, output: output, dependencies: dependencies)
            }
            if options.remember {
                var store = dependencies.loadDrillStore()
                store.set(name: hinted.word, status: store.status(for: FamilyIdentityText.normalized(hinted.word)),
                          hint: hinted.hint.description)
                _ = try? dependencies.saveDrillStore(store, .build(list: PronunciationDrillList(items: []),
                                                                   lexicon: dependencies.loadLexicon(), store: store))
            }
            // Not mappable: offer a few ways built from the hint (the picker).
            let word = knownSpelling(hinted.word, state: state, dependencies: dependencies) ?? hinted.word
            return await offerInShell(word: word, hint: hinted.hint, respellings: [], round: 0, fromDrill: false,
                                      state: &state, output: output, dependencies: dependencies,
                                      prefix: "I've noted \u{201C}\(hinted.hint.description)\u{201D} for \(word). ")
        }
        // Free-form (live miss #17): typo-tolerant pronounce-word + known name.
        let known = { (token: String) in knownSpelling(token, state: state, dependencies: dependencies) != nil }
        if let free = HalliePronunciationFreeform.detect(
            text, isKnownName: known,
            gold: dependencies.loadPronunciationGold()) {
            switch free.kind {
            case .teach:
                return await teachOneOff(word: free.word, alternatives: free.alternatives, hint: nil, freeform: free,
                                         options: options, state: &state, output: output, dependencies: dependencies)
            case .query:
                if let answered = await answerQuery(.name(free.word), state: &state, output: output, dependencies: dependencies) {
                    return answered
                }
            case .hintOnly:
                if options.remember {
                    var store = dependencies.loadDrillStore()
                    store.set(name: free.word, status: store.status(for: FamilyIdentityText.normalized(free.word)), hint: free.rawHint)
                    _ = try? dependencies.saveDrillStore(store, .build(list: PronunciationDrillList(items: []),
                                                                       lexicon: dependencies.loadLexicon(), store: store))
                }
                return await emitPronunciation(
                    HalliePronunciationFreeform.hintOnlyReply(free), description: "pronunciation hint",
                    basis: "Basis: listening — pronunciation hint kept, needs a respelling; no model call, no catalog query.",
                    state: &state, output: output, dependencies: dependencies)
            }
        }
        return nil
    }

    private static func teachOneOff(
        word: String, alternatives: [String], hint: HalliePronunciationHintTelling?,
        freeform: HallieFreeformPronunciation? = nil,
        options: Options, state: inout Session, output: (String) -> Void, dependencies: Dependencies
    ) async -> AnswerOutcome {
        let told = HallieTellingMode.PronunciationTelling(word: word, alternatives: alternatives)
        let target = HallieAppTurnCoordinator.resolvePronunciationTarget(
            word: word, cyberBrain: state.cyberBrain, graph: state.graph)
        let scope: HallieTellingMode.PronunciationScope
        switch target {
        case .cyberBrainPerson(_, let name), .treePerson(let name, _, _): scope = .person(name: name)
        case .file: scope = .file
        }
        var prose = freeform.map { HalliePronunciationFreeform.teachReply($0, scope: scope) }
            ?? hint.map { HallieTellingMode.hintReply($0, respelling: told.spoken, scope: scope) }
            ?? HallieTellingMode.pronunciationReply(told, scope: scope)
        var basis = "Basis: listening — pronunciation kept (\(scope == .file ? "pronunciations.json" : "person record")); no model call, no catalog query."
        let phonemes = HallieAppTurnCoordinator.derivePhonemes(
            alternatives: alternatives, hint: hint?.hint,
            gold: dependencies.loadPronunciationGold())
        if options.remember {
            do {
                try dependencies.recordPronunciation(.init(word: word, saidAs: told.saidAs, phonemes: phonemes, target: target))
                HallieAppTurnCoordinator.logTaught(word: word, saidAs: told.saidAs + (phonemes.map { " /\($0)/" } ?? ""))
                var store = dependencies.loadDrillStore()
                let derived = hint != nil || freeform?.explicit == false
                store.set(name: word, status: alternatives.count > 1 ? .alternativesPending : .taught,
                          alternatives: alternatives, phonemes: phonemes, origin: derived ? .derived : .taught,
                          hint: hint?.hint.description ?? freeform?.rawHint)
                _ = try? dependencies.saveDrillStore(store, .build(list: PronunciationDrillList(items: []),
                                                                   lexicon: dependencies.loadLexicon(), store: store))
            } catch {
                prose = HallieTellingMode.pronunciationFailureReply(told, error: error.localizedDescription)
                basis = "Basis: listening — pronunciation NOT kept (\(error.localizedDescription)); no model call, no catalog query."
            }
        } else {
            state.rememberPronunciation(
                word: word,
                spoken: told.saidAs,
                phonemes: phonemes,
                origin: "told")
            prose += " (Kept for this session only — run with --remember to save it.)"
            basis = "Basis: listening — pronunciation NOT saved (no --remember); no model call, no catalog query."
        }
        return await emitPronunciation(prose, description: hint == nil ? "pronunciation" : "pronunciation hint",
                                       basis: basis, state: &state, output: output, dependencies: dependencies)
    }

    private static func answerQuery(
        _ query: HalliePronunciationQuery,
        state: inout Session, output: (String) -> Void, dependencies: Dependencies
    ) async -> AnswerOutcome? {
        let lexicon = state.pronunciationLexicon(base: dependencies.loadLexicon())
        let prose: String
        switch query {
        case .list:
            prose = HalliePronunciationQuery.listAnswer(lexicon: lexicon)
        case .name(let typed):
            let key = FamilyIdentityText.normalized(typed)
            let entry = lexicon.entries.first { FamilyIdentityText.normalized($0.written) == key }
            let spelling = knownSpelling(typed, state: state, dependencies: dependencies)
            guard entry != nil || spelling != nil else { return nil }
            let record = dependencies.loadDrillStore().record(for: key)
            let taughtAt = (record?.status == .taught || record?.status == .alternativesPending) ? record?.attestedAt : nil
            let isTransient = state.transientPronunciations.contains {
                FamilyIdentityText.normalized($0.written) == key
            }
            prose = HalliePronunciationQuery.nameAnswer(
                word: entry?.written ?? spelling ?? typed,
                entry: entry,
                source: isTransient ? nil : entry.map { lexicon.source(of: $0) },
                taughtAt: isTransient ? nil : taughtAt)
        }
        return await emitPronunciation(prose, description: "pronunciation question",
                                       basis: HalliePronunciationQuery.basisLine,
                                       state: &state, output: output, dependencies: dependencies)
    }

    /// The archive's spelling of `word` (lexicon, People tab, tree, brain).
    static func knownSpelling(_ word: String, state: Session, dependencies: Dependencies) -> String? {
        let key = FamilyIdentityText.normalized(word)
        guard !key.isEmpty else { return nil }
        let lexicon = state.pronunciationLexicon(base: dependencies.loadLexicon())
        if let entry = lexicon.entries.first(where: {
            FamilyIdentityText.normalized($0.written) == key
        }) {
            return entry.written
        }
        func spelling(in names: [String]) -> String? {
            for name in names {
                for part in FamilyTreePronunciationChips.nameWords(name) where FamilyIdentityText.normalized(part) == key {
                    return part
                }
            }
            return nil
        }
        for profile in state.profiles ?? [] {
            if let found = spelling(in: [profile.name] + profile.aliases) { return found }
        }
        for person in state.graph?.people.values ?? [String: GedcomFamilyGraph.Person]().values {
            if let found = spelling(in: [person.name] + person.alternateNames) { return found }
        }
        for person in state.cyberBrain?.archive.people ?? [] {
            if let found = spelling(in: [person.canonicalName] + person.aliases) { return found }
        }
        return nil
    }

    private static func emitPronunciation(
        _ prose: String, description: String, basis: String,
        state: inout Session, output: (String) -> Void, dependencies: Dependencies
    ) async -> AnswerOutcome {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: basis,
            queryDescription: description,
            citations: [],
            catalogPersonName: nil)
        state.lastResponder = "local"
        output("interpreted: \(description) (local)")
        render(result, ast: nil, context: state.identityContext,
               state: &state, output: output)
        let event = transcriptEvent(result: result, responder: "local", state: &state)
        await dependencies.recordTranscript([event])
        return .answered
    }
}
