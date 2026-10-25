// CatalogPersonFilterTests.swift
// The Catalog's "Person ▾" picker (Rick 2026-10-24, DECISIONS "People tab vs
// Catalog"): one person, left of the search box; the table narrows to the
// records associated with them — confirmed tags and face matches, never a
// rejected one — and the Showing line says so with a person pill.
//
// Five-dimension coverage (CLAUDE.md rule 8):
//   Logic      — tagged + face-matched kept (aliases, any case), maybes,
//                rejected, other people and substrings ("Danatella") out;
//                Everyone is the identity; the filter and the People tab's
//                tier rule agree on every record (one matcher).
//   Truth      — the pill names exactly the chosen person, after the volume
//                pill and before the box; the spoken sentence carries it;
//                the empty table names them.
//   Isolation  — a chosen person whose profile disappears falls back to
//                Everyone (no crash); a profile with no name still lists;
//                a new store (= launch) is Everyone.
//   Scale      — 100k records, the person in 2k: within the Catalog's
//                filter budget (CatalogSearchBudgetSensorTests: 50 ms).
//   Sensor     — computeFiltered applies it after the search, before the
//                volume filter; the matcher is PersonVideos.associates; the
//                toolbar draws the menu left of the search and the pill after
//                the volume pill; nothing persists the choice.
//   Media matrix — N/A: catalog metadata only, no file is opened.
// Synthetic fixtures only.
//
// Suites: CatalogPersonFilterLogicTests · CatalogPersonPillTests ·
//         CatalogPersonFilterStoreTests · CatalogPersonFilterScaleTests ·
//         CatalogPersonFilterSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func rec(_ name: String, confirmed: [String] = [], detected: [String] = [],
                 suspected: [String] = [], rejected: [String] = []) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = "/Volumes/test_T/\(name)"
    r.filename = name
    r.directory = "/Volumes/test_T"
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
    r.detectedPeople = detected
    r.suspectedPeople = suspected
    r.rejectedPeople = rejected
    return r
}

private func dana(aliases: [String] = []) -> POIProfile {
    var p = POIProfile(name: "Dana", referencePath: "")
    p.aliases = aliases
    return p
}

private typealias Summary = CatalogShowingSummary

// MARK: - Logic

@Suite("Catalog Person picker — the filter")
struct CatalogPersonFilterLogicTests {

    @Test func keepsTaggedAndFaceMatchedDropsTheRest() {
        let tagged = rec("tagged.mov", confirmed: ["Dana"])
        let byFace = rec("face.mov", detected: ["dana"])
        let byAlias = rec("alias.mov", detected: ["Goldie"])
        let maybe = rec("maybe.mov", suspected: ["Dana"])
        let rejected = rec("rejected.mov", detected: ["Dana"], rejected: ["dana"])
        let other = rec("other.mov", confirmed: ["Rick"])
        let longer = rec("longer.mov", confirmed: ["Danatella"])
        let none = rec("none.mov")
        let input = [tagged, byFace, byAlias, maybe, rejected, other, longer, none]
        let out = CatalogPersonFilter.apply(input, person: CatalogPerson(dana(aliases: ["Goldie"])))
        #expect(out.map(\.filename) == ["tagged.mov", "face.mov", "alias.mov"],
                "tagged + face matches, in table order; maybe, rejected, others and substrings out")
    }

    /// A confirmed tag is Rick's word — it wins over a stale rejection.
    @Test func aConfirmedTagWinsOverAStaleRejection() {
        let both = rec("both.mov", confirmed: ["Dana"], rejected: ["Dana"])
        #expect(CatalogPersonFilter.apply([both], person: CatalogPerson(dana())).count == 1)
    }

    @Test func everyoneIsTheIdentity() {
        let input = [rec("a.mov"), rec("b.mov", confirmed: ["Dana"]), rec("c.mov", detected: ["Rick"])]
        let out = CatalogPersonFilter.apply(input, person: nil)
        #expect(out.count == input.count)
        #expect(zip(out, input).allSatisfy { $0 === $1 }, "same rows, same order")
    }

    /// One matcher: the Catalog's filter and the People tab's tier rule
    /// agree on every record (tagged or found by face; rejected never).
    @Test func agreesWithThePeopleTabTierRuleOnEveryRecord() {
        let names = ["Dana", "dana", "DANA", "Goldie", "Rick", "Danatella", ""]
        var recs: [VideoRecord] = []
        for (i, n) in names.enumerated() {
            recs.append(rec("c\(i).mov", confirmed: [n]))
            recs.append(rec("d\(i).mov", detected: [n]))
            recs.append(rec("s\(i).mov", suspected: [n]))
            recs.append(rec("r\(i).mov", detected: [n], rejected: ["Dana"]))
        }
        let person = CatalogPerson(dana(aliases: ["Goldie"]))
        let viaFilter = Set(CatalogPersonFilter.apply(recs, person: person).map(\.id))
        let viaTier = Set(recs.filter {
            guard let t = PersonVideos.tier(of: $0, keys: person.keys) else { return false }
            return t == .tagged || t == .foundByFace
        }.map(\.id))
        #expect(viaFilter == viaTier)
        #expect(viaFilter.count == 8, "Dana in 3 cases + Goldie, each confirmed and detected: \(viaFilter.count)")
        // The People tab's tier rule itself respects the rejection now.
        #expect(PersonVideos.tier(of: rec("x.mov", detected: ["Dana"], rejected: ["Dana"]), keys: person.keys) == nil)
    }
}

// MARK: - The pill, the sentence, the empty note

@Suite("Catalog Person picker — the Showing line")
struct CatalogPersonPillTests {

    private func state(volumes: [String] = [], person: String? = nil, focus: String? = nil) -> Summary.State {
        Summary.State(kindFacet: .everything, hasMasterArchive: true, focusLabel: focus,
                      selectedVolumeLabels: volumes, selectedPersonName: person)
    }

    @Test func noPersonNoPill() {
        #expect(Summary.personPill(name: nil) == nil)
        #expect(!Summary.pills(for: state()).contains { $0.emphasis == .person || $0.action == .clearPerson })
        #expect(Summary.pills(for: state()).map(\.text) == ["All kinds", "Including archived", "Connected drives"])
    }

    @Test func thePersonPillFollowsTheVolumePillThenTheBox() throws {
        let pills = Summary.pills(for: state(volumes: ["CrucialX9"], person: "Dana"))
        #expect(pills.map(\.text) == ["CrucialX9", "Dana", "All kinds", "Including archived", "Connected drives"])
        let person = try #require(pills.first { $0.emphasis == .person })
        #expect(person.text == "Dana" && person.action == .clearPerson)
        #expect(Summary.pills(for: state(person: "Dana")).map(\.text).first == "Dana", "no volume: it leads")
        #expect(Summary.boxPills(for: state(person: "Dana")).allSatisfy { $0.text != "Dana" }, "the box does not repeat it")
    }

    @Test func theSpokenSentenceCarriesIt() {
        #expect(Summary.sentence(for: state(volumes: ["CrucialX9"], person: "Dana"))
                == "Showing CrucialX9, Dana, All kinds, Including archived, Connected drives")
        #expect(Summary.personHelp(name: "Dana") == "Showing only videos of Dana — click to show everyone")
    }

    @Test func focusModeOverridesThePersonPillToo() {
        #expect(Summary.pills(for: state(person: "Dana", focus: "A/V Pair focus")).map(\.text) == ["A/V Pair focus"])
    }

    @Test func clickingThePillClearsToEveryoneAndNothingElseDoes() {
        let chosen: UUID? = UUID()
        #expect(Summary.personSelection(after: .clearPerson, chosen) == nil)
        for other: Summary.Pill.Action in [.none, .toggleArchived, .toggleDrives, .clearVolumes] {
            #expect(Summary.personSelection(after: other, chosen) == chosen, "\(other) leaves the person alone")
        }
        let vols: Set<UUID> = [UUID()]
        #expect(Summary.volumeSelection(after: .clearPerson, vols) == vols, "clearing the person leaves the volumes")
    }

    @Test func anEmptyTableNamesThePerson() {
        #expect(CatalogEmptyNote.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false,
                                      personChosen: true) == .noPerson)
        #expect(CatalogEmptyNote.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false,
                                      personChosen: false) == .none, "Everyone: today's behaviour")
        #expect(CatalogEmptyNote.pick(rowsEmpty: true, searching: true, foldersOnlyFindsNothing: false,
                                      personChosen: true) == .noMatches, "the search's own note wins")
        #expect(CatalogEmptyNote.pick(rowsEmpty: false, searching: false, foldersOnlyFindsNothing: false,
                                      personChosen: true) == .none, "rows showing: no note")
        let words = Summary.personEmptyNote(name: "Dana")
        #expect(words.hasPrefix("No videos of Dana here") && words.contains("Everyone"))
        #expect(Summary.personSearchHint(name: "Dana").contains("videos of Dana"))
        let folders = FootageFolderWords.foldersOnlyEmpty(volumeLabels: [], personName: "Dana", foldersExist: true)
        #expect(folders.hasPrefix("No folders with Dana match"))
        #expect(FootageFolderWords.foldersOnlyEmpty(volumeLabels: [], personName: nil, foldersExist: true)
                == FootageFolderWords.foldersOnlyEmpty, "no person: today's words")
    }
}

// MARK: - The store (isolation)

@MainActor
@Suite("Catalog Person picker — the store")
struct CatalogPersonFilterStoreTests {

    private func profile(_ name: String, display: String? = nil) -> POIProfile {
        var p = POIProfile(name: name, referencePath: "")
        if let display { p.aliases = [display] }   // displayName = the first alias
        return p
    }

    @Test func launchIsEveryone() {
        let store = CatalogPersonFilterStore()
        #expect(store.selected == nil && store.people.isEmpty)
    }

    @Test func listsThePeopleTabsProfilesInItsOrderByDisplayName() {
        let store = CatalogPersonFilterStore()
        store.reload([profile("Zed"), profile("Ann"), profile("Dana", display: "Dana Breen")])
        #expect(store.people.map(\.name) == ["Zed", "Ann", "Dana Breen"], "the People tab's order, not alphabetical")
    }

    @Test func choosingAPersonAndEveryone() throws {
        let store = CatalogPersonFilterStore()
        let p = profile("Dana")
        store.reload([profile("Ann"), p])
        store.select(id: p.uuid)
        #expect(store.selected?.id == p.uuid && store.selected?.name == "Dana")
        store.select(id: nil)
        #expect(store.selected == nil)
        store.select(id: UUID())
        #expect(store.selected == nil, "an unknown id is Everyone")
    }

    /// ISOLATION: the chosen person's profile is deleted (People tab) while
    /// the Catalog is away; the next reload falls back to Everyone.
    @Test func aChosenPersonWhoseProfileDisappearsFallsBackToEveryone() {
        let store = CatalogPersonFilterStore()
        let p = profile("Dana")
        store.reload([p, profile("Ann")])
        store.select(id: p.uuid)
        store.reload([profile("Ann")])
        #expect(store.selected == nil)
        #expect(store.people.map(\.name) == ["Ann"])
        store.reload([])
        #expect(store.selected == nil && store.people.isEmpty, "no people at all: no crash")
    }

    @Test func aRenamedPersonStaysChosenUnderTheNewName() {
        let store = CatalogPersonFilterStore()
        var p = profile("Dana")
        store.reload([p])
        store.select(id: p.uuid)
        p.aliases = ["Dana B."]
        store.reload([p])
        #expect(store.selected?.name == "Dana B.")
    }

    /// A person chosen from the People tab before the Catalog ever loaded
    /// its list is kept, and the first reload confirms it.
    @Test func aPersonChosenBeforeTheListLoadedIsKept() {
        let store = CatalogPersonFilterStore()
        let p = profile("Dana")
        store.select(CatalogPerson(p))
        #expect(store.selected?.id == p.uuid)
        store.reload([p])
        #expect(store.selected?.id == p.uuid)
    }

    /// ISOLATION: a profile with no usable name still gets a menu line; its
    /// filter matches nothing rather than everything.
    @Test func aNamelessProfileListsAndMatchesNothing() {
        let blank = profile("  ", display: "")
        let person = CatalogPerson(blank)
        #expect(person.name == CatalogPerson.unnamed)
        #expect(person.keys.isEmpty)
        #expect(CatalogPersonFilter.apply([rec("a.mov", confirmed: [""]), rec("b.mov")], person: person).isEmpty)
    }
}

// MARK: - Scale

@Suite("Catalog Person picker — 100k scale")
struct CatalogPersonFilterScaleTests {

    /// 100k records, the person in 2k (1k tagged, 1k by face), 500 rejected,
    /// 14k tagged with someone else. Budget: the Catalog's filter budget
    /// (CatalogSearchBudgetSensorTests, 50 ms) — held in Debug too (measured
    /// 22 ms Debug on the M4 Max, 2026-10-24).
    @Test func hundredThousandRecordsWithinTheCatalogFilterBudget() {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            if i % 100 == 0 {
                recs.append(rec("t\(i).mov", confirmed: ["Dana"]))
            } else if i % 100 == 50 {
                recs.append(rec("f\(i).mov", detected: ["Dana", "Rick"]))
            } else if i % 200 == 25 {
                recs.append(rec("r\(i).mov", detected: ["Dana"], rejected: ["Dana"]))
            } else if i % 7 == 0 {
                recs.append(rec("o\(i).mov", confirmed: ["Rick"], detected: ["Ann"]))
            } else {
                recs.append(rec("x\(i).mov"))
            }
        }
        let person = CatalogPerson(dana())
        _ = CatalogPersonFilter.apply(recs, person: person)   // warm
        let clock = ContinuousClock()
        var out: [VideoRecord] = []
        var times: [Duration] = []
        let loadBefore = TimingBudget.sampleLoad()
        for _ in 0..<5 {
            times.append(clock.measure { out = CatalogPersonFilter.apply(recs, person: person) })
        }
        let median = times.sorted()[2]
        #expect(out.count == 2_000)
        let budget = Duration.milliseconds(50)
        print("[person-picker-scale] 100k median=\(median) budget=\(budget)")
        expectWithinTimingBudget("100k Person picker filter (median of 5)", measured: median, budget: budget,
                                 loadBefore: loadBefore)
    }
}

// MARK: - Sensors

@Suite("Catalog Person picker — wiring sensors")
struct CatalogPersonFilterSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.strippingComments(SourceTree.appSource(named: name))
    }

    /// In computeFiltered: after the search (the badge counts the whole
    /// catalog's hits, the volume filter's contract) and before the volume
    /// filter (which then sees the smaller set).
    @Test func computeFilteredAppliesItAfterTheSearchBeforeTheVolumeFilter() throws {
        let src = try code("CatalogHelpers.swift")
        let body = try #require(src.range(of: "func computeFiltered() -> [VideoRecord] {"))
        let tail = String(src[body.upperBound...])
        let search = try #require(tail.range(of: "model.searchIndex.filter(records:"))
        let person = try #require(tail.range(of: "CatalogPersonFilter.apply(out, person: personFilter)"))
        let volume = try #require(tail.range(of: "pfRecordOnSelectedVolume($0, prefixes: prefixes)"))
        #expect(search.lowerBound < person.lowerBound && person.lowerBound < volume.lowerBound)
    }

    @Test func oneMatcherAndNoPersistence() throws {
        let src = try code("CatalogPersonFilter.swift")
        #expect(src.contains("PersonVideos.associates("), "the People tab's matcher")
        #expect(src.contains("PersonVideos.tagKeys(for:"), "the People tab's keys")
        for own in ["confirmedByUserPeople", "detectedPeople", "rejectedPeople", "lowercased()"] {
            #expect(!src.contains(own), "no second matcher (\(own))")
        }
        for persisted in ["AppStorage", "SceneStorage", "UserDefaults"] {
            #expect(!src.contains(persisted), "session-only: launch shows Everyone (\(persisted))")
        }
    }

    @Test func toolbarDrawsTheMenuLeftOfTheSearchAndThePillAfterTheVolumePill() throws {
        let src = try code("CatalogToolbar.swift")
        let volumePill = try #require(src.range(of: "CatalogVolumePill(labels: selectedVolumeLabels"))
        let personPill = try #require(src.range(of: "CatalogPersonPill(name: selectedPerson?.name"))
        let box = try #require(src.range(of: "CatalogShowingBox(state: showingState)"))
        let menu = try #require(src.range(of: "CatalogPersonMenu("))
        let field = try #require(src.range(of: "TextField(\"Search\", text: $searchText)"))
        #expect(volumePill.lowerBound < personPill.lowerBound && personPill.lowerBound < box.lowerBound)
        #expect(menu.lowerBound < field.lowerBound, "the menu is left of the search box")
        #expect(src.contains("selectedPersonName: selectedPerson?.name"), "the Showing state carries it")
    }

    @Test func theTokenViewIsSharedNotCopied() throws {
        let src = try code("CatalogShowingSummary.swift")
        #expect(src.contains("struct CatalogFilterToken: View"))
        #expect(src.components(separatedBy: "Color.accentColor.opacity(0.18)").count == 2, "one token style")
        #expect(src.contains("systemName: \"person.crop.circle\"") || src.contains("symbol: \"person.crop.circle\""))
    }

    @Test func theParentOwnsOneSessionStoreAndTheTableRefreshesOnIt() throws {
        let content = try code("ContentView.swift")
        #expect(content.contains("@StateObject private var catalogPersonFilter = CatalogPersonFilterStore()"))
        #expect(content.contains(".environmentObject(catalogPersonFilter)"))
        #expect(content.contains("personFilter.reload(POIProfile.listAll())"), "the People tab's list, on appear")
        #expect(content.contains("personFilter: personFilter.selected"))
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains(".onChange(of: personFilter) { refreshRows() }"))
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("personChosen: personFilter != nil"))
    }
}
