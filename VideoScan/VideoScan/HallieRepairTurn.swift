// HallieRepairTurn.swift
// Conversation repair: a turn ABOUT Hallie's previous answer ("that's
// wrong", "you presented me a list of people born hundreds of years ago",
// "no, I meant the living one", "why did you…") is never a catalog or tree
// search. Live miss #4, 2026-08-28: after a which-one list of medieval
// namesakes for "me (Rick)", Rick's complaint became a presence search for
// the keyword "hundreds of years ago" and was declined.
//
// The detector is deterministic and deliberately narrow: a second-person
// reference to Hallie plus a complaint / correction cue, a demonstrative
// about the last answer plus a cue, or an explicit negation of it. It only
// applies when there IS a previous exchange to repair (ConversationMemory
// .lastExchange); the same words as a fresh first question route normally.
//
// The reply acknowledges, restates what was understood from the ORIGINAL
// ask (the turn before the clarification / answer, not the complaint), and
// either re-asks a better which-one — with the obvious constraint from the
// complaint applied ("born hundreds of years ago" → recent people and
// People-tab profiles only) — or offers the most plausible next steps as
// chips. No model call. Logged as `outcome: repaired`.

import Foundation

enum HallieRepairTurn {
    typealias Exec = HallieTurnExecutor

    // MARK: Detection

    /// Complaint / correction cues that stand on their own once the turn
    /// refers to Hallie or to her last answer.
    private static let complaintCues: [String] = [
        "wrong", "not what i asked", "not what i meant", "not what i wanted",
        "not what i want", "useless", "didn't ask", "did not ask", "never asked",
        "not right", "isn't right", "incorrect", "mistake", "misunderstood",
        "misread", "not helpful", "makes no sense", "make no sense", "no sense",
        "that's not it", "not the one i", "none of those", "none of them",
        "not those", "no good", "way off", "missed",
    ]
    /// Cues that explicitly question what Hallie did.
    private static let whyCues: [String] = [
        "why did you", "why are you", "why would you", "why do you keep",
    ]
    /// Past-tense verbs about what Hallie DID last turn ("you presented me
    /// a list"): meta only with "you" and only when the sentence is not a
    /// request in its own right.
    private static let assistantActionVerbs: [String] = [
        "presented", "gave", "showed", "listed", "offered", "picked", "chose",
        "returned", "suggested", "answered",
    ]
    private static let secondPerson: Set<String> = [
        "you", "your", "you're", "you've", "youre", "youve", "hallie",
    ]
    /// Openers that mean the person is asking for something new, not
    /// talking about the last answer (mirrors HallieClarificationPolicy).
    private static let requestOpeners: Set<String> = [
        "show", "play", "find", "search", "list", "count", "how", "what",
        "when", "where", "who", "which", "can", "could", "would", "will",
        "tell", "give", "reveal", "open", "is", "are", "was", "were", "do",
        "does", "did", "let", "please", "get", "look",
    ]
    private static let demonstrativeOpeners: [String] = [
        "that's", "thats", "that is", "that ", "those ", "these ", "this ",
        "the list", "your list", "the answer", "your answer", "that list",
    ]
    private static let negationOpeners: [String] = ["no,", "no ", "nope", "not that", "not those", "not them"]
    private static let negationCues: [String] = [
        "meant", "i mean", "not that", "not those", "not them", "the other",
        "the living", "the one ", "wrong", "not him", "not her",
    ]
    /// The complaint says the offered people were too long ago / not alive.
    private static let pastEraCues: [String] = [
        "hundreds of years", "hundreds or years", "centuries", "medieval",
        "ancient", "long dead", "long ago", "too old", "living", "alive",
        "still around", "recent", "modern",
    ]
    private static let centuryDecade = /\b1[0-9]00s\b/

    /// Lowercased, curly quotes straightened, whitespace collapsed.
    static func fold(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func words(_ folded: String) -> [String] {
        folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    /// True when the text is a meta / repair turn about the previous answer.
    /// Pure text: the caller decides whether there is an answer to repair.
    static func isRepair(_ text: String) -> Bool {
        let folded = fold(text)
        guard !folded.isEmpty else { return false }
        let tokens = words(folded)
        guard let opener = tokens.first else { return false }
        let hasSecondPerson = tokens.contains { secondPerson.contains($0) }
        let hasComplaint = complaintCues.contains { folded.contains($0) }
        let hasWhy = whyCues.contains { folded.contains($0) }
        let hasPastEra = pastEraCues.contains { folded.contains($0) }
            || folded.firstMatch(of: centuryDecade) != nil
        let demonstrative = demonstrativeOpeners.contains { folded.hasPrefix($0) }
        let negation = negationOpeners.contains { folded.hasPrefix($0) }
            && negationCues.contains { folded.contains($0) }

        if hasWhy { return true }
        if negation { return true }
        // Bare verdicts: "wrong", "nope, incorrect".
        if ["wrong", "incorrect", "nope"].contains(folded) { return true }
        // A request in its own right ("show me people born hundreds of years
        // ago", "can you find …") is never a repair, whatever else it says.
        if requestOpeners.contains(opener) { return false }
        if demonstrative, hasComplaint || hasPastEra { return true }
        if hasSecondPerson, hasComplaint { return true }
        // "you presented me a list of people born hundreds or years ago":
        // Hallie + what she did last turn, stated rather than asked.
        if hasSecondPerson, !folded.hasSuffix("?"),
           tokens.contains(where: { assistantActionVerbs.contains($0) }) {
            return true
        }
        return false
    }

    /// The complaint says the offered people were from centuries ago (or
    /// asks for the living / recent one): prefer recent candidates.
    static func prefersRecent(_ text: String) -> Bool {
        let folded = fold(text)
        return pastEraCues.contains { folded.contains($0) }
            || folded.firstMatch(of: centuryDecade) != nil
    }

    // MARK: Candidate narrowing

    /// The first 4-digit year in a which-one label ("Richard Cholmeley
    /// (b. 1516, d. 17 May 1583)") — the birth year, the way labels are
    /// built; nil for an undated person.
    static func birthYear(of candidate: Exec.Candidate) -> Int? {
        candidate.label.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/).flatMap { Int($0.1) }
    }

    /// Anyone who could be alive: born within the last 125 years.
    static var recentCutoffYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: Date()) - 125
    }

    /// Recent / living-plausible candidates: People-tab profiles first (a
    /// profile is a person the family recognises today), then the tree's
    /// recent births, newest first. Undated tree people are dropped — the
    /// complaint was about era, and an unknown era is not an answer to it.
    static func recentCandidates(_ candidates: [Exec.Candidate], cutoff: Int = recentCutoffYear) -> [Exec.Candidate] {
        let profiles = candidates.filter { $0.source == .peopleProfile }
        let recentTree = candidates
            .filter { $0.source != .peopleProfile }
            .compactMap { c in birthYear(of: c).map { (c, $0) } }
            .filter { $0.1 >= cutoff }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        return profiles + recentTree
    }

    // MARK: Reply

    static let maximumChips = 4

    /// The repair reply for `text`, given the exchange it complains about.
    static func answer(_ text: String, exchange: Exec.ConversationMemory.Exchange) -> Exec.Result {
        let understood = describe(exchange)
        let original = "You asked “\(exchange.question)”, and I took it as \(understood)."
        let basis = "Basis: your correction and my previous answer; no catalog query, tree lookup, or model call."
        let wantsRecent = prefersRecent(text)

        if !exchange.candidates.isEmpty {
            let offered = exchange.candidates
            let shortlist = wantsRecent
                ? recentCandidates(offered)
                : offered.filter { $0.source == .peopleProfile } + offered.filter { $0.source != .peopleProfile }
            let shown = Array(shortlist.prefix(maximumChips))
            let chips: [Exec.OfferedAction] = shown.map { .ask(question: $0.label, label: $0.label) }
            if wantsRecent, shown.isEmpty {
                return Exec.Result(
                    route: .followUp, outcome: .repaired,
                    prose: "Sorry — that list was no help. " + original
                        + " Everyone I offered was born centuries ago, and I have no recent "
                        + "person by that name in the family tree or the People tab. "
                        + "Give me the full name, or a birth year, and I'll try again.",
                    basisLine: basis,
                    queryDescription: "repair: which-one had no recent candidate (\(offered.count) offered)",
                    citations: [], catalogPersonName: nil,
                    offeredActions: [
                        .ask(question: exchange.question, label: askAgainLabel(exchange.question)),
                        .ask(question: "help", label: "Show me what I can ask"),
                    ])
            }
            let lead = wantsRecent
                ? "Sorry — that list was no help; most of those people were born centuries ago. "
                : "Sorry — let me try that again. "
            let names = shown.map(\.label).joined(separator: " · ")
            let which = wantsRecent
                ? "The recent one\(shown.count == 1 ? "" : "s") I have: \(names). "
                : "The people I can match: \(names). "
            return Exec.Result(
                route: .followUp, outcome: .repaired,
                prose: lead + original + " " + which
                    + (shown.count == 1 ? "Is that who you meant?" : "Which one did you mean?"),
                basisLine: basis,
                queryDescription: "repair: which-one narrowed \(offered.count)→\(shown.count)"
                    + (wantsRecent ? " (recent)" : ""),
                citations: [], catalogPersonName: nil,
                offeredActions: chips)
        }

        let quoted = String(exchange.answer.prefix(160))
            + (exchange.answer.count > 160 ? "…" : "")
        return Exec.Result(
            route: .followUp, outcome: .repaired,
            prose: "Sorry about that. " + original + " My answer was: “\(quoted)”. "
                + "Tell me what was off — a different person, year, or place — or ask it another way and I'll look again.",
            basisLine: basis,
            queryDescription: "repair: restated “\(exchange.question.prefix(60))”",
            citations: [], catalogPersonName: nil,
            offeredActions: [
                .ask(question: exchange.question, label: askAgainLabel(exchange.question)),
                .ask(question: "help", label: "Show me what I can ask"),
            ])
    }

    private static func askAgainLabel(_ question: String) -> String {
        guard question.count > 48 else { return "Ask again: \(question)" }
        var short = String(question.prefix(45))
        if let cut = short.lastIndex(of: " ") { short = String(short[..<cut]) }
        return "Ask again: \(short)…"
    }

    /// A plain-words restatement of how the original ask was read.
    static func describe(_ exchange: Exec.ConversationMemory.Exchange) -> String {
        func list(_ people: [String]) -> String {
            let names = people.filter { !$0.isEmpty }
            switch names.count {
            case 0: return ""
            case 1: return " about \(names[0])"
            case 2: return " about \(names[0]) and \(names[1])"
            default:
                let last = names[names.count - 1]
                return " about " + names.dropLast().joined(separator: ", ") + ", and \(last)"
            }
        }
        func span(_ start: Int?, _ end: Int?) -> String {
            switch (start, end) {
            case (let s?, let e?) where s != e: return " from \(s) to \(e)"
            case (let s?, _): return " around \(s)"
            case (nil, let e?): return " up to \(e)"
            default: return ""
            }
        }
        guard let ast = exchange.ast else {
            return "a question I answered on my own (\(Exec.label(exchange.route)))"
        }
        switch ast {
        case .graph(let g):
            switch g.operation {
            case .relationship: return "a family-tree question about how the two are related" + (g.people.count == 2 ? " (\(g.people[0]) and \(g.people[1]))" : "")
            case .commonAncestor: return "a question about the closest common ancestor" + (g.people.count == 2 ? " of \(g.people[0]) and \(g.people[1])" : "")
            case .kinship: return "a family-tree question\(list(g.people))" + (g.relation.map { " (\($0.rawValue))" } ?? "")
            case .familyTree: return "a request for the family tree\(list(g.people))"
            case .biography: return "a request to tell you\(list(g.people))"
            case .birth:
                return g.people.count == 1 ? "a question about when \(g.people[0]) was born"
                    : "a question about birth dates\(list(g.people))"
            case .death:
                return g.people.count == 1 ? "a question about when \(g.people[0]) died"
                    : "a question about death dates\(list(g.people))"
            case .birthPlace:
                return g.people.count == 1 ? "a question about where \(g.people[0]) was born"
                    : "a question about birthplaces\(list(g.people))"
            case .deathPlace:
                return g.people.count == 1 ? "a question about where \(g.people[0]) died"
                    : "a question about where people died\(list(g.people))"
            }
        case .presence(let p):
            let kind = p.mediaKind == .photo ? "photos" : "videos"
            return "a search for \(kind)\(list(p.people ?? []))\(span(p.yearStart, p.yearEnd))"
        case .cross(let p):
            return "a search for videos\(list(p.people ?? []))\(span(p.yearStart, p.yearEnd))"
        case .event(let p):
            return "a search for an event\(list(p.people ?? []))\(span(p.yearStart, p.yearEnd))"
        case .temporal(let p):
            return "a question about \(p.subject) at a point in time"
        case .aggregate(let p):
            return "a count over the catalog\(list(p.anchorPeople))"
        }
    }
}
