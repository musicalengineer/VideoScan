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

/// Any JSON value, kept so that what we write back has the SAME VALUE we
/// read (codex review 2026-10-02 #4 — before, every number outside Int64
/// became a Double and UInt64.max came back as ...616).
///
/// Numbers are held in the narrowest exact type. Decimal is read FIRST —
/// JSONDecoder builds it from the literal's digits in base 10, so it is
/// the exact reading — and Int64 / UInt64 are accepted only when they
/// EQUAL that reading (codex cycle #29 F3: Foundation's Int64 slow path
/// rounds "1.0000000000000001" through Double to 1 and would otherwise
/// have been taken at its word). What Decimal cannot hold (exponents
/// beyond roughly ±128, e.g. 1.5e300 or 5e-324 — exactly the values a
/// Double wrote in the first place) is a Double.
/// The VALUE survives; the SPELLING is JSONEncoder's (`1e3` → `1000`,
/// `1.0` → `1`), so canonically spelled numbers come back byte for byte.
/// The one value-loss left: a literal with more than 38 significant digits
/// keeps 38 — no Swift numeric type can write such a literal
/// (docs/practices/invariants/Catalog.md, "Known and accepted").
///
/// (For Rick: think `std::variant<int64_t, uint64_t, decimal128, double, …>`
/// where the parser reads the exact decimal first and only then asks
/// "does a narrower alternative hold this very value?")
public indirect enum CatalogJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Integers above Int64.max (UInt64 range).
    case uint(UInt64)
    /// Non-integers and integers beyond 64 bits, up to 38 significant
    /// digits, held in base 10 so nothing is rounded to binary.
    case decimal(Decimal)
    /// What Decimal cannot hold (huge / tiny exponents) and negative zero.
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
        // Decimal FIRST: JSONDecoder parses it from the literal's digits (no
        // binary detour), so it is the exact reading the integer cases are
        // validated against (codex cycle #29 F3 — Foundation's Int64 slow
        // path accepts "1.0000000000000001" as 1 by way of Double). It
        // REFUSES a literal outside Decimal's exponent range, which then
        // falls through to Double — the type that wrote it.
        if let m = try? c.decode(Decimal.self), m.isFinite {
            // `-0` / `-0.0`: Decimal has no negative zero; keep the sign.
            if m == 0, let d = try? c.decode(Double.self), d.sign == .minus {
                self = .double(d); return
            }
            if let i = try? c.decode(Int64.self), Decimal(i) == m { self = .int(i); return }
            if let u = try? c.decode(UInt64.self), Decimal(u) == m { self = .uint(u); return }
            self = .decimal(m); return
        }
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
        case .uint(let u):
            var c = encoder.singleValueContainer(); try c.encode(u)
        case .decimal(let m):
            var c = encoder.singleValueContainer(); try c.encode(m)
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
