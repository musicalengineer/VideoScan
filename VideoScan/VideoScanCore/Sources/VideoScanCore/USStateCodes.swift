// USStateCodes.swift
// "David T. McGill was born in KY, 1843." (GH #184 item 6, live 2026-09-11)
//
// FamilySearch exports carry two-letter postal codes as whole places, and
// Hallie read — and Bella spoke — "KY" verbatim. Rick tried three times to
// teach "KY" → "Kentucky" as a pronunciation; none routed anywhere useful
// (pronunciations are for people). The cheaper, honest fix: expand the
// codes where PLACES are phrased and where prose is spoken. Nothing stored
// changes — a tree birthplace stays "KY", a record's hand-entered
// userPlace stays exactly as typed; only the sentence differs.
//
// Two shapes:
//   expandStateCodes(inPlace:) — a place STRING ("KY", "Louisville, KY",
//     "Louisville KY"): a code expands only as a whole comma-separated
//     part or as the last whitespace token of the last part.
//   expandStateCodes(inProse:) — a SENTENCE: a code expands only when it
//     stands alone (own token, exact upper case) after a place cue —
//     "in/at/of/from/near/born/—" or a capitalised place part and a comma
//     ("Louisville, KY") — so "Al Smith", "it is OK", a filename
//     "2006_KY_trip.mov" and the word "in" are never touched.
// Pure text work; a lookup table plus two small tokenisers.

import Foundation

public enum USStateCodes {

    /// The fifty states plus the District of Columbia. Upper-case keys.
    public static let names: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
        "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
        "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "DC": "District of Columbia",
    ]

    /// The state name for an EXACT upper-case two-letter code; nil for
    /// anything else ("Ky", "ky", "Al", "KYY").
    public static func name(forCode code: String) -> String? {
        guard code.count == 2, code.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return nil }
        return names[code]
    }

    // MARK: - Place strings

    /// "KY" → "Kentucky"; "Louisville, KY" → "Louisville, Kentucky";
    /// "Louisville KY" → "Louisville Kentucky" (the last token of the last
    /// part expands in place). Every other place string comes back byte
    /// for byte ("Louisville, Jefferson, Kentucky, United States",
    /// "Al Smith", "2006_KY_trip.mov").
    public static func expandStateCodes(inPlace place: String) -> String {
        guard place.contains(where: { $0.isUppercase }) else { return place }
        var parts = place.components(separatedBy: ",")
        for index in parts.indices {
            let part = parts[index]
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let name = name(forCode: trimmed) {
                parts[index] = replacingTrimmedContent(of: part, with: name)
            } else if index == parts.indices.last {
                // The last whitespace token of the last part ("Louisville KY").
                let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: false)
                if tokens.count > 1, let last = tokens.last, let name = name(forCode: String(last)) {
                    let replaced = tokens.dropLast().joined(separator: " ") + " " + name
                    parts[index] = replacingTrimmedContent(of: part, with: replaced)
                }
            }
        }
        return parts.joined(separator: ",")
    }

    /// Keep the leading/trailing whitespace of `part`, swap its content.
    private static func replacingTrimmedContent(of part: String, with content: String) -> String {
        let leading = part.prefix { $0 == " " }
        let trailing = part.reversed().prefix { $0 == " " }
        return String(leading) + content + String(trailing)
    }

    // MARK: - Prose

    /// The word before a code that marks it as a place.
    private static let placeCues: Set<String> = ["in", "at", "of", "from", "near", "born", "—", "–", "-"]

    /// Expand a code that stands alone in a place position of a sentence.
    /// Whitespace runs and every other token are preserved exactly.
    public static func expandStateCodes(inProse text: String) -> String {
        guard text.contains(where: { $0.isUppercase }) else { return text }
        // Tokens alternate with the whitespace runs between them, so the
        // result is rebuilt without touching spacing.
        var pieces: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if space != inSpace, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            inSpace = space
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }

        // Word tokens are the pieces at even or odd indices depending on
        // whether the text opened with whitespace.
        var wordIndices: [Int] = []
        for (index, piece) in pieces.enumerated() where !(piece.first?.isWhitespace ?? true) {
            wordIndices.append(index)
        }
        for (position, index) in wordIndices.enumerated() {
            let (lead, core, trail) = split(pieces[index])
            guard let name = name(forCode: core) else { continue }
            guard position > 0 else { continue }
            let previous = pieces[wordIndices[position - 1]]
            let (_, previousCore, previousTrail) = split(previous)
            let cue = previousCore.lowercased()
            var isPlace = false
            if placeCues.contains(cue) || placeCues.contains(previous.trimmingCharacters(in: .whitespaces)) {
                isPlace = true
            } else if previousTrail.hasPrefix(","), previousCore.first?.isUppercase == true {
                // "Louisville, KY" — but not "Yes, OK" at a sentence start.
                let sentenceInitial: Bool
                if position == 1 {
                    sentenceInitial = true
                } else {
                    let before = split(pieces[wordIndices[position - 2]]).trail
                    sentenceInitial = before.contains(where: { ".!?".contains($0) })
                }
                isPlace = !sentenceInitial
            }
            guard isPlace else { continue }
            pieces[index] = lead + name + trail
        }
        return pieces.joined()
    }

    /// "(KY," → ("(", "KY", ",").
    private static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let punctuation = CharacterSet(charactersIn: ".,;:!?()\"'“”‘’[]")
        var scalars = Array(token.unicodeScalars)
        var lead = ""
        while let first = scalars.first, punctuation.contains(first) {
            lead.unicodeScalars.append(first)
            scalars.removeFirst()
        }
        var trailScalars: [Unicode.Scalar] = []
        while let last = scalars.last, punctuation.contains(last) {
            trailScalars.insert(last, at: 0)
            scalars.removeLast()
        }
        var core = ""
        core.unicodeScalars.append(contentsOf: scalars)
        var trail = ""
        trail.unicodeScalars.append(contentsOf: trailScalars)
        return (lead, core, trail)
    }
}
