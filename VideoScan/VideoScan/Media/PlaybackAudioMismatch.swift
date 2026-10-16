// PlaybackAudioMismatch.swift
// MP3 sound inside an MPEG-4 container plays SILENTLY in AVFoundation
// (Rick 2026-10-16: Christmas1990-part1-35mins.m4v — ffprobe says mp3
// 44.1 kHz stereo, the catalog says Video+Audio, the sound print found
// 76k landmarks, Verify Media says ok — and `loadTracks(withMediaType:
// .audio)` returns 0 tracks). The in-app player played picture only and
// said nothing.
//
// The fix is a comparison, not a decoder: when the app starts an AVPlayer
// it asks AVFoundation how many audio tracks it can read and compares that
// with the catalog's audio stream. A mismatch is a one-line notice over the
// player, naming the real codec, with the two ways out — another player,
// or an access copy (AAC) through the existing Transcode door.
//
// `words(catalogCodec:avAudioTracks:)` is pure so the rule is testable
// without a file; the track count is one async AVFoundation call.

import AVFoundation
import SwiftUI

enum PlaybackAudioMismatch {

    /// The notice the preview pane shows, keyed by the file it is about
    /// so a stale one never shows over the next row.
    struct Notice: Equatable {
        let path: String
        let text: String
    }

    /// Codec names as people know them (ffprobe `codec_name` → label).
    /// Data, not a switch: the list only grows.
    private static let displayNames: [String: String] = [
        "mp3": "MP3", "mp2": "MP2", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS",
        "truehd": "TrueHD", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC",
        "wmav1": "WMA", "wmav2": "WMA", "wmapro": "WMA", "unknown": "(unknown codec)"
    ]

    /// "MP3" for "mp3"; pcm_* keeps its exact spelling; anything else is
    /// upper-cased.
    static func displayName(_ codec: String) -> String {
        let key = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = displayNames[key] { return known }
        return key.hasPrefix("pcm_") ? "PCM (\(key))" : key.uppercased()
    }

    /// The notice, or nil when there is nothing to say: the catalog has
    /// no audio stream, or AVFoundation found at least one track.
    static func words(catalogCodec: String, avAudioTracks: Int) -> String? {
        let codec = catalogCodec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !codec.isEmpty, avAudioTracks <= 0 else { return nil }
        return "This file's \(displayName(codec)) sound can't be played by QuickTime. "
            + "Open in IINA/VLC, or make an access copy (AAC)."
    }

    /// The catalog's side of the comparison: the scanner's audio codec,
    /// or "unknown" for a Video+Audio row whose codec field is empty (the
    /// notice is still owed — the catalog says there IS sound). Empty
    /// means the catalog knows of no sound, so there is nothing to miss.
    static func catalogCodec(of rec: VideoRecord) -> String {
        if !rec.audioCodec.isEmpty { return rec.audioCodec }
        return rec.streamType == .videoAndAudio ? "unknown" : ""
    }

    /// How many audio tracks AVFoundation can read from `url`. 0 for
    /// MP3-in-MP4. Throws when the asset cannot be opened at all (mkv) —
    /// the preview router never starts an AVPlayer on those, so a throw
    /// here is a surprise the caller logs rather than hides.
    static func avAudioTrackCount(url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
    }
}

// MARK: - The notice over the player

/// One line over the preview player: the words, and the two ways out.
struct PlaybackAudioNoticeBar: View {
    let text: String
    /// "Open in VLC" when VLC is installed, else "Open With…" (the system
    /// default handler for the file).
    let openWithTitle: String
    let openWith: () -> Void
    let makeAccessCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(openWithTitle, action: openWith)
                .controlSize(.small)
                .accessibilityIdentifier("catalog.preview.audioMismatch.openWith")
            Button("Make Access Copy…", action: makeAccessCopy)
                .controlSize(.small)
                .accessibilityIdentifier("catalog.preview.audioMismatch.accessCopy")
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
        .accessibilityIdentifier("catalog.preview.audioMismatch")
    }
}
