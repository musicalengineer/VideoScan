// UnifiedReviewAdversarialTests.swift
// Adversarial regression coverage for the blind-holdout/candidate boundary.
//
// These tests exercise the same pure seam used by ConfirmPersonSheet:
// ReviewSessionPolicy.heldOutExclusionPaths(...) -> pfConfirmRound(...).
// They deliberately avoid real review data and global state.

import Foundation
import Testing
@testable import VideoScan

@Suite("Unified Review Adversarial Isolation")
struct UnifiedReviewAdversarialTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-review-adversarial-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func queue(_ rows: [String], in directory: URL) throws -> HoldoutReviewQueue {
        let csv = (["reviewId,fullPath,rickConfirm(yes/no),notes"] + rows)
            .map { $0 + "\r\n" }
            .joined()
        let url = directory.appendingPathComponent(HoldoutReviewQueue.csvFilename)
        try Data(csv.utf8).write(to: url)
        return try HoldoutReviewQueue.load(csvURL: url)
    }

    @MainActor
    private func record(_ path: String, personSignal: Bool,
                        partialMD5: String = "") -> VideoRecord {
        let rec = VideoRecord()
        rec.fullPath = path
        rec.filename = personSignal
            ? "donna_\((path as NSString).lastPathComponent)"
            : (path as NSString).lastPathComponent
        rec.directory = (path as NSString).deletingLastPathComponent
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.durationSeconds = 60
        rec.partialMD5 = partialMD5
        return rec
    }

    @MainActor
    private func candidatePaths(
        records: [VideoRecord],
        heldOut: Set<String>,
        topN: Int = 100,
        controlK: Int = 100
    ) -> (all: Set<String>, positives: Set<String>, controls: Set<String>, stats: ConfirmRoundStats) {
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna",
            records: records,
            topN: topN,
            controlK: controlK,
            alreadyLabeled: [],
            heldOutPaths: heldOut,
            isReachable: { _ in true },
            rng: &rng
        )
        let positives = Set(result.candidates
            .filter { $0.signals != ["control"] }
            .map(\.recordPath))
        let controls = Set(result.candidates
            .filter { $0.signals == ["control"] }
            .map(\.recordPath))
        return (Set(result.candidates.map(\.recordPath)), positives, controls, result.stats)
    }

    @Test @MainActor
    func allQueueViewsAndAnswerStatesStayOutOfPositivesAndControls() throws {
        // Session view: the first row was skipped and remains pending; the
        // second is the optimistic/in-flight row, which is also pending until
        // its serialized CSV write commits.
        let session = try queue([
            "AAAA00000001,/v/eval/donna_skipped.mov,,",
            "BBBB00000002,/v/eval/plain_in_flight.mov,,",
            "BBBB00000003,/v/eval/plain_variant.mov,,",
        ], in: makeTempDir())

        // Fresh disk view: includes a pending row restored after a failed
        // write and a durably answered eval row. Full-queue custody excludes
        // both states.
        let disk = try queue([
            "CCCC00000003,/v/eval/donna_write_failed.mov,,",
            "DDDD00000004,/v/eval/plain_answered.mov,yes,clear view",
        ], in: makeTempDir())

        // Discovery may carry a representation absent from the open sheet.
        // Include a standardized-path spelling too: exact path variants are
        // safe when any active queue view actually carries each spelling.
        let discovered = try queue([
            "EEEE00000005,/v/eval/donna_discovered.mov,no,not her",
            "FFFFFFFF0006,/v/eval/sub/../plain_variant.mov,,",
        ], in: makeTempDir())

        let heldOut = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: session,
            diskQueue: disk,
            discoveredQueue: discovered
        )
        let expectedHeldOut: Set<String> = [
            "/v/eval/donna_skipped.mov",
            "/v/eval/plain_in_flight.mov",
            "/v/eval/plain_variant.mov",
            "/v/eval/donna_write_failed.mov",
            "/v/eval/plain_answered.mov",
            "/v/eval/donna_discovered.mov",
            "/v/eval/sub/../plain_variant.mov",
        ]
        #expect(heldOut == expectedHeldOut)

        let records = [
            record("/v/eval/donna_skipped.mov", personSignal: true),
            record("/v/eval/plain_in_flight.mov", personSignal: false),
            record("/v/eval/plain_variant.mov", personSignal: false),
            record("/v/eval/donna_write_failed.mov", personSignal: true),
            record("/v/eval/plain_answered.mov", personSignal: false),
            record("/v/eval/donna_discovered.mov", personSignal: true),
            record("/v/eval/sub/../plain_variant.mov", personSignal: false),
            record("/v/free/free_positive.mov", personSignal: true),
            record("/v/free/free_control.mov", personSignal: false),
        ]
        let output = candidatePaths(records: records, heldOut: heldOut)

        #expect(output.all.isDisjoint(with: heldOut),
                "active eval paths leaked into the candidate round: \(output.all.intersection(heldOut))")
        #expect(output.positives == ["/v/free/free_positive.mov"])
        #expect(output.controls == ["/v/free/free_control.mov"])
        #expect(output.stats.heldOutExcluded == 3,
                "heldOutExcluded counts scored eval rows; zero-signal control exclusions are intentionally not part of this counter")
    }

    @Test @MainActor
    func actualAnswerWriteFailureLeavesPathExcludedWhenRowReturnsToPending() throws {
        let directory = try makeTempDir()
        var q = try queue([
            "AAAA00000001,/v/eval/donna_failed_write.mov,,",
        ], in: directory)
        let csvURL = q.csvURL

        // Replace the CSV file with a directory. recordAnswer's fresh disk
        // reload must fail before commit, leaving the in-memory row pending.
        let savedURL = directory.appendingPathComponent("saved.csv")
        try FileManager.default.moveItem(at: csvURL, to: savedURL)
        try FileManager.default.createDirectory(at: csvURL,
                                                withIntermediateDirectories: false)
        #expect(throws: Error.self) {
            try q.recordAnswer(reviewId: "AAAA00000001", confirm: "yes", notes: "")
        }
        #expect(q.rows[0].isPending)

        let heldOut = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil)
        let output = candidatePaths(
            records: [
                record("/v/eval/donna_failed_write.mov", personSignal: true),
                record("/v/free/free_positive.mov", personSignal: true),
            ],
            heldOut: heldOut,
            controlK: 0
        )
        #expect(!output.all.contains("/v/eval/donna_failed_write.mov"))
        #expect(output.positives == ["/v/free/free_positive.mov"])
    }

    /// Intentional RED regression on 31f27bb.
    ///
    /// A different path carrying the same stable content identity as a sealed
    /// eval row is still the same video. Showing that copy as either a scored
    /// positive or a zero-signal control lets the reviewer watch/model-prime
    /// the blind item through an alias. Exact-path exclusion is therefore not
    /// sufficient; the production seam must also communicate held-out content
    /// identities into round assembly.
    @Test @MainActor
    func red_contentIdenticalAliasesCannotEnterPositivesOrControls() throws {
        let q = try queue([
            "AAAA00000001,/v/eval/donna_original.mov,,",
            "BBBB00000002,/v/eval/plain_original.mov,,",
        ], in: makeTempDir())
        let heldOut = ReviewSessionPolicy.heldOutExclusionPaths(
            sessionQueue: q, diskQueue: nil, discoveredQueue: nil)

        let positiveIdentity = "eval-positive-content-id"
        let controlIdentity = "eval-control-content-id"
        let positiveAlias = "/v/copy/donna_alias.mov"
        let controlAlias = "/v/copy/plain_alias.mov"
        let records = [
            record("/v/eval/donna_original.mov", personSignal: true,
                   partialMD5: positiveIdentity),
            record(positiveAlias, personSignal: true,
                   partialMD5: positiveIdentity),
            record("/v/eval/plain_original.mov", personSignal: false,
                   partialMD5: controlIdentity),
            record(controlAlias, personSignal: false,
                   partialMD5: controlIdentity),
            record("/v/free/free_positive.mov", personSignal: true,
                   partialMD5: "free-positive"),
            record("/v/free/free_control.mov", personSignal: false,
                   partialMD5: "free-control"),
        ]

        // controlK exceeds the legal pool, so selection is deterministic:
        // every control-eligible record is returned. No random seed can mask
        // an alias leak.
        let output = candidatePaths(records: records, heldOut: heldOut,
                                    topN: 10, controlK: 10)
        let contentAliases: Set<String> = [positiveAlias, controlAlias]

        #expect(output.all.isDisjoint(with: contentAliases),
                "sealed eval content leaked through duplicate paths: \(output.all.intersection(contentAliases)); held-out identity must extend beyond exact path")
        #expect(output.positives == ["/v/free/free_positive.mov"])
        #expect(output.controls == ["/v/free/free_control.mov"])
    }

    @Test @MainActor
    func corruptReloadFailsClosedWithoutTouchingValidationLabels() throws {
        let queueDirectory = try makeTempDir()
        let snapshot = try queue([
            "AAAA00000001,/v/eval/donna_blind.mov,,",
        ], in: queueDirectory)

        let labelsDirectory = try makeTempDir()
        let labels = ValidationLabelStore(directory: labelsDirectory)
        labels.record(recordPath: "/v/free/already_labeled.mov", person: "Donna",
                      rating: .likely, signals: ["filename"], score: 10)
        let labelBytesBefore = try Data(contentsOf: labels.fileURL)

        // Poison the file after discovery, matching startHoldout's
        // freshCopyFromDisk failure window.
        try Data([0xFF, 0xFE, 0x00, 0x81]).write(to: snapshot.csvURL)
        #expect(throws: Error.self) {
            _ = try snapshot.freshCopyFromDisk()
        }

        let landing = ReviewSessionPolicy.phaseAfterQueueLoadFailure
        #expect(landing == .holdout)
        #expect(!ReviewSessionPolicy.mayLoadCandidates(in: landing),
                "an unreadable blind queue must not enter the scorer")
        #expect(try Data(contentsOf: labels.fileURL) == labelBytesBefore,
                "queue reload failure altered validation labels")
    }

    @Test @MainActor
    func scale_100kRecordsWith50kHeldOutStaysDisjointWithinBudget() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var heldOut = Set<String>()
        heldOut.reserveCapacity(50_000)
        var expectedHeldOutSignals = 0

        for i in 0..<100_000 {
            let hasSignal = i.isMultiple(of: 99)
            let filename = hasSignal ? "donna_\(i).mov" : "clip_\(i).mov"
            let path = "/v/scale/\(i / 1000)/\(filename)"
            records.append(record(path, personSignal: false))
            if i.isMultiple(of: 2) {
                heldOut.insert(path)
                if hasSignal { expectedHeldOutSignals += 1 }
            }
        }

        let clock = ContinuousClock()
        var output: (all: Set<String>, positives: Set<String>, controls: Set<String>, stats: ConfirmRoundStats)?
        let elapsed = clock.measure {
            output = candidatePaths(records: records, heldOut: heldOut,
                                    topN: 100, controlK: 100)
        }

        #expect(elapsed < .seconds(12),
                "100k records + 50k blind exclusions took \(elapsed)")
        #expect(output?.all.isDisjoint(with: heldOut) == true)
        #expect(output?.positives.count == 100)
        #expect(output?.controls.count == 100)
        #expect(output?.stats.heldOutExcluded == expectedHeldOutSignals)
    }
}
