// AdversarialPlaceFindingsTests.swift
// Red tests from the first nightly adversarial review (2026-10-01, range
// 9ed39299..05c2b9a5, brief 2), kept as regression pins:
//   efdf169d  "Co. <county>" read as Colorado
//   cafe2e2d  undotted "Mont" / "Del" read as US states
//   0bb392bd  bare "Down" beside an English county read as Northern Ireland
// Synthetic, public-repo safe: place names only.

import Testing
@testable import VideoScanCore

@Suite struct IrishCountyPrefixRegionTests {
    @Test func coDotCountyIsNeverAnAmericanRegion() {
        let american: Set<BirthplaceClassifier.BirthRegion> = [.newEngland, .restOfUS, .unitedStatesUnspecified]
        for place in ["Fenlane, Co. Cork", "Testerly, Co. Down", "Co. Mayo", "CO DUBLIN", "Fenlane, Co Cork"] {
            let region = BirthplaceClassifier.region(place)
            #expect(!american.contains(region), "\(place) → \(region)")
            #expect(LifeAndTimes.region(ofPlace: place) != .unitedStates, "\(place)")
            #expect(BirthplaceClassifier.classify(place).country != BirthplaceClassifier.unitedStates, "\(place)")
            #expect(!FamilyTreeResearchLinks.regions(ofPlace: place).contains(.unitedStates), "\(place)")
        }
        // The Irish county is recognised as Ireland, and County Down as
        // Northern Ireland, once "Co." no longer short-circuits to the US.
        #expect(BirthplaceClassifier.region("Fenlane, Co. Cork") == .ireland)
        #expect(LifeAndTimes.region(ofPlace: "Testerly, Co. Down") == .northernIreland)
    }

    /// Colorado is still Colorado where it is written as a state.
    @Test func coloradoInStatePositionStaysColorado() {
        for place in ["Synthville, Colo.", "Synthville, CO", "Synthville, Colorado", "Synthville CO USA",
                      "Synthville, El Paso Co., Colo."] {
            #expect(BirthplaceClassifier.region(place) == .restOfUS, "\(place)")
            #expect(LifeAndTimes.region(ofPlace: place) == .unitedStates, "\(place)")
        }
    }
}

@Suite struct WordLikeStateFormTests {
    @Test func capitalisedWordWithoutPeriodIsNotAState() {
        #expect(USPlaceNames.stateName(recorded: "Mont") == nil)
        #expect(USPlaceNames.stateName(recorded: "Del") == nil)
        for word in ["Cal", "Kan", "Ark", "Neb"] {
            #expect(USPlaceNames.stateName(recorded: word) == nil, "\(word)")
        }
        let american: Set<BirthplaceClassifier.BirthRegion> = [.newEngland, .restOfUS, .unitedStatesUnspecified]
        for place in ["Mont Saint-Michel", "Puerto Del Rosario"] {
            let region = BirthplaceClassifier.region(place)
            #expect(!american.contains(region), "\(place) → \(region)")
            #expect(LifeAndTimes.region(ofPlace: place) != .unitedStates, "\(place)")
        }
    }

    /// The dotted and upper-case forms the header promises still count.
    @Test func dottedOrUpperCaseWordLikeFormsAreStates() {
        #expect(USPlaceNames.stateName(recorded: "Mont.") == "Montana")
        #expect(USPlaceNames.stateName(recorded: "MONT") == "Montana")
        #expect(USPlaceNames.stateName(recorded: "Del.") == "Delaware")
        #expect(USPlaceNames.stateName(recorded: "Cal.") == "California")
        #expect(USPlaceNames.stateName(recorded: "del.") == nil)
        #expect(BirthplaceClassifier.region("Synthburg, Mont.") == .restOfUS)
    }
}

/// ea7b6739 (brief 3), the Core side: "W.I." (West Indies) and "W.A."
/// (Western Australia) are dotted initials, and Wisconsin and Washington
/// are one-word names: no state was ever written that way. Dotted initials
/// name a state only when they ARE its initials ("N.H.", "R.I.", "D.C.").
@Suite struct DottedInitialsStateFormTests {
    @Test func westIndiesAndWesternAustraliaAreNotStates() {
        for form in ["W.I.", "W. I.", "W.A.", "W. A."] {
            #expect(USPlaceNames.stateName(recorded: form) == nil, "\(form)")
        }
        let american: Set<BirthplaceClassifier.BirthRegion> = [.newEngland, .restOfUS, .unitedStatesUnspecified]
        for place in ["Kingston, Jamaica, W.I.", "Bridgetown, Barbados, W.I.", "Perth, W.A."] {
            #expect(!american.contains(BirthplaceClassifier.region(place)), "\(place)")
            #expect(LifeAndTimes.region(ofPlace: place) != .unitedStates, "\(place)")
            #expect(BirthplaceClassifier.classify(place).country != BirthplaceClassifier.unitedStates, "\(place)")
            #expect(!USPlaceNames.mentionsUnitedStates(place), "\(place)")
        }
    }

    @Test func realDottedInitialsStillNameTheirState() {
        for (form, state) in [("N.H.", "New Hampshire"), ("N. H.", "New Hampshire"), ("R.I.", "Rhode Island"),
                              ("N.Y.", "New York"), ("D.C.", "District of Columbia"), ("W.V.", "West Virginia"),
                              ("Va.", "Virginia"), ("WI", "Wisconsin"), ("WA", "Washington")] {
            #expect(USPlaceNames.stateName(recorded: form) == state, "\(form)")
        }
    }
}

@Suite struct BareCountyDownMarkerTests {
    @Test func downBesideAnEnglishCountyIsNotNorthernIreland() {
        #expect(LifeAndTimes.region(ofPlace: "Down, Kent") != .northernIreland)
        #expect(LifeAndTimes.region(ofPlace: "Down, Kent, United Kingdom") != .northernIreland)
        #expect(LifeAndTimes.region(ofPlace: "Down, Kent, England") != .northernIreland)
        // County Down with Ireland after it must stay Northern Ireland (F5).
        #expect(LifeAndTimes.region(ofPlace: "Down, Ireland") == .northernIreland)
        #expect(LifeAndTimes.region(ofPlace: "Newry, Down") == .northernIreland)
    }
}
