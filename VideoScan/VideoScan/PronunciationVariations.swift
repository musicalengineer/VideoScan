// PronunciationVariations.swift
// "Maybe we need her to say Latta a few different ways until she gets it
// right and I click on the correct one" (Rick, 2026-08-29). This is the
// candidate generator behind that picker — docs/
// pronunciation_training_research.md §2.1 and §5 Phase 1: a hand-built
// variant expander over misaki's vowel set, no model, no I/O beyond an
// optional read of misaki's own gold lexicon for "as in <word>" exemplars.
//
// For a name it produces a RANKED list of distinct pronunciations, each as
//   - misaki phonemes ("lˈætə") — what Kokoro is told, via `[Latta](/lˈætə/)`,
//   - a display respelling ("LAT-uh") — what the chip shows,
//   - a short label ("short a, stress on the 1st") — why it is on the list.
// Candidates that follow Rick's own cues come first (a respelling he typed,
// a hint such as "short a on the La", "rhymes with data", "stress on the
// second syllable"), then the systematic variants: stress on each syllable,
// the plausible readings of the stressed vowel (a → æ ɑ eɪ), a final
// unstressed "a" as ə or ɑ, and the American flapped t ("like ladder").
// Everything is de-duplicated by phoneme string, so the list never offers
// the same sound twice under two spellings.
//
// Pure and deterministic: the same name and cues always give the same list
// in the same order, which is what the tests pin. Memory: a few dozen short
// strings per call; the gold lexicon (a few MB) is loaded once by
// MisakiGoldLexicon only when an exemplar is looked up.

import Foundation
import VideoScanCore

enum PronunciationVariations {

    /// One way to say the name.
    struct Candidate: Equatable, Sendable, Identifiable {
        /// misaki phonemes — the identity of the candidate.
        let phonemes: String
        /// Display respelling, stressed syllable in capitals ("LAT-uh").
        let respelling: String
        /// Why it is offered ("short a, stress on the 1st"; "as you spelled it").
        let label: String

        var id: String { phonemes }

        /// misaki's inline override for the Kokoro path (rating 5 — beats
        /// every lexicon layer inside the G2P).
        func spokenForm(word: String) -> String { "[\(word)](/\(phonemes)/)" }
    }

    /// How many the picker shows per page.
    static let defaultLimit = 6
    /// The most this ever generates for one name.
    static let maximum = 12

    // MARK: - Entry point

    /// Ranked candidates for `name`: Rick's cues first (his respellings,
    /// then the hint), then the systematic variants; distinct by phonemes;
    /// at most `limit`. Empty when the name has no readable syllable and no
    /// cue could be turned into phonemes.
    static func candidates(
        for name: String,
        hint: HalliePronunciationHint? = nil,
        respellings: [String] = [],
        limit: Int = defaultLimit,
        gold: MisakiGoldLexicon = .shared
    ) -> [Candidate] {
        Array(allCandidates(for: name, hint: hint, respellings: respellings, gold: gold).prefix(max(0, limit)))
    }

    /// The whole ranked list (up to `maximum`), for paging ("none of these"
    /// → the next few).
    static func allCandidates(
        for name: String,
        hint: HalliePronunciationHint? = nil,
        respellings: [String] = [],
        gold: MisakiGoldLexicon = .shared
    ) -> [Candidate] {
        var out: [Candidate] = []
        var seen: Set<String> = []
        func add(_ candidate: Candidate?) {
            guard let candidate, !candidate.phonemes.isEmpty,
                  seen.insert(candidate.phonemes).inserted else { return }
            out.append(candidate)
        }

        // 1. Rick's own respellings ("Lah-Tah", "Latt-Uh"): exact phonemes
        //    by the teach rules; display normalised (stressed syllable up).
        for respelling in respellings {
            guard let phonemes = HalliePhonemes.derive(respelling: respelling) else { continue }
            add(Candidate(phonemes: phonemes, respelling: normalisedRespelling(respelling), label: "as you spelled it"))
        }

        let word = parse(name)

        // 2. The hint, as constraints on the systematic shapes (or, where a
        //    constraint does not apply, as the hint file's own respelling).
        if let hint {
            for candidate in cueCandidates(word, name: name, hint: hint, gold: gold) { add(candidate) }
        }

        // 3. Systematic variants.
        if let word {
            for shape in systematicShapes(word) { add(candidate(word, shape)) }
        }
        return Array(out.prefix(maximum))
    }

    // MARK: - Model

    /// One reading of a syllable's nucleus, with the coda it goes with
    /// (the "Mc" prefix is "muh" with no coda or "mick" with a k).
    struct Choice: Equatable, Sendable {
        let vowel: String        // misaki vowel (may carry a following ɹ: "ɜɹ")
        let coda: String         // coda phones
        let codaLetters: String  // coda as spelled, for the display
    }

    struct Syllable: Equatable, Sendable {
        let onsetLetters: String
        let vowelLetters: String
        let onset: String                 // onset phones
        let stressed: [Choice]            // readings when this syllable carries the stress, best first
        let unstressed: [Choice]          // readings otherwise, default first
        let isMcPrefix: Bool

        var spelling: String { onsetLetters + vowelLetters + (stressed.first?.codaLetters ?? "") }
    }

    /// A concrete pronunciation: which syllable is stressed, which reading
    /// each syllable takes, and whether a t is flapped.
    struct Shape: Equatable, Sendable {
        var stress: Int
        var picks: [Choice]
        var flapAt: Int? = nil
    }

    // MARK: - Spelling → syllables

    private static let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// "Latta" → ["lat", "a"]; "McGill" → ["mc", "gill"]; "Edith" → ["e", "dith"].
    static func syllableSpellings(_ name: String) -> [String] {
        var parts = HalliePronunciationRespelling.syllables(name)
        guard !parts.isEmpty else { return [] }
        // "lat|ta": the doubled letter is one sound — drop the second
        // syllable's copy (as the hint file does).
        if parts.count > 1 {
            for index in 1..<parts.count {
                if let last = parts[index - 1].last, parts[index].first == last, !vowelLetters.contains(last) {
                    parts[index] = String(parts[index].dropFirst())
                }
            }
        }
        // "Mc"/"Mac" + consonant is its own syllable (no vowel letter, so the
        // vowel-group split cannot see it).
        if let first = parts.first {
            if first.hasPrefix("mc"), first.count > 2 {
                parts[0] = String(first.dropFirst(2))
                parts.insert("mc", at: 0)
            } else if first.hasPrefix("mac"), first.count > 3,
                      let next = first.dropFirst(3).first, !vowelLetters.contains(next) {
                parts[0] = String(first.dropFirst(3))
                parts.insert("mac", at: 0)
            }
        }
        return parts.filter { !$0.isEmpty }
    }

    /// Nil when any syllable has a letter the tables cannot read.
    static func parse(_ name: String) -> [Syllable]? {
        let spellings = syllableSpellings(name)
        guard !spellings.isEmpty else { return nil }
        var out: [Syllable] = []
        for (index, spelling) in spellings.enumerated() {
            guard let syllable = parseSyllable(spelling, isFinal: index == spellings.count - 1) else { return nil }
            out.append(syllable)
        }
        return out
    }

    private static func parseSyllable(_ text: String, isFinal: Bool) -> Syllable? {
        if text == "mc" || text == "mac" {
            return Syllable(
                onsetLetters: "m", vowelLetters: "", onset: "m",
                stressed: [Choice(vowel: "ɪ", coda: "k", codaLetters: "ck"),
                           Choice(vowel: "æ", coda: "k", codaLetters: "ck")],
                unstressed: [Choice(vowel: "ə", coda: "", codaLetters: ""),
                             Choice(vowel: "ɪ", coda: "k", codaLetters: "ck")],
                isMcPrefix: true)
        }
        let chars = Array(text)
        var at = 0
        var onsetLetters = ""
        // A leading "y" before more letters is a consonant ("Yul").
        while at < chars.count, !vowelLetters.contains(chars[at]) || (chars[at] == "y" && at == 0 && chars.count > 1) {
            onsetLetters.append(chars[at]); at += 1
        }
        var nucleus = ""
        while at < chars.count, vowelLetters.contains(chars[at]) { nucleus.append(chars[at]); at += 1 }
        var codaLetters = String(chars[at...])
        guard !nucleus.isEmpty else { return nil }
        // A final "h"/"gh" after a vowel is silent ("Bethiah", "Hugh").
        if isFinal, codaLetters == "h" || codaLetters == "gh" { codaLetters = "" }
        // r-coloured: the r belongs to the vowel ("car" → ɑɹ, "her" → ɜɹ).
        if codaLetters.first == "r", nucleus.count == 1 || ["ea", "ee", "ai", "oo", "ou"].contains(nucleus) {
            nucleus.append("r")
            codaLetters = String(codaLetters.dropFirst())
        }
        guard let onset = consonantPhones(onsetLetters, before: nucleus),
              let coda = consonantPhones(codaLetters, before: "") else { return nil }
        let open = codaLetters.isEmpty
        let stressed = stressedVowels(nucleus, open: open).map { Choice(vowel: $0, coda: coda, codaLetters: codaLetters) }
        var unstressed = [Choice(vowel: unstressedVowel(nucleus, isFinal: isFinal), coda: coda, codaLetters: codaLetters)]
        // A final open "a" is "uh" or "ah" (Latt-uh / Latt-ah).
        if isFinal, open, nucleus == "a" {
            unstressed.append(Choice(vowel: "ɑ", coda: coda, codaLetters: codaLetters))
        }
        guard !stressed.isEmpty else { return nil }
        return Syllable(onsetLetters: onsetLetters, vowelLetters: nucleus, onset: onset,
                        stressed: stressed, unstressed: unstressed, isMcPrefix: false)
    }

    /// Consonant letters → phones (HalliePhonemes' table; soft c before
    /// e/i/y; a doubled letter is one sound). Nil for a letter it cannot read.
    static func consonantPhones(_ letters: String, before nucleus: String) -> String? {
        let chars = Array(letters)
        var out = ""
        var at = 0
        while at < chars.count {
            let rest = String(chars[at...])
            if chars[at] == "c", at == chars.count - 1, let next = nucleus.first, "eiy".contains(next) {
                out += "s"; at += 1; continue
            }
            guard let (spelling, phone) = HalliePhonemes.consonants.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            if !out.hasSuffix(phone) || phone.count > 1 { out += phone }
            at += spelling.count
        }
        return out
    }

    // MARK: - Vowel readings

    /// Plausible readings of a vowel spelling when it carries the stress,
    /// best first. A closed syllable ("lat") leans short; an open one
    /// ("la", "e") leans long (research doc §2.1).
    static func stressedVowels(_ spelling: String, open: Bool) -> [String] {
        switch spelling {
        case "a": return open ? ["ɑ", "A", "æ"] : ["æ", "ɑ", "A"]
        case "e": return open ? ["i", "ɛ", "A"] : ["ɛ", "i", "A"]
        case "i": return open ? ["I", "i", "ɪ"] : ["ɪ", "i", "I"]
        case "o": return open ? ["O", "ɑ", "ʌ"] : ["ɑ", "O", "ʌ"]
        case "u": return open ? ["u", "ʌ", "ju"] : ["ʌ", "u", "ʊ"]
        case "y": return open ? ["I", "i"] : ["ɪ", "I"]
        case "ee", "ea": return ["i", "A", "ɛ"]
        case "ai", "ay": return ["A", "I", "æ"]
        case "oo": return ["u", "ʊ"]
        case "ou", "ow": return ["W", "O", "u"]
        case "ie": return ["i", "I", "A"]
        case "ei", "ey": return ["A", "i", "I"]
        case "au", "aw": return ["ɔ", "ɑ"]
        case "oi", "oy": return ["Y"]
        case "eu", "ew", "ue": return ["u", "ju"]
        case "oa", "oe": return ["O"]
        case "ia": return ["iə", "I", "A"]
        case "io": return ["iO", "iə"]
        case "ar": return ["ɑɹ", "ɛɹ"]
        case "er", "ir", "ur", "yr": return ["ɜɹ", "ɛɹ"]
        case "or": return ["ɔɹ"]
        case "ear", "eer": return ["ɪɹ", "ɛɹ"]
        case "air": return ["ɛɹ"]
        case "oor", "our": return ["ɔɹ", "W"]
        default:
            // An unlisted digraph reads by its first letter.
            if let first = spelling.first { return stressedVowels(String(first), open: open) }
            return []
        }
    }

    /// The reading of a vowel spelling without stress.
    static func unstressedVowel(_ spelling: String, isFinal: Bool) -> String {
        switch spelling {
        case "a", "o", "u": return "ə"
        case "e": return "ə"
        case "i": return "ɪ"
        case "y", "ee", "ea", "ie", "ey", "ei": return "i"
        case "ay", "ai": return "A"
        case "oo", "ou", "ue", "ew", "eu": return "u"
        case "ow", "oa", "oe": return "O"
        case "ar", "er", "ir", "ur", "yr": return "əɹ"
        case "or", "oor", "our": return "ɔɹ"
        case "ear", "eer": return "ɪɹ"
        case "air": return "ɛɹ"
        case "au", "aw": return "ɔ"
        case "oi", "oy": return "Y"
        case "ia": return "iə"
        case "io": return "iO"
        default:
            if let first = spelling.first { return unstressedVowel(String(first), isFinal: isFinal) }
            return "ə"
        }
    }

    /// "short a" / "long a" → the misaki vowel a hint pins.
    static func hintedVowel(letter: Character, length: HalliePronunciationHint.VowelLength) -> String? {
        switch (letter, length) {
        case ("a", .short): return "æ"
        case ("a", .long): return "A"
        case ("e", .short): return "ɛ"
        case ("e", .long): return "i"
        case ("i", .short): return "ɪ"
        case ("i", .long): return "I"
        case ("o", .short): return "ɑ"
        case ("o", .long): return "O"
        case ("u", .short): return "ʌ"
        case ("u", .long): return "u"
        default: return nil
        }
    }

    // MARK: - Shapes

    /// Stress falls on the first syllable, except that "Mc" never carries it.
    static func defaultStress(_ word: [Syllable]) -> Int {
        (word.first?.isMcPrefix == true && word.count > 1) ? 1 : 0
    }

    /// One shape: `stress` carries `stressedChoice`; every other syllable
    /// takes its default reading, or `unstressedOverride` = (syllable,
    /// choice index) for one of them. Nil when an index is out of range.
    private static func shape(
        _ word: [Syllable], stress: Int, stressedChoice: Int = 0, unstressedOverride: (Int, Int)? = nil
    ) -> Shape? {
        guard word.indices.contains(stress) else { return nil }
        var picks: [Choice] = []
        for (index, syllable) in word.enumerated() {
            if index == stress {
                guard syllable.stressed.indices.contains(stressedChoice) else { return nil }
                picks.append(syllable.stressed[stressedChoice])
            } else if let (at, choice) = unstressedOverride, at == index {
                guard syllable.unstressed.indices.contains(choice) else { return nil }
                picks.append(syllable.unstressed[choice])
            } else {
                picks.append(syllable.unstressed[0])
            }
        }
        return Shape(stress: stress, picks: picks)
    }

    /// The American flap: a coda t before an unstressed vowel-initial
    /// syllable ("Latta" → "ladder"). Nil when the shape has no such t.
    static func flapped(_ shape: Shape, _ word: [Syllable]) -> Shape? {
        guard shape.flapAt == nil else { return nil }
        for index in 0..<(word.count - 1) where shape.picks[index].coda.hasSuffix("t") {
            if word[index + 1].onset.isEmpty, shape.stress != index + 1 {
                var out = shape
                out.flapAt = index
                return out
            }
        }
        return nil
    }

    /// A broad stressed ɑ pulls a final "a" along ("LAH-tah").
    private static func broadened(_ shape: Shape, _ word: [Syllable]) -> Shape {
        var out = shape
        for (index, syllable) in word.enumerated() where index != shape.stress {
            if let broad = syllable.unstressed.first(where: { $0.vowel == "ɑ" }) { out.picks[index] = broad }
        }
        return out
    }

    /// The systematic list, in the order the picker offers it (see the
    /// header). Duplicates are removed later by phoneme string.
    static func systematicShapes(_ word: [Syllable]) -> [Shape] {
        let count = word.count
        let s0 = defaultStress(word)
        var shapes: [Shape] = []
        guard let base = shape(word, stress: s0) else { return [] }
        shapes.append(base)                                                  // A: the plain reading
        if let flap = flapped(base, word) { shapes.append(flap) }            // B: flapped t
        if let second = shape(word, stress: s0, stressedChoice: 1) {         // C: the next vowel reading
            shapes.append(second.picks[s0].vowel == "ɑ" ? broadened(second, word) : second)
        }
        for stress in 0..<count where stress != s0 {                         // D: stress elsewhere
            if let moved = shape(word, stress: stress) { shapes.append(moved) }
        }
        for index in 0..<count where index != s0 {                           // E: an unstressed alternative
            if let alt = shape(word, stress: s0, unstressedOverride: (index, 1)) { shapes.append(alt) }
        }
        var choice = 2                                                       // F: further vowel readings
        while let more = shape(word, stress: s0, stressedChoice: choice) { shapes.append(more); choice += 1 }
        for stress in 0..<count where stress != s0 {                         // G: stress elsewhere, other vowels
            var choice = 1
            while let more = shape(word, stress: stress, stressedChoice: choice) { shapes.append(more); choice += 1 }
        }
        for candidate in Array(shapes.dropFirst(2)) {                        // H: flaps of the rest
            if let flap = flapped(candidate, word) { shapes.append(flap) }
        }
        return shapes
    }

    /// Shapes under a hint's constraints: `stress` fixed, `pinned`
    /// (syllable → vowel) fixed; the base, its flap, and the unstressed
    /// alternatives.
    private static func constrainedShapes(_ word: [Syllable], stress: Int, pinned: [Int: String]) -> [Shape] {
        guard word.indices.contains(stress), var base = shape(word, stress: stress) else { return [] }
        for (index, vowel) in pinned where word.indices.contains(index) {
            let current = base.picks[index]
            base.picks[index] = Choice(vowel: vowel, coda: current.coda, codaLetters: current.codaLetters)
        }
        var shapes = [base]
        if let flap = flapped(base, word) { shapes.append(flap) }
        for index in 0..<word.count where index != stress && pinned[index] == nil {
            if word[index].unstressed.count > 1 {
                var alt = base
                alt.picks[index] = word[index].unstressed[1]
                shapes.append(alt)
            }
        }
        return shapes
    }

    // MARK: - Cues

    /// The syllable Rick named ("La") or the first one carrying the letter.
    private static func syllableIndex(_ word: [Syllable], named: String?, letter: Character) -> Int? {
        if let named = named?.lowercased(), !named.isEmpty {
            return word.firstIndex { $0.spelling.hasPrefix(named) || named.hasPrefix($0.spelling) }
        }
        return word.firstIndex { $0.vowelLetters.contains(letter) }
    }

    private static func cueCandidates(
        _ word: [Syllable]?, name: String, hint: HalliePronunciationHint, gold: MisakiGoldLexicon
    ) -> [Candidate] {
        let tag = "from your hint (\(hint.description))"
        var out: [Candidate] = []
        // The hint file's own respelling, displayed from its phonemes so the
        // chip reads the way the sound goes ("LAT-ah", not "LA-tah").
        func fromHintFile() {
            guard let respelling = HalliePronunciationRespelling.respelling(for: name, hint: hint),
                  let phonemes = HalliePhonemes.derive(respelling: respelling) else { return }
            out.append(Candidate(phonemes: phonemes, respelling: self.respelling(fromPhonemes: phonemes), label: tag))
        }
        switch hint {
        case .vowel(let letter, let length, let syllable):
            guard let word, let at = syllableIndex(word, named: syllable, letter: letter),
                  let vowel = hintedVowel(letter: letter, length: length) else { fromHintFile(); break }
            out += constrainedShapes(word, stress: at, pinned: [at: vowel]).map { candidate(word, $0, label: tag) }
        case .stress(let ordinal):
            guard let word else { break }
            let at = ordinal.index.map { min($0, word.count - 1) } ?? (word.count - 1)
            out += constrainedShapes(word, stress: at, pinned: [:]).map { candidate(word, $0, label: tag) }
        case .vowelLike(let letter, let exemplar):
            guard let word, let at = syllableIndex(word, named: nil, letter: letter) else { fromHintFile(); break }
            if let vowel = HalliePhonemes.exemplarVowel(exemplar, gold: gold) {
                out += constrainedShapes(word, stress: at, pinned: [at: vowel]).map { candidate(word, $0, label: tag) }
            } else {
                fromHintFile()
            }
        case .syllables(let given):
            // The hint file's own respelling ("LA-tah"), exemplar vowels
            // pinned from the gold lexicon when it is installed…
            if let respelling = HalliePronunciationRespelling.respelling(for: name, hint: hint) {
                var pins: [Int: String] = [:]
                for (index, part) in given.enumerated() {
                    if let exemplar = part.exemplar, let vowel = HalliePhonemes.exemplarVowel(exemplar, gold: gold) { pins[index] = vowel }
                }
                if let phonemes = HalliePhonemes.derive(respelling: respelling, exemplarVowels: pins) {
                    out.append(Candidate(phonemes: phonemes, respelling: self.respelling(fromPhonemes: phonemes), label: tag))
                }
            }
            // …and the exemplar vowels as constraints on the name's own
            // syllables when the counts agree ("La (as in Lag)" → æ).
            if let word, word.count == given.count {
                var pins: [Int: String] = [:]
                var stress: Int?
                for (index, part) in given.enumerated() {
                    guard let exemplar = part.exemplar, let vowel = HalliePhonemes.exemplarVowel(exemplar, gold: gold) else { continue }
                    pins[index] = vowel
                    if stress == nil { stress = index }
                }
                if !pins.isEmpty {
                    out += constrainedShapes(word, stress: stress ?? defaultStress(word), pinned: pins).map { candidate(word, $0, label: tag) }
                }
            }
        case .rhymes(let with):
            // "rhymes with data": the name's onset + the exemplar from its
            // stressed vowel on (dˈAɾə → lˈAɾə).
            guard let word, let base = systematicShapes(word).first,
                  let phones = gold.phonemes(for: with), let tail = phones.firstIndex(of: "ˈ") else { break }
            let basePhones = phonemes(word, base)
            guard let head = basePhones.firstIndex(of: "ˈ") else { break }
            let joined = String(basePhones[..<head]) + String(phones[tail...])
            out.append(Candidate(phonemes: joined, respelling: respelling(fromPhonemes: joined), label: "rhymes with \(with)"))
        case .silent, .softG, .hardG:
            fromHintFile()
        }
        return out
    }

    // MARK: - Rendering

    static func phonemes(_ word: [Syllable], _ shape: Shape) -> String {
        var out = ""
        for (index, syllable) in word.enumerated() {
            let pick = shape.picks[index]
            var coda = pick.coda
            if shape.flapAt == index, coda.hasSuffix("t") { coda = String(coda.dropLast()) + "ɾ" }
            // "mick" + "car": a consonant doubled across the boundary is one sound.
            var onset = syllable.onset
            if let first = onset.first, out.last == first { onset.removeFirst() }
            out += onset + (index == shape.stress ? "ˈ" : "") + pick.vowel + coda
        }
        return out
    }

    /// Vowels that read as open/long in a respelling — a single coda
    /// consonant after them goes to the next syllable ("LAH-tah").
    private static let openVowels: Set<String> = ["ɑ", "A", "i", "O", "u", "ɔ", "I", "W", "Y", "ə", "ju", "iə", "iO"]

    /// Respelling spelling of a misaki vowel. An unstressed ə keeps a plain
    /// "a"/"o" letter mid-word ("la-TAH") and is "uh" at the end ("LAT-uh").
    static func vowelSpelling(_ vowel: String, grapheme: String, isFinal: Bool) -> String {
        switch vowel {
        case "ə":
            if !isFinal, grapheme == "a" { return "a" }
            if !isFinal, grapheme == "o" { return "o" }
            return "uh"
        case "æ": return "a"
        case "ɑ": return "ah"
        case "A": return "ay"
        case "ɛ": return "eh"
        case "i": return "ee"
        case "ɪ": return "i"
        case "I": return "eye"
        case "O": return "oh"
        case "u": return "oo"
        case "ʊ": return "oo"
        case "ʌ": return "uh"
        case "ɔ": return "aw"
        case "W": return "ow"
        case "Y": return "oy"
        case "ju": return "yoo"
        case "iə": return "eeuh"
        case "iO": return "eeoh"
        case "ɑɹ": return "ar"
        case "ɜɹ", "əɹ":
            // Unstressed "ar"/"or" keep their letters ("mick-car-thee"), a
            // respelled "er" would read as "sir".
            return grapheme.hasSuffix("r") && grapheme.count == 2 ? grapheme : "er"
        case "ɔɹ": return "or"
        case "ɪɹ": return "eer"
        case "ɛɹ": return "air"
        default: return vowel
        }
    }

    static func respelling(_ word: [Syllable], _ shape: Shape) -> String {
        struct Display { var onset: String; var nucleus: String; var coda: String }
        var parts: [Display] = []
        for (index, syllable) in word.enumerated() {
            let pick = shape.picks[index]
            var coda = pick.codaLetters
            if shape.flapAt == index {
                // "tt"/"t" → "d": what the flap sounds like to an American ear.
                coda = coda.replacingOccurrences(of: "tt", with: "d").replacingOccurrences(of: "t", with: "d")
            } else if coda == "ck", openVowels.contains(pick.vowel) {
                // A long/open vowel takes plain "k" in the phonetic
                // display: RICK, but REEK / REYEK rather than REECK.
                coda = "k"
            }
            parts.append(Display(onset: syllable.onsetLetters,
                                 nucleus: vowelSpelling(pick.vowel, grapheme: syllable.vowelLetters, isFinal: index == word.count - 1),
                                 coda: coda))
        }
        if parts.count > 1 {
            for index in 0..<(parts.count - 1)
            where openVowels.contains(shape.picks[index].vowel) && parts[index].coda.count == 1 && parts[index + 1].onset.isEmpty {
                parts[index + 1].onset = parts[index].coda
                parts[index].coda = ""
            }
        }
        return parts.enumerated().map { index, part in
            let text = part.onset + part.nucleus + part.coda
            return index == shape.stress ? text.uppercased() : text.lowercased()
        }.joined(separator: "-")
    }

    /// A respelling for an arbitrary phoneme string (the rhyme candidate):
    /// syllables start at each vowel; a consonant after a short vowel stays
    /// in its coda, otherwise consonants open the next syllable.
    static func respelling(fromPhonemes phonemes: String) -> String {
        let reverse: [Character: String] = ["ɡ": "g", "ʤ": "j", "ʧ": "ch", "ʃ": "sh", "ʒ": "zh", "θ": "th", "ð": "th",
                                            "ŋ": "ng", "ɹ": "r", "ɾ": "d", "j": "y"]
        let short: Set<String> = ["æ", "ɛ", "ɪ", "ʌ", "ʊ"]
        struct Piece { var onset = ""; var vowel = ""; var coda = ""; var stressed = false }
        var pieces: [Piece] = []
        var current = Piece()
        var pendingStress = false
        let chars = Array(phonemes)
        var at = 0
        while at < chars.count {
            let char = chars[at]
            if char == "ˈ" || char == "ˌ" { pendingStress = char == "ˈ"; at += 1; continue }
            if HalliePhonemes.vowelPhones.contains(char) {
                if current.vowel.isEmpty {
                    // The word's onset gathered before the first vowel.
                    current.onset += current.coda
                    current.coda = ""
                } else {
                    // Consonants gathered since the last vowel: split them.
                    let between = current.coda
                    current.coda = ""
                    var next = Piece()
                    if short.contains(current.vowel), let first = between.first {
                        current.coda = String(first)
                        next.onset = String(between.dropFirst())
                    } else {
                        next.onset = between
                    }
                    pieces.append(current)
                    current = next
                }
                var vowel = String(char)
                if (char == "ɜ" || char == "ə" || char == "ɑ" || char == "ɔ" || char == "ɪ" || char == "ɛ"),
                   at + 1 < chars.count, chars[at + 1] == "ɹ", at + 2 >= chars.count || !HalliePhonemes.vowelPhones.contains(chars[at + 2]) {
                    vowel.append("ɹ"); at += 1
                }
                current.vowel = vowel
                current.stressed = pendingStress
                pendingStress = false
            } else {
                current.coda += reverse[char] ?? String(char)
            }
            at += 1
        }
        pieces.append(current)
        let mapped = pieces.enumerated().map { index, piece -> String in
            // Onset and coda were mapped to letters as they were gathered.
            // A short final vowel + /l/ reads naturally with doubled l
            // (GILL); the phonemes themselves cannot retain orthography.
            let coda = readableCoda(
                piece.coda, doublesFinalL: short.contains(piece.vowel))
            let letters = piece.onset
                + vowelSpelling(piece.vowel, grapheme: "", isFinal: index == pieces.count - 1)
                + coda
            return piece.stressed ? letters.uppercased() : letters.lowercased()
        }
        return mapped.joined(separator: "-")
    }

    private static func readableCoda(_ coda: String, doublesFinalL: Bool) -> String {
        doublesFinalL && coda == "l" ? "ll" : coda
    }

    /// "Lah-Tah" → "LAH-tah"; "latt-UH" stays "latt-UH"; a CamelCase
    /// "MahGill" → "mah-GILL"-style split as the teach rules read it.
    static func normalisedRespelling(_ respelling: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in respelling {
            if let previous, previous.isLowercase, character.isUppercase { spaced.append("-") }
            spaced.append(character)
            previous = character
        }
        let syllables = spaced.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        let stressed = syllables.firstIndex { syllable in
            let letters = syllable.filter(\.isLetter)
            return !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        } ?? 0
        return syllables.enumerated().map { $0 == stressed ? $1.uppercased() : $1.lowercased() }.joined(separator: "-")
    }

    private static func vowelName(_ vowel: String) -> String {
        switch vowel {
        case "æ": return "short a"
        case "ɑ": return "broad ah"
        case "A": return "long a"
        case "ɛ": return "short e"
        case "i": return "long e"
        case "ɪ": return "short i"
        case "I": return "long i"
        case "ʌ": return "short u"
        case "u": return "long u"
        case "ʊ": return "oo as in book"
        case "O": return "long o"
        case "ɔ": return "aw"
        case "ə": return "uh"
        case "W": return "ow"
        case "Y": return "oy"
        default: return vowel
        }
    }

    private static func ordinal(_ index: Int) -> String {
        ["1st", "2nd", "3rd", "4th", "5th", "6th"].indices.contains(index) ? ["1st", "2nd", "3rd", "4th", "5th", "6th"][index] : "\(index + 1)th"
    }

    static func candidate(_ word: [Syllable], _ shape: Shape, label: String? = nil) -> Candidate {
        var notes: [String] = []
        if let label {
            notes.append(label)
        } else {
            notes.append(vowelName(shape.picks[shape.stress].vowel))
            if word.count > 1 { notes.append("stress on the \(ordinal(shape.stress))") }
            for (index, syllable) in word.enumerated() where index != shape.stress {
                if syllable.isMcPrefix, shape.picks[index].vowel == "ɪ" { notes.append("Mick") }
                if index == word.count - 1, shape.picks[index].vowel == "ɑ", syllable.vowelLetters == "a" { notes.append("ends in ah") }
            }
        }
        if shape.flapAt != nil { notes.append("flapped t, like ladder") }
        return Candidate(phonemes: phonemes(word, shape), respelling: respelling(word, shape), label: notes.joined(separator: ", "))
    }
}
