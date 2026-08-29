// HalliePhonemes.swift
// Respelling → misaki phonemes, deterministically (docs/
// pronunciation_training_research.md §1–§2, 2026-08-29). A respelling like
// "LAT-uh" is re-guessed by misaki's BART fallback when Kokoro reads it,
// so a teach also derives the phoneme string the inline override needs:
//   "LAT-uh"  → "lˈætə"     "muh-GILL" → "məɡˈɪl"     "EE-dith" → "ˈidɪθ"
// Rules: syllables split at "-"; a syllable written ALL IN CAPITALS
// carries the primary stress `ˈ` (none capitalised → first syllable);
// consonant and vowel spellings follow the conventions Rick's respellings
// already use (below). Anything this table cannot read → nil: no guess is
// ever stored as phonemes. `.` is NOT a syllable marker in misaki and is
// never emitted; syllables are simply concatenated.
//
// "as in <word>" exemplars: the vowel comes from misaki's own gold
// lexicon (us_gold.json inside the installed helper bundle, read-only,
// e.g. "lag" → "lˈæɡ" → æ). The bundle is optional; without it the
// respelling rules alone decide. Memory: the gold table is ~90k short
// strings (a few MB) loaded once on first exemplar lookup and kept.

import Foundation

enum HalliePhonemes {

    /// misaki's US vowel symbols (single characters, including the
    /// diphthong letters A I W Y O).
    static let vowelPhones: Set<Character> = ["ə", "i", "u", "ɑ", "ɔ", "ɛ", "ɜ", "ɪ", "ʊ", "ʌ", "æ", "A", "I", "W", "Y", "O", "ᵊ", "ᵻ"]

    /// Multi-letter spellings first (longest match wins at each position).
    static let consonants: [(String, String)] = [
        ("tch", "ʧ"), ("dge", "ʤ"), ("ng", "ŋ"), ("sh", "ʃ"), ("zh", "ʒ"), ("th", "θ"), ("dh", "ð"),
        ("ch", "ʧ"), ("ph", "f"), ("ck", "k"), ("wh", "w"), ("gh", "ɡ"), ("qu", "kw"), ("kh", "k"),
        ("b", "b"), ("c", "k"), ("d", "d"), ("f", "f"), ("g", "ɡ"), ("h", "h"), ("j", "ʤ"), ("k", "k"),
        ("l", "l"), ("m", "m"), ("n", "n"), ("p", "p"), ("r", "ɹ"), ("s", "s"), ("t", "t"), ("v", "v"),
        ("w", "w"), ("x", "ks"), ("z", "z"),
    ]

    /// Vowel spellings as respellings use them. `stressed`/`unstressed`
    /// differ only where the convention does ("uh" = ʌ stressed, ə not).
    private struct Vowel { let stressed: String; let unstressed: String }
    private static let vowels: [(String, Vowel)] = [
        ("eye", Vowel(stressed: "I", unstressed: "I")),
        ("igh", Vowel(stressed: "I", unstressed: "I")),
        ("air", Vowel(stressed: "ɛɹ", unstressed: "ɛɹ")),
        ("ear", Vowel(stressed: "ɪɹ", unstressed: "ɪɹ")),
        ("oor", Vowel(stressed: "ɔɹ", unstressed: "ɔɹ")),
        ("our", Vowel(stressed: "ɔɹ", unstressed: "ɔɹ")),
        ("ah", Vowel(stressed: "ɑ", unstressed: "ɑ")),
        ("aw", Vowel(stressed: "ɔ", unstressed: "ɔ")),
        ("ay", Vowel(stressed: "A", unstressed: "A")),
        ("ai", Vowel(stressed: "A", unstressed: "A")),
        ("ee", Vowel(stressed: "i", unstressed: "i")),
        ("ea", Vowel(stressed: "i", unstressed: "i")),
        ("eh", Vowel(stressed: "ɛ", unstressed: "ɛ")),
        ("ih", Vowel(stressed: "ɪ", unstressed: "ɪ")),
        ("oh", Vowel(stressed: "O", unstressed: "O")),
        ("oo", Vowel(stressed: "u", unstressed: "u")),
        // "ROW-nin", "show": respellings write the oʊ sound as "ow"/"oh";
        // the aʊ sound is written "ou" ("LOUD").
        ("ow", Vowel(stressed: "O", unstressed: "O")),
        ("ou", Vowel(stressed: "W", unstressed: "W")),
        ("ar", Vowel(stressed: "ɑɹ", unstressed: "əɹ")),
        ("or", Vowel(stressed: "ɔɹ", unstressed: "ɔɹ")),
        ("oy", Vowel(stressed: "Y", unstressed: "Y")),
        ("uh", Vowel(stressed: "ʌ", unstressed: "ə")),
        ("er", Vowel(stressed: "ɜɹ", unstressed: "əɹ")),
        ("ur", Vowel(stressed: "ɜɹ", unstressed: "əɹ")),
        ("ir", Vowel(stressed: "ɜɹ", unstressed: "əɹ")),
        ("ie", Vowel(stressed: "i", unstressed: "i")),
        ("ey", Vowel(stressed: "A", unstressed: "i")),
        ("a", Vowel(stressed: "æ", unstressed: "ə")),
        ("e", Vowel(stressed: "ɛ", unstressed: "ɛ")),
        ("i", Vowel(stressed: "ɪ", unstressed: "ɪ")),
        ("o", Vowel(stressed: "ɑ", unstressed: "ə")),
        ("u", Vowel(stressed: "ʌ", unstressed: "ə")),
        ("y", Vowel(stressed: "I", unstressed: "i")),
    ]

    /// The phoneme string for a respelling, or nil when any piece of it is
    /// not a spelling this table knows. `exemplarVowels` (syllable index →
    /// misaki vowel) pins a syllable's vowel from an "as in <word>" hint.
    static func derive(respelling: String, exemplarVowels: [Int: String] = [:]) -> String? {
        // "MahGill" (no hyphen, CamelCase) splits at the case change.
        var spaced = ""
        var previous: Character?
        for character in respelling {
            if let previous, previous.isLowercase, character.isUppercase { spaced.append("-") }
            spaced.append(character)
            previous = character
        }
        let syllables = spaced
            .split(whereSeparator: { $0 == "-" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !syllables.isEmpty, syllables.allSatisfy({ $0.allSatisfy { $0.isLetter || $0 == "'" } }) else { return nil }
        let stressedIndex = syllables.firstIndex { syllable in
            let letters = syllable.filter(\.isLetter)
            return letters.count >= 1 && letters.allSatisfy(\.isUppercase)
        } ?? 0
        var out = ""
        for (index, syllable) in syllables.enumerated() {
            guard let phones = phonemes(forSyllable: syllable.lowercased().filter(\.isLetter),
                                        stressed: index == stressedIndex,
                                        pinnedVowel: exemplarVowels[index]) else { return nil }
            // "LAT-tah": the same consonant closing one syllable and
            // opening the next is one sound (lˈætɑ, not lˈættɑ).
            if let first = phones.first, let last = out.last, first == last,
               !vowelPhones.contains(first), first != "ˈ" {
                out += phones.dropFirst()
            } else {
                out += phones
            }
        }
        return out
    }

    /// One syllable: an onset of consonants, one vowel spelling, a coda of
    /// consonants. Stress goes right before the vowel (misaki's form:
    /// "lˈætə"). A syllable with no vowel (the "Mc" of a respelling written
    /// "Mc-GILL") gets a schwa.
    private static func phonemes(forSyllable text: String, stressed: Bool, pinnedVowel: String?) -> String? {
        let chars = Array(text)
        var out = ""
        var index = 0
        var sawVowel = false
        while index < chars.count {
            let rest = String(chars[index...])
            if !sawVowel, let (spelling, vowel) = vowels.first(where: { rest.hasPrefix($0.0) }) {
                // A leading "y" is a consonant ("yul" → jəl), not a vowel.
                if spelling == "y", index == 0, chars.count > 1 {
                    out += "j"; index += 1; continue
                }
                sawVowel = true
                out += (stressed ? "ˈ" : "") + (pinnedVowel ?? (stressed ? vowel.stressed : vowel.unstressed))
                index += spelling.count
                continue
            }
            if let (spelling, phone) = consonants.first(where: { rest.hasPrefix($0.0) }) {
                // "GILL", "Latta": a doubled letter is one sound.
                if !out.hasSuffix(phone) || phone.count > 1 { out += phone }
                index += spelling.count
                continue
            }
            return nil
        }
        if !sawVowel {
            // "Mc" / "St" — a syllabic schwa keeps it pronounceable.
            out += (stressed ? "ˈ" : "") + "ə"
        }
        return out
    }

    /// The stressed vowel of a word in misaki's gold lexicon ("lag" → "æ"),
    /// nil when the bundle is absent or the word is not there.
    static func exemplarVowel(_ word: String, gold: MisakiGoldLexicon = .shared) -> String? {
        guard let phones = gold.phonemes(for: word) else { return nil }
        return stressedVowel(in: phones)
    }

    /// The vowel after `ˈ`, else the first vowel symbol.
    static func stressedVowel(in phones: String) -> String? {
        let chars = Array(phones)
        if let at = chars.firstIndex(of: "ˈ"), at + 1 < chars.count, vowelPhones.contains(chars[at + 1]) {
            return vowelSequence(chars, from: at + 1)
        }
        if let at = chars.firstIndex(where: { vowelPhones.contains($0) }) {
            return vowelSequence(chars, from: at)
        }
        return nil
    }

    /// A vowel plus a following ɹ ("ɜɹ") when the vowel is r-coloured.
    private static func vowelSequence(_ chars: [Character], from at: Int) -> String {
        var out = String(chars[at])
        if chars[at] == "ɜ" || chars[at] == "ə", at + 1 < chars.count, chars[at + 1] == "ɹ" { out.append("ɹ") }
        return out
    }
}

/// misaki's `us_gold.json` (word → phonemes, or → {"DEFAULT": …} for
/// homographs) from the installed Kokoro helper, read once, read-only.
/// `NSLock` ≈ std::mutex around the lazy load.
final class MisakiGoldLexicon: @unchecked Sendable {
    static let shared = MisakiGoldLexicon()

    private let lock = NSLock()
    private var table: [String: String]?
    private let url: URL?

    init(url: URL? = MisakiGoldLexicon.defaultURL) {
        self.url = url
    }

    /// `HallieKokoro/MisakiSwift_MisakiSwift.bundle/Resources/us_gold.json`.
    static var defaultURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("VideoScan/HallieKokoro/MisakiSwift_MisakiSwift.bundle/Resources/us_gold.json")
    }

    var isAvailable: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func phonemes(for word: String) -> String? {
        let key = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return lock.withLock {
            if table == nil { table = load() }
            return table?[key]
        }
    }

    private func load() -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(object.count)
        for (word, value) in object {
            if let phones = value as? String { out[word] = phones }
            else if let variants = value as? [String: String], let phones = variants["DEFAULT"] ?? variants.values.sorted().first {
                out[word] = phones
            }
        }
        return out
    }
}
