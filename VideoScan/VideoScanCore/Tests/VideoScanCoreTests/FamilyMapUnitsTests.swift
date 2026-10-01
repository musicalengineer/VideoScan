// FamilyMapUnitsTests.swift
// The GeoJSON decoder and point-in-polygon (GH #227 Stage 1) over a
// SYNTHETIC file — no bundled data, no App Support, no network:
//   eng        a big square (the country outline) that encloses eng-alpha
//   eng-alpha  a square with a square hole
//   eng-beta   a MultiPolygon: a square plus a distant island
//   sct-enclave a small square INSIDE eng-beta's first polygon
//   usa-twin-a / usa-twin-b   identical squares (the equal-area tie)
// Inside, in the hole, in the enclave, on a border, in the sea, on the
// island. Decoder refusals for every contract violation. SCALE: 1,000
// lookups over 200 units × 300 vertices.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap units — GeoJSON decoder and point-in-polygon")
struct FamilyMapUnitsTests {

    typealias C = FamilyMap.Coordinate

    // MARK: Fixture

    static func square(lon0: Double, lat0: Double, lon1: Double, lat1: Double) -> [[Double]] {
        [[lon0, lat0], [lon1, lat0], [lon1, lat1], [lon0, lat1], [lon0, lat0]]
    }

    static func feature(key: String, name: String, country: String, kind: String, geometry: [String: Any]) -> [String: Any] {
        ["type": "Feature",
         "properties": ["key": key, "name": name, "country": country, "kind": kind],
         "geometry": geometry]
    }

    static var fixture: [String: Any] {
        ["type": "FeatureCollection", "features": [
            feature(key: "eng", name: "England", country: "ENG", kind: "country",
                    geometry: ["type": "Polygon", "coordinates": [square(lon0: -5, lat0: -5, lon1: 15, lat1: 15)]]),
            feature(key: "eng-alpha", name: "Alpha", country: "ENG", kind: "county",
                    geometry: ["type": "Polygon", "coordinates": [square(lon0: 0, lat0: 0, lon1: 10, lat1: 10),
                                                                  square(lon0: 4, lat0: 4, lon1: 6, lat1: 6)]]),
            feature(key: "eng-beta", name: "Beta", country: "ENG", kind: "county",
                    geometry: ["type": "MultiPolygon", "coordinates": [[square(lon0: 20, lat0: 0, lon1: 30, lat1: 10)],
                                                                       [square(lon0: 40, lat0: 0, lon1: 42, lat1: 2)]]]),
            feature(key: "sct-enclave", name: "Enclave", country: "SCT", kind: "county",
                    geometry: ["type": "Polygon", "coordinates": [square(lon0: 22, lat0: 2, lon1: 24, lat1: 4)]]),
            feature(key: "usa-twin-a", name: "Twin A", country: "USA", kind: "state",
                    geometry: ["type": "Polygon", "coordinates": [square(lon0: 100, lat0: 50, lon1: 101, lat1: 51)]]),
            feature(key: "usa-twin-b", name: "Twin B", country: "USA", kind: "state",
                    geometry: ["type": "Polygon", "coordinates": [square(lon0: 100, lat0: 50, lon1: 101, lat1: 51)]]),
        ]]
    }

    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    static func units() throws -> FamilyMapUnits { try FamilyMapUnits(geoJSON: data(fixture)) }

    // MARK: Decoder

    @Test func decodesEveryFeatureWithItsPropertiesAndGeometry() throws {
        let units = try Self.units()
        #expect(units.count == 6)
        #expect(units.units.map(\.key) == ["eng", "eng-alpha", "eng-beta", "sct-enclave", "usa-twin-a", "usa-twin-b"], "sorted by key")
        let alpha = try #require(units.unit(forKey: "eng-alpha"))
        #expect(alpha.name == "Alpha")
        #expect(alpha.country == .england)
        #expect(alpha.kind == .county)
        #expect(alpha.polygons.count == 1)
        #expect(alpha.polygons[0].holes.count == 1)
        #expect(alpha.bbox == FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 10, minLongitude: 0, maxLongitude: 10))
        let beta = try #require(units.unit(forKey: "eng-beta"))
        #expect(beta.polygons.count == 2)
        #expect(beta.bbox.maxLongitude == 42, "the bbox spans both polygons")
        #expect(units.unit(forKey: "eng")?.kind == .country)
        #expect(units.unit(forKey: "nowhere") == nil)
        // [lon, lat] order was honoured: Alpha's first vertex is (lat 0, lon 0), Beta's island is at lon 40.
        #expect(beta.polygons[1].outer.first == C(latitude: 0, longitude: 40))
    }

    @Test func refusesEveryContractViolation() throws {
        func decode(_ features: [[String: Any]], type: String = "FeatureCollection") throws -> FamilyMapUnits {
            try FamilyMapUnits(geoJSON: Self.data(["type": type, "features": features]))
        }
        let ok = Self.square(lon0: 0, lat0: 0, lon1: 1, lat1: 1)
        #expect(throws: FamilyMapUnits.DecodeError.notAFeatureCollection) {
            try decode([], type: "Feature")
        }
        #expect(throws: FamilyMapUnits.DecodeError.missingProperty(feature: 0, name: "name")) {
            try decode([["type": "Feature", "properties": ["key": "eng-x", "country": "ENG", "kind": "county"],
                         "geometry": ["type": "Polygon", "coordinates": [ok]]]])
        }
        #expect(throws: FamilyMapUnits.DecodeError.unknownCountry(feature: 0, value: "POL")) {
            try decode([Self.feature(key: "pol-x", name: "X", country: "POL", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.unknownKind(feature: 0, value: "parish")) {
            try decode([Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "parish", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.malformedKey(feature: 0, key: "eng-england", reason: "a country unit's key must be 'eng'")) {
            try decode([Self.feature(key: "eng-england", name: "England", country: "ENG", kind: "country", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.malformedKey(feature: 0, key: "sct-x", reason: "must start with 'eng-'")) {
            try decode([Self.feature(key: "sct-x", name: "X", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.malformedKey(feature: 0, key: "eng-", reason: "must start with 'eng-'")) {
            try decode([Self.feature(key: "eng-", name: "X", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.malformedKey(feature: 0, key: "eng-East Lothian", reason: "not slug-shaped (FamilyMapKey rule)")) {
            try decode([Self.feature(key: "eng-East Lothian", name: "East Lothian", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.duplicateKey("eng-x")) {
            let f = Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]])
            try decode([f, f])
        }
        #expect(throws: FamilyMapUnits.DecodeError.self) {
            try decode([Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county", geometry: ["type": "Point", "coordinates": [0, 0]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.self) {
            // [lat, lon] by mistake: latitude 95 is out of range.
            try decode([Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county",
                                     geometry: ["type": "Polygon", "coordinates": [[[0, 95], [1, 95], [1, 96], [0, 95]]]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.badGeometry(feature: 0, reason: "ring with fewer than 3 positions")) {
            try decode([Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county",
                                     geometry: ["type": "Polygon", "coordinates": [[[0, 0], [1, 1]]]])])
        }
        #expect(throws: FamilyMapUnits.DecodeError.badGeometry(feature: 0, reason: "empty MultiPolygon")) {
            try decode([Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county",
                                     geometry: ["type": "MultiPolygon", "coordinates": []])])
        }
        #expect(throws: (any Error).self) { try FamilyMapUnits(geoJSON: Data("not json".utf8)) }
    }

    /// The bundled file names usa-district-of-columbia "Washington": a
    /// well-formed key that is not unitKey(country, name) is recorded,
    /// never refused. Ireland's "County " rule is part of the derivation.
    @Test func keyNameMismatchesAreRecordedNotRefused() throws {
        let ok = Self.square(lon0: 0, lat0: 0, lon1: 1, lat1: 1)
        let units = try FamilyMapUnits(geoJSON: Self.data(["type": "FeatureCollection", "features": [
            Self.feature(key: "usa-district-of-columbia", name: "Washington", country: "USA", kind: "state", geometry: ["type": "Polygon", "coordinates": [ok]]),
            Self.feature(key: "eng-yorks", name: "Yorkshire", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]]),
            Self.feature(key: "irl-cork", name: "County Cork", country: "IRL", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]]),
            Self.feature(key: "nir-antrim", name: "Antrim", country: "NIR", kind: "county", geometry: ["type": "Polygon", "coordinates": [ok]]),
            Self.feature(key: "can-quebec", name: "Québec", country: "CAN", kind: "province", geometry: ["type": "Polygon", "coordinates": [ok]]),
        ]]))
        #expect(units.count == 5)
        #expect(units.keyNameMismatches == ["eng-yorks", "usa-district-of-columbia"])
        #expect(try Self.units().keyNameMismatches.isEmpty)
    }

    @Test func aThirdCoordinateAndAnOpenRingAreTolerated() throws {
        let ring: [[Double]] = [[0, 0, 12], [1, 0, 12], [1, 1, 12], [0, 1, 12]]   // elevation, not closed
        let units = try FamilyMapUnits(geoJSON: Self.data(["type": "FeatureCollection", "features": [
            Self.feature(key: "eng-x", name: "X", country: "ENG", kind: "county", geometry: ["type": "Polygon", "coordinates": [ring]]),
        ]]))
        #expect(units.unit(containing: C(latitude: 0.5, longitude: 0.5))?.key == "eng-x")
        #expect(units.unit(containing: C(latitude: 1.5, longitude: 0.5)) == nil)
    }

    // MARK: Point in polygon

    @Test func insideHoleEnclaveBorderSeaAndIsland() throws {
        let units = try Self.units()
        func at(_ lat: Double, _ lon: Double) -> String? { units.unit(containing: C(latitude: lat, longitude: lon))?.key }
        #expect(at(2, 2) == "eng-alpha", "inside Alpha, which beats the enclosing country outline")
        #expect(at(5, 5) == "eng", "in Alpha's hole: not Alpha, so the country outline")
        #expect(units.unit(forKey: "eng-alpha")?.contains(C(latitude: 5, longitude: 5)) == false)
        #expect(at(12, 12) == "eng", "inside the outline, outside every county")
        #expect(at(3, 23) == "sct-enclave", "the enclave beats its enclosure")
        #expect(at(8, 28) == "eng-beta")
        #expect(at(1, 41) == "eng-beta", "the second polygon of a MultiPolygon")
        #expect(at(5, 17) == nil, "the sea between Alpha and Beta")
        #expect(at(50, -100) == nil)
        #expect(at(3, 41) == nil, "just north of the island")
    }

    @Test func aPointOnABorderIsInsideAndTiesAreDeterministic() throws {
        let units = try Self.units()
        func at(_ lat: Double, _ lon: Double) -> String? { units.unit(containing: C(latitude: lat, longitude: lon))?.key }
        #expect(at(5, 10) == "eng-alpha", "on Alpha's east edge: Alpha (smaller box) beats the outline")
        #expect(at(0, 0) == "eng-alpha", "on a vertex")
        #expect(at(4, 5) == "eng-alpha", "on the hole's boundary counts as inside the unit")
        #expect(at(3, 22) == "sct-enclave", "on the enclave's border, inside Beta: the enclave wins")
        #expect(at(50.5, 100.5) == "usa-twin-a", "identical twins: the smaller key wins")
        #expect(at(50, 100) == "usa-twin-a")
        // The raw predicates, for the record.
        let alpha = try #require(units.unit(forKey: "eng-alpha")).polygons[0]
        #expect(FamilyMapUnits.relation(C(latitude: 5, longitude: 10), ring: alpha.outer) == .boundary)
        #expect(FamilyMapUnits.relation(C(latitude: 5, longitude: 9.99), ring: alpha.outer) == .inside)
        #expect(FamilyMapUnits.relation(C(latitude: 5, longitude: 10.01), ring: alpha.outer) == .outside)
        #expect(FamilyMapUnits.relation(C(latitude: 10, longitude: 10), ring: alpha.outer) == .boundary, "a vertex")
        #expect(FamilyMapUnits.relation(C(latitude: 5, longitude: 5), ring: alpha.holes[0]) == .inside)
    }

    @Test func aConcavePolygonIsHandledByEvenOdd() {
        // A "U": the notch between the arms is outside.
        let u: [C] = [C(latitude: 0, longitude: 0), C(latitude: 0, longitude: 6), C(latitude: 6, longitude: 6),
                      C(latitude: 6, longitude: 4), C(latitude: 2, longitude: 4), C(latitude: 2, longitude: 2),
                      C(latitude: 6, longitude: 2), C(latitude: 6, longitude: 0)]
        let polygon = FamilyMapUnits.Polygon(outer: u)
        #expect(FamilyMapUnits.contains(C(latitude: 1, longitude: 3), polygon: polygon), "the base")
        #expect(FamilyMapUnits.contains(C(latitude: 5, longitude: 1), polygon: polygon), "the left arm")
        #expect(!FamilyMapUnits.contains(C(latitude: 5, longitude: 3), polygon: polygon), "the notch")
        #expect(FamilyMapUnits.contains(C(latitude: 5, longitude: 5), polygon: polygon), "the right arm")
    }

    // MARK: Nearest (coarse coastlines)

    @Test func aPointJustOffACoastResolvesToTheAdjacentUnitAndMidOceanIsNil() throws {
        let units = try Self.units()
        // Just east of Beta's island (lon 40…42, lat 0…2): 0.1° off the coast.
        let offshore = C(latitude: 1, longitude: 42.1)
        #expect(units.unit(containing: offshore) == nil)
        #expect(units.unit(nearest: offshore)?.key == "eng-beta")
        #expect(units.unit(nearest: offshore, withinDegrees: 0.05) == nil, "beyond the tolerance")
        #expect(units.unit(nearest: C(latitude: 30, longitude: 60)) == nil, "mid-ocean")
        // (lat 5, lon 17) is in the sea between the outline (east edge lon 15,
        // 2° away) and Beta (west edge lon 20, 3° away): edge distance, not
        // vertex distance — the nearest vertices are 10° and 5.8° off.
        let sea = C(latitude: 5, longitude: 17)
        #expect(units.unit(nearest: sea) == nil)
        #expect(units.unit(nearest: sea, withinDegrees: 1.9) == nil)
        #expect(units.unit(nearest: sea, withinDegrees: 2.5)?.key == "eng", "only the outline is within reach")
        // A county beats a nearer COUNTRY outline once it is within reach:
        // the outlines are coarser than the counties (Halifax, 2026-09-29).
        #expect(units.unit(nearest: sea, withinDegrees: 4)?.key == "eng-beta", "finer unit preferred over the nearer outline")
    }

    @Test func nearestTiesGoToTheKey() throws {
        let units = try Self.units()
        // The twins are identical squares: equidistant, so the key decides.
        let p = C(latitude: 50.5, longitude: 101.1)
        #expect(units.unit(containing: p) == nil)
        #expect(units.unit(nearest: p)?.key == "usa-twin-a")
    }

    /// `among:` restricts both lookups to the listed keys (codex #1782,
    /// stage 2 F1): the map asks over the COUNTED units, so a click in an
    /// empty county reaches the counted outline around it, and the nearest
    /// fallback never answers with an uncounted unit.
    @Test func amongRestrictsContainingAndNearestToTheListedKeys() throws {
        let units = try Self.units()
        let inAlpha = C(latitude: 2, longitude: 2)                 // Alpha (county) inside England
        #expect(units.unit(containing: inAlpha)?.key == "eng-alpha")
        #expect(units.unit(containing: inAlpha, among: ["eng"])?.key == "eng", "the county is not listed: the outline answers")
        #expect(units.unit(containing: inAlpha, among: ["eng-beta"]) == nil, "nothing listed contains it")
        #expect(units.unit(containing: inAlpha, among: [])  == nil)
        #expect(units.unit(containing: inAlpha, among: nil)?.key == "eng-alpha", "nil = everything")
        // Off Beta's island: the nearest is Beta unless Beta is not listed.
        let offshore = C(latitude: 1, longitude: 42.1)
        #expect(units.unit(nearest: offshore)?.key == "eng-beta")
        #expect(units.unit(nearest: offshore, among: ["eng-beta"])?.key == "eng-beta")
        #expect(units.unit(nearest: offshore, among: ["eng-alpha", "sct-enclave"]) == nil)
        // The twins tie: listing only B makes B the answer.
        let twins = C(latitude: 50.5, longitude: 101.1)
        #expect(units.unit(nearest: twins, among: ["usa-twin-b"])?.key == "usa-twin-b")
    }

    /// The boolean refusal (FamilyMapUnitsAdversarialTests) must not take
    /// genuine zeros and ones with it: Greenwich and the equator are real.
    @Test func numericZerosAndOnesStillDecodeAsCoordinates() throws {
        let object: [String: Any] = ["type": "FeatureCollection", "features": [
            Self.feature(key: "eng-o", name: "O", country: "ENG", kind: "county",
                         geometry: ["type": "Polygon", "coordinates": [Self.square(lon0: 0, lat0: 0, lon1: 1, lat1: 1)]]),
        ]]
        let units = try FamilyMapUnits(geoJSON: Self.data(object))
        #expect(units.unit(containing: C(latitude: 0.5, longitude: 0.5))?.key == "eng-o")
        #expect(units.unit(forKey: "eng-o")?.bbox == FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 1, minLongitude: 0, maxLongitude: 1))
        // Integer JSON literals ("[0, 0]") are numbers too — only true / false are refused.
        let literal = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"key":"eng-i","name":"I","country":"ENG","kind":"county"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}]}"#.utf8)
        #expect(try FamilyMapUnits(geoJSON: literal).count == 1)
        #expect(FamilyMapUnits.number(true) == nil)
        #expect(FamilyMapUnits.number(NSNumber(value: false)) == nil)
        #expect(FamilyMapUnits.number(NSNumber(value: 1)) == 1)
        #expect(FamilyMapUnits.number(0) == 0)
        #expect(FamilyMapUnits.number("1") == nil)
    }

    // MARK: Coverage (camera)

    /// The latitude-band index must give exactly the reference answer —
    /// inside, boundary and outside — on a dense grid, on every vertex and
    /// on every edge midpoint of a 300-vertex ring, a concave U and a
    /// square with a hole.
    @Test func bandIndexedRelationMatchesTheReferenceScan() throws {
        var rings: [[C]] = []
        rings.append((0..<300).map { k in
            let a = Double(k) / 300 * 2 * .pi
            return C(latitude: 10 + 3 * sin(a), longitude: 20 + 5 * cos(a))
        })
        rings.append([C(latitude: 0, longitude: 0), C(latitude: 0, longitude: 6), C(latitude: 6, longitude: 6),
                      C(latitude: 6, longitude: 4), C(latitude: 2, longitude: 4), C(latitude: 2, longitude: 2),
                      C(latitude: 6, longitude: 2), C(latitude: 6, longitude: 0)])
        rings.append((0..<40).map { k in   // a jagged star: many band-straddling edges
            let a = Double(k) / 40 * 2 * .pi
            let r = k % 2 == 0 ? 4.0 : 1.5
            return C(latitude: -30 + r * sin(a), longitude: -60 + r * cos(a))
        })
        var checked = 0, boundaries = 0
        for ring in rings {
            let index = FamilyMapUnits.RingIndex(ring: ring)
            var points: [C] = ring
            for i in ring.indices {
                let j = i == 0 ? ring.count - 1 : i - 1
                points.append(C(latitude: (ring[i].latitude + ring[j].latitude) / 2, longitude: (ring[i].longitude + ring[j].longitude) / 2))
            }
            let box = try #require(FamilyMap.BoundingBox(around: ring))
            for a in 0...40 {
                for b in 0...40 {
                    points.append(C(latitude: box.minLatitude - 0.5 + (box.maxLatitude - box.minLatitude + 1) * Double(a) / 40,
                                    longitude: box.minLongitude - 0.5 + (box.maxLongitude - box.minLongitude + 1) * Double(b) / 40))
                }
            }
            for p in points {
                let reference = FamilyMapUnits.relation(p, ring: ring)
                let indexed = FamilyMapUnits.relation(p, ring: ring, index: index)
                #expect(indexed == reference, "(\(p.latitude), \(p.longitude)): indexed \(indexed) vs reference \(reference)")
                checked += 1
                if reference == .boundary { boundaries += 1 }
            }
        }
        #expect(checked > 5_000)
        #expect(boundaries >= 2 * (300 + 8 + 40), "every vertex and midpoint is on the boundary")
    }

    @Test func coverageIsTheUnionOfTheListedUnitsThatExist() throws {
        let units = try Self.units()
        let box = try #require(units.coverage(for: ["eng-alpha", "sct-enclave", "nowhere"]))
        #expect(box == FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 10, minLongitude: 0, maxLongitude: 24))
        #expect(units.coverage(for: ["nowhere"]) == nil)
        #expect(units.coverage(for: [String]()) == nil)
        #expect(units.coverage(for: Set(["usa-twin-b"]))?.minLongitude == 100)
    }

    /// A country-only count must not widen the camera past the counties
    /// (QA round 2, 2026-09-29: ~838 "New England" births resolve to `usa`
    /// on every real walk and the union opened on a hemisphere). The camera
    /// is the FINE counted units whenever any exist; a country outline
    /// joins only when nothing finer is counted.
    @Test func coveragePrefersTheFineUnitsAndFallsBackToTheCountryOutlines() throws {
        let units = try Self.units()
        let alpha = try #require(units.unit(forKey: "eng-alpha"))
        let england = try #require(units.unit(forKey: "eng"))
        #expect(units.coverage(for: ["eng", "eng-alpha"]) == alpha.cameraBox, "the county, not the outline around it")
        #expect(units.coverage(for: ["eng-alpha", "eng"]) == alpha.cameraBox, "order does not matter")
        #expect(units.coverage(for: ["eng"]) == england.cameraBox, "only the country counted: its outline frames the map")
        #expect(units.coverage(for: ["eng", "nowhere"]) == england.cameraBox)
        #expect(units.coverage(for: ["eng", "usa-twin-a"])?.minLongitude == 100, "a state elsewhere still wins over the outline")
    }

    /// The largest piece (by bounding-box area) is the PRINCIPAL piece — the
    /// contiguous US, mainland Britain — and a country outline's camera box
    /// and label anchor come from it, never from the union of every island.
    /// A county / state keeps the union camera (Michigan has two peninsulas).
    @Test func aCountryOutlinesCameraAndLabelComeFromItsPrincipalPiece() {
        let mainland = FamilyMapUnits.Polygon(outer: [C(latitude: 25, longitude: -125), C(latitude: 25, longitude: -67),
                                                     C(latitude: 49, longitude: -67), C(latitude: 49, longitude: -125)])
        let island = FamilyMapUnits.Polygon(outer: [C(latitude: 19, longitude: -160), C(latitude: 19, longitude: -155),
                                                   C(latitude: 22, longitude: -155), C(latitude: 22, longitude: -160)])
        let north = FamilyMapUnits.Polygon(outer: [C(latitude: 55, longitude: -168), C(latitude: 55, longitude: -130),
                                                  C(latitude: 71, longitude: -130), C(latitude: 71, longitude: -168)])
        let country = FamilyMapUnits.Unit(key: "usa", name: "United States", country: .unitedStates, kind: .country,
                                          polygons: [island, north, mainland])   // the principal piece is not first
        #expect(country.principalBox == mainland.bbox)
        #expect(country.principalCentroid == C(latitude: 37, longitude: -96))
        #expect(country.cameraBox == mainland.bbox, "a country outline's camera is its principal piece")
        #expect(country.labelAnchor == country.principalCentroid)
        #expect(country.bbox.minLatitude == 19 && country.bbox.maxLatitude == 71, "containment still covers every piece")
        #expect(country.contains(C(latitude: 20, longitude: -157)), "the island still answers clicks")
        // The same pieces as a STATE: the union camera (minus far-eastern
        // pieces) and the union centre, as before.
        let state = FamilyMapUnits.Unit(key: "usa-x", name: "X", country: .unitedStates, kind: .state,
                                        polygons: [island, north, mainland])
        #expect(state.principalBox == mainland.bbox)
        #expect(state.cameraBox == state.bbox)
        #expect(state.labelAnchor == state.cameraBox.center)
        // A single-piece unit: principal == bbox == camera.
        let one = FamilyMapUnits.Unit(key: "irl", name: "Ireland", country: .ireland, kind: .country, polygons: [island])
        #expect(one.principalBox == one.bbox && one.cameraBox == one.bbox)
        // Equal areas: the first piece is the principal (deterministic).
        let twin = FamilyMapUnits.Polygon(outer: [C(latitude: 0, longitude: 0), C(latitude: 0, longitude: 5), C(latitude: 3, longitude: 5), C(latitude: 3, longitude: 0)])
        let twin2 = FamilyMapUnits.Polygon(outer: [C(latitude: 10, longitude: 10), C(latitude: 10, longitude: 15), C(latitude: 13, longitude: 15), C(latitude: 13, longitude: 10)])
        let tie = FamilyMapUnits.Unit(key: "eng", name: "England", country: .england, kind: .country, polygons: [twin, twin2])
        #expect(tie.principalBox == twin.bbox)
    }

    /// Alaska: pieces west of −130° plus Aleutian pieces at 172…180°. The
    /// containment box spans both; the camera box ignores the far-eastern
    /// pieces so the camera does not open on the whole Pacific.
    @Test func cameraBoxIgnoresFarEasternPiecesOfAWesternUnit() {
        let mainland = FamilyMapUnits.Polygon(outer: [C(latitude: 55, longitude: -165), C(latitude: 55, longitude: -130),
                                                     C(latitude: 70, longitude: -130), C(latitude: 70, longitude: -165)])
        let aleutian = FamilyMapUnits.Polygon(outer: [C(latitude: 52, longitude: 172), C(latitude: 52, longitude: 180),
                                                     C(latitude: 53, longitude: 180), C(latitude: 53, longitude: 172)])
        let alaska = FamilyMapUnits.Unit(key: "usa-alaska", name: "Alaska", country: .unitedStates, kind: .state,
                                         polygons: [mainland, aleutian])
        #expect(alaska.bbox.minLongitude == -165 && alaska.bbox.maxLongitude == 180, "containment covers every piece")
        #expect(alaska.cameraBox == FamilyMap.BoundingBox(minLatitude: 55, maxLatitude: 70, minLongitude: -165, maxLongitude: -130))
        #expect(alaska.contains(C(latitude: 52.5, longitude: 175)), "the Aleutian piece still answers clicks")
        #expect(!alaska.contains(C(latitude: 60, longitude: 0)), "the union box alone does not make the Atlantic Alaska")
        let map = FamilyMapUnits(units: [alaska])
        #expect(map.coverage(for: ["usa-alaska"]) == alaska.cameraBox)
        // An eastern-hemisphere unit keeps its eastern pieces.
        let east = FamilyMapUnits.Unit(key: "eng-x", name: "X", country: .england, kind: .county,
                                       polygons: [FamilyMapUnits.Polygon(outer: [C(latitude: 0, longitude: 160), C(latitude: 0, longitude: 170), C(latitude: 1, longitude: 170)])])
        #expect(east.cameraBox == east.bbox)
    }

    // MARK: Scale

    /// 200 units on a grid, each a 300-vertex near-circle; 1,000 lookups
    /// that mostly land inside a unit. Budget 20 ms (Debug, load-aware).
    @Test func thousandLookupsOverTwoHundredUnitsUnderBudget() {
        var units: [FamilyMapUnits.Unit] = []
        for i in 0..<200 {
            let row = Double(i / 20), col = Double(i % 20)
            let cLat = row * 3 + 1.5, cLon = col * 3 + 1.5
            let ring: [C] = (0..<300).map { k in
                let a = Double(k) / 300 * 2 * .pi
                return C(latitude: cLat + 1.4 * sin(a), longitude: cLon + 1.4 * cos(a))
            }
            units.append(FamilyMapUnits.Unit(key: "usa-u\(i)", name: "U\(i)", country: .unitedStates, kind: .state,
                                             polygons: [FamilyMapUnits.Polygon(outer: ring)]))
        }
        let map = FamilyMapUnits(units: units)
        let points: [C] = (0..<1_000).map { k in
            let i = (k * 37) % 200
            let row = Double(i / 20), col = Double(i % 20)
            let r = Double(k % 10) / 10 * 1.6     // 0 … 1.44: some land outside the circle
            let a = Double(k) * 0.7
            return C(latitude: row * 3 + 1.5 + r * sin(a), longitude: col * 3 + 1.5 + r * cos(a))
        }
        // Thread CPU time (GH #208): a pure loop, budgeted on what it
        // consumed, not on what the rest of the host was doing.
        var hits = 0
        var wall: Duration = .zero
        let cpu = TimingBudget.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                for p in points where map.unit(containing: p) != nil { hits += 1 }
            }
        }
        let ceiling = TimingBudget.loadAwareDebugCeiling(.milliseconds(20))
        print("[family-map] 1,000 lookups over 200×300: cpu \(cpu), wall \(wall), \(hits) hits (\(TimingBudget.loadDescription()))")
        #expect(cpu < ceiling, "1,000 lookups took \(cpu) cpu / \(wall) wall, ceiling \(ceiling) (\(TimingBudget.loadDescription()))")
        #expect(hits > 800 && hits < 1_000, "\(hits)")
    }

    // MARK: Isolation

    /// The whole API takes bytes and values: there is no initialiser that
    /// reads a path, so App Support and the network are unreachable from
    /// here by construction. Decoding twice from the same bytes is pure.
    @Test func decodingIsPureAndReadsNoFiles() throws {
        let bytes = try Self.data(Self.fixture)
        let a = try FamilyMapUnits(geoJSON: bytes)
        let b = try FamilyMapUnits(geoJSON: bytes)
        #expect(a.units == b.units)
        #expect(a.unit(containing: C(latitude: 2, longitude: 2)) == b.unit(containing: C(latitude: 2, longitude: 2)))
    }
}
