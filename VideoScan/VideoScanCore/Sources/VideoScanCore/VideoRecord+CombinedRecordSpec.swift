// VideoRecord+CombinedRecordSpec.swift
//
// Seam A of the VideoRecord-Sendable restructure, Combine path.
//
// The Combine path historically built and stamped a whole `VideoRecord` (a
// reference type, NOT Sendable) off the main actor inside
// `buildCombinedRecord` — it ran ffprobe on the muxed output and then set ~40
// fields directly on the freshly-`new`'d record while still on a background
// task. That object was then handed back and appended to `model.records` on
// the main actor: a classic actor-boundary hole, the same shape the probe
// path closed with `ProbeResult` / `ProbeOutcome`.
//
// `CombinedRecordSpec` is the Sendable carrier for everything the combine
// path computes off-actor. The worker fills it in (pure value work — ffprobe
// parsing, byte counts, date formatting), hands it across the boundary, and
// the actual `VideoRecord()` construction + `apply(spec)` happens on the
// @MainActor side at the point of insertion into `records`.
//
// For Rick (C++ analogy): `CombinedRecordSpec` ≈ a POD result struct returned
// by value from a worker thread; the `VideoRecord` (heap object) is built from
// it on the owning thread. Nothing shares the heap object across threads.
//
// Behavior-preservation: every spec field defaults to the SAME value as the
// matching `VideoRecord` stored property, and the off-actor builder assigns a
// field only when its source is present (mirroring the old conditional
// mutation), leaving the rest at the default. `apply` is then an unconditional
// copy onto a fresh record — reproducing the old in-place mutation exactly.
// The recovered-MXF-pair wiring (`combinedFromPairID`) and the
// lifecycle/disposition/archive stamping are carried verbatim. Pinned by
// VideoScanTests/CombineTests.

import Foundation

// MARK: - CombinedRecordSpec (Sendable carrier for a combined output record)

/// Everything the Combine path computes off-actor for a successfully muxed
/// output file, as a Sendable value. Each default mirrors the corresponding
/// `VideoRecord` default so `VideoRecord.apply(_:)` is a faithful
/// unconditional copy onto a freshly constructed record.
public struct CombinedRecordSpec: Sendable {
    // File identity / container
    public var filename: String = ""
    public var ext: String = ""
    public var fullPath: String = ""
    public var directory: String = ""
    public var container: String = ""
    public var streamTypeRaw: String = ""

    // Size
    public var sizeBytes: Int64 = 0
    public var size: String = ""

    // Duration
    public var durationSeconds: Double = 0
    public var duration: String = ""

    // Video stream (left at defaults when the output has no video stream)
    public var videoCodec: String = ""
    public var resolution: String = ""
    public var frameRate: String = ""
    public var videoBitrate: String = ""
    public var colorSpace: String = ""
    public var bitDepth: String = ""
    public var scanType: String = ""

    // Audio stream (left at defaults when the output has no audio stream)
    public var audioCodec: String = ""
    public var audioChannels: String = ""
    public var audioSampleRate: String = ""

    // Misc probe-derived
    public var totalBitrate: String = ""
    public var isPlayable: String = ""
    public var notes: String = ""

    // Dates (left at defaults when the source date is missing/impossible)
    public var dateCreatedRaw: Date?
    public var dateCreated: String = ""
    public var dateModifiedRaw: Date?
    public var dateModified: String = ""

    // Lifecycle / provenance — the combine-specific stamping.
    public var mediaDisposition: MediaDisposition = .unreviewed
    public var archiveStage: ArchiveStage = .none
    public var lifecycleStage: LifecycleStage = .cataloged
    public var starRating: Int = 0
    public var combinedFromPairID: UUID?

    public init() {}
}

// MARK: - VideoRecord.apply(CombinedRecordSpec)

extension VideoRecord {
    /// Materialize a combined-output spec onto `self`. The SINGLE authoritative
    /// copy point from the Sendable `CombinedRecordSpec` into the catalog
    /// record; called only on the main actor at the point the combined record
    /// is appended to `records`. Field order mirrors the old in-place
    /// `buildCombinedRecord` mutation exactly.
    public func apply(_ s: CombinedRecordSpec) {
        filename        = s.filename
        ext             = s.ext
        fullPath        = s.fullPath
        directory       = s.directory
        container       = s.container
        streamTypeRaw   = s.streamTypeRaw

        sizeBytes       = s.sizeBytes
        size            = s.size

        durationSeconds = s.durationSeconds
        duration        = s.duration

        videoCodec      = s.videoCodec
        resolution      = s.resolution
        frameRate       = s.frameRate
        videoBitrate    = s.videoBitrate
        colorSpace      = s.colorSpace
        bitDepth        = s.bitDepth
        scanType        = s.scanType

        audioCodec      = s.audioCodec
        audioChannels   = s.audioChannels
        audioSampleRate = s.audioSampleRate

        totalBitrate    = s.totalBitrate
        isPlayable      = s.isPlayable
        notes           = s.notes

        dateCreatedRaw  = s.dateCreatedRaw
        dateCreated     = s.dateCreated
        dateModifiedRaw = s.dateModifiedRaw
        dateModified    = s.dateModified

        mediaDisposition   = s.mediaDisposition
        archiveStage       = s.archiveStage
        lifecycleStage     = s.lifecycleStage
        starRating         = s.starRating
        combinedFromPairID = s.combinedFromPairID
    }
}
