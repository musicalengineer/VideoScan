import Foundation

/// One normalization contract for GEDCOM and CyberBrain identity lookup.
/// Names remain evidence-bearing aliases; this helper only normalizes their
/// spelling and token boundaries, never inventing fuzzy or phonetic matches.
public enum FamilyIdentityText {
    public static func normalized(_ value: String) -> String {
        // ASCII fast path (2026-08-28): case folding, diacritic folding and
        // canonical composition are all the identity-or-lowercase on pure
        // ASCII, so the three Unicode passes below are skipped for the
        // overwhelming majority of names. Same result byte for byte
        // (FamilyIdentityTextTests pins it against the slow path).
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return asciiLowercasedTrimmed(value)
        }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    static func asciiLowercasedTrimmed(_ value: String) -> String {
        var bytes = Array(value.utf8)
        // Trim ASCII whitespace/newlines (space, \t, \n, \v, \f, \r) at both ends.
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0D).contains(b) }
        var lo = 0, hi = bytes.count
        while lo < hi, isSpace(bytes[lo]) { lo += 1 }
        while hi > lo, isSpace(bytes[hi - 1]) { hi -= 1 }
        if lo > 0 || hi < bytes.count { bytes = Array(bytes[lo..<hi]) }
        for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] |= 0x20 }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func tokens(_ value: String) -> [String] {
        let text = normalized(value)
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Letters and digits only, as Character.isLetter/isNumber say
            // for ASCII.
            var out: [String] = []
            var current: [UInt8] = []
            for b in text.utf8 {
                let isWord = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
                if isWord { current.append(b) }
                else if !current.isEmpty { out.append(String(decoding: current, as: UTF8.self)); current.removeAll(keepingCapacity: true) }
            }
            if !current.isEmpty { out.append(String(decoding: current, as: UTF8.self)) }
            return out
        }
        return text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The pre-fast-path implementation, kept for the equivalence test.
    static func slowNormalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }
    static func slowTokens(_ value: String) -> [String] {
        slowNormalized(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
