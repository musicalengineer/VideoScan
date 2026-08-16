import Testing
@testable import VideoScanCore

struct ArchivistBiographyPolicyTests {
    private static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Alex /River/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1 JAN 1900
    1 DEAT
    2 DATE 2 FEB 1980
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Bailey /River/
    1 SEX F
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Alex /River/ Jr
    1 SEX M
    1 FAMC @F1@
    0 @I4@ INDI
    1 NAME Casey /Solo/
    1 SEX X
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.tree)
    }

    @Test func biographyContainsOnlyGraphFactsAndProvenance() {
        let answer = ArchivistBiographyPolicy.biography(
            for: "alex river jr", in: graph)

        #expect(answer.state == .answered)
        #expect(answer.text == "Alex River Jr — child of Alex River Sr and Bailey River.")
        #expect(answer.basis == "Basis: imported family tree (GEDCOM).")
        #expect(answer.catalogPersonName == "Alex River Jr")
        #expect(answer.candidates.isEmpty)
    }

    @Test func ambiguousNameIsSurfacedRatherThanGuessed() {
        let answer = ArchivistBiographyPolicy.biography(for: "alex", in: graph)

        #expect(answer.state == .ambiguous)
        #expect(answer.candidates.map(\.name)
                == ["Alex River Jr", "Alex River Sr"])
        #expect(answer.catalogPersonName == nil)
        #expect(answer.basis.hasPrefix("Checked:"))
    }

    @Test func unknownPersonDeclinesWithCheckedSource() {
        let answer = ArchivistBiographyPolicy.biography(for: "Morgan", in: graph)

        #expect(answer.state == .notFound)
        #expect(answer.text.contains("don't find"))
        #expect(answer.basis == "Checked: imported family tree (GEDCOM).")
        #expect(answer.catalogPersonName == nil)
    }

    @Test func knownPersonWithNoBiographyFactsSaysSo() {
        let answer = ArchivistBiographyPolicy.biography(for: "Casey", in: graph)

        #expect(answer.state == .missingFact)
        #expect(answer.text == "Casey Solo is in the family tree, but it records no further details.")
        #expect(answer.basis == "Basis: imported family tree (GEDCOM).")
    }

    @Test func datesDistinguishAnsweredMissingAndAmbiguous() {
        let birth = ArchivistBiographyPolicy.lifeDate(
            for: "alex river sr", birth: true, in: graph)
        #expect(birth.state == .answered)
        #expect(birth.text == "Alex River Sr was born 1 JAN 1900.")

        let missing = ArchivistBiographyPolicy.lifeDate(
            for: "Bailey", birth: false, in: graph)
        #expect(missing.state == .missingFact)
        #expect(missing.text.contains("doesn't record a death date"))

        let ambiguous = ArchivistBiographyPolicy.lifeDate(
            for: "Alex", birth: true, in: graph)
        #expect(ambiguous.state == .ambiguous)
        #expect(ambiguous.candidates.count == 2)
    }

    @Test func repeatedDisplayNamesResolveByStableGedcomID() throws {
        let repeated = GedcomFamilyGraph(gedcomText: """
        0 @I10@ INDI
        1 NAME John /River/
        1 BIRT
        2 DATE 1901
        0 @I20@ INDI
        1 NAME John /River/
        1 BIRT
        2 DATE 1955
        0 TRLR
        """)

        let ambiguous = ArchivistBiographyPolicy.biography(
            for: "John River", in: repeated)
        #expect(ambiguous.state == .ambiguous)
        #expect(ambiguous.candidates.map(\.label)
                == ["John River (b. 1901)", "John River (b. 1955)"])

        let chosen = try #require(
            ambiguous.candidates.first { $0.id == "@I20@" })
        let answer = ArchivistBiographyPolicy.biography(
            personID: chosen.id, in: repeated)
        #expect(answer.state == .answered)
        #expect(answer.text == "John River — born 1955.")
    }

    @Test func biographyIsIndependentOfFamilyAndChildDeclarationOrder() throws {
        let firstOrder = GedcomFamilyGraph(gedcomText: """
        0 @S@ INDI
        1 NAME Parent /One/
        1 FAMS @F2@
        1 FAMS @F1@
        0 @Z@ INDI
        1 NAME Zoe /Partner/
        1 FAMS @F2@
        0 @C2@ INDI
        1 NAME Sam /Child/
        1 FAMC @F2@
        0 @A@ INDI
        1 NAME Aaron /Child/
        1 FAMC @F2@
        0 @B@ INDI
        1 NAME Amy /Partner/
        1 FAMS @F1@
        0 @C1@ INDI
        1 NAME Sam /Child/
        1 FAMC @F1@
        0 @F2@ FAM
        1 HUSB @S@
        1 WIFE @Z@
        1 CHIL @C2@
        1 CHIL @A@
        0 @F1@ FAM
        1 HUSB @S@
        1 WIFE @B@
        1 CHIL @C1@
        0 TRLR
        """)
        let reversedOrder = GedcomFamilyGraph(gedcomText: """
        0 @C1@ INDI
        1 NAME Sam /Child/
        1 FAMC @F1@
        0 @B@ INDI
        1 NAME Amy /Partner/
        1 FAMS @F1@
        0 @A@ INDI
        1 NAME Aaron /Child/
        1 FAMC @F2@
        0 @C2@ INDI
        1 NAME Sam /Child/
        1 FAMC @F2@
        0 @Z@ INDI
        1 NAME Zoe /Partner/
        1 FAMS @F2@
        0 @S@ INDI
        1 NAME Parent /One/
        1 FAMS @F1@
        1 FAMS @F2@
        0 @F1@ FAM
        1 HUSB @S@
        1 WIFE @B@
        1 CHIL @C1@
        0 @F2@ FAM
        1 HUSB @S@
        1 WIFE @Z@
        1 CHIL @A@
        1 CHIL @C2@
        0 TRLR
        """)

        let first = ArchivistBiographyPolicy.biography(
            personID: "@S@", in: firstOrder)
        let reversed = ArchivistBiographyPolicy.biography(
            personID: "@S@", in: reversedOrder)

        #expect(first == reversed)
        #expect(first.text
                == "Parent One — married to Amy Partner, Zoe Partner; "
                    + "parent of Aaron Child, Sam Child, Sam Child.")
        #expect(first.basis == ArchivistBiographyPolicy.gedcomBasis)

        let firstSubject = try #require(firstOrder.people["@S@"])
        let reversedSubject = try #require(reversedOrder.people["@S@"])
        let firstChildIDs = ArchivistBiographyPolicy.orderedPeople(
            firstOrder.relatives(.children, of: firstSubject)).map(\.id)
        let reversedChildIDs = ArchivistBiographyPolicy.orderedPeople(
            reversedOrder.relatives(.children, of: reversedSubject)).map(\.id)
        #expect(firstChildIDs == ["@A@", "@C1@", "@C2@"]) // ID breaks name ties.
        #expect(reversedChildIDs == firstChildIDs)
    }
}
