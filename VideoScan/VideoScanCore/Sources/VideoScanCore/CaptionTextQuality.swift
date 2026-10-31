// CaptionTextQuality.swift
// GH #402: refuse a degenerate VLM generation before it is stored as a
// caption. Pure, Foundation-only; lives beside `SceneCaption` (Tagging.swift).

import Foundation

/// Is a VLM caption's text an observation, or the model's degenerate
/// repetition output?
///
/// WHY (GH #402, rule 1 "a shown fact comes from evidence"): 2,850 of
/// 3,128 stored `ocrDate` captions were the 3B captioner's repetition loop
/// (`!!!!!!!!…`) saved as if the model had read a burn-in. A degenerate
/// generation is not an observation: storing it pollutes the OCR evidence
/// the DateTriangulator ranks and inflates the "has OCR date" coverage.
/// The caption write path asks this verdict first and drops `.degenerate`.
///
/// The rule — `.degenerate` when ANY of these holds on the trimmed text:
///   (d) empty or whitespace only.
///   (c) longer than 3 characters and no letter or digit at all
///       (`?!?!`, `！！！！`, `━━━━`).
///   (a) longer than 8 characters and ≤ 3 distinct non-space characters
///       make up ≥ 90 % of the non-space characters, where that dominant
///       set holds at most ONE letter/digit (`!!!!…`, `.....`, `-----`,
///       `aaaaaaaaa`, `!a!a!a!a!`). Two carve-outs keep real readings:
///       a set with 2+ letters/digits is a word (`MISSISSIPPI`: S, I, P);
///       a digit-dominated text of ≤ 24 characters is a date/time burn-in
///       (`11-11-11 11:11`). A digit loop longer than 24 is degenerate.
///   (b) the same whitespace-separated token (case- and edge-punctuation-
///       insensitive) repeated ≥ 6 times in a row (`the the the the the the`).
/// Everything else is `.usable` — including the legitimate short answers
/// "none", "N/A", "unknown", "1991", "JUN 21 1991", "no date visible".
///
/// Characters are Swift `Character`s (grapheme clusters), so a fullwidth
/// `！` or an emoji counts as one character, like a user sees it.
///
/// C++ analogy: a pure `static Verdict classify(std::u32string_view)` in a
/// namespace — no state, no I/O; the enum with a payload is a
/// `std::variant<Usable, Degenerate{std::string reason}>`.
public enum CaptionTextQuality {

    public enum Verdict: Equatable, Sendable {
        case usable
        case degenerate(reason: String)

        public var isDegenerate: Bool {
            if case .degenerate = self { return true }
            return false
        }
    }

    /// Repetition threshold for rule (b).
    public static let maxTokenRun = 6
    /// Rule (a) applies only to texts longer than this.
    public static let dominantMinLength = 8
    /// Rule (a): share of non-space characters the dominant set must reach.
    public static let dominantShare = 0.90
    /// Rule (a) carve-out: a digit-dominated text this short is a burn-in.
    public static let dateShapeMaxLength = 24

    /// The verdict on one caption text: the first rule that fires names the
    /// reason. O(n) in the text's characters plus a sort of its distinct
    /// characters (<= n); one histogram and one token array, both bounded
    /// by the text.
    public static func verdict(_ text: String) -> Verdict {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .degenerate(reason: "empty") }                     // (d)
        let reason = noLetterOrDigit(s) ?? dominantCharacters(s) ?? repeatedToken(s)
        return reason.map { .degenerate(reason: $0) } ?? .usable
    }

    /// Rule (c): longer than 3 characters and no letter or digit at all.
    static func noLetterOrDigit(_ s: String) -> String? {
        guard s.count > 3, !s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return "no letter or digit in \(s.count) characters"
    }

    /// Rule (a): a set of <= 3 characters with at most one letter/digit
    /// covers >= 90 % of the non-space characters (with the burn-in carve-out).
    static func dominantCharacters(_ s: String) -> String? {
        guard s.count > dominantMinLength else { return nil }
        var histogram: [Character: Int] = [:]
        var nonSpace = 0
        for ch in s where !ch.isWhitespace {
            histogram[ch, default: 0] += 1
            nonSpace += 1
        }
        let top = histogram.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3)
        let topCount = top.reduce(0) { $0 + $1.value }
        let alnumInTop = top.filter { $0.key.isLetter || $0.key.isNumber }
        guard nonSpace > 0, Double(topCount) >= dominantShare * Double(nonSpace), alnumInTop.count <= 1 else { return nil }
        let digitDominated = alnumInTop.first?.key.isNumber ?? false
        if digitDominated && s.count <= dateShapeMaxLength { return nil }   // a burn-in, not a loop
        let pct = Int((Double(topCount) / Double(nonSpace) * 100).rounded(.down))
        return "\(top.count) character(s) '\(top.map { String($0.key) }.joined())' make up \(pct)% of \(nonSpace)"
    }

    /// Rule (b): the same token (case- and edge-punctuation-insensitive)
    /// `maxTokenRun` or more times in a row.
    static func repeatedToken(_ s: String) -> String? {
        let tokens = s.split(whereSeparator: { $0.isWhitespace }).map { raw -> String in
            let stripped = raw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return stripped.isEmpty ? String(raw) : stripped
        }
        guard tokens.count >= maxTokenRun else { return nil }
        var run = 1
        for i in 1..<tokens.count {
            run = tokens[i] == tokens[i - 1] ? run + 1 : 1
            if run >= maxTokenRun { return "token '\(tokens[i].prefix(24))' repeated \(maxTokenRun)+ times in a row" }
        }
        return nil
    }

    /// The captions a verdict calls usable, in order, plus how many were
    /// refused. The one filter the write path and the readers share.
    public static func partition(_ captions: [SceneCaption]) -> (kept: [SceneCaption], refused: Int) {
        var kept: [SceneCaption] = []
        kept.reserveCapacity(captions.count)
        for c in captions where !verdict(c.text).isDegenerate { kept.append(c) }
        return (kept, captions.count - kept.count)
    }

    /// Only the usable captions — for display of rows stored before the
    /// write-side refusal existed (GH #402).
    public static func usable(_ captions: [SceneCaption]) -> [SceneCaption] {
        partition(captions).kept
    }
}
