// VideoScanModel+AudioFingerprintBackfill.swift
// The catalog's side of "Fingerprint Sound…" (Rick 2026-10-14):
//   • `audioFingerprintBackfillPlan` — what the job still has to look at
//     (AudioFingerprintBackfillPlanner over the live records, archive first
//     within each drive). ONE pass, O(records); never in a view body — the
//     confirm sheet computes it once on appear.
//   • `applyAudioFingerprintStamp` — the only catalog write: compare-and-set
//     on the record the plan named (same id, path and size). Media is never
//     touched.
//   • `revertAudioFingerprintStamp` — the undo for a stamp whose save was
//     not acknowledged (only when the record still holds exactly it).
//   • `audioFingerprintSidecarDirectory` — the sidecar lives beside
//     catalog.json (App Support/VideoScan in production; a test catalog's
//     scratch folder in tests), so it follows the catalog it indexes.
//   • `audioFingerprintNote` — the one sink: console + catalog.log,
//     videoscan.log, unified log.
//
// (For Rick: an `extension` ≈ more member functions of the same class in
// another file.)

import Foundation
import VideoScanCore
import os

private let audioFingerprintLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fingerprintSound")

/// What a compare-and-set write did.
enum AudioFingerprintWrite: Equatable, Sendable {
    case written
    /// The record moved, changed size, vanished, or the catalog is
    /// read-only — nothing written.
    case recordChanged
}

extension VideoScanModel {

    /// The backfill plan over the live catalog (archive first per drive).
    func audioFingerprintBackfillPlan() -> AudioFingerprintBackfillPlan {
        AudioFingerprintBackfillPlanner.plan(records: records) { self.isArchiveElement($0) }
    }

    /// The backfill's write: compare-and-set on the planned record.
    func applyAudioFingerprintStamp(_ stamp: AudioFingerprintStamp,
                                    to item: AudioFingerprintBackfillItem) -> AudioFingerprintWrite {
        guard !isReadOnly, let rec = record(forID: item.id),
              rec.fullPath == item.path, rec.sizeBytes == item.sizeBytes, !rec.isPurged
        else { return .recordChanged }
        rec.audioFingerprint = stamp
        return .written
    }

    /// Undo a write whose save was NOT acknowledged — only when the record
    /// still holds exactly what the job wrote. The record becomes a
    /// candidate again, so the next run looks at it again.
    func revertAudioFingerprintStamp(_ item: AudioFingerprintBackfillItem,
                                     written: AudioFingerprintStamp) -> Bool {
        guard let rec = record(forID: item.id), rec.audioFingerprint == written else { return false }
        rec.audioFingerprint = nil
        return true
    }

    /// The folder holding catalog.json — where audio-fingerprints.sqlite lives.
    var audioFingerprintSidecarDirectory: URL {
        URL(fileURLWithPath: catalogStore.fileLocation).deletingLastPathComponent()
    }

    /// Console + catalog.log (`log`), videoscan.log and the unified log —
    /// the backfill's one sink for START / progress / OUTCOME lines.
    func audioFingerprintNote(_ line: String) {
        log("Fingerprint sound: " + line)
        appLog.write("[fingerprint-sound] " + line)
        audioFingerprintLog.notice("\(line, privacy: .public)")
    }
}
