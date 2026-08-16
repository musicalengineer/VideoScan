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
// re-quoted by the composer alone. The production translator strictly
// rejects unknown wire fields/enum values and oversized lists; the
// normalizer still drops unsafe values as defense in depth for specs built
// by other callers. An all-empty result means "fall back to literal
// substring search" — never an error dialog.

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

    static let wireKeys: Set<String> = [
        "people", "yearStart", "yearEnd", "mediaKind", "keywords",
        "transcript", "intent",
    ]
    static let wireMediaKinds: Set<String> = [
        "video", "video-only", "audio", "both",
    ]

    /// Decode model output under the actual QueryAST wire contract. Swift's
    /// synthesized Decodable silently ignores unknown keys and accepts null
    /// for optional arrays/intent, even though the Ollama schema forbids both.
    /// The model endpoint is not trusted to enforce its requested schema, so
    /// production validates independently before decoding.
    static func decodeStrictWire(_ data: Data) throws -> NLQuerySpec {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NLQuerySpecWireError.invalid("not a JSON object")
        }
        guard let object = raw as? [String: Any] else {
            throw NLQuerySpecWireError.invalid("top level is not an object")
        }

        let unknown = Set(object.keys).subtracting(wireKeys).sorted()
        guard unknown.isEmpty else {
            throw NLQuerySpecWireError.invalid(
                "unknown field(s): \(unknown.joined(separator: ", "))")
        }

        for key in ["people", "keywords", "transcript"] {
            guard let value = object[key] else { continue } // sparse v1
            guard let items = value as? [Any] else {
                throw NLQuerySpecWireError.invalid("\(key) is not an array")
            }
            guard items.count <= NLQueryNormalizer.maxListItems else {
                throw NLQuerySpecWireError.invalid(
                    "\(key) exceeds \(NLQueryNormalizer.maxListItems) items")
            }
        }

        if let value = object["intent"] {
            guard let intent = value as? String,
                  intent == "filter" || intent == "count" else {
                throw NLQuerySpecWireError.invalid(
                    "intent must be filter or count")
            }
        }
        if let value = object["mediaKind"], !(value is NSNull) {
            guard let mediaKind = value as? String,
                  wireMediaKinds.contains(mediaKind) else {
                throw NLQuerySpecWireError.invalid("unknown mediaKind")
            }
        }

        do {
            return try JSONDecoder().decode(NLQuerySpec.self, from: data)
        } catch {
            throw NLQuerySpecWireError.invalid(
                "field type does not match the schema")
        }
    }
}

enum NLQuerySpecWireError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        guard case .invalid(let detail) = self else { return nil }
        return "invalid query specification: \(detail)"
    }
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
        // Media-generic noise is DROPPED: the LLM routinely emits the
        // question's carrier words ("clips", "videos", "footage") as
        // keywords, and under AND semantics one such token zeroes the
        // whole search — 'show me clips of Donna in the 90s' composed
        // people:donna year:1990..1999 clips → 0 matches (Rick's demo
        // morning, 2026-08-07). A keyword that is ONLY noise words
        // vanishes; mixed phrases keep their meaningful words.
        query.keywords = Array(
            (spec.keywords ?? [])
                .map { sanitizeValue($0) }
                .map { keyword in
                    keyword.split(separator: " ")
                        .filter { !Self.keywordNoise.contains(String($0)) }
                        .joined(separator: " ")
                }
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

    /// The question's carrier words — media types and viewing verbs
    /// that describe the ASK, not the content. Never useful as required
    /// substrings; deadly under AND semantics.
    static let keywordNoise: Set<String> = [
        "clip", "clips", "video", "videos", "movie", "movies", "film",
        "films", "footage", "media", "recording", "recordings", "show",
        "shows", "watch", "see", "find", "display", "all", "any", "some",
    ]

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

enum NLQueryInputPolicy {
    /// True when the user already supplied recognized catalog grammar.
    /// Such input is executable as-is and must not make an unnecessary LLM
    /// round trip. Quoted `"people:donna"` remains a literal phrase because
    /// the production tokenizer reports it as `.substring`, not `.field`.
    static func isStructuredInfix(_ text: String) -> Bool {
        if pfTokenizeSearchQuery(text).contains(where: { token in
            if case .field = token { return true }
            return false
        }) {
            return true
        }

        // `year:` and `decade:` tokenize to `.yearRange`, the same case as
        // natural shorthand like `1990s`; inspect only unquoted raw tokens
        // so shorthand still goes through natural-language translation.
        for raw in text.split(whereSeparator: {
            $0.isWhitespace || $0 == "," || $0 == ";"
        }) {
            let token = String(raw)
            guard !token.hasPrefix("\"") && !token.hasPrefix("'"),
                  let colon = token.firstIndex(of: ":") else { continue }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            if key == "year", pfParseYearRangeValue(value) != nil {
                return true
            }
            if key == "decade", pfParseDecadeValue(value) != nil {
                return true
            }
        }
        return false
    }
}
