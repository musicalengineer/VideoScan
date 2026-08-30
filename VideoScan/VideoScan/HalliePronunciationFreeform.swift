// HalliePronunciationFreeform.swift
// Live miss #17 (Rick, 2026-08-29 17:35):
//   "Latta is prounounced like Ladder but with Laddah or Lattah short a
//    first ah second, like ladder but latt ah"
// fell through every pronunciation detector (the verb was misspelled, the
// cues were free-form) and reached the translator, which declined.
//
// Two things fix that class of miss:
//   1. Pronounce-words are read typo-tolerantly ("prounounced",
//      "pronounciation", "pronunced": edit distance ≤ 2 on the stem) and
//      normalised BEFORE the strict detectors run, so "Latta is prounounced
//      Lah-Tah" takes the same path as the correctly spelled sentence.
//   2. A free-form fallback: any sentence naming a name the archive knows
//      plus a pronounce-word is a TEACH (respellings and cues found) or a
//      QUERY (question shape) or, at worst, a kept hint with a request to
//      spell it out — never a search. Cues read: explicit respellings
//      ("Laddah or Lattah", "latt ah", "LAT-uh", "MahGill"), exemplars
//      ("like ladder", "as in lag", "rhymes with data"), vowel descriptions
//      ("short a first", "ah second", "stress on the first syllable").
//
// Choosing what to say when several respellings are offered is
// deterministic: explicit respellings beat exemplars beat descriptions;
// among respellings, the one the cues support best, then the one closest
// to the written name, then the first one Rick typed. All of them are
// kept. Pure text work: no I/O, no model. Like std::string algorithms in a
// header — the caller supplies `isKnownName`.

import Foundation
import VideoScanCore

// MARK: - Pronounce-words

enum HalliePronounceWords {

    /// Canonical spellings, each the target of a typo-tolerant match.
    static let canonical: [String] = [
        "pronounce", "pronounced", "pronounces", "pronouncing", "pronunciation", "pronunciations",
    ]

    /// The canonical form of a (possibly misspelled) pronounce-word, nil
    /// for any other word. Requires the "pro"/"pru" stem so a short common
    /// word can never be within two edits of one.
    static func canonicalForm(_ token: String) -> String? {
        let word = token.lowercased().filter(\.isLetter)
        guard word.count >= 8, word.hasPrefix("pro") || word.hasPrefix("pru") || word.hasPrefix("por"),
              word != "pronouns" else { return nil }
        var best: (String, Int)?
        for candidate in canonical {
            let distance = editDistance(word, candidate)
            if distance <= 2, distance < (best?.1 ?? Int.max) { best = (candidate, distance) }
        }
        return best?.0
    }

    static func isPronounceWord(_ token: String) -> Bool { canonicalForm(token) != nil }

    /// Rewrite every misspelled pronounce-word in `text` to its canonical
    /// spelling (case preserved for the first letter), leaving everything
    /// else byte-for-byte as typed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            if let canonical = canonicalForm(word), word.lowercased() != canonical {
                let capital = word.first?.isUppercase == true
                out += capital ? canonical.prefix(1).uppercased() + canonical.dropFirst() : canonical
            } else {
                out += word
            }
            word = ""
        }
        for character in text {
            if character.isLetter { word.append(character) } else { flush(); out.append(character) }
        }
        flush()
        return out
    }

    /// Levenshtein distance (the classic two-row DP).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

// MARK: - Free-form teach

/// What a free-form sentence taught, resolved.
struct HallieFreeformPronunciation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Respellings found (or derived from cues): teach them.
        case teach
        /// Question shape: answer from the lexicon.
        case query
        /// Nothing mappable: keep the raw hint, ask for a spelling.
        case hintOnly
    }
    let word: String
    let kind: Kind
    /// Every respelling, first = spoken. Empty for `.query` / `.hintOnly`.
    let alternatives: [String]
    /// The cues as Rick gave them, for the drill-sheet record ("like
    /// ladder; Laddah or Lattah; short a first, ah second").
    let rawHint: String
    /// A short read-back of the vowel cues ("short a, then ah"), nil when
    /// there were none.
    let cueSummary: String?
    /// Several respellings AND cues (or a cue the chosen one does not
    /// satisfy): the read-back says what was chosen and invites "no — …".
    let uncertain: Bool
    /// Rick typed the respellings (true) or Hallie derived them from cues.
    let explicit: Bool
}

enum HalliePronunciationFreeform {

    /// One parsed cue from the words around the pronounce-word.
    enum Cue: Equatable, Sendable {
        /// "short a first" / "long e on the La": length + letter + position.
        case vowel(letter: Character, length: HalliePronunciationHint.VowelLength, position: Int?)
        /// "ah second": a respelled vowel sound at a syllable position.
        case sound(String, position: Int?)
        /// "stress on the first syllable".
        case stress(Int)
        /// "like ladder" / "as in lag" / "rhymes with data".
        case exemplar(String)
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "been", "being", "it", "its", "it's", "that", "this", "with", "but",
        "and", "or", "so", "not", "no", "yes", "like", "as", "in", "on", "of", "to", "for", "you", "your", "i", "we",
        "my", "me", "should", "would", "could", "can", "must", "has", "have", "had", "gets", "get", "say", "said",
        "says", "saying", "spoken", "name", "word", "please", "hallie", "sound", "sounds", "vowel", "syllable",
        "syllables", "first", "second", "third", "last", "then", "next", "short", "long", "stress", "stressed",
        "accent", "emphasis", "silent", "soft", "hard", "rhymes", "rhyme", "more", "than", "just", "really", "kind",
        "sort", "bit", "way", "one", "two", "also", "too", "either", "both", "rather", "instead", "actually",
        "correctly", "properly", "right", "wrong", "wrongly", "how", "what", "which", "who", "why", "when", "where",
        "do", "does", "did", "tell", "show", "give", "will", "never", "always", "at", "by", "from", "into", "each",
        "all", "any", "some", "there", "here", "over", "under", "again", "still", "up", "out", "off",
    ]

    /// Tokens that spell a vowel sound on their own ("ah", "uh", "ay").
    static let vowelSounds: Set<String> = ["ah", "uh", "ay", "ee", "oh", "eye", "aw", "oo", "ih", "eh", "ow", "oy", "er"]

    private static let ordinals: [String: Int] = ["first": 0, "second": 1, "third": 2, "1st": 0, "2nd": 1, "3rd": 2]
    private static let questionOpeners: Set<String> = [
        "how", "what", "what's", "whats", "which", "do", "does", "did", "can", "could", "would", "will", "is", "are",
        "tell", "show", "give", "read",
    ]

    /// Well-known example words whose stressed vowel is fixed here so the
    /// answer never depends on the optional misaki bundle. Beyond this
    /// table, misaki's gold lexicon is consulted when installed.
    private static let exemplarVowels: [String: String] = [
        "ladder": "æ", "latter": "æ", "matter": "æ", "batter": "æ", "lag": "æ", "bag": "æ", "cat": "æ", "hat": "æ",
        "bat": "æ", "bad": "æ", "apple": "æ", "man": "æ", "pat": "æ", "data": "A", "day": "A", "cake": "A", "late": "A",
        "gate": "A", "bay": "A", "father": "ɑ", "palm": "ɑ", "calm": "ɑ", "spa": "ɑ", "car": "ɑ", "far": "ɑ",
        "bed": "ɛ", "pet": "ɛ", "feet": "i", "see": "i", "me": "i", "tree": "i", "green": "i", "bit": "ɪ", "sit": "ɪ",
        "hit": "ɪ", "gill": "ɪ", "bite": "I", "kite": "I", "eye": "I", "ice": "I", "hot": "ɑ", "cot": "ɑ", "pot": "ɑ",
        "boat": "O", "go": "O", "no": "O", "but": "ʌ", "cup": "ʌ", "cut": "ʌ", "boot": "u", "moon": "u", "tune": "u",
    ]

    /// The stressed vowel of an exemplar word (table, then the gold lexicon).
    static func exemplarVowel(
        _ word: String,
        gold: MisakiGoldLexicon = .empty
    ) -> String? {
        let key = word.lowercased().filter(\.isLetter)
        if let known = exemplarVowels[key] { return known }
        return HalliePhonemes.exemplarVowel(key, gold: gold)
    }

    /// A respelling spelling for a misaki vowel, used when a respelling is
    /// derived from an exemplar alone ("Latta like ladder" → LAT-uh).
    static func vowelSpelling(_ vowel: String, letter: Character) -> HalliePronunciationHint? {
        switch vowel {
        case "æ", "ɛ", "ɪ", "ʌ", "ʊ": return .vowel(letter: letter, length: .short, syllable: nil)
        case "A", "i", "I", "O", "u": return .vowel(letter: letter, length: .long, syllable: nil)
        case "ɑ": return letter == "a" ? .vowelLike(letter: "a", exemplar: "father") : .vowel(letter: letter, length: .short, syllable: nil)
        default: return nil
        }
    }

    // MARK: Detection

    /// Read a free-form sentence about how a name is said. Nil when it has
    /// no pronounce-word, no name `isKnownName` accepts, or is a plain
    /// respelling/hint the strict detectors already handle (callers run
    /// those first). `isKnownName` decides which token is the subject.
    static func detect(
        _ text: String,
        isKnownName: (String) -> Bool,
        gold: MisakiGoldLexicon = .empty
    ) -> HallieFreeformPronunciation? {
        let cleaned = HalliePronounceWords.normalize(
            text.replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?:hallie[,]?\s+)"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        guard !cleaned.isEmpty else { return nil }
        let rawTokens = cleaned.split(separator: " ").map(String.init)
        let tokens = rawTokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]")) }
        guard let verbAt = tokens.firstIndex(where: { HalliePronounceWords.isPronounceWord($0) }) else { return nil }

        // The subject: the first token (preferring those before the verb)
        // that the archive knows and is not a stop word.
        let order = Array(tokens.indices.filter { $0 < verbAt }) + Array(tokens.indices.filter { $0 > verbAt })
        guard let nameAt = order.first(where: { at in
            let token = tokens[at]
            return token.count >= 2 && token.first?.isLetter == true && !stopWords.contains(token.lowercased())
                && !HalliePronounceWords.isPronounceWord(token) && isKnownName(token)
        }) else { return nil }
        let word = tokens[nameAt]
        let nameKey = FamilyIdentityText.normalized(word)

        let isQuestion = cleaned.hasSuffix("?") || questionOpeners.contains(tokens.first?.lowercased() ?? "")

        // The rest: everything but the subject and the pronounce-words.
        var rest: [String] = []
        for (at, token) in tokens.enumerated() where at != nameAt && !HalliePronounceWords.isPronounceWord(token) && !token.isEmpty {
            rest.append(token)
        }
        var scanner = CueScanner(rest: rest, word: word, nameKey: nameKey, gold: gold)
        scanner.scan()
        let cues = scanner.cues
        let respellings = scanner.respellings

        return resolve(
            word: word, nameKey: nameKey, rest: rest, cues: cues,
            respellings: respellings, isQuestion: isQuestion, gold: gold)
    }

    /// Question shape → query; typed respellings → teach (ranked); cues
    /// alone → a derived respelling, else a kept hint.
    private static func resolve(
        word: String, nameKey: String, rest: [String], cues: [Cue],
        respellings: [String], isQuestion: Bool, gold: MisakiGoldLexicon
    ) -> HallieFreeformPronunciation {
        let rawHint = rest.joined(separator: " ")
        if isQuestion, respellings.isEmpty {
            return HallieFreeformPronunciation(word: word, kind: .query, alternatives: [], rawHint: rawHint,
                                               cueSummary: nil, uncertain: false, explicit: false)
        }
        // Rick's own spellings, de-duplicated by their letters.
        var seen: Set<String> = []
        var explicit: [String] = []
        for spelling in respellings {
            let key = spelling.lowercased().filter(\.isLetter)
            guard !key.isEmpty, key != nameKey, !seen.contains(key) else { continue }
            seen.insert(key)
            explicit.append(spelling)
        }
        let summary = cueSummary(cues)
        if !explicit.isEmpty {
            let canonical = cues.isEmpty ? explicit : explicit.map { canonicalRespelling($0, cues: cues) }
            let ranked = rank(canonical, cues: cues, nameKey: nameKey, gold: gold)
            let uncertain = canonical.count > 1 && !cues.isEmpty
                || (ranked.first.map {
                    support($0, cues: cues, gold: gold) < cueCount(cues, gold: gold)
                } ?? false)
            return HallieFreeformPronunciation(word: word, kind: .teach, alternatives: ranked, rawHint: rawHint,
                                               cueSummary: summary, uncertain: uncertain, explicit: true)
        }
        // No respelling typed: derive one from the cues where that is safe.
        if let derived = deriveRespelling(for: word, cues: cues, gold: gold) {
            return HallieFreeformPronunciation(word: word, kind: .teach, alternatives: [derived], rawHint: rawHint,
                                               cueSummary: summary, uncertain: false, explicit: false)
        }
        return HallieFreeformPronunciation(word: word, kind: .hintOnly, alternatives: [], rawHint: rawHint,
                                           cueSummary: summary, uncertain: false, explicit: false)
    }

    /// One left-to-right pass over the words around the pronounce-word.
    /// Each `scan…` consumes what it recognises and returns true.
    private struct CueScanner {
        let rest: [String]
        let word: String
        let nameKey: String
        let gold: MisakiGoldLexicon
        var cues: [Cue] = []
        var respellings: [String] = []
        var at = 0
        /// Position (in `rest`) of the last respelling token, so "latt ah"
        /// folds into one respelling.
        var respellingsEndAt = -1

        init(
            rest: [String],
            word: String,
            nameKey: String,
            gold: MisakiGoldLexicon
        ) {
            self.rest = rest
            self.word = word
            self.nameKey = nameKey
            self.gold = gold
        }

        func lower(_ i: Int) -> String? { i < rest.count ? rest[i].lowercased() : nil }

        mutating func scan() {
            while at < rest.count {
                if scanExemplar() || scanVowel() || scanSound() || scanStress() { continue }
                scanRespelling()
                at += 1
            }
        }

        /// "like X" / "as in X" / "rhymes with X" / "sounds like X".
        private mutating func scanExemplar() -> Bool {
            let low = rest[at].lowercased()
            var exemplarAt: Int?
            if low == "like" || low == "unlike" { exemplarAt = at + 1 }
            else if low == "as", lower(at + 1) == "in" { exemplarAt = at + 2 }
            else if low == "rhymes", lower(at + 1) == "with" { exemplarAt = at + 2 }
            else if low == "sounds", lower(at + 1) == "like" { exemplarAt = at + 2 }
            guard let exemplarAt, exemplarAt < rest.count else { return false }
            var candidate = rest[exemplarAt]
            var consumed = exemplarAt
            if ["the", "in"].contains(candidate.lowercased()), exemplarAt + 1 < rest.count {
                candidate = rest[exemplarAt + 1]; consumed = exemplarAt + 1
            }
            let candidateLow = candidate.lowercased()
            if looksLikeExplicitRespelling(candidate)
                || (isRespellingCandidate(candidate, nameKey: nameKey)
                    && exemplarVowel(candidate, gold: gold) == nil) {
                respellings.append(candidate)
            } else if low != "unlike", !stopWords.contains(candidateLow), candidate.first?.isLetter == true,
                      !cues.contains(.exemplar(candidateLow)) {
                cues.append(.exemplar(candidateLow))
            }
            at = consumed + 1
            return true
        }

        /// "short a first" / "long e on the La" / "short a on the first syllable".
        private mutating func scanVowel() -> Bool {
            let low = rest[at].lowercased()
            guard low == "short" || low == "long", let letter = lower(at + 1), letter.count == 1, "aeiou".contains(letter) else { return false }
            let length: HalliePronunciationHint.VowelLength = low == "short" ? .short : .long
            var position: Int?
            var consumed = at + 1
            var look = at + 2
            while look < rest.count, ["on", "in", "the", "sound", "vowel", "syllable", "for"].contains(rest[look].lowercased()) { look += 1 }
            if look < rest.count, let ordinal = ordinals[rest[look].lowercased()] {
                position = ordinal; consumed = look
                if look + 1 < rest.count, rest[look + 1].lowercased() == "syllable" { consumed = look + 1 }
            } else if look < rest.count, let index = syllablePosition(named: rest[look], of: word),
                      ["on", "in", "the"].contains(rest[look - 1].lowercased()) {
                position = index; consumed = look
            }
            cues.append(.vowel(letter: Character(letter), length: length, position: position))
            at = consumed + 1
            return true
        }

        /// "ah second" / "second ah" / "then ah" — or the second half of
        /// "latt ah", which folds into the respelling before it.
        private mutating func scanSound() -> Bool {
            let token = rest[at]
            let low = token.lowercased()
            guard vowelSounds.contains(low) else { return false }
            var position: Int?
            var consumed = at
            if let ordinal = lower(at + 1).flatMap({ ordinals[$0] }) { position = ordinal; consumed = at + 1 }
            else if at > 0, let ordinal = ordinals[rest[at - 1].lowercased()] { position = ordinal }
            else if at > 0, rest[at - 1].lowercased() == "then" { position = 1 }
            if let last = respellings.last, respellingsEndAt == at - 1, !last.contains("-"), position == nil {
                respellings[respellings.count - 1] = last + "-" + token
                respellingsEndAt = at
            } else {
                cues.append(.sound(low, position: position))
            }
            at = consumed + 1
            return true
        }

        /// "stress on the first syllable" / "accent on the second".
        private mutating func scanStress() -> Bool {
            guard ["stress", "stressed", "accent", "emphasis", "emphasize", "emphasise"].contains(rest[at].lowercased()) else { return false }
            var look = at + 1
            while look < rest.count, ["on", "is", "the", "goes", "falls"].contains(rest[look].lowercased()) { look += 1 }
            guard look < rest.count, let ordinal = ordinals[rest[look].lowercased()] else { return false }
            cues.append(.stress(ordinal))
            at = look + (look + 1 < rest.count && rest[look + 1].lowercased() == "syllable" ? 2 : 1)
            return true
        }

        /// An explicit respelling, or a word close enough to the name to be
        /// one ("Laddah", "Lattah", "latt").
        private mutating func scanRespelling() {
            let token = rest[at]
            let low = token.lowercased()
            guard !stopWords.contains(low), ordinals[low] == nil,
                  looksLikeExplicitRespelling(token) || isRespellingCandidate(token, nameKey: nameKey) else { return }
            respellings.append(token)
            respellingsEndAt = at
        }
    }

    /// Hyphenated ("LAT-uh"), CamelCase ("MahGill") or all-caps-syllable
    /// ("LAT") spellings are respellings whatever the name.
    static func looksLikeExplicitRespelling(_ token: String) -> Bool {
        let letters = token.filter { $0.isLetter || $0 == "-" }
        guard letters.count >= 2, letters.allSatisfy({ $0.isLetter || $0 == "-" }) else { return false }
        if letters.contains("-"), letters.first != "-", letters.last != "-" { return true }
        var previous: Character?
        for character in letters {
            if let previous, previous.isLowercase, character.isUppercase { return true }
            previous = character
        }
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// A plain word close enough to the name's letters to be a respelling
    /// of it: same first letter, edit distance within 60 % of the name.
    static func isRespellingCandidate(_ token: String, nameKey: String) -> Bool {
        let key = token.lowercased().filter(\.isLetter)
        guard key.count >= 2, key.allSatisfy(\.isLetter), !nameKey.isEmpty, key.first == nameKey.first else { return false }
        if key == nameKey { return false }
        let budget = Int((Double(nameKey.count) * 0.6).rounded(.up))
        return HalliePronounceWords.editDistance(key, nameKey) <= budget
    }

    /// The syllable index Rick named ("La" → 0 in Latta), nil if none fits.
    private static func syllablePosition(named: String, of name: String) -> Int? {
        let key = named.lowercased().filter(\.isLetter)
        guard key.count >= 2 else { return nil }
        return HalliePronunciationRespelling.syllables(name).firstIndex { $0.hasPrefix(key) || key.hasPrefix($0) }
    }

    // MARK: Resolution

    /// "Lattah" → "LAT-tah": a plain spelling split into syllables with
    /// the stress cue applied (first syllable by default); a spelling Rick
    /// already marked up (hyphen / caps) is kept as typed.
    static func canonicalRespelling(_ spelling: String, cues: [Cue]) -> String {
        let stress = cues.compactMap { cue -> Int? in if case .stress(let at) = cue { return at }; return nil }.first ?? 0
        if spelling.contains("-") {
            var parts = spelling.split(separator: "-").map(String.init)
            let marked = parts.contains { $0.count >= 2 && $0.allSatisfy(\.isUppercase) }
            if marked { return spelling }
            // "latt-uh": a doubled consonant closing a syllable before a
            // vowel-led one is one sound → "LAT-uh".
            for index in parts.indices.dropLast() {
                let letters = Array(parts[index].lowercased())
                if letters.count >= 3, letters[letters.count - 1] == letters[letters.count - 2],
                   !"aeiou".contains(letters[letters.count - 1]),
                   let next = parts[index + 1].lowercased().first, "aeiou".contains(next) {
                    parts[index] = String(parts[index].dropLast())
                }
            }
            return parts.enumerated().map { $0.offset == min(stress, parts.count - 1) ? $0.element.uppercased() : $0.element.lowercased() }.joined(separator: "-")
        }
        if looksLikeExplicitRespelling(spelling) { return spelling }
        let parts = HalliePronunciationRespelling.syllables(spelling)
        guard parts.count > 1 else { return spelling.uppercased() }
        let at = min(stress, parts.count - 1)
        return parts.enumerated().map { $0.offset == at ? $0.element.uppercased() : $0.element }.joined(separator: "-")
    }

    private static func cueCount(
        _ cues: [Cue],
        gold: MisakiGoldLexicon
    ) -> Int {
        cues.filter {
            if case .exemplar = $0 {
                return exemplarVowel(exemplarWord($0)!, gold: gold) != nil
            }
            return true
        }.count
    }

    private static func exemplarWord(_ cue: Cue) -> String? {
        if case .exemplar(let word) = cue { return word }
        return nil
    }

    /// How many cues a respelling satisfies.
    static func support(
        _ respelling: String,
        cues: [Cue],
        gold: MisakiGoldLexicon = .empty
    ) -> Int {
        let syllables = respelling.split(whereSeparator: { $0 == "-" || $0 == " " }).map { $0.lowercased() }
        guard !syllables.isEmpty else { return 0 }
        var score = 0
        for cue in cues {
            switch cue {
            case .vowel(let letter, let length, let position):
                let syllable = syllables[min(position ?? 0, syllables.count - 1)]
                guard let vowelAt = syllable.firstIndex(of: letter) else { continue }
                let after = syllable[syllable.index(after: vowelAt)...]
                let closed = after.first.map { !"aeiouhy".contains($0) } ?? false
                let spelledLong = after.hasPrefix("y") || after.hasPrefix("e") || after.hasPrefix("i")
                if (length == .short && closed) || (length == .long && (spelledLong || after.isEmpty)) { score += 1 }
            case .sound(let sound, let position):
                if let position, position < syllables.count {
                    if syllables[position].contains(sound) { score += 1 }
                } else if syllables.contains(where: { $0.contains(sound) }) { score += 1 }
            case .stress(let at):
                let stressed = syllables.firstIndex { $0.uppercased() == $0 && $0.count >= 2 }
                if stressed == nil ? at == 0 : stressed == at { score += 1 }
            case .exemplar(let word):
                guard let vowel = exemplarVowel(word, gold: gold),
                      let phones = HalliePhonemes.derive(respelling: respelling),
                      let first = HalliePhonemes.stressedVowel(in: phones) else { continue }
                if first == vowel { score += 1 }
            }
        }
        return score
    }

    /// With cues: best-supported first, then nearest the written name,
    /// then as typed. Without cues: as typed — the first one is spoken,
    /// the rule every other teach follows ("MahGill or MicGill").
    static func rank(
        _ respellings: [String],
        cues: [Cue],
        nameKey: String,
        gold: MisakiGoldLexicon = .empty
    ) -> [String] {
        guard !cues.isEmpty else { return respellings }
        return respellings.enumerated().sorted { a, b in
            let sa = support(a.element, cues: cues, gold: gold)
            let sb = support(b.element, cues: cues, gold: gold)
            if sa != sb { return sa > sb }
            let da = HalliePronounceWords.editDistance(a.element.lowercased().filter(\.isLetter), nameKey)
            let db = HalliePronounceWords.editDistance(b.element.lowercased().filter(\.isLetter), nameKey)
            if da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// From cues alone: one vowel/stress cue or one exemplar maps through
    /// the existing hint path; anything else is left for Rick to spell.
    static func deriveRespelling(
        for name: String,
        cues: [Cue],
        gold: MisakiGoldLexicon = .empty
    ) -> String? {
        let hints: [HalliePronunciationHint] = cues.compactMap { cue in
            switch cue {
            case .vowel(let letter, let length, let position):
                let syllables = HalliePronunciationRespelling.syllables(name)
                let named = position.flatMap { $0 < syllables.count ? syllables[$0] : nil }
                return .vowel(letter: letter, length: length, syllable: named)
            case .stress(let at):
                return .stress(at == 0 ? .first : at == 1 ? .second : .third)
            case .exemplar(let word):
                guard let vowel = exemplarVowel(word, gold: gold),
                      let letter = name.lowercased().first(where: { "aeiou".contains($0) }) else { return nil }
                return vowelSpelling(vowel, letter: letter)
            case .sound:
                return nil
            }
        }
        // A vowel/stress description beats an exemplar; use the first of each.
        let preferred = hints.first { if case .vowel = $0 { return true }; if case .stress = $0 { return true }; return false }
            ?? hints.first
        guard let hint = preferred,
              var respelling = HalliePronunciationRespelling.respelling(
                for: name, hint: hint, gold: gold) else { return nil }
        // "ah second": a positioned sound rewrites that syllable's vowel.
        for cue in cues {
            guard case .sound(let sound, let position?) = cue else { continue }
            var parts = respelling.split(separator: "-").map(String.init)
            guard position < parts.count else { continue }
            let part = parts[position]
            let isUpper = part == part.uppercased()
            if let vowelAt = part.lowercased().firstIndex(where: { "aeiou".contains($0) }) {
                let consonants = String(part[..<vowelAt])
                parts[position] = isUpper ? (consonants + sound).uppercased() : consonants + sound
                respelling = parts.joined(separator: "-")
            }
        }
        return respelling
    }

    /// "short a, then ah" — the vowel/stress descriptions in order, for the
    /// read-back; the exemplar only when that is all there was.
    static func cueSummary(_ cues: [Cue]) -> String? {
        var pieces: [String] = cues.compactMap { cue in
            switch cue {
            case .vowel(let letter, let length, _): return "\(length.rawValue) \(letter)"
            case .sound(let sound, _): return sound
            case .stress(let at): return "stress on the \(["first", "second", "third"][min(at, 2)])"
            case .exemplar: return nil
            }
        }
        if pieces.isEmpty {
            pieces = cues.compactMap { if case .exemplar(let word) = $0 { return "like \(word)" }; return nil }
        }
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 { return pieces[0] }
        return pieces.dropLast().joined(separator: ", ") + ", then " + pieces.last!
    }

    // MARK: Wording

    /// The read-back for a free-form teach. Uncertain (several respellings
    /// plus cues): "OK, noted — Latta. I'll say LAT-tah (short a, then ah)
    /// and keep LAD-dah too. Say 'no — …' if that's off." Plain
    /// alternatives: "OK, noted — Latta. I'll say Lattah and keep Laddah
    /// too." One respelling: the ordinary "I'll say Latta as X from now on."
    static func teachReply(_ told: HallieFreeformPronunciation, scope: HallieTellingMode.PronunciationScope) -> String {
        guard let spoken = told.alternatives.first else { return HallieTellingMode.pronunciationReadBack(told.word) }
        let cue = told.cueSummary.map { " (\($0))" } ?? ""
        var text = HallieTellingMode.pronunciationReadBack(told.word)
        if told.alternatives.count > 1 {
            text += " I'll say \(spoken)\(cue) and keep \(told.alternatives.dropFirst().joined(separator: " and ")) too."
            if told.uncertain { text += " Say 'no — …' if that's off." }
        } else {
            text += " I'll say \(told.word) as \(spoken)\(cue) from now on."
        }
        switch scope {
        case .person(let name) where FamilyIdentityText.normalized(name) != FamilyIdentityText.normalized(told.word):
            return text + " I've kept that with \(name)."
        case .person:
            return text + " I've kept that on \(told.word)'s record."
        case .file:
            return text + " I've kept that in the pronunciation list."
        }
    }

    /// Nothing mappable: the raw hint is kept; ask for a spelling.
    static func hintOnlyReply(_ told: HallieFreeformPronunciation) -> String {
        "I've noted what you said about \(told.word) — spell it out for me like \u{201C}LAT-uh\u{201D} and I'll say it that way?"
    }
}
