// CatalogUnknownFields.swift
// Forward compatibility for catalog.json (GH #167, Rick 2026-10-02:
// "make sure we don't run into forward/backward compat issues, so we
// don't need to be psychotic about it, just polite").
//
// The incident class: an older build read catalog.json, did not know a
// field a newer build had added (masterArchive, archiveFixity on 8/15),
// and saved the catalog back WITHOUT it. Swift's Codable silently ignores
// keys it has no CodingKey for, so the loss made no noise.
//
// The fix here is the polite half: whatever JSON key a build does not
// recognise — at the top level of catalog.json or inside a record — is
// kept verbatim as a `CatalogJSONValue` and written back unchanged on the
// next save. A future build that adds a field therefore survives a round
// trip through today's build, and adding a field no longer needs a
// version bump (see docs/practices/invariants/Catalog.md for the rule).
//
// Two rules make this safe:
//   1. Unknown keys NEVER override known fields. Capture skips every key
//      the type knows; emit skips them again (belt and braces), so a
//      known field is always written from the typed property.
//   2. Cost is paid only by records that carry unknown keys. Records
//      without any keep an empty dictionary (the shared empty singleton —
//      no allocation) and encode byte-identically to before.
//
// Memory: one `CatalogJSONValue` tree per unknown key actually present.
// Worst case is proportional to the unknown JSON itself (the bytes were
// already in memory as the decoder's input), never to the record count.
//
// For Rick: `CatalogJSONValue` is a tagged union (C++ `std::variant`) over
// the six JSON shapes; `indirect` lets a case hold the enum recursively
// (≈ a variant whose array/object alternatives hold heap pointers).

import Foundation

/// Any JSON value, kept losslessly enough to write back what we read:
/// integers that fit Int64 stay integers, everything else numeric is a
/// Double (a UInt64 above Int64.max or a >17-digit decimal loses its last
/// digits — no catalog field has ever been shaped like that).
public indirect enum CatalogJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CatalogJSONValue])
    case object([String: CatalogJSONValue])

    public init(from decoder: Decoder) throws {
        // Object / array first: a single-value container cannot hold them,
        // and asking for the wrong container kind throws cheaply.
        if let keyed = try? decoder.container(keyedBy: CatalogAnyCodingKey.self) {
            var out: [String: CatalogJSONValue] = [:]
            out.reserveCapacity(keyed.allKeys.count)
            for key in keyed.allKeys {
                out[key.stringValue] = try keyed.decode(CatalogJSONValue.self, forKey: key)
            }
            self = .object(out)
            return
        }
        if var list = try? decoder.unkeyedContainer() {
            var out: [CatalogJSONValue] = []
            if let n = list.count { out.reserveCapacity(n) }
            while !list.isAtEnd {
                out.append(try list.decode(CatalogJSONValue.self))
            }
            self = .array(out)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before numbers: JSONDecoder refuses to read `1` as Bool and
        // `true` as a number, so the order only matters for clarity.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognised JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer(); try c.encode(i)
        case .double(let d):
            var c = encoder.singleValueContainer(); try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .object(let o):
            var c = encoder.container(keyedBy: CatalogAnyCodingKey.self)
            // Sorted so the bytes are deterministic run to run.
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                try c.encode(v, forKey: CatalogAnyCodingKey(k))
            }
        }
    }
}

/// A CodingKey that accepts any string — the "give me every key" lens on a
/// keyed container. (≈ iterating a std::map<string, …> instead of reading
/// named struct members.)
public struct CatalogAnyCodingKey: CodingKey, Hashable, Sendable {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

/// The capture / emit pair every catalog Codable type uses. One place, so
/// the record and the top-level snapshot follow the same two rules.
public enum CatalogUnknownFields {

    /// Every key in `decoder`'s object that is NOT in `known`, decoded as a
    /// `CatalogJSONValue`. Empty (and allocation-free) when there are none.
    public static func capture(from decoder: Decoder,
                               known: Set<String>) throws -> [String: CatalogJSONValue] {
        let any = try decoder.container(keyedBy: CatalogAnyCodingKey.self)
        var out: [String: CatalogJSONValue] = [:]
        for key in any.allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try any.decode(CatalogJSONValue.self, forKey: key)
        }
        return out
    }

    /// Write `fields` into `encoder`'s CURRENT object, skipping any key in
    /// `known` (a known field is only ever written from its typed
    /// property). Call AFTER the typed keys are encoded; JSONEncoder hands
    /// back the same object for a second keyed container. Sorted keys keep
    /// the bytes deterministic.
    public static func emit(_ fields: [String: CatalogJSONValue],
                            known: Set<String>,
                            to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var c = encoder.container(keyedBy: CatalogAnyCodingKey.self)
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) where !known.contains(k) {
            try c.encode(v, forKey: CatalogAnyCodingKey(k))
        }
    }

    /// Union for a reconcile (live reload): keys `incoming` carries replace
    /// ours, keys only we carry stay. Known keys are never admitted.
    public static func merged(_ ours: [String: CatalogJSONValue],
                              with incoming: [String: CatalogJSONValue],
                              known: Set<String>) -> [String: CatalogJSONValue] {
        guard !incoming.isEmpty else { return ours }
        var out = ours
        for (k, v) in incoming where !known.contains(k) { out[k] = v }
        return out
    }
}
