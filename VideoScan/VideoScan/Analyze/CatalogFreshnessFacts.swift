// CatalogFreshnessFacts.swift
// The NON-RECORD facts the Catalog Status band needs (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §2–§3): what the last
// Audit Catalog run left in `catalog-audit.json`, and whether the sound
// fingerprint sidecar can be opened at all. Both are read OFF the main
// actor, in the same detached pass that computes AnalyzeCoverageReport —
// one small JSON and one SQLite open per debounced catalog change, never
// per record and never in a view body.
//
// Read-only: a missing, damaged or newer-schema marker reads as "never
// ran"; a sidecar that refuses to open reads as a red row with the
// store's own words. Nothing here writes, starts or marks anything.
//
// (For Rick: `nonisolated static` functions on an enum ≈ free functions
// in a namespace; `Sendable` structs ≈ plain-old-data safe to hand across
// threads.)

import Foundation
import VideoScanCore

/// What the summary band learns from outside the catalog records.
struct CatalogFreshnessFacts: Sendable, Equatable {
    /// The last Audit Catalog run (nil = never, or the marker is unreadable).
    var audit: CatalogAuditRunRecord?
    /// Words from the sound sidecar when it cannot be opened; nil = fine
    /// (or not created yet — nothing stored is not a fault).
    var soundStoreProblem: String?

    init(audit: CatalogAuditRunRecord? = nil, soundStoreProblem: String? = nil) {
        self.audit = audit
        self.soundStoreProblem = soundStoreProblem
    }
}

enum CatalogFreshnessFactsReader {

    /// Read both facts for the catalog at `catalogFile` (its catalog.json
    /// path). Safe off the main actor; never throws.
    nonisolated static func read(catalogFile: String) -> CatalogFreshnessFacts {
        let folder = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
        return CatalogFreshnessFacts(audit: auditRecord(in: folder),
                                     soundStoreProblem: soundStoreProblem(in: folder))
    }

    // MARK: Audit marker

    /// The marker's name — the same string CatalogAuditRunMarker.fileName
    /// holds (that one is main-actor bound; CatalogFreshnessFactsTests pins
    /// the two equal), spelled here so the read can run off the main actor.
    nonisolated static let auditMarkerFileName = "catalog-audit.json"

    /// Decode `catalog-audit.json` beside the catalog. Garbage, a missing
    /// file or a newer schema → nil (never ran), never a crash.
    nonisolated static func auditRecord(in folder: URL) -> CatalogAuditRunRecord? {
        let url = folder.appendingPathComponent(auditMarkerFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CatalogAuditRunRecord.self, from: data)
    }

    /// Same decoder shape as CatalogAuditRunMarker's (ISO-8601 dates).
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Sound sidecar

    /// Try to open the sidecar the way the fingerprint job will. A file
    /// that does not exist yet is not a problem (the first run creates
    /// it) — unless its folder is not writable, which is exactly the
    /// refusal the job would give. Any `Failure` becomes the row's words.
    nonisolated static func soundStoreProblem(in folder: URL) -> String? {
        let file = folder.appendingPathComponent(AudioFingerprintStore.fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            return fm.isWritableFile(atPath: folder.path) ? nil : "the fingerprint folder is not writable: \(folder.path)"
        }
        do {
            _ = try AudioFingerprintStore(directory: folder)
            return nil
        } catch let failure as AudioFingerprintStore.Failure {
            return failure.description
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Presence facts from the audit marker (pure)

/// What the File Presence row reads off the last run's marker.
struct CatalogAuditPresenceFacts: Sendable, Equatable {
    /// Rows the run actually asked (every result but "not asked").
    var checked = 0
    /// gone + changed of the last completed run — a person decides.
    var needsDecision = 0
    var lastCompleted: Date?
    var outcome: FreshnessRow.Outcome = .neverRan

    /// nil record = never ran. A run still marked "running" with no end
    /// is a run that was killed (quit or crash): red, like a failure.
    nonisolated static func from(_ record: CatalogAuditRunRecord?) -> CatalogAuditPresenceFacts {
        guard let r = record else { return CatalogAuditPresenceFacts() }
        var f = CatalogAuditPresenceFacts()
        f.checked = CatalogAuditResult.allCases
            .filter { $0 != .notAsked }
            .reduce(0) { $0 + (r.counts[$1.rawValue] ?? 0) }
        f.lastCompleted = r.finishedAt
        switch r.outcome {
        case .completed:
            f.outcome = r.partial ? .partial : .ok
            f.needsDecision = (r.counts[CatalogAuditResult.gone.rawValue] ?? 0)
                + (r.counts[CatalogAuditResult.changed.rawValue] ?? 0)
        case .stopped:
            f.outcome = .partial
        case .failed, .running:
            f.outcome = .failed
        case .refused:
            f.outcome = .neverRan
        }
        return f
    }
}
