// AnthropicSchemaSanitizer.swift
// The copy of a Hallie JSON schema that Anthropic's structured outputs will
// accept (2026-11-08).
//
// WHY. The cloud brain constrains its reply with `output_config.format`
// (json_schema) instead of a forced tool call: forced `tool_choice` is a 400
// on claude-sonnet-5-5 / claude-opus-5-5. Structured outputs accept only a
// subset of JSON Schema, and there is no Swift SDK to trim our schemas for
// us. This is that trim, in one pure function.
//
// WHAT CHANGES (only in the copy sent to Anthropic):
//   - every object schema gets `"additionalProperties": false` (required;
//     any other value is refused);
//   - `oneOf` becomes `anyOf` (`oneOf` is refused — verified live 2026-11-08);
//   - numeric bounds (`minimum`, `maximum`, `exclusiveMinimum`,
//     `exclusiveMaximum`, `multipleOf`), string lengths (`minLength`,
//     `maxLength`) and array bounds (`maxItems`, `uniqueItems`, `minItems`
//     other than 0 or 1) are dropped;
//   - `anyOf` branches identical but for one property's `enum` are merged
//     into one branch with the union of the enums. This is an EXACT
//     rewrite (A∪B of closed objects that differ only there), and it is
//     load-bearing: the full interpretation schema (7 branches, event and
//     cross sharing one payload) was refused live on 2026-11-08 with "The
//     compiled grammar is too large"; merged (6 branches) it is accepted.
//     The grammar budget is not documented; the scale tripwire in
//     AnthropicSchemaSanitizerTests pins the accepted size.
// WHAT DOES NOT. The local decoders (HallieBrainDecoding) and the verifier
// still enforce the full rules — every bound dropped here is re-checked on
// the reply, so a looser constraint can only cost a repair retry, never let
// an out-of-range value through.
//
// Keyword-aware walk: the keys of `properties` / `$defs` are field NAMES, not
// keywords, so a field called "minimum" survives. `enum`, `const`,
// `required` and `default` are values and are copied untouched.
//
// Memory: one copy of a schema (a few KB); nothing cached.

import Foundation

enum AnthropicSchemaSanitizer {

    /// Keywords structured outputs refuse; removed wherever they appear in a
    /// schema position.
    static let droppedKeywords: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "maxItems", "uniqueItems",
    ]

    /// Keywords whose value is a map of name → schema.
    private static let schemaMaps: Set<String> = ["properties", "$defs", "definitions", "patternProperties"]
    /// Keywords whose value is a list of schemas.
    private static let schemaLists: Set<String> = ["anyOf", "allOf", "oneOf", "prefixItems"]
    /// Keywords whose value is one schema.
    private static let schemaSingles: Set<String> = ["items", "not", "contains"]

    static func sanitize(_ schema: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (keyword, value) in schema {
            if droppedKeywords.contains(keyword) { continue }
            switch keyword {
            case "minItems":
                // Only 0 and 1 are supported; anything stricter is the
                // decoder's job.
                if let n = value as? Int, n <= 1 { out[keyword] = n }
            case "additionalProperties":
                break  // forced to false below for every object
            case "oneOf", "anyOf":
                out["anyOf"] = mergeEnumSiblings((out["anyOf"] as? [Any] ?? []) + sanitizeList(value))
            case _ where schemaLists.contains(keyword):
                out[keyword] = sanitizeList(value)
            case _ where schemaMaps.contains(keyword):
                if let map = value as? [String: Any] {
                    out[keyword] = map.mapValues { sanitizeAny($0) }
                } else {
                    out[keyword] = value
                }
            case _ where schemaSingles.contains(keyword):
                out[keyword] = sanitizeAny(value)
            default:
                out[keyword] = value
            }
        }
        if isObjectSchema(schema) {
            out["additionalProperties"] = false
        }
        return out
    }

    /// An object schema: `type` is (or includes) "object", or it declares
    /// `properties`.
    static func isObjectSchema(_ schema: [String: Any]) -> Bool {
        if schema["properties"] != nil { return true }
        if let type = schema["type"] as? String { return type == "object" }
        if let types = schema["type"] as? [String] { return types.contains("object") }
        return false
    }

    /// Merge branches that differ only in the `enum` of one property.
    /// O(branches² × schema size); branches are single digits.
    static func mergeEnumSiblings(_ branches: [Any]) -> [Any] {
        var out: [Any] = []
        for branch in branches {
            if let index = out.indices.first(where: { mergedEnums(out[$0], branch) != nil }),
               let merged = mergedEnums(out[index], branch) {
                out[index] = merged
            } else {
                out.append(branch)
            }
        }
        return out
    }

    /// `a` with property P's enum widened by `b`'s, when `a` and `b` are
    /// equal everywhere except that one enum; otherwise nil.
    private static func mergedEnums(_ a: Any, _ b: Any) -> [String: Any]? {
        guard let a = a as? [String: Any], let b = b as? [String: Any],
              var aProps = a["properties"] as? [String: Any],
              let bProps = b["properties"] as? [String: Any],
              Set(aProps.keys) == Set(bProps.keys),
              canonical(a.filter { $0.key != "properties" }) == canonical(b.filter { $0.key != "properties" })
        else { return nil }
        let differing = aProps.keys.filter { canonical(aProps[$0]) != canonical(bProps[$0]) }
        guard differing.count == 1, let name = differing.first,
              let aField = aProps[name] as? [String: Any], let bField = bProps[name] as? [String: Any],
              let aEnum = aField["enum"] as? [Any], let bEnum = bField["enum"] as? [Any],
              canonical(aField.filter { $0.key != "enum" }) == canonical(bField.filter { $0.key != "enum" })
        else { return nil }
        var field = aField
        field["enum"] = aEnum + bEnum.filter { value in !aEnum.contains { canonical($0) == canonical(value) } }
        aProps[name] = field
        var merged = a
        merged["properties"] = aProps
        return merged
    }

    /// Order-independent bytes for equality of JSON values.
    private static func canonical(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func sanitizeAny(_ value: Any) -> Any {
        if let dict = value as? [String: Any] { return sanitize(dict) }
        return value  // a boolean schema or a malformed node: copied as is
    }

    private static func sanitizeList(_ value: Any) -> [Any] {
        (value as? [Any] ?? []).map(sanitizeAny)
    }
}
