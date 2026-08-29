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
            switch Mode.classify(question, session: session) {
            case .leave:
                logSession(session)
                return nil
            case .start:
                return response(Mode.openingReply(session, remaining: session.remaining(store: store), resumed: true),
                                drill: session, telling: telling, referent: referent)
            case .unrecognized:
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
            case .teach(let correction):
                guard let word = correction.word ?? session.current?.name else {
                    return response(Mode.exhaustedReply(session), drill: nil, telling: telling, referent: referent)
                }
                let outcome = teach(word: word, alternatives: correction.alternatives, dependencies: dependencies)
                switch outcome {
                case .failure(let error):
                    return response(
                        Mode.failedTeachReply(word: word, error: error.localizedDescription, session: session),
                        drill: session, telling: telling, referent: referent, outcome: .failed,
                        basis: "pronunciation NOT kept (\(error.localizedDescription))")
                case .success:
                    let status: PronunciationDrillStatus = correction.alternatives.count > 1 ? .alternativesPending : .taught
                    let key = FamilyIdentityText.normalized(word)
                    if let item = session.list.items.first(where: { $0.key == key }) {
                        store.set(item, status: status, respelling: HalliePronunciationLexicon.joinedAlternatives(correction.alternatives))
                    } else {
                        store.set(name: word, status: status, respelling: HalliePronunciationLexicon.joinedAlternatives(correction.alternatives))
                    }
                    session.taught += 1
                    let movedOn = session.current?.key == key
                    if movedOn { advance(&session, store: store) }
                    let saved = save(store, session: session, dependencies: dependencies)
                    return finish(
                        Mode.taughtReply(word: word, alternatives: correction.alternatives, session: session, movedOn: movedOn),
                        saveNote: saved, session: session, telling: telling, referent: referent)
                }
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
    static func teach(word: String, alternatives: [String], dependencies: Dependencies) -> Result<PronunciationTarget, Error> {
        let saidAs = HalliePronunciationLexicon.joinedAlternatives(alternatives)
        let target = resolvePronunciationTarget(
            word: word, cyberBrain: dependencies.loadCyberBrain(), graph: dependencies.loadGraph())
        do {
            try dependencies.recordPronunciation(PronunciationWrite(word: word, saidAs: saidAs, target: target))
        } catch {
            return .failure(error)
        }
        logTaught(word: word, saidAs: saidAs)
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
