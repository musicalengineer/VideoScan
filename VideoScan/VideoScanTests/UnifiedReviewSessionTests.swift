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

    // MARK: - 8. Entry-point sensor (dlib-removal style source scan)

    /// The old "Confirm <name>…" context-menu item was REMOVED in favor of
    /// the single "Review <name>…" entry (design note D7). This sensor
    /// keeps it from quietly coming back — and keeps both surviving entry
    /// points (menu item + badge) wired. Fails loudly if the People file
    /// moves; update the path deliberately, not by deleting the test.
    @Test func sensor_confirmMenuItemStaysRemoved_reviewEntryStaysWired() throws {
        let peopleFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // VideoScanTests/
            .deletingLastPathComponent()            // VideoScan/ (project dir)
            .appendingPathComponent("VideoScan/PersonFinderView+People.swift")
        let source = try String(contentsOf: peopleFile, encoding: .utf8)

        // The removed item must not come back…
        #expect(!source.contains("Button(\"Confirm \\(profile.name)"),
                "the redundant 'Confirm <name>…' menu item was removed 2026-07-27 — route through 'Review <name>…' instead")
        // …its replacement must exist…
        #expect(source.contains("Button(\"Review \\(profile.name)"),
                "the unified 'Review <name>…' menu entry is missing — people would have no path to the labeling flow")
        // …and the nag-button badge entry point stays wired.
        #expect(source.contains("holdoutReviewBadge(for: profile)"),
                "the holdout Review badge overlay is no longer applied to person cards")
        // The dashboard remains reachable from the gallery too.
        #expect(source.contains("Button(\"View Confirmations\\u{2026}\")"),
                "the View Confirmations dashboard entry is missing from the context menu")
    }

    // MARK: - 9. Sheet-wiring sensor (QA 2026-07-27 🟠 B)

    /// The pure-layer sensors above prove the ROUTER is correct — but
    /// deleting the sheet's guards and writing validation labels straight
    /// from holdoutAnswer would still pass all of them. This source scan
    /// pins the WIRING: both answer handlers consult the custody router,
    /// prepareSetup carries the blindness gate (twice — entry + inside
    /// the scoring task), resumeHoldout purges candidate state, and the
    /// validation store has exactly ONE call site in the sheet.
    @Test func sensor_sheetWiringRoutesThroughCustodyAndBlindnessGates() throws {
        let sheetFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // VideoScanTests/
            .deletingLastPathComponent()            // VideoScan/ (project dir)
            .appendingPathComponent("VideoScan/ConfirmPersonSheet.swift")
        let source = try String(contentsOf: sheetFile, encoding: .utf8)

        // (a) Holdout answers consult the custody router before writing.
        let holdoutAnswerBody = memberBody(of: source, from: "private func holdoutAnswer(")
        #expect(holdoutAnswerBody.contains("ReviewWriteRouting.sink(for: .holdout"),
                "holdoutAnswer no longer routes through ReviewWriteRouting — the custody sensors can't see this wiring, do not remove it")
        #expect(holdoutAnswerBody.contains("== .sealedHoldoutCSV"),
                "holdoutAnswer must require the sealed-CSV sink verdict")

        // (b) Candidate ratings consult the custody router before writing.
        let applyBody = memberBody(of: source, from: "private func apply(rating: ConfirmRating")
        #expect(applyBody.contains("ReviewWriteRouting.sink(for: .candidate"),
                "apply(rating:to:) no longer routes through ReviewWriteRouting")
        #expect(applyBody.contains("== .validationStoreAndCatalog"),
                "apply(rating:to:) must require the validation-store sink verdict")

        // (c) The blindness gate guards prepareSetup at entry AND inside
        // the scoring task (the schedule-vs-run window, QA 🟡 C).
        let prepareBody = memberBody(of: source, from: "private func prepareSetup(")
        #expect(occurrences(
            of: "guard ReviewSessionPolicy.mayLoadCandidates(in: policyPhase) else",
            in: String(prepareBody)) >= 2,
                "prepareSetup must gate candidate scoring at entry and inside the Task body")

        // (d) Re-entering the blind phase purges candidate state and
        // rebuilds media metadata from queue rows only (QA 🟠 A).
        let resumeBody = memberBody(of: source, from: "private func resumeHoldout(")
        #expect(resumeBody.contains("ReviewSessionPolicy.mustPurgeCandidates(entering: .holdout)"),
                "resumeHoldout no longer consults the purge policy")
        #expect(resumeBody.contains("buildMediaMeta(for: Set(q.rows.map(\\.fullPath)))"),
                "resumeHoldout must rebuild mediaMetaByPath from holdout rows — retained candidate KEYS are model-derived state")

        // (e) Exactly ONE validation-store write site in the whole sheet —
        // a second one is the naive-merge contamination this file exists
        // to prevent.
        #expect(occurrences(of: "validationLabels.record(", in: source) == 1,
                "ConfirmPersonSheet must have exactly one ValidationLabelStore write site (in apply)")

        // (f) Blocker fixes 2026-07-27 (codex #35 + #39): the full-queue
        // CONTENT-IDENTITY matcher is built (with catalog records, so
        // duplicate identities resolve) and passed into pfConfirmRound.
        #expect(prepareBody.contains("ReviewSessionPolicy.heldOutIdentityMatcher("),
                "prepareSetup no longer builds the held-out content-identity matcher")
        #expect(prepareBody.contains("records: catalogModel.records)"),
                "the matcher must be built WITH catalog records — path-only exclusion misses byte-identical aliases (codex #39)")
        #expect(prepareBody.contains("heldOut: heldOut"),
                "prepareSetup no longer passes the holdout exclusion into pfConfirmRound — eval content would surface with scores")

        // (g) Blocker fix 2026-07-27: queue load failure FAILS CLOSED —
        // startHoldout's catch lands on the fail-closed phase, never the
        // candidate transition.
        let startHoldoutBody = memberBody(of: source, from: "private func startHoldout(")
        #expect(startHoldoutBody.contains("phase = sheetPhase(ReviewSessionPolicy.phaseAfterQueueLoadFailure)"),
                "startHoldout's load-failure path no longer fails closed — a broken queue would leak the session into candidate scoring")
    }

    // MARK: - 10. Blocker regressions (codex #35, 2026-07-27 — full-queue exclusion)

    /// Synthetic catalog record with (optional) filename signal for Donna
    /// and (optional) duplicate-identity evidence.
    @MainActor
    private func makeRecord(_ path: String, md5: String = "",
                            dgid: UUID? = nil, size: Int64 = 0) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 60
        r.partialMD5 = md5
        r.duplicateGroupID = dgid
        r.sizeBytes = size
        return r
    }

    // (a) A skipped (still-pending) holdout row must never surface as a
    // candidate — the exact breach codex found: skip the last row →
    // transitionToCandidates → the skipped file appears with signals.
    @Test @MainActor func blocker_skippedPendingHoldoutPathNeverSurfacesAsCandidate() throws {
        let dir = try makeTempDir()
        let url = try writeQueueCSV(csvText([
            "AAAA00000001,/v/eval/donna_answered.mov,yes,",
            "BBBB00000002,/v/eval/donna_skipped.mov,,",
        ]), in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)
        let heldOutPaths = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil)

        // Both eval files carry a STRONG filename signal — absent the
        // exclusion they would rank at the top of the round.
        let records = [
            makeRecord("/v/eval/donna_answered.mov"),
            makeRecord("/v/eval/donna_skipped.mov"),
            makeRecord("/v/other/donna_free.mov"),
            makeRecord("/v/other/plain_1.mov"),
            makeRecord("/v/other/plain_2.mov"),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil, records: records)
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 2,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        let outPaths = Set(result.candidates.map(\.recordPath))
        #expect(outPaths.isDisjoint(with: heldOutPaths),
                "holdout-queue paths leaked into the candidate round: \(outPaths.intersection(heldOutPaths))")
        #expect(outPaths.contains("/v/other/donna_free.mov"),
                "non-eval positives must still surface")
        #expect(result.stats.heldOutExcluded == 2)
    }

    // (b) Union across in-memory and on-disk views: a row present in only
    // ONE of them (external regeneration/truncation, or an optimistic
    // in-flight answer the disk hasn't committed) is still excluded —
    // answer state is entirely irrelevant to the full-queue rule.
    @Test @MainActor func blocker_exclusionUnionsMemoryAndDiskViews() throws {
        let dirMem = try makeTempDir()
        let memURL = try writeQueueCSV(csvText([
            "AAAA00000001,/v/eval/only_in_memory.mov,yes,",   // answered (e.g. optimistic)
            "BBBB00000002,/v/eval/in_both.mov,,",
        ]), in: dirMem)
        let memoryQ = try HoldoutReviewQueue.load(csvURL: memURL)

        let dirDisk = try makeTempDir()
        let diskURL = try writeQueueCSV(csvText([
            "BBBB00000002,/v/eval/in_both.mov,,",
            "CCCC00000003,/v/eval/only_on_disk.mov,,",        // external edit added it
        ]), in: dirDisk)
        let diskQ = try HoldoutReviewQueue.load(csvURL: diskURL)

        let heldOutPaths = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: memoryQ, diskQueue: diskQ, discoveredQueue: nil)
        #expect(heldOutPaths == ["/v/eval/only_in_memory.mov",
                                 "/v/eval/in_both.mov",
                                 "/v/eval/only_on_disk.mov"])

        let records = heldOutPaths.map { makeRecord($0.replacingOccurrences(of: ".mov", with: "_donna.mov")) }
            + heldOutPaths.map { makeRecord($0) }
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: memoryQ, diskQueue: diskQ, discoveredQueue: nil,
            records: records)
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 5,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        #expect(Set(result.candidates.map(\.recordPath)).isDisjoint(with: heldOutPaths))
    }

    // (c) A queue load/reload failure FAILS CLOSED: the landing phase
    // forbids candidate loading entirely.
    @Test func blocker_queueLoadFailureFailsClosed() {
        let landing = ReviewSessionPolicy.phaseAfterQueueLoadFailure
        #expect(landing == .holdout)
        #expect(!ReviewSessionPolicy.mayLoadCandidates(in: landing),
                "the load-failure landing phase must forbid candidate scoring — fail closed, not open")
    }

    // (d) STRICTER-THAN-CODEX rule: even DURABLY-ANSWERED rows stay
    // excluded — positives AND zero-signal controls — because the sealed
    // eval set's paths must never enter validation labels (QA item-8:
    // sampler-seed contamination).
    @Test @MainActor func blocker_durablyAnsweredEvalRowsExcludedFromPositivesAndControls() throws {
        let dir = try makeTempDir()
        let url = try writeQueueCSV(csvText([
            "AAAA00000001,/v/eval/donna_done.mov,yes,clearly her",
            "BBBB00000002,/v/eval/plain_eval.mov,no,",
        ]), in: dir)
        let q = try HoldoutReviewQueue.load(csvURL: url)
        #expect(q.pendingCount == 0, "fixture drift — this test is about a FULLY ANSWERED queue")
        let heldOutPaths = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: nil, diskQueue: nil, discoveredQueue: q)

        // donna_done → would be a top positive; plain_eval → zero signal,
        // would be a near-certain control pick from this tiny pool.
        let records = [
            makeRecord("/v/eval/donna_done.mov"),
            makeRecord("/v/eval/plain_eval.mov"),
            makeRecord("/v/other/donna_free.mov"),
            makeRecord("/v/other/plain_free.mov"),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: nil, diskQueue: nil, discoveredQueue: q, records: records)
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 5,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        let outPaths = Set(result.candidates.map(\.recordPath))
        #expect(outPaths.isDisjoint(with: heldOutPaths),
                "durably-answered eval paths leaked into the round: \(outPaths.intersection(heldOutPaths))")
        #expect(outPaths.contains("/v/other/donna_free.mov"))
        // The free zero-signal record is the only legal control.
        let controls = result.candidates.filter { $0.signals == ["control"] }
        #expect(controls.map(\.recordPath) == ["/v/other/plain_free.mov"],
                "the control pool must exclude eval paths too")
    }

    // MARK: - 11. Content-identity exclusion (codex #39 — blindness is
    // about the MEDIA, not the pathname)

    /// One-row eval queue at /v/eval/…; helper for the alias tests.
    private func evalQueue(path: String) throws -> HoldoutReviewQueue {
        let dir = try makeTempDir()
        let url = try writeQueueCSV(csvText(["AAAA00000001,\(path),,"]), in: dir)
        return try HoldoutReviewQueue.load(csvURL: url)
    }

    // (39a) A byte-identical duplicate at a DIFFERENT path is excluded
    // from positives AND controls. This is ALSO the dedup-order-
    // independence pin: the eval path itself never enters the pool, so
    // the alias has no twin to collapse against — under path-only
    // exclusion it would have SURVIVED dedup and surfaced with a score.
    @Test @MainActor func codex39_byteIdenticalAliasAtDifferentPathIsExcluded() throws {
        let q = try evalQueue(path: "/Volumes/LaCie/eval/donna_park.mov")
        let records = [
            // The eval row's catalog record (carries the hash evidence).
            makeRecord("/Volumes/LaCie/eval/donna_park.mov", md5: "beefcafe01", size: 900),
            // Byte-identical copy on another volume, different pathname —
            // strong filename signal, would top the round if it leaked.
            makeRecord("/Volumes/X9/backup/donna_park_copy.mov", md5: "beefcafe01", size: 900),
            // Byte-identical ZERO-signal copy — would be a control pick.
            makeRecord("/Volumes/X9/backup/mvi_0042.mov", md5: "beefcafe01", size: 900),
            // Unrelated legitimate candidates.
            makeRecord("/v/other/donna_free.mov", md5: "0ddba11", size: 500),
            makeRecord("/v/other/plain_free.mov", md5: "f00dface", size: 400),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil, records: records)
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 5,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        let outPaths = Set(result.candidates.map(\.recordPath))
        #expect(!outPaths.contains("/Volumes/X9/backup/donna_park_copy.mov"),
                "byte-identical alias leaked into positives — blindness must follow content, not pathname")
        #expect(!outPaths.contains("/Volumes/X9/backup/mvi_0042.mov"),
                "byte-identical zero-signal alias leaked into the control pool")
        #expect(outPaths.contains("/v/other/donna_free.mov"))
        #expect(outPaths.contains("/v/other/plain_free.mov"))
    }

    // (39b) A duplicate-group sibling (DuplicateDetector verdict, e.g. a
    // transcode with a different hash) is excluded too.
    @Test @MainActor func codex39_duplicateGroupSiblingIsExcluded() throws {
        let group = UUID()
        let q = try evalQueue(path: "/Volumes/LaCie/eval/donna_lake.mov")
        let records = [
            makeRecord("/Volumes/LaCie/eval/donna_lake.mov", md5: "aaaa01", dgid: group, size: 700),
            // Same duplicate group, different bytes/size (transcoded copy).
            makeRecord("/Volumes/X10/transcodes/donna_lake_h264.mp4", md5: "bbbb02", dgid: group, size: 300),
            makeRecord("/v/other/donna_free.mov", size: 500),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil, records: records)
        #expect(heldOut.matches(path: "/Volumes/X10/transcodes/donna_lake_h264.mp4",
                                record: records[1]))
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 0,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        let outPaths = Set(result.candidates.map(\.recordPath))
        #expect(!outPaths.contains("/Volumes/X10/transcodes/donna_lake_h264.mp4"))
        #expect(outPaths.contains("/v/other/donna_free.mov"))
    }

    // (39c) Conservative fallback: no hash, no dup group — a same-stem,
    // same-size sibling (mirrors codex's sampler collapse rule) is still
    // excluded. Zero sizes are NOT identity evidence: two unhashed
    // size-0 records sharing a stem must NOT blanket-exclude each other.
    @Test @MainActor func codex39_stemSizeFallbackExcludes_butUnknownSizeDoesNot() throws {
        let q = try evalQueue(path: "/Volumes/LaCie/eval/donna_xmas.mov")
        let records = [
            makeRecord("/Volumes/LaCie/eval/donna_xmas.mov", size: 12_345),
            // Same stem + same size, different directory and extension case.
            makeRecord("/Volumes/X9/mirror/donna_xmas.MOV", size: 12_345),
            // Same stem, DIFFERENT size → legitimately different media.
            makeRecord("/v/other/donna_xmas.mov", size: 999),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil, records: records)
        #expect(heldOut.matches(path: records[1].fullPath, record: records[1]))
        #expect(!heldOut.matches(path: records[2].fullPath, record: records[2]))

        // Unknown-size guard: eval record with size 0 keys NOTHING on
        // stem+size — an unrelated size-0 record with the same stem stays.
        let q0 = try evalQueue(path: "/Volumes/LaCie/eval0/donna_beach.mov")
        let recs0 = [
            makeRecord("/Volumes/LaCie/eval0/donna_beach.mov", size: 0),
            makeRecord("/v/other/donna_beach.mov", size: 0),
        ]
        let held0 = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q0, diskQueue: nil, discoveredQueue: nil, records: recs0)
        #expect(!held0.matches(path: recs0[1].fullPath, record: recs0[1]),
                "size-0 records must not blanket-match by stem — over-exclusion here is unbounded")
        #expect(held0.matches(path: recs0[0].fullPath, record: recs0[0]),
                "the eval row itself is still excluded by exact path")
    }

    // (39d) RESIDUAL GAP, documented honestly: a held-out path with NO
    // catalog record contributes only its exact path — no identity can
    // be derived, so an un-cataloged-identity copy at another path is
    // NOT recognized. Exact-path exclusion must still hold.
    @Test @MainActor func codex39_catalogMissKeepsExactPathExclusion_residualGapDocumented() throws {
        let q = try evalQueue(path: "/Volumes/Unplugged/eval/donna_attic.mov")
        // The catalog has NO record for the eval path (catalog-miss) —
        // only an alias with no shared evidence, plus a free positive.
        let records = [
            makeRecord("/v/other/donna_attic_copy.mov", md5: "cccc03", size: 800),
            makeRecord("/v/other/donna_free.mov", size: 500),
        ]
        let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil, records: records)
        // Exact path still held (fed straight to the matcher)…
        #expect(heldOut.matches(path: "/Volumes/Unplugged/eval/donna_attic.mov", record: nil))
        // …and the RESIDUAL GAP is real: the alias is not recognizable
        // without catalog evidence for the eval path. This assertion is
        // the honest documentation — if identity derivation for
        // catalog-miss rows is ever added (e.g. hash-on-demand), flip it.
        #expect(!heldOut.matches(path: records[0].fullPath, record: records[0]),
                "catalog-miss alias unexpectedly matched — if hash-on-demand was added, update this documented gap")
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(name: "Donna", records: records,
                                    topN: 10, controlK: 0,
                                    alreadyLabeled: [], heldOut: heldOut,
                                    rng: &rng)
        #expect(!result.candidates.map(\.recordPath).contains("/Volumes/Unplugged/eval/donna_attic.mov"))
    }

    // MARK: Source-scan helpers

    /// Slice a member's body: from the declaration marker to the next
    /// top-level member/MARK at 4-space indent. Deliberately rough — this
    /// is a sensor, not a parser; if the file's layout changes enough to
    /// break the slice, the sensor fails and forces a look.
    private func memberBody(of source: String, from startMarker: String) -> Substring {
        guard let start = source.range(of: startMarker) else { return "" }
        let tail = source[start.upperBound...]
        let endMarkers = ["\n    private func ", "\n    private nonisolated",
                          "\n    private var ", "\n    func ", "\n    // MARK:"]
        let end = endMarkers.compactMap { tail.range(of: $0)?.lowerBound }.min()
            ?? tail.endIndex
        return tail[..<end]
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack[...]
        while let r = search.range(of: needle) {
            count += 1
            search = search[r.upperBound...]
        }
        return count
    }
}
