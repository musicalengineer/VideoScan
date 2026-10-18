// HashingEncoder.swift
// An `Encoder` that writes nothing: every key and value the encoded type
// emits is fed straight into one SipHash state (`Hasher`). Used by
// CatalogChangeDetector to fingerprint a record through the app's ONE
// encoder (`VideoRecordDTO.encode(to:)`) without building JSON text or a
// value tree — no number formatting, no string escaping, no allocation per
// field.
//
// What makes two encodings hash alike: the same keys, in the same order,
// with the same values (a key `encodeIfPresent` omits is simply absent).
// Every key name is hashed with its value and every container opens with a
// tag, so `{"a":1}` and `[1]` differ, and so do two keys swapping values.
//
// (For Rick: a visitor over the serialiser's calls that folds them into a
// running checksum instead of writing bytes.)

import Foundation

/// The running hash shared by the encoder and its containers.
final class HashingSink {
    var hasher = Hasher()

    func tag(_ t: UInt8) { hasher.combine(t) }
    func key(_ k: CodingKey) { hasher.combine(k.stringValue) }
}

struct HashingEncoder: Encoder {
    let sink: HashingSink
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        sink.tag(1)
        return KeyedEncodingContainer(HashingKeyed<Key>(sink: sink))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        sink.tag(2)
        return HashingUnkeyed(sink: sink)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        HashingSingle(sink: sink)
    }

    /// The hash of `value`'s encoding.
    static func hash<T: Encodable>(_ value: T) throws -> Int {
        let sink = HashingSink()
        try value.encode(to: HashingEncoder(sink: sink))
        return sink.hasher.finalize()
    }
}

/// Values the containers forward to the sink, typed so `Date`, `UUID` and
/// `Data` hash their own bits instead of their Codable expansion.
private func combine<T: Encodable>(_ value: T, into sink: HashingSink) throws {
    switch value {
    case let date as Date: sink.tag(10); sink.hasher.combine(date.timeIntervalSinceReferenceDate)
    case let uuid as UUID: sink.tag(11); sink.hasher.combine(uuid)
    case let data as Data: sink.tag(12); sink.hasher.combine(data)
    case let url as URL: sink.tag(13); sink.hasher.combine(url.absoluteString)
    default: try value.encode(to: HashingEncoder(sink: sink))
    }
}

private struct HashingKeyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let sink: HashingSink
    var codingPath: [CodingKey] = []

    mutating func encodeNil(forKey key: Key) throws { sink.key(key); sink.tag(0) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: String, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: Float, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: Int, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { sink.key(key); sink.hasher.combine(value) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { sink.key(key); try combine(value, into: sink) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                        forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        sink.key(key); sink.tag(1)
        return KeyedEncodingContainer(HashingKeyed<NestedKey>(sink: sink))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        sink.key(key); sink.tag(2)
        return HashingUnkeyed(sink: sink)
    }

    mutating func superEncoder() -> Encoder { HashingEncoder(sink: sink) }
    mutating func superEncoder(forKey key: Key) -> Encoder { sink.key(key); return HashingEncoder(sink: sink) }
}

private struct HashingUnkeyed: UnkeyedEncodingContainer {
    let sink: HashingSink
    var codingPath: [CodingKey] = []
    private(set) var count = 0

    init(sink: HashingSink) { self.sink = sink }

    mutating func encodeNil() throws { count += 1; sink.tag(0) }
    mutating func encode(_ value: Bool) throws { count += 1; sink.hasher.combine(value) }
    mutating func encode(_ value: String) throws { count += 1; sink.hasher.combine(value) }
    mutating func encode(_ value: Double) throws { count += 1; sink.hasher.combine(value) }
    mutating func encode(_ value: Int) throws { count += 1; sink.hasher.combine(value) }
    mutating func encode(_ value: Int64) throws { count += 1; sink.hasher.combine(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { count += 1; try combine(value, into: sink) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        count += 1; sink.tag(1)
        return KeyedEncodingContainer(HashingKeyed<NestedKey>(sink: sink))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        count += 1; sink.tag(2)
        return HashingUnkeyed(sink: sink)
    }

    mutating func superEncoder() -> Encoder { HashingEncoder(sink: sink) }
}

private struct HashingSingle: SingleValueEncodingContainer {
    let sink: HashingSink
    var codingPath: [CodingKey] = []

    mutating func encodeNil() throws { sink.tag(0) }
    mutating func encode(_ value: Bool) throws { sink.hasher.combine(value) }
    mutating func encode(_ value: String) throws { sink.hasher.combine(value) }
    mutating func encode(_ value: Double) throws { sink.hasher.combine(value) }
    mutating func encode(_ value: Int) throws { sink.hasher.combine(value) }
    mutating func encode(_ value: Int64) throws { sink.hasher.combine(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { try combine(value, into: sink) }
}
