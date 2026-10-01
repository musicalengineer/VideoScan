import Foundation
import Testing
@testable import VideoScanCore

/// The resolver and the BUNDLED border file agree (GH #227 stage 0 ↔ 1):
/// every key the resolver can produce is a unit in the file, and every
/// unit in the file is reachable from the resolver. Reads the committed
/// file from the repo (never App Support, never the network); skips only
/// when the checkout has no file (a stripped package checkout).
@Suite("Family map — resolver keys ⇔ bundled units")
struct FamilyMapBundledDataTests {
    static let fileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()                             // …/VideoScan (the Xcode project folder)
        .appendingPathComponent("VideoScan/Resources/FamilyMap/family-map-units.geojson")

    @Test func everyResolverKeyIsABundledUnitAndViceVersa() throws {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            Issue.record("bundled family-map-units.geojson not found at \(Self.fileURL.path)")
            return
        }
        let units = try FamilyMapUnits(geoJSON: data)
        let bundled = Set(units.units.map(\.key))
        let resolver = BirthplaceUnitResolver.allUnitKeys
        #expect(resolver.subtracting(bundled).isEmpty, "resolver keys with no border: \(resolver.subtracting(bundled).sorted())")
        #expect(bundled.subtracting(resolver).isEmpty, "bundled units the resolver never names: \(bundled.subtracting(resolver).sorted())")
        // 189 until the Western Europe stage (2026-09-30) added 65: 13 French
        // régions, 16 Länder, 12 Dutch + 11 Belgian provinces, 13 outlines.
        // tests/test_family_map_units.py pins the same number.
        #expect(units.units.count == 254)
        // The data build uses the source's `name` (not name_en "Washington") for DC, so no mismatches.
        #expect(units.keyNameMismatches.isEmpty, "\(units.keyNameMismatches)")
    }

    /// The country outlines frame their PRINCIPAL piece (QA round 2,
    /// 2026-09-29): `usa` is 123 pieces whose union runs from the western
    /// Aleutians (−178°) across the antimeridian (+180°) and up to 71°N; the
    /// principal piece is the contiguous US. `can` reaches 83°N through the
    /// Arctic islands; its principal piece is the mainland. `eng` and `irl`
    /// are one island plus an islet, so the principal piece IS the outline.
    @Test func countryOutlinesFrameTheirPrincipalPiece() throws {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let units = try FamilyMapUnits(geoJSON: data)
        let usa = try #require(units.unit(forKey: "usa"))
        #expect(usa.polygons.count > 50, "many pieces: \(usa.polygons.count)")
        #expect(usa.bbox.maxLongitude > 150 && usa.bbox.minLongitude < -170, "the union crosses the antimeridian")
        let lower48 = usa.principalBox
        #expect(lower48.minLatitude > 24 && lower48.maxLatitude < 50 && lower48.minLongitude > -126 && lower48.maxLongitude < -66,
                "the contiguous US: \(lower48)")
        #expect(usa.cameraBox == lower48)
        #expect(usa.labelAnchor.latitude < 45 && usa.labelAnchor.longitude > -100 && usa.labelAnchor.longitude < -90,
                "the label sits in the middle of the country, not in Oregon: \(usa.labelAnchor)")
        let can = try #require(units.unit(forKey: "can"))
        #expect(can.bbox.maxLatitude > 80, "the union reaches the Arctic islands")
        #expect(can.principalBox.maxLatitude < 75 && can.principalBox.minLongitude > -142 && can.principalBox.maxLongitude < -50,
                "the mainland: \(can.principalBox)")
        #expect(can.cameraBox == can.principalBox)
        for key in ["eng", "irl"] {
            let u = try #require(units.unit(forKey: key))
            #expect(u.principalBox.area > 0.9 * u.bbox.area, "\(key): the main island is the outline (\(u.polygons.count) pieces)")
        }
        let sct = try #require(units.unit(forKey: "sct"))
        #expect(sct.principalBox.maxLatitude < 59.5 && sct.bbox.maxLatitude > 60, "Scotland's camera is the mainland, not Shetland")
    }

    @Test func realPlacesLandInTheRightBundledUnit() throws {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let units = try FamilyMapUnits(geoJSON: data)
        func hit(_ lat: Double, _ lon: Double) -> String? {
            units.unit(containing: .init(latitude: lat, longitude: lon))?.key
        }
        #expect(hit(53.9600, -1.0873) == "eng-yorkshire")       // York
        #expect(hit(42.3601, -71.0589) == "usa-massachusetts")  // Boston
        #expect(hit(55.9533, -3.1883) == "sct-midlothian")      // Edinburgh
        #expect(hit(51.4816, -3.1791) == "wls-glamorgan")       // Cardiff
        #expect(hit(55.0, 2.0) == nil)                          // North Sea
        // Halifax waterfront is outside NE 1:50m Nova Scotia — the nearest fallback catches it.
        #expect(units.unit(nearest: .init(latitude: 44.6488, longitude: -63.5752))?.key == "can-nova-scotia")
        // Western Europe: a région, a Land (Berlin is an enclave in
        // Brandenburg — the smaller box wins), a province, an outline.
        #expect(hit(48.8566, 2.3522) == "fra-ile-de-france")   // Paris
        #expect(hit(49.4432, 1.0999) == "fra-normandy")        // Rouen
        #expect(hit(52.5200, 13.4050) == "deu-berlin")         // Berlin
        #expect(hit(52.3906, 13.0645) == "deu-brandenburg")    // Potsdam
        #expect(hit(51.4416, 5.4697) == "nld-north-brabant")   // Eindhoven
        #expect(hit(50.4542, 3.9567) == "bel-hainaut")         // Mons
        #expect(hit(43.7696, 11.2558) == "ita")                // Florence: Italy is outline-only
    }

    /// The Western Europe outlines are the home territory and the camera
    /// frames their MAINLAND: France is metropolitan (no overseas
    /// départements), Norway has no Svalbard, and Spain's / Portugal's
    /// principal piece is the peninsula, not the Canaries or the Azores.
    @Test func europeanOutlinesFrameTheirMainland() throws {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let units = try FamilyMapUnits(geoJSON: data)
        let esp = try #require(units.unit(forKey: "esp"))
        #expect(esp.bbox.minLatitude < 29, "the Canaries are part of the outline")
        #expect(esp.cameraBox.minLatitude > 35 && esp.cameraBox.minLongitude > -10, "mainland Spain: \(esp.cameraBox)")
        let prt = try #require(units.unit(forKey: "prt"))
        #expect(prt.bbox.minLongitude < -25, "the Azores are part of the outline")
        #expect(prt.cameraBox.minLongitude > -10, "mainland Portugal: \(prt.cameraBox)")
        let nor = try #require(units.unit(forKey: "nor"))
        #expect(nor.bbox.maxLatitude < 72, "no Svalbard: \(nor.bbox)")
        let fra = try #require(units.unit(forKey: "fra"))
        #expect(fra.bbox.minLongitude > -6 && fra.bbox.maxLongitude < 10, "metropolitan France only: \(fra.bbox)")
        // Every outline-only country has nothing finer in the file.
        for c in FamilyMap.Country.allCases where !c.hasSubdivisions {
            #expect(!units.units.contains { $0.country == c && $0.kind != .country }, "\(c) is outline-only")
        }
    }
}
