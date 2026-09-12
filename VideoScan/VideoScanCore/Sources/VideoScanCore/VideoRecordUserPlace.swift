// VideoRecordUserPlace.swift
// Hand-entered PLACE (Rick 2026-09-12): the pure logic behind Rick's
// typed locations — a near-clone of VideoRecordUserDate.swift.
//
//   "should we add a location field, in a similar way, best guess or
//    I'm sure … typical places would be Franklin MA, Framingham MA,
//    Ashland, Westford, some places in NH, mostly MA, sometimes a trip,
//    Montana, and of course Cape Cod … that way we can search on
//    locations more exactly."
//
//   - `UserPlaceEntry.canonicalize(_:)` — lenient entry normalizer. Trims,
//     collapses whitespace, Title-Cases the town, upper-cases a trailing
//     two-letter state after a comma: "franklin, ma" → "Franklin, MA",
//     "cape cod" → "Cape Cod", "Montana" stays "Montana". It is a FREE
//     TEXT string on purpose — no geocoding, no coordinates, no gazetteer.
//     Coarse values ("Cape Cod", "NH") are valid: the precision is
//     whatever Rick typed, exactly like the partial date.
//   - `UserPlaceStatus` — the DERIVED (never stored) known / estimated /
//     unplaced state, computed from the two stored fields so it can
//     never disagree with them.
//   - `VideoRecord.resolvedPlaceDisplay` / `.resolvedPlaceSortKey` — the
//     "best place" resolution. Today Rick's place is the ONLY place a
//     record can have (no machine place exists yet), so the best place is
//     simply `userPlace`; the accessors exist so a future machine tier
//     (OCR of a road sign, a transcript mention) slots in BELOW Rick's
//     value without touching the table column. O(1) per record — these
//     back a catalog table column.
//   - `UserPlaceEntry.matches(_:against:)` — the exact-match rule shared
//     by the catalog's `place:` prefix search and Hallie's place facet:
//     whole-phrase or town-only, case-insensitive, never substring. A
//     transcript that says "cape cod" is NOT a place match — that is the
//     whole point of the field.
//
// Foundation-only on purpose so it lives in the VideoScanCore package
// beside VideoRecordUserDate.swift.

import Foundation

// MARK: - Confidence (stored as a raw string on VideoRecord)

/// Typed view of `VideoRecord.userPlaceConfidence`. Stored as a plain
/// `String?` ("estimated" | "known") so catalog.json stays readable and
/// future values don't break old decoders; this enum is the app-side
/// vocabulary. Same shape as `UserDateConfidence`.
public enum UserPlaceConfidence: String, Sendable {
    /// Rick's best guess — the DEFAULT.
    case estimated
    /// Certain AT THE PRECISION ENTERED: "Cape Cod" + known means "it
    /// was the Cape", not "it was this beach".
    case known
}

// MARK: - Derived status (computed, never stored)

/// Where a record stands on the "where was this?" question. Derived from
/// the two stored fields on every read so it can never disagree with
/// them — no backfill migration, no scan-time default to forget.
public enum UserPlaceStatus: String, Sendable {
    /// Rick entered a place and marked it certain (at its precision).
    case known
    /// Rick entered a place as a best guess (the default).
    case estimated
    /// No hand-entered place yet — the "No place yet" review queue.
    case unplaced
}

// MARK: - Lenient entry normalizer

/// Namespace for the user-place entry grammar. Pure functions only — no
/// locale, no globals — so the whole table is testable.
/// (`enum` with only statics ≈ a C++ namespace; it can never be
/// instantiated.)
public enum UserPlaceEntry {

    /// Normalize a hand-typed place into its canonical display form.
    ///
    ///   "franklin, ma"     → "Franklin, MA"
    ///   "  cape   cod "    → "Cape Cod"
    ///   "Montana"          → "Montana"
    ///   "nh"               → "NH"          (a bare US state code)
    ///   "wilkes-barre, pa" → "Wilkes-Barre, PA"
    ///   "McGill's Farm"    → "McGill's Farm" (mixed case is left alone)
    ///
    /// Returns nil for empty / punctuation-only input. Rejection is the
    /// normalizer's job; "did the user mean to clear the field" (empty
    /// input) is the UI's job and should be decided before calling this.
    public static func canonicalize(_ raw: String) -> String? {
        // Trim, then split on commas so each segment is Title-Cased on
        // its own and re-joined with the one canonical ", " separator.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A place has at least one letter or digit: "...", "---", "??"
        // are not places (codex #1370 minor).
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let segments = trimmed
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var out: [String] = []
        out.reserveCapacity(segments.count)
        for (i, segment) in segments.enumerated() {
            let isTrailing = (i == segments.count - 1) && segments.count > 1
            // "franklin, ma": the trailing two-letter token after a comma
            // is a state — uppercase it whatever was typed.
            if isTrailing, segment.count == 2, segment.allSatisfy(\.isLetter) {
                out.append(segment.uppercased())
            } else {
                out.append(titleCase(segment))
            }
        }
        return out.joined(separator: ", ")
    }

    /// The town half of a canonical place — everything before the first
    /// comma ("Franklin, MA" → "Franklin"; "Cape Cod" → "Cape Cod").
    public static func town(of canonical: String) -> String {
        if let comma = canonical.firstIndex(of: ",") {
            return String(canonical[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return canonical
    }

    /// The EXACT-match rule. `query` matches `canonical` when, compared
    /// case-insensitively after both go through `canonicalize`:
    ///   * the whole phrase is equal ("franklin, ma" ~ "Franklin, MA"), or
    ///   * the query equals the town alone ("Franklin" ~ "Franklin, MA").
    /// Never substring: "Cod" does not match "Cape Cod", and nothing
    /// outside the place field is consulted.
    public static func matches(_ query: String, against canonical: String) -> Bool {
        guard let q = canonicalize(query) else { return false }
        let lq = q.lowercased()
        let lc = canonical.lowercased()
        if lq == lc { return true }
        return lq == town(of: canonical).lowercased()
    }

    // MARK: Primitives

    /// Runs of whitespace (including newlines) → one space; ends trimmed.
    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Title Case one comma-free segment, word by word (space-separated,
    /// and after a hyphen inside a word):
    ///   * all-lowercase or all-uppercase word → first letter up, rest
    ///     down ("cape" → "Cape", "FRANKLIN" → "Franklin")
    ///   * two-letter US state code, any case → uppercase ("nh" → "NH")
    ///   * short all-caps (≤ 3 letters: "USA", "MA") → kept
    ///   * mixed case ("McGill", "DeSoto") → kept as typed
    static func titleCase(_ segment: String) -> String {
        segment.split(separator: " ").map { word -> String in
            word.split(separator: "-", omittingEmptySubsequences: false)
                .map { titleCaseWord(String($0)) }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func titleCaseWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        if word.count == 2, usStateCodes.contains(word.uppercased()) {
            return word.uppercased()
        }
        let letters = word.filter(\.isLetter)
        let allLower = letters.allSatisfy(\.isLowercase)
        let allUpper = letters.allSatisfy(\.isUppercase)
        if allUpper, letters.count <= 3 { return word }
        if allLower || allUpper {
            return String(first).uppercased() + word.dropFirst().lowercased()
        }
        return word
    }

    /// The 50 states + DC. Used ONLY to recognise a bare two-letter code
    /// so "nh" becomes "NH"; nothing here validates that a place exists.
    static let usStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID",
        "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS",
        "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK",
        "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
        "WI", "WY", "DC",
    ]
}

// MARK: - VideoRecord: derived status + best-place resolution

extension VideoRecord {

    /// Typed read of the stored confidence string. nil when the record
    /// has no user place (the stored confidence is meaningless then) or
    /// the string is unrecognized.
    public var userPlaceConfidenceValue: UserPlaceConfidence? {
        guard userPlace != nil else { return nil }
        return userPlaceConfidence.flatMap(UserPlaceConfidence.init(rawValue:))
    }

    /// Derived — NEVER stored — place status. A user place with a
    /// missing or unrecognized confidence string counts as "estimated":
    /// the conservative default and the entry UI's default.
    public var userPlaceStatus: UserPlaceStatus {
        guard userPlace != nil else { return .unplaced }
        return userPlaceConfidenceValue == .known ? .known : .estimated
    }

    /// Best-place SORT key for the catalog table's Place column. Rick's
    /// place is the only place today, so this is the canonical string
    /// lowercased; "" (sorts first ascending — the review queue clusters
    /// at the top, like undated rows in the Date column) when unplaced.
    public var resolvedPlaceSortKey: String {
        userPlace?.lowercased() ?? ""
    }

    /// Best-place DISPLAY string for the Place column: the canonical
    /// place with an " (est.)" suffix when it's a best guess; a known
    /// place renders bare. Empty when unplaced (the cell shows "—").
    public var resolvedPlaceDisplay: String {
        guard let p = userPlace else { return "" }
        return userPlaceStatus == .known ? p : p + " (est.)"
    }

    /// Tooltip explaining the displayed place.
    public var resolvedPlaceHelp: String {
        switch userPlaceStatus {
        case .known:
            return "Your place — marked as known (certain at the precision you entered)"
        case .estimated:
            return "Your place — best guess. Refine it any time in the inspector."
        case .unplaced:
            return "No place yet — enter one in the inspector (a town or a region like Cape Cod is plenty)."
        }
    }
}
