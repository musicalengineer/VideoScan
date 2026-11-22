// TranscodeJob+FrameMD5.swift
// The pure frame-MD5 verification primitives for the Preservation preset —
// the `FrameMD5Verdict` value type plus the pure `compareFrameMD5` /
// `frameMD5Hashes` / `frameCount` statics — extracted verbatim from
// TranscodeJob.swift (refactor 2026-06-25). No I/O, no subprocess; these
// drive the unit-tested bit-exact compare. Kept as an extension of
// TranscodeJob so existing call sites and TranscodeTests are unchanged.
// `frameMD5Hashes` stays `private` because both its callers live in this
// file. Behavior unchanged.

import Foundation
import VideoScanCore

// MARK: - Frame MD5 verification (preservation only)
//
// The safety-critical core of the Preservation preset. We decode BOTH the
// source and the freshly-written FFV1 master to per-frame MD5 hashes
// (ffmpeg's `-f framemd5` muxer) and compare them element-wise. If every
// frame hash matches, the FFV1 file is PROVABLY bit-exact with the source
// at the decoded-pixel / decoded-sample level — exactly the guarantee an
// archive deposit needs.
//
// The COMPARE is extracted as a pure function (`compareFrameMD5`) so it can
// be unit-tested against string fixtures with zero subprocess plumbing.

/// Result of comparing two framemd5 streams. `Equatable` so tests can
/// assert exact verdicts. (≈ a C++ tagged union / std::variant.)
enum FrameMD5Verdict: Equatable {
    /// Every per-frame hash matched, in order. Bit-exact.
    case match
    /// The first frame whose hashes diverged (0-based), with both hashes.
    case mismatch(frameIndex: Int, source: String, output: String)
    /// The streams couldn't be meaningfully compared (empty input, no hash
    /// tokens, differing frame counts, …). The associated string explains.
    case malformed(String)
}

extension TranscodeJob {

    /// Compare two `framemd5`-format strings, frame by frame. PURE — no
    /// I/O. The input is the literal stdout ffmpeg's framemd5 muxer
    /// produces:
    ///
    ///     # software: ...
    ///     # tb 0: 1/30
    ///     0,          0,          0,     1,   152064, d41d8c...<hash>
    ///     0,          1,          1,     1,   152064, 9e107d...<hash>
    ///
    /// We:
    ///   - read both through `frameMD5Records` (the one line parser: `#`
    ///     headers and blank lines dropped, every other line a full record,
    ///     else `.malformed`),
    ///   - compare the two hash arrays element-wise,
    ///   - on the first divergence return `.mismatch` with the 0-based
    ///     frame index and both hashes,
    ///   - empty input or differing frame counts → a sensible verdict.
    nonisolated static func compareFrameMD5(source: String,
                                            output: String) -> FrameMD5Verdict {
        switch (frameMD5Records(source), frameMD5Records(output)) {
        case (.malformed(let why), _): return .malformed("source framemd5 stream: \(why)")
        case (_, .malformed(let why)): return .malformed("output framemd5 stream: \(why)")
        case (.hashes(let src), .hashes(let out)): return compareFrameMD5(sourceHashes: src, outputHashes: out)
        }
    }

    /// The comparison of two record lists already read by `frameMD5Records`.
    nonisolated private static func compareFrameMD5(sourceHashes srcHashes: [String],
                                                    outputHashes outHashes: [String]) -> FrameMD5Verdict {
        if srcHashes.isEmpty && outHashes.isEmpty {
            return .malformed("both framemd5 streams were empty — no frame hashes parsed")
        }
        if srcHashes.isEmpty {
            return .malformed("source framemd5 stream had no frame hashes")
        }
        if outHashes.isEmpty {
            return .malformed("output framemd5 stream had no frame hashes")
        }

        // Compare the overlapping prefix first so we report the EARLIEST
        // real divergence even when the counts also differ.
        let n = min(srcHashes.count, outHashes.count)
        var i = 0
        while i < n {
            if srcHashes[i] != outHashes[i] {
                return .mismatch(frameIndex: i,
                                 source: srcHashes[i],
                                 output: outHashes[i])
            }
            i += 1
        }

        if srcHashes.count != outHashes.count {
            return .malformed("frame count mismatch — source has \(srcHashes.count) frames, output has \(outHashes.count)")
        }

        return .match
    }

    /// One framemd5 answer, read once: every record's MD5 in order, or why
    /// the answer is not framemd5 output.
    enum FrameMD5Records: Equatable {
        case hashes([String])
        case malformed(String)
    }

    /// THE line parser — the record check, the comparison and the frame
    /// count all read the answer through this one function. THE BUG (Codex
    /// r2 #3, P0): the check (an ICU regex, which ends a line at `\r` too)
    /// and the comparison (split on `\n`, last token of each line) read the
    /// same text differently, so `\r`-separated source [A, A] against master
    /// [B, A] "matched". A line ends at `\n` or `\r` (`\r\n` leaves a blank
    /// line, which is skipped); any other byte that is not a field's own
    /// makes the record malformed (a Unicode line separator, a form feed).
    /// A line that is blank or opens with `#` is a header; every other line
    /// must be six comma-separated fields — stream index 0, four integers
    /// (dts, pts, duration, size), a 32-hex-digit MD5 — with spaces or tabs
    /// around them. O(bytes), one pass over the UTF-8 in place. Worst case:
    /// a 4-hour tape is 432,000 records (~30 MB) per stream → 432,000
    /// 32-byte strings (~25 MB with headers), released by the caller.
    nonisolated static func frameMD5Records(_ stream: String) -> FrameMD5Records {
        var text = stream   // `withUTF8` may make a bridged string contiguous (≈ c_str() on a rope)
        return text.withUTF8 { frameMD5Records(bytes: $0) }
    }

    nonisolated private static func frameMD5Records(bytes b: UnsafeBufferPointer<UInt8>) -> FrameMD5Records {
        var hashes: [String] = []
        var lineStart = 0
        while lineStart < b.count {
            var end = lineStart
            while end < b.count && b[end] != 0x0A && b[end] != 0x0D { end += 1 }   // \n, \r
            let line = FrameMD5Byte.trimmed(b, lineStart..<end)
            switch frameMD5Line(b, line) {
            case .header:
                break
            case .record(let md5):
                hashes.append(FrameMD5Byte.ascii(b, md5))
            case .notARecord:
                let shown = FrameMD5Byte.text(b, line)
                return .malformed("record \(hashes.count + 1) of ffmpeg's answer (“\(shown.count > 60 ? String(shown.prefix(60)) + "…" : shown)”)"
                                  + " is not a frame MD5 record")
            }
            lineStart = end + 1
        }
        return .hashes(hashes)
    }

    /// What one line of a framemd5 answer is.
    private enum FrameMD5Line { case header, record(md5: Range<Int>), notARecord }

    /// One line, trimmed of spaces and tabs: blank or `#` → a header; six
    /// comma-separated fields that `isFrameMD5Field` accepts → a record
    /// (with where its MD5 is); anything else → not a record.
    nonisolated private static func frameMD5Line(_ b: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> FrameMD5Line {
        guard let first = line.first, b[first] != 0x23 else { return .header }   // `#`
        var p = line.lowerBound, md5 = p..<p
        for field in 0..<6 {
            let token = FrameMD5Byte.token(b, from: &p, before: line.upperBound)
            guard isFrameMD5Field(field, b, token) else { return .notARecord }
            if field == 5 { md5 = token; continue }
            guard p < line.upperBound, b[p] == 0x2C else { return .notARecord }   // `,`
            p += 1
        }
        return p == line.upperBound ? .record(md5: md5) : .notARecord
    }

    /// Field 0 is the stream index (0 — one stream is mapped); 1–4 are
    /// dts, pts, duration, size (integers, dts may be negative); 5 is the
    /// MD5 (32 hex digits).
    nonisolated private static func isFrameMD5Field(_ field: Int, _ b: UnsafeBufferPointer<UInt8>, _ token: Range<Int>) -> Bool {
        // `while` over indices, not `for … in`: an iterator per field is the
        // dominant cost of a Debug build's 432,000-record answer.
        var i = token.lowerBound
        switch field {
        case 0:
            return token.count == 1 && b[i] == 0x30   // `0`
        case 5:
            guard token.count == 32 else { return false }
            while i < token.upperBound && FrameMD5Byte.isHex(b[i]) { i += 1 }
        default:
            if i < token.upperBound && b[i] == 0x2D { i += 1 }   // `-`
            guard i < token.upperBound else { return false }
            while i < token.upperBound && b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
        }
        return i == token.upperBound
    }

    /// The per-frame hashes of a framemd5 stream, or none when the stream
    /// is malformed (the comparison reports why through `frameMD5Records`).
    nonisolated private static func frameMD5Hashes(from stream: String) -> [String] {
        if case .hashes(let hashes) = frameMD5Records(stream) { return hashes }
        return []
    }

    /// Number of per-frame MD5 rows in a framemd5 dump (ignores `#` headers).
    /// Used only for the archive-grade summary's "frames verified" count.
    nonisolated static func frameCount(_ stream: String) -> Int {
        frameMD5Hashes(from: stream).count
    }

    // MARK: - Evidence for a proof that failed (GH #501)
    //
    // The proof runs before the publish; a master that fails it is removed,
    // so the EVIDENCE must live in the job's failure sentence (the row, the
    // Center's OUTCOME line, the summary block in videoscan.log). Each
    // function below is pure and answers one bounded sentence, or nil when
    // there is nothing to report.

    /// The words every failed proof opens with.
    nonisolated static let losslessProofFailed = "Lossless verification FAILED"

    /// A hash token as evidence: at most 40 characters (an MD5 is 32; a
    /// garbled token must not flood the line).
    nonisolated static func evidenceHash(_ token: String) -> String {
        token.isEmpty ? "(no hash)" : (token.count > 40 ? String(token.prefix(40)) + "…" : token)
    }

    /// Why two framemd5 streams are not proof of a lossless video stream,
    /// or nil when every frame matches: the first frame that differs with
    /// both hashes, how many of the frames compared differ, and both frame
    /// counts when they disagree. O(frames), no I/O.
    nonisolated static func frameMD5Evidence(source: String, output: String) -> String? {
        // A hash stream must BE a hash stream before two of them can agree
        // (Codex r1 #3: both decodes printing the same `garbage` "matched"),
        // and the records checked are the records compared (Codex r2 #3).
        let a: [String], b: [String]
        switch frameMD5Records(source) {
        case .malformed(let bad): return "the source's video frame MD5 could not be computed: \(bad)"
        case .hashes(let hashes): a = hashes
        }
        switch frameMD5Records(output) {
        case .malformed(let bad): return "the new master's video frame MD5 could not be computed: \(bad)"
        case .hashes(let hashes): b = hashes
        }
        switch compareFrameMD5(sourceHashes: a, outputHashes: b) {
        case .match:
            return nil
        case .malformed(let why):
            return "the video frame MD5s could not be compared: \(why)"
        case .mismatch(let frameIndex, let src, let out):
            let compared = min(a.count, b.count)
            var differing = 0
            for i in 0..<compared where a[i] != b[i] { differing += 1 }
            var words = "video frame \(frameIndex) (0-based) is the first of \(differing) that differ in \(compared) compared"
                + " (source MD5 \(evidenceHash(src)), new master MD5 \(evidenceHash(out)))"
            if a.count != b.count { words += "; the source has \(a.count) frames, the new master \(b.count)" }
            return words
        }
    }

    /// True for exactly 32 hexadecimal digits — what an MD5 is.
    nonisolated static func isMD5(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// Why `stream` is not ffmpeg `-f framemd5` output, or nil when every
    /// record is well formed (or there are none — the comparison reports an
    /// empty stream in its own words). Read by `frameMD5Records`, the same
    /// parser the comparison uses (Codex r1 #3, r2 #3).
    nonisolated static func frameMD5Malformed(_ stream: String) -> String? {
        if case .malformed(let why) = frameMD5Records(stream) { return why }
        return nil
    }

    /// Why one side's whole-stream audio MD5 is not an MD5, or nil.
    nonisolated private static func audioMD5Malformed(_ hash: String, whose: String) -> String? {
        guard !isMD5(hash) else { return nil }
        return "\(whose) audio MD5 could not be computed: ffmpeg's answer was not an MD5 "
            + (hash.isEmpty ? "(it printed none)" : "(“\(evidenceHash(hash))”)")
    }

    /// Why two whole-stream audio MD5s are not proof, or nil when both ARE
    /// MD5s (32 hex digits) and equal. Two identical non-hashes are not a
    /// match (Codex r1 #3).
    nonisolated static func audioMD5Evidence(source: String, output: String, pcmCodec: String) -> String? {
        if let bad = audioMD5Malformed(source, whose: "the source's") ?? audioMD5Malformed(output, whose: "the new master's") { return bad }
        guard source != output else { return nil }
        return "the audio whole-stream MD5s differ, both decoded as \(pcmCodec)"
            + " (source \(evidenceHash(source)), new master \(evidenceHash(output)))"
    }

    /// Why a proof decode gave no usable hash stream — ffmpeg could not be
    /// started, or stopped nonzero (a crash is its signal number) — or nil
    /// when it exited 0. `what` names the hash ("the source's video frame
    /// MD5"). The tool's last words are bounded by FFmpegEncodeCheck.
    nonisolated static func proofToolFailure(_ result: ProcessRunner.Result, what: String) -> String? {
        let tail = FFmpegEncodeCheck.stderrTail(result.stderr)
        let said = tail.isEmpty ? "" : " — \(tail)"
        guard result.launched else {
            return "\(what) could not be computed: ffmpeg could not be started (exit code \(result.exitCode))\(said)"
        }
        guard result.exitCode == 0 else {
            return "\(what) could not be computed: ffmpeg stopped with exit code \(result.exitCode)\(said)"
        }
        return nil
    }
}

/// The one line parser's small byte-range helpers. (≈ a C++ namespace of
/// inline functions over a `const uint8_t*` and index ranges.) The bytes
/// are literals, not `static let`s: in a Debug build every `static let`
/// read is a lazy-global accessor call, and these run once per byte of a
/// ~30 MB answer.
private enum FrameMD5Byte {
    static func isBlank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }   // space, tab
    static func isHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }

    /// `range` without leading or trailing spaces and tabs.
    static func trimmed(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Range<Int> {
        var s = range.lowerBound, e = range.upperBound
        while s < e && isBlank(b[s]) { s += 1 }
        while e > s && isBlank(b[e - 1]) { e -= 1 }
        return s..<e
    }

    /// The next field from `p`: blanks skipped on both sides, the token
    /// ends at a comma, a blank or `end`. `p` is left on the comma (or end).
    static func token(_ b: UnsafeBufferPointer<UInt8>, from p: inout Int, before end: Int) -> Range<Int> {
        while p < end && (b[p] == 0x20 || b[p] == 0x09) { p += 1 }
        let start = p
        while p < end && b[p] != 0x2C && b[p] != 0x20 && b[p] != 0x09 { p += 1 }   // `,`, space, tab
        let token = start..<p
        while p < end && (b[p] == 0x20 || b[p] == 0x09) { p += 1 }
        return token
    }

    /// Bytes already checked to be ASCII (an MD5's 32 hex digits) as a
    /// String — the direct decode, which cannot be lossy here.
    static func ascii(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: UnsafeBufferPointer(rebasing: b[range]), as: UTF8.self)
    }

    /// The bytes as text; anything not UTF-8 shows as U+FFFD (only ever quoted, never compared).
    static func text(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(bytes: UnsafeBufferPointer(rebasing: b[range]), encoding: .utf8)
            ?? String(repeating: "\u{FFFD}", count: min(range.count, 61))
    }
}
