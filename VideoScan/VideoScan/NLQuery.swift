import Foundation

// MARK: - Natural-language search: spec → validated query → infix string
//
// The "family archivist" frontend (P1, 2026-08-01). A translator brain
// (local LLM) converts a sentence like "show me videos of Donna from
// 1992 to 1995" into an NLQuerySpec — a FIXED schema, never free text.
// This file owns everything after the brain:
//
//   NLQuerySpec  --normalize-->  NLQuery  --compose-->  infix string
//   (untrusted)    (fail-closed)  (trusted)              (existing grammar)
//
// The composed string runs through the SAME pfTokenizeSearchQuery /
// CatalogSearchIndex path as a hand-typed query, and is shown to the
// user as an editable "Interpreted as:" chip. The brain never sees
// catalog content and never phrases answers about the data — Swift
// computes truth. That is the anti-hallucination contract: a wrong
// translation can only ever produce a visibly-wrong FILTER, never a
// confidently-wrong FACT.
//
// Security stance: spec values are DATA. Colons are stripped so a value
// can never mint a field token ("type:junk" as a keyword must not become
// a structural filter), quotes are stripped and multi-word values are
// re-quoted by the composer alone. Unknown media kinds, insane years,
// and over-long lists are dropped, not guessed at. An all-empty result
// means "fall back to literal substring search" — never an error dialog.

// MARK: Untrusted wire format

/// Exactly what the translator brain is asked to emit (all fields
/// optional — a sparse answer is a GOOD answer; inventing is the sin).
/// Mirrors the JSON schema sent to ollama's structured-output `format`.
struct NLQuerySpec: Codable, Equatable {
    var people: [String]?
    var yearStart: Int?
    var yearEnd: Int?
    var mediaKind: String?
    var keywords: [String]?
    var transcript: [String]?
    var intent: String?
}

// MARK: Trusted, normalized query

/// A spec that survived normalization. Every field here is safe to
/// compose into the infix grammar verbatim.
struct NLQuery: Equatable {
    enum Intent: String { case filter, count }

    var people: [String] = []        // single lowercase words
    var years: ClosedRange<Int>?     // clamped to the grammar's 1900...2099
    var mediaKind: String?           // whitelisted type: value
    var keywords: [String] = []      // may be multi-word (composer quotes)
    var transcript: [String] = []    // single lowercase words
    var intent: Intent = .filter

    /// Nothing extractable — caller should fall back to treating the
    /// user's raw text as a plain substring search.
    var isEmpty: Bool {
        people.isEmpty && years == nil && mediaKind == nil
            && keywords.isEmpty && transcript.isEmpty
    }
}

enum NLQueryNormalizer {

    /// Grammar bounds — keep in lock-step with pfParseYearRangeValue.
    static let yearBounds = 1900...2099
    /// Caps: a translation needing more than this is a bad translation.
    static let maxListItems = 6
    static let maxValueLength = 40

    /// `type:` values the composer may emit — the subset of
    /// pfMediaKindAliasMatches spellings the brain is taught, plus the
    /// synonyms we map onto them. Unknown → nil (no filter), because a
    /// typo'd type: token matches NOTHING by grammar contract.
    private static let mediaKindSynonyms: [String: String] = [
        "video": "video", "videos": "video", "movie": "video",
        "movies": "video", "clip": "video", "clips": "video",
        "film": "video", "films": "video",
        "video-only": "video-only", "videoonly": "video-only",
        "silent": "video-only",
        "audio": "audio", "audio-only": "audio", "audioonly": "audio",
        "sound": "audio", "recording": "audio", "recordings": "audio",
        "both": "both", "av": "both",
    ]

    /// Fail-closed normalization of an untrusted spec.
    static func normalize(_ spec: NLQuerySpec) -> NLQuery {
        var query = NLQuery()

        // People become per-word people: tokens ("Dad Breen" → dad, breen
        // — AND semantics across tokens matches both words in the field).
        query.people = Array(
            (spec.people ?? [])
                .flatMap { $0.split(separator: " ") }
                .map { sanitizeValue(String($0)) }
                .filter { !$0.isEmpty }
                .prefix(maxListItems))

        query.transcript = Array(
            (spec.transcript ?? [])
                .flatMap { $0.split(separator: " ") }
                .map { sanitizeValue(String($0)) }
                .filter { !$0.isEmpty }
                .prefix(maxListItems))

        // Keywords keep interior spaces (the composer quotes phrases).
        query.keywords = Array(
            (spec.keywords ?? [])
                .map { sanitizeValue($0) }
                .filter { !$0.isEmpty }
                .prefix(maxListItems))

        query.years = normalizeYears(start: spec.yearStart, end: spec.yearEnd)

        if let kind = spec.mediaKind {
            query.mediaKind = mediaKindSynonyms[
                kind.lowercased().trimmingCharacters(in: .whitespaces)]
        }

        query.intent = spec.intent?.lowercased() == "count" ? .count : .filter
        return query
    }

    /// Lowercase, trim, strip the two characters that could mint grammar
    /// structure (colon → field token, quote → phrase boundary), collapse
    /// interior whitespace runs, cap length.
    static func sanitizeValue(_ raw: String) -> String {
        let stripped = raw.lowercased()
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        let collapsed = stripped
            .split(separator: " ")
            .joined(separator: " ")
        return String(collapsed.prefix(maxValueLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Clamp to grammar bounds, tolerate a reversed or half-open pair.
    static func normalizeYears(start: Int?, end: Int?) -> ClosedRange<Int>? {
        let bounded = [start, end]
            .compactMap { $0 }
            .filter { yearBounds.contains($0) }
        guard let lo = bounded.min(), let hi = bounded.max() else { return nil }
        return lo...hi
    }
}

enum NLQueryComposer {

    /// Compose the validated query into the existing infix grammar.
    /// Deterministic field order (people, year, type, transcript,
    /// keywords) so tests and the "Interpreted as:" chip are stable.
    static func infixString(for query: NLQuery) -> String {
        var parts: [String] = []
        parts.append(contentsOf: query.people.map { "people:\($0)" })
        if let years = query.years {
            parts.append(years.lowerBound == years.upperBound
                         ? "year:\(years.lowerBound)"
                         : "year:\(years.lowerBound)..\(years.upperBound)")
        }
        if let kind = query.mediaKind {
            parts.append("type:\(kind)")
        }
        parts.append(contentsOf: query.transcript.map { "transcript:\($0)" })
        parts.append(contentsOf: query.keywords.map { keyword in
            keyword.contains(" ") ? "\"\(keyword)\"" : keyword
        })
        return parts.joined(separator: " ")
    }
}
