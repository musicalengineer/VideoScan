// GedcomIdentityRulingsTests.swift
// codex #1710 (3) / #1712, 2026-09-23: Rick's identity rulings reached ONE
// query — `people(matching:)`. The surname roster, whole-tree iteration
// (superlatives), relationship answers and the compiled lineage walks all
// read the raw records, so a record he hid came back as a family member, an
// earliest-born O'Connor, a sibling or a second mother.
//
// The fixture is his real shape, with invented ids for the extras:
//
//   @F6@  Michael O'Connor + Bridget      → Mary Christina [G89Q-34N], Mary [GNZ5-428]
//   @F3@  David Latta Sr + Mary Christina → Eileen
//   @F4@  (no husband)   + Mary [dup]     → Eileen, Kathleen   (Kathleen only here)
//   @FB3@ (no husband)   + Mary Christina → Eileen
//
// Rulings: GNZ5-428 duplicateOf G89Q-34N. The duplicate carries a bogus
// 1850 birth year so an unfiltered "earliest-born O'Connor" picks her.
//
// Dimensions: LOGIC (each query surface) · SCALE (100k synthetic people,
// time budget) · ISOLATION (the raw graph is untouched by the ruled copy) ·
// SENSOR (patched compiled topology == a from-scratch build of the ruled
// graph, so the walks and `relatives` can never drift).
//
// NOT tested here, deliberately: WHICH of Eileen's genuinely different parent
// families is right. That is Rick's open ruling; these tests pin only that
// his PERSON ruling is applied and that nothing is dropped in silence.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Identity rulings: one ruled query view (codex #1710/#1712)")
struct GedcomIdentityRulingsTests {

    static let text = """
    0 HEAD
    0 @F6@ FAM
    1 HUSB @M@
    1 WIFE @B@
    1 CHIL @I7@
    1 CHIL @I5@
    0 @F3@ FAM
    1 HUSB @D@
    1 WIFE @I7@
    1 CHIL @E@
    1 _FSFTID MT64-4HP
    0 @F4@ FAM
    1 WIFE @I5@
    1 CHIL @E@
    1 CHIL @K@
    0 @FB3@ FAM
    1 WIFE @I7@
    1 CHIL @E@
    0 @M@ INDI
    1 NAME Michael /O'Connor/
    1 SEX M
    1 FAMS @F6@
    1 _FSFTID GMOC-001
    0 @B@ INDI
    1 NAME Bridget /Ronan/
    1 SEX F
    1 FAMS @F6@
    1 _FSFTID GBRI-002
    0 @I7@ INDI
    1 NAME Mary Christina /O'Connor/
    1 SEX F
    1 BIRT
    2 DATE 23 December 1904
    1 FAMC @F6@
    1 FAMS @F3@
    1 FAMS @FB3@
    1 _FSFTID G89Q-34N
    0 @I5@ INDI
    1 NAME Mary /O'Connor/
    1 SEX F
    1 BIRT
    2 DATE 1850
    1 FAMC @F6@
    1 FAMS @F4@
    1 _FSFTID GNZ5-428
    0 @D@ INDI
    1 NAME David McGill /Latta/ Sr
    1 SEX M
    1 FAMS @F3@
    1 _FSFTID LX9M-WJG
    0 @E@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 FAMC @F3@
    1 FAMC @F4@
    1 FAMC @FB3@
    1 _FSFTID G2CR-R4H
    0 @K@ INDI
    1 NAME Kathleen /Latta/
    1 SEX F
    1 FAMC @F4@
    1 _FSFTID GKAT-111
    0 TRLR
    """

    static var rulings: FamilyIdentityDecisions {
        var r = FamilyIdentityDecisions()
        r.record(.init(key: .familySearch("G89Q-34N"), verified: true))
        r.record(.init(key: .familySearch("GNZ5-428"), duplicateOf: .familySearch("G89Q-34N")))
        return r
    }

    /// A raw graph whose compiled index is already built — the production
    /// shape (a promoted artifact arrives with its index installed), so
    /// the ruled view has to PATCH it rather than build one lazily.
    private func rawWithIndex() -> GedcomFamilyGraph {
        let g = GedcomFamilyGraph(gedcomText: Self.text)
        _ = g.index
        return g
    }

    private func ids(_ people: [GedcomFamilyGraph.Person]) -> [String] { people.map(\.id) }

    // MARK: The roster and whole-tree iteration

    @Test func theSurnameRosterNoLongerCarriesTheHiddenRecord() {
        let raw = rawWithIndex()
        #expect(ids(raw.people(withSurname: "O'Connor")).contains("@I5@"),
                "precondition: raw, the duplicate IS an O'Connor")
        let ruled = raw.applyingIdentityRulings(Self.rulings)
        let roster = ids(ruled.people(withSurname: "O'Connor"))
        #expect(!roster.contains("@I5@"), "hidden duplicate is back in the O'Connor roster: \(roster)")
        #expect(roster.filter { $0 == "@I7@" }.count == 1, "the verified Mary exactly once")
        #expect(roster.contains("@M@"))
    }

    @Test func wholeTreeIterationSkipsTheHiddenRecord_soItCannotWinEarliestBorn() {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        #expect(!ids(ruled.visiblePeople).contains("@I5@"))
        #expect(ruled.visiblePeople.count == ruled.people.count - 1)
        // The superlative's own rule: earliest birth year among O'Connors.
        let earliest = ruled.people(withSurname: "O'Connor")
            .compactMap { p in p.birthYear.map { (p, $0) } }
            .min { $0.1 < $1.1 }?.0
        #expect(earliest?.id == "@I7@", "the bogus 1850 duplicate won earliest-born: \(earliest?.name ?? "nil")")
    }

    @Test func namedLikeHandsTheDuplicateToTheVerifiedRecord() {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let found = ids(ruled.people(namedLike: "Mary O'Connor"))
        #expect(!found.contains("@I5@"))
        #expect(found.filter { $0 == "@I7@" }.count == 1)
    }

    // MARK: Relationships (direct access)

    @Test func eileenHasOneMotherAndItIsTheVerifiedMary() {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let eileen = ruled.people["@E@"]!
        #expect(ids(ruled.relatives(.mother, of: eileen)) == ["@I7@"])
        #expect(ids(ruled.relatives(.parents, of: eileen)) == ["@D@", "@I7@"])
    }

    @Test func aChildRecordedOnlyUnderTheDuplicateHasTheVerifiedMotherAndSheHasTheChild() {
        let raw = rawWithIndex()
        #expect(ids(raw.relatives(.mother, of: raw.people["@K@"]!)) == ["@I5@"], "precondition")
        let ruled = raw.applyingIdentityRulings(Self.rulings)
        #expect(ids(ruled.relatives(.mother, of: ruled.people["@K@"]!)) == ["@I7@"],
                "a hidden record was returned as Kathleen's mother")
        // Symmetric: the walk down agrees with the walk up.
        let kids = ids(ruled.relatives(.children, of: ruled.people["@I7@"]!))
        #expect(kids.sorted() == ["@E@", "@K@"], "children of the verified Mary: \(kids)")
        #expect(kids.filter { $0 == "@E@" }.count == 1, "Eileen listed once, not once per family record")
    }

    @Test func theHiddenRecordIsNobodysSiblingOrChild() {
        let raw = rawWithIndex()
        #expect(ids(raw.relatives(.siblings, of: raw.people["@I7@"]!)) == ["@I5@"], "precondition")
        let ruled = raw.applyingIdentityRulings(Self.rulings)
        #expect(ruled.relatives(.siblings, of: ruled.people["@I7@"]!).isEmpty)
        #expect(ids(ruled.relatives(.children, of: ruled.people["@M@"]!)) == ["@I7@"])
        let units = ruled.familyUnits(of: ruled.people["@B@"]!)
        #expect(units.flatMap(\.children).map(\.id) == ["@I7@"])
    }

    @Test func familyUnitsOfTheVerifiedMaryIncludeTheDuplicatesMarriage() {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let units = ruled.familyUnits(of: ruled.people["@I7@"]!)
        #expect(Set(units.map(\.id)) == ["@F3@", "@FB3@", "@F4@"])
        #expect(units.first { $0.id == "@F4@" }?.children.map(\.id) == ["@E@", "@K@"])
    }

    // MARK: Parent-family choice — Rick's PERSON ruling applied, nothing chosen silently

    @Test func eileensParentFamilyChoiceAppliesThePersonRulingAndStillReportsEveryFamily() throws {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let choice = try #require(ruled.parentFamilyChoice(of: ruled.people["@E@"]!))
        #expect(choice.ranks.count == 3, "all three FAMC families are still in the ranking")
        #expect(choice.mother?.id == "@I7@")
        #expect(!choice.alternates.contains { $0.person.id == "@I5@" },
                "the hidden record resurfaced as an alternate mother")
        let note = ruled.parentFamilyBasisNote(for: ruled.people["@E@"]!) ?? ""
        #expect(!note.contains("1850"), "the basis note names the hidden record: \(note)")
    }

    @Test func aGenuinelyDifferentParentFamilyIsStillReportedNotDroppedSilently() throws {
        // Zoe: a FamilySearch family (Adam + Alice) and a stray local one
        // with a different father. An unrelated ruling is in force, so the
        // ruled code path runs.
        let text = """
        0 HEAD
        0 @FA@ FAM
        1 HUSB @A@
        1 WIFE @L@
        1 CHIL @Z@
        1 _FSFTID FAMA-001
        0 @FS@ FAM
        1 HUSB @S@
        1 CHIL @Z@
        0 @A@ INDI
        1 NAME Adam /Foster/
        1 SEX M
        1 FAMS @FA@
        1 _FSFTID GADA-001
        0 @L@ INDI
        1 NAME Alice /Grey/
        1 SEX F
        1 FAMS @FA@
        1 _FSFTID GALI-001
        0 @S@ INDI
        1 NAME Zeke /Smith/
        1 SEX M
        1 FAMS @FS@
        1 _FSFTID GZEK-001
        0 @Z@ INDI
        1 NAME Zoe /Foster/
        1 SEX F
        1 FAMC @FA@
        1 FAMC @FS@
        1 _FSFTID GZOE-001
        0 @X@ INDI
        1 NAME Unrelated /Person/
        1 _FSFTID GXXX-001
        0 TRLR
        """
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("GXXX-001"), hidden: true))
        let ruled = GedcomFamilyGraph(gedcomText: text).applyingIdentityRulings(rulings)
        #expect(!ruled.suppressedPersonIDs.isEmpty, "precondition: the ruled path is active")
        let choice = try #require(ruled.parentFamilyChoice(of: ruled.people["@Z@"]!))
        #expect(choice.primaryFamilyID == "@FA@")
        #expect(choice.unfoldedAlternates.map(\.person.id) == ["@S@"])
        let note = try #require(ruled.parentFamilyBasisNote(for: ruled.people["@Z@"]!))
        #expect(note.contains("second parent family"), "a different family must be disclosed: \(note)")
    }

    // MARK: Compiled topology (the walks) — SENSOR

    @Test func patchedTopologyEqualsAFromScratchBuildOfTheRuledGraph() {
        let patched = rawWithIndex().applyingIdentityRulings(Self.rulings).index
        // No index built before ruling → the lazy build reads the ruled
        // `relatives`: the reference answer.
        let scratch = GedcomFamilyGraph(gedcomText: Self.text).applyingIdentityRulings(Self.rulings).index
        #expect(patched.parentStart == scratch.parentStart)
        #expect(patched.parents == scratch.parents)
        #expect(patched.motherOffset == scratch.motherOffset)
        #expect(patched.childStart == scratch.childStart)
        #expect(patched.children == scratch.children)
        #expect(patched.spouseStart == scratch.spouseStart)
        #expect(patched.spouses == scratch.spouses)
    }

    @Test func theLineageWalkGoesThroughTheVerifiedRecord() {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let line = ruled.ancestorLine(of: ruled.people["@K@"]!, line: .maternal, generations: 2)
        #expect(line.first?.people.map(\.id) == ["@I7@"], "Kathleen's mother via the compiled walk")
        #expect(line.dropFirst().first?.people.map(\.id) == ["@B@"], "…and on to Bridget")
    }

    /// QA follow-up 2026-09-24: `directAncestorLine` climbed raw parent
    /// pointers, so Kathleen's only parent family (@F4@, wife = the hidden
    /// duplicate @I5@) took the climb THROUGH the record Rick hid and never
    /// reached the verified Mary.
    @Test func theDirectAncestorClimbGoesThroughTheVerifiedRecordNeverAHiddenOne() throws {
        let ruled = rawWithIndex().applyingIdentityRulings(Self.rulings)
        let kathleen = try #require(ruled.people["@K@"])
        let mary = try #require(ruled.people["@I7@"])
        let toMary = try #require(ruled.directAncestorLine(from: kathleen, to: mary),
                                  "Kathleen's verified mother is not on her direct line")
        #expect(toMary.generations == 1)
        #expect(ids(toMary.chain) == ["@K@", "@I7@"])

        let bridget = try #require(ruled.people["@B@"])
        let toBridget = try #require(ruled.directAncestorLine(from: kathleen, to: bridget))
        #expect(toBridget.generations == 2)
        #expect(ids(toBridget.chain) == ["@K@", "@I7@", "@B@"])
        for chain in [toMary.chain, toBridget.chain] {
            #expect(!chain.contains { ruled.isHidden($0.id) }, "a chain passed through a hidden record")
        }
        let hidden = try #require(ruled.people["@I5@"])
        #expect(ruled.directAncestorLine(from: kathleen, to: hidden) == nil,
                "the hidden duplicate is nobody's ancestor in the ruled view")
    }

    // MARK: ISOLATION — the raw graph is untouched

    @Test func theRawGraphKeepsItsRawAnswersAndIndex() {
        let raw = rawWithIndex()
        let rawParents = raw.index.parents
        _ = raw.applyingIdentityRulings(Self.rulings).index
        #expect(raw.suppressedPersonIDs.isEmpty)
        #expect(raw.index.parents == rawParents, "the ruled patch leaked into the raw graph's shared index")
        #expect(ids(raw.relatives(.mother, of: raw.people["@K@"]!)) == ["@I5@"])
        #expect(raw.allRecordedParents(of: raw.people["@E@"]!).map(\.id).contains("@I5@"),
                "audits still see the raw evidence")
    }

    @Test func reapplyingIsANoOpAndUnhidingRestoresTheRawView() {
        let raw = rawWithIndex()
        let ruled = raw.applyingIdentityRulings(Self.rulings)
        let again = ruled.applyingIdentityRulings(Self.rulings)
        #expect(again.suppressedPersonIDs == ruled.suppressedPersonIDs)
        #expect(again.preferredPersonID == ruled.preferredPersonID)
        let unhidden = ruled.applyingIdentityRulings(FamilyIdentityDecisions())
        #expect(unhidden.suppressedPersonIDs.isEmpty && unhidden.preferredPersonID.isEmpty)
        #expect(unhidden.index.parents == raw.index.parents)
        #expect(unhidden.index.children == raw.index.children)
        #expect(ids(unhidden.people(withSurname: "O'Connor")).contains("@I5@"))
    }

    // MARK: Rulings revision (the shared cache's key)

    @Test func theRevisionFollowsTheFileContent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rulings-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FamilyIdentityDecisions.loadWithRevision(from: dir).revision == "none")
        try Self.rulings.save(to: dir)
        let first = FamilyIdentityDecisions.loadWithRevision(from: dir)
        // (decidedAt round-trips at whole seconds, so compare the rulings' substance.)
        #expect(first.decisions.suppressedFamilySearchIDs == Self.rulings.suppressedFamilySearchIDs)
        #expect(first.decisions.preferred(.familySearch("GNZ5-428")) == .familySearch("G89Q-34N"))
        #expect(first.revision.count == 64)
        #expect(FamilyIdentityDecisions.loadWithRevision(from: dir).revision == first.revision, "stable")
        var unhidden = Self.rulings
        unhidden.remove(.familySearch("GNZ5-428"))
        try unhidden.save(to: dir)
        #expect(FamilyIdentityDecisions.loadWithRevision(from: dir).revision != first.revision)
    }

    // MARK: SCALE

    @Test func applyingRulingsTo100kPeopleWithAnIndexStaysInBudget() {
        // 25k four-person families (father, mother, two children); every
        // 1000th mother is recorded twice and ruled a duplicate.
        var lines = ["0 HEAD"]
        lines.reserveCapacity(25_000 * 30)
        var rulings = FamilyIdentityDecisions()
        for f in 0..<25_000 {
            let fam = "@F\(f)@", dad = "@D\(f)@", mom = "@M\(f)@"
            lines += ["0 \(fam) FAM", "1 HUSB \(dad)", "1 WIFE \(mom)", "1 CHIL @A\(f)@", "1 CHIL @B\(f)@"]
            lines += ["0 \(dad) INDI", "1 NAME Dad\(f) /Surname\(f % 500)/", "1 SEX M", "1 FAMS \(fam)"]
            lines += ["0 \(mom) INDI", "1 NAME Mom\(f) /Other\(f % 500)/", "1 SEX F", "1 FAMS \(fam)",
                      "1 _FSFTID M\(String(format: "%03d", f % 1000))-\(String(format: "%03d", f / 1000))"]
            lines += ["0 @A\(f)@ INDI", "1 NAME Ann\(f) /Surname\(f % 500)/", "1 SEX F", "1 FAMC \(fam)"]
            lines += ["0 @B\(f)@ INDI", "1 NAME Bob\(f) /Surname\(f % 500)/", "1 SEX M", "1 FAMC \(fam)"]
            if f % 1000 == 0 {
                let dupFam = "@G\(f)@"
                lines += ["0 \(dupFam) FAM", "1 WIFE @X\(f)@", "1 CHIL @A\(f)@"]
                lines += ["0 @X\(f)@ INDI", "1 NAME Mom\(f) /Other\(f % 500)/", "1 SEX F", "1 FAMS \(dupFam)",
                          "1 _FSFTID X\(String(format: "%03d", f / 1000))-DUP"]
                rulings.record(.init(key: .familySearch("X\(String(format: "%03d", f / 1000))-DUP"),
                                     duplicateOf: .familySearch("M000-\(String(format: "%03d", f / 1000))")))
            }
        }
        lines.append("0 TRLR")
        let raw = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        #expect(raw.people.count == 100_025)
        _ = raw.index
        let clock = ContinuousClock()
        let start = clock.now
        let ruled = raw.applyingIdentityRulings(rulings)
        let topology = ruled.index
        let elapsed = clock.now - start
        #expect(ruled.suppressedPersonIDs.count == 25)
        #expect(ruled.preferredPersonID.count == 25)
        #expect(topology.parents.count <= raw.index.parents.count)
        // Debug build on the M4 measured well under this; the point is
        // "no full index rebuild" (~1.5–3 s Debug at this size).
        #expect(elapsed < .milliseconds(1_000), "applying 25 rulings to 100k people took \(elapsed)")
        let a0 = ruled.people["@A0@"]!
        #expect(ruled.relatives(.mother, of: a0).map(\.id) == ["@M0@"])
    }
}
