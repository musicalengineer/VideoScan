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
                    cyberBrainPersonID: personID))
            }
        }
        return out.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}

/// Where the production CyberBrain lives — the same directory Hallie's
/// coordinator reads and the telling mode writes.
enum FamilyTreeNotesStorage {
    static var productionRootURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VideoScan/cyberbrain", isDirectory: true)
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
