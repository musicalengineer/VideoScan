// HoldoutAnswerWriteChainTests.swift
// LOGIC + SCALE coverage for the serialized answer-write chain
// (fix/review-sheet-performance, 2026-07-26).
//
// ConfirmPersonSheet.holdoutAnswer moved the per-answer CSV
// read-modify-write off the main actor: each answer captures a VALUE
// snapshot of the queue and chains a Task onto the previous write
// (strict FIFO), and recordAnswer itself reloads the CSV fresh from
// disk as the merge base (the QA-gated 65fbfcf semantic — byte-identical
// HoldoutReviewQueue.swift, new call site). These tests exercise that
// exact pattern — snapshot → chained Task → recordAnswer-merges-onto-
// fresh-disk — through the public HoldoutReviewQueue API, because
// performAnswerWrite/holdoutWriteChain are private view internals.
// For Rick: this is the classic lost-update test from database land —
// N read-modify-writes must serialize, and the merge base must be the
// LIVE file, not the snapshot each writer happens to hold.
//
// Pins:
//   1. N rapid chained writes, ALL from one stale snapshot → the final
//      CSV contains ALL N answers (no lost update).
//   2. Last-writer-wins per row: re-answers through the chain leave the
//      LAST writer's state on the row, exactly once.
//   3. External-edit survival at the new call site: a hand edit landing
//      on disk between two chained stale-snapshot writes SURVIVES.
//   4. SCALE: chained writes against a 1k-row CSV stay inside a
//      per-write time envelope consistent with the suite's existing
//      scale budget (HoldoutReviewQueueTests: 100k-row load < 8 s).
//
// All I/O is per-test temp directories — the real review CSV is never
// touched (settings-pollution class).

import Foundation
import Testing
@testable import VideoScan

/// Thread-safe error collector — chained writer tasks report here so
/// the test can assert the whole chain succeeded (a swallowed throw
/// would silently fake a green "all answers landed").
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ error: Error, context: String) {
        lock.lock(); stored.append("\(context): \(error)"); lock.unlock()
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite("Holdout Answer Write Chain")
struct HoldoutAnswerWriteChainTests {

    // MARK: - Fixture helpers (same conventions as HoldoutReviewQueueTests)

    private func csvText(_ dataLines: [String]) -> String {
        (["reviewId,fullPath,rickConfirm(yes/no),notes"] + dataLines)
            .map { $0 + "\r\n" }.joined()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holdout-chain-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeCSV(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(HoldoutReviewQueue.csvFilename)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func rowId(_ i: Int) -> String { String(format: "R%04d", i) }

    /// N all-pending rows R0000…R{N-1}.
    private func pendingRowsCSV(count: Int) -> String {
        csvText((0..<count).map { "\(rowId($0)),/Volumes/T/v\($0).mov,," })
    }

    /// The production pattern, verbatim in shape: each write chains onto
    /// the previous task (strict FIFO) and operates on a VALUE copy of
    /// the snapshot — recordAnswer reloads disk as its merge base.
    private func chainWrite(previous: Task<Void, Never>?,
                            snapshot: HoldoutReviewQueue,
                            reviewId: String, confirm: String, notes: String,
                            errors: ErrorBox) -> Task<Void, Never> {
        Task {
            _ = await previous?.value   // strict FIFO across answers
            var q = snapshot            // stale value copy, like performAnswerWrite
            do {
                try q.recordAnswer(reviewId: reviewId, confirm: confirm, notes: notes)
            } catch {
                errors.record(error, context: reviewId)
            }
        }
    }

    // MARK: - 1. No lost update

    @Test func chain_rapidWritesFromOneStaleSnapshotAllLand() async throws {
        let n = 20
        let dir = try makeTempDir()
        let url = try writeCSV(pendingRowsCSV(count: n), in: dir)
        // ONE snapshot for every write — maximally stale by design. If
        // recordAnswer ever regressed to rewriting from snapshot memory,
        // every earlier answer would be clobbered and only the last
        // would survive.
        let snapshot = try HoldoutReviewQueue.load(csvURL: url)
        let errors = ErrorBox()

        var chain: Task<Void, Never>?
        for i in 0..<n {
            chain = chainWrite(previous: chain, snapshot: snapshot,
                               reviewId: rowId(i),
                               confirm: i.isMultiple(of: 2) ? "yes" : "no",
                               notes: "note \(i)",
                               errors: errors)
        }
        _ = await chain?.value

        #expect(errors.all.isEmpty, "chained writes threw: \(errors.all)")
        let final = try HoldoutReviewQueue.load(csvURL: url)
        #expect(final.pendingCount == 0, "lost update: \(final.pendingCount) of \(n) answers vanished")
        for i in 0..<n {
            #expect(final.rows[i].rickConfirm == (i.isMultiple(of: 2) ? "yes" : "no"))
            #expect(final.rows[i].notes == "note \(i)")
        }
    }

    // MARK: - 2. Last writer wins per row

    @Test func chain_reAnswersLeaveLastWritersStateExactlyOnce() async throws {
        let dir = try makeTempDir()
        let url = try writeCSV(pendingRowsCSV(count: 3), in: dir)
        let snapshot = try HoldoutReviewQueue.load(csvURL: url)
        let errors = ErrorBox()

        // Five rapid answers to the SAME row (Back-and-re-answer spam),
        // then one to a different row, all through the chain.
        var chain: Task<Void, Never>?
        for pass in 0..<5 {
            chain = chainWrite(previous: chain, snapshot: snapshot,
                               reviewId: rowId(0),
                               confirm: pass.isMultiple(of: 2) ? "yes" : "no",
                               notes: "pass \(pass)",
                               errors: errors)
        }
        chain = chainWrite(previous: chain, snapshot: snapshot,
                           reviewId: rowId(2), confirm: "yes", notes: "other row",
                           errors: errors)
        _ = await chain?.value

        #expect(errors.all.isEmpty, "chained writes threw: \(errors.all)")
        let final = try HoldoutReviewQueue.load(csvURL: url)
        #expect(final.rows.count == 3, "re-answers must edit in place, never duplicate rows")
        // Last writer (pass 4: even → yes) owns the row.
        #expect(final.rows[0].rickConfirm == "yes")
        #expect(final.rows[0].notes == "pass 4")
        #expect(final.rows[1].isPending)          // untouched row untouched
        #expect(final.rows[2].rickConfirm == "yes")
        #expect(final.rows[2].notes == "other row")
    }

    // MARK: - 3. External-edit survival (65fbfcf semantic, new call site)

    @Test func chain_staleSnapshotWritePreservesExternalHandEdit() async throws {
        let dir = try makeTempDir()
        let url = try writeCSV(csvText([
            "AAAA00000001,/Volumes/T/a.mov,,",
            "BBBB00000002,/Volumes/T/b.mov,,",
            "CCCC00000003,/Volumes/T/c.mov,,",
        ]), in: dir)
        // Snapshot taken BEFORE everything below — both chained writes
        // use it stale.
        let snapshot = try HoldoutReviewQueue.load(csvURL: url)
        let errors = ErrorBox()

        // Answer row A through the chain.
        var chain: Task<Void, Never>? = chainWrite(
            previous: nil, snapshot: snapshot,
            reviewId: "AAAA00000001", confirm: "no", notes: "not her",
            errors: errors)
        _ = await chain?.value

        // Behind the app's back: a HAND EDIT gives row B notes on disk
        // (still pending — notes only, exactly what an editor tweak or
        // codex tooling annotation looks like).
        let text = try String(contentsOf: url, encoding: .utf8)
        let edited = text.replacingOccurrences(
            of: "BBBB00000002,/Volumes/T/b.mov,,",
            with: "BBBB00000002,/Volumes/T/b.mov,,edited externally")
        #expect(edited != text, "fixture drift — the external-edit row was not found")
        try Data(edited.utf8).write(to: url)

        // Answer row C via the STALE snapshot (predates A's answer AND
        // the hand edit). recordAnswer must merge onto fresh disk state.
        chain = chainWrite(previous: chain, snapshot: snapshot,
                           reviewId: "CCCC00000003", confirm: "yes", notes: "porch",
                           errors: errors)
        _ = await chain?.value

        #expect(errors.all.isEmpty, "chained writes threw: \(errors.all)")
        let final = try HoldoutReviewQueue.load(csvURL: url)
        // The hand edit SURVIVES the stale-snapshot write...
        #expect(final.rows[1].notes == "edited externally",
                "stale-snapshot chained write clobbered an external edit — 65fbfcf semantic broken at the new call site")
        #expect(final.rows[1].isPending)   // notes-only edit stays pending
        // ...and both chained answers are recorded.
        #expect(final.rows[0].rickConfirm == "no")
        #expect(final.rows[0].notes == "not her")
        #expect(final.rows[2].rickConfirm == "yes")
        #expect(final.rows[2].notes == "porch")
    }

    // MARK: - 4. Scale (checklist dimension 2)

    @Test func scale_chainedWritesOn1kRowCSVStayInTimeEnvelope() async throws {
        // Every write re-parses and re-serializes the whole 1k-row CSV
        // (that IS the merge-onto-fresh-disk design). Envelope: 50
        // chained writes < 5 s total — 100 ms per read-modify-write of
        // a 1k-row file, proportionate to the suite's existing budget
        // (100k-row load < 8 s in HoldoutReviewQueueTests). If this
        // trips, per-answer cost has blown up and the review pane will
        // feel it on every click.
        let rows = 1_000
        let writes = 50
        let dir = try makeTempDir()
        let url = try writeCSV(pendingRowsCSV(count: rows), in: dir)
        let snapshot = try HoldoutReviewQueue.load(csvURL: url)
        let errors = ErrorBox()

        let clock = ContinuousClock()
        let start = clock.now
        var chain: Task<Void, Never>?
        for i in 0..<writes {
            chain = chainWrite(previous: chain, snapshot: snapshot,
                               reviewId: rowId(i), confirm: "yes",
                               notes: "scale \(i)", errors: errors)
        }
        _ = await chain?.value
        let elapsed = clock.now - start

        #expect(errors.all.isEmpty, "chained writes threw: \(errors.all)")
        #expect(elapsed < .seconds(5),
                "\(writes) chained writes over \(rows) rows took \(elapsed) — per-answer cost has regressed")
        let final = try HoldoutReviewQueue.load(csvURL: url)
        #expect(final.pendingCount == rows - writes)
        for i in 0..<writes {
            #expect(final.rows[i].notes == "scale \(i)")
        }
    }
}
