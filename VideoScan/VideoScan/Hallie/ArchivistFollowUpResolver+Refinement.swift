// ArchivistFollowUpResolver+Refinement.swift
// The cumulative refinement half of the follow-up resolver: bare fragments
// after an answered list question ("playing guitar", "in westford", "around
// 2005", "with donna") narrow the previous AST step by step. Pure; no model,
// no I/O. Split from ArchivistFollowUpResolver.swift for size only.

import Foundation

extension ArchivistFollowUpResolver {

    // MARK: - Cumulative refinement (Rick 2026-08-17)
    //
    // After an answered list question, BARE FRAGMENTS refine the previous AST
    // cumulatively: "playing guitar" → keywords += guitar; "in westford" →
    // keywords += westford; "around 2005" → years 2004–2006; "with donna" →
    // people += donna. Each step keeps the prior constraints (AND). A
    // comparative lead ("what about matt?", "matt instead of donna") swaps
    // the like field instead of adding. Non-list shapes (family tree, age,
    // who-appears-with) keep single-field replacement. A fully formed
    // question — a sentence verb, or a person plus other content with no
    // lead — is never a refinement; it starts fresh through the translator.

    private enum LeadKind { case additive, comparative, subtractive }

    private struct Lead {
        let phrase: String
        let kind: LeadKind
        /// Prepositions ("in", "at") are soft: they shape the fragment but
        /// are not, by themselves, evidence that the user is continuing a
        /// conversation the way "and …" / "what about …" are.
        let soft: Bool
    }

    private static let leads: [Lead] = [
        // Comparative — swap the like field.
        .init(phrase: "and what about", kind: .comparative, soft: false),
        .init(phrase: "and how about", kind: .comparative, soft: false),
        .init(phrase: "what about", kind: .comparative, soft: false),
        .init(phrase: "how about", kind: .comparative, soft: false),
        .init(phrase: "what bout", kind: .comparative, soft: false),
        .init(phrase: "how bout", kind: .comparative, soft: false),
        .init(phrase: "same for", kind: .comparative, soft: false),
        .init(phrase: "same but", kind: .comparative, soft: false),
        .init(phrase: "or maybe", kind: .comparative, soft: false),
        .init(phrase: "or just", kind: .comparative, soft: false),
        .init(phrase: "or", kind: .comparative, soft: false),
        .init(phrase: "but", kind: .comparative, soft: false),
        .init(phrase: "just", kind: .comparative, soft: false),
        .init(phrase: "only", kind: .comparative, soft: false),
        .init(phrase: "rather", kind: .comparative, soft: false),
        // Subtractive — drop a person.
        .init(phrase: "but not", kind: .subtractive, soft: false),
        .init(phrase: "and not", kind: .subtractive, soft: false),
        .init(phrase: "without", kind: .subtractive, soft: false),
        .init(phrase: "not", kind: .subtractive, soft: false),
        .init(phrase: "minus", kind: .subtractive, soft: false),
        .init(phrase: "except", kind: .subtractive, soft: false),
        .init(phrase: "drop", kind: .subtractive, soft: false),
        .init(phrase: "remove", kind: .subtractive, soft: false),
        // Narrowing verbs people actually type ("narrow that to winter",
        // "filter to 1994"). Without these the VERB itself became a search
        // keyword and the answer read "Narrowed to Narrow, Winter — nothing
        // matched" (eval 2026-08-21). Longest form first so "narrow it down
        // to" is consumed whole.
        .init(phrase: "narrow it down to", kind: .comparative, soft: false),
        .init(phrase: "narrow that down to", kind: .comparative, soft: false),
        .init(phrase: "narrow it down", kind: .comparative, soft: false),
        .init(phrase: "narrow that down", kind: .comparative, soft: false),
        .init(phrase: "narrow it to", kind: .comparative, soft: false),
        .init(phrase: "narrow that to", kind: .comparative, soft: false),
        .init(phrase: "narrow down to", kind: .comparative, soft: false),
        .init(phrase: "narrow to", kind: .comparative, soft: false),
        .init(phrase: "narrow", kind: .comparative, soft: false),
        .init(phrase: "filter to", kind: .comparative, soft: false),
        .init(phrase: "filter", kind: .comparative, soft: false),
        .init(phrase: "limit to", kind: .comparative, soft: false),
        .init(phrase: "limit", kind: .comparative, soft: false),
        .init(phrase: "restrict to", kind: .comparative, soft: false),
        .init(phrase: "refine to", kind: .comparative, soft: false),
        // Additive — keep everything and add.
        .init(phrase: "and also", kind: .additive, soft: false),
        .init(phrase: "and now", kind: .additive, soft: false),
        .init(phrase: "and then", kind: .additive, soft: false),
        .init(phrase: "and with", kind: .additive, soft: false),
        .init(phrase: "ok and", kind: .additive, soft: false),
        .init(phrase: "okay and", kind: .additive, soft: false),
        .init(phrase: "also with", kind: .additive, soft: false),
        .init(phrase: "and", kind: .additive, soft: false),
        .init(phrase: "also", kind: .additive, soft: false),
        .init(phrase: "with", kind: .additive, soft: false),
        .init(phrase: "plus", kind: .additive, soft: false),
        .init(phrase: "now", kind: .additive, soft: false),
        .init(phrase: "then", kind: .additive, soft: false),
        .init(phrase: "in", kind: .additive, soft: true),
        .init(phrase: "at", kind: .additive, soft: true),
        .init(phrase: "from", kind: .additive, soft: true),
        .init(phrase: "during", kind: .additive, soft: true),
        .init(phrase: "for", kind: .additive, soft: true),
        .init(phrase: "of", kind: .additive, soft: true),
        .init(phrase: "on", kind: .additive, soft: true),
    ]

    /// Words a fragment may carry that add nothing to the search: function
    /// words, the media nouns, and the "doing" verbs people put in front of
    /// a topic ("playing guitar", "saying peekaboo", "wearing the red hat").
    private static let fragmentFiller: Set<String> = ArchivistKeywordText.stopwords.union([
        "the", "a", "an", "just", "only", "back", "over", "to", "maybe", "say",
        "please", "then", "hallie", "same", "again", "one", "ones", "those",
        "these", "them", "it", "he", "she", "they", "him", "her", "his",
        "hers", "their", "as", "well", "too", "also", "plus", "and",
        "with", "at", "in", "on", "of", "from", "during", "for", "playing",
        "plays", "played", "play", "doing", "does", "did", "do", "having",
        "has", "have", "had", "being", "wearing", "riding", "rides", "rode",
        "saying", "says", "said", "singing", "sings", "sang", "talking",
        "talks", "talked", "sitting", "sits", "sat", "standing", "stands",
        "holding", "holds", "held", "using", "uses", "used", "going", "goes",
        "went", "getting", "gets", "got", "making", "makes", "made", "eating",
        "eats", "ate", "opening", "opens", "opened", "where", "when", "while",
        "yes", "yeah", "yep", "no", "nope", "ok", "okay", "hmm", "um", "uh",
        "sure", "right", "so", "oh", "ah", "like", "kind", "sort", "stuff",
        "things", "thing", "something", "anything", "everything", "there",
        "here", "who", "whom", "which", "what", "about", "around", "circa",
        "roughly", "approximately", "near", "nearly", "sometime", "somewhere",
        "some", "any", "instead", "rather", "than", "not", "without", "except",
        "minus", "but", "or", "ish", "time", "times", "day", "days", "year",
        "years", "old", "little", "young", "still", "more", "less", "other",
        "others", "another", "again", "either", "both", "each", "every", "all",
        "many", "much", "lot", "lots", "few", "several", "way", "ways",
    ])

    private static let politeness: Set<String> = [
        "please", "hallie", "ok", "okay", "hey", "um", "uh", "well", "yes",
        "yeah", "kindly", "so", "oh", "ah", "hmm", "right", "sure", "cool",
        "great", "thanks",
    ]

    private static let mediaNouns: Set<String> = [
        "video", "videos", "clip", "clips", "movie", "movies", "footage",
        "recording", "recordings", "tape", "tapes", "film", "films", "reel",
        "reels", "photo", "photos", "picture", "pictures",
    ]

    private static let approxWords: Set<String> = [
        "around", "about", "circa", "roughly", "approximately", "near",
        "nearly", "sometime", "close", "like", "maybe", "say", "ish",
    ]

    private static let sentenceVerbs: Set<String> = [
        "show", "play", "find", "who", "what", "when", "where", "how", "is",
        "was", "are", "were", "do", "does", "did", "can", "could", "tell",
        "count", "list", "reveal", "open", "get", "give", "search", "watch",
        "which", "why", "would", "should", "will", "want", "need", "know",
        "think", "remember", "have", "has", "had", "i", "we", "you", "let",
        "let's", "lets", "please", "help",
    ]

    /// Cap on people/topics one question can hold (the AST list bound), so a
    /// runaway chain is stopped with an honest message instead of an invalid
    /// query.
    private static let maxChainTerms = ArchivistQueryAST.maxListItems

    /// The leads peeled off the front of a fragment and what is left.
    private struct LeadScan {
        var residual: [String]
        var kind: LeadKind?
        var explicit = false
        var soft = false
        var hadLead: Bool { explicit || soft }
    }

    /// Peel leads while they keep matching ("and with donna"). Comparative
    /// and subtractive leads beat additive ones.
    private static func scanLeads(_ rawWords: [String]) -> LeadScan {
        // Politeness only — "and", "then", "just" are leads with meaning here.
        var scan = LeadScan(residual: Array(rawWords.drop { politeness.contains($0) }))
        var progressed = true
        while progressed {
            progressed = false
            for lead in leads.sorted(by: { $0.phrase.count > $1.phrase.count }) {
                let leadWords = lead.phrase.split(separator: " ").map(String.init)
                guard Array(scan.residual.prefix(leadWords.count)) == leadWords,
                      scan.residual.count > leadWords.count else { continue }
                scan.residual = Array(scan.residual.dropFirst(leadWords.count))
                if lead.soft { scan.soft = true } else { scan.explicit = true }
                switch (scan.kind, lead.kind) {
                case (nil, let new), (.additive?, let new): scan.kind = new
                default: break
                }
                progressed = true
                break
            }
        }
        return scan
    }

    /// A sentence of its own — verbs, kinship possessives, too long, or
    /// asking FOR media ("videos of nobody", "christmas videos") without a
    /// continuation lead.
    private static func readsAsSentence(_ scan: LeadScan) -> Bool {
        let residual = scan.residual
        if residual.contains(where: { sentenceVerbs.contains($0) }) { return true }
        if residual.contains(where: { $0.hasSuffix("'s") }) { return true }
        // "and her husband?" / "and his kids": a third-person pronoun with
        // anything beside it is a follow-up ABOUT the last answer's subject
        // (HalliePronounContinuity owns that), never a fragment refining the
        // last query. Before this rule (eval 2026-09-01) "her" was filler,
        // "husband" matched five tree people named Husband, and the graph
        // AST came out as people = ["husband"] relation = children.
        if residual.count >= 2,
           residual.contains(where: HalliePronounContinuity.isThirdPersonPronoun) { return true }
        if residual.count > (scan.hadLead ? 6 : 4) { return true }
        if !scan.explicit, residual.contains(where: { mediaNouns.contains($0) }) { return true }
        return false
    }

    /// Content groups split at filler boundaries: "with donna at the cape"
    /// → [donna] [cape]; "playing guitar" → [guitar]; "red bike" → [red bike].
    private static func contentGroups(_ words: [String]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        for word in words {
            if fragmentFiller.contains(word) {
                if !current.isEmpty { groups.append(current); current = [] }
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// "matt instead of donna" / "instead of donna" / "donna instead" →
    /// (new person words, old person words), or nil when there is no
    /// "instead". Consumes the whole remainder.
    private static func splitInstead(_ rest: inout [String]) -> (new: [String], old: [String])? {
        guard let index = rest.firstIndex(of: "instead") else { return nil }
        let new = Array(rest[..<index]).filter { !fragmentFiller.contains($0) }
        var after = Array(rest[(index + 1)...])
        if after.first == "of" { after.removeFirst() }
        let old = after.filter { !fragmentFiller.contains($0) }
        rest = []
        return (new, old)
    }

    private static func insteadChange(
        new: [String], old: [String], isKnownPerson: (String) -> Bool
    ) -> Change? {
        let newName = new.joined(separator: " ")
        let oldName = old.joined(separator: " ")
        let newKnown = !newName.isEmpty && isKnownPerson(newName)
        let oldKnown = !oldName.isEmpty && isKnownPerson(oldName)
        if newKnown { return .replacePerson(newName, of: oldKnown ? oldName : nil) }
        if oldKnown, newName.isEmpty { return .removePerson(oldName) }
        if !newName.isEmpty { return .replaceKeyword(newName) }
        return nil
    }

    private static func personChange(_ name: String, kind: LeadKind?) -> Change {
        switch kind {
        case .comparative?: return .replacePerson(name, of: nil)
        case .subtractive?: return .removePerson(name)
        default: return .addPerson(name)
        }
    }

    static func refinementResolution(
        _ rawWords: [String], snapshot: Snapshot?, isKnownPerson: (String) -> Bool
    ) -> Resolution? {
        let original = rawWords.joined(separator: " ")
        let scan = scanLeads(rawWords)

        // Nothing but filler ("ok", "and", "hmm?"): not a question at all.
        if scan.residual.allSatisfy({ fragmentFiller.contains($0) }) {
            return snapshot?.ast == nil ? .none : .declineUninterpretable(original)
        }
        if readsAsSentence(scan) { return nil }

        // Years first ("around 2005", "in the 90s", "1990 to 1995"), then an
        // age band ("as a baby"), then "instead", then whatever is left.
        var changes: [Change] = []
        var rest = scan.residual
        if let extracted = extractYears(from: rest) {
            changes.append(.years(extracted.range, label: extracted.label))
            rest = extracted.remaining
        }
        if let band = extractAgeBand(from: rest) {
            changes.append(.ageBand(keyword: band.keyword))
            rest = band.remaining
        }
        let instead = splitInstead(&rest)
        let groups = contentGroups(rest)

        // No previous question: a year alone or a bare topic word may still
        // be a fresh question for the translator; an explicit continuation
        // lead ("and …") is an honest decline. Name lookups cost identity
        // sources, so nothing below runs without something to refine.
        guard let snapshot, let ast = snapshot.ast else {
            return scan.explicit ? .declineNoPriorResult(nil) : .none
        }
        let listShape: Bool
        switch ast {
        case .presence, .cross, .event: listShape = true
        default: listShape = false
        }

        if let instead {
            guard let change = insteadChange(
                new: instead.new, old: instead.old, isKnownPerson: isKnownPerson)
            else { return .declineUninterpretable(original) }
            changes.append(change)
        }

        // People and topics. Without any lead, a person plus anything else
        // ("donna at christmas", "matt in 2005") is a fresh question.
        var people: [String] = []
        var topics: [String] = []
        for group in groups {
            let phrase = group.joined(separator: " ")
            if isKnownPerson(phrase) { people.append(phrase) } else { topics.append(phrase) }
        }
        if !scan.hadLead, !people.isEmpty, people.count + topics.count + changes.count > 1 {
            return nil
        }
        // For non-list shapes an unknown bare word without a lead is not
        // confidently a refinement (old behavior: let the translator decide).
        if !listShape, !scan.hadLead, !topics.isEmpty { return nil }

        changes.append(contentsOf: people.map { personChange($0, kind: scan.kind) })
        for topic in topics {
            switch scan.kind {
            case .comparative?: changes.append(.replaceKeyword(topic))
            case .subtractive?:
                return .declineNotRefinable(
                    reason: "I can only drop a person, not a topic word — ask it fresh")
            default: changes.append(.addKeyword(topic))
            }
        }
        guard !changes.isEmpty else { return .declineUninterpretable(original) }

        if listShape {
            return applyCumulative(changes, to: ast, previousChain: snapshot.chain)
        }
        return applyReplacement(changes[0], to: ast)
    }

    // MARK: Year and age extraction

    private static let decadeWords: [String: Int] = [
        "forties": 1940, "fifties": 1950, "sixties": 1960, "seventies": 1970,
        "eighties": 1980, "nineties": 1990, "aughts": 2000, "twenties": 2020,
        "40s": 1940, "50s": 1950, "60s": 1960, "70s": 1970, "80s": 1980,
        "90s": 1990, "00s": 2000, "10s": 2010, "20s": 2020,
        "1940s": 1940, "1950s": 1950, "1960s": 1960, "1970s": 1970,
        "1980s": 1980, "1990s": 1990, "2000s": 2000, "2010s": 2010,
        "2020s": 2020,
    ]
    private static let yearQualifiers: Set<String> = ["early", "mid", "late"]
    private static let yearConnectors: Set<String> = [
        "to", "through", "thru", "until", "till", "and", "or",
    ]

    private static func decade(_ word: String) -> Int? {
        decadeWords[word.replacingOccurrences(of: "'", with: "")]
    }

    private static func isYear(_ word: String) -> Bool {
        if let value = Int(word) { return ArchivistQueryAST.yearRange.contains(value) }
        return false
    }

    /// The first year phrase in the fragment, its label as said, and the
    /// words that remain. "around 2005" → 2004–2006 / "around 2005".
    static func extractYears(
        from words: [String]
    ) -> (range: ClosedRange<Int>, label: String, remaining: [String])? {
        guard let start = words.firstIndex(where: { isYear($0) || decade($0) != nil })
        else { return nil }
        var lower = start
        var group: [String] = []
        if lower > 0, yearQualifiers.contains(words[lower - 1]) {
            lower -= 1
        }
        var approx = false
        var approxIndex: Int?
        if lower > 0, approxWords.contains(words[lower - 1]) {
            approx = true
            approxIndex = lower - 1
        }
        group = Array(words[lower...start])
        var upper = start
        var index = start + 1
        while index < words.count {
            let word = words[index]
            if isYear(word) {
                group.append(word); upper = index; index += 1
            } else if yearConnectors.contains(word), index + 1 < words.count,
                      isYear(words[index + 1]) {
                group.append(word); group.append(words[index + 1])
                upper = index + 1; index += 2
            } else {
                break
            }
        }
        // Trailing "ish" / "or so": approximate.
        var trailing = upper
        if trailing + 1 < words.count, words[trailing + 1] == "ish" {
            approx = true; trailing += 1
        } else if trailing + 2 < words.count, words[trailing + 1] == "or",
                  words[trailing + 2] == "so" {
            approx = true; trailing += 2
        }
        guard var range = yearExpression(group) else { return nil }
        var label: String
        if range.lowerBound == range.upperBound {
            let year = range.lowerBound
            if approx {
                let bounds = ArchivistQueryAST.yearRange
                range = max(bounds.lowerBound, year - 1)...min(bounds.upperBound, year + 1)
                label = "around \(year)"
            } else {
                label = "\(year)"
            }
        } else {
            label = "\(range.lowerBound)–\(range.upperBound)"
        }
        var remaining: [String] = []
        for (position, word) in words.enumerated() {
            if position >= lower, position <= trailing { continue }
            if let approxIndex, position == approxIndex { continue }
            remaining.append(word)
        }
        return (range, label, remaining)
    }

    /// "as a baby" (alone or inside the fragment) → the age keyword the
    /// presence executor turns into a birth-year band, plus what remains.
    static func extractAgeBand(
        from words: [String]
    ) -> (keyword: String, remaining: [String])? {
        guard let index = words.firstIndex(where: { ArchivistAgePhrase.band(forWord: $0) != nil })
        else { return nil }
        let word = words[index]
        // Only the carriers leading into the band word belong to the phrase
        // ("as a", "when she was a"); the rest of the fragment is kept.
        var start = index
        while start > 0, ArchivistAgePhrase.isCarrier(words[start - 1]) { start -= 1 }
        let remaining = Array(words[..<start]) + Array(words[(index + 1)...])
        return ("as a \(word)", remaining)
    }

    /// Year phrases people actually say: "1994", "1990 to 1995", "the 90s",
    /// "1990s", "early 90s", "late eighties".
    static func yearExpression(_ words: [String]) -> ClosedRange<Int>? {
        var qualifier: String?
        var remaining = words
        if let first = remaining.first, yearQualifiers.contains(first) {
            qualifier = first
            remaining.removeFirst()
        }
        if remaining.count == 1, let decade = decade(remaining[0]) {
            switch qualifier {
            case "early": return decade...(decade + 3)
            case "mid": return (decade + 4)...(decade + 6)
            case "late": return (decade + 7)...(decade + 9)
            default: return decade...(decade + 9)
            }
        }
        let years = remaining.compactMap { Int($0) }
        guard qualifier == nil, !years.isEmpty,
              years.allSatisfy({ ArchivistQueryAST.yearRange.contains($0) })
        else { return nil }
        let others = remaining.filter { Int($0) == nil }
        guard others.allSatisfy(yearConnectors.contains) else { return nil }
        if years.count == 1 { return years[0]...years[0] }
        if years.count == 2, years[0] <= years[1] { return years[0]...years[1] }
        return nil
    }

    // MARK: Applying changes

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    /// Cumulative apply for list shapes. Adds AND onto the previous
    /// constraints; comparative changes swap the like field; the chain and
    /// the "what changed" lead are rebuilt so the answer can say so.
    /// The fields the list shapes share, lifted out so the cumulative apply
    /// is one loop over changes rather than three copies of it.
    private struct ListFields {
        var people: [String]
        var keywords: [String]
        var yearStart: Int?
        var yearEnd: Int?

        init?(_ ast: ArchivistQueryAST) {
            switch ast {
            case .presence(let p):
                self.init(p.people, p.keywords, p.yearStart, p.yearEnd)
            case .cross(let p):
                self.init(p.people, p.keywords, p.yearStart, p.yearEnd)
            case .event(let p):
                self.init(p.people, p.keywords, p.yearStart, p.yearEnd)
            default:
                return nil
            }
        }

        private init(_ people: [String]?, _ keywords: [String]?, _ start: Int?, _ end: Int?) {
            self.people = people ?? []
            self.keywords = keywords ?? []
            self.yearStart = start
            self.yearEnd = end
        }

        /// The same shape as `ast` with these fields written back.
        func written(into ast: ArchivistQueryAST) -> ArchivistQueryAST {
            let people = self.people.isEmpty ? nil : self.people
            let keywords = self.keywords.isEmpty ? nil : self.keywords
            switch ast {
            case .presence(var p):
                p.people = people; p.keywords = keywords
                p.yearStart = yearStart; p.yearEnd = yearEnd
                return .presence(p)
            case .cross(var p):
                p.people = people; p.keywords = keywords
                p.yearStart = yearStart; p.yearEnd = yearEnd
                return .cross(p)
            case .event(var p):
                p.people = people; p.keywords = keywords
                p.yearStart = yearStart; p.yearEnd = yearEnd
                return .event(p)
            default:
                return ast
            }
        }
    }

    static func applyCumulative(
        _ changes: [Change], to ast: ArchivistQueryAST, previousChain: Chain?
    ) -> Resolution {
        guard var fields = ListFields(ast) else {
            return applyReplacement(changes[0], to: ast)
        }
        var yearLabel: String? = previousChain?.yearLabel ?? Chain.base(for: ast).yearLabel

        for change in changes {
            switch change {
            case .years(let range, let label):
                fields.yearStart = range.lowerBound; fields.yearEnd = range.upperBound
                yearLabel = label
                // An explicit year replaces an earlier age band.
                fields.keywords.removeAll { ArchivistAgePhrase.detect(in: [$0]) != nil }
            case .ageBand(let keyword):
                fields.yearStart = nil; fields.yearEnd = nil
                yearLabel = keyword
                fields.keywords.removeAll { ArchivistAgePhrase.detect(in: [$0]) != nil }
                fields.keywords.append(keyword)
            case .addPerson(let name):
                if fields.people.contains(where: { sameName($0, name) }) {
                    return .declineNotRefinable(
                        reason: "\(Chain.capitalized(name)) is already part of the question")
                }
                fields.people.append(name)
            case .replacePerson(let name, let old):
                if let old, let index = fields.people.firstIndex(where: { sameName($0, old) }) {
                    fields.people[index] = name
                } else {
                    fields.people = [name]
                }
            case .removePerson(let name):
                guard fields.people.contains(where: { sameName($0, name) }) else {
                    return .declineNotRefinable(
                        reason: "\(Chain.capitalized(name)) isn't part of the question")
                }
                fields.people.removeAll { sameName($0, name) }
            case .addKeyword(let word):
                if fields.keywords.contains(where: { sameName($0, word) }) {
                    return .declineNotRefinable(
                        reason: "“\(word)” is already part of the question")
                }
                fields.keywords.append(word)
            case .replaceKeyword(let word):
                fields.keywords = [word]
            }
        }
        if fields.people.count > maxChainTerms || fields.keywords.count > maxChainTerms {
            return .declineNotRefinable(
                reason: "I can hold at most \(maxChainTerms) people and \(maxChainTerms) topics "
                + "in one question — say “start over” to begin again")
        }
        if fields.people.isEmpty, fields.keywords.isEmpty, fields.yearStart == nil, fields.yearEnd == nil {
            return .declineNotRefinable(reason: "that would leave nothing to search for")
        }
        let hasAgeBand = fields.keywords.contains { ArchivistAgePhrase.detect(in: [$0]) != nil }
        if fields.yearStart == nil, fields.yearEnd == nil, !hasAgeBand {
            yearLabel = nil
        }

        let refined = fields.written(into: ast)

        // Chain: previous terms that survived, in the order they were said,
        // then the new ones. Age keywords live in the year label, not terms.
        var spoken: [String] = []
        if case .cross(let p) = ast { spoken = p.transcript ?? [] }
        let live = (fields.people + fields.keywords + spoken)
            .filter { ArchivistAgePhrase.detect(in: [$0]) == nil }
        var terms = (previousChain?.terms ?? Chain.base(for: ast).terms).filter { term in
            live.contains { sameName($0, term) }
        }
        for term in live where !terms.contains(where: { sameName($0, term) }) {
            terms.append(term)
        }
        let chain = Chain(terms: terms, yearLabel: yearLabel)
        return .refine(refined, chain: chain, whatChanged: whatChanged(changes))
    }

    /// "Narrowed to Westford, around 2005" / "Added Donna; narrowed to guitar".
    static func whatChanged(_ changes: [Change]) -> String {
        var topics: [String] = []
        var times: [String] = []
        var others: [String] = []
        for change in changes {
            switch change {
            case .years(_, let label): times.append(label)
            case .ageBand(let keyword): times.append(keyword)
            case .addKeyword(let word): topics.append(Chain.capitalized(word))
            default: others.append(change.prose)
            }
        }
        var parts = others
        let narrowed = topics + times
        if !narrowed.isEmpty {
            let lead = parts.isEmpty ? "Narrowed to " : "narrowed to "
            parts.append(lead + narrowed.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    /// Single-field replacement for the non-list shapes (family tree, age,
    /// who-appears-with), where "and matt?" can only mean "matt instead".
    static func applyReplacement(_ change: Change, to ast: ArchivistQueryAST) -> Resolution {
        func person(_ change: Change) -> String? {
            switch change {
            case .addPerson(let name), .replacePerson(let name, _): return name
            default: return nil
            }
        }
        func years(_ change: Change) -> ClosedRange<Int>? {
            if case .years(let range, _) = change { return range }
            return nil
        }
        func done(_ refined: ArchivistQueryAST) -> Resolution {
            .refine(refined, chain: Chain.base(for: refined), whatChanged: change.prose)
        }
        switch ast {
        case .presence, .cross, .event:
            return applyCumulative([change], to: ast, previousChain: nil)

        case .graph(var payload):
            if let name = person(change) {
                payload.people = [name]
                payload.surname = nil
                return done(.graph(payload))
            }
            if years(change) != nil {
                return .declineNotRefinable(
                    reason: "a family-tree question doesn't take a year")
            }
            return .declineNotRefinable(
                reason: "a family-tree question doesn't take a topic word")

        case .temporal(var payload):
            if let name = person(change) {
                payload.subject = name
                return done(.temporal(payload))
            }
            if let range = years(change) {
                guard range.lowerBound == range.upperBound else {
                    return .declineNotRefinable(
                        reason: "an age question needs a single year")
                }
                payload.reference = .explicitYear(range.lowerBound)
                return done(.temporal(payload))
            }
            return .declineNotRefinable(
                reason: "an age question doesn't take a topic word")

        case .aggregate(var payload):
            if let name = person(change) {
                payload.anchorPeople = [name]
                return done(.aggregate(payload))
            }
            return .declineNotRefinable(
                reason: "a who-appears-with question only takes a person")

        case .record(var payload):
            // "and Donna?" after "is Rick in this video" — same record,
            // another name. Years and topic words have no place here.
            if let name = person(change) {
                payload.people = [name]
                payload.operations = [.people]
                return done(.record(payload))
            }
            return .declineNotRefinable(
                reason: "a question about one video only takes a person")
        }
    }
}
