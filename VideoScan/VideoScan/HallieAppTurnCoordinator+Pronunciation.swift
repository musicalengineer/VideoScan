// HallieAppTurnCoordinator+Pronunciation.swift
// The chat window's side of "Nathaniel is pronounced nuh-THAN-yul"
// (HallieTellingMode.detectPronunciation, 2026-08-26), "pronounce McGill
// like MahGill or MicGill" (alternatives), descriptive hints ("Latta
// should be pronounced with a short a on the La") and pronunciation
// QUESTIONS ("tell me latta pronounciations") — 2026-08-29. Decides WHOSE
// name the word is — one CyberBrain person, one tree person, or nobody in
// particular — and hands a typed write to the dependency that owns the
// file. Every reply that kept something opens with the read-back
// ("OK, noted — McGill.") and is spoken with the new entry in force.
// None of these turns ever reaches translation or a catalog search.

import Foundation
import VideoScanCore

extension HallieAppTurnCoordinator {

    /// Where a told pronunciation is kept.
    enum PronunciationTarget: Sendable, Equatable {
        /// The word is one CyberBrain person's name (canonical or alias).
        case cyberBrainPerson(id: String, name: String)
        /// The word is one tree person's name with no CyberBrain record
        /// yet; the writer mints one carrying the GEDCOM pointer.
        case treePerson(name: String, gedcomID: String, aliases: [String])
        /// Nobody's in particular (or several people's): pronunciations.json.
        case file
    }

    struct PronunciationWrite: Sendable, Equatable {
        let word: String
        /// The stored respelling; alternatives joined with " | ".
        let saidAs: String
        /// misaki phonemes derived from the spoken respelling (HalliePhonemes),
        /// nil when the respelling used a spelling the rules do not read.
        let phonemes: String?
        let target: PronunciationTarget

        init(word: String, saidAs: String, phonemes: String? = nil, target: PronunciationTarget) {
            self.word = word
            self.saidAs = saidAs
            self.phonemes = phonemes
            self.target = target
        }
    }

    /// Phonemes for the spoken (first) alternative. An "as in <word>"
    /// exemplar pins that syllable's vowel from misaki's gold lexicon when
    /// the helper bundle is installed; otherwise the respelling rules decide.
    static func derivePhonemes(alternatives: [String], hint: HalliePronunciationHint?) -> String? {
        guard let spoken = alternatives.first else { return nil }
        var pinned: [Int: String] = [:]
        if case .syllables(let given)? = hint {
            for (index, syllable) in given.enumerated() {
                if let exemplar = syllable.exemplar, let vowel = HalliePhonemes.exemplarVowel(exemplar) {
                    pinned[index] = vowel
                }
            }
        }
        return HalliePhonemes.derive(respelling: spoken, exemplarVowels: pinned)
    }

    /// Handle the turn if it tells Hallie how to say a name, hints at it,
    /// or asks how she says one. Nil otherwise. `telling` is passed straight
    /// through so a correction mid-interview does not end the interview.
    static func pronunciationResponse(
        question: String,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        if let told = HallieTellingMode.detectPronunciation(question) {
            return teachResponse(word: told.word, alternatives: told.alternatives, hint: nil,
                                 telling: telling, referent: referent, dependencies: dependencies)
        }
        if let query = HalliePronunciationQuery.detect(question) {
            return queryResponse(query, telling: telling, referent: referent, dependencies: dependencies)
        }
        if let hinted = HallieTellingMode.detectPronunciationHint(question),
           isKnownName(hinted.word, dependencies: dependencies) {
            if let respelling = HalliePronunciationRespelling.respelling(for: hinted.word, hint: hinted.hint) {
                return teachResponse(word: hinted.word, alternatives: [respelling], hint: hinted,
                                     telling: telling, referent: referent, dependencies: dependencies)
            }
            // Understood, not mappable: keep the hint for the variations
            // picker and ask for a spelling. Never a search.
            var store = dependencies.loadDrillStore()
            store.set(name: hinted.word, status: store.status(for: FamilyIdentityText.normalized(hinted.word)),
                      hint: hinted.hint.description)
            let manifest = PronunciationDrillManifest.build(
                list: PronunciationDrillList(items: []), lexicon: dependencies.loadLexicon(), store: store)
            _ = try? dependencies.saveDrillStore(store, manifest)
            return pronunciationReply(
                HallieTellingMode.hintNeedsSpellingReply(hinted), outcome: .answered,
                basis: "listening — pronunciation hint understood, needs a respelling",
                description: "pronunciation hint", telling: telling, referent: referent)
        }
        return nil
    }

    /// One taught name (typed respelling, alternatives, or a mapped hint):
    /// write, confirm with the read-back, note it on the drill sheet.
    private static func teachResponse(
        word: String, alternatives: [String], hint: HalliePronunciationHintTelling?,
        telling: HallieTellingMode.Session?, referent: CapturedReferent, dependencies: Dependencies
    ) -> Response {
        let told = HallieTellingMode.PronunciationTelling(word: word, alternatives: alternatives)
        switch teach(word: word, alternatives: alternatives, hint: hint?.hint, dependencies: dependencies) {
        case .success(let target):
            let scope: HallieTellingMode.PronunciationScope
            switch target {
            case .cyberBrainPerson(_, let name), .treePerson(let name, _, _):
                scope = .person(name: name)
            case .file:
                scope = .file
            }
            let prose = hint.map { HallieTellingMode.hintReply($0, respelling: told.spoken, scope: scope) }
                ?? HallieTellingMode.pronunciationReply(told, scope: scope)
            // The sheet learns of a one-off teach so the drill never asks
            // for a name Rick just corrected. Best effort: the lexicon is
            // the truth; the sheet is bookkeeping.
            var store = dependencies.loadDrillStore()
            store.set(name: word, status: alternatives.count > 1 ? .alternativesPending : .taught,
                      alternatives: alternatives, phonemes: derivePhonemes(alternatives: alternatives, hint: hint?.hint),
                      origin: hint == nil ? .taught : .derived, hint: hint?.hint.description)
            let manifest = PronunciationDrillManifest.build(
                list: PronunciationDrillList(items: []), lexicon: dependencies.loadLexicon(), store: store)
            if (try? dependencies.saveDrillStore(store, manifest)) == nil {
                appLog.write("[hallie-voice] drill: sheet not updated after a one-off teach")
            }
            return pronunciationReply(
                prose, outcome: .answered,
                basis: "listening — pronunciation kept (\(scope == .file ? "pronunciations.json" : "person record"))",
                description: hint == nil ? "pronunciation" : "pronunciation hint",
                telling: telling, referent: referent)
        case .failure(let error):
            // Honest failure (codex #700): no "OK, noted", not an answer, and
            // the basis says it was NOT kept.
            return pronunciationReply(
                HallieTellingMode.pronunciationFailureReply(told, error: error.localizedDescription),
                outcome: .failed,
                basis: "listening — pronunciation NOT kept (\(error.localizedDescription))",
                description: "pronunciation", telling: telling, referent: referent)
        }
    }

    /// "how do you say McGill" / "tell me latta pronounciations" / "what
    /// pronunciations do you have". A name the archive does not know at
    /// all is not a pronunciation question (nil → ordinary answering).
    private static func queryResponse(
        _ query: HalliePronunciationQuery,
        telling: HallieTellingMode.Session?, referent: CapturedReferent, dependencies: Dependencies
    ) -> Response? {
        let lexicon = dependencies.loadLexicon()
        let prose: String
        switch query {
        case .list:
            prose = HalliePronunciationQuery.listAnswer(lexicon: lexicon)
        case .name(let typed):
            let key = FamilyIdentityText.normalized(typed)
            let entry = lexicon.entries.first { FamilyIdentityText.normalized($0.written) == key }
            guard entry != nil || isKnownName(typed, dependencies: dependencies) else { return nil }
            let store = dependencies.loadDrillStore()
            let record = store.record(for: key)
            let taughtAt = (record?.status == .taught || record?.status == .alternativesPending) ? record?.attestedAt : nil
            prose = HalliePronunciationQuery.nameAnswer(
                word: entry?.written ?? knownSpelling(typed, dependencies: dependencies) ?? typed,
                entry: entry, source: entry.map { lexicon.source(of: $0) }, taughtAt: taughtAt)
        }
        return pronunciationReply(
            prose, outcome: .answered, basis: "pronunciation notes — the voice lexicon and the drill sheet",
            description: "pronunciation question", telling: telling, referent: referent)
    }

    /// Is `word` a name the archive carries — in the lexicon, on a tree
    /// record, a People-tab profile, or a CyberBrain person?
    static func isKnownName(_ word: String, dependencies: Dependencies) -> Bool {
        knownSpelling(word, dependencies: dependencies) != nil
    }

    /// The archive's spelling of `word`, or nil when nobody carries it.
    static func knownSpelling(_ word: String, dependencies: Dependencies) -> String? {
        let key = FamilyIdentityText.normalized(word)
        guard !key.isEmpty else { return nil }
        if let entry = dependencies.loadLexicon().entries.first(where: { FamilyIdentityText.normalized($0.written) == key }) {
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
        if let profiles = dependencies.loadProfiles() {
            for profile in profiles {
                if let found = spelling(in: [profile.canonicalName] + profile.aliases) { return found }
            }
        }
        if let graph = dependencies.loadGraph() {
            for person in graph.people.values {
                if let found = spelling(in: [person.name] + person.alternateNames) { return found }
            }
        }
        if let brain = dependencies.loadCyberBrain() {
            for person in brain.archive.people {
                if let found = spelling(in: [person.canonicalName] + person.aliases) { return found }
            }
        }
        return nil
    }

    private static func pronunciationReply(
        _ prose: String, outcome: HallieTurnExecutor.Outcome, basis: String, description: String,
        telling: HallieTellingMode.Session?, referent: CapturedReferent
    ) -> Response {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: outcome,
            prose: prose,
            basisLine: "Basis: \(basis); no model call, no catalog query.",
            queryDescription: description,
            citations: [],
            catalogPersonName: nil)
        return Response(
            result: result,
            responderHost: localResponder,
            biographyPhoto: nil,
            capturedReferentID: referent.recordID,
            citations: [],
            pendingClarification: nil,
            playAfterAnswer: false,
            executedIntent: nil,
            telling: telling)
    }

    /// One word → whose name it is. A word exactly ONE CyberBrain person
    /// carries (canonical name or alias) is theirs; else exactly one tree
    /// person; else the file. Several people sharing the word go to the
    /// file — the lexicon is word-based, so the effect is identical and
    /// nobody's record is chosen arbitrarily. O(brain people + tree people)
    /// once per told pronunciation; never in a view body.
    static func resolvePronunciationTarget(
        word: String,
        cyberBrain: CyberBrainIndex?,
        graph: GedcomFamilyGraph?
    ) -> PronunciationTarget {
        let token = FamilyIdentityText.normalized(word)
        guard !token.isEmpty else { return .file }

        if let cyberBrain {
            let carriers = cyberBrain.archive.people.filter { person in
                ([person.canonicalName] + person.aliases).contains {
                    FamilyIdentityText.tokens($0).contains(token)
                }
            }
            if carriers.count == 1 {
                return .cyberBrainPerson(id: carriers[0].id, name: carriers[0].canonicalName)
            }
            if carriers.count > 1 { return .file }
        }
        if let graph {
            let carriers = graph.people.values.filter { person in
                ([person.name] + person.alternateNames).contains {
                    FamilyIdentityText.tokens($0).contains(token)
                }
            }
            if carriers.count == 1 {
                let person = carriers[0]
                return .treePerson(name: person.name, gedcomID: person.id, aliases: person.alternateNames)
            }
        }
        return .file
    }

    /// The live write: the same CyberBrain writer as testimony (atomic
    /// rename + backups/), or the JSON file; then drop the voice cache so
    /// the very next utterance uses it.
    static func recordPronunciationLive(_ write: PronunciationWrite) throws {
        // Remote viewer (Phase 1): pronunciations.json and the CyberBrain
        // are synced from the master; a viewer never writes them.
        try ViewerWriteGuard.check("Pronunciation.record")
        switch write.target {
        case .cyberBrainPerson(let id, let name):
            guard let root = FamilyTreeNotesStorage.productionRootURL else {
                throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
            }
            let receipt = try CyberBrainWriter.setPronunciation(
                personID: id, token: write.word, saidAs: write.saidAs, rootURL: root)
            appLog.write("[hallie-voice] kept pronunciation \(receipt.word) → \(write.saidAs) on \(name) (\(id))")
            try keepPhonemesInFile(write)
        case .treePerson(let name, let gedcomID, let aliases):
            guard let root = FamilyTreeNotesStorage.productionRootURL else {
                throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
            }
            let receipt = try CyberBrainWriter.setPronunciation(
                subjectName: name, gedcomPersonID: gedcomID, aliases: aliases,
                token: write.word, saidAs: write.saidAs, rootURL: root)
            appLog.write("[hallie-voice] kept pronunciation \(receipt.word) → \(write.saidAs) on \(name) (\(receipt.personID)\(receipt.createdPerson ? ", new record" : ""))")
            try keepPhonemesInFile(write)
        case .file:
            try HalliePronunciationLexicon.setFileEntry(
                written: write.word, spoken: write.saidAs, phonemes: write.phonemes, origin: "told")
        }
        PersonPronunciationCache.shared.invalidate()
    }

    /// Person records hold respellings only (CyberBrainPerson.pronunciations
    /// is word → string); the phonemes a teach derived live in
    /// pronunciations.json beside the same respelling, and the merge lends
    /// them to the person-level entry. Nothing to do without phonemes.
    private static func keepPhonemesInFile(_ write: PronunciationWrite) throws {
        guard let phonemes = write.phonemes else { return }
        try HalliePronunciationLexicon.setFileEntry(
            written: write.word, spoken: write.saidAs, phonemes: phonemes, origin: "told")
    }
}
