// FullHashBackfillResume.swift
// "Did the last Fill In Full Hashes run finish?" (Rick 2026-10-11).
//
// The WORK needs no resume bookkeeping: a record whose full hash was saved
// is skipped by the next plan, so starting again continues where the last
// run stopped. What this file adds is the HONEST OFFER: a small marker,
// `fullhash-backfill.json` beside catalog.json, written when a run starts
// and stamped finished when it completes. At launch an unfinished marker
// produces one console/log line and turns the Catalog menu item into
// "Resume Filling In Full Hashes…". Nothing auto-starts.
//
// Per catalog (the marker lives in the catalog's folder), so a test
// catalog in a scratch directory never sees the real one.
//
// The only file this type writes is that marker, in Application Support
// (or the test catalog's scratch folder) — never beside media.
//
// (For Rick: `ObservableObject` + `@Published` ≈ a C++ subject in the
// observer pattern — SwiftUI views holding it re-render when `unfinished`
// changes, so the menu title follows it.)

import Combine
import Foundation
import VideoScanCore

/// What the marker file holds.
struct FullHashBackfillRunRecord: Codable, Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date?
    /// Hashes saved by the run when the marker was last written.
    var hashedSoFar: Int = 0

    var isFinished: Bool { finishedAt != nil }
}

@MainActor
final class FullHashBackfillResumeMarker: ObservableObject {

    static let fileName = "fullhash-backfill.json"

    /// Non-nil when the last run started and did not finish.
    @Published private(set) var unfinished: FullHashBackfillRunRecord?
    private var current: FullHashBackfillRunRecord?
    private(set) var fileURL: URL?

    init() {}

    /// Point at the catalog in use (its catalog.json path) and read what
    /// the last run left. Returns the unfinished run, if any.
    @discardableResult
    func attach(catalogFile: String) -> FullHashBackfillRunRecord? {
        let url = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        fileURL = url
        let record = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(FullHashBackfillRunRecord.self, from: $0) }
        unfinished = record?.isFinished == false ? record : nil
        return unfinished
    }

    /// The menu title: "Resume…" while the last run is unfinished.
    var menuTitle: String {
        unfinished == nil ? "Fill In Full Hashes…" : "Resume Filling In Full Hashes…"
    }

    func noteStarted(at date: Date = Date()) {
        current = FullHashBackfillRunRecord(startedAt: date)
        persist()
    }

    /// At each acknowledged checkpoint — so the launch line can say how
    /// far the interrupted run got.
    func noteSaved(hashedSoFar: Int) {
        guard current != nil else { return }
        current?.hashedSoFar = hashedSoFar
        persist()
    }

    /// The run reached its end (stopped or failed runs stay unfinished).
    func noteFinished(hashed: Int, at date: Date = Date()) {
        guard current != nil else { return }
        current?.hashedSoFar = hashed
        current?.finishedAt = date
        persist()
        unfinished = nil
    }

    /// The run ended without finishing: offer Resume from now on.
    func noteUnfinished() {
        if let current { unfinished = current }
    }

    /// The launch line for an unfinished run.
    nonisolated static func launchLine(_ r: FullHashBackfillRunRecord) -> String {
        let started = r.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "Fill in full hashes: the run started \(started) did not finish (\(r.hashedSoFar.formatted()) hashes saved). "
            + "Catalog ▸ Resume Filling In Full Hashes… continues where it stopped; nothing was started."
    }

    private func persist() {
        guard let fileURL, let current, let data = try? Self.encoder.encode(current) else { return }
        try? AtomicFilePublish.write(data, to: fileURL, durability: .fast)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
