// FamilyNameTokens.swift
// Which single word may stand for a person (GH #184 item 6, 2026-09-12).
//
// Live 2026-09-11 22:11Z: Rick typed "when you see KY as a location in
// caps, it is OK, and recommended to pornounce it "Kentucky"". The
// free-form pronunciation detector asked "is `see` a name the archive
// knows?", and the answer was yes — because GEDCOM keeps every extra NAME
// line as an alternate name, and Adam FitzHerbert of Llanllowell carries
// the notes-style alias "Llanlowell Llan Hywel and see note". Every
// whitespace token of every alias counted as a name, so "see" resolved to
// him and a CyberBrain person was minted with pronunciations {"see": "KY |
// OK"}.
//
// This is the one rule, shared by the resolvers and the writer, for when a
// typed token names a person:
//   1. it equals a WHOLE alias (or the whole primary name), or
//   2. it is a name-shaped word of the PRIMARY name — any word that is not
//      a common English / note word ("peter ronan" is lowercase in the
//      tree, so the primary name needs no capital), or
//   3. it is a name-shaped word of an ALIAS: capitalised in the alias (or
//      also a word of the primary name), not a common word, and the alias
//      is not notes-style (parenthetical, bracketed, carrying a lowercase
//      common word, or longer than five words).
// Pure text work; no I/O. Think of a header-only helper with a static
// stop-word set.

import Foundation

public enum FamilyNameTokens {

    /// Function words and note words that are never a person's name on
    /// their own, however they are capitalised. Titles are included: a
    /// family will not teach Hallie how to say "of" or "Sir".
    public static let commonWords: Set<String> = [
        // articles, prepositions, conjunctions
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "of", "in", "on", "at", "to", "for", "by",
        "with", "from", "into", "onto", "upon", "over", "under", "near", "after", "before", "about", "as",
        "than", "then", "via", "per",
        // pronouns and auxiliaries
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her", "it", "its",
        "they", "them", "their", "this", "that", "these", "those", "who", "whom", "whose", "which", "what",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "has", "have", "had",
        "can", "could", "may", "might", "shall", "should", "will", "would", "must",
        // note words that turn up inside GEDCOM / FamilySearch names
        "see", "note", "notes", "aka", "alias", "also", "known", "called", "named", "formerly", "nee", "née",
        "unknown", "unnamed", "infant", "child", "son", "daughter", "wife", "husband", "widow", "twin",
        "possibly", "probably", "maybe", "perhaps", "same", "not", "no", "yes", "if", "when", "where",
        "born", "died", "married", "unmarried", "living", "deceased", "spouse", "family", "ok",
        // titles and honorifics
        "mr", "mrs", "ms", "miss", "dr", "rev", "capt", "col", "gen", "sir", "lady", "lord", "king", "queen",
        "prince", "princess", "duke", "duchess", "earl", "count", "countess", "baron", "baroness", "knight",
        "esq", "jr", "sr", "ii", "iii", "iv",
    ]

    /// Whitespace-split words with the punctuation a name carries trimmed
    /// off ("O'Connor," → "O'Connor"; "(Ma)" → "Ma"). Words with no letter
    /// are dropped. Original spelling and case kept.
    public static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()\"'“”‘’/[]{}!?—–-"))
            guard word.contains(where: \.isLetter) else { return nil }
            return word
        }
    }

    /// A notes-style alias is never a source of single-word names: it
    /// carries a parenthetical or bracket, a lowercase common word
    /// ("... and see note"), or more than five words (a whole office, "High
    /// Sheriff of Essex, Assistant to King Henry VIII").
    public static func isNotesStyle(_ alias: String) -> Bool {
        if alias.contains(where: { "()[]{}".contains($0) }) { return true }
        let parts = words(alias)
        if parts.count > 5 { return true }
        return parts.contains { word in
            word.first?.isLowercase == true && commonWords.contains(FamilyIdentityText.normalized(word))
        }
    }

    /// The words of a PRIMARY name that may stand for the person: every
    /// word that is not a common word. No capital required — the tree
    /// carries "peter ronan".
    public static func nameWords(ofPrimaryName name: String) -> [String] {
        words(name).filter { !commonWords.contains(FamilyIdentityText.normalized($0)) }
    }

    /// The words of an ALIAS that may stand for the person: none for a
    /// notes-style alias; otherwise the capitalised, non-common words (and
    /// any word the primary name also carries).
    public static func nameWords(ofAlias alias: String, primaryName: String) -> [String] {
        guard !isNotesStyle(alias) else { return [] }
        let primary = Set(nameWords(ofPrimaryName: primaryName).map(FamilyIdentityText.normalized))
        return words(alias).filter { word in
            let key = FamilyIdentityText.normalized(word)
            guard !commonWords.contains(key) else { return false }
            return word.first?.isUppercase == true || primary.contains(key)
        }
    }

    /// The archive's spelling of `candidate` when it names this person by
    /// the rule above — a whole alias / whole primary name first, then a
    /// name word of the primary name, then a name word of an alias. Nil
    /// when it does not. `candidate` may carry any case ("nate", "NATE").
    public static func spelling(
        of candidate: String,
        primaryName: String,
        aliases: [String]
    ) -> String? {
        let key = FamilyIdentityText.normalized(candidate)
        guard !key.isEmpty else { return nil }
        let primaryTrimmed = primaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if FamilyIdentityText.normalized(primaryTrimmed) == key { return primaryTrimmed }
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if FamilyIdentityText.normalized(trimmed) == key { return trimmed }
        }
        if let word = nameWords(ofPrimaryName: primaryName).first(where: { FamilyIdentityText.normalized($0) == key }) {
            return word
        }
        for alias in aliases {
            if let word = nameWords(ofAlias: alias, primaryName: primaryName)
                .first(where: { FamilyIdentityText.normalized($0) == key }) {
                return word
            }
        }
        return nil
    }

    /// Does `candidate` name this person (whole alias or a name word)?
    public static func matches(_ candidate: String, primaryName: String, aliases: [String]) -> Bool {
        spelling(of: candidate, primaryName: primaryName, aliases: aliases) != nil
    }
}
