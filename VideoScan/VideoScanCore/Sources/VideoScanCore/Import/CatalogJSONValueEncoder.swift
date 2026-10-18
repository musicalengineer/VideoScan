// CatalogJSONValueEncoder.swift
// Encodes any `Encodable` straight into a `CatalogJSONValue` tree — the DOM
// the importer reads — with NO JSON text in between (cutover B1,
// docs/design/catalog_cutover_f_prime_2026_10_17.md §2–§3).
//
// Why it exists: `CatalogRecordDTO.init(record: VideoRecord)` must give the
// SAME DTO the importer builds from the catalog.json bytes of that record.
// The one way to guarantee that without a second hand-written mapping of 129
// keys is to run the app's ONE encoder (`VideoRecordDTO.encode(to:)`) and
// the importer's own reader (`VideoRecordJSON.init(from:)`) — and this file
// (with CatalogJSONValueDecoder.swift) lets them meet in memory instead of
// through a 73 MB text round-trip.
//
// The value rules are the catalog encoder's (`CatalogStore`, JSONEncoder
// `.iso8601`), as the importer would SEE them after `CatalogJSONValue`
// parsed the text:
//   * `Date` → ISO-8601 whole seconds, UTC (`CatalogJSONDate.format`, floor);
//   * `Double` / `Float` with no fractional part → `.int` (JSON text "3"
//     reads back as an integer); `Float` goes through its shortest decimal
//     text first, exactly as JSONEncoder writes it ("0.7", not 0.69999…);
//   * non-finite numbers throw (JSONEncoder throws too);
//   * `UUID` → its uppercase string (its own Encodable does that);
//   * `Data` → base64 (JSONEncoder's default); `URL` → absoluteString.
//
// (For Rick: a serializer that writes into a tree of tagged unions instead
// of a char buffer — think a SAX writer building a DOM. `Encoder` is
// Swift's visitor interface: the value calls back into containers.)

import Foundation

public struct CatalogJSONValueEncoder: Sendable {

    public init() {}

    /// The value as the importer's DOM.
    public func encode<T: Encodable>(_ value: T) throws -> CatalogJSONValue {
        try DOMEncoding.encode(value, codingPath: [])
    }
}

// MARK: - The scalar rules (shared with the containers)

enum DOMEncoding {

    static func encode<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> CatalogJSONValue {
        if let special = try special(value, codingPath: codingPath) { return special }
        let node = DOMNode()
        try value.encode(to: DOMWriter(node: node, codingPath: codingPath))
        return node.value
    }

    /// The types JSONEncoder treats specially, and the DOM itself (fast path).
    private static func special<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> CatalogJSONValue? {
        switch value {
        case let v as CatalogJSONValue: return v
        case let v as String: return .string(v)
        case let v as Date: return date(v)
        case let v as UUID: return .string(v.uuidString)
        case let v as Double: return try double(v, codingPath)
        case let v as Float: return try float(v, codingPath)
        case let v as Bool: return .bool(v)
        case let v as Data: return .string(v.base64EncodedString())
        case let v as URL: return .string(v.absoluteString)
        default: return try integer(value)
        }
    }

    static func date(_ d: Date) -> CatalogJSONValue {
        .string(CatalogJSONDate.format(Int64(d.timeIntervalSince1970.rounded(.down))))
    }

    static func double(_ d: Double, _ codingPath: [CodingKey]) throws -> CatalogJSONValue {
        guard d.isFinite else {
            throw EncodingError.invalidValue(d, .init(codingPath: codingPath, debugDescription: "a non-finite number has no JSON form"))
        }
        if d.rounded() == d, abs(d) < 9.0e18 { return .int(Int64(d)) }
        return .double(d)
    }

    /// JSONEncoder writes a Float by its shortest decimal text; read that text back as a Double.
    static func float(_ f: Float, _ codingPath: [CodingKey]) throws -> CatalogJSONValue {
        guard f.isFinite else {
            throw EncodingError.invalidValue(f, .init(codingPath: codingPath, debugDescription: "a non-finite number has no JSON form"))
        }
        return try double(Double(f.description) ?? Double(f), codingPath)
    }

    /// Every fixed-width integer; nil when `value` is not one.
    static func integer<T>(_ value: T) throws -> CatalogJSONValue? {
        guard let i = value as? any BinaryInteger else { return nil }
        if let exact = Int64(exactly: i) { return .int(exact) }
        return .double(Double(i))           // above Int64.max: what the text would read back as
    }
}

// MARK: - The tree under construction

/// One node being written. A value encodes into exactly one of the three
/// shapes; `value` freezes it into the immutable DOM.
final class DOMNode {
    var scalar: CatalogJSONValue?
    var object: [String: DOMNode]?
    var array: [DOMNode]?

    init(_ scalar: CatalogJSONValue? = nil) {
        self.scalar = scalar
    }

    var value: CatalogJSONValue {
        if let object { return .object(object.mapValues(\.value)) }
        if let array { return .array(array.map(\.value)) }
        return scalar ?? .object([:])        // a value that wrote nothing: JSONEncoder writes {}
    }
}

/// The `Encoder` a value's `encode(to:)` sees.
struct DOMWriter: Encoder {
    let node: DOMNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if node.object == nil { node.object = [:] }
        return KeyedEncodingContainer(DOMKeyedWriter<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if node.array == nil { node.array = [] }
        return DOMUnkeyedWriter(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        DOMSingleWriter(node: node, codingPath: codingPath)
    }
}

struct DOMKeyedWriter<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: DOMNode
    let codingPath: [CodingKey]

    private func put(_ value: CatalogJSONValue, _ key: Key) { node.object?[key.stringValue] = DOMNode(value) }

    mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        put(try DOMEncoding.encode(value, codingPath: codingPath + [key]), key)
    }
    mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { put(try DOMEncoding.double(value, codingPath + [key]), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { put(try DOMEncoding.float(value, codingPath + [key]), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { put(.int(value), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { put(try DOMEncoding.integer(value) ?? .null, key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { put(try DOMEncoding.integer(value) ?? .null, key) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                        forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = DOMNode()
        node.object?[key.stringValue] = child
        return DOMWriter(node: child, codingPath: codingPath + [key]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = DOMNode()
        node.object?[key.stringValue] = child
        return DOMWriter(node: child, codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder { superEncoder(named: "super") }
    mutating func superEncoder(forKey key: Key) -> Encoder { superEncoder(named: key.stringValue) }

    private func superEncoder(named name: String) -> Encoder {
        let child = DOMNode()
        node.object?[name] = child
        return DOMWriter(node: child, codingPath: codingPath)
    }
}

struct DOMUnkeyedWriter: UnkeyedEncodingContainer {
    let node: DOMNode
    let codingPath: [CodingKey]
    var count: Int { node.array?.count ?? 0 }

    private func append(_ value: CatalogJSONValue) { node.array?.append(DOMNode(value)) }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode<T: Encodable>(_ value: T) throws { append(try DOMEncoding.encode(value, codingPath: codingPath)) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(try DOMEncoding.double(value, codingPath)) }
    mutating func encode(_ value: Float) throws { append(try DOMEncoding.float(value, codingPath)) }
    mutating func encode(_ value: Int) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(value)) }
    mutating func encode(_ value: UInt) throws { append(try DOMEncoding.integer(value) ?? .null) }
    mutating func encode(_ value: UInt8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt64) throws { append(try DOMEncoding.integer(value) ?? .null) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = DOMNode()
        node.array?.append(child)
        return DOMWriter(node: child, codingPath: codingPath).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = DOMNode()
        node.array?.append(child)
        return DOMWriter(node: child, codingPath: codingPath).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let child = DOMNode()
        node.array?.append(child)
        return DOMWriter(node: child, codingPath: codingPath)
    }
}

struct DOMSingleWriter: SingleValueEncodingContainer {
    let node: DOMNode
    let codingPath: [CodingKey]

    mutating func encodeNil() throws { node.scalar = .null }
    mutating func encode<T: Encodable>(_ value: T) throws {
        node.scalar = try DOMEncoding.encode(value, codingPath: codingPath)
    }
    mutating func encode(_ value: Bool) throws { node.scalar = .bool(value) }
    mutating func encode(_ value: String) throws { node.scalar = .string(value) }
    mutating func encode(_ value: Double) throws { node.scalar = try DOMEncoding.double(value, codingPath) }
    mutating func encode(_ value: Float) throws { node.scalar = try DOMEncoding.float(value, codingPath) }
    mutating func encode(_ value: Int) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: Int8) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: Int16) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: Int32) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: Int64) throws { node.scalar = .int(value) }
    mutating func encode(_ value: UInt) throws { node.scalar = try DOMEncoding.integer(value) }
    mutating func encode(_ value: UInt8) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: UInt16) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: UInt32) throws { node.scalar = .int(Int64(value)) }
    mutating func encode(_ value: UInt64) throws { node.scalar = try DOMEncoding.integer(value) }
}
