// HallieTreeFollowUp.swift
// "show me" / "let me see" / "open it" after a family-tree answer (design
// §3.5, live 2026-09-11 "show me" after Rick's biography). The thing to
// show — the "Open in Family Tree" offer, the photo — is remembered on
// ConversationMemory.tree; this pure handler acts on it:
//   exactly one → performed (immediateOfferedAction / the photo re-attached);
//   several     → a choice, as chips;
//   none        → "show you what?" with chips built from the subject.
// Identity rides on the offer's personID where it has one, so a stale
// offer against a renamed or recompiled tree is refused, never fired.

import Foundation

enum HallieTreeFollowUp {
    typealias Exec = HallieTurnExecutor

    /// What the last tree answer offered to show, as one list.
    enum Offer: Equatable, Sendable {
        case action(Exec.OfferedAction)
        case photo(HalliePhotoAttachment)

        var label: String {
            switch self {
            case .action(let action): return Exec.offerLabel(action)
            case .photo(let photo): return "The photo of \(photo.personName)"
            }
        }
    }

    private static let politeness: Set<String> = ["please", "hallie", "ok", "okay", "yes", "yeah", "sure", "then"]
    private static let shapes: Set<[String]> = [
        ["show", "me"], ["show", "it"], ["show", "me", "it"], ["show", "it", "to", "me"],
        ["show", "that"], ["show", "me", "that"], ["show", "them"], ["show", "me", "them"],
        ["let", "me", "see"], ["let", "me", "see", "it"], ["let", "me", "see", "that"],
        ["lets", "see"], ["let's", "see"], ["lets", "see", "it"], ["let's", "see", "it"],
        ["open", "it"], ["can", "i", "see", "it"], ["can", "i", "see"], ["i", "want", "to", "see", "it"],
        ["go", "ahead"], ["do", "it"],
    ]

    /// A bare "show me" with nothing to say what — the elliptical form only.
    static func isShowMe(_ question: String) -> Bool {
        let words = HallieMediaVocabulary.words(question).filter { !politeness.contains($0) }
        return shapes.contains(words)
    }

    /// The offers still valid: an offer that names a tree person by id is
    /// kept only when that id still exists (`isTreePersonID`); nil = trust.
    static func offers(
        in tree: Exec.ConversationMemory.TreeContext,
        isTreePersonID: ((String) -> Bool)?
    ) -> (live: [Offer], stale: Int) {
        var stale = 0
        var live: [Offer] = []
        for action in tree.lastOffers {
            switch action {
            case .openFamilyTreePerson(let id, _), .showPossibleDuplicate(let id, _):
                if let isTreePersonID, !isTreePersonID(id) { stale += 1; continue }
                live.append(.action(action))
            default:
                live.append(.action(action))
            }
        }
        if let photo = tree.lastPhoto { live.append(.photo(photo)) }
        return (live, stale)
    }

    /// Nil unless the turn is a bare "show me" — the caller decides that
    /// the session is in tree mode.
    static func turn(
        question: String,
        memory: Exec.ConversationMemory,
        isTreePersonID: ((String) -> Bool)? = nil
    ) -> Exec.Result? {
        guard isShowMe(question) else { return nil }
        let found = offers(in: memory.tree, isTreePersonID: isTreePersonID)
        let subject = memory.tree.subject
        switch found.live.count {
        case 1:
            return perform(found.live[0], subject: subject)
        case 0:
            if found.stale > 0 {
                return decline(
                    "The person I offered to show has changed since my last answer — ask me about them again and I'll offer it afresh.",
                    query: "tree follow-up: show me → stale offer refused")
            }
            guard let subject, !subject.isEmpty else {
                return decline("Show you what? Ask me about someone in the family first.",
                               query: "tree follow-up: show me → nothing offered")
            }
            let possessive = subject.hasSuffix("s") ? subject + "’" : subject + "’s"
            return Exec.Result(
                route: .graph, outcome: .declined,
                prose: "Show you what — a photo of \(subject), or \(possessive) place in the family tree?",
                basisLine: "Basis: my last answer offered nothing to show; these are the two things I can show for \(subject). Nothing was looked up.",
                queryDescription: "tree follow-up: show me → offer chips for \(subject)",
                citations: [], catalogPersonName: subject,
                offeredActions: [
                    .ask(question: "photos of \(subject)", label: "A photo of \(subject)"),
                    .ask(question: "show \(possessive) family tree", label: "\(possessive) family tree"),
                ],
                mode: .tree)
        default:
            let chips: [Exec.OfferedAction] = found.live.map { offer in
                switch offer {
                case .action(let action): return action
                case .photo(let photo):
                    return .ask(question: "photos of \(photo.personName)", label: "The photo of \(photo.personName)")
                }
            }
            let labels = found.live.map(\.label)
            let list = labels.dropLast().joined(separator: ", ") + ", or " + (labels.last ?? "")
            return Exec.Result(
                route: .graph, outcome: .answered,
                prose: "Which would you like — \(list)?",
                basisLine: "Basis: the offers from my last answer; nothing new was looked up.",
                queryDescription: "tree follow-up: show me → \(found.live.count) offers",
                citations: [], catalogPersonName: subject,
                offeredActions: chips,
                mode: .tree)
        }
    }

    private static func perform(_ offer: Offer, subject: String?) -> Exec.Result {
        switch offer {
        case .action(let action):
            return Exec.Result(
                route: .graph, outcome: .answered,
                prose: "Opening \(Exec.offerLabel(action).replacingOccurrences(of: "Open in Family Tree: ", with: "the family tree on ")).",
                basisLine: "Basis: the one thing my last answer offered to show; nothing new was looked up.",
                queryDescription: "tree follow-up: show me → \(Exec.offerLabel(action))",
                citations: [], catalogPersonName: subject,
                offeredActions: [action],
                immediateOfferedAction: action,
                mode: .tree)
        case .photo(let photo):
            return Exec.Result(
                route: .graph, outcome: .answered,
                prose: "Here's the photo of \(photo.personName) again.",
                basisLine: "Basis: the photo my last answer showed; nothing new was looked up.",
                queryDescription: "tree follow-up: show me → photo of \(photo.personName)",
                citations: [], catalogPersonName: photo.personName,
                attachments: [.photo(photo)],
                mode: .tree)
        }
    }

    private static func decline(_ prose: String, query: String) -> Exec.Result {
        Exec.Result(
            route: .graph, outcome: .declined, prose: prose,
            basisLine: "Basis: conversation memory only; nothing was looked up.",
            queryDescription: query, citations: [], catalogPersonName: nil,
            mode: .tree)
    }
}
