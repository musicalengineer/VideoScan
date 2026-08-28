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
        // Donna's F3 (Ann, partner unknown, child Rose) is NOT George+Ann's
        // F3: kept separate and reported.
        #expect(outcome.conflicts.map(\.kind) == [.unmatchedPerson, .familyKeptSeparate])
        #expect(outcome.conflicts[1].ids.first == "@F3@")
    }

    @Test func parentlessDonnaGainsParentsFromHerOwnPull() throws {
        #expect(rick.relatives(.parents, of: rick.people["@I3@"]!).isEmpty)
        let g = rick.merged(with: donna)
        let d = try #require(g.person(familySearchID: "G2CL-86B"))
        #expect(d.id == "@I3@", "Donna keeps the FIRST file's pointer")
        #expect(d.birthDate == "1959", "a nil on the first side is filled from the second")
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

    @Test func sameFingerprintSelfMergeIsIdempotent() {
        var fingerprinted = rick
        fingerprinted.sourceFingerprint = "abc123"
        let outcome = fingerprinted.merge(with: fingerprinted)
        #expect(outcome.graph.people.count == rick.people.count)
        #expect(outcome.graph.familyCount == rick.familyCount)
        #expect(outcome.unmatched.isEmpty, "identical file re-read: pointer alone identifies the no-FSID record")
        #expect(outcome.sharedPeopleCount == rick.people.count)
        #expect(outcome.conflicts.isEmpty)
    }

    /// codex #775: "@I42@ John Smith" in two independent exports are two
    /// people. Same pointer, same name, both without a birth date — and
    /// no shared fingerprint — must NOT collapse.
    @Test func noFSIDRecordsFromDifferentSourcesAreNeverMerged() {
        let a = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I42@ INDI
        1 NAME John /Smith/
        1 FAMS @F1@
        0 @I43@ INDI
        1 NAME Kid /Smith/
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I42@
        1 CHIL @I43@
        0 TRLR
        """)
        let b = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I42@ INDI
        1 NAME John /Smith/
        1 FAMS @F1@
        0 @I43@ INDI
        1 NAME Other /Smith/
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I42@
        1 CHIL @I43@
        0 TRLR
        """)
        for pair in [(a, b), ({ var x = a; x.sourceFingerprint = "one"; return x }(), { var y = b; y.sourceFingerprint = "two"; return y }())] {
            let outcome = pair.0.merge(with: pair.1)
            #expect(outcome.graph.people.count == 4, "two Johns, two children")
            #expect(outcome.sharedPeopleCount == 0)
            #expect(outcome.unmatched.map(\.name) == ["John Smith", "Other Smith"])
            #expect(outcome.graph.familyCount == 2, "no family splice")
            #expect(outcome.graph.relatives(.children, of: outcome.graph.people["@I42@"]!).map(\.name) == ["Kid Smith"])
            #expect(outcome.conflicts.filter { $0.kind == .unmatchedPerson }.count == 2)
        }
        // Pointer collision means "not the same" too: nothing from A is renumbered.
        #expect(a.merge(with: b).graph.people["@I42@"]?.id == "@I42@")
    }

    /// codex #774: parent P with two unknown-partner families {c1,c2} and
    /// {c3} stays two families, each with its own MARR data; a same-parent
    /// near-miss is reported, not merged.
    @Test func singleParentFamiliesWithDifferentChildrenStaySeparate() throws {
        let a = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME P /Parent/
        1 FAMS @F1@
        1 _FSFTID PPPP-001
        0 @I2@ INDI
        1 NAME C1 /Kid/
        1 FAMC @F1@
        1 _FSFTID CCCC-001
        0 @I3@ INDI
        1 NAME C2 /Kid/
        1 FAMC @F1@
        1 _FSFTID CCCC-002
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        1 CHIL @I3@
        1 MARR
        2 DATE 1900
        0 TRLR
        """)
        let b = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I7@ INDI
        1 NAME P /Parent/
        1 FAMS @F9@
        1 FAMS @F8@
        1 _FSFTID PPPP-001
        0 @I8@ INDI
        1 NAME C3 /Kid/
        1 FAMC @F9@
        1 _FSFTID CCCC-003
        0 @I9@ INDI
        1 NAME C1 /Kid/
        1 FAMC @F8@
        1 _FSFTID CCCC-001
        0 @I10@ INDI
        1 NAME C2 /Kid/
        1 FAMC @F8@
        1 _FSFTID CCCC-002
        0 @F9@ FAM
        1 HUSB @I7@
        1 CHIL @I8@
        1 MARR
        2 DATE 1920
        0 @F8@ FAM
        1 HUSB @I7@
        1 CHIL @I9@
        1 CHIL @I10@
        0 TRLR
        """)
        let outcome = a.merge(with: b)
        let g = outcome.graph
        let p = try #require(g.person(familySearchID: "PPPP-001"))
        let units = g.familyUnits(of: p)
        #expect(units.count == 2)
        #expect(units.map { $0.children.map(\.name).sorted() } == [["C1 Kid", "C2 Kid"], ["C3 Kid"]])
        #expect(units.map(\.marriageDate) == ["1900", "1920"], "each family keeps its own MARR")
        #expect(outcome.conflicts.map(\.kind) == [.familyKeptSeparate])
        #expect(outcome.conflicts[0].ids == ["@F1@", "@FB9@"])
    }

    @Test func coupleKeyRequiresBothFamilySearchIDs() {
        // Same husband (FSID) + a wife WITHOUT an FSID on both sides: not a
        // couple key, and the two wives are distinct people → two families.
        let a = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME H /Man/
        1 FAMS @F1@
        1 _FSFTID HHHH-001
        0 @I2@ INDI
        1 NAME Mary /Unknown/
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        0 TRLR
        """)
        let outcome = a.merge(with: a)   // no fingerprint → Mary is a different Mary
        #expect(outcome.graph.familyCount == 2)
        #expect(outcome.conflicts.map(\.kind) == [.unmatchedPerson, .familyKeptSeparate])
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

    /// codex #780: two non-nil, different values → first source kept, the
    /// disagreement reported and counted; a differing NAME survives as an
    /// alternate name.
    @Test func scalarDisagreementsKeepFirstSourceAndAreReported() throws {
        let a = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Ann /Shared/
        1 SEX F
        1 BIRT
        2 DATE 1870
        2 PLAC Cork, Ireland
        1 _FSFTID SHRD-001
        0 TRLR
        """)
        let b = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I5@ INDI
        1 NAME Anne /Shared/
        1 SEX F
        1 BIRT
        2 DATE ABT 1871
        2 PLAC Cork, Ireland
        1 DEAT
        2 DATE 1950
        1 _FSFTID SHRD-001
        0 TRLR
        """)
        let outcome = a.merge(with: b)
        let ann = try #require(outcome.graph.person(familySearchID: "SHRD-001"))
        #expect(ann.name == "Ann Shared")
        #expect(ann.alternateNames == ["Anne Shared"])
        #expect(ann.birthDate == "1870", "first source kept")
        #expect(ann.deathDate == "1950", "nil filled from the second")
        #expect(ann.birthPlace == "Cork, Ireland")
        #expect(outcome.fieldConflictCount == 2)
        let fields = outcome.conflicts.filter { $0.kind == .fieldDisagreement }
        #expect(fields.map(\.ids) == [["@I1@"], ["@I1@"]])
        #expect(fields[0].resolution == "SHRD-001 NAME: kept “Ann Shared” (first source); second source says “Anne Shared”")
        #expect(fields[1].resolution == "SHRD-001 BIRT DATE: kept “1870” (first source); second source says “ABT 1871”")
        // Reversed order: the other file is "first" and wins.
        #expect(b.merge(with: a).graph.person(familySearchID: "SHRD-001")?.birthDate == "ABT 1871")
    }

    /// codex #780 loss accounting: what the parser drops is counted, the
    /// merge sums it, and the artifact flag survives the round trip.
    @Test func lossAccountingAndMergedFlag() {
        let a = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 SOUR getmyancestors
        0 @I1@ INDI
        1 NAME Ann /Shared/
        1 SEX F
        1 BIRT
        2 DATE 1870
        2 SOUR @S1@
        3 PAGE 12
        1 OCCU Weaver
        1 NOTE Long story
        2 CONT more
        1 _FSFTID SHRD-001
        0 @S1@ SOUR
        1 TITL Census
        0 TRLR
        """)
        #expect(a.droppedLineCount == 5, "SOUR+PAGE under BIRT, OCCU, NOTE+CONT; the SOUR record's own lines are not under INDI/FAM (not counted)")
        #expect(a.isMergedArtifact == false)
        var b = a; b.sourceFingerprint = nil
        let outcome = a.merge(with: b)
        #expect(outcome.droppedLineCount == 10)
        #expect(outcome.graph.isMergedArtifact)
        let back = GedcomFamilyGraph(gedcomText: outcome.graph.gedcomText())
        #expect(back.isMergedArtifact)
        #expect(back.droppedLineCount == 0, "the artifact carries only what the parser keeps")
        // Same-root, same-name re-pull merge: ONE root, one file name — still an artifact.
        #expect(back.roots.count == 1)
        #expect(back.sourceFileNames.isEmpty)
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

    /// codex #780: continuations are level-2 CONC/CONT under a level-1
    /// NOTE, and a long multi-line note reads back identically.
    @Test func longMultiLineNoteRoundTripsWithSubordinateContinuations() {
        let word = "abcdefghij"
        let long = (0..<40).map { _ in word }.joined(separator: " ")   // 439 chars, spaces every 11
        let note = "Derived VideoScan merge artifact (lossy: names, vitals, links, FSIDs).\n"
            + long + "\n"
            + "\n"   // an empty line
            + String(repeating: "x", count: 450) + " end"
        let text = rick.gedcomText(provenance: note)
        let headLines = text.split(separator: "\n").prefix { !$0.hasPrefix("0 @") }
        #expect(headLines.contains { $0.hasPrefix("1 NOTE ") })
        #expect(headLines.filter { $0.hasPrefix("1 CONC") || $0.hasPrefix("1 CONT") }.isEmpty, "no level-1 continuations")
        #expect(headLines.filter { $0.hasPrefix("2 CONC ") }.count >= 4)
        #expect(headLines.filter { $0.hasPrefix("2 CONT") }.count == 3)
        for line in headLines where line.hasPrefix("2 CONC ") || line.hasPrefix("2 CONT ") || line.hasPrefix("1 NOTE ") {
            #expect(!line.hasSuffix(" "), "chunks never end in a space: \(line)")
            #expect(line.count <= 2 + 5 + GedcomFamilyGraph.noteChunk + 11)
        }
        let back = GedcomFamilyGraph(gedcomText: text)
        #expect(back.headNote == note)
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

    // MARK: Scale — full pipeline (codex #780 item 11)

    /// Two synthetic 100k-person pedigrees that overlap on 50k FSIDs.
    static func synthetic(offset: Int, count: Int) -> GedcomFamilyGraph {
        var people: [String: GedcomFamilyGraph.Person] = [:]
        var families: [String: GedcomFamilyGraph.Family] = [:]
        people.reserveCapacity(count)
        for i in 0..<count {
            // Identity (name, sex, birth) follows the FSID index so the
            // same person in both files agrees field for field.
            let k = i + offset
            var p = GedcomFamilyGraph.Person(id: "@I\(i)@", name: "P\(k) S", sex: k % 2 == 0 ? "M" : "F",
                                             childOfFamily: nil)
            p.surname = "S"
            // Person i's parents are 2i+1, 2i+2 (a binary pedigree).
            if 2 * i + 2 < count {
                p.childOfFamilies = ["@F\(i)@"]; p.childOfFamily = "@F\(i)@"
                families["@F\(i)@"] = GedcomFamilyGraph.Family(
                    husband: "@I\(2 * i + 1)@", wife: "@I\(2 * i + 2)@", children: ["@I\(i)@"])
            }
            if i > 0 { p.spouseOfFamilies = ["@F\((i - 1) / 2)@"] }
            p.birthDate = "\(1500 + (k % 400))"
            p.familySearchID = String(format: "%04X-%03X", (i + offset) / 4096 % 65536, (i + offset) % 4096)
            people[p.id] = p
        }
        return GedcomFamilyGraph(people: people, families: families, rootPersonIDs: ["@I0@"], sourceFileNames: [])
    }

    /// parse-free build → merge → write → PARSE the written text → verify
    /// counts, roots, edges (every 97th person's parents and spouses), and
    /// sample queries. Budget 20 s Debug for the whole pipeline; each
    /// stage's time is printed so a regression is visible.
    @Test func fullPipelineAtTwoHundredThousandStaysWithinBudget() throws {
        let n = 100_000
        var a = Self.synthetic(offset: 0, count: n); a.sourceFileName = "a.ged"
        var b = Self.synthetic(offset: n / 2, count: n); b.sourceFileName = "b.ged"
        let t0 = Date()
        let outcome = a.merge(with: b)
        let tMerge = Date().timeIntervalSince(t0)
        #expect(outcome.graph.people.count == n + n / 2)
        #expect(outcome.sharedPeopleCount == n / 2)
        #expect(outcome.fieldConflictCount == 0)

        let t1 = Date()
        let text = outcome.graph.gedcomText(provenance: "scale pipeline")
        let tWrite = Date().timeIntervalSince(t1)
        let t2 = Date()
        let back = GedcomFamilyGraph(gedcomText: text)
        let tParse = Date().timeIntervalSince(t2)

        let t3 = Date()
        #expect(back.people.count == outcome.graph.people.count)
        #expect(back.familyCount == outcome.graph.familyCount)
        #expect(back.rootPersonIDs == outcome.graph.rootPersonIDs)
        #expect(back.roots.count == 2)
        #expect(back.isMergedArtifact)
        #expect(back.headNote == "scale pipeline")
        var edgeMismatches = 0
        for (i, id) in GedcomFamilyGraph.sortedPointers(back.people.keys).enumerated() where i % 97 == 0 {
            let p = try #require(back.people[id]), q = try #require(outcome.graph.people[id])
            if p != q { edgeMismatches += 1 }
            if back.relatives(.parents, of: p).map(\.id) != outcome.graph.relatives(.parents, of: q).map(\.id) { edgeMismatches += 1 }
            if back.relatives(.spouse, of: p).map(\.id) != outcome.graph.relatives(.spouse, of: q).map(\.id) { edgeMismatches += 1 }
        }
        #expect(edgeMismatches == 0)
        // Sample queries on the reloaded graph.
        let donnaSide = try #require(outcome.pointerMap["@I0@"])
        let hits = back.commonAncestors(of: "@I0@", and: donnaSide, limit: 5)
        #expect(!hits.isEmpty)
        #expect(back.person(familySearchID: b.people["@I0@"]!.familySearchID!)?.id == donnaSide)
        #expect(back.directRelation(between: "@I0@", and: "@I1@")?.kind == .parentChild)
        let tVerify = Date().timeIntervalSince(t3)
        let total = Date().timeIntervalSince(t0)
        print("SCALE pipeline 2×\(n): merge \(String(format: "%.2f", tMerge))s write \(String(format: "%.2f", tWrite))s (\(text.utf8.count / 1_000_000) MB) parse \(String(format: "%.2f", tParse))s verify \(String(format: "%.2f", tVerify))s total \(String(format: "%.2f", total))s")
        #expect(tMerge < 2, "merge budget")
        #expect(total < 20, "pipeline budget (Debug)")
    }
}
