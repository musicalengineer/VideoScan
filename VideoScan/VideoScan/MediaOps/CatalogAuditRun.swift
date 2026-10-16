// CatalogAuditRun.swift
// "When did the catalog's presence last get checked, and how did it go?"
// (Rick 2026-10-16, Catalog Status freshness §2/§6).
//
// The audit keeps NO per-record stamp. What it keeps is one small marker,
// `catalog-audit.json` beside catalog.json (FullHashBackfillResume's
// pattern), written when a run starts and rewritten at each acknowledged
// checkpoint and at the end: when it started, when it finished, the counts,
// the outcome word and whether it was partial. The File Presence row of
// the Catalog Status panel reads it for its date and colour.
//
// Per catalog (the marker lives in the catalog's folder), so a test
// catalog in a scratch directory never sees the real one. A missing,
// damaged or newer-schema marker is read-only noise: `lastRun` is nil, no
// line is written, nothing starts and no record is touched.
//
// The only file this type writes is that marker, through AtomicFilePublish
// — never beside media. (MOPS-14.)

import Combine
import Foundation
import VideoScanCore

/// What the marker file holds.
struct CatalogAuditRunRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case running, completed, stopped, failed, refused }

    var startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome = .running
    /// True when the run did not ask every planned row (stopped or failed).
    var partial = false
    /// Result word → count, as `CatalogAuditResult.rawValue` (and the
    /// skipped total under "skipped").
    var counts: [String: Int] = [:]
    /// Rows the run changed and whose save was acknowledged.
    var marked = 0

    var isFinished: Bool { finishedAt != nil }
}

@MainActor
final class CatalogAuditRunMarker: ObservableObject {

    static let fileName = "catalog-audit.json"

    /// The last run the marker knows (nil = never ran, or unreadable).
    @Published private(set) var lastRun: CatalogAuditRunRecord?
    private var current: CatalogAuditRunRecord?
    private(set) var fileURL: URL?

    init() {}

    /// Point at the catalog in use (its catalog.json path) and read what
    /// the last run left. Returns it, if readable.
    @discardableResult
    func attach(catalogFile: String) -> CatalogAuditRunRecord? {
        let url = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        fileURL = url
        lastRun = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(CatalogAuditRunRecord.self, from: $0) }
        return lastRun
    }

    func noteStarted(at date: Date = Date()) {
        current = CatalogAuditRunRecord(startedAt: date)
        persist()
    }

    /// At each acknowledged checkpoint — so a crash still leaves "how far".
    func noteSaved(totals: CatalogAuditTotals, marked: Int) {
        guard current != nil else { return }
        current?.counts = Self.counts(totals)
        current?.marked = marked
        persist()
    }

    /// The run ended. `partial` = not every planned row was asked.
    func noteFinished(_ outcome: CatalogAuditRunRecord.Outcome, totals: CatalogAuditTotals, marked: Int,
                      partial: Bool, at date: Date = Date()) {
        guard current != nil else { return }
        current?.counts = Self.counts(totals)
        current?.marked = marked
        current?.outcome = outcome
        current?.partial = partial
        current?.finishedAt = date
        persist()
        lastRun = current
    }

    /// The marker's counts: every result with a count, plus "skipped".
    nonisolated static func counts(_ totals: CatalogAuditTotals) -> [String: Int] {
        var out: [String: Int] = [:]
        for (r, n) in totals.counts where n > 0 { out[r.rawValue] = n }
        if totals.skippedCount > 0 { out["skipped"] = totals.skippedCount }
        out["planned"] = totals.planned
        return out
    }

    /// At launch: read the marker beside this catalog and, when the last
    /// run has something to say (files gone, or a run that did not finish),
    /// write that one line through the audit's sink. Nothing starts; a
    /// missing or damaged marker says nothing.
    func announceLastRun(to model: VideoScanModel?) {
        guard let model, let last = attach(catalogFile: model.catalogStore.fileLocation),
              let line = Self.launchLine(last) else { return }
        model.catalogAuditNote(line)
    }

    /// The launch line for the last run (nil when none).
    nonisolated static func launchLine(_ r: CatalogAuditRunRecord) -> String? {
        let started = r.startedAt.formatted(date: .abbreviated, time: .shortened)
        switch r.outcome {
        case .completed:
            let gone = r.counts[CatalogAuditResult.gone.rawValue] ?? 0
            let archived = r.counts[CatalogAuditResult.goneArchived.rawValue] ?? 0
            let unseen = r.counts[CatalogAuditResult.neverSeenByAnAudit.rawValue] ?? 0
            guard gone + archived + unseen > 0 else { return nil }
            return "Audit catalog: the run of \(started) found \(gone.formatted()) file(s) gone (marked Missing)"
                + (archived > 0 ? " and \(archived.formatted()) archive copy(ies) not at their path" : "")
                + (unseen > 0 ? " and \(unseen.formatted()) file(s) not at their path that no audit had seen before (not marked — Fix Links decides)" : "")
                + " — the Catalog Status panel lists them."
        case .running:
            return "Audit catalog: the run started \(started) did not finish (quit or crash) — marks saved before that are kept; run Catalog ▸ Audit Catalog… again."
        case .stopped, .failed:
            return "Audit catalog: the run of \(started) \(r.outcome.rawValue) (partial) — run Catalog ▸ Audit Catalog… again."
        case .refused:
            return nil
        }
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
