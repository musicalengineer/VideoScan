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
// WHERE A PERSON'S PLACE COMES FROM (Rick 2026-09-29 23:05 — his
// grandmother Mary Christina O'Connor, @I7@ / G89Q-34N, has no birthplace
// in the pulled tree but her Cork birth certificate is in the archive and
// CyberBrain carries the birth event with a `place`):
//   1. the tree's `birthPlace`, if the resolver can place it;
//   2. else the family's own knowledge: the person's ACTIVE `lifeEvents`
//      item that says born / birth and carries a non-empty `place`,
//      resolved through the same resolver;
//   3. else nothing — the person is listed under "Not on the map" with
//      whatever text WAS recorded (tree first), so "Berlin, Germany" reads
//      as "recorded but off the map", not as "no recorded place".
// Each person carries a `PlaceSource` (tree / family / none) so the panel
// can say "place from the family's notes" — and `familyRecordedIDs` says
// whose RECORDED text (placed or not) was the family's, so "Not on the map"
// never prints "recorded as Berlin" when the tree recorded nothing. The
// CyberBrain index is read through the tree's own `FamilyTreeNotesResolver`
// (the object FamilyTreeLiveModel already built — linked people first,
// then name matches), injected by the sheet; nil in tests → tree only.
// PRIVACY: the map is a family-facing surface (Donna and the relatives see
// it), so a note is read only when visible at `privacyCeiling` (= .family):
// a `.private` birth event never places anyone and never reaches the
// panel. NOTHING HERE EVER WRITES CYBERBRAIN (a source sensor in
// FamilyMapModelTests pins it).
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
// "1,200 more Englishmen, county unresolved" — and the totals line spells it
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

    /// Where a person's map place came from.
    enum PlaceSource: Sendable, Equatable {
        /// The tree's recorded birthplace.
        case tree
        /// The family's own notes (a CyberBrain birth event with a place).
        case family
        /// Neither placed them.
        case none
    }

    /// Everything a recompute reads, built once per walk off-main.
    struct Inputs: Sendable {
        let people: FamilyMapTally.People
        /// Ordinals of the people on the fan — the tally's `visited`.
        let visited: [Int]
        /// Parallel to `people.ids` (the Highlight's folded keys / regions).
        let surnameKeys: [String]
        let regions: [BirthplaceClassifier.BirthRegion]
        /// Parallel to `people.ids`: where each person's place came from.
        let placeSources: [PlaceSource]
        /// The ids placed from the family's notes — a handful, kept as a set
        /// so a member row can be tagged by id in O(1).
        let familyPlacedIDs: Set<String>
        /// The ids whose RECORDED place text came from the family's notes,
        /// placed or not (⊇ `familyPlacedIDs`): the tree was blank and the
        /// note is what "Not on the map" shows.
        let familyRecordedIDs: Set<String>
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
        /// The considered people the map could not place, nearest
        /// generation first (≤ `unplacedLimit`; the totals hold the count).
        var unplaced: [FamilyMapTally.Member] = []
    }

    /// Fill opacity range for a shaded unit (design §4: 0.35…0.85).
    /// `nonisolated`: plain constants, read from the off-main recompute.
    nonisolated static let minimumOpacity = 0.35
    nonisolated static let maximumOpacity = 0.85
    /// How many units get a name-and-count label.
    nonisolated static let labelLimit = 12
    /// How many of the people not on the map the panel lists.
    nonisolated static let unplacedLimit = 25
    /// The most private a family note may be and still place someone on
    /// this family-facing map. `.family` (QA round 2, 2026-09-29): Donna
    /// and the relatives see the map, so a `.private` item never places
    /// anyone. Rick can raise this to `.private` for an owner-only view
    /// later — a design decision noted for the morning, not taken here.
    nonisolated static let privacyCeiling: CyberBrainItem.Privacy = .family

    let inputs: Inputs
    let units: FamilyMapUnits
    let displayNames: [String]

    @Published private(set) var computed = Computed()
    @Published private(set) var selection = TreeWalkHighlight.Selection()
    @Published private(set) var yearCeiling: Int?
    @Published private(set) var selectedKey: String?
    /// The last tally problem, if any (a mask length mismatch would be a
    /// programming error; it is shown AND logged, never swallowed).
    @Published private(set) var problem: String?
    /// How many tallies have been started (the "ignore a stale reply"
    /// sequence number). Readable so a test can pin "bind tallies once".
    private(set) var generation = 0
    private var highlightSubscription: AnyCancellable?

    init(inputs: Inputs, units: FamilyMapUnits, displayNames: [String]) {
        self.inputs = inputs
        self.units = units
        self.displayNames = displayNames
    }

    // MARK: Building the inputs (once per walk, off-main)

    /// The columns for `inputs(…)`, gathered from the walk, the graph and
    /// — when the tree has a CyberBrain beside it — the family's notes, OFF
    /// the main actor. `highlight` is the Highlight panel's inputs for the
    /// same walk (its visited ordinals, folded surnames and regions are
    /// reused, not recomputed). `familyKnowledge` nil = tree only.
    nonisolated static func prepare(result: TreeWalk.Result, graph: GedcomFamilyGraph,
                                    highlight: TreeWalkHighlighter.Inputs,
                                    familyKnowledge: FamilyTreeNotesResolver? = nil) async -> Inputs {
        await Task.detached(priority: .userInitiated) {
            let n = result.ids.count
            var generations = [Int?](repeating: nil, count: n)
            for p in highlight.placed {
                let o = Int(p.ordinal)
                if o >= 0, o < n { generations[o] = p.generation }
            }
            var surnames = [String](repeating: "", count: n)
            var places = [String?](repeating: nil, count: n)
            var familyPlaces = [String?](repeating: nil, count: n)
            for o in highlight.visited where o >= 0 && o < n {
                let person = graph.people[result.ids[o]]
                surnames[o] = person?.surname ?? ""
                places[o] = person?.birthPlace
                if let familyKnowledge {
                    familyPlaces[o] = familyBirthPlace(gedcomID: result.ids[o], in: familyKnowledge)
                }
            }
            return inputs(ids: result.ids, names: result.names, surnames: surnames,
                          surnameKeys: highlight.surnameKeys, birthPlaces: places,
                          familyPlaces: familyKnowledge == nil ? nil : familyPlaces,
                          birthYears: highlight.birthYears, generations: generations,
                          lines: result.decorations.map(\.line), visited: highlight.visited,
                          regions: highlight.regions)
        }.value
    }

    /// The family's recorded birthplace for one tree record: the first
    /// ACTIVE life event of any CyberBrain person standing for the record
    /// that asserts THAT PERSON'S OWN birth (`isOwnBirthEvent`), carries a
    /// place, and is visible at the map's privacy ceiling. Read-only;
    /// disputed items are passed over (a disputed birthplace must not
    /// quietly place someone); a `.private` item is passed over too (the
    /// map is family-facing). O(items about the person).
    nonisolated static func familyBirthPlace(gedcomID: String, in knowledge: FamilyTreeNotesResolver) -> String? {
        for person in knowledge.cyberBrainPeople(forGedcomID: gedcomID) {
            for item in knowledge.index.allActiveItems(for: person.id)
            where item.kind == .event && item.confidence != .disputed
                && item.privacy.isVisible(at: privacyCeiling) && isOwnBirthEvent(item, of: person) {
                if let place = item.place, FamilyMapTally.hasText(place) { return place }
            }
        }
        return nil
    }

    /// Does a life event assert the SUBJECT'S OWN birth? (codex #227
    /// follow-up, P2: "Moved to Boston after the birth of her daughter" is
    /// an event ABOUT Mary whose birth is somebody else's — Boston must
    /// not become Mary's birthplace.) A CyberBrain event is free text;
    /// `CyberBrainItem` has no structured "birth" kind (Hallie's
    /// `TreeFact.Kind.birth` lives on the telling, not on stored items),
    /// so this reads the sentence the way the writers write it.
    ///
    /// Rejected first, whatever else the text says:
    ///   - "birth of …", "gave birth", "birth to …" — a birth that belongs
    ///     to someone else;
    ///   - a relative noun (daughter, son, child, twins, brother, …),
    ///     optionally followed by a Name, then "was / were born".
    /// Accepted (any one):
    ///   1. the text BEGINS "Born …" / "Birth …" ("Born in Cork.",
    ///      "BIRTH registered late.");
    ///   2. it BEGINS "His / Her birth …" (a life event about the person,
    ///      opening with her own birth: "Her birth was registered in
    ///      Yorkshire.");
    ///   3. "she / he was born" anywhere;
    ///   4. it BEGINS with a run of capitalised Names then "was / is
    ///      born" (or ", born"), and one of those Names is one of the
    ///      person's own GIVEN names (canonical name or alias, token-wise,
    ///      the surname excluded — a relative shares it): "Mary Christina
    ///      O'Connor was born on 1 January 1900 at 1 Example Lane,
    ///      Cork …" — the shape of the 2026-09-29 birth-certificate
    ///      event. "Daniel O'Connor was born in Cork" on Mary's record
    ///      is her father's name, not hers; ambiguous stays unplaced.
    /// Anything else — "Married Jane Osborne at Birthdale", "(The tree
    /// gives her birth as August 1903)" inside a death event — is not her
    /// birth. Known false negatives, by design: a nickname the archive
    /// does not list ("Grandma was born in Cork"), a surname-only form
    /// ("Mrs O'Connor was born"), a lower-case particle in the name run
    /// ("Mary de Burgh was born").
    nonisolated static func isOwnBirthEvent(_ item: CyberBrainItem, of person: CyberBrainPerson) -> Bool {
        let text = item.text
        let ci: String.CompareOptions = [.regularExpression, .caseInsensitive]
        let cs: String.CompareOptions = [.regularExpression]
        // Someone else's birth, in any wording → never the subject's.
        if text.range(of: #"\bbirths?\s+(?:of|to)\b|\bgave\s+birth\b"#, options: ci) != nil { return false }
        if text.range(of: Self.relativeBornPattern, options: cs) != nil { return false }
        // The subject's own birth, in the writers' shapes.
        if text.range(of: #"^\W*(?:born|birth|his\s+birth|her\s+birth)\b"#, options: ci) != nil { return true }
        if text.range(of: #"\b(?:she|he)\s+was\s+born\b"#, options: ci) != nil { return true }
        guard let run = text.range(of: #"^\W*(?:\p{Lu}\S*\s+){1,6}?(?=(?:was\s+|is\s+)?born\b)"#, options: cs) else { return false }
        let given = Set(givenNameTokens(person))
        return FamilyIdentityText.tokens(String(text[run])).contains { $0.count >= 2 && given.contains($0) }
    }

    /// The person's given-name tokens: every name (canonical + aliases)
    /// minus its last token (the surname) — a one-word alias ("Mamie") is
    /// kept whole. Initials and other one-letter tokens are dropped.
    nonisolated static func givenNameTokens(_ person: CyberBrainPerson) -> [String] {
        ([person.canonicalName] + person.aliases).flatMap { name -> [String] in
            let tokens = FamilyIdentityText.tokens(name)
            return (tokens.count > 1 ? Array(tokens.dropLast()) : tokens).filter { $0.count >= 2 }
        }
    }

    /// "her daughter was born", "his son John Patrick was born", "the
    /// twins were born" — a relative, at most three capitalised name
    /// tokens, then was / were born. Case-sensitive so the optional Names
    /// are real Names: "Daughter of Daniel, she was born in Cork" does not
    /// match ("of" is no Name), and rule 3 then accepts it.
    nonisolated private static let relativeBornPattern =
        #"\b(?i:daughters?|sons?|child|children|baby|babies|twins?|grandsons?|granddaughters?|grandchild|grandchildren|"# +
        #"brothers?|sisters?|nieces?|nephews?|cousins?|wife|husband|mother|father|parents?)\s+(?:\p{Lu}\S*\s+){0,3}(?:was|were|is|are)\s+born\b"#

    /// The pure form: resolves every VISITED person's place once and packs
    /// the columns. Columns are parallel to `ids`; `visited` lists
    /// ordinals. The tree's `birthPlaces` win when they resolve; a
    /// `familyPlaces` entry (nil = no family knowledge) is tried only then.
    /// Synchronous and actor-free so a scale test can time it directly.
    nonisolated static func inputs(ids: [String], names: [String], surnames: [String], surnameKeys: [String],
                                   birthPlaces: [String?], familyPlaces: [String?]? = nil,
                                   birthYears: [Int?], generations: [Int?],
                                   lines: [TreeWalk.Line], visited: [Int],
                                   regions: [BirthplaceClassifier.BirthRegion]) -> Inputs {
        var unitKeys = [String?](repeating: nil, count: ids.count)
        var recorded = [String?](repeating: nil, count: ids.count)
        var sources = [PlaceSource](repeating: .none, count: ids.count)
        var familyPlaced = Set<String>()
        var familyRecorded = Set<String>()
        for o in visited where o >= 0 && o < birthPlaces.count {
            let tree = birthPlaces[o]
            let family: String? = familyPlaces.flatMap { o < $0.count ? $0[o] : nil }
            // ONE resolver call site (a sensor pins it): tree first, then
            // the family's note; the first that places the person wins.
            for (candidate, source) in [(tree, PlaceSource.tree), (family, PlaceSource.family)] {
                guard let candidate, FamilyMapTally.hasText(candidate) else { continue }
                if recorded[o] == nil {                                // what WAS recorded, tree first
                    recorded[o] = candidate
                    if source == .family { familyRecorded.insert(ids[o]) }
                }
                if let hit = BirthplaceUnitResolver.resolve(candidate) {
                    unitKeys[o] = hit.unitKey
                    recorded[o] = candidate
                    sources[o] = source
                    if source == .family {
                        familyPlaced.insert(ids[o])
                        familyRecorded.insert(ids[o])
                    }
                    break
                }
            }
        }
        let people = FamilyMapTally.People(ids: ids, names: names, surnames: surnames, surnameKeys: surnameKeys,
                                           birthYears: birthYears, generations: generations, lines: lines,
                                           unitKeys: unitKeys, recordedPlaces: recorded)
        return Inputs(people: people, visited: visited, surnameKeys: surnameKeys, regions: regions,
                      placeSources: sources, familyPlacedIDs: familyPlaced, familyRecordedIDs: familyRecorded)
    }

    /// Was this person placed from the family's notes rather than the tree?
    func isPlacedFromFamilyNotes(_ id: String) -> Bool { inputs.familyPlacedIDs.contains(id) }

    /// Is the place text shown for this person the family's note (the tree
    /// recorded nothing)? True for everyone placed by the notes AND for the
    /// unplaced whose only recorded text is a note the map could not read.
    func isRecordedFromFamilyNotes(_ id: String) -> Bool { inputs.familyRecordedIDs.contains(id) }

    // MARK: Following the Highlight checks

    /// Mirror the Highlight panel's checks: the map filters exactly as the
    /// fan highlights. Subscribed once; the model recomputes even while the
    /// fan is showing, so a return to the map is already current. A
    /// `@Published` publisher REPLAYS its current value on subscription, so
    /// binding is itself the first tally — the caller must not `apply` the
    /// same selection again afterwards (it did, once: two tallies of every
    /// walk; QA round 2).
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
                                                      mask: mask, yearCeiling: yearCeiling,
                                                      unplacedLimit: Self.unplacedLimit)
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
                // Counts only (a TallyError names column lengths), never a person.
                appLog.write("Family map: tally failed — \(outcome.1 ?? "unknown error")")
            }
        }
    }

    /// The published bundle for one tally result: shades, the top labels
    /// (each on its unit's `labelAnchor` — a country outline's on its
    /// principal piece), the camera box (the fine counted units; the
    /// country outlines only when nothing finer is counted — see
    /// `FamilyMapUnits.coverage`), and the unplaced list. O(units with a
    /// count).
    nonisolated static func computed(from r: FamilyMapTally.Result, units: FamilyMapUnits) -> Computed {
        var c = Computed()
        c.counts = r.counts
        c.totals = r.totals
        c.unplaced = r.unplaced
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
                let anchor = unit.labelAnchor
                return Label(key: key, name: unit.name, count: u.people,
                             latitude: anchor.latitude, longitude: anchor.longitude)
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

    /// A click on the map, decided over the COUNTED units only (an empty
    /// county has nothing to say, so it never blocks what is under or
    /// beside it — codex #1782, stage 2 F1):
    ///   (a) the finest counted county / state / province containing the
    ///       point;
    ///   (b) else the nearest counted fine unit within the coastal tolerance
    ///       (Natural Earth's outlines are coarser than the counties, so a
    ///       waterfront click is often "inside the country, outside every
    ///       county" — Halifax; the probe (45.774, -63.102));
    ///   (c) else the counted country outline containing the point;
    ///   (d) else the selection is left as it was.
    func select(coordinate: FamilyMap.Coordinate) {
        var fine = Set<String>(), countries = Set<String>()
        for key in computed.counts.keys {
            if FamilyMapKey.isCountryKey(key) { countries.insert(key) } else { fine.insert(key) }
        }
        let hit = units.unit(containing: coordinate, among: fine)
            ?? units.unit(nearest: coordinate, among: fine)
            ?? units.unit(containing: coordinate, among: countries)
        guard let hit else { return }
        select(unitKey: hit.key)
    }

    func select(unitKey: String?) {
        guard let unitKey, computed.counts[unitKey] != nil else { selectedKey = nil; return }
        selectedKey = unitKey
    }

    var selectedUnit: FamilyMapUnits.Unit? { selectedKey.flatMap(units.unit(forKey:)) }
    var selectedCount: FamilyMapTally.UnitCount? { selectedKey.flatMap { computed.counts[$0] } }

    // MARK: Panel text

    /// "412 of 1,024 people placed; 37 country-only; 58 with no recorded
    /// place; 12 recorded but off the map" — a zero part is left out, so a
    /// Berlin birth is never described as unrecorded (codex #1782, F2).
    nonisolated static func totalsLine(_ t: FamilyMapTally.Totals) -> String {
        totalsLine(considered: t.considered, resolved: t.resolved, countryOnly: t.countryOnly,
                   unresolved: t.unresolved, unsupported: t.unsupported)
    }

    nonisolated static func totalsLine(considered: Int, resolved: Int, countryOnly: Int, unresolved: Int,
                                       unsupported: Int = 0) -> String {
        var line = "\(resolved.formatted()) of \(considered.formatted()) \(considered == 1 ? "person" : "people") placed"
        if countryOnly > 0 { line += "; \(countryOnly.formatted()) country-only" }
        let noPlace = unresolved - unsupported
        if noPlace > 0 { line += "; \(noPlace.formatted()) with no recorded place" }
        if unsupported > 0 { line += "; \(unsupported.formatted()) recorded but off the map" }
        return line
    }

    /// The second line under "Not on the map": why, in plain words.
    /// "2 with no recorded place · 1 recorded but off the map"; "" when
    /// everyone is placed.
    nonisolated static func notOnTheMapLine(_ t: FamilyMapTally.Totals) -> String {
        var parts: [String] = []
        if t.noRecordedPlace > 0 { parts.append("\(t.noRecordedPlace.formatted()) with no recorded place") }
        if t.unsupported > 0 { parts.append("\(t.unsupported.formatted()) recorded but off the map") }
        return parts.joined(separator: " · ")
    }

    /// What a member row says under the name: where the place came from
    /// and what was recorded. nil when nothing was recorded.
    nonisolated static func placeNote(recordedPlace: String?, fromFamilyNotes: Bool) -> String? {
        guard let recordedPlace, FamilyMapTally.hasText(recordedPlace) else { return nil }
        return fromFamilyNotes ? "from the family's notes: \(recordedPlace)" : "recorded as \(recordedPlace)"
    }
}
