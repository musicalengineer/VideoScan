// HallieAppTurnCoordinator+Drill.swift
// The chat window's side of the name drill (HalliePronunciationDrillMode,
// Rick 2026-08-29). The mode decides what a turn means and what Hallie
// says; this file owns the sheet (PronunciationDrillStore, explicit save),
// the durable pronunciation write (the same path as a one-off "pronounce X
// like Y"), the logging, and the session that rides in the Response.
//
// The read-back: after a teach the reply opens "OK, noted — McGill." The
// write has already landed and PersonPronunciationCache is dropped by the
// live writer, and HallieSpeaker re-resolves the lexicon per utterance, so
// the very next thing the voice says — this reply — uses the new entry.

import Foundation
import OSLog
import VideoScanCore

/// Names are logged here at the DEFAULT (private) OSLog level only; the
/// public stream carries counts (codex #861). The flat-file appLog under
/// ~/Library/Logs is Rick's own and keeps the "taught: X ← Y" line.
private let voiceLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "hallie.voice")

extension HallieAppTurnCoordinator {

    /// Handle the turn if it starts or continues a drill. Nil when there is
    /// no drill and the turn is not an opener, or when a question ended one
    /// (the caller answers it; the drill state is dropped by the Response
    /// that answer builds).
    static func drillResponse(
        question: String,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        typealias Mode = HalliePronunciationDrillMode
        if var session = drill {
            var store = dependencies.loadDrillStore()
            switch Mode.classify(question, session: session, isKnownName: { isKnownName($0, dependencies: dependencies) }) {
            case .leave:
                logSession(session)
                return nil
            case .start:
                return response(Mode.openingReply(session, remaining: session.remaining(store: store), resumed: true),
                                drill: session, telling: telling, referent: referent)
            case .unrecognized:
                // A bare "no" with no respelling: offer a few ways to say
                // the name instead of asking for a spelling (the picker,
                // Rick 2026-08-29).
                if let item = session.current, HalliePronunciationPicker.isBareNo(question) {
                    return offerResponse(word: item.name, hint: nil, respellings: [], round: 0, fromDrill: true,
                                         drill: session, telling: telling, referent: referent, dependencies: dependencies)
                }
                return response(Mode.unrecognizedReply(session), drill: session, telling: telling, referent: referent)
            case .stop:
                logSession(session)
                return response(Mode.closingReply(session, nextName: session.current?.name),
                                drill: nil, telling: telling, referent: referent)
            case .judgedOk:
                guard let item = session.current else {
                    return response(Mode.exhaustedReply(session), drill: nil, telling: telling, referent: referent)
                }
                store.set(item, status: .judgedOk)
                session.judgedOk += 1
                advance(&session, store: store)
                let saved = save(store, session: session, dependencies: dependencies)
                return finish(Mode.judgedOkReply(session), saveNote: saved, session: session, telling: telling, referent: referent)
            case .skip:
                guard let item = session.current else {
                    return response(Mode.exhaustedReply(session), drill: nil, telling: telling, referent: referent)
                }
                store.set(item, status: .skipped)
                session.skipped += 1
                advance(&session, store: store)
                let saved = save(store, session: session, dependencies: dependencies)
                return finish(Mode.skippedReply(session), saveNote: saved, session: session, telling: telling, referent: referent)
            case .next:
                advance(&session, store: store)
                return finish(Mode.nextReply(session), saveNote: nil, session: session, telling: telling, referent: referent)
            case .hint(let hinted):
                // A hint about a name nobody carries is not a judgement.
                let key = FamilyIdentityText.normalized(hinted.word)
                guard session.current?.key == key || session.list.items.contains(where: { $0.key == key })
                        || isKnownName(hinted.word, dependencies: dependencies) else {
                    return response(Mode.unrecognizedReply(session), drill: session, telling: telling, referent: referent)
                }
                guard let respelling = HalliePronunciationRespelling.respelling(for: hinted.word, hint: hinted.hint) else {
                    // Not mappable: keep the hint on the record and offer a
                    // few ways to say it, built from the hint (the picker).
                    if let item = session.list.items.first(where: { $0.key == key }) {
                        store.set(item, status: store.status(for: key), hint: hinted.hint.description)
                    } else {
                        store.set(name: hinted.word, status: store.status(for: key), hint: hinted.hint.description)
                    }
                    _ = save(store, session: session, dependencies: dependencies)
                    let word = session.list.items.first(where: { $0.key == key })?.name
                        ?? knownSpelling(hinted.word, dependencies: dependencies) ?? hinted.word
                    return offerResponse(word: word, hint: hinted.hint, respellings: [], round: 0, fromDrill: true,
                                         drill: session, telling: telling, referent: referent, dependencies: dependencies,
                                         prefix: "I've noted \u{201C}\(hinted.hint.description)\u{201D} for \(word). ")
                }
                return applyTeach(Mode.Correction(word: hinted.word, alternatives: [respelling]), hint: hinted.hint,
                                  session: session, store: store, telling: telling, referent: referent, dependencies: dependencies)
            case .teach(let correction):
                return applyTeach(correction, hint: nil, session: session, store: store,
                                  telling: telling, referent: referent, dependencies: dependencies)
            }
        }

        guard Mode.detectStart(question) else { return nil }
        let store = dependencies.loadDrillStore()
        let list = PronunciationDrillList.build(
            graph: dependencies.loadGraph(),
            profiles: dependencies.loadProfiles() ?? [],
            speakers: dependencies.loadSpeakers(),
            lexicon: dependencies.loadLexicon(),
            store: store)
        var session = Mode.Session(list: list, index: nil)
        session.index = list.nextPending(from: 0, store: store)
        let resumed = store.names.values.contains { $0.status != .untested }
        guard session.current != nil else {
            appLog.write("[hallie-voice] drill: nothing pending on a sheet of \(list.items.count) names")
            return response(Mode.exhaustedReply(session), drill: nil, telling: telling, referent: referent)
        }
        appLog.write("[hallie-voice] drill: started — \(list.items.count) names on the sheet, \(session.remaining(store: store)) pending\(resumed ? " (resumed)" : "")")
        return response(
            Mode.openingReply(session, remaining: session.remaining(store: store), resumed: resumed),
            drill: session, telling: telling, referent: referent)
    }

    /// One correction (typed, alternatives, or a mapped hint) while drilling.
    private static func applyTeach(
        _ correction: HalliePronunciationDrillMode.Correction,
        hint: HalliePronunciationHint?,
        session: HalliePronunciationDrillMode.Session,
        store: PronunciationDrillStore,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response {
        typealias Mode = HalliePronunciationDrillMode
        var session = session
        var store = store
        guard let word = correction.word ?? session.current?.name else {
            return response(Mode.exhaustedReply(session), drill: nil, telling: telling, referent: referent)
        }
        switch teach(word: word, alternatives: correction.alternatives, hint: hint, dependencies: dependencies) {
        case .failure(let error):
            return response(
                Mode.failedTeachReply(word: word, error: error.localizedDescription, session: session),
                drill: session, telling: telling, referent: referent, outcome: .failed,
                basis: "pronunciation NOT kept (\(error.localizedDescription))")
        case .success:
            let status: PronunciationDrillStatus = correction.alternatives.count > 1 ? .alternativesPending : .taught
            let key = FamilyIdentityText.normalized(word)
            let origin: PronunciationDrillStore.Origin = hint == nil ? .taught : .derived
            let phonemes = derivePhonemes(alternatives: correction.alternatives, hint: hint)
            if let item = session.list.items.first(where: { $0.key == key }) {
                store.set(item, status: status, alternatives: correction.alternatives, phonemes: phonemes, origin: origin, hint: hint?.description)
            } else {
                store.set(name: word, status: status, alternatives: correction.alternatives, phonemes: phonemes, origin: origin, hint: hint?.description)
            }
            session.taught += 1
            let movedOn = session.current?.key == key
            if movedOn { advance(&session, store: store) }
            let saved = save(store, session: session, dependencies: dependencies)
            return finish(
                Mode.taughtReply(word: word, alternatives: correction.alternatives, hint: hint, session: session, movedOn: movedOn),
                saveNote: saved, session: session, telling: telling, referent: referent)
        }
    }

    // MARK: - Steps

    /// Move to the next pending name; the session ends (index nil) when
    /// none is left.
    private static func advance(_ session: inout HalliePronunciationDrillMode.Session, store: PronunciationDrillStore) {
        guard let index = session.index else { return }
        session.index = session.list.nextPending(from: index + 1, store: store)
    }

    /// Persist the sheet and the manifest. Returns the honest note for the
    /// reply when the save failed (the judgement still holds for this
    /// session); nil when it landed.
    private static func save(
        _ store: PronunciationDrillStore,
        session: HalliePronunciationDrillMode.Session,
        dependencies: Dependencies
    ) -> String? {
        let manifest = PronunciationDrillManifest.build(
            list: session.list, lexicon: dependencies.loadLexicon(), store: store)
        do {
            try dependencies.saveDrillStore(store, manifest)
            return nil
        } catch {
            appLog.write("[hallie-voice] drill: sheet NOT saved — \(error.localizedDescription)")
            return " (I couldn't save the sheet: \(error.localizedDescription).)"
        }
    }

    /// The reply after a step: ends the drill when the sheet ran out.
    private static func finish(
        _ prose: String, saveNote: String?,
        session: HalliePronunciationDrillMode.Session,
        telling: HallieTellingMode.Session?, referent: CapturedReferent
    ) -> Response {
        let ended = session.current == nil
        if ended { logSession(session) }
        return response(prose + (saveNote ?? ""), drill: ended ? nil : session, telling: telling, referent: referent)
    }

    /// One taught name, drill or one-off: resolve whose name it is, write
    /// through the injected recorder, log. Shared with the one-off path so
    /// both leave the same trail.
    /// `phonemes` overrides the derivation when the caller already has the
    /// exact string (the picker); `origin` is the lexicon's `source` field.
    static func teach(word: String, alternatives: [String], hint: HalliePronunciationHint? = nil,
                      phonemes explicit: String? = nil, origin: String = "told",
                      dependencies: Dependencies) -> Result<PronunciationTarget, Error> {
        let saidAs = HalliePronunciationLexicon.joinedAlternatives(alternatives)
        let target = resolvePronunciationTarget(
            word: word, cyberBrain: dependencies.loadCyberBrain(), graph: dependencies.loadGraph())
        let phonemes = explicit ?? derivePhonemes(alternatives: alternatives, hint: hint)
        do {
            try dependencies.recordPronunciation(PronunciationWrite(word: word, saidAs: saidAs, phonemes: phonemes,
                                                                    target: target, origin: origin))
        } catch {
            return .failure(error)
        }
        logTaught(word: word, saidAs: saidAs + (phonemes.map { " /\($0)/" } ?? ""))
        return .success(target)
    }

    /// `[hallie-voice] taught: McGill ← MahGill | MicGill` in Rick's private
    /// file log; the name reaches OSLog only at debug level with default
    /// (private) redaction — never the public stream (codex #861).
    static func logTaught(word: String, saidAs: String) {
        appLog.write("[hallie-voice] taught: \(word) ← \(saidAs)")
        voiceLog.debug("taught: \(word, privacy: .private) ← \(saidAs, privacy: .private)")
        voiceLog.info("pronunciation taught (1 name)")
    }

    /// Session counts only — no names (codex #861).
    static func logSession(_ session: HalliePronunciationDrillMode.Session) {
        appLog.write(HalliePronunciationDrillMode.logLine(session))
        voiceLog.info("drill: taught \(session.taught, privacy: .public), judged-ok \(session.judgedOk, privacy: .public), skipped \(session.skipped, privacy: .public) (session)")
    }

    // MARK: - Response

    private static func response(
        _ prose: String,
        drill: HalliePronunciationDrillMode.Session?,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        outcome: HallieTurnExecutor.Outcome = .answered,
        basis: String? = nil
    ) -> Response {
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: outcome,
            prose: prose,
            basisLine: basis.map { "Basis: name drill — \($0); no model call, no catalog query." }
                ?? HalliePronunciationDrillMode.basisLine,
            queryDescription: "pronunciation drill",
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
        return response
    }
}
