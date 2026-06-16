// ValidationLabelStore.swift
// Disk-backed accumulator for ValidationLabel rows. Lives next to the
// catalog in Application Support so it's discoverable and survives app
// reinstalls. Append-only writeback model — each label appends one row
// and persists immediately (one JSON file rewrite per label, atomic).
// At Rick's scale (single user, ~10-100 labels per round) the file
// stays a few KB and the rewrite is cheap.
//
// Future swap path: if the file grows past ~5MB (~50k labels) we
// switch the on-disk format to JSONL (one row per line, append-only).
// The Swift API stays the same.
//
// Rick 2026-06-16.

import Combine
import Foundation
import os

private let validationLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "confirm.validation"
)

@MainActor
final class ValidationLabelStore: ObservableObject {

    /// All labels persisted, newest-last. Source of truth across the
    /// process; mutations always flush to disk before returning.
    @Published private(set) var labels: [ValidationLabel] = []

    /// On-disk location. Defaults to next to catalog.json. Tests pass
    /// a temp directory.
    let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.fileURL = dir.appendingPathComponent("validation_labels.json")
        load()
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("VideoScan", isDirectory: true)
    }

    // MARK: - Load / Save

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ValidationLabel].self, from: data) {
            labels = decoded
            validationLog.info("Loaded \(decoded.count) validation labels")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(labels)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            validationLog.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Public API

    /// Append a label and persist. Returns the row that was written
    /// (with id assigned).
    @discardableResult
    func record(
        recordPath: String,
        person: String,
        rating: ConfirmRating,
        signals: [String],
        score: Int
    ) -> ValidationLabel {
        let row = ValidationLabel(
            id: UUID(),
            recordPath: recordPath,
            person: person,
            rating: rating,
            labeledAt: Date(),
            signals: signals,
            score: score
        )
        labels.append(row)
        save()
        return row
    }

    /// Map of (recordPath → most recent rating) for a given person.
    /// Used by the Confirm sheet to skip records already labeled in a
    /// prior round (idempotency).
    func labeledByPath(for person: String) -> [String: ValidationLabel] {
        let target = person.lowercased()
        var out: [String: ValidationLabel] = [:]
        for row in labels where row.person.lowercased() == target {
            // newest wins (labels appended in order)
            out[row.recordPath] = row
        }
        return out
    }

    /// Convenience for the summary report.
    func roundSummary(for person: String, since: Date) -> RoundSummary {
        let target = person.lowercased()
        let rows = labels.filter {
            $0.person.lowercased() == target && $0.labeledAt >= since
        }
        var counts: [ConfirmRating: Int] = [:]
        var signalsByPositive: [String: Int] = [:]
        for r in rows {
            counts[r.rating, default: 0] += 1
            if r.rating.writebackTier != .none {
                for s in r.signals {
                    signalsByPositive[s, default: 0] += 1
                }
            }
        }
        return RoundSummary(
            total: rows.count,
            counts: counts,
            signalsByPositive: signalsByPositive
        )
    }

    struct RoundSummary {
        let total: Int
        /// Distribution across rating levels.
        let counts: [ConfirmRating: Int]
        /// For the .definitely + .likely subset: which catalog signals
        /// flagged the videos the user ended up confirming? Answers
        /// "where is the catalog metadata actually right?"
        let signalsByPositive: [String: Int]
    }
}
