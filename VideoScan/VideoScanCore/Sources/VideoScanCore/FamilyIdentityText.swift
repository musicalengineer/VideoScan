import Foundation

/// One normalization contract for GEDCOM and CyberBrain identity lookup.
/// Names remain evidence-bearing aliases; this helper only normalizes their
/// spelling and token boundaries, never inventing fuzzy or phonetic matches.
public enum FamilyIdentityText {
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    public static func tokens(_ value: String) -> [String] {
        normalized(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
