// ArchivistQueryAST+TranslatorDecoding.swift
// Decoding what the MODEL wrote — tolerant of benign extras, hostile to the
// fields that have caused wrong answers — as opposed to the strict Codable
// conformance in ArchivistQueryAST.swift, which is the wire format between
// our own layers. Moved out unchanged on 2026-09-07 night; pinned by
// ArchivistQueryASTTranslatorDecodingTests and OllamaDecodeFailureDetailTests.

import Foundation

// MARK: - Translator-output decoding (tolerant of benign model extras)

/// The strict Codable above is the wire CONTRACT and stays strict: unknown
/// keys, misplaced constraint fields, bad enum values, and empty required
/// lists are rejected. This entry point sits in front of it for text that
/// came from the translator model, which — schema or not — occasionally
/// decorates a correct answer with harmless extras (`"limit":1` on a
/// presence payload for "how many…", `"confidence"`, `"explanation"`, a
/// `null` for an optional field). Failing the whole turn on those threw
/// away good translations (Hallie log 2026-08-17, "how many videos of Donna
/// do we have?").
///
/// Rules, deliberately narrow:
///   * A key that is not any known constraint field is dropped and noted.
///     A dropped key cannot widen or narrow the evidence set because no
///     executor reads it, so the anti-hallucination contract is intact.
///   * EXCEPT keys that mean the model tried to answer instead of translate
///     ("answer", "sql", "response", …): those still fail the turn. A model
///     that is phrasing facts is not translating, and its other fields are
///     not to be trusted either.
///   * A KNOWN constraint field in the wrong place ("transcript" on a
///     presence payload, "yearStart" beside "shape") is NOT dropped — it
///     reaches the strict decoder and is rejected, because silently dropping
///     it would change the question's meaning.
///   * `limit` is presentation, not evidence: kept for aggregate (where the
///     contract defines it), dropped elsewhere.
///   * `null` for an optional field means absent; the key is dropped.
///   * List quirks are normalized: entries are trimmed, empty entries and
///     stopword-only people/keywords ("videos", "the") are dropped. A
///     required list that ends up empty is still rejected downstream.
///     Speaker pronouns in `people` ("me", "you", "myself") are KEPT even
///     though they are stopwords for keyword search — the executor binds
///     them to the owner / the archivist (2026-08-18).
///   * A graph `kinship` whose relation is a "how are we related" word
///     ("self", "related", "relationship", …) is rewritten to the
///     `relationship` operation and the relation dropped; the strict decoder
///     then still requires exactly two people, so a one-name payload fails
///     with a clear message rather than a guessed second party.
///   * A temporal `reference` written in the model's shorthand —
///     `{"explicitYear":1998}`, `{"currentSelection":true}`,
///     `"currentSelection"`, or a bare year — is rewritten to the contract's
///     `{"kind":…}` object. The meaning is unambiguous; only the spelling
///     differs (seen live from qwen3.6, 2026-08-16).
///   * An aggregate whose ONLY anchor is a selection word ("it", "this
///     video", "currentSelection") is a question about the selected record,
///     not a co-occurrence count over the catalog ("who else is in it",
///     eval cs003) → `record{currentSelection, [people]}`.
///   * A presence/cross whose keywords name a media FILE ("New
///     Hampshire.mov") is a question about that one record, not a keyword
///     sweep ("who is in New Hampshire.mov" → 29 videos, live 2026-09-02)
///     → `record{file, [people]}` carrying the people list.
extension ArchivistQueryAST {
    struct TranslatorDecoding: Sendable {
        let ast: ArchivistQueryAST
        /// Human-readable notes about what was ignored or normalized; empty
        /// when the model output was already strict. Callers log these.
        let notes: [String]
    }

    /// Every field name the contract knows, at any level. Anything else on a
    /// known object is a benign extra.
    static let knownFieldNames: Set<String> = [
        "shape", "payload", "people", "yearStart", "yearEnd", "mediaKind",
        "keywords", "transcript", "subject", "operation", "reference", "kind",
        "year", "anchorPeople", "relation", "limit", "side", "surname",
        "name", "operations",
    ]

    /// Keys whose presence means the model stopped translating and started
    /// answering. Never tolerated, at any level.
    static let hostileFieldNames: Set<String> = [
        "answer", "answers", "response", "reply", "prose", "text", "message",
        "sql", "sqlquery", "query", "result", "results", "fact", "facts",
    ]

    private static let listFieldNames: Set<String> = [
        "people", "keywords", "transcript", "anchorPeople",
    ]
    private static let requiredListFieldNames: Set<String> = [
        "anchorPeople",
    ]

    static func decodeTranslatorOutput(_ data: Data) throws -> TranslatorDecoding {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              var top = object as? [String: Any] else {
            // Not a JSON object at all: let the strict decoder produce the
            // canonical error.
            return TranslatorDecoding(
                ast: try JSONDecoder().decode(ArchivistQueryAST.self, from: data),
                notes: [])
        }

        var notes: [String] = []
        top = recordScopeRewrite(top, notes: &notes)
        let shape = top["shape"] as? String
        top = try sanitize(top, path: "", shape: shape, notes: &notes)
        if var payload = top["payload"] as? [String: Any] {
            payload = try sanitize(payload, path: "payload.", shape: shape,
                                   notes: &notes)
            if shape == "temporal", let reference = payload["reference"],
               let rewritten = canonicalReference(reference) {
                payload["reference"] = rewritten
                notes.append("rewrote shorthand payload.reference")
            }
            if var reference = payload["reference"] as? [String: Any] {
                reference = try sanitize(reference, path: "payload.reference.",
                                         shape: shape, notes: &notes)
                payload["reference"] = reference
            }
            if shape == "graph" {
                payload = canonicalGraphPayload(payload, notes: &notes)
            }
            top["payload"] = payload
        }

        let cleaned = try JSONSerialization.data(withJSONObject: top)
        let ast = try JSONDecoder().decode(ArchivistQueryAST.self, from: cleaned)
        return TranslatorDecoding(ast: ast, notes: notes)
    }

    /// Rewrites (a) and (b) from the doc comment above: a catalog-wide shape
    /// that is really about ONE record becomes `record`. Runs on the raw
    /// object, before list normalization would drop "it" as a stopword.
    private static func recordScopeRewrite(
        _ top: [String: Any],
        notes: inout [String]
    ) -> [String: Any] {
        guard let shape = top["shape"] as? String,
              let payload = top["payload"] as? [String: Any] else { return top }
        var result = top
        if shape == "aggregate",
           let anchors = payload["anchorPeople"] as? [String],
           anchors.count == 1, Record.isSelectionWord(anchors[0]) {
            result["shape"] = "record"
            result["payload"] = [
                "reference": ["kind": "currentSelection"],
                "operations": ["people"],
            ] as [String: Any]
            notes.append("rewrote aggregate anchored on '\(anchors[0])' to record{currentSelection}")
            return result
        }
        if shape == "presence" || shape == "cross",
           let keywords = payload["keywords"] as? [String],
           let file = keywords.first(where: Record.endsWithMediaExtension) {
            var rewritten: [String: Any] = [
                "reference": ["kind": "file",
                              "name": file.trimmingCharacters(in: .whitespacesAndNewlines)],
                "operations": ["people"],
            ]
            if let people = payload["people"] { rewritten["people"] = people }
            result["shape"] = "record"
            result["payload"] = rewritten
            let dropped = keywords.filter { $0 != file }
                + ((payload["transcript"] as? [String]) ?? [])
            var note = "rewrote \(shape) naming file '\(file)' to record{file}"
            if !dropped.isEmpty {
                note += " (dropped keywords: \(dropped.joined(separator: ", ")))"
            }
            notes.append(note)
            return result
        }
        return top
    }

    /// Graph-payload spellings the model uses for meanings the contract
    /// already has: "family tree"/"ancestors"/"lineage" → familyTree, and
    /// colloquial kinship words ("grandma", "great grandmother", "maternal
    /// great-grandmother" → relation + side, "mom" → mother). Only the
    /// spelling changes; an unknown word is left for the strict decoder to
    /// reject, never guessed.
    private static func canonicalGraphPayload(
        _ payload: [String: Any],
        notes: inout [String]
    ) -> [String: Any] {
        var result = payload
        if let operation = payload["operation"] as? String,
           Graph.Operation(rawValue: operation) == nil {
            let key = operation.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            let treeWords: Set<String> = [
                "familytree", "tree", "ancestors", "ancestry", "ancestor",
                "descendants", "descendant", "lineage", "pedigree",
                "genealogy", "family", "familyhistory", "relatives",
            ]
            if treeWords.contains(key) {
                result["operation"] = "familyTree"
                notes.append("rewrote payload.operation '\(operation)' to familyTree")
            } else if let known = Graph.Operation(rawValue: key)
                        ?? (key == "bio" ? .biography : nil) {
                result["operation"] = known.rawValue
                notes.append("rewrote payload.operation '\(operation)' to \(known.rawValue)")
            }
        }
        // "how am I related to you" → kinship + relation "self"/"related"
        // (seen live from qwen3.6, 2026-08-18: `"relation":"sel…"`). The
        // meaning is the symmetric relationship operation; only the spelling
        // is wrong. Rewrite the operation, drop the pseudo-relation.
        if result["operation"] as? String == "kinship",
           let relation = payload["relation"] as? String {
            let key = relation.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let relationshipWords: Set<String> = [
                "self", "related", "relation", "relationship", "relative",
                "related to", "relatedto", "how related", "connection",
                "connected", "kin", "kinship", "any", "unknown",
            ]
            if relationshipWords.contains(key) {
                result["operation"] = "relationship"
                result["relation"] = nil
                notes.append("rewrote kinship relation '\(relation)' to the relationship operation")
            }
        }
        if let operation = payload["operation"] as? String,
           Graph.Operation(rawValue: operation) == nil,
           ["relationship", "related", "relation", "howrelated", "relatedto",
            "connection", "kin"].contains(
                operation.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")),
           result["operation"] as? String != "relationship" {
            result["operation"] = "relationship"
            result["relation"] = nil
            notes.append("rewrote payload.operation '\(operation)' to relationship")
        }
        if result["operation"] as? String == "relationship",
           let people = result["people"] as? [String], people.count == 1,
           people[0].lowercased().hasPrefix("me and ") || people[0].lowercased().hasPrefix("me & ") {
            // "me and you" packed into ONE entry — split, never invent.
            let parts = people[0].components(separatedBy: " and ")
                .flatMap { $0.components(separatedBy: " & ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count == 2 {
                result["people"] = parts
                notes.append("split payload.people '\(people[0])' into two entries")
            }
        }
        if let relation = result["relation"] as? String,
           Graph.Relation(rawValue: relation) == nil {
            var canonical: String?
            var impliedSide: String?
            if let single = GedcomFamilyGraph.relation(fromWord: relation) {
                canonical = single.rawValue
            } else if let extended = GedcomFamilyGraph.extendedRelation(
                fromPhrase: relation) {
                canonical = extended.relation.rawValue
                impliedSide = extended.side?.rawValue
            }
            if let canonical {
                result["relation"] = canonical
                notes.append("rewrote payload.relation '\(relation)' to '\(canonical)'")
            }
            if let impliedSide, payload["side"] == nil {
                result["side"] = impliedSide
                notes.append("derived payload.side '\(impliedSide)' from relation wording")
            }
        }
        if let side = payload["side"] as? String,
           Graph.Side(rawValue: side) == nil {
            let key = side.lowercased()
            let mapped: String? = key.contains("mother") || key.contains("maternal")
                ? "maternal"
                : key.contains("father") || key.contains("paternal")
                    ? "paternal" : nil
            if let mapped {
                result["side"] = mapped
                notes.append("rewrote payload.side '\(side)' to '\(mapped)'")
            }
        }
        // "the Breens" offered as a person is a surname roll-up in disguise.
        if result["operation"] as? String == "familyTree",
           result["surname"] == nil,
           let people = result["people"] as? [String], people.count == 1,
           let only = people.first {
            let lowered = only.lowercased().trimmingCharacters(in: .whitespaces)
            if lowered.hasPrefix("the "), lowered.hasSuffix("s") {
                result["surname"] = String(only.dropFirst(4))
                result["people"] = [String]()
                notes.append("rewrote payload.people '\(only)' to surname")
            }
        }
        return result
    }

    /// Contract form for a temporal reference the model wrote in shorthand;
    /// nil when it is already an object with "kind" (or unrecognizable, in
    /// which case the strict decoder reports it).
    private static func canonicalReference(_ value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let kind = object["kind"] as? String {
                // `{"kind":"explicitYear","value":1998}` — right kind, wrong
                // key for the number (seen live from qwen3.6, 2026-08-17).
                guard kind == "explicitYear", object["year"] == nil,
                      object.count == 2,
                      let year = (object["value"] ?? object["explicitYear"]) as? Int
                else { return nil }
                return ["kind": "explicitYear", "year": year]
            }
            let keys = Set(object.keys.map { $0.lowercased() })
            if keys == ["explicityear"],
               let year = object.values.first as? Int {
                return ["kind": "explicitYear", "year": year]
            }
            if keys == ["currentselection"] {
                return ["kind": "currentSelection"]
            }
            return nil
        }
        if let text = value as? String {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.lowercased() == "currentselection" {
                return ["kind": "currentSelection"]
            }
            if let year = Int(key), yearRange.contains(year) {
                return ["kind": "explicitYear", "year": year]
            }
            return nil
        }
        if let year = value as? Int, yearRange.contains(year) {
            return ["kind": "explicitYear", "year": year]
        }
        return nil
    }

    private static func sanitize(
        _ object: [String: Any],
        path: String,
        shape: String?,
        notes: inout [String]
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            let isPayloadLevel = path == "payload."
            if hostileFieldNames.contains(key.lowercased()) {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "translator attempted to answer: field "
                        + "\(path)\(key) is not a translation"))
            }
            if !knownFieldNames.contains(key)
                || (key == "limit" && !(isPayloadLevel && shape == "aggregate")) {
                notes.append("ignored extra field \(path)\(key)")
                continue
            }
            if value is NSNull {
                notes.append("dropped null \(path)\(key)")
                continue
            }
            if isPayloadLevel, listFieldNames.contains(key),
               let list = value as? [Any] {
                let strings = list.compactMap { $0 as? String }
                guard strings.count == list.count else {
                    result[key] = value        // non-string entries: strict rejects
                    continue
                }
                let kept = normalizeList(strings, field: key, path: path,
                                         notes: &notes)
                if kept.isEmpty, !requiredListFieldNames.contains(key),
                   !(key == "people" && shape == "graph") {
                    if !strings.isEmpty {
                        notes.append("dropped now-empty list \(path)\(key)")
                    }
                    continue
                }
                result[key] = kept
                continue
            }
            result[key] = value
        }
        return result
    }

    private static func normalizeList(
        _ values: [String],
        field: String,
        path: String,
        notes: inout [String]
    ) -> [String] {
        var kept: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                notes.append("dropped empty entry in \(path)\(field)")
                continue
            }
            if field == "people", HallieTurnExecutor.isSpeakerPronoun(value) {
                // "you"/"me" are stopwords for keyword search but PEOPLE
                // here: the executor binds them (2026-08-18 log evidence:
                // people:["you"]). Kept verbatim.
                if kept.contains(value) {
                    notes.append("dropped duplicate \(field) entry '\(value)'")
                    continue
                }
                kept.append(value)
                continue
            }
            if field == "keywords" || field == "people" || field == "anchorPeople",
               ArchivistKeywordText.significantTokens(value).isEmpty,
               !ArchivistKeywordText.tokens(value).isEmpty {
                notes.append("dropped stopword-only \(field) entry '\(value)'")
                continue
            }
            if kept.contains(value) {
                notes.append("dropped duplicate \(field) entry '\(value)'")
                continue
            }
            kept.append(value)
        }
        return kept
    }
}
