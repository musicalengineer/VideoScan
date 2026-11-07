// CatalogFrameIndexRows.swift (VideoScanCore/Store)
// What the SigLIP 2 frame index reads of catalog.sqlite (FrameIndex.swift;
// docs/design/file_dossier_view.md §II.7): one row per CONTENT in an
// ObservationsScope — its whole-file SHA-256 and the standing file that shows
// it (live first, then by path), with the duration and stream type the
// indexer needs to pick frame times. READ ONLY, inside a `read` snapshot; no
// schema change. The indexer plans from it; the Frames search uses it to
// keep a hit inside the scope and to name the file a hit came from (a file
// name appears only as that link — §II.0).
//
// Memory: one row per content in scope (~250 B) — 20k contents ≈ 5 MB.
//
// (For Rick: the DAO header — one value struct plus one read-only interface.)

import Foundation

extension CatalogRow {

    /// One content in scope and the file that stands for it.
    public struct FrameIndexFile: Sendable, Equatable {
        /// Whole-file SHA-256 — the key the frame index uses.
        public var digest: String
        public var fileID: String
        public var filename: String
        public var path: String
        /// Every copy in scope is removed (only a selection can name one).
        public var removed: Bool
        public var durationSeconds: Double
        /// `files.stream_type` ('Video+Audio', 'Video only', 'Audio only', …).
        public var streamType: String

        public init(digest: String, fileID: String, filename: String, path: String, removed: Bool, durationSeconds: Double, streamType: String) {
            self.digest = digest
            self.fileID = fileID
            self.filename = filename
            self.path = path
            self.removed = removed
            self.durationSeconds = durationSeconds
            self.streamType = streamType
        }

        /// The probe found a picture.
        public var hasVideo: Bool { streamType == "Video+Audio" || streamType == "Video only" }
    }
}

/// The frame index's read-only seam (implemented on the READ handle only).
public protocol CatalogFrameIndexReading {
    /// Every content in `scope`, one row each, ordered by the standing file's path.
    func frameIndexFiles(_ scope: ObservationsScope) throws -> [CatalogRow.FrameIndexFile]
}
