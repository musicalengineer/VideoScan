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
//               resolved once) stays under 300 ms in Debug, load-aware.
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
/// US state, no place at all (Donna), and a place off the map (Germany).
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
2 PLAC Berlin, Germany
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
        #expect(key("@I8@") == nil, "Germany is off the map")

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
        #expect(FamilyMapModel.totalsLine(t) == "4 of 6 people placed; 1 country-only; 2 with no recorded place")

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
    /// so a return from the fan to the map is already current.
    @Test func theModelFollowsTheHighlighterChecks() async throws {
        let (m, h, _, _) = try await mapModel(for: placedRoots)
        m.bind(to: h)
        m.apply(selection: h.selection, yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 6 }
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

    @Test func aClickSelectsTheUnitUnderItOrTheNearestCoastAndOnlyOneWithACount() async throws {
        let (m, _, _, _) = try await mapModel(for: placedRoots)
        m.apply(selection: .init(), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 6 }

        m.select(coordinate: .init(latitude: 54, longitude: -1))           // inside Yorkshire (and England)
        #expect(m.selectedKey == "eng-yorkshire", "the smaller box wins the overlap")
        #expect(m.selectedUnit?.name == "Yorkshire")
        #expect(m.selectedCount?.people == 1)

        m.select(coordinate: .init(latitude: 51, longitude: -1))           // England, outside Yorkshire
        #expect(m.selectedKey == "eng")

        m.select(coordinate: .init(latitude: 40, longitude: -100))         // the US outline: no count → nothing
        #expect(m.selectedKey == nil)

        m.select(coordinate: .init(latitude: 56.55, longitude: -3))        // just off Fife's north coast
        #expect(m.selectedKey == "sct-fife", "the nearest-boundary fallback")

        m.select(coordinate: .init(latitude: 0, longitude: 0))             // open sea
        #expect(m.selectedKey == nil)

        m.select(unitKey: "usa-massachusetts")
        #expect(m.selectedKey == "usa-massachusetts")
        m.select(unitKey: "no-such-unit")
        #expect(m.selectedKey == nil)

        // A selection that narrows the map away from the selected unit
        // clears the selection rather than showing a stale panel.
        m.select(unitKey: "sct-fife")
        m.apply(selection: .init(surnames: ["breen"]), yearCeiling: nil)
        try await waitUntil { m.computed.totals.considered == 2 }
        #expect(m.selectedKey == nil)
    }

    @Test func shadesLabelsCameraAndPanelLinesArePinned() {
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
        // The totals line, singular and plural.
        #expect(M.totalsLine(considered: 1, resolved: 1, countryOnly: 0, unresolved: 0)
                == "1 of 1 person placed; 0 country-only; 0 with no recorded place")
        #expect(M.totalsLine(considered: 39_249, resolved: 24_500, countryOnly: 20_284, unresolved: 14_749)
                == "24,500 of 39,249 people placed; 20,284 country-only; 14,749 with no recorded place")
        // The camera region: padded, never tighter than 0.6°, never wider than the world.
        let box = FamilyMap.BoundingBox(minLatitude: 50, maxLatitude: 58, minLongitude: -8, maxLongitude: 2)
        let r = FamilyTreeMapView.cameraRegion(for: box)
        #expect(r == .init(centerLatitude: 54, centerLongitude: -3, latitudeDelta: 10, longitudeDelta: 12.5))
        let tiny = FamilyTreeMapView.cameraRegion(for: .init(minLatitude: 56.1, maxLatitude: 56.5, minLongitude: -3.5, maxLongitude: -2.5))
        #expect(tiny.latitudeDelta == 0.6 && tiny.longitudeDelta == 1.25)
        let world = FamilyTreeMapView.cameraRegion(for: .init(minLatitude: -80, maxLatitude: 80, minLongitude: -179, maxLongitude: 179))
        #expect(world.latitudeDelta == 170 && world.longitudeDelta == 340)
        // The count line: a county names its country; a country outline says what is missing.
        let york = syntheticUnits.unit(forKey: "eng-yorkshire")!
        #expect(FamilyTreeMapView.countLine(unit: york, count: 42) == "42 people born in Yorkshire, England")
        #expect(FamilyTreeMapView.countLine(unit: york, count: 1) == "1 person born in Yorkshire, England")
        #expect(FamilyTreeMapView.countLine(unit: syntheticUnits.unit(forKey: "eng")!, count: 7)
                == "7 people born in England, county not recorded")
        #expect(FamilyTreeMapView.countLine(unit: syntheticUnits.unit(forKey: "usa")!, count: 7)
                == "7 people born in United States, state not recorded")
        // A synthetic unit set gets one stable fingerprint (the MKPolygon cache key).
        #expect(FamilyMapShapes.fingerprint(syntheticUnits) == FamilyMapShapes.fingerprint(syntheticUnits))
        #expect(FamilyMapShapes.fingerprint(syntheticUnits) == "5/eng/usa-massachusetts/20")
    }

    // MARK: Scale — 40k people, every birthplace resolved once, < 300 ms

    @Test func buildingTheInputsFor40kPeopleStaysUnderBudget() throws {
        let n = 40_000
        let places: [String?] = ["Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
                                 "England", "Fife, Scotland", "Cardiff, Glamorgan, Wales", nil, "Berlin, Germany",
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
        // 9 of the 12 spellings resolve (nil, Germany and Australia do not);
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
        #expect(units.count == 189, "the bundled unit set (FamilyMapBundledDataTests pins the same number)")
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
