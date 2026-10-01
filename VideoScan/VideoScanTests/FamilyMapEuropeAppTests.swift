// FamilyMapEuropeAppTests.swift
// The Western Europe stage of the family map, app side (GH #227 + the
// #229 card flags; Rick 2026-09-30: "Countries + regions").
//   LOGIC     the card flag and the map agree for every European place
//             (one decision, `FamilyMapModel.place`); historic names fly
//             today's flag with an honest tooltip ("Born in … Prussia ·
//             shown under today's flag"); the panel's count line says
//             "region / state / province unresolved" for a country with
//             subdivisions and nothing extra for an outline-only country.
//   SELECTION a click just inside counted Belgium is Belgium, never the
//             French région a few km away; a coastal click inside France
//             still reaches the nearby French région (the Halifax rule).
//   CAMERA    a walk with European births frames Europe; one without is
//             framed exactly as before.
//   SCALE     100k people with European places through the map's inputs
//             and the card-flag build, thread CPU against load-aware
//             ceilings (GH #208).
// Synthetic units and made-up places/names only — no bundled file, no
// network, no personal data.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func box(_ key: String, _ country: FamilyMap.Country, _ kind: FamilyMap.UnitKind,
                 lat: ClosedRange<Double>, lon: ClosedRange<Double>) -> FamilyMapUnits.Unit {
    let ring = [FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.lowerBound),
                FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.upperBound),
                FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.upperBound),
                FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.lowerBound)]
    return FamilyMapUnits.Unit(key: key, name: key, country: country, kind: kind,
                               polygons: [FamilyMapUnits.Polygon(outer: ring)])
}

/// England + Yorkshire; France with one région (Hauts-de-France) whose
/// eastern edge is the Belgian border at lon 3; Belgium east of it; Italy.
private let europeUnits = FamilyMapUnits(units: [
    box("eng", .england, .country, lat: 50...56, lon: -6...2),
    box("eng-yorkshire", .england, .county, lat: 53...55, lon: -2...0),
    box("fra", .france, .country, lat: 42...51, lon: -5...3),
    box("fra-hauts-de-france", .france, .region, lat: 49...51, lon: 1...3),
    box("bel", .belgium, .country, lat: 49.5...51.5, lon: 3...6),
    box("ita", .italy, .country, lat: 36...47, lon: 6...19),
])

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within 2 s")
}

@MainActor
private func model(places: [String?], units: FamilyMapUnits = europeUnits) async throws -> FamilyMapModel {
    let n = places.count
    let surnames = (0..<n).map { "Family\($0 % 5)" }
    let inputs = FamilyMapModel.inputs(
        ids: (0..<n).map { "@E\($0)@" }, names: (0..<n).map { "Person \($0)" }, surnames: surnames,
        surnameKeys: TreeWalkHighlight.surnameKeys(surnames), birthPlaces: places,
        birthYears: [Int?](repeating: 1850, count: n), generations: (0..<n).map { Optional($0 % 6) },
        lines: (0..<n).map { TreeWalk.Line.allCases[$0 % 3] }, visited: Array(0..<n),
        regions: [BirthplaceClassifier.BirthRegion](repeating: .unknown, count: n))
    let m = FamilyMapModel(inputs: inputs, units: units, displayNames: ["Rick", "Donna"])
    m.apply(selection: .init(), yearCeiling: nil)
    try await waitUntil { m.computed.totals.considered == n }
    return m
}

@Suite("FamilyMap Western Europe — app (#227/#229)")
@MainActor
struct FamilyMapEuropeAppTests {

    static let europeanPlaces: [String?] = [
        "Rouen, Seine-Maritime, Haute-Normandie, France",
        "Of France",
        "Koblenz, Rhineland, Prussia",
        "Stuttgart, Württemberg, Germany",
        "Breda, Noord-Brabant, Nederland",
        "Mons, Hainaut, België",
        "Some Village, Denmark",
        "Napoli, Italy",
        "ENGLAND OR Wales or France",
        "Warsaw, Poland",
    ]

    // MARK: Logic — the card and the map agree

    @Test func theCardFlagAndTheMapAgreeForEveryEuropeanPlace() {
        let places = Self.europeanPlaces
        let ids = (0..<places.count).map { "@E\($0)@" }
        let flags = FamilyTreeBirthCountries.build(ids: ids, treePlaces: places)
        let inputs = FamilyMapModel.inputs(
            ids: ids, names: ids, surnames: ids.map { _ in "" }, surnameKeys: ids.map { _ in "" },
            birthPlaces: places, birthYears: ids.map { _ in nil }, generations: ids.map { _ in 1 },
            lines: ids.map { _ in .first }, visited: Array(0..<ids.count),
            regions: ids.map { _ in .unknown })
        let expected: [FamilyMap.Country?] = [.france, .france, .germany, .germany, .netherlands, .belgium,
                                              .denmark, .italy, nil, nil]
        for (i, id) in ids.enumerated() {
            let mapCountry = inputs.people.unitKeys[i].flatMap { FamilyMapKey.country(of: $0) }
            #expect(flags[id]?.country == expected[i], "card: \(places[i] ?? "nil")")
            #expect(mapCountry == expected[i], "map: \(places[i] ?? "nil")")
            #expect(flags[id]?.country == mapCountry, "card and map disagree on \(places[i] ?? "nil")")
        }
        #expect(inputs.people.unitKeys[0] == "fra-normandy", "an old région folds into today's")
        #expect(inputs.people.unitKeys[2] == "deu", "Rhineland under Prussia: Germany, no single Land")
        #expect(flags["@E0@"]?.emoji == "🇫🇷" && flags["@E2@"]?.emoji == "🇩🇪" && flags["@E5@"]?.emoji == "🇧🇪")
        // The alternative and the off-map place: recorded, no flag, not placed.
        #expect(flags["@E8@"] == nil && flags["@E9@"] == nil)
        #expect(inputs.people.recordedPlaces[8] == "ENGLAND OR Wales or France", "kept as recorded for 'Not on the map'")
    }

    /// Today's flag, honestly labelled: the card says what was recorded,
    /// and the map's member row says "recorded as …".
    @Test func historicNamesFlyTodaysFlagWithAnHonestTooltip() throws {
        let flags = FamilyTreeBirthCountries.build(ids: ["@P@"], treePlaces: ["Koblenz, Rhineland, Prussia"])
        let flag = try #require(flags["@P@"])
        #expect(flag.country == .germany && flag.emoji == "🇩🇪")
        #expect(flag.tooltip == "Born in Koblenz, Rhineland, Prussia · shown under today's flag")
        #expect(flag.accessibilityLabel == "Germany")
        #expect(FamilyMapModel.placeNote(recordedPlace: "Koblenz, Rhineland, Prussia", fromFamilyNotes: false)
                == "recorded as Koblenz, Rhineland, Prussia")
    }

    @Test func theCountLineIsHonestForEachKindOfCountry() {
        func line(_ key: String, _ country: FamilyMap.Country, _ count: Int) -> String {
            FamilyTreeMapView.countLine(unit: box(key, country, .country, lat: 0...1, lon: 0...1), count: count)
        }
        // The box helper names a unit by its key; the line uses the unit's name.
        #expect(line("ita", .italy, 8) == "8 people born in ita", "outline-only: nothing finer to resolve")
        #expect(line("fra", .france, 3) == "3 people born in fra, region unresolved")
        #expect(line("deu", .germany, 1) == "1 person born in deu, state unresolved")
        #expect(line("bel", .belgium, 2) == "2 people born in bel, province unresolved")
        #expect(line("eng", .england, 5) == "5 people born in eng, county unresolved", "unchanged")
        let normandy = box("fra-normandy", .france, .region, lat: 0...1, lon: 0...1)
        #expect(FamilyTreeMapView.countLine(unit: normandy, count: 2) == "2 people born in fra-normandy, France")
    }

    // MARK: Selection across a land border

    @Test func aClickInsideCountedBelgiumIsBelgiumNotTheFrenchRegionNextDoor() async throws {
        let m = try await model(places: ["Lille, Nord, France", "Some Village, Belgium", "Napoli, Italy"])
        #expect(Set(m.computed.counts.keys) == ["fra-hauts-de-france", "bel", "ita"])
        // 0.05° inside Belgium, within the 0.15° coastal tolerance of the région.
        m.select(coordinate: .init(latitude: 50.5, longitude: 3.05))
        #expect(m.selectedKey == "bel", "a different country's counted outline holds the point")
        // Inside the région itself: the région.
        m.select(coordinate: .init(latitude: 50.5, longitude: 2.5))
        #expect(m.selectedKey == "fra-hauts-de-france")
        // Inside France's (uncounted) outline, just outside the région: the
        // région still wins (the Halifax rule) — same country.
        m.select(unitKey: nil)
        m.select(coordinate: .init(latitude: 48.95, longitude: 2.0))
        #expect(m.selectedKey == "fra-hauts-de-france")
        // Italy: outline-only, its own outline.
        m.select(coordinate: .init(latitude: 41.9, longitude: 12.5))
        #expect(m.selectedKey == "ita")
    }

    // MARK: Camera

    @Test func aWalkWithEuropeanBirthsFramesEuropeAndOneWithoutIsUnchanged() async throws {
        let withEurope = try await model(places: ["Sheffield, Yorkshire, England", "Napoli, Italy"])
        let camera = try #require(withEurope.computed.cameraBox)
        #expect(camera.maxLongitude == 19 && camera.minLatitude == 36, "Italy is in the frame: \(camera)")
        #expect(camera.minLongitude == -2 && camera.maxLatitude == 55, "and so is Yorkshire")

        let without = try await model(places: ["Sheffield, Yorkshire, England", "England"])
        let legacy = try #require(without.computed.cameraBox)
        #expect(legacy == europeUnits.unit(forKey: "eng-yorkshire")?.cameraBox,
                "no Europe: the county frames the map, the outline does not widen it")
    }

    // MARK: Scale — 100k people with European places

    @Test func oneHundredThousandEuropeanPeopleThroughTheMapAndTheFlags() throws {
        let n = 100_000
        let mix: [String?] = Self.europeanPlaces + [
            "Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
            nil, "Lyon, Rhône, Auvergne-Rhône-Alpes, France", "Brittany, France", "Bayern",
        ]
        let ids = (0..<n).map { "@I\($0)@" }
        let places = (0..<n).map { i -> String? in
            guard let p = mix[i % mix.count] else { return nil }
            return i % 4 == 0 ? "Hamlet \(i), " + p : p
        }
        let surnames = (0..<n).map { "Family\($0 % 97)" }
        let keys = TreeWalkHighlight.surnameKeys(surnames)
        var inputs: FamilyMapModel.Inputs?
        let inputsCPU = PerformanceLane.measureThreadCPUTime {
            inputs = FamilyMapModel.inputs(ids: ids, names: ids, surnames: surnames, surnameKeys: keys,
                                           birthPlaces: places, birthYears: [Int?](repeating: nil, count: n),
                                           generations: (0..<n).map { Optional($0 % 24) },
                                           lines: (0..<n).map { TreeWalk.Line.allCases[$0 % 3] },
                                           visited: Array(0..<n),
                                           regions: [BirthplaceClassifier.BirthRegion](repeating: .unknown, count: n))
        }
        var flags = FamilyTreeBirthCountries.empty
        let flagsCPU = PerformanceLane.measureThreadCPUTime {
            flags = FamilyTreeBirthCountries.build(ids: ids, treePlaces: places)
        }
        print("[family-map] 100k European: inputs cpu \(inputsCPU), flags cpu \(flagsCPU) (\(PerformanceLane.loadDescription()))")
        // ~3× the quiet Debug measurement (2026-09-30, M4 Max).
        #expect(inputsCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(900)),
                "100k inputs took \(inputsCPU) cpu (\(PerformanceLane.loadDescription()))")
        #expect(flagsCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(900)),
                "100k flags took \(flagsCPU) cpu (\(PerformanceLane.loadDescription()))")
        let built = try #require(inputs)
        // 13 of the 16 spellings place someone (the OR string, Poland and nil do not).
        let placing: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 13, 14, 15]
        let expected = (0..<n).reduce(0) { $0 + (placing.contains($1 % mix.count) ? 1 : 0) }
        #expect(built.people.unitKeys.compactMap { $0 }.count == expected)
        #expect(flags.flaggedCount == expected, "every placed person has a flag, no one else does")
    }
}
