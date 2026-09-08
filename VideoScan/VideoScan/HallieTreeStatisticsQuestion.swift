// HallieTreeStatisticsQuestion.swift
// "how many people in the tree were born in england in total?"
//   → "The family tree has 49 people named England — which one?"
//
// Rick asked that live on 2026-09-07 and got England read as a person's name,
// because there was no route for counting. The engine existed
// (TreeStatistics, 5398c6fa) and nothing could reach it.
//
// THIS IS THE FIRST RECOGNIZER BUILT TO codex's RULE (see
// docs/hallie_intent_recognizer_design.md): a sentence is recognized only when
// the FULL supported shape is accounted for — an aggregate AND every filter
// the sentence names. A sentence carrying a constraint this cannot represent
// is ABSTAINED, not approximated, so it reaches the model instead of being
// answered narrowly and confidently. That is the difference between this and
// the three guards shipped earlier the same day, which spotted a cue and
// claimed the sentence.
//
// Pure text → query. No graph, no model, no I/O.

import Foundation
import VideoScanCore

enum HallieTreeStatisticsQuestion: Equatable, Sendable {
    /// "how many people were born in Ireland" — a count with its population.
    case count(TreeStatistics.Query)
    /// "what was the average lifespan" — a numeric summary.
    case lifespan(TreeStatistics.Query)
    /// "which countries were they born in" — grouped rows.
    case birthCountries(TreeStatistics.Query)

    var query: TreeStatistics.Query {
        switch self {
        case .count(let q), .lifespan(let q), .birthCountries(let q): return q
        }
    }

    // MARK: - Vocabulary

    private static let countAsk = /\bhow\s+many\b|\bhow\s+much\b|\bnumber\s+of\b|\bcount\s+(the|how|people)\b|\btotal\s+number\b/
    private static let averageAsk = /\baverage\b|\bmean\b|\bmedian\b|\btypical\b/
    private static let lifespanWord = /\blifespan\b|\blife\s+span\b|\blived?\s+to\b|\bage\s+at\s+death\b|\bhow\s+long\s+.{0,20}\blive[ds]?\b|\bages?\b/
    private static let groupingAsk = /\bwhich\s+countr(y|ies)\b|\bwhat\s+countr(y|ies)\b|\bcountries\b|\bby\s+country\b|\bwhere\s+were\s+they\s+(all\s+)?born\b/
    /// The sentence is about the population, not one person.
    private static let populationWord = /\bpeople\b|\bpersons?\b|\bancestors?\b|\brelatives\b|\beveryone\b|\bthey\b|\bfamily\s+tree\b|\bthe\s+tree\b|\bin\s+the\s+family\b/
    private static let ancestorScope = /\bmy\s+ancestors?\b|\bour\s+ancestors?\b|\bmy\s+line\b|\bmy\s+own\s+line\b|\bmy\s+direct\s+ancestors?\b/

    /// Constraints this recognizer cannot represent. Their presence forces an
    /// ABSTAIN rather than an answer that quietly ignores them — the whole
    /// point of the full-shape rule. "how many people born in Ireland MARRIED
    /// a Breen" is not a place count with the marriage silently dropped.
    private static let unsupportedConstraint = /\bmarried\b|\bmarriage\b|\bspouse\b|\bchildren\b|\bsons?\b|\bdaughters?\b|\bsurname\b|\bnamed\b|\bcalled\b|\bwith\s+photos?\b|\bin\s+videos?\b|\bphotos?\b|\bvideos?\b|\bper\s+(decade|century|generation)\b|\bby\s+(decade|century|generation)\b|\bgeneration\b/

    // MARK: - Recognition

    /// The recognizer. Nil = ABSTAIN: either this is not a statistics question
    /// at all, or it is one carrying a constraint we cannot honour.
    static func detect(_ question: String) -> HallieTreeStatisticsQuestion? {
        let q = question.lowercased()

        let wantsCount = q.firstMatch(of: countAsk) != nil
        let wantsAverage = q.firstMatch(of: averageAsk) != nil
        let wantsGrouping = q.firstMatch(of: groupingAsk) != nil
        guard wantsCount || wantsAverage || wantsGrouping else { return nil }

        // About the population, not one person: "how many children did he
        // have" is a kinship question that happens to start with "how many".
        guard q.firstMatch(of: populationWord) != nil else { return nil }

        // A constraint we cannot represent means we do not answer. Checked
        // BEFORE building a query so a partial answer can never escape.
        guard q.firstMatch(of: unsupportedConstraint) == nil else { return nil }

        let scope: TreeStatistics.Scope = q.firstMatch(of: ancestorScope) != nil
            ? .ancestors(of: "", maxGenerations: LineageTrail.generationCap)
            : .wholeTree
        let time = timeFilter(in: q)
        let place = placeFilter(in: q)

        // A sentence that names a place we could not classify is abstained:
        // answering "0 people were born in Ruritania" when we simply failed to
        // read the word would be a confident lie about the tree.
        if place == nil { return nil }

        var query = TreeStatistics.Query(scope: scope, place: place ?? .anywhere, time: time.filter)
        if !time.understood { return nil }
        query.place = place ?? .anywhere

        if wantsAverage, q.firstMatch(of: lifespanWord) != nil { return .lifespan(query) }
        if wantsGrouping { return .birthCountries(query) }
        if wantsCount { return .count(query) }
        // "average" with no measurable quantity named — "what is the average
        // family like" — is not ours.
        return nil
    }

    // MARK: - Filters

    /// Nil = a place was named that we could not classify → abstain.
    /// `.anywhere` = no place named at all, which is a fine whole-tree ask.
    private static func placeFilter(in q: String) -> TreeStatistics.PlaceFilter? {
        // "outside the US" and its cousins.
        if q.firstMatch(of: /\b(outside|out\s+of|beyond|not\s+in)\s+(of\s+)?(the\s+)?(usa|u\.?s\.?a?\.?|united\s+states|america|the\s+states|this\s+country)\b|\babroad\b|\boverseas\b|\bforeign(-|\s)born\b|\banother\s+countr(y|ies)\b/) != nil {
            return .outsideCountry(BirthplaceClassifier.unitedStates)
        }
        // A continent by name.
        for continent in BirthplaceClassifier.Continent.allCases
        where q.range(of: "\\b\(NSRegularExpression.escapedPattern(for: continent.rawValue.lowercased()))\\b",
                      options: .regularExpression) != nil {
            return .continent(continent)
        }
        // "born in <somewhere>", and also "birthplace in <somewhere>" — Rick
        // asked both ways within a minute ("were born in england in total",
        // "have a birthplace in the coubtry of england"), and only the first
        // was matched.
        guard let match = q.firstMatch(
            of: /\b(?:born|birth\s*place|place\s+of\s+birth)\s+(?:in|at)\s+(?:the\s+)?(?:countr(?:y|ies)\s+of\s+)?([a-z][a-z .'’-]{1,40})/) else {
            return .anywhere
        }
        let raw = String(match.1)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+(in\s+total|total|altogether|overall|and|or)\s*$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?"))
        guard !raw.isEmpty else { return .anywhere }
        // A bare article is what is left when the sentence said "born in the
        // 1840s": the year is a TIME filter that has already been read, and
        // there is no place here at all. Without this the recognizer captured
        // "the", failed to classify it, and abstained from a question it can
        // answer perfectly well.
        if ["the", "a", "an", "this", "that"].contains(raw) { return .anywhere }
        // A year is a time filter that already ran, not a place.
        if raw.range(of: #"^\d{3,4}$"#, options: .regularExpression) != nil { return .anywhere }

        // A COUNTRY OF THE UNITED KINGDOM IS NOT THE UNITED KINGDOM, for
        // counting purposes. The classifier maps England, Scotland, Wales and
        // Northern Ireland to "United Kingdom", which is correct for asking
        // whether a birth was in Europe and WRONG for "how many were born in
        // England": it would silently return 13,622 (the whole UK) where Rick
        // asked about 11,280. Matching the recorded text keeps his question's
        // meaning; the classifier still owns continent membership everywhere
        // else.
        // Checked on the LAST WORD as well as the whole phrase. Rick typed
        // "birthplace in the coubtry of england" — one transposed letter, so
        // the "country of" pattern did not match and the captured place was
        // "coubtry of england". The classifier's own tail-token fallback still
        // found England and returned the United Kingdom, walking straight past
        // an exact-string check. A typo should not silently widen a count from
        // 11,280 to 13,622.
        let classified = BirthplaceClassifier.classify(raw)
        if let country = classified.country, !classified.isAmbiguous {
            // The last-word check runs ONLY when the phrase already classifies
            // as the United Kingdom. My first version tested the last word
            // first and was about to read "new england" as England — its own
            // test caught it — which would have counted Massachusetts births
            // as English ones. "New England" classifies as the United States,
            // never reaches this branch, and keeps its country filter.
            if country == BirthplaceClassifier.unitedKingdom {
                let lastWord = raw.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? raw
                for constituent in ["northern ireland", "england", "scotland", "wales"]
                where raw == constituent || lastWord == constituent {
                    return .recordedText(constituent)
                }
            }
            return .country(country)
        }
        // Not a country the classifier knows. It may still be a real recorded
        // region ("new england"), which the engine can match as raw text —
        // but only when it looks like a place name rather than a stray word.
        if raw.split(whereSeparator: \.isWhitespace).count <= 3, raw.count >= 4 {
            return .recordedText(raw)
        }
        return nil
    }

    /// `understood` is false when the sentence names a time constraint whose
    /// shape we cannot represent, which abstains the whole question.
    private static func timeFilter(in q: String) -> (filter: TreeStatistics.TimeFilter,
                                                     understood: Bool) {
        var filter = TreeStatistics.TimeFilter()
        if let m = q.firstMatch(of: /\bborn\s+(?:before|prior\s+to|earlier\s+than)\s+(\d{3,4})\b/) {
            filter.bornTo = Int(m.1).map { $0 - 1 }
        }
        if let m = q.firstMatch(of: /\bborn\s+(?:after|later\s+than|since)\s+(\d{3,4})\b/) {
            filter.bornFrom = Int(m.1).map { $0 + 1 }
        }
        if let m = q.firstMatch(of: /\bborn\s+between\s+(\d{3,4})\s+and\s+(\d{3,4})\b/) {
            filter.bornFrom = Int(m.1)
            filter.bornTo = Int(m.2)
        }
        if let m = q.firstMatch(of: /\bborn\s+in\s+the\s+(\d{3,4})s\b/) {
            let decade = Int(m.1) ?? 0
            filter.bornFrom = decade
            filter.bornTo = decade + 9
        }
        // A century said in words is a shape we do not parse. Say so rather
        // than answering as if no date had been mentioned.
        let mentionsUnparsedPeriod = q.firstMatch(
            of: /\b(nineteenth|eighteenth|seventeenth|sixteenth|twentieth|fifteenth)\s+century\b|\bvictorian\b|\bmedieval\b|\bcolonial\s+(era|period|times)\b/) != nil
        return (filter, !mentionsUnparsedPeriod)
    }
}
