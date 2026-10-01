import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Synthetic model-only tests: no tiles, display, App Support, or network.
/// Run this app-hosted suite on M5/M1, not the active M4.
@Suite("FamilyMap adversarial app integration")
@MainActor
struct FamilyMapAdversarialAppTests {
    private static func square(key: String, name: String, kind: FamilyMap.UnitKind,
                               lat: ClosedRange<Double>, lon: ClosedRange<Double>) -> FamilyMapUnits.Unit {
        let ring = [FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.lowerBound),
                    FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.upperBound),
                    FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.upperBound),
                    FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.lowerBound)]
        return FamilyMapUnits.Unit(key: key, name: name, country: .england, kind: kind,
                                   polygons: [.init(outer: ring)])
    }

    private static var units: FamilyMapUnits {
        FamilyMapUnits(units: [
            square(key: "eng", name: "England", kind: .country, lat: 50...56, lon: -6...2),
            square(key: "eng-yorkshire", name: "Yorkshire", kind: .county, lat: 53...55, lon: -2...0),
        ])
    }

    private static func model(places: [String]) async throws -> FamilyMapModel {
        let n = places.count
        let surnames = [String](repeating: "Smith", count: n)
        let inputs = FamilyMapModel.inputs(
            ids: (0..<n).map { "person-\($0)" }, names: (0..<n).map { "Person \($0)" },
            surnames: surnames, surnameKeys: TreeWalkHighlight.surnameKeys(surnames),
            birthPlaces: places.map(Optional.some), birthYears: [Int?](repeating: 1800, count: n),
            generations: [Int?](repeating: 1, count: n),
            lines: Array(repeating: TreeWalk.Line.first, count: n),
            visited: Array(0..<n), regions: Array(repeating: BirthplaceClassifier.BirthRegion.england, count: n))
        let model = FamilyMapModel(inputs: inputs, units: units, displayNames: ["Rick", "Donna"])
        model.apply(selection: .init(), yearCeiling: nil)
        for _ in 0..<200 {
            if model.computed.totals.considered == n { return model }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.tallyDidNotPublish
    }

    private enum WaitError: Error { case tallyDidNotPublish }

    @Test func clickingAnUncountedCountySelectsTheShadedCountryBelowIt() async throws {
        let model = try await Self.model(places: ["England"])
        #expect(model.computed.counts["eng"]?.people == 1)
        #expect(model.computed.counts["eng-yorkshire"] == nil)
        model.select(coordinate: .init(latitude: 54, longitude: -1))
        #expect(model.selectedKey == "eng", "the shaded country must remain clickable through empty county outlines")
    }

    @Test func aCountedCountyWinsWhenCountryAndCountyBothHavePeople() async throws {
        let model = try await Self.model(places: ["England", "Yorkshire, England"])
        model.select(coordinate: .init(latitude: 54, longitude: -1))
        #expect(model.selectedKey == "eng-yorkshire")
        #expect(model.selectedCount?.people == 1)
    }

    @Test func aCoarseOutlineDoesNotSuppressTheCountedCoastalCountyFallback() async throws {
        let model = try await Self.model(places: ["Yorkshire, England"])
        let coastalPoint = FamilyMap.Coordinate(latitude: 55.005, longitude: -1)
        #expect(Self.units.unit(containing: coastalPoint)?.key == "eng")
        #expect(Self.units.unit(nearest: coastalPoint)?.key == "eng-yorkshire")
        model.select(coordinate: coastalPoint)
        #expect(model.selectedKey == "eng-yorkshire", "a coarse outline must not block the finer coastal fallback")
    }

    @Test func unsupportedRecordedPlacesAreNotDescribedAsMissingRecords() async throws {
        let model = try await Self.model(places: ["Warsaw, Poland"])
        #expect(model.computed.totals.unresolved == 1)
        let text = FamilyMapModel.totalsLine(model.computed.totals)
        #expect(!text.contains("no recorded place"), "the birthplace was recorded; only its map placement is unresolved")
    }

    @Test func aRecordedCoarseRegionIsNotDescribedAsUnrecorded() throws {
        #expect(BirthplaceUnitResolver.resolve("Lothian, Scotland")?.unitKey == "sct")
        let ring = [FamilyMap.Coordinate(latitude: 54, longitude: -6),
                    FamilyMap.Coordinate(latitude: 54, longitude: 0),
                    FamilyMap.Coordinate(latitude: 60, longitude: 0),
                    FamilyMap.Coordinate(latitude: 60, longitude: -6)]
        let unit = FamilyMapUnits.Unit(key: "sct", name: "Scotland", country: .scotland,
                                       kind: .country, polygons: [.init(outer: ring)])
        let text = FamilyTreeMapView.countLine(unit: unit, count: 1)
        #expect(!text.contains("not recorded"), "Lothian was recorded but cannot identify one supported county")
    }
}
