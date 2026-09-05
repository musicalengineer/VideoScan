// HallieSelfReferenceQuestion.swift
// "Are you a real person or a program?" is a question about HALLIE — the
// assistant the family is talking to — not about Hallie Mae McGill, the
// 1876 great-grandmother she is named after.
//
// Live 2026-09-05, hours before the family demo, all three of these were
// answered with the ancestor's birth and death records:
//
//     Do you ever get tired?
//     Are you a real person or a program?
//     who made you
//     did you serve in the military
//
//     → "Hallie Mae McGill was born March 1876 in Louisville … and died
//        14 January 1908 …"  (route=graph operation=biography person=Hallie Mae)
//
// Nothing claimed them before translation, so the model turned "you" into a
// person reference, `HallieSpeakerBinding.bindPronouns` bound it to the
// archivist's configured name, the name ladder found "Hallie" in the GEDCOM,
// and the biography route did its job on the wrong Hallie.
//
// This file is the SIBLING of `HallieConversationGuard.isSecondPersonLifeExperience`,
// which already claims the REMINISCENCE shape ("what was your first job",
// "did you have TV growing up") and answers it with the fixed no-memory
// boundary. That predicate covers a lived past; this one covers the
// assistant's NATURE, STATE and ORIGIN, which it never looked for.
//
// It writes no new persona prose. It only says WHICH existing answer applies:
//
//   .noPersonalLife → HallieSocialConversation's personaPast boundary
//                     ("I don't have personal memories or a childhood of my
//                     own. If you mean Hallie Mae in the family tree …")
//   .introduction   → ArchivistConversationCommand.helpCard, the same answer
//                     "who are you" and "what are you" already get.
//
// THE VOCABULARY BELOW IS THE ONE PLACE. It is a stop-gap shape: a closed
// word list is not a theory of self-reference, and when the proposer-with-
// tools direction lands (docs, 2026-08-26) this should become a claim the
// model proposes and Swift verifies. Until then, add words here and nowhere
// else.
//
// (For Rick: a whitelist grammar, the same trick as
// `ArchivistConversationCommand.isWeatherAside`. The sentence is accepted
// only if EVERY token is explained by one of the sets below. Any unexplained
// token — a name, a year, a kin word, a media noun — rejects the line, which
// is what keeps "tell me about Hallie Mae McGill" and "how am I related to
// you?" out of here without a single special case. In C++ terms: a total
// parse over a fixed terminal alphabet, not a substring search.)

import Foundation

enum HallieSelfReferenceQuestion {

    /// Which existing answer a self-referential question should get. This
    /// type never carries prose; both cases name an answer that already
    /// exists elsewhere.
    enum Answer: Equatable, Sendable {
        /// Her nature, state or feelings — the existing personaPast
        /// boundary in `HallieSocialConversation`.
        case noPersonalLife
        /// Her name or who made her — the existing help card, which opens
        /// "Hi — I'm Hallie Mae, the family archivist."
        case introduction
    }

    /// The classification, or nil when the line is not about the assistant
    /// herself. Pure: text in, verdict out, no I/O and no identity lookup.
    ///
    /// Three conditions must all hold:
    ///   1. a bare second-person pronoun is present ("you", "your",
    ///      "yours", "yourself") — her NAME does not count, so "who was
    ///      Hallie Mae" and "tell me about Hallie Mae McGill" are never
    ///      claimed and keep returning the ancestor's biography;
    ///   2. at least one nature/state or origin cue is present;
    ///   3. every remaining token is ordinary glue. A person, a place, a
    ///      year, a kin word, a media noun or any other content word ends
    ///      the match — that is how "how am I related to you?" stays a
    ///      family-tree question ("related" is not glue).
    static func detect(_ text: String) -> Answer? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        // Her name is an address here ("who made you, Hallie?"), not a
        // subject. Removing it also means "are you Hallie Mae McGill" keeps
        // "mcgill" as an unexplained token and is not claimed.
        tokens.removeAll { $0 == "hallie" || $0 == "please" }
        guard tokens.count >= 2, tokens.count <= 14 else { return nil }

        // A year is always archive content ("were you around in 1908").
        guard !tokens.contains(where: { $0.count == 4 && Int($0) != nil }) else { return nil }

        guard tokens.contains(where: { secondPersonPronouns.contains($0) }) else { return nil }

        var nature = false
        var origin = false
        for token in tokens {
            if secondPersonPronouns.contains(token) { continue }
            if natureCues.contains(token) { nature = true; continue }
            if originCues.contains(token) { origin = true; continue }
            guard glue.contains(token) else { return nil }
        }
        if nature { return .noPersonalLife }
        return origin ? .introduction : nil
    }

    // MARK: - The vocabulary (the one place)

    /// Only the PRONOUNS. Her name is deliberately absent: an explicit name
    /// means the ancestor, a pronoun means the assistant. That distinction
    /// is the whole point of this file.
    static let secondPersonPronouns: Set<String> = [
        "you", "your", "yours", "yourself",
    ]

    /// What she IS, what she FEELS, what her body would do — the questions
    /// the existing no-memory boundary answers well. Vital-record words
    /// ("born", "died", "married") are deliberately absent: "when were you
    /// born" is a real family-tree question about her namesake and is
    /// already handled by `HallieConversationGuard.directPersonaFacts`.
    static let natureCues: Set<String> = [
        // person or machine
        "real", "person", "people", "human", "humans", "woman",
        "lady", "girl", "man", "flesh", "body", "physical", "alive", "living",
        "live", "lives", "exist", "exists", "existed", "sentient", "conscious",
        "consciousness", "soul", "spirit", "ghost", "imaginary", "fictional",
        "fiction", "pretend", "pretending", "character", "actress", "actor",
        "avatar", "puppet",
        "program", "programme", "programs", "computer", "computers",
        "software", "app", "application", "robot", "robots", "bot", "chatbot",
        "machine", "machines", "algorithm", "algorithms", "ai", "artificial",
        "intelligence", "llm", "chatgpt", "simulation", "simulated", "virtual",
        "digital", "automated", "automatic",
        // state and feeling
        "tired", "tire", "tires", "tiring", "exhausted", "sleep", "sleeps",
        "sleeping", "asleep", "awake", "rest", "rests", "resting", "eat",
        "eats", "eating", "hungry", "thirsty", "drink", "bored", "boring",
        "lonely", "afraid", "scared", "hurt", "pain",
        "sick", "ill", "breathe", "breathing", "dream", "dreams", "dreaming",
        "feel", "feels", "feeling", "feelings", "emotion", "emotions",
        "emotional", "mood", "moods",
        "age", "aged", "old", "young", "birthday",
        // a life a person would have had
        "serve", "served", "serving", "service", "military", "army", "navy",
        "marines", "marine", "veteran", "war", "enlist", "enlisted", "draft",
        "drafted", "vote", "voted", "drive", "drove", "work", "worked",
    ]

    /// Where she CAME FROM and what she is CALLED — the questions the help
    /// card's opening line answers ("Hi — I'm Hallie Mae, the family
    /// archivist …").
    static let originCues: Set<String> = [
        "made", "make", "makes", "making", "built", "build", "builds",
        "created", "create", "creates", "creator", "wrote", "write", "writes",
        "written", "programmed", "designed", "design", "designer", "developed",
        "develop", "developer", "invented", "invent", "inventor", "coded",
        "coder", "author", "behind", "origin", "origins", "name", "named",
        "call", "called", "nickname",
    ]

    /// Everyday connective tissue. Anything NOT listed here and not a cue
    /// rejects the line — including every proper name, kin word, media noun
    /// and search verb, none of which need their own blocklist.
    static let glue: Set<String> = [
        "who", "who's", "whos", "whom", "what", "whats", "what's", "when", "where", "why",
        "how", "which",
        "are", "aren't", "arent", "is", "isn't", "isnt", "was", "wasn't",
        "wasnt", "were", "weren't", "werent", "be", "been", "being", "am",
        "do", "don't", "dont", "does", "doesn't", "doesnt", "did", "didn't",
        "didnt", "can", "can't", "cant", "could", "couldn't", "couldnt",
        "would", "wouldn't", "will", "won't", "wont", "shall", "should",
        "have", "haven't", "havent", "has", "hasn't", "hasnt", "had", "get",
        "gets", "getting", "got", "go", "goes", "going",
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with",
        "without", "from", "by", "or", "and", "but", "not", "no", "yes",
        "so", "too", "any", "some", "all", "both", "either", "else",
        "i", "i'm", "im", "me", "my", "mine", "we", "us", "our", "it", "it's",
        "its", "this", "that", "there", "here", "these", "those", "one",
        "ones", "thing", "things", "kind", "kinds", "sort", "sorts", "type",
        "like", "as", "than", "then", "if", "just", "even", "still", "yet",
        "ever", "never", "always", "sometimes", "often", "actually", "about",
        "out", "up", "down", "over", "much", "many", "more", "most", "long",
        "time", "times", "now", "today", "tonight", "anymore", "very", "quite",
        "sure", "ok", "okay", "oh", "well", "hey", "say", "tell", "know",
    ]
}
