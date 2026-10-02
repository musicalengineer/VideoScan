// CatalogHeaderScanner.swift
// Finds catalog.json's TOP-LEVEL "version" and "generation" without
// decoding the records (GH #165 / #167; codex review 2026-10-02 #2).
//
// Why this exists: the old probe took the first `"version":` string match
// in the first 4 KB (or the last one in the last 4 KB). JSON key order is
// free, so a perfectly valid catalog such as
//     {"records":[{"version":1}],"version":8,"generation":0}
// probed as v1 — and the v8 file it described was then fair game for a v7
// save. The probe is the newer-catalog gate's first line, so it must read
// the catalog's own key and nothing else.
//
// How: a byte-level JSON TOKENISER, not a parser. It tracks only what is
// needed to know where a byte sits — string or not (with backslash
// escapes), and container depth — and reads the integer that follows a
// depth-1 key named "version" / "generation". It never builds a value and
// never allocates per byte, so it runs in constant memory on a file of any
// size. (For Rick: a hand-rolled lexer state machine, like the ones you
// wrote for serial protocols — no recursion, no tree.)
//
// Three passes, cheapest first; each fills only what is still missing:
//   1. HEAD  — forward over the first window. Our own encoder writes
//              `version` and `generation` first, so this settles every
//              catalog this app wrote.
//   2. TAIL  — backward over the last window. Legacy catalogs (keys in a
//              per-process random order, GH #165) and python json.dump
//              put some header keys after the records array.
//   3. WHOLE — forward over the whole file in 1 MB chunks, only when
//              `version` is still unknown. A hand-made layout can put the
//              key anywhere; a guessed "old" here would let a v7 save
//              replace a newer catalog. Constant memory; linear time.
// A forward pass that reaches the top-level object's closing brace is
// complete: a key it did not see is genuinely absent (a v0 catalog).

import Foundation

enum CatalogHeaderScanner {

    struct Found: Equatable {
        var version: Int?
        var generation: Int?
        /// True when a forward pass saw the top-level object close — what
        /// it did not find is not in the file.
        var complete = false
        var isSettled: Bool { complete || (version != nil && generation != nil) }
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let minus = UInt8(ascii: "-")
    private static let zero = UInt8(ascii: "0")
    private static let nine = UInt8(ascii: "9")
    private static let versionKey = Array("version".utf8)
    private static let generationKey = Array("generation".utf8)

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
    private static func isDigit(_ b: UInt8) -> Bool { b >= zero && b <= nine }

    /// Which header key a depth-1 key's raw bytes (between the quotes)
    /// name. Escaped spellings (`"version"`) are unescaped through
    /// JSONDecoder, exactly as the real decode would see them.
    private enum Slot { case version, generation }
    private static func slot(forKeyBytes raw: [UInt8], hasEscape: Bool) -> Slot? {
        var bytes = raw
        if hasEscape {
            guard let s = try? JSONDecoder().decode(String.self, from: Data([quote] + raw + [quote])) else { return nil }
            bytes = Array(s.utf8)
        }
        if bytes == versionKey { return .version }
        if bytes == generationKey { return .generation }
        return nil
    }

    // MARK: Forward pass (resumable across chunks)

    /// Forward tokeniser state. Feed it the file from byte 0 in any chunk
    /// sizes; it resumes mid-string, mid-key and mid-number.
    /// (≈ a C struct of lexer registers, updated byte by byte.)
    struct Forward {
        private(set) var found = Found()
        private var started = false
        private var aborted = false
        private var depth = 0
        private var inString = false
        private var escape = false
        /// At depth 1, the next string is a KEY (after `{` or `,`).
        private var expectingKey = false
        private var collectingKey = false
        private var keyBytes: [UInt8] = []
        private var keyHasEscape = false
        private var keyTooLong = false
        /// The depth-1 key just closed, waiting for its `:`.
        private var pendingSlot: Slot?
        /// Reading the value of a header key.
        private var capturing: Slot?
        private var reader = ValueReader()

        /// Done: nothing more to learn (both found, top level closed, or
        /// the file is not a JSON object).
        var isDone: Bool { aborted || found.isSettled }

        mutating func feed(_ chunk: Data) {
            chunk.withUnsafeBytes { raw in
                for b in raw.bindMemory(to: UInt8.self) {
                    if isDone { return }
                    step(b)
                }
            }
        }

        /// Call at end of input: a number running to EOF is finished.
        mutating func finish() { if capturing != nil { endCapture() } }

        private mutating func endCapture() {
            guard let slot = capturing else { return }
            capturing = nil
            let v = reader.value
            reader = ValueReader()
            switch slot {
            case .version: if found.version == nil { found.version = v }
            case .generation: if found.generation == nil { found.generation = v }
            }
        }

        private mutating func step(_ b: UInt8) {
            if !started {
                if CatalogHeaderScanner.isSpace(b) { return }
                started = true
                guard b == CatalogHeaderScanner.openBrace else { aborted = true; return }
                depth = 1
                expectingKey = true
                return
            }
            if capturing != nil {
                if reader.read(b) { return }
                // The value ended (or was never a number): record it, then
                // tokenise this byte normally (it is `,`, `}`, a quote, …).
                endCapture()
            }
            if inString {
                if escape { escape = false; if collectingKey { appendKey(b) }; return }
                if b == CatalogHeaderScanner.backslash {
                    escape = true
                    if collectingKey { keyHasEscape = true; appendKey(b) }
                    return
                }
                if b == CatalogHeaderScanner.quote {
                    inString = false
                    if collectingKey {
                        collectingKey = false
                        pendingSlot = keyTooLong ? nil
                            : CatalogHeaderScanner.slot(forKeyBytes: keyBytes, hasEscape: keyHasEscape)
                    }
                    return
                }
                if collectingKey { appendKey(b) }
                return
            }
            switch b {
            case CatalogHeaderScanner.quote:
                inString = true
                if depth == 1 && expectingKey {
                    expectingKey = false
                    collectingKey = true
                    keyBytes.removeAll(keepingCapacity: true)
                    keyHasEscape = false
                    keyTooLong = false
                }
            case CatalogHeaderScanner.colon:
                if depth == 1, let slot = pendingSlot {
                    capturing = slot
                    reader = ValueReader()
                }
                pendingSlot = nil
            case CatalogHeaderScanner.comma:
                if depth == 1 { expectingKey = true }
            case CatalogHeaderScanner.openBrace, CatalogHeaderScanner.openBracket:
                depth += 1
            case CatalogHeaderScanner.closeBrace, CatalogHeaderScanner.closeBracket:
                depth -= 1
                if depth == 0 { found.complete = true }
            default:
                break
            }
        }

        private mutating func appendKey(_ b: UInt8) {
            // Longest spelling worth comparing: "generation" fully \u-escaped.
            if keyBytes.count < 64 { keyBytes.append(b) } else { keyTooLong = true }
        }
    }

    // MARK: Backward pass (tail window)

    /// Scan `tail` (the LAST bytes of the file) backward from the end for
    /// depth-1 keys. Reading in reverse, a depth-1 `:` announces that the
    /// next string is a key and its value starts right after the colon.
    /// A quote is a delimiter unless an odd run of backslashes precedes
    /// it. Stops at the window's start (whatever is beyond it is unknown).
    static func scanTail(_ tail: [UInt8]) -> Found {
        var out = Found()
        var i = tail.count - 1
        while i >= 0 && isSpace(tail[i]) { i -= 1 }
        guard i >= 0, tail[i] == closeBrace else { return out }
        var depth = 1
        i -= 1
        var colonAt: Int?
        func escapedQuote(at q: Int) -> Bool {
            var n = 0, k = q - 1
            while k >= 0 && tail[k] == backslash { n += 1; k -= 1 }
            return n % 2 == 1
        }
        while i >= 0 {
            let b = tail[i]
            if b == quote {
                // A string, read backward to its opening quote.
                let close = i
                var j = i - 1
                while j >= 0 && !(tail[j] == quote && !escapedQuote(at: j)) { j -= 1 }
                guard j >= 0 else { return out }   // string runs past the window
                if depth == 1, let c = colonAt {
                    let raw = Array(tail[(j + 1)..<close])
                    if let slot = slot(forKeyBytes: raw, hasEscape: raw.contains(backslash)) {
                        var f = ValueReader()
                        for k in (c + 1)..<tail.count { if !f.read(tail[k]) { break } }
                        switch slot {
                        case .version: if out.version == nil { out.version = f.value }
                        case .generation: if out.generation == nil { out.generation = f.value }
                        }
                        if out.version != nil && out.generation != nil { return out }
                    }
                    colonAt = nil
                }
                i = j - 1
                continue
            }
            switch b {
            case colon: if depth == 1 { colonAt = i }
            case closeBrace, closeBracket: depth += 1
            case openBrace, openBracket:
                depth -= 1
                if depth == 0 { return out }       // reached the top-level `{`
            default: break
            }
            i -= 1
        }
        return out
    }

    // MARK: Whole-file probe

    /// The probe `CatalogSnapshot.headerProbe` uses: head → tail → whole.
    static func probe(fileAt url: URL, window: Int) -> Found? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: window) else { return nil }
        var fwd = Forward()
        fwd.feed(head)
        var found = fwd.found
        let size = (try? handle.seekToEnd()) ?? UInt64(head.count)
        if size <= UInt64(head.count) { fwd.finish(); found = fwd.found; found.complete = true }
        if found.isSettled { return found }
        // 2. Tail window, backward.
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        if (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() {
            let t = scanTail(Array(tail))
            if found.version == nil { found.version = t.version }
            if found.generation == nil { found.generation = t.generation }
        }
        if found.version != nil { return found }
        // 3. Whole file, forward, 1 MB at a time — only when the version
        // is still unknown. Resumes nothing from pass 1 (cheap to redo the
        // first window; simpler than carrying state across the seek).
        guard (try? handle.seek(toOffset: 0)) != nil else { return found }
        var whole = Forward()
        while !whole.isDone, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            whole.feed(chunk)
        }
        whole.finish()
        if found.generation == nil { found.generation = whole.found.generation }
        found.version = whole.found.version
        found.complete = whole.found.complete
        return found
    }
}

extension CatalogHeaderScanner {
    /// Reads ONE header value, byte by byte, starting right after its `:`.
    /// `read` returns false at the first byte that is not part of a number
    /// (that byte belongs to whatever follows). Shared by both passes.
    struct ValueReader {
        private var bytes: [UInt8] = []
        private var started = false
        mutating func read(_ b: UInt8) -> Bool {
            let isNumberByte = b == UInt8(ascii: "-") || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E") || b == UInt8(ascii: "+")
            if !started && (b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) { return true }
            guard isNumberByte, bytes.count < 32 else { return false }
            started = true
            bytes.append(b)
            return true
        }
        /// Integer value, or nil for floats / non-numbers (same rule as the
        /// forward pass).
        var value: Int? {
            guard let first = bytes.first else { return nil }
            let digits = first == UInt8(ascii: "-") ? bytes.dropFirst() : bytes[...]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self))
        }
    }
}
