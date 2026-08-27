// FamilyTreeLiveModel.swift
// Observable model behind the Family Tree tab (feature/family-tree-gedcom,
// 2026-08-22). Replaces the hard-coded demo people with the real
// GedcomFamilyGraph when a .ged exists in the authorized 40_Family_Tree/GEDCOM
// directory; falls back to the demo tree (with a banner) when none does.
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
    let assetPerson: FamilyAssetPerson?

    init(id: String, person: FamilyTreePersonSummary, position: CGPoint,
         isRoot: Bool, photo: NSImage?, assetPerson: FamilyAssetPerson? = nil) {
        self.id = id
        self.person = person
        self.position = position
        self.isRoot = isRoot
        self.photo = photo
        self.assetPerson = assetPerson
    }
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

/// Someone a "Line to…" can end at: the tree root ("me") and the root's
/// spouse(s). Built once at install; labels are the person's first given
/// name, never a hard-coded "Rick"/"Donna".
struct FamilyTreeAnchor: Identifiable, Equatable {
    let id: String
    let label: String
    /// True for the root: the label reads "your …" instead of "Donna's …".
    let isRoot: Bool
}

/// One "Line to X" button for the selected person: the path when they are
/// an ancestor of the anchor, nil (disabled) when not.
struct FamilyTreeLineOption: Identifiable, Equatable {
    var id: String { anchor.id }
    let anchor: FamilyTreeAnchor
    /// Generations from the selected person down to the anchor (1 =
    /// parent); nil when they are not an ancestor. The path itself is
    /// built only when the chain is shown — it can be thousands long.
    let generations: Int?
    /// "your great-great-grandmother" — nil when `generations` is nil.
    let relation: String?
    var isAvailable: Bool { generations != nil }
}

/// The vertical chain the canvas draws in place of the tree.
struct FamilyTreeLineChain: Equatable {
    struct Card: Identifiable, Equatable {
        var id: String { person.id }
        let person: FamilyTreePersonSummary
        /// Recorded spouse names, as a caption ("⚭ Eileen Latta").
        let spouseNames: [String]
        /// 0 = the ancestor at the top.
        let generation: Int
    }
    let anchor: FamilyTreeAnchor
    let title: String
    let cards: [Card]
    var personIDs: Set<String> { Set(cards.map { $0.person.id }) }
}

// MARK: - Model

/// `@MainActor` ≈ "every member runs on the UI thread"; `ObservableObject`
/// + `@Published` ≈ a property-changed signal SwiftUI subscribes to.
@MainActor
final class FamilyTreeLiveModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case unavailable
        /// `live` is false when no .ged was found and the demo tree is shown.
        case loaded(live: Bool)
    }

    // MARK: Published state

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var peopleCount = 0
    /// The sidebar rows. `didSet` on a `@Published` property ≈ a setter hook
    /// that fires after the value lands — here it keeps `filteredIndexByID`
    /// in step so arrow keys never scan the 16k-row list.
    @Published private(set) var filteredPeople: [FamilyTreePersonSummary] = [] {
        didSet { rebuildFilteredIndex() }
    }
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedPerson: FamilyTreePersonSummary?
    @Published private(set) var selectedRelatives = FamilyTreeRelatives()
    @Published private(set) var scene: FamilyTreeScene = .empty
    @Published private(set) var loadWarning: String?
    /// "Archivist Notes": what the CyberBrain says about the selected
    /// person. Rebuilt on selection change and after a save — never in
    /// `body`.
    @Published private(set) var selectedNotes: [FamilyTreeNote] = []
    /// Why the notes pane is empty when it is (no brain yet / unreadable).
    @Published private(set) var notesStatus: String?
    /// "Said as": one chip per word of the selected person's name, with any
    /// person-level respelling from their CyberBrain record. Rebuilt with
    /// the notes — never in `body`.
    @Published private(set) var selectedPronunciations: [FamilyTreePronunciationChip] = []
    /// "Line to…" targets, built once per install (root + root's spouses).
    @Published private(set) var anchors: [FamilyTreeAnchor] = []
    /// One option per anchor for the selected person; computed on
    /// selection change (cached per person id), never in `body`.
    @Published private(set) var lineOptions: [FamilyTreeLineOption] = []
    /// Non-nil while the canvas shows a chain instead of the tree.
    @Published private(set) var lineChain: FamilyTreeLineChain?

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
    private(set) var originalsDirectory: URL
    private var sourceAccess: FamilyAssetStore.Access
    /// Where cyberbrain.json lives. Production = App Support/VideoScan/
    /// cyberbrain (the directory Hallie reads and telling mode writes);
    /// tests inject a temp directory.
    let cyberBrainRootURL: URL?
    /// Who is writing notes — the owner name from the archivist settings.
    var noteAuthor: String
    /// What the voice says for a word with no person-level entry (file +
    /// shipped layers). A PROVIDER, not a value: it is called in
    /// refreshSelectedNotes() so a file-level telling ("say Latta as
    /// LAH-tuh" for a name several people share) shows on the next
    /// selection instead of the table captured at init (QA 2026-08-26).
    /// Production reads pronunciations.json (tiny) — and, on first use,
    /// writes the shipped default there — lazily, never in init. Tests
    /// inject `{ .shipped }` so no real file is touched.
    private let pronunciationFallback: () -> HalliePronunciationLexicon

    // MARK: Private state

    private var graph: GedcomFamilyGraph?
    /// Sorted by surname, then given name, then id (stable).
    private var sortedPeople: [GedcomFamilyGraph.Person] = []
    private var photoOverrides: [String: NSImage] = [:]
    /// id → row index in `filteredPeople`. Rebuilt only when the filter
    /// changes (O(rows) once), so each ↑/↓ keypress is one dictionary
    /// lookup, not a linear scan.
    private var filteredIndexByID: [String: Int] = [:]
    private var loadGeneration = 0
    private var installedSourceKey: String?
    private var notesResolver: FamilyTreeNotesResolver?
    private var brainIndex: CyberBrainIndex?
    private var notesGeneration = 0
    /// selectedID → line options; cleared at install. Bounded by the number
    /// of people visited this session (a few hundred entries at most).
    private var lineCache: [String: [FamilyTreeLineOption]] = [:]
    /// One upward BFS per anchor, built at install (O(ancestors) once) so a
    /// selection change costs O(path length), not a graph walk.
    private var anchorIndexes: [String: GedcomFamilyGraph.AncestorIndex] = [:]

    private let ancestorGenerations: Int
    private let descendantGenerations: Int

    // MARK: Init

    // `nonisolated` ≈ "no actor lock needed": pure path math, usable as a
    // default argument before the main-actor instance exists.
    nonisolated static var productionOriginalsDirectory: URL {
        FamilyAssetConfigurationCenter.shared.snapshot().gedcomDirectory()
    }

    init(originalsDirectory: URL? = nil,
         cyberBrainRootURL: URL? = nil,
         noteAuthor: String? = nil,
         pronunciationFallback: (() -> HalliePronunciationLexicon)? = nil,
         ancestorGenerations: Int = 3,
         descendantGenerations: Int = 2,
         photoProvider: @escaping (GedcomFamilyGraph.Person) -> NSImage? = { _ in nil }) {
        let production = FamilyAssetConfigurationCenter.shared.snapshot()
        // A test that injects an originals directory but no brain gets NO
        // brain, never the real one (isolation rule).
        self.cyberBrainRootURL = cyberBrainRootURL
            ?? (originalsDirectory == nil ? FamilyTreeNotesStorage.productionRootURL : nil)
        self.noteAuthor = noteAuthor
            ?? HallieTurnExecutor.Speakers.fromDefaults().ownerName
            ?? HallieTurnExecutor.Speakers.defaultOwnerName
        self.pronunciationFallback = pronunciationFallback
            ?? (originalsDirectory == nil
                ? { HalliePronunciationLexicon.merged([.load(), .shipped]) }
                : { .shipped })
        self.originalsDirectory = originalsDirectory
            ?? production.gedcomDirectory()
        self.sourceAccess = originalsDirectory == nil ? production.access : .readWrite
        self.ancestorGenerations = ancestorGenerations
        self.descendantGenerations = descendantGenerations
        self.photoProvider = photoProvider
    }

    // MARK: Loading

    /// Read the newest .ged off the main thread, then install it. Safe to
    /// call more than once (e.g. after the user drops a file in).
    func loadFromDisk() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        guard sourceAccess != .unavailable else {
            installUnavailable()
            return
        }
        loadState = .loading
        let directory = originalsDirectory
        // `Task.detached` ≈ spawn on a worker thread; the parse can take a
        // few hundred ms on a large tree and must not block the UI.
        let loaded = await Task.detached(priority: .userInitiated) {
            FamilyGraphFileLoader(originalsDirectory: directory).loadNewestOutcome()
        }.value
        guard generation == loadGeneration else { return }
        install(outcome: loaded)
    }

    /// Synchronous variant for tests and for callers that already have
    /// the file in hand.
    func loadNow() {
        loadGeneration &+= 1
        guard sourceAccess != .unavailable else {
            installUnavailable()
            return
        }
        loadState = .loading
        install(outcome: FamilyGraphFileLoader(
            originalsDirectory: originalsDirectory).loadNewestOutcome())
    }

    /// Install a parsed graph (nil → demo fallback). Keeps the current
    /// selection when the person still exists, else picks the first
    /// sorted person.
    func install(graph newGraph: GedcomFamilyGraph?) {
        loadWarning = nil
        let previousPerson = selectedID.flatMap { graph?.people[$0] }
        let sourceKey = newGraph.map(Self.sourceKey)
        if sourceKey != installedSourceKey {
            photoOverrides.removeAll()
            installedSourceKey = sourceKey
        }
        graph = newGraph
        // Group-photo attribution follows the tree (2026-08-26): rebuilt
        // here from tree + speaker settings; a Hallie turn later enriches
        // it with CyberBrain / People-tab aliases.
        FamilyAssetConfigurationCenter.shared.publishIdentity(newGraph.map {
            FamilyAssetIdentityDirectory(graph: $0, speakers: .fromDefaults())
        })
        if let newGraph {
            sortedPeople = Self.sorted(Array(newGraph.people.values))
            peopleCount = sortedPeople.count
            anchors = Self.anchors(
                in: newGraph,
                ownerFamilySearchID: UserDefaults.standard.string(
                    forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey))
            anchorIndexes = Dictionary(uniqueKeysWithValues: anchors.map {
                ($0.id, GedcomFamilyGraph.AncestorIndex(graph: newGraph, descendantID: $0.id))
            })
        } else {
            sortedPeople = []
            peopleCount = FamilyTreeDemoData.people.count
            anchors = []
            anchorIndexes = [:]
        }
        loadState = .loaded(live: newGraph != nil)
        lineCache.removeAll()
        lineChain = nil

        let keep = selectedID.flatMap { id -> String? in
            guard isLive else {
                return FamilyTreeDemoData.person(id) != nil ? id : nil
            }
            guard let candidate = newGraph?.people[id] else { return nil }
            guard let previousPerson else { return id }
            return Self.sameIdentity(previousPerson, candidate) ? id : nil
        }
        selectedID = keep ?? (isLive ? sortedPeople.first?.id : FamilyTreeDemoData.rootID)
        refilter()
        scheduleNotesResolverRebuild()
        rebuildSelection()
    }

    private func install(outcome: FamilyGraphFileLoader.Outcome) {
        install(graph: outcome.graph)
        if let rejected = outcome.rejectedURLs.first {
            if let selected = outcome.selectedURL {
                loadWarning = "Could not read \(rejected.lastPathComponent); using \(selected.lastPathComponent)."
            } else {
                loadWarning = "Could not read \(rejected.lastPathComponent) as a non-empty GEDCOM file."
            }
        }
    }

    func configure(source: FamilyAssetConfiguration) {
        originalsDirectory = source.gedcomDirectory()
        sourceAccess = source.access
    }

    private func installUnavailable() {
        loadGeneration &+= 1
        graph = nil
        sortedPeople = []
        peopleCount = 0
        filteredPeople = []
        selectedID = nil
        selectedPerson = nil
        selectedRelatives = FamilyTreeRelatives()
        scene = .empty
        loadWarning = nil
        loadState = .unavailable
        notesResolver = nil
        selectedNotes = []
        anchors = []
        lineOptions = []
        lineChain = nil
        lineCache.removeAll()
        anchorIndexes = [:]
    }

    nonisolated private static func sourceKey(_ graph: GedcomFamilyGraph) -> String {
        [graph.sourceDirectory ?? "", graph.sourceFileName ?? "",
         graph.sourceModifiedAt.map { String($0.timeIntervalSince1970) } ?? ""]
            .joined(separator: "|")
    }

    nonisolated private static func sameIdentity(
        _ lhs: GedcomFamilyGraph.Person,
        _ rhs: GedcomFamilyGraph.Person
    ) -> Bool {
        lhs.name.compare(rhs.name, options: [
            .caseInsensitive, .diacriticInsensitive,
        ]) == .orderedSame
            && lhs.birthDate == rhs.birthDate
            && lhs.deathDate == rhs.deathDate
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

    /// Hallie / People-tab focus: exact preferred name first, then one
    /// unambiguous preferred/alternate name or FamilySearch ID, then surname
    /// holders (first by sort order). Returns false when nothing matched so
    /// the caller can leave the current selection alone.
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
            let identityMatches = graph.people(matching: wanted)
            if identityMatches.count == 1, let identity = identityMatches.first {
                select(identity.id)
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

    func focus(onID id: String) -> Bool {
        guard graph?.people[id] != nil else { return false }
        select(id)
        return true
    }

    // MARK: Keyboard navigation (sidebar ↑ / ↓ / Return)

    /// Row index of the current selection within `filteredPeople`, or nil
    /// when the selected person is filtered out (or nothing is selected).
    var selectedFilteredIndex: Int? {
        selectedID.flatMap { filteredIndexByID[$0] }
    }

    /// ↓: move to the next row. No wrap; at the bottom this is a no-op.
    /// When the selection is not in the list (filter changed underneath it)
    /// the first row is selected so the keys always do something visible.
    func selectNext() { step(by: 1) }

    /// ↑: move to the previous row. No wrap; at the top this is a no-op.
    func selectPrevious() { step(by: -1) }

    /// Return in the search field: select the first match. Returns false
    /// when the list is empty so the caller can leave the selection alone.
    @discardableResult
    func selectFirstFiltered() -> Bool {
        guard let first = filteredPeople.first else { return false }
        select(first.id)
        return true
    }

    private func step(by delta: Int) {
        guard !filteredPeople.isEmpty else { return }
        guard let index = selectedFilteredIndex else {
            select(filteredPeople[0].id)
            return
        }
        let target = index + delta
        guard filteredPeople.indices.contains(target) else { return }
        select(filteredPeople[target].id)
    }

    private func rebuildFilteredIndex() {
        var map: [String: Int] = [:]
        map.reserveCapacity(filteredPeople.count)
        for (index, person) in filteredPeople.enumerated() { map[person.id] = index }
        filteredIndexByID = map
    }

    // MARK: Line to… (direct descent chain)

    /// "Me" first, then each recorded spouse. "Me" is the person carrying
    /// the configured FamilySearch ID (`hallie.ownerFamilySearchID`) when
    /// the tree has it, else the tree root. A root with two marriages
    /// yields two anchors — that IS the picker.
    nonisolated static func anchors(in graph: GedcomFamilyGraph,
                                    ownerFamilySearchID: String? = nil) -> [FamilyTreeAnchor] {
        guard let root = graph.person(familySearchID: ownerFamilySearchID) ?? graph.rootPerson else { return [] }
        var out = [FamilyTreeAnchor(id: root.id, label: firstGivenName(root), isRoot: true)]
        var seen: Set<String> = [root.id]
        for spouse in graph.relatives(.spouse, of: root) where seen.insert(spouse.id).inserted {
            out.append(FamilyTreeAnchor(id: spouse.id, label: firstGivenName(spouse), isRoot: false))
        }
        return out
    }

    /// "Richard Harding Breen Jr" → "Richard"; a lone surname or empty
    /// name falls back to the whole (or "(unnamed)").
    nonisolated static func firstGivenName(_ person: GedcomFamilyGraph.Person) -> String {
        let tokens = person.name.split(separator: " ").map(String.init)
        if let surname = person.surname,
           let first = tokens.first(where: { $0.caseInsensitiveCompare(surname) != .orderedSame }) {
            return first
        }
        return tokens.first ?? "(unnamed)"
    }

    /// Show the chain from the selected person down to `anchorID`.
    func showLine(to anchorID: String) {
        guard let graph, let id = selectedID,
              let option = lineOptions.first(where: { $0.anchor.id == anchorID }),
              option.isAvailable, let relation = option.relation,
              let path = anchorIndexes[anchorID]?.path(from: id),
              let ancestor = path.first else { return }
        let cards = path.enumerated().map { index, person -> FamilyTreeLineChain.Card in
            let spouses = graph.relatives(.spouse, of: person)
            return FamilyTreeLineChain.Card(
                person: Self.summary(person),
                spouseNames: spouses.map { $0.name.isEmpty ? "(unnamed)" : $0.name },
                generation: index)
        }
        let generations = path.count - 1
        lineChain = FamilyTreeLineChain(
            anchor: option.anchor,
            title: "\(ancestor.name) → \(option.anchor.label): \(relation) (\(generations) generation\(generations == 1 ? "" : "s"))",
            cards: cards)
    }

    func showFullTree() {
        lineChain = nil
    }

    private func refreshLineOptions() {
        guard graph != nil, let id = selectedID, isLive, !anchors.isEmpty else {
            lineOptions = []
            lineChain = nil
            return
        }
        if let cached = lineCache[id] {
            lineOptions = cached
        } else {
            let options = anchors.map { anchor -> FamilyTreeLineOption in
                let generations = anchorIndexes[anchor.id]?.generations(from: id)
                let relation = generations.map { n -> String in
                    let possessive = anchor.isRoot ? "your" : anchor.label + "'s"
                    return possessive + " " + GedcomFamilyGraph.generationLabel(
                        generations: n, sex: graph?.people[id]?.sex ?? "")
                }
                return FamilyTreeLineOption(anchor: anchor, generations: generations, relation: relation)
            }
            lineCache[id] = options
            lineOptions = options
        }
        // Selecting a card IN the chain keeps the chain; selecting anyone
        // else (sidebar, relatives) returns to the tree.
        if let chain = lineChain, !chain.personIDs.contains(id) {
            lineChain = nil
        }
    }

    // MARK: Archivist Notes (CyberBrain)

    /// Read cyberbrain.json off the main thread and build the tree→brain
    /// resolver. Safe to call again (after Hallie learns something).
    func loadCyberBrain() async {
        guard let root = cyberBrainRootURL else {
            applyBrain(index: nil, status: "No family knowledge file is configured.")
            return
        }
        notesGeneration &+= 1
        let generation = notesGeneration
        let outcome: Result<CyberBrainIndex?, Error> = await Task.detached(priority: .userInitiated) {
            Result { try FamilyTreeNotesStorage.loadIndex(rootURL: root) }
        }.value
        guard generation == notesGeneration else { return }
        switch outcome {
        case .success(let index):
            applyBrain(index: index, status: index == nil
                ? "Hallie has not been told anything yet. Add a note below, or tell her in the chat window." : nil)
        case .failure(let error):
            applyBrain(index: nil, status: "Family knowledge file could not be read: \(error.localizedDescription)")
        }
    }

    /// Synchronous variant for tests.
    func loadCyberBrainNow() {
        notesGeneration &+= 1
        guard let root = cyberBrainRootURL else {
            applyBrain(index: nil, status: "No family knowledge file is configured.")
            return
        }
        do {
            let index = try FamilyTreeNotesStorage.loadIndex(rootURL: root)
            applyBrain(index: index, status: index == nil
                ? "Hallie has not been told anything yet. Add a note below, or tell her in the chat window." : nil)
        } catch {
            applyBrain(index: nil, status: "Family knowledge file could not be read: \(error.localizedDescription)")
        }
    }

    /// Save one note about the selected person through the same writer
    /// Hallie's telling mode uses (atomic rename + backups/), then refresh
    /// the pane from the archive the writer handed back — no re-read.
    /// Throws the writer's error so the view can show it verbatim.
    func addNote(_ text: String, kind: CyberBrainItem.Kind = .note, date: Date = Date()) throws {
        guard let root = cyberBrainRootURL else {
            throw CyberBrainWriter.WriteError.unsafeRoot("no CyberBrain directory configured")
        }
        guard let graph, let id = selectedID, let person = graph.people[id] else {
            throw CyberBrainWriter.WriteError.emptySubject
        }
        let testimony = CyberBrainWriter.Testimony(
            subjectName: person.name,
            subjectAliases: person.alternateNames,
            speakerName: noteAuthor,
            text: text,
            kind: kind,
            date: date,
            origin: .familyTreeNote,
            gedcomPersonID: person.id)
        let receipt = try CyberBrainWriter.record(testimony, rootURL: root)
        notesGeneration &+= 1
        applyBrain(index: try CyberBrainIndex(archive: receipt.archive), status: nil)
    }

    private func applyBrain(index: CyberBrainIndex?, status: String?) {
        brainIndex = index
        notesStatus = status
        notesResolver = nil
        if let index, let graph {
            notesResolver = FamilyTreeNotesResolver(index: index, graph: graph)
        }
        refreshSelectedNotes()
    }

    /// The graph changed under an already-loaded brain: rebuild the
    /// resolver off the main thread (NameIndex over 16k people is tens of
    /// ms — not worth a hitch on every reload).
    private func scheduleNotesResolverRebuild() {
        notesResolver = nil
        guard let index = brainIndex, let graph else {
            refreshSelectedNotes()
            return
        }
        notesGeneration &+= 1
        let generation = notesGeneration
        Task { [weak self] in
            let resolver = await Task.detached(priority: .userInitiated) {
                FamilyTreeNotesResolver(index: index, graph: graph)
            }.value
            guard let self, generation == self.notesGeneration else { return }
            self.notesResolver = resolver
            self.refreshSelectedNotes()
        }
    }

    private func refreshSelectedNotes() {
        guard let id = selectedID, isLive, let person = graph?.people[id] else {
            if !selectedNotes.isEmpty { selectedNotes = [] }
            if !selectedPronunciations.isEmpty { selectedPronunciations = [] }
            return
        }
        // Chips need only the name; the brain adds the person-level entries.
        selectedPronunciations = FamilyTreePronunciationChips.make(
            name: person.name,
            people: notesResolver?.cyberBrainPeople(forGedcomID: id) ?? [],
            fallback: pronunciationFallback())
        guard let resolver = notesResolver else {
            if !selectedNotes.isEmpty { selectedNotes = [] }
            return
        }
        selectedNotes = resolver.notes(forGedcomID: id)
    }

    /// "Said as" for one word of the selected person's name, kept on their
    /// CyberBrain record (minted with the GEDCOM pointer if Hallie has no
    /// record for them yet). Empty/nil `saidAs` removes the entry. Same
    /// atomic writer as notes; the voice cache is dropped so the next
    /// utterance uses it.
    func setPronunciation(word: String, saidAs: String?) throws {
        guard let root = cyberBrainRootURL else {
            throw CyberBrainWriter.WriteError.unsafeRoot("no CyberBrain directory configured")
        }
        guard let graph, let id = selectedID, let person = graph.people[id] else {
            throw CyberBrainWriter.WriteError.emptySubject
        }
        let receipt = try CyberBrainWriter.setPronunciation(
            subjectName: person.name,
            gedcomPersonID: person.id,
            aliases: person.alternateNames,
            token: word,
            saidAs: saidAs,
            rootURL: root)
        PersonPronunciationCache.shared.invalidate()
        notesGeneration &+= 1
        applyBrain(index: try CyberBrainIndex(archive: receipt.archive), status: nil)
    }

    /// Store key for the selected person (folder lookup for photos).
    func assetPerson(for personID: String) -> FamilyAssetPerson? {
        graph?.people[personID].map(FamilyAssetPerson.init)
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
        let store = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        guard let folder = try? store.ensureGEDCOMDirectory(),
              folder == originalsDirectory.standardizedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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
        guard !needle.isEmpty else {
            filteredPeople = isLive
                ? sortedPeople.map(Self.summary)
                : FamilyTreeDemoData.people
            return
        }
        if isLive {
            filteredPeople = sortedPeople.filter { person in
                person.name.localizedCaseInsensitiveContains(needle)
                    || person.alternateNames.contains {
                        $0.localizedCaseInsensitiveContains(needle)
                    }
                    || (person.surname?.localizedCaseInsensitiveContains(needle) ?? false)
                    || person.alternateSurnames.contains {
                        $0.localizedCaseInsensitiveContains(needle)
                    }
                    || person.id.localizedCaseInsensitiveContains(needle)
                    || (person.familySearchID?.localizedCaseInsensitiveContains(needle) ?? false)
            }.map(Self.summary)
            return
        }
        filteredPeople = FamilyTreeDemoData.people.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.surname?.localizedCaseInsensitiveContains(needle) ?? false)
                || $0.reference.localizedCaseInsensitiveContains(needle)
        }
    }

    private func rebuildSelection() {
        defer { refreshSelectedNotes() }
        defer { refreshLineOptions() }
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
                                          photo: photo(for: person.id),
                                          assetPerson: FamilyAssetPerson(person))
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
