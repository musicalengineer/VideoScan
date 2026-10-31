// BackgroundPayloadCodec.swift — VideoScanCore/Background
//
// ONE serializer for everything that crosses the XPC wire or lands in the
// queue/checkpoint folders (design §3.3: "one serializer, versioned with a
// `schema` field; a mismatch is a refusal in words, like the catalog's").
//
// Envelope: { "schema": 1, "kind": "JobRequest", "body": { … } }. `kind` is
// the Swift type name, so a `JobID` blob handed to `enqueue` is refused as
// "expected JobRequest, got JobID" instead of decoding to garbage.
//
// C++ reading: a header struct in front of the payload, checked before the
// payload is touched — the same discipline as a versioned file format.

import Foundation

public enum BackgroundPayloadCodec {

    private struct Envelope<Body: Codable>: Codable {
        let schema: Int
        let kind: String
        let body: Body
    }

    /// The header alone — read first so a wrong schema never reaches the
    /// body's decoder.
    private struct Header: Codable {
        let schema: Int
        let kind: String
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Codable>(_ payload: T) throws -> Data {
        try encoder().encode(Envelope(schema: BackgroundProtocolVersion.current,
                                      kind: String(describing: T.self), body: payload))
    }

    /// Decodes `data` as a `T` envelope. Throws a `Refusal` (words) for a
    /// schema mismatch, a kind mismatch, or bytes that are not an envelope
    /// (a partial queue file, say).
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let header: Header
        do {
            header = try decoder().decode(Header.self, from: data)
        } catch {
            throw Refusal("not a background payload: \(Self.words(error))")
        }
        guard header.schema == BackgroundProtocolVersion.current else {
            throw Refusal("background payload schema \(header.schema) is not this build's schema \(BackgroundProtocolVersion.current) — the app and VideoScan Background disagree; rebuild both")
        }
        let expected = String(describing: T.self)
        guard header.kind == expected else {
            throw Refusal("expected a \(expected) payload, got \(header.kind)")
        }
        do {
            return try decoder().decode(Envelope<T>.self, from: data).body
        } catch {
            throw Refusal("could not read \(expected): \(Self.words(error))")
        }
    }

    /// Whether `error` is the codec saying no (as opposed to I/O).
    public static func refusal(_ error: Error) -> Refusal? { error as? Refusal }

    private static func words(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context): return "corrupt data at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .keyNotFound(let key, _): return "missing field \(key.stringValue)"
            case .typeMismatch(let type, let context): return "field \(context.codingPath.map(\.stringValue).joined(separator: ".")) is not a \(type)"
            case .valueNotFound(let type, let context): return "field \(context.codingPath.map(\.stringValue).joined(separator: ".")) has no \(type)"
            @unknown default: return String(describing: decoding)
            }
        }
        return String(describing: error)
    }
}
