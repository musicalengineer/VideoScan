// FamilyTreeWalkHighlight.swift
// The Walk Tree fan's HIGHLIGHT panel (Donna 2026-09-29, after her first
// demo: "last names and/or places, as checkmarks"). Check a surname or a
// place and the fan dims everyone else and lights up the matches; a list
// under the checks names them. The rule (OR within a group, AND across)
// and the counting live in VideoScanCore (`TreeWalkHighlight`, tested
// there); this file is the state behind the checkboxes and the view.
//
// Why a highlight and not a filter: the fan keeps its shape (the families
// still fan out from Rick on the left and Donna on the right), so a match
// is seen WHERE it sits in the tree — "the McGills are all on Donna's side,
// eight generations back" is the story, and a filter would erase it.
//
// COST (no O(people) work in a view body): the inputs (surnames, regions,
// birth years per visited person) are built once, off-main, when the walk
// finishes. A change of checks recomputes the mask off-main (~1 ms at 39k)
// and publishes the lit dots and the first `listCap` names; a newer change
// supersedes an older one still in flight (a generation counter — the last
// click wins).
//
// (For Rick: `@Published` ≈ a property with change notification; the view
// observes this object the way a Qt widget connects to a signal.)

import Combine
import SwiftUI
import VideoScanCore

@MainActor
final class TreeWalkHighlighter: ObservableObject {

    struct Match: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let birthYear: Int?
        let generation: Int
    }

    /// Everything the matching reads, parallel to `layout.placed`.
    struct Inputs: Sendable {
        let placed: [TreeWalkFanLayout.Placed]
        /// Ordinals of the placed people (the walk's `ids` indices).
        let visited: [Int]
        let ids: [String]
        let names: [String]
        let surnameKeys: [String]
        let regions: [BirthplaceClassifier.BirthRegion]
        let birthYears: [Int?]
        let facets: TreeWalkHighlight.Facets
    }

    /// How many surnames the checklist shows before a search narrows it.
    static let surnamesShown = 25
    /// How many matching names the list holds (the count is always exact).
    static let listCap = 200

    let inputs: Inputs
    @Published private(set) var selection = TreeWalkHighlight.Selection()
    @Published private(set) var lit: [TreeWalkFanLayout.Placed] = []
    @Published private(set) var matches: [Match] = []
    @Published private(set) var matchCount = 0
    @Published private(set) var visibleSurnames: [TreeWalkHighlight.Facet] = []
    @Published var surnameQuery = "" { didSet { refreshSurnameList() } }
    private var generation = 0

    init(inputs: Inputs) {
        self.inputs = inputs
        refreshSurnameList()
    }

    /// Build the inputs OFF the main actor from the finished walk.
    nonisolated static func prepare(result: TreeWalk.Result, graph: GedcomFamilyGraph,
                                    layout: TreeWalkFanLayout) async -> Inputs {
        await Task.detached(priority: .userInitiated) {
            let surnames = result.ids.map { graph.people[$0]?.surname ?? "" }
            let regions = result.decorations.map(\.birthRegion)
            let years = result.decorations.map(\.birthYear)
            let visited = layout.placed.map { Int($0.ordinal) }
            let facets = TreeWalkHighlight.facets(visited: visited, surnames: surnames, regions: regions,
                                                  surnameLimit: Int.max)
            return Inputs(placed: layout.placed, visited: visited, ids: result.ids, names: result.names,
                          surnameKeys: TreeWalkHighlight.surnameKeys(surnames), regions: regions,
                          birthYears: years, facets: facets)
        }.value
    }

    func isOn(surname key: String) -> Bool { selection.surnames.contains(key) }
    func isOn(region key: String) -> Bool { selection.regions.contains(key) }

    func setSurname(_ key: String, on: Bool) {
        if on { selection.surnames.insert(key) } else { selection.surnames.remove(key) }
        recompute()
    }

    func setRegion(_ key: String, on: Bool) {
        if on { selection.regions.insert(key) } else { selection.regions.remove(key) }
        recompute()
    }

    func clear() {
        selection = .init()
        surnameQuery = ""
        recompute()
    }

    /// The top surnames, or those containing the typed text — plus any
    /// already checked, so a check never scrolls out of reach.
    private func refreshSurnameList() {
        let all = inputs.facets.surnames
        let q = TreeWalkHighlight.surnameKey(surnameQuery)
        var shown = q.isEmpty ? Array(all.prefix(Self.surnamesShown))
                              : Array(all.lazy.filter { $0.key.contains(q) }.prefix(Self.surnamesShown))
        let shownKeys = Set(shown.map(\.key))
        shown += all.filter { selection.surnames.contains($0.key) && !shownKeys.contains($0.key) }
        visibleSurnames = shown
    }

    private func recompute() {
        generation += 1
        let mine = generation, selection = selection, inputs = inputs
        refreshSurnameList()
        Task { [weak self] in
            let (lit, list, count) = await Task.detached(priority: .userInitiated) {
                () -> ([TreeWalkFanLayout.Placed], [Match], Int) in
                let mask = TreeWalkHighlight.mask(visited: inputs.visited, selection: selection,
                                                  surnameKeys: inputs.surnameKeys, regions: inputs.regions)
                var lit: [TreeWalkFanLayout.Placed] = []
                var list: [Match] = []
                for (i, on) in mask.enumerated() where on {
                    let p = inputs.placed[i]
                    lit.append(p)
                    if list.count < Self.listCap {
                        let o = inputs.visited[i]
                        list.append(Match(id: inputs.ids[o],
                                          name: inputs.names[o].isEmpty ? inputs.ids[o] : inputs.names[o],
                                          birthYear: inputs.birthYears[o], generation: p.generation))
                    }
                }
                return (lit, list, lit.count)
            }.value
            guard let self, self.generation == mine else { return }   // a newer click won
            self.lit = lit
            self.matches = list
            self.matchCount = count
        }
    }
}

/// The checklists and the match list (the side panel, once the replay ends).
struct TreeWalkHighlightPanel: View {
    @ObservedObject var highlighter: TreeWalkHighlighter
    /// The Family Map (GH #227) from the places heading; nil hides the link.
    var onShowMap: (() -> Void)? = nil

    var body: some View {
        let h = highlighter
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Highlight").font(.headline)
                Spacer()
                if !h.selection.isEmpty {
                    Button("Clear") { h.clear() }.controlSize(.small)
                }
            }
            Text(h.selection.isEmpty
                 ? "Check places or surnames to pick those people out on the fan."
                 : "\(h.matchCount.formatted()) \(h.matchCount == 1 ? "person matches" : "people match") — lit on the fan, the rest dimmed.")
                .font(.system(size: 12)).foregroundStyle(h.selection.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                Text("Where they were born").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                if let onShowMap {
                    Button("Show on map") { onShowMap() }.controlSize(.mini)
                }
            }
            .padding(.top, 4)
            ForEach(h.inputs.facets.regions) { f in
                checkbox(f, isOn: h.isOn(region: f.key)) { h.setRegion(f.key, on: $0) }
            }

            Text("Surnames").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            TextField("Find a surname", text: $highlighter.surnameQuery)
                .textFieldStyle(.roundedBorder).controlSize(.small)
            ForEach(h.visibleSurnames) { f in
                checkbox(f, isOn: h.isOn(surname: f.key)) { h.setSurname(f.key, on: $0) }
            }
            if h.surnameQuery.isEmpty && h.inputs.facets.distinctSurnames > TreeWalkHighlighter.surnamesShown {
                Text("The \(TreeWalkHighlighter.surnamesShown) most common of \(h.inputs.facets.distinctSurnames.formatted()) — type to find others.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if !h.matches.isEmpty {
                Divider().padding(.vertical, 4)
                Text(h.matchCount > h.matches.count
                     ? "The nearest \(h.matches.count) of \(h.matchCount.formatted())"
                     : "Who they are")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(h.matches) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.name).font(.system(size: 12))
                        Spacer(minLength: 6)
                        Text(m.birthYear.map { "b. \($0)" } ?? "").font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("gen \(m.generation)").font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func checkbox(_ f: TreeWalkHighlight.Facet, isOn: Bool,
                          set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            HStack {
                Text(f.label).font(.system(size: 12))
                Spacer(minLength: 6)
                Text(f.count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}
