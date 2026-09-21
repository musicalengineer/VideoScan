// PersonFactRefresh.swift (VideoScanCore)
// "Refresh from FamilySearch…" for ONE person (Rick, 2026-09-21):
//
//   "I have to edit FS then refresh so it helps me with the research to keep
//    the FS and the app's FT in sync. We don't want to do a whole gedcom dump
//    when we can just get the one."
//
// This file is the PURE half: what a one-person getmyancestors export must
// look like before VideoScan will believe it (`PersonRefreshFile.evaluate`),
// the facts of one person as the tree and as FamilySearch record them
// (`PersonFacts`), and the per-field difference between the two
// (`PersonRefreshDiff.compute`). No I/O, no clock, no SwiftUI — table-tested
// in PersonFactRefreshTests.
//
// FACTS ONLY. The fields below are exactly the facts GedcomFamilyGraph
// models (name, surname, sex, birth/death date + place, marriage date).
// Burial, marriage PLACE and other events are not modelled by the parser,
// so they are not diffed: a diff that proposed a value the tree could not
// show would be a promise the overlay could not keep. Relationships are
// compared only to be REPORTED — `PersonRefreshRelationshipNote` — and there
// is no field for them, so nothing downstream can apply one.
//
// (For Rick: the enums with associated values below are tagged unions —
// C++ `std::variant` with the tag and payload in one value. `Result<T, E>`
// ≈ `std::expected<T, E>`.)

import Foundation

// MARK: - Fields

/// One fact the refresh can change. `key` is the on-disk spelling in the
/// overlay file — never rename a key; add cases at the end.
public enum PersonRefreshField: Hashable, Sendable, Comparable {
    case name
    case surname
    case sex
    case birthDate
    case birthPlace
    case deathDate
    case deathPlace
    /// The MARR date of the family this person shares with the spouse who
    /// carries this FamilySearch ID. Keyed by the spouse's FSID, never by a
    /// file-local @F…@ pointer, because pointers move between exports.
    case marriageDate(spouseFamilySearchID: String)

    public var key: String {
        switch self {
        case .name: return "name"
        case .surname: return "surname"
        case .sex: return "sex"
        case .birthDate: return "birthDate"
        case .birthPlace: return "birthPlace"
        case .deathDate: return "deathDate"
        case .deathPlace: return "deathPlace"
        case .marriageDate(let spouse): return "marriageDate:\(spouse)"
        }
    }

    /// Parses an overlay key. Unknown keys are nil — a hand-edited
    /// "parents" or "FAMC" key in the overlay file therefore does NOTHING,
    /// which is the relationship guarantee enforced at the parser.
    public init?(key: String) {
        switch key {
        case "name": self = .name
        case "surname": self = .surname
        case "sex": self = .sex
        case "birthDate": self = .birthDate
        case "birthPlace": self = .birthPlace
        case "deathDate": self = .deathDate
        case "deathPlace": self = .deathPlace
        default:
            let prefix = "marriageDate:"
            guard key.hasPrefix(prefix) else { return nil }
            let spouse = String(key.dropFirst(prefix.count))
            guard GedcomFamilyGraph.isFamilySearchID(spouse) else { return nil }
            self = .marriageDate(spouseFamilySearchID: spouse)
        }
    }

    /// Display order in the sheet: who, then born, then died, then married.
    var sortRank: Int {
        switch self {
        case .name: return 0
        case .surname: return 1
        case .sex: return 2
        case .birthDate: return 3
        case .birthPlace: return 4
        case .deathDate: return 5
        case .deathPlace: return 6
        case .marriageDate: return 7
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortRank != rhs.sortRank ? lhs.sortRank < rhs.sortRank : lhs.key < rhs.key
    }
}

// MARK: - Facts of one person

/// The facts of one person, as one source records them. Built from a graph
/// record; compared field by field.
public struct PersonFacts: Equatable, Sendable {
    public struct SpouseLink: Equatable, Sendable {
        public var familySearchID: String?
        public var name: String
        public var marriageDate: String?
        public init(familySearchID: String?, name: String, marriageDate: String?) {
            self.familySearchID = familySearchID
            self.name = name
            self.marriageDate = marriageDate
        }
    }

    public var familySearchID: String
    public var name: String
    public var surname: String?
    public var sex: String
    public var birthDate: String?
    public var birthPlace: String?
    public var deathDate: String?
    public var deathPlace: String?
    public var spouses: [SpouseLink]

    public init(familySearchID: String, name: String, surname: String? = nil, sex: String = "",
                birthDate: String? = nil, birthPlace: String? = nil,
                deathDate: String? = nil, deathPlace: String? = nil,
                spouses: [SpouseLink] = []) {
        self.familySearchID = familySearchID
        self.name = name
        self.surname = surname
        self.sex = sex
        self.birthDate = birthDate
        self.birthPlace = birthPlace
        self.deathDate = deathDate
        self.deathPlace = deathPlace
        self.spouses = spouses
    }

    /// Facts of `person` as `graph` records them. Nil when the record has
    /// no FamilySearch ID (a refresh is keyed on it).
    public init?(person: GedcomFamilyGraph.Person, in graph: GedcomFamilyGraph) {
        guard let fsid = person.familySearchID else { return nil }
        self.init(familySearchID: fsid, name: person.name, surname: person.surname, sex: person.sex,
                  birthDate: person.birthDate, birthPlace: person.birthPlace,
                  deathDate: person.deathDate, deathPlace: person.deathPlace,
                  spouses: graph.familyUnits(of: person).map {
                      SpouseLink(familySearchID: $0.spouse?.familySearchID,
                                 name: $0.spouse?.name ?? "unknown spouse",
                                 marriageDate: $0.marriageDate)
                  })
    }

    /// The value of one field ("" and nil both read as nil).
    public func value(of field: PersonRefreshField) -> String? {
        let raw: String?
        switch field {
        case .name: raw = name
        case .surname: raw = surname
        case .sex: raw = sex
        case .birthDate: raw = birthDate
        case .birthPlace: raw = birthPlace
        case .deathDate: raw = deathDate
        case .deathPlace: raw = deathPlace
        case .marriageDate(let spouse):
            raw = spouses.first { $0.familySearchID == spouse }?.marriageDate
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

// MARK: - Diff

/// One changed fact: what the tree shows now, what FamilySearch says.
public struct PersonRefreshChange: Equatable, Sendable, Identifiable {
    public let field: PersonRefreshField
    /// "Birth date", "Marriage date (with Muriel Lamb)".
    public let label: String
    /// Nil = the tree has no value. `new == nil` = FamilySearch no longer
    /// records one (applying clears it in the tree's view).
    public let old: String?
    public let new: String?
    public var id: String { field.key }

    public init(field: PersonRefreshField, label: String, old: String?, new: String?) {
        self.field = field
        self.label = label
        self.old = old
        self.new = new
    }
}

/// A relationship difference. REPORTED, never applied: a person refresh
/// fetches one person and their spouses, which is not enough evidence to
/// rewire a 39,250-person tree (a full pull updates relationships).
public struct PersonRefreshRelationshipNote: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// FamilySearch links a spouse the tree does not.
        case spouseOnlyOnFamilySearch
        /// The tree links a spouse FamilySearch no longer shows.
        case spouseOnlyInTree
    }
    public let kind: Kind
    public let spouseName: String
    public let spouseFamilySearchID: String
    public var id: String { kind.rawValue + ":" + spouseFamilySearchID }

    public init(kind: Kind, spouseName: String, spouseFamilySearchID: String) {
        self.kind = kind
        self.spouseName = spouseName
        self.spouseFamilySearchID = spouseFamilySearchID
    }

    /// The honest sentence the sheet shows beside it.
    public var sentence: String {
        switch kind {
        case .spouseOnlyOnFamilySearch:
            return "FamilySearch shows a different spouse (\(spouseName), \(spouseFamilySearchID)) — "
                + "not changed here; a full tree pull updates relationships."
        case .spouseOnlyInTree:
            return "The tree links \(spouseName) (\(spouseFamilySearchID)) as a spouse but FamilySearch "
                + "no longer does — not changed here; a full tree pull updates relationships."
        }
    }
}

public struct PersonRefreshDiff: Equatable, Sendable {
    public let familySearchID: String
    /// Changed facts, in display order. Empty = "Already matches FamilySearch."
    public let changes: [PersonRefreshChange]
    /// Relationship differences — shown, never applied.
    public let relationshipNotes: [PersonRefreshRelationshipNote]

    public var factsMatch: Bool { changes.isEmpty }

    /// Pure field-by-field comparison. Rules, each one a false alarm that
    /// would otherwise make Rick distrust the sheet:
    ///   • whitespace runs and letter case are not changes ("21 FEB 1929"
    ///     == "21 Feb 1929" — GEDCOM months are case-insensitive);
    ///   • "" and nil are the same absence; sex "U" is the same as "";
    ///   • FamilySearch returning NO name is never a proposal to erase the
    ///     tree's name (a nameless record is a broken fetch, not a fact);
    ///   • a marriage is compared only when BOTH sides name the spouse by
    ///     FamilySearch ID — pointers and names are not identities;
    ///   • parents are never compared: `-a 0` does not fetch them, and
    ///     absence of data is not a different parent.
    public static func compute(installed: PersonFacts, incoming: PersonFacts) -> PersonRefreshDiff {
        var changes: [PersonRefreshChange] = []
        func consider(_ field: PersonRefreshField, _ label: String) {
            let old = installed.value(of: field)
            let new = incoming.value(of: field)
            if field == .name, new == nil { return }
            if field == .sex, normalizedSex(old) == normalizedSex(new) { return }
            guard comparable(old) != comparable(new) else { return }
            changes.append(PersonRefreshChange(field: field, label: label, old: old, new: new))
        }
        consider(.name, "Name")
        consider(.surname, "Surname")
        consider(.sex, "Sex")
        consider(.birthDate, "Birth date")
        consider(.birthPlace, "Birth place")
        consider(.deathDate, "Death date")
        consider(.deathPlace, "Death place")

        var notes: [PersonRefreshRelationshipNote] = []
        let installedSpouses = Dictionary(
            installed.spouses.compactMap { s in s.familySearchID.map { ($0, s) } },
            uniquingKeysWith: { first, _ in first })
        let incomingSpouses = Dictionary(
            incoming.spouses.compactMap { s in s.familySearchID.map { ($0, s) } },
            uniquingKeysWith: { first, _ in first })
        for fsid in incomingSpouses.keys.sorted() {
            let theirs = incomingSpouses[fsid]!
            if installedSpouses[fsid] != nil {
                consider(.marriageDate(spouseFamilySearchID: fsid), "Marriage date (with \(theirs.name))")
            } else {
                notes.append(PersonRefreshRelationshipNote(
                    kind: .spouseOnlyOnFamilySearch, spouseName: theirs.name, spouseFamilySearchID: fsid))
            }
        }
        for fsid in installedSpouses.keys.sorted() where incomingSpouses[fsid] == nil {
            notes.append(PersonRefreshRelationshipNote(
                kind: .spouseOnlyInTree, spouseName: installedSpouses[fsid]!.name, spouseFamilySearchID: fsid))
        }
        return PersonRefreshDiff(familySearchID: installed.familySearchID,
                                 changes: changes.sorted { $0.field < $1.field },
                                 relationshipNotes: notes)
    }

    public init(familySearchID: String, changes: [PersonRefreshChange],
                relationshipNotes: [PersonRefreshRelationshipNote]) {
        self.familySearchID = familySearchID
        self.changes = changes
        self.relationshipNotes = relationshipNotes
    }

    static func comparable(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed.lowercased()
    }

    static func normalizedSex(_ value: String?) -> String {
        let v = (value ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return v == "U" ? "" : v
    }
}

// MARK: - Accepting a one-person export

/// Why a one-person export was not accepted. Each case is one honest
/// sentence; none of them changes anything.
public enum PersonRefreshRefusal: Error, Equatable, Sendable {
    /// Not a `0 HEAD … 0 TRLR` GEDCOM (or unreadable).
    case notAGedcom(fileName: String)
    /// FamilySearch returned nobody for the ID — merged away or deleted.
    case recordGone(requested: String)
    /// FamilySearch returned a DIFFERENT person (typically the survivor of
    /// a merge answering for the old ID).
    case differentPersonReturned(requested: String, returned: String)
    /// More people than the requested one and their immediate family —
    /// this is not a one-person export, and treating it as one is exactly
    /// how a tree gets narrowed.
    case tooManyPeople(requested: String, people: Int, unrelated: Int)

    public var sentence: String {
        switch self {
        case .notAGedcom(let name):
            return "\(name) is not a valid GEDCOM file (it may be empty because the download stopped — "
                + "check the Terminal window). Nothing was changed."
        case .recordGone(let id):
            return "FamilySearch no longer has \(id) — it may have been merged into another record; "
                + "open it on FamilySearch to find the new ID. Nothing was changed."
        case .differentPersonReturned(let requested, let returned):
            return "FamilySearch answered \(requested) with a different person, \(returned) — the record "
                + "may have been merged into \(returned). Nothing was changed; open \(requested) on "
                + "FamilySearch to check."
        case .tooManyPeople(let id, let people, let unrelated):
            return "The download for \(id) holds \(people) people, \(unrelated) of them not \(id)'s "
                + "immediate family — that is not a one-person refresh, so it was not used. Nothing was changed."
        }
    }

    /// Short machine tag for the `[fs-refresh] refused` log line.
    public var logReason: String {
        switch self {
        case .notAGedcom: return "not-a-gedcom"
        case .recordGone: return "record-gone"
        case .differentPersonReturned(_, let returned): return "different-person(\(returned))"
        case .tooManyPeople(_, let people, let unrelated): return "too-many-people(\(people) people, \(unrelated) unrelated)"
        }
    }
}

public enum PersonRefreshFile {
    /// Accept or refuse a one-person export. `graph` is the parse of the
    /// downloaded file (nil = it did not parse as GEDCOM). On success the
    /// requested person's facts come back, spouses included.
    ///
    /// "Immediate family stubs": getmyancestors `-m` writes each spouse as
    /// a full INDI linked through a FAM; parents/children would appear only
    /// with `-a`/`-d` > 0. Anyone in the file who is not the requested
    /// person, a parent, a spouse or a child of theirs is unrelated, and
    /// one unrelated person is enough to refuse.
    public static func evaluate(_ graph: GedcomFamilyGraph?, fileName: String,
                                requestedFamilySearchID raw: String) -> Result<PersonFacts, PersonRefreshRefusal> {
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let graph else { return .failure(.notAGedcom(fileName: fileName)) }
        guard let principal = graph.person(familySearchID: requested) else {
            if graph.people.isEmpty { return .failure(.recordGone(requested: requested)) }
            // The first INDI is who the tool was asked for (it writes the
            // starting individual first); fall back to any ID in the file.
            let returned = graph.rootPerson?.familySearchID
                ?? graph.people.keys.sorted().lazy.compactMap { graph.people[$0]?.familySearchID }.first
            guard let returned else { return .failure(.recordGone(requested: requested)) }
            return .failure(.differentPersonReturned(requested: requested, returned: returned))
        }
        var family: Set<String> = [principal.id]
        for relation in [GedcomFamilyGraph.Relation.parents, .spouse, .children] {
            for relative in graph.relatives(relation, of: principal) { family.insert(relative.id) }
        }
        let unrelated = graph.people.keys.filter { !family.contains($0) }.count
        guard unrelated == 0 else {
            return .failure(.tooManyPeople(requested: requested, people: graph.people.count, unrelated: unrelated))
        }
        // `person(familySearchID:)` matched, so the facts init cannot fail.
        return .success(PersonFacts(person: principal, in: graph)!)
    }
}
