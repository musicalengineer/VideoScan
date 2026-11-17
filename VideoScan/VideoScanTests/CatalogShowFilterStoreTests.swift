// CatalogShowFilterStoreTests.swift
// The ONE owner of the Catalog ▸ Show filter set (CatalogShowFilterStore.swift,
// 2026-11-17).
//
//   LOGIC      turn on / off / clear; Not Yet Archived and Has Master Copy
//              exclude each other; the persisted value round-trips under
//              stable keys; the old label-keyed value migrates once, dropping
//              the removed filters and anything unknown; the seed runs once.
//   LOGGING    every writer's change is exactly one line naming the change,
//              the writer and the resulting set; launch logs what it restored;
//              a call that changes nothing writes nothing.
//   ISOLATION  a poisoned stored value (a number, data, garbage text) restores
//              as no filters, never crashes, and is rewritten clean.
//   SCALE      N/A — six enums; no records are read.
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

    @Test("LOGIC: the menu after the 2026-11-17 trim — six filters, stable keys, the menu's words")
    func theTrimmedFilterList() {
        #expect(CatalogViewFilter.allCases.map(\.title) == [
            "Unpaired Only", "Repaired — Awaiting Confirmation", "Not Yet Archived", "Has Master Copy",
            "Hide Other Versions", "Needs a Date",
        ])
        #expect(CatalogViewFilter.allCases.map(\.rawValue) == [
            "unpairedOnly", "awaitingConfirmation", "notYetArchived", "hasMasterCopy", "onePerFootage", "needsDate",
        ])
        for f in CatalogViewFilter.allCases {
            #expect(!f.icon.isEmpty)
            #expect(f.rawValue != f.title, "\(f): the stored key must not be the display label")
        }
        // The pure per-record filters carry a predicate; the model-backed pair and the group pass do not.
        let modelBacked: Set<CatalogViewFilter> = [.notYetArchived, .hasMasterCopy, .onePerFootage]
        for f in CatalogViewFilter.allCases {
            #expect((f.recordPredicate == nil) == modelBacked.contains(f), "\(f)")
        }
    }

    @Test("LOGIC: on, off and Clear All — the set follows, and survives a relaunch")
    func setClearAndPersistenceRoundTrip() {
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            #expect(s.active.isEmpty)
            s.set(.needsDate, on: true, by: .showMenu)
            s.set(.unpairedOnly, on: true, by: .showMenu)
            s.set(.notYetArchived, on: true, by: .showMenu)
            #expect(s.active == [.needsDate, .unpairedOnly, .notYetArchived])
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "unpairedOnly,notYetArchived,needsDate",
                    "stable keys, in menu order")
            // Relaunch: a second store over the same defaults.
            #expect(store(defaults, Lines()).active == [.needsDate, .unpairedOnly, .notYetArchived])
            s.set(.unpairedOnly, on: false, by: .showMenu)
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

    @Test("LOGIC: Not Yet Archived and Has Master Copy cannot both be on — turning one on turns the other off")
    func theArchivePairIsMutuallyExclusive() {
        withDefaults { defaults in
            let lines = Lines()
            let s = store(defaults, lines)
            s.set(.notYetArchived, on: true, by: .showMenu)
            s.set(.needsDate, on: true, by: .showMenu)
            lines.all.removeAll()
            s.set(.hasMasterCopy, on: true, by: .showMenu)
            #expect(s.active == [.hasMasterCopy, .needsDate])
            #expect(lines.all == ["Catalog Show filters: on: Has Master Copy; off: Not Yet Archived (by Show menu) "
                                    + "→ now Has Master Copy, Needs a Date"],
                    "one change, one line, both halves named")
            s.set(.notYetArchived, on: true, by: .showMenu)
            #expect(s.active == [.notYetArchived, .needsDate])
            // No sequence of writes reaches the pair.
            for f in CatalogViewFilter.allCases { s.set(f, on: true, by: .showMenu) }
            #expect(!(s.active.contains(.notYetArchived) && s.active.contains(.hasMasterCopy)))
            // A stored value that holds both (an old build's, hand-edited) is made legal at launch, and says so.
            defaults.set("notYetArchived,hasMasterCopy", forKey: CatalogShowFilterStore.key)
            let relaunch = Lines()
            #expect(store(defaults, relaunch).active == [.notYetArchived])
            #expect(relaunch.all.first?.contains("dropped Has Master Copy") == true)
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "notYetArchived")
        }
    }

    @Test("LOGIC: the old label-keyed value migrates once — kept filters carried, removed and unknown dropped and named")
    func migrationOfTheOldStoredValue() {
        withDefaults { defaults in
            let old = ["Video+Audio Only", "Unpaired Only", "Rated Only", "Has Family", "In Workspace",
                       "Untagged (junk candidate)", "Not Yet Archived", "Archive Candidates", "No Place Yet",
                       "One Per Footage", "Confirmed Date", "A Filter From Another Build"].joined(separator: "|")
            defaults.set(old, forKey: CatalogShowFilterStore.legacyKey)
            let lines = Lines()
            let s = store(defaults, lines)
            #expect(s.active == [.unpairedOnly, .notYetArchived, .onePerFootage])
            #expect(!s.active.contains(.needsDate), "Confirmed Date is the OPPOSITE of Needs a Date — never carried over")
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "unpairedOnly,notYetArchived,onePerFootage")
            #expect(defaults.object(forKey: CatalogShowFilterStore.legacyKey) == nil, "the old key is gone after the migration")
            let line = lines.all.first ?? ""
            #expect(lines.all.count == 1)
            #expect(line.hasPrefix("Catalog Show filters: restored at launch → Unpaired Only, Not Yet Archived, Hide Other Versions"))
            #expect(line.contains("migrated from the old setting"))
            for gone in CatalogShowFilterStore.removedLegacyLabels { #expect(line.contains(gone), "\(gone) not named") }
            #expect(line.contains("not known to this build: A Filter From Another Build"))
            // Once: the next launch reads the stable key and has nothing to say about a migration.
            let again = Lines()
            #expect(store(defaults, again).active == [.unpairedOnly, .notYetArchived, .onePerFootage])
            #expect(again.all == ["Catalog Show filters: restored at launch → Unpaired Only, Not Yet Archived, Hide Other Versions"])
        }
    }

    @Test("LOGIC: the stable key wins over a leftover old key; an unknown stable token is dropped and named")
    func stableKeyWinsAndUnknownTokensAreNamed() {
        withDefaults { defaults in
            defaults.set("Has Master Copy", forKey: CatalogShowFilterStore.legacyKey)
            defaults.set("needsDate,fromTheFuture", forKey: CatalogShowFilterStore.key)
            let lines = Lines()
            #expect(store(defaults, lines).active == [.needsDate])
            #expect(lines.all == ["Catalog Show filters: restored at launch → Needs a Date "
                                    + "(dropped, not known to this build: fromTheFuture)"])
            #expect(defaults.string(forKey: CatalogShowFilterStore.key) == "needsDate", "rewritten without the unknown token")
        }
    }

    @Test("LOGIC: the first-run default is applied once, logged, and never fights Has Master Copy")
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
        withDefaults { defaults in
            let s = store(defaults, Lines())
            s.set(.hasMasterCopy, on: true, by: .showMenu)
            s.seedDefaultIfUntouched(hasMasterArchive: true)
            #expect(s.active == [.hasMasterCopy])
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
        #expect(words == ["Show menu", "Analyze menu", "Steward", "empty-table note", "first-run default"])
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
