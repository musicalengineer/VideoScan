// HeldBackCurated.swift — GH #339: what Rick knew about a held-back row, read
// from its `quarantine.raw_row` (the October catalog.json record, verbatim).
//
// One rule: a poisoned row is said, never guessed. `parse` never throws:
//   * text that is not JSON, or JSON that is not an object → `.unreadable`
//     with words (the list shows "the old record could not be read");
//   * a member of the wrong type, or a date / place this app would never
//     have written (not its own canonical form) → that member is ABSENT and
//     one `problems` line names it — it is shown as a problem and never
//     offered for carrying.
// Only the curated members the list shows and the carry may offer are read:
// tag (mediaDisposition), date (+ confidence), place (+ confidence); stars,
// notes and tags are shown, not carried (the ruling names tag, date, place).
//
// (For Rick: a tolerant field extractor over a JSON DOM — each getter checks
// the variant's type tag before it reads, like `std::get_if`.)

import Foundation

public struct HeldBackCurated: Sendable, Equatable {
    public var filename: String?
    public var disposition: MediaDisposition?
    public var userDate: String?
    public var userDateConfidence: String?
    public var userPlace: String?
    public var userPlaceConfidence: String?
    public var starRating: Int = 0
    public var hasUserNotes = false
    public var tagCount = 0
    /// One line per member that was present but unusable.
    public var problems: [String] = []

    public init() {}

    /// The old row as read, or why it could not be.
    public enum Parsed: Sendable, Equatable {
        case read(HeldBackCurated)
        case unreadable(String)
    }

    /// True when the old row carried anything Rick decided (beyond Unreviewed).
    public var carriesCuratedValue: Bool {
        (disposition.map { $0 != .unreviewed } ?? false) || userDate != nil || userPlace != nil
            || starRating > 0 || hasUserNotes || tagCount > 0
    }

    public static func parse(_ text: String?) -> Parsed {
        guard let text else { return .unreadable("the import kept no record for this row") }
        guard let tree = CatalogJSONValue.parse(text) else { return .unreadable("the old record is not valid JSON") }
        guard let object = tree.objectValue else { return .unreadable("the old record is not a record (JSON \(kind(tree)))") }
        var out = HeldBackCurated()
        out.filename = string(object, "filename", into: &out.problems)
        out.disposition = validated(object, "mediaDisposition", into: &out.problems, MediaDisposition.init(rawValue:)) {
            "tag \"\($0.prefix(40))\" is not a tag this app knows"
        }
        out.userDate = validated(object, "userDate", into: &out.problems, { UserDateEntry.canonicalize($0) == $0 ? $0 : nil }) {
            "date \"\($0.prefix(40))\" is not a date this app writes"
        }
        if out.userDate != nil { out.userDateConfidence = string(object, "userDateConfidence", into: &out.problems) }
        out.userPlace = validated(object, "userPlace", into: &out.problems, { UserPlaceEntry.canonicalize($0) == $0 ? $0 : nil }) {
            "place \"\($0.prefix(40))\" is not a place this app writes"
        }
        if out.userPlace != nil { out.userPlaceConfidence = string(object, "userPlaceConfidence", into: &out.problems) }
        out.readShownOnly(object)
        return .read(out)
    }

    /// Stars, notes and tags: shown in the list, never carried.
    private mutating func readShownOnly(_ object: [String: CatalogJSONValue]) {
        if let value = object["starRating"], value != .null {
            if let n = value.int64Value, (0...5).contains(n) { starRating = Int(n) } else { problems.append("stars are not a number from 0 to 5") }
        }
        if let value = object["userNotes"], value != .null {
            if let s = value.stringValue { hasUserNotes = !s.isEmpty } else { problems.append("notes are not text") }
        }
        if let value = object["tags"], value != .null {
            if let a = value.arrayValue { tagCount = a.count } else { problems.append("tags are not a list") }
        }
    }

    /// A text member that must also be a value this app writes: nil when
    /// absent; `refuse`'s problem line (and nil) when `accept` says no.
    private static func validated<T>(_ object: [String: CatalogJSONValue], _ key: String, into problems: inout [String],
                                     _ accept: (String) -> T?, refuse: (String) -> String) -> T? {
        guard let raw = string(object, key, into: &problems) else { return nil }
        if let value = accept(raw) { return value }
        problems.append(refuse(raw))
        return nil
    }

    /// A string member; nil when absent or null; a problem line (and nil)
    /// when it is any other type.
    private static func string(_ object: [String: CatalogJSONValue], _ key: String, into problems: inout [String]) -> String? {
        guard let value = object[key], value != .null else { return nil }
        guard let s = value.stringValue else {
            problems.append("\(key) is JSON \(kind(value)), not text")
            return nil
        }
        return s.isEmpty ? nil : s
    }

    private static func kind(_ v: CatalogJSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "true/false"
        case .int, .double: return "number"
        case .string: return "text"
        case .array: return "list"
        case .object: return "object"
        }
    }
}
