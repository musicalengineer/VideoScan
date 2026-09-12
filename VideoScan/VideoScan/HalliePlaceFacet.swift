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
        let text = question
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return nil }
        // Way 1 — a keyword that IS one of Rick's places, when some OCCURRENCE
        // of that term in the question has a location shape ("at/in/from/of
        // <place>", "videos <place>", "<place> videos") that is not the object
        // of content wording ("where someone says Cape Cod", "captioned
        // Westford", "titled Montana" — codex #1370 P1 / #1374 / #1380). The
        // rule is per OCCURRENCE: "videos at Cape Cod where Donna says Cape
        // Cod" yields place = Cape Cod from the first occurrence AND keeps the
        // keyword for the second. "of" counts here: the term is already a
        // keyword — the presence step demoted an unresolved name, or the
        // translator chose a word — so "videos of Franklin" is the place
        // once Franklin is not a person.
        if let keywords = payload.keywords {
            for (index, term) in keywords.enumerated() {
                guard let canonical = UserPlaceEntry.canonicalize(term),
                      knownPlaces.contains(where: { UserPlaceEntry.matches(canonical, against: $0) })
                else { continue }
                let occurrences = self.occurrences(of: term, in: text) + self.occurrences(of: canonical, in: text)
                guard occurrences.contains(where: { $0.isLocation && !$0.isContentObject }) else { continue }
                let alsoSaid = occurrences.contains(where: { $0.isContentObject })
                var consumed: [String] = []
                if !alsoSaid {
                    var kept = keywords
                    kept.remove(at: index)
                    payload.keywords = kept.isEmpty ? nil : kept
                    consumed = [term]
                }
                payload.place = canonical
                return Detection(place: canonical, consumed: consumed, fromQuestion: false)
            }
        }

        // Way 2 — the question names a place after a place preposition (an
        // occurrence that is not itself a content object). Keywords made only
        // of the place's words leave the keyword list — UNLESS that keyword
        // has its own content-object occurrence ("videos at Cape Cod where
        // someone says cod" keeps "cod", codex #1380).
        for known in knownPlaces {
            var candidates = [known]
            let town = UserPlaceEntry.town(of: known)
            if town != known { candidates.append(town) }
            for candidate in candidates {
                let occurrences = self.occurrences(of: candidate, in: text)
                guard occurrences.contains(where: { $0.isStrictPreposition && !$0.isContentObject }),
                      let canonical = UserPlaceEntry.canonicalize(candidate) else { continue }
                let placeTokens = Set(tokens(canonical))
                var consumed: [String] = []
                if let keywords = payload.keywords {
                    let kept = keywords.filter { keyword in
                        let words = tokens(keyword)
                        guard !words.isEmpty, words.allSatisfy(placeTokens.contains) else { return true }
                        if self.occurrences(of: keyword, in: text).contains(where: { $0.isContentObject }) {
                            return true   // the word someone SAYS stays a word
                        }
                        consumed.append(keyword)
                        return false
                    }
                    payload.keywords = kept.isEmpty ? nil : kept
                }
                payload.place = canonical
                return Detection(place: canonical, consumed: consumed, fromQuestion: true)
            }
        }
        return nil
    }

    // MARK: - Occurrences

    /// One appearance of a term in the question, classified by what sits
    /// immediately around it. (For Rick: a tiny POD; the regexes below are
    /// anchored at the occurrence's edges so the classification is local.)
    struct Occurrence: Equatable {
        /// Preceded by a place preposition ("at", "in", "from", … — "of"
        /// and "by" included, see Way 1).
        let isPreposition: Bool
        /// Preceded by a STRICT place preposition (no "of"/"by") — Way 2.
        let isStrictPreposition: Bool
        /// Beside a media noun ("videos cape cod", "cape cod videos").
        let isMediaNoun: Bool
        /// Preceded by content wording ("says", "captioned", "titled", …).
        let isContentObject: Bool
        var isLocation: Bool { isPreposition || isMediaNoun }
    }

    /// Every whole-word occurrence of `term` in `lowercasedText`, classified.
    static func occurrences(of term: String, in lowercasedText: String) -> [Occurrence] {
        let escaped = NSRegularExpression.escapedPattern(for: term.lowercased())
        guard !escaped.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#) else { return [] }
        let whole = NSRange(lowercasedText.startIndex..., in: lowercasedText)
        return regex.matches(in: lowercasedText, options: [], range: whole).compactMap { match in
            guard let range = Range(match.range, in: lowercasedText) else { return nil }
            let before = String(lowercasedText[..<range.lowerBound])
            let after = String(lowercasedText[range.upperBound...])
            let strict = tail(strictPrepositionPrefix, before)
            let loose = strict || tail(loosePrepositionPrefix, before)
            let media = tail(mediaNounPrefix, before) || head(mediaNounSuffix, after)
            let content = tail(contentPrefix, before)
            return Occurrence(isPreposition: loose, isStrictPreposition: strict,
                              isMediaNoun: media, isContentObject: content)
        }
    }

    private static func tail(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static func head(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let mediaNouns = #"(?:videos?|clips?|footage|tapes?|movies?|films?|recordings?|anything|everything|stuff|shots?)"#
    /// Force-unwraps are deliberate: compile-time literals — a bad one fails
    /// the first test, not a live turn.
    private static let strictPrepositionPrefix = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:at|in|from|around|near|on|to|down|up|out)\s+(?:the\s+)?$"#)
    private static let loosePrepositionPrefix = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:of|by)\s+(?:the\s+)?$"#)
    private static let mediaNounPrefix = try! NSRegularExpression(
        pattern: #"(?:^|\s)"# + mediaNouns + #"\s+(?:the\s+)?$"#)
    private static let mediaNounSuffix = try! NSRegularExpression(
        pattern: #"^\s+"# + mediaNouns + #"\b"#)
    private static let contentPrefix = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:says?|said|saying|mentions?|mentioned|mentioning|talk(?:s|ed|ing)? about|"#
            + #"caption(?:s|ed)?(?: with| as)?|titled?|named|called|transcripts? (?:of|for|with|containing)|"#
            + #"hears?|heard|subtitled|reads?)\s+(?:the\s+)?(?:words?\s+)?["'“‘]?$"#)

    /// "at cape cod", "in franklin", "from montana", "down the cape cod" —
    /// the place as a whole word run right after a STRICT place preposition
    /// ("of" is absent: "videos of Montana" names a person until the
    /// presence step's demotion says otherwise). Any occurrence counts.
    static func mentions(_ place: String, in lowercasedText: String) -> Bool {
        occurrences(of: place, in: lowercasedText).contains(where: \.isStrictPreposition)
    }

    /// `term` is the OBJECT of content wording — the thing said, captioned,
    /// titled, named or mentioned ("where someone says Cape Cod", "clips
    /// captioned Westford", "titled Montana", "talking about Westford").
    /// Then it is a word IN the video, not where it was shot. Judged per
    /// term: content wording elsewhere in the sentence ("audio clips from
    /// Westford") does not make a place a word.
    static func isContentObject(_ term: String, in lowercasedText: String) -> Bool {
        occurrences(of: term, in: lowercasedText).contains(where: \.isContentObject)
    }

    /// A LOCATION shape around `term`: after a place preposition (incl.
    /// "of" — see Way 1), or beside a media noun ("videos cape cod",
    /// "cape cod videos", "anything cape cod").
    static func hasLocationShape(_ term: String, in lowercasedText: String) -> Bool {
        occurrences(of: term, in: lowercasedText).contains(where: \.isLocation)
    }

    static func tokens(_ value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
