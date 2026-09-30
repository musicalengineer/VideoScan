// FamilyMapKeyTests.swift
// SENSOR for the one rule that joins the bundled border file to the
// resolver (GH #227 Stage 1). scripts/build_family_map_units.py implements
// the same slug:
//
//     def slug(name):
//         s = unicodedata.normalize("NFKD", name)
//         s = "".join(c for c in s if not unicodedata.combining(c)).lower()
//         return re.sub(r"[^a-z0-9]+", "-", s).strip("-")
//
// and its pytest pins the same examples. If either side changes, both
// tests must change together.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap key rule")
struct FamilyMapKeyTests {

    /// The documented examples, exactly.
    @Test func slugMatchesTheDocumentedExamples() {
        let examples: [(String, String)] = [
            ("Yorkshire", "yorkshire"),
            ("East Lothian", "east-lothian"),
            ("Québec", "quebec"),
            ("Ynys Môn", "ynys-mon"),
            ("Inverness-shire", "inverness-shire"),
            ("Kinross-shire", "kinross-shire"),
            ("Ross and Cromarty", "ross-and-cromarty"),
            ("St. John's", "st-john-s"),
            ("Queen's County", "queen-s-county"),
            ("District of Columbia", "district-of-columbia"),
            ("Newfoundland and Labrador", "newfoundland-and-labrador"),
            ("  Yorkshire  ", "yorkshire"),
            ("YORKSHIRE", "yorkshire"),
            ("Sir Gaerfyrddin", "sir-gaerfyrddin"),
            ("Massachusetts Bay Colony", "massachusetts-bay-colony"),
            ("", ""),
            ("---", ""),
        ]
        for (name, expected) in examples {
            #expect(FamilyMapKey.slug(name) == expected, "slug(\(name))")
        }
    }

    @Test func unitKeyIsCountryDashSlugAndDropsCountyForIreland() {
        #expect(FamilyMapKey.unitKey(country: .england, name: "Yorkshire") == "eng-yorkshire")
        #expect(FamilyMapKey.unitKey(country: .scotland, name: "East Lothian") == "sct-east-lothian")
        #expect(FamilyMapKey.unitKey(country: .wales, name: "Ynys Môn") == "wls-ynys-mon")
        #expect(FamilyMapKey.unitKey(country: .unitedStates, name: "Massachusetts") == "usa-massachusetts")
        #expect(FamilyMapKey.unitKey(country: .canada, name: "Québec") == "can-quebec")
        #expect(FamilyMapKey.unitKey(country: .ireland, name: "County Antrim") == "irl-antrim")
        #expect(FamilyMapKey.unitKey(country: .ireland, name: "county Cork") == "irl-cork")
        #expect(FamilyMapKey.unitKey(country: .ireland, name: "Cork") == "irl-cork")
        #expect(FamilyMapKey.unitKey(country: .northernIreland, name: "County Antrim") == "nir-antrim")
        #expect(FamilyMapKey.unitKey(country: .england, name: "County Durham") == "eng-county-durham",
                "the County prefix is dropped for Ireland only")
    }

    @Test func aBlankNameIsTheCountryUnit() {
        #expect(FamilyMapKey.unitKey(country: .england, name: nil) == "eng")
        #expect(FamilyMapKey.unitKey(country: .scotland, name: "   ") == "sct")
        #expect(FamilyMapKey.unitKey(country: .unitedStates, name: "") == "usa")
        for c in FamilyMap.Country.allCases {
            #expect(FamilyMapKey.unitKey(country: c, name: nil) == c.rawValue.lowercased())
            #expect(FamilyMapKey.isCountryKey(c.key))
            #expect(FamilyMapKey.country(of: c.key) == c)
        }
    }

    @Test func countryOfKeyReadsThePrefix() {
        #expect(FamilyMapKey.country(of: "eng-yorkshire") == .england)
        #expect(FamilyMapKey.country(of: "usa-new-york") == .unitedStates)
        #expect(FamilyMapKey.country(of: "nir-antrim") == .northernIreland)
        #expect(FamilyMapKey.country(of: "xx-nowhere") == nil)
        #expect(FamilyMapKey.country(of: "") == nil)
        #expect(!FamilyMapKey.isCountryKey("eng-yorkshire"))
        #expect(!FamilyMapKey.isCountryKey("england"))
    }

    @Test func countryUnitKindsAndLabels() {
        #expect(FamilyMap.Country.england.unitKind == .county)
        #expect(FamilyMap.Country.unitedStates.unitKind == .state)
        #expect(FamilyMap.Country.canada.unitKind == .province)
        #expect(FamilyMap.Country.northernIreland.label == "Northern Ireland")
        #expect(FamilyMap.Country(rawValue: "SCT") == .scotland)
    }

    @Test func boundingBoxUnionContainsAndArea() {
        let a = FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 1, minLongitude: 0, maxLongitude: 2)
        let b = FamilyMap.BoundingBox(minLatitude: -1, maxLatitude: 0.5, minLongitude: 1, maxLongitude: 3)
        let u = a.union(b)
        #expect(u == FamilyMap.BoundingBox(minLatitude: -1, maxLatitude: 1, minLongitude: 0, maxLongitude: 3))
        #expect(a.area == 2)
        #expect(a.contains(FamilyMap.Coordinate(latitude: 1, longitude: 2)), "closed on the boundary")
        #expect(!a.contains(FamilyMap.Coordinate(latitude: 1.0001, longitude: 2)))
        let around = FamilyMap.BoundingBox(around: [.init(latitude: 3, longitude: -3), .init(latitude: -3, longitude: 3)])
        #expect(around == FamilyMap.BoundingBox(minLatitude: -3, maxLatitude: 3, minLongitude: -3, maxLongitude: 3))
        #expect(FamilyMap.BoundingBox(around: []) == nil)
        #expect(a.center == FamilyMap.Coordinate(latitude: 0.5, longitude: 1))
    }
}
