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
        if stem.range(of: "-vs-", options: .caseInsensitive) != nil {
            let r = vsDashRegex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem),
                                                         withTemplate: "")
            if r != stem { stem = r; stripped = true }
        }
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
        if let r = counterRegex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let range = Range(r.range, in: stem) {
            let base = alnumLower(String(stem[..<range.lowerBound]))
            if base.count >= 6, base != key { counterBase = base }
        }

        var collision: String?
        if let r = collisionRegex.firstMatch(in: rawStem, range: NSRange(rawStem.startIndex..., in: rawStem)),
           let range = Range(r.range, in: rawStem),
           let nn = Int(rawStem[range].dropFirst()), nn >= 2 {
            let baseStem = String(rawStem[..<range.lowerBound])
            if !baseStem.isEmpty {
                collision = (ext.isEmpty ? baseStem : baseStem + "." + ext).lowercased()
            }
        }

        return Analysis(key: key.isEmpty ? alnumLower(rawStem) : key,
                        strippedStem: stem,
                        hasDerivativeToken: stripped,
                        nameRole: nameRole(lowerRaw),
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
    private static let counterRegex = try! NSRegularExpression(
        pattern: #"[-_ ]\d{1,2}$"#)
    private static let collisionRegex = try! NSRegularExpression(
        pattern: #"_\d{2}$"#)
}
