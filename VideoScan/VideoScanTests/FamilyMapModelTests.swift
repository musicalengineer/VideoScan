// FamilyMapModelTests.swift
// The Family Map's app half (GH #227 stage 2). Dimensions:
//   Logic     — the walked people resolve to units through the real
//               pipeline (walk → fan layout → Highlight inputs → map
//               inputs); an EMPTY selection counts everyone (nil mask,
//               never all-false); a surname check narrows; a country-only
//               birth shades the outline and a county birth does NOT also
//               shade its country; totals reconcile (resolved + unresolved
//               == considered, countryOnly ⊂ resolved); a click picks the
//               unit under it, else the nearest coast, and only a unit with
//               a count; shades, labels, the camera region and the panel
//               lines are pinned.
//   Scale     — building the inputs for 40k people (every birthplace
//               resolved once) stays under 300 ms in Debug, load-aware;
//               100k people (2.5× the real tree) build + tally under a
//               thread-CPU budget (GH #208). The bundled map at the real
//               tree's size, on screen, is FamilyMapRenderSensorTests.
//   Isolation — synthetic units only (never the bundle from here); the
//               model and the view read no App Support and no network.
//   Sensor    — `FamilyTreeMapView` never resolves or tallies in a body;
//               the bundled border file is in the built app; the About
//               window carries the border-data attribution.
//
// Never `import MapKit` here: the link sensor (MapKitLinkSensorTests)
// checks the APP loaded it, and an import from the test bundle would load
// it from here and blind that sensor.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

/// Rick and Donna with a few ancestors whose birthplaces cover every case:
/// a county (Yorkshire), a country alone (England), a Scottish county, a
/// US state, no place at all (Donna), and a place off the map (Poland).
private let placedRoots = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
2 PLAC Boston, Massachusetts
1 FAMC @F1@
1 FAMS @F0@
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMC @F2@
1 FAMS @F0@
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 21 FEB 1929
2 PLAC Sheffield, Yorkshire, England
1 FAMS @F1@
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1931
2 PLAC England
1 FAMC @F3@
1 FAMS @F1@
0 @I7@ INDI
1 NAME Richard C /Hudson/
1 SEX M
1 BIRT
2 PLAC Fife, Scotland
1 FAMS @F2@
0 @I8@ INDI
1 NAME Karl /Latta/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC Warsaw, Poland
1 FAMS @F3@
0 @F0@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I8@
1 CHIL @I4@
0 TRLR
"""

/// Axis-aligned squares standing in for the bundled borders: England's
/// outline holds Yorkshire; the US outline holds Massachusetts; Fife is a
/// small square off to the north.
private func square(_ key: String, _ name: String, _ country: FamilyMap.Country, _ kind: FamilyMap.UnitKind,
                    lat: ClosedRange<Double>, lon: ClosedRange<Double>) -> FamilyMapUnits.Unit {
    let ring = [FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.lowerBound),
                FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.upperBound),
                FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.upperBound),
                FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.lowerBound)]
    return FamilyMapUnits.Unit(key: key, name: name, country: country, kind: kind,
                               polygons: [FamilyMapUnits.Polygon(outer: ring)])
}

private let syntheticUnits = FamilyMapUnits(units: [
    square("eng", "England", .england, .country, lat: 50...56, lon: -6...2),
    square("eng-yorkshire", "Yorkshire", .england, .county, lat: 53...55, lon: -2...0),
    square("sct-fife", "Fife", .scotland, .county, lat: 56.1...56.5, lon: -3.5...(-2.5)),
    square("usa", "United States", .unitedStates, .country, lat: 25...49, lon: -125...(-66)),
    square("usa-massachusetts", "Massachusetts", .unitedStates, .state, lat: 41.5...43, lon: -73.5...(-70)),
])

/// The four totals as an array — `FamilyMapTally.Totals` has no public
/// initializer to build an expected value with.
private func fields(_ t: FamilyMapTally.Totals) -> [Int] { [t.considered, t.resolved, t.countryOnly, t.unresolved] }

/// Poll a main-actor condition (the model publishes after an off-main hop);
/// fails after ~2 s rather than hanging.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within 2 s")
}

/// The real pipeline from a GEDCOM to a map model over the synthetic units.
@MainActor
private func mapModel(for gedcom: String, starts: [String] = ["@I1@", "@I2@"])
async throws -> (FamilyMapModel, TreeWalkHighlighter, TreeWalk.Result, GedcomFamilyGraph) {
    let g = GedcomFamilyGraph(gedcomText: gedcom)
    let r = try TreeWalk.walk(g, options: .init(starts: starts))
    let layout = await TreeWalkAnimator.prepare(r, size: CGSize(width: 600, height: 600))
    let highlight = await TreeWalkHighlighter.prepare(result: r, graph: g, layout: layout)
    let inputs = await FamilyMapModel.prepare(result: r, graph: g, highlight: highlight)
    let model = FamilyMapModel(inputs: inputs, units: syntheticUnits, displayNames: ["Rick", "Donna"])
    return (model, TreeWalkHighlighter(inputs: highlight), r, g)
}

@Suite("FamilyMapModel")
@MainActor
struct FamilyMapModelTests {

    // MARK: Logic

    @Test func theWalkedPeopleResolveToUnitsAndTheTotalsReconcile() async throws {
        let (m, _, r, _) = try await mapModel(for: placedRoots)
        #expect(r.visitedCount == 6)
        #expect(m.inputs.visited.count == 6)
        // The resolver ran once per visited person, on the recorded place.
        func key(_ id: String) -> String? { r.ordinal(of: id).flatMap { m.inputs.people.unitKeys[$0] } }
        #expect(key("@I1@") == "usa-massachusetts")
        #expect(key("@I3@") == "eng-yorkshire")
        #expect(key("@I4@") == "eng", "a country alone shades the outline")
        #expect(key("@I7@") == "sct-fife")
        #expect(key("@I2@") == nil, "no recorded place")
        #expect(key("@I8@") == nil, "Poland is off the map")

        m.apply(selection: .init(), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 6 }
        let t = m.computed.totals
        #expect(fields(t) == [6, 4, 1, 2], "considered / resolved / countryOnly / unresolved")
        #expect(t.resolved + t.unresolved == t.considered)
        #expect(m.computed.counts.values.reduce(0) { $0 + $1.people } == t.resolved)
        #expect(m.computed.counts["eng-yorkshire"]?.people == 1)
        #expect(m.computed.counts["eng"]?.people == 1, "ONLY the country-only person — Yorkshire's is not counted twice")
        #expect(m.computed.counts["sct-fife"]?.people == 1)
        #expect(m.computed.counts["usa-massachusetts"]?.people == 1)
        #expect(m.computed.counts["usa"] == nil, "no one was recorded as just 'United States'")
        #expect(m.computed.counts["eng"]?.members.map(\.name) == ["Eileen Latta"])
        #expect(m.computed.counts["eng-yorkshire"]?.byLine == [.first: 1])
        #expect(m.computed.counts["sct-fife"]?.byLine == [.second: 1])
        #expect(t.unsupported == 1, "Karl's Warsaw was recorded; Donna recorded nothing")
        #expect(FamilyMapModel.totalsLine(t) == "4 of 6 people placed; 1 country-only; 1 with no recorded place; 1 recorded but off the map")
        // Not on the map, nearest generation first: Donna (a start, gen 0)
        // before Karl (gen 2), each with what was recorded.
        #expect(m.computed.unplaced.map(\.name) == ["Donna Hudson", "Karl Latta"])
        #expect(m.computed.unplaced.map(\.recordedPlace) == [nil, "Warsaw, Poland"])
        #expect(m.computed.unplaced.map(\.generation) == [0, 2])
        #expect(FamilyMapModel.notOnTheMapLine(t) == "1 with no recorded place · 1 recorded but off the map")
        // Every placed person carries the recorded text (the colonial tooltip).
        #expect(m.computed.counts["eng-yorkshire"]?.members.first?.recordedPlace == "Sheffield, Yorkshire, England")
        #expect(m.computed.counts["usa-massachusetts"]?.members.first?.recordedPlace == "Boston, Massachusetts")
        // Tree only (no family knowledge was injected): every place is the tree's.
        func source(_ id: String) -> FamilyMapModel.PlaceSource? { r.ordinal(of: id).map { m.inputs.placeSources[$0] } }
        #expect(source("@I1@") == .tree && source("@I3@") == .tree && source("@I4@") == .tree && source("@I7@") == .tree)
        #expect(source("@I2@") == FamilyMapModel.PlaceSource.none && source("@I8@") == FamilyMapModel.PlaceSource.none)
        #expect(m.inputs.familyPlacedIDs.isEmpty)

        // Shades: every unit with a count, opacity in the documented range,
        // tinted by its line; labels are the busiest first, by name on ties.
        #expect(Set(m.computed.shades.keys) == Set(m.computed.counts.keys))
        #expect(m.computed.shades.values.allSatisfy { $0.opacity >= FamilyMapModel.minimumOpacity && $0.opacity <= FamilyMapModel.maximumOpacity })
        #expect(m.computed.shades["eng-yorkshire"]?.line == .first)
        #expect(m.computed.shades["sct-fife"]?.line == .second)
        #expect(m.computed.labels.map(\.key) == ["eng", "eng-yorkshire", "sct-fife", "usa-massachusetts"])
        #expect(m.computed.labels.first?.name == "England")
        // The camera box is the coverage of the shaded units only.
        #expect(m.computed.cameraBox == syntheticUnits.coverage(for: m.computed.counts.keys))
        #expect(m.computed.cameraBox?.minLongitude == -73.5, "Massachusetts is the western edge")
        #expect(m.computed.cameraBox?.maxLatitude == 56.5, "Fife is the northern edge")
        #expect(m.problem == nil)
    }

    @Test func aSurnameCheckNarrowsAndAnEmptySelectionCountsEveryoneAgain() async throws {
        let (m, _, _, _) = try await mapModel(for: placedRoots)
        m.apply(selection: .init(surnames: ["breen"]), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 2 }
        #expect(fields(m.computed.totals) == [2, 2, 0, 0])
        #expect(Set(m.computed.counts.keys) == ["usa-massachusetts", "eng-yorkshire"])
        #expect(m.computed.labels.count == 2)
        #expect(!m.selection.isEmpty)

        // Back to no checks: nil mask → everyone, NOT the all-false mask
        // TreeWalkHighlight.mask returns for an empty selection.
        m.apply(selection: .init(), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 6 }
        #expect(m.computed.totals.resolved == 4)
        #expect(m.selection.isEmpty)

        // A region check AND a surname check: a Breen born in New England.
        m.apply(selection: .init(surnames: ["breen"], regions: [BirthplaceClassifier.BirthRegion.newEngland.rawValue]),
                yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 1 }
        #expect(m.computed.counts.keys.sorted() == ["usa-massachusetts"])

        // The year ceiling: births ≤ 1930 — Karl 1900 (unresolved) and
        // Richard Sr 1929; the undated are excluded when a ceiling is set.
        m.apply(selection: .init(), yearCeiling: 1930)
        try await waitUntil { m.computed.totals.considered == 2 }
        #expect(fields(m.computed.totals) == [2, 1, 0, 1])
        #expect(m.yearCeiling == 1930)
    }

    /// The model follows the Highlight panel's checks through `bind(to:)`,
    /// so a return from the fan to the map is already current. Binding
    /// replays the current selection, so it is the ONE tally the sheet
    /// needs — a second explicit `apply` would count everyone twice (QA
    /// round 2 nit).
    @Test func theModelFollowsTheHighlighterChecks() async throws {
        let (m, h, _, _) = try await mapModel(for: placedRoots)
        #expect(m.generation == 0)
        m.bind(to: h)
        #expect(m.generation == 1, "bind tallies once; no second apply is needed")
        try await waitUntil { m.computed.totals.considered == 6 }
        #expect(m.generation == 1, "and nothing tallied a second time")
        h.setSurname("hudson", on: true)
        try await waitUntil { m.computed.totals.considered == 2 }
        #expect(m.computed.counts.keys.sorted() == ["sct-fife"], "Donna has no place; her father is in Fife")
        #expect(m.computed.totals.unresolved == 1)
        h.clear()
        try await waitUntil { m.computed.totals.considered == 6 }
    }

    /// Two changes in flight at once: the LAST one wins, whichever finishes
    /// first (the generation counter; same pattern as the Highlight).
    @Test func theLastOfTwoRapidChangesWins() async throws {
        let (m, _, _, _) = try await mapModel(for: placedRoots)
        m.apply(selection: .init(surnames: ["breen"]), yearCeiling: nil)
        m.apply(selection: .init(), yearCeiling: nil)             // no await between them
        try await waitUntil { m.computed.totals.considered == 6 }
        try await Task.sleep(for: .milliseconds(60))               // let a stale reply (if any) land
        #expect(m.computed.totals.considered == 6, "the empty selection was last")
        #expect(m.selection.isEmpty)

        m.apply(selection: .init(), yearCeiling: nil)
        m.apply(selection: .init(surnames: ["breen"]), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 2 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(m.computed.totals.considered == 2, "the surname check was last")
        #expect(m.selection.surnames == ["breen"])
    }

    /// A click is decided over the COUNTED units in four steps (codex #1782,
    /// stage 2 F1): (a) the finest counted fine unit containing the point;
    /// (b) else the nearest counted fine unit within tolerance; (c) else
    /// the counted country containing it; (d) else no change. Synthetic
    /// units and a synthetic tally (the pure `inputs`), no walk.
    @Test func aClickIsDecidedOverTheCountedUnitsInFourSteps() async throws {
        // Kent is a county nobody was born in; "United States" has no
        // country-only person — both are uncounted outlines on the map.
        let units = FamilyMapUnits(units: syntheticUnits.units + [
            square("eng-kent", "Kent", .england, .county, lat: 51...51.5, lon: 0.5...1.5),
        ])
        let places: [String?] = ["England", "Sheffield, Yorkshire, England", "Fife, Scotland", "Boston, Massachusetts"]
        let n = places.count
        let surnames = ["Latta", "Breen", "Hudson", "Breen"]
        let inputs = FamilyMapModel.inputs(
            ids: (0..<n).map { "@P\($0)@" }, names: ["Eileen", "Richard", "Hudson", "Rick"], surnames: surnames,
            surnameKeys: TreeWalkHighlight.surnameKeys(surnames), birthPlaces: places,
            birthYears: [1931, 1929, nil, 1959], generations: [1, 1, 1, 0],
            lines: [.first, .first, .second, .first], visited: Array(0..<n),
            regions: [.england, .england, .scotland, .newEngland])
        let m = FamilyMapModel(inputs: inputs, units: units, displayNames: ["Rick", "Donna"])
        m.apply(selection: .init(), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == n }
        #expect(Set(m.computed.counts.keys) == ["eng", "eng-yorkshire", "sct-fife", "usa-massachusetts"])

        // (a) inside Yorkshire AND England, both counted: the county.
        m.select(coordinate: .init(latitude: 54, longitude: -1))
        #expect(m.selectedKey == "eng-yorkshire", "the finest counted unit containing the point")
        #expect(m.selectedUnit?.name == "Yorkshire")
        #expect(m.selectedCount?.people == 1)

        // (b) inside England, 0.05° south of Yorkshire's edge: the county
        // beats the outline that contains the point (a coarse coastline).
        m.select(coordinate: .init(latitude: 52.95, longitude: -1))
        #expect(m.selectedKey == "eng-yorkshire", "the nearest counted fine unit within tolerance")
        m.select(coordinate: .init(latitude: 56.55, longitude: -3))        // just off Fife's north coast, in no unit
        #expect(m.selectedKey == "sct-fife")

        // (c) inside EMPTY Kent: the counted country around it, not nothing.
        m.select(coordinate: .init(latitude: 51.2, longitude: 1))
        #expect(m.selectedKey == "eng", "an uncounted county never blocks the counted outline under it")
        m.select(coordinate: .init(latitude: 51, longitude: -1))           // plain England, far from any county
        #expect(m.selectedKey == "eng")

        // (d) nothing counted under or near the point: the selection stays.
        m.select(unitKey: "sct-fife")
        m.select(coordinate: .init(latitude: 40, longitude: -100))         // the uncounted US outline
        #expect(m.selectedKey == "sct-fife", "no change")
        m.select(coordinate: .init(latitude: 0, longitude: 0))             // open sea
        #expect(m.selectedKey == "sct-fife", "no change")
        m.select(unitKey: nil)
        m.select(coordinate: .init(latitude: 0, longitude: 0))
        #expect(m.selectedKey == nil, "still nothing")

        // By key: only a counted unit can be selected.
        m.select(unitKey: "usa-massachusetts")
        #expect(m.selectedKey == "usa-massachusetts")
        m.select(unitKey: "eng-kent")
        #expect(m.selectedKey == nil, "no count → nothing to say")
        m.select(unitKey: "no-such-unit")
        #expect(m.selectedKey == nil)

        // A selection that narrows the map away from the selected unit
        // clears the selection rather than showing a stale panel.
        m.select(unitKey: "sct-fife")
        m.apply(selection: .init(surnames: ["breen"]), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 2 }
        #expect(m.selectedKey == nil)
    }

    @Test func shadesLabelsCameraAndPanelLinesArePinned() throws {
        typealias M = FamilyMapModel
        // Opacity: a log ramp from the floor (1 person) to the ceiling (the peak).
        #expect(M.opacity(count: 0, peak: 10) == 0)
        #expect(M.opacity(count: 1, peak: 1) == M.maximumOpacity, "the only unit is the peak")
        #expect(M.opacity(count: 1, peak: 100) == M.minimumOpacity)
        #expect(abs(M.opacity(count: 10, peak: 100) - 0.6) < 1e-9, "halfway up the log ramp")
        #expect(M.opacity(count: 100, peak: 100) == M.maximumOpacity)
        #expect(M.opacity(count: 30, peak: 600) > M.minimumOpacity + 0.2, "30 still reads next to 600")
        // The tint: Rick's / Donna's by majority; both, or a tie, is violet.
        #expect(M.dominantLine([.first: 5, .second: 2]) == .first)
        #expect(M.dominantLine([.first: 1, .second: 4, .both: 1]) == .second)
        #expect(M.dominantLine([.first: 3, .second: 3]) == .both)
        #expect(M.dominantLine([.first: 2, .second: 1, .both: 2]) == .both)
        #expect(M.dominantLine([.none: 4]) == .none)
        #expect(M.dominantLine([:]) == .none)
        // The totals line, singular and plural; a zero part is left out, and
        // a recorded-but-off-the-map birth is never "no recorded place".
        #expect(M.totalsLine(considered: 1, resolved: 1, countryOnly: 0, unresolved: 0)
                == "1 of 1 person placed")
        #expect(M.totalsLine(considered: 39_249, resolved: 24_500, countryOnly: 20_284, unresolved: 14_749)
                == "24,500 of 39,249 people placed; 20,284 country-only; 14,749 with no recorded place")
        #expect(M.totalsLine(considered: 39_249, resolved: 24_500, countryOnly: 20_284, unresolved: 14_749, unsupported: 825)
                == "24,500 of 39,249 people placed; 20,284 country-only; 13,924 with no recorded place; 825 recorded but off the map")
        #expect(M.totalsLine(considered: 1, resolved: 0, countryOnly: 0, unresolved: 1, unsupported: 1)
                == "0 of 1 person placed; 1 recorded but off the map")
        #expect(M.notOnTheMapLine(.init(considered: 3, resolved: 1, countryOnly: 0, unresolved: 2, unsupported: 2))
                == "2 recorded but off the map")
        #expect(M.notOnTheMapLine(.init(considered: 3, resolved: 3, countryOnly: 0, unresolved: 0)).isEmpty)
        // The member note: what was recorded, and whose record it was.
        #expect(M.placeNote(recordedPlace: "Massachusetts Bay Colony", fromFamilyNotes: false) == "recorded as Massachusetts Bay Colony")
        #expect(M.placeNote(recordedPlace: "Cork, Ireland", fromFamilyNotes: true) == "from the family's notes: Cork, Ireland")
        #expect(M.placeNote(recordedPlace: nil, fromFamilyNotes: false) == nil)
        #expect(M.placeNote(recordedPlace: "  ", fromFamilyNotes: true) == nil)
        // The camera region: padded, never tighter than 0.6°, never wider than the world.
        let box = FamilyMap.BoundingBox(minLatitude: 50, maxLatitude: 58, minLongitude: -8, maxLongitude: 2)
        let r = FamilyTreeMapView.cameraRegion(for: box)
        #expect(r == .init(centerLatitude: 54, centerLongitude: -3, latitudeDelta: 10, longitudeDelta: 12.5))
        let tiny = FamilyTreeMapView.cameraRegion(for: .init(minLatitude: 56.1, maxLatitude: 56.5, minLongitude: -3.5, maxLongitude: -2.5))
        #expect(tiny.latitudeDelta == 0.6 && tiny.longitudeDelta == 1.25)
        let world = FamilyTreeMapView.cameraRegion(for: .init(minLatitude: -80, maxLatitude: 80, minLongitude: -179, maxLongitude: 179))
        #expect(world.latitudeDelta == 170 && world.longitudeDelta == 340)
        // The count line: a county names its country; a country outline says
        // the county is UNRESOLVED — "Lothian, Scotland" was recorded, the
        // map just cannot pin one county to it (codex #1782, stage 2 F2).
        let york = try #require(syntheticUnits.unit(forKey: "eng-yorkshire"))
        let england = try #require(syntheticUnits.unit(forKey: "eng"))
        let usa = try #require(syntheticUnits.unit(forKey: "usa"))
        #expect(FamilyTreeMapView.countLine(unit: york, count: 42) == "42 people born in Yorkshire, England")
        #expect(FamilyTreeMapView.countLine(unit: york, count: 1) == "1 person born in Yorkshire, England")
        #expect(FamilyTreeMapView.countLine(unit: england, count: 7) == "7 people born in England, county unresolved")
        #expect(FamilyTreeMapView.countLine(unit: usa, count: 7) == "7 people born in United States, state unresolved")
        #expect(!FamilyTreeMapView.countLine(unit: england, count: 7).contains("not recorded"))
        // A synthetic unit set gets one stable fingerprint (the MKPolygon cache key).
        #expect(FamilyMapShapes.fingerprint(syntheticUnits) == FamilyMapShapes.fingerprint(syntheticUnits))
        #expect(FamilyMapShapes.fingerprint(syntheticUnits) == "5/eng/usa-massachusetts/20")
    }

    // MARK: The camera (QA round 2, 2026-09-29) — over the BUNDLED file

    /// The committed border file, read from the repo by path (as
    /// FamilyMapBundledDataTests does) — never the app bundle, never App
    /// Support. The camera tests need the real `usa` outline: 123 pieces
    /// from the western Aleutians across the antimeridian to 71°N.
    private static func bundledUnits() throws -> FamilyMapUnits {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/Resources/FamilyMap/family-map-units.geojson")
        return try FamilyMapUnits(geoJSON: try Data(contentsOf: url))
    }

    private static func computed(unitKeys: [String?], recorded: [String], units: FamilyMapUnits) throws -> FamilyMapModel.Computed {
        let n = unitKeys.count
        let people = FamilyMapTally.People(ids: (0..<n).map { "@P\($0)@" }, names: (0..<n).map { "P\($0)" },
                                           surnames: (0..<n).map { "S\($0)" },
                                           birthYears: [Int?](repeating: nil, count: n), generations: [Int?](repeating: 1, count: n),
                                           lines: [TreeWalk.Line](repeating: .first, count: n),
                                           unitKeys: unitKeys, recordedPlaces: recorded)
        return FamilyMapModel.computed(from: try FamilyMapTally.counts(people: people, visited: Array(0..<n)), units: units)
    }

    /// QA's red test: one Yorkshire birth and one "New England" birth
    /// (country-only `usa`). Before the fix the camera box was the union of
    /// Yorkshire and the whole US outline — Aleutians to Yorkshire, 223° ×
    /// 66° — and the "United States" label sat at the union centre, in
    /// Oregon. Now the fine counted unit frames the map alone, and the
    /// outline's label is on its principal piece.
    @Test func aCountryOnlyCountDoesNotOpenTheCameraOnAHemisphere() throws {
        let units = try Self.bundledUnits()
        let people = FamilyMapTally.People(ids: ["a", "b"], names: ["A", "B"], surnames: ["X", "Y"],
                                           birthYears: [nil, nil], generations: [1, 1], lines: [.first, .first],
                                           unitKeys: ["eng-yorkshire", "usa"], recordedPlaces: ["Sheffield, Yorkshire, England", "New England"])
        let c = FamilyMapModel.computed(from: try FamilyMapTally.counts(people: people, visited: [0, 1]), units: units)
        let box = try #require(c.cameraBox)
        #expect(box.maxLongitude - box.minLongitude < 10, "Aleutians→Yorkshire: \(box)")
        #expect(box.maxLatitude - box.minLatitude < 5, "\(box)")
        #expect(box == units.unit(forKey: "eng-yorkshire")?.cameraBox, "Yorkshire alone frames the map")
        let usa = try #require(c.labels.first { $0.key == "usa" })
        #expect(usa.latitude < 45 && usa.longitude > -100, "label in Oregon at (\(usa.latitude), \(usa.longitude))")
        #expect(usa.latitude > 30 && usa.longitude < -90, "the middle of the lower 48: (\(usa.latitude), \(usa.longitude))")
        #expect(c.counts["usa"]?.people == 1, "the country-only person is still counted")
    }

    /// Only country-only counts (nothing finer): the camera still has
    /// somewhere sensible to go — the principal piece of each outline, not
    /// the union of every island.
    @Test func onlyCountryOnlyCountsStillGetASensibleCamera() throws {
        let units = try Self.bundledUnits()
        let usaOnly = try Self.computed(unitKeys: ["usa", "usa"], recorded: ["New England", "USA"], units: units)
        let box = try #require(usaOnly.cameraBox)
        #expect(box == units.unit(forKey: "usa")?.principalBox, "the contiguous US: \(box)")
        #expect(box.minLongitude > -126 && box.maxLongitude < -66 && box.minLatitude > 24 && box.maxLatitude < 50, "\(box)")
        // Two countries, both country-only: the union of their principal pieces.
        let both = try Self.computed(unitKeys: ["usa", "eng"], recorded: ["USA", "England"], units: units)
        let atlantic = try #require(both.cameraBox)
        #expect(atlantic.minLongitude > -126 && atlantic.maxLongitude < 3 && atlantic.maxLatitude < 57, "lower 48 to England: \(atlantic)")
    }

    /// A real walk's mix — Yorkshire, Massachusetts and ~800 "New England"
    /// country-only births — frames Yorkshire…Massachusetts: the Atlantic,
    /// about 70° wide. That is expected and fine. The Aleutians are not.
    @Test func aRealWalkMixFramesTheAtlanticNotThePacific() throws {
        let units = try Self.bundledUnits()
        var keys: [String?] = ["eng-yorkshire", "usa-massachusetts"]
        var recorded = ["Sheffield, Yorkshire, England", "Boston, Massachusetts"]
        for _ in 0..<800 { keys.append("usa"); recorded.append("New England") }
        let c = try Self.computed(unitKeys: keys, recorded: recorded, units: units)
        let box = try #require(c.cameraBox)
        let width = box.maxLongitude - box.minLongitude
        #expect(width > 60 && width < 80, "Yorkshire to Massachusetts, ~70°: \(box)")
        #expect(box.minLongitude > -75 && box.maxLongitude < 1, "\(box)")
        #expect(box.minLatitude > 41 && box.maxLatitude < 55.5, "\(box)")
        #expect(c.totals.countryOnly == 800)
        #expect(c.labels.first?.key == "usa", "the busiest unit is still the outline")
    }

    // MARK: The family's notes fill the tree's gaps (Rick 2026-09-29 23:05)

    /// Mary Christina O'Connor (@I7@ in the real tree) has no birthplace in
    /// the pulled tree, but her birth certificate is in the archive and
    /// CyberBrain carries the birth event with a place. Here: a synthetic
    /// tree with a blank grandmother and a synthetic CyberBrain (never the
    /// real one) — the family's ACTIVE birth event places her; the tree
    /// wins whenever it resolves; a retracted note, an anecdote and a
    /// disputed claim never place anyone; and nothing is written.
    @Test func theFamilysNotesFillATreeGapButNeverOverrideTheTree() async throws {
        let gedcom = """
        0 HEAD
        1 _VS_MERGED Y
        1 _VS_ROOT @I1@
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 BIRT
        2 PLAC Boston, Massachusetts
        1 FAMC @F1@
        0 @I3@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 BIRT
        2 PLAC Fife, Scotland
        1 FAMC @F3@
        1 FAMS @F1@
        0 @I4@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 PLAC Warsaw, Poland
        1 FAMS @F1@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 23 DEC 1904
        1 FAMS @F3@
        0 @I9@ INDI
        1 NAME Patrick /O'Connor/
        1 SEX M
        1 FAMC @F4@
        1 FAMS @F3@
        0 @I10@ INDI
        1 NAME Daniel /O'Connor/
        1 SEX M
        1 FAMS @F4@
        0 @F1@ FAM
        1 HUSB @I3@
        1 WIFE @I4@
        1 CHIL @I1@
        0 @F3@ FAM
        1 HUSB @I9@
        1 WIFE @I7@
        1 CHIL @I3@
        0 @F4@ FAM
        1 HUSB @I10@
        1 CHIL @I9@
        0 TRLR
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ id: String, _ kind: CyberBrainItem.Kind, _ text: String, person: String, place: String?,
                  confidence: CyberBrainItem.Confidence = .confirmed, status: CyberBrainItem.Status = .active,
                  disputes: [String] = [], correction: CyberBrainCorrection? = nil) -> CyberBrainItem {
            CyberBrainItem(id: id, kind: kind, text: text, subjectPersonIDs: [person], place: place,
                           sourceIDs: ["source.bc"], confidence: confidence, privacy: .family, status: status,
                           disputesItemIDs: disputes, createdAt: now, updatedAt: now, correction: correction)
        }
        let archive = CyberBrainArchive(archiveID: "test.map", displayName: "Test", people: [
            // Mary: linked by GEDCOM id. A retracted (wrong) birth note, an
            // anecdote that says "born", then the active birth event.
            CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I7@", canonicalName: "Mary Christina O'Connor",
                             anecdotes: [item("anec.mary", .anecdote, "She was born a storyteller, they said in Boston.", person: "person.mary", place: "Boston, Massachusetts")],
                             lifeEvents: [
                                item("event.mary.wrong", .event, "Mary Christina O'Connor was born in Dublin.", person: "person.mary", place: "Dublin, Ireland",
                                     status: .retracted,
                                     correction: .init(action: .removed, reason: .wrongInformation, at: now, by: "Rick")),
                                item("event.mary.birth", .event, "Mary Christina O'Connor was born 1 January 1900 at 1 Example Lane, Cork; birth certificate in the archive.",
                                     person: "person.mary", place: "Cork, Ireland"),
                             ]),
            // Richard Sr: the tree says Fife; the family's note says Cork. The tree wins.
            CyberBrainPerson(id: "person.richard", gedcomPersonID: "@I3@", canonicalName: "Richard Harding Breen Sr",
                             lifeEvents: [item("event.richard.birth", .event, "Richard Harding Breen Sr was born in Cork, the family says.", person: "person.richard", place: "Cork, Ireland")]),
            // Eileen: the tree's Warsaw is off the map; the family's note places her.
            CyberBrainPerson(id: "person.eileen", gedcomPersonID: "@I4@", canonicalName: "Eileen Latta",
                             lifeEvents: [item("event.eileen.birth", .event, "Eileen Latta was born in Yorkshire; her birth was registered there.", person: "person.eileen", place: "Leeds, Yorkshire, England")]),
            // Patrick: matched by NAME (no GEDCOM link); a disputed birthplace
            // never places anyone (its counter-claim is a note with no place).
            CyberBrainPerson(id: "person.patrick", canonicalName: "Patrick O'Connor",
                             lifeEvents: [item("event.patrick.birth", .event, "Patrick O'Connor was born in Kerry — or Cork; the family disagrees.",
                                               person: "person.patrick", place: "Kerry, Ireland", confidence: .disputed,
                                               disputes: ["note.patrick.counter"])],
                             notes: [item("note.patrick.counter", .note, "Uncle Dan always said Cork, not Kerry.", person: "person.patrick", place: nil)]),
            // Daniel: a life event with a place that is NOT a birth.
            CyberBrainPerson(id: "person.daniel", gedcomPersonID: "@I10@", canonicalName: "Daniel O'Connor",
                             lifeEvents: [item("event.daniel.died", .event, "Died at home in Skibbereen.", person: "person.daniel", place: "Skibbereen, Cork, Ireland")]),
        ], sources: [CyberBrainSource(id: "source.bc", type: .officialRecord, title: "Birth certificate, Cork 1904")])
        let index = try CyberBrainIndex(archive: archive)
        let g = GedcomFamilyGraph(gedcomText: gedcom)
        let knowledge = FamilyTreeNotesResolver(index: index, graph: g)
        #expect(knowledge.cyberBrainPeople(forGedcomID: "@I9@").map(\.id) == ["person.patrick"], "Patrick is attached by name")

        // The pure helper: which note places whom.
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: knowledge) == "Cork, Ireland", "the active birth event, not the retracted one or the anecdote")
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I9@", in: knowledge) == nil, "disputed")
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I10@", in: knowledge) == nil, "a death is not a birth")
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I1@", in: knowledge) == nil, "no notes at all")
        let anyone = CyberBrainPerson(id: "p", canonicalName: "Test Person")
        #expect(FamilyMapModel.isOwnBirthEvent(item("x", .event, "Married Jane Osborne at Birthdale.", person: "p", place: nil), of: anyone) == false, "whole words only")
        #expect(FamilyMapModel.isOwnBirthEvent(item("x", .event, "BIRTH registered late.", person: "p", place: nil), of: anyone) == false,
                "#235: an opener does not say whose birth it is")
        #expect(FamilyMapModel.isOwnBirthEvent(item("x", .event, "Test Person was born late.", person: "p", place: nil), of: anyone),
                "her own name, then 'was born'")

        // Through the real pipeline with the knowledge injected.
        let r = try TreeWalk.walk(g, options: .init(starts: ["@I1@"]))
        let layout = await TreeWalkAnimator.prepare(r, size: CGSize(width: 600, height: 600))
        let highlight = await TreeWalkHighlighter.prepare(result: r, graph: g, layout: layout)
        let inputs = await FamilyMapModel.prepare(result: r, graph: g, highlight: highlight, familyKnowledge: knowledge)
        func key(_ id: String) -> String? { r.ordinal(of: id).flatMap { inputs.people.unitKeys[$0] } }
        func source(_ id: String) -> FamilyMapModel.PlaceSource? { r.ordinal(of: id).map { inputs.placeSources[$0] } }
        func recorded(_ id: String) -> String? { r.ordinal(of: id).flatMap { inputs.people.recordedPlaces[$0] } }
        #expect(key("@I7@") == "irl-cork" && source("@I7@") == .family && recorded("@I7@") == "Cork, Ireland", "Mary: the family's note fills the gap")
        #expect(key("@I3@") == "sct-fife" && source("@I3@") == .tree && recorded("@I3@") == "Fife, Scotland", "the tree wins when it resolves")
        #expect(key("@I4@") == "eng-yorkshire" && source("@I4@") == .family, "Warsaw is off the map; the family's note places her")
        #expect(recorded("@I4@") == "Leeds, Yorkshire, England", "the text that placed her")
        #expect(key("@I1@") == "usa-massachusetts" && source("@I1@") == .tree)
        #expect(key("@I9@") == nil && source("@I9@") == FamilyMapModel.PlaceSource.none && recorded("@I9@") == nil, "disputed: not placed, nothing recorded")
        #expect(key("@I10@") == nil && recorded("@I10@") == nil)
        #expect(inputs.familyPlacedIDs == ["@I7@", "@I4@"])

        let m = FamilyMapModel(inputs: inputs, units: syntheticUnits, displayNames: ["Rick"])
        #expect(m.isPlacedFromFamilyNotes("@I7@") && !m.isPlacedFromFamilyNotes("@I3@"))
        m.apply(selection: .init(), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == r.visitedCount }
        #expect(fields(m.computed.totals) == [6, 4, 0, 2])
        #expect(m.computed.totals.unsupported == 0, "Patrick and Daniel recorded nothing the map could read")
        #expect(m.computed.counts["irl-cork"]?.members.map(\.name) == ["Mary Christina O'Connor"])
        #expect(m.computed.unplaced.map(\.name) == ["Patrick O'Connor", "Daniel O'Connor"])

        // Without the knowledge the same walk leaves Mary and Eileen off the map.
        let bare = await FamilyMapModel.prepare(result: r, graph: g, highlight: highlight, familyKnowledge: nil)
        #expect(r.ordinal(of: "@I7@").flatMap { bare.people.unitKeys[$0] } == nil)
        #expect(r.ordinal(of: "@I4@").flatMap { bare.people.recordedPlaces[$0] } == "Warsaw, Poland", "recorded but off the map")
        #expect(bare.familyPlacedIDs.isEmpty)
        // Read-only: the archive the index was built from is untouched.
        #expect(index.archive == archive)
    }

    /// PRIVACY CEILING (QA round 2, 2026-09-29). The map is a family-facing
    /// surface — Donna and the relatives see it — so a family note places
    /// someone only when its privacy is visible at `.family`: a `.private`
    /// birth event never places anyone and never reaches the panel. Rick
    /// can raise the ceiling later (`FamilyMapModel.privacyCeiling`; design
    /// decision noted for the morning); the twin below pins that `.family`
    /// DOES place.
    @Test func aPrivateBirthNoteNeverPlacesAnyone() throws {
        let gedcom = """
        0 HEAD
        1 _VS_MERGED Y
        1 _VS_ROOT @I1@
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMC @F1@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 FAMS @F1@
        0 @F1@ FAM
        1 WIFE @I7@
        1 CHIL @I1@
        0 TRLR
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func knowledge(privacy: CyberBrainItem.Privacy) throws -> FamilyTreeNotesResolver {
            let item = CyberBrainItem(id: "event.mary.birth", kind: .event,
                                      text: "Mary Christina O'Connor was born 1 January 1900 at 1 Example Lane, Cork.", subjectPersonIDs: ["person.mary"],
                                      place: "Cork, Ireland", sourceIDs: ["source.bc"], confidence: .confirmed, privacy: privacy,
                                      status: .active, disputesItemIDs: [], createdAt: now, updatedAt: now, correction: nil)
            let archive = CyberBrainArchive(archiveID: "test.map.privacy", displayName: "Test", people: [
                CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I7@", canonicalName: "Mary Christina O'Connor", lifeEvents: [item]),
            ], sources: [CyberBrainSource(id: "source.bc", type: .officialRecord, title: "Birth certificate, Cork 1904")])
            return FamilyTreeNotesResolver(index: try CyberBrainIndex(archive: archive), graph: GedcomFamilyGraph(gedcomText: gedcom))
        }
        #expect(FamilyMapModel.privacyCeiling == .family)
        let k = try knowledge(privacy: .private)
        #expect(k.cyberBrainPeople(forGedcomID: "@I7@").count == 1, "she IS linked; the item is just private")
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: k) == nil, "a private note never places anyone")
        // Through the pipeline: not placed, nothing recorded, not in the panel.
        let g = GedcomFamilyGraph(gedcomText: gedcom)
        let r = try TreeWalk.walk(g, options: .init(starts: ["@I1@"]))
        let inputs = FamilyMapModel.inputs(ids: r.ids, names: r.names, surnames: r.ids.map { _ in "" },
                                           surnameKeys: r.ids.map { _ in "" },
                                           birthPlaces: r.ids.map { _ in nil },
                                           familyPlaces: r.ids.map { FamilyMapModel.familyBirthPlace(gedcomID: $0, in: k) },
                                           birthYears: r.ids.map { _ in nil }, generations: r.ids.map { _ in 0 },
                                           lines: r.ids.map { _ in .first }, visited: Array(r.ids.indices),
                                           regions: r.ids.map { _ in .unknown })
        let o = try #require(r.ordinal(of: "@I7@"))
        #expect(inputs.people.unitKeys[o] == nil && inputs.people.recordedPlaces[o] == nil)
        #expect(inputs.familyPlacedIDs.isEmpty && inputs.familyRecordedIDs.isEmpty)
    }

    @Test func aFamilyVisibleBirthNoteDoesPlace() throws {
        let gedcom = """
        0 HEAD
        1 _VS_MERGED Y
        1 _VS_ROOT @I1@
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMC @F1@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 FAMS @F1@
        0 @F1@ FAM
        1 WIFE @I7@
        1 CHIL @I1@
        0 TRLR
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func knowledge(privacy: CyberBrainItem.Privacy) throws -> FamilyTreeNotesResolver {
            let item = CyberBrainItem(id: "event.mary.birth", kind: .event,
                                      text: "Mary Christina O'Connor was born 1 January 1900 at 1 Example Lane, Cork.", subjectPersonIDs: ["person.mary"],
                                      place: "Cork, Ireland", sourceIDs: ["source.bc"], confidence: .confirmed, privacy: privacy,
                                      status: .active, disputesItemIDs: [], createdAt: now, updatedAt: now, correction: nil)
            let archive = CyberBrainArchive(archiveID: "test.map.privacy", displayName: "Test", people: [
                CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I7@", canonicalName: "Mary Christina O'Connor", lifeEvents: [item]),
            ], sources: [CyberBrainSource(id: "source.bc", type: .officialRecord, title: "Birth certificate, Cork 1904")])
            return FamilyTreeNotesResolver(index: try CyberBrainIndex(archive: archive), graph: GedcomFamilyGraph(gedcomText: gedcom))
        }
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: try knowledge(privacy: .family)) == "Cork, Ireland")
        #expect(FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: try knowledge(privacy: .public)) == "Cork, Ireland",
                "public is visible at the family ceiling too")
    }

    /// "Not on the map" says WHOSE text failed to resolve (QA round 2): a
    /// family note the map could not read is "from the family's notes:
    /// Warsaw, Poland", never "recorded as Warsaw" when the TREE recorded
    /// nothing. The tree's own text stays "recorded as …".
    @Test func anUnplacedFamilyNoteIsToldApartFromTheTreesText() throws {
        // 0: tree blank, family note off the map → the family's text, unplaced.
        // 1: tree off the map, no family note → the tree's text, unplaced.
        // 2: tree off the map, family note off the map → the tree's text (tree first).
        // 3: tree blank, family note resolves → placed from the family's notes.
        // 4: tree resolves → placed from the tree; the family note is never read.
        let ids = ["@A@", "@B@", "@C@", "@D@", "@E@"]
        let inputs = FamilyMapModel.inputs(
            ids: ids, names: ["A", "B", "C", "D", "E"], surnames: ["", "", "", "", ""], surnameKeys: ["", "", "", "", ""],
            birthPlaces: [nil, "Warsaw, Poland", "Gdansk, Poland", "   ", "Fife, Scotland"],
            familyPlaces: ["Warsaw, Poland", nil, "Minsk, Belarus", "Cork, Ireland", "Cork, Ireland"],
            birthYears: [nil, nil, nil, nil, nil], generations: [1, 1, 1, 1, 1],
            lines: [.first, .first, .first, .first, .first], visited: [0, 1, 2, 3, 4],
            regions: [.unknown, .unknown, .unknown, .unknown, .unknown])
        #expect(inputs.people.unitKeys == [nil, nil, nil, "irl-cork", "sct-fife"])
        #expect(inputs.people.recordedPlaces == ["Warsaw, Poland", "Warsaw, Poland", "Gdansk, Poland", "Cork, Ireland", "Fife, Scotland"])
        #expect(inputs.familyRecordedIDs == ["@A@", "@D@"], "whose recorded text came from the family's notes")
        #expect(inputs.familyPlacedIDs == ["@D@"], "…and who was actually placed by them")
        let m = FamilyMapModel(inputs: inputs, units: syntheticUnits, displayNames: ["Rick"])
        #expect(m.isRecordedFromFamilyNotes("@A@") && !m.isPlacedFromFamilyNotes("@A@"))
        #expect(!m.isRecordedFromFamilyNotes("@B@") && !m.isRecordedFromFamilyNotes("@C@"))
        #expect(m.isRecordedFromFamilyNotes("@D@") && m.isPlacedFromFamilyNotes("@D@"))
        #expect(!m.isRecordedFromFamilyNotes("@E@"))
        // The row text the panel shows for each unplaced person.
        func note(_ id: String) -> String? {
            let o = ids.firstIndex(of: id)!
            return FamilyMapModel.placeNote(recordedPlace: inputs.people.recordedPlaces[o], fromFamilyNotes: m.isRecordedFromFamilyNotes(id))
        }
        #expect(note("@A@") == "from the family's notes: Warsaw, Poland")
        #expect(note("@B@") == "recorded as Warsaw, Poland")
        #expect(note("@C@") == "recorded as Gdansk, Poland")
        // And the view asks the model, not a constant `false`, for the unplaced rows.
        let view = try SourceTree.appSource(named: "FamilyTreeMapView.swift")
        #expect(view.contains("fromFamilyNotes: model.isRecordedFromFamilyNotes(m.id)"), "the unplaced row names its source")
        #expect(!view.contains("fromFamilyNotes: false"))
    }

    // MARK: Scale — 40k people, every birthplace resolved once, < 300 ms

    @Test func buildingTheInputsFor40kPeopleStaysUnderBudget() throws {
        let n = 40_000
        let places: [String?] = ["Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
                                 "England", "Fife, Scotland", "Cardiff, Glamorgan, Wales", nil, "Warsaw, Poland",
                                 "Halifax, Nova Scotia, Canada", "Cork, Ireland", "Providence, Rhode Island", "Lowell Mass. U.S.A.",
                                 "Perth, WA, Australia"]
        let family = ["Breen", "Lamb", "Latta", "McGill", "Hudson", "Stone", "Hill", "Adams", "Alden", "Bradford",
                      "Brewster", "Standish", "Winslow", "Howland", "Warren", "Fuller", "Cooke", "Allerton", "Chilton",
                      "Eaton", "Hopkins", "Mullins", "Priest", "Rogers", "Soule", "Tilley", "White", "Billington"]
        let surnames = (0..<n).map { family[$0 % family.count] }
        let ids = (0..<n).map { "@I\($0)@" }
        let names = (0..<n).map { "P\($0)" }
        let keys = TreeWalkHighlight.surnameKeys(surnames)       // the Highlight's, computed once per walk already
        let birthPlaces = (0..<n).map { places[$0 % places.count] }
        let years = (0..<n).map { Optional(1500 + $0 % 400) }
        let generations = (0..<n).map { Optional($0 % 20) }
        let lines = (0..<n).map { TreeWalk.Line.allCases[$0 % 3] }
        let regions = [BirthplaceClassifier.BirthRegion](repeating: .unknown, count: n)
        let visited = Array(0..<n)

        let clock = ContinuousClock()
        let t0 = clock.now
        let inputs = FamilyMapModel.inputs(ids: ids, names: names, surnames: surnames, surnameKeys: keys,
                                           birthPlaces: birthPlaces, birthYears: years, generations: generations,
                                           lines: lines, visited: visited, regions: regions)
        let took = clock.now - t0
        let ceiling = PerformanceLane.loadAwareDebugCeiling(.milliseconds(300))
        #expect(took < ceiling, "40k inputs took \(took) (\(PerformanceLane.loadDescription()))")
        #expect(inputs.people.count == n)
        let resolved = inputs.people.unitKeys.compactMap { $0 }.count
        // 9 of the 12 spellings resolve (nil, Poland and Australia do not);
        // 40,000 is not a multiple of 12, so count the cycle exactly.
        let resolving: Set<Int> = [0, 1, 2, 3, 4, 7, 8, 9, 10]
        let expected = (0..<n).reduce(0) { $0 + (resolving.contains($1 % places.count) ? 1 : 0) }
        #expect(resolved == expected, "\(resolved) resolved, expected \(expected)")
        #expect(inputs.people.unitKeys[1] == "usa-massachusetts")
        #expect(inputs.people.unitKeys[11] == nil, "Perth, WA, Australia is not Washington")

        // The tally over the same 40k, off the model's hot path: coarse ceiling.
        let t1 = clock.now
        let r = try FamilyMapTally.counts(people: inputs.people, visited: visited)
        let tally = clock.now - t1
        #expect(tally < PerformanceLane.loadAwareDebugCeiling(.milliseconds(200)), "40k tally took \(tally)")
        #expect(r.totals.considered == n && r.totals.resolved == resolved)
        let c = FamilyMapModel.computed(from: r, units: syntheticUnits)
        #expect(c.labels.count <= FamilyMapModel.labelLimit)
        #expect(c.labels.count == 4, "only the units the synthetic border set knows get a label: eng, eng-yorkshire, sct-fife, usa-massachusetts")
        #expect(c.labels.map(\.key).sorted() == ["eng", "eng-yorkshire", "sct-fife", "usa-massachusetts"])
        #expect(c.counts.count == 8, "every resolved key is tallied even when the border set lacks it (Boston and Lowell share usa-massachusetts)")
    }

    // MARK: Scale — 100k people (2.5× the real tree), thread CPU time (GH #208)

    /// The whole model build at 100k: every place resolved once, the
    /// columns packed and interned, then one tally and the published
    /// bundle. CPU time of the calling thread, so a busy host stretches
    /// the wall clock without failing this; the budgets are ~3× the
    /// quiet Debug measurement (2026-09-29, M4 Max: inputs ≈ 190 ms,
    /// tally ≈ 45 ms). O(people) is the contract — a regression to
    /// O(people × units) or a per-person allocation storm trips it.
    @Test func buildingAndTallying100kPeopleStaysUnderBudget() throws {
        let n = 100_000
        let places: [String?] = ["Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
                                 "England", "Fife, Scotland", "Cardiff, Glamorgan, Wales", nil, "Warsaw, Poland",
                                 "Halifax, Nova Scotia, Canada", "Cork, Ireland", "Providence, Rhode Island", "Lowell Mass. U.S.A.",
                                 "Perth, WA, Australia", "United States", "Co. Antrim, Northern Ireland", "Toronto, Ontario, Canada"]
        let family = ["Breen", "Lamb", "Latta", "McGill", "Hudson", "Stone", "Hill", "Adams", "Alden", "Bradford",
                      "Brewster", "Standish", "Winslow", "Howland", "Warren", "Fuller", "Cooke", "Allerton", "Chilton",
                      "Eaton", "Hopkins", "Mullins", "Priest", "Rogers", "Soule", "Tilley", "White", "Billington"]
        let surnames = (0..<n).map { family[($0 * 7919) % family.count] }
        let ids = (0..<n).map { "@I\($0)@" }
        let names = (0..<n).map { "P\($0)" }
        let keys = TreeWalkHighlight.surnameKeys(surnames)
        let birthPlaces = (0..<n).map { places[$0 % places.count] }
        let years = (0..<n).map { $0 % 11 == 0 ? nil : Optional(1500 + $0 % 400) }
        let generations = (0..<n).map { Optional($0 % 24) }
        let lines = (0..<n).map { TreeWalk.Line.allCases[$0 % 3] }
        let regions = [BirthplaceClassifier.BirthRegion](repeating: .unknown, count: n)
        let visited = Array(0..<n)

        var inputs: FamilyMapModel.Inputs?
        var inputsWall: Duration = .zero
        let inputsCPU = PerformanceLane.measureThreadCPUTime {
            inputsWall = ContinuousClock().measure {
                inputs = FamilyMapModel.inputs(ids: ids, names: names, surnames: surnames, surnameKeys: keys,
                                               birthPlaces: birthPlaces, birthYears: years, generations: generations,
                                               lines: lines, visited: visited, regions: regions)
            }
        }
        let built = try #require(inputs)
        var result: FamilyMapTally.Result?
        var computed: FamilyMapModel.Computed?
        let tallyCPU = PerformanceLane.measureThreadCPUTime {
            result = try? FamilyMapTally.counts(people: built.people, visited: visited, unplacedLimit: FamilyMapModel.unplacedLimit)
            computed = result.map { FamilyMapModel.computed(from: $0, units: syntheticUnits) }
        }
        print("[family-map] 100k inputs: cpu \(inputsCPU), wall \(inputsWall); tally+computed: cpu \(tallyCPU) (\(PerformanceLane.loadDescription()))")
        #expect(inputsCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(600)),
                "100k inputs took \(inputsCPU) cpu / \(inputsWall) wall (\(PerformanceLane.loadDescription()))")
        #expect(tallyCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(150)),
                "100k tally took \(tallyCPU) cpu (\(PerformanceLane.loadDescription()))")

        // Correctness at scale: 12 of the 15 spellings resolve (nil, Poland
        // and Australia do not), 100,000 is not a multiple of 15.
        let resolving: Set<Int> = [0, 1, 2, 3, 4, 7, 8, 9, 10, 12, 13, 14]
        let expected = (0..<n).reduce(0) { $0 + (resolving.contains($1 % places.count) ? 1 : 0) }
        let r = try #require(result)
        #expect(built.people.count == n)
        #expect(r.totals.considered == n && r.totals.resolved == expected, "\(r.totals.resolved) resolved, expected \(expected)")
        #expect(r.totals.unsupported == (0..<n).reduce(0) { $0 + ([6, 11].contains($1 % places.count) ? 1 : 0) })
        #expect(r.counts.count == 11, "eng-yorkshire, usa-massachusetts, eng, sct-fife, wls-glamorgan, can-nova-scotia, irl-cork, usa-rhode-island, usa, nir-antrim, can-ontario")
        let c = try #require(computed)
        #expect(c.shades.count == r.counts.count)
        #expect(c.labels.map(\.key).sorted() == ["eng", "eng-yorkshire", "sct-fife", "usa", "usa-massachusetts"],
                "only the synthetic border set's units get a label")
        #expect(c.unplaced.count == FamilyMapModel.unplacedLimit)
    }

    // MARK: Isolation — no App Support, no network; synthetic units only

    @Test func theModelAndTheViewReadNoAppSupportAndNoNetwork() throws {
        for name in ["FamilyMapModel.swift", "FamilyTreeMapView.swift"] {
            let src = try SourceTree.appSource(named: name)
            for forbidden in ["applicationSupportDirectory", "NSHomeDirectory", "URLSession", "MKDirections",
                              "MKLocalSearch", "CLLocationManager", "UserDefaults"] {
                #expect(!src.contains(forbidden), "\(name) must not use \(forbidden)")
            }
        }
        // The only file that may touch the bundle is the cache, by resource name.
        let model = try SourceTree.appSource(named: "FamilyMapModel.swift")
        #expect(model.contains("Bundle.main.url(forResource: \"family-map-units\", withExtension: \"geojson\")"))
        // The family's notes are READ; the map never writes CyberBrain. The
        // only `write(` allowed is the app log line (counts, never names).
        let scrubbed = model.replacingOccurrences(of: "appLog.write(", with: "")
        for forbidden in ["CyberBrainWriter", "CyberBrainLoader", "FamilyTreeNotesStorage", "record(", "write("] {
            #expect(!scrubbed.contains(forbidden), "FamilyMapModel.swift must not use \(forbidden)")
        }
        // The family's notes are read at the FAMILY privacy ceiling, never
        // through the owner-only `allActiveItems` alone (QA round 2).
        #expect(model.contains("isVisible(at: privacyCeiling)"), "the privacy ceiling gates the family's notes")
        // Errors are logged, not only shown (QA round 2): one line each,
        // "Family map: …", through the app's log sink.
        #expect(model.contains("appLog.write(\"Family map: "), "a tally failure reaches the log")
        let sheet = try SourceTree.appSource(named: "FamilyTreeWalkSheet.swift")
        #expect(sheet.contains("appLog.write(\"Family map: "), "a failure to show the map reaches the log")
        #expect(sheet.contains("familyKnowledge: familyKnowledge"), "the sheet hands the map the tree's own resolver")
        #expect(!sheet.contains("CyberBrainWriter"))
        #expect(!sheet.contains("map.apply("), "bind(to:) is the sheet's one tally; no second apply")
        let view = try SourceTree.appSource(named: "FamilyTreeMapView.swift")
        #expect(!view.contains("Bundle.main"), "the view is handed its units; it never loads them")
    }

    // MARK: Sensors

    /// No O(people) work in a body: the view never resolves a place or
    /// tallies; it reads what the model published.
    @Test func theMapViewNeverResolvesOrTalliesInABody() throws {
        let view = try SourceTree.appSource(named: "FamilyTreeMapView.swift")
        #expect(!view.contains("BirthplaceUnitResolver"), "resolving belongs to FamilyMapModel.prepare")
        #expect(!view.contains("FamilyMapTally.counts"), "the tally belongs to FamilyMapModel.apply")
        #expect(!view.contains("FamilyMapModel.prepare"), "the sheet builds the model, once per walk")
        #expect(view.contains("mapKitLinkAnchor()"), "the MapKit link anchor is called from the body")
        #expect(view.contains(".mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))"))
        // And the model resolves ONCE per walk — inside `inputs`, nowhere else.
        let model = try SourceTree.appSource(named: "FamilyMapModel.swift")
        #expect(model.components(separatedBy: "BirthplaceUnitResolver.resolve(").count == 2, "exactly one call site")
    }

    /// The bundled border file is copied into the built app and decodes.
    /// Runs only when the test bundle is hosted in VideoScan.app; a bare
    /// test host has no such resource and the test says so instead of
    /// pretending.
    @Test func theBundledBorderFileIsInTheBuiltApp() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            print("FamilyMapModelTests: not hosted in the app (\(Bundle.main.bundleURL.lastPathComponent)) — bundled-file check skipped")
            return
        }
        let url = try #require(FamilyMapUnitsCache.bundledURL, "family-map-units.geojson is not in \(Bundle.main.bundleURL.path)/Contents/Resources")
        #expect(url.lastPathComponent == "family-map-units.geojson")
        let units = try await FamilyMapUnitsCache.shared.units()
        #expect(units.count == 254, "the bundled unit set (FamilyMapBundledDataTests pins the same number)")
        #expect(units.unit(forKey: "eng-yorkshire") != nil)
        // Loaded once per process: the second call is the same decoded set.
        let again = try await FamilyMapUnitsCache.shared.units()
        #expect(again.count == units.count)
    }

    /// The About window carries the acknowledgement the Historic Counties
    /// Trust asks for, and Natural Earth's, word for word from ATTRIBUTION.txt.
    @Test func theAboutWindowCreditsTheBorderData() throws {
        let attribution = try String(contentsOf: SourceTree.appSourceRoot
            .appendingPathComponent("Resources/FamilyMap/ATTRIBUTION.txt"), encoding: .utf8)
        let line = AboutView.familyMapAttribution
        #expect(line.contains("This mapping made use of data provided by the Historic County Borders Project."))
        #expect(line.contains("Made with Natural Earth."))
        #expect(attribution.contains("This mapping made use of data provided by the Historic County Borders Project."))
        #expect(attribution.contains("Made with Natural Earth."))
        let about = try SourceTree.appSource(named: "VideoScanApp.swift")
        #expect(about.contains("Text(AboutView.familyMapAttribution)"), "the line is rendered in the About view")
    }
}
