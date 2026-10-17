// JSONDuplicateKeyScanner.swift
// fix 2026-10-17 (codex D′ #2): both decodes of an import file go through
// Foundation's JSONDecoder, which keeps ONE member when an object carries a
// key twice (`"userNotes":"first","userNotes":"second"` → one of them).
// The second decode re-reads the same bytes and makes the same choice, so
// no comparator built on decoded values can see the loss. This pre-pass
// walks the RAW BYTES — a small tokenizer that tracks object scopes and the
// keys each one has seen — and names the first duplicate (its JSON path, the
// key, and the catalog row ordinal when the duplicate sits inside
// `records[n]`). The gate refuses the run on it before anything is decoded
// or written. No Foundation decode is involved.
//
// Pure, O(bytes), O(depth × keys) memory. Keys are compared after JSON
// unescaping, so `"a"` and `"a"` are the same key, as they are to any
// decoder. A document that is not well-formed JSON is not this scanner's
// business: it reports no duplicate, and the decoder reports the damage.
//
// (For Rick: a hand-rolled lexer over a byte buffer with a stack of
// frames; think of a recursive-descent parser that only remembers the keys
// it has passed, never the values.)

import Foundation

public enum JSONDuplicateKeyScanner {

    /// The first duplicate found: where (`records[3].scanContext.volumeUUID`),
    /// which key, and — when the path starts at `records[n]` — that ordinal.
    public struct Duplicate: Sendable, Equatable {
        public var path: String
        public var key: String
        public var recordOrdinal: Int?

        public init(path: String, key: String, recordOrdinal: Int?) {
            self.path = path
            self.key = key
            self.recordOrdinal = recordOrdinal
        }
    }

    /// The first duplicate key within any one object of `data`, or nil.
    public static func firstDuplicate(in data: Data) -> Duplicate? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Duplicate? in
            var scanner = Scanner(buffer)
            return scanner.run()
        }
    }

    /// The same, line by line (JSONL): the 0-based line and its duplicate.
    public static func firstDuplicate(inLines data: Data) -> (line: Int, duplicate: Duplicate)? {
        for (line, raw) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if let found = firstDuplicate(in: Data(raw)) { return (line, found) }
        }
        return nil
    }

    // MARK: - The tokenizer

    private enum Frame {
        case object(seen: Set<String>, key: String?, expectingKey: Bool)
        case array(index: Int)
    }

    private struct Scanner {
        let bytes: UnsafeRawBufferPointer
        var i = 0
        var frames: [Frame] = []

        init(_ bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
        }

        mutating func run() -> Duplicate? {
            while i < bytes.count {
                let c = bytes[i]
                switch c {
                case 0x7B:                                             // {
                    frames.append(.object(seen: [], key: nil, expectingKey: true))
                    i += 1
                case 0x5B:                                             // [
                    frames.append(.array(index: 0))
                    i += 1
                case 0x7D, 0x5D:                                       // } ]
                    if !frames.isEmpty { frames.removeLast() }
                    i += 1
                case 0x2C:                                             // ,
                    nextMember()
                    i += 1
                case 0x22:                                             // "
                    if let duplicate = string() { return duplicate }
                default:
                    i += 1                                             // whitespace, ':', numbers, true/false/null
                }
            }
            return nil
        }

        /// After a comma: an object expects a key, an array moves to its next element.
        private mutating func nextMember() {
            guard let top = frames.last else { return }
            switch top {
            case .object(let seen, _, _): frames[frames.count - 1] = .object(seen: seen, key: nil, expectingKey: true)
            case .array(let index): frames[frames.count - 1] = .array(index: index + 1)
            }
        }

        /// A string at `i`: a KEY when the enclosing object expects one (then
        /// it is unescaped and checked), otherwise skipped without decoding.
        private mutating func string() -> Duplicate? {
            guard case .object(let seen, _, true)? = frames.last else {
                skipString()
                return nil
            }
            let key = readKey()
            if seen.contains(key) {
                return Duplicate(path: path(key), key: key, recordOrdinal: recordOrdinal)
            }
            var grown = seen
            grown.insert(key)
            frames[frames.count - 1] = .object(seen: grown, key: key, expectingKey: false)
            return nil
        }

        private mutating func skipString() {
            i += 1                                                     // opening quote
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x5C { i += 2; continue }                      // backslash: skip the escaped byte
                i += 1
                if c == 0x22 { return }
            }
        }

        /// The key's bytes, JSON escapes resolved (\" \\ \/ \b \f \n \r \t \uXXXX with surrogate pairs).
        private mutating func readKey() -> String {
            i += 1                                                     // opening quote
            var out: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x22 { i += 1; break }
                if c != 0x5C { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                if e == 0x75 {                                         // \uXXXX
                    out.append(contentsOf: Array(unicodeEscape().utf8))
                } else {
                    out.append(JSONDuplicateKeyScanner.simpleEscapes[e] ?? e)
                }
            }
            // A key that is not UTF-8 (the decoder will refuse the document) keeps
            // its own identity as hex, so it cannot collide with another such key.
            return String(bytes: out, encoding: .utf8) ?? out.map { String(format: "%02x", $0) }.joined()
        }

        /// Reads the 4 hex digits after `\u` (and a following low surrogate
        /// when the first is a high one); `i` ends past them.
        private mutating func unicodeEscape() -> String {
            guard let high = hex4() else { return "\u{FFFD}" }
            if (0xD800...0xDBFF).contains(high), i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 {
                let mark = i
                i += 2
                if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                    let scalar = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return Unicode.Scalar(scalar).map { String(Character($0)) } ?? "\u{FFFD}"
                }
                i = mark
            }
            return Unicode.Scalar(high).map { String(Character($0)) } ?? "\u{FFFD}"
        }

        private mutating func hex4() -> Int? {
            guard i + 4 <= bytes.count else { i = bytes.count; return nil }
            var value = 0
            for k in 0..<4 {
                guard let digit = JSONDuplicateKeyScanner.hexValue(bytes[i + k]) else { return nil }
                value = value * 16 + digit
            }
            i += 4
            return value
        }

        /// `records[3].scanContext.volumeUUID` — the frames' keys and indexes, then the key.
        private func path(_ key: String) -> String {
            var text = ""
            for frame in frames.dropLast() {
                switch frame {
                case .object(_, let k, _): if let k { text += text.isEmpty ? k : ".\(k)" }
                case .array(let index): text += "[\(index)]"
                }
            }
            return text.isEmpty ? key : "\(text).\(key)"
        }

        /// The ordinal when the duplicate sits inside the top-level `records` array.
        private var recordOrdinal: Int? {
            guard frames.count >= 2, case .object(_, let k, _) = frames[0], k == "records",
                  case .array(let index) = frames[1] else { return nil }
            return index
        }
    }

    private static let simpleEscapes: [UInt8: UInt8] = [
        0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09,
    ]

    private static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c) - 0x30
        case 0x41...0x46: return Int(c) - 0x41 + 10
        case 0x61...0x66: return Int(c) - 0x61 + 10
        default: return nil
        }
    }
}
