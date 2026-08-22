// CatalogShowingSummaryTests.swift
// LOGIC + ISOLATION + SCALE for the "Showing: …" row (2026-08-22):
// the plain-words vocabulary, pill order, the persisted filter set's
// round trip, and the archived-hits split behind "Show in Archive".
// Pure functions over constructed values — no UserDefaults, no model.

import Foundation
import Testing
@testable import VideoScan

@Suite("Showing row — vocabulary and pills")
struct CatalogShowingSummaryTests {

    private func texts(_ s: CatalogShowingSummary.State) -> [String] {
        CatalogShowingSummary.pills(for: s).map(\.text)
    }

    @Test func defaultWithoutMasterArchiveSaysVideosOnConnectedDrives() {
        let s = CatalogShowingSummary.State()
        #expect(texts(s) == ["Videos", "Connected drives"])
        #expect(CatalogShowingSummary.sentence(for: s) == "Showing Videos, Connected drives")
    }

    @Test func masterArchiveAddsTheArchivePillInTheSecondSlot() {
        var s = CatalogShowingSummary.State(hasMasterArchive: true)
        #expect(texts(s) == ["Videos", "Including archived", "Connected drives"])
        s.viewFilters = [.notYetArchived]
        #expect(texts(s) == ["Videos", "Not yet archived", "Connected drives"])
        s.viewFilters = [.hasMasterCopy]
        #expect(texts(s) == ["Videos", "Already archived", "Connected drives"])
    }

    @Test func archivePillIsTheOnlyGreenOneAndIsClickable() {
        let s = CatalogShowingSummary.State(viewFilters: [.notYetArchived, .ratedOnly],
                                            hasMasterArchive: true)
        let pills = CatalogShowingSummary.pills(for: s)
        let green = pills.filter { $0.emphasis == .archiveToDo }
        #expect(green.map(\.text) == ["Not yet archived"])
        #expect(green.first?.action == .toggleArchived)
        #expect(pills.first { $0.text == "Starred" }?.action == CatalogShowingSummary.Pill.Action.none)
        #expect(pills.first { $0.text == "Connected drives" }?.action == .toggleDrives)
    }

    @Test func everyFilterHasPlainWordsAndNoRawMenuLabelLeaks() {
        for f in CatalogViewFilter.allCases {
            let w = CatalogShowingSummary.words(for: f)
            #expect(!w.isEmpty)
            #expect(!w.contains("("), "parenthetical jargon leaked for \(f)")
            #expect(w == "Not yet archived" || !w.lowercased().hasPrefix("not "),
                    "negative phrasing for \(f): \(w)")
        }
        for k in CatalogKindFacet.allCases {
            #expect(!CatalogShowingSummary.words(for: k).isEmpty)
        }
    }

    @Test func kitchenSinkReadsInFixedOrder() {
        let s = CatalogShowingSummary.State(
            kindFacet: .everything,
            viewFilters: [.notYetArchived, .hasFamily, .ratedOnly],
            showPairsOnly: true, showDisconnectedMedia: true,
            showRemoved: true, showSetAside: true, showSuperseded: true,
            hasMasterArchive: true)
        #expect(texts(s) == [
            "All kinds", "Not yet archived", "Starred", "With family", "Pairs only",
            "All drives", "Plus removed files", "Plus set-aside files", "Plus replaced originals",
        ])
    }

    @Test func focusModeReplacesEveryPill() {
        let s = CatalogShowingSummary.State(viewFilters: [.notYetArchived],
                                            hasMasterArchive: true,
                                            focusLabel: "A/V Pair focus")
        #expect(texts(s) == ["A/V Pair focus"])
    }

    // MARK: Persistence round trip

    @Test func filterSetRoundTripsAndSurvivesUnknownTokens() {
        let all = Set(CatalogViewFilter.allCases)
        #expect(CatalogShowingSummary.decode(CatalogShowingSummary.encode(all)) == all)
        #expect(CatalogShowingSummary.decode("") == [])
        let raw = CatalogShowingSummary.encode([.notYetArchived]) + "|Retired Filter From 2027"
        #expect(CatalogShowingSummary.decode(raw) == [.notYetArchived])
    }

    @Test func encodingIsDeterministicRegardlessOfSetOrder() {
        let a = CatalogShowingSummary.encode([.ratedOnly, .notYetArchived, .hasFamily])
        let b = CatalogShowingSummary.encode([.hasFamily, .ratedOnly, .notYetArchived])
        #expect(a == b)
    }

    // MARK: Archived-hits split

    private func rec(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    @Test func splitKeepsOrderAndCountsBothSides() {
        let recs = (0..<10).map { rec("v\($0).mov") }
        let archivedNames: Set<String> = ["v1.mov", "v4.mov", "v9.mov"]
        let split = CatalogShowingSummary.splitArchivedHits(recs) { archivedNames.contains($0.filename) }
        #expect(split.shown.map(\.filename) == ["v0.mov", "v2.mov", "v3.mov", "v5.mov", "v6.mov", "v7.mov", "v8.mov"])
        #expect(split.archived.map(\.filename) == ["v1.mov", "v4.mov", "v9.mov"])
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 1) == "1 match is already in the Archive.")
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 3) == "3 matches are already in the Archive.")
    }

    /// Scale (checklist dimension 2): the split runs inside the
    /// catalog's search pass, so 100k records must stay well under the
    /// per-keystroke budget.
    @Test func splitOf100kStaysUnderBudget() {
        let recs = (0..<100_000).map { rec("v\($0).mov") }
        let t0 = Date()
        let split = CatalogShowingSummary.splitArchivedHits(recs) { $0.filename.hasSuffix("7.mov") }
        let elapsed = Date().timeIntervalSince(t0)
        #expect(split.archived.count == 10_000)
        #expect(split.shown.count == 90_000)
        #expect(elapsed < 0.5, "split took \(elapsed)s for 100k records")
    }
}
