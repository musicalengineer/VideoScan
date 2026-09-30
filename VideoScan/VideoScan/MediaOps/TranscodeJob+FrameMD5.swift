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
    ///   - drop comment/header lines (those starting with `#`),
    ///   - take the LAST whitespace/comma-separated token of each remaining
    ///     line as that frame's hash,
    ///   - compare the two hash arrays element-wise,
    ///   - on the first divergence return `.mismatch` with the 0-based
    ///     frame index and both hashes,
    ///   - empty input or differing frame counts → a sensible verdict.
    nonisolated static func compareFrameMD5(source: String,
                                            output: String) -> FrameMD5Verdict {
        let srcHashes = frameMD5Hashes(from: source)
        let outHashes = frameMD5Hashes(from: output)

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

    /// Extract the per-frame hash tokens from a framemd5 stream. Comment /
    /// header lines (leading `#`) and blank lines are dropped; for every
    /// remaining line the hash is the LAST comma-or-whitespace token.
    nonisolated private static func frameMD5Hashes(from stream: String) -> [String] {
        var hashes: [String] = []
        hashes.reserveCapacity(1024)
        for rawLine in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // framemd5 columns are comma-separated, but be liberal and also
            // split on whitespace so a hand-written fixture still parses.
            let tokens = line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            guard let last = tokens.last else { continue }
            hashes.append(String(last))
        }
        return hashes
    }

    /// Number of per-frame MD5 rows in a framemd5 dump (ignores `#` headers).
    /// Used only for the archive-grade summary's "frames verified" count.
    nonisolated static func frameCount(_ stream: String) -> Int {
        frameMD5Hashes(from: stream).count
    }
}
