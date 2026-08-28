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
        #expect(a.droppedLineCount == 7, "SOUR+PAGE under BIRT, OCCU, NOTE+CONT (5) + the whole @S1@ SOUR record (2); the HEAD SOUR envelope line is not counted")
        #expect(a.isMergedArtifact == false)
        var b = a; b.sourceFingerprint = nil
        let outcome = a.merge(with: b)
        #expect(outcome.droppedLineCount == 14)
        #expect(outcome.graph.totalDroppedLineCount == 14, "nameless sources: loss stays unattributed but never under-counted")
        #expect(outcome.graph.isMergedArtifact)
        let back = GedcomFamilyGraph(gedcomText: outcome.graph.gedcomText())
        #expect(back.isMergedArtifact)
        #expect(back.droppedLineCount == 0, "the artifact carries only what the parser keeps")
        // Same-root, same-name re-pull merge: ONE root, one file name — still an artifact.
        #expect(back.roots.count == 1)
        #expect(back.sourceFileNames.isEmpty)
    }

    /// codex #794 (4): a chained merge keeps every source's name, hash and
    /// loss. A+B → write → parse → +C lists A, B, C with their figures,
    /// and the total loss is the sum of all three.
    @Test func chainedMergeCarriesPerSourceProvenanceThroughTheWrittenFile() throws {
        var a = rick; a.sourceFileName = "a.ged"; a.sourceFingerprint = "AA11"
        var b = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 SOUR getmyancestors
        0 @I1@ INDI
        1 NAME Donna /Hudson/
        1 OCCU Teacher
        1 _FSFTID G2CL-86B
        0 @N1@ NOTE A stray note
        1 CONT with a continuation
        0 TRLR
        """)
        b.sourceFileName = "b.ged"; b.sourceFingerprint = "bb22"
        #expect(a.droppedLineCount == 0)
        #expect(b.droppedLineCount == 3)
        let ab = a.merge(with: b)
        #expect(ab.droppedLineCount == 3)
        #expect(ab.graph.sourceProvenance == [
            .init(name: "a.ged", sha256: "AA11", droppedLineCount: 0),
            .init(name: "b.ged", sha256: "bb22", droppedLineCount: 3),
        ])

        let text = ab.graph.gedcomText(provenance: "A+B")
        #expect(text.contains("1 _VS_SOURCE a.ged\n2 _VS_SHA256 AA11\n2 _VS_DROPPED 0\n1 _VS_SOURCE b.ged\n2 _VS_SHA256 bb22\n2 _VS_DROPPED 3\n"))
        var artifact = GedcomFamilyGraph(gedcomText: text)
        artifact.sourceFileName = "ab.ged"; artifact.sourceFingerprint = "abab"
        #expect(artifact.droppedLineCount == 0, "our own HEAD envelope + provenance lines are not loss")
        #expect(artifact.totalDroppedLineCount == 3)
        #expect(artifact.sourceProvenance.map(\.name) == ["a.ged", "b.ged"])
        #expect(artifact.sourceProvenance.map(\.sha256) == ["AA11", "bb22"], "hashes read back verbatim")
        #expect(artifact.sourceProvenance.map(\.droppedLineCount) == [0, 3])

        var c = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I9@ INDI
        1 NAME Walter /Hudson/
        1 NOTE x
        1 NOTE y
        1 _FSFTID DON1-DAD
        0 @O1@ OBJE
        1 FILE photo.jpg
        0 TRLR
        """)
        c.sourceFileName = "c.ged"; c.sourceFingerprint = "cc33"
        #expect(c.droppedLineCount == 4)
        let abc = artifact.merge(with: c)
        #expect(abc.graph.sourceFileNames == ["a.ged", "b.ged", "c.ged"], "the artifact's own name is NOT a source; its sources are")
        #expect(abc.graph.sourceProvenance.map { "\($0.name):\($0.sha256 ?? "-"):\($0.droppedLineCount)" }
                == ["a.ged:AA11:0", "b.ged:bb22:3", "c.ged:cc33:4"])
        #expect(abc.droppedLineCount == 7)
        #expect(abc.graph.droppedLineCount == 0, "everything attributed")
        // And once more through text: still three sources.
        let back = GedcomFamilyGraph(gedcomText: abc.graph.gedcomText())
        #expect(back.sourceProvenance == abc.graph.sourceProvenance)
        #expect(back.totalDroppedLineCount == 7)
        // Merging the same export again (same name + hash) does not list it twice.
        #expect(abc.graph.merge(with: c).graph.sourceProvenance.count == 3)
        // A plain single export writes itself as its own one-line provenance.
        #expect(c.gedcomText().contains("1 _VS_SOURCE c.ged\n2 _VS_SHA256 cc33\n2 _VS_DROPPED 4\n"))
    }

    /// codex #794 (5): a matched family whose MARR DATE differs keeps the
    /// first source's date and REPORTS the disagreement with both family
    /// ids and both values.
    @Test func matchedFamilyMarriageDateDisagreementIsReported() throws {
        let donnaWithDate = donnaPull.replacingOccurrences(of: "0 @F9@ FAM\n1 HUSB @I2@\n1 WIFE @I1@\n",
                                                           with: "0 @F9@ FAM\n1 HUSB @I2@\n1 WIFE @I1@\n1 MARR\n2 DATE 12 SEP 1981\n")
        #expect(donnaWithDate != donnaPull)
        let outcome = rick.merge(with: GedcomFamilyGraph(gedcomText: donnaWithDate))
        let r = try #require(outcome.graph.person(familySearchID: "GVQV-NW3"))
        #expect(outcome.graph.marriages(of: r).compactMap(\.date) == ["1981"], "first source kept")
        let marr = outcome.conflicts.filter { $0.kind == .fieldDisagreement }
        #expect(marr.count == 1)
        #expect(outcome.fieldConflictCount == 1)
        #expect(marr.first?.ids == ["@F2@", "@F9@"])
        #expect(marr.first?.resolution == "Richard Harding Breen Jr & Donna Hudson MARR DATE: kept “1981” (first source, @F2@); second source (@F9@) says “12 SEP 1981”")
        // Same date on both sides, or a nil on the first side: no report.
        #expect(rick.merge(with: donna).fieldConflictCount == 0)
        let sameDate = donnaPull.replacingOccurrences(of: "0 @F9@ FAM\n1 HUSB @I2@\n1 WIFE @I1@\n",
                                                      with: "0 @F9@ FAM\n1 HUSB @I2@\n1 WIFE @I1@\n1 MARR\n2 DATE 1981\n")
        #expect(rick.merge(with: GedcomFamilyGraph(gedcomText: sameDate)).fieldConflictCount == 0)
        #expect(GedcomFamilyGraph(gedcomText: donnaWithDate).merge(with: rick).fieldConflictCount == 1, "reversed: the other side is first")
        let reversed = GedcomFamilyGraph(gedcomText: donnaWithDate).merge(with: rick).graph
        let rickInReversed = try #require(reversed.person(familySearchID: "GVQV-NW3"))
        #expect(rickInReversed.id == "@I2@", "Donna's file is first: its pointers are kept")
        #expect(reversed.marriages(of: rickInReversed).compactMap(\.date) == ["12 SEP 1981"])
    }

    // MARK: Determinism sensor (codex #794 item 3)

    /// Deterministic seeded generator (C++: a hand-rolled LCG) so the
    /// perturbation is reproducible in a failure report.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// The same records in a different file order: the first INDI stays
    /// first (the root convention is file order by design); everything
    /// after HEAD and before TRLR is shuffled at record granularity.
    static func perturbed(_ text: String, seed: UInt64) -> String {
        var records = text.components(separatedBy: "\n0 ").enumerated().map { $0.offset == 0 ? $0.element : "0 " + $0.element }
        let head = records.removeFirst()
        let trailer = records.removeLast()
        let firstIndiIndex = records.firstIndex { $0.hasSuffix(" INDI") || $0.contains(" INDI\n") }!
        let firstIndi = records.remove(at: firstIndiIndex)
        var rng = SeededRNG(state: seed)
        records.shuffle(using: &rng)
        return ([head, firstIndi] + records + [trailer]).joined(separator: "\n")
    }

    /// Fixture with the paths that used to depend on Dictionary order: the
    /// FIRST graph holds two same-parent unknown-partner families (@F5@,
    /// @F6@) so a near-miss from the second file must name one of them;
    /// and two identical-key families (@F7@, @F8@: same lone parent, same
    /// children) so a key-match from the second file must pick one.
    static let orderSensitiveFirst = rickPull.replacingOccurrences(of: "0 TRLR", with: """
    0 @I20@ INDI
    1 NAME Xavier /Lone/
    1 SEX M
    1 FAMS @F5@
    1 FAMS @F6@
    1 FAMS @F7@
    1 FAMS @F8@
    1 _FSFTID XAVI-001
    0 @I21@ INDI
    1 NAME Kid /One/
    1 FAMC @F5@
    1 _FSFTID KIDD-001
    0 @I22@ INDI
    1 NAME Kid /Two/
    1 FAMC @F6@
    1 _FSFTID KIDD-002
    0 @I23@ INDI
    1 NAME Kid /Four/
    1 FAMC @F7@
    1 FAMC @F8@
    1 _FSFTID KIDD-004
    0 @F5@ FAM
    1 HUSB @I20@
    1 CHIL @I21@
    0 @F6@ FAM
    1 HUSB @I20@
    1 CHIL @I22@
    0 @F7@ FAM
    1 HUSB @I20@
    1 CHIL @I23@
    1 MARR
    2 DATE 1900
    0 @F8@ FAM
    1 HUSB @I20@
    1 CHIL @I23@
    1 MARR
    2 DATE 1901
    0 TRLR
    """)
    static let orderSensitiveSecond = donnaPull.replacingOccurrences(of: "0 TRLR", with: """
    0 @I20@ INDI
    1 NAME Xavier /Lone/
    1 SEX M
    1 FAMS @F20@
    1 FAMS @F21@
    1 _FSFTID XAVI-001
    0 @I24@ INDI
    1 NAME Kid /Three/
    1 FAMC @F20@
    1 _FSFTID KIDD-003
    0 @I23@ INDI
    1 NAME Kid /Four/
    1 FAMC @F21@
    1 _FSFTID KIDD-004
    0 @F20@ FAM
    1 HUSB @I20@
    1 CHIL @I24@
    0 @F21@ FAM
    1 HUSB @I20@
    1 CHIL @I23@
    1 MARR
    2 DATE 1902
    0 TRLR
    """)

    /// Merge the same two graphs repeatedly, and with BOTH files'
    /// records order-perturbed under several seeds: byte-identical
    /// written text and identical conflict lists every time.
    @Test func mergeIsDeterministicAcrossRunsAndRecordOrder() throws {
        let stamp = Date(timeIntervalSince1970: 1_756_400_000)
        func run(_ a: String, _ b: String) -> (String, [GedcomFamilyGraph.ConflictReport]) {
            var x = GedcomFamilyGraph(gedcomText: a); x.sourceFileName = "a.ged"; x.sourceFingerprint = "aa"
            var y = GedcomFamilyGraph(gedcomText: b); y.sourceFileName = "b.ged"; y.sourceFingerprint = "bb"
            let outcome = x.merge(with: y)
            return (outcome.graph.gedcomText(provenance: "sensor", now: stamp), outcome.conflicts)
        }
        let reference = run(Self.orderSensitiveFirst, Self.orderSensitiveSecond)
        // The order-sensitive paths are actually exercised.
        let near = reference.1.filter { $0.kind == .familyKeptSeparate && $0.ids.last == "@FB20@" }
        #expect(near.map(\.ids) == [["@F5@", "@FB20@"]], "the lowest neighbour is named, always")
        #expect(reference.1.contains { $0.kind == .fieldDisagreement && $0.ids == ["@F7@", "@F21@"] },
                "@F21@ folds into the lowest identical-key family @F7@ and its MARR disagreement is reported")
        #expect(reference.0.contains("0 @F7@ FAM\n1 HUSB @I20@\n1 CHIL @I23@\n1 MARR\n2 DATE 1900\n"))

        for _ in 0..<3 {
            let again = run(Self.orderSensitiveFirst, Self.orderSensitiveSecond)
            #expect(again.0 == reference.0)
            #expect(again.1 == reference.1)
        }
        for seed: UInt64 in [1, 7, 42, 1234, 99_991] {
            let pa = Self.perturbed(Self.orderSensitiveFirst, seed: seed)
            let pb = Self.perturbed(Self.orderSensitiveSecond, seed: seed &+ 1)
            #expect(pa != Self.orderSensitiveFirst && pb != Self.orderSensitiveSecond, "perturbation changed the files (seed \(seed))")
            let again = run(pa, pb)
            #expect(again.0 == reference.0, "written text differs for seed \(seed)")
            #expect(again.1 == reference.1, "conflicts differ for seed \(seed)")
        }
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

    // MARK: Provenance union is identity-aware (codex #810)

    private func named(_ text: String, _ name: String, _ sha: String) -> GedcomFamilyGraph {
        var g = GedcomFamilyGraph(gedcomText: text); g.sourceFileName = name; g.sourceFingerprint = sha; return g
    }
    static let lossyA = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Ann /Shared/
    1 OCCU Weaver
    1 NOTE Long story
    1 _FSFTID SHRD-001
    0 TRLR
    """
    static let lossyB = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 OCCU Teacher
    1 _FSFTID G2CL-86B
    0 @N1@ NOTE A stray note
    1 CONT with a continuation
    0 TRLR
    """
    static let lossyC = """
    0 HEAD
    0 @I9@ INDI
    1 NAME Walter /Hudson/
    1 NOTE x
    1 NOTE y
    1 _FSFTID DON1-DAD
    0 @O1@ OBJE
    1 FILE photo.jpg
    0 TRLR
    """

    /// A+B then +B again: B is ONE entry and its loss is counted once —
    /// exact list, local and total after each step.
    @Test func mergingTheSameSourceTwiceCountsItsLossOnce() throws {
        let a = named(Self.lossyA, "a.ged", "aa"), b = named(Self.lossyB, "b.ged", "bb")
        #expect(a.droppedLineCount == 2 && b.droppedLineCount == 3)
        let ab = a.merge(with: b)
        #expect(ab.graph.sourceProvenance == [.init(name: "a.ged", sha256: "aa", droppedLineCount: 2),
                                              .init(name: "b.ged", sha256: "bb", droppedLineCount: 3)])
        #expect(ab.graph.droppedLineCount == 0, "every side attributed → local 0")
        #expect(ab.graph.totalDroppedLineCount == 5)
        #expect(ab.droppedLineCount == 5)

        let abb = ab.graph.merge(with: b)
        #expect(abb.graph.sourceProvenance == ab.graph.sourceProvenance, "same (name, sha) → one entry")
        #expect(abb.graph.droppedLineCount == 0)
        #expect(abb.graph.totalDroppedLineCount == 5, "not 8: B's loss is not counted again")
        #expect(abb.droppedLineCount == 5)
        #expect(abb.graph.people.count == ab.graph.people.count)
        #expect(!abb.conflicts.contains { $0.ids == ["b.ged"] }, "no disagreement: same count")

        // Same name, DIFFERENT bytes = a re-pull: a second entry, both counted.
        let b2 = named(Self.lossyB.replacingOccurrences(of: "Teacher", with: "Educator"), "b.ged", "b2")
        let abb2 = ab.graph.merge(with: b2)
        #expect(abb2.graph.sourceProvenance.map { "\($0.name):\($0.sha256!)" } == ["a.ged:aa", "b.ged:bb", "b.ged:b2"])
        #expect(abb2.graph.totalDroppedLineCount == 8)
    }

    /// Overlapping chained merge: (A+B) written and parsed back, then +
    /// (B+C). B appears on both sides with the same identity → listed
    /// once; the artifact's own name is not a source; total = a + b + c.
    @Test func overlappingChainedMergeListsEverySourceOnceWithExactTotals() throws {
        let a = named(Self.lossyA, "a.ged", "aa"), b = named(Self.lossyB, "b.ged", "bb"), c = named(Self.lossyC, "c.ged", "cc")
        #expect(c.droppedLineCount == 4)
        let ab = a.merge(with: b).graph
        var abFile = GedcomFamilyGraph(gedcomText: ab.gedcomText(provenance: "A+B"))
        abFile.sourceFileName = "ab.ged"; abFile.sourceFingerprint = "abab"
        #expect(abFile.droppedLineCount == 0, "our own HEAD lines are not loss")
        #expect(abFile.sourceProvenance.map(\.name) == ["a.ged", "b.ged"])
        let bc = b.merge(with: c).graph
        #expect(bc.sourceProvenance.map(\.name) == ["b.ged", "c.ged"])

        let all = abFile.merge(with: bc)
        #expect(all.graph.sourceProvenance == [.init(name: "a.ged", sha256: "aa", droppedLineCount: 2),
                                               .init(name: "b.ged", sha256: "bb", droppedLineCount: 3),
                                               .init(name: "c.ged", sha256: "cc", droppedLineCount: 4)])
        #expect(all.graph.sourceFileNames == ["a.ged", "b.ged", "c.ged"])
        #expect(all.graph.droppedLineCount == 0)
        #expect(all.graph.totalDroppedLineCount == 9)
        #expect(all.droppedLineCount == 9)
        #expect(all.graph.people.count == 3, "Ann, Donna, Walter — Donna once")
        #expect(all.graph.sourceFingerprint == nil, "an in-memory merge has no file of its own")
        // Through text once more: identical list and totals.
        let back = GedcomFamilyGraph(gedcomText: all.graph.gedcomText())
        #expect(back.sourceProvenance == all.graph.sourceProvenance)
        #expect(back.droppedLineCount == 0 && back.totalDroppedLineCount == 9)
    }

    /// Two entries with the same identity but a different dropped count
    /// (someone edited a `_VS_DROPPED` line, or two parsers disagreed):
    /// a `.fieldDisagreement` naming both counts, first kept, counted once.
    @Test func provenanceCountDisagreementIsReportedAndTheFirstKept() throws {
        let a = named(Self.lossyA, "a.ged", "aa"), b = named(Self.lossyB, "b.ged", "bb")
        let ab = a.merge(with: b).graph
        var altered = GedcomFamilyGraph(gedcomText: ab.gedcomText()
            .replacingOccurrences(of: "2 _VS_SHA256 bb\n2 _VS_DROPPED 3", with: "2 _VS_SHA256 bb\n2 _VS_DROPPED 7"))
        altered.sourceFileName = "altered.ged"; altered.sourceFingerprint = "alt"
        #expect(altered.sourceProvenance.last?.droppedLineCount == 7)
        let outcome = ab.merge(with: altered)
        let report = try #require(outcome.conflicts.first { $0.kind == .fieldDisagreement && $0.ids == ["b.ged"] })
        #expect(report.resolution.contains("kept 3") && report.resolution.contains("says 7"), Comment(rawValue: report.resolution))
        #expect(outcome.graph.sourceProvenance == ab.sourceProvenance, "first kept, listed once")
        #expect(outcome.graph.totalDroppedLineCount == 5)
        // Reversed order: the 7 is first, so it is kept and 3 reported.
        let reversed = altered.merge(with: ab)
        #expect(reversed.graph.sourceProvenance.last?.droppedLineCount == 7)
        #expect(reversed.graph.totalDroppedLineCount == 9)
        #expect(reversed.conflicts.contains { $0.ids == ["b.ged"] && $0.resolution.contains("kept 7") })
    }

    /// A nameless text side cannot be listed: its loss stays LOCAL in the
    /// merged graph, a named side's loss is attributed, the total is exact.
    @Test func namelessSideKeepsItsLossLocalNamedSideIsAttributed() throws {
        let nameless = GedcomFamilyGraph(gedcomText: Self.lossyA)
        let b = named(Self.lossyB, "b.ged", "bb")
        let outcome = nameless.merge(with: b)
        #expect(outcome.graph.sourceProvenance == [.init(name: "b.ged", sha256: "bb", droppedLineCount: 3)])
        #expect(outcome.graph.droppedLineCount == 2, "the nameless side's loss")
        #expect(outcome.graph.totalDroppedLineCount == 5)
        #expect(outcome.droppedLineCount == 5)
    }
}
