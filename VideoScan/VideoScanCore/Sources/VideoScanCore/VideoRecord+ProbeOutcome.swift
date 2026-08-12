// VideoRecord+ProbeOutcome.swift
//
// Step 3-full + 4 of the VideoRecord-Sendable restructure.
//
// `ProbeResult` (sibling file) already closed the metadata seam: the 19
// ffprobe-derived fields now travel off-actor as a Sendable value. But the
// probe engine still constructed and mutated a whole `VideoRecord` off the
// main actor — it set file-identity fields (filename, path, size, dates,
// hash), the failure/fallback diagnosis, and the transient scan-time fields
// (wasCacheHit, scanContext) directly on the reference type.
//
// `ProbeOutcome` is the FULL Sendable carrier for everything one probe
// produces. It composes the metadata `ProbeResult` and adds every other
// field the off-actor path used to stamp onto a `VideoRecord`. The pipeline
// now flows `ProbeOutcome` across the actor boundary and constructs the
// `VideoRecord` only at the main-actor drain points via `apply(_:)`.
//
// For Rick (C++ analogy): `ProbeOutcome` ≈ a POD result struct returned by
// value from a worker thread; the `VideoRecord` (heap object) is built from
// it on the owning thread. Nothing shares the heap object across threads.
//
// Behavior-preservation: every field defaults to the SAME value as the
// matching `VideoRecord` stored property, and `apply` is an unconditional
// copy — so building a fresh record and applying an outcome reproduces the
// old in-place mutation exactly. Pinned by the probe-extraction golden and
// the probe-engine error-path / cache-hit tests.

import Foundation

// MARK: - ProbeOutcome (full Sendable probe carrier)

/// Everything a single probe produces, as a Sendable value. Carries the
/// file-identity + probe-side fields the engine sets directly, the 19
/// ffprobe-derived metadata fields (`probe`), and the transient scan-time
/// fields that are NOT persisted to the SQLite cache (`wasCacheHit`,
/// `scanContext`). Each default mirrors the corresponding `VideoRecord`
/// default so `VideoRecord.apply(_:)` is a faithful unconditional copy.
public struct ProbeOutcome: Sendable {
    // File-identity + probe-side fields (set by the engine before/around the
    // ffprobe call, and by the cache-hit / failure-sentinel paths).
    public var filename: String = ""
    public var ext: String = ""
    public var fullPath: String = ""
    public var directory: String = ""
    public var sizeBytes: Int64 = 0
    public var size: String = ""
    public var dateCreated: String = ""
    public var dateModified: String = ""
    public var dateCreatedRaw: Date?
    public var dateModifiedRaw: Date?
    public var partialMD5: String = ""
    public var contentHash: String = ""
    public var contentHashAt: Date?
    public var notes: String = ""

    /// The 19 ffprobe-derived metadata fields (container, codecs, resolution,
    /// streamTypeRaw, isPlayable, …). Defaults match `VideoRecord`.
    public var probe: ProbeResult = ProbeResult()

    /// Transient scan-time fields — recaptured every scan, never persisted to
    /// the SQLite probe cache. Folding them here is what removes the last
    /// off-actor `cached.wasCacheHit = …; cached.scanContext = …` mutation.
    public var wasCacheHit: Bool = false
    public var scanContext: ScanContext = ScanContext()

    /// True when the probe engine's magic-byte content sniff rejected an
    /// extensionless / unknown-extension candidate BEFORE ffprobe ran
    /// (discovery-completeness feature, 2026-07-02). Purely diagnostic —
    /// the discovery audit uses it to distinguish "no media signature"
    /// from "ffprobe could not identify". Sniff-rejected outcomes are
    /// always gated out of the catalog, so `VideoRecord.apply(_:)` has no
    /// counterpart field to copy this into (same as it would be for any
    /// never-cataloged diagnostic).
    public var sniffRejected: Bool = false

    public init() {}
}

// MARK: - ProbeOutcome(scanDerivedFrom:) — the inverse lift

extension ProbeOutcome {
    /// Inverse of `VideoRecord.apply(_:)` below: lift EXACTLY the scan-derived
    /// field set back out of a record. A freshly-scanned record's non-default
    /// state is precisely what `apply(ProbeOutcome)` stamped onto it, so this
    /// round-trips the technical fields and nothing else (never the dossier /
    /// user-curation / pair / duplicate fields).
    ///
    /// Consumer: the scan-merge move/rename adoption (2026-07-02) — the OLD
    /// record survives a file move with its id, and adopts the fresh probe's
    /// technical fields via `old.apply(ProbeOutcome(scanDerivedFrom: fresh))`.
    ///
    /// MAINTENANCE: adding a field to `ProbeOutcome` means updating BOTH this
    /// init and `apply(_:)` — keep them adjacent and in the same order.
    /// (`sniffRejected` has no record counterpart; it stays false.)
    @MainActor
    public init(scanDerivedFrom rec: VideoRecord) {
        self.init()
        filename        = rec.filename
        ext             = rec.ext
        fullPath        = rec.fullPath
        directory       = rec.directory
        sizeBytes       = rec.sizeBytes
        size            = rec.size
        dateCreated     = rec.dateCreated
        dateModified    = rec.dateModified
        dateCreatedRaw  = rec.dateCreatedRaw
        dateModifiedRaw = rec.dateModifiedRaw
        partialMD5      = rec.partialMD5
        contentHash     = rec.contentHash
        contentHashAt   = rec.contentHashAt
        notes           = rec.notes
        probe           = ProbeResult(scanDerivedFrom: rec)
        wasCacheHit     = rec.wasCacheHit
        scanContext     = rec.scanContext
    }
}

// MARK: - VideoRecord.apply(ProbeOutcome)

extension VideoRecord {
    /// Materialize a full probe result onto `self`. The SINGLE authoritative
    /// copy point from the Sendable `ProbeOutcome` into the persisted record;
    /// called only at the main-actor drain points (and the `@MainActor`
    /// single-file reprobe shims). Unconditional by design — see the file
    /// header note on why that preserves the old in-place mutation behavior.
    public func apply(_ o: ProbeOutcome) {
        filename        = o.filename
        ext             = o.ext
        fullPath        = o.fullPath
        directory       = o.directory
        sizeBytes       = o.sizeBytes
        size            = o.size
        dateCreated     = o.dateCreated
        dateModified    = o.dateModified
        dateCreatedRaw  = o.dateCreatedRaw
        dateModifiedRaw = o.dateModifiedRaw
        partialMD5      = o.partialMD5
        contentHash     = o.contentHash
        contentHashAt   = o.contentHashAt
        notes           = o.notes
        apply(o.probe)              // the 19 ffprobe metadata fields
        wasCacheHit     = o.wasCacheHit
        scanContext     = o.scanContext
    }
}
