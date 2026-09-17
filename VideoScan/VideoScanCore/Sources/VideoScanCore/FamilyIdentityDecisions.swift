// FamilyIdentityDecisions.swift
// What Rick has RULED about who is who, kept as data beside the archive so
// new evidence never needs a code change (2026-09-17: "make sure the code is
// flexible to new info … no hardwiring here, just good abstractions and
// working assumptions and evidence as it comes in will be added").
//
// WHY THIS IS DATA AND NOT LOGIC. FamilySearch is a shared tree with real
// duplicates in it, and the only way to settle one is human knowledge that
// arrives slowly and out of order. Rick's grandmother took weeks:
// "Mary Christina O'Connor was a hard won battle of investigation, she is my
// grandma, this is verified, the other Mary should be ignored by the app."
// Elizabeth Brashear is the opposite — she is in the bible records and a
// printed tree from old relatives, and nobody yet knows her FamilySearch
// record. Both states have to be expressible, and the second has to be
// allowed to stay unresolved for months without anything pretending
// otherwise.
//
// WHY NAMES CANNOT BE THE KEY. Rick, same day: "humans reuse first names all
// the time so John Latta is there many times because humans, esp back 200
// yrs ago maybe lived to 40-70 yrs, their son continues the name." A ruling
// keyed on a name would drift onto a grandson. Rulings are keyed on the
// FamilySearch ID, which is also why they survive the re-pull that renumbers
// every GEDCOM xref.
//
// SOMEONE WITH NO FAMILYSEARCH ID is a first-class case, not an error: the
// living relatives in the People tab, who often prefer not to be on
// FamilySearch at all. They are keyed by a stable local key instead.

import Foundation

/// One person's identity ruling. Every field is optional evidence: a
/// half-known person is a normal state here, not a broken one.
public struct FamilyIdentityDecision: Codable, Equatable, Sendable {
    /// `G89Q-34N`, or a local key for someone deliberately not on
    /// FamilySearch.
    public var key: Key
    /// Rick has confirmed this record IS the person. "Verified" is his word
    /// and his standard of proof, not a similarity score.
    public var verified: Bool
    /// This record is the same human being as `key`, and should give way to
    /// it. The app shows the target and keeps this one out of the way.
    public var duplicateOf: Key?
    /// Why — a bible record, a conversation with an uncle, a census. Free
    /// text on purpose: the next piece of evidence will not fit a schema we
    /// guessed today.
    public var note: String?
    public var decidedAt: Date

    public init(key: Key, verified: Bool = false, duplicateOf: Key? = nil,
                note: String? = nil, decidedAt: Date = Date()) {
        self.key = key
        self.verified = verified
        self.duplicateOf = duplicateOf
        self.note = note
        self.decidedAt = decidedAt
    }

    /// How a person is named durably. Two cases and no third, so a caller
    /// cannot forget the second one exists.
    public enum Key: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
        /// A record in the shared tree.
        case familySearch(String)
        /// Someone the People tab knows and FamilySearch does not — a living
        /// relative, usually by choice. The string is a stable local key,
        /// never a display name (see `Key.local(_:)`).
        case local(String)

        public var description: String {
            switch self {
            case .familySearch(let id): return id
            case .local(let key): return "local:\(key)"
            }
        }

        /// The FamilySearch id, when there is one.
        public var familySearchID: String? {
            if case .familySearch(let id) = self { return id }
            return nil
        }

        // Encoded as a PLAIN STRING — "G89Q-34N" or "local:elizabeth-brashear"
        // — not as Swift's synthesised {"familySearch":{"_0":"…"}}. Rick
        // edits this file by hand as evidence turns up; the synthesised
        // shape is unreadable and easy to get wrong.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw.hasPrefix("local:")
                ? .local(String(raw.dropFirst("local:".count)))
                : .familySearch(raw)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }
}

/// Every ruling, loaded from and saved to one file.
///
/// Pure and injectable: the directory is supplied, never discovered, so a
/// test writes to its own scratch dir and never Rick's archive.
public struct FamilyIdentityDecisions: Equatable, Sendable {
    public private(set) var decisions: [FamilyIdentityDecision.Key: FamilyIdentityDecision]

    public init(decisions: [FamilyIdentityDecision] = []) {
        self.decisions = Dictionary(decisions.map { ($0.key, $0) },
                                    uniquingKeysWith: { $1 })
    }

    public var isEmpty: Bool { decisions.isEmpty }
    public var count: Int { decisions.count }

    public func decision(for key: FamilyIdentityDecision.Key) -> FamilyIdentityDecision? {
        decisions[key]
    }

    /// True when this record should be kept out of the way: Rick has said it
    /// is a duplicate of someone else.
    public func isSuppressed(_ key: FamilyIdentityDecision.Key) -> Bool {
        decisions[key]?.duplicateOf != nil
    }

    /// The record that should stand in for this one, following a chain of
    /// rulings and stopping at the first one that does not point onward.
    ///
    /// BOUNDED, and not by recursion: a chain that loops (A duplicate of B,
    /// B duplicate of A — two rulings made months apart, which is exactly
    /// how this data arrives) must not hang the app. It walks at most
    /// `decisions.count` steps and then gives up and answers with where it
    /// got to.
    public func preferred(_ key: FamilyIdentityDecision.Key) -> FamilyIdentityDecision.Key {
        var current = key
        var seen: Set<FamilyIdentityDecision.Key> = [key]
        for _ in 0..<decisions.count {
            guard let next = decisions[current]?.duplicateOf, !seen.contains(next) else { break }
            current = next
            seen.insert(next)
        }
        return current
    }

    /// Record a ruling, replacing any earlier one for that person. New
    /// evidence supersedes old evidence; that is the whole point.
    public mutating func record(_ decision: FamilyIdentityDecision) {
        decisions[decision.key] = decision
    }

    public mutating func remove(_ key: FamilyIdentityDecision.Key) {
        decisions[key] = nil
    }

    // MARK: Storage

    public static let fileName = "family-identity-decisions.json"

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Never throws. A missing or unreadable file means "nothing has been
    /// ruled yet", which is the correct answer and must not stop the tree
    /// from opening.
    public static func load(from directory: URL) -> FamilyIdentityDecisions {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else {
            return FamilyIdentityDecisions()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([FamilyIdentityDecision].self, from: data) else {
            return FamilyIdentityDecisions()
        }
        return FamilyIdentityDecisions(decisions: list)
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Stable order so the file diffs cleanly — Rick edits this by hand.
        let ordered = decisions.values.sorted { $0.key.description < $1.key.description }
        try encoder.encode(ordered).write(to: Self.fileURL(in: directory), options: .atomic)
    }
}
