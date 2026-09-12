import Testing
@testable import VideoScanCore

/// GH #184 item 6: "David T. McGill was born in KY, 1843." reads and
/// speaks as Kentucky. A code expands only as a standalone token in a
/// place position; never inside a word, a filename, or a person's name.
struct USStateCodesTests {

    @Test func theTableIsExactUpperCaseTwoLetterCodes() {
        #expect(USStateCodes.name(forCode: "KY") == "Kentucky")
        #expect(USStateCodes.name(forCode: "MA") == "Massachusetts")
        #expect(USStateCodes.name(forCode: "DC") == "District of Columbia")
        #expect(USStateCodes.name(forCode: "Ky") == nil)
        #expect(USStateCodes.name(forCode: "ky") == nil)
        #expect(USStateCodes.name(forCode: "Al") == nil)
        #expect(USStateCodes.name(forCode: "KYY") == nil)
        #expect(USStateCodes.name(forCode: "ZZ") == nil)
        #expect(USStateCodes.names.count == 51)
    }

    @Test func placeStringsExpandOnlyWholePartsOrTheLastToken() {
        let cases: [(String, String)] = [
            ("KY", "Kentucky"),
            ("MS", "Mississippi"),
            ("Louisville, KY", "Louisville, Kentucky"),
            ("Louisville, KY, USA", "Louisville, Kentucky, USA"),
            ("Louisville KY", "Louisville Kentucky"),
            ("Indianapolis, IN", "Indianapolis, Indiana"),
            ("IN", "Indiana"),
            // Untouched.
            ("Louisville, Jefferson, Kentucky, United States", "Louisville, Jefferson, Kentucky, United States"),
            ("Wheeling, Ohio, West Virginia", "Wheeling, Ohio, West Virginia"),
            ("Al Smith", "Al Smith"),
            ("2006_KY_trip.mov", "2006_KY_trip.mov"),
            ("Born IN hospital", "Born IN hospital"),
            ("in KY", "in Kentucky"),         // a place STRING has no prepositions: last token rule
            ("KY Louisville", "KY Louisville"), // not last, not a whole part
            ("Boston, Suffolk, Massachusetts", "Boston, Suffolk, Massachusetts"),
            ("", ""),
            ("Ireland", "Ireland"),
        ]
        for (place, expected) in cases {
            #expect(USStateCodes.expandStateCodes(inPlace: place) == expected, Comment(rawValue: place))
        }
    }

    @Test func placeStringsKeepTheirSpacing() {
        #expect(USStateCodes.expandStateCodes(inPlace: "Louisville , KY ") == "Louisville , Kentucky ")
        #expect(USStateCodes.expandStateCodes(inPlace: " KY") == " Kentucky")
    }

    @Test func proseExpandsACodeOnlyAfterAPlaceCue() {
        let cases: [(String, String)] = [
            ("David T. McGill was born in KY, 1843.", "David T. McGill was born in Kentucky, 1843."),
            ("born in KY", "born in Kentucky"),
            ("She died in MS.", "She died in Mississippi."),
            ("David T. McGill (1843–1906), born KY and James Mcgill.", "David T. McGill (1843–1906), born Kentucky and James Mcgill."),
            ("David T. McGill [GEDCOM @I19@] (1843–1906) — KY", "David T. McGill [GEDCOM @I19@] (1843–1906) — Kentucky"),
            ("They moved from OH to Louisville, KY.", "They moved from Ohio to Louisville, Kentucky."),
            ("in KY, 1843", "in Kentucky, 1843"),
            // Untouched.
            ("Al Smith was there.", "Al Smith was there."),
            ("it is OK, and recommended", "it is OK, and recommended"),
            ("Yes, OK, fine.", "Yes, OK, fine."),
            ("The file 2006_KY_trip.mov is untouched.", "The file 2006_KY_trip.mov is untouched."),
            ("He lives in Kentucky.", "He lives in Kentucky."),
            ("I'm in it.", "I'm in it."),
            ("KY", "KY"),
            ("Trust ME on this.", "Trust ME on this."),
            ("in the IN box", "in the IN box"),
        ]
        for (text, expected) in cases {
            #expect(USStateCodes.expandStateCodes(inProse: text) == expected, Comment(rawValue: text))
        }
    }

    @Test func proseKeepsWhitespaceRunsAndPunctuation() {
        #expect(USStateCodes.expandStateCodes(inProse: "born  in   KY,\n1843") == "born  in   Kentucky,\n1843")
        #expect(USStateCodes.expandStateCodes(inProse: "(born in KY)") == "(born in Kentucky)")
        #expect(USStateCodes.expandStateCodes(inProse: "born in \"KY\".") == "born in \"Kentucky\".")
    }
}
