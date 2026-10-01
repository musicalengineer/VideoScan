// FamilyTreeBirthFlagTests.swift
// GH #229: the tiny birth-country flag on a Family Tree person card.
// Dimensions:
//   Logic     — every country in scope from the tree (county, country-only,
//               colonial New England → 🇺🇸); off-map and unrecorded → no
//               flag; the family's notes flag someone the tree could not,
//               at the family privacy ceiling, and the tooltip says so; the
//               tree wins when both resolve; the card and the map agree
//               person for person (same `FamilyMapModel.place`); photo →
//               badge, no photo → placeholder; the log line's shape.
//   Scale     — 100k synthetic people build the dictionary under a
//               thread-CPU budget (the map's 100k pattern, GH #208).
//   Isolation — the model is built with an injected originals directory
//               (no real brain, bookmarks or defaults); the brain, when
//               one is used, is a temp file; the builder and the views
//               read no defaults, bundle, App Support or network (source
//               sensor).
//   Sensor    — the live model builds the dictionary ONCE per bind and a
//               card lookup never builds or resolves; no view file names
//               the resolver or the builder; the app log gets its line.
//   Media     — n/a.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

/// Eleven people: one per country in scope (England by county, Scotland,
/// Wales, Northern Ireland, Ireland country-only, colonial Massachusetts,
/// Nova Scotia), one off the map (Berlin), one unrecorded, one whose place
/// only the family's notes know (Mary, Cork), and one off-map trap (Perth,
/// WA — must never fly 🇺🇸).
private let flagsGedcom = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
0 @I1@ INDI
1 NAME John /Yorke/
1 SEX M
1 BIRT
2 DATE 1650
2 PLAC Sheffield, Yorkshire, England
0 @I2@ INDI
1 NAME Agnes /Fife/
1 SEX F
1 BIRT
2 PLAC Fife, Scotland
0 @I3@ INDI
1 NAME Owen /Morgan/
1 SEX M
1 BIRT
2 PLAC Cardiff, Glamorgan, Wales
0 @I4@ INDI
1 NAME Sarah /Antrim/
1 SEX F
1 BIRT
2 PLAC Belfast, County Antrim, Northern Ireland
0 @I5@ INDI
1 NAME Patrick /Ronan/
1 SEX M
1 BIRT
2 PLAC Ireland
0 @I6@ INDI
1 NAME William /Alden/
1 SEX M
1 BIRT
2 DATE 1650
2 PLAC Boston, Suffolk, Massachusetts Bay Colony, British Colonial America
0 @I7@ INDI
1 NAME Anne /Halifax/
1 SEX F
1 BIRT
2 PLAC Halifax, Nova Scotia, Canada
0 @I8@ INDI
1 NAME Karl /Berlin/
1 SEX M
1 BIRT
2 PLAC Berlin, Germany
0 @I9@ INDI
1 NAME Nobody /Knows/
1 SEX U
0 @I10@ INDI
1 NAME Mary Christina /O'Connor/
1 SEX F
1 BIRT
2 DATE 23 DEC 1904
0 @I11@ INDI
1 NAME Bruce /Swan/
1 SEX M
1 BIRT
2 PLAC Perth, WA, Australia
0 TRLR
"""

private func flagsGraph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: flagsGedcom) }

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A brain whose Mary (@I10@) has a Cork birth event, plus optional extra
/// items so the tree-wins / disputed / private cases can be built.
private func brainArchive(maryPrivacy: CyberBrainItem.Privacy = .family,
                          maryConfidence: CyberBrainItem.Confidence = .confirmed,
                          extraPeople: [CyberBrainPerson] = []) -> CyberBrainArchive {
    // A disputed item must name what it disputes (CyberBrainValidator):
    // a counter-claim with NO place, so the disputed case has nothing
    // else to fall back on.
    let counterClaim = CyberBrainItem(id: "event.mary.birth.elsewhere", kind: .event,
                                      text: "Mary Christina O'Connor was born, some say, somewhere else entirely.", subjectPersonIDs: ["person.mary"],
                                      place: nil, sourceIDs: ["source.bc"], confidence: .uncertain, privacy: .family,
                                      status: .active, disputesItemIDs: [], createdAt: now, updatedAt: now, correction: nil)
    let birth = CyberBrainItem(id: "event.mary.birth", kind: .event,
                               text: "Mary Christina O'Connor was born 1 January 1900 at 1 Example Lane, Cork.", subjectPersonIDs: ["person.mary"],
                               place: "Cork, Ireland", sourceIDs: ["source.bc"], confidence: maryConfidence,
                               privacy: maryPrivacy, status: .active,
                               disputesItemIDs: maryConfidence == .disputed ? [counterClaim.id] : [],
                               createdAt: now, updatedAt: now, correction: nil)
    return CyberBrainArchive(archiveID: "test.flags", displayName: "Test", people: [
        CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I10@", canonicalName: "Mary Christina O'Connor",
                         lifeEvents: maryConfidence == .disputed ? [birth, counterClaim] : [birth]),
    ] + extraPeople, sources: [CyberBrainSource(id: "source.bc", type: .officialRecord, title: "Birth certificate, Cork 1904")])
}

private func knowledge(_ archive: CyberBrainArchive, graph: GedcomFamilyGraph) throws -> FamilyTreeNotesResolver {
    FamilyTreeNotesResolver(index: try CyberBrainIndex(archive: archive), graph: graph)
}

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FamilyTreeBirthFlags-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Write an archive where FamilyTreeNotesStorage.loadIndex will read it.
private func writeBrain(_ archive: CyberBrainArchive, to root: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(archive).write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
}

/// The expected flag per tree person from the TREE alone.
private let expectedFromTree: [String: FamilyMap.Country?] = [
    "@I1@": .england, "@I2@": .scotland, "@I3@": .wales, "@I4@": .northernIreland, "@I5@": .ireland,
    "@I6@": .unitedStates, "@I7@": .canada, "@I8@": nil, "@I9@": nil, "@I10@": nil, "@I11@": nil,
]

// MARK: - Tests

@Suite("Family Tree birth-country flags (#229)")
@MainActor
struct FamilyTreeBirthFlagTests {

    // MARK: Logic — from the tree

    @Test func everyCountryCountryOnlyAndOffMapFromTheTree() {
        let built = FamilyTreeBirthCountries.build(graph: flagsGraph(), knowledge: nil)
        #expect(built.peopleCount == 11)
        #expect(built.flaggedCount == 7 && built.treeCount == 7 && built.notesCount == 0)
        for (id, country) in expectedFromTree {
            #expect(built[id]?.country == country, "\(id)")
            #expect(built[id]?.fromFamilyNotes == (country == nil ? nil : false), "\(id)")
        }
        // Country-only still flies the flag; colonial New England flies today's.
        #expect(built["@I5@"]?.emoji == "🇮🇪")
        #expect(built["@I6@"]?.emoji == "🇺🇸")
        // Northern Ireland: the UK flag, but the label says where.
        #expect(built["@I4@"]?.emoji == "🇬🇧")
        #expect(built["@I4@"]?.accessibilityLabel == "Northern Ireland")
        // Historical honesty in the tooltip, from the tree.
        #expect(built["@I6@"]?.tooltip
                == "Born in Boston, Suffolk, Massachusetts Bay Colony, British Colonial America · shown under today's flag")
        #expect(built["@I1@"]?.tooltip == "Born in Sheffield, Yorkshire, England · shown under today's flag")
        #expect(built["@I4@"]?.recordedPlace == "Belfast, County Antrim, Northern Ireland")
        // The Perth, WA trap and Berlin: recorded, off the map, no flag.
        #expect(built["@I11@"] == nil && built["@I8@"] == nil)
    }

    // MARK: Logic — from the family's notes

    @Test func theFamilysNotesFlagSomeoneTheTreeCouldNot() throws {
        let graph = flagsGraph()
        let built = FamilyTreeBirthCountries.build(graph: graph, knowledge: try knowledge(brainArchive(), graph: graph))
        let mary = try #require(built["@I10@"])
        #expect(mary.country == .ireland && mary.emoji == "🇮🇪")
        #expect(mary.fromFamilyNotes)
        #expect(mary.recordedPlace == "Cork, Ireland")
        #expect(mary.tooltip == "Born in Cork, Ireland (from the family's notes) · shown under today's flag")
        #expect(built.flaggedCount == 8 && built.treeCount == 7 && built.notesCount == 1)
        // Everyone else is exactly as from the tree.
        for (id, country) in expectedFromTree where id != "@I10@" {
            #expect(built[id]?.country == country, "\(id)")
        }
        #expect(built.summaryLine == "flags: 8 of 11 people have a birth country (tree 7, notes 1)")
    }

    @Test func aPrivateOrDisputedNoteNeverFlagsAnyone() throws {
        let graph = flagsGraph()
        let privateBrain = FamilyTreeBirthCountries.build(
            graph: graph, knowledge: try knowledge(brainArchive(maryPrivacy: .private), graph: graph))
        #expect(privateBrain["@I10@"] == nil, "a .private birth event is above the family ceiling")
        let disputed = FamilyTreeBirthCountries.build(
            graph: graph, knowledge: try knowledge(brainArchive(maryConfidence: .disputed), graph: graph))
        #expect(disputed["@I10@"] == nil, "a disputed birthplace must not quietly flag someone")
        #expect(privateBrain.notesCount == 0 && disputed.notesCount == 0)
    }

    @Test func theTreeWinsWhenBothResolveAndTheNoteOnlyFillsAGap() throws {
        let graph = flagsGraph()
        // John (@I1@, Yorkshire in the tree) has a note claiming Cork; Karl
        // (@I8@, Berlin in the tree — off the map) has a note saying Cork.
        let johnNote = CyberBrainItem(id: "event.john.birth", kind: .event, text: "John Yorke was born in Cork, they say.",
                                      subjectPersonIDs: ["person.john"], place: "Cork, Ireland", sourceIDs: ["source.bc"],
                                      confidence: .probable, privacy: .family, status: .active, disputesItemIDs: [],
                                      createdAt: now, updatedAt: now, correction: nil)
        let karlNote = CyberBrainItem(id: "event.karl.birth", kind: .event, text: "Karl Berlin was born in Cork; the birth was registered there.",
                                      subjectPersonIDs: ["person.karl"], place: "Cork, Ireland", sourceIDs: ["source.bc"],
                                      confidence: .probable, privacy: .family, status: .active, disputesItemIDs: [],
                                      createdAt: now, updatedAt: now, correction: nil)
        let archive = brainArchive(extraPeople: [
            CyberBrainPerson(id: "person.john", gedcomPersonID: "@I1@", canonicalName: "John Yorke", lifeEvents: [johnNote]),
            CyberBrainPerson(id: "person.karl", gedcomPersonID: "@I8@", canonicalName: "Karl Berlin", lifeEvents: [karlNote]),
        ])
        let built = FamilyTreeBirthCountries.build(graph: graph, knowledge: try knowledge(archive, graph: graph))
        let john = try #require(built["@I1@"])
        #expect(john.country == .england && !john.fromFamilyNotes, "the tree's Yorkshire wins over the note")
        let karl = try #require(built["@I8@"])
        #expect(karl.country == .ireland && karl.fromFamilyNotes, "an off-map tree text yields to a resolving note — as the map does")
        #expect(built.notesCount == 2 && built.treeCount == 7)
    }

    // MARK: Logic — the card and the map agree, person for person

    /// The flags go through `FamilyMapModel.place`, the map's own decision.
    /// Build the map's inputs for the same people and check every person's
    /// unit key country and family-notes source match the flag's.
    @Test func theCardAndTheMapAgreePersonForPerson() throws {
        let graph = flagsGraph()
        let know = try knowledge(brainArchive(), graph: graph)
        let flags = FamilyTreeBirthCountries.build(graph: graph, knowledge: know)

        let ids = graph.people.keys.sorted()
        let n = ids.count
        let people = ids.compactMap { graph.people[$0] }
        #expect(people.count == n)
        let surnames = people.map { $0.surname ?? "" }
        let inputs = FamilyMapModel.inputs(
            ids: ids, names: people.map(\.name), surnames: surnames,
            surnameKeys: TreeWalkHighlight.surnameKeys(surnames),
            birthPlaces: people.map(\.birthPlace),
            familyPlaces: ids.map { FamilyMapModel.familyBirthPlace(gedcomID: $0, in: know) },
            birthYears: [Int?](repeating: nil, count: n), generations: [Int?](repeating: nil, count: n),
            lines: [TreeWalk.Line](repeating: .none, count: n), visited: Array(0..<n),
            regions: [BirthplaceClassifier.BirthRegion](repeating: .unknown, count: n))

        for (o, id) in ids.enumerated() {
            let mapCountry = FamilyMapFlag.country(forUnitKey: inputs.people.unitKeys[o])
            #expect(flags[id]?.country == mapCountry, "\(id): card \(String(describing: flags[id]?.country)) vs map \(String(describing: mapCountry))")
            #expect((flags[id]?.fromFamilyNotes ?? false) == inputs.familyPlacedIDs.contains(id), "\(id)")
            if let flag = flags[id] {
                #expect(flag.recordedPlace == inputs.people.recordedPlaces[o], "\(id)")
            }
        }
        #expect(flags.flaggedCount == inputs.people.unitKeys.compactMap { $0 }.count)
    }

    // MARK: Logic — the view-model decision

    @Test func theTooltipSaysWhereAndUnderWhichFlag() {
        #expect(FamilyTreeBirthFlag.tooltip(recordedPlace: "Cork, Ireland", fromFamilyNotes: false)
                == "Born in Cork, Ireland · shown under today's flag")
        #expect(FamilyTreeBirthFlag.tooltip(recordedPlace: "Cork, Ireland", fromFamilyNotes: true)
                == "Born in Cork, Ireland (from the family's notes) · shown under today's flag")
        #expect(FamilyTreeBirthCountries.empty.summaryLine == "flags: 0 of 0 people have a birth country (tree 0, notes 0)")
    }

    // MARK: Sensor — the live model builds once per bind; a card only looks up

    @Test func theLiveModelBuildsOncePerBindAndCardsOnlyLookUp() async throws {
        // Isolation: an injected originals directory means no real brain,
        // no real bookmarks, no UserDefaults (see FamilyTreeLiveModel.init).
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        #expect(model.birthCountryBuilds == 0 && model.birthCountries == .empty)
        model.install(graph: flagsGraph())
        let task = try #require(model.birthCountriesTask, "install schedules the build")
        await task.value
        #expect(model.birthCountryBuilds == 1)
        #expect(model.birthCountriesTask == nil)
        #expect(model.birthCountries.flaggedCount == 7)
        #expect(model.birthFlag(for: "@I1@")?.country == .england)
        #expect(model.birthFlag(for: "@I9@") == nil)

        // 10,000 card lookups: no build, no resolve — a dictionary hit each.
        let ids = Array(expectedFromTree.keys)
        var hits = 0
        for i in 0..<10_000 where model.birthFlag(for: ids[i % ids.count]) != nil { hits += 1 }
        #expect(hits > 0)
        #expect(model.birthCountryBuilds == 1, "cards never rebuild the dictionary")
        #expect(model.birthCountriesTask == nil)
    }

    @Test func theLiveModelPicksUpTheFamilysNotesThroughTheSamePath() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBrain(brainArchive(), to: root)
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
                                        cyberBrainRootURL: root, noteAuthor: "Rick")
        model.install(graph: flagsGraph())
        model.loadCyberBrainNow()          // supersedes the tree-only build before it can land
        let task = try #require(model.birthCountriesTask)
        await task.value
        #expect(model.birthCountryBuilds == 1, "the superseded tree-only build is dropped, not applied")
        let mary = try #require(model.birthFlag(for: "@I10@"))
        #expect(mary.country == .ireland && mary.fromFamilyNotes)
        #expect(model.birthCountries.notesCount == 1 && model.birthCountries.flaggedCount == 8)
    }

    /// QA #229 P3-1: GEDCOM ids are local to a file — a different tree's
    /// @I1@ is a different person. Until the new tree's build lands the
    /// cards must show no flag, never the previous tree's.
    @Test func aNewTreeNeverShowsTheOldTreesFlags() async throws {
        // Two different tree FILES (the live model tells trees apart by
        // directory + file name + modification time; a re-pulled file gets
        // a new time and may renumber its ids).
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        var first = flagsGraph()
        first.sourceDirectory = "/nonexistent/trees"
        first.sourceFileName = "first.ged"
        model.install(graph: first)
        if let task = model.birthCountriesTask { await task.value }
        #expect(model.birthFlag(for: "@I1@")?.country == .england)
        var second = GedcomFamilyGraph(gedcomText:
            "0 HEAD\n1 _VS_MERGED Y\n1 _VS_ROOT @I1@\n0 @I1@ INDI\n1 NAME Hans /Other/\n1 SEX M\n1 BIRT\n2 PLAC Berlin, Germany\n0 TRLR")
        second.sourceDirectory = "/nonexistent/trees"
        second.sourceFileName = "second.ged"
        model.install(graph: second)
        #expect(model.birthFlag(for: "@I1@") == nil, "the old tree's England flag on the new tree's @I1@")
        if let task = model.birthCountriesTask { await task.value }
        #expect(model.birthFlag(for: "@I1@") == nil, "Berlin is off the map")
    }

    /// Public repo: no real street address in these fixtures (policy of
    /// the #227 codex follow-up merge a29d5403; QA #229 P1).
    @Test func noRealStreetAddressInTheseTests() throws {
        // Any "<number> <Name> Lane/Street/Road/…" other than the neutral
        // "1 Example Lane" is treated as a real address.
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let street = try Regex(#"\b\d+[A-Za-z]?\s+(?!Example\b)(?:\p{Lu}[\p{L}'’-]+\s+){1,3}(?:Lane|Street|St\.|Road|Rd\.|Place|Terrace|Row|Square|Avenue)\b"#)
        #expect(source.firstMatch(of: street) == nil, "public repo: no real street address in test fixtures")
    }

    /// Rick 2026-09-30: the flag lives in the card's header row, never on
    /// the photo (a badge there covered faces). Source sensor: the badge is
    /// drawn exactly once in the cards file, and not by the portrait.
    @Test func theFlagSitsInTheHeaderNotOnThePhoto() throws {
        let cards = try SourceTree.appSource(named: "FamilyTreeCards.swift")
        let uses = cards.components(separatedBy: "FamilyTreeBirthFlagBadge(").count - 1
        #expect(uses == 1, "one header badge per card, found \(uses)")
        #expect(!cards.contains("image != nil, let flag"), "the portrait no longer draws a badge on the photo")
    }

    @Test func noTreeMeansNoFlags() async throws {
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: flagsGraph())
        if let task = model.birthCountriesTask { await task.value }
        #expect(model.birthCountries.flaggedCount == 7)
        model.install(graph: nil)
        #expect(model.birthCountries == .empty, "the demo tree flies no flags")
        #expect(model.birthCountriesTask == nil)
    }

    // MARK: Scale — 100k people, thread CPU time (GH #208 pattern)

    /// Every place resolved once through `FamilyMapModel.place`; the
    /// dictionary packed. Budget ≈ 3× the quiet Debug measurement, CPU
    /// time of the calling thread so a busy host does not fail it.
    @Test func building100kPeopleStaysUnderBudget() throws {
        let n = 100_000
        let places: [String?] = ["Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
                                 "England", "Fife, Scotland", "Cardiff, Glamorgan, Wales", nil, "Berlin, Germany",
                                 "Halifax, Nova Scotia, Canada", "Cork, Ireland", "Providence, Rhode Island", "Lowell Mass. U.S.A.",
                                 "Perth, WA, Australia", "United States", "Co. Antrim, Northern Ireland", "Toronto, Ontario, Canada"]
        // Built with plain loops: Xcode 26.3 (CI) cannot type-check the
        // one-line map/ternary closures in reasonable time (same trap as
        // FamilyMapRenderSensorTests, 6d7d4f3f).
        let count = places.count
        var ids: [String] = []
        var treePlaces: [String?] = []
        var familyPlaces: [String?] = []
        ids.reserveCapacity(n)
        treePlaces.reserveCapacity(n)
        familyPlaces.reserveCapacity(n)
        for i in 0..<n {
            ids.append("@I" + String(i) + "@")
            treePlaces.append(places[i % count])
            // Every 5th unrecorded person has a family note (Cork).
            let unrecordedSlot: Bool = i % count == 5
            let everyFifth: Bool = (i / count) % 5 == 0
            let note: String? = (unrecordedSlot && everyFifth) ? "Cork, Ireland" : nil
            familyPlaces.append(note)
        }

        var built: FamilyTreeBirthCountries?
        var wall: Duration = .zero
        let cpu = PerformanceLane.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                built = FamilyTreeBirthCountries.build(ids: ids, treePlaces: treePlaces, familyPlaces: familyPlaces)
            }
        }
        print("[tree-flags] 100k build: cpu \(cpu), wall \(wall) (\(PerformanceLane.loadDescription()))")
        #expect(cpu < PerformanceLane.loadAwareDebugCeiling(.milliseconds(600)),
                "100k flags took \(cpu) cpu / \(wall) wall (\(PerformanceLane.loadDescription()))")

        // Correctness at scale: 12 of 15 spellings resolve (nil, Germany,
        // Australia do not); the notes add the Cork people.
        let resolving: Set<Int> = [0, 1, 2, 3, 4, 7, 8, 9, 10, 12, 13, 14]
        var fromTree = 0
        for i in 0..<n where resolving.contains(i % count) { fromTree += 1 }
        var fromNotes = 0
        for note in familyPlaces where note != nil { fromNotes += 1 }
        let b = try #require(built)
        #expect(b.peopleCount == n)
        #expect(b.treeCount == fromTree && b.notesCount == fromNotes, "\(b.treeCount) tree, \(b.notesCount) notes")
        #expect(b.flaggedCount == fromTree + fromNotes)
        #expect(b["@I11@"] == nil, "Perth, WA never flies 🇺🇸")
        #expect(b["@I5@"]?.fromFamilyNotes == true && b["@I5@"]?.country == .ireland)
    }

    // MARK: Isolation + sensors on the source

    /// No view resolves or builds; the view layer does one lookup; the
    /// builder goes through the map's decision (never the resolver
    /// directly); nothing here reads defaults, the bundle, App Support or
    /// the network; the log line exists.
    @Test func viewsOnlyLookUpAndTheBuilderSharesTheMapsDecision() throws {
        for name in ["FamilyTreeCards.swift", "FamilyTreeView.swift", "FamilyTreeBirthFlagViews.swift"] {
            let src = try SourceTree.appSource(named: name)
            #expect(!src.contains("BirthplaceUnitResolver"), "\(name) must not resolve a place")
            #expect(!src.contains("FamilyTreeBirthCountries.build"), "\(name) must not build the dictionary")
            #expect(!src.contains("FamilyMapModel.place("), "\(name) must not decide a place")
        }
        let view = try SourceTree.appSource(named: "FamilyTreeView.swift")
        #expect(view.contains("birthFlag: model.birthFlag(for: card.person.id)"), "the card gets its flag by one lookup")
        let cards = try SourceTree.appSource(named: "FamilyTreeCards.swift")
        #expect(!cards.contains("FamilyTreeBirthFlagPlaceholder"), "KISS: the flag is never the portrait")
        #expect(cards.contains("FamilyTreeBirthFlagBadge(flag: birthFlag)"), "every flagged card → the header flag")

        let builder = try SourceTree.appSource(named: "FamilyTreeBirthCountries.swift")
        #expect(!builder.contains("BirthplaceUnitResolver.resolve("), "the builder never resolves on its own")
        #expect(builder.contains("FamilyMapModel.place("), "the builder uses the map's decision")
        #expect(builder.contains("FamilyMapModel.familyBirthPlace("), "and the map's family-notes fallback")
        for name in ["FamilyTreeBirthCountries.swift", "FamilyTreeBirthFlagViews.swift"] {
            let src = try SourceTree.appSource(named: name)
            for forbidden in ["UserDefaults", "URLSession", "Bundle.main", "applicationSupportDirectory",
                              "NSHomeDirectory", "CyberBrainWriter", "FamilyTreeNotesStorage"] {
                #expect(!src.contains(forbidden), "\(name) must not use \(forbidden)")
            }
        }
        // The map still has exactly one resolver call site, now the shared `place`.
        let map = try SourceTree.appSource(named: "FamilyMapModel.swift")
        #expect(map.components(separatedBy: "BirthplaceUnitResolver.resolve(").count == 2)

        // The model: built off-main, once per bind, and logged.
        let model = try SourceTree.appSource(named: "FamilyTreeLiveModel.swift")
        #expect(model.contains("appLog.write(\"Family Tree: \\(built.summaryLine)\")"), "one log line per build")
        #expect(model.components(separatedBy: "FamilyTreeBirthCountries.build(").count == 2, "one build call site")
        #expect(model.contains("func birthFlag(for personID: String) -> FamilyTreeBirthFlag? {\n        birthCountries.flags[personID]"),
                "a lookup is a dictionary hit")
    }
}
