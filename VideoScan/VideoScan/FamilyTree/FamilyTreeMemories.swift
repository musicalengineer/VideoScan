// FamilyTreeMemories.swift
// "Show me some memories…" (Rick, 2026-10-01) — a small, optional button
// at the top-left of the Family Tree. It does NOTHING until clicked; then a
// card lists "Recently discovered": up to five recent things the app
// already knows, newest first, each one a click away from that person in
// the tree.
//
// This is a STUB of a bigger idea — GH #236 (Story of the Day). It is
// built as a provider list so later sources plug in without touching the
// card: CyberBrain additions, Life & Times lines, on-this-day events. A
// provider is one small type conforming to `FamilyMemoryProvider`; add it
// to `FamilyMemories.defaultProviders()`.
//
// TODAY'S PROVIDERS, all over data already on disk:
//   • RecentDocumentsMemoryProvider — documents filed in the last 30 days
//     (People/<…_FSID>/Documents/documents.json; the sidecar's
//     modification date is checked FIRST, so an untouched list is never
//     opened). Only FamilySearch-keyed folders are used: a folder named
//     only for a person cannot be tied to one tree record without a guess.
//   • RecentResearchMemoryProvider — research dossiers saved in the last 30
//     days (People/<key>/research/dossier.json, modification date first)
//     that hold findings Rick marked Confirmed. One item per person.
//   • PersonOfTheDayMemoryProvider — today's Person of the Day.
//
// PRIVACY: an item is shown only for someone who has passed on
// (LifeStatus.privacyVerdict) or is in the inner circle (the home people,
// their spouses and children). Everyone else is dropped before anything of
// theirs is read.
//
// COST AND MEMORY (all off the main actor): one listing of People/ (capped
// at `maxFoldersConsidered` entries) and one stat per FamilySearch-keyed
// folder; at most `maxSidecarsRead` document lists (≤ 8 MB each by the
// store's cap, typically a few KB) and `maxDossiersRead` dossiers (≤ 0.5 MB
// each) are decoded, newest first. Worst case ≈ 40 × 0.5 MB transient;
// nothing is cached — the card re-gathers on each open.
//
// (For Rick: a `protocol` ≈ a C++ abstract base class with pure virtual
// functions; `any FamilyMemoryProvider` ≈ a pointer to that base.)

import Foundation
import VideoScanCore

// MARK: - The item

/// One line of the "Recently discovered" card.
struct FamilyMemory: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case document, research, personOfTheDay

        var symbolName: String {
            switch self {
            case .document: return "doc.text"
            case .research: return "checkmark.seal"
            case .personOfTheDay: return "sun.max"
            }
        }
    }

    /// Stable across gathers: "<kind>.<source id>".
    let id: String
    let kind: Kind
    /// The tree person a click focuses.
    let personID: String
    let title: String
    let detail: String?
    /// When it happened (filed, saved, today) — the sort key.
    let date: Date
}

// MARK: - What a provider may read

/// Everything a provider may look at. Built inside the background task
/// (it holds the archive store, which is not thread-safe to share).
struct FamilyMemoryContext {
    /// Today's Person of the Day as plain values (Core's `Pick` has no
    /// public initializer; tests build one of these instead).
    struct Featured: Equatable, Sendable {
        let personID: String
        let name: String
        let whyToday: String
    }

    let graph: GedcomFamilyGraph
    let innerCircle: Set<String>
    let now: Date
    let calendar: Calendar
    /// The family archive; nil when it is not available.
    let assetStore: FamilyAssetStore?
    let researchStore: ResearchStore?
    let featured: Featured?
    /// How far back "recent" reaches.
    var window: TimeInterval = 30 * 24 * 3600

    var cutoff: Date { now.addingTimeInterval(-window) }

    /// Passed on, or inner circle. Living people outside it are never shown.
    func mayShow(_ personID: String) -> Bool {
        guard let person = graph.people[personID] else { return false }
        if innerCircle.contains(personID) { return true }
        return LifeStatus.privacyVerdict(person, in: graph, now: now, calendar: calendar) != .living
    }
}

/// A source of memories. Implementations must be cheap to construct and
/// must bound their own I/O (see the header).
protocol FamilyMemoryProvider {
    /// At most `limit` items, newest first, for people `context.mayShow`.
    func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory]
}

// MARK: - Gathering

enum FamilyMemories {
    /// How many lines the card shows.
    static let maxItems = 5

    /// The providers in use. GH #236 (Story of the Day): CyberBrain
    /// additions, Life & Times lines and on-this-day plug in here.
    static func defaultProviders() -> [any FamilyMemoryProvider] {
        [RecentDocumentsMemoryProvider(), RecentResearchMemoryProvider(), PersonOfTheDayMemoryProvider()]
    }

    /// Ask every provider, drop anything privacy forbids, dedupe by id,
    /// newest first, at most `limit`.
    static func gather(_ providers: [any FamilyMemoryProvider], in context: FamilyMemoryContext,
                       limit: Int = maxItems) -> [FamilyMemory] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        let all = providers.flatMap { $0.memories(in: context, limit: limit) }
            .filter { context.mayShow($0.personID) && seen.insert($0.id).inserted }
        return Array(all.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.prefix(limit))
    }

    /// The card's empty line.
    static let emptyMessage = "Nothing new yet — file a record or run Research and it'll show up here."

    /// Production: build the context from the installed tree and the
    /// archive configuration, then gather. Call OFF the main actor.
    static func gatherForTree(graph: GedcomFamilyGraph, ownerFamilySearchID: String?,
                              configuration: FamilyAssetConfiguration?,
                              featured: FamilyMemoryContext.Featured?, now: Date = Date()) -> [FamilyMemory] {
        let starts = FamilyTreeWalkCenter.defaultStarts(in: graph, ownerFamilySearchID: ownerFamilySearchID)
        let store = configuration?.makeStore()
        let context = FamilyMemoryContext(
            graph: graph,
            innerCircle: FamilyTreeFeatureContext.innerCircle(graph: graph, starts: starts),
            now: now, calendar: .current,
            assetStore: store,
            researchStore: store.map { ResearchStore(peopleRoot: $0.peopleDirectory) },
            featured: featured)
        return gather(defaultProviders(), in: context)
    }
}

// MARK: - Documents filed recently

struct RecentDocumentsMemoryProvider: FamilyMemoryProvider {
    /// People/ entries looked at (one stat each for keyed folders).
    var maxFoldersConsidered = 20_000
    /// Document lists actually opened, newest first.
    var maxSidecarsRead = 40

    func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory] {
        guard let store = context.assetStore, limit > 0,
              let children = try? FileManager.default.contentsOfDirectory(
                at: store.peopleDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = context.cutoff
        // Pass 1 — names and modification dates only.
        var recent: [(folder: URL, modified: Date, person: GedcomFamilyGraph.Person)] = []
        for folder in children.prefix(maxFoldersConsidered) {
            guard let fsid = FamilyAssetStore.familySearchID(inFolderComponent: folder.lastPathComponent),
                  let person = context.graph.person(familySearchID: fsid),
                  context.mayShow(person.id) else { continue }
            let sidecar = FamilyAssetStore.documentsFolder(in: folder)
                .appendingPathComponent(FamilyAssetStore.documentsSidecarName)
            guard let modified = (try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, modified >= cutoff else { continue }
            recent.append((folder, modified, person))
        }
        recent.sort { $0.modified > $1.modified }
        // Pass 2 — open only the newest lists.
        var out: [FamilyMemory] = []
        for entry in recent.prefix(maxSidecarsRead) {
            let documents = store.documents(inPersonFolder: entry.folder, for: FamilyAssetPerson(entry.person))
            for document in documents where document.addedAt >= cutoff {
                out.append(FamilyMemory(
                    id: "document.\(document.id.uuidString)", kind: .document, personID: entry.person.id,
                    title: "\(document.kind.displayName) filed for \(entry.person.name)",
                    detail: document.note.isEmpty ? document.originalFilename : document.note,
                    date: document.addedAt))
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }
}

// MARK: - Research confirmed recently

struct RecentResearchMemoryProvider: FamilyMemoryProvider {
    var maxFoldersConsidered = 20_000
    /// Dossiers actually decoded, newest first.
    var maxDossiersRead = 40

    func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory] {
        guard let research = context.researchStore, limit > 0,
              let children = try? FileManager.default.contentsOfDirectory(
                at: research.peopleRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = context.cutoff
        // Pass 1 — research keys and dossier modification dates only.
        var recent: [(key: String, modified: Date)] = []
        for child in children.prefix(maxFoldersConsidered) {
            let key = child.lastPathComponent
            guard ResearchSubject.isSafeKey(key), let url = try? research.dossierURL(key: key),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, modified >= cutoff else { continue }
            recent.append((key, modified))
        }
        recent.sort { $0.modified > $1.modified }
        // Pass 2 — decode the newest dossiers.
        var out: [FamilyMemory] = []
        for entry in recent.prefix(maxDossiersRead) {
            guard let dossier = try? research.loadDossier(key: entry.key),
                  let person = Self.person(for: dossier, key: entry.key, in: context.graph),
                  context.mayShow(person.id) else { continue }
            let confirmed = dossier.findings.filter { $0.verdict == .confirmed }
                .sorted { $0.retrievedAt > $1.retrievedAt }
            guard let newest = confirmed.first else { continue }
            let more = confirmed.count > 1 ? " and \(confirmed.count - 1) more" : ""
            out.append(FamilyMemory(
                id: "research.\(entry.key)", kind: .research, personID: person.id,
                title: "Research confirmed for \(person.name)",
                detail: newest.title + more, date: entry.modified))
        }
        return Array(out.prefix(limit))
    }

    /// The tree record a dossier belongs to: by FamilySearch ID, else the
    /// GEDCOM pointer the dossier recorded — accepted only if that record
    /// still derives the same key (a re-pull may have renumbered it).
    static func person(for dossier: ResearchDossier, key: String,
                       in graph: GedcomFamilyGraph) -> GedcomFamilyGraph.Person? {
        if let byID = graph.person(familySearchID: key) { return byID }
        guard let byPointer = graph.people[dossier.subject.gedcomPersonID],
              ResearchSubject(person: byPointer).key == key else { return nil }
        return byPointer
    }
}

// MARK: - Person of the Day

struct PersonOfTheDayMemoryProvider: FamilyMemoryProvider {
    func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory] {
        guard limit > 0, let featured = context.featured,
              context.graph.people[featured.personID] != nil else { return [] }
        let today = context.calendar.startOfDay(for: context.now)
        return [FamilyMemory(
            id: "potd.\(featured.personID)", kind: .personOfTheDay, personID: featured.personID,
            title: "Person of the Day: \(featured.name)", detail: featured.whyToday, date: today)]
    }
}
