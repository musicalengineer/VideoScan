// Offline adversarial cases for GH #227 Stage 1. County decorations do
// not remove geographic ambiguity, and the rightmost country constrains
// every earlier component (including an earlier off-map country name).

import Testing
@testable import VideoScanCore

@Suite("FamilyMap resolver adversarial regressions")
struct FamilyMapResolverAdversarialTests {
    typealias Resolver = BirthplaceUnitResolver

    struct ResolvedCase: Sendable {
        let place: String
        let unitKey: String
    }

    // Swift Testing runs one argument case per row, like a parameterized
    // C++ test; #expect records a failed assertion without ending the case.
    @Test(arguments: [
        "County Middlesex",
        "Middlesex County",
        "Suffolk County",
        "Co. Antrim",
        "Perth County",
        "Windsor, Essex County",
    ])
    func decoratedAmbiguousCountiesRequireCountry(_ place: String) {
        let hit = Resolver.resolve(place)
        #expect(hit == nil, "\(place) guessed \(hit?.unitKey ?? "nil") without a country")
    }

    @Test(arguments: [
        ResolvedCase(place: "County Middlesex, England", unitKey: "eng-middlesex"),
        ResolvedCase(place: "Middlesex County, Massachusetts, United States", unitKey: "usa-massachusetts"),
        ResolvedCase(place: "Suffolk County, England", unitKey: "eng-suffolk"),
        ResolvedCase(place: "Suffolk County, New York, USA", unitKey: "usa-new-york"),
        ResolvedCase(place: "Co. Antrim, Ireland", unitKey: "nir-antrim"),
        ResolvedCase(place: "Co. Antrim, Northern Ireland", unitKey: "nir-antrim"),
        ResolvedCase(place: "Perth County, Scotland", unitKey: "sct-perthshire"),
        ResolvedCase(place: "Perth County, Ontario, Canada", unitKey: "can-ontario"),
        ResolvedCase(place: "Windsor, Essex County, Ontario, Canada", unitKey: "can-ontario"),
        ResolvedCase(place: "Windsor, Essex County, England", unitKey: "eng-essex"),
    ])
    func explicitCountryStillResolvesDecoratedNames(_ row: ResolvedCase) {
        let hit = Resolver.resolve(row.place)
        #expect(hit?.unitKey == row.unitKey,
                "\(row.place) resolved \(hit?.unitKey ?? "nil"), expected \(row.unitKey)")
    }

    @Test(arguments: [
        ResolvedCase(place: "France, England", unitKey: "eng"),
        ResolvedCase(place: "Yorkshire, France, England", unitKey: "eng-yorkshire"),
        ResolvedCase(place: "Quebec, France, Canada", unitKey: "can-quebec"),
    ])
    func rightmostSupportedCountrySurvivesEarlierForeignComponent(_ row: ResolvedCase) {
        let hit = Resolver.resolve(row.place)
        #expect(hit?.unitKey == row.unitKey,
                "\(row.place) lost rightmost country: \(hit?.unitKey ?? "nil")")
    }

    @Test(arguments: [
        "Yorkshire, England, Poland",
        "Quebec, Canada, Poland",
        "Perth County, Scotland, Australia",
    ])
    func rightmostUnsupportedCountryStopsEarlierMapNames(_ place: String) {
        #expect(Resolver.resolve(place) == nil, "\(place) must remain outside this map")
    }

    @Test(arguments: [
        ResolvedCase(place: "Suffolk County, United States", unitKey: "usa"),
        ResolvedCase(place: "County Middlesex, Canada", unitKey: "can"),
        ResolvedCase(place: "Co. Antrim, United States", unitKey: "usa"),
        ResolvedCase(place: "Perth County, Canada", unitKey: "can"),
        ResolvedCase(place: "Windsor, Essex County, Canada", unitKey: "can"),
    ])
    func countryMismatchDoesNotGuessAnOverseasCounty(_ row: ResolvedCase) {
        let hit = Resolver.resolve(row.place)
        #expect(hit?.unitKey == row.unitKey,
                "\(row.place) guessed an overseas county: \(hit?.unitKey ?? "nil")")
        #expect(hit?.isCountryOnly == true,
                "a recognised country with no matching unit must retain its outline")
    }
}
