// HallieCapabilityDeclineFallback.swift
// A narrow second chance, taken AFTER an archive route has already given
// up — never a smarter router. Rick's brother's demo (2026-09-03 eve) hit
// two reflective questions that dead-ended instead of being answered:
//
//   "why do old home videos feel so emotional"
//     -> "Event queries are not supported yet; I did not run a broader
//        search."
//   "what questions could I ask my grandmother about her childhood"
//     -> a tree lookup on the bare kinship word "grandmother" failing with
//        the usual "I don't find … in the family tree" decline.
//
// Both are real answers the general-knowledge lane already gives well (see
// HallieGeneralKnowledgeLane / HallieSocialConversation): the app just never
// asked it. This file does NOT touch the pre-classification router — that
// risks sending a real archive question off to philosophise, a worse
// failure. Instead it recognises, AFTER an archive route has already
// declined, a decline shape that is both (a) a capability/no-referent dead
// end, never a real archive fact or an honest `.capability` answer, and
// (b) a reflective/advisory/creative QUESTION, never a retrieval. Both
// gates are required — see `qualifies`. Three shapes that must NEVER be
// swapped for free chat, caught in review 2026-09-04: an honest
// `.capability` answer ("I can't edit biographies yet…", "I'm read-only"),
// a real retrieval that merely translated into an unsupported-event AST
// ("find birthday parties"), and a lookup on an unknown but real-shaped
// proper name ("who is Jonathan Smith") — none of those are dead ends, and
// generic chat prose in their place would be worse than the original,
// honest decline.
//
// The general answer still goes through HallieGeneralAnswerBoundary exactly
// as any other general reply does — this file only decides WHETHER to ask
// the general lane, never what it may say once asked. Callers own the
// compose/boundary wiring (HallieAppTurnCoordinator, HallieShellCLI already
// have it for the ordinary conversation lane); this file is deliberately
// UI- and dependency-free so it is trivial to unit test.
//
// C++ readers: a namespace of pure static functions over value types, same
// shape as HallieGeneralKnowledgeLane and HallieGeneralAnswerBoundary.

import Foundation

enum HallieCapabilityDeclineFallback {

    /// True for a decline this turn may retry once through general
    /// knowledge. TWO gates, both required:
    ///
    ///  1. Route/outcome shape — narrow on purpose:
    ///     - `.unsupportedEvent` with outcome `.unsupported` — the "event
    ///       queries are not supported yet" family. `.capability` also
    ///       returns `.unsupported` for perfectly good, offer-bearing
    ///       answers ("I can't edit biographies or family facts yet…",
    ///       "I can't <verb> media files; I'm read-only" —
    ///       HallieTurnExecutor+Conversation.capabilityResult) and must
    ///       NEVER be swapped for free chat; those are the answer, not a
    ///       dead end.
    ///     - `.declined` with `noReferentDecline` — a tree/person lookup
    ///       where the typed name never resolved to any real family member
    ///       at all (see `FamilyKnowledgeSupplement.notFoundOffer`, the one
    ///       place that sets it).
    ///  2. The ORIGINAL QUESTION must be reflective, advisory, or creative
    ///     in shape, and must not name a concrete archive referent
    ///     (`isReflectiveOrAdvisoryQuestion`). Without this gate a real
    ///     retrieval that merely happens to translate into an
    ///     unsupported-event AST ("find birthday parties") or a lookup on a
    ///     real but unknown proper name ("who is Jonathan Smith") would get
    ///     generic chat prose in place of an honest decline — a worse
    ///     failure than the dead end this file exists to fix.
    ///
    /// Never true for `.answered`, `.needsClarification` (an offer or a
    /// "did you mean X or Y?" keeps its own answer), `.failed`, `.repaired`,
    /// a plain `.declined` that reports a real archive fact, or any
    /// `.capability` route.
    static func qualifies(_ result: HallieTurnExecutor.Result, question: String) -> Bool {
        let shapeQualifies: Bool
        switch result.outcome {
        case .unsupported:
            shapeQualifies = result.route == .unsupportedEvent
        case .declined:
            shapeQualifies = result.noReferentDecline
        case .answered, .needsClarification, .failed, .repaired:
            shapeQualifies = false
        }
        guard shapeQualifies else { return false }
        return isReflectiveOrAdvisoryQuestion(question)
    }

    /// Openings that mark a reflective, advisory, or creative question —
    /// the shape Rick's brother's live questions actually had. Deliberately
    /// a SEPARATE, smaller list from `HallieGeneralKnowledgeLane.adviceLeads`
    /// rather than an edit to it: that list also gates the pre-classification
    /// router, and widening it there would change which questions reach the
    /// archive lane AT ALL — a much bigger, riskier change than this file
    /// exists to avoid. This list only ever runs after an archive route has
    /// already declined.
    static let reflectiveLeads = [
        "why ", "what should i", "what could i", "what questions",
        "how do i", "how can i", "how should i", "how might i",
        "give me advice", "any advice", "some advice", "tips for",
        "ideas for", "suggest", "help me think", "brainstorm",
        "what makes", "what causes", "how does", "what if",
    ]

    /// Nil-safe defense in depth: even a reflective-shaped opener names a
    /// concrete referent often enough to be a retrieval in disguise ("why
    /// did we visit the Cape in 1994" names a year). A catalog-range year
    /// or decade, or a sentence that ALSO opens like a retrieval command
    /// elsewhere, disqualifies it. Deliberately does NOT reject on ordinary
    /// archive vocabulary alone ("video", "home video") — Rick's own live
    /// example uses exactly that word reflectively, not as a lookup.
    static func isReflectiveOrAdvisoryQuestion(_ question: String) -> Bool {
        let normalized = HallieGeneralKnowledgeLane.normalize(question)
        guard reflectiveLeads.first(where: normalized.hasPrefix) != nil else {
            return false
        }
        let tokens = HallieGeneralKnowledgeLane.words(normalized)
        guard !tokens.contains(where: HallieGeneralKnowledgeLane.isCatalogDate)
        else { return false }
        guard HallieGeneralKnowledgeLane.retrievalLeads
            .first(where: normalized.hasPrefix) == nil
        else { return false }
        return true
    }

    /// The basis line for a fallback answer. Deliberately does not say
    /// "archive" or "catalog" as the source of the FACTS — only that the
    /// archive had nothing, and general knowledge answered instead — so a
    /// free answer can never be mistaken for cited archive evidence.
    static let basisLine =
        "Basis: the archive had nothing to answer this from; answered instead from general knowledge, not the family archive."

    /// Turn-log line written before the retry, so the fallback is visible
    /// in the transcript even when it changes nothing (the boundary still
    /// rejects it and the original decline is kept).
    static func logLine(for result: HallieTurnExecutor.Result, question: String) -> String {
        "[hallie-general] dead-end decline (\(HallieTurnExecutor.label(result.route))/\(HallieTurnExecutor.label(result.outcome))) — retrying through general knowledge — \u{201C}\(question.prefix(120))\u{201D}"
    }

    /// Turn-log line written when the general lane's answer crossed the
    /// family-fact boundary and the original decline was kept instead.
    static let boundaryKeptOriginalLogLine =
        "[hallie-general] fallback answer crossed the family-fact boundary — keeping the original decline"

    /// Whether an enforced reply is the boundary's own refusal (as opposed
    /// to an ordinary general answer, however plain). When true, the
    /// caller must show the ORIGINAL decline, never this refusal stacked on
    /// top of it — the user asked one question and must see one answer.
    static func isBoundaryRefusal(_ reply: HallieSocialConversation.Reply) -> Bool {
        !reply.composedByModel
            && reply.note == HallieGeneralAnswerBoundary.replacementNote
            && reply.text == HallieGeneralAnswerBoundary.replacement
    }

    /// Build the Result a caller shows when the fallback succeeds. `route`
    /// is `.conversation`, matching the ordinary general-knowledge answer —
    /// this IS that lane, arrived at one turn late.
    static func result(
        for reply: HallieSocialConversation.Reply,
        queryDescription: String?
    ) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .conversation,
            outcome: .answered,
            prose: reply.text,
            basisLine: basisLine,
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: nil,
            composedBy: reply.composedByModel ? .model : .template)
    }
}
