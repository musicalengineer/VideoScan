// CatalogJSONValue.swift
// A lossless JSON value for the catalog importer (step D′,
// docs/design/catalog_contract_freeze_2026_10_17.md). The importer keeps
// EVERY row verbatim (`quarantine.raw_row`, `knowledge_sources.value_json`,
// `derived_unverified.value_json`), and "nothing the JSON carried is merged
// away" (contract, header), so the row is held as a tree of these values
// beside the typed mirror — a key the typed decode could not read is still
// here.
//
// Pure value type: no file I/O. Numbers are kept as Int64 when the text was
// an integer and as Double otherwise, so `2` and `2.0` both survive as the
// importer read them.
//
// (For Rick: a tagged union ≈ `std::variant<null, bool, int64, double,
// string, vector, map>` with a JSON reader/writer.)

import Foundation

public enum CatalogJSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CatalogJSONValue])
    case object([String: CatalogJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([CatalogJSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: CatalogJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The object's member, or nil (not an object, or no such key).
    public subscript(key: String) -> CatalogJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: CatalogJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [CatalogJSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Integer value; a Double with no fractional part also answers.
    public var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e18: return Int64(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    // MARK: - Codec

    /// Sorted keys, slashes unescaped: the same value always gives the same
    /// bytes (the comparator compares `value_json` text by this encoding).
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// The canonical text of this value (sorted keys).
    public func canonicalText() -> String {
        guard let data = try? Self.makeEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Any Encodable value as a CatalogJSONValue (encode, then read back).
    public static func of<T: Encodable>(_ value: T) throws -> CatalogJSONValue {
        let data = try makeEncoder().encode(value)
        return try JSONDecoder().decode(CatalogJSONValue.self, from: data)
    }

    /// Decode a typed value back out of this tree.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try Self.makeEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Dates

/// An ISO-8601 instant as the catalog wrote it (`JSONEncoder .iso8601`,
/// whole seconds — contract §a "Precision"), plus the INTEGER unix seconds
/// the DDL stores. Millisecond text (BackupAttestation.Timestamp) also reads;
/// the seconds are floored. Text that is not ISO-8601 fails to decode, so
/// the key lands in `VideoRecordJSON.undecodable` and stays in `raw`.
public struct CatalogJSONDate: Codable, Sendable, Equatable, Hashable {
    /// The text exactly as it was in the file.
    public let text: String
    /// Unix seconds (floor).
    public let unixSeconds: Int64

    public init(text: String) throws {
        guard let seconds = Self.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an ISO-8601 date: \(text)"))
        }
        self.text = text
        self.unixSeconds = seconds
    }

    public init(unixSeconds: Int64) {
        self.unixSeconds = unixSeconds
        self.text = Self.format(unixSeconds)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let seconds = Self.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
        }
        text = s
        unixSeconds = seconds
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)` → floored unix seconds; nil for
    /// anything else. Hand-written (no DateFormatter): pure, Sendable, and
    /// cheap enough for 100k rows.
    public static func parse(_ s: String) -> Int64? {
        let b = Array(s.utf8)
        func digits(_ at: Int, _ n: Int) -> Int? {
            guard at + n <= b.count else { return nil }
            var v = 0
            for i in at..<(at + n) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var i = 19
        if i < b.count, b[i] == 46 {                       // '.' fractional seconds: floored away
            i += 1
            let fracStart = i
            while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            guard i > fracStart else { return nil }
        }
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] == 90 || b[i] == 122 {                     // 'Z'
            i += 1
        } else if b[i] == 43 || b[i] == 45 {               // '+' / '-'
            guard let oh = digits(i + 1, 2), i + 3 < b.count, b[i + 3] == 58, let om = digits(i + 4, 2) else { return nil }
            offset = (oh * 3_600 + om * 60) * (b[i] == 43 ? 1 : -1)
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Int64(days) * 86_400 + Int64(hour * 3_600 + minute * 60 + second - offset)
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` (the catalog's own whole-second form).
    public static func format(_ t: Int64) -> String {
        let days = Int(t >= 0 ? t / 86_400 : (t - 86_399) / 86_400)
        let secs = Int(t - Int64(days) * 86_400)
        let (y, m, d) = civilFromDays(days)
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let year = String(repeating: "0", count: max(0, 4 - String(y).count)) + String(y)
        return "\(year)-\(two(m))-\(two(d))T\(two(secs / 3_600)):\(two(secs % 3_600 / 60)):\(two(secs % 60))Z"
    }

    /// Howard Hinnant's days_from_civil (proleptic Gregorian, 1970-01-01 = 0).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The inverse (civil_from_days).
    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
