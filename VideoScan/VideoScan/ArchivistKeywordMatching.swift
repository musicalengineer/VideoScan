import Foundation

/// Deterministic keyword text rules shared by the presence executor and the
/// translator's output normalizer. Everything here is pure string work: no
/// model, no catalog access, no regex.
///
/// Three-tier keyword semantics (see `ArchivistPresenceExecutor.keywordBasis`):
///   1. whole-phrase substring — "cape cod" inside "CapeCod_June_1997" after
///      normalization ("cape cod" is not a substring of "capecod_june_1997",
///      but "cape" is of "cape-1992");
///   2. token-all — every SIGNIFICANT token of the keyword is a token of the
///      value ("down the cape" → ["cape"] ⊆ {cape, 1992, archive});
///   3. alias — the same token-all test using `ArchivistKeywordAliases`
///      ("cape cod" → ["capecod"] for lowercase one-word filenames).
/// Never OR-over-tokens: "down the cape" must not match "Down the Road".
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

    /// Case-insensitive (ASCII) substring test; the phrase tier.
    static func containsPhrase(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        let n = bytes.count, m = needle.count
        if m == 0 || m > n { return false }
        let first = needle[0]
        var i = 0
        outer: while i <= n - m {
            if lowerASCII(bytes[i]) != first { i += 1; continue }
            var j = 1
            while j < m {
                if lowerASCII(bytes[i + j]) != needle[j] { i += 1; continue outer }
                j += 1
            }
            return true
        }
        return false
    }

    /// Whole-token test: a case-insensitive occurrence of `needle` with a
    /// token boundary before and after and none inside ("cape" is a token of
    /// "CapeCod_1997" and "cape-1992", not of "scape" or "CaPe").
    static func containsToken(
        _ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        let n = bytes.count, m = needle.count
        if m == 0 || m > n { return false }
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
                if !split { return true }
            }
            i += 1
        }
        return false
    }

    /// Index of the first needle list (lowest index wins) whose every token
    /// is a token of the value, or nil.
    static func firstList(
        of lists: [[[UInt8]]], fullyContainedIn bytes: UnsafeBufferPointer<UInt8>
    ) -> Int? {
        for (index, needles) in lists.enumerated()
            where needles.allSatisfy({ containsToken($0, in: bytes) }) {
            return index
        }
        return nil
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
                if let listIndex = ArchivistKeywordText.withFoldedBytes(value, {
                    ArchivistKeywordText.firstList(of: lists, fullyContainedIn: $0)
                }) {
                    return Hit(field: field, value: value,
                               timestamp: timestamps?[index],
                               listIndex: listIndex)
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
