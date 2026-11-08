// PreviewPaneSurface.swift
// The catalog preview pane's DECISIONS, separate from its views (C → B
// lift, 2026-11-07, out of CatalogContent.previewPlayer): which surface
// the centre shows for the selected row, and what the info column says.
// Pure — values in, values out; no SwiftUI, no I/O. The view reads the
// volume's reachability once per body and passes it in.
//
// PreviewPaneSurfaceTests pins `decide` against a verbatim transcription of
// the old if/else-if chain over every combination of its inputs.

import Foundation

/// What the centre of the preview pane shows for the selected row. First
/// match wins, in the order of `decide`. Swift enum-with-payloads ≈ a C++
/// std::variant; the view's `switch` must handle every case.
enum PreviewPaneSurface {
    /// The volume is known offline, or the file's volume is not mounted.
    case mediaOffline
    /// The filmstrip (MKV/FFV1 and other files AVKit cannot decode) is
    /// ready for THIS row.
    case filmstrip(path: String, frames: [PreviewFilmstrip.Frame])
    /// The filmstrip for this row is being extracted: "frame N of M".
    case extracting(frame: Int, of: Int)
    /// The in-app AVPlayer is playing.
    case player
    /// The poster frame; a play button only on files with a picture.
    case poster(showsPlayButton: Bool)
    /// Preview generation failed (or the negative cache remembers it).
    case noPreview
    /// No picture to show, and none coming.
    case audioOnly
    /// Preview generation genuinely in flight — the spinner.
    case generating

    /// Everything the decision reads, as plain values.
    struct Inputs {
        var path: String
        var streamType: StreamType
        var volumeReachable: Bool
        var offlineVolumeName: String?
        var filmstrip: PreviewFilmstripState
        var isPlaying: Bool
        var hasPlayer: Bool
        var hasPoster: Bool
        var previewUnavailable: Bool
    }

    static func decide(_ i: Inputs) -> PreviewPaneSurface {
        if i.offlineVolumeName != nil || !i.volumeReachable { return .mediaOffline }
        if let strip = filmstrip(i.filmstrip, forPath: i.path) { return strip }
        if i.isPlaying && i.hasPlayer { return .player }
        if i.hasPoster { return .poster(showsPlayButton: hasPicture(i.streamType)) }
        if i.previewUnavailable { return .noPreview }
        if i.streamType == .audioOnly { return .audioOnly }
        return .generating
    }

    /// The filmstrip surface when the strip state belongs to `path`; a
    /// strip for a different row is stale and never shown.
    static func filmstrip(_ state: PreviewFilmstripState, forPath path: String) -> PreviewPaneSurface? {
        switch state {
        case .ready(let p, let frames) where p == path:
            return .filmstrip(path: p, frames: frames)
        case .loading(let p, let done, let total) where p == path:
            let of = max(total, 1)
            return .extracting(frame: min(done + 1, of), of: of)
        default:
            return nil
        }
    }

    static func hasPicture(_ streamType: StreamType) -> Bool {
        streamType == .videoAndAudio || streamType == .videoOnly
    }
}

/// The info column beside the preview: what the selected file IS and WHO
/// is in it (Rick 2026-07-31 / 08-01).
enum PreviewPaneInfo {

    /// Finder-like "N selected" above the volume name; nil for none.
    static func selectionCount(_ count: Int) -> String? {
        count > 0 ? "\(count) selected" : nil
    }

    /// "Video: h264   Audio: aac" — the parts the catalog knows; nil for none.
    static func codecLine(videoCodec: String, audioCodec: String) -> String? {
        let parts = [
            videoCodec.isEmpty ? nil : "Video: \(videoCodec)",
            audioCodec.isEmpty ? nil : "Audio: \(audioCodec)",
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    /// "People: Ann, Bob*" — the People column's notation: plain =
    /// confirmed by you, * = detected by a recipe and not confirmed
    /// (case-insensitive). nil when nobody is known.
    static func peopleLine(confirmed: [String], detected: [String]) -> String? {
        let confirmedKeys = Set(confirmed.map { $0.lowercased() })
        let people = confirmed
            + detected.filter { !confirmedKeys.contains($0.lowercased()) }.map { "\($0)*" }
        return people.isEmpty ? nil : "People: \(people.joined(separator: ", "))"
    }

    /// The Stop button shows while either preview mode is live for this
    /// row: the AVPlayer, or a filmstrip loading / ready for this path.
    static func showsStop(isPlaying: Bool, filmstrip: PreviewFilmstripState, path: String) -> Bool {
        isPlaying || filmstrip.isActive(forPath: path)
    }
}
