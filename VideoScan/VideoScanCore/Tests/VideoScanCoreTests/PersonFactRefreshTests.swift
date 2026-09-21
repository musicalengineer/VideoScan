import Testing
import Foundation
@testable import VideoScanCore

// "Refresh from FamilySearch…" for one person (2026-09-21) — the pure half:
// accepting a one-person export, the per-field diff, the overlay's edits,
// apply-at-read-time and its store. Synthetic people only (2026-08-03
// privacy policy); IDs are shaped like FamilySearch's but belong to nobody.
//
// Dimensions (CLAUDE.md feature-test checklist): LOGIC (every table below),
// SCALE (`overlayOverFortyThousandPeople`), ISOLATION (every store test uses
// its own temp directory), SENSOR (`relationshipsAreNeverChangedByAnOverlay`).

// MARK: - Fixtures

enum PersonRefreshFixtures {
    /// The installed tree: Walter (the refreshed person) married to Mae,
    /// their son Ned, Walter's parents Otto + Ida, and an unrelated Zed.
    static let tree = """
    0 HEAD
    1 GEDC
    2 VERS 5.5.1
    0 @I1@ INDI
    1 NAME Walter James /Dunn/
    1 SEX M
    1 BIRT
    2 DATE 21 Feb 1928
    2 PLAC Boston, Massachusetts
    1 DEAT
    2 DATE 25 Jun 2008
    1 FAMC @F1@
    1 FAMS @F2@
    1 _FSFTID WWWW-111
    0 @I2@ INDI
    1 NAME Mae /Lamb/
    1 SEX F
    1 FAMS @F2@
    1 _FSFTID MMMM-222
    0 @I3@ INDI
    1 NAME Ned /Dunn/
    1 SEX M
    1 FAMC @F2@
    1 _FSFTID NNNN-333
    0 @I4@ INDI
    1 NAME Otto /Dunn/
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID OOOO-444
    0 @I5@ INDI
    1 NAME Ida /Roe/
    1 SEX F
    1 FAMS @F1@
    1 _FSFTID IIII-555
    0 @I6@ INDI
    1 NAME Zed /Far/
    1 SEX M
    1 BIRT
    2 DATE 1900
    1 _FSFTID ZZZZ-666
    0 @F1@ FAM
    1 HUSB @I4@
    1 WIFE @I5@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 MARR
    2 DATE 1950
    0 TRLR
    """

    /// What getmyancestors `-i WWWW-111 -a 0 -d 0 -m` writes: the person
    /// first, each spouse as a full INDI, one FAM per couple, no parents.
    static func onePerson(birth: String = "21 Feb 1929", deathPlace: String? = "Pittsfield, Massachusetts",
                          marriage: String = "12 Jun 1950", extraSpouse: Bool = false,
                          unrelated: Bool = false, fsid: String = "WWWW-111") -> String {
        var lines = [
            "0 HEAD", "1 CHAR UTF-8", "1 SOUR getmyancestors",
            "0 @I1@ INDI", "1 NAME Walter James /Dunn/", "1 SEX M",
            "1 BIRT", "2 DATE \(birth)", "2 PLAC Boston, Massachusetts",
            "1 DEAT", "2 DATE 25 Jun 2008",
        ]
        if let deathPlace { lines.append("2 PLAC \(deathPlace)") }
        lines += ["1 FAMS @F1@"]
        if extraSpouse { lines.append("1 FAMS @F2@") }
        lines += ["1 _FSFTID \(fsid)",
                  "0 @I2@ INDI", "1 NAME Mae /Lamb/", "1 SEX F", "1 FAMS @F1@", "1 _FSFTID MMMM-222"]
        if extraSpouse {
            lines += ["0 @I3@ INDI", "1 NAME Vera /Kent/", "1 SEX F", "1 FAMS @F2@", "1 _FSFTID VVVV-777"]
        }
        if unrelated {
            lines += ["0 @I9@ INDI", "1 NAME Stranger /Nobody/", "1 _FSFTID SSSS-999"]
        }
        lines += ["0 @F1@ FAM", "1 HUSB @I1@", "1 WIFE @I2@", "1 MARR", "2 DATE \(marriage)", "1 _FSFTID CCCC-001"]
        if extraSpouse { lines += ["0 @F2@ FAM", "1 HUSB @I1@", "1 WIFE @I3@"] }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }

    static var treeGraph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: tree) }

    static func installedFacts(_ graph: GedcomFamilyGraph = treeGraph, fsid: String = "WWWW-111") -> PersonFacts {
        PersonFacts(person: graph.person(familySearchID: fsid)!, in: graph)!
    }

    static func incomingFacts(_ text: String) throws -> PersonFacts {
        try PersonRefreshFile.evaluate(GedcomFamilyGraph(gedcomText: text), fileName: "person.ged",
                                       requestedFamilySearchID: "WWWW-111").get()
    }

    static func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-refresh-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private typealias F = PersonRefreshFixtures

// MARK: - Fields

struct PersonRefreshFieldTests {
    @Test func keysRoundTrip() {
        let all: [PersonRefreshField] = [.name, .surname, .sex, .birthDate, .birthPlace, .deathDate,
                                         .deathPlace, .marriageDate(spouseFamilySearchID: "MMMM-222")]
        for field in all { #expect(PersonRefreshField(key: field.key) == field) }
    }

    @Test(arguments: ["parents", "FAMC", "spouse", "children", "marriageDate:", "marriageDate:not-an-id", ""])
    func relationshipAndMalformedKeysAreNotFields(_ key: String) {
        #expect(PersonRefreshField(key: key) == nil)
    }
}

// MARK: - Accepting the export

struct PersonRefreshFileTests {
    @Test func unparsableFileIsNotAGedcom() {
        let result = PersonRefreshFile.evaluate(nil, fileName: "person.ged", requestedFamilySearchID: "WWWW-111")
        #expect(result == .failure(.notAGedcom(fileName: "person.ged")))
    }

    @Test func emptyExportMeansTheRecordIsGone() {
        let graph = GedcomFamilyGraph(gedcomText: "0 HEAD\n1 SOUR getmyancestors\n0 TRLR")
        let result = PersonRefreshFile.evaluate(graph, fileName: "p.ged", requestedFamilySearchID: "wwww-111")
        #expect(result == .failure(.recordGone(requested: "WWWW-111")))
        guard case .failure(let refusal) = result else { return }
        #expect(refusal.sentence.contains("FamilySearch no longer has WWWW-111"))
        #expect(refusal.sentence.contains("merged into another record"))
    }

    @Test func aDifferentPersonReturnedIsRefusedAndNamed() {
        let graph = GedcomFamilyGraph(gedcomText: F.onePerson(fsid: "WXYZ-999"))
        let result = PersonRefreshFile.evaluate(graph, fileName: "p.ged", requestedFamilySearchID: "WWWW-111")
        #expect(result == .failure(.differentPersonReturned(requested: "WWWW-111", returned: "WXYZ-999")))
    }

    @Test func anUnrelatedPersonInTheFileIsRefused() {
        let graph = GedcomFamilyGraph(gedcomText: F.onePerson(unrelated: true))
        let result = PersonRefreshFile.evaluate(graph, fileName: "p.ged", requestedFamilySearchID: "WWWW-111")
        #expect(result == .failure(.tooManyPeople(requested: "WWWW-111", people: 3, unrelated: 1)))
    }

    @Test func aWholeTreeIsNotAOnePersonRefresh() {
        // The narrowing shape: a many-person file offered as "one person".
        let result = PersonRefreshFile.evaluate(F.treeGraph, fileName: "tree.ged", requestedFamilySearchID: "WWWW-111")
        #expect(result == .failure(.tooManyPeople(requested: "WWWW-111", people: 6, unrelated: 1)))
    }

    @Test func spouseStubsAreAccepted() throws {
        let facts = try F.incomingFacts(F.onePerson(extraSpouse: true))
        #expect(facts.familySearchID == "WWWW-111")
        #expect(facts.spouses.compactMap(\.familySearchID).sorted() == ["MMMM-222", "VVVV-777"])
        #expect(facts.birthDate == "21 Feb 1929")
    }
}

// MARK: - Diff

struct PersonRefreshDiffTests {
    @Test func identicalFactsAlreadyMatch() throws {
        let installed = F.installedFacts()
        let diff = PersonRefreshDiff.compute(installed: installed, incoming: installed)
        #expect(diff.factsMatch)
        #expect(diff.relationshipNotes.isEmpty)
    }

    @Test func correctedBirthYearAddedPlaceAndMarriageDateAreThreeChanges() throws {
        let diff = PersonRefreshDiff.compute(installed: F.installedFacts(),
                                             incoming: try F.incomingFacts(F.onePerson()))
        #expect(diff.changes.map(\.field) == [.birthDate, .deathPlace,
                                              .marriageDate(spouseFamilySearchID: "MMMM-222")])
        #expect(diff.changes[0].old == "21 Feb 1928")
        #expect(diff.changes[0].new == "21 Feb 1929")
        #expect(diff.changes[1].old == nil)
        #expect(diff.changes[1].new == "Pittsfield, Massachusetts")
        #expect(diff.changes[2].label == "Marriage date (with Mae Lamb)")
        #expect(diff.changes[2].old == "1950")
        #expect(diff.relationshipNotes.isEmpty)
    }

    /// Each row: (field, installed value, incoming value, is it a change?).
    static let table: [(PersonRefreshField, String?, String?, Bool)] = [
        (.birthDate, "21 FEB 1929", "21 Feb 1929", false),        // GEDCOM month case
        (.birthDate, "21  Feb 1929 ", "21 Feb 1929", false),      // whitespace
        (.birthDate, "", nil, false),                             // both absent
        (.birthDate, "1929", "ABT 1929", true),
        (.deathDate, "25 Jun 2008", nil, true),                   // FamilySearch cleared it
        (.birthPlace, "Boston", "Boston, Massachusetts", true),
        (.sex, "U", "", false),                                   // unknown == blank
        (.sex, "M", "F", true),
        (.name, "Walter Dunn", nil, false),                       // never erase a name
        (.name, "Walter Dunn", "Walter James Dunn", true),
        (.surname, nil, "Dunn", true),
    ]

    @Test(arguments: 0..<table.count)
    func fieldTable(_ row: Int) {
        let (field, old, new, isChange) = Self.table[row]
        var installed = PersonFacts(familySearchID: "WWWW-111", name: "Walter Dunn")
        var incoming = installed
        func set(_ facts: inout PersonFacts, _ value: String?) {
            switch field {
            case .name: facts.name = value ?? ""
            case .surname: facts.surname = value
            case .sex: facts.sex = value ?? ""
            case .birthDate: facts.birthDate = value
            case .birthPlace: facts.birthPlace = value
            case .deathDate: facts.deathDate = value
            case .deathPlace: facts.deathPlace = value
            case .marriageDate: break
            }
        }
        set(&installed, old)
        set(&incoming, new)
        let diff = PersonRefreshDiff.compute(installed: installed, incoming: incoming)
        #expect(diff.changes.map(\.field) == (isChange ? [field] : []), "row \(row)")
    }

    @Test func spouseDifferencesAreNotesNotChanges() throws {
        // FamilySearch shows a second wife the tree does not have.
        let diff = PersonRefreshDiff.compute(installed: F.installedFacts(),
                                             incoming: try F.incomingFacts(F.onePerson(marriage: "1950", extraSpouse: true)))
        #expect(diff.changes.map(\.field) == [.birthDate, .deathPlace])
        #expect(diff.relationshipNotes.map(\.kind) == [.spouseOnlyOnFamilySearch])
        #expect(diff.relationshipNotes[0].sentence.contains("FamilySearch shows a different spouse (Vera Kent, VVVV-777)"))
        #expect(diff.relationshipNotes[0].sentence.contains("a full tree pull updates relationships"))

        // …and the reverse: the tree links a spouse FamilySearch dropped.
        var incoming = try F.incomingFacts(F.onePerson())
        incoming.spouses = []
        let reverse = PersonRefreshDiff.compute(installed: F.installedFacts(), incoming: incoming)
        #expect(reverse.relationshipNotes.map(\.kind) == [.spouseOnlyInTree])
        #expect(!reverse.changes.contains { if case .marriageDate = $0.field { return true } else { return false } })
    }

    @Test func missingParentsInAZeroGenerationPullAreNotADifference() throws {
        // `-a 0` never fetches parents; the tree has Otto + Ida. No note.
        let diff = PersonRefreshDiff.compute(installed: F.installedFacts(),
                                             incoming: try F.incomingFacts(F.onePerson()))
        #expect(!diff.relationshipNotes.contains { $0.spouseFamilySearchID == "OOOO-444" || $0.spouseFamilySearchID == "IIII-555" })
    }
}

// MARK: - Overlay edits

struct PersonFactOverlayEditTests {
    private func change(_ field: PersonRefreshField, _ old: String?, _ new: String?) -> PersonRefreshChange {
        PersonRefreshChange(field: field, label: field.key, old: old, new: new)
    }

    @Test func recordMergesAndUndoRestoresEachEarlierState() throws {
        var overlay = PersonFactOverlay()
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        overlay.record([change(.birthDate, "1928", "1929")], familySearchID: "wwww-111", displayName: "Walter", at: t1)
        overlay.record([change(.deathPlace, nil, "Pittsfield")], familySearchID: "WWWW-111", displayName: "Walter", at: t2)
        let entry = try #require(overlay.entries["WWWW-111"])
        #expect(entry.facts.keys.sorted() == ["birthDate", "deathPlace"])
        #expect(entry.appliedAt == t2)
        #expect(entry.history.count == 1)

        let firstUndo = overlay.undoLast(familySearchID: "WWWW-111")
        let first = try #require(firstUndo)
        #expect(first.after?.facts.keys.sorted() == ["birthDate"])
        #expect(first.after?.appliedAt == t1)
        let secondUndo = overlay.undoLast(familySearchID: "WWWW-111")
        let second = try #require(secondUndo)
        #expect(second.after == nil)
        #expect(overlay.entries.isEmpty)
        let thirdUndo = overlay.undoLast(familySearchID: "WWWW-111")
        #expect(thirdUndo == nil)
    }

    @Test func historyIsBounded() {
        var overlay = PersonFactOverlay()
        for i in 0..<(PersonFactOverlay.historyLimit + 5) {
            overlay.record([change(.birthDate, nil, "\(1900 + i)")], familySearchID: "WWWW-111",
                           displayName: "W", at: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(overlay.entries["WWWW-111"]?.history.count == PersonFactOverlay.historyLimit)
    }

    @Test func aNewerPullSupersedesOnlyOlderEntries() {
        var overlay = PersonFactOverlay()
        overlay.record([change(.birthDate, nil, "1929")], familySearchID: "WWWW-111", displayName: "W",
                       at: Date(timeIntervalSince1970: 100))
        overlay.record([change(.birthDate, nil, "1882")], familySearchID: "MMMM-222", displayName: "M",
                       at: Date(timeIntervalSince1970: 300))
        let stale = overlay.superseded(byPullAt: Date(timeIntervalSince1970: 200))
        #expect(stale == ["WWWW-111"])
        overlay.retire(stale, at: Date(timeIntervalSince1970: 400), reason: "test")
        #expect(overlay.entries.keys.sorted() == ["MMMM-222"])
        #expect(overlay.retired.map(\.familySearchID) == ["WWWW-111"])
    }

    @Test func codecRoundTrips() throws {
        var overlay = PersonFactOverlay()
        overlay.record([change(.marriageDate(spouseFamilySearchID: "MMMM-222"), "1950", "12 Jun 1950")],
                       familySearchID: "WWWW-111", displayName: "Walter", at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try PersonFactOverlay.decode(overlay.encoded()) == overlay)
    }
}

// MARK: - Apply at read time

struct PersonFactOverlayApplyTests {
    private func overlay(_ facts: [PersonRefreshField: String?], fsid: String = "WWWW-111") -> PersonFactOverlay {
        var o = PersonFactOverlay()
        o.record(facts.map { PersonRefreshChange(field: $0.key, label: "", old: nil, new: $0.value) },
                 familySearchID: fsid, displayName: "W", at: Date())
        return o
    }

    @Test func datesApplyAndThePatchedIndexEqualsAFreshBuild() {
        let base = F.treeGraph
        _ = base.index                                     // a compiled tree arrives indexed
        let (graph, report) = base.applyingFactOverlay(overlay([.birthDate: "21 Feb 1929", .deathPlace: "Pittsfield"]))
        #expect(report.fieldsChanged == 2)
        #expect(!report.indexDropped)
        #expect(graph.hasBuiltIndex)                       // patched, not dropped
        let walter = graph.person(familySearchID: "WWWW-111")!
        #expect(walter.birthDate == "21 Feb 1929")
        #expect(walter.deathPlace == "Pittsfield")
        #expect(graph.index == GedcomFamilyGraph.TreeIndex(graph: graph))
        // The base value is untouched (value semantics + its own box).
        #expect(base.person(familySearchID: "WWWW-111")!.birthDate == "21 Feb 1928")
        #expect(base.index.lifeYears == GedcomFamilyGraph.TreeIndex(graph: base).lifeYears)
    }

    @Test func aNameChangeDropsTheIndexSoSearchFindsTheNewName() {
        let base = F.treeGraph
        _ = base.index
        let (graph, report) = base.applyingFactOverlay(overlay([.name: "Walter Jameson Dunn"]))
        #expect(report.indexDropped)
        #expect(graph.people(matching: "Jameson").map(\.id) == ["@I1@"])
        #expect(base.people(matching: "Jameson").isEmpty)
    }

    @Test func marriageDateAppliesOnlyToAFamilyThePersonIsAlreadyIn() {
        let (graph, _) = F.treeGraph.applyingFactOverlay(overlay([
            .marriageDate(spouseFamilySearchID: "MMMM-222"): "12 Jun 1950",
            .marriageDate(spouseFamilySearchID: "VVVV-777"): "1960",   // not linked in the tree
        ]))
        let walter = graph.person(familySearchID: "WWWW-111")!
        #expect(graph.marriages(of: walter).map(\.date) == ["12 Jun 1950"])
    }

    @Test func nothingDifferentReturnsTheSameGraphAndIndex() {
        let base = F.treeGraph
        let index = base.index
        let (graph, report) = base.applyingFactOverlay(overlay([.birthDate: "21 Feb 1928"]))
        #expect(report.fieldsChanged == 0)
        #expect(graph.index == index)
        #expect(graph.indexBox === base.indexBox)
    }

    @Test func missingPeopleAreReportedNotInvented() {
        let (graph, report) = F.treeGraph.applyingFactOverlay(overlay([.birthDate: "1900"], fsid: "QQQQ-000"))
        #expect(report.missingFamilySearchIDs == ["QQQQ-000"])
        #expect(graph.people.count == 6)
    }

    @Test func unknownKeysInTheFileAreIgnored() throws {
        var o = PersonFactOverlay()
        o.entries["WWWW-111"] = .init(familySearchID: "WWWW-111", displayName: "W", appliedAt: Date(),
                                      facts: ["parents": .init(value: "@I6@", before: nil),
                                              "FAMC": .init(value: "@F9@", before: nil)])
        let (graph, report) = F.treeGraph.applyingFactOverlay(o)
        #expect(report.fieldsChanged == 0)
        #expect(graph.person(familySearchID: "WWWW-111")!.childOfFamilies == ["@F1@"])
    }

    /// SENSOR: whatever an overlay says, every relationship in the tree is
    /// byte-for-byte what the pull said — pointers, FAMC/FAMS, HUSB/WIFE/
    /// CHIL, roots and FamilySearch IDs.
    @Test func relationshipsAreNeverChangedByAnOverlay() {
        let base = F.treeGraph
        var o = overlay([.name: "Walt Dunn", .surname: "Dunne", .sex: "F", .birthDate: "1929",
                         .deathDate: nil, .marriageDate(spouseFamilySearchID: "MMMM-222"): "1951"])
        o.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: "1850")],
                 familySearchID: "NNNN-333", displayName: "Ned", at: Date())
        let (graph, _) = base.applyingFactOverlay(o)
        #expect(graph.people.keys.sorted() == base.people.keys.sorted())
        for (id, before) in base.people {
            let after = graph.people[id]!
            #expect(after.childOfFamilies == before.childOfFamilies)
            #expect(after.childOfFamily == before.childOfFamily)
            #expect(after.spouseOfFamilies == before.spouseOfFamilies)
            #expect(after.familySearchID == before.familySearchID)
        }
        #expect(graph.familyTable.keys.sorted() == base.familyTable.keys.sorted())
        for (id, before) in base.familyTable {
            let after = graph.familyTable[id]!
            #expect(after.husband == before.husband)
            #expect(after.wife == before.wife)
            #expect(after.children == before.children)
            #expect(after.familySearchID == before.familySearchID)
        }
        #expect(graph.rootPersonIDs == base.rootPersonIDs)
        let walter = graph.person(familySearchID: "WWWW-111")!
        #expect(graph.relatives(.parents, of: walter).map(\.id).sorted() == ["@I4@", "@I5@"])
        #expect(graph.relatives(.children, of: walter).map(\.id) == ["@I3@"])
    }

    /// SCALE: an overlay over a 40,000-person tree (the real one is 39,250).
    /// Budget 3 s in a Debug `swift test` build for the date path — the one
    /// every ordinary refresh takes. Measured locally well under that; the
    /// budget is a regression alarm, not a target.
    @Test func overlayOverFortyThousandPeople() {
        var lines = ["0 HEAD"]
        let count = 40_000
        lines.reserveCapacity(count * 5)
        for n in 0..<count {
            lines += ["0 @I\(n)@ INDI", "1 NAME Given\(n) /Sur\(n % 500)/",
                      "1 BIRT", "2 DATE \(1700 + n % 300)",
                      String(format: "1 _FSFTID A%03d-%03d", n / 1000, n % 1000)]
        }
        lines.append("0 TRLR")
        let base = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        #expect(base.people.count == count)
        _ = base.index
        var o = PersonFactOverlay()
        for n in stride(from: 0, to: count, by: 800) {        // 50 refreshed people
            let fsid = String(format: "A%03d-%03d", n / 1000, n % 1000)
            o.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: "12 Mar 1801")],
                     familySearchID: fsid, displayName: "P\(n)", at: Date())
        }
        let clock = ContinuousClock()
        let start = clock.now
        let (graph, report) = base.applyingFactOverlay(o)
        let elapsed = clock.now - start
        #expect(report.peopleChanged == 50)
        #expect(!report.indexDropped)
        #expect(graph.people.count == count)
        #expect(graph.index.lifeYears[Int(graph.index.ordinal(of: "@I800@")!)] == "b. 1801")
        #expect(elapsed < .seconds(3), "overlay apply over \(count) people took \(elapsed)")
    }
}

// MARK: - Store (ISOLATION: every test owns its directory)

struct PersonFactOverlayStoreTests {
    @Test func saveLoadAndStampFollowTheFile() throws {
        let dir = F.tempDirectory("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersonFactOverlayStore(directory: dir)
        #expect(store.load() == PersonFactOverlay())
        #expect(store.stamp() == "none")
        var overlay = PersonFactOverlay()
        overlay.record([PersonRefreshChange(field: .birthDate, label: "", old: "1928", new: "1929")],
                       familySearchID: "WWWW-111", displayName: "W", at: Date(timeIntervalSince1970: 1_000))
        try store.save(overlay)
        #expect(store.load() == overlay)
        #expect(store.stamp() != "none")
        // No temp artifacts left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == [PersonFactOverlayStore.fileName])
    }

    @Test func unreadableOverlayAppliesNothingAndIsNotOverwritten() throws {
        let dir = F.tempDirectory("garbage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OverlayLogBox()
        let store = PersonFactOverlayStore(directory: dir, log: { log.append($0) })
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(store.effective(newestPullAt: Date(), canWrite: true) == PersonFactOverlay())
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ not json")
        #expect(log.lines.contains { $0.contains("unreadable") })
    }

    @Test func effectiveRetiresSupersededEntriesWithALogLine() throws {
        let dir = F.tempDirectory("retire")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OverlayLogBox()
        let store = PersonFactOverlayStore(directory: dir, log: { log.append($0) })
        var overlay = PersonFactOverlay()
        overlay.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: "1929")],
                       familySearchID: "WWWW-111", displayName: "Walter", at: Date(timeIntervalSince1970: 100))
        try store.save(overlay)

        // Read-only (viewer): not applied, not written.
        let readOnly = store.effective(newestPullAt: Date(timeIntervalSince1970: 200), canWrite: false)
        #expect(readOnly.entries.isEmpty)
        #expect(store.load().entries.count == 1)

        let effective = store.effective(newestPullAt: Date(timeIntervalSince1970: 200), canWrite: true)
        #expect(effective.entries.isEmpty)
        #expect(store.load().entries.isEmpty)
        #expect(store.load().retired.map(\.familySearchID) == ["WWWW-111"])
        #expect(log.lines.contains { $0.hasPrefix("[fs-refresh] retired overlay for Walter (WWWW-111)") })

        // An OLDER pull leaves a newer entry alone.
        var fresh = PersonFactOverlay()
        fresh.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: "1929")],
                     familySearchID: "WWWW-111", displayName: "Walter", at: Date(timeIntervalSince1970: 500))
        try store.save(fresh)
        #expect(store.effective(newestPullAt: Date(timeIntervalSince1970: 200), canWrite: true).entries.count == 1)
    }

    @Test func newestPullDateSeesOnlyWhatTheLoaderSees() throws {
        let dir = F.tempDirectory("pulldate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let top = dir.appendingPathComponent("tree.ged")
        try "0 HEAD\n0 TRLR".write(to: top, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: top.path)
        let nested = dir.appendingPathComponent("person-refresh/WWWW-111-x", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "0 HEAD\n0 TRLR".write(to: nested.appendingPathComponent("person.ged"), atomically: true, encoding: .utf8)
        let note = dir.appendingPathComponent("readme.txt")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        #expect(PersonFactOverlayStore.newestPullDate(in: dir) == Date(timeIntervalSince1970: 1_000))
    }
}

final class OverlayLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
