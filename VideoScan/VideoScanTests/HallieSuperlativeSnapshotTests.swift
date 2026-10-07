// HallieSuperlativeSnapshotTests.swift
// GH #281 R3 (2026-10-06): characterization snapshots for
// HallieLineageAnswer.superlative, recorded from the pre-refactor code
// (main@ebcd2f09) before the function was split. Full grid: every
// SuperlativeKind (plus a place nobody was born in) × every scope shape
// (whole tree, surname found / not found, ancestors / descendants of the
// owner, a name, a leaf, an unknown name, the other side of the owner / of
// the spouse / unresolved, an owner with no spouse), under three owner
// contexts. Synthetic tree only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Superlative answer: characterization snapshots")
struct HallieSuperlativeSnapshotTests {
    typealias Q = HallieLineageQuestion

    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    1 BIRT
    2 DATE 4 MAR 1959
    2 PLAC Boston, Massachusetts
    1 FAMC @F1@
    1 FAMS @F5@
    0 @I2@ INDI
    1 NAME Rick /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1929
    2 PLAC Boston, Massachusetts
    1 DEAT
    2 DATE 2008
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 BIRT
    2 DATE 1930
    2 PLAC Dublin, Ireland
    1 FAMS @F1@
    0 @I7@ INDI
    1 NAME George /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1898
    2 PLAC Cork, Ireland
    1 DEAT
    2 DATE 1990
    1 FAMS @F2@
    0 @I8@ INDI
    1 NAME Muriel /Lamb/
    1 SEX F
    1 BIRT
    2 DATE 1899
    1 DEAT
    2 DATE 1950
    1 FAMS @F2@
    0 @I30@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 1959
    1 FAMC @F7@
    1 FAMS @F5@
    0 @I31@ INDI
    1 NAME Owen /Hudson/
    1 SEX M
    1 BIRT
    2 DATE 1930
    1 DEAT
    2 DATE 2010
    1 FAMC @F8@
    1 FAMS @F7@
    0 @I32@ INDI
    1 NAME Gruffudd ap /Einion/
    1 SEX M
    1 BIRT
    2 DATE 780
    1 FAMS @F8@
    0 @I40@ INDI
    1 NAME Dan /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1984
    1 FAMC @F5@
    0 @I41@ INDI
    1 NAME Mark /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1986
    1 FAMC @F5@
    0 @I43@ INDI
    1 NAME Timmy /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1999
    1 FAMC @F5@
    0 @I50@ INDI
    1 NAME Ann /Able/
    1 SEX F
    1 BIRT
    2 DATE 1999
    0 @I51@ INDI
    1 NAME Bea /Baker/
    1 SEX F
    1 BIRT
    2 DATE 1999
    0 @I52@ INDI
    1 NAME Zed /Solo/
    1 SEX M
    1 BIRT
    2 DATE 1999
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I3@
    1 MARR
    2 DATE 1955
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I7@
    1 WIFE @I8@
    1 MARR
    2 DATE 12 JUN 1925
    1 CHIL @I2@
    0 @F5@ FAM
    1 HUSB @I1@
    1 WIFE @I30@
    1 MARR
    2 DATE 1980
    1 CHIL @I40@
    1 CHIL @I41@
    1 CHIL @I43@
    0 @F7@ FAM
    1 HUSB @I31@
    1 CHIL @I30@
    0 @F8@ FAM
    1 HUSB @I32@
    1 CHIL @I31@
    0 TRLR
    """

    static let graph = GedcomFamilyGraph(gedcomText: tree)

    static let contexts: [(String, HallieTurnExecutor.Context)] = [
        ("pinned owner", .init(profiles: [], graph: graph, assetConfiguration: { .emptyForTests },
                               speakers: .init(ownerName: "Rick Breen", archivistName: nil,
                                               archivistPersonName: nil, ownerFamilySearchID: "GVQV-NW3"))),
        ("no owner", .init(profiles: [], graph: graph, assetConfiguration: { .emptyForTests }, speakers: .none)),
        ("owner without spouse", .init(profiles: [], graph: graph, assetConfiguration: { .emptyForTests },
                                       speakers: .init(ownerName: "Zed Solo", archivistName: nil))),
    ]

    static let kinds: [Q.SuperlativeKind] = [
        .earliestBorn, .latestBorn, .longestLived, .latestDied, .earliestMarried,
        .mostChildren, .deepestAncestor, .firstBornIn(place: "Ireland"), .firstBornIn(place: "Atlantis"),
    ]

    static let scopes: [Q.SuperlativeScope] = [
        .wholeTree, .surname("breen"), .surname("hudson"), .surname("nobody"),
        .ancestorsOf(nil), .ancestorsOf("donna"), .ancestorsOf("zed"), .ancestorsOf("nobody here"),
        .descendantsOf(nil), .descendantsOf("george"), .descendantsOf("timmy"), .descendantsOf("nobody here"),
        .otherSideOf(nil), .otherSideOf("donna"), .otherSideOf("nobody here"),
    ]

    static func render(_ result: HallieTurnExecutor.Result) -> String {
        HallieGoldenSnapshot.render(result)
            + "\nsuperlative=\(String(reflecting: result.superlative))"
            + "\nattachments=\(HallieGoldenSnapshot.masked(String(reflecting: result.attachments)))"
    }

    @Test func everyKindAndScopeMatchesItsRecordedSnapshot() throws {
        var out: [String: String] = [:]
        for (contextName, context) in Self.contexts {
            for kind in Self.kinds {
                for scope in Self.scopes {
                    let result = HallieLineageAnswer.superlative(
                        kind, scope: scope, graph: Self.graph, context: context)
                    out["\(contextName) | \(kind) | \(scope)"] = Self.render(result)
                }
            }
        }
        #expect(out.count == Self.contexts.count * Self.kinds.count * Self.scopes.count)
        try HallieGoldenSnapshot.verify("superlative", out)
    }
}
