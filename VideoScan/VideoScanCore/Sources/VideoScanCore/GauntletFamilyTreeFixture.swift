// GauntletFamilyTreeFixture.swift
//
// The SYNTHETIC family tree Gauntlet flow 7 loads (open the Family Map from
// the Family Tree tab). Pure text, no I/O: the UI-test runner writes it into
// its per-run sandbox and hands the folder to the app with
// `-gauntletFamilyTreeDir` (GauntletSeams.familyTreeDirectory); the unit
// tests parse and map the same bytes. Lives in VideoScanCore for the same
// reason as GauntletFixturePlan — it is the one module both the unit-test
// target and the UI-test bundle link.
//
// Every name is invented (no real family, no real person); every birthplace
// is a well-known city in a country the Family Map draws, so the map has
// something to shade. Three generations, eleven people:
//
//   Cornelius Quillfeather ─┬─ Philippa Thistlewood    Leopold Marchbank ─┬─ Henrietta Vantongeren
//                           │                                             │
//          ┌────────────────┴──┐                       ┌──────────────────┴──┐
//   Fennimore Quillfeather  Barnaby Quillfeather ─┬─ Odessa Marchbank   Wilhelmina Marchbank
//                                                 │
//                                 ┌───────────────┴──┐
//                         Juniper Quillfeather   Rosalind Quillfeather
//                                 │
//                         (spouse) Caspian Ollerenshaw
//
// Juniper is the first INDI, so the parser makes her the tree's root (the
// "home person" Walk Tree… starts from by default).

import Foundation

public enum GauntletFamilyTreeFixture {

    /// The file the runner writes. `test_` prefix like every Gauntlet fixture.
    public static let fileName = "test_gauntlet_family.ged"

    public static let rootID = "@I1@"
    public static let peopleCount = 11

    /// Every person's display name, in xref order (@I1@ … @I11@).
    public static let names = [
        "Juniper Quillfeather", "Barnaby Quillfeather", "Odessa Marchbank",
        "Cornelius Quillfeather", "Philippa Thistlewood", "Leopold Marchbank",
        "Henrietta Vantongeren", "Rosalind Quillfeather", "Fennimore Quillfeather",
        "Wilhelmina Marchbank", "Caspian Ollerenshaw",
    ]

    public static let gedcom = """
    0 HEAD
    1 SOUR VideoScanGauntlet
    1 GEDC
    2 VERS 5.5.1
    1 CHAR UTF-8
    0 @I1@ INDI
    1 NAME Juniper /Quillfeather/
    1 SEX F
    1 BIRT
    2 DATE 12 MAY 1990
    2 PLAC Boston, Massachusetts, United States
    1 FAMC @F1@
    1 FAMS @F4@
    0 @I2@ INDI
    1 NAME Barnaby /Quillfeather/
    1 SEX M
    1 BIRT
    2 DATE 3 FEB 1960
    2 PLAC Chicago, Illinois, United States
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Odessa /Marchbank/
    1 SEX F
    1 BIRT
    2 DATE 21 AUG 1962
    2 PLAC Toronto, Ontario, Canada
    1 FAMC @F3@
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Cornelius /Quillfeather/
    1 SEX M
    1 BIRT
    2 DATE 1930
    2 PLAC Sheffield, Yorkshire, England
    1 DEAT
    2 DATE 2001
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Philippa /Thistlewood/
    1 SEX F
    1 BIRT
    2 DATE 1932
    2 PLAC Edinburgh, Scotland
    1 DEAT
    2 DATE 2010
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Leopold /Marchbank/
    1 SEX M
    1 BIRT
    2 DATE 1934
    2 PLAC Cork, Ireland
    1 DEAT
    2 DATE 1999
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Henrietta /Vantongeren/
    1 SEX F
    1 BIRT
    2 DATE 1936
    2 PLAC Lyon, France
    1 FAMS @F3@
    0 @I8@ INDI
    1 NAME Rosalind /Quillfeather/
    1 SEX F
    1 BIRT
    2 DATE 1993
    2 PLAC Boston, Massachusetts, United States
    1 FAMC @F1@
    0 @I9@ INDI
    1 NAME Fennimore /Quillfeather/
    1 SEX M
    1 BIRT
    2 DATE 1963
    2 PLAC Chicago, Illinois, United States
    1 FAMC @F2@
    0 @I10@ INDI
    1 NAME Wilhelmina /Marchbank/
    1 SEX F
    1 BIRT
    2 DATE 1965
    2 PLAC Hamburg, Germany
    1 FAMC @F3@
    0 @I11@ INDI
    1 NAME Caspian /Ollerenshaw/
    1 SEX M
    1 BIRT
    2 DATE 1988
    2 PLAC Portland, Maine, United States
    1 FAMS @F4@
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I3@
    1 CHIL @I1@
    1 CHIL @I8@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I5@
    1 CHIL @I2@
    1 CHIL @I9@
    0 @F3@ FAM
    1 HUSB @I6@
    1 WIFE @I7@
    1 CHIL @I3@
    1 CHIL @I10@
    0 @F4@ FAM
    1 HUSB @I11@
    1 WIFE @I1@
    0 TRLR

    """
}
