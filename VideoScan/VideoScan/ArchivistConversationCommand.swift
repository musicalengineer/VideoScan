// ArchivistConversationCommand.swift
// Deterministic, model-free handling of the three things family members type
// that are not questions at all (Rick 2026-08-17, "family members will use
// this"): asking for help ("help", "?", "what can you do"), small talk
// ("thanks", "hi", "good morning"), and clearing the conversation ("start
// over", "forget that"). Each is answered locally — never declined, never sent
// to the translator. Pure: text in, classification out; no I/O.

import Foundation

enum ArchivistConversationCommand: Equatable, Sendable {
    /// Show the help card — the whole card, or one topic's section
    /// ("help with pronunciation", Rick 2026-08-29 17:50).
    case help(topic: HelpTopic? = nil)
    /// A one-line friendly reply.
    case smalltalk(Smalltalk)
    /// Clear conversation memory.
    case reset

    enum Smalltalk: Equatable, Sendable {
        case greeting
        case wellbeing
        case userDoingWell
        case userHavingHardTime
        case companionship
        case userWelcome
        case understanding
        case date
        case time
        case timeOfDay
        case thanks
        case farewell
        case affirmation
        /// "sorry, I meant something else" / "my apologies, I keep typing
        /// the wrong name" — no search, no fuss.
        case apology
        /// "hold on a sec" / "one moment please" — wait, say so.
        case holdOn
    }

    /// A topic the help card can be scoped to. Deterministic: "help with
    /// <topic>" never reaches the social-lane model.
    enum HelpTopic: Equatable, Sendable, CaseIterable {
        /// Pronunciation: teaching names, the drill, asking how one is said.
        case names
        /// Kinship questions.
        case relationships
        /// Family-tree navigation.
        case tree
        /// Research findings.
        case research
    }

    // MARK: - Detection

    /// "help with pronunciation" / "help me with names" / "pronunciation
    /// help" / "how do i teach you names" → the topic; "help with X" for
    /// an unknown X → `.help(topic: nil)` (the whole card). Nil when the
    /// words are not a help request at all ("help me find donna" is a
    /// search, untouched).
    static func detectHelpTopic(words: [String]) -> ArchivistConversationCommand? {
        guard words.count >= 2, words.count <= 8 else { return nil }
        var topicWords: [String]?
        if words[0] == "help" {
            var rest = Array(words.dropFirst())
            if rest.first == "me" || rest.first == "us" { rest.removeFirst() }
            if let first = rest.first, ["with", "on", "for", "about", "regarding"].contains(first) {
                topicWords = Array(rest.dropFirst())
            } else if rest.count == 1, helpTopic(for: rest) != nil {
                topicWords = rest   // "help pronunciation"
            }
        } else if words.last == "help", words.count <= 3 {
            topicWords = Array(words.dropLast())   // "pronunciation help"
        } else {
            // "how do i teach you names" — every remaining word must be from
            // the closed how-to vocabulary, so "how do you pronounce Latta"
            // (a pronunciation question about a name) is never help.
            for lead in howToLeads where words.joined(separator: " ").hasPrefix(lead + " ") {
                let rest = Array(words.dropFirst(lead.split(separator: " ").count))
                guard rest.allSatisfy({ howToTopicVocabulary.contains($0) }) else { continue }
                if let topic = helpTopic(for: rest) { return .help(topic: topic) }
            }
        }
        guard let topicWords else { return nil }
        guard !topicWords.isEmpty else { return .help() }
        return .help(topic: helpTopic(for: topicWords))
    }

    /// The topic named by a few words, nil for none of ours.
    static func helpTopic(for words: [String]) -> HelpTopic? {
        let text = words.joined(separator: " ")
        if words.contains(where: { $0.hasPrefix("pronunc") || $0.hasPrefix("pronounc") || $0.hasPrefix("prounounc") })
            || words.contains("names") || words.contains("name") || text.contains("saying names") || text.contains("say names")
            || text.contains("teach you") || text.contains("practice") || text.contains("practise") {
            return .names
        }
        if words.contains(where: { $0.hasPrefix("relat") || $0 == "kinship" || $0 == "kin" || $0 == "cousins" }) {
            return .relationships
        }
        if words.contains("tree") || words.contains("center") || words.contains("centre") || words.contains("navigate") {
            return .tree
        }
        if words.contains(where: { $0.hasPrefix("research") }) { return .research }
        return nil
    }

    /// Whole-message forms only. Anything with real content beyond these
    /// phrases ("thanks, now show me rick") is not a command and falls
    /// through to the ordinary pipeline.
    static func detect(_ text: String) -> ArchivistConversationCommand? {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return nil }
        // "?" / "??" alone is a request for help.
        if lowered.allSatisfy({ "?!.".contains($0) }) { return .help() }

        // Strip trailing punctuation, then a leading/trailing "hallie" and
        // politeness so "thanks hallie!" and "hallie, help" both classify.
        var words = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        let addressedOnly = !words.isEmpty && words.allSatisfy { addressWords.contains($0) }
        // Hallie's name and "please" may naturally appear at either edge.
        // Conversational fillers are leading words only: removing every
        // occurrence turned "I'm doing well, thanks" into "I'm doing thanks".
        words.removeAll { $0 == "hallie" || $0 == "please" }
        while let first = words.first,
              leadingAddressWords.contains(first) {
            words.removeFirst()
        }
        guard !words.isEmpty else {
            // "hey hallie" / "hallie?" is a greeting; "ok" / "please" alone is
            // nothing (the follow-up resolver says so honestly).
            let greeting = addressedOnly
                && (lowered.contains("hallie") || lowered.hasPrefix("hey"))
            return greeting ? .smalltalk(.greeting) : nil
        }
        let phrase = words.joined(separator: " ")

        if helpPhrases.contains(phrase) { return .help() }
        if resetPhrases.contains(phrase) { return .reset }
        if let scoped = detectHelpTopic(words: words) { return scoped }
        if let smalltalk = smalltalkPhrases[phrase] { return .smalltalk(smalltalk) }

        // Family members naturally combine a salutation and a social
        // question: "Hi Hallie, how are you today?" Hallie's name has
        // already been stripped above, leaving "hi how are you today".
        // Peel only a known leading salutation, then require that the rest
        // is itself an exact small-talk phrase. This keeps "hello Donna"
        // and actual catalog questions on the ordinary query path.
        if let first = words.first, leadingSalutations.contains(first) {
            let remainder = words.dropFirst().joined(separator: " ")
            if let smalltalk = smalltalkPhrases[remainder] {
                return .smalltalk(smalltalk)
            }
        }

        // Live 8/25: "How hallie, how are you?" — a mistyped salutation
        // ("How" for "Hi") addressed to Hallie BY NAME, followed by an exact
        // small-talk clause — answered as her 1876 namesake's biography.
        // When the person names Hallie and one comma-separated clause is
        // exactly a small-talk phrase, the leftover may be at most one
        // stray word: that is a greeting, not a family question. "Donna,
        // how are you?" (no Hallie) and "Hallie, how old is Donna?" (not a
        // small-talk clause) are untouched.
        if lowered.contains("hallie") {
            let clauses = lowered
                .split(whereSeparator: { ",;.!?".contains($0) })
                .map { clause -> [String] in
                    clause.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                        .map(String.init)
                        .filter { $0 != "hallie" && $0 != "please" }
                }
            let hits = clauses.compactMap { smalltalkPhrases[$0.joined(separator: " ")] }
            let leftovers = clauses.filter { smalltalkPhrases[$0.joined(separator: " ")] == nil }
            if let smalltalk = hits.first,
               leftovers.allSatisfy({ $0.count <= 1 }) {
                return .smalltalk(smalltalk)
            }
        }

        // Thanks / apology / hold-on / goodbye in their everyday shapes,
        // which no phrase table can enumerate.
        if let social = detectSocialLine(words: words, raw: lowered) {
            return .smalltalk(social)
        }

        // "how do i …" / "how can we …" is a how-to question about Hallie
        // herself; the help card answers it with worked examples. Capability
        // questions ("how do i change donna's bio") are classified BEFORE
        // this by ArchivistCapabilityQuestion, so only genuine how-to reaches
        // here.
        for lead in howToLeads where phrase == lead || phrase.hasPrefix(lead + " ") {
            if phrase == lead || words.allSatisfy({ helpVocabulary.contains($0) }) {
                return .help()
            }
        }
        // "what can you do", "what can i ask you about", "what do you know
        // how to do", "what kinds of things can i ask" — any what-can/what-do
        // sentence about "you"/"i ask" with no family content is help.
        // Every word must be from the closed help vocabulary, so "what do
        // you know about donna" (a biography question) never lands here.
        if words.first == "what", words.count <= 10,
           words.contains(where: { ["can", "could", "do", "should"].contains($0) }),
           words.contains(where: { ["you", "ask", "hallie"].contains($0) }),
           words.allSatisfy({ helpVocabulary.contains($0) }) {
            return .help()
        }
        return nil
    }

    // MARK: - Social lines by shape

    // Eval 2026-09-01 (smalltalk 8 misses): "Thanks, that's really
    // helpful.", "I appreciate you.", "Sorry, I meant something else.",
    // "My apologies, I keep typing the wrong name.", "hold on a sec",
    // "one moment please", "ok gotta run, talk later", "Have a good night."
    // each went to the translator, came back as a presence search with no
    // subject, and were declined with "I need something to look for". The
    // exact-phrase table above cannot enumerate everyday English; this
    // recogniser is bounded by SHAPE instead: a short line (at most eight
    // words), no question, no search verb, no media noun, no year, and one
    // clear social cue. "thanks, now show me rick" and "sorry, who was
    // Donna's mother?" still fall through to the ordinary pipeline.

    /// Words that mean the line is a question or a request, not a social
    /// aside. Any one of them disqualifies the line.
    private static let socialBlockWords: Set<String> = [
        "who", "whom", "what", "when", "where", "which", "why", "how",
        "show", "find", "search", "play", "reveal", "open", "list", "count",
        "tell", "give", "look", "video", "videos", "clip", "clips", "photo",
        "photos", "picture", "pictures", "footage", "tape", "tapes", "file",
        "files", "movie", "movies", "recording", "recordings", "catalog",
        "archive", "tree", "born", "died", "married", "related",
    ]

    private static let farewellPhrases = [
        "gotta run", "gotta go", "got to go", "got to run", "have to go",
        "have to run", "need to go", "need to run", "talk later",
        "talk to you later", "talk soon", "talk tomorrow", "see ya",
        "see you", "see you later", "see you tomorrow", "catch you later",
        "good night", "have a good night", "have a good day",
        "have a good one", "have a good evening", "have a great",
        "have a nice", "take care", "signing off", "logging off",
        "until next time", "bye for now", "off to bed", "heading out",
        "heading to bed", "going to bed",
    ]
    private static let farewellWords: Set<String> = [
        "bye", "goodbye", "goodnight", "cya", "ttyl", "farewell",
    ]

    private static let holdOnPhrases = [
        "hold on", "hang on", "one moment", "one sec", "one second",
        "just a sec", "just a second", "just a moment", "just a minute",
        "give me a sec", "give me a second", "give me a minute",
        "give me a moment", "wait a sec", "wait a second", "wait a minute",
        "wait a moment", "be right back", "hold that thought",
        "back in a sec", "back in a minute", "back in a moment",
    ]
    private static let holdOnWords: Set<String> = ["brb"]

    private static let apologyLeads = [
        "sorry", "so sorry", "i'm sorry", "im sorry", "i am sorry",
        "my apologies", "apologies", "my bad", "my mistake", "i apologize",
        "i apologise", "oops", "whoops", "oop", "pardon me", "excuse me",
    ]
    /// What may follow an apology and still be only an apology. A name or
    /// anything else outside this list ("sorry, I meant Timmy") is a real
    /// correction for the pipeline, not a pleasantry.
    private static let apologyTailVocabulary: Set<String> = [
        "i", "i'm", "im", "meant", "mean", "something", "else", "different",
        "that", "was", "wrong", "a", "the", "typo", "typing", "type", "typed",
        "keep", "name", "names", "mistake", "my", "about", "ignore", "didn't",
        "didnt", "did", "not", "bad", "again", "spelling", "spelled",
        "misspelled", "misspelt", "it", "there", "here", "confusing",
        "confused", "you", "hallie", "so", "for", "and", "sorry", "one",
        "last", "question", "message", "thing", "wrote", "said", "say",
        "asked", "ask", "mixed", "up", "muddled", "garbled", "fat", "fingers",
        "fingered", "on", "phone", "ipad", "autocorrect", "hit", "enter",
        "early", "too", "soon", "fast", "quick", "quickly", "never", "mind",
    ]

    private static let thanksWords: Set<String> = [
        "thanks", "thank", "thx", "ty", "cheers", "thankyou",
    ]

    /// The social kind of a short line, by shape. `words` is the line with
    /// "hallie", "please", and leading "ok"/"hey" already removed; `raw`
    /// is the lowercased original, used only to spot a question mark.
    static func detectSocialLine(words: [String], raw: String) -> Smalltalk? {
        guard !words.isEmpty, words.count <= 8 else { return nil }
        guard !raw.hasSuffix("?") else { return nil }
        let wordSet = Set(words)
        guard wordSet.isDisjoint(with: socialBlockWords) else { return nil }
        guard !words.contains(where: { $0.count == 4 && Int($0) != nil }) else { return nil }
        let padded = " " + words.joined(separator: " ") + " "

        // Goodbyes first: "thanks, talk later" is a goodbye.
        if farewellPhrases.contains(where: { padded.contains(" \($0) ") })
            || !wordSet.isDisjoint(with: farewellWords) {
            return .farewell
        }
        if holdOnPhrases.contains(where: { padded.contains(" \($0) ") })
            || !wordSet.isDisjoint(with: holdOnWords) {
            return .holdOn
        }
        for lead in apologyLeads where padded.hasPrefix(" \(lead) ") {
            let tail = words.dropFirst(lead.split(separator: " ").count)
            // "sorry, thanks anyway" is thanks.
            if tail.contains(where: { thanksWords.contains($0) }) { return .thanks }
            if tail.allSatisfy({ apologyTailVocabulary.contains($0) }) {
                return .apology
            }
            return nil
        }
        if !wordSet.isDisjoint(with: thanksWords) { return .thanks }
        // "I appreciate you" / "appreciate your help" / "much appreciated".
        if let index = words.firstIndex(where: { $0 == "appreciate" || $0 == "appreciated" }) {
            let after = words.dropFirst(index + 1)
            if after.isEmpty || after.contains(where: {
                ["you", "it", "that", "this", "your", "the"].contains($0)
            }) {
                return .thanks
            }
        }
        return nil
    }

    private static let addressWords: Set<String> = [
        "hallie", "please", "hey", "ok", "okay", "oh", "well",
    ]

    private static let leadingAddressWords: Set<String> = [
        "hey", "ok", "okay", "oh", "well",
    ]

    private static let leadingSalutations: Set<String> = [
        "hi", "hello", "hiya", "howdy", "yo",
    ]

    private static let helpPhrases: Set<String> = [
        "help", "help me", "i need help", "need help", "some help",
        "commands", "command list", "list commands", "show commands",
        "examples", "example", "example questions", "some examples",
        "show examples", "show me examples", "give me examples",
        "give me some examples", "show me some examples",
        "give me a few examples of things i can ask",
        "what can you do", "what can you do for me", "what do you do",
        "what can i ask", "what can i ask you", "what can i ask you about",
        "what can we ask", "what can we ask you", "what should i ask",
        "what should i ask you", "what do you know", "what do you know about",
        "what are you", "who are you", "what is this", "what's this",
        "tell me about yourself", "tell me about you", "tell us about yourself",
        "tell me about yourself, hallie", "describe yourself",
        "introduce yourself", "who are you, hallie",
        "how does this work", "how do you work", "how does it work",
        "how do i use this", "how do i use you", "how do we use this",
        "how do i talk to you", "how do i ask", "how do i ask you",
        "how do i ask you things", "how do i ask questions", "how to use",
        "how to", "instructions", "usage", "menu", "options", "tips",
        "what now", "what next", "im lost", "i'm lost", "i am lost",
        "i don't know what to ask", "i dont know what to ask",
        "not sure what to ask", "what kind of questions can i ask",
        "what kinds of questions can i ask", "what questions can i ask",
        "what can you help with", "what can you help me with",
        "can you help me", "can you help", "help please",
    ]

    /// Words a topic how-to may use ("how do i teach you names", "how do
    /// i practice names", "how do i research someone").
    private static let howToTopicVocabulary: Set<String> = [
        "teach", "you", "your", "a", "the", "names", "name", "pronunciation", "pronunciations", "pronounce",
        "practice", "practise", "drill", "research", "someone", "somebody", "person", "people", "tree",
        "family", "navigate", "center", "centre", "move", "around", "relationships", "relationship",
        "related", "kinship", "find", "out", "how", "who", "is", "are", "to", "with", "in", "on", "me", "us", "it",
    ]

    private static let howToLeads: [String] = [
        "how do i", "how do we", "how can i", "how can we", "how would i",
        "how should i", "how do you", "how to",
    ]

    private static let helpVocabulary: Set<String> = [
        "what", "can", "could", "do", "does", "should", "you", "i", "we", "ask",
        "hallie", "know", "help", "questions", "question", "things", "thing",
        "kind", "kinds", "sort", "sorts", "type", "types", "of", "for", "with",
        "about", "me", "us", "the", "to", "say", "are", "is", "able", "possible",
        "stuff", "all", "anything", "else", "here", "this", "tell", "find",
        "out", "exactly", "actually", "even", "answer", "handle", "understand",
        "good", "at", "your", "job", "purpose",
    ]

    private static let resetPhrases: Set<String> = [
        "start over", "start again", "start fresh", "start a new question",
        "new question", "a new question", "new topic", "new search",
        "forget that", "forget it", "forget all that", "forget about that",
        "forget the last one", "forget what i said", "reset", "reset that",
        "clear", "clear that", "clear it", "clear all", "clear everything",
        "clear the conversation", "clear memory", "never mind", "nevermind",
        "never mind that", "nevermind that", "scratch that", "scrap that",
        "drop that", "let's start over", "lets start over", "from the top",
        "begin again", "fresh start", "restart", "start clean",
    ]

    private static let smalltalkPhrases: [String: Smalltalk] = [
        // Greetings
        "hi": .greeting, "hello": .greeting, "hiya": .greeting, "hi there": .greeting,
        "hello there": .greeting, "howdy": .greeting, "good morning": .greeting,
        "good afternoon": .greeting, "good evening": .greeting, "morning": .greeting,
        "afternoon": .greeting, "evening": .greeting, "yo": .greeting,
        "hi hallie": .greeting, "are you there": .greeting,
        "you there": .greeting, "anyone there": .greeting, "hello hallie": .greeting,
        // Wellbeing. Keep a few common speech-to-text / typing variants here:
        // the 2026-08-20 transcript turned "how re you hallie?" into a family
        // relationship query, which is both unfriendly and factually dangerous.
        "how are you": .wellbeing, "how are you doing": .wellbeing,
        "how are you today": .wellbeing, "how is your day": .wellbeing,
        "how's your day": .wellbeing, "hows your day": .wellbeing,
        "how's your day going": .wellbeing, "hows your day going": .wellbeing,
        "how is your day going": .wellbeing, "how's your day been": .wellbeing,
        "how are things": .wellbeing, "how are you holding up": .wellbeing,
        "hows it going": .wellbeing,
        "how's it going": .wellbeing, "how r you": .wellbeing,
        "how re you": .wellbeing,
        // A small conversational second turn. These are deliberately about
        // the speaker's mood, not catalog facts, and therefore stay local.
        "i'm good": .userDoingWell, "im good": .userDoingWell,
        "i am good": .userDoingWell, "i'm well": .userDoingWell,
        "im well": .userDoingWell, "i am well": .userDoingWell,
        "doing well": .userDoingWell, "pretty good": .userDoingWell,
        "i'm doing well": .userDoingWell, "im doing well": .userDoingWell,
        "i am doing well": .userDoingWell,
        "i'm doing well thanks": .userDoingWell,
        "im doing well thanks": .userDoingWell,
        "i am doing well thanks": .userDoingWell,
        "not bad": .userDoingWell, "i'm okay": .userDoingWell,
        "im okay": .userDoingWell, "i am okay": .userDoingWell,
        "i'm tired": .userHavingHardTime, "im tired": .userHavingHardTime,
        "i am tired": .userHavingHardTime, "rough day": .userHavingHardTime,
        "i had a rough day": .userHavingHardTime,
        "i'm having a rough day": .userHavingHardTime,
        "im having a rough day": .userHavingHardTime,
        "i'm a little tired today": .userHavingHardTime,
        "im a little tired today": .userHavingHardTime,
        "i am a little tired today": .userHavingHardTime,
        "not great": .userHavingHardTime, "could be better": .userHavingHardTime,
        // Local clock questions are not archive searches.
        "what is the date": .date, "what's the date": .date,
        "whats the date": .date, "what is today's date": .date,
        "what's today's date": .date, "whats todays date": .date,
        "what day is it": .date, "what is the day": .date,
        "what is the daye": .date, "today's date": .date,
        "todays date": .date,
        "what time is it": .time, "what's the time": .time,
        "whats the time": .time, "what is the time": .time,
        "do you know what time it is": .time, "current time": .time,
        "is it morning or afternoon": .timeOfDay,
        "is it morning afternoon or evening": .timeOfDay,
        // Thanks
        "thanks": .thanks, "thank you": .thanks, "thank you very much": .thanks,
        "thanks very much": .thanks, "thanks so much": .thanks, "thanks a lot": .thanks,
        "thank you so much": .thanks, "many thanks": .thanks, "thanks a bunch": .thanks,
        "thanks a million": .thanks, "thank u": .thanks, "thx": .thanks, "ty": .thanks,
        "cheers": .thanks, "much appreciated": .thanks, "appreciate it": .thanks,
        "i appreciate it": .thanks, "thanks that's great": .thanks,
        "thanks that's kind of you": .thanks, "thanks thats kind of you": .thanks,
        "thank you for helping me": .thanks,
        "thanks thats great": .thanks, "great thanks": .thanks, "perfect thanks": .thanks,
        "great thank you": .thanks, "perfect thank you": .thanks, "wonderful thanks": .thanks,
        "awesome thanks": .thanks, "nice thanks": .thanks, "cool thanks": .thanks,
        // Farewells
        "bye": .farewell, "goodbye": .farewell, "bye bye": .farewell,
        "good night": .farewell, "goodnight": .farewell, "night": .farewell,
        "see you": .farewell, "see you later": .farewell, "later": .farewell,
        "talk later": .farewell, "talk to you later": .farewell, "gotta go": .farewell,
        "that's all": .farewell, "thats all": .farewell, "that's all for now": .farewell,
        "thats all for now": .farewell, "all done": .farewell, "done": .farewell,
        "im done": .farewell, "i'm done": .farewell, "that's it": .farewell,
        "thats it": .farewell, "that's it for now": .farewell, "thats it for now": .farewell,
        "i'll talk with you later": .farewell, "ill talk with you later": .farewell,
        // Affirmations that need no action
        "great": .affirmation, "perfect": .affirmation, "wonderful": .affirmation,
        "awesome": .affirmation, "nice": .affirmation, "cool": .affirmation,
        "lovely": .affirmation, "excellent": .affirmation, "good": .affirmation,
        "very good": .affirmation, "good job": .affirmation, "well done": .affirmation,
        "nice work": .affirmation, "good work": .affirmation, "you're the best": .affirmation,
        "youre the best": .affirmation, "love it": .affirmation, "i love it": .affirmation,
        "yay": .affirmation, "wow": .affirmation, "neat": .affirmation, "sweet": .affirmation,
        "fantastic": .affirmation, "amazing": .affirmation, "brilliant": .affirmation,
        "that makes sense": .understanding,
        "okay that makes sense": .understanding,
        "ok that makes sense": .understanding,
        "you're welcome": .userWelcome, "youre welcome": .userWelcome,
        "it's nice to talk with you": .companionship,
        "its nice to talk with you": .companionship,
        "that was helpful": .affirmation,
    ]

    // MARK: - Replies

    /// The help card: a short intro and example questions in family language,
    /// grouped by kind. Plain text with line breaks; renders as one bubble.
    static let helpCard: String = """
        Hi — I'm Hallie Mae, the family archivist. I answer from the video catalog and \
        the family tree, and I always show my evidence. Here's the kind of thing you can ask:

        Videos
        • show me videos of Donna down the Cape in the 90s
        • Christmas videos from 2006
        • show Timmy as a baby saying peekaboo
        • how many videos of Matt do we have?

        Family
        • who is Rick's dad?
        • who was Donna's great grandmother on her maternal side?
        • how am I related to you? · how is Donna related to Thankful Pratt?
        • show Donna's family tree
        • tell me about Thankful Pratt

        Names and the tree
        • let's practice names · pronounce McGill like MahGill or MicGill · how do you say Latta
        • how is Tim related to Rick? · how is Rick related to everyone in the People tab?
        • center the family tree on Martha Lamson
        • what do we know about David Latta from research?

        Follow-ups (after an answer)
        • play the first one · show more · reveal that one · show it in the catalog
        • narrow it down a step at a time: “playing guitar” · “in Westford” · “around 2005” · “with Donna”
        • and in the 90s? · what about Matt?

        Housekeeping
        • start over · help
        """

    /// One topic's section of the card, with the intro line the card has.
    static func helpSection(_ topic: HelpTopic) -> String {
        switch topic {
        case .names:
            return """
                Names — how I say them
                • let's practice names — I put one name at a time to you; say "right", "skip", or how to say it
                • pronounce McGill like MahGill or MicGill · Nathaniel is pronounced nuh-THAN-yul
                • either MahGill or MicGill (both kept; the first is what I say)
                • Latta should be pronounced with a short a on the La · La (as in Lag) and Tah
                • how do you say Latta? · what pronunciations do you have?
                """
        case .relationships:
            return """
                Relationships
                • how is Tim related to Rick? · how am I related to Donna?
                • how is Rick related to everyone in the People tab?
                • who is Rick's dad? · who was Donna's great grandmother on her maternal side?
                """
        case .tree:
            return """
                The family tree
                • show Donna's family tree · center the family tree on Martha Lamson
                • trace the Latta line back 5 generations · the Latta family tree
                • tell me about Thankful Pratt
                """
        case .research:
            return """
                Research
                • what do we know about David Latta from research?
                • tell me about Thankful Pratt
                """
        }
    }

    /// Example chips for a scoped card.
    static func helpExamples(_ topic: HelpTopic) -> [(question: String, label: String)] {
        switch topic {
        case .names:
            return [("let's practice names", "Try: let's practice names"),
                    ("how do you say Latta?", "Try: how do you say Latta?")]
        case .relationships:
            return [("how is Tim related to Rick?", "Try: how is Tim related to Rick?")]
        case .tree:
            return [("center the family tree on Martha Lamson", "Try: center the family tree on Martha Lamson")]
        case .research:
            return [("what do we know about David Latta from research?", "Try: what do we know about David Latta from research?")]
        }
    }

    /// Three example questions offered as clickable chips under the card.
    static let helpExamples: [(question: String, label: String)] = [
        ("show me videos of Donna down the Cape in the 90s",
         "Try: videos of Donna down the Cape in the 90s"),
        ("who is Rick's dad?", "Try: who is Rick's dad?"),
        ("show Donna's family tree", "Try: show Donna's family tree"),
    ]

    static func smalltalkReply(
        _ kind: Smalltalk,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        switch kind {
        case .greeting:
            return "Hello! It's good to see you. How can I help?"
        case .wellbeing:
            return "I'm doing well, thank you. It's good to see you. How are you doing?"
        case .userDoingWell:
            return "I'm glad to hear that. What would you like to talk about?"
        case .userHavingHardTime:
            return "I'm sorry to hear that. We can take things at an easy pace. What would be helpful right now?"
        case .companionship, .userWelcome, .understanding:
            return acknowledgementReply(kind)
        case .date:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "Today is \(formatter.string(from: now))."
        case .time:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return "It's \(formatter.string(from: now))."
        case .timeOfDay:
            let hour = Calendar(identifier: .gregorian)
                .dateComponents(in: timeZone, from: now).hour ?? 12
            switch hour {
            case 5..<12: return "It's morning."
            case 12..<17: return "It's afternoon."
            default: return "It's evening."
            }
        case .thanks:
            return "You're very welcome. I'm glad I could help."
        case .apology:
            return "No need to apologize. Say it again however it comes out, and I'll take another look."
        case .holdOn:
            return "Take your time — I'll be right here."
        case .farewell:
            return "Bye for now — I'll be right here when you want to look through more."
        case .affirmation:
            return "Glad that helped! Ask me another one whenever you're ready."
        }
    }

    private static func acknowledgementReply(_ kind: Smalltalk) -> String {
        switch kind {
        case .companionship:
            return "It's nice to talk with you too. What would you like to talk about?"
        case .userWelcome:
            return "Thank you. What would you like to talk about next?"
        case .understanding:
            return "Good. We can keep going whenever you're ready."
        default:
            preconditionFailure("acknowledgementReply called for \(kind)")
        }
    }

    static let resetReply =
        "Okay — I've cleared what we were talking about. Ask me anything."
}
