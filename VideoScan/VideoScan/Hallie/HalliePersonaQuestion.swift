// HalliePersonaQuestion.swift
// A life fact asked of Hallie HERSELF (GH #184 item 5, live 2026-09-11
// 22:05Z): "where were you born, hallie?" → route temporal, "I need to
// know who you mean — and which video".
//
// What went wrong: HallieConversationGuard.directPersonaFacts treats
// "where were you born" as a tree fact about her namesake and hands it to
// the model, trusting the translator to bind "you" to the archivist and
// come back with a graph ask. The model came back with an age-in-video
// ask and an unbound subject. Nothing deterministic sat ahead of it.
//
// The rule a person would use: a question in the SECOND PERSON with no
// third party in it is addressed to Hallie, and Hallie is the family's
// archivist, not a person with a birthplace, a birthday, an age, a death
// or relatives of her own. She says so — and because she IS named after a
// real tree person (Hallie Mae McGill, Ma's grandmother), she offers that
// biography as the next tap. Model-free, before translation, and narrow:
// only the vital / identity / family-fact shapes are claimed here; the
// life-experience persona lane ("what was your first job") and the
// capability, command and relationship roads keep their own detectors.
//
// What stays out on purpose (each has a negative test):
//   • a third party — a typed capitalised name or a People-tab / CyberBrain
//     name ("how old was Donna in this video", "where were you and Donna
//     in 1994"): archive questions; the presence road already drops the
//     speaker pronouns from the people list;
//   • a first-person word ("how am I related to you"): the owner ↔
//     archivist relationship road;
//   • a search or media word, or a catalog year: archive requests;
//   • a request lead ("can you …", "do you know …"): "you" is the
//     addressee of a request, not the subject of a life question.

import Foundation

enum HalliePersonaQuestion {

    enum Ask: Equatable, Sendable {
        case birthplace
        case birthdate
        case age
        case death
        case origin
        /// "who was your father" / "did you have children" — the kin word.
        case relatives(String)

        var description: String {
            switch self {
            case .birthplace: return "birthplace"
            case .birthdate: return "birthdate"
            case .age: return "age"
            case .death: return "death"
            case .origin: return "origin"
            case .relatives(let word): return "relatives(\(word))"
            }
        }
    }

    static let secondPersonWords: Set<String> = ["you", "your", "yours", "yourself"]
    static let firstPersonWords: Set<String> = [
        "i", "i'm", "me", "my", "mine", "myself", "we", "us", "our", "ours",
    ]
    static let searchAndMediaWords: Set<String> = [
        "show", "find", "search", "play", "reveal", "open", "list", "count",
        "video", "videos", "clip", "clips", "photo", "photos", "picture",
        "pictures", "footage", "tape", "tapes", "recording", "recordings",
        "file", "files", "catalog", "archive", "transcript", "movie",
        "movies", "film", "films",
    ]
    /// "can you …" at the start: the "you" is a request's addressee.
    static let requestLeads = [
        "can you", "could you", "would you", "will you", "do you know",
        "did you find", "have you got", "are you able to",
    ]
    static let vocatives = ["hallie mae", "hallie"]
    static let leadFillers: Set<String> = ["hey", "hi", "ok", "okay", "so", "please"]

    static let kinWords: [String] = [
        "mother", "mom", "mum", "mama", "father", "dad", "daddy", "papa",
        "parents", "grandmother", "grandma", "grandfather", "grandpa",
        "grandparents", "husband", "wife", "spouse", "children", "kids",
        "son", "sons", "daughter", "daughters", "brother", "brothers",
        "sister", "sisters", "siblings", "family", "ancestors",
    ]

    /// Stopwords never offered to the identity oracle as a name (the
    /// same reason HallieConversationGuard keeps a list: a lone glue word
    /// must not be asked about).
    private static let identityStopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "do",
        "does", "did", "can", "could", "would", "should", "will", "to", "of",
        "in", "on", "for", "with", "and", "or", "but", "you", "your", "yours",
        "yourself", "it", "its", "this", "that", "what", "why", "how", "when",
        "where", "who", "which", "as", "at", "from", "about", "into", "than",
        "then", "if", "please", "born", "old", "still", "ever", "any", "have",
        "has", "had", "get", "got", "live", "die", "died", "dead", "alive",
        "come", "grow", "up", "hallie", "mae", "many", "much",
    ]

    /// The ask when `question` is a life fact asked of Hallie herself, else
    /// nil. `isInnerCircleName` is the SMALL curated oracle (People tab +
    /// CyberBrain); the wide tree oracle is deliberately not consulted here
    /// — "born", "old" and "still" are all surnames in a 39k-person tree.
    static func detect(_ question: String, isInnerCircleName: (String) -> Bool) -> Ask? {
        guard let words = normalizedWords(question) else { return nil }
        // Archive cues: a catalog year, a search or media word.
        guard !hasArchiveCue(words) else { return nil }
        // No "you" at all: not this shape, and — before any oracle is
        // asked — nothing is loaded for it (the identity sources are lazy
        // and a translated question must not pull them in for nothing).
        guard words.contains(where: secondPersonWords.contains) else { return nil }
        guard !hasTypedThirdParty(question) else { return nil }
        let remaining = peelingRequestLeads(words)
        // The owner is in it: a relationship / owner question, not hers.
        guard Set(remaining).isDisjoint(with: firstPersonWords) else { return nil }
        guard remaining.contains(where: secondPersonWords.contains) else { return nil }
        // Last, because it is the one check that costs a load.
        guard !containsKnownPerson(words, isInnerCircleName: isInnerCircleName) else { return nil }

        // `padded` has a space at each end so every phrase is matched on
        // word boundaries: " your son " never matches "your sonata".
        let padded = " " + remaining.joined(separator: " ") + " "
        return relativesAsk(in: padded) ?? vitalAsk(in: padded, opener: remaining.first ?? "")
    }

    // MARK: - Phrase tables (ORDER IS THE SPEC: first table that matches wins)
    //
    // GH #281 R3 (2026-10-06): these were one long if-chain of
    // `padded.contains(" … ")` alternatives. Same phrases, same order, now
    // data; HalliePersonaParserOracleTests pins the conversion against a
    // frozen copy of the old chain over every corpus and test sentence.

    /// Relatives: "your father", "your mother's job", "did you have
    /// children". Each frame is (text before the kin word, text after).
    /// Kin words are tried in `kinWords` order, the OUTER loop, exactly as
    /// before — the first kin word with any matching frame wins.
    static let relativeFrames: [(lead: String, tail: String)] = [
        (" your ", " "), (" your ", "'s "),
        (" you have ", " "), (" you have any ", " "), (" you have a ", " "),
        (" you ever have ", " "), (" you ever have any ", " "), (" you ever have a ", " "),
    ]
    /// "were you married" / "did you ever marry" → her husband.
    static let marriedPhrases = [" you married ", " you ever married ", " you ever marry ", " you marry "]
    /// Any of these makes it a birth question; the next three lists decide which.
    static let birthCues = [" born ", " birthplace ", " birthday ", " birth date ", " date of birth "]
    static let birthdateNouns = [" birthday ", " birth date ", " date of birth "]
    /// With the opener "when" these mean the date …
    static let birthdateCues = [" what year ", " what day ", " what date "]
    /// … and with the opener "where" these mean the place.
    static let birthplaceCues = [" what town ", " what city ", " what country ", " what place ",
                                 " what state ", " birthplace "]
    /// The vital asks after birth, in the order they were tried.
    static let laterVitalCues: [(ask: Ask, phrases: [String])] = [
        (.age, [" how old ", " your age ", " age are you "]),
        (.death, [" die ", " died ", " death ", " dead ", " alive ", " pass away ", " passed away ",
                  " still living ", " still around "]),
        (.origin, [" where are you from ", " where do you come from ", " where did you come from ",
                   " where did you grow up ", " where were you raised ", " where are you originally from ",
                   " where you grew up ", " where did you live ", " where do you live "]),
    ]

    private static func containsAny(_ padded: String, _ phrases: [String]) -> Bool {
        phrases.contains { padded.contains($0) }
    }

    private static func relativesAsk(in padded: String) -> Ask? {
        for kin in kinWords
        where relativeFrames.contains(where: { padded.contains($0.lead + kin + $0.tail) }) {
            return .relatives(kin)
        }
        return containsAny(padded, marriedPhrases) ? .relatives("husband") : nil
    }

    private static func vitalAsk(in padded: String, opener: String) -> Ask? {
        if containsAny(padded, birthCues) {
            if containsAny(padded, birthdateNouns) { return .birthdate }
            if opener == "when" || containsAny(padded, birthdateCues) { return .birthdate }
            if opener == "where" || containsAny(padded, birthplaceCues) { return .birthplace }
            return .birthdate
        }
        return laterVitalCues.first { containsAny(padded, $0.phrases) }?.ask
    }

    // MARK: - The guard prelude (order of the guards in `detect` is kept)

    /// Lowercased words with the vocative ("…, hallie"), lead fillers and a
    /// leading "hallie [mae]" peeled; nil when nothing is left.
    private static func normalizedWords(_ question: String) -> [String]? {
        guard question.count <= 200 else { return nil }
        var text = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;: "))
        guard !text.isEmpty else { return nil }

        // Peel the vocative: "hallie, where were you born" / "…, hallie".
        for name in vocatives {
            if text.hasSuffix(", " + name) || text.hasSuffix(" " + name) {
                text = String(text.dropLast(name.count + (text.hasSuffix(", " + name) ? 2 : 1)))
                break
            }
        }
        var words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        while let first = words.first, leadFillers.contains(first) { words.removeFirst() }
        if words.first == "hallie" {
            words.removeFirst()
            if words.first == "mae" { words.removeFirst() }
        }
        return words.isEmpty ? nil : words
    }

    /// A catalog year or a search / media word: an archive request.
    private static func hasArchiveCue(_ words: [String]) -> Bool {
        if words.contains(where: {
            guard $0.count == 4, let year = Int($0) else { return false }
            return ArchivistQueryAST.yearRange.contains(year)
        }) { return true }
        return !Set(words).isDisjoint(with: searchAndMediaWords)
    }

    /// A third party: a typed capitalised word past the first token (never
    /// her own name). The curated known names are checked last, in `detect`.
    private static func hasTypedThirdParty(_ question: String) -> Bool {
        let typedNames = question
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .dropFirst()
            .filter {
                $0.first?.isUppercase == true
                    && !["hallie", "mae", "i", "i'm"].contains($0.lowercased())
            }
        return !typedNames.isEmpty
    }

    /// Request leads peeled: "can you tell me where you were born" keeps
    /// its second "you"; "do you know where donna was born" loses its
    /// only one. "tell me" is a lead too — its "me" is not the owner
    /// asking about himself ("tell me about your family").
    private static func peelingRequestLeads(_ words: [String]) -> [String] {
        var remaining = words
        var opening = " " + remaining.joined(separator: " ") + " "
        for lead in requestLeads where opening.hasPrefix(" \(lead) ") {
            remaining.removeFirst(lead.split(separator: " ").count)
            break
        }
        opening = " " + remaining.joined(separator: " ") + " "
        if opening.hasPrefix(" tell me ") || opening.hasPrefix(" tell us ") {
            remaining.removeFirst(2)
        }
        return remaining
    }

    private static func containsKnownPerson(_ words: [String],
                                            isInnerCircleName: (String) -> Bool) -> Bool {
        let maximum = min(3, words.count)
        guard maximum > 0 else { return false }
        for width in 1...maximum {
            for start in 0...(words.count - width) {
                let span = words[start..<(start + width)]
                if width == 1, identityStopwords.contains(span[span.startIndex]) { continue }
                if isInnerCircleName(span.joined(separator: " ")) { return true }
            }
        }
        return false
    }

    /// The fixed persona reply. `namesake` = the tree / People-tab person
    /// the archivist is named after (nil = none resolves); with one, the
    /// answer says so and offers her biography as the next question.
    static func answer(_ ask: Ask, archivistName: String?, namesake: String?) -> HallieTurnExecutor.Result {
        let name = archivistName ?? HallieTurnExecutor.Speakers.defaultArchivistName
        let role = "I'm \(name), the family's archivist"
        let opening: String
        switch ask {
        case .birthplace:
            opening = "I wasn't born anywhere — \(role), not a person with a birthplace of my own."
        case .birthdate:
            opening = "I don't have a birthday — \(role), not a person with a life of my own."
        case .age:
            opening = "I don't have an age — \(role), not a person who grows older."
        case .death:
            opening = "I don't have a lifetime to end — \(role), not a person."
        case .origin:
            opening = "I'm not from anywhere in particular — \(role), not a person with a hometown."
        case .relatives(let word):
            let plural = word.hasSuffix("s") || word == "children" || word == "kids" || word == "family"
            let noun = word == "family" ? "a family" : (plural ? word : "a \(word)")
            opening = "I don't have \(noun) of my own — \(role), not a person."
        }
        var prose = opening
        var offers: [HallieTurnExecutor.OfferedAction] = []
        var basis = "Basis: a question addressed to \(name) herself, answered from her role; no catalog, family tree, biography or media action was used"
        if let namesake {
            prose += " I am named after \(namesake) in the family tree, though — ask me and I'll tell you what the archive records about \(namesake)."
            offers.append(.ask(question: "tell me about \(namesake)", label: "Tell me about \(namesake)"))
            basis += "; the namesake “\(namesake)” is offered by exact name from the family tree."
        } else {
            prose += " Ask me about the family and I'll answer from the archive."
            basis += "."
        }
        return HallieTurnExecutor.Result(
            route: .conversation,
            outcome: .answered,
            prose: prose,
            basisLine: basis,
            queryDescription: "persona: \(ask.description)",
            citations: [],
            catalogPersonName: nil,
            offeredActions: offers,
            answerPlan: HallieAnswerPlan(route: .conversation, shape: .fixed, fallbackText: prose),
            composedBy: .template)
    }
}
