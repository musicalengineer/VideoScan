// CatalogFreshnessTests.swift — the colour rules of
// docs/design/catalog_status_freshness_2026_10_16.md §3, pinned.
//
// Every rule, the precedence between them, the summary headline for each
// colour, the worst-of ordering, the words for a handful of rows, a
// deterministic relative-time helper, a Codable round-trip of the colour,
// and a sanity budget for a 1,000-row summary. `now` and the calendar are
// fixed (America/New_York, 2026-10-16 14:30) so no test depends on the
// machine's clock, time zone or locale.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogFreshness")
struct CatalogFreshnessTests {

    // MARK: Fixtures

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    static let wording = FreshnessWording(calendar: calendar, groupingSeparator: ",")

    /// 2026-10-16 14:30 Eastern.
    static let now: Date = date(2026, 10, 16, 14, 30)

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? Date(timeIntervalSince1970: 0)
    }

    static let hashPhrases = FreshnessRow.Phrases(unit: "file", uncovered: "without a full hash",
                                                 decision: "needing a decision")
    static let presencePhrases = FreshnessRow.Phrases(unit: "row", uncovered: "not yet checked",
                                                     decision: "pointing at nothing — look at Fix Links")

    /// A current Full Hashes row: everything stamped, finished this morning.
    static func currentHashes() -> FreshnessRow {
        FreshnessRow(kind: "fullhash", title: "Full Hashes", eligible: 1_200, covered: 1_200,
                     lastCompleted: date(2026, 10, 16, 10, 42), lastOutcome: .ok, phrases: hashPhrases)
    }

    /// A current File Presence row on a 1-day cadence, finished at 02:14.
    static func currentPresence() -> FreshnessRow {
        FreshnessRow(kind: "presence", title: "File Presence", eligible: 5_000, covered: 5_000,
                     lastCompleted: date(2026, 10, 16, 2, 14), lastOutcome: .ok,
                     cadence: .seconds(86_400), phrases: presencePhrases)
    }

    func judge(_ row: FreshnessRow) -> FreshnessVerdict {
        FreshnessPolicy.judge(row, now: Self.now, wording: Self.wording)
    }

    func summarize(_ rows: [FreshnessRow]) -> FreshnessSummary {
        FreshnessPolicy.summarize(rows, now: Self.now, wording: Self.wording)
    }

    // MARK: Colour order

    @Test func worstOfOrderIsRedYellowGreenGrey() {
        #expect(FreshnessColour.red > .yellow)
        #expect(FreshnessColour.yellow > .green)
        #expect(FreshnessColour.green > .grey)
        #expect([FreshnessColour.grey, .green, .yellow, .red].max() == .red)
        #expect([FreshnessColour.grey, .green].max() == .green)
        #expect([FreshnessColour.grey, .grey].max() == .grey)
        #expect(([] as [FreshnessColour]).max() == nil)
    }

    @Test func colourRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(FreshnessColour.allCases)
        let back = try JSONDecoder().decode([FreshnessColour].self, from: data)
        #expect(back == FreshnessColour.allCases)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"["green","yellow","red","grey"]"#)
    }

    // MARK: Green

    @Test func everythingStampedIsGreenWithTheCheckedTime() {
        let v = judge(Self.currentHashes())
        #expect(v.colour == .green)
        #expect(v.words == "current · checked today at 10:42")
        #expect(v.reason == .current(checked: Self.date(2026, 10, 16, 10, 42)))
    }

    @Test func withinCadenceIsGreen() {
        let v = judge(Self.currentPresence())
        #expect(v.colour == .green)
        #expect(v.words == "current · checked today at 02:14")
    }

    @Test func stampedWithNoTimeSaysCurrent() {
        var row = Self.currentHashes()
        row.lastCompleted = nil
        #expect(judge(row).words == "current")
    }

    @Test func offlineRowsDoNotSpoilGreen() {
        var row = Self.currentHashes()
        row.offline = 340
        #expect(judge(row).colour == .green)
    }

    // MARK: Yellow — a run fixes it

    @Test func uncoveredRowsAreYellowWithTheCount() {
        var row = Self.currentHashes()
        row.covered = 540
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "660 files without a full hash")
        #expect(v.reason == .uncovered(660))
    }

    @Test func neverRanWithEligibleRowsIsYellow() {
        let row = FreshnessRow(kind: "soundprint", title: "Sound Prints", eligible: 12, covered: 12,
                               lastOutcome: .neverRan)
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "never run — 12 files waiting")
    }

    @Test func neverRanWithNothingEligibleIsNotYellow() {
        let row = FreshnessRow(kind: "soundprint", title: "Sound Prints", lastOutcome: .neverRan)
        #expect(judge(row).colour == .grey)
    }

    @Test func partialLastRunIsYellow() {
        var row = Self.currentHashes()
        row.lastOutcome = .partial
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "the last run stopped part way — run it again")
    }

    @Test func olderThanCadenceIsYellowNotRed() {
        var row = Self.currentPresence()
        row.lastCompleted = Self.date(2026, 10, 13, 2, 14)
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "last checked 3 days ago")
    }

    @Test func cadenceWithNoCompletionIsYellow() {
        var row = Self.currentPresence()
        row.lastCompleted = nil
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "not checked yet")
    }

    @Test func noCadenceMeansOldStampsStayGreen() {
        var row = Self.currentHashes()
        row.lastCompleted = Self.date(2024, 1, 1, 9, 0)
        #expect(judge(row).colour == .green)
    }

    @Test func coverageWinsOverCadenceInTheWords() {
        var row = Self.currentPresence()
        row.covered = 4_999
        row.lastCompleted = Self.date(2026, 10, 1, 2, 14)
        #expect(judge(row).words == "1 row not yet checked")
    }

    // MARK: Red — a person has to look

    @Test func unopenableStoreIsRed() {
        var row = Self.currentHashes()
        row.storeUnavailable = "audio-prints.json is not valid JSON"
        let v = judge(row)
        #expect(v.colour == .red)
        #expect(v.words == "sidecar can't be opened: audio-prints.json is not valid JSON")
    }

    @Test func failedLastRunIsRed() {
        var row = Self.currentHashes()
        row.lastOutcome = .failed
        let v = judge(row)
        #expect(v.colour == .red)
        #expect(v.words == "the last run failed or was stopped — look at the log, then run again")
    }

    @Test func rowsNeedingADecisionAreRedWithTheKindsWords() {
        var row = Self.currentPresence()
        row.needsDecision = 3
        let v = judge(row)
        #expect(v.colour == .red)
        #expect(v.words == "3 rows pointing at nothing — look at Fix Links")
        #expect(v.reason == .needsDecision(3))
    }

    @Test func oneDecisionRowIsSingular() {
        var row = Self.currentPresence()
        row.needsDecision = 1
        #expect(judge(row).words == "1 row pointing at nothing — look at Fix Links")
    }

    @Test func redBeatsYellowWhenBothApply() {
        var row = Self.currentHashes()
        row.covered = 0
        row.lastOutcome = .failed
        let v = judge(row)
        #expect(v.colour == .red)
        #expect(v.reason == .lastRunFailed)
    }

    @Test func storeBeatsFailureBeatsDecision() {
        var row = Self.currentHashes()
        row.needsDecision = 2
        #expect(judge(row).reason == .needsDecision(2))
        row.lastOutcome = .failed
        #expect(judge(row).reason == .lastRunFailed)
        row.storeUnavailable = "locked"
        #expect(judge(row).reason == .storeUnavailable("locked"))
    }

    // MARK: Running

    /// Decided here: a running stale row is yellow and reads "running" —
    /// the pass is in progress, the button is not needed, and it is left
    /// out of staleKinds so Update everything stale does not queue it twice.
    @Test func runningStaleRowIsYellowAndReadsRunning() {
        var row = Self.currentHashes()
        row.covered = 540
        row.isRunning = true
        let v = judge(row)
        #expect(v.colour == .yellow)
        #expect(v.words == "running")
        #expect(summarize([row]).staleKinds.isEmpty)
    }

    @Test func runningCurrentRowStaysGreenAndReadsRunning() {
        var row = Self.currentHashes()
        row.isRunning = true
        let v = judge(row)
        #expect(v.colour == .green)
        #expect(v.words == "running")
    }

    @Test func runningRowKeepsItsRedDecisionCount() {
        var row = Self.currentPresence()
        row.needsDecision = 3
        row.isRunning = true
        let v = judge(row)
        #expect(v.colour == .red)
        #expect(v.words == "3 rows pointing at nothing — look at Fix Links · running")
    }

    @Test func runningOverdueRowIsNeverRedForStaleness() {
        var row = Self.currentPresence()
        row.lastCompleted = Self.date(2026, 9, 1, 2, 14)
        row.isRunning = true
        #expect(judge(row).colour == .yellow)
    }

    // MARK: Grey — not asked

    @Test func everythingOnUnmountedDrivesIsGrey() {
        let row = FreshnessRow(kind: "fullhash", title: "Full Hashes", eligible: 0, covered: 0, offline: 340,
                               lastOutcome: .ok, phrases: Self.hashPhrases)
        let v = judge(row)
        #expect(v.colour == .grey)
        #expect(v.words == "not asked — 340 files on drives that aren't mounted")
    }

    @Test func nothingAtAllIsGrey() {
        let row = FreshnessRow(kind: "fullhash", title: "Full Hashes", lastOutcome: .ok)
        let v = judge(row)
        #expect(v.colour == .grey)
        #expect(v.words == "nothing to check")
    }

    @Test func greyNeverOutranksAFailure() {
        let row = FreshnessRow(kind: "fullhash", title: "Full Hashes", offline: 340, lastOutcome: .failed)
        #expect(judge(row).colour == .red)
    }

    // MARK: Words

    @Test func countsAreGrouped() {
        #expect(Self.wording.grouped(0) == "0")
        #expect(Self.wording.grouped(999) == "999")
        #expect(Self.wording.grouped(1_000) == "1,000")
        #expect(Self.wording.grouped(1_234_567) == "1,234,567")
        #expect(Self.wording.count(1, "file") == "1 file")
        #expect(Self.wording.count(12_000, "row") == "12,000 rows")
        let french = FreshnessWording(calendar: Self.calendar, groupingSeparator: " ")
        #expect(french.grouped(12_345) == "12 345")
    }

    @Test func relativeTimeWordsAreDeterministic() {
        let r = RelativeTimeWords(calendar: Self.calendar, now: Self.now)
        #expect(r.words(for: Self.now) == "just now")
        #expect(r.words(for: Self.now.addingTimeInterval(-59)) == "just now")
        #expect(r.words(for: Self.now.addingTimeInterval(-60)) == "1 minute ago")
        #expect(r.words(for: Self.now.addingTimeInterval(-25 * 60)) == "25 minutes ago")
        #expect(r.words(for: Self.date(2026, 10, 16, 10, 42)) == "today at 10:42")
        #expect(r.words(for: Self.date(2026, 10, 16, 0, 5)) == "today at 00:05")
        #expect(r.words(for: Self.date(2026, 10, 15, 23, 5)) == "yesterday at 23:05")
        #expect(r.words(for: Self.date(2026, 10, 14, 23, 59)) == "2 days ago")
        #expect(r.words(for: Self.date(2026, 10, 13, 0, 1)) == "3 days ago")
        #expect(r.words(for: Self.date(2026, 9, 16, 14, 30)) == "30 days ago")
        // A stamp from the future (clock skew) reads as just now, never negative.
        #expect(r.words(for: Self.now.addingTimeInterval(600)) == "just now")
    }

    @Test func lateNightStampJustAfterMidnightIsMinutesNotYesterday() {
        let now = Self.date(2026, 10, 16, 0, 30)
        let r = RelativeTimeWords(calendar: Self.calendar, now: now)
        #expect(r.words(for: Self.date(2026, 10, 15, 23, 50)) == "40 minutes ago")
        #expect(r.words(for: Self.date(2026, 10, 15, 22, 50)) == "yesterday at 22:50")
    }

    // MARK: Summary

    @Test func allGreenReadsCatalogIsCurrent() {
        let s = summarize([Self.currentHashes(), Self.currentPresence()])
        #expect(s.colour == .green)
        #expect(s.headline == "Catalog is current")
        #expect(s.items.isEmpty)
        #expect(s.staleKinds.isEmpty)
        #expect(!s.needsAttention)
    }

    @Test func yellowRowsCountTheThingsThatNeedARun() {
        var hashes = Self.currentHashes()
        hashes.covered = 540
        let prints = FreshnessRow(kind: "soundprint", title: "Sound Prints", eligible: 12, lastOutcome: .neverRan)
        let s = summarize([Self.currentPresence(), hashes, prints])
        #expect(s.colour == .yellow)
        #expect(s.headline == "2 things need attention")
        #expect(s.items.map(\.kind) == ["fullhash", "soundprint"])
        #expect(s.items[0].words == "660 files without a full hash")
        #expect(s.items[0].title == "Full Hashes")
        #expect(s.staleKinds == ["fullhash", "soundprint"])
        #expect(!s.needsAttention)
    }

    @Test func oneYellowRowIsSingular() {
        var hashes = Self.currentHashes()
        hashes.covered = 540
        #expect(summarize([hashes]).headline == "1 thing needs attention")
    }

    @Test func oneRedRowPutsItsWordsInTheHeadline() {
        var presence = Self.currentPresence()
        presence.needsDecision = 3
        let s = summarize([Self.currentHashes(), presence])
        #expect(s.colour == .red)
        #expect(s.headline == "Needs a decision: 3 rows pointing at nothing — look at Fix Links")
        #expect(s.needsAttention)
        #expect(s.items.map(\.kind) == ["presence"])
    }

    @Test func severalRedRowsAreCounted() {
        var presence = Self.currentPresence()
        presence.needsDecision = 3
        var hashes = Self.currentHashes()
        hashes.lastOutcome = .failed
        let s = summarize([hashes, presence])
        #expect(s.headline == "Needs a decision: 2 things")
    }

    @Test func itemsListRedFirstThenYellowThenGreyInRegistryOrder() {
        var a = Self.currentHashes(); a.kind = "a"; a.covered = 1
        var b = Self.currentPresence(); b.kind = "b"; b.needsDecision = 1
        let c = FreshnessRow(kind: "c", title: "C", offline: 5, lastOutcome: .ok)
        var d = Self.currentHashes(); d.kind = "d"; d.covered = 2
        var e = Self.currentPresence(); e.kind = "e"; e.lastOutcome = .failed
        var f = Self.currentHashes(); f.kind = "f"
        let s = summarize([a, b, c, d, e, f])
        #expect(s.items.map(\.kind) == ["b", "e", "a", "d", "c"])
        #expect(s.items.map(\.colour) == [.red, .red, .yellow, .yellow, .grey])
        _ = f
    }

    @Test func staleKindsExcludesRedAndGreyRows() {
        var red = Self.currentHashes(); red.kind = "red"; red.covered = 0; red.lastOutcome = .failed
        var yellow = Self.currentHashes(); yellow.kind = "yellow"; yellow.covered = 0
        let grey = FreshnessRow(kind: "grey", title: "G", offline: 1, lastOutcome: .ok)
        let s = summarize([red, yellow, grey, Self.currentPresence()])
        #expect(s.colour == .red)
        #expect(s.staleKinds == ["yellow"])
    }

    @Test func allGreyWithOfflineRowsSaysDrivesNotMounted() {
        let rows = [FreshnessRow(kind: "fullhash", title: "Full Hashes", offline: 340, lastOutcome: .ok),
                    FreshnessRow(kind: "soundprint", title: "Sound Prints", offline: 12, lastOutcome: .ok)]
        let s = summarize(rows)
        #expect(s.colour == .grey)
        #expect(s.headline == "Nothing to check — drives not mounted")
        #expect(s.items.count == 2)
    }

    @Test func emptyRegistrySaysNothingToCheck() {
        let s = summarize([])
        #expect(s.colour == .grey)
        #expect(s.headline == "Nothing to check")
        #expect(s.items.isEmpty)
    }

    @Test func greyRowsBesideGreenOnesReadCurrent() {
        let grey = FreshnessRow(kind: "soundprint", title: "Sound Prints", offline: 12, lastOutcome: .ok)
        let s = summarize([Self.currentHashes(), grey])
        #expect(s.colour == .green)
        #expect(s.headline == "Catalog is current")
        #expect(s.items.map(\.kind) == ["soundprint"])
    }

    // MARK: Scale — a sanity budget

    /// The registry has ~10 rows; 1,000 is a sanity bound, not a target.
    /// Measured 2026-10-16, M4 Max, Debug, quiet: 4.5 ms wall = 4.5 ms
    /// thread CPU (~4.5 µs a row, mostly the one Calendar call behind
    /// "today at 10:42"). Budget 10 ms, judged load-aware (GH #208).
    @Test func thousandRowSummaryIsCheap() {
        // A quarter each: uncovered (yellow), overdue (yellow, a calendar
        // call for the words), needing a decision (red), current (green,
        // a calendar call too).
        let rows: [FreshnessRow] = (0..<1_000).map { i in
            var row = i % 2 == 0 ? Self.currentHashes() : Self.currentPresence()
            row.kind = "kind-\(i)"
            switch i % 4 {
            case 0: row.covered = row.eligible - 7
            case 1: row.cadence = .seconds(86_400); row.lastCompleted = Self.date(2026, 10, 10, 1, 0)
            case 2: row.needsDecision = 1 + i % 3
            default: break
            }
            return row
        }
        _ = summarize(rows)   // warm the code path once; the budget is for steady state
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var summary: FreshnessSummary?
        let cpu = TimingBudget.measureThreadCPUTime { summary = summarize(rows) }
        let elapsed = clock.now - start
        print("[freshness-scale] 1,000 rows: wall \(elapsed), thread CPU \(cpu)")
        expectWithinTimingBudget("1,000-row freshness summary", measured: elapsed,
                                 budget: .milliseconds(10), loadBefore: loadBefore)
        #expect(summary?.colour == .red)
        #expect(summary?.items.count == 750)
        #expect(summary?.staleKinds.count == 500)
        #expect(summary?.headline == "Needs a decision: 250 things")
    }
}
