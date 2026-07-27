// UnifiedReviewSessionTests.swift
// Proving tests for the unified Review session (feature/unified-review,
// docs/design/unified-review.md) — committed BEFORE the sheet rewiring,
// per the high-stakes-restructure protocol.
//
// Sensors here pin the three contamination-critical contracts:
//
//   1. WRITE-SINK CUSTODY (both directions) — a holdout yes/no can only
//      route to the sealed CSV; a candidate rating can only route to the
//      validation store + catalog; a mismatched pairing is REJECTED (nil),
//      never coerced. Plus file-level custody: recording on one surface
//      leaves the other surface's file byte-identical.
//   2. BLINDNESS PHASE GATE — candidate scoring is permitted only in the
//      candidate phases; re-entering the holdout phase requires a purge.
//   3. BACK NEVER CROSSES PHASES — candidate index 0 has no Back.
//
// Plus: navigation-core parity (the generic wrap/linear walk the two
// phases now share), SCALE for pfConfirmRound at 100k records (verified
// missing 2026-07-27 — added per checklist dimension 2), and ISOLATION
// (garbage queue CSV + garbage validation_labels.json simultaneously).
//
// All I/O uses per-test temp directories — never the real review CSV,
// validation labels, or prefs (settings-pollution class).

import Testing
import Foundation
@testable import VideoScan

@Suite("Unified Review Session")
struct UnifiedReviewSessionTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-review-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func csvText(_ dataLines: [String]) -> String {
        (["reviewId,fullPath,rickConfirm(yes/no),notes"] + dataLines)
            .map { $0 + "\r\n" }.joined()
    }

    private func writeQueueCSV(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(HoldoutReviewQueue.csvFilename)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func holdoutRow(_ id: String = "AAAA00000001",
                            path: String = "/Volumes/T/a.mov",
                            answered: Bool = false) -> HoldoutReviewRow {
        HoldoutReviewRow(reviewId: id, fullPath: path,
                         rickConfirm: answered ? "yes" : "",
                         notes: "", extraColumns: [])
    }

    private func candidate(path: String = "/Volumes/T/c.mov",
                           score: Int = 10) -> PersonCandidateScore {
        PersonCandidateScore(recordID: UUID(), recordPath: path,
                             filename: (path as NSString).lastPathComponent,
                             score: score, signals: ["filename"],
                             reachable: true)
    }

    // MARK: - 1a. Custody router: legal pairings

    @Test func custody_holdoutAnswerRoutesOnlyToSealedCSV() {
        let item = ReviewItem.holdout(holdoutRow())
        #expect(ReviewWriteRouting.sink(for: item, answer: .holdoutConfirm("yes"))
                == .sealedHoldoutCSV)
        #expect(ReviewWriteRouting.sink(for: item, answer: .holdoutConfirm("no"))
                == .sealedHoldoutCSV)
    }

    @Test func custody_candidateRatingRoutesOnlyToValidationStore() {
        let item = ReviewItem.candidate(candidate())
        for rating in ConfirmRating.allCases {
            #expect(ReviewWriteRouting.sink(for: item, answer: .rating(rating))
                    == .validationStoreAndCatalog,
                    "rating \(rating.rawValue) must route to the validation store")
        }
    }

    // MARK: - 1b. Custody router: forbidden pairings REJECTED, not coerced

    @Test func custody_ratingAimedAtBlindRowIsRejected() {
        // The naive-merge failure mode: a unified answer handler feeding a
        // 4-tier rating into a holdout row. The router must return nil —
        // the caller drops the write — never map it onto yes/no.
        let blind = ReviewItem.holdout(holdoutRow())
        for rating in ConfirmRating.allCases {
            #expect(ReviewWriteRouting.sink(for: blind, answer: .rating(rating)) == nil,
                    "rating \(rating.rawValue) against a blind row must be rejected")
        }
    }

    @Test func custody_yesNoAimedAtCandidateIsRejected() {
        // Reverse direction: a holdout yes/no must never reach the
        // validation store / catalog writeback via a candidate item.
        let cand = ReviewItem.candidate(candidate())
        #expect(ReviewWriteRouting.sink(for: cand, answer: .holdoutConfirm("yes")) == nil)
        #expect(ReviewWriteRouting.sink(for: cand, answer: .holdoutConfirm("no")) == nil)
    }

    // MARK: - 1c. File-level custody (both directions)

    @Test @MainActor func custody_holdoutAnswerLeavesValidationLabelsByteIdentical() throws {
        let dir = try makeTempDir()
        let csvURL = try writeQueueCSV(csvText([
            "AAAA00000001,/Volumes/T/a.mov,,",
        ]), in: dir)
        // A validation store with real content lives right next door.
        let store = ValidationLabelStore(directory: dir)
        store.record(recordPath: "/Volumes/T/other.mov", person: "Donna",
                     rating: .definitely, signals: ["filename"], score: 10)
        let labelBytesBefore = try Data(contentsOf: store.fileURL)

        var q = try HoldoutReviewQueue.load(csvURL: csvURL)
        try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "porch")

        // The sealed answer landed in the CSV…
        #expect(try HoldoutReviewQueue.load(csvURL: csvURL).rows[0].rickConfirm == "yes")
        // …and the validation labels file is byte-identical.
        #expect(try Data(contentsOf: store.fileURL) == labelBytesBefore,
                "a holdout answer modified validation_labels.json — custody breach")
    }

    @Test @MainActor func custody_validationRecordLeavesSealedCSVByteIdentical() throws {
        let dir = try makeTempDir()
        let csvURL = try writeQueueCSV(csvText([
            "AAAA00000001,/Volumes/T/a.mov,,",
            "BBBB00000002,/Volumes/T/b.mov,no,too dark",
        ]), in: dir)
        let csvBytesBefore = try Data(contentsOf: csvURL)

        let store = ValidationLabelStore(directory: dir)
        // Rating the SAME path that appears in the queue — the tempting
        // naive-merge shortcut would "helpfully" update the CSV row too.
        store.record(recordPath: "/Volumes/T/a.mov", person: "Donna",
                     rating: .no, signals: ["control"], score: 0)

        #expect(store.labels.count == 1)
        #expect(try Data(contentsOf: csvURL) == csvBytesBefore,
                "a confirm rating modified the sealed holdout CSV — custody breach")
    }

    // MARK: - 2. Blindness phase gate

    @Test func blindness_candidateLoadingForbiddenDuringHoldoutPhase() {
        #expect(!ReviewSessionPolicy.mayLoadCandidates(in: .holdout),
                "pfConfirmRound/prepareSetup must not run while blind rows can be presented")
        #expect(ReviewSessionPolicy.mayLoadCandidates(in: .candidateSetup))
        #expect(ReviewSessionPolicy.mayLoadCandidates(in: .candidateLabeling))
        #expect(ReviewSessionPolicy.mayLoadCandidates(in: .summary))
    }

    @Test func blindness_reenteringHoldoutRequiresCandidatePurge() {
        // "Continue Reviewing" from the transition pane goes back to blind
        // rows — loaded-but-hidden candidate state is not allowed there.
        #expect(ReviewSessionPolicy.mustPurgeCandidates(entering: .holdout))
        #expect(!ReviewSessionPolicy.mustPurgeCandidates(entering: .candidateSetup))
        #expect(!ReviewSessionPolicy.mustPurgeCandidates(entering: .candidateLabeling))
    }

    @Test func blindness_reviewItemBlindFlagMatchesCase() {
        #expect(ReviewItem.holdout(holdoutRow()).isBlind)
        #expect(!ReviewItem.candidate(candidate()).isBlind)
    }

    // MARK: - 3. Back never crosses phases

    @Test func back_candidateIndexZeroHasNoBack_evenWithHoldoutHistory() {
        // Design note D2: from the candidate phase, Back stops at the first
        // candidate. It must NOT cross into answered holdout rows.
        #expect(!ReviewSessionPolicy.canGoBack(in: .candidateLabeling, index: 0))
        #expect(ReviewSessionPolicy.canGoBack(in: .candidateLabeling, index: 1))
        // Within holdout, Back keeps today's behavior.
        #expect(!ReviewSessionPolicy.canGoBack(in: .holdout, index: 0))
        #expect(ReviewSessionPolicy.canGoBack(in: .holdout, index: 3))
        // No Back affordance on setup/summary panes.
        #expect(!ReviewSessionPolicy.canGoBack(in: .candidateSetup, index: 5))
        #expect(!ReviewSessionPolicy.canGoBack(in: .summary, index: 5))
    }

    // MARK: - 4. Unified item accessors

    @Test func item_pathAndFilenameComeFromTheWrappedPayload() {
        let h = ReviewItem.holdout(holdoutRow(path: "/Volumes/T/sub/movie one.mov"))
        #expect(h.fullPath == "/Volumes/T/sub/movie one.mov")
        #expect(h.filename == "movie one.mov")
        let c = ReviewItem.candidate(candidate(path: "/Volumes/X/dir/clip.avi"))
        #expect(c.fullPath == "/Volumes/X/dir/clip.avi")
        #expect(c.filename == "clip.avi")
    }

    // MARK: - 5. Navigation core (D5 — one walk, two policies)

    @Test func nav_wrapPolicyVisitsEveryOtherIndexOnceNeverSelf() {
        // Wrap mode == the holdout walk: skips non-actionable, wraps to the
        // front, and a row is never its own successor.
        let actionable: Set<Int> = [0, 2]
        #expect(HoldoutNavigation.nextIndex(after: 0, count: 5, wraps: true,
                                            isActionable: { actionable.contains($0) }) == 2)
        #expect(HoldoutNavigation.nextIndex(after: 2, count: 5, wraps: true,
                                            isActionable: { actionable.contains($0) }) == 0)
        // Only the current index is actionable → no successor (never self).
        #expect(HoldoutNavigation.nextIndex(after: 2, count: 5, wraps: true,
                                            isActionable: { $0 == 2 }) == nil)
        // Single-item queue: no successor.
        #expect(HoldoutNavigation.nextIndex(after: 0, count: 1, wraps: true,
                                            isActionable: { _ in true }) == nil)
    }

    @Test func nav_linearPolicyNeverWraps_skippedItemsDoNotComeBack() {
        // Linear mode == the candidate walk: strictly forward, end = done.
        // (The existing Confirm semantic — a skipped candidate does not
        // come back around in the same round.)
        #expect(HoldoutNavigation.nextIndex(after: 0, count: 3, wraps: false,
                                            isActionable: { _ in true }) == 1)
        #expect(HoldoutNavigation.nextIndex(after: 2, count: 3, wraps: false,
                                            isActionable: { _ in true }) == nil,
                "linear walk must not wrap — that would resurrect skipped candidates")
        // Front search: after -1 includes index 0.
        #expect(HoldoutNavigation.nextIndex(after: -1, count: 3, wraps: false,
                                            isActionable: { _ in true }) == 0)
        #expect(HoldoutNavigation.nextIndex(after: -1, count: 0, wraps: false,
                                            isActionable: { _ in true }) == nil)
    }

    @Test func nav_delegatingWrappersPreserveOriginalHoldoutSemantics() {
        // Parity pin: the refactored delegating wrappers must reduce to the
        // exact pre-refactor behavior (mirrors HoldoutOfflinePrefilterTests'
        // baseline, duplicated here so THIS file fails standalone if the
        // core drifts).
        let rows = [holdoutRow("A", path: "/Volumes/T/a.mov"),
                    holdoutRow("B", path: "/Volumes/T/b.mov", answered: true),
                    holdoutRow("C", path: "/Volumes/T/c.mov")]
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 0)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 0, rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 2)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 2, rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 0)
    }

    // MARK: - 6. Scale (checklist dim 2 — pfConfirmRound at 100k records)

    @Test @MainActor func scale_confirmRoundOver100kRecordsWithinBudget() {
        // Verified 2026-07-27: pfConfirmRound had NO 100k-scale coverage
        // (ConfirmVerbTests is logic-only). The unified session runs this
        // scorer at the phase transition, so its cost is a visible UI wait —
        // budget generous but real, proportionate to the suite's existing
        // envelopes (100k CSV load < 8 s).
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            // Every 100th record carries a filename signal → 1000 positives.
            r.filename = i.isMultiple(of: 100) ? "donna_\(i).mov" : "clip_\(i).mov"
            r.fullPath = "/v/scale/\(i / 1000)/\(r.filename)"
            r.directory = "/v/scale/\(i / 1000)"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 60
            records.append(r)
        }
        var rng = SystemRandomNumberGenerator()
        let clock = ContinuousClock()
        var result: (candidates: [PersonCandidateScore], stats: ConfirmRoundStats)?
        let elapsed = clock.measure {
            result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 100, controlK: 5,
                                    alreadyLabeled: [], rng: &rng)
        }
        #expect(elapsed < .seconds(10),
                "candidate scoring at 100k records took \(elapsed) — the phase transition will feel it")
        #expect(result?.stats.candidatesSurfaced == 1_000)
        // topN positives + up to controlK controls.
        #expect((result?.candidates.count ?? 0) >= 100)
        #expect((result?.candidates.count ?? 0) <= 105)
    }

    // MARK: - 7. Isolation (poisoned state on BOTH surfaces at once)

    @Test @MainActor func isolation_garbageCSVAndGarbageLabelsDegradeIndependently() throws {
        let root = try makeTempDir()
        // Poison surface 1: the newest dated queue dir holds binary garbage
        // where the CSV should be.
        let dated = root.appendingPathComponent(
            "output/person-eval-private/2026-07-27", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        let csvURL = dated.appendingPathComponent(HoldoutReviewQueue.csvFilename)
        try Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x9C]).write(to: csvURL)
        // Poison surface 2: validation_labels.json is truncated JSON junk.
        let labelsDir = try makeTempDir()
        try Data("[{\"id\": \"not even close".utf8).write(
            to: labelsDir.appendingPathComponent("validation_labels.json"))

        // Queue side: badge path degrades to nil (no crash), throwing path
        // surfaces the parse error.
        #expect(HoldoutReviewQueue.discover(repoRoot: root) == nil)
        #expect(throws: Error.self) {
            _ = try HoldoutReviewQueue.discoverLatest(repoRoot: root)
        }

        // Label side: store opens empty and still records — one poisoned
        // surface must not take down the other.
        let store = ValidationLabelStore(directory: labelsDir)
        #expect(store.labels.isEmpty)
        store.record(recordPath: "/v/x.mov", person: "Donna",
                     rating: .likely, signals: ["filename"], score: 10)
        #expect(store.labels.count == 1)

        // And recording on the label side never "repaired"/touched the
        // poisoned CSV (custody holds even in the degraded state).
        #expect(try Data(contentsOf: csvURL) == Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x9C]))
    }
}
