// HallieGeneralKnowledgeLane.swift
// The deterministic decision, made in Swift and never by the model, of
// whether a question is ordinary public knowledge / language / advice /
// harmless creativity — answerable freely in Hallie's voice — or an
// archive, family, tree, catalog or app question that must keep going
// through the grounded, cited, verified path.
//
// Rick's ruling 2026-09-03 (demo the next day): Hallie should answer a
// general question like a normal assistant instead of forcing it into a
// catalog search. The safety of that rests on TWO separate mechanisms:
//   1. this router, which is conservative about what counts as "general";
//   2. HallieGeneralAnswerBoundary, which refuses a general answer that
//      asserts anything about Rick's family, media or archive.
// Neither one is a prompt instruction. The model is never asked whether it
// may answer freely.
//
// Why the old recogniser missed 13 of 20 general questions (eval
// demo-20260903-eve): it vetoed on `isKnownPerson` applied to every
// lowercase token. In a 39,250-person GEDCOM, "English", "Star", "Short",
// "Old" and "Happy" are all surnames, so "Explain nostalgia in plain
// English." and "Tell me a short clean joke." looked like questions about
// relatives. A person's name in English is CAPITALISED; this file only
// consults the tree for a span the user actually typed as a name.

import Foundation

enum HallieGeneralKnowledgeLane {

    /// The two identity oracles this router needs. They are deliberately
    /// different sizes: `isKnownPerson` is the whole 39k tree and may only
    /// be asked about a span typed as a proper name; `isInnerCircleName`
    /// is the small curated set (People-tab profiles + CyberBrain) and is
    /// the only oracle allowed to judge a lone capitalised word.
    ///
    /// They are passed as two plain parameters rather than bundled in a
    /// struct so that callers may hand over non-escaping closures — a
    /// stored property would force `@escaping`, and every caller here is
    /// synchronous. (Swift's non-escaping default ≈ a C++ callback you
    /// promise not to keep past the call.)

    /// Why a question was or was not claimed — logged verbatim so a general
    /// answer can be explained afterwards from the log alone.
    enum Verdict: Equatable {
        case general(reason: String)
        case grounded(reason: String)

        var isGeneral: Bool {
            if case .general = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .general(let reason), .grounded(let reason): return reason
            }
        }
    }

    // MARK: - The rule

    /// THE ROUTING RULE, in order. First match wins.
    ///
    ///  1. a HARD archive cue → grounded. Media/catalog/tree vocabulary, a
    ///     retrieval command, a catalog-range year or decade, a proper name
    ///     the user typed that the family knows, an app-capability ask.
    ///  2. the question is not self-contained — a pronoun pointing at an
    ///     earlier turn, an ellipsis of fewer than four words, a dangling
    ///     preposition ("what are you unsure about?") → grounded. A
    ///     question that cannot be understood on its own is a follow-up,
    ///     and follow-ups belong to the grounded path.
    ///  3. a SOFT family cue (kin word, "family", "photographs", "stories",
    ///     "born"…) with no advice/creative/definition shape → grounded.
    ///     With such a shape it is family-ADJACENT ADVICE, which Rick asked
    ///     for in this lane: "a thoughtful way to label old family
    ///     photographs" is general advice, "when was my grandmother born"
    ///     is a family fact.
    ///  4. otherwise → general.
    ///
    /// Note the default in step 4 is the inversion Rick asked for: with no
    /// archive cue at all, an ordinary English question is answered, not
    /// searched for. The family-claim boundary is what makes that safe.
    /// One-oracle form. Without a curated inner circle the WIDE oracle is
    /// used for lone words too — the conservative direction, so a caller
    /// that has only one oracle over-routes to grounded rather than
    /// under-routing to free composition.
    static func decide(_ text: String, isKnownPerson: (String) -> Bool) -> Verdict {
        decide(text, isKnownPerson: isKnownPerson, isInnerCircleName: isKnownPerson)
    }

    static func decide(
        _ text: String,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> Verdict {
        let normalized = normalize(text)
        let tokens = words(normalized)
        guard !tokens.isEmpty else {
            return .grounded(reason: "empty question")
        }

        // Vocabulary, commands and dates first: they cost nothing and they
        // settle most turns. Identity is consulted only afterwards, so a
        // two-word fragment never loads the People tab or the tree.
        if let cue = vocabularyCue(normalized: normalized, tokens: tokens) {
            return .grounded(reason: "hard archive cue: \(cue)")
        }

        if let why = notSelfContained(normalized, tokens: tokens) {
            return .grounded(reason: "not self-contained: \(why)")
        }

        if let hit = secondPersonSubject(tokens: tokens) {
            return .grounded(reason: "addressed to Hallie herself (“\(hit)”)")
        }

        if let name = typedFamilyName(text, isKnownPerson: isKnownPerson,
                                      isInnerCircleName: isInnerCircleName) {
            return .grounded(reason: "typed family name “\(name)”")
        }

        if let soft = softFamilyCue(tokens: tokens) {
            guard let shape = adviceShape(normalized) else {
                return .grounded(reason: "family cue “\(soft)” with no advice shape")
            }
            return .general(reason: "family-adjacent advice (\(shape)) about “\(soft)”")
        }

        return .general(reason: "no archive or family cue")
    }

    /// The NARROW gate used before the deterministic family lanes run
    /// (`HallieTurnExecutor.preTranslationSingle`). Only an advice /
    /// creative / definition request with no hard archive cue may skip
    /// them; everything else keeps the existing lane order untouched.
    ///
    /// This exists for one observed shape: "Help me think of three
    /// questions to ask my grandmother." was answered by the kinship lane
    /// with the names of Rick's two grandmothers. A plain "Why is the sky
    /// blue?" needs no early gate — no family lane claims it, and the
    /// full rule catches it at translation time.
    static func claimsBeforeFamilyLanes(
        _ text: String, isKnownPerson: (String) -> Bool
    ) -> Verdict {
        claimsBeforeFamilyLanes(text, isKnownPerson: isKnownPerson,
                                isInnerCircleName: isKnownPerson)
    }

    static func claimsBeforeFamilyLanes(
        _ text: String,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> Verdict {
        guard adviceShape(normalize(text)) != nil else {
            return .grounded(reason: "not an advice or creative request")
        }
        return decide(text, isKnownPerson: isKnownPerson,
                      isInnerCircleName: isInnerCircleName)
    }

    // MARK: - Hard archive cues

    /// Vocabulary with no ordinary conversational use in this app. Kin
    /// words, "photo", "story", "born" and friends are deliberately NOT
    /// here — they are soft, because advice about them is still advice.
    static let hardArchiveWords: Set<String> = [
        "archive", "archives", "archived", "catalog", "catalogs", "catalogue",
        "mxf", "transcript", "transcripts", "caption", "captions",
        "dossier", "gedcom", "metadata", "codec", "thumbnail", "filmstrip",
        "video", "videos", "clip", "clips", "footage", "tape", "tapes",
        "reel", "reels", "recording", "recordings", "movie", "movies",
        "film", "films", "filmed", "file", "files", "folder", "volume",
        "biography", "biographies", "genealogy", "lineage", "ancestry",
        "surname", "surnames", "maiden",
        "kinship", "related", "relationship", "relationships",
        "evidence", "citation", "citations", "provenance",
    ]

    /// Phrases that name the archive, the app, or a selected item.
    static let hardArchivePhrases = [
        "family tree", "people tab", "catalog tab", "storage tab",
        "archive tab", "triage tab", "family archive", "in the archive",
        "the catalog", "our catalog", "my catalog", "the collection",
        "this video", "this clip", "this photo", "this file", "this record",
        "this tape", "the selected", "home video", "home movies",
        "related to", "where did that come from", "show the source",
        "what is the source",
    ]

    /// Asks about Hallie's own features. They have a deterministic
    /// capability/help answer and must never become free conversation.
    static let capabilityPhrases = [
        "what can you", "what else can you", "things i can ask",
        "examples of things", "what do you do", "how do i ask",
        "can you do", "what are you able", "help me with",
        "what should i ask you", "how do you work", "what are your",
    ]

    /// Retrieval commands. Prefix-matched: a sentence that OPENS with one
    /// of these is an instruction to look something up.
    static let retrievalLeads = [
        "show ", "show me", "find ", "search ", "look up", "look for",
        "play ", "reveal ", "open ", "list ", "count ", "pull up",
        "how many", "how much", "tell me about", "who is", "who was",
        "who are", "who were", "whos ", "when is", "when was", "when did",
        "where is", "where was", "where did", "do we have", "do you have",
        "did you find", "which ", "is there a", "are there any",
        "research ", "look into",
    ]

    /// Contained anywhere, not just at the front.
    static let retrievalPhrases = [
        "how old is", "how old was", "how old were", "how old would",
        "how am i related",
        "how are you related", "how is he related", "how is she related",
    ]

    /// The cues that need no identity oracle at all.
    private static func vocabularyCue(
        normalized: String,
        tokens: [String]
    ) -> String? {
        if let hit = capabilityPhrases.first(where: normalized.contains) {
            return "app capability “\(hit)”"
        }
        if let hit = hardArchivePhrases.first(where: normalized.contains) {
            return "“\(hit)”"
        }
        if let hit = retrievalLeads.first(where: normalized.hasPrefix) {
            return "retrieval command “\(hit.trimmingCharacters(in: .whitespaces))”"
        }
        if let hit = retrievalPhrases.first(where: normalized.contains) {
            return "retrieval phrase “\(hit)”"
        }
        if let hit = tokens.first(where: hardArchiveWords.contains) {
            return "archive word “\(hit)”"
        }
        if let hit = tokens.first(where: isCatalogDate) {
            return "catalog-range date “\(hit)”"
        }
        return nil
    }

    /// "can you …", "could you …", "do you have …" at the START: the "you"
    /// is the addressee of a request, not a subject Hallie must have a life
    /// to answer about. Only the opening is peeled.
    private static let requestLeads = [
        "can you", "could you", "would you", "will you", "do you know",
        "do you have", "are you able to", "please can you",
    ]
    private static let leadFillers = ["hallie", "please", "ok", "okay", "so", "hey"]
    private static let secondPersonWords: Set<String> = [
        "you", "your", "yours", "yourself",
    ]

    /// A question that still speaks to "you" after its opening request lead
    /// is peeled is a question about HALLIE — "what was your favorite
    /// meal?", "did your house have electricity?", "what was school like
    /// for you?". She has no life of her own to report, so such a question
    /// belongs to the deterministic persona/graph path and never to free
    /// composition, whatever else it looks like.
    ///
    /// None of the twenty general questions in the corpus says "you" or
    /// "your" outside a peeled request lead, which is what makes this cue
    /// free to apply.
    static func secondPersonSubject(tokens: [String]) -> String? {
        var remaining = tokens
        while let first = remaining.first, leadFillers.contains(first) {
            remaining.removeFirst()
        }
        let opening = " " + remaining.joined(separator: " ") + " "
        for lead in requestLeads where opening.hasPrefix(" \(lead) ") {
            remaining.removeFirst(lead.split(separator: " ").count)
            break
        }
        return remaining.first(where: secondPersonWords.contains)
    }

    /// A four-digit year in the catalog range, or a decade ("1990s").
    /// A year is a strong archive cue even in a sentence shaped like a
    /// public-knowledge question ("Why did we move to Westford in 1994?").
    static func isCatalogDate(_ token: String) -> Bool {
        if token.count == 4, let year = Int(token) {
            return ArchivistQueryAST.yearRange.contains(year)
        }
        if token.count == 5, token.hasSuffix("s"),
           let year = Int(token.dropLast()) {
            return ArchivistQueryAST.yearRange.contains(year)
        }
        return false
    }

    // MARK: - Typed proper names

    /// Kin words that make the NEXT capitalised word a person's name
    /// ("my brother Mark", "cousin Sue").
    private static let namingKinWords: Set<String> = [
        "grandma", "grandmother", "grandpa", "grandfather", "grandparent",
        "mom", "mum", "mother", "dad", "father", "parent", "brother",
        "sister", "uncle", "aunt", "cousin", "niece", "nephew", "son",
        "daughter", "child", "husband", "wife", "spouse", "nana",
        "great-grandmother", "great-grandfather",
    ]

    /// A span the user typed as a name that the family knows.
    ///
    /// FOUR rules, in order, and the split between them is the whole fix:
    ///
    ///  1. any word with a possessive, or right after a kin word, is asked
    ///     of the WHOLE tree — "donna's", "my brother Mark";
    ///  2. a run of two or more CAPITALISED words is asked of the whole
    ///     tree — "Matthew Rice", "Hallie Mae";
    ///  3. a run of two or more name-plausible words in ANY case is asked
    ///     of the whole tree — Rick types lowercase, and "research william
    ///     love latter" must still be a tree question. Function words,
    ///     archive words and family words break the run, so "the sky blue"
    ///     is only ever asked as "sky blue";
    ///  4. a LONE word is asked only of the small curated inner circle.
    ///
    /// Rule 4 is the one that matters. In a 39,250-person GEDCOM,
    /// "english", "star", "short", "old", "happy", "bread" and "rise" are
    /// all surnames; asking the tree about a lone word turned thirteen
    /// ordinary English questions into family-tree lookups.
    static func typedFamilyName(
        _ text: String, isKnownPerson: (String) -> Bool
    ) -> String? {
        typedFamilyName(text, isKnownPerson: isKnownPerson,
                        isInnerCircleName: isKnownPerson)
    }

    static func typedFamilyName(
        _ text: String,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> String? {
        let tokens = capitalizationTokens(text)
        guard !tokens.isEmpty else { return nil }

        // 1. Possessives and appositions to a kin word.
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1].word.lowercased() : ""
            guard isNamePlausible(token.word),
                  token.possessive || namingKinWords.contains(previous) else { continue }
            if isKnownPerson(token.word) { return token.word }
        }

        // 2. Capitalised runs.
        if let hit = runHit(in: tokens, isKnownPerson: isKnownPerson,
                            member: { $0.isCapitalized }) {
            return hit
        }

        // 3. Name-plausible runs, whatever the case.
        if let hit = runHit(in: tokens, isKnownPerson: isKnownPerson,
                            member: { isNamePlausible($0.word) }) {
            return hit
        }

        // 4a. Hallie is both the assistant and a person in the tree. Named
        // OUTSIDE the vocative — "what don't we know about Hallie?" — the
        // question is about the person and belongs to the graph. Named in
        // the vocative — "Good morning, Hallie." / "Hallie, tell me a
        // joke." — she is only being addressed. (Live 2026-09-03: the
        // biography question took the general lane and got a polite
        // non-answer instead of her record.)
        if let hit = nonVocativeAssistantName(text) { return hit }

        // 4. Lone words: the inner circle only, and never a glue word.
        // GEDCOM middle initials make single letters legitimate name
        // tokens, so "a" and "i" resolve as people in a 39k tree — that
        // made almost every English sentence look as though it named a
        // relative.
        for token in tokens
        where isNamePlausible(token.word) && isInnerCircleName(token.word) {
            return token.word
        }
        return nil
    }

    /// "Hallie" used as a noun rather than as a form of address. Vocative
    /// = touching a comma, or standing alone as the whole line.
    static func nonVocativeAssistantName(_ text: String) -> String? {
        let scalars = Array(text)
        let lowered = text.lowercased()
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: "hallie", range: searchStart..<lowered.endIndex) {
            searchStart = range.upperBound
            let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            let end = start + "hallie".count
            // A longer name ("Hallie Mae", "Hallies") is handled by the
            // ordinary run rules, not here.
            if end < scalars.count, scalars[end].isLetter { continue }
            if start > 0, scalars[start - 1].isLetter { continue }
            // Part of a longer name ("Hallie Mae McGill") or a possessive
            // ("Hallie's father") — both belong to the ordinary run and
            // possessive rules, which ask the whole tree.
            if end < scalars.count, scalars[end] == "'" || scalars[end] == "\u{2019}" {
                continue
            }
            var after = end
            while after < scalars.count, scalars[after] == " " { after += 1 }
            if after > end, after < scalars.count, scalars[after].isUppercase { continue }
            func commaNear(_ index: Int, step: Int) -> Bool {
                var cursor = index
                while cursor >= 0 && cursor < scalars.count {
                    let character = scalars[cursor]
                    if character == "," { return true }
                    if !character.isWhitespace { return false }
                    cursor += step
                }
                return false
            }
            if commaNear(start - 1, step: -1) || commaNear(end, step: 1) { continue }
            return "Hallie"
        }
        return nil
    }

    /// Maximal runs of two or more tokens satisfying `member`, each run
    /// tried whole and then as every contiguous sub-span of two or more
    /// words. A "name" longer than four words is not a name.
    private static func runHit(
        in tokens: [CapToken],
        isKnownPerson: (String) -> Bool,
        member: (CapToken) -> Bool
    ) -> String? {
        var index = 0
        while index < tokens.count {
            guard member(tokens[index]) else { index += 1; continue }
            var end = index
            while end + 1 < tokens.count, member(tokens[end + 1]) { end += 1 }
            if end > index {
                for width in stride(from: min(4, end - index + 1), through: 2, by: -1) {
                    for start in index...(end - width + 1) {
                        let span = tokens[start..<(start + width)]
                            .map(\.word).joined(separator: " ")
                        if isKnownPerson(span) { return span }
                    }
                }
            }
            index = end + 1
        }
        return nil
    }

    /// Words that never carry a person on their own: closed-class English
    /// glue, plus every archive and family word this file already knows.
    /// A run is broken by any of them, which is what keeps "the sky blue"
    /// from being asked as a three-word name.
    static let nameStopWords: Set<String> = {
        var words: Set<String> = [
            "a", "an", "the", "and", "or", "but", "if", "so", "as", "than",
            "then", "that", "this", "these", "those", "there", "here",
            "is", "are", "was", "were", "be", "been", "being", "am",
            "do", "does", "did", "have", "has", "had", "can", "could",
            "will", "would", "shall", "should", "may", "might", "must",
            "to", "of", "in", "on", "for", "with", "at", "by", "from",
            "about", "into", "over", "under", "between", "after", "before",
            "i", "me", "my", "mine", "we", "us", "our", "ours", "you",
            "your", "yours", "he", "him", "his", "she", "hers", "it",
            "its", "they", "them", "their", "theirs",
            "what", "why", "how", "when", "where", "who", "whom", "which",
            "whose", "not", "no", "yes", "please", "just", "very", "some",
            "any", "all", "both", "each", "more", "most", "other",
            "another", "same", "only", "own", "such", "one", "ones", "two",
            "three", "four", "five", "few", "many", "much", "old", "new",
            "good", "nice", "best", "way", "ways", "thing", "things",
            "tell", "told", "say", "said", "make", "made", "give", "get",
            "go", "come", "know", "think", "want", "like", "help", "ask",
            "asked", "show", "find", "write", "suggest", "explain",
            "define", "mean", "means", "meant", "use", "used", "put",
            "take", "keep", "let", "see", "look", "need", "try", "call",
            "called", "start", "begin", "end", "back",
        ]
        words.formUnion(hardArchiveWords)
        words.formUnion(softFamilyWords)
        return words
    }()

    static func isNamePlausible(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return word.count >= 2
            && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
            && !nameStopWords.contains(lowered)
    }

    private struct CapToken {
        let word: String
        let isCapitalized: Bool
        let possessive: Bool
    }

    /// Words with their original case, plus whether a possessive `'s`
    /// followed. Sentence-initial position is NOT special-cased: a lone
    /// capitalised opener ("Why", "Explain") is already limited to the
    /// inner-circle oracle, which will not claim it.
    private static func capitalizationTokens(_ text: String) -> [CapToken] {
        var tokens: [CapToken] = []
        var current = ""
        var possessive = false

        func flush() {
            let trimmed = current.trimmingCharacters(
                in: CharacterSet(charactersIn: "'’"))
            if !trimmed.isEmpty {
                tokens.append(CapToken(
                    word: trimmed,
                    isCapitalized: trimmed.first?.isUppercase == true,
                    possessive: possessive))
            }
            current = ""
            possessive = false
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "s" || text[next] == "S" {
                    let afterS = text.index(after: next)
                    let boundary = afterS >= text.endIndex || !text[afterS].isLetter
                    if boundary && !current.isEmpty {
                        possessive = true
                        index = afterS
                        flush()
                        continue
                    }
                }
                current.append(character)
            } else {
                flush()
            }
            index = text.index(after: index)
        }
        flush()
        return tokens
    }

    // MARK: - Soft family cues

    /// Ordinary English words that are ALSO family-archive vocabulary.
    /// They keep a question grounded unless it is plainly a request for
    /// advice, a definition, or something creative.
    static let softFamilyWords: Set<String> = [
        "family", "families", "relative", "relatives", "ancestor",
        "ancestors", "descendant", "descendants", "heritage", "generation",
        "generations", "reunion",
        "grandma", "grandmother", "grandmothers", "grandpa", "grandfather",
        "grandfathers", "grandparent", "grandparents", "grandchild",
        "grandchildren", "grandson", "granddaughter",
        "mom", "moms", "mum", "mother", "mothers", "dad", "dads", "father",
        "fathers", "parent", "parents", "brother", "brothers", "sister",
        "sisters", "uncle", "uncles", "aunt", "aunts", "cousin", "cousins",
        "niece", "nieces", "nephew", "nephews", "son", "sons", "daughter",
        "daughters", "child", "children", "kid", "kids", "boy", "boys",
        "girl", "girls", "folks", "husband", "wife",
        "spouse", "nana", "sibling", "siblings",
        "photo", "photos", "photograph", "photographs", "picture",
        "pictures", "album", "albums", "slide", "slides", "negative",
        "negatives", "snapshot", "snapshots",
        "story", "stories", "memory", "memories", "keepsake", "heirloom",
        "memento", "mementos",
        "born", "birth", "birthday", "died", "death", "married",
        "marriage", "wedding", "anniversary", "funeral",
        "record", "records", "source", "sources", "note", "notes",
        "audio", "sound", "music", "song", "songs", "track", "voice",
        "history", "past", "generationally",
    ]

    private static func softFamilyCue(tokens: [String]) -> String? {
        tokens.first(where: softFamilyWords.contains)
    }

    // MARK: - Advice / creative / definition shapes

    /// Openings that mark a request for advice, a definition, an
    /// explanation of public knowledge, or something creative. Used ONLY to
    /// let a family-ADJACENT request through — never to decide, on its own,
    /// that something is general.
    /// Interview-planning questions are family-adjacent advice, not asks
    /// for a fact about the relative. Kept separate because only these
    /// leads may treat a later locally-bound possessive ("my grandmother
    /// ... her childhood") as self-contained.
    static let familyInterviewAdviceLeads = [
        "what questions can i", "what questions could i",
        "what questions should i", "what questions might i",
    ]

    static let adviceLeads = [
        "help me", "suggest", "give me", "write ", "make up a",
        "come up with", "think of", "recommend", "any ideas", "ideas for",
        "tips for", "brainstorm",
        "can you think", "can you make", "can you write", "can you suggest",
        "can you come up with", "can you explain", "could you write",
        "could you suggest", "could you explain",
        "what is a good", "what's a good", "whats a good",
        "what is a nice", "what's a nice", "what is a thoughtful",
        "what's a thoughtful", "what is the best way", "what's the best way",
        "what would be a good", "what would you suggest",
        "how can i", "how could i", "how might i", "how should i",
        "what should i", "what could i",
    ] + familyInterviewAdviceLeads + [
        "tell me a ", "tell me another ",
        "explain ", "define ", "what does ", "what do ",
        "what is the difference", "what's the difference",
        "whats the difference", "what is another word",
        "what's another word", "what is meant by",
        "why ", "what makes ", "what causes ", "how does ", "how do ",
        "is it true", "what happens when",
    ]

    /// The same idea, matched anywhere in the sentence.
    static let advicePhrases = [
        " a good way to ", " a nice way to ", " a thoughtful way to ",
        " a gentle way to ", " ideas for ", " tips for ", " some advice ",
        " any advice ", " suggestions for ", " a way to ",
    ]

    /// Nil when the sentence is not an advice/creative/definition request.
    static func adviceShape(_ normalized: String) -> String? {
        if let hit = adviceLeads.first(where: normalized.hasPrefix) {
            return hit.trimmingCharacters(in: .whitespaces)
        }
        let padded = " " + normalized + " "
        if let hit = advicePhrases.first(where: padded.contains) {
            return hit.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Continuity

    /// Words that point OUT of this sentence, at the previous answer.
    static let outwardReferences: Set<String> = [
        "it", "its", "that", "those", "these", "them", "they", "their",
        "theirs", "he", "him", "his", "she", "her", "hers", "one", "ones",
        "instead", "again", "more", "then",
    ]

    /// A possessive pronoun can be self-contained when its antecedent was
    /// stated earlier in the same sentence: "my grandmother ... her
    /// childhood". Without this distinction, the advice request is treated
    /// as a follow-up even though it needs no conversation history.
    private static let feminineKinAntecedents: Set<String> = [
        "grandma", "grandmother", "mom", "mum", "mother", "sister",
        "aunt", "niece", "daughter", "wife", "nana",
    ]
    private static let masculineKinAntecedents: Set<String> = [
        "grandpa", "grandfather", "dad", "father", "brother", "uncle",
        "nephew", "son", "husband",
    ]
    private static let neutralKinAntecedents: Set<String> = [
        "grandparent", "grandparents", "parent", "parents", "relative",
        "relatives", "sibling", "siblings", "cousin", "cousins", "child",
        "children", "kid", "kids", "spouse",
    ]

    private static func hasLocalPossessiveAntecedent(
        for pronoun: String,
        before index: Int,
        tokens: [String]
    ) -> Bool {
        let candidates: Set<String>
        switch pronoun {
        case "her", "hers": candidates = feminineKinAntecedents
        case "his": candidates = masculineKinAntecedents
        case "their", "theirs": candidates = neutralKinAntecedents
        default: return false
        }
        guard index >= 2 else { return false }
        return (1..<index).contains { position in
            (tokens[position - 1] == "my" || tokens[position - 1] == "our")
                && candidates.contains(tokens[position])
        }
    }

    /// Prepositions a sentence only ends with when its object was said in
    /// the previous turn ("what are you unsure about?").
    static let danglingPrepositions: Set<String> = [
        "about", "from", "of", "with", "in", "on", "for", "to", "at",
        "by", "like", "after", "before", "instead", "too",
    ]

    /// Nil when the question stands on its own; otherwise why it does not.
    static func notSelfContained(_ normalized: String, tokens: [String]) -> String? {
        if tokens.count < 4 {
            return "is an ellipsis of \(tokens.count) word\(tokens.count == 1 ? "" : "s")"
        }
        if let last = tokens.last, danglingPrepositions.contains(last) {
            return "ends with the dangling preposition “\(last)”"
        }
        let isFamilyInterviewAdvice = familyInterviewAdviceLeads.contains {
            normalized.hasPrefix($0)
        }
        if let hit = tokens.enumerated().first(where: { index, token in
            outwardReferences.contains(token)
                && !(isFamilyInterviewAdvice
                     && hasLocalPossessiveAntecedent(
                        for: token, before: index, tokens: tokens))
        })?.element {
            return "refers back with “\(hit)”"
        }
        return nil
    }

    // MARK: - Normalization

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
