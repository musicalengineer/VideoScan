// CatalogRowsTests.swift
// `CatalogRows.rows(records, state)` — which records the Catalog's files table
// lists (CatalogRows.swift, 2026-11-17) — and the Needs a Date filter.
//
//   LOGIC      every remaining Show filter's membership on real record shapes;
//              the held row (selected + listed stays, marked, until the
//              selection moves; only the Show filters are forgiven); focus
//              ignores every filter; the search badge and the archived-hits
//              split.
//   TRUTH      Needs a Date lists exactly the rows the Archive tab's "Needs a
//              Date" lists and Promote would file under Undated/ — one rule.
//   SCALE      100k records through the whole function, plain and with every
//              filter on and a held row, inside the Catalog's filter budget.
//   ISOLATION  a held id that is not in the catalog, was trashed, or is out of
//              scope is never listed; duplicate rows and an empty catalog.
//   SENSOR     computeFiltered is the function's only caller and holds no
//              filter branch of its own.
//   MEDIA      N/A — no media is opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog rows — membership is one pure function")
struct CatalogRowsTests {

    private func rec(_ name: String, stream: StreamType = .videoAndAudio, userDate: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = stream.rawValue
        r.userDate = userDate
        r.userDateConfidence = userDate == nil ? nil : "known"
        return r
    }

    private func names(_ result: CatalogRows.Result) -> [String] { result.rows.map(\.filename) }

    private func membership(_ group: UUID, rank: Int, original: UUID) -> FootageMembership {
        FootageMembership(groupID: group, groupSize: 2, confidence: .likely, role: rank == 0 ? .original : .copy,
                          rank: rank, likelyOriginalID: original, originalInCatalog: true,
                          evidence: ["same name + length"], scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          algorithmVersion: 1)
    }

    /// No reachability probes, every kind — the filter under test is the only narrowing.
    private func open(_ filters: Set<CatalogViewFilter> = []) -> CatalogRows.State {
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        s.kindFacet = .everything
        s.filters = filters
        return s
    }

    // MARK: LOGIC — each remaining filter

    @Test("LOGIC: no filter — every active record, in catalog order")
    func noFilterListsEverything() {
        let all = [rec("a.mov"), rec("b.mov"), rec("c.mov")]
        #expect(names(CatalogRows.rows(all, open())) == ["a.mov", "b.mov", "c.mov"])
        #expect(CatalogRows.rows([], open(Set(CatalogViewFilter.allCases))).rows.isEmpty)
    }

    @Test("LOGIC: Unpaired Only — video-only and audio-only files with no partner")
    func unpairedOnly() {
        let both = rec("both.mov")
        let video = rec("video.mov", stream: .videoOnly)
        let audio = rec("audio.wav", stream: .audioOnly)
        let pairedVideo = rec("pv.mov", stream: .videoOnly)
        let pairedAudio = rec("pa.wav", stream: .audioOnly)
        pairedVideo.pairedWith = pairedAudio
        pairedAudio.pairedWith = pairedVideo
        let out = CatalogRows.rows([both, video, audio, pairedVideo, pairedAudio], open([.unpairedOnly]))
        #expect(names(out) == ["video.mov", "audio.wav"])
    }

    @Test("LOGIC: Repaired — Awaiting Confirmation — repair copies Rick has not confirmed")
    func awaitingConfirmation() {
        let plain = rec("plain.mov")
        let waiting = rec("tape_RepairedAudio.mov")
        waiting.derivedFrom = plain.id
        waiting.derivationKind = "rebuildAudio"
        let confirmed = rec("done_RepairedAudio.mov")
        confirmed.derivedFrom = plain.id
        confirmed.derivationKind = "rebuildAudio"
        confirmed.repairConfirmedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let trimmed = rec("trim.mov")
        trimmed.derivedFrom = plain.id
        trimmed.derivationKind = "trim"
        #expect(names(CatalogRows.rows([plain, waiting, confirmed, trimmed], open([.awaitingConfirmation])))
                    == ["tape_RepairedAudio.mov"])
    }

    @Test("LOGIC: Not Yet Archived and Has Master Copy ask the archive index, one record at a time")
    func theArchivePair() {
        let all = [rec("todo.mov"), rec("archived.mov"), rec("sampled.mov")]
        var s = open([.notYetArchived])
        s.engines.notYetArchived = { $0.filename == "todo.mov" }
        s.engines.hasMasterCopy = { $0.filename == "archived.mov" }
        #expect(names(CatalogRows.rows(all, s)) == ["todo.mov"])
        s.filters = [.hasMasterCopy]
        #expect(names(CatalogRows.rows(all, s)) == ["archived.mov"],
                "a file hidden only by a sampled match is neither to-do nor proven archived")
        s.filters = [.notYetArchived, .hasMasterCopy]
        #expect(CatalogRows.rows(all, s).rows.isEmpty, "the pair the store refuses: always empty")
    }

    private func digest(_ r: VideoRecord, _ hex: Character) {
        r.sizeBytes = 4_096
        r.contentFixity = ContentFixity(digest: String(repeating: hex, count: 64), byteCount: 4_096,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: 4_096, mtimeNs: 0),
                                        computedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("LOGIC: Hide Other Versions also lists ONE of a set of byte-identical files the footage run has not grouped")
    func hideOtherVersionsCollapsesIdenticalBytes() {
        // Two identical files scanned after the last footage run: no membership on either.
        let first = rec("first.mov"), second = rec("second.mov"), other = rec("other.mov"), bare = rec("no-digest.mov")
        digest(first, "a"); digest(second, "a"); digest(other, "b")
        #expect(VideoScanModel.storedFullDigest(first) == VideoScanModel.storedFullDigest(second))
        #expect(first.footage == nil && second.footage == nil, "the precondition: nothing groups them")
        #expect(names(CatalogRows.rows([first, second, other, bare], open([.onePerFootage])))
                    == ["first.mov", "other.mov", "no-digest.mov"], "ties keep the first in table order")
        #expect(names(CatalogRows.rows([first, second, other, bare], open())).count == 4, "filter off: every row")
        // The rank rule: a ranked member beats an unranked identical file, wherever it sits.
        let group = UUID()
        second.footage = membership(group, rank: 0, original: second.id)
        #expect(names(CatalogRows.rows([first, second, other], open([.onePerFootage]))) == ["second.mov", "other.mov"])
        // Identical bytes in two DIFFERENT groups: the lower rank is listed.
        first.footage = membership(UUID(), rank: 1, original: first.id)
        #expect(names(CatalogRows.rows([first, second, other], open([.onePerFootage]))) == ["second.mov", "other.mov"])
        // A digest whose byte count no longer equals the file's size proves nothing: both rows stay.
        let stale = rec("stale.mov"), fresh = rec("fresh.mov")
        digest(stale, "c"); digest(fresh, "c")
        stale.sizeBytes = 9_999
        #expect(names(CatalogRows.rows([stale, fresh], open([.onePerFootage]))) == ["stale.mov", "fresh.mov"])
        // Only live rows compete: a trashed identical file never takes the slot.
        let trashed = rec("trashed.mov"), live = rec("live.mov")
        digest(trashed, "d"); digest(live, "d")
        trashed.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(names(CatalogRows.rows([trashed, live], open([.onePerFootage]))) == ["live.mov"])
        #expect(CatalogOneOfIdentical.filter([]).isEmpty)
    }

    @Test("LOGIC: Hide Other Versions — the best-ranked listed member of each group, plus every ungrouped file")
    func onePerFootage() {
        let group = UUID()
        let original = rec("original.mov")
        original.footage = membership(group, rank: 0, original: original.id)
        let copy = rec("copy.mov")
        copy.footage = membership(group, rank: 1, original: original.id)
        let loose = rec("loose.mov")
        #expect(names(CatalogRows.rows([copy, original, loose], open([.onePerFootage]))) == ["original.mov", "loose.mov"])
        // LAST: it picks among the rows the other filters left.
        original.userDate = "1992"
        original.userDateConfidence = "known"
        #expect(names(CatalogRows.rows([copy, original, loose], open([.onePerFootage, .needsDate]))) == ["copy.mov", "loose.mov"])
    }

    @Test("LOGIC: filters are additive, and the base gates still apply under them")
    func filtersComposeWithTheBaseGates() {
        let keep = rec("keep.mov", stream: .videoOnly)
        let dated = rec("dated.mov", stream: .videoOnly, userDate: "1992-06-14")
        let trashed = rec("trashed.mov", stream: .videoOnly)
        trashed.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let audio = rec("song.mp3", stream: .audioOnly)
        var s = open([.unpairedOnly, .needsDate])
        #expect(names(CatalogRows.rows([keep, dated, trashed, audio], s)) == ["keep.mov", "song.mp3"])
        s.kindFacet = .videoBearing
        #expect(names(CatalogRows.rows([keep, dated, trashed, audio], s)) == ["keep.mov"])
        s.showRemoved = true
        #expect(names(CatalogRows.rows([keep, dated, trashed, audio], s)) == ["keep.mov", "trashed.mov"])
        s.volumePrefixes = ["/Volumes/Elsewhere"]
        #expect(CatalogRows.rows([keep, dated, trashed, audio], s).rows.isEmpty)
    }

    @Test("LOGIC: a focus set is the rows — every filter, the search and the scope are ignored")
    func focusIgnoresEveryFilter() {
        let dated = rec("dated.mov", userDate: "1992")
        let trashed = rec("trashed.mov")
        trashed.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let other = rec("other.mov")
        var s = open(Set(CatalogViewFilter.allCases))
        s.searchText = "nothing matches this"
        s.focusIDs = [dated.id, trashed.id]
        let out = CatalogRows.rows([dated, trashed, other], s)
        #expect(names(out) == ["dated.mov", "trashed.mov"])
        #expect(out.searchHitCount == 0 && out.noLongerMatching.isEmpty)
    }

    @Test("LOGIC: the search badge counts hits before the Show filters; Not Yet Archived remembers what it hid")
    func searchBadgeAndArchivedHits() {
        let all = [rec("beach 1.mov"), rec("beach 2.mov"), rec("beach 3.mov"), rec("lake.mov")]
        var s = open([.notYetArchived])
        s.searchText = "beach"
        s.engines.notYetArchived = { $0.filename != "beach 2.mov" && $0.filename != "beach 3.mov" }
        s.engines.possiblyArchivedSampled = { $0.filename == "beach 3.mov" }
        let out = CatalogRows.rows(all, s)
        #expect(names(out) == ["beach 1.mov"])
        #expect(out.searchHitCount == 3)
        #expect(out.archivedSearchHitIDs == [all[1].id, all[2].id])
        #expect(out.archivedSearchSampledHitCount == 1)
        // Connected drives only: the badge counts what can be seen.
        s.showDisconnectedMedia = false
        s.engines.isReachable = { !$0.hasSuffix("beach 1.mov") }
        #expect(CatalogRows.rows(all, s).searchHitCount == 2)
    }

    @Test("LOGIC: Show Pairs Only lists each video then its audio partner")
    func pairsOnly() {
        let v = rec("v.mov", stream: .videoOnly)
        let a = rec("a.wav", stream: .audioOnly)
        v.pairedWith = a
        a.pairedWith = v
        var s = open()
        s.showPairsOnly = true
        #expect(names(CatalogRows.rows([a, rec("solo.mov"), v], s)) == ["v.mov", "a.wav"])
    }

    // MARK: LOGIC — the held row

    @Test("LOGIC: an edit that stops a SELECTED, listed row matching leaves it listed and marked — until the selection moves")
    func theHeldRowStaysUntilTheSelectionMoves() {
        let a = rec("a.mov"), b = rec("b.mov"), c = rec("c.mov")
        let all = [a, b, c]
        var s = open([.needsDate])
        #expect(names(CatalogRows.rows(all, s)) == ["a.mov", "b.mov", "c.mov"])
        // Rick dates b in the inspector while it is selected.
        b.userDate = "1992-06-14"
        b.userDateConfidence = "known"
        s.held = [b.id]
        let held = CatalogRows.rows(all, s)
        #expect(names(held) == ["a.mov", "b.mov", "c.mov"], "the row keeps its place")
        #expect(held.noLongerMatching == [b.id], "and is marked")
        // The selection moves to c: nothing is held any more — b leaves now, not later.
        s.held = [c.id]
        let after = CatalogRows.rows(all, s)
        #expect(names(after) == ["a.mov", "c.mov"])
        #expect(after.noLongerMatching.isEmpty, "c still matches: nothing to mark")
    }

    @Test("LOGIC: an unselected row that stops matching leaves at that refresh")
    func anUnselectedRowLeavesAtOnce() {
        let a = rec("a.mov"), b = rec("b.mov")
        var s = open([.needsDate])
        s.held = [a.id]
        b.userDate = "1992"
        b.userDateConfidence = "known"
        let out = CatalogRows.rows([a, b], s)
        #expect(names(out) == ["a.mov"])
        #expect(out.noLongerMatching.isEmpty)
    }

    @Test("LOGIC: only the Show filters are forgiven — a held row that was trashed or is out of scope leaves")
    func heldNeverOutlivesTheBaseGates() {
        let a = rec("a.mov"), b = rec("b.mov", userDate: "1992")
        var s = open([.needsDate])
        s.held = [b.id]
        #expect(names(CatalogRows.rows([a, b], s)) == ["a.mov", "b.mov"])
        // ⌘⌫ on the held row: it must go, selected or not.
        b.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let trashed = CatalogRows.rows([a, b], s)
        #expect(names(trashed) == ["a.mov"])
        #expect(trashed.noLongerMatching.isEmpty)
        b.purgedAt = nil
        s.searchText = "a.mov"
        #expect(names(CatalogRows.rows([a, b], s)) == ["a.mov"], "outside the search")
        s.searchText = ""
        s.volumePrefixes = ["/Volumes/Other"]
        #expect(CatalogRows.rows([a, b], s).rows.isEmpty, "outside the selected volumes")
        s.volumePrefixes = []
        s.showDisconnectedMedia = false
        s.engines.isReachable = { !$0.hasSuffix("b.mov") }
        #expect(names(CatalogRows.rows([a, b], s)) == ["a.mov"], "its drive is not connected")
    }

    @Test("LOGIC: a held row promoted under Not Yet Archived stays, and is not counted as a hidden search hit")
    func heldUnderTheArchiveFilterAndSearch() {
        let a = rec("beach a.mov"), b = rec("beach b.mov")
        var s = open([.notYetArchived])
        s.searchText = "beach"
        s.engines.notYetArchived = { $0.filename != "beach b.mov" }
        s.held = [b.id]
        let out = CatalogRows.rows([a, b], s)
        #expect(names(out) == ["beach a.mov", "beach b.mov"])
        #expect(out.noLongerMatching == [b.id])
        #expect(out.archivedSearchHitIDs.isEmpty, "the row is on screen — the banner must not call it hidden")
    }

    @Test("LOGIC: with Show Pairs Only the held row is still listed (after the pairs)")
    func heldWithPairsOnly() {
        let v = rec("v.mov", stream: .videoOnly), a = rec("a.wav", stream: .audioOnly)
        v.pairedWith = a
        a.pairedWith = v
        var s = open([.unpairedOnly])
        s.showPairsOnly = true
        s.held = [v.id]
        let out = CatalogRows.rows([a, v], s)
        #expect(Set(names(out)) == ["v.mov"], "paired rows never match Unpaired Only; the selected one is held")
        #expect(out.noLongerMatching == [v.id])
    }

    // MARK: ISOLATION

    @Test("ISOLATION: held ids that are unknown, and a catalog with the same row twice, never add or duplicate a row")
    func poisonedHeldSet() {
        let a = rec("a.mov"), b = rec("b.mov", userDate: "1992")
        var s = open([.needsDate])
        s.held = [UUID(), UUID()]
        #expect(names(CatalogRows.rows([a, b], s)) == ["a.mov"])
        s.held = [b.id, UUID()]
        let twice = CatalogRows.rows([a, b, b], s)
        #expect(names(twice) == ["a.mov", "b.mov"], "a row listed twice in the catalog is held once")
        #expect(twice.noLongerMatching == [b.id])
        s.held = [a.id]
        #expect(CatalogRows.rows([a, b], s).noLongerMatching.isEmpty, "a held row that still matches is not marked")
    }

    // MARK: TRUTH — Needs a Date

    @Test("TRUTH: Needs a Date is the Archive tab's rule — the rows Promote would file under Undated/")
    func needsDateIsThePromoteRule() {
        let rick = rec("rick.mov", userDate: "1992-06-14")
        let rickYear = rec("rick-year.mov", userDate: "1992")
        let nothing = rec("IMG_0001.mov")
        let embedded = rec("camera.mov")
        embedded.embeddedCreationDate = Date(timeIntervalSince1970: 708_000_000)   // 1992
        let named = rec("1994-07-04 parade.mov")
        let garbage = rec("garbage.mov", userDate: "banana")
        let all = [rick, rickYear, nothing, embedded, named, garbage]
        let listed = CatalogRows.rows(all, open([.needsDate])).rows
        // ONE rule: the same function the Archive tab's "Needs a Date" list and Promote's placement read.
        #expect(listed.map(\.id) == all.filter(ArchiveCategorySnapshot.needsDate).map(\.id))
        for r in all { #expect(pfRecordNeedsDate(r) == ArchiveCategorySnapshot.needsDate(r), "\(r.filename)") }
        // And what that rule says, on shapes whose answer is not in doubt.
        #expect(!pfRecordNeedsDate(rick), "Rick's own date")
        #expect(!pfRecordNeedsDate(rickYear), "Rick's year is a filing date")
        #expect(pfRecordNeedsDate(nothing), "no date anywhere")
        #expect(pfRecordNeedsDate(garbage), "a malformed user date is not a date")
        // Every listed row resolves to no decade folder; no unlisted row does.
        for r in all {
            let precision = RecordDateResolver.resolve(
                userDate: r.userDate, userDateConfidence: r.userDateConfidence,
                embeddedCreationDate: r.embeddedCreationDate, originMake: r.originMake, originModel: r.originModel,
                originEncoder: r.originEncoder, inferredRecordDate: r.inferredRecordDate,
                inferredDateConfidence: r.inferredDateConfidence, inferredDateRange: r.inferredDateRange,
                filename: r.filename).precision
            #expect((precision >= .decade) == listed.contains { $0 === r }, "\(r.filename): \(precision)")
        }
    }

    @Test("TRUTH: dating a row takes it out of Needs a Date; clearing the date puts it back")
    func needsDateFollowsTheEdit() {
        let r = rec("IMG_0002.mov")
        #expect(names(CatalogRows.rows([r], open([.needsDate]))) == ["IMG_0002.mov"])
        r.userDate = "1988"
        r.userDateConfidence = "estimated"
        #expect(CatalogRows.rows([r], open([.needsDate])).rows.isEmpty, "his best guess is still a filing date")
        r.userDate = nil
        r.userDateConfidence = nil
        #expect(names(CatalogRows.rows([r], open([.needsDate]))) == ["IMG_0002.mov"])
    }
}

// MARK: - SCALE

@Suite("Catalog rows — 100k records inside the filter budget")
struct CatalogRowsScaleTests {

    private func catalog(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = i % 3 == 0 ? "IMG_\(i).mov" : "199\(i % 10)-0\(1 + i % 9)-1\(i % 9) clip \(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/\(r.filename)"
            r.directory = "/Volumes/V\(i % 4)"
            r.streamTypeRaw = (i % 5 == 0 ? StreamType.videoOnly : StreamType.videoAndAudio).rawValue
            if i % 7 == 0 { r.userDate = "1992"; r.userDateConfidence = "known" }
            return r
        }
    }

    /// Budget: the Catalog's filter pass at 100k rows — 1.0 s for the plain
    /// pass (the same ceiling CatalogAllVolumesDefaultTests gives the view's
    /// pass), 2.0 s with every filter on (Needs a Date resolves a date per row).
    @Test("SCALE: 100k records — plain, and with every filter on and a held row")
    func hundredThousandRows() {
        let all = catalog(100_000)
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        var t0 = Date()
        let plain = CatalogRows.rows(all, s)
        var elapsed = Date().timeIntervalSince(t0)
        #expect(plain.rows.count == 100_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 1.0), "plain pass took \(elapsed)s for 100k records")

        s.filters = [.unpairedOnly, .needsDate, .notYetArchived, .onePerFootage]
        s.engines.notYetArchived = { $0.sizeBytes == 0 }
        let heldRow = all[70_000]   // dated (70_000 % 7 == 0) and video-only: fails Needs a Date
        s.held = [heldRow.id]
        t0 = Date()
        let filtered = CatalogRows.rows(all, s)
        elapsed = Date().timeIntervalSince(t0)
        #expect(filtered.noLongerMatching == [heldRow.id])
        #expect(filtered.rows.contains { $0 === heldRow })
        #expect(filtered.rows.count > 1_000 && filtered.rows.count < 20_001)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 2.0), "filtered pass took \(elapsed)s for 100k records")
    }
}

// MARK: - SENSOR

@Suite("Catalog rows — the view only calls the function (sensor)")
struct CatalogRowsSensorTests {

    @Test("SENSOR: computeFiltered hands the work to CatalogRows.rows and holds no filter branch of its own")
    func computeFilteredIsAnAdapter() throws {
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        let start = try #require(helpers.range(of: "func computeFiltered("))
        let end = try #require(helpers.range(of: "\n    }\n", range: start.upperBound..<helpers.endIndex))
        let body = String(helpers[start.lowerBound..<end.upperBound])
        #expect(body.contains("CatalogRows.rows(records, "))
        for branch in ["viewFilters.contains(", ".filter {", "pfApply", "FootageOnePerGroup", "recordPredicate"] {
            #expect(!body.contains(branch), "computeFiltered still filters by hand: \(branch)")
        }
        // The function itself is pure: no model, no view, no defaults.
        let rows = try SourceTree.appCode(named: "CatalogRows.swift")
        let pureStart = try #require(rows.range(of: "enum CatalogRows {"))
        let pureEnd = try #require(rows.range(of: "final class CatalogEditClock"))
        let pure = String(rows[pureStart.lowerBound..<pureEnd.lowerBound])
        for impure in ["VideoScanModel", "UserDefaults", "@State", "@Published", "VolumeReachability", "model."] {
            #expect(!pure.contains(impure), "CatalogRows reads \(impure)")
        }
    }

    @Test("SENSOR: the table holds the selection only after an edit, and releases it when the selection moves")
    func theTableHoldsOnlyAfterAnEdit() throws {
        let state = try SourceTree.appCode(named: "CatalogTableState.swift")
        #expect(state.contains("func refreshRows(afterEdit: Bool = false)"))
        #expect(state.contains("let hold = afterEdit ? CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData) : []"),
                "a filter, search or scope change must hold nothing (Finder's rule: a hidden row is deselected)")
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(table.contains("releaseHeldRowsIfSelectionMoved()"))
        // The filter/search/scope triggers stay plain refreshes.
        for trigger in ["viewFilters", "searchText", "filterTargetPaths", "personFilter", "showPairsOnly", "filterByIDs"] {
            #expect(table.contains(".onChange(of: \(trigger)) { refreshRows() }"), "\(trigger) must not hold rows")
        }
    }
}
