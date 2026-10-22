// AvidPairRelease.swift
// THE door through which stored A/V pairs are released on Avid evidence
// (AvidPairEvidence: a render, an MXF video's non-MXF partner, two
// different clip names). Two callers: the launch (after the committer's
// baseline, so the launch commit writes the release) and Fill In Avid IDs
// (after the IDs are read). Rick 2026-10-22: he must be able to SEE and
// UNDO the releases, so, in this order:
//
//   1. PLAN     — CorrelationScorer.releaseInvalidPairs(dryRun:): what would
//                 go, nothing cleared. Nothing to release → nothing happens
//                 (no copy, no journal line).
//   2. SAFETY COPY — the existing safety-copy path
//                 (VideoScanModel.snapshotCatalog → a sealed
//                 `catalog.pre-pair-release.<stamp>.sqlite` beside the
//                 catalog, written with the writer held). It fails →
//                 NOTHING is released, and the log says so. Degraded = hold.
//   3. JOURNAL  — one JSON line per pair appended to
//                 ~/Library/Logs/VideoScan/pair-releases/released-pairs.jsonl
//                 (the receipts' home, beside deletions/): the time, both
//                 paths, both clip names and UMIDs, the reason, and the
//                 safety copy that holds the links. It fails → hold.
//   4. RELEASE  — the links cleared on both rows (catalog only; no media
//                 file is moved, deleted or edited), one log line per pair,
//                 the OUTCOME line naming the journal and the copy.
//
// (For Rick: an enum with no cases ≈ a C++ namespace of free functions.)

import Foundation

/// One journal line (Codable → one JSON object per line).
struct PairReleaseJournalLine: Codable, Equatable, Sendable {
    let at: Date
    let context: String
    let reason: String
    let video: CorrelationScorer.ReleasedPair.Side
    let audio: CorrelationScorer.ReleasedPair.Side
    let safetyCopy: String
}

enum AvidPairRelease {

    enum Outcome: Equatable {
        case nothingToRelease
        /// Nothing was released, and why.
        case held(String)
        case released([CorrelationScorer.ReleasedPair], journal: URL, safetyCopy: String)
    }

    /// ~/Library/Logs/VideoScan/pair-releases/released-pairs.jsonl — under a
    /// test host, a per-process scratch folder (no test writes Rick's logs).
    static var defaultJournalURL: URL {
        let dir: URL
        if TestEnvironment.isTestHost {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/pair-releases-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/VideoScan/pair-releases", isDirectory: true)
        }
        return dir.appendingPathComponent("released-pairs.jsonl")
    }

    /// Plan → safety copy → journal → release (see the header). `safetyCopy`
    /// and `journal` are seams; production passes the model's safety-copy
    /// path and the default journal.
    @MainActor
    static func release(in model: VideoScanModel, context: String,
                        safetyCopy: () -> String?,
                        journal: URL = AvidPairRelease.defaultJournalURL,
                        now: Date = Date(),
                        sink: (String) -> Void) -> Outcome {
        let plan = CorrelationScorer.releaseInvalidPairs(in: model.records, dryRun: true)
        guard !plan.released.isEmpty else { return .nothingToRelease }
        let n = plan.released.count
        guard let copy = safetyCopy() else {
            let why = "the safety copy of the catalog could not be made"
            sink("HELD \(n) stored A/V pair release(s) \(context) — \(why); NOTHING was released. Run again when the catalog can be copied.")
            return .held(why)
        }
        let lines = plan.released.map {
            PairReleaseJournalLine(at: now, context: context, reason: $0.reason, video: $0.video, audio: $0.audio, safetyCopy: copy)
        }
        if let why = append(lines, to: journal) {
            sink("HELD \(n) stored A/V pair release(s) \(context) — the journal \(journal.path) could not be written (\(why)); "
                 + "NOTHING was released (safety copy \(copy) kept).")
            return .held(why)
        }
        let outcome = CorrelationScorer.releaseInvalidPairs(in: model.records)
        let head = "OUTCOME released \(outcome.released.count) stored A/V pair(s) \(context) "
            + "(\(outcome.clearedEndpoints) link end(s) cleared; catalog only — no media touched) · journal \(journal.path) · safety copy \(copy)"
        sink(([head] + outcome.released.map { "  " + $0.line }).joined(separator: "\n"))
        if outcome.clearedEndpoints > 0 { model.noteCatalogRecordsMutated() }
        return .released(outcome.released, journal: journal, safetyCopy: copy)
    }

    /// Append the lines (one JSON object each) in ONE write; nil = written,
    /// else the reason. Never truncates: the journal only grows.
    static func append(_ lines: [PairReleaseJournalLine], to url: URL) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            var data = Data()
            for line in lines {
                data.append(try encoder.encode(line))
                data.append(0x0A)
            }
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { return "the file could not be created" }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
