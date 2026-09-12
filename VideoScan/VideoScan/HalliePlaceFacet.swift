// HalliePlaceFacet.swift
// The deterministic PLACE facet on the presence road (Rick 2026-09-12):
// "videos at Cape Cod", "videos of Donna in Westford", "what do we have
// from Montana". Rides beside the year facet: a term that is one of
// Rick's OWN places — the distinct hand-entered `userPlace` values in
// the catalog, nothing seeded, no gazetteer — becomes an EXACT match on
// the Place field instead of a word search. A transcript that SAYS
// "cape cod" no longer answers for a video shot there; that is the whole
// point of the field (sensor: placeSearchIsExactNotSubstringOfTranscript).
//
// Two ways in, both pure:
//   1. A keyword the translator emitted (or a name the presence step
//      demoted to a word) that IS one of Rick's places → the place facet,
//      and the term leaves the keyword list.
//   2. The question names a place after a place preposition ("at", "in",
//      "from", "near", …) — whole phrase or town alone ("Franklin" for
//      "Franklin, MA") — even when the translator dropped it. Keywords
//      made only of the place's own words leave the keyword list too.
// The facet value is the CANONICAL form of what was asked, not the
// roster spelling, so "Franklin" still matches both "Franklin, MA" and
// "Franklin, NH" at execution (town-only rule, UserPlaceEntry.matches).
//
// Without any placed record the step is a no-op and the words go on
// being searched exactly as before — the list grows from use.
//
// COST. One pass over the presence snapshots to collect the distinct
// places (a Set insert per placed record), then a handful of regex
// tests per known place. Budgeted at 100k records by HalliePlaceFacetTests.
//
// (For Rick: `enum` with only statics ≈ a C++ namespace; `inout` ≈ a
// non-const reference parameter.)

import Foundation
import VideoScanCore

enum HalliePlaceFacet {

    /// What the step decided, for the basis line and for tests.
    struct Detection: Equatable, Sendable {
        /// Canonical form of the asked place (UserPlaceEntry.canonicalize).
        let place: String
        /// Keyword terms removed from the payload because they WERE the place.
        let consumed: [String]
        /// True when the place came from the question text (way 2).
        let fromQuestion: Bool

        var note: String {
            "“\(place)” is one of your places, so I matched the Place field exactly "
                + "(not words in transcripts or file names)"
        }
    }

    /// Rick's own places, as the presence snapshots carry them: distinct,
    /// longest first so "North Conway, NH" is tried before "Conway".
    static func knownPlaces(in records: [ArchivistPresenceRecordSnapshot]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for record in records {
            if let place = record.userPlace, !place.isEmpty, seen.insert(place).inserted {
                out.append(place)
            }
        }
        return out.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a < b
        }
    }

    /// Rewrite `payload` in place: set `place` and drop the consumed terms.
    /// nil (payload untouched) when nothing in the question is one of
    /// Rick's places. A payload that already carries a place (a refinement
    /// re-run) is only canonicalized.
    static func apply(
        to payload: inout ArchivistQueryAST.Presence,
        question: String,
        knownPlaces: [String]
    ) -> Detection? {
        if let existing = payload.place {
            payload.place = UserPlaceEntry.canonicalize(existing)
            return nil
        }
        guard !knownPlaces.isEmpty else { return nil }

        // Way 1 — a keyword that IS one of Rick's places.
        if let keywords = payload.keywords {
            for (index, term) in keywords.enumerated() {
                guard let canonical = UserPlaceEntry.canonicalize(term),
                      knownPlaces.contains(where: { UserPlaceEntry.matches(canonical, against: $0) })
                else { continue }
                var kept = keywords
                kept.remove(at: index)
                payload.keywords = kept.isEmpty ? nil : kept
                payload.place = canonical
                return Detection(place: canonical, consumed: [term], fromQuestion: false)
            }
        }

        // Way 2 — the question names a place after a place preposition.
        let text = question
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return nil }
        for known in knownPlaces {
            var candidates = [known]
            let town = UserPlaceEntry.town(of: known)
            if town != known { candidates.append(town) }
            for candidate in candidates {
                guard mentions(candidate, in: text),
                      let canonical = UserPlaceEntry.canonicalize(candidate) else { continue }
                let placeTokens = Set(tokens(canonical))
                var consumed: [String] = []
                if let keywords = payload.keywords {
                    let kept = keywords.filter { keyword in
                        let words = tokens(keyword)
                        if !words.isEmpty, words.allSatisfy(placeTokens.contains) {
                            consumed.append(keyword)
                            return false
                        }
                        return true
                    }
                    payload.keywords = kept.isEmpty ? nil : kept
                }
                payload.place = canonical
                return Detection(place: canonical, consumed: consumed, fromQuestion: true)
            }
        }
        return nil
    }

    /// "at cape cod", "in franklin", "from montana", "down the cape cod" —
    /// the place as a whole word run right after a place preposition.
    static func mentions(_ place: String, in lowercasedText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: place.lowercased())
        // "of" is deliberately absent: "videos of Montana" names a person
        // until the presence step's demotion says otherwise.
        let pattern = #"\b(?:at|in|from|around|near|on|to|down|up|out)\s+(?:the\s+)?"# + escaped + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(lowercasedText.startIndex..., in: lowercasedText)
        return regex.firstMatch(in: lowercasedText, options: [], range: whole) != nil
    }

    static func tokens(_ value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
