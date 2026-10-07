// VideoScanModel+PerceptualFingerprints.swift
// GH #293 item 1 (2026-10-07): the catalog's side of stored perceptual
// fingerprints (StoredPerceptualFingerprint in VideoScanCore).
//
//   • `storedPerceptualFingerprint(of:)` — THE read: the record's kept
//     fingerprint when it is current for the file as catalogued (same
//     recipe, same size, enough frames, undamaged), else nil. Every reader
//     (Compare These Two Files' visual tier, the backfill planner) asks
//     this before running ffmpeg.
//   • `perceptualFingerprintBackfillPlan` — what "Fingerprint pictures"
//     still has to do: every live video record with a known duration and
//     no current fingerprint, ARCHIVED FILES FIRST (Rick's order: the
//     archive is what the Year check and delete-excess read), then the
//     rest; each group in path order so a resumed run reads disks in the
//     same order. ONE pass over the records, O(records); never in a view.
//   • `applyPerceptualFingerprint` — the only write: compare-and-set on
//     the record the plan named (same id, path and size), catalog field
//     only. Media is never touched.
//
// (For Rick: an `extension` ≈ more member functions of the same class in
// another file; `static` ones are free functions in its namespace.)

import Foundation
import VideoScanCore
import os

private let perceptualFingerprintLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fingerprint")

/// One file the backfill will fingerprint — plain values captured on the
/// main actor, safe to hand to the off-main ffmpeg pass.
struct PerceptualFingerprintBackfillItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let path: String
    let filename: String
    let sizeBytes: Int64
    let durationSeconds: Double
    /// A Master Archive file (planned first).
    let isArchived: Bool
}

/// What a compare-and-set write did.
enum PerceptualFingerprintWrite: Equatable, Sendable {
    case written
    /// The record moved, changed size, vanished, or the catalog is
    /// read-only — nothing written.
    case recordChanged
}

extension VideoScanModel {

    /// The record's kept fingerprint when it may stand in for a fresh
    /// ffmpeg pass over the file as catalogued; nil otherwise.
    static func storedPerceptualFingerprint(of rec: VideoRecord) -> [UInt64]? {
        guard let fp = rec.perceptualFingerprint,
              fp.isCurrent(forSizeBytes: rec.sizeBytes, minimumFrames: PerceptualFingerprinter.minimumFrames)
        else { return nil }
        return fp.hashes
    }

    /// May the backfill fingerprint this record? A live, readable video
    /// row with a picture, a known duration and size, and no current
    /// fingerprint.
    static func needsPerceptualFingerprint(_ rec: VideoRecord) -> Bool {
        guard rec.purgedAt == nil, !rec.isSetAside, !rec.isSuperseded,
              rec.streamType == .videoAndAudio || rec.streamType == .videoOnly,
              rec.durationSeconds > 0, rec.sizeBytes > 0 else { return false }
        return storedPerceptualFingerprint(of: rec) == nil
    }

    /// The backfill plan over the live catalog (archive first).
    func perceptualFingerprintBackfillPlan() -> [PerceptualFingerprintBackfillItem] {
        Self.perceptualFingerprintBackfillPlan(records: records) { self.isArchiveElement($0) }
    }

    /// Pure over its inputs (the tests drive it with 100k synthetic rows).
    static func perceptualFingerprintBackfillPlan(
        records: [VideoRecord], isArchived: (VideoRecord) -> Bool
    ) -> [PerceptualFingerprintBackfillItem] {
        var archived: [PerceptualFingerprintBackfillItem] = []
        var others: [PerceptualFingerprintBackfillItem] = []
        for rec in records where needsPerceptualFingerprint(rec) {
            let inArchive = isArchived(rec)
            let item = PerceptualFingerprintBackfillItem(
                id: rec.id, path: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                durationSeconds: rec.durationSeconds, isArchived: inArchive)
            if inArchive { archived.append(item) } else { others.append(item) }
        }
        archived.sort { $0.path < $1.path }
        others.sort { $0.path < $1.path }
        return archived + others
    }

    /// The backfill's write: compare-and-set on the planned record.
    func applyPerceptualFingerprint(_ fp: StoredPerceptualFingerprint,
                                    to item: PerceptualFingerprintBackfillItem) -> PerceptualFingerprintWrite {
        guard !isReadOnly, let rec = record(forID: item.id),
              rec.fullPath == item.path, rec.sizeBytes == item.sizeBytes, rec.purgedAt == nil
        else { return .recordChanged }
        rec.perceptualFingerprint = fp
        return .written
    }

    /// Undo a write whose catalog save was NOT acknowledged — only when the
    /// record still holds exactly what the job wrote. The record becomes a
    /// candidate again, so the next run recomputes it.
    func revertPerceptualFingerprint(_ item: PerceptualFingerprintBackfillItem,
                                     written: StoredPerceptualFingerprint) -> Bool {
        guard let rec = record(forID: item.id), rec.perceptualFingerprint == written else { return false }
        rec.perceptualFingerprint = nil
        return true
    }

    /// Console + catalog.log (`log`), videoscan.log and the unified log —
    /// the backfill's one sink for START / progress / OUTCOME lines.
    func perceptualFingerprintNote(_ line: String) {
        log(line)
        appLog.write("[fingerprint] " + line)
        perceptualFingerprintLog.notice("\(line, privacy: .public)")
    }
}

/// Keep a freshly computed fingerprint on the record it describes (the
/// Compare tier's write-back). No-op when the record's size no longer
/// matches the file that was read, or a current value is already kept.
/// Returns true when it wrote.
@MainActor
@discardableResult
func keepPerceptualFingerprint(_ hashes: [UInt64], on rec: VideoRecord,
                               sizeBytes: Int64, durationSeconds: Double) -> Bool {
    guard rec.sizeBytes == sizeBytes, sizeBytes > 0,
          hashes.count >= PerceptualFingerprinter.minimumFrames,
          VideoScanModel.storedPerceptualFingerprint(of: rec) == nil else { return false }
    rec.perceptualFingerprint = StoredPerceptualFingerprint(hashes: hashes, sizeBytes: sizeBytes,
                                                            durationSeconds: durationSeconds)
    return true
}
