// HallieAppTurnCoordinator+Picker.swift
// The chat window's side of the variations picker (HalliePronunciationPicker,
// Rick 2026-08-29). The picker decides what a reply means and what Hallie
// says; this file owns the offer that rides in the Response, the durable
// write of the chosen phonemes (the same path as a typed "pronounce X like
// Y", `source: picked`), the drill sheet when the offer came from the
// drill, and the logging.
//
// How an offer is opened:
//   - "say Latta a few ways" / "let me pick" / "which sounds right";
//   - the drill: a bare "no" with no respelling, or a hint Hallie could
//     not map (HallieAppTurnCoordinator+Drill);
//   - a one-off hint Hallie could not map (…+Pronunciation).
// How it closes: a pick (write + read-back "OK, noted — Latta."), "none"
// past the last page (ask for a spelling), or any other turn.

import Foundation
import OSLog
import VideoScanCore

private let voiceLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "hallie.voice")

extension HallieAppTurnCoordinator {

    /// Handle the turn if an offer is up and the reply is about it, or if
    /// the turn asks for the picker. Nil otherwise (the offer, if any, is
    /// dropped by whatever Response the caller builds next).
    static func pickerResponse(
        question: String,
        picker: HalliePronunciationPicker.Offer?,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        typealias Picker = HalliePronunciationPicker
        if var offer = picker {
            switch Picker.classify(question, offer: offer) {
            case .leave:
                return nil
            case .pick(let number):
                return pickResponse(offer, number: number, drill: drill, telling: telling,
                                    referent: referent, dependencies: dependencies)
            case .confirmHeard:
                guard let number = offer.heard else {
                    return response(Picker.needsNumberReply(offer), picker: offer, drill: drill, telling: telling, referent: referent)
                }
                return pickResponse(offer, number: number, drill: drill, telling: telling,
                                    referent: referent, dependencies: dependencies)
            case .needsNumber:
                return response(Picker.needsNumberReply(offer), picker: offer, drill: drill, telling: telling, referent: referent)
            case .outOfRange(let number):
                return response(Picker.outOfRangeReply(offer, number: number), picker: offer, drill: drill, telling: telling, referent: referent)
            case .hear(let number):
                offer.heard = number
                return response(Picker.hearReply(offer, number: number), picker: offer, drill: drill, telling: telling,
                                referent: referent,
                                speech: Picker.hearSpeech(offer, number: number),
                                speechFallback: Picker.hearSpeechFallback(offer, number: number))
            case .none:
                return offerResponse(word: offer.word, hint: offer.hint, respellings: offer.respellings,
                                     round: offer.round + 1, fromDrill: offer.fromDrill,
                                     drill: drill, telling: telling, referent: referent, dependencies: dependencies)
            }
        }

        guard let request = Picker.detectRequest(question) else { return nil }
        let typed = request.word ?? drill?.current?.name
        guard let typed else {
            return response(Picker.whichNameReply(), picker: nil, drill: drill, telling: telling, referent: referent)
        }
        let key = FamilyIdentityText.normalized(typed)
        // A name nobody carries is not ours ("say hello a few ways").
        guard let word = drill?.list.items.first(where: { $0.key == key })?.name
                ?? knownSpelling(typed, dependencies: dependencies) else { return nil }
        let fromDrill = drill?.list.items.contains { $0.key == key } ?? false
        return offerResponse(word: word, hint: nil, respellings: [], round: 0, fromDrill: fromDrill,
                             drill: drill, telling: telling, referent: referent, dependencies: dependencies)
    }

    /// Put page `round` of the candidates up; past the last page, ask for a
    /// spelling or a hint (the offer closes). `prefix` opens the sentence
    /// when the offer follows something else ("I've noted …").
    static func offerResponse(
        word: String,
        hint: HalliePronunciationHint?,
        respellings: [String],
        round: Int,
        fromDrill: Bool,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies,
        prefix: String = ""
    ) -> Response {
        typealias Picker = HalliePronunciationPicker
        guard let offer = Picker.makeOffer(word: word, hint: hint, respellings: respellings, round: round, fromDrill: fromDrill) else {
            let prose = round == 0 ? Picker.cannotOfferReply(word: word) : Picker.exhaustedReply(word: word)
            return response(prefix + prose + stillOn(drill), picker: nil, drill: drill, telling: telling, referent: referent)
        }
        appLog.write(Picker.logLine(offered: offer))
        voiceLog.info("picker: offered \(offer.candidates.count, privacy: .public) (page \(offer.round + 1, privacy: .public))")
        return response(prefix + Picker.offerReply(offer), picker: offer, drill: drill, telling: telling, referent: referent,
                        speech: Picker.spokenOffer(offer), speechFallback: Picker.spokenOfferFallback(offer))
    }

    /// Number `number` is right: keep its phonemes as taught (`picked`),
    /// note it on the drill sheet, advance the drill if the name was up,
    /// and read it back with the new entry in force.
    private static func pickResponse(
        _ offer: HalliePronunciationPicker.Offer,
        number: Int,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response {
        typealias Picker = HalliePronunciationPicker
        typealias Mode = HalliePronunciationDrillMode
        guard let candidate = offer.candidate(number) else {
            return response(Picker.outOfRangeReply(offer, number: number), picker: offer, drill: drill, telling: telling, referent: referent)
        }
        let word = offer.word
        switch teach(word: word, alternatives: [candidate.respelling], hint: nil,
                     phonemes: candidate.phonemes, origin: "picked", dependencies: dependencies) {
        case .failure(let error):
            let telling0 = HallieTellingMode.PronunciationTelling(word: word, alternatives: [candidate.respelling])
            return response(
                HallieTellingMode.pronunciationFailureReply(telling0, error: error.localizedDescription),
                picker: offer, drill: drill, telling: telling, referent: referent,
                outcome: .failed, basis: "pronunciation NOT kept (\(error.localizedDescription))")
        case .success(let target):
            let scope: HallieTellingMode.PronunciationScope
            switch target {
            case .cyberBrainPerson(_, let name), .treePerson(let name, _, _): scope = .person(name: name)
            case .file: scope = .file
            }
            var prose = Picker.pickedReply(word: word, candidate: candidate, number: number, scope: scope)
            var store = dependencies.loadDrillStore()
            let key = FamilyIdentityText.normalized(word)
            var session = drill
            if let item = session?.list.items.first(where: { $0.key == key }) {
                store.set(item, status: .taught, alternatives: [candidate.respelling], phonemes: candidate.phonemes,
                          origin: .picked, hint: offer.hint?.description)
            } else {
                store.set(name: word, status: .taught, alternatives: [candidate.respelling], phonemes: candidate.phonemes,
                          origin: .picked, hint: offer.hint?.description)
            }
            if var live = session {
                live.taught += 1
                if live.current?.key == key, let index = live.index {
                    live.index = live.list.nextPending(from: index + 1, store: store)
                }
                session = live
                if let item = live.current {
                    prose += live.current?.key == key ? " Still on: \(item.name)." : " " + Mode.putName(item)
                } else {
                    prose += " " + Mode.exhaustedReply(live)
                    logSession(live)
                    session = nil
                }
            }
            let manifest = PronunciationDrillManifest.build(
                list: drill?.list ?? PronunciationDrillList(items: []), lexicon: dependencies.loadLexicon(), store: store)
            do {
                try dependencies.saveDrillStore(store, manifest)
            } catch {
                appLog.write("[hallie-voice] drill: sheet NOT saved after a pick — \(error.localizedDescription)")
                prose += " (I couldn't save the sheet: \(error.localizedDescription).)"
            }
            voiceLog.info("picker: picked (1 name)")
            return response(prose, picker: nil, drill: session, telling: telling, referent: referent,
                            basis: "pronunciation kept (\(scope == .file ? "pronunciations.json" : "person record"), picked)")
        }
    }

    private static func stillOn(_ drill: HalliePronunciationDrillMode.Session?) -> String {
        guard let item = drill?.current else { return "" }
        return " Still on: \(item.name)."
    }

    // MARK: - Response

    private static func response(
        _ prose: String,
        picker: HalliePronunciationPicker.Offer?,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        speech: String? = nil,
        speechFallback: String? = nil,
        outcome: HallieTurnExecutor.Outcome = .answered,
        basis: String? = nil
    ) -> Response {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: outcome,
            prose: prose,
            basisLine: basis.map { "Basis: pronunciation picker — \($0); no model call, no catalog query." }
                ?? HalliePronunciationPicker.basisLine,
            queryDescription: "pronunciation picker",
            citations: [],
            catalogPersonName: nil)
        var response = Response(
            result: result,
            responderHost: localResponder,
            biographyPhoto: nil,
            capturedReferentID: referent.recordID,
            citations: [],
            pendingClarification: nil,
            playAfterAnswer: false,
            executedIntent: nil,
            telling: telling)
        response.drill = drill
        response.picker = picker
        response.pickerSpeech = speech
        response.pickerSpeechFallback = speechFallback
        return response
    }
}
