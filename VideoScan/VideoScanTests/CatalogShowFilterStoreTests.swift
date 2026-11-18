// CatalogShowFilterStoreTests.swift
// The ONE owner of the Catalog ▸ Show filter set (CatalogShowFilterStore.swift,
// 2026-11-17).
//
//   LOGIC      the five ticks; turn on / off / clear; Audio Only and Videos
//              Missing Sound exclude each other; the persisted value
//              round-trips under stable keys; the old label-keyed value
//              migrates once, dropping the removed filters and anything
//              unknown; a stable-key value holding a removed filter drops it
//              and says so; the media-kind section's setting migrates once
//              from each of its three values; the seed runs once.
//   LOGGING    every writer's change is exactly one line naming the change,
//              the writer and the resulting set; launch logs what it restored;
//              a call that changes nothing writes nothing.
//   ISOLATION  a poisoned stored value (a number, data, garbage text) — the
//              filter set's or the old media-kind setting's — restores as no
//              filters, never crashes, and is rewritten clean.
//   SCALE      N/A — five enums; no records are read.
//   MEDIA      N/A — no media is opened.
// The sensor (nothing else writes the keys) is ShowFiltersAuditSensorTests;
// the truth test (the box names exactly the set) is in CatalogShowingSummaryTests.

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Show filter store — one owner, every change logged")
struct CatalogShowFilterStoreTests {

    /// A private defaults domain per test, removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "show-filter-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// Collects the lines a store writes (a class so the closure can append).
    private final class Lines {
        var all: [String] = []
    }

    private func store(_ defaults: UserDefaults, _ lines: Lines) -> CatalogShowFilterStore {
        CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
    }

    // MARK: LOGIC

    @Test("LOGIC: the menu's final shape (2026-11-17) — five ticks, in this order, stable keys, the menu's words")
    func theFiveTicks() {
        #expect(CatalogViewFilter.allCases.map(\.title) == [
            "Audio Only", "Videos Missing Sound", "Not Yet Archived", "Needs a Date", "Hide Other Versions",
        ])
        #expect(CatalogViewFilter.allCases.map(\.rawValue) == [
            "audioOnly", "videosMissingSound", "notYetArchived", "needsDate", "onePerFootage",
        ])
        for f in CatalogViewFilter.allCases {
            #expect(!f.icon.isEmpty && !f.help.isEmpty)
            #expect(f.rawValue != f.title, "\(f): the stored key must not be the display label")
        }
        #expect(Set(CatalogViewFilter.allCases.map(\.icon)).count == 5, "each tick has its own glyph")
        // The pure per-record filters carry a predicate; the model-backed one and the group pass do not.
        let modelBacked: Set<CatalogViewFilter> = [.notYetArchived, .onePerFootage]
        for f in CatalogViewFilter.allCases {
            #expect((f.recordPredicate == nil) == modelBacked.contains(f), "\(f)")
        }
        // No removed filter's key is a live one, and none of the removed words is a live title.
        for (key, words) in CatalogShowFilterStore.removedStableKeys {
            #expect(CatalogViewFilter(rawValue: key) == nil, "\(key)")
            #expect(!CatalogViewFilter.allCases.map(\.title).contains(words), "\(words)")
        }
    }

    @Test("LOGIC: on, off and Clear All — the set follows, and survives a relaunch")
    func setClearAndPersistenceRoundTrip() {
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            #expect(s.active.isEmpty)
            s.set(.needsDate, on: true, by: .showMenu)
            s.set(.videosMissingSound, on: true, by: .showMenu)
            s.set(.notYetArchived, on: true, by: .showMenu)
            #expect(s.active == [.needsDate, .videosMissingSound, .notYetArchived])
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "videosMissingSound,notYetArchived,needsDate",
                    "stable keys, in menu order")
            // Relaunch: a second store over the same defaults.
            #expect(store(defaults, Lines()).active == [.needsDate, .videosMissingSound, .notYetArchived])
            s.set(.videosMissingSound, on: false, by: .showMenu)
            #expect(store(defaults, Lines()).active == [.needsDate, .notYetArchived])
            s.clearAll(by: .emptyTable)
            #expect(s.active.isEmpty)
            #expect(store(defaults, Lines()).active.isEmpty)
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "")
        }
    }

    @Test("LOGIC: every subset round-trips through the stored value")
    func everySubsetRoundTrips() {
        let all = CatalogViewFilter.allCases
        for mask in 0..<(1 << all.count) {
            let set = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            withDefaults { defaults in
                defaults.set(CatalogShowFilterStore.encode(set), forKey: CatalogShowFilterStore.key)
                #expect(store(defaults, Lines()).active == CatalogShowFilterStore.legal(set), "\(set)")
            }
        }
    }

    @Test("LOGIC: Audio Only and Videos Missing Sound cannot both be on — turning one on turns the other off")
    func theSoundPairIsMutuallyExclusive() {
        #expect(CatalogViewFilter.audioOnly.excludes == .videosMissingSound)
        #expect(CatalogViewFilter.videosMissingSound.excludes == .audioOnly)
        for f in [CatalogViewFilter.notYetArchived, .needsDate, .onePerFootage] { #expect(f.excludes == nil, "\(f)") }
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            s.set(.audioOnly, on: true, by: .showMenu)
            s.set(.needsDate, on: true, by: .showMenu)
            lines.all.removeAll()
            s.set(.videosMissingSound, on: true, by: .showMenu)
            #expect(s.active == [.videosMissingSound, .needsDate])
            #expect(lines.all == ["Catalog Show filters: on: Videos Missing Sound; off: Audio Only (by Show menu) "
                                    + "→ now Videos Missing Sound, Needs a Date"],
                    "one change, one line, both halves named")
            s.set(.audioOnly, on: true, by: .showMenu)
            #expect(s.active == [.audioOnly, .needsDate])
            // Turning the one that is on OFF leaves the other off: no filter is switched on behind the user's back.
            s.set(.audioOnly, on: false, by: .showMenu)
            #expect(s.active == [.needsDate])
            // No sequence of writes reaches the pair.
            for f in CatalogViewFilter.allCases { s.set(f, on: true, by: .showMenu) }
            #expect(!(s.active.contains(.audioOnly) && s.active.contains(.videosMissingSound)))
            #expect(s.active.count == 4)
            // A stored value that holds both (hand-edited) is made legal at launch, and says so.
            defaults.set("audioOnly,videosMissingSound", forKey: CatalogShowFilterStore.key)
            let relaunch = Lines()
            #expect(store(defaults, relaunch).active == [.audioOnly])
            #expect(relaunch.all.first?.contains("dropped Videos Missing Sound") == true)
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "audioOnly")
        }
    }

    @Test("LOGIC: the old label-keyed value migrates once — kept filters carried, removed and unknown dropped and named")
    func migrationOfTheOldStoredValue() {
        withDefaults { defaults in
            let old = ["Video+Audio Only", "Unpaired Only", "Rated Only", "Has Family", "In Workspace",
                       "Untagged (junk candidate)", "Not Yet Archived", "Archive Candidates", "No Place Yet",
                       "One Per Footage", "Confirmed Date", "Has Master Copy", "Repaired — Awaiting Confirmation",
                       "A Filter From Another Build"].joined(separator: "|")
            defaults.set(old, forKey: CatalogShowFilterStore.legacyKey)
            let lines = Lines()
            let s = store(defaults, lines)
            #expect(s.active == [.notYetArchived, .onePerFootage])
            #expect(!s.active.contains(.needsDate), "Confirmed Date is the OPPOSITE of Needs a Date — never carried over")
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "notYetArchived,onePerFootage")
            #expect(defaults.object(forKey: CatalogShowFilterStore.legacyKey) == nil, "the old key is gone after the migration")
            let line = lines.all.first ?? ""
            #expect(lines.all.count == 1)
            #expect(line.hasPrefix("Catalog Show filters: restored at launch → Not Yet Archived, Hide Other Versions"))
            #expect(line.contains("migrated from the old setting"))
            for gone in CatalogShowFilterStore.removedLegacyLabels { #expect(line.contains(gone), "\(gone) not named") }
            #expect(line.contains("not known to this build: A Filter From Another Build"))
            // Once: the next launch reads the stable key and has nothing to say about a migration.
            let again = Lines()
            #expect(store(defaults, again).active == [.notYetArchived, .onePerFootage])
            #expect(again.all == ["Catalog Show filters: restored at launch → Not Yet Archived, Hide Other Versions"])
        }
    }

    @Test("LOGIC: a stored set holding a filter removed on 2026-11-17 drops it, names it, and is rewritten — each one, and all three",
          arguments: [["unpairedOnly"], ["hasMasterCopy"], ["awaitingConfirmation"],
                      ["unpairedOnly", "awaitingConfirmation", "hasMasterCopy"]])
    func removedStableTokensAreDroppedAndNamed(removed: [String]) {
        withDefaults { defaults in
            defaults.set((["needsDate"] + removed + ["notYetArchived"]).joined(separator: ","), forKey: CatalogShowFilterStore.key)
            let lines = Lines()
            #expect(store(defaults, lines).active == [.needsDate, .notYetArchived], "the filters that remain are kept")
            #expect(lines.all.count == 1)
            let line = lines.all.first ?? ""
            #expect(line.hasPrefix("Catalog Show filters: restored at launch → Not Yet Archived, Needs a Date (dropped, no longer in the menu: "))
            for key in removed {
                #expect(line.contains(CatalogShowFilterStore.removedStableKeys[key] ?? "?"), "\(key) is not named in: \(line)")
            }
            #expect(!line.contains("not known to this build"), "a removed filter is named as removed, not as unknown")
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "notYetArchived,needsDate", "rewritten without them")
            // Once: the next launch has nothing to drop.
            let again = Lines()
            #expect(store(defaults, again).active == [.needsDate, .notYetArchived])
            #expect(again.all == ["Catalog Show filters: restored at launch → Not Yet Archived, Needs a Date"])
        }
        // Only removed filters stored: nothing is on, and the store still works.
        withDefaults { defaults in
            defaults.set(removed.joined(separator: ","), forKey: CatalogShowFilterStore.key)
            let s = store(defaults, Lines())
            #expect(s.active.isEmpty)
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "")
            s.set(.audioOnly, on: true, by: .showMenu)
            #expect(store(defaults, Lines()).active == [.audioOnly])
        }
    }

    // MARK: The media-kind section's setting (removed 2026-11-17)

    @Test("LOGIC: the media-kind setting migrates once — Audio Only becomes the tick, Videos and All Kinds become no tick; logged",
          arguments: [("audioOnly", true, "Audio Only and is now the Audio Only filter"),
                      ("videoBearing", false, "Videos and is now no filter"),
                      ("everything", false, "All Kinds and is now no filter")])
    func migrationOfTheKindFacet(stored: String, audioOnly: Bool, words: String) {
        let facetKey = CatalogShowFilterStore.legacyKindFacetKey
        #expect(facetKey == "catalogKindFacet", "the key the removed section wrote")
        withDefaults { defaults in
            defaults.set(stored, forKey: facetKey)
            defaults.set("needsDate", forKey: CatalogShowFilterStore.key)
            let lines = Lines()
            let s = store(defaults, lines)
            let expected: Set<CatalogViewFilter> = audioOnly ? [.audioOnly, .needsDate] : [.needsDate]
            #expect(s.active == expected)
            #expect(defaults.object(forKey: facetKey) == nil, "the old key is deleted")
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == CatalogShowFilterStore.encode(expected))
            #expect(lines.all.count == 2, "the launch line, then the migration's one line: \(lines.all)")
            let line = lines.all.last ?? ""
            #expect(line.hasPrefix("Catalog Show filters: the Show menu's media-kind section was removed; its setting was " + words))
            #expect(line.hasSuffix("→ now " + CatalogShowFilterStore.names(expected)))
            // Once.
            let again = Lines()
            #expect(store(defaults, again).active == expected)
            #expect(again.all.count == 1)
        }
        // With no filter set stored at all (the common case).
        withDefaults { defaults in
            defaults.set(stored, forKey: facetKey)
            let s = store(defaults, Lines())
            #expect(s.active == (audioOnly ? [.audioOnly] : []))
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == (audioOnly ? "audioOnly" : ""))
            #expect(defaults.object(forKey: facetKey) == nil)
        }
    }

    @Test("LOGIC: a migrated Audio Only turns off a stored Videos Missing Sound; no stored media-kind setting says nothing")
    func kindFacetMigrationKeepsTheSetLegal() {
        withDefaults { defaults in
            defaults.set("audioOnly", forKey: CatalogShowFilterStore.legacyKindFacetKey)
            defaults.set("videosMissingSound,notYetArchived", forKey: CatalogShowFilterStore.key)
            let lines = Lines()
            #expect(store(defaults, lines).active == [.audioOnly, .notYetArchived])
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "audioOnly,notYetArchived")
            #expect(lines.all.last?.hasSuffix("→ now Audio Only, Not Yet Archived") == true)
        }
        withDefaults { defaults in
            let before: Set<CatalogViewFilter> = [.needsDate]
            let out = CatalogShowFilterStore.migrateKindFacet(in: defaults, into: before)
            #expect(out.filters == before && out.line == nil, "a fresh install has nothing to migrate")
            let lines = Lines()
            _ = store(defaults, lines)
            #expect(lines.all == ["Catalog Show filters: restored at launch → none"])
            #expect(defaults.object(forKey: CatalogShowFilterStore.key) == nil, "nothing changed — nothing written")
        }
    }

    @Test("ISOLATION: a poisoned media-kind setting is dropped, said once, and never turns a filter on")
    func poisonedKindFacet() {
        let long = String(repeating: "k", count: 5_000)
        let poisons: [Any] = [7, 3.5, true, Data([0xFF, 0x00]), ["audioOnly"], ["a": 1], Date(),
                              "", "AUDIOONLY", " audioOnly ", "audioOnly,everything", "definitely-not-a-facet", long]
        for poison in poisons {
            withDefaults { defaults in
                defaults.set(poison, forKey: CatalogShowFilterStore.legacyKindFacetKey)
                defaults.set("notYetArchived", forKey: CatalogShowFilterStore.key)
                let lines = Lines()
                let s = store(defaults, lines)
                #expect(s.active == [.notYetArchived], "\(type(of: poison)): \(String(describing: poison).prefix(30))")
                #expect(defaults.object(forKey: CatalogShowFilterStore.legacyKindFacetKey) == nil)
                #expect(lines.all.count == 2 && lines.all[1].contains("was dropped"), "\(lines.all)")
                #expect(lines.all[1].count < 400, "a long stored value is clipped in the log line")
                // Still a working store; the next launch is quiet.
                s.set(.audioOnly, on: true, by: .showMenu)
                let again = Lines()
                #expect(store(defaults, again).active == [.audioOnly, .notYetArchived])
                #expect(again.all.count == 1)
            }
        }
    }

    @Test("LOGIC: the stable key wins over a leftover old key; an unknown stable token is dropped and named")
    func stableKeyWinsAndUnknownTokensAreNamed() {
        withDefaults { defaults in
            defaults.set("Not Yet Archived", forKey: CatalogShowFilterStore.legacyKey)
            defaults.set("needsDate,fromTheFuture", forKey: CatalogShowFilterStore.key)
            let lines = Lines()
            #expect(store(defaults, lines).active == [.needsDate])
            #expect(lines.all == ["Catalog Show filters: restored at launch → Needs a Date "
                                    + "(dropped, not known to this build: fromTheFuture)"])
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "needsDate", "rewritten without the unknown token")
        }
    }

    @Test("LOGIC: the first-run default is applied once and logged; after that the user's choice wins")
    func theSeedRunsOnce() {
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            lines.all.removeAll()
            s.seedDefaultIfUntouched(hasMasterArchive: false)
            #expect(s.active.isEmpty && lines.all.isEmpty, "no Master Archive — nothing to default to")
            s.seedDefaultIfUntouched(hasMasterArchive: true)
            #expect(s.active == [.notYetArchived])
            #expect(lines.all == ["Catalog Show filters: on: Not Yet Archived (by first-run default) → now Not Yet Archived"])
            s.set(.notYetArchived, on: false, by: .showMenu)
            s.seedDefaultIfUntouched(hasMasterArchive: true)
            #expect(s.active.isEmpty, "the user's choice wins after the one seed")
        }
        // The seed adds to what is on; it never clears another filter.
        withDefaults { defaults in
            let s = store(defaults, Lines())
            s.set(.audioOnly, on: true, by: .showMenu)
            s.seedDefaultIfUntouched(hasMasterArchive: true)
            #expect(s.active == [.audioOnly, .notYetArchived])
        }
    }

    // MARK: LOGGING

    @Test("LOGGING: every writer's change is one line that names the change, the writer and the result",
          arguments: CatalogShowFilterStore.Writer.allCases)
    func everyWriterLogs(writer: CatalogShowFilterStore.Writer) {
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            #expect(lines.all == ["Catalog Show filters: restored at launch → none"])
            lines.all.removeAll()
            s.set(.onePerFootage, on: true, by: writer)
            #expect(lines.all == ["Catalog Show filters: on: Hide Other Versions (by \(writer.rawValue)) → now Hide Other Versions"])
            s.set(.onePerFootage, on: true, by: writer)
            #expect(lines.all.count == 1, "no change — no line")
            s.set(.needsDate, on: false, by: writer)
            #expect(lines.all.count == 1, "turning off what is off — no line")
            s.clearAll(by: writer)
            #expect(lines.all.last == "Catalog Show filters: off: Hide Other Versions (by \(writer.rawValue)) → now none")
            s.clearAll(by: writer)
            #expect(lines.all.count == 2)
        }
    }

    @Test("LOGGING: the writers the brief names all exist, each with its own words")
    func theWritersAreDistinct() {
        let words = CatalogShowFilterStore.Writer.allCases.map(\.rawValue)
        #expect(Set(words).count == words.count)
        // "a folder reveal" (2026-11-17): New Folder / Show in Catalog turning Show ▸ Folders on.
        #expect(words == ["Show menu", "Analyze menu", "Steward", "empty-table note", "first-run default", "a folder reveal"])
    }

    // MARK: The retired hidden-records reveals

    @Test("LOGIC: a stored Removed / Set aside reveal is forced off at launch, said once, and stays off")
    func retiredRevealsAreForcedOff() {
        withDefaults { defaults in
            defaults.set(true, forKey: "catalogShowRemoved")
            defaults.set(true, forKey: "catalogShowSetAside")
            let lines = Lines()
            _ = store(defaults, lines)
            #expect(defaults.object(forKey: "catalogShowRemoved") == nil)
            #expect(defaults.object(forKey: "catalogShowSetAside") == nil)
            #expect(!defaults.bool(forKey: "catalogShowRemoved") && !defaults.bool(forKey: "catalogShowSetAside"))
            #expect(lines.all.count == 2)
            #expect(lines.all.last?.contains("catalogShowRemoved, catalogShowSetAside was on and is now off") == true)
            // The next launch has nothing to retire and says nothing.
            let again = Lines()
            _ = store(defaults, again)
            #expect(again.all.count == 1)
        }
        // Stored false, a poisoned value, or nothing: removed quietly.
        for value: Any? in [false, "banana", Data([1, 2]), nil] {
            withDefaults { defaults in
                if let value { defaults.set(value, forKey: "catalogShowSetAside") }
                #expect(CatalogShowFilterStore.retireHiddenRecordReveals(in: defaults) == nil)
                #expect(defaults.object(forKey: "catalogShowSetAside") == nil)
            }
        }
        #expect(CatalogShowFilterStore.retiredRevealKeys == ["catalogShowRemoved", "catalogShowSetAside"])
    }

    // MARK: ISOLATION

    @Test("ISOLATION: a poisoned stored value restores as no filters, says so, and is rewritten clean")
    func poisonedStoredValues() {
        let poisons: [Any] = [7, 3.5, true, Data([0xFF, 0x00, 0xFE]), ["notYetArchived"], ["a": 1], Date()]
        for poison in poisons {
            for key in [CatalogShowFilterStore.key, CatalogShowFilterStore.legacyKey] {
                withDefaults { defaults in
                    defaults.set(poison, forKey: key)
                    let lines = Lines()
                    let s = store(defaults, lines)
                    #expect(s.active.isEmpty, "\(type(of: poison)) under \(key)")
                    #expect(lines.all.count == 1 && lines.all[0].contains("unreadable"), "\(lines.all)")
                    #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "")
                    #expect(defaults.object(forKey: CatalogShowFilterStore.legacyKey) == nil)
                    // Still a working store.
                    s.set(.needsDate, on: true, by: .showMenu)
                    #expect(store(defaults, Lines()).active == [.needsDate])
                }
            }
        }
    }

    @Test("ISOLATION: garbage text never crashes and keeps what it can read")
    func garbageText() {
        let long = String(repeating: "x", count: 5_000)
        for garbage in ["", ",,,", "|||", " needsDate ,, notYetArchived ", "NEEDSDATE", "needsDate|notYetArchived",
                        "\u{0}\u{1F4A9},needsDate", long] {
            withDefaults { defaults in
                defaults.set(garbage, forKey: CatalogShowFilterStore.key)
                let lines = Lines()
                let s = store(defaults, lines)
                #expect(s.active.isSubset(of: [.needsDate, .notYetArchived]), "\(garbage.prefix(40))")
                #expect(lines.all.count == 1)
                #expect(lines.all[0].count < 400, "an unknown token is clipped in the log line")
            }
        }
        withDefaults { defaults in
            defaults.set(" needsDate ,, notYetArchived ", forKey: CatalogShowFilterStore.key)
            #expect(store(defaults, Lines()).active == [.needsDate, .notYetArchived])
        }
    }
}
