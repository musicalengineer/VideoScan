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
        let normalized = normalize(text)
        if directPersonaFacts.contains(where: normalized.contains) { return true }

        // This recognizer has already rejected known names and archive
        // commands. Generic kin words inside an advice/creative request do
        // not turn that request into a catalog search.
        if definitelyGeneral(text, isKnownPerson: isKnownPerson) != nil {
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
        let normalized = normalize(text)
        let safetyPhrases = [
            "private notes", "hidden instructions", "model prompt",
            "raw request", "raw json", "hostname", "stack trace",
        ]
        if safetyPhrases.contains(where: normalized.contains) {
            return .safetyBoundary
        }
        let personaPhrases = [
            "pretend you remember", "make up a childhood story",
            "like for you", "when you were young", "as a child",
            "from your childhood",
        ]
        let tokens = words(normalized)
        guard !tokens.isEmpty else { return nil }
        if personaPhrases.contains(where: normalized.contains) {
            // This lane is a fixed refusal/redirect and never sees a model or
            // archive evidence. It remains the safest answer even when the
            // request names a real relative ("make up a story for Hallie").
            return .personaPast
        }
        guard !directPersonaFacts.contains(where: normalized.contains) else {
            return nil
        }

        let archiveCommands = [
            "show ", "find ", "search ", "play ", "reveal ", "open ",
            "how many", "tell me about", "who was", "who is", "when was",
            "where was", "where did", "how are you related",
        ]
        guard !archiveCommands.contains(where: normalized.hasPrefix) else {
            return nil
        }
        // A year in Hallie's catalog range is a strong archive cue even in a
        // sentence shaped like a public-knowledge question ("Why did we move
        // to Westford in 1994?"). False archive is safer than invented family
        // context.
        if tokens.contains(where: {
            guard $0.count == 4, let year = Int($0) else { return false }
            return ArchivistQueryAST.yearRange.contains(year)
        }) {
            return nil
        }

        let factualLeads = [
            "why ", "what makes ", "what does ", "what is the difference ",
            "what's the difference ", "whats the difference ",
            "what is another word ", "what's another word ",
            "explain ", "define ",
        ]
        if factualLeads.contains(where: normalized.hasPrefix) {
            guard !containsKnownPerson(tokens, isKnownPerson: isKnownPerson) else {
                return nil
            }
            // Factual questions containing archive/tree vocabulary remain
            // grounded even when they happen to start with "why" or "what".
            return Set(tokens).isDisjoint(with: archiveWords)
                ? .generalKnowledge : nil
        }

        let creativeOrAdviceLeads = [
            "can you make ", "help me think of ", "what is a thoughtful way ",
            "what's a thoughtful way ", "how can i encourage ",
            "how can we encourage ", "suggest ", "tell me a short ",
            "write ", "give me a cheerful ", "give me a gentle ",
        ]
        guard creativeOrAdviceLeads.contains(where: normalized.hasPrefix),
              !containsKnownPerson(tokens, isKnownPerson: isKnownPerson) else {
            return nil
        }
        return .generalKnowledge
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
