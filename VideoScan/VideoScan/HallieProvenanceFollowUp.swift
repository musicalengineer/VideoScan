// HallieProvenanceFollowUp.swift
// "Where did that come from?" / "How do you know?" / "How sure are you?" —
// answered from the LAST answer's own provenance, never by asking the
// model (overnight cycle 1, 2026-08-21; codex's pass-4 found these turns
// falling through to the classifier and coming back vague).
//
// Every Hallie answer already carries its provenance: the route it took,
// the basis line (the deterministic audit trail), the cited catalog items,
// and the family-knowledge citations. ConversationMemory keeps that for
// one turn; this file turns it back into a plain sentence. Pure.

import Foundation

enum HallieProvenanceFollowUp {

    enum Kind: Equatable, Sendable {
        /// "where did that come from", "what's your source", "which records…"
        case source
        /// "how sure are you", "is that verified", "are you certain"
        case confidence
    }

    /// What one answer rested on. Recorded for every answered archive turn.
    struct Provenance: Equatable, Sendable {
        let route: HallieTurnExecutor.Route
        let basisLine: String
        let citations: [String]          // filenames, bounded
        let knowledge: [String]          // "title (attribution)", bounded
        let matchCount: Int?
        let composedBy: HallieComposedBy
        /// True when any cited item rests on a person-confirmed tag.
        let humanConfirmed: Bool
        /// True when a family-knowledge item was marked not yet verified.
        let unverifiedKnowledge: Bool

        init(result: HallieTurnExecutor.Result) {
            route = result.route
            basisLine = result.basisLine
            citations = result.citations.prefix(5).map(\.filename)
            knowledge = result.knowledgeCitations.prefix(4).map { citation in
                if let attribution = citation.attribution { return "\(citation.title) (\(attribution))" }
                return citation.title
            }
            matchCount = result.matchCount
            composedBy = result.composedBy
            humanConfirmed = result.citations.contains { citation in
                citation.bases.contains { basis in
                    if case .humanPersonTag = basis { return true }
                    return false
                }
            }
            unverifiedKnowledge = result.prose.contains("not yet verified")
                || result.basisLine.contains("unverified")
        }
    }

    // MARK: - Detection

    private static let sourcePhrases: Set<String> = [
        "where did that come from", "where does that come from", "where did this come from",
        "where did you get that", "where did you get this", "where is that from", "where's that from",
        "how do you know", "how do you know that", "how do you know this", "how would you know",
        "what's your source", "what is your source", "whats your source", "source", "sources",
        "your source", "what are your sources", "what's the source", "what is the source",
        "which records support that", "what records support that", "which records is that from",
        "what records is that based on", "what is that based on", "what's that based on",
        "based on what", "what's the evidence", "what is the evidence", "show me the evidence",
        "what's the basis", "what is the basis", "is that from the family tree or the catalog",
        "family tree or catalog", "is that from the catalog", "is that from the family tree",
        "did that come from the family tree", "did that come from the catalog",
        "where is that written", "who told you that", "who said that", "says who",
        "can you back that up", "back that up", "prove it", "what's that from",
    ]

    private static let confidencePhrases: Set<String> = [
        "how sure are you", "how certain are you", "how confident are you", "are you sure",
        "are you certain", "are you confident", "is that verified", "is that confirmed",
        "is that right", "is that true", "is that accurate", "is that reliable", "can i trust that",
        "how reliable is that", "how accurate is that", "really", "are you sure about that",
        "is that a guess", "did you guess", "are you guessing", "how do you know for sure",
    ]

    private static let lead: Set<String> = [
        "hallie", "please", "ok", "okay", "hey", "so", "and", "but", "um", "wait", "hmm", "now",
    ]

    /// Leads that may carry an object: "which records support that
    /// biography?", "how certain are you about that date?". Matched as a
    /// prefix of a short turn (≤ 12 words), so "how do you know Donna"
    /// (a real question) still goes to the archive — the object after a
    /// lead must be a back-reference (that / this / it / the …), never a
    /// name.
    private static let sourceLeads: [String] = [
        "where did that come from", "where did this come from", "where does that come from",
        "which records support", "what records support", "which record supports",
        "what is that based on", "what's that based on", "what records is that based on",
        "what's your source", "what is your source", "what are your sources",
        "is that from the family tree", "is that from the catalog", "who told you",
        "how do you know that", "how do you know this", "where did you get that",
    ]
    private static let confidenceLeads: [String] = [
        "how sure are you", "how certain are you", "how confident are you",
        "are you sure", "are you certain", "are you confident",
        "is that verified", "is that confirmed", "how reliable is that", "how accurate is that",
    ]
    private static let backReferences: Set<String> = [
        "that", "this", "it", "the", "those", "these", "your", "about", "of", "on", "in",
        "answer", "biography", "date", "fact", "number", "count", "list", "one", "last",
        "claim", "year", "name", "birthday", "age", "result", "file", "files", "video", "videos",
    ]

    static func detect(_ text: String) -> Kind? {
        var words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        while let first = words.first, lead.contains(first) { words.removeFirst() }
        while let last = words.last, ["hallie", "please", "exactly", "though"].contains(last) { words.removeLast() }
        let phrase = words.joined(separator: " ")
        guard !phrase.isEmpty, words.count <= 12 else { return nil }
        if confidencePhrases.contains(phrase) { return .confidence }
        if sourcePhrases.contains(phrase) { return .source }
        // A lead followed only by back-references ("… about that date?").
        func tail(after lead: String) -> [String]? {
            guard phrase == lead || phrase.hasPrefix(lead + " ") else { return nil }
            return Array(phrase.dropFirst(lead.count).split(separator: " ").map(String.init))
        }
        for lead in confidenceLeads {
            if let rest = tail(after: lead), rest.allSatisfy({ backReferences.contains($0) }) { return .confidence }
        }
        for lead in sourceLeads {
            if let rest = tail(after: lead), rest.allSatisfy({ backReferences.contains($0) }) { return .source }
        }
        return nil
    }

    // MARK: - Answer

    static func answer(_ kind: Kind, provenance: Provenance?) -> HallieTurnExecutor.Result {
        guard let p = provenance else {
            return result(
                "Ask me something first and I'll tell you exactly where the answer came from — I always keep the trail.",
                basis: "Basis: conversation memory only; no previous answer to explain.")
        }
        var sentences: [String] = [sourceSentence(p)]
        let trail = p.basisLine.hasPrefix("Basis: ") ? String(p.basisLine.dropFirst(7)) : p.basisLine
        if !trail.isEmpty { sentences.append("The trail: " + trail) }
        if !p.citations.isEmpty {
            let list = p.citations.joined(separator: ", ")
            if let total = p.matchCount, total > p.citations.count {
                sentences.append("I cited \(p.citations.count) of \(total) matching items: \(list).")
            } else {
                sentences.append("I cited: \(list).")
            }
        }
        if !p.knowledge.isEmpty {
            sentences.append("Family knowledge: " + p.knowledge.joined(separator: "; ") + ".")
        }
        if kind == .confidence { sentences.append(confidenceSentence(p)) }
        if p.composedBy == .model {
            sentences.append("The wording was phrased by the local model, but every sentence was checked against those facts before I showed it.")
        }
        return result(sentences.joined(separator: " "),
                      basis: "Basis: provenance of the previous answer, from conversation memory; no new query.")
    }

    private static func sourceSentence(_ p: Provenance) -> String {
        switch p.route {
        case .presence, .cross:
            return p.humanConfirmed
                ? "That came from the video catalog — the people tags on those files were confirmed by a person, not guessed."
                : "That came from the video catalog: file names, dates and the tags on each file."
        case .aggregate:
            return "That came from counting person-confirmed tags across the whole video catalog."
        case .temporal:
            return "That came from the selected recording's date and the person's birth date in the family records."
        case .graph:
            return p.knowledge.isEmpty
                ? "That came from the family tree (the imported GEDCOM), not the video catalog."
                : "That came from the family tree together with what the family has told me."
        case .telling:
            return "That was you telling me — I wrote it down exactly as you said it, marked as told by you and not yet verified."
        case .unsupportedEvent, .followUp, .capability, .help, .smalltalk, .conversation, .reset:
            return "That wasn't a fact from the archive — it was conversation, so there's nothing to cite."
        }
    }

    private static func confidenceSentence(_ p: Provenance) -> String {
        if p.unverifiedKnowledge {
            return "As sure as the family's own account: part of it was told to me and is marked not yet verified, so treat it as a recollection, not a record."
        }
        switch p.route {
        case .presence, .cross, .aggregate:
            return p.humanConfirmed
                ? "Quite sure — those tags were confirmed by a person; I don't infer who is in a video."
                : "Sure of the files; less sure of who is in them unless a person tagged them — I never guess identity."
        case .graph:
            return "As sure as the family tree is — I report what it records and say so when it's missing something."
        case .temporal:
            return "The arithmetic is exact; the recording date is only as good as its source, which I name in the trail."
        default:
            return "I only say what the catalog and the family records contain; nothing is inferred."
        }
    }

    private static func result(_ prose: String, basis: String) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .followUp,
            outcome: .answered,
            prose: prose,
            basisLine: basis,
            queryDescription: "provenance",
            citations: [],
            catalogPersonName: nil)
    }
}
