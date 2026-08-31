import Testing
import Foundation
import VideoScanCore

// MARK: - FamilyTreeResearchLinksTests
//
// "When someone is born in Ireland we know we have to go out to these Irish
// search sites" (Rick, 2026-08-31). The rule runs off the place string,
// which only became available to the app the day before.
//
// The negative cases matter as much as the positive: offering Irish
// archives for a man born in Boston is the kind of noise that makes a
// feature get switched off.

struct FamilyTreeResearchLinksTests {

    private func regions(_ birth: String?, _ death: String? = nil)
        -> Set<FamilyTreeResearchLinks.Region> {
        FamilyTreeResearchLinks.regions(birthPlace: birth, deathPlace: death)
    }

    // MARK: Region detection

    @Test func irelandIsFoundFromTheCountryName() {
        #expect(regions("Cork, Ireland") == [.ireland])
        #expect(regions("Derry, Ireland") == [.ireland])
    }

    /// Plenty of Irish records name only the county.
    @Test func irelandIsFoundFromACountyAlone() {
        for place in ["Co. Mayo", "Ballina, Mayo", "Skibbereen, County Cork", "Tipperary"] {
            #expect(regions(place) == [.ireland],
                    Comment(rawValue: "\(place) should resolve to Ireland"))
        }
    }

    /// Emigration is the normal case in this tree: born in Cork, died in
    /// Boston. Both sides are worth searching, so this returns two.
    @Test func emigrationYieldsBothCountries() {
        #expect(regions("Cork, Ireland", "Boston, Massachusetts")
                == [.ireland, .unitedStates])
    }

    @Test func aBostonManIsNotOfferedIrishArchives() {
        #expect(regions("Boston, Massachusetts") == [.unitedStates])
        #expect(!regions("Boston, Massachusetts").contains(.ireland))
    }

    @Test func englandIsNotIreland() {
        #expect(regions("Yorkshire, England") == [.england])
        #expect(regions("England") == [.england])
    }

    @Test func noPlaceYieldsNoRegions() {
        #expect(regions(nil, nil).isEmpty)
        #expect(regions("").isEmpty)
    }

    // MARK: Links

    /// FamilySearch comes first on purpose — it has indexed the Irish
    /// census and civil registration, so the record may already be attached
    /// to the profile.
    @Test func familySearchLeadsWhenAnIDIsKnown() throws {
        let links = FamilyTreeResearchLinks.links(
            name: "Peter Roynane", surname: "Roynane", birthYear: 1861,
            birthPlace: "Cork, Ireland", deathPlace: nil, familySearchID: "GVQV-NW3")
        let first = try #require(links.first)
        #expect(first.title.contains("FamilySearch"))
        #expect(first.url.absoluteString.contains("GVQV-NW3"))
        #expect(first.isPrefilled)
    }

    @Test func anIrishBirthOffersTheIrishArchives() {
        let links = FamilyTreeResearchLinks.links(
            name: "Peter Roynane", surname: "Roynane", birthYear: 1861,
            birthPlace: "Cork, Ireland", deathPlace: nil, familySearchID: nil)
        let titles = links.map(\.title).joined(separator: " | ")
        #expect(titles.contains("Census of Ireland"))
        #expect(titles.contains("civil records"))
    }

    @Test func aPersonWithNoPlaceAndNoIDGetsNothingRatherThanGuesses() {
        let links = FamilyTreeResearchLinks.links(
            name: "Unknown Person", surname: nil, birthYear: nil,
            birthPlace: nil, deathPlace: nil, familySearchID: nil)
        #expect(links.isEmpty, "no evidence means no suggestions, not every archive on earth")
    }

    /// A link that lands on an error page is worse than one that lands on a
    /// search form, so the flag has to be honest about which it is.
    @Test func onlyVerifiedLinksClaimToBePrefilled() throws {
        let links = FamilyTreeResearchLinks.links(
            name: "Peter Roynane", surname: "Roynane", birthYear: 1861,
            birthPlace: "Cork, Ireland", deathPlace: nil, familySearchID: "GVQV-NW3")
        let census = try #require(links.first { $0.title.contains("Census of Ireland") })
        #expect(census.isPrefilled == false,
                "the Irish state sites' query parameters are unverified — the link lands on their form")
        #expect(links.allSatisfy { $0.url.scheme == "https" })
    }

    @Test func theFamilySearchRecordSearchCarriesTheNameAndAYearWindow() throws {
        let url = try #require(FamilyTreeResearchLinks.familySearchRecordSearch(
            name: "Peter Roynane", surname: "Roynane", birthYear: 1861, country: "Ireland"))
        let q = url.absoluteString
        #expect(q.contains("q.givenName=Peter"))
        #expect(q.contains("q.surname=Roynane"))
        #expect(q.contains("1856"), "a five-year window either side of 1861")
        #expect(q.contains("1866"))
    }

    @Test func everyLinkExplainsWhyItIsBeingOffered() {
        let links = FamilyTreeResearchLinks.links(
            name: "Peter Roynane", surname: "Roynane", birthYear: 1861,
            birthPlace: "Cork, Ireland", deathPlace: "Boston, Massachusetts",
            familySearchID: "GVQV-NW3")
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { !$0.reason.isEmpty },
                "a list of bare links is a list nobody reads")
    }
}
