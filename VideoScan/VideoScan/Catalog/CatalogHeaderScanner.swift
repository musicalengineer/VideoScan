// CatalogHeaderScanner.swift
// Finds catalog.json's TOP-LEVEL "version" and "generation" without
// decoding the records (GH #165 / #167; codex review 2026-10-02 #2, and
// cycle #29 F1).
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
//
// THE VERDICT IS THREE-WAY (codex cycle #29 F1). The probe answers one of:
//   .version(n)       — the top-level key was read.
//   .confirmedAbsent  — a forward pass read the WHOLE file as one complete
//                       top-level object (only whitespace after its closing
//                       brace) and saw no "version" key: a genuine
//                       pre-versioning catalog, v0.
//   .unknown          — anything else: not a JSON object this scanner can
//                       follow (array root, UTF-16, garbage), truncated or
//                       unterminated, bytes after the object, a "version"
//                       key whose value is not an integer, an unreadable
//                       file. Unknown is NEVER "old": every write gate
//                       refuses on it. Foundation reads some of these (a
//                       UTF-16 file, say) as a perfectly good newer
//                       catalog, which is exactly why guessing is not
//                       allowed.
// A leading UTF-8 BOM is skipped, as Foundation's decoder skips it.
//
// Cost bound: the whole-file pass is O(file). It cannot repeat against
// the same unchanged file on the write paths, because every verdict that
// would re-run it latches the store for the session (newer → latch,
// unknown → latch) or is followed by a save that rewrites the file in
// canonical layout (old / absent → `version` is in the head from then
// on). `wholeFilePasses` counts the passes so a test can pin that bound.

import Foundation
import os

/// What the probe could learn about the catalog's own `version` key.
enum CatalogVersionVerdict: Equatable, Sendable {
    case version(Int)
    case confirmedAbsent
    case unknown

    var number: Int? { if case .version(let v) = self { return v }; return nil }
}

enum CatalogHeaderScanner {

    /// How many times the whole-file pass (3) has run in this process.
    /// Diagnostic + test sensor for the cost bound above. (≈ a
    /// mutex-guarded counter.)
    static let wholeFilePasses = OSAllocatedUnfairLock(initialState: 0)

    struct Found: Equatable {
        var version: Int?
        var generation: Int?
        /// A forward pass saw a depth-1 "version" key — whatever its value.
        var versionKeySeen = false
        /// A forward pass over the WHOLE input reached the top-level
        /// object's closing brace and nothing but whitespace followed.
        var complete = false
        /// The input is not a JSON object this scanner can follow.
        var aborted = false

        var verdict: CatalogVersionVerdict {
            if let v = version { return .version(v) }
            if versionKeySeen || aborted || !complete { return .unknown }
            return .confirmedAbsent
        }
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
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

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
        private var bomMatched = 0
        private var pastBOM = false
        private var started = false
        /// The top-level object's closing brace has been seen.
        private var closed = false
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

        /// Done: nothing more to learn. Not done merely because the object
        /// closed — with no version in hand the bytes after the brace
        /// decide between "confirmed absent" and "unknown".
        var isDone: Bool {
            found.aborted || (found.version != nil && (found.generation != nil || closed))
        }

        mutating func feed(_ chunk: Data) {
            chunk.withUnsafeBytes { raw in
                for b in raw.bindMemory(to: UInt8.self) {
                    if isDone { return }
                    step(b)
                }
            }
        }

        /// Call at end of input: a number running to EOF is finished, and
        /// the pass learns whether it read one complete object.
        mutating func finish() {
            if capturing != nil { endCapture() }
            found.complete = closed && !found.aborted
        }

        private mutating func endCapture() {
            guard let slot = capturing else { return }
            capturing = nil
            let v = reader.value
            reader = ValueReader()
            guard let v else { return }
            // Duplicate keys: keep the HIGHER stamp. Foundation keeps the
            // later one; whichever it is, the higher reading can only make
            // the gate refuse more, never less.
            switch slot {
            case .version: found.version = max(found.version ?? v, v)
            case .generation: found.generation = max(found.generation ?? v, v)
            }
        }

        private mutating func step(_ b: UInt8) {
            if !pastBOM {
                // Foundation strips one leading UTF-8 BOM; so do we. A
                // partial BOM, or any other high byte here, is not JSON.
                if b == CatalogHeaderScanner.utf8BOM[bomMatched] {
                    bomMatched += 1
                    if bomMatched == 3 { pastBOM = true }
                    return
                }
                if bomMatched > 0 { found.aborted = true; return }
                pastBOM = true
            }
            if !started {
                if CatalogHeaderScanner.isSpace(b) { return }
                started = true
                guard b == CatalogHeaderScanner.openBrace else { found.aborted = true; return }
                depth = 1
                expectingKey = true
                return
            }
            if closed {
                // Only whitespace may follow the object (Foundation agrees).
                if !CatalogHeaderScanner.isSpace(b) { found.aborted = true }
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
                        if pendingSlot == .version { found.versionKeySeen = true }
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
                if depth == 0 { closed = true }
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
    /// Fills values only; the verdict is the forward passes' business.
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
                        if let v = f.value {
                            switch slot {
                            case .version: out.version = max(out.version ?? v, v)
                            case .generation: out.generation = max(out.generation ?? v, v)
                            }
                        }
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

    /// The probe `CatalogSnapshot.header` uses: head → tail → whole.
    /// nil only when the file cannot be opened (the caller decides whether
    /// that is "no file" or "unreadable").
    static func probe(fileAt url: URL, window: Int) -> Found? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // read(upToCount:) hands back nil at EOF — an empty file.
        let head = (try? handle.read(upToCount: window)).flatMap { $0 } ?? Data()
        var fwd = Forward()
        fwd.feed(head)
        let size = (try? handle.seekToEnd()) ?? UInt64(head.count)
        if size <= UInt64(head.count) {
            // The whole file is in hand: this pass IS the whole-file pass.
            fwd.finish()
            return fwd.found
        }
        var found = fwd.found
        // Not a JSON object from its first byte: no window will change that.
        if found.aborted { return found }
        if found.version != nil && found.generation != nil { return found }
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
        // This is the pass that can say "confirmed absent".
        wholeFilePasses.withLock { $0 += 1 }
        guard (try? handle.seek(toOffset: 0)) != nil else { return found }   // verdict stays .unknown
        var whole = Forward()
        while !whole.isDone, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            whole.feed(chunk)
        }
        whole.finish()
        var out = whole.found
        if out.generation == nil { out.generation = found.generation }
        return out
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
