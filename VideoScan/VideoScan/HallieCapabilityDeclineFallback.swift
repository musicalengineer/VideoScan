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
// asked it. Rather than teach the classifier which questions are
// "reflective" — which risks sending a real archive question off to
// philosophise, a worse failure — this file recognises the SHAPE of a
// capability/no-referent decline once the archive route has already
// answered, and lets the caller retry the very same turn through the
// general lane. Every other decline (a genuine archive fact — "nothing
// from 1950-1959", "I don't find Frank among his three siblings") is left
// exactly as it was: those are correct, informative answers.
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
    /// knowledge:
    ///  - `.unsupported` — the "<shape> queries are not supported yet"
    ///    family (currently just `.unsupportedEvent`; any future unsupported
    ///    shape reuses this Outcome and is covered for free);
    ///  - `.declined` with `noReferentDecline` — a tree/person lookup where
    ///    the typed name never resolved to any real family member at all
    ///    (see `FamilyKnowledgeSupplement.notFoundOffer`, the one place that
    ///    sets it).
    ///
    /// Never true for `.answered`, `.needsClarification` (an offer or a
    /// "did you mean X or Y?" keeps its own answer), `.failed`, `.repaired`,
    /// or a plain `.declined` that reports a real archive fact.
    static func qualifies(_ result: HallieTurnExecutor.Result) -> Bool {
        switch result.outcome {
        case .unsupported:
            return true
        case .declined:
            return result.noReferentDecline
        case .answered, .needsClarification, .failed, .repaired:
            return false
        }
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
