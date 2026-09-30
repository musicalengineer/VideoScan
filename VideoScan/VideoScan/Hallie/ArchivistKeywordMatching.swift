import Foundation

/// Deterministic keyword text rules shared by the presence executor and the
/// translator's output normalizer. Everything here is pure string work: no
/// model, no catalog access, no regex.
///
/// Three-tier keyword semantics (see `ArchivistPresenceExecutor.keywordBasis`):
///   1. word-start-anchored phrase — the phrase must BEGIN at a token
///      boundary but may continue into more characters: "golf" matches
///      "golfing" and "golfer"; "cia" does NOT match "special", "social" or
///      "Garcia";
///   2. token-all — every SIGNIFICANT token of the keyword is a token of the
///      value ("down the cape" → ["cape"] ⊆ {cape, 1992, archive});
///   3. alias — the same token-all test using `ArchivistKeywordAliases`
///      ("cape cod" → ["capecod"] for lowercase one-word filenames).
/// Never OR-over-tokens: "down the cape" must not match "Down the Road".
///
/// Tier 1 was a NAKED SUBSTRING TEST until 2026-09-05. It answered "tell us
/// about ma breen and the cia" with a transcript hit, because a child saying
/// "my little special rock" contains "cia". Manufacturing evidence for a
/// premise the questioner supplied is worse than saying nothing, so tier 1
/// now anchors the start of the phrase at a token boundary — the same
/// boundary rules `containsToken` already used on both ends. It is
/// deliberately NOT anchored at the end: "golf" must keep matching
/// "golfing".
enum ArchivistKeywordText {
    /// Function words and generic media nouns that carry no place/event
    /// meaning. Dropped from keywords before token matching so a family idiom
    /// ("down the cape", "our trip up to the lake") reduces to its place.
    /// C++ analogy: a `static const std::unordered_set<std::string>`.
    static let stopwords: Set<String> = [
        // Function words the translator tends to keep from the sentence.
        "a", "an", "and", "at", "by", "down", "for", "from", "in", "into",
        "of", "on", "or", "our", "out", "over", "the", "to", "up", "with",
        "my", "me", "we", "us", "you", "i", "it", "its", "is", "are", "was",
        "were", "that", "this", "there", "here", "some", "any", "all",
        // Generic request/media nouns that never name a place or event.
        "trip", "video", "videos", "clip", "clips", "movie", "movies",
        "footage", "show", "find",
    ]

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lowercase, diacritic-folded, canonically composed phrase form used by
    /// the substring tier and by alias membership. Cheap ASCII fast path.
    static func normalizedPhrase(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return value.lowercased()
        }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: posix)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    /// Splits on non-alphanumerics AND on camelCase / letter–digit
    /// boundaries, so "CapeCod_June_1997" → [cape, cod, june, 1997] and
    /// "Cape-1992-archive" → [cape, 1992, archive]. Tokens are lowercase and
    /// diacritic-folded. One linear pass over unicode scalars; no regex.
    static func tokens(_ value: String) -> [String] {
        var tokens: [String] = []
        forEachToken(in: value) { token in
            tokens.append(token)
            return true
        }
        return tokens
    }

    /// True when every needle occurs as a whole token of `value`.
    static func containsAllTokens(_ value: String, _ needles: [String]) -> Bool {
        let bytes = needles.map { Array($0.utf8) }
        return withFoldedBytes(value) { buffer in
            bytes.allSatisfy { containsToken($0, in: buffer) }
        }
    }

    // MARK: Byte-level matching (the hot path)
    //
    // The scalar tokenizer above is the REFERENCE semantics (query side,
    // tests). Record scanning uses these UTF-8 routines instead: a
    // case-insensitive byte search that verifies the tokenizer's boundary
    // rules only at candidate hits. Same answers, ~10× cheaper per value in
    // Debug and no per-record allocation — a 100k-record keyword scan is
    // O(total bytes) with a tiny constant.

    /// Runs `body` over the value's UTF-8 bytes; non-ASCII values are
    /// diacritic-folded first (one Foundation call, only when needed).
    static func withFoldedBytes<R>(
        _ value: String,
        _ body: (UnsafeBufferPointer<UInt8>) -> R
    ) -> R {
        var source = value.utf8.allSatisfy({ $0 < 0x80 })
            ? value
            : value.folding(options: .diacriticInsensitive, locale: posix)
                .precomposedStringWithCanonicalMapping
        return source.withUTF8(body)
    }

    private static func byteKind(_ b: UInt8) -> ScalarKind {
        if b >= 0x61 && b <= 0x7A { return .lower }
        if b >= 0x41 && b <= 0x5A { return .upper }
        if b >= 0x30 && b <= 0x39 { return .digit }
        if b >= 0x80 { return .lower }        // folded non-ASCII: a letter
        return .other
    }

    private static func lowerASCII(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }

    /// Token boundary between byte i-1 and byte i (same rules as
    /// `forEachToken`): non-alphanumeric, letter/digit change, lower→upper,
    /// or the end of an acronym (upper, upper, then lower).
    private static func isBoundary(
        _ bytes: UnsafeBufferPointer<UInt8>, _ i: Int
    ) -> Bool {
        let n = bytes.count
        if i <= 0 || i >= n { return true }
        let p = byteKind(bytes[i - 1]), c = byteKind(bytes[i])
        if p == .other || c == .other { return true }
        if (p == .digit) != (c == .digit) { return true }
        if p == .lower && c == .upper { return true }
        if p == .upper && c == .upper && i + 1 < n
            && byteKind(bytes[i + 1]) == .lower { return true }
        return false
    }

    /// Byte offset of the first case-insensitive (ASCII) occurrence of
    /// `needle` that BEGINS at a token boundary; the phrase tier.
    ///
    /// Anchored at the start only. "golf" finds "golfing" at 0; "cia" finds
    /// nothing in "special" (the candidate at index 3 has a lowercase letter
    /// before it, so it is not a word start).
    static func firstPhraseStart(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Int? {
        let n = bytes.count, m = needle.count
        if m == 0 || m > n { return nil }
        let first = needle[0]
        var i = 0
        outer: while i <= n - m {
            if lowerASCII(bytes[i]) != first { i += 1; continue }
            var j = 1
            while j < m {
                if lowerASCII(bytes[i + j]) != needle[j] { i += 1; continue outer }
                j += 1
            }
            if isBoundary(bytes, i) { return i }
            i += 1
        }
        return nil
    }

    /// Case-insensitive (ASCII) word-start-anchored phrase test.
    static func containsPhrase(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        firstPhraseStart(needle, in: bytes) != nil
    }

    /// Byte offset of the first whole-token occurrence of `needle`: a token
    /// boundary before and after and none inside ("cape" is a token of
    /// "CapeCod_1997" and "cape-1992", not of "scape" or "CaPe").
    static func firstTokenStart(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Int? {
        let n = bytes.count, m = needle.count
        if m == 0 || m > n { return nil }
        let first = needle[0]
        var i = 0
        outer: while i <= n - m {
            if lowerASCII(bytes[i]) != first { i += 1; continue }
            var j = 1
            while j < m {
                if lowerASCII(bytes[i + j]) != needle[j] { i += 1; continue outer }
                j += 1
            }
            if isBoundary(bytes, i), isBoundary(bytes, i + m) {
                var k = i + 1
                var split = false
                while k < i + m {
                    if isBoundary(bytes, k) { split = true; break }
                    k += 1
                }
                if !split { return i }
            }
            i += 1
        }
        return nil
    }

    /// Whole-token test: see `firstTokenStart`.
    static func containsToken(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        firstTokenStart(needle, in: bytes) != nil
    }

    /// Which needle list matched, and where its FIRST needle was found — the
    /// span a citation quotes back so a reader can falsify it.
    struct ListMatch {
        let listIndex: Int
        let start: Int
        let length: Int
    }

    /// First needle list (lowest index wins) whose every token is a token of
    /// the value, or nil.
    static func firstList(
        of lists: [[[UInt8]]], fullyContainedIn bytes: UnsafeBufferPointer<UInt8>
    ) -> ListMatch? {
        for (index, needles) in lists.enumerated() {
            guard let firstNeedle = needles.first else { continue }
            guard let start = firstTokenStart(firstNeedle, in: bytes) else {
                continue
            }
            guard needles.dropFirst().allSatisfy({
                containsToken($0, in: bytes)
            }) else { continue }
            return ListMatch(listIndex: index, start: start,
                             length: firstNeedle.count)
        }
        return nil
    }

    // MARK: Citation excerpts
    //
    // A basis line is a claim a human is meant to be able to check. Before
    // 2026-09-05 a transcript hit printed the WHOLE transcript into it (326
    // basis lines in the September conversation logs were over 400 chars,
    // the largest 60,331) while a phrase hit printed no text at all. Both
    // are unfalsifiable in practice. These two helpers give every citation
    // the same shape: the matched span with a little context.

    /// Characters of context on each side of a quoted match.
    static let citationSnippetContext = 40
    /// Values longer than this are quoted as an excerpt, not in full.
    static let citationValueLimit = 160

    /// The matched span plus `context` bytes either side, whitespace
    /// collapsed, elided with "..." where it was cut. Built from the same
    /// folded buffer the match was found in, so the offsets are exact.
    static func snippet(
        at start: Int,
        length: Int,
        in bytes: UnsafeBufferPointer<UInt8>,
        context: Int = citationSnippetContext
    ) -> String {
        let n = bytes.count
        guard n > 0, start >= 0, start < n, length >= 0 else { return "" }
        let matchEnd = min(n, start + length)
        var lo = max(0, start - context)
        var hi = min(n, matchEnd + context)
        // Never split a UTF-8 scalar: back up off continuation bytes at the
        // low end, run forward past them at the high end.
        while lo > 0, (bytes[lo] & 0xC0) == 0x80 { lo -= 1 }
        while hi < n, (bytes[hi] & 0xC0) == 0x80 { hi += 1 }
        guard lo < hi else { return "" }
        // `String(decoding:as:)`, not `String(bytes:encoding:)`: the range is
        // already scalar-aligned, and a repaired excerpt beats an Optional
        // that would add an unrelated failure path to every citation.
        let slice = UnsafeBufferPointer(rebasing: bytes[lo..<hi])
        // swiftlint:disable:next optional_data_string_conversion
        let text = collapsingWhitespace(String(decoding: slice, as: UTF8.self))
        if text.isEmpty { return "" }
        return (lo > 0 ? "..." : "") + text + (hi < n ? "..." : "")
    }

    /// Runs of whitespace (including newlines) become one space; ends
    /// trimmed. Transcripts are full of newlines that would wreck a one-line
    /// basis.
    static func collapsingWhitespace(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var pendingSpace = false
        for character in value {
            if character.isWhitespace {
                if !out.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(character)
            }
        }
        return out
    }

    /// What a citation should print for the value it matched in: short
    /// values (filenames, tags, volume names) verbatim; long ones
    /// (transcripts, note blobs, OCR dumps) as the matched excerpt.
    static func citationValue(_ value: String, matchSnippet: String?) -> String {
        // utf8.count is O(1) on a native String; `count` would walk 21 KB.
        if value.utf8.count <= citationValueLimit { return value }
        if let matchSnippet, !matchSnippet.isEmpty { return matchSnippet }
        return collapsingWhitespace(String(value.prefix(citationValueLimit)))
            + "..."
    }

    private enum ScalarKind { case upper, lower, digit, other }

    private static func kind(_ scalar: Unicode.Scalar) -> ScalarKind {
        let v = scalar.value
        if v < 0x80 {
            if v >= 0x61 && v <= 0x7A { return .lower }        // a-z
            if v >= 0x41 && v <= 0x5A { return .upper }        // A-Z
            if v >= 0x30 && v <= 0x39 { return .digit }        // 0-9
            return .other
        }
        let properties = scalar.properties
        if properties.isAlphabetic {
            return properties.isUppercase ? .upper : .lower
        }
        if properties.numericType == .decimal { return .digit }
        return .other
    }

    /// Visits each token in order; the visitor returns false to stop early.
    /// The token buffer is reused between tokens (removeAll keeps capacity).
    private static func forEachToken(
        in value: String,
        _ visit: (String) -> Bool
    ) {
        let isASCII = value.utf8.allSatisfy { $0 < 0x80 }
        let source = isASCII
            ? value
            : value.folding(options: .diacriticInsensitive, locale: posix)
                .precomposedStringWithCanonicalMapping

        var current = ""
        var previous: ScalarKind = .other
        var iterator = source.unicodeScalars.makeIterator()
        var lookahead = iterator.next()
        while let scalar = lookahead {
            lookahead = iterator.next()
            let currentKind = kind(scalar)
            let breakBefore: Bool
            switch (previous, currentKind) {
            case (_, .other):
                breakBefore = true
            case (.lower, .upper):
                breakBefore = true                       // capeCod
            case (.upper, .upper):
                // Acronym end: "USAToday" → USA | Today.
                breakBefore = lookahead.map { kind($0) == .lower } ?? false
            case (.digit, .upper), (.digit, .lower), (.upper, .digit),
                 (.lower, .digit):
                breakBefore = true                       // Cape1992, 1997June
            default:
                breakBefore = false
            }
            if breakBefore, !current.isEmpty {
                let token = current
                current.removeAll(keepingCapacity: true)
                if !visit(token) { return }
            }
            if currentKind != .other {
                let v = scalar.value
                if v < 0x80 {
                    if v >= 0x41 && v <= 0x5A {
                        current.unicodeScalars.append(Unicode.Scalar(UInt8(v + 0x20)))
                    } else {
                        current.unicodeScalars.append(scalar)
                    }
                } else if currentKind == .upper {
                    current.append(scalar.properties.lowercaseMapping)
                } else {
                    current.unicodeScalars.append(scalar)
                }
            }
            previous = currentKind
        }
        if !current.isEmpty { _ = visit(current) }
    }

    /// Keyword tokens with stopwords removed; order preserved, duplicates
    /// kept out. Empty means the keyword had no place/event content.
    static func significantTokens(_ value: String) -> [String] {
        var seen: Set<String> = []
        return tokens(value).filter {
            !stopwords.contains($0) && seen.insert($0).inserted
        }
    }
}

/// One keyword from the AST, pre-computed once per query so record
/// evaluation is a set lookup, not repeated string work.
struct ArchivistKeywordQuery: Sendable, Equatable {
    let original: String
    let phrase: String
    let significantTokens: [String]
    /// Alias token lists from `ArchivistKeywordAliases`, already excluding the
    /// keyword's own token list.
    let aliasTokenLists: [[String]]
    /// `[significantTokens] + aliasTokenLists`, the scan order for one field
    /// pass; empty when the keyword has no significant tokens.
    let tokenLists: [[String]]
    /// UTF-8 forms for the byte-level scan (see ArchivistKeywordText).
    let phraseBytes: [UInt8]
    let tokenListBytes: [[[UInt8]]]

    init(_ keyword: String) {
        original = keyword
        phrase = ArchivistKeywordText.normalizedPhrase(keyword)
        significantTokens = ArchivistKeywordText.significantTokens(keyword)
        aliasTokenLists = ArchivistKeywordAliases.aliases(for: keyword)
        tokenLists = significantTokens.isEmpty
            ? [] : [significantTokens] + aliasTokenLists
        phraseBytes = Array(phrase.utf8)
        tokenListBytes = tokenLists.map { $0.map { Array($0.utf8) } }
    }
}

/// Field-by-field token scan of one record, in citation priority order.
/// Nothing is pre-tokenized or cached: each call streams only the fields
/// it needs and stops at the first hit, so a 100k-record scan allocates one
/// small buffer per field visited instead of a Set per field per record.
enum ArchivistKeywordFieldScan {
    struct Hit {
        let field: String
        let value: String
        let timestamp: Double?
        /// Which needle list matched (index into the `lists` argument).
        let listIndex: Int
        /// The matched span with context, for the citation's basis line.
        let snippet: String
    }

    /// First value (citation priority order) whose tokens include every
    /// needle of any list; among lists matched by that value, the lowest
    /// index wins. Every list must be non-empty.
    static func firstValue(
        in record: ArchivistPresenceRecordSnapshot,
        containingAnyOf lists: [[[UInt8]]]
    ) -> Hit? {
        func scan(_ field: String, _ values: [String],
                  timestamps: [Double]? = nil) -> Hit? {
            for (index, value) in values.enumerated() {
                // The snippet is cut inside the closure because the byte
                // offsets index the FOLDED buffer, which need not line up
                // with the original String for non-ASCII values.
                let found = ArchivistKeywordText.withFoldedBytes(value) { buffer -> (Int, String)? in
                    guard let match = ArchivistKeywordText.firstList(
                        of: lists, fullyContainedIn: buffer) else { return nil }
                    return (match.listIndex,
                            ArchivistKeywordText.snippet(
                                at: match.start, length: match.length,
                                in: buffer))
                }
                if let (listIndex, snippet) = found {
                    return Hit(field: field, value: value,
                               timestamp: timestamps?[index],
                               listIndex: listIndex, snippet: snippet)
                }
            }
            return nil
        }
        if let hit = scan("tag", record.tags) { return hit }
        if let hit = scan("userNotes", [record.userNotes]) { return hit }
        if let hit = scan("filename", [record.filename]) { return hit }
        if let hit = scan("directory", [record.directory]) { return hit }
        if let hit = scan("volumeName", [record.volumeName]) { return hit }
        if let hit = scan("person tag", record.confirmedPeople.map(\.name)) {
            return hit
        }
        if let transcript = record.transcript,
           let hit = scan("transcript", [transcript]) {
            return hit
        }
        if let hit = scan("caption", record.captions.map(\.text),
                          timestamps: record.captions.map(\.timestamp)) {
            return hit
        }
        if let hit = scan("ocrDate", record.ocrDateCandidates.map(\.text)) {
            return hit
        }
        return scan("ocrText", record.ocrText.map(\.text))
    }
}
