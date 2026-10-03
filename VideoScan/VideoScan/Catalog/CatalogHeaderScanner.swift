// CatalogHeaderScanner.swift
// Finds catalog.json's TOP-LEVEL "version" and "generation" without
// decoding the records (GH #165 / #167; codex review 2026-10-02 #2,
// cycle #29 F1, cycle #30 R1 + R4).
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
// escapes), and the stack of open containers — and reads the integer that
// follows a depth-1 key named "version" / "generation". It never builds a
// value and never allocates per byte, so it runs in constant memory on a
// file of any size. (For Rick: a hand-rolled lexer state machine, like the
// ones you wrote for serial protocols — no recursion, no tree.)
//
// ONE PASS, THE WHOLE FILE (codex cycle #30 R1). Earlier revisions read a
// head window, then a tail window, and stopped as soon as both stamps were
// in hand. That is unsound: a later duplicate `"version":8` after an early
// `7` was never seen (Foundation and python's json disagree about which
// duplicate wins — the probe must refuse whichever way the reader goes),
// and a truncated or trailing-garbage file with an old header was accepted
// as old. A verdict now needs the WHOLE top-level object to have been read
// and to be well-formed: matching delimiters, closed, nothing but
// whitespace after it. Duplicate stamps keep the HIGHER value.
//
// THE VERDICT IS THREE-WAY (codex cycle #29 F1). The probe answers one of:
//   .version(n)       — one complete, well-formed top-level object was
//                       read and its top-level `version` key(s) were all
//                       integers; n is the highest.
//   .confirmedAbsent  — one complete, well-formed top-level object was
//                       read and it has no `version` key at all: a genuine
//                       pre-versioning catalog, v0.
//   .unknown          — anything else: not a JSON object this scanner can
//                       follow (array root, UTF-16, garbage), truncated or
//                       unterminated, mismatched delimiters, bytes after
//                       the object, a `version` key whose value is not an
//                       integer, an unreadable file. Unknown is NEVER
//                       "old": every write gate refuses on it. Foundation
//                       reads some of these (a UTF-16 file, say) as a
//                       perfectly good catalog, which is exactly why
//                       guessing is not allowed.
// A leading UTF-8 BOM is skipped, as Foundation's decoder skips it.
//
// COST (codex cycle #30 R4). The pass is O(file) — 0.3 s for a 63 MB /
// 200k-record catalog in a Debug build on an M4 Max (the windowed scanner
// it replaced took 1.2 s on the same file) — so its verdict is CACHED
// per path, keyed by the file's identity and timestamps (`FileKey`), and
// every write this process verifies SEEDS the cache with the verdict of
// the bytes it just proved on disk. Steady state: one open + fstat(2) per
// probe (~0.1 ms); a pass only when the file changed under us.
// `wholeFilePasses` / `wholeFilePasses(for:)` count the passes so tests
// can pin that bound.

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

    /// How many whole-file passes have run in this process. Diagnostic +
    /// test sensor for the cost bound above. (≈ a mutex-guarded counter.)
    static let wholeFilePasses = OSAllocatedUnfairLock(initialState: 0)

    /// Whole-file passes run against ONE path in this process. The test
    /// sensor for the cost bound: immune to other suites probing other
    /// files in parallel, which the process-wide counter is not.
    static let wholeFilePassesByPath = OSAllocatedUnfairLock(initialState: [String: Int]())
    static func wholeFilePasses(for url: URL) -> Int {
        wholeFilePassesByPath.withLock { $0[url.path] ?? 0 }
    }

    /// Bytes read per `FileHandle.read` during a pass.
    static let chunkBytes = 1 << 20

    struct Found: Equatable {
        var version: Int?
        var generation: Int?
        /// A depth-1 "version" key was seen — whatever its value.
        var versionKeySeen = false
        /// A depth-1 "version" key had a value that is not an integer
        /// (string, float, exponent, null…). Even beside a readable
        /// duplicate, the file is not one this build can vouch for.
        var versionUnreadable = false
        /// The pass reached the top-level object's closing brace, every
        /// container it opened was closed by its own kind of bracket, and
        /// nothing but whitespace followed.
        var complete = false
        /// The input is not a JSON object this scanner can follow.
        var aborted = false

        var verdict: CatalogVersionVerdict {
            if aborted || !complete || versionUnreadable { return .unknown }
            if let v = version { return .version(v) }
            if versionKeySeen { return .unknown }
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
    private static let versionKey = Array("version".utf8)
    private static let generationKey = Array("generation".utf8)
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

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
        /// Open containers, innermost last: true = object, false = array.
        /// Its count is the depth. A closing bracket must match the kind
        /// on top, or the input is not JSON (codex cycle #30 R1: `]`
        /// used to close `{`).
        private var containers: [Bool] = []
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

        init() {
            containers.reserveCapacity(16)
        }

        /// Feed the next chunk. Stops only on abort: finding both stamps
        /// is NOT done — a later duplicate, a truncation or trailing bytes
        /// would change the verdict (codex cycle #30 R1).
        mutating func feed(_ chunk: Data) {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let n = raw.count
                var i = 0
                while i < n {
                    if found.aborted { return }
                    if inString && !collectingKey && !escape {
                        // Fast path: inside a string VALUE nothing matters
                        // until its closing quote or an escape. Most of a
                        // catalog's bytes are here (paths, names, notes).
                        var j = i
                        while j < n {
                            let b = base[j]
                            if b == CatalogHeaderScanner.quote || b == CatalogHeaderScanner.backslash { break }
                            j += 1
                        }
                        i = j
                        if i == n { return }
                    }
                    step(base[i])
                    i += 1
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
            guard let v else {
                // Not an integer. For `version` that makes the whole file
                // unknown: the decoder may read it (7.0, 1e1) or reject it,
                // and either way this build cannot vouch for the stamp.
                if slot == .version { found.versionUnreadable = true }
                return
            }
            // Duplicate keys: keep the HIGHER stamp. Foundation keeps the
            // first on this OS, python's json the last; the higher reading
            // can only make the gate refuse more, never less.
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
                containers.append(true)
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
                if containers.count == 1 && expectingKey {
                    expectingKey = false
                    collectingKey = true
                    keyBytes.removeAll(keepingCapacity: true)
                    keyHasEscape = false
                    keyTooLong = false
                }
            case CatalogHeaderScanner.colon:
                if containers.count == 1, let slot = pendingSlot {
                    capturing = slot
                    reader = ValueReader()
                }
                pendingSlot = nil
            case CatalogHeaderScanner.comma:
                if containers.count == 1 { expectingKey = true }
            case CatalogHeaderScanner.openBrace:
                containers.append(true)
            case CatalogHeaderScanner.openBracket:
                containers.append(false)
            case CatalogHeaderScanner.closeBrace, CatalogHeaderScanner.closeBracket:
                let wantsObject = b == CatalogHeaderScanner.closeBrace
                guard let top = containers.popLast(), top == wantsObject else {
                    found.aborted = true   // `]` closing `{`, or one `}` too many
                    return
                }
                if containers.isEmpty { closed = true }
            default:
                break
            }
        }

        private mutating func appendKey(_ b: UInt8) {
            // Longest spelling worth comparing: "generation" fully \u-escaped.
            if keyBytes.count < 64 { keyBytes.append(b) } else { keyTooLong = true }
        }
    }

    // MARK: Verdict cache (codex cycle #30 R4)

    /// Identity of the BYTES a verdict was read from: device + inode (a
    /// rename-in-place gives a new inode), size, and the modification AND
    /// change timestamps at nanosecond resolution (ctime cannot be set from
    /// user space, so an mtime-preserving copy tool still changes the key).
    /// Taken with fstat(2) on the handle that is then read, so the key and
    /// the bytes belong to the same file. (≈ the fields of `struct stat`
    /// you would compare in C.)
    struct FileKey: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
        let ctimeSec: Int
        let ctimeNsec: Int

        /// nil when fstat fails or the descriptor is not a regular file.
        init?(fileDescriptor fd: Int32) {
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            mtimeSec = st.st_mtimespec.tv_sec
            mtimeNsec = st.st_mtimespec.tv_nsec
            ctimeSec = st.st_ctimespec.tv_sec
            ctimeNsec = st.st_ctimespec.tv_nsec
        }
    }

    private struct CacheEntry {
        var key: FileKey
        var found: Found
    }

    /// One verdict per path for the life of the process, valid while the
    /// file's `FileKey` is unchanged. Every probe costs one open + fstat;
    /// the O(file) pass runs only when the key differs from the cached one
    /// — i.e. when the file CHANGED. Declined in cycle #29 ("every verdict
    /// that would re-scan latches or is followed by a canonical save");
    /// codex showed the residual in cycle #30: a v0 file whose save is
    /// refused for another reason (stale generation, lock) re-scanned per
    /// attempt, and a v0 save scanned twice (precondition + queue gate).
    private static let verdictCache = OSAllocatedUnfairLock(initialState: [String: CacheEntry]())

    /// The bytes at `url` were just written by THIS process and proven on
    /// disk (read-back SHA-256 equal to the encoded payload, read through
    /// the handle `key` was taken from). Our encoder writes one complete
    /// object with `version` and `generation` first and no other top-level
    /// stamp (CAT-2), so this is exactly what a pass would find — recorded
    /// so the probes that follow every save (completion bookkeeping, the
    /// next save's precondition and gate) cost a stat, not a pass.
    static func noteVerifiedWrite(at url: URL, key: FileKey, version: Int, generation: Int) {
        var found = Found()
        found.version = version
        found.generation = generation
        found.versionKeySeen = true
        found.complete = true
        verdictCache.withLock { $0[url.path] = CacheEntry(key: key, found: found) }
    }

    // MARK: Probe

    /// The probe `CatalogSnapshot.header` uses: the cached verdict when the
    /// file is unchanged, else one complete pass. nil only when the file
    /// cannot be opened or is not a regular file (the caller decides
    /// whether that is "no file" or "unreadable").
    static func probe(fileAt url: URL) -> Found? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let key = FileKey(fileDescriptor: handle.fileDescriptor) else { return nil }
        let path = url.path
        if let hit = verdictCache.withLock({ $0[path] }), hit.key == key { return hit.found }
        wholeFilePasses.withLock { $0 += 1 }
        wholeFilePassesByPath.withLock { $0[path, default: 0] += 1 }
        var pass = Forward()
        // read(upToCount:) hands back nil at EOF (an empty file is one
        // zero-length read). A read error ends the pass short of the
        // closing brace: not complete → unknown → held, as it should be.
        while !pass.found.aborted, let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            pass.feed(chunk)
        }
        pass.finish()
        let found = pass.found
        verdictCache.withLock { $0[path] = CacheEntry(key: key, found: found) }
        return found
    }
}

extension CatalogHeaderScanner {
    /// Reads ONE header value, byte by byte, starting right after its `:`.
    /// `read` returns false at the first byte that is not part of a number
    /// (that byte belongs to whatever follows).
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
        /// Integer value, or nil for floats / exponents / non-numbers.
        var value: Int? {
            guard let first = bytes.first else { return nil }
            let digits = first == UInt8(ascii: "-") ? bytes.dropFirst() : bytes[...]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self))
        }
    }
}
