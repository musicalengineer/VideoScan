// ProvenanceFields.swift (VideoScanCore/Provenance)
// The three provenance fields Rick types himself — digitization date, tape
// label, source — kept as rows of the EXISTING `provenance_assertions` table
// (DECISIONS 2026-11-27 "Provenance fields live in provenance_assertions; no
// schema change"). No DDL: subject_kind 'content', subject_id = the content's
// whole-file SHA-256, field 'digitizedOn' / 'carrier' / 'source', by 'rick'.
//
// PURE: no I/O, no clock, no SQL (one streamed read helper over the reader
// protocol at the bottom). Four parts —
//   1. `current(fromRowsOfOneSubject:)` — what stands per field: Rick's NEWEST
//      row of that field; `confirmed` / `corrected` → its value, `rejected`
//      → unknown (Rick cleared it; an older value never comes back). Machine
//      rows are never read here: a missing field is unknown, never guessed.
//   2. `normalize(_:_:)` — what may be stored: trimmed, one line, bounded;
//      a digitization date is `YYYY`, `YYYY-MM` or `YYYY-MM-DD` (a real
//      calendar day), never anything looser.
//   3. `drafts(...)` — the rows a save appends: a first value `confirmed`, a
//      changed value `corrected`, a cleared value `rejected` (of the value it
//      clears); an unchanged field writes nothing. Evidence says where it was
//      entered.
//   4. `searchWords(_:)` — the words the Catalog search indexes: "digitized
//      2024-07", "tape <label>", "source <text>" (DECISIONS 2026-11-01:
//      human words; never the field key, the state or the digest).
//
// THE TAPE FIELD IS `carrier` (by ruling): the same field the provenance
// estimate (ProvenanceResolver) proposes "VHS" in. Consequences, deliberate:
// Rick's typed label stands over the machine's "VHS" there too (his decision
// always wins, `ProvenanceResolver.standing`), and a Confirm Provenance that
// wrote Rick's confirmed "VHS" shows here as the tape until he types a label.
//
// ARCHIVED CONTENT (rule 3): `digitizedOn` is a DATE of the file, so the
// assertions door refuses it on archived content (`isNameOrDate`); the save
// then rolls back whole and says so. `carrier` and `source` are metadata and
// are accepted there. The form greys the date out for an archived file.
//
// (For Rick: a value-object header — like a C++ `policy.h` of free functions
// over a POD struct; the "event log → current value" fold is `current`.)

import Foundation

/// One of the three fields Rick types.
public enum ProvenanceField: String, CaseIterable, Sendable, Hashable {
    case digitizedOn
    case carrier
    case source

    /// The stored `field` column (the raw values ARE the stored names).
    public var stored: String { rawValue }

    /// The label a person reads.
    public var label: String {
        switch self {
        case .digitizedOn: return "Digitized"
        case .carrier: return "Tape"
        case .source: return "Source"
        }
    }
}

/// What stands for one content: nil = unknown.
public struct ProvenanceFieldValues: Equatable, Sendable, Hashable {
    public var digitizedOn: String?
    public var carrier: String?
    public var source: String?

    public init(digitizedOn: String? = nil, carrier: String? = nil, source: String? = nil) {
        self.digitizedOn = digitizedOn
        self.carrier = carrier
        self.source = source
    }

    public subscript(field: ProvenanceField) -> String? {
        get {
            switch field {
            case .digitizedOn: return digitizedOn
            case .carrier: return carrier
            case .source: return source
            }
        }
        set {
            switch field {
            case .digitizedOn: digitizedOn = newValue
            case .carrier: carrier = newValue
            case .source: source = newValue
            }
        }
    }

    /// Every field unknown.
    public var isEmpty: Bool { digitizedOn == nil && carrier == nil && source == nil }
}

public enum ProvenanceFields {

    /// The only writer of these rows: the catalog's owning (admin) user —
    /// the table's CHECK literal (DECISIONS 2026-11-01).
    public static let owner = "rick"
    /// The word a missing field is shown as. Never a guess.
    public static let unknown = "unknown"
    /// A typed value longer than this is refused (a label, not a document).
    public static let maxLength = 300

    // MARK: 1. Rows → what stands

    /// Per field: Rick's newest row. confirmed / corrected → its value;
    /// rejected → unknown. Rows of other fields and machine rows are ignored.
    public static func current(fromRowsOfOneSubject rows: [CatalogRow.ProvenanceAssertionReading]) -> ProvenanceFieldValues {
        var newest: [ProvenanceField: CatalogRow.ProvenanceAssertionReading] = [:]
        for row in rows where row.by == owner {
            guard let field = ProvenanceField(rawValue: row.field) else { continue }
            if let seen = newest[field], seen.seq > row.seq { continue }
            newest[field] = row
        }
        var out = ProvenanceFieldValues()
        for (field, row) in newest where row.state == "confirmed" || row.state == "corrected" {
            out[field] = row.value
        }
        return out
    }

    // MARK: 2. What may be stored

    public enum Normalized: Equatable, Sendable {
        /// Nothing typed: the field is (or becomes) unknown.
        case empty
        case value(String)
        /// Refused, with the words the form shows.
        case invalid(String)
    }

    /// The form's text → what would be stored.
    public static func normalize(_ field: ProvenanceField, _ text: String) -> Normalized {
        // One line: any run of whitespace (newlines, tabs) becomes one space.
        let oneLine = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if oneLine.isEmpty { return .empty }
        if oneLine.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .invalid("\(field.label) has a character that cannot be stored")
        }
        if oneLine.count > maxLength { return .invalid("\(field.label) is longer than \(maxLength) characters") }
        guard field == .digitizedOn else { return .value(oneLine) }
        return digitizationDate(oneLine).map(Normalized.value)
            ?? .invalid("Digitized must be a year, a year and month, or a day: 2024, 2024-07 or 2024-07-04")
    }

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD` (a real proleptic-Gregorian day),
    /// 1900–2100; nil otherwise. `/` and `.` separators are read as `-`.
    public static func digitizationDate(_ text: String) -> String? {
        let parts = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count == 4, let year = Int(parts[0]), (1900...2100).contains(year) else { return nil }
        if parts.count == 1 { return parts[0] }
        guard parts[1].count <= 2, let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        let mm = String(format: "%02d", month)
        if parts.count == 2 { return "\(parts[0])-\(mm)" }
        guard parts[2].count <= 2, let day = Int(parts[2]), day >= 1, day <= daysIn(year: year, month: month) else { return nil }
        return "\(parts[0])-\(mm)-\(String(format: "%02d", day))"
    }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The form's three texts → the values a save would leave standing, or
    /// the first refusal's words (nothing is saved then).
    public static func values(digitizedOn: String, carrier: String, source: String) -> Result<ProvenanceFieldValues, FieldRefusal> {
        var out = ProvenanceFieldValues()
        for (field, text) in [(ProvenanceField.digitizedOn, digitizedOn), (.carrier, carrier), (.source, source)] {
            switch normalize(field, text) {
            case .empty: out[field] = nil
            case .value(let v): out[field] = v
            case .invalid(let words): return .failure(FieldRefusal(words: words))
            }
        }
        return .success(out)
    }

    public struct FieldRefusal: Error, Equatable, Sendable {
        public let words: String
    }

    // MARK: 3. The rows a save appends

    /// Rows that take `before` to `after` for one content. `digest` must be
    /// the content's whole-file SHA-256 (any spelling; normalised here).
    /// Unchanged fields write nothing; an empty result means "nothing to save".
    public static func drafts(digest: String, before: ProvenanceFieldValues, after: ProvenanceFieldValues,
                              at seconds: Int64, enteredIn place: String) -> [CatalogRow.ProvenanceAssertionDraft] {
        guard let subject = ProvenanceAssertionSubject.contentID(digest) else { return [] }
        let evidence = evidenceJSON(enteredIn: place)
        var out: [CatalogRow.ProvenanceAssertionDraft] = []
        for field in ProvenanceField.allCases {
            let old = before[field], new = after[field]
            guard old != new else { continue }
            let (value, state): (String, String)
            switch (old, new) {
            case (nil, let typed?): (value, state) = (typed, "confirmed")
            case (_?, let typed?): (value, state) = (typed, "corrected")
            case (let cleared?, nil): (value, state) = (cleared, "rejected")
            case (nil, nil): continue
            }
            out.append(CatalogRow.ProvenanceAssertionDraft(subjectKind: ProvenanceAssertionSubject.content, subjectID: subject,
                                                           field: field.stored, value: value, state: state, by: owner,
                                                           at: seconds, confidence: nil, evidenceJSON: evidence))
        }
        return out
    }

    /// `{"entered":"<place>","how":"typed by the owner"}` — sorted keys, so
    /// the same save is the same payload (the door's duplicate rule).
    public static func evidenceJSON(enteredIn place: String) -> String {
        let object: [String: String] = ["entered": place, "how": "typed by the owner"]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    // MARK: 4. Words

    /// "Digitized: 2024-07" / "Tape: unknown" — the Inspector's three lines.
    public static func lines(_ values: ProvenanceFieldValues) -> [String] {
        ProvenanceField.allCases.map { "\($0.label): \(values[$0] ?? unknown)" }
    }

    /// What the Catalog search finds a content by. Empty for an unknown field.
    public static func searchWords(_ values: ProvenanceFieldValues) -> [String] {
        var out: [String] = []
        if let d = values.digitizedOn { out.append("digitized \(d)") }
        if let c = values.carrier { out.append("tape \(c)") }
        if let s = values.source { out.append("source \(s)") }
        return out
    }

    // MARK: Reading the table

    /// Every content that has any of the three fields, what stands for it.
    /// One streamed statement (one subject's rows in memory at a time).
    /// Memory: one small struct per content with a value — 100k ≈ 10 MB.
    public static func all(in reader: any CatalogProvenanceAssertionReading) throws -> [String: ProvenanceFieldValues] {
        var out: [String: ProvenanceFieldValues] = [:]
        try reader.forEachProvenanceAssertionSubject(subjectKind: ProvenanceAssertionSubject.content,
                                                     fields: ProvenanceField.allCases.map(\.stored)) { subject, rows in
            let values = current(fromRowsOfOneSubject: rows)
            if !values.isEmpty { out[subject] = values }
        }
        return out
    }
}
