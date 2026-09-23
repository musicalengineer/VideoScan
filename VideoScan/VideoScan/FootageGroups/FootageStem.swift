// FootageStem.swift
// Find Similar Footage, Phase 1 — the NAME half of the "duration + name"
// evidence rule (docs/find_original_design.md, top section).
//
// Two files are name-matched when their normalized stems are equal. The
// normalizer strips, in order:
//
//   1. the extension;
//   2. date prefixes the archive writes ("1990-xx-xx_", "1990-12-25 ",
//      doubled prefixes too) — ArchiveItemVersions' rule;
//   3. the app's own version tokens: "-vs-edit(_02)", then every trailing
//      derivative token ArchiveAngel.derivativeBaseStem knows (".vs.*",
//      "_balanced", "_trimmed", "_converted", " copy 2", "_NV12"…),
//      repeatedly, then " cleaned";
//   4. case and punctuation (lowercase letters and digits only).
//
// NOT stripped here, on purpose:
//   * a trailing "_02": ArchiveItemVersions rules that it is a promote
//     collision ONLY when "<name>.<ext>" sits in the SAME folder. That
//     needs the folder's siblings, so FootageGrouping applies it
//     (`collisionBaseFilename`), never the normalizer.
//   * any other trailing counter ("-3", "_7", " 2"): "Clip 1" / "Clip 2"
//     are different recordings. `counterBaseKey` offers the stripped key so
//     the grouping can add a POSSIBLE edge (one hop, never a chain) when
//     the lengths also match — the DickyTheBoysDadBreen-1985 / -1985-3 case.
//
// Pure. Regexes are compiled once (≈ a C++ function-local
// `static const std::regex`): compiling per call made a 100k-record pass
// cost seconds elsewhere in the app. Worst-case memory: one Analysis
// (~5 short strings) per record, ~200 B → 20 MB at 100k records.

import Foundation
import VideoScanCore

enum FootageStem {

    /// Everything the grouping needs from one filename.
    struct Analysis: Sendable, Equatable {
        /// Normalized key ("" only for an empty stem).
        let key: String
        /// The stem after steps 1–3 (original case) — for the generic test.
        let strippedStem: String
        /// A version token was stripped (the name itself says "derivative").
        let hasDerivativeToken: Bool
        /// The role the version token names, when it names one.
        let nameRole: FootageRole?
        /// Key of the stem with one trailing counter removed ("-3", "_7",
        /// " 2"), when the remaining stem is specific enough (≥ 6 letters/
        /// digits); nil otherwise.
        let counterBaseKey: String?
        /// "<name>.<ext>" (lowercased) when this file is "<name>_NN.<ext>"
        /// with NN ≥ 02 — a promote collision IF that file is in the same
        /// folder (checked by FootageGrouping). nil otherwise.
        let collisionBaseFilename: String?
    }

    static func analyze(_ filename: String) -> Analysis {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let rawStem = ns.deletingPathExtension
        let lowerRaw = rawStem.lowercased()

        var stem = stripDatePrefixes(rawStem)
        var stripped = false
        if asciiContains(stem, "-vs-") {
            let r = vsDashRegex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem),
                                                         withTemplate: "")
            if r != stem { stem = r; stripped = true }
        }
        // (Measured 2026-09-23, Debug, 100k names: the compiled regex costs
        // 0.13 s; Foundation `contains` pre-checks cost more than it.)
        while let base = ArchiveAngel.derivativeBaseStem(stem) {
            stem = base
            stripped = true
        }
        if stem.lowercased().hasSuffix(" cleaned") {
            stem = String(stem.dropLast(" cleaned".count))
            stripped = true
        }
        let key = alnumLower(stem)

        var counterBase: String?
        if let cut = trailingCounterStart(stem) {
            let base = alnumLower(String(stem[..<cut]))
            if base.count >= 6, base != key { counterBase = base }
        }

        var collision: String?
        if let (cut, nn) = collisionSuffix(rawStem), nn >= 2 {
            let baseStem = String(rawStem[..<cut])
            if !baseStem.isEmpty {
                collision = (ext.isEmpty ? baseStem : baseStem + "." + ext).lowercased()
            }
        }

        return Analysis(key: key.isEmpty ? alnumLower(rawStem) : key,
                        strippedStem: stem,
                        hasDerivativeToken: stripped,
                        nameRole: stripped || asciiContains(rawStem, ".vs.") ? nameRole(lowerRaw) : nil,
                        counterBaseKey: counterBase,
                        collisionBaseFilename: collision)
    }

    /// "1990-xx-xx_1990-xx-xx_Christmas" → "Christmas". Same rule as
    /// ArchiveItemVersions.stripDatePrefixes, with a cheap first-character
    /// guard so the regex runs only on names that can start with a date.
    static func stripDatePrefixes(_ stem: String) -> String {
        var s = stem
        while let first = s.first, first.isNumber || first == "x" || first == "X",
              let r = datePrefixRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(r.range, in: s) {
            let rest = s[range.upperBound...]
            if rest.isEmpty { break }
            s = String(rest)
        }
        return s
    }

    /// Case-insensitive ASCII substring test over UTF-8 bytes — the
    /// Foundation `contains` / `range(of:)` path measured ~5× slower in
    /// Debug on a 100k-name pass. `needle` must be lowercase ASCII.
    static func asciiContains(_ haystack: String, _ needle: StaticString) -> Bool {
        let n = UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount)
        guard let first = n.first else { return true }
        let h = Array(haystack.utf8)
        guard h.count >= n.count else { return false }
        @inline(__always) func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        var i = 0
        while i + n.count <= h.count {
            if lower(h[i]) == first {
                var k = 1
                while k < n.count, lower(h[i + k]) == n[k] { k += 1 }
                if k == n.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Index where a trailing "[-_ ]\d{1,2}" starts ("Tape-3" → at "-"),
    /// or nil. Hand-rolled (no regex): 1–2 ASCII digits after a separator.
    static func trailingCounterStart(_ s: String) -> String.Index? {
        var i = s.endIndex
        var digits = 0
        while i > s.startIndex {
            let j = s.index(before: i)
            guard let c = s[j].asciiValue, c >= 48, c <= 57 else { break }
            digits += 1
            i = j
            if digits > 2 { return nil }
        }
        guard digits >= 1, i > s.startIndex else { return nil }
        let sep = s.index(before: i)
        return "-_ ".contains(s[sep]) ? sep : nil
    }

    /// "<name>_NN" → (index of "_", NN), or nil. Exactly two ASCII digits.
    static func collisionSuffix(_ s: String) -> (String.Index, Int)? {
        let chars = Array(s.utf8.suffix(3))
        guard chars.count == 3, chars[0] == UInt8(ascii: "_"),
              (48...57).contains(chars[1]), (48...57).contains(chars[2]) else { return nil }
        let cut = s.index(s.endIndex, offsetBy: -3)
        return (cut, Int(chars[1] - 48) * 10 + Int(chars[2] - 48))
    }

    /// Lowercase letters and digits only ("Rick's Guitars-2024" → "ricksguitars2024").
    static func alnumLower(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.append(u)
        }
        return String(out)
    }

    /// The role a version token in the name announces (ArchiveItemVersions'
    /// vocabulary, mapped to footage roles). nil = the name says nothing.
    static func nameRole(_ lowerStem: String) -> FootageRole? {
        if lowerStem.contains(".vs.") || lowerStem.contains("-vs-") { return .reEncode }
        let tail = lowerStem
        for token in ["_balanced", "-balanced", "_cleaned", " cleaned", "_restored", "_fixed", "_corrections", "_denoise"]
        where tail.hasSuffix(token) || tail.contains(token) { return .restored }
        if tail.hasSuffix("_trimmed") || tail.hasSuffix("-trimmed") { return .trim }
        if tail.hasSuffix("_proxy") || tail.hasSuffix("-proxy") { return .transcode }
        for token in ["_converted", "_reformatted", "_reencoded", "_nv12"] where tail.contains(token) { return .reEncode }
        if tail.hasSuffix(" copy") || tail.range(of: " copy ") != nil || tail.hasSuffix("_copy") { return .copy }
        return nil
    }

    /// Frames per second from the catalog's string ("29.97", "30000/1001").
    /// nil when unparseable.
    static func framesPerSecond(_ s: String) -> Double? {
        if let d = Double(s), d > 0 { return d }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), n > 0, d > 0 { return n / d }
        return nil
    }

    /// ±2 frames at the record's own frame rate. A rate outside 10…121 fps
    /// (stills slideshows at 1–2 fps, QuickTime timescales like 600 or
    /// 90000 misread as a rate) is not a frame rate we trust: 0.1 s then.
    static func durationTolerance(frameRate: String) -> Double {
        guard let f = framesPerSecond(frameRate), f >= 10, f <= 121 else { return 0.1 }
        return 2.0 / f
    }

    /// The widest tolerance any record can have (2 frames at 10 fps).
    static let maxDurationTolerance = 0.2

    // MARK: Compiled patterns

    private static let datePrefixRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}|xxxx)(-[0-9x]{2}){0,2}[_ ]+"#, options: [.caseInsensitive])
    private static let vsDashRegex = try! NSRegularExpression(
        pattern: #"-vs-(edit|preserve|archive)(_\d{2})?$"#, options: [.caseInsensitive])
}
