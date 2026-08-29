// HallieAppTurnCoordinator+Pronunciation.swift
// The chat window's side of "Nathaniel is pronounced nuh-THAN-yul"
// (HallieTellingMode.detectPronunciation, 2026-08-26) and "pronounce McGill
// like MahGill or MicGill" (alternatives, 2026-08-29). Decides WHOSE name
// the word is — one CyberBrain person, one tree person, or nobody in
// particular — and hands a typed write to the dependency that owns the
// file. The reply opens with the read-back ("OK, noted — McGill.") and is
// spoken with the new entry in force, which is the proof Rick asked for.

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
        let target: PronunciationTarget
    }

    /// Handle the turn if it tells Hallie how to say a name. Nil otherwise.
    /// `telling` is passed straight through so a correction mid-interview
    /// does not end the interview.
    static func pronunciationResponse(
        question: String,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        guard let told = HallieTellingMode.detectPronunciation(question) else { return nil }
        let prose: String
        let outcome: HallieTurnExecutor.Outcome
        let basis: String
        switch teach(word: told.word, alternatives: told.alternatives, dependencies: dependencies) {
        case .success(let target):
            let scope: HallieTellingMode.PronunciationScope
            switch target {
            case .cyberBrainPerson(_, let name), .treePerson(let name, _, _):
                scope = .person(name: name)
            case .file:
                scope = .file
            }
            prose = HallieTellingMode.pronunciationReply(told, scope: scope)
            outcome = .answered
            basis = "pronunciation kept (\(scope == .file ? "pronunciations.json" : "person record"))"
            // The sheet learns of a one-off teach so the drill never asks
            // for a name Rick just corrected. Best effort: the lexicon is
            // the truth; the sheet is bookkeeping.
            var store = dependencies.loadDrillStore()
            store.set(name: told.word,
                      status: told.alternatives.count > 1 ? .alternativesPending : .taught,
                      respelling: told.saidAs)
            let manifest = PronunciationDrillManifest.build(
                list: PronunciationDrillList(items: []), lexicon: dependencies.loadLexicon(), store: store)
            if (try? dependencies.saveDrillStore(store, manifest)) == nil {
                appLog.write("[hallie-voice] drill: sheet not updated after a one-off teach")
            }
        case .failure(let error):
            // Honest failure (codex #700): no "OK, noted", not an answer, and
            // the basis says it was NOT kept.
            prose = HallieTellingMode.pronunciationFailureReply(told, error: error.localizedDescription)
            outcome = .failed
            basis = "pronunciation NOT kept (\(error.localizedDescription))"
        }
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: outcome,
            prose: prose,
            basisLine: "Basis: listening — \(basis); no model call, no catalog query.",
            queryDescription: "pronunciation",
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
        switch write.target {
        case .cyberBrainPerson(let id, let name):
            guard let root = FamilyTreeNotesStorage.productionRootURL else {
                throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
            }
            let receipt = try CyberBrainWriter.setPronunciation(
                personID: id, token: write.word, saidAs: write.saidAs, rootURL: root)
            appLog.write("[hallie-voice] kept pronunciation \(receipt.word) → \(write.saidAs) on \(name) (\(id))")
        case .treePerson(let name, let gedcomID, let aliases):
            guard let root = FamilyTreeNotesStorage.productionRootURL else {
                throw CyberBrainWriter.WriteError.unsafeRoot("Application Support unavailable")
            }
            let receipt = try CyberBrainWriter.setPronunciation(
                subjectName: name, gedcomPersonID: gedcomID, aliases: aliases,
                token: write.word, saidAs: write.saidAs, rootURL: root)
            appLog.write("[hallie-voice] kept pronunciation \(receipt.word) → \(write.saidAs) on \(name) (\(receipt.personID)\(receipt.createdPerson ? ", new record" : ""))")
        case .file:
            try HalliePronunciationLexicon.setFileEntry(written: write.word, spoken: write.saidAs)
        }
        PersonPronunciationCache.shared.invalidate()
    }
}
