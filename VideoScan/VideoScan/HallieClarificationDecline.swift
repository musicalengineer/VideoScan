// HallieClarificationDecline.swift
// What a typed "no" to a pending question means, per stage (2026-09-10).
//
// The chat window used to answer every "no" / "cancel" with "Okay — I
// won't guess which person you meant." That is the right line for a
// which-one, and the wrong one for an OFFER ("want to see them all?"):
// nobody was being guessed at. One shared table so the Mac window and the
// shell say the same thing; the web client only takes chip selections.

import Foundation

enum HallieClarificationDecline {
    /// Replies that close a pending question without choosing. Matched on
    /// the normalized text (PersonResolver.normalize), so "No, thanks!"
    /// and "no thanks" are the same reply.
    static let phrases: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "not now", "not right now",
        "maybe later", "later", "cancel", "never mind", "nevermind", "skip", "no not now",
    ]

    static func matches(_ text: String) -> Bool {
        let folded = PersonResolver.normalize(text)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        return phrases.contains(folded)
    }

    /// The line Hallie says when the pending question is let go.
    static func reply(for stage: HallieTurnExecutor.ClarificationStage) -> String {
        switch stage {
        case .galleryOffer:
            return "Okay."
        case .profileIdentity, .gedcomPerson, .cyberBrainPerson, .suggestedIdentity:
            return "Okay — I won't guess which person you meant."
        }
    }
}
