// FamilyTreeLiveModel.swift
// Observable model behind the Family Tree tab (feature/family-tree-gedcom,
// 2026-08-22). Replaces the hard-coded demo people with the real
// GedcomFamilyGraph when a .ged exists under App Support/VideoScan/
// family-tree/originals; falls back to the demo tree (with a banner) when
// none does.
//
// Division of labour:
//   - FamilyGraphFileLoader  → which .ged to read (newest wins; only the
//                              injected directory is consulted)
//   - GedcomFamilyGraph      → parse + kinship (VideoScanCore)
//   - FamilyTreeLayout       → pure geometry (no SwiftUI)
//   - this class             → selection/search state, photo lookup, and
//                              turning a layout into display cards
//
// Nothing here runs per-frame: `scene` and `filteredPeople` are rebuilt
// only when the selection, search text, photos, or graph change, so the
// view's `body` does O(cards) work, never O(people).
//
// Memory: the graph holds one Person per INDI (a few hundred bytes each) —
// a 50,000-person GEDCOM is ~tens of MB. Photos are held only for cards
// currently on the canvas (≤ ~100) plus the user's in-session overrides.

import AppKit
import Combine
import Foundation

// MARK: - Display types

/// Sex as the card draws it. GEDCOM records "M" / "F" / "" (or "U").
enum FamilyTreeSex: Equatable {
    case male, female, unknown

    init(gedcom value: String) {
        switch value.uppercased() {
        case "M": self = .male
        case "F": self = .female
        default: self = .unknown
        }
    }

    var glyph: String {
        switch self {
        case .male: return "♂"
        case .female: return "♀"
        case .unknown: return ""
        }
    }
}

/// One row in the sidebar / one person in the inspector. Only facts the
/// GEDCOM actually records; nothing is invented.
struct FamilyTreePersonSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let surname: String?
    let years: String?
    let sex: FamilyTreeSex
    /// "I123" style GEDCOM pointer for live people, a short label for demo
    /// people. Shown in monospace on the card's last line.
    let reference: String
}

/// One card on the canvas, resolved from a layout node.
struct FamilyTreeCard: Identifiable {
    let id: String
    let person: FamilyTreePersonSummary
    let position: CGPoint
    let isRoot: Bool
    let photo: NSImage?
}

struct FamilyTreeScene {
    var cards: [FamilyTreeCard] = []
    var edges: [FamilyTreeLayout.Edge] = []
    var size: CGSize = .zero

    static let empty = FamilyTreeScene()
}

/// The people the inspector lists around the selected person.
struct FamilyTreeRelatives: Equatable {
    var parents: [FamilyTreePersonSummary] = []
    var spouses: [FamilyTreePersonSummary] = []
    var children: [FamilyTreePersonSummary] = []
    var siblings: [FamilyTreePersonSummary] = []

    var isEmpty: Bool {
        parents.isEmpty && spouses.isEmpty && children.isEmpty && siblings.isEmpty
    }
}

// MARK: - Model

/// `@MainActor` ≈ "every member runs on the UI thread"; `ObservableObject`
/// + `@Published` ≈ a property-changed signal SwiftUI subscribes to.
@MainActor
final class FamilyTreeLiveModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        /// `live` is false when no .ged was found and the demo tree is shown.
        case loaded(live: Bool)
    }

    // MARK: Published state

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var peopleCount = 0
    @Published private(set) var filteredPeople: [FamilyTreePersonSummary] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedPerson: FamilyTreePersonSummary?
    @Published private(set) var selectedRelatives = FamilyTreeRelatives()
    @Published private(set) var scene: FamilyTreeScene = .empty

    /// Sidebar filter. Setting it refilters once (O(people)) — not in `body`.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { refilter() } }
    }

    var isLive: Bool { graph != nil }

    /// Where photos come from. codex's FamilyAssetStore plugs in here
    /// later; tonight the default says "no photo" for everyone. The
    /// per-card Pick Photo / Apple Photos choice is an in-memory override
    /// that wins over the provider.
    var photoProvider: (GedcomFamilyGraph.Person) -> NSImage?

    /// The directory the loader reads. Production = App Support; tests
    /// inject a temp directory and nothing outside it is ever consulted.
    let originalsDirectory: URL

    // MARK: Private state

    private var graph: GedcomFamilyGraph?
    /// Sorted by surname, then given name, then id (stable).
    private var sortedPeople: [GedcomFamilyGraph.Person] = []
    private var photoOverrides: [String: NSImage] = [:]

    private let ancestorGenerations: Int
    private let descendantGenerations: Int

    // MARK: Init

    // `nonisolated` ≈ "no actor lock needed": pure path math, usable as a
    // default argument before the main-actor instance exists.
    nonisolated static var productionOriginalsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/family-tree/originals")
    }

    init(originalsDirectory: URL = FamilyTreeLiveModel.productionOriginalsDirectory,
         ancestorGenerations: Int = 3,
         descendantGenerations: Int = 2,
         photoProvider: @escaping (GedcomFamilyGraph.Person) -> NSImage? = { _ in nil }) {
        self.originalsDirectory = originalsDirectory
        self.ancestorGenerations = ancestorGenerations
        self.descendantGenerations = descendantGenerations
        self.photoProvider = photoProvider
    }

    // MARK: Loading

    /// Read the newest .ged off the main thread, then install it. Safe to
    /// call more than once (e.g. after the user drops a file in).
    func loadFromDisk() async {
        loadState = .loading
        let directory = originalsDirectory
        // `Task.detached` ≈ spawn on a worker thread; the parse can take a
        // few hundred ms on a large tree and must not block the UI.
        let loaded = await Task.detached(priority: .userInitiated) {
            FamilyGraphFileLoader(originalsDirectory: directory).loadNewest()
        }.value
        install(graph: loaded)
    }

    /// Synchronous variant for tests and for callers that already have
    /// the file in hand.
    func loadNow() {
        loadState = .loading
        install(graph: FamilyGraphFileLoader(originalsDirectory: originalsDirectory).loadNewest())
    }

    /// Install a parsed graph (nil → demo fallback). Keeps the current
    /// selection when the person still exists, else picks the first
    /// sorted person.
    func install(graph newGraph: GedcomFamilyGraph?) {
        graph = newGraph
        if let newGraph {
            sortedPeople = Self.sorted(Array(newGraph.people.values))
            peopleCount = sortedPeople.count
        } else {
            sortedPeople = []
            peopleCount = FamilyTreeDemoData.people.count
        }
        loadState = .loaded(live: newGraph != nil)

        let keep = selectedID.flatMap { id in
            isLive ? (newGraph?.people[id] != nil ? id : nil)
                   : (FamilyTreeDemoData.person(id) != nil ? id : nil)
        }
        selectedID = keep ?? (isLive ? sortedPeople.first?.id : FamilyTreeDemoData.rootID)
        refilter()
        rebuildSelection()
    }

    // MARK: Selection

    func select(_ id: String) {
        guard id != selectedID else { return }
        let exists = isLive ? graph?.people[id] != nil
                            : FamilyTreeDemoData.person(id) != nil
        guard exists else { return }
        selectedID = id
        rebuildSelection()
    }

    /// Hallie / People-tab focus: exact name (case-insensitive) first, then
    /// surname holders (first by sort order). Returns false when nothing
    /// matched so the caller can leave the current selection alone.
    @discardableResult
    func focus(onName raw: String) -> Bool {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }

        if let graph {
            if let exact = sortedPeople.first(where: {
                $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
            }) {
                select(exact.id)
                return true
            }
            if let bySurname = Self.sorted(graph.people(withSurname: wanted)).first {
                select(bySurname.id)
                return true
            }
            return false
        }

        if let demo = FamilyTreeDemoData.people.first(where: {
            $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }) {
            select(demo.id)
            return true
        }
        return false
    }

    // MARK: Photos

    func setPhotoOverride(_ image: NSImage, for personID: String) {
        photoOverrides[personID] = image
        rebuildScene()
    }

    func photo(for personID: String) -> NSImage? {
        if let override = photoOverrides[personID] { return override }
        guard let person = graph?.people[personID] else { return nil }
        return photoProvider(person)
    }

    // MARK: Folder

    /// Create the originals folder if needed and show it in Finder so the
    /// user can drop a GEDCOM in.
    func revealOriginalsFolder() {
        try? FileManager.default.createDirectory(at: originalsDirectory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([originalsDirectory])
    }

    // MARK: Summaries (pure; `nonisolated` so tests and other actors can
    // call them without hopping to the main thread)

    nonisolated static func summary(_ person: GedcomFamilyGraph.Person) -> FamilyTreePersonSummary {
        FamilyTreePersonSummary(
            id: person.id,
            name: person.name.isEmpty ? "(unnamed)" : person.name,
            surname: person.surname,
            years: years(birth: person.birthDate, death: person.deathDate),
            sex: FamilyTreeSex(gedcom: person.sex),
            reference: person.id.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
    }

    /// Life-dates line. Years when both dates carry one ("1929–2008");
    /// otherwise the raw GEDCOM text, prefixed so "b."/"d." is explicit.
    /// Never claims "Living" — absence of a death date is not evidence.
    nonisolated static func years(birth: String?, death: String?) -> String? {
        let birthYear = year(in: birth)
        let deathYear = year(in: death)
        switch (birthYear, deathYear) {
        case let (b?, d?):
            return "\(b)–\(d)"
        case let (b?, nil):
            if let death, !death.isEmpty { return "\(b) – d. \(death)" }
            return "b. \(b)"
        case let (nil, d?):
            if let birth, !birth.isEmpty { return "b. \(birth) – \(d)" }
            return "d. \(d)"
        case (nil, nil):
            let parts = [birth.map { "b. \($0)" }, death.map { "d. \($0)" }]
                .compactMap { $0 }
                .filter { $0.count > 3 }
            return parts.isEmpty ? nil : parts.joined(separator: " – ")
        }
    }

    /// First four-digit run in a raw GEDCOM date ("ABT 1944", "BET 1930
    /// AND 1931" → 1930). Mirrors GedcomFamilyGraph's private helper; the
    /// graph only exposes `birthYear`, and the card needs the death year.
    nonisolated static func year(in raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits) { return year }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return digits.count == 4 ? Int(digits) : nil
    }

    /// Surname, then given name, then id. People with no surname go last.
    nonisolated static func sorted(_ people: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
        people.sorted { lhs, rhs in
            let ls = lhs.surname?.lowercased() ?? "\u{FFFF}"
            let rs = rhs.surname?.lowercased() ?? "\u{FFFF}"
            if ls != rs { return ls < rs }
            let ln = lhs.name.lowercased(), rn = rhs.name.lowercased()
            if ln != rn { return ln < rn }
            return lhs.id < rhs.id
        }
    }

    // MARK: Rebuild

    private func refilter() {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let source: [FamilyTreePersonSummary] = isLive
            ? sortedPeople.map(Self.summary)
            : FamilyTreeDemoData.people
        guard !needle.isEmpty else {
            filteredPeople = source
            return
        }
        filteredPeople = source.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.surname?.localizedCaseInsensitiveContains(needle) ?? false)
                || $0.reference.localizedCaseInsensitiveContains(needle)
        }
    }

    private func rebuildSelection() {
        if let graph, let id = selectedID, let person = graph.people[id] {
            selectedPerson = Self.summary(person)
            selectedRelatives = FamilyTreeRelatives(
                parents: graph.relatives(.parents, of: person).map(Self.summary),
                spouses: graph.relatives(.spouse, of: person).map(Self.summary),
                children: graph.relatives(.children, of: person).map(Self.summary),
                siblings: graph.relatives(.siblings, of: person).map(Self.summary))
        } else if !isLive, let id = selectedID {
            selectedPerson = FamilyTreeDemoData.person(id)
            selectedRelatives = FamilyTreeRelatives()
        } else {
            selectedPerson = nil
            selectedRelatives = FamilyTreeRelatives()
        }
        rebuildScene()
    }

    private func rebuildScene() {
        if let graph, let rootID = selectedID {
            let layout = FamilyTreeLayout.layout(
                graph: graph, rootID: rootID,
                ancestorGenerations: ancestorGenerations,
                descendantGenerations: descendantGenerations)
            scene = FamilyTreeScene(
                cards: layout.nodes.compactMap { node in
                    guard let person = graph.people[node.personID] else { return nil }
                    return FamilyTreeCard(id: node.id,
                                          person: Self.summary(person),
                                          position: node.position,
                                          isRoot: node.isRoot,
                                          photo: photo(for: person.id))
                },
                edges: layout.edges,
                size: layout.size)
        } else if !isLive {
            scene = FamilyTreeDemoData.scene(photos: photoOverrides)
        } else {
            scene = .empty
        }
    }
}

// MARK: - Demo fallback

/// The hard-coded tree the tab shipped with, kept only as the fallback
/// when no GEDCOM exists. Names/dates here are illustrative; the cards
/// carry nothing that pretends to be a measurement.
enum FamilyTreeDemoData {
    static let rootID = "demo-richard"

    struct DemoPerson {
        let summary: FamilyTreePersonSummary
        let position: CGPoint
    }

    private static let entries: [DemoPerson] = [
        demo("demo-george", "George Breen", "Breen", "1898–1995", .male, CGPoint(x: 280, y: 100)),
        demo("demo-muriel", "Muriel Lamb", "Lamb", "1902–1977", .female, CGPoint(x: 450, y: 100)),
        demo("demo-david", "David McGill Latta", "Latta", "1902–1983", .male, CGPoint(x: 760, y: 100)),
        demo("demo-mary", "Mary Catherine O'Connor", "O'Connor", "1904–1985", .female, CGPoint(x: 930, y: 100)),
        demo("demo-richard-sr", "Richard Hardin Breen", "Breen", "1929–2008", .male, CGPoint(x: 405, y: 335)),
        demo("demo-eileen", "Eileen Latta", "Latta", "1930–2023", .female, CGPoint(x: 705, y: 335)),
        demo(rootID, "Richard Breen", "Breen", "b. 1959", .male, CGPoint(x: 560, y: 560)),
        demo("demo-donna", "Donna Hudson", "Hudson", "b. 1959", .female, CGPoint(x: 760, y: 560)),
        demo("demo-next", "Next Generation", nil, nil, .unknown, CGPoint(x: 660, y: 820)),
    ]

    static var people: [FamilyTreePersonSummary] { entries.map(\.summary) }

    static func person(_ id: String) -> FamilyTreePersonSummary? {
        entries.first { $0.summary.id == id }?.summary
    }

    static func scene(photos: [String: NSImage]) -> FamilyTreeScene {
        let cards = entries.map { entry in
            FamilyTreeCard(id: entry.summary.id,
                           person: entry.summary,
                           position: entry.position,
                           isRoot: entry.summary.id == rootID,
                           photo: photos[entry.summary.id])
        }
        return FamilyTreeScene(cards: cards, edges: edges,
                               size: CGSize(width: 1200, height: 920))
    }

    /// Same lines the original demo drew, expressed as layout edges.
    private static let edges: [FamilyTreeLayout.Edge] = [
        spouseEdge(CGPoint(x: 280, y: 100), CGPoint(x: 450, y: 100)),
        spouseEdge(CGPoint(x: 760, y: 100), CGPoint(x: 930, y: 100)),
        spouseEdge(CGPoint(x: 405, y: 335), CGPoint(x: 705, y: 335)),
        spouseEdge(CGPoint(x: 560, y: 560), CGPoint(x: 760, y: 560)),
        .init(kind: .child, from: CGPoint(x: 365, y: 197), to: CGPoint(x: 405, y: 238)),
        .init(kind: .child, from: CGPoint(x: 845, y: 197), to: CGPoint(x: 705, y: 238)),
        .init(kind: .child, from: CGPoint(x: 555, y: 432), to: CGPoint(x: 560, y: 463)),
        .init(kind: .child, from: CGPoint(x: 660, y: 657), to: CGPoint(x: 660, y: 723)),
    ]

    private static func spouseEdge(_ left: CGPoint, _ right: CGPoint) -> FamilyTreeLayout.Edge {
        .init(kind: .spouse,
              from: CGPoint(x: left.x + 75, y: left.y),
              to: CGPoint(x: right.x - 75, y: right.y))
    }

    private static func demo(_ id: String, _ name: String, _ surname: String?,
                             _ years: String?, _ sex: FamilyTreeSex,
                             _ position: CGPoint) -> DemoPerson {
        DemoPerson(summary: FamilyTreePersonSummary(id: id, name: name, surname: surname,
                                                    years: years, sex: sex,
                                                    reference: "demo"),
                   position: position)
    }
}
