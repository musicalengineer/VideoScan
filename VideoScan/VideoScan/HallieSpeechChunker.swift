// HallieSpeechChunker.swift
//
// Kokoro (KokoroSwift) refuses any single utterance whose phoneme-token
// count exceeds 510 (`KokoroTTS.Constants.maxTokenCount`); the helper used
// to receive Hallie's whole answer and die with `tooManyTokens` (live
// 2026-08-26 19:29, a ~600-character list of great-great-grandfathers).
// Measured against the installed helper: name-heavy prose overflows at
// ~520–530 characters (≈1 token per character), but date-heavy prose
// overflows at ~300–350 because "1938" is spoken as "nineteen thirty-eight"
// (≈4 tokens per digit). So the budget is measured in *estimated tokens*,
// not characters, and the halving retry in HallieSpeaker covers whatever the
// estimate still gets wrong.
//
// Pure functions, no state — the kind of thing you'd put in a header-only
// namespace in C++.

import Foundation

enum HallieSpeechChunker {
    /// Conservative per-chunk budget in estimated tokens (~63% of Kokoro's 510).
    static let defaultBudget = 320

    /// Kokoro's hard cap, for tests and diagnostics.
    static let kokoroMaxTokens = 510

    /// Rough phoneme-token estimate: every character is one token except
    /// digits, which expand to spoken number words (~4 tokens each).
    static func estimatedTokens(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.properties.numericType != nil ? 4 : 1) }
    }

    /// Greedily merge already-split sentences into chunks that fit `budget`.
    /// A single sentence over budget is split at `; ` / `: ` / `, ` and, as a
    /// last resort, at a space that is not inside a name (see `halve`).
    static func chunks(sentences: [String], budget: Int = defaultBudget) -> [String] {
        let pieces = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { fit($0, budget: budget) }

        var out: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if estimatedTokens(current) + 1 + estimatedTokens(piece) <= budget {
                current += " " + piece
            } else {
                out.append(current)
                current = piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Break one over-budget sentence into pieces that each fit.
    static func fit(_ sentence: String, budget: Int) -> [String] {
        guard estimatedTokens(sentence) > budget else { return [sentence] }
        for separator in ["; ", ": ", ", "] {
            let parts = splitKeepingSeparator(sentence, separator: separator)
            guard parts.count > 1 else { continue }
            // Re-merge greedily so we don't produce a dozen tiny clauses.
            return chunks(sentences: parts, budget: budget)
        }
        let (head, tail) = halve(sentence)
        guard let tail else { return [sentence] }   // one enormous word: nothing to do
        return fit(head, budget: budget) + fit(tail, budget: budget)
    }

    /// Split at the space nearest the middle that does not sit inside a name
    /// or a number. Returns `(text, nil)` when there is no usable space.
    ///
    /// "Inside a name" means the space joins two capitalised words
    /// ("Richard Breen"), follows an initial ("Richard H. Breen"), or joins a
    /// digit-bearing word to its neighbour ("June 4, 1961", "1,200 feet").
    static func halve(_ text: String) -> (String, String?) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return (text, nil) }

        func joinsName(_ index: Int) -> Bool {   // gap between words[index-1] and words[index]
            let left = words[index - 1], right = words[index]
            if left.contains(where: \.isNumber) || right.contains(where: \.isNumber) { return true }
            if isInitial(left) { return true }
            return startsUppercase(left) && startsUppercase(right)
        }

        let middle = text.count / 2
        var best = (index: 0, distance: Int.max)        // nearest gap outside a name
        var fallback = (index: 0, distance: Int.max)    // nearest gap of any kind
        var offset = 0
        for index in 1..<words.count {
            offset += words[index - 1].count + 1
            let distance = abs(offset - middle)
            if distance < fallback.distance { fallback = (index, distance) }
            if !joinsName(index), distance < best.distance { best = (index, distance) }
        }
        let cut = best.index > 0 ? best.index : fallback.index
        let head = words[..<cut].joined(separator: " ")
        let tail = words[cut...].joined(separator: " ")
        return (head, tail)
    }

    private static func splitKeepingSeparator(_ text: String, separator: String) -> [String] {
        let parts = text.components(separatedBy: separator)
        guard parts.count > 1 else { return [text] }
        let trailing = String(separator.dropLast())    // keep the punctuation, drop the space
        return parts.enumerated().map { index, part in
            index < parts.count - 1 ? part + trailing : part
        }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func startsUppercase(_ word: String) -> Bool {
        word.first(where: \.isLetter)?.isUppercase == true
    }

    /// "H." / "J.R." style initials.
    private static func isInitial(_ word: String) -> Bool {
        word.hasSuffix(".") && word.filter(\.isLetter).count <= 2 && startsUppercase(word)
    }
}
