// HallieAppTurnCoordinator+Telling.swift
// The chat window's side of "let me tell you about …" (HallieTellingMode).
// Same decisions and wording as the shell; the only differences are that
// the app always writes (it IS the family's tool) and that state travels
// in the Response instead of a mutable session.

import Foundation

extension HallieAppTurnCoordinator {

    /// Handle the turn if it opens or continues a telling. Returns nil when
    /// ordinary answering should proceed (no telling, or a question that
    /// ended one).
    static func tellingResponse(
        question: String,
        telling: HallieTellingMode.Session?,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        let speakers = dependencies.loadSpeakers()
        if var session = telling {
            switch HallieTellingMode.classify(question, session: session) {
            case .switchSubject(let opening):
                return begin(opening, previous: session, speakers: speakers,
                             referent: referent, dependencies: dependencies)
            case .question:
                return nil
            case .finish:
                let persisted = session.persistedCount == session.passages.count
                    && !session.awaitingName
                return response(
                    HallieTellingMode.closingReply(
                        session, persisted: persisted, speaker: speakers.ownerName),
                    telling: nil, speakers: speakers, referent: referent)
            case .name(let name):
                session.subject = name
                let pending = session.pendingPassages
                session.pendingPassages = []
                var notes: [String] = []
                for statement in pending {
                    keep(statement, session: &session, speakers: speakers,
                         dependencies: dependencies, notes: &notes)
                }
                let reply = HallieTellingMode.namedReply(&session)
                return response(
                    notes.joined() + reply,
                    telling: session, speakers: speakers, referent: referent)
            case .statement(let statement):
                if session.awaitingName {
                    session.pendingPassages.append(statement)
                    return response(
                        HallieTellingMode.stillNeedNameReply(session),
                        telling: session, speakers: speakers, referent: referent)
                }
                var notes: [String] = []
                keep(statement, session: &session, speakers: speakers,
                     dependencies: dependencies, notes: &notes)
                let reply = HallieTellingMode.acknowledgement(&session)
                return response(notes.joined() + reply, telling: session,
                                speakers: speakers, referent: referent)
            }
        }
        guard let opening = HallieTellingMode.detectOpening(question) else { return nil }
        return begin(opening, previous: nil, speakers: speakers,
                     referent: referent, dependencies: dependencies)
    }

    private static func begin(
        _ opening: HallieTellingMode.Opening,
        previous: HallieTellingMode.Session?,
        speakers: HallieTurnExecutor.Speakers,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response {
        var preface = ""
        if let previous {
            preface = HallieTellingMode.closingReply(
                previous,
                persisted: previous.persistedCount == previous.passages.count && !previous.awaitingName,
                speaker: speakers.ownerName) + " "
        }
        var session = HallieTellingMode.Session(opening: opening)
        let alreadyKnown = opening.subject.map { subject in
            if case .resolved = dependencies.loadCyberBrain()?.resolve(subject) ?? .notFound {
                return true
            }
            return false
        } ?? false
        var reply: String
        var notes: [String] = []
        if let first = opening.firstStatement, !session.awaitingName {
            keep(first, session: &session, speakers: speakers,
                 dependencies: dependencies, notes: &notes)
            reply = HallieTellingMode.openingReply(&session, alreadyKnown: alreadyKnown)
                .replacingOccurrences(of: " — I'll remember it.", with: " — I've written that down.")
                .replacingOccurrences(of: " — I'll add it to what I already have.", with: " — I've added that.")
        } else {
            if let first = opening.firstStatement { session.pendingPassages.append(first) }
            reply = HallieTellingMode.openingReply(&session, alreadyKnown: alreadyKnown)
        }
        return response(preface + notes.joined() + reply, telling: session,
                        speakers: speakers, referent: referent)
    }

    private static func keep(
        _ statement: String,
        session: inout HallieTellingMode.Session,
        speakers: HallieTurnExecutor.Speakers,
        dependencies: Dependencies,
        notes: inout [String]
    ) {
        guard let subject = session.subject else { return }
        let isFirst = session.passages.isEmpty
        session.passages.append(statement)
        let speaker = speakers.ownerName ?? ""
        let now = Date()
        do {
            if isFirst, let relation = session.relation {
                try dependencies.recordTestimony(.init(
                    subjectName: subject, speakerName: speaker,
                    text: "\(subject) is \(relation).", kind: .note, date: now))
            }
            try dependencies.recordTestimony(.init(
                subjectName: subject, speakerName: speaker,
                text: statement, kind: .biography, date: now))
            session.persistedCount += 1
        } catch {
            notes.append("I couldn't save that to the family record (\(error.localizedDescription)); I'll keep it for this conversation. ")
        }
    }

    private static func response(
        _ prose: String,
        telling: HallieTellingMode.Session?,
        speakers: HallieTurnExecutor.Speakers,
        referent: CapturedReferent
    ) -> Response {
        let speaker = speakers.ownerName ?? "you"
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: "Basis: listening — kept as told by \(speaker), unverified; no model call, no catalog query.",
            queryDescription: "telling",
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
}
