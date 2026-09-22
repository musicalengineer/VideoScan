// HallieTypoNormalizer.swift
// ONE deterministic front door for everyday typos, applied to the words a
// person typed before any pre-model lane reads them (Rick 2026-09-21).
//
// LIVE MISS (app, 2026-09-21 18:52): "Hi Hallie how areyou?" went to the
// translator — every small-talk table matches "how are you" by exact
// tokens, "areyou" is one token, so nothing fired — and came back as
// `catalog shape=presence keyword=hi keyword=how are you`: "687 videos
// matched: 25 shown where someone says “hi”…". A minute later "Hi Hallie
// how are you?" was fine. Rick's standing rule: a one-character slip is a
// defect in Hallie, not user error — his users are retirees typing
// casually.
//
// What it reads (and only from its closed tables, HallieTypoNormalizer+
// Lexicon.swift):
//   1. run-together pairs and missing apostrophes ("areyou", "whos",
//      "dont", "iam") and texting forms ("u", "ur", "r" beside a question
//      word, "pls", "thx");
//   2. stretched letters ("helllo", "hiii", "sooo");
//   3. a token that splits cleanly into two or three of Hallie's function
//      words ("whowas", "videosof");
//   4. ONE keyboard slip — a swapped pair, a dropped or extra letter, or a
//      neighbouring key — from exactly one word of Hallie's own command
//      vocabulary ("shwo" → "show", "vidoes" → "videos", "tel" → "tell").
//
// What it never touches: a known person's name, alias or surname (the
// injected oracle plus a built-in list of common given names — "Dan" is
// never "and", "Tim" never "time", "Ma" never "me"); a quoted phrase; a
// token with a digit or an apostrophe; a real English word from the
// common-word table ("fine" is not "find"); a capitalised word in the
// middle of a sentence (a typed name); any token of two letters or fewer
// for slip correction.
//
// The ORIGINAL text stays the transcript; the normalized text is what the
// routing lanes and the translator read. Untouched tokens are copied byte
// for byte, so capitalisation and punctuation survive for the lanes that
// read them (typed names, question marks, quotes).
//
// Cost: O(tokens × vocabulary) with a length pre-filter — a few
// microseconds per sentence, no allocation beyond the output string.
// Memory: the static tables (a few thousand short strings, well under
// 1 MB), built once.
//
// C++ analogy: a pure function over a `std::string_view`, with the name
// oracle passed as a `std::function<bool(std::string_view)>` so tests
// inject their own and nothing here reads disk.

import Foundation

enum HallieTypoNormalizer {
    struct Correction: Equatable, Sendable {
        enum Kind: String, Sendable {
            case runTogether, texting, repeatedLetters, split, slip, possessive
        }
        let original: String
        let replacement: String
        let kind: Kind
    }

    struct Result: Equatable, Sendable {
        let original: String
        let text: String
        let corrections: [Correction]

        var changed: Bool { !corrections.isEmpty }

        /// `[hallie-typo] read “areyou” as “are you”` — one line per turn,
        /// only when something changed, and no other text of the question.
        var logLine: String? {
            guard changed else { return nil }
            return "[hallie-typo] read " + corrections
                .map { "“\($0.original)” as “\($0.replacement)”" }
                .joined(separator: ", ")
        }
    }

    // MARK: - Entry point

    /// `isProtectedName` is asked only about a token that would otherwise
    /// be rewritten, so a clean sentence never consults it (the app loads
    /// identity sources lazily behind it).
    static func normalize(
        _ text: String,
        isProtectedName: (String) -> Bool = { _ in false }
    ) -> Result {
        let segments = tokenize(text)
        guard segments.contains(where: \.isWord) else {
            return Result(original: text, text: text, corrections: [])
        }
        let words = segments.indices.filter { segments[$0].isWord }
        var replaced: [Int: Correction] = [:]

        // A word glued to a dot on either side is part of a file name or
        // an abbreviation ("Christmas.mov", "Sr.", "e.g") — never a typo.
        func inFileName(_ index: Int) -> Bool {
            if index > 0, !segments[index - 1].isWord, segments[index - 1].text == "." { return true }
            if index + 2 < segments.count, segments[index + 1].text == ".", segments[index + 2].isWord { return true }
            return false
        }

        // Pass 1: every word on its own (with its neighbours for context).
        for (position, index) in words.enumerated() where !segments[index].quoted && !inFileName(index) {
            let previous = position > 0 ? segments[words[position - 1]].text.lowercased() : nil
            let next = position + 1 < words.count ? segments[words[position + 1]].text.lowercased() : nil
            if let fix = rewrite(
                segments[index].text, previous: previous, next: next,
                sentenceStart: isSentenceStart(segments, before: index),
                isProtectedName: isProtectedName) {
                replaced[index] = fix
            }
        }

        // Pass 2: a name's possessive typed without its apostrophe, read
        // against the CORRECTED neighbours ("donnas maidne name" → the
        // follower is "maiden" by now).
        func final(_ position: Int) -> String? {
            guard words.indices.contains(position) else { return nil }
            let index = words[position]
            let text = replaced[index]?.replacement ?? segments[index].text
            return text.split(separator: " ").first.map { $0.lowercased() }
        }
        for (position, index) in words.enumerated()
        where !segments[index].quoted && replaced[index] == nil && !inFileName(index) {
            if let fix = possessive(
                segments[index].text, previous: final(position - 1), next: final(position + 1),
                isProtectedName: isProtectedName) {
                replaced[index] = fix
            }
        }

        guard !replaced.isEmpty else {
            return Result(original: text, text: text, corrections: [])
        }
        var output = ""
        output.reserveCapacity(text.utf8.count + 16)
        for (index, segment) in segments.enumerated() {
            output += replaced[index]?.replacement ?? segment.text
        }
        let corrections = replaced.keys.sorted().compactMap { replaced[$0] }
        return Result(original: text, text: output, corrections: corrections)
    }

    // MARK: - One token

    static func rewrite(
        _ token: String,
        previous: String?,
        next: String?,
        sentenceStart: Bool,
        isProtectedName: (String) -> Bool
    ) -> Correction? {
        if token.contains(where: { $0 == "'" || $0 == "\u{2019}" }) {
            return rewriteContraction(token, sentenceStart: sentenceStart, isProtectedName: isProtectedName)
        }
        guard token.allSatisfy(\.isLetter) else { return nil }   // digits
        let lower = token.lowercased()
        let capitalisedMid = !sentenceStart && token.first?.isUppercase == true

        // A name is never rewritten. Asked lazily: only once a rewrite is
        // on the table.
        func protected() -> Bool {
            builtinProtectedNames.contains(lower) || isProtectedName(token)
        }
        func make(_ replacement: String, _ kind: Correction.Kind) -> Correction? {
            guard !protected() else { return nil }
            return Correction(original: token, replacement: matchCase(replacement, like: token), kind: kind)
        }

        // 1. Single-letter texting, lower-case only (a lone capital is an
        //    initial — "John R Smith" — never texting).
        switch token {
        case "u":
            return make("you", .texting)
        case "r":
            let beside = [previous, next].compactMap { $0 }
            return beside.contains(where: areNeighbours.contains) ? make("are", .texting) : nil
        case "ur":
            return make(youAreFollowers.contains(next ?? "") ? "you're" : "your", .texting)
        default:
            break
        }
        if lower.count == 1 { return nil }

        // 2. The fixed table.
        if let fixed = fixedRewrites[lower] {
            if capitalisedMid, nameLikeRewrites.contains(lower) { return nil }
            return make(fixed.text, fixed.kind)
        }

        // Real words, vocabulary words and split parts are left alone.
        if isKnownWord(lower) { return nil }
        // Any other real English word (the system word list, with simple
        // inflections) is left alone too: "taking" is not "talking".
        // Only a triple letter ("helllo") is read past it — no English
        // word has one.
        // A slip of a holiday people capitalise ("Chrismas") is read even
        // mid-sentence and even when the word list has an obscure match.
        if lower.count > 3, let word = uniqueSlipTarget(lower), capitalisedVocabulary.contains(word) {
            return make(word, .slip)
        }
        let realWord = HallieEnglishWords.contains(lower)

        // 4. A name glued to a function word: "isDonna", "Donnaborn".
        if realWord {
            guard hasTripleRun(lower), !capitalisedMid,
                  let collapsed = collapseRepeats(lower) else { return nil }
            if let fixed = fixedRewrites[collapsed] { return make(fixed.text, .repeatedLetters) }
            return make(collapsed, .repeatedLetters)
        }
        // A name part is a built-in given name, or a Capitalised part the
        // oracle knows — so a clean "Donna" never asks about "nna".
        if let parts = nameSplit(token, isName: {
            builtinProtectedNames.contains($0.lowercased())
                || ($0.first?.isUppercase == true && isProtectedName($0))
        }) {
            return protected() ? nil
                : Correction(original: token, replacement: parts.joined(separator: " "), kind: .split)
        }

        // A capitalised word mid-sentence is a typed name.
        if capitalisedMid { return nil }

        // 5. Stretched letters.
        if let collapsed = collapseRepeats(lower) {
            if let fixed = fixedRewrites[collapsed] { return make(fixed.text, .repeatedLetters) }
            return make(collapsed, .repeatedLetters)
        }

        // 6. A clean split into function words.
        if let parts = split(lower) {
            return make(parts.joined(separator: " "), .split)
        }

        // 7. One keyboard slip from exactly one vocabulary word.
        if lower.count >= 3, let word = uniqueSlipTarget(lower) {
            if let fixed = fixedRewrites[word] { return make(fixed.text, .slip) }
            return make(word, .slip)
        }
        return nil
    }

    /// "whos donnas mom" → "donna's", "who is Tims brother" → "Tim's":
    /// a token that is not a word, whose stem is a name, before a word
    /// that is not glue. Never after "the" ("the Breens" is the family).
    static func possessive(
        _ token: String, previous: String?, next: String?,
        isProtectedName: (String) -> Bool
    ) -> Correction? {
        let lower = token.lowercased()
        guard token.allSatisfy(\.isLetter), lower.count >= 4, lower.hasSuffix("s"),
              !isKnownWord(lower), fixedRewrites[lower] == nil,
              previous != "the", let next, next.first?.isLetter == true,
              !possessiveBlockers.contains(next) else { return nil }
        let stem = String(token.dropLast())
        guard builtinProtectedNames.contains(stem.lowercased()) || isProtectedName(stem),
              !isProtectedName(token) else { return nil }
        return Correction(original: token, replacement: stem + "'s", kind: .possessive)
    }

    /// Glue after which "Xs" stays as typed ("Tims at the beach").
    static let possessiveBlockers: Set<String> = [
        "at", "in", "on", "with", "from", "and", "or", "to", "for", "of", "by",
        "is", "are", "was", "were", "be", "been", "have", "has", "had", "do",
        "does", "did", "who", "what", "when", "where", "how", "why", "which",
        "that", "this", "the", "a", "an", "if", "but", "so", "too", "also",
        "i", "you", "he", "she", "we", "they", "it", "me", "him", "her", "us",
        "them", "not", "all", "both", "together", "please",
    ]

    /// A word with an apostrophe: "whaat's" → "what's", "tdoay's" →
    /// "today's", "isrick's" → "is rick's", "rick'sbrother" → "rick's
    /// brother". The head is read by the same rules; the tail is kept.
    static func rewriteContraction(
        _ token: String, sentenceStart: Bool, isProtectedName: (String) -> Bool
    ) -> Correction? {
        guard let mark = token.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) else { return nil }
        let head = String(token[..<mark])
        let tail = String(token[token.index(after: mark)...])
        let apostrophe = String(token[mark])
        guard !head.isEmpty, head.allSatisfy(\.isLetter), tail.allSatisfy(\.isLetter) else { return nil }
        let lowerTail = tail.lowercased()
        // "rick'sbrother": the space after the possessive was dropped.
        if lowerTail.count >= 3, lowerTail.hasPrefix("s") {
            let rest = String(tail.dropFirst())
            if isKnownWord(rest.lowercased()) {
                return Correction(original: token, replacement: head + apostrophe + "s " + rest, kind: .split)
            }
        }
        let contractionTails: Set<String> = ["s", "t", "re", "ve", "ll", "d", "m"]
        guard contractionTails.contains(lowerTail),
              !(lowerTail == "t" && contractionHeads.contains(head.lowercased())),
              let fix = rewrite(head, previous: nil, next: nil, sentenceStart: sentenceStart,
                                isProtectedName: isProtectedName),
              fix.kind != .runTogether, fix.kind != .texting,
              !fix.replacement.contains("'") else { return nil }
        return Correction(original: token, replacement: fix.replacement + apostrophe + tail, kind: fix.kind)
    }

    /// The part of an "n't" contraction before the apostrophe.
    static let contractionHeads: Set<String> = [
        "isn", "aren", "wasn", "weren", "don", "doesn", "didn", "can", "couldn",
        "won", "wouldn", "shouldn", "haven", "hasn", "hadn", "ain", "mustn",
        "needn", "mightn", "shan",
    ]

    /// Words after which "Xs" is "X's" when X is a name.
    static let possessionFollowers: Set<String> = HallieConversationGuard.treeCues
        .union(HallieModeClassifier.treeCues)
        .union(HallieMediaVocabulary.all)
        .union([
            "family", "tree", "birthday", "wedding", "house", "home", "life",
            "story", "side", "line", "kids", "friends", "friend", "age", "funeral",
            "grave", "name", "maiden", "first", "last", "middle", "best", "favorite",
            "favourite", "old", "new", "mom", "dad", "mother", "father", "husband",
            "wife", "brother", "sister", "sons", "daughters", "brothers", "sisters",
            "parents", "grandmother", "grandfather", "birth", "death", "job", "car",
            "dog", "graduation", "party", "christening", "baptism", "anniversary",
        ])

    // MARK: - Tables as predicates

    /// Every word that must be left exactly as typed.
    /// The words a one-slip misspelling may be read as: the hand-picked
    /// command vocabulary, a few short function words, and every word of
    /// four letters or more in the small-talk / help / reset tables.
    /// The fixed table's longer keys are slip targets too ("whts" →
    /// "whats" → "what's"); the caller maps them through the table.
    static let slipVocabulary: Set<String> = vocabulary
        .union(shortSlipVocabulary)
        .union(ArchivistConversationCommand.phraseVocabulary.filter { $0.count >= 4 })
        .subtracting(fixedRewrites.keys)
        .union(fixedRewrites.keys.filter { $0.count >= 4 })
        .subtracting(builtinProtectedNames)
        .subtracting(slipVocabularyExclusions)

    static let knownWords: Set<String> = {
        var words = commonWords
            .union(slipVocabulary)
            .union(ArchivistConversationCommand.phraseVocabulary)
            .union(ArchivistConversationCommand.everydayWords)
            .union(vocabulary)
            .union(splitParts)
            .union(HallieConversationGuard.catalogCues)
            .union(HallieConversationGuard.treeCues)
            .union(HallieSocialShapeGuard.reactionWords)
            .union(HallieSocialShapeGuard.fillerWords)
            .union(HallieGeneralKnowledgeLane.hardArchiveWords)
            .union(HallieMediaVocabulary.all)
            .union(HallieModeClassifier.treeCues)
            .union(HallieModeClassifier.catalogCues)
        // Simple inflections of the vocabulary ("shows", "tells", "played").
        for word in vocabulary {
            let suffixes = word.hasSuffix("s") ? ["ed", "ing"] : ["s", "es", "ed", "ing", "er", "ers"]
            for suffix in suffixes { words.insert(word + suffix) }
        }
        // …but never a key of the fixed table ("whats", "hows").
        words.subtract(fixedRewrites.keys)
        words.subtract(["u", "r", "ur"])
        return words
    }()

    static func isKnownWord(_ lower: String) -> Bool {
        knownWords.contains(lower)
    }

    // MARK: - Stretched letters

    /// Three of the same letter in a row — no English word has that.
    static func hasTripleRun(_ lower: String) -> Bool {
        let chars = Array(lower)
        guard chars.count >= 3 else { return false }
        return (2..<chars.count).contains { chars[$0] == chars[$0 - 1] && chars[$0] == chars[$0 - 2] }
    }

    /// "helllo" → "hello", "hiii" → "hi", "thankss" → "thanks". A triple
    /// run may land on any known word; a double only on the short social
    /// list (names are full of doubles).
    static func collapseRepeats(_ lower: String) -> String? {
        let chars = Array(lower)
        var runs: [(char: Character, length: Int)] = []
        for character in chars {
            if let last = runs.last, last.char == character {
                runs[runs.count - 1].length += 1
            } else {
                runs.append((character, 1))
            }
        }
        let repeated = runs.indices.filter { runs[$0].length >= 2 }
        guard !repeated.isEmpty, repeated.count <= 4 else { return nil }

        // Every choice of keeping 2 or 1 of each repeated run, doubles
        // first (so "goood" prefers "good" to "god").
        var best: String?
        let combinations = 1 << repeated.count
        for mask in 0..<combinations {
            var candidate = ""
            for (runIndex, run) in runs.enumerated() {
                if let slot = repeated.firstIndex(of: runIndex) {
                    let keepTwo = mask & (1 << slot) == 0
                    candidate += String(repeating: run.char, count: keepTwo ? 2 : 1)
                } else {
                    candidate += String(run.char)
                }
            }
            guard candidate != lower else { continue }
            // Any known word ("thhe" → "the", "hoow" → "how"). A name with
            // a double letter never gets here: the caller has already
            // left Capitalised words alone, and the oracle and the
            // built-in names protect "matt", "donna", "moore".
            let acceptable = isKnownWord(candidate) || fixedRewrites[candidate] != nil
            if acceptable { best = candidate; break }
        }
        return best
    }

    // MARK: - Run-together split

    /// Two parts, else three, every part a split word; exactly one way to
    /// do it or nothing ("i" may only lead).
    static func split(_ lower: String) -> [String]? {
        let chars = Array(lower)
        guard chars.count >= 4, chars.count <= 24 else { return nil }
        func part(_ from: Int, _ to: Int, first: Bool) -> String? {
            let text = String(chars[from..<to])
            if text == "i" { return first ? text : nil }
            guard text.count >= 2, splitParts.contains(text) else { return nil }
            return text
        }
        var twos: [[String]] = []
        for cut in 1..<chars.count {
            if let a = part(0, cut, first: true), let b = part(cut, chars.count, first: false) {
                twos.append([a, b])
            }
        }
        if twos.count == 1 { return twos[0] }
        guard twos.isEmpty else { return nil }
        var threes: [[String]] = []
        for cut1 in 1..<(chars.count - 1) {
            guard let a = part(0, cut1, first: true) else { continue }
            for cut2 in (cut1 + 1)..<chars.count {
                if let b = part(cut1, cut2, first: false), let c = part(cut2, chars.count, first: false) {
                    threes.append([a, b, c])
                }
            }
        }
        if threes.count == 1 { return threes[0] }
        guard threes.isEmpty else { return nil }
        // One function word and one of Hallie's own words: "mygrandfather",
        // "thewhole", "holdon", "hisspouse". Hallie's vocabulary only —
        // "island" is not "is land", "notice" not "not ice".
        var mixed: [[String]] = []
        for cut in 2..<(chars.count - 1) {
            let left = String(chars[..<cut]), right = String(chars[cut...])
            let leftPart = splitParts.contains(left), rightPart = splitParts.contains(right)
            if leftPart, right.count >= 3, hallieWords.contains(right) { mixed.append([left, right]) }
            else if rightPart, left.count >= 3, hallieWords.contains(left) { mixed.append([left, right]) }
        }
        return mixed.count == 1 ? mixed[0] : nil
    }

    /// Hallie's own words: the slip vocabulary, the split parts and every
    /// word of the phrase tables.
    static let hallieWords: Set<String> = slipVocabulary
        .union(splitParts)
        .union(ArchivistConversationCommand.phraseVocabulary)
        .subtracting(fixedRewrites.keys)

    // MARK: - One keyboard slip

    /// The one vocabulary word this token is a single slip from, or nil
    /// when there is none or more than one ("hwo": how or who?).
    ///
    /// Slips are ranked the way fingers make them — two letters swapped
    /// first, then a letter dropped, then a neighbouring key or an extra
    /// letter — and the best rank must be unique: "wehre" is "where" (a
    /// swap) rather than "were" (an extra letter); "sho" is "show" (a drop)
    /// rather than "who" (a neighbour).
    static func uniqueSlipTarget(_ lower: String) -> String? {
        var best: (word: String, rank: Int)?
        var tied = false
        let length = lower.count
        for word in slipVocabulary where abs(word.count - length) <= 1 {
            guard let rank = slipRank(lower, word) else { continue }
            if let current = best {
                if rank < current.rank { best = (word, rank); tied = false }
                else if rank == current.rank, current.word != word { tied = true }
            } else {
                best = (word, rank)
            }
        }
        return tied ? nil : best?.word
    }

    /// 0 = swapped pair, 1 = dropped letter, 2 = neighbouring key or an
    /// extra letter; nil = not one slip.
    static func slipRank(_ typed: String, _ word: String) -> Int? {
        guard isOneSlip(typed, word) else { return nil }
        let a = typed.count, b = word.count
        if a + 1 == b { return 1 }
        // An extra letter only onto a word of five letters or more: a
        // short word plus one letter is too often a name ("breen" is not
        // "been").
        if a == b + 1 { return b >= 5 ? 2 : nil }
        // Same length: a swap or a neighbouring key.
        let x = Array(typed), y = Array(word)
        let differing = x.indices.filter { x[$0] != y[$0] }
        return differing.count == 2 ? 0 : 2
    }

    /// A name glued to one function word, in either order ("isDonna",
    /// "Donnaborn" → "is Donna", "Donna born"). The name part keeps its
    /// case; it must be three letters or more and a name.
    static func nameSplit(_ token: String, isName: (String) -> Bool) -> [String]? {
        let chars = Array(token)
        guard chars.count >= 5, chars.count <= 24 else { return nil }
        var found: [String]?
        for cut in 2..<(chars.count - 1) {
            let left = String(chars[..<cut]), right = String(chars[cut...])
            if hallieWords.contains(left.lowercased()), right.count >= 3, isName(right) {
                guard found == nil else { return nil }
                found = [left, right]
            } else if hallieWords.contains(right.lowercased()), right.count >= 2,
                      left.count >= 3, isName(left) {
                guard found == nil else { return nil }
                found = [left, right]
            }
        }
        return found
    }

    /// True when `typed` is one slip from `word`: two neighbours swapped,
    /// one letter dropped, one letter added, or one letter replaced by a
    /// NEIGHBOURING key. (Plain edit distance would let "harry" become
    /// "marry"; a keyboard slip cannot.)
    static func isOneSlip(_ typed: String, _ word: String) -> Bool {
        let a = Array(typed), b = Array(word)
        if a == b { return false }
        if a.count == b.count {
            guard let i = a.indices.first(where: { a[$0] != b[$0] }) else { return false }
            if a[(i + 1)...] == b[(i + 1)...] {
                return areKeyboardNeighbours(a[i], b[i])
            }
            if i + 1 < a.count, a[i] == b[i + 1], a[i + 1] == b[i],
               a[(i + 2)...] == b[(i + 2)...] {
                return true
            }
            return false
        }
        if a.count == b.count + 1 {   // an extra letter typed
            let i = b.indices.first(where: { a[$0] != b[$0] }) ?? b.count
            return a[(i + 1)...] == b[i...]
        }
        if a.count + 1 == b.count {   // a letter dropped
            let i = a.indices.first(where: { a[$0] != b[$0] }) ?? a.count
            return a[i...] == b[(i + 1)...]
        }
        return false
    }

    private static let keyboardRows: [String] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// QWERTY neighbours: same row ±1, and the diagonal keys above/below.
    static func areKeyboardNeighbours(_ x: Character, _ y: Character) -> Bool {
        func position(_ c: Character) -> (row: Int, column: Double)? {
            for (row, keys) in keyboardRows.enumerated() {
                if let index = keys.firstIndex(of: c) {
                    // Each row sits half a key right of the one above.
                    return (row, Double(keys.distance(from: keys.startIndex, to: index)) + Double(row) * 0.5)
                }
            }
            return nil
        }
        guard let p = position(x), let q = position(y), x != y else { return false }
        if p.row == q.row { return abs(p.column - q.column) <= 1.0 }
        return abs(p.row - q.row) == 1 && abs(p.column - q.column) <= 0.5
    }

    // MARK: - Tokens

    struct Segment: Equatable {
        let text: String
        let isWord: Bool
        let quoted: Bool
    }

    /// Words are runs of letters and digits, with an apostrophe allowed
    /// between letters ("don't"). Everything else is copied as a separator.
    /// Text inside straight or curly double quotes is marked quoted.
    static func tokenize(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var separator = ""
        var quoted = false
        let chars = Array(text)
        func flushWord() {
            if !current.isEmpty { segments.append(Segment(text: current, isWord: true, quoted: quoted)) }
            current = ""
        }
        func flushSeparator() {
            if !separator.isEmpty { segments.append(Segment(text: separator, isWord: false, quoted: quoted)) }
            separator = ""
        }
        for (index, character) in chars.enumerated() {
            let isApostrophe = character == "'" || character == "\u{2019}"
            let inWordApostrophe = isApostrophe && !current.isEmpty
                && index + 1 < chars.count && chars[index + 1].isLetter
            if character.isLetter || character.isNumber || inWordApostrophe {
                flushSeparator()
                current.append(character)
                continue
            }
            flushWord()
            separator.append(character)
            if character == "\"" {
                flushSeparator()
                quoted.toggle()
            } else if character == "\u{201C}" {
                flushSeparator()
                quoted = true
            } else if character == "\u{201D}" {
                flushSeparator()
                quoted = false
            }
        }
        flushWord()
        flushSeparator()
        return segments
    }

    /// True when the word at `index` opens a sentence: nothing before it,
    /// or the last separator before it ends a sentence.
    static func isSentenceStart(_ segments: [Segment], before index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0 {
            let segment = segments[cursor]
            if segment.isWord { return false }
            if segment.text.contains(where: { ".!?\n".contains($0) }) { return true }
            cursor -= 1
        }
        return true
    }

    /// "Areyou" → "Are you", "AREYOU" → "ARE YOU", "areyou" → "are you".
    /// A replacement that carries its own capital ("I'm") keeps it.
    static func matchCase(_ replacement: String, like token: String) -> String {
        if token.count > 1, token.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return replacement.uppercased()
        }
        if token.first?.isUppercase == true, let first = replacement.first {
            return first.uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
