// FamilyMapModel.swift
// The state behind the Family Map (GH #227 stage 2, design §4): when the
// Walk Tree replay has finished, "Show on map" shades the historic counties
// / states / provinces by how many of the walked ancestors were born there,
// and a click on a region names them.
//
// WHAT IS BUILT, AND WHEN (no O(people) work in any SwiftUI body):
//   • ONCE PER WALK, off the main actor (`prepare`): every visited person's
//     recorded birthplace goes through `BirthplaceUnitResolver` exactly
//     once, and the result is packed with the walk's other per-person
//     columns into `FamilyMapTally.People` (which interns the keys). ~2 µs
//     per place; 40k people well under 300 ms in Debug (FamilyMapModelTests).
//   • ONCE PER PROCESS (`FamilyMapUnitsCache`): the bundled border file is
//     decoded. It is ~1.3 MB of JSON → ~1 MB of coordinates resident, and
//     nothing grows after that. Tests hand the model synthetic units and
//     never touch the bundle.
//   • PER CHANGE OF CHECKS (`apply`): the Highlight selection becomes a
//     mask and `FamilyMapTally.counts` runs off-main (~10 ms at 40k). A
//     generation counter makes the last change win when two overlap — the
//     same pattern as `TreeWalkHighlighter.recompute`.
//
// THE MASK. `TreeWalkHighlight.mask` returns ALL-FALSE for an empty
// selection ("no highlight" on the fan). Handed to the tally, all-false
// would honestly count nobody, so an empty selection is passed as nil —
// everyone on the fan is counted — and a mask is built only when at least
// one box is checked.
//
// NO DOUBLE COUNTING. A person resolved to a county ("Yorkshire, England")
// is counted in eng-yorkshire and NOT in eng; the country outline's count
// is only the people whose record names the country and nothing finer
// ("England"). So a map that shades Yorkshire 661 and England 1,200 says
// "1,200 more Englishmen, county unknown" — and the totals line spells it
// out ("K country-only"). The tally already keys each person to exactly one
// unit; this file never adds a person to a second one.
//
// (For Rick: `@MainActor final class … ObservableObject` ≈ a UI-thread
// model with change notification; `Task.detached` ≈ std::async on a
// worker; the `generation` counter is the usual "ignore a stale reply"
// sequence number.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore

// MARK: - The bundled border file, once per process

/// Loads and caches the bundled `family-map-units.geojson`. An `actor` ≈ a
/// class with an implicit mutex around all of its members, so two sheets
/// asking at once decode the file once.
actor FamilyMapUnitsCache {
    static let shared = FamilyMapUnitsCache()

    private var loaded: FamilyMapUnits?

    enum LoadError: Error, CustomStringConvertible {
        case missingResource
        var description: String { "family-map-units.geojson is not in the app bundle" }
    }

    /// The bundled file's URL, or nil when the app was built without it.
    nonisolated static var bundledURL: URL? {
        Bundle.main.url(forResource: "family-map-units", withExtension: "geojson")
    }

    func units() throws -> FamilyMapUnits {
        if let loaded { return loaded }
        guard let url = Self.bundledURL else { throw LoadError.missingResource }
        let data = try Data(contentsOf: url)
        let units = try FamilyMapUnits(geoJSON: data)
        loaded = units
        return units
    }
}

// MARK: - The model

@MainActor
final class FamilyMapModel: ObservableObject {

    /// Everything a recompute reads, built once per walk off-main.
    struct Inputs: Sendable {
        let people: FamilyMapTally.People
        /// Ordinals of the people on the fan — the tally's `visited`.
        let visited: [Int]
        /// Parallel to `people.ids` (the Highlight's folded keys / regions).
        let surnameKeys: [String]
        let regions: [BirthplaceClassifier.BirthRegion]
    }

    /// How one unit is painted: the dominant line's colour at an opacity
    /// that grows with log(count).
    struct Shade: Sendable, Equatable {
        let key: String
        let line: TreeWalk.Line
        let opacity: Double
    }

    /// A name-and-count label for one of the busiest units.
    struct Label: Identifiable, Sendable, Equatable {
        let key: String
        let name: String
        let count: Int
        let latitude: Double
        let longitude: Double
        var id: String { key }
    }

    /// What one recompute produces, published together so the map never
    /// shows counts from one selection with labels from another.
    struct Computed: Sendable, Equatable {
        var counts: [String: FamilyMapTally.UnitCount] = [:]
        var totals = FamilyMapTally.Result.empty.totals
        var shades: [String: Shade] = [:]
        var labels: [Label] = []
        var cameraBox: FamilyMap.BoundingBox?
    }

    /// Fill opacity range for a shaded unit (design §4: 0.35…0.85).
    /// `nonisolated`: plain constants, read from the off-main recompute.
    nonisolated static let minimumOpacity = 0.35
    nonisolated static let maximumOpacity = 0.85
    /// How many units get a name-and-count label.
    nonisolated static let labelLimit = 12

    let inputs: Inputs
    let units: FamilyMapUnits
    let displayNames: [String]

    @Published private(set) var computed = Computed()
    @Published private(set) var selection = TreeWalkHighlight.Selection()
    @Published private(set) var yearCeiling: Int?
    @Published private(set) var selectedKey: String?
    /// The last tally problem, if any (a mask length mismatch would be a
    /// programming error; it is shown, never swallowed).
    @Published private(set) var problem: String?
    private var generation = 0
    private var highlightSubscription: AnyCancellable?

    init(inputs: Inputs, units: FamilyMapUnits, displayNames: [String]) {
        self.inputs = inputs
        self.units = units
        self.displayNames = displayNames
    }

    // MARK: Building the inputs (once per walk, off-main)

    /// The columns for `inputs(…)`, gathered from the walk and the graph
    /// OFF the main actor. `highlight` is the Highlight panel's inputs for
    /// the same walk (its visited ordinals, folded surnames and regions are
    /// reused, not recomputed).
    nonisolated static func prepare(result: TreeWalk.Result, graph: GedcomFamilyGraph,
                                    highlight: TreeWalkHighlighter.Inputs) async -> Inputs {
        await Task.detached(priority: .userInitiated) {
            let n = result.ids.count
            var generations = [Int?](repeating: nil, count: n)
            for p in highlight.placed {
                let o = Int(p.ordinal)
                if o >= 0, o < n { generations[o] = p.generation }
            }
            var surnames = [String](repeating: "", count: n)
            var places = [String?](repeating: nil, count: n)
            for o in highlight.visited where o >= 0 && o < n {
                let person = graph.people[result.ids[o]]
                surnames[o] = person?.surname ?? ""
                places[o] = person?.birthPlace
            }
            return inputs(ids: result.ids, names: result.names, surnames: surnames,
                          surnameKeys: highlight.surnameKeys, birthPlaces: places,
                          birthYears: highlight.birthYears, generations: generations,
                          lines: result.decorations.map(\.line), visited: highlight.visited,
                          regions: highlight.regions)
        }.value
    }

    /// The pure form: resolves every VISITED birthplace once and packs the
    /// columns. Columns are parallel to `ids`; `visited` lists ordinals.
    /// Synchronous and actor-free so a scale test can time it directly.
    nonisolated static func inputs(ids: [String], names: [String], surnames: [String], surnameKeys: [String],
                                   birthPlaces: [String?], birthYears: [Int?], generations: [Int?],
                                   lines: [TreeWalk.Line], visited: [Int],
                                   regions: [BirthplaceClassifier.BirthRegion]) -> Inputs {
        var unitKeys = [String?](repeating: nil, count: ids.count)
        for o in visited where o >= 0 && o < birthPlaces.count {
            unitKeys[o] = BirthplaceUnitResolver.resolve(birthPlaces[o])?.unitKey
        }
        let people = FamilyMapTally.People(ids: ids, names: names, surnames: surnames, surnameKeys: surnameKeys,
                                           birthYears: birthYears, generations: generations, lines: lines,
                                           unitKeys: unitKeys)
        return Inputs(people: people, visited: visited, surnameKeys: surnameKeys, regions: regions)
    }

    // MARK: Following the Highlight checks

    /// Mirror the Highlight panel's checks: the map filters exactly as the
    /// fan highlights. Subscribed once; the model recomputes even while the
    /// fan is showing, so a return to the map is already current.
    func bind(to highlighter: TreeWalkHighlighter) {
        highlightSubscription = highlighter.$selection
            .removeDuplicates()
            .sink { [weak self] selection in
                guard let self else { return }
                self.apply(selection: selection, yearCeiling: self.yearCeiling)
            }
    }

    /// Recompute the counts for a selection (nil mask when empty) and an
    /// optional births-≤-year ceiling. Off-main; the last call wins.
    func apply(selection: TreeWalkHighlight.Selection, yearCeiling: Int?) {
        self.selection = selection
        self.yearCeiling = yearCeiling
        generation += 1
        let mine = generation, inputs = inputs, units = units
        Task { [weak self] in
            // (Computed, nil) on success; (nil, message) on a tally error —
            // a plain tuple, because `any Error` is not Sendable across the
            // detached task.
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Computed?, String?) in
                // An empty selection is "everyone", never an all-false mask.
                let mask: [Bool]? = selection.isEmpty ? nil
                    : TreeWalkHighlight.mask(visited: inputs.visited, selection: selection,
                                             surnameKeys: inputs.surnameKeys, regions: inputs.regions)
                do {
                    let r = try FamilyMapTally.counts(people: inputs.people, visited: inputs.visited,
                                                      mask: mask, yearCeiling: yearCeiling)
                    return (Self.computed(from: r, units: units), nil)
                } catch {
                    return (nil, "\(error)")
                }
            }.value
            guard let self, self.generation == mine else { return }   // a newer change won
            if let c = outcome.0 {
                self.computed = c
                self.problem = nil
                if let key = self.selectedKey, c.counts[key] == nil { self.selectedKey = nil }
            } else {
                self.problem = outcome.1
            }
        }
    }

    /// The published bundle for one tally result: shades, the top labels,
    /// and the camera box around every shaded unit. O(units with a count).
    nonisolated static func computed(from r: FamilyMapTally.Result, units: FamilyMapUnits) -> Computed {
        var c = Computed()
        c.counts = r.counts
        c.totals = r.totals
        let peak = r.counts.values.map(\.people).max() ?? 0
        var shades: [String: Shade] = [:]
        shades.reserveCapacity(r.counts.count)
        for (key, u) in r.counts {
            shades[key] = Shade(key: key, line: dominantLine(u.byLine), opacity: opacity(count: u.people, peak: peak))
        }
        c.shades = shades
        c.labels = r.counts
            .sorted { a, b in a.value.people != b.value.people ? a.value.people > b.value.people : a.key < b.key }
            .prefix(labelLimit)
            .compactMap { key, u -> Label? in
                guard let unit = units.unit(forKey: key) else { return nil }
                let centre = unit.cameraBox.center
                return Label(key: key, name: unit.name, count: u.people,
                             latitude: centre.latitude, longitude: centre.longitude)
            }
        c.cameraBox = units.coverage(for: r.counts.keys)
        return c
    }

    /// The line that tints a unit: whichever of Rick's / Donna's has more
    /// people; a tie (or a unit that is mostly "both") is violet.
    nonisolated static func dominantLine(_ byLine: [TreeWalk.Line: Int]) -> TreeWalk.Line {
        let first = byLine[.first] ?? 0, second = byLine[.second] ?? 0, both = byLine[.both] ?? 0
        if first == 0 && second == 0 && both == 0 { return .none }
        if both >= first && both >= second { return .both }
        if first == second { return .both }
        return first > second ? .first : .second
    }

    /// Sequential ramp on log(count): 1 person = the floor, the busiest
    /// unit = the ceiling, log-spaced between so a county with 30 births
    /// still reads next to one with 600.
    nonisolated static func opacity(count: Int, peak: Int) -> Double {
        guard count > 0 else { return 0 }
        guard peak > 1, count > 1 else { return count >= peak ? maximumOpacity : minimumOpacity }
        let t = log(Double(count)) / log(Double(peak))
        return minimumOpacity + (maximumOpacity - minimumOpacity) * min(1, max(0, t))
    }

    // MARK: Selecting a unit

    /// A click on the map: the unit under the point, else the nearest
    /// boundary (a coarse coastline), else nothing. Only a unit with a
    /// count can be selected — an empty county has nothing to say.
    func select(coordinate: FamilyMap.Coordinate) {
        let hit = units.unit(containing: coordinate) ?? units.unit(nearest: coordinate)
        select(unitKey: hit?.key)
    }

    func select(unitKey: String?) {
        guard let unitKey, computed.counts[unitKey] != nil else { selectedKey = nil; return }
        selectedKey = unitKey
    }

    var selectedUnit: FamilyMapUnits.Unit? { selectedKey.flatMap(units.unit(forKey:)) }
    var selectedCount: FamilyMapTally.UnitCount? { selectedKey.flatMap { computed.counts[$0] } }

    /// "412 of 1,024 people placed; 37 country-only; 58 with no recorded place"
    nonisolated static func totalsLine(_ t: FamilyMapTally.Totals) -> String {
        totalsLine(considered: t.considered, resolved: t.resolved, countryOnly: t.countryOnly, unresolved: t.unresolved)
    }

    nonisolated static func totalsLine(considered: Int, resolved: Int, countryOnly: Int, unresolved: Int) -> String {
        let placed = "\(resolved.formatted()) of \(considered.formatted()) \(considered == 1 ? "person" : "people") placed"
        return placed + "; \(countryOnly.formatted()) country-only; \(unresolved.formatted()) with no recorded place"
    }
}
