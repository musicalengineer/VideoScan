// HallieShellCLI+Telling.swift
// The shell's side of "let me tell you about …" (HallieTellingMode). The
// mode decides what a turn means and what Hallie says; this file owns the
// session state, the durable write (only with --remember), the transcript
// events, and the hand-off back to ordinary answering when the speaker asks
// a question instead.

import Foundation

extension HallieShellCLI {

    /// Start listening. Keeps any statement that arrived with the opener.
    static func beginTelling(
        _ opening: HallieTellingMode.Opening,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        // A telling already in progress about someone else: close it
        // honestly (everything said was kept as it was said).
        if let previous = state.telling {
            let closing = HallieTellingMode.closingReply(
                previous, persisted: previous.persistedCount == previous.passages.count && options.remember,
                speaker: dependencies.speakers().ownerName)
            output(closing)
            state.telling = nil
        }
        var session = HallieTellingMode.Session(opening: opening)
        let alreadyKnown = opening.subject.map { subject in
            if case .resolved = state.cyberBrain?.resolve(subject) ?? .notFound { return true }
            return false
        } ?? false
        var reply: String
        if let first = opening.firstStatement, !session.awaitingName {
            keep(first, session: &session, options: options,
                 state: &state, output: output, dependencies: dependencies)
            reply = HallieTellingMode.openingReply(&session, alreadyKnown: alreadyKnown)
                .replacingOccurrences(of: " — I'll remember it.", with: " — I've written that down.")
                .replacingOccurrences(of: " — I'll add it to what I already have.", with: " — I've added that.")
        } else {
            if let first = opening.firstStatement { session.pendingPassages.append(first) }
            reply = HallieTellingMode.openingReply(&session, alreadyKnown: alreadyKnown)
        }
        state.telling = session
        return await emitTelling(reply, state: &state, output: output,
                                 dependencies: dependencies)
    }

    /// One turn while listening. Returns nil when the turn was a question:
    /// the telling is closed quietly and the caller answers the question.
    static func continueTelling(
        _ text: String,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome? {
        guard var session = state.telling else { return nil }
        let speaker = dependencies.speakers().ownerName
        switch HallieTellingMode.classify(text, session: session) {
        case .switchSubject(let opening):
            return await beginTelling(
                opening, options: options, state: &state,
                output: output, dependencies: dependencies)

        case .question:
            // Everything said so far is already kept; just step aside.
            let aside = HallieTellingMode.settingAsideReply(session)
            if !aside.isEmpty { output(aside.trimmingCharacters(in: .whitespaces)) }
            state.telling = nil
            return nil

        case .finish:
            let persisted = options.remember
                && session.persistedCount == session.passages.count
            let closing = HallieTellingMode.closingReply(
                session, persisted: persisted, speaker: speaker)
            state.telling = nil
            return await emitTelling(closing, state: &state, output: output,
                                     dependencies: dependencies)

        case .name(let name):
            session.subject = name
            // Persist what was said before the name arrived, in order.
            let pending = session.pendingPassages
            session.pendingPassages = []
            for statement in pending {
                keep(statement, session: &session, options: options,
                     state: &state, output: output, dependencies: dependencies)
            }
            let reply = HallieTellingMode.namedReply(&session)
            state.telling = session
            return await emitTelling(reply, state: &state, output: output,
                                     dependencies: dependencies)

        case .statement(let statement):
            if session.awaitingName {
                session.pendingPassages.append(statement)
                state.telling = session
                return await emitTelling(
                    HallieTellingMode.stillNeedNameReply(session),
                    state: &state, output: output, dependencies: dependencies)
            }
            keep(statement, session: &session, options: options,
                 state: &state, output: output, dependencies: dependencies)
            let reply = HallieTellingMode.acknowledgement(&session)
            state.telling = session
            return await emitTelling(reply, state: &state, output: output,
                                     dependencies: dependencies)
        }
    }

    /// Keep one statement: in the session always; on disk with --remember.
    private static func keep(
        _ statement: String,
        session: inout HallieTellingMode.Session,
        options: Options,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) {
        guard let subject = session.subject else { return }
        let isFirst = session.passages.isEmpty
        session.passages.append(statement)
        guard options.remember else { return }
        let speaker = dependencies.speakers().ownerName ?? ""
        let now = Date()
        do {
            // The relation the speaker gave ("Rick's dad") is a fact about
            // the person, kept as a note — never as an alias, because the
            // alias tokens ("rick") would make "rick" ambiguous later.
            if isFirst, let relation = session.relation,
               let index = try dependencies.recordTestimony(.init(
                    subjectName: subject, speakerName: speaker,
                    text: "\(subject) is \(relation).", kind: .note, date: now)) {
                state.cyberBrain = index
            }
            // A nil index means "recorded, nothing to reload" (tests, or a
            // client that reloads lazily); only a throw means not kept.
            if let index = try dependencies.recordTestimony(.init(
                subjectName: subject, speakerName: speaker,
                text: statement, kind: .biography, date: now)) {
                state.cyberBrain = index
            }
            session.persistedCount += 1
        } catch {
            output("I couldn't save that to the family record (\(error.localizedDescription)); I'll keep it for this session.")
        }
    }

    private static func emitTelling(
        _ prose: String,
        state: inout Session,
        output: (String) -> Void,
        dependencies: Dependencies
    ) async -> AnswerOutcome {
        let speaker = dependencies.speakers().ownerName ?? "you"
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: "Basis: listening — kept as told by \(speaker), unverified; no model call, no catalog query.",
            queryDescription: "telling",
            citations: [],
            catalogPersonName: nil)
        state.lastResponder = "local"
        output("interpreted: telling (local)")
        render(result, ast: nil, context: state.identityContext,
               state: &state, output: output)
        // Deliberately NOT added to the composer's history: what a family
        // member told Hallie must never become phrasing material for an
        // unrelated later answer (the 2026-08-21 history-leak guard).
        let event = transcriptEvent(result: result, responder: "local", state: &state)
        await dependencies.recordTranscript([event])
        return .answered
    }
}
