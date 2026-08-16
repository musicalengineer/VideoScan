// VideoRecord+ProbeResult.swift
//
// The off-actor probe path historically mutated a `VideoRecord` (a reference
// type, NOT Sendable) in place while running on a background task — an
// actor-boundary hole. This file introduces the seam that closes it:
//
//   * `ProbeResult` — a pure `Sendable` value struct carrying EXACTLY the 19
//     metadata fields that `ScanEngine.extractMetadata` populates from ffprobe
//     output. Being a value type with only `String`/`Double` members it is
//     trivially `Sendable`, so it can cross the actor boundary safely.
//
//   * `VideoRecord.apply(_:)` — the single authoritative point that copies a
//     `ProbeResult` into a `VideoRecord`. Computing the fields off-actor into a
//     `ProbeResult` and then `apply`-ing it on the main actor lets the mutation
//     of the reference type happen where it's safe.
//
// Behavior-preservation note: every `ProbeResult` field defaults to the SAME
// value as the matching `VideoRecord` stored property ("" for String, 0 for
// Double). `extractMetadata` only assigns a field when its ffprobe source is
// present, leaving the rest at the default — so an unconditional copy in
// `apply` reproduces the old in-place mutation exactly on a freshly constructed
// record. Pinned by VideoScanTests/ProbeExtractionGoldenTests.
//
// For Rick (C++ analogy): `ProbeResult` ≈ a plain POD struct passed by value
// across threads; `VideoRecord` ≈ a heap object (shared_ptr-like reference)
// whose mutation we now confine to one thread. `apply` is the copy-assign that
// stamps the POD's fields onto the heap object.

import Foundation

// MARK: - ProbeResult (Sendable value carrier)

/// Immutable-by-convention value carrier for the metadata fields produced by
/// the off-actor ffprobe extraction stage. Mirrors the 19 fields pinned by the
/// probe-extraction golden test. Each default matches the corresponding
/// `VideoRecord` default so `apply` is a faithful unconditional copy.
public struct ProbeResult: Sendable {
    public var container: String = ""
    public var durationSeconds: Double = 0
    public var duration: String = ""
    public var totalBitrate: String = ""
    public var timecode: String = ""
    public var tapeName: String = ""
    public var materialPackageUMID: String = ""
    public var videoCodec: String = ""
    public var resolution: String = ""
    public var frameRate: String = ""
    public var videoBitrate: String = ""
    public var colorSpace: String = ""
    public var bitDepth: String = ""
    public var scanType: String = ""
    public var audioCodec: String = ""
    public var audioChannels: String = ""
    public var audioSampleRate: String = ""
    public var streamTypeRaw: String = ""
    public var isPlayable: String = ""
    // Embedded creation date + origin (2026-08-16). Read from the SAME
    // ffprobe JSON the 19 fields above come from (format/stream tags),
    // so no extra subprocess. nil defaults match VideoRecord.
    public var embeddedCreationDate: Date?
    public var embeddedCreationSource: String?
    public var originMake: String?
    public var originModel: String?
    public var originEncoder: String?

    public init() {}
}

// MARK: - VideoRecord.apply

extension ProbeResult {
    /// Inverse of `VideoRecord.apply(_:)` below: lift the 19 metadata fields
    /// back OUT of a record. Used by the scan-merge move/rename adoption
    /// (2026-07-02) to transplant a freshly-probed record's technical fields
    /// onto the surviving old record without inventing a second field list —
    /// this init and `apply` are the two directions of the SAME list.
    ///
    /// MAINTENANCE: adding a field to `ProbeResult` means updating BOTH this
    /// init and `apply(_:)` — keep them adjacent and in the same order.
    ///
    /// `// @MainActor ≈ "reads the mutable heap object, so UI-thread only" —
    /// // same convention as RescanPreservedFields.init(from:).`
    @MainActor
    public init(scanDerivedFrom rec: VideoRecord) {
        self.init()
        container           = rec.container
        durationSeconds     = rec.durationSeconds
        duration            = rec.duration
        totalBitrate        = rec.totalBitrate
        timecode            = rec.timecode
        tapeName            = rec.tapeName
        materialPackageUMID = rec.materialPackageUMID
        videoCodec          = rec.videoCodec
        resolution          = rec.resolution
        frameRate           = rec.frameRate
        videoBitrate        = rec.videoBitrate
        colorSpace          = rec.colorSpace
        bitDepth            = rec.bitDepth
        scanType            = rec.scanType
        audioCodec          = rec.audioCodec
        audioChannels       = rec.audioChannels
        audioSampleRate     = rec.audioSampleRate
        streamTypeRaw       = rec.streamTypeRaw
        isPlayable          = rec.isPlayable
        embeddedCreationDate   = rec.embeddedCreationDate
        embeddedCreationSource = rec.embeddedCreationSource
        originMake             = rec.originMake
        originModel            = rec.originModel
        originEncoder          = rec.originEncoder
    }
}

extension VideoRecord {
    /// Copy every `ProbeResult` field into `self`. This is the SINGLE
    /// authoritative copy point from the Sendable probe value into the
    /// persisted record. Unconditional by design — see the file header note on
    /// why that preserves the old conditional in-place mutation behavior.
    public func apply(_ r: ProbeResult) {
        container           = r.container
        durationSeconds     = r.durationSeconds
        duration            = r.duration
        totalBitrate        = r.totalBitrate
        timecode            = r.timecode
        tapeName            = r.tapeName
        materialPackageUMID = r.materialPackageUMID
        videoCodec          = r.videoCodec
        resolution          = r.resolution
        frameRate           = r.frameRate
        videoBitrate        = r.videoBitrate
        colorSpace          = r.colorSpace
        bitDepth            = r.bitDepth
        scanType            = r.scanType
        audioCodec          = r.audioCodec
        audioChannels       = r.audioChannels
        audioSampleRate     = r.audioSampleRate
        streamTypeRaw       = r.streamTypeRaw
        isPlayable          = r.isPlayable
        embeddedCreationDate   = r.embeddedCreationDate
        embeddedCreationSource = r.embeddedCreationSource
        originMake             = r.originMake
        originModel            = r.originModel
        originEncoder          = r.originEncoder
    }
}
