// HallieTurnInterpretation.swift
// The model's first decision is deliberately typed: either an archive AST
// or a bounded non-archive conversation. ArchivistQueryAST remains an
// archive-only protocol and never acquires a catch-all "chat" shape.

import Foundation

enum HallieConversationKind: String, Sendable, Equatable, CaseIterable {
    /// Greetings and ordinary back-and-forth not handled by the deterministic
    /// small-talk table.
    case casual
    /// Timeless public knowledge, language, advice, or harmless creativity.
    case generalKnowledge
    /// A request that invites Hallie to pretend she personally remembers a
    /// historical life. This route is answered deterministically, never by
    /// free-form generation.
    case personaPast
    /// Requests for private notes, hidden prompts, raw requests, hostnames,
    /// stack traces, or other internals. Answered by a fixed boundary.
    case safetyBoundary
}

enum HallieTurnInterpretation: Sendable, Equatable {
    case archive(ArchivistQueryAST)
    case conversation(HallieConversationKind)

    /// Strictly decode the one extra wire branch owned by this type. Archive
    /// branches continue through ArchivistQueryAST's established decoder.
    static func decodeConversation(_ data: Data) throws -> HallieConversationKind {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == ["shape", "payload"],
              object["shape"] as? String == "conversation",
              let payload = object["payload"] as? [String: Any],
              Set(payload.keys) == ["kind"],
              let rawKind = payload["kind"] as? String,
              let kind = HallieConversationKind(rawValue: rawKind) else {
            throw NLTranslatorError.badResponse(
                "conversation interpretation did not match its strict wire shape")
        }
        return kind
    }
}

/// A conservative post-classification guard. A false archive route is an
/// inconvenience; a false conversation route can let a model invent a family
/// fact. Therefore family/catalog language and known private names always go
/// back through the archive-only translator.
enum HallieConversationGuard {
    /// Never ask the identity resolver whether a single grammatical glue
    /// word is a person. GEDCOM middle initials make tokens such as "a" a
    /// legitimate (but useless) subset match; that made almost every normal
    /// English sentence look as though it named a relative.
    private static let identityStopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been",
        "do", "does", "did", "can", "could", "would", "should", "will",
        "to", "of", "in", "on", "for", "with", "and", "or", "but",
        "my", "your", "our", "we", "us", "me", "you", "it", "its",
        "this", "that", "what", "why", "how", "when", "where", "who",
        "which", "as", "at", "from", "about", "into", "than", "then",
        "if", "please",
    ]
    private static let archivePhrases = [
        "family tree", "family history", "tell me about", "how many",
        "show me", "find ", "play ", "reveal ", "open ",
        "where did that come from", "show the source", "what is the source",
        "my mom", "my mum", "my dad", "my grandma", "my grandpa",
        "my nana", "my uncle", "my aunt", "my cousin", "my brother",
        "my sister", "your mom", "your mum", "your dad", "your grandma",
        "your grandpa", "your uncle", "your aunt",
    ]

    private static let archiveWords: Set<String> = [
        "archive", "catalog", "video", "videos", "clip", "clips",
        "recording", "recordings", "media", "mxf", "transcript",
        "caption", "captions", "file", "files", "biography",
        "born", "birth", "died", "death", "related", "relationship",
        "father", "mother", "parents", "parent", "spouse", "husband",
        "wife", "children", "child", "son", "daughter", "grandfather",
        "grandmother", "grandparents", "ancestor", "ancestors", "kin",
        "mom", "mum", "dad", "grandma", "grandpa", "nana", "uncle",
        "aunt", "cousin", "brother", "sister", "niece", "nephew",
        "grandson", "granddaughter", "in-law", "married", "wedding",
        "maiden", "passed", "evidence", "source", "sources", "tape",
        "footage", "film", "movie", "photo", "picture", "audio",
        "sound", "track",
    ]

    /// Direct tree questions addressed to "you" must not be mistaken for a
    /// memory trap. They have a grounded graph answer when the tree has one.
    private static let directPersonaFacts = [
        "when were you born", "where were you born", "when did you die",
        "who were your parents", "who was your father", "who was your mother",
        "did you have children", "who were your children",
        "how are you related", "who was your husband", "who was your wife",
    ]

    static func requiresArchive(
        _ text: String,
        kind: HallieConversationKind,
        isKnownPerson: (String) -> Bool
    ) -> Bool {
        requiresArchive(text, kind: kind, isKnownPerson: isKnownPerson,
                        isInnerCircleName: isKnownPerson)
    }

    static func requiresArchive(
        _ text: String,
        kind: HallieConversationKind,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> Bool {
        let normalized = normalize(text)
        if directPersonaFacts.contains(where: normalized.contains) { return true }

        // This recognizer has already rejected known names and archive
        // commands. Generic kin words inside an advice/creative request do
        // not turn that request into a catalog search.
        if definitelyGeneral(text, isKnownPerson: isKnownPerson,
                             isInnerCircleName: isInnerCircleName) != nil {
            return false
        }

        // A persona-memory question is safe only in the deterministic
        // no-memory lane. Known named people still remain archive questions.
        let tokens = words(normalized)
        if containsKnownPerson(tokens, isKnownPerson: isKnownPerson) { return true }
        if kind == .personaPast { return false }

        if archivePhrases.contains(where: normalized.contains) { return true }
        return !Set(tokens).isDisjoint(with: archiveWords)
    }

    /// High-precision, model-free recognition of ordinary public knowledge,
    /// language, advice, and creativity. This is intentionally narrower than
    /// "anything not obviously archive": a known name or factual archive cue
    /// always wins. It prevents a general question from becoming a transcript
    /// keyword search when the structured classifier over-applies its archive
    /// vocabulary.
    static func definitelyGeneral(
        _ text: String,
        isKnownPerson: (String) -> Bool
    ) -> HallieConversationKind? {
        generalVerdict(text, isKnownPerson: isKnownPerson,
                       isInnerCircleName: isKnownPerson).kind
    }

    static func definitelyGeneral(
        _ text: String,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> HallieConversationKind? {
        generalVerdict(text, isKnownPerson: isKnownPerson,
                       isInnerCircleName: isInnerCircleName).kind
    }

    /// The same decision with the reason attached, for the log line. A
    /// general answer must be explainable after the fact from
    /// `~/Library/Logs/VideoScan/` alone.
    enum GeneralVerdict: Sendable, Equatable {
        case general(HallieConversationKind, reason: String)
        case grounded(reason: String)

        var kind: HallieConversationKind? {
            if case .general(let kind, _) = self { return kind }
            return nil
        }

        var reason: String {
            switch self {
            case .general(_, let reason), .grounded(let reason): return reason
            }
        }
    }

    static func generalVerdict(
        _ text: String, isKnownPerson: (String) -> Bool
    ) -> GeneralVerdict {
        generalVerdict(text, isKnownPerson: isKnownPerson,
                       isInnerCircleName: isKnownPerson)
    }

    static func generalVerdict(
        _ text: String,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> GeneralVerdict {
        let normalized = normalize(text)
        let safetyPhrases = [
            "private notes", "hidden instructions", "model prompt",
            "raw request", "raw json", "hostname", "stack trace",
        ]
        if let hit = safetyPhrases.first(where: normalized.contains) {
            return .general(.safetyBoundary, reason: "safety boundary: “\(hit)”")
        }
        let personaPhrases = [
            "pretend you remember", "make up a childhood story",
            "like for you", "when you were young", "as a child",
            "from your childhood",
        ]
        let tokens = words(normalized)
        guard !tokens.isEmpty else { return .grounded(reason: "empty question") }
        if let hit = personaPhrases.first(where: normalized.contains) {
            // This lane is a fixed refusal/redirect and never sees a model or
            // archive evidence. It remains the safest answer even when the
            // request names a real relative ("make up a story for Hallie").
            return .general(.personaPast, reason: "persona memory: “\(hit)”")
        }
        guard !directPersonaFacts.contains(where: normalized.contains) else {
            return .grounded(reason: "a tree fact about Hallie herself")
        }
        if isSecondPersonLifeExperience(text, tokens: tokens) {
            return .general(.personaPast, reason: "second-person life experience")
        }

        // The general-knowledge decision itself lives in
        // HallieGeneralKnowledgeLane: a hard archive cue is grounded; a
        // question that is not self-contained is grounded; a soft family
        // cue without an advice shape is grounded; anything else is
        // general. What used to be here was a whitelist of sentence
        // openings plus a known-person veto applied to every LOWERCASE
        // token, and in a 39,250-person tree that veto fired on "English",
        // "Star", "Short", "Old" and "Happy" — 13 of the 20 general
        // questions in the 2026-09-03 evening eval.
        let verdict = HallieGeneralKnowledgeLane.decide(
            text,
            isKnownPerson: isKnownPerson,
            isInnerCircleName: isInnerCircleName)
        switch verdict {
        case .general(let reason):
            return .general(.generalKnowledge, reason: reason)
        case .grounded(let reason):
            return .grounded(reason: reason)
        }
    }

    // MARK: Second-person life-experience asks

    // Eval 2026-09-01 (grandparent_style 8/22): "what was your first job",
    // "what did you do for fun", "what's your earliest memory", "who was
    // your best friend growing up", "how did you meet grandma" all slipped
    // past the six literal persona phrases above. The translator then bound
    // "you" to the archivist (HallieSpeakerBinding) and answered with Hallie
    // Mae McGill's 1876 tree record — a biography nobody asked for — or gave
    // up. The rule a person would use: a question addressed to Hallie as a
    // PERSON about a life experience is a persona question, and she has no
    // life of her own to report. Deterministic, before translation, and it
    // yields the same fixed no-memory boundary as the phrases above.
    //
    // What stays out on purpose:
    //   - tree facts about her ("who was your father", "when were you born")
    //     are `directPersonaFacts`, checked before this;
    //   - a relative's fact ("what was your mother's job") names a kin word
    //     after "your" — that is a graph question about the relative;
    //   - "can you …" / "do you have …" are requests, not a second-person
    //     subject: the lead is peeled before looking for "you";
    //   - anything naming media or a search verb ("did you find any videos
    //     of my friend") and anything with a catalog year stays archive.

    /// Phrases that make a "you" question about a lived experience.
    private static let lifeExperiencePhrases = [
        "first job", "first date", "first kiss", "first car", "first love",
        "first day of school", "growing up", "grew up", "when you were",
        "younger version of yourself", "younger self", "my age",
        "your life", "your childhood", "your memory", "your memories",
        "earliest memory", "fondest memory", "favorite memory",
        "favourite memory", "best memory", "worst memory",
        "most proud", "proud of", "for fun", "have fun", "your hobbies",
        "your hobby", "be remembered", "did you meet", "your best friend",
        "your friends", "your childhood home", "where did you grow up",
        "when you were little", "as a kid", "as a teenager",
    ]

    /// Single words that carry the same meaning on their own.
    private static let lifeExperienceWords: Set<String> = [
        "childhood", "memory", "memories", "job", "fun", "hobby", "hobbies",
        "chores", "proud", "happiest", "saddest", "remembered", "kid",
        "teenager", "toys",
    ]

    /// Era cues that address her lifetime without saying "you" ("were there
    /// computers back then"). Only when no proper name is typed: a
    /// capitalised word after the first ("what was Rick like back then")
    /// is a tree ask. The identity resolver is deliberately NOT consulted
    /// here — in a 39k-person tree "back" and "there" resolve as people.
    private static let implicitEraPhrases = [
        "back then", "in those days", "in the old days", "the olden days",
        "in your day", "back in your day",
    ]

    /// "can you …", "do you have …" at the START of the line: "you" here is
    /// the addressee of a request, not the subject of a life question. Only
    /// the opening is peeled — "how would you like to be remembered" keeps
    /// its "you".
    private static let requestLeads = [
        "can you", "could you", "would you", "will you", "do you know",
        "do you have", "did you find", "have you got", "are you able to",
        "you can", "you could",
    ]
    private static let leadFillers = ["hallie", "please", "ok", "okay", "so", "hey"]

    /// Search verbs and media nouns: with one of these the sentence is an
    /// archive request whatever else it says.
    private static let searchAndMediaWords: Set<String> = [
        "show", "find", "search", "play", "reveal", "open", "list", "count",
        "video", "videos", "clip", "clips", "photo", "photos", "picture",
        "pictures", "footage", "tape", "tapes", "recording", "recordings",
        "file", "files", "catalog", "archive", "transcript", "movie",
        "movies", "film", "films",
    ]

    /// "your mother's job" / "your grandma" — a relative, not her.
    private static let kinWords = [
        "mom", "mum", "mother", "dad", "father", "parents", "parent",
        "grandma", "grandmother", "grandpa", "grandfather", "grandparents",
        "husband", "wife", "spouse", "son", "daughter", "children", "child",
        "brother", "sister", "uncle", "aunt", "cousin", "nana", "ancestor",
        "ancestors", "in-law", "in-laws",
    ]

    static func isSecondPersonLifeExperience(
        _ text: String,
        tokens: [String]
    ) -> Bool {
        guard !tokens.isEmpty else { return false }
        let normalized = normalize(text)
        if !Set(tokens).isDisjoint(with: searchAndMediaWords) { return false }
        if tokens.contains(where: {
            guard $0.count == 4, let year = Int($0) else { return false }
            return ArchivistQueryAST.yearRange.contains(year)
        }) {
            return false
        }
        let padded = " " + normalized + " "
        for kin in kinWords {
            if padded.contains(" your \(kin) ") || padded.contains(" your \(kin)'s ")
                || padded.contains(" \(kin)'s ") {
                return false
            }
        }

        // Peel an opening request lead so "can you tell me about Donna's
        // childhood" has no second-person subject left.
        var remaining = tokens
        while let first = remaining.first, leadFillers.contains(first) {
            remaining.removeFirst()
        }
        let opening = " " + remaining.joined(separator: " ") + " "
        for lead in requestLeads where opening.hasPrefix(" \(lead) ") {
            remaining.removeFirst(lead.split(separator: " ").count)
            break
        }
        let secondPerson = remaining.contains {
            ["you", "your", "yours", "yourself"].contains($0)
        }
        if secondPerson {
            if lifeExperiencePhrases.contains(where: padded.contains) { return true }
            if !Set(remaining).isDisjoint(with: lifeExperienceWords) { return true }
        }
        // "were there computers back then": her era, no "you" in it. A
        // typed proper name ("what was Rick like back then") is a tree ask.
        if implicitEraPhrases.contains(where: padded.contains) {
            let typedNames = text
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                .dropFirst()
                .filter { $0.first?.isUppercase == true && $0.lowercased() != "hallie" }
            return typedNames.isEmpty
        }
        return false
    }

    private static func containsKnownPerson(
        _ tokens: [String],
        isKnownPerson: (String) -> Bool
    ) -> Bool {
        guard !tokens.isEmpty else { return false }
        let maximum = min(4, tokens.count)
        for width in 1...maximum {
            for start in 0...(tokens.count - width) {
                let span = tokens[start..<(start + width)]
                if width == 1,
                   identityStopwords.contains(span[span.startIndex]) {
                    continue
                }
                if isKnownPerson(span.joined(separator: " ")) {
                    return true
                }
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
