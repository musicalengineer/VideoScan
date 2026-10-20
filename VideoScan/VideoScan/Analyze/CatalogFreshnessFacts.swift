// CatalogFreshnessFacts.swift
// The NON-RECORD facts the Catalog Status band needs (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §2–§3): what the last
// Audit Catalog run left in `catalog-audit.json`, and whether the sound
// fingerprint sidecar can be opened at all. Both are read OFF the main
// actor, in the same detached pass that computes AnalyzeCoverageReport —
// one small JSON and one SQLite open per debounced catalog change, never
// per record and never in a view body.
//
// Read-only: a missing marker reads as "never ran"; a damaged or
// newer-schema one also leaves `audit` nil but carries `auditProblem`, which
// the Catalog Status band reads as red (QA 2026-10-20 P3-a); a sidecar that refuses to open reads as a red row with the
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
    /// The last Verify Catalog report (integrity-latest.json), as facts.
    var integrity: IntegrityReportFacts
    /// When `catalog.cutover` says this catalog switched to SQLite; nil =
    /// no switch (or a latch this build cannot read). The File Presence row
    /// judges the audit marker against it (the Integrity facts already
    /// were, when they were read).
    var switchedAt: Date?
    /// `catalog-audit.json` EXISTS but cannot be decoded — its words (QA
    /// 2026-10-20 P3-a: an unreadable record is red, never "never ran").
    /// nil when it is absent or reads fine. `audit` stays nil either way.
    var auditProblem: String?

    init(audit: CatalogAuditRunRecord? = nil, soundStoreProblem: String? = nil,
         integrity: IntegrityReportFacts = IntegrityReportFacts(), switchedAt: Date? = nil, auditProblem: String? = nil) {
        self.audit = audit
        self.soundStoreProblem = soundStoreProblem
        self.integrity = integrity
        self.switchedAt = switchedAt
        self.auditProblem = auditProblem
    }
}

enum CatalogFreshnessFactsReader {

    /// Read the facts for the catalog at `catalogFile` (its catalog.json
    /// path — still where every sidecar lives after the switch). Safe off
    /// the main actor; never throws.
    nonisolated static func read(catalogFile: String) -> CatalogFreshnessFacts {
        let folder = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
        let switchedAt = cutoverSwitchedAt(in: folder)
        let audit = auditRead(in: folder)
        return CatalogFreshnessFacts(audit: audit.record,
                                     soundStoreProblem: soundStoreProblem(in: folder),
                                     integrity: integrityFacts(catalogFile: catalogFile, switchedAt: switchedAt),
                                     switchedAt: switchedAt, auditProblem: audit.problem)
    }

    // MARK: Integrity report

    /// The strict read of `integrity-latest.json` beside the catalog, as
    /// the Integrity row's facts: missing → never run; garbage or a newer
    /// schema → the row's red words; a report from before the switch to
    /// SQLite → not this catalog's (`IntegrityReportFacts.predatesSwitch`);
    /// never a crash.
    nonisolated static func integrityFacts(catalogFile: String, switchedAt: Date? = nil) -> IntegrityReportFacts {
        IntegrityReportFacts.from(IntegrityReportStore.read(besideCatalogAt: URL(fileURLWithPath: catalogFile)),
                                  switchedAt: switchedAt)
    }

    // MARK: The switch to SQLite

    /// The latch's name — the same string CatalogAuthority.latchFileName
    /// holds (CatalogFreshnessFactsTests pins the two equal), spelled here
    /// so the read can run off the main actor.
    nonisolated static let cutoverLatchFileName = "catalog.cutover"

    /// `switchedAt` from `catalog.cutover` beside the catalog (written once,
    /// by Switch Catalog to SQLite…). Missing, garbage or no date → nil:
    /// then nothing is judged by it and every row reads as it always did.
    nonisolated static func cutoverSwitchedAt(in folder: URL) -> Date? {
        struct Latch: Decodable { let switchedAt: Date }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(cutoverLatchFileName)) else { return nil }
        return (try? decoder.decode(Latch.self, from: data))?.switchedAt
    }

    /// THE rule (one place, three readers — the File Presence row, Verify
    /// Catalog's tier 0 and the Integrity row, and the audit's launch line):
    /// a pass that STARTED before the switch read catalog.json, the store
    /// the switch retired. Its findings are about rows as catalog.json had
    /// them — the import quarantined the ones it could not vouch for, so
    /// they are not records at all — and not about the catalog in use.
    /// No switch (nil) → false: nothing changes for a JSON catalog.
    nonisolated static func predatesSwitch(_ startedAt: Date, switchedAt: Date?) -> Bool {
        guard let switchedAt else { return false }
        return startedAt < switchedAt
    }

    // MARK: Audit marker

    /// The marker's name — the same string CatalogAuditRunMarker.fileName
    /// holds (that one is main-actor bound; CatalogFreshnessFactsTests pins
    /// the two equal), spelled here so the read can run off the main actor.
    nonisolated static let auditMarkerFileName = "catalog-audit.json"

    /// Decode `catalog-audit.json` beside the catalog. Garbage, a missing
    /// file or a newer schema → nil (never ran), never a crash.
    nonisolated static func auditRecord(in folder: URL) -> CatalogAuditRunRecord? {
        auditRead(in: folder).record
    }

    /// The same read, telling ABSENT (nil, nil — never ran) from PRESENT
    /// BUT UNDECODABLE (nil, words — the band's red "can't be read").
    nonisolated static func auditRead(in folder: URL) -> (record: CatalogAuditRunRecord?, problem: String?) {
        let url = folder.appendingPathComponent(auditMarkerFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            return (try decoder.decode(CatalogAuditRunRecord.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (nil, "\(auditMarkerFileName) can't be read: \(error.localizedDescription)")
        }
    }

    /// Same decoder shape as CatalogAuditRunMarker's (ISO-8601 dates).
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Sound sidecar

    /// Try to open the sidecar the way the fingerprint job will. Red only
    /// when the file EXISTS and cannot be opened (design §3: "a sidecar
    /// that cannot be opened"). A file that does not exist yet is never a
    /// problem here — before the first run the row is yellow "never ran",
    /// and an unwritable folder is the backfill job's own refusal when it
    /// runs (codex cycle #80, P2). Any `Failure` becomes the row's words.
    nonisolated static func soundStoreProblem(in folder: URL) -> String? {
        let file = folder.appendingPathComponent(AudioFingerprintStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
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
    /// gone + changed of the last COMPLETED, non-partial run — a person
    /// decides. A run that stopped part way claims nothing: its count is
    /// of the rows it reached, not of the catalog (codex cycle #80, P2).
    var needsDecision = 0
    var lastCompleted: Date?
    var outcome: FreshnessRow.Outcome = .neverRan
    /// The last run read catalog.json before the switch to SQLite
    /// (`CatalogFreshnessFactsReader.predatesSwitch`): it claims nothing
    /// about this catalog — never ran, as far as these rows go.
    var predatesSwitch = false

    /// nil record = never ran. A run still marked "running" with no end
    /// is a run that was killed (quit or crash): red, like a failure. A
    /// run from before the switch to SQLite is no run of this catalog's.
    nonisolated static func from(_ record: CatalogAuditRunRecord?, switchedAt: Date? = nil) -> CatalogAuditPresenceFacts {
        guard let r = record else { return CatalogAuditPresenceFacts() }
        if CatalogFreshnessFactsReader.predatesSwitch(r.startedAt, switchedAt: switchedAt) {
            return CatalogAuditPresenceFacts(predatesSwitch: true)
        }
        var f = CatalogAuditPresenceFacts()
        f.checked = CatalogAuditResult.allCases
            .filter { $0 != .notAsked }
            .reduce(0) { $0 + (r.counts[$1.rawValue] ?? 0) }
        f.lastCompleted = r.finishedAt
        switch r.outcome {
        case .completed where r.partial:
            f.outcome = .partial
        case .completed:
            f.outcome = .ok
            f.needsDecision = (r.counts[CatalogAuditResult.gone.rawValue] ?? 0)
                + (r.counts[CatalogAuditResult.changed.rawValue] ?? 0)
                + (r.counts[CatalogAuditResult.neverSeenByAnAudit.rawValue] ?? 0)   // the Fix Links bucket (codex r3 D5)
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
