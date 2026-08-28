// GedcomMergeTests.swift
// Two FamilySearch pulls (Rick's, Donna's) → one tree keyed by FSID
// (2026-08-27). Dimensions: LOGIC (union, dedup, richer-record wins,
// parentless Donna gains parents, unmatched no-FSID records reported),
// round-trip WRITER, common ancestors + the kinship term, and SCALE
// (2 × 100k synthetic people, < 2 s). Pure text fixtures; no files.

import Foundation
import Testing
@testable import VideoScanCore

/// Rick's pull: Rick (@I1@) ← parents; Donna (@I3@) as spouse only, no
/// parents; Rick's grandmother Ann Shared (@I6@) with FSID SHRD-001.
private let rickPull = """
0 HEAD
1 SOUR getmyancestors
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F2@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
1 FAMC @F3@
1 FAMS @F1@
1 _FSFTID RICK-DAD
0 @I3@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMS @F2@
1 _FSFTID G2CL-86B
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @F1@
1 _FSFTID RICK-MOM
0 @I5@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMS @F3@
1 _FSFTID RICK-GF1
0 @I6@ INDI
1 NAME Ann /Shared/
1 SEX F
1 BIRT
2 DATE 1870
1 FAMS @F3@
1 _FSFTID SHRD-001
0 @I7@ INDI
1 NAME No /Fsid/
1 SEX M
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I4@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I3@
1 MARR
2 DATE 1981
0 @F3@ FAM
1 HUSB @I5@
1 WIFE @I6@
1 CHIL @I2@
0 TRLR
"""

/// Donna's pull: Donna is @I1@ here (pointers are export-local), WITH
/// parents; her mother's mother is a DAUGHTER of Ann Shared — the same
/// Ann, same FSID, born 1870, but this export also knows her death.
/// Rick appears as spouse only (thinner record than in his own pull).
private let donnaPull = """
0 HEAD
1 SOUR getmyancestors
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F9@
1 _FSFTID G2CL-86B
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 FAMS @F9@
1 _FSFTID GVQV-NW3
0 @I3@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMS @F1@
1 _FSFTID DON1-DAD
0 @I4@ INDI
1 NAME Betty /Miller/
1 SEX F
1 FAMC @F2@
1 FAMS @F1@
1 _FSFTID DON1-MOM
0 @I5@ INDI
1 NAME Rose /Shared/
1 SEX F
1 FAMC @F3@
1 FAMS @F2@
1 _FSFTID DON1-GM0
0 @I6@ INDI
1 NAME Ann /Shared/
1 SEX F
1 BIRT
2 DATE 1870
1 DEAT
2 DATE 1950
1 FAMS @F3@
1 _FSFTID SHRD-001
0 @I7@ INDI
1 NAME Another /Nofsid/
1 SEX F
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F2@ FAM
1 WIFE @I5@
1 CHIL @I4@
0 @F3@ FAM
1 WIFE @I6@
1 CHIL @I5@
0 @F9@ FAM
1 HUSB @I2@
1 WIFE @I1@
0 TRLR
"""

@Suite("GEDCOM merge by FamilySearch ID")
struct GedcomMergeTests {
    let rick = GedcomFamilyGraph(gedcomText: rickPull)
    let donna = GedcomFamilyGraph(gedcomText: donnaPull)

    @Test func unionDedupsByFamilySearchID() throws {
        let outcome = rick.merge(with: donna)
        let g = outcome.graph
        // 7 + 7 people, 4 shared by FSID (Rick, Donna, Ann; plus nothing
        // else) → Rick, Donna, Ann shared = 3; @I7@ No Fsid vs Another
        // Nofsid share a pointer but not a name → NOT matched.
        #expect(outcome.sharedPeopleCount == 3)
        #expect(outcome.addedPeopleCount == 4)
        #expect(g.people.count == 11)
        // Ann appears ONCE, under Rick's pointer, and now knows her death.
        let anns = g.people.values.filter { $0.familySearchID == "SHRD-001" }
        #expect(anns.count == 1)
        #expect(anns.first?.id == "@I6@")
        #expect(anns.first?.deathDate == "1950")
        #expect(g.person(familySearchID: "SHRD-001")?.id == "@I6@")
        // Rick's own (richer) record kept its pointer, parents, and gained
        // nothing spurious.
        let r = try #require(g.person(familySearchID: "GVQV-NW3"))
        #expect(r.id == "@I1@")
        #expect(g.relatives(.father, of: r).map(\.name) == ["Richard Harding Breen Sr"])
        #expect(g.relatives(.spouse, of: r).map(\.name) == ["Donna Hudson"])
        // The marriage family was matched by (husband, wife) — one FAM,
        // with Rick's marriage date kept.
        #expect(g.familyCount == 3 + 3)   // F1,F2,F3 mine + Donna's F1,F2,F3 (F9 merged into F2)
        #expect(g.marriages(of: r).compactMap(\.date) == ["1981"])
    }

    @Test func parentlessDonnaGainsParentsFromHerOwnPull() throws {
        #expect(rick.relatives(.parents, of: rick.people["@I3@"]!).isEmpty)
        let g = rick.merged(with: donna)
        let d = try #require(g.person(familySearchID: "G2CL-86B"))
        #expect(d.id == "@I3@", "Donna keeps the FIRST file's pointer")
        #expect(d.birthDate == "1959", "the richer record's facts win")
        #expect(g.relatives(.father, of: d).map(\.name) == ["Walter Hudson"])
        #expect(g.relatives(.mother, of: d).map(\.name) == ["Betty Miller"])
        #expect(g.ancestorLine(of: d, line: .maternal, generations: 5).map { $0.people.map(\.name) }
                == [["Betty Miller"], ["Rose Shared"], ["Ann Shared"]])
        // Donna's husband link survived the pointer remap.
        #expect(g.relatives(.husband, of: d).map(\.name) == ["Richard Harding Breen Jr"])
    }

    @Test func recordsWithoutFamilySearchIDAreReportedNotGuessed() {
        let outcome = rick.merge(with: donna)
        #expect(outcome.unmatched.map(\.name) == ["Another Nofsid"])
        // Added under a fresh pointer; the first file's @I7@ is untouched.
        #expect(outcome.graph.people["@I7@"]?.name == "No Fsid")
        #expect(outcome.pointerMap["@I7@"] == "@IB7@")
        #expect(outcome.graph.people["@IB7@"]?.name == "Another Nofsid")
    }

    @Test func sameFileMergedWithItselfIsUnchangedAndNoFSIDRecordsMatchStrictly() {
        let outcome = rick.merge(with: rick)
        #expect(outcome.graph.people.count == rick.people.count)
        #expect(outcome.graph.familyCount == rick.familyCount)
        #expect(outcome.unmatched.isEmpty, "same pointer + same name + same birth = the same record")
        #expect(outcome.sharedPeopleCount == rick.people.count)
    }

    @Test func rootsAndSourcesAreCarried() {
        var a = rick; a.sourceFileName = "familysearch-tree-20generations.ged"
        var b = donna; b.sourceFileName = "familysearch-donna-20generations.ged"
        let g = a.merged(with: b)
        #expect(g.roots.map(\.name) == ["Richard Harding Breen Jr", "Donna Hudson"])
        #expect(g.rootPerson?.name == "Richard Harding Breen Jr", "compatibility: first root")
        #expect(g.sourceFileNames == ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"])
    }

    @Test func mergeIsIdempotent() {
        let once = rick.merged(with: donna)
        let twice = once.merged(with: donna)
        #expect(twice.people.count == once.people.count + 1, "only the no-FSID record is added again (never guessed)")
        #expect(twice.familyCount == once.familyCount)
    }

    // MARK: Writer

    @Test func writerRoundTripsWhatTheParserReads() throws {
        var a = rick; a.sourceFileName = "rick.ged"
        var b = donna; b.sourceFileName = "donna.ged"
        let merged = a.merged(with: b)
        let text = merged.gedcomText(provenance: "Merged by VideoScan from rick.ged and donna.ged\nfor a test")
        #expect(text.hasPrefix("0 HEAD\n"))
        #expect(text.hasSuffix("0 TRLR\n"))
        #expect(text.contains("1 NOTE Merged by VideoScan from rick.ged and donna.ged\n2 CONT for a test"))
        #expect(text.contains("1 NAME Richard Harding /Breen/ Jr"))
        #expect(text.contains("1 _FSFTID SHRD-001"))
        // Roots are written FIRST so the first-INDI convention still holds.
        let firstIndi = try #require(text.range(of: "0 @I1@ INDI"))
        let donnaIndi = try #require(text.range(of: "0 @I3@ INDI"))
        let otherIndi = try #require(text.range(of: "0 @I2@ INDI"))
        #expect(firstIndi.lowerBound < donnaIndi.lowerBound && donnaIndi.lowerBound < otherIndi.lowerBound)

        let back = GedcomFamilyGraph(gedcomText: text)
        #expect(back.people.count == merged.people.count)
        #expect(back.familyCount == merged.familyCount)
        #expect(back.rootPersonIDs == merged.rootPersonIDs, "roots come back from _VS_ROOT, not file order")
        #expect(back.sourceFileNames == ["rick.ged", "donna.ged"])
        for (id, p) in merged.people {
            let q = try #require(back.people[id], "missing \(id)")
            #expect(q == p, "round-trip mismatch for \(id)")
        }
        for (id, p) in merged.people {
            #expect(back.familyUnits(of: p) == merged.familyUnits(of: p), "family units differ for \(id)")
            #expect(back.relatives(.parents, of: p) == merged.relatives(.parents, of: p))
        }
    }

    @Test func writerRebuildsNameSlashesAndAlternateSurnames() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Muriel /Lamb/
        1 NAME Muriel /Breen/
        1 NAME Mimi
        1 SEX F
        0 TRLR
        """)
        let text = g.gedcomText()
        #expect(text.contains("1 NAME Muriel /Lamb/\n1 NAME Muriel /Breen/\n1 NAME Mimi\n"))
        let back = GedcomFamilyGraph(gedcomText: text)
        #expect(back.people["@I1@"] == g.people["@I1@"])
        #expect(GedcomFamilyGraph.gedcomName("Jean de la Fontaine", surnames: ["de la Fontaine"]) == "Jean /de la Fontaine/")
        #expect(GedcomFamilyGraph.gedcomName("Plain Name", surnames: []) == "Plain Name")
    }

    // MARK: Common ancestors

    /// Rick ← Sr ← George+Ann: Ann is Rick's grandmother (depth 2 via
    /// Sr… wait — F3 is Sr's parents, so Ann is depth 2 above Rick).
    /// Donna ← Betty ← Rose ← Ann: depth 3. Below, a deeper fixture puts
    /// them at 3/4 → 2nd cousins once removed.
    @Test func commonAncestorsRankNearestFirstWithBothPaths() throws {
        let g = rick.merged(with: donna)
        let hits = g.commonAncestors(of: "@I1@", and: "@I3@")
        #expect(hits.count == 1)
        let ann = try #require(hits.first)
        #expect(ann.person.name == "Ann Shared")
        #expect(ann.depthA == 2 && ann.depthB == 3)
        #expect(ann.pathA.map(\.name) == ["Ann Shared", "Richard Harding Breen Sr", "Richard Harding Breen Jr"])
        #expect(ann.pathB.map(\.name) == ["Ann Shared", "Rose Shared", "Betty Miller", "Donna Hudson"])
        #expect(ann.kinshipTerm == "1st cousins once removed")
        // Before the merge Donna had no ancestors: nothing shared.
        #expect(rick.commonAncestors(of: "@I1@", and: "@I3@").isEmpty)
        #expect(rick.ancestorDepth(of: "@I3@") == 0)
        #expect(rick.ancestorDepth(of: "@I1@") == 2)
        // Same person / unknown ids → empty.
        #expect(g.commonAncestors(of: "@I1@", and: "@I1@").isEmpty)
        #expect(g.commonAncestors(of: "@I1@", and: "@NOPE@").isEmpty)
    }

    @Test func depthsThreeAndFourAreSecondCousinsOnceRemoved() throws {
        // Common ancestor Z; Rick 3 up (Z ← p ← gp ← Rick), Donna 4 up.
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Donna /Hudson/
        1 FAMC @F2@
        0 @I3@ INDI
        1 NAME RickParent /Breen/
        1 FAMS @F1@
        1 FAMC @F3@
        0 @I4@ INDI
        1 NAME RickGrand /Breen/
        1 FAMS @F3@
        1 FAMC @F5@
        0 @I5@ INDI
        1 NAME DonnaParent /Hudson/
        1 FAMS @F2@
        1 FAMC @F4@
        0 @I6@ INDI
        1 NAME DonnaGrand /Hudson/
        1 FAMS @F4@
        1 FAMC @F6@
        0 @I7@ INDI
        1 NAME DonnaGreat /Hudson/
        1 FAMS @F6@
        1 FAMC @F5@
        0 @I8@ INDI
        1 NAME Z /Common/
        1 SEX M
        1 BIRT
        2 DATE 1800
        1 FAMS @F5@
        0 @F1@ FAM
        1 HUSB @I3@
        1 CHIL @I1@
        0 @F2@ FAM
        1 HUSB @I5@
        1 CHIL @I2@
        0 @F3@ FAM
        1 HUSB @I4@
        1 CHIL @I3@
        0 @F4@ FAM
        1 HUSB @I6@
        1 CHIL @I5@
        0 @F5@ FAM
        1 HUSB @I8@
        1 CHIL @I4@
        1 CHIL @I7@
        0 @F6@ FAM
        1 HUSB @I7@
        1 CHIL @I6@
        0 TRLR
        """)
        let hit = try #require(g.commonAncestors(of: "@I1@", and: "@I2@").first)
        #expect(hit.person.name == "Z Common")
        #expect(hit.depthA == 3 && hit.depthB == 4)
        #expect(hit.kinshipTerm == "2nd cousins once removed")
        // Symmetric.
        let flipped = try #require(g.commonAncestors(of: "@I2@", and: "@I1@").first)
        #expect(flipped.depthA == 4 && flipped.depthB == 3)
        #expect(flipped.kinshipTerm == "2nd cousins once removed")
    }

    @Test func kinshipTermTable() {
        typealias G = GedcomFamilyGraph
        #expect(G.kinshipTerm(depthA: 1, depthB: 1) == "siblings")
        #expect(G.kinshipTerm(depthA: 1, depthB: 2) == "aunt/uncle and niece/nephew")
        #expect(G.kinshipTerm(depthA: 3, depthB: 1) == "great-aunt/uncle and great-niece/nephew")
        #expect(G.kinshipTerm(depthA: 2, depthB: 2) == "1st cousins")
        #expect(G.kinshipTerm(depthA: 2, depthB: 3) == "1st cousins once removed")
        #expect(G.kinshipTerm(depthA: 3, depthB: 4) == "2nd cousins once removed")
        #expect(G.kinshipTerm(depthA: 5, depthB: 3) == "2nd cousins twice removed")
        #expect(G.kinshipTerm(depthA: 8, depthB: 9) == "7th cousins once removed")
        #expect(G.kinshipTerm(depthA: 12, depthB: 12) == "11th cousins")
    }

    // MARK: Scale

    /// Two synthetic 100k-person pedigrees that overlap on 50k FSIDs.
    /// Budget 2 s for parse-free merge (both graphs pre-built).
    @Test func twoHundredThousandPersonMergeStaysUnderTwoSeconds() {
        func synthetic(offset: Int, count: Int) -> GedcomFamilyGraph {
            var people: [String: GedcomFamilyGraph.Person] = [:]
            var families: [String: GedcomFamilyGraph.Family] = [:]
            people.reserveCapacity(count)
            for i in 0..<count {
                var p = GedcomFamilyGraph.Person(id: "@I\(i)@", name: "P\(i) /S/", sex: i % 2 == 0 ? "M" : "F",
                                                 childOfFamily: nil)
                // Person i's parents are 2i+1, 2i+2 (a binary pedigree).
                if 2 * i + 2 < count {
                    p.childOfFamilies = ["@F\(i)@"]; p.childOfFamily = "@F\(i)@"
                    families["@F\(i)@"] = GedcomFamilyGraph.Family(
                        husband: "@I\(2 * i + 1)@", wife: "@I\(2 * i + 2)@", children: ["@I\(i)@"])
                }
                if i > 0 { p.spouseOfFamilies = ["@F\((i - 1) / 2)@"] }
                p.familySearchID = String(format: "%04X-%03X", (i + offset) / 4096 % 65536, (i + offset) % 4096)
                people[p.id] = p
            }
            return GedcomFamilyGraph(people: people, families: families, rootPersonIDs: ["@I0@"], sourceFileNames: [])
        }
        let n = 100_000
        let a = synthetic(offset: 0, count: n)
        let b = synthetic(offset: n / 2, count: n)
        let t0 = Date()
        let outcome = a.merge(with: b)
        let elapsed = Date().timeIntervalSince(t0)
        print("SCALE merge 2×\(n): \(String(format: "%.3f", elapsed))s people=\(outcome.graph.people.count)")
        #expect(outcome.graph.people.count == n + n / 2)
        #expect(outcome.sharedPeopleCount == n / 2)
        #expect(elapsed < 2, "merge budget")
        let t1 = Date()
        let hits = outcome.graph.commonAncestors(of: "@I0@", and: outcome.pointerMap["@I0@"]!, limit: 5)
        let ca = Date().timeIntervalSince(t1)
        print("SCALE commonAncestors: \(String(format: "%.3f", ca))s hits=\(hits.count)")
        #expect(!hits.isEmpty)
        #expect(ca < 2)
    }
}
