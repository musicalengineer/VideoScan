import Testing
@testable import VideoScanCore

/// GH #184 item 6: "David T. McGill was born in KY, 1843." — the
/// birth-place route phrases the code as the state; the tree's own value
/// is untouched.
struct ArchivistBiographyPolicyStateCodeTests {
    private static let tree = """
    0 HEAD
    0 @I19@ INDI
    1 NAME David T. /McGill/
    1 SEX M
    1 BIRT
    2 DATE 1843
    2 PLAC KY
    1 DEAT
    2 DATE 1906
    2 PLAC MS
    0 @I15@ INDI
    1 NAME Hallie Mae /McGill/
    1 SEX F
    1 BIRT
    2 DATE MAR 1876
    2 PLAC Louisville, Jefferson, Kentucky, United States
    0 TRLR
    """

    @Test func birthAndDeathPlacesReadTheStateName() {
        let graph = GedcomFamilyGraph(gedcomText: Self.tree)
        let birth = ArchivistBiographyPolicy.lifePlace(personID: "@I19@", birth: true, in: graph)
        #expect(birth.text == "David T. McGill was born in Kentucky, 1843.")
        let death = ArchivistBiographyPolicy.lifePlace(personID: "@I19@", birth: false, in: graph)
        #expect(death.text == "David T. McGill died in Mississippi, 1906.")
        // Stored value untouched: display/speech only.
        #expect(graph.people["@I19@"]?.birthPlace == "KY")
        #expect(graph.people["@I19@"]?.deathPlace == "MS")
    }

    @Test func aFullPlaceIsUnchanged() {
        let graph = GedcomFamilyGraph(gedcomText: Self.tree)
        let birth = ArchivistBiographyPolicy.lifePlace(personID: "@I15@", birth: true, in: graph)
        #expect(birth.text == "Hallie Mae McGill was born in Louisville, Jefferson, Kentucky, United States, MAR 1876.")
    }
}
