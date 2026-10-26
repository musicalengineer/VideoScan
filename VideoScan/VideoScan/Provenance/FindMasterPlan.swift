// FindMasterPlan.swift — Provenance ▸ Find Master (by sound), the PLAN.
// Design: docs/design/provenance_retroactive_2026_10_26.md §Phase A.
//
// ONE SENTENCE: from a snapshot of the selected records and the catalog,
// decide which files can be searched (their sidecar key) and which are
// refused BEFORE any search, with the reason in words; and keep a small
// digest → label map so the answers can name what they found.
//
// Pure: no I/O, no model, no SwiftUI. Built ONCE when the job starts —
// O(records) once, never in a view body (rule 5). The one thing it cannot
// see is a print's recipe (that lives in the sidecar, not the stamp); the
// finder refuses another recipe when the print is loaded.
//
// MEMORY: one label per sounded digest (≈ 200 B: name, path, flags) — for
// today's ≈ 5,400 prints ≈ 1 MB; 100k sounded records ≈ 20 MB.
//
// (For Rick: a value-type "plan object" — like a const struct a C++ worker
// is handed by value, so the worker never reaches back into the model.)

import Foundation
import VideoScanCore

/// Why a selected file is not searched. Each case is one sentence
/// (`FindMasterAnswer.refusal`) — never "no master found".
enum FindMasterRefusalReason: Equatable, Sendable {
    /// No whole-file SHA-256: a sampled hash is not identity (rule 6).
    case notHashed
    /// No current sound-print stamp (never fingerprinted, a stale stamp,
    /// or one keyed on the sampled hash).
    case noSoundPrint
    /// The stamp says no sound track, or measured silence.
    case noSound
    /// Fewer landmarks than the matcher can ever confirm.
    case tooLittleSound(landmarks: Int)
    /// The print in the sidecar was made by another recipe.
    case olderRecipe
}

struct FindMasterQuery: Equatable, Sendable, Identifiable {
    let recordID: UUID
    let name: String
    let key: AudioFingerprintStore.Key
    var id: UUID { recordID }
}

struct FindMasterRefusal: Equatable, Sendable, Identifiable {
    let recordID: UUID
    let name: String
    let reason: FindMasterRefusalReason
    var id: UUID { recordID }
}

/// What the answers say about a content they found: the best record that
/// carries that digest (a live one before a removed one, archived first).
struct FindMasterLabel: Equatable, Sendable {
    let recordID: UUID
    let name: String
    let path: String
    let isArchived: Bool
    /// nil = live. A removed candidate is SHOWN with its state, never hidden
    /// and never offered as a keeper (design §Failure modes).
    let removal: RemovalMarker.State?
}

struct FindMasterPlan: Equatable, Sendable {
    let queries: [FindMasterQuery]
    let refusals: [FindMasterRefusal]
    /// Sidecar digest ("sha256:<hex>") → label.
    let labels: [String: FindMasterLabel]
    /// For the negative sentence: distinct contents whose stamp says no
    /// sound track or measured silence, and live hashed contents with no
    /// current sound print.
    let noSoundTrackContents: Int
    let notFingerprintedContents: Int

    var selectedCount: Int { queries.count + refusals.count }

    /// The plan for `selected`, labels and counts from `all`.
    /// `isArchived` is the model's archive-element test, passed in so the
    /// plan stays pure.
    static func make(selected: [VideoRecord], all: [VideoRecord],
                     isArchived: (VideoRecord) -> Bool) -> FindMasterPlan {
        var queries: [FindMasterQuery] = []
        var refusals: [FindMasterRefusal] = []
        for record in selected {
            switch classify(record) {
            case .success(let key):
                queries.append(FindMasterQuery(recordID: record.id, name: record.filename, key: key))
            case .failure(let refusal):
                refusals.append(FindMasterRefusal(recordID: record.id, name: record.filename, reason: refusal.reason))
            }
        }
        let census = Census.of(all, isArchived: isArchived)
        return FindMasterPlan(queries: queries, refusals: refusals, labels: census.labels,
                              noSoundTrackContents: census.noSound.count,
                              notFingerprintedContents: census.notFingerprinted.count)
    }

    struct Refused: Error { let reason: FindMasterRefusalReason }

    /// The sidecar key a record can be searched by, or why not.
    static func classify(_ r: VideoRecord) -> Result<AudioFingerprintStore.Key, Refused> {
        guard let full = fullDigest(r) else { return .failure(Refused(reason: .notHashed)) }
        guard let stamp = r.audioFingerprint, stamp.sizeBytes == r.sizeBytes,
              stamp.contentDigest == AudioFingerprintStamp.fullDigest(full) else {
            return .failure(Refused(reason: .noSoundPrint))
        }
        switch stamp.hearing(headerHasAudio: !r.audioCodec.isEmpty) {
        case .noAudioTrack, .measuredSilence: return .failure(Refused(reason: .noSound))
        case .notEvidence: return .failure(Refused(reason: .noSoundPrint))
        case .heardSound: break
        }
        guard stamp.landmarks >= AudioMatchPolicy.default.minMatchedLandmarks else {
            return .failure(Refused(reason: .tooLittleSound(landmarks: stamp.landmarks)))
        }
        return .success(AudioFingerprintStore.Key(contentDigest: stamp.contentDigest, sizeBytes: stamp.sizeBytes))
    }

    /// The stored whole-file SHA-256 (the same rule as
    /// `VideoScanModel.storedFullDigest`, which this pure file cannot call
    /// without the model).
    static func fullDigest(_ r: VideoRecord) -> String? {
        if let f = r.contentFixity, f.algorithm == ContentFixity.sha256, f.byteCount == r.sizeBytes, !f.digest.isEmpty {
            return f.digest
        }
        if let a = r.archiveFixity, a.algorithm == ContentFixity.sha256, a.sizeBytes == r.sizeBytes, !a.digest.isEmpty {
            return a.digest.lowercased()
        }
        return nil
    }

    /// One pass over the catalog: labels for sounded digests and the two
    /// counts the negative sentence carries.
    private struct Census {
        var labels: [String: FindMasterLabel] = [:]
        var noSound: Set<String> = []
        var notFingerprinted: Set<String> = []

        static func of(_ all: [VideoRecord], isArchived: (VideoRecord) -> Bool) -> Census {
            var c = Census()
            var printed: Set<String> = []
            for r in all {
                guard let full = fullDigest(r) else { continue }
                let digest = AudioFingerprintStamp.fullDigest(full)
                switch classify(r) {
                case .success:
                    printed.insert(digest)
                    c.offer(r, digest: digest, isArchived: isArchived(r))
                case .failure(let refused):
                    switch refused.reason {
                    case .noSound: c.noSound.insert(digest)
                    case .noSoundPrint where r.removal == nil: c.notFingerprinted.insert(digest)
                    default: break
                    }
                }
            }
            c.notFingerprinted.subtract(printed)
            c.notFingerprinted.subtract(c.noSound)
            c.noSound.subtract(printed)
            return c
        }

        /// Keep the best record per digest: live over removed, then archived.
        mutating func offer(_ r: VideoRecord, digest: String, isArchived: Bool) {
            let label = FindMasterLabel(recordID: r.id, name: r.filename, path: r.fullPath,
                                        isArchived: isArchived, removal: r.removal?.state)
            guard let current = labels[digest] else { labels[digest] = label; return }
            func rank(_ l: FindMasterLabel) -> Int { (l.removal == nil ? 0 : 2) + (l.isArchived ? 0 : 1) }
            if rank(label) < rank(current) { labels[digest] = label }
        }
    }
}
