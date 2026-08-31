// ArchiveMedium.swift
// Which kind of thing a file IS, decided by extension (2026-08-31).
//
// The archive used to route by StreamType alone, which asks ffprobe what
// streams a file has. That is the right question for A/V — an MXF can be
// audio-only or video-only and only probing tells you which — but it is
// the WRONG question for everything else, and it was quietly wrong in two
// ways:
//
//   * ffprobe reads a JPEG as a single-frame mjpeg VIDEO stream, so loose
//     scans were filed under 30_Video. 10_Photos was declared, listed in
//     `buckets`, created on disk by Initialize — and unreachable.
//   * A PDF has no streams at all, so it fell into the `.noStreams` arm
//     and also landed in 30_Video.
//
// Extension is the honest signal here: no amount of probing tells you a
// birth certificate is a document, and a file's extension is exactly what
// a person means when they call it "the PDF". So medium is decided first,
// and StreamType keeps its real job — splitting A/V into audio and video.

import Foundation

/// What kind of thing a file is, for the purpose of choosing an archive
/// bucket. Deliberately coarse: this answers "which numbered folder",
/// not "what codec".
public enum ArchiveMedium: String, Codable, Sendable, CaseIterable {
    /// Video or audio — the bucket is then decided by `StreamType`,
    /// because only probing separates an audio-only MXF from a video one.
    case audioVisual
    /// A still image: a scan, a photograph, a camera raw.
    case photo
    /// A document: birth certificates, letters, records, deeds.
    case document

    /// Stills. Camera raws are included: a raw scan is still a photo, and
    /// filing it away from its JPEG sibling would split a single shoot.
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "webp",
        "tif", "tiff", "psd",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef",
    ]

    /// Papers a family keeps. Spreadsheets are here too — a census
    /// transcription is a record, not a program's scratch file.
    public static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "odt", "rtf", "txt", "md", "pages",
        "xls", "xlsx", "numbers", "csv", "tsv",
        "ppt", "pptx", "key", "epub",
    ]

    /// Classify by extension. Anything unrecognised is `.audioVisual`,
    /// which preserves the old behaviour for the long tail of media
    /// extensions (and for extensionless files, which this archive has
    /// thousands of): unknown things keep going where they always went,
    /// so this change can only move files it positively identifies.
    public static func forExtension(_ ext: String?) -> ArchiveMedium {
        let key = (ext ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        if key.isEmpty { return .audioVisual }
        if photoExtensions.contains(key) { return .photo }
        if documentExtensions.contains(key) { return .document }
        return .audioVisual
    }

    /// Classify by filename, for callers that hold a name rather than a
    /// parsed extension. A dotfile has no extension, it has a name.
    public static func forFilename(_ filename: String) -> ArchiveMedium {
        let name = (filename as NSString).lastPathComponent
        guard !name.hasPrefix("."), name.contains(".") else { return .audioVisual }
        return forExtension((name as NSString).pathExtension)
    }

    /// Whether a file of this medium can carry A/V streams worth probing.
    /// ffprobe *will* answer for a JPEG; the point is that we should not
    /// ask, and should not treat the answer as a stream shape.
    public var isProbeable: Bool { self == .audioVisual }
}
