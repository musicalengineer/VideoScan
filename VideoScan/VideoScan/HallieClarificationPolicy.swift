// HallieClarificationPolicy.swift
// When a clarifying question should be abandoned (Rick's 2026-08-21
// conversational-quality eval).
//
// THE BUG THIS EXISTS FOR: once Hallie asked "which Tim did you mean?", every
// later turn was consumed as a (rejected) answer to that question — 25
// consecutive turns of "I need one of the listed names or numbers so I don't
// guess", because the pending clarification was only ever cleared by an
// explicit `:cancel`. A person who simply asks something else is trapped, and
// nothing feels less like a conversation.
//
// The rule a person would use: if you answered my question, good; if you
// plainly asked me something ELSE, I should drop mine and follow you. Only if
// you seem to be trying to answer and missing do I ask again.
//
// Pure and client-agnostic on purpose: the shell and the chat window both
// decide with this, so the behaviour cannot drift between them.

import Foundation

enum HallieClarificationPolicy {

    enum Decision: Sendable, Equatable {
        /// The reply picks a candidate — proceed with that identity.
        case select(String)
        /// The reply is a failed attempt AT the clarification (a number out
        /// of range, a near-miss name): ask once more.
        case reprompt
        /// The reply is a new turn. Drop the clarification and answer THIS.
        case abandon
    }

    /// Decide what a reply to a pending clarification means.
    ///
    /// - Parameters:
    ///   - reply: what the user typed.
    ///   - candidates: the offered labels, in the order they were shown.
    ///   - select: the client's exact selector (ordinals, stable IDs, exact
    ///     names). Returning non-nil always wins — this policy never
    ///     second-guesses a real selection.
    static func decide(
        reply: String,
        candidates: [String],
        select: (String) -> String?
    ) -> Decision {
        if let id = select(reply) { return .select(id) }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reprompt }

        // A bare number or a one-or-two-word fragment reads as someone still
        // trying to pick from the list (possibly out of range, possibly a
        // misspelling) — ask again rather than silently changing the subject.
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        let looksLikeAnAttempt =
            words.count <= 2
            && !endsWithQuestionMark(trimmed)
            && !startsWithRequestVerb(trimmed)
        if looksLikeAnAttempt { return .reprompt }

        // Mentions one of the candidates by name inside a longer sentence
        // ("I meant Timmy the youngest") — still about the clarification.
        let lowered = trimmed.lowercased()
        for candidate in candidates {
            let name = candidate.lowercased()
            if !name.isEmpty, lowered.contains(name) { return .reprompt }
        }

        // Anything else is a new question. Follow the person.
        return .abandon
    }

    /// What Hallie says when she lets her own question go — she acknowledges
    /// it rather than pretending it never happened.
    static let abandonNote = "Setting that aside for now."

    private static func endsWithQuestionMark(_ text: String) -> Bool {
        text.hasSuffix("?")
    }

    /// Openers that mean the user is asking for something new rather than
    /// answering — kept deliberately small and literal.
    static let requestVerbs = [
        "show", "play", "find", "search", "list", "count", "how", "what",
        "when", "where", "who", "why", "did", "do", "does", "can", "could",
        "tell", "give", "reveal", "open", "is", "are", "was", "were",
        "thanks", "thank", "never", "forget", "hi", "hello", "hey",
    ]

    private static func startsWithRequestVerb(_ text: String) -> Bool {
        guard let first = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first else { return false }
        return requestVerbs.contains(String(first))
    }
}
