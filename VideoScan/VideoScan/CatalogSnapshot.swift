import Foundation

// MARK: - VideoRecordSnapshot
//
// Sendable value-type view of a `VideoRecord`. Use this when a record
// needs to cross an actor boundary — pass a snapshot, not the class.
// Reference fields (`pairedWith: VideoRecord?`) are flattened to IDs
// (`pairedWithID: UUID?`) so the type can be `Sendable` with no escapes.
//
// The snapshot intentionally omits high-churn workflow state (the live
// `var` properties on the catalog record that the UI mutates in place).
// Anything a worker on a background actor needs to *read* about the
// media should be here; anything it needs to *write* goes back through
// the catalog on MainActor with the record ID as the key.
//
// Pattern:
//
//     // ❌ Old: captures non-Sendable VideoRecord across actors.
//     await MainActor.run { self.bytesWritten += rec.sizeBytes }
//
//     // ✅ New: capture only the snapshot.
//     let snap = rec.snapshot()
//     await MainActor.run { self.bytesWritten += snap.sizeBytes }
//
// See issue #66, plus the strict-concurrency findings on the metrics
// dashboard for the warning count this is paying down.

struct VideoRecordSnapshot: Sendable, Identifiable, Hashable {
    let id: UUID

    // MARK: identity & path
    let filename: String
    let fullPath: String
    let directory: String
    let ext: String

    // MARK: stream / size / time
    let streamTypeRaw: String
    let sizeBytes: Int64
    let durationSeconds: Double
    let dateCreatedRaw: Date?
    let dateModifiedRaw: Date?

    // MARK: codec / format
    let container: String
    let videoCodec: String
    let audioCodec: String
    let resolution: String
    let frameRate: String
    let timecode: String

    // MARK: identity hashing
    let partialMD5: String

    // MARK: Avid metadata (often the only identity for orphaned MXF)
    let avidClipName: String
    let avidMobID: String
    let avidMaterialUUID: String
    let avidTapeName: String

    // MARK: relationships (reference-free — IDs only)
    let pairedWithID: UUID?
    let pairGroupID: UUID?
    let duplicateGroupID: UUID?
    let combinedFromPairID: UUID?

    // MARK: lifecycle / workflow state (all Sendable enums)
    let lifecycleStage: LifecycleStage
    let mediaDisposition: MediaDisposition
    let archiveStage: ArchiveStage
    let starRating: Int

    // MARK: catalog-derived signals
    let detectedPeople: [String]
    let suspectedPeople: [String]
    let junkScore: Int

    /// Computed for callers that want the strongly-typed enum.
    var streamType: StreamType {
        StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed
    }
}

// MARK: - Snapshot extraction

extension VideoRecord {
    /// Capture a Sendable view of this record. Cheap (~30 fields copied).
    /// Reads must happen on the actor that owns this record (typically
    /// MainActor) — call this from there, then ferry the snapshot across.
    func snapshot() -> VideoRecordSnapshot {
        VideoRecordSnapshot(
            id: id,
            filename: filename,
            fullPath: fullPath,
            directory: directory,
            ext: ext,
            streamTypeRaw: streamTypeRaw,
            sizeBytes: sizeBytes,
            durationSeconds: durationSeconds,
            dateCreatedRaw: dateCreatedRaw,
            dateModifiedRaw: dateModifiedRaw,
            container: container,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            resolution: resolution,
            frameRate: frameRate,
            timecode: timecode,
            partialMD5: partialMD5,
            avidClipName: avidClipName,
            avidMobID: avidMobID,
            avidMaterialUUID: avidMaterialUUID,
            avidTapeName: avidTapeName,
            pairedWithID: pairedWith?.id,
            pairGroupID: pairGroupID,
            duplicateGroupID: duplicateGroupID,
            combinedFromPairID: combinedFromPairID,
            lifecycleStage: lifecycleStage,
            mediaDisposition: mediaDisposition,
            archiveStage: archiveStage,
            starRating: starRating,
            detectedPeople: detectedPeople,
            suspectedPeople: suspectedPeople,
            junkScore: junkScore
        )
    }
}

extension Collection where Element == VideoRecord {
    /// Bulk snapshot. Useful when a worker takes a `[VideoRecord]` —
    /// pass `records.snapshots()` instead.
    func snapshots() -> [VideoRecordSnapshot] {
        self.map { $0.snapshot() }
    }
}
