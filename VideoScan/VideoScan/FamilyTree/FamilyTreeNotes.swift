// FamilyTreeNotes.swift
// "Archivist Notes" for the Family Tree inspector (Rick 2026-08-26): what
// the family's knowledge file (CyberBrain) says about the selected GEDCOM
// person — including what Rick told Hallie in conversation ("let me tell
// you about Dad Breen") — plus the resolver that maps tree records to
// CyberBrain people.
//
// Resolution order, per person:
//   1. a CyberBrain person whose `gedcomPersonID` IS this record (the link
//      the writer creates when a note is added from this pane), else
//   2. a CyberBrain person whose canonical name or alias finds EXACTLY this
//      tree record through `people(namedLike:)` — the same tolerant matcher
//      Hallie uses (diminutives, suffix rule). An alias that fits two tree
//      records (Jr and Sr) attaches to neither; guessing would put a
//      father's anecdote on the son's card.
//
// Cost: the mapping is built ONCE per (graph, brain) pair — O(brain names ×
// index lookups), tens of ms for 16k people × 500 items — and every
// selection change is then a dictionary hit plus the person's own items.
// Nothing here runs in a view body.
//
// Memory: the resolver holds the brain index (≤ 16 MB JSON by the loader's
// cap) and one small dictionary; the graph's NameIndex is ~100k short
// strings for 16k people.

import Foundation
import VideoScanCore

/// One row in the notes pane. Value type; built once per selection.
struct FamilyTreeNote: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let kind: CyberBrainItem.Kind
    let confidence: CyberBrainItem.Confidence
    let privacy: CyberBrainItem.Privacy
    let createdAt: Date
    /// "Told to Hallie by Rick · Aug 21" / "Archivist note · Aug 26".
    let attribution: String
    /// Which CyberBrain person the item belongs to (for follow-ups).
    let cyberBrainPersonID: String
    /// The tree record this row was READ FOR. A correction acts on this
    /// person, never on whoever is selected when the dialog is confirmed
    /// (same rule as documents, codex 1593 #9).
    var treePersonID: String = ""
    /// Earlier wordings of this note, newest first — filled only while
    /// "Show corrections" is on.
    var earlierVersions: [FamilyTreeNoteCorrectionLine] = []

    /// Caption from the item's first source plus its creation date.
    static func attributionLine(item: CyberBrainItem,
                                source: CyberBrainSource?,
                                now: Date = Date(),
                                calendar: Calendar = .current) -> String {
        let who: String
        switch source?.type {
        case .familyWitness?:
            let teller = source?.attribution ?? "a family member"
            who = "Told to Hallie by \(teller)"
        case .profileNote?:
            who = "Archivist note"
        case .gedcom?:
            who = "From the family tree"
        case .some:
            who = source?.title ?? "Family record"
        case .none:
            who = "Family record"
        }
        return "\(who) · \(shortDate(item.createdAt, now: now, calendar: calendar))"
    }

    /// "Aug 21" this year, "Aug 21, 2024" otherwise.
    static func shortDate(_ date: Date, now: Date = Date(),
                          calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

/// One struck-through line under "Show corrections": a note that was taken
/// back or moved away (red), or an earlier wording of a current note
/// (grey). Built once per selection in the model; never in `body`.
struct FamilyTreeNoteCorrectionLine: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// Removed or moved away — red.
        case retracted
        /// Replaced by a newer wording — grey.
        case earlierWording
    }

    let id: String
    let text: String
    /// "Removed 9/29 — wrong person" / "Moved 9/29 to John Robert Latta" /
    /// "Earlier wording · changed 9/29".
    let caption: String
    let style: Style
    /// Earlier wordings of a note that was later removed or moved.
    var earlierVersions: [FamilyTreeNoteCorrectionLine] = []

    /// "9/29" this year, "9/29/2025" otherwise.
    static func shortDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M/d" : "M/d/yyyy"
        return formatter.string(from: date)
    }

    static func reasonText(_ correction: CyberBrainCorrection) -> String {
        switch correction.reason {
        case .wrongPerson: return "wrong person"
        case .wrongInformation: return "wrong information"
        case .duplicate: return "duplicate"
        case .other: return correction.detail ?? "other"
        }
    }

    /// The caption for a hidden item. `movedToName` resolves a move's
    /// destination person for display.
    static func caption(for item: CyberBrainItem, movedToName: String?,
                        now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = shortDay(item.correction?.at ?? item.updatedAt, now: now, calendar: calendar)
        guard let correction = item.correction else {
            return item.status == .retracted ? "Taken back \(day)" : "Earlier wording · changed \(day)"
        }
        switch correction.action {
        case .removed:
            return "Removed \(day) — \(reasonText(correction))"
        case .moved:
            return "Moved \(day) to \(movedToName ?? "another person")"
        case .edited:
            return "Earlier wording · changed \(day)"
        }
    }
}

/// Who a note being typed is about (see FamilyTreeLiveModel.noteDraftOwner).
struct FamilyTreeNoteDraftOwner: Equatable, Sendable {
    let personID: String
    /// Full tree name — "John Robert Latta".
    let name: String
    /// First given name + surname — "John Latta" — for the button.
    let shortName: String
    /// "1835–1911" when known, so the header tells two Johns apart.
    let years: String?

    init(personID: String, name: String, shortName: String, years: String?) {
        self.personID = personID
        self.name = name
        self.shortName = shortName
        self.years = years
    }

    init(person: GedcomFamilyGraph.Person) {
        self.init(personID: person.id, name: person.name,
                  shortName: Self.shortName(person), years: FamilyTreeLiveModel.summary(person).years)
    }

    /// "John Robert Latta" → "John Latta"; a one-word name stays as is.
    static func shortName(_ person: GedcomFamilyGraph.Person) -> String {
        let words = person.name.split(separator: " ").map(String.init)
        guard let first = words.first else { return person.name }
        let surname = (person.surname?.isEmpty == false ? person.surname : nil)
            ?? (words.count > 1 ? words.last : nil)
        guard let surname, surname != first else { return first }
        return "\(first) \(surname)"
    }
}

/// Tree record → CyberBrain people, built once; `notes(forGedcomID:)` is
/// O(items about that person). `Sendable` so it can be built off the main
/// actor and handed back.
struct FamilyTreeNotesResolver: Sendable {
    let index: CyberBrainIndex
    /// GEDCOM id → CyberBrain person ids, linked first then name matches.
    private let cyberBrainIDsByGedcomID: [String: [String]]
    /// CyberBrain people whose names matched MORE than one tree record and
    /// were therefore attached to none — surfaced so the pane can say so.
    let ambiguousPersonIDs: Set<String>

    init(index: CyberBrainIndex, graph: GedcomFamilyGraph,
         nameIndex: GedcomFamilyGraph.NameIndex? = nil) {
        self.index = index
        let names = nameIndex ?? GedcomFamilyGraph.NameIndex(graph: graph)
        var map: [String: [String]] = [:]
        var ambiguous: Set<String> = []
        for person in index.archive.people {
            if let pointer = person.gedcomPersonID, graph.people[pointer] != nil {
                map[pointer, default: []].append(person.id)
                continue
            }
            // Name path: try the canonical name, then each alias; the first
            // spelling that pins exactly one tree record wins.
            var attached = false
            var sawAmbiguity = false
            for spelling in [person.canonicalName] + person.aliases {
                let matches = names.people(namedLike: spelling)
                if matches.count == 1 {
                    map[matches[0].id, default: []].append(person.id)
                    attached = true
                    break
                }
                if matches.count > 1 { sawAmbiguity = true }
            }
            if !attached, sawAmbiguity { ambiguous.insert(person.id) }
        }
        self.cyberBrainIDsByGedcomID = map
        self.ambiguousPersonIDs = ambiguous
    }

    /// The CyberBrain people that stand for this tree record.
    func cyberBrainPeople(forGedcomID gedcomID: String) -> [CyberBrainPerson] {
        (cyberBrainIDsByGedcomID[gedcomID] ?? []).compactMap { index.person(id: $0) }
    }

    /// Every active item about this tree record, newest first.
    func notes(forGedcomID gedcomID: String, now: Date = Date()) -> [FamilyTreeNote] {
        var out: [FamilyTreeNote] = []
        var seen: Set<String> = []
        for personID in cyberBrainIDsByGedcomID[gedcomID] ?? [] {
            for item in index.allActiveItems(for: personID) where seen.insert(item.id).inserted {
                let source = item.sourceIDs.compactMap { index.source(id: $0) }.first
                out.append(FamilyTreeNote(
                    id: item.id,
                    text: item.text,
                    kind: item.kind,
                    confidence: item.confidence,
                    privacy: item.privacy,
                    createdAt: item.createdAt,
                    attribution: FamilyTreeNote.attributionLine(item: item, source: source, now: now),
                    cyberBrainPersonID: personID,
                    treePersonID: gedcomID))
            }
        }
        return out.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    /// "Show corrections" for one tree record: earlier wordings keyed by
    /// the item they now hang under (a current note OR a removed/moved
    /// one), and the removed/moved notes themselves, newest first.
    /// O(items about this person); called once per selection while the
    /// toggle is on.
    func corrections(forGedcomID gedcomID: String, now: Date = Date())
        -> (earlierByItemID: [String: [FamilyTreeNoteCorrectionLine]], retracted: [FamilyTreeNoteCorrectionLine]) {
        var hidden: [String: CyberBrainItem] = [:]
        var visibleIDs: Set<String> = []
        var successor: [String: String] = [:]
        for personID in cyberBrainIDsByGedcomID[gedcomID] ?? [] {
            let active = index.allActiveItems(for: personID)
            let gone = index.hiddenItems(for: personID)
            for item in active { visibleIDs.insert(item.id) }
            for item in gone { hidden[item.id] = item }
            for item in active + gone {
                if let prior = item.supersedesItemID { successor[prior] = item.id }
            }
        }
        func line(_ item: CyberBrainItem, style: FamilyTreeNoteCorrectionLine.Style) -> FamilyTreeNoteCorrectionLine {
            let movedTo = item.correction?.movedToPersonID.flatMap { index.person(id: $0)?.canonicalName }
            return FamilyTreeNoteCorrectionLine(
                id: item.id, text: item.text,
                caption: FamilyTreeNoteCorrectionLine.caption(for: item, movedToName: movedTo, now: now),
                style: style)
        }
        // An earlier wording hangs under the newest version in its chain
        // that is either current or retracted. Chains are acyclic (the
        // validator), and the walk is bounded by the item count anyway.
        var earlier: [String: [(Date, FamilyTreeNoteCorrectionLine)]] = [:]
        var retractedItems: [CyberBrainItem] = []
        for item in hidden.values {
            if item.status == .retracted {
                retractedItems.append(item)
                continue
            }
            var head = item.id
            var steps = 0
            while let next = successor[head], steps <= hidden.count {
                head = next
                steps += 1
                if visibleIDs.contains(head) || hidden[head]?.status == .retracted { break }
            }
            let key = (visibleIDs.contains(head) || hidden[head]?.status == .retracted) ? head : item.id
            earlier[key, default: []].append((item.updatedAt, line(item, style: .earlierWording)))
        }
        let earlierByItemID = earlier.mapValues { rows in
            rows.sorted { $0.0 == $1.0 ? $0.1.id > $1.1.id : $0.0 > $1.0 }.map(\.1)
        }
        var retracted = retractedItems
            .sorted { lhs, rhs in
                let l = lhs.correction?.at ?? lhs.updatedAt, r = rhs.correction?.at ?? rhs.updatedAt
                return l == r ? lhs.id < rhs.id : l > r
            }
            .map { item -> FamilyTreeNoteCorrectionLine in
                var row = line(item, style: .retracted)
                row.earlierVersions = earlierByItemID[item.id] ?? []
                return row
            }
        // An earlier wording whose chain ended nowhere visible (its newer
        // version is about other people only) still shows, on its own.
        for (key, rows) in earlierByItemID where !visibleIDs.contains(key) && hidden[key]?.status != .retracted {
            retracted.append(contentsOf: rows)
        }
        return (earlierByItemID, retracted)
    }
}

/// Where the production CyberBrain lives — the same directory Hallie's
/// coordinator reads and the telling mode writes.
enum FamilyTreeNotesStorage {
    /// The real CyberBrain — EXCEPT inside a test host, where it is a
    /// private per-process temp directory (2026-09-24, QA follow-up).
    /// This is the DEFAULT for FamilyTreeLiveModel, the pronunciation
    /// lexicon and the live pronunciation writer, so a test that forgets
    /// to inject a brain used to read — and could WRITE — Rick's family
    /// knowledge. Same rule and same shared detector as
    /// FamilyGraphCompiledStore.production. No env override: no test has
    /// ever needed the real brain, and none should.
    static var productionRootURL: URL? {
        let support = TestHostDetection.sandboxedApplicationSupportRoot(for: "FamilyTreeNotesStorage.productionRootURL")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?.appendingPathComponent("VideoScan/cyberbrain", isDirectory: true)
    }

    /// Load the archive and build an index; nil when no brain exists yet.
    /// Throws for a corrupt/unsafe file so the pane can say so instead of
    /// silently showing nothing.
    static func loadIndex(rootURL: URL) throws -> CyberBrainIndex? {
        do {
            return try CyberBrainIndex(archive: CyberBrainLoader(rootURL: rootURL).load())
        } catch CyberBrainError.missingArchive {
            return nil
        }
    }
}
