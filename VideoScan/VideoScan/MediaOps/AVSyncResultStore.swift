// AVSyncResultStore.swift
// ONE SENTENCE: this session's A/V sync results, keyed by BOTH whole-file
// digests and the policy that judged them, so a "Sound & picture timing"
// line is shown only for the exact content that was measured.
//
// Feature store (CLAUDE.md rule 12, #337): owned by MediaFileOperationsCenter
// (`avSyncResults`), never an `extension VideoScanModel`. Session memory only:
// the design (docs/design/av_sync_analysis.md §6) asks for an evidence row
// keyed by both digests and the policy version, and no existing catalog table
// fits without DDL (media_checks' kind CHECK, provenance_assertions is
// provenance) — a schema change is Rick's (rule 6), so until then each result
// lives here and in videoscan.log (AVSyncJob writes one line per pair).
//
// TRUTH (rule 1): `entry(forProcessedDigest:)` answers only for the digest the
// caller holds NOW, and only for results judged by the CURRENT policy and
// analyzer — a file whose bytes changed, or a result from an older rule,
// shows nothing rather than a stale verdict.
//
// MEMORY: one report per entry — about 200 B per window (a 2-hour file has
// 719 windows ≈ 145 KB); FIFO-capped at `cap` (100) entries ⇒ worst case
// ≈ 15 MB, typically a few hundred KB.
//
// (For Rick: @MainActor ObservableObject ≈ a main-thread-only C++ model
// object with a change signal SwiftUI subscribes to.)

import Combine
import Foundation
import VideoScanCore

/// One side of a check, snapshotted on the main actor (VideoRecord is a
/// class and not Sendable).
struct AVSyncSide: Sendable, Equatable {
    let recordID: UUID
    let filename: String
    let path: String
    let sizeBytes: Int64
    let durationSeconds: Double
    /// Whole-file SHA-256 (CatalogCommit.digest), nil when not known yet.
    let digest: String?

    @MainActor
    init(record: VideoRecord) {
        recordID = record.id
        filename = record.filename
        path = record.fullPath
        sizeBytes = record.sizeBytes
        durationSeconds = record.durationSeconds
        digest = CatalogCommit.digest(of: record)
    }

    init(recordID: UUID, filename: String, path: String, sizeBytes: Int64, durationSeconds: Double, digest: String?) {
        self.recordID = recordID
        self.filename = filename
        self.path = path
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.digest = digest
    }
}

@MainActor
final class AVSyncResultStore: ObservableObject {

    struct Key: Hashable, Sendable {
        let processedDigest: String
        let originalDigest: String
        let policyIdentity: String
        let analyzerVersion: Int
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let key: Key
        let report: AVSyncReport
        let processed: AVSyncSide
        let original: AVSyncSide
        let measuredAt: Date
    }

    static let cap = 100

    /// Bumped on every write so observers re-render.
    @Published private(set) var revision = 0
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    /// processed digest → the key most recently recorded for it.
    private var latestKeyByProcessed: [String: Key] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Store a result. Refused (false) unless both digests are present —
    /// identity is the whole-file SHA-256, never the path.
    @discardableResult
    func record(_ report: AVSyncReport, processed: AVSyncSide, original: AVSyncSide, at date: Date = Date()) -> Bool {
        guard let pd = processed.digest, let od = original.digest else { return false }
        let key = Key(processedDigest: pd, originalDigest: od, policyIdentity: report.policyIdentity,
                      analyzerVersion: report.analyzerVersion)
        if entries[key] == nil {
            order.append(key)
            if order.count > Self.cap {
                let evicted = order.removeFirst()
                entries[evicted] = nil
                if latestKeyByProcessed[evicted.processedDigest] == evicted {
                    latestKeyByProcessed[evicted.processedDigest] = nil
                }
            }
        }
        entries[key] = Entry(key: key, report: report, processed: processed, original: original, measuredAt: date)
        latestKeyByProcessed[pd] = key
        revision += 1
        return true
    }

    /// The latest result for content `digest` as the processed file, judged
    /// by `policy` and the current analyzer; nil otherwise.
    func entry(forProcessedDigest digest: String?, policy: AVSyncPolicy = .default) -> Entry? {
        guard let digest, let key = latestKeyByProcessed[digest], let entry = entries[key],
              key.policyIdentity == policy.identity,
              key.analyzerVersion == AVSyncReport.currentAnalyzerVersion else { return nil }
        return entry
    }

    /// The Media Info / Inspector line for `entry`.
    nonisolated static func line(for entry: Entry) -> String {
        let when = entry.measuredAt.formatted(date: .abbreviated, time: .shortened)
        return "\(entry.report.sentence) — against \(entry.original.filename), checked \(when)"
    }
}
