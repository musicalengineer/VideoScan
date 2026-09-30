// FamilyMapFlagTests.swift
// GH #229: unit key → country → flag, the Core half of the card flags.
// Dimensions: Logic (all seven countries, county and country-only keys,
// nil for unresolved / off-map / malformed; the resolver's own hits map
// to flags); Sensor (each flag is a well-formed regional-indicator pair
// or a tag-sequence subdivision flag — a stray normalisation would turn
// Scotland into a bare black flag). Isolation: pure functions, no I/O.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap flags (#229)")
struct FamilyMapFlagTests {

    /// Every country in scope has exactly the flag the spec names.
    @Test func everyCountryHasItsFlag() {
        let expected: [FamilyMap.Country: String] = [
            .england: "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
            .scotland: "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
            .wales: "🏴󠁧󠁢󠁷󠁬󠁳󠁿",
            .northernIreland: "🇬🇧",
            .ireland: "🇮🇪",
            .unitedStates: "🇺🇸",
            .canada: "🇨🇦",
        ]
        #expect(expected.count == FamilyMap.Country.allCases.count, "the table covers every country")
        for country in FamilyMap.Country.allCases {
            #expect(FamilyMapFlag.emoji(for: country) == expected[country], "\(country)")
            #expect(country.flag == FamilyMapFlag.emoji(for: country))
        }
    }

    /// A county key and the bare country key fly the same flag.
    @Test func countyAndCountryOnlyKeysMapToTheSameCountry() {
        let cases: [(String, String, FamilyMap.Country)] = [
            ("eng-yorkshire", "eng", .england),
            ("sct-fife", "sct", .scotland),
            ("wls-glamorgan", "wls", .wales),
            ("nir-antrim", "nir", .northernIreland),
            ("irl-cork", "irl", .ireland),
            ("usa-massachusetts", "usa", .unitedStates),
            ("can-nova-scotia", "can", .canada),
        ]
        for (fine, coarse, country) in cases {
            #expect(FamilyMapFlag.country(forUnitKey: fine) == country, "\(fine)")
            #expect(FamilyMapFlag.country(forUnitKey: coarse) == country, "\(coarse)")
            #expect(FamilyMapFlag.emoji(forUnitKey: fine) == country.flag)
            #expect(FamilyMapFlag.emoji(forUnitKey: coarse) == country.flag)
        }
    }

    /// No key, a blank key, or a key of no country the map knows → no flag.
    @Test func unresolvedAndOffMapKeysHaveNoFlag() {
        #expect(FamilyMapFlag.country(forUnitKey: nil) == nil)
        #expect(FamilyMapFlag.country(forUnitKey: "") == nil)
        #expect(FamilyMapFlag.country(forUnitKey: "deu-berlin") == nil, "Germany is off the map")
        #expect(FamilyMapFlag.country(forUnitKey: "aus") == nil)
        #expect(FamilyMapFlag.country(forUnitKey: "england") == nil, "a name is not a key")
        #expect(FamilyMapFlag.emoji(forUnitKey: nil) == nil)
        #expect(FamilyMapFlag.emoji(forUnitKey: "xx-nowhere") == nil)
    }

    /// End to end through the resolver: the spellings the tree actually
    /// carries land on the flag the map would shade. Colonial New England
    /// flies 🇺🇸 (the map's policy); a lone "Ireland" still flies 🇮🇪;
    /// off-map places fly nothing.
    @Test func resolverHitsFlyTheMapsFlag() {
        let cases: [(String, FamilyMap.Country?)] = [
            ("Sheffield, West Riding, Yorkshire, England", .england),
            ("England", .england),
            ("Fife, Scotland", .scotland),
            ("Cardiff, Glamorgan, Wales", .wales),
            ("Belfast, County Antrim, Northern Ireland", .northernIreland),
            ("Cork, Ireland", .ireland),
            ("Ireland", .ireland),
            ("Boston, Suffolk, Massachusetts Bay Colony, British Colonial America", .unitedStates),
            ("Providence, Rhode Island", .unitedStates),
            ("Halifax, Nova Scotia, Canada", .canada),
            ("Berlin, Germany", nil),
            ("Perth, WA, Australia", nil),
            ("", nil),
        ]
        for (place, country) in cases {
            let key = BirthplaceUnitResolver.resolve(place)?.unitKey
            #expect(FamilyMapFlag.country(forUnitKey: key) == country, "\(place)")
        }
        #expect(FamilyMapFlag.country(forUnitKey: BirthplaceUnitResolver.resolve(nil)?.unitKey) == nil)
    }

    /// Sensor: the subdivision flags are the seven-scalar tag sequence
    /// (black flag, five tag letters, cancel tag) and the national flags
    /// are two regional indicators. A normalised or truncated literal
    /// would render as a plain black flag or two letters.
    @Test func flagsAreWellFormedEmojiSequences() {
        let tagged: [FamilyMap.Country] = [.england, .scotland, .wales]
        for country in tagged {
            let scalars = Array(country.flag.unicodeScalars)
            #expect(scalars.count == 7, "\(country): \(scalars.count) scalars")
            #expect(scalars.first?.value == 0x1F3F4, "\(country) starts with the black flag")
            #expect(scalars.last?.value == 0xE007F, "\(country) ends with the cancel tag")
            #expect(scalars.dropFirst().dropLast().allSatisfy { (0xE0061...0xE007A).contains($0.value) },
                    "\(country): the middle is tag letters")
        }
        for country in [FamilyMap.Country.northernIreland, .ireland, .unitedStates, .canada] {
            let scalars = Array(country.flag.unicodeScalars)
            #expect(scalars.count == 2, "\(country): \(scalars.count) scalars")
            #expect(scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }, "\(country): regional indicators")
        }
        // Every flag is one grapheme cluster: a Text of it is one glyph.
        for country in FamilyMap.Country.allCases {
            #expect(country.flag.count == 1, "\(country) is one glyph")
        }
    }
}
