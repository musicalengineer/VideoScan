// HallieTellingMode.swift
// "Let me tell you about Dad Breen, Rick's dad…" → "Oh, tell me all about
// him — I'll remember it." (Rick, 2026-08-21.)
//
// The conversation Hallie can have that no search can: a family member
// TELLS her about someone, she listens, asks the next natural question, and
// what she is told becomes attributed, recorded-but-unverified passages in
// the family's knowledge file (CyberBrainWriter). Later, "tell me about Dad
// Breen" answers from those passages and says where they came from.
//
// Pure and client-agnostic, like HallieClarificationPolicy: text in,
// decisions and wording out. No I/O, no model. The shell and the chat
// window both drive it, so the interview cannot drift between them. The
// questions are a fixed bank in StoryCorps order (origins → family → work →
// service → character → stories); she asks about what has not been covered,
// never invents, never paraphrases what she was told.

import Foundation

enum HallieTellingMode {

    // MARK: - Types

    enum Pronoun: Equatable, Sendable {
        case he, she, they

        var subject: String {
            switch self {
            case .he: return "he"
            case .she: return "she"
            case .they: return "they"
            }
        }
        var object: String {
            switch self {
            case .he: return "him"
            case .she: return "her"
            case .they: return "them"
            }
        }
        var possessive: String {
            switch self {
            case .he: return "his"
            case .she: return "her"
            case .they: return "their"
            }
        }
    }

    /// The detected "let me tell you about …" turn.
    struct Opening: Equatable, Sendable {
        /// The person as named ("Dad Breen"), or nil when only a relation
        /// was given ("my dad") and the name must be asked for.
        let subject: String?
        /// "Rick's dad" / "my dad" — kept as an alias so the relation is
        /// searchable later.
        let relation: String?
        let pronoun: Pronoun
        /// Content that arrived in the same breath as the opener
        /// ("Let me tell you about Dad Breen. He fixed typewriters.").
        let firstStatement: String?
    }

    /// Live state while Hallie is listening. Owned by the client's session
    /// (shell Session / chat window), advanced only through this enum.
    struct Session: Equatable, Sendable {
        var subject: String?
        var relation: String?
        var pronoun: Pronoun
        /// Everything told so far, in order, verbatim.
        var passages: [String] = []
        /// Statements told BEFORE a name was given; persisted once it is.
        var pendingPassages: [String] = []
        var askedTopics: [Topic] = []
        /// How many passages the client has durably recorded.
        var persistedCount = 0

        var awaitingName: Bool { subject == nil }
        var displayName: String { subject ?? relation ?? "them" }

        init(opening: Opening) {
            self.subject = opening.subject
            self.relation = opening.relation
            self.pronoun = opening.pronoun
        }
    }

    /// What a turn means while Hallie is listening.
    enum TurnKind: Equatable, Sendable {
        /// Something about the person — keep it.
        case statement(String)
        /// "that's all" / "thanks" / "start over" — close and keep.
        case finish
        /// A question or request for Hallie — close quietly and answer it.
        case question
        /// The name, when she had asked for one.
        case name(String)
        /// "let me tell you about Mom" mid-stream — close this, open that.
        case switchSubject(Opening)
    }

    /// StoryCorps-style question bank, in the order a relative would ask.
    enum Topic: String, CaseIterable, Equatable, Sendable {
        case origins, family, marriage, children, work, home, service
        case character, passions, story, looks, legacy

        fileprivate var keywords: [String] {
            switch self {
            case .origins: ["born", "birth", "grew up", "raised", "hometown", "childhood", "as a boy", "as a girl", "as a kid"]
            case .family: ["mother", "father", "parents", "brother", "sister", "sibling", "son of", "daughter of", "his mom", "her mom", "his dad", "her dad"]
            case .marriage: ["married", "wife", "husband", "wedding", "they met", "sweetheart"]
            case .children: ["children", "kids", "sons", "daughters", "his son", "her son", "his daughter", "her daughter", "father of", "mother of"]
            case .work: ["work", "job", "career", "repair", "business", "company", "retired", "factory", "for a living", "profession", "shop", "office", "taught", "teacher", "nurse"]
            case .home: ["lived", "moved", "house", "home", "street", "apartment", "neighborhood", "town of"]
            case .service: ["served", "marine", "army", "navy", "air force", "coast guard", "the war", "veteran", "enlisted", "drafted", "military", "stationed"]
            case .character: ["kind", "funny", "stubborn", "quiet", "gentle", "temper", "generous", "patient", "proud", "strict", "warm", "personality", "sense of humor"]
            case .passions: ["loved to", "hobby", "hobbies", "enjoyed", "passion", "music", "fishing", "garden", "played", "favorite", "collected"]
            case .story: ["once", "one time", "story", "remember when", "that time", "used to"]
            case .looks: ["tall", "short", "hair", "eyes", "looked like", "glasses", "beard", "mustache", "handsome", "beautiful", "build"]
            case .legacy: ["remembered", "legacy", "passed away", "died", "funeral", "buried", "miss"]
            }
        }

        fileprivate func question(_ p: Pronoun) -> String {
            let was = p == .they ? "were" : "was"
            return switch self {
            case .origins: "Where and when \(was) \(p.subject) born?"
            case .family: "Who were \(p.possessive) parents — and did \(p.subject) have brothers or sisters?"
            case .marriage: "Who did \(p.subject) marry, and how did they meet?"
            case .children: "Did \(p.subject) have children?"
            case .work: "What did \(p.subject) do for work?"
            case .home: "Where did \(p.subject) live?"
            case .service: "Did \(p.subject) serve in the military?"
            case .character: "What \(was) \(p.subject) like — what did people love about \(p.object)?"
            case .passions: "What did \(p.subject) love to do?"
            case .story: "Is there a story about \(p.object) the family still tells?"
            case .looks: "What did \(p.subject) look like?"
            case .legacy: "How would \(p.subject) want to be remembered?"
            }
        }
    }

    // MARK: - Detecting the opener

    /// Whole-turn forms only. "tell me about X" (a question to Hallie) never
    /// matches — every opener is the speaker offering to tell HER.
    static func detectOpening(_ text: String) -> Opening? {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return nil }
        var tail: String?
        for pattern in openerPatterns {
            if let range = cleaned.range(of: pattern, options: [.regularExpression, .anchored]) {
                tail = String(cleaned[range.upperBound...])
                break
            }
        }
        guard var rest = tail?.trimmingCharacters(in: .whitespaces), !rest.isEmpty else {
            return nil
        }

        // Split off content that followed the opener in the same turn:
        // "…about Dad Breen. He fixed typewriters." / "…about Dad Breen: he…"
        var firstStatement: String?
        if let cut = rest.range(of: #"[.:;!]\s+|\s+[-–—]\s+"#, options: .regularExpression) {
            let after = rest[cut.upperBound...].trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<cut.lowerBound])
            if !after.isEmpty { firstStatement = originalCase(after, in: text) }
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?\"'"))
        guard !rest.isEmpty else { return nil }

        // "Dad Breen, Rick's dad" / "Dad Breen (Rick's dad)" → name + relation.
        var namePart = rest
        var relation: String?
        if let paren = rest.range(of: #"\s*\((.+)\)\s*$"#, options: .regularExpression) {
            relation = String(rest[paren]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            namePart = String(rest[..<paren.lowerBound])
        } else if let comma = rest.range(of: ",") {
            relation = rest[comma.upperBound...].trimmingCharacters(in: .whitespaces)
            namePart = String(rest[..<comma.lowerBound])
        }
        namePart = namePart.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?\"'"))
        if let relation, relation.isEmpty { return nil }

        // Kinship word → pronoun; "my dad" with no name → ask for it.
        let nameWords = namePart.split(separator: " ").map(String.init)
        let pronoun = kinshipPronoun(in: nameWords)
            ?? relation.flatMap { kinshipPronoun(in: $0.split(separator: " ").map(String.init)) }
            ?? .they
        let possessiveLead = ["my", "our", "your"].contains(nameWords.first ?? "")
        let kinshipOnly = possessiveLead
            && nameWords.count >= 2
            && nameWords.dropFirst().allSatisfy { kinshipWords[$0] != nil || ["own", "late", "dear"].contains($0) }
        if kinshipOnly {
            // "my dad", "our grandmother" — a relation, not a name.
            return Opening(subject: nil,
                           relation: originalCase(namePart, in: text),
                           pronoun: pronoun,
                           firstStatement: firstStatement)
        }
        var subject = originalCase(namePart, in: text)
        var relationOut = relation.map { originalCase($0, in: text) }
        if possessiveLead, nameWords.count >= 3, kinshipWords[nameWords[1]] != nil {
            // "my uncle Bob" → subject "Uncle Bob", relation "my uncle".
            subject = originalCase(nameWords.dropFirst().joined(separator: " "), in: text)
            relationOut = relationOut ?? originalCase(nameWords.prefix(2).joined(separator: " "), in: text)
        }
        guard !subject.isEmpty, subject.count <= 60 else { return nil }
        return Opening(subject: subject, relation: relationOut,
                       pronoun: pronoun, firstStatement: firstStatement)
    }

    // MARK: - Classifying a turn while listening

    static func classify(_ text: String, session: Session) -> TurnKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .finish }
        if let opening = detectOpening(trimmed) {
            // "I'll tell you about his temper" is more about the SAME
            // person, not a new one; only a named or kin-related person
            // switches the subject.
            let lead = (opening.subject ?? opening.relation ?? "").lowercased()
            let aboutSamePerson = ["his ", "her ", "their ", "that ", "the ", "it "]
                .contains { lead.hasPrefix($0) }
            let sameName = opening.subject.map {
                FamilyIdentityText.normalized($0) == FamilyIdentityText.normalized(session.displayName)
            } ?? false
            if !aboutSamePerson && !sameName { return .switchSubject(opening) }
        }

        let cleaned = normalize(trimmed)
        if isFinish(cleaned) { return .finish }
        if let command = ArchivistConversationCommand.detect(trimmed) {
            switch command {
            case .reset: return .finish
            case .help: return .question
            case .smalltalk(let kind):
                switch kind {
                case .thanks, .farewell, .affirmation: return .finish
                default: return .question
                }
            }
        }
        if looksLikeQuestion(cleaned) { return .question }

        if session.awaitingName {
            if let name = nameReply(trimmed) { return .name(name) }
        }
        return .statement(trimmed)
    }

    // MARK: - Wording

    /// Hallie's reply to the opener. `alreadyKnown`: the person already has
    /// passages, so she frames this as adding to them.
    static func openingReply(_ session: inout Session, alreadyKnown: Bool) -> String {
        let p = session.pronoun
        if session.awaitingName {
            let who = session.relation ?? "them"
            return "Oh, please do — I'd love to hear about \(who). What was \(p.possessive) name?"
        }
        let name = session.displayName
        let lead = alreadyKnown
            ? "Oh, tell me more about \(name) — I'll add it to what I already have."
            : "Oh, tell me all about \(name) — I'll remember it."
        if let question = askNext(&session) {
            return lead + " " + question
        }
        return lead
    }

    /// After a statement has been kept: a short, varied acknowledgement and
    /// the next uncovered question. Mutates `askedTopics`.
    static func acknowledgement(_ session: inout Session) -> String {
        let p = session.pronoun
        let count = session.passages.count
        let thanks = [
            "I've written that down.",
            "Noted — thank you.",
            "That's a lovely detail; I have it.",
            "Got it.",
            "I'll remember that.",
            "Thank you — that's part of \(p.possessive) story now.",
        ]
        let ack = thanks[max(0, count - 1) % thanks.count]
        if let topic = nextTopic(session) {
            session.askedTopics.append(topic)
            return ack + " " + topic.question(p)
        }
        return ack + " Anything else you'd like me to keep about \(p.object)? Say \"that's all\" when you're done."
    }

    /// She asked for a name and got one.
    static func namedReply(_ session: inout Session) -> String {
        let name = session.displayName
        var text = "Thank you — \(name). Tell me all about \(session.pronoun.object) and I'll remember it."
        if let question = askNext(&session) { text += " " + question }
        return text
    }

    /// She asked for a name and got something else: keep it, ask once more.
    static func stillNeedNameReply(_ session: Session) -> String {
        "I'll keep that. Before I write it down properly — what was \(session.pronoun.possessive) name?"
    }

    /// Closing. `persisted` is false when the client could not write (the
    /// read-only shell) so she says so instead of pretending.
    static func closingReply(_ session: Session, persisted: Bool, speaker: String?) -> String {
        let p = session.pronoun
        let name = session.displayName
        let n = session.passages.count
        guard n > 0 else {
            return "All right. Whenever you'd like to tell me about \(name), I'm here."
        }
        let things = n == 1 ? "one thing" : "\(n) things"
        if session.awaitingName {
            return "I didn't catch \(p.possessive) name, so I've kept \(things) you told me for this conversation only. Tell me \(p.possessive) name next time and I'll write it down properly."
        }
        let who = speaker.map { "told by \($0)" } ?? "told by you"
        if persisted {
            return "Thank you. I've kept \(things) you told me about \(name) — marked as \(who) today, to be verified. Ask me about \(p.object) any time."
        }
        return "Thank you. I've kept \(things) about \(name) for this session only — this shell is read-only. In the app, or with --remember, I'll keep it for good."
    }

    /// The quiet hand-off when the speaker asks something else mid-stream.
    static func settingAsideReply(_ session: Session) -> String {
        let n = session.passages.count
        guard n > 0 else { return "" }
        return "I'll keep what you told me about \(session.displayName). "
    }

    static func nextQuestion(_ session: Session) -> String? {
        nextTopic(session)?.question(session.pronoun)
    }

    /// The next uncovered question, recorded as asked so it is never
    /// repeated.
    private static func askNext(_ session: inout Session) -> String? {
        guard let topic = nextTopic(session) else { return nil }
        session.askedTopics.append(topic)
        return topic.question(session.pronoun)
    }

    // MARK: - Helpers

    private static func nextTopic(_ session: Session) -> Topic? {
        let corpus = (session.passages + session.pendingPassages)
            .joined(separator: " ").lowercased()
        return Topic.allCases.first { topic in
            !session.askedTopics.contains(topic)
                && !topic.keywords.contains { corpus.contains($0) }
        }
    }

    private static let openerPatterns: [String] = [
        // "let me tell you about", "can I tell you about", "I want to tell you a bit about"
        #"^(?:hallie[,]?\s+)?(?:please\s+)?(?:let me|lemme|can i|could i|may i|i want to|i wanna|i'd like to|i would like to|i need to|i'm going to|i am going to|i'll|i will|i have to|i've got to|let me just|i should) (?:just )?tell you (?:something |a bit |a little |a little bit |more |a story |some things |a few things |all )?about "#,
        #"^(?:hallie[,]?\s+)?(?:here's|here is) (?:something|a story|what i know|what i remember|a few things|some things) about "#,
        #"^(?:hallie[,]?\s+)?(?:i have|i've got|i got) (?:a story|some stories|something|some things|a few things|a memory|some memories|memories) (?:to tell you |to share |i want to share |i'd like to share )?about "#,
        #"^(?:hallie[,]?\s+)?(?:remember this|write this down|make a note|take a note|note this|take this down|write this) about "#,
        #"^(?:hallie[,]?\s+)?(?:let me|i want to|i'd like to) tell you (?:who|what) (?:\w+ )?(?:was|is) like[,:]? "#,
    ]

    private static let kinshipWords: [String: Pronoun] = [
        "dad": .he, "father": .he, "daddy": .he, "papa": .he, "pop": .he, "pa": .he,
        "grandfather": .he, "grandpa": .he, "granddad": .he, "grampa": .he, "pepe": .he, "pépé": .he,
        "uncle": .he, "brother": .he, "son": .he, "husband": .he, "nephew": .he, "grandson": .he,
        "stepfather": .he, "stepdad": .he, "godfather": .he,
        "mom": .she, "mother": .she, "mommy": .she, "mama": .she, "ma": .she, "mum": .she,
        "grandmother": .she, "grandma": .she, "nana": .she, "gram": .she, "grammy": .she, "meme": .she, "mémé": .she,
        "aunt": .she, "auntie": .she, "sister": .she, "daughter": .she, "wife": .she, "niece": .she, "granddaughter": .she,
        "stepmother": .she, "stepmom": .she, "godmother": .she,
        "cousin": .they, "parent": .they, "grandparent": .they, "child": .they, "friend": .they, "neighbor": .they,
        "great": .they, "in": .they, "law": .they,
    ]

    private static func kinshipPronoun(in words: [String]) -> Pronoun? {
        for word in words {
            let key = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,'’"))
            if let pronoun = kinshipWords[key], pronoun != .they { return pronoun }
        }
        return words.contains { kinshipWords[$0.lowercased()] == .they } ? .they : nil
    }

    private static let finishPhrases: Set<String> = [
        "that's all", "thats all", "that is all", "that's it", "thats it", "that is it",
        "that's everything", "thats everything", "that's all for now", "thats all for now",
        "that's it for now", "thats it for now", "that's all i have", "thats all i have",
        "that's all i remember", "thats all i remember", "that's all i know", "thats all i know",
        "that's about it", "thats about it", "that's enough", "thats enough", "that's enough for now",
        "i'm done", "im done", "i am done", "done", "all done", "we're done", "were done",
        "nothing else", "nothing more", "no more", "not right now", "not now", "no thanks",
        "no thank you", "end", "stop", "finished", "i'm finished", "im finished",
        "i think that's it", "i think thats it", "i think that's all", "i think thats all",
        "that will do", "that'll do", "thatll do", "enough for now", "later", "maybe later",
        "no", "nope", "nah", "not really", "that's plenty", "thats plenty",
        "thanks that's all", "thank you that's all", "thanks thats all",
    ]

    private static func isFinish(_ cleaned: String) -> Bool {
        var words = cleaned.split(separator: " ").map(String.init)
        while let first = words.first, ["ok", "okay", "well", "oh", "hallie", "yeah", "yes", "alright", "so", "and", "um", "i", "think", "guess", "suppose"].contains(first) {
            words.removeFirst()
        }
        let phrase = words.joined(separator: " ")
        if finishPhrases.contains(phrase) { return true }
        // "ok I think that's all for today" — the closer is the last clause.
        for closer in ["that's all", "thats all", "that's it", "thats it", "i'm done", "im done", "that's everything", "nothing else"] {
            if phrase.hasPrefix(closer + " ") && words.count <= 8 { return true }
        }
        return false
    }

    private static let questionLeads: [String] = [
        "who ", "what ", "when ", "where ", "why ", "how ", "which ", "whose ",
        "show ", "play ", "find ", "search ", "list ", "count ", "open ", "reveal ",
        "tell me", "do you ", "does ", "did you ", "can you ", "could you ", "would you ",
        "will you ", "are you ", "is there ", "are there ", "have you ", "has ", "should i ",
        "help", "give me ", "get me ", "bring up ", "pull up ", "look up ", "look for ",
    ]

    private static func looksLikeQuestion(_ cleaned: String) -> Bool {
        if cleaned.hasSuffix("?") { return true }
        return questionLeads.contains { cleaned.hasPrefix($0) }
    }

    /// A name reply: one to four capitalised-ish words, no verb-y content.
    /// "Richard Breen" / "Dad Breen" / "his name was Richard" / "Richard."
    private static func nameReply(_ text: String) -> String? {
        var candidate = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!,"))
        let lowered = candidate.lowercased()
        for lead in ["his name was ", "her name was ", "their name was ", "his name is ",
                     "her name is ", "their name is ", "it was ", "it's ", "that's ",
                     "name was ", "name is ", "he was ", "she was ", "he's ", "she's ",
                     "everyone called him ", "everyone called her ", "we called him ",
                     "we called her ", "we called them ", "people called him ", "people called her "] {
            if lowered.hasPrefix(lead) {
                candidate = String(candidate.dropFirst(lead.count))
                break
            }
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " .!,\"'"))
        let words = candidate.split(separator: " ")
        guard (1...4).contains(words.count), candidate.count <= 40 else { return nil }
        // A sentence with a verb in it is a statement, not a name.
        let verbs: Set<String> = ["was", "is", "were", "had", "has", "did", "born", "lived", "worked", "loved", "died"]
        guard !words.contains(where: { verbs.contains($0.lowercased()) }) else { return nil }
        return candidate
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Recover the speaker's own capitalisation for a lowercased fragment
    /// ("dad breen" → "Dad Breen") by locating it in the original text;
    /// falls back to capitalising each word.
    private static func originalCase(_ fragment: String, in original: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        if let range = original.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            return String(original[range]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
