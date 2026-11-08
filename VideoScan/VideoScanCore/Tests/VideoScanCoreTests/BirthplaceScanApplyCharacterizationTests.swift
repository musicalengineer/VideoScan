import Testing
import Foundation
@testable import VideoScanCore

// Characterization of BirthplaceUnitResolver.Scan.apply (2026-11-07),
// written against the version BEFORE it was decomposed. Two layers:
//   1. resolve() over places that exercise each token arm (unit, country,
//      coarse, foreign, outside, today, alternatives), pinned to today's
//      answers;
//   2. Scan.apply driven token by token, pinning the scan STATE each arm
//      leaves behind (country, its range, the search set, stopped) — the
//      part resolve() only shows indirectly.
// FamilyMapResolverTests and the adversarial suites own the wider tables.

struct BirthplaceScanApplyCharacterizationTests {
    typealias R = BirthplaceUnitResolver

    /// (place, unit key or nil, matched component or nil)
    static let pinned: [(String, String?, String?)] = [
        // .unit: alone only when unambiguous; otherwise needs a country.
        ("Yorkshire", "eng-yorkshire", "Yorkshire"),
        ("Middlesex", nil, nil),
        ("Co. Essex", nil, nil),
        ("Middlesex, England", "eng-middlesex", "Middlesex"),
        ("Yorkshire, France", "fra", "France"),
        // .country: the rightmost wins; a contradicted European one stops.
        ("France, England", "eng", "England"),
        ("Germany, England", "eng", "England"),
        ("England, United Kingdom", "eng", "England"),
        ("France, United Kingdom", nil, nil),
        // .coarse: narrows, shades nothing alone, never widens a country.
        ("Yorkshire, United Kingdom", "eng-yorkshire", "Yorkshire"),
        ("United Kingdom", nil, nil),
        ("Virginia, United Kingdom, United States", "usa-virginia", "Virginia"),
        // .foreign: stops only while no supported country is established.
        ("Quebec, Poland, Canada", "can-quebec", "Quebec"),
        ("Yorkshire, Poland", nil, nil),
        // .outside: ends the scan unless the country is excepted.
        ("Breslau, Silesia, Germany", nil, nil),
        // .today: placed where the ground is now.
        ("Strasbourg, Alsace, Germany", "fra-grand-est", "Alsace"),
        // .alternatives: a shared name is a unit only of the country found.
        ("Maastricht, Limburg, Netherlands", "nld-limburg", "Limburg"),
        ("Hasselt, Limburg, Belgium", "bel-limburg", "Limburg"),
        ("Limburg", nil, nil),
    ]

    @Test func resolvePinsEachTokenArm() {
        for (place, key, matched) in Self.pinned {
            let hit = R.resolve(place)
            #expect(hit?.unitKey == key, "\(place) → \(hit?.unitKey ?? "nil")")
            #expect(hit?.matchedComponent == matched, "\(place) matched \(hit?.matchedComponent ?? "nil")")
        }
    }

    // MARK: Scan state, token by token

    /// Run `body` over a Scan of `text`'s bytes (the buffer lives only here).
    private func scanning<T>(_ text: String, _ body: (inout R.Scan) -> T) -> T {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { bytes -> T in
            var scan = R.Scan(bytes: bytes)
            return body(&scan)
        }!
    }

    private let yorkshire = R.Token.unit(.england, name: "Yorkshire", key: "eng-yorkshire")
    private let middlesex = R.Token.unit(.england, name: "Middlesex", key: "eng-middlesex")

    @Test func aUnitWithNoSearchIsTakenUnlessItsNameIsAmbiguous() {
        let hit = scanning("Yorkshire") { $0.apply(yorkshire, key: "yorkshire", range: 0..<9) }
        #expect(hit == R.Hit(unitKey: "eng-yorkshire", country: .england, kind: .county, matchedComponent: "Yorkshire"))
        let refused = scanning("County Middlesex") { scan -> (R.Hit?, Bool) in
            (scan.apply(middlesex, key: "county middlesex", range: 0..<16), scan.stopped)
        }
        #expect(refused.0 == nil)
        #expect(!refused.1)
    }

    @Test func aUnitOutsideTheSearchIsSkippedNotStopped() {
        let result = scanning("Yorkshire") { scan -> (R.Hit?, Bool) in
            scan.searches = [.france]
            return (scan.apply(yorkshire, key: "yorkshire", range: 0..<9), scan.stopped)
        }
        #expect(result.0 == nil)
        #expect(!result.1)
        let inside = scanning("Middlesex") { scan -> R.Hit? in
            scan.searches = R.homeNations
            return scan.apply(middlesex, key: "middlesex", range: 0..<9)
        }
        #expect(inside?.unitKey == "eng-middlesex")
    }

    @Test func theFirstCountryIsKeptWithItsRangeAndSearches() {
        let state = scanning("Wales, England") { scan -> (FamilyMap.Country?, Range<Int>, Set<FamilyMap.Country>?, Bool) in
            _ = scan.apply(.country(.england, searches: [.england]), key: "england", range: 7..<14)
            _ = scan.apply(.country(.wales, searches: [.wales]), key: "wales", range: 0..<5)
            return (scan.country, scan.countryRange, scan.searches, scan.stopped)
        }
        #expect(state.0 == .england)
        #expect(state.1 == 7..<14)
        #expect(state.2 == [.england])
        #expect(!state.3)
    }

    @Test func aEuropeanCountryContradictedByACoarseNameStops() {
        let state = scanning("France") { scan -> (FamilyMap.Country?, Bool) in
            _ = scan.apply(.coarse(R.homeNations), key: "united kingdom", range: 0..<6)
            _ = scan.apply(.country(.france, searches: [.france]), key: "france", range: 0..<6)
            return (scan.country, scan.stopped)
        }
        #expect(state.0 == nil)
        #expect(state.1)
        // A non-European country under the same coarse name is simply taken
        // (the search set then follows the country).
        let taken = scanning("Canada") { scan -> (FamilyMap.Country?, Set<FamilyMap.Country>?, Bool) in
            _ = scan.apply(.coarse(R.homeNations), key: "united kingdom", range: 0..<6)
            _ = scan.apply(.country(.canada, searches: [.canada]), key: "canada", range: 0..<6)
            return (scan.country, scan.searches, scan.stopped)
        }
        #expect(taken.0 == .canada)
        #expect(taken.1 == [.canada])
        #expect(!taken.2)
    }

    @Test func aCoarseNameNarrowsOnlyAnOpenSearch() {
        let narrowed = scanning("UK") { scan -> Set<FamilyMap.Country>? in
            _ = scan.apply(.coarse(R.homeNations), key: "uk", range: 0..<2)
            return scan.searches
        }
        #expect(narrowed == R.homeNations)
        let kept = scanning("UK") { scan -> (Set<FamilyMap.Country>?, FamilyMap.Country?) in
            scan.searches = [.unitedStates]
            _ = scan.apply(.coarse(R.homeNations), key: "uk", range: 0..<2)
            return (scan.searches, scan.country)
        }
        #expect(kept.0 == [.unitedStates])
        #expect(kept.1 == nil)
    }

    @Test func aForeignCountryStopsOnlyBeforeACountryIsKnown() {
        let open = scanning("Poland") { scan -> Bool in
            _ = scan.apply(.foreign, key: "poland", range: 0..<6)
            return scan.stopped
        }
        #expect(open)
        let known = scanning("Poland") { scan -> Bool in
            scan.country = .canada
            _ = scan.apply(.foreign, key: "poland", range: 0..<6)
            return scan.stopped
        }
        #expect(!known)
    }

    @Test func outsideGroundStopsUnlessTheCountryIsExcepted() {
        let stops = scanning("Silesia") { scan -> Bool in
            scan.country = .germany
            _ = scan.apply(.outside(except: [.spain]), key: "silesia", range: 0..<7)
            return scan.stopped
        }
        #expect(stops)
        let noCountry = scanning("Silesia") { scan -> Bool in
            _ = scan.apply(.outside(except: [.spain]), key: "silesia", range: 0..<7)
            return scan.stopped
        }
        #expect(noCountry)
        let excepted = scanning("Galicia") { scan -> (R.Hit?, Bool) in
            scan.country = .spain
            return (scan.apply(.outside(except: [.spain]), key: "galicia", range: 0..<7), scan.stopped)
        }
        #expect(excepted.0 == nil)
        #expect(!excepted.1)
    }

    @Test func todayAndAlternativesAreDelegated() {
        let today = scanning("Alsace") { scan -> R.Hit? in
            scan.country = .germany
            scan.searches = [.germany]
            return scan.apply(.today(.unit(.france, name: "Grand Est", key: "fra-grand-est")), key: "alsace", range: 0..<6)
        }
        #expect(today?.unitKey == "fra-grand-est")
        #expect(today?.matchedComponent == "Alsace")
        let shared = R.Token.alternatives([.unit(.netherlands, name: "Limburg", key: "nld-limburg"),
                                           .unit(.belgium, name: "Limburg", key: "bel-limburg")])
        let belgian = scanning("Limburg") { scan -> R.Hit? in
            scan.searches = [.belgium]
            return scan.apply(shared, key: "limburg", range: 0..<7)
        }
        #expect(belgian?.unitKey == "bel-limburg")
        let alone = scanning("Limburg") { $0.apply(shared, key: "limburg", range: 0..<7) }
        #expect(alone == nil)
    }
}

/// The two rules Scan.apply delegates to, one at a time.
struct BirthplaceScanApplyStepTests {
    typealias R = BirthplaceUnitResolver

    private func scanning<T>(_ text: String, _ body: (inout R.Scan) -> T) -> T {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { bytes -> T in
            var scan = R.Scan(bytes: bytes)
            return body(&scan)
        }!
    }

    @Test func acceptUnitFollowsTheSearchSetOrTheAmbiguityRule() {
        let open = scanning("Yorkshire") { $0.acceptUnit(of: .england, unitKey: "eng-yorkshire", key: "yorkshire", range: 0..<9) }
        #expect(open?.unitKey == "eng-yorkshire")
        #expect(open?.kind == .county)
        let ambiguous = scanning("Co. Essex") { $0.acceptUnit(of: .england, unitKey: "eng-essex", key: "co essex", range: 0..<9) }
        #expect(ambiguous == nil)
        let outside = scanning("Yorkshire") { scan -> R.Hit? in
            scan.searches = [.unitedStates]
            return scan.acceptUnit(of: .england, unitKey: "eng-yorkshire", key: "yorkshire", range: 0..<9)
        }
        #expect(outside == nil)
        let inside = scanning("Essex") { scan -> R.Hit? in
            scan.searches = [.england]
            return scan.acceptUnit(of: .england, unitKey: "eng-essex", key: "essex", range: 0..<5)
        }
        #expect(inside?.matchedComponent == "Essex")
    }

    @Test func establishCountryKeepsTheFirstAndRefusesAContradiction() {
        let first = scanning("Wales, England") { scan -> (FamilyMap.Country?, Range<Int>, Bool) in
            scan.establishCountry(.england, searches: [.england], range: 7..<14)
            scan.establishCountry(.wales, searches: [.wales], range: 0..<5)
            return (scan.country, scan.countryRange, scan.stopped)
        }
        #expect(first.0 == .england)
        #expect(first.1 == 7..<14)
        #expect(!first.2)
        let contradiction = scanning("France") { scan -> (FamilyMap.Country?, Bool) in
            scan.searches = R.homeNations
            scan.establishCountry(.france, searches: [.france], range: 0..<6)
            return (scan.country, scan.stopped)
        }
        #expect(contradiction.0 == nil)
        #expect(contradiction.1)
        let overlapping = scanning("England") { scan -> (FamilyMap.Country?, Set<FamilyMap.Country>?) in
            scan.searches = R.homeNations
            scan.establishCountry(.england, searches: [.england], range: 0..<7)
            return (scan.country, scan.searches)
        }
        #expect(overlapping.0 == .england)
        #expect(overlapping.1 == [.england])
    }
}
