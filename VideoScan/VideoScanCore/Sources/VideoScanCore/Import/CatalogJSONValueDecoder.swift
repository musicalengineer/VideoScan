// CatalogJSONValueDecoder.swift
// Decodes any `Decodable` straight out of a `CatalogJSONValue` tree — the
// partner of CatalogJSONValueEncoder.swift (cutover B1). Two readers use it:
//   * `VideoRecordJSON(record:)` — the importer's own reader run over the
//     tree the app's encoder wrote (no text in between);
//   * the app's `VideoRecord.init(row:)` — the app's own decoder run over
//     the JSON row a SQLite load reassembles, so every default and load-time
//     migration of `VideoRecord.init(from:)` applies exactly as it does to
//     catalog.json.
//
// The value rules mirror JSONDecoder with the catalog's `.iso8601` dates,
// read through `CatalogJSONDate` (whole or fractional seconds, floored):
//   * a `Date` reads from ISO-8601 text; anything else is a type mismatch;
//   * an integer type reads from `.int` (or a `.double` with no fraction,
//     in range) — never from text or a Bool;
//   * `Double`/`Float` read from `.int` or `.double`;
//   * `UUID` reads from its string; `Data` from base64; `URL` from text;
//   * a missing key throws `keyNotFound`; `decodeIfPresent` answers nil for
//     a missing key or `null`, as JSONDecoder does.
//
// (For Rick: the mirror image of the encoder — a recursive-descent reader
// over the parsed tree instead of over a token stream.)

import Foundation

public struct CatalogJSONValueDecoder: Sendable {

    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from value: CatalogJSONValue) throws -> T {
        try DOMDecoding.decode(type, from: value, codingPath: [])
    }

    /// A `Decoder` over `value`, for a type's own `init(from:)` (a class's
    /// convenience init can delegate to it).
    public static func decoder(for value: CatalogJSONValue) -> Decoder {
        DOMReader(value: value, codingPath: [])
    }
}

// MARK: - The scalar rules
//
// Coding paths are built only when needed (an error, or a nested type's own
// decoder): a load decodes ~130 keys per record, 100k records at a time,
// and an array allocation per value was most of the cost (B1 scale test).

/// A coding path not yet built: the parent's path plus one key.
struct LazyPath {
    let parent: [CodingKey]
    let key: CodingKey?

    var path: [CodingKey] { key.map { parent + [$0] } ?? parent }
}

enum DOMDecoding {

    static func decode<T: Decodable>(_ type: T.Type, from value: CatalogJSONValue, at path: LazyPath) throws -> T {
        if let special = try special(type, value, path) { return special }
        return try T(from: DOMReader(value: value, codingPath: path.path))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: CatalogJSONValue, codingPath: [CodingKey]) throws -> T {
        try decode(type, from: value, at: LazyPath(parent: codingPath, key: nil))
    }

    /// The DOM itself, the common scalars (fast path, most frequent first)
    /// and the types JSONDecoder treats specially.
    private static func special<T>(_ type: T.Type, _ value: CatalogJSONValue, _ path: LazyPath) throws -> T? {
        if type == String.self { return try string(value, path) as? T }
        if type == Date.self { return try date(value, path) as? T }
        if type == Double.self { return try double(value, path) as? T }
        if type == Int.self { return try integer(Int.self, value, path) as? T }
        if type == Int64.self { return try integer(Int64.self, value, path) as? T }
        if type == Bool.self { return try bool(value, path) as? T }
        if type == UUID.self { return try uuid(value, path) as? T }
        if type == CatalogJSONValue.self { return value as? T }
        if type == Float.self { return Float(try double(value, path)) as? T }
        if type == Data.self { return try data(value, path) as? T }
        if type == URL.self { return try url(value, path) as? T }
        if let integer = type as? any FixedWidthInteger.Type { return try self.integer(integer, value, path) as? T }
        return nil
    }

    static func mismatch(_ type: Any.Type, _ value: CatalogJSONValue, _ path: [CodingKey]) -> DecodingError {
        .typeMismatch(type, .init(codingPath: path, debugDescription: "expected \(type), found \(value.canonicalText())"))
    }

    static func string(_ value: CatalogJSONValue, _ path: LazyPath) throws -> String {
        guard case .string(let s) = value else { throw mismatch(String.self, value, path.path) }
        return s
    }

    static func bool(_ value: CatalogJSONValue, _ path: LazyPath) throws -> Bool {
        guard case .bool(let b) = value else { throw mismatch(Bool.self, value, path.path) }
        return b
    }

    static func double(_ value: CatalogJSONValue, _ path: LazyPath) throws -> Double {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: throw mismatch(Double.self, value, path.path)
        }
    }

    static func integer<I: FixedWidthInteger>(_ type: I.Type, _ value: CatalogJSONValue, _ path: LazyPath) throws -> I {
        let exact: I?
        switch value {
        case .int(let i): exact = I(exactly: i)
        case .double(let d): exact = I(exactly: d)
        default: exact = nil
        }
        guard let exact else { throw mismatch(type, value, path.path) }
        return exact
    }

    static func date(_ value: CatalogJSONValue, _ path: LazyPath) throws -> Date {
        guard case .string(let s) = value, let seconds = CatalogJSONDate.parse(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path.path, debugDescription: "not an ISO-8601 date: \(value.canonicalText())"))
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func uuid(_ value: CatalogJSONValue, _ path: LazyPath) throws -> UUID {
        guard let uuid = UUID(uuidString: try string(value, path)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path.path, debugDescription: "not a UUID: \(value.canonicalText())"))
        }
        return uuid
    }

    static func data(_ value: CatalogJSONValue, _ path: LazyPath) throws -> Data {
        guard let data = Data(base64Encoded: try string(value, path)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path.path, debugDescription: "not base64"))
        }
        return data
    }

    static func url(_ value: CatalogJSONValue, _ path: LazyPath) throws -> URL {
        guard let url = URL(string: try string(value, path)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path.path, debugDescription: "not a URL"))
        }
        return url
    }
}

// MARK: - The Decoder a type's init(from:) sees

struct DOMReader: Decoder {
    let value: CatalogJSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw DOMDecoding.mismatch([String: CatalogJSONValue].self, value, codingPath)
        }
        return KeyedDecodingContainer(DOMKeyedReader<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let array) = value else {
            throw DOMDecoding.mismatch([CatalogJSONValue].self, value, codingPath)
        }
        return DOMUnkeyedReader(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        DOMSingleReader(value: value, codingPath: codingPath)
    }
}

struct DOMKeyedReader<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: CatalogJSONValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    private func member(_ key: Key) throws -> CatalogJSONValue {
        guard let v = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "no value for \(key.stringValue)"))
        }
        return v
    }

    private func read<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        try DOMDecoding.decode(type, from: try member(key), at: LazyPath(parent: codingPath, key: key))
    }

    /// One lookup for "absent or null → nil" (the default implementation
    /// asks contains, decodeNil and decode: three).
    private func readIfPresent<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        guard let v = object[key.stringValue], v != .null else { return nil }
        return try DOMDecoding.decode(type, from: v, at: LazyPath(parent: codingPath, key: key))
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try readIfPresent(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try readIfPresent(type, key) }

    func decodeNil(forKey key: Key) throws -> Bool { try member(key) == .null }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try read(type, key) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try read(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try read(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try read(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try read(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try read(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try read(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try read(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try read(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try read(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try read(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try read(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try read(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try read(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try read(type, key) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                               forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try DOMReader(value: try member(key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try DOMReader(value: try member(key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder { DOMReader(value: object["super"] ?? .null, codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder { DOMReader(value: object[key.stringValue] ?? .null, codingPath: codingPath) }
}

struct DOMUnkeyedReader: UnkeyedDecodingContainer {
    let array: [CatalogJSONValue]
    let codingPath: [CodingKey]
    private(set) var currentIndex = 0

    init(array: [CatalogJSONValue], codingPath: [CodingKey]) {
        self.array = array
        self.codingPath = codingPath
    }

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private struct Index: CodingKey {
        let intValue: Int?
        let stringValue: String
        init(_ i: Int) { intValue = i; stringValue = "Index \(i)" }
        init?(stringValue: String) { return nil }
        init?(intValue: Int) { self.init(intValue) }
    }

    private mutating func next() throws -> (CatalogJSONValue, LazyPath) {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(CatalogJSONValue.self, .init(codingPath: codingPath, debugDescription: "unkeyed container is at its end"))
        }
        defer { currentIndex += 1 }
        return (array[currentIndex], LazyPath(parent: codingPath, key: Index(currentIndex)))
    }

    private mutating func read<T: Decodable>(_ type: T.Type) throws -> T {
        let (value, path) = try next()
        return try DOMDecoding.decode(type, from: value, at: path)
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, array[currentIndex] == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try read(type) }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try read(type) }
    mutating func decode(_ type: String.Type) throws -> String { try read(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try read(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try read(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try read(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try read(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try read(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try read(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try read(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try read(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try read(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try read(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try read(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try read(type) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (value, path) = try next()
        return try DOMReader(value: value, codingPath: path.path).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let (value, path) = try next()
        return try DOMReader(value: value, codingPath: path.path).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let (value, path) = try next()
        return DOMReader(value: value, codingPath: path.path)
    }
}

struct DOMSingleReader: SingleValueDecodingContainer {
    let value: CatalogJSONValue
    let codingPath: [CodingKey]

    private func read<T: Decodable>(_ type: T.Type) throws -> T {
        try DOMDecoding.decode(type, from: value, codingPath: codingPath)
    }

    func decodeNil() -> Bool { value == .null }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try read(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try read(type) }
    func decode(_ type: String.Type) throws -> String { try read(type) }
    func decode(_ type: Double.Type) throws -> Double { try read(type) }
    func decode(_ type: Float.Type) throws -> Float { try read(type) }
    func decode(_ type: Int.Type) throws -> Int { try read(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try read(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try read(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try read(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try read(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try read(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try read(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try read(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try read(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try read(type) }
}
