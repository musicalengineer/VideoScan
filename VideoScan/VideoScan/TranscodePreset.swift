// TranscodePreset.swift
// The Transcode recipe enum (editing / archival / preservation) and its
// naming/UI tags — extracted verbatim from TranscodeJob.swift (refactor
// 2026-06-25). Standalone value type with no dependency on TranscodeJob's
// `self`, so it moves as a whole type. Behavior unchanged.

import Foundation

// MARK: - Preset

/// Which Transcode recipe to run. Drives the args list, the output suffix
/// (`.vs.edit.mov` / `.vs.archive.mov` / `.vs.preserve.mkv`), and the
/// subtitle text. (Swift's `String`-raw-value enum ≈ a C++ enum class with
/// a `to_string` member built in.)
enum TranscodePreset: String {
    case editing
    case archival
    case preservation

    /// Tag used in the derived-file naming convention.
    ///
    /// See DerivedFileNaming.swift — the convention is
    /// `<stem>.vs.<purpose>.<codec>.<timestamp>.<ext>`. We pick a single
    /// short codec token per preset so the derived files self-describe in
    /// Finder.
    var codecTag: String {
        switch self {
        case .editing:      return "prores422hq"
        case .archival:     return "hevc10bit"
        case .preservation: return "ffv1v3"
        }
    }

    /// Purpose segment in the derived-file naming convention. Used as a
    /// Finder search anchor ("show me all my archive derivatives").
    var purposeTag: String {
        switch self {
        case .editing:      return "edit"
        case .archival:     return "archive"
        case .preservation: return "preserve"
        }
    }

    /// Output container extension. Editing/Archival are QuickTime (.mov)
    /// because their codecs (ProRes / HEVC+AAC) are what FCP and
    /// AVFoundation expect in a .mov. Preservation is Matroska (.mkv):
    /// FFV1 + FLAC is the FADGI/LoC-blessed lossless combo, and Matroska
    /// is the archival container that carries them losslessly (QuickTime
    /// can't hold FFV1).
    var fileExtension: String {
        switch self {
        case .editing, .archival: return "mov"
        case .preservation:       return "mkv"
        }
    }

    /// Live subtitle in the operations window while the encode runs.
    var subtitle: String {
        switch self {
        case .editing:      return "Transcoding to ProRes 422 HQ…"
        case .archival:     return "Transcoding to HEVC 10-bit…"
        case .preservation: return "Encoding FFV1 v3 preservation master…"
        }
    }

    /// Human label used in the journey/notes stamp + success summary and
    /// in the context-menu button.
    var humanLabel: String {
        switch self {
        case .editing:      return "Editing (ProRes 422 HQ)"
        case .archival:     return "Archival (HEVC 10-bit)"
        case .preservation: return "Preservation Master (FFV1 v3, verified)"
        }
    }
}
