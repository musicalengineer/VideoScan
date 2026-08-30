// HalliePronunciationHint.swift
// Descriptive pronunciation hints and pronunciation QUESTIONS (live misses
// #14/#15, Rick 2026-08-29):
//   "Latta should be pronounced with a short a on the La"
//   "Latta should be pronounced La (as in Lag) and Tah, so short a on Latta"
//   "tell me latta pronounciations" / "how do you say McGill?"
// Before this, all three fell through to a catalog SEARCH. A hint about a
// name the archive knows is never a search: it is mapped to a respelling
// deterministically where that is safe (short/long vowel on a syllable,
// stress on the nth syllable, explicit syllables with an "as in" exemplar,
// a silent letter, soft/hard g), and otherwise Hallie asks for it spelled
// out. A question is answered from the lexicon and the drill sheet.
//
// Pure text work, like HallieTellingMode+Pronunciation: no I/O, no model.
// The caller (coordinator / shell) decides whether the subject is a name
// the archive knows before treating a hint or question as such.

import Foundation
import VideoScanCore

// MARK: - Hint

enum HalliePronunciationHint: Equatable, Sendable {
    enum VowelLength: String, Equatable, Sendable { case short, long }
    enum Ordinal: String, Equatable, Sendable {
        case first, second, third, last
        var index: Int? {
            switch self {
            case .first: return 0
            case .second: return 1
            case .third: return 2
            case .last: return nil
            }
        }
    }
    /// One syllable as Rick spelled it, with the "(as in Lag)" exemplar.
    struct Syllable: Equatable, Sendable {
        let text: String
        let exemplar: String?
    }

    /// "short a on the La" / "long e" (no syllable named).
    case vowel(letter: Character, length: VowelLength, syllable: String?)
    /// "stress on the first syllable".
    case stress(Ordinal)
    /// "La (as in Lag) and Tah".
    case syllables([Syllable])
    /// "the t is silent".
    case silent(Character)
    /// "soft g" / "hard g".
    case softG, hardG
    /// "the a like in father".
    case vowelLike(letter: Character, exemplar: String)
    /// "rhymes with …" — never mapped; Hallie asks for a spelling.
    case rhymes(with: String)

    /// How the hint reads back in the confirmation ("short a on La").
    var description: String {
        switch self {
        case .vowel(let letter, let length, let syllable):
            return "\(length.rawValue) \(letter)" + (syllable.map { " on \($0)" } ?? "")
        case .stress(let ordinal):
            return "stress on the \(ordinal.rawValue) syllable"
        case .syllables(let parts):
            return parts.map { $0.text + ($0.exemplar.map { " (as in \($0))" } ?? "") }.joined(separator: " and ")
        case .silent(let letter):
            return "silent \(letter)"
        case .softG: return "soft g"
        case .hardG: return "hard g"
        case .vowelLike(let letter, let exemplar):
            return "\(letter) as in \(exemplar)"
        case .rhymes(let word):
            return "rhymes with \(word)"
        }
    }
}

/// One told hint: the name word (as typed) and the hint.
struct HalliePronunciationHintTelling: Equatable, Sendable {
    let word: String
    let hint: HalliePronunciationHint
}

extension HallieTellingMode {

    private static let nameGroup = #"([\p{L}'’-]{2,})"#
    private static let verbs = #"(?:\s+(?:is|should be|must be|has to be|ought to be|gets))?(?:\s+(?:pronounced|said|spoken))?"#

    /// Each pattern names its groups by order in `groups`.
    private struct HintPattern {
        enum Group { case name, length, letter, syllable, ordinal, syllables, exemplar, gHardness, rhyme }
        let regex: NSRegularExpression
        let groups: [Group]
        init(_ pattern: String, _ groups: [Group]) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.groups = groups
        }
    }

    private static let hintPatterns: [HintPattern] = [
        // "Latta should be pronounced La (as in Lag) and Tah, so short a on Latta"
        // Syllables are joined by "and"/"then" only: a hyphenated form
        // ("LAT-uh") is a respelling (detectPronunciation), and a comma
        // list would swallow "no, MahGill".
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+(?:as|like))?\s+((?:[A-Za-z]+(?:\s*\(as in [A-Za-z]+\))?)(?:(?:,?\s+and\s+|,?\s+then\s+)(?:[A-Za-z]+(?:\s*\(as in [A-Za-z]+\))?))+)(?:[,;]?\s*so\b.*)?[.!]?$"#,
            [.name, .syllables]),
        // "Latta should be pronounced with a short a on the La", "Latta has a long e"
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+(?:with|has|takes|uses|gets))?\s+(?:a |the )?(short|long)\s+([aeiou])(?:\s+(?:sound|vowel))?(?:\s+(?:on|in)\s+(?:the\s+)?(?:(?:first|second|third|last)\s+)?(?:syllable\s+)?["']?([A-Za-z]+)["']?)?[.!]?$"#,
            [.name, .length, .letter, .syllable]),
        // "the a in Latta is short"
        HintPattern(
            #"^the ([aeiou]) (?:in|of) "# + nameGroup + #" (?:is|sounds|should be) (short|long)[.!]?$"#,
            [.letter, .name, .length]),
        // "Latta with the stress on the first syllable", "stress the first syllable of Latta"
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+with)?\s+(?:the\s+)?(?:stress|accent|emphasis)\s+(?:on|is on)\s+(?:the\s+)?(first|second|third|last)(?:\s+syllable)?[.!]?$"#,
            [.name, .ordinal]),
        HintPattern(
            #"^(?:put the )?(?:stress|accent|emphasis|emphasize|stress on)\s+(?:on\s+)?(?:the\s+)?(first|second|third|last)\s+syllable\s+(?:of|in)\s+"# + nameGroup + #"[.!]?$"#,
            [.ordinal, .name]),
        // "the a in Latta is like in father", "Latta with the a as in father"
        HintPattern(
            #"^the ([aeiou]) (?:in|of) "# + nameGroup + #" (?:is|sounds|goes) (?:like|as)(?: in| the [aeiou] in)? ([A-Za-z]+)[.!]?$"#,
            [.letter, .name, .exemplar]),
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+with)?\s+(?:the\s+)?([aeiou])\s+(?:like|as)\s+in\s+([A-Za-z]+)[.!]?$"#,
            [.name, .letter, .exemplar]),
        // "the t in Latta is silent", "Latta has a silent t"
        HintPattern(
            #"^the ([a-z]) (?:in|of) "# + nameGroup + #" is silent[.!]?$"#,
            [.letter, .name]),
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+(?:with|has|takes))?\s+(?:a\s+)?silent\s+([a-z])[.!]?$"#,
            [.name, .letter]),
        // "McGill has a hard g", "the g in Gill is soft"
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + verbs + #"(?:\s+(?:with|has|takes|uses|gets))?\s+(?:a\s+|the\s+)?(soft|hard)\s+g[.!]?$"#,
            [.name, .gHardness]),
        HintPattern(
            #"^the g (?:in|of) "# + nameGroup + #" (?:is|sounds) (soft|hard)[.!]?$"#,
            [.name, .gHardness]),
        // "Latta rhymes with data"
        HintPattern(
            #"^(?:the (?:name|word) )?"# + nameGroup + #" rhymes with ([A-Za-z'’-]+)[.!]?$"#,
            [.name, .rhyme]),
    ]

    /// Words that are never the subject of a hint.
    private static let notHintSubjects: Set<String> = [
        "it", "that", "this", "the", "name", "word", "there", "here", "which", "what", "with",
    ]

    /// Detect a descriptive hint with its subject named. Nil for a plain
    /// respelling (detectPronunciation handles that), a question, or
    /// anything without a name.
    static func detectPronunciationHint(_ text: String) -> HalliePronunciationHintTelling? {
        let cleaned = HalliePronounceWords.normalize(text)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:hallie[,]?\s+)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty, !cleaned.hasSuffix("?") else { return nil }
        for pattern in hintPatterns {
            guard let match = pattern.regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else { continue }
            var values: [HintPattern.Group: String] = [:]
            for (at, group) in pattern.groups.enumerated() {
                guard let range = Range(match.range(at: at + 1), in: cleaned) else { continue }
                values[group] = String(cleaned[range])
            }
            guard let word = values[.name]?.trimmingCharacters(in: CharacterSet(charactersIn: "'\"-")),
                  !notHintSubjects.contains(word.lowercased()) else { continue }
            guard let hint = makeHint(values) else { continue }
            return HalliePronunciationHintTelling(word: word, hint: hint)
        }
        return nil
    }

    private static func makeHint(_ values: [HintPattern.Group: String]) -> HalliePronunciationHint? {
        if let raw = values[.syllables] {
            let parts = parseSyllables(raw)
            guard parts.count >= 2 else { return nil }
            return .syllables(parts)
        }
        if let length = values[.length].flatMap({ HalliePronunciationHint.VowelLength(rawValue: $0.lowercased()) }),
           let letter = values[.letter]?.lowercased().first {
            return .vowel(letter: letter, length: length, syllable: values[.syllable])
        }
        if let ordinal = values[.ordinal].flatMap({ HalliePronunciationHint.Ordinal(rawValue: $0.lowercased()) }) {
            return .stress(ordinal)
        }
        if let exemplar = values[.exemplar], let letter = values[.letter]?.lowercased().first {
            return .vowelLike(letter: letter, exemplar: exemplar.lowercased())
        }
        if let hardness = values[.gHardness] {
            return hardness.lowercased() == "soft" ? .softG : .hardG
        }
        if let rhyme = values[.rhyme] { return .rhymes(with: rhyme) }
        if let letter = values[.letter]?.lowercased().first { return .silent(letter) }
        return nil
    }

    /// "La (as in Lag) and Tah" → [La/Lag, Tah/nil].
    static func parseSyllables(_ raw: String) -> [HalliePronunciationHint.Syllable] {
        let pieces = raw.replacingOccurrences(of: #"\s*,?\s+and\s+|\s*,?\s+then\s+"#, with: "|",
                                              options: [.regularExpression, .caseInsensitive])
            .split(separator: "|")
        let exemplar = try! NSRegularExpression(pattern: #"^([A-Za-z]+)\s*(?:\(as in ([A-Za-z]+)\))?$"#, options: [.caseInsensitive])
        return pieces.compactMap { piece in
            let text = piece.trimmingCharacters(in: .whitespaces)
            guard let match = exemplar.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let syllableRange = Range(match.range(at: 1), in: text) else { return nil }
            let example = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            return .init(text: String(text[syllableRange]), exemplar: example)
        }
    }

    // MARK: Wording

    /// "OK, noted — Latta. From your hint (short a on La), I'll say Latta as
    /// LAT-uh from now on." plus where it was kept.
    static func hintReply(_ told: HalliePronunciationHintTelling, respelling: String, scope: PronunciationScope) -> String {
        let lead = pronunciationReadBack(told.word)
            + " From your hint (\(told.hint.description)), I'll say \(told.word) as \(respelling) from now on."
        switch scope {
        case .person(let name) where FamilyIdentityText.normalized(name) != FamilyIdentityText.normalized(told.word):
            return lead + " I've kept that with \(name)."
        case .person:
            return lead + " I've kept that on \(told.word)'s record."
        case .file:
            return lead + " I've kept that in the pronunciation list."
        }
    }

    static func transientHintReply(
        _ told: HalliePronunciationHintTelling,
        respelling: String
    ) -> String {
        pronunciationReadBack(told.word)
            + " From your hint (\(told.hint.description)), I'll say \(told.word) as \(respelling) from now on."
            + " I'll use that for this session only; run with --remember to save it."
    }

    /// A hint Hallie cannot turn into a spelling safely: ask, never search.
    static func hintNeedsSpellingReply(_ told: HalliePronunciationHintTelling) -> String {
        "I've noted \u{201C}\(told.hint.description)\u{201D} for \(told.word) — I'll offer you a few ways to say it next; for now, spell it out for me like \u{201C}LAT-uh\u{201D}?"
    }
}

// MARK: - Respelling from a hint

/// Turns a hint into a respelling deterministically, or declines (nil).
/// Syllables are found by a plain vowel-group split with the common
/// digraphs kept whole; that is enough for the family's names and is
/// never spoken as correct — Rick judges the read-back.
enum HalliePronunciationRespelling {

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private static let digraphs: Set<String> = ["th", "sh", "ch", "ph", "gh", "ck", "wh", "ng", "qu"]

    /// "Latta" → ["lat", "ta"]; "Edith" → ["e", "dith"]; "McGill" → ["mcgill"].
    static func syllables(_ name: String) -> [String] {
        let letters = Array(name.lowercased().filter { $0.isLetter })
        guard !letters.isEmpty else { return [] }
        func isVowel(_ at: Int) -> Bool {
            let c = letters[at]
            if c == "y" { return at > 0 }   // "y" is a vowel except word-initially
            return vowels.contains(c)
        }
        // Vowel-group ranges.
        var groups: [Range<Int>] = []
        var at = 0
        while at < letters.count {
            if isVowel(at) {
                let start = at
                while at < letters.count, isVowel(at) { at += 1 }
                groups.append(start..<at)
            } else { at += 1 }
        }
        guard groups.count > 1 else { return [String(letters)] }
        var out: [String] = []
        var start = 0
        for (index, group) in groups.enumerated() where index + 1 < groups.count {
            let next = groups[index + 1]
            let cluster = Array(letters[group.upperBound..<next.lowerBound])
            // Consonant units: digraphs whole, else single letters.
            var units: [String] = []
            var i = 0
            while i < cluster.count {
                if i + 1 < cluster.count, digraphs.contains(String(cluster[i...i + 1])) {
                    units.append(String(cluster[i...i + 1])); i += 2
                } else { units.append(String(cluster[i])); i += 1 }
            }
            // V-CV keeps one unit with the next syllable; VC-CV splits after
            // the first unit ("lat|ta", "mclaugh|lin").
            let keep = units.count <= 1 ? 0 : units[0].count
            let end = group.upperBound + keep
            out.append(String(letters[start..<end]))
            start = end
        }
        out.append(String(letters[start...]))
        return out
    }

    /// Nil when the hint cannot be mapped safely (rhymes-with, an unknown
    /// exemplar, a syllable Rick named that the name does not contain).
    static func respelling(
        for name: String,
        hint: HalliePronunciationHint,
        gold: MisakiGoldLexicon = .empty
    ) -> String? {
        var parts = syllables(name)
        guard !parts.isEmpty else { return nil }
        // After a "tt" split the second syllable would re-say the t: drop it.
        for index in 1..<max(parts.count, 1) where parts.count > 1 {
            if let last = parts[index - 1].last, parts[index].first == last, !vowels.contains(last) {
                parts[index] = String(parts[index].dropFirst())
            }
        }
        var stressed = 0
        switch hint {
        case .rhymes:
            return nil
        case .syllables(let given):
            let texts = given.map { $0.text.lowercased() }
            let at = given.firstIndex { $0.exemplar != nil } ?? 0
            return render(texts, stressed: at, schwaFinalA: false)
        case .stress(let ordinal):
            stressed = ordinal.index.map { min($0, parts.count - 1) } ?? (parts.count - 1)
        case .vowel(let letter, let length, let syllable):
            guard let at = syllableIndex(parts, named: syllable, vowel: letter) else { return nil }
            stressed = at
            var target = parts[at]
            guard let vowelAt = target.firstIndex(of: letter) else { return nil }
            switch length {
            case .short:
                // A short vowel wants a closed syllable: pull the next
                // syllable's opening consonant in ("na|tha" → "nath|a").
                if target.last.map({ vowels.contains($0) }) == true, at + 1 < parts.count,
                   let opener = parts[at + 1].first, !vowels.contains(opener) {
                    target.append(opener)
                    parts[at + 1] = String(parts[at + 1].dropFirst())
                }
            case .long:
                let spoken: String
                switch letter {
                case "a": spoken = "ay"
                case "e": spoken = "ee"
                case "i": spoken = "eye"
                case "o": spoken = "oh"
                default: spoken = "oo"
                }
                // A long vowel wants an open syllable: hand a closing
                // consonant to the next one ("lat|a" → "lay|ta").
                let tail = String(target[target.index(after: vowelAt)...])
                if !tail.isEmpty, at + 1 < parts.count {
                    parts[at + 1] = tail + parts[at + 1]
                    target = String(target[..<target.index(after: vowelAt)])
                }
                target.replaceSubrange(vowelAt...vowelAt, with: spoken)
            }
            parts[at] = target
        case .vowelLike(let letter, let exemplar):
            guard let at = syllableIndex(parts, named: nil, vowel: letter),
                  let sound = exemplarSound(exemplar, letter: letter, gold: gold) else { return nil }
            stressed = at
            switch sound {
            case .short:
                return respelling(
                    for: name, hint: .vowel(letter: letter, length: .short, syllable: nil), gold: gold)
            case .long:
                return respelling(
                    for: name, hint: .vowel(letter: letter, length: .long, syllable: nil), gold: gold)
            case .spelled(let text):
                var target = parts[at]
                guard let vowelAt = target.firstIndex(of: letter) else { return nil }
                target.replaceSubrange(vowelAt...vowelAt, with: text)
                parts[at] = target
            }
        case .silent(let letter):
            var joined = parts.joined(separator: "|")
            guard let at = joined.dropFirst().firstIndex(of: letter) else { return nil }
            joined.remove(at: at)
            parts = joined.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
        case .softG:
            parts = parts.map { $0.replacingOccurrences(of: "g", with: "j") }
        case .hardG:
            parts = parts.map { $0.replacingOccurrences(of: "ge", with: "ghe").replacingOccurrences(of: "gi", with: "ghi") }
        }
        return render(parts, stressed: stressed, schwaFinalA: true)
    }

    private enum ExemplarSound { case short, long, spelled(String) }

    /// The vowel sound of a well-known example word.
    private static func exemplarSound(
        _ exemplar: String,
        letter: Character,
        gold: MisakiGoldLexicon
    ) -> ExemplarSound? {
        let word = exemplar.lowercased()
        let ah: Set<String> = ["father", "palm", "calm", "spa", "ah", "car", "far", "bra"]
        let shortWords: Set<String> = ["cat", "hat", "bat", "lag", "bag", "bad", "apple", "man", "pat", "bed", "pet", "bit", "sit", "hit", "hot", "cot", "pot", "but", "cup", "cut"]
        let longWords: Set<String> = ["cake", "day", "late", "gate", "bay", "feet", "see", "me", "tree", "bite", "kite", "eye", "ice", "boat", "go", "no", "boot", "moon", "tune"]
        if ah.contains(word), letter == "a" { return .spelled("ah") }
        if shortWords.contains(word) { return .short }
        if longWords.contains(word) { return .long }
        // Beyond the table: misaki's gold lexicon when the helper is installed.
        guard let vowel = HalliePronunciationFreeform.exemplarVowel(word, gold: gold),
              let hint = HalliePronunciationFreeform.vowelSpelling(vowel, letter: letter) else { return nil }
        switch hint {
        case .vowel(_, .short, _): return .short
        case .vowel(_, .long, _): return .long
        case .vowelLike: return .spelled("ah")
        default: return nil
        }
    }

    /// The syllable Rick named ("La" → the one starting "la"), else the
    /// first syllable carrying the vowel.
    private static func syllableIndex(_ parts: [String], named: String?, vowel: Character) -> Int? {
        if let named = named?.lowercased(), !named.isEmpty {
            if let exact = parts.firstIndex(where: { $0.hasPrefix(named) || named.hasPrefix($0) }) { return exact }
            return nil
        }
        return parts.firstIndex { $0.contains(vowel) }
    }

    /// Stressed syllable in capitals, the rest lowercase, a final unstressed
    /// "a" said as "uh", hyphen-joined: ["lat","a"] stressed 0 → "LAT-uh".
    private static func render(_ parts: [String], stressed: Int, schwaFinalA: Bool) -> String {
        var out: [String] = []
        for (index, raw) in parts.enumerated() {
            var syllable = raw.lowercased()
            if schwaFinalA, index == parts.count - 1, index != stressed, syllable == "a" || (syllable.hasSuffix("a") && syllable.count > 1 && !syllable.hasSuffix("ah")) {
                syllable = String(syllable.dropLast()) + "uh"
            }
            out.append(index == stressed ? syllable.uppercased() : syllable)
        }
        return out.joined(separator: "-")
    }
}

// MARK: - Query

/// "how do you say McGill" / "tell me latta pronounciations" / "what
/// pronunciations do you have".
enum HalliePronunciationQuery: Equatable, Sendable {
    case name(String)
    case list

    /// "pronunciation", "pronounciation", "pronunciations", "pronunciaton"…
    private static let pronunciationWord = #"pron\w{3,}tions?"#

    private static let listPatterns: [NSRegularExpression] = [
        #"^(?:hallie[,]?\s+)?(?:what|which)\s+(?:names?\s+)?"# + pronunciationWord + #"\s+(?:do you|have you|did you)\s+(?:have|know|keep|learn|learned|been taught|got)(?:\s+so far)?\??$"#,
        #"^(?:hallie[,]?\s+)?(?:list|show|tell me|read me|give me|what are)\s+(?:all\s+|the\s+|your\s+|my\s+)?(?:taught\s+|known\s+)?"# + pronunciationWord + #"(?:\s+(?:you (?:have|know)|list|sheet))?\??$"#,
        #"^(?:hallie[,]?\s+)?(?:which|what)\s+names\s+(?:have i taught you|did i teach you|do you know how to say)\??$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let name = #"([\p{L}'’-]{2,})"#
    private static let namePatterns: [NSRegularExpression] = [
        // "how do you say McGill", "how is Latta pronounced", "how would you pronounce Latta"
        #"^(?:hallie[,]?\s+)?how\s+(?:do|would|will|should|did)\s+you\s+(?:say|pronounce)\s+(?:the (?:name|word)\s+)?"# + name + #"\??$"#,
        #"^(?:hallie[,]?\s+)?how\s+(?:is|do you say|are you saying|are you pronouncing)\s+(?:the (?:name|word)\s+)?"# + name + #"(?:\s+(?:pronounced|said))?\??$"#,
        // "tell me latta pronounciations", "tell me Latta's pronunciation", "what's the pronunciation of Latta"
        #"^(?:hallie[,]?\s+)?(?:tell me|show me|give me|what is|what's|whats|read me)\s+(?:the\s+|your\s+)?"# + name + #"(?:'s)?\s+"# + pronunciationWord + #"\??$"#,
        #"^(?:hallie[,]?\s+)?(?:tell me|show me|give me|what is|what's|whats)\s+(?:the\s+|your\s+)?"# + pronunciationWord + #"\s+(?:of|for)\s+(?:the (?:name|word)\s+)?"# + name + #"\??$"#,
        // "do you know how to say Latta", "do you have a pronunciation for Latta"
        #"^(?:hallie[,]?\s+)?do you (?:know how to (?:say|pronounce)|have a "# + pronunciationWord + #" for)\s+"# + name + #"\??$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func detect(_ text: String) -> HalliePronunciationQuery? {
        let cleaned = HalliePronounceWords.normalize(text)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        guard !cleaned.isEmpty else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for regex in listPatterns where regex.firstMatch(in: cleaned, range: range) != nil { return .list }
        for regex in namePatterns {
            guard let match = regex.firstMatch(in: cleaned, range: range),
                  let nameRange = Range(match.range(at: 1), in: cleaned) else { continue }
            let word = String(cleaned[nameRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"-"))
            guard !["it", "that", "this", "the", "name", "word", "names", "them"].contains(word.lowercased()) else { continue }
            return .name(word)
        }
        return nil
    }

    // MARK: Answers

    /// Where the lexicon entry came from, for the sentence.
    static func nameAnswer(
        word: String,
        entry: HalliePronunciationLexicon.Entry?,
        source: HalliePronunciationLexicon.Source?,
        taughtAt: Date?,
        now: Date = Date()
    ) -> String {
        guard let entry else {
            return "I don't have a note for \(word); I'd say it as Kokoro does — tell me how (\"pronounce \(word) like LAT-uh\")."
        }
        let alternatives = HalliePronunciationLexicon.alternatives(entry.spoken)
        let said = alternatives.count > 1
            ? "\(alternatives[0]) (or \(alternatives.dropFirst().joined(separator: " or ")))"
            : (alternatives.first ?? entry.spoken)
        let lead = entry.spoken == entry.written
            ? "I say \(entry.written) as it's spelled"
            : "I say \(entry.written) as \(said)"
        if let taughtAt {
            return lead + " — you taught me that \(whenLabel(taughtAt, now: now))."
        }
        switch source {
        case .person(_, let name): return lead + " — that's on \(name)'s record."
        case .file: return lead + " — that's in the pronunciation list."
        case .shipped: return lead + " — that's from my shipped list, not yet judged by you."
        case nil: return lead + "."
        }
    }

    static let listCap = 12

    static func listAnswer(lexicon: HalliePronunciationLexicon) -> String {
        let taught = lexicon.entries.filter { $0.spoken != $0.written }
            .sorted { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        guard !taught.isEmpty else {
            return "I don't have any taught pronunciations yet — tell me one (\"pronounce Latta like LAT-uh\") or say \"let's practice names\"."
        }
        let shown = taught.prefix(listCap).map { entry in
            "\(entry.written) as \(HalliePronunciationLexicon.alternatives(entry.spoken).first ?? entry.spoken)"
        }
        var text = "I have \(taught.count) taught pronunciation\(taught.count == 1 ? "" : "s"): " + shown.joined(separator: ", ")
        if taught.count > listCap { text += ", and \(taught.count - listCap) more" }
        return text + "."
    }

    /// "today (8/29)" / "on 8/26".
    static func whenLabel(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        let day = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today (\(day))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday (\(day))"
        }
        return "on \(day)"
    }

    static let basisLine = "Basis: pronunciation notes — the voice lexicon and the drill sheet; no model call, no catalog query."
}
