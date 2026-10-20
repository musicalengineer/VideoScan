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

// MARK: - The external-player door (GH #332, 2026-10-19)
//
// The Archive tab (and every other "open / play" door) hands files to
// QuickTime Player or VLC through `MediaOpener.open`. Its choice came from
// a codec allow-list alone, so MP3 sound in an .m4v went to QuickTime and
// played SILENTLY. The same comparison the in-app player makes now runs
// before a QuickTime launch: QuickTime only when AVFoundation reads the
// audio track the catalog knows about; otherwise VLC (plays it) with a
// line saying why, or — no VLC — the system handler plus words a person
// must read.

extension PlaybackAudioMismatch {

    /// One line about a file the door re-routed or could not route to a
    /// player with sound. `needsAttention` = no player with sound was
    /// available; the caller must show the words, not only log them.
    struct RouteNote: Equatable {
        let path: String
        let words: String
        let needsAttention: Bool
    }

    struct RouteCheck: Equatable {
        let choice: MediaPlayerChoice
        let note: RouteNote?
    }

    /// MediaOpener's codec choice, verified for QuickTime: `trackCount` is
    /// the one AVFoundation call (injectable for tests). VLC / default
    /// choices pass through untouched — no I/O.
    @MainActor
    static func checkedChoice(for rec: VideoRecord, url: URL, hasVLC: Bool,
                              trackCount: (URL) async throws -> Int = PlaybackAudioMismatch.avAudioTrackCount(url:)) async -> RouteCheck {
        let base = MediaOpener.preferredPlayer(for: rec, hasVLC: hasVLC)
        let codec = catalogCodec(of: rec)
        guard base == .quickTime, !codec.isEmpty else { return RouteCheck(choice: base, note: nil) }
        let why: String
        do {
            let tracks = try await trackCount(url)
            guard words(catalogCodec: codec, avAudioTracks: tracks) != nil else {
                return RouteCheck(choice: .quickTime, note: nil)
            }
            why = "QuickTime can't play its \(displayName(codec)) sound in \(containerLabel(rec))"
        } catch {
            why = "QuickTime can't read its sound (\(error.localizedDescription))"
        }
        return RouteCheck(choice: hasVLC ? .vlc : .systemDefault,
                          note: routeNote(rec, why: why, hasVLC: hasVLC))
    }

    /// "M4V" from the record's extension, else "this container".
    static func containerLabel(_ rec: VideoRecord) -> String {
        let ext = rec.ext.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ext.isEmpty ? "this container" : ext
    }

    /// The words: re-routed to VLC (heard), or no player with sound.
    static func routeNote(_ rec: VideoRecord, why: String, hasVLC: Bool) -> RouteNote {
        if hasVLC {
            return RouteNote(path: rec.fullPath,
                             words: "\(rec.filename): \(why) — opened in VLC so it plays with sound.",
                             needsAttention: false)
        }
        return RouteNote(path: rec.fullPath,
                         words: "\(rec.filename): plays in QuickTime: no — \(why). "
                             + "Open it in IINA or VLC, or make an access copy (AAC).",
                         needsAttention: true)
    }
}

// MARK: - Playback identity (codex P2, 2026-10-16)

/// The check is async; the player it was started for may be gone by the
/// time AVFoundation answers. Every player start takes a ticket here, and
/// a check's result counts only while its ticket is still the current one
/// — so the first file's "no sound" can never land over the second file's
/// player. (For Rick: a generation counter; a stale ticket is an ABA guard.)
@MainActor
final class PlaybackAudioChecker {
    private(set) var generation = 0

    enum Outcome: Equatable {
        /// The player this check was started for is gone — say nothing.
        case stale
        /// AVFoundation reads a track, or the catalog knows of no sound.
        case fine
        case notice(words: String, tracks: Int)
        /// The asset could not be opened at all; `String` is the error.
        case unreadable(String)
    }

    /// Call on EVERY player start; the ticket identifies that player.
    func playerStarted() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ ticket: Int) -> Bool { ticket == generation }

    /// Compare the catalog's codec with what AVFoundation reads, for the
    /// player `ticket`. `trackCount` is the one AVFoundation call,
    /// injectable for tests.
    func outcome(ticket: Int, catalogCodec: String, url: URL,
                 trackCount: (URL) async throws -> Int = PlaybackAudioMismatch.avAudioTrackCount(url:)) async -> Outcome {
        let result: Outcome
        do {
            let tracks = try await trackCount(url)
            result = PlaybackAudioMismatch.words(catalogCodec: catalogCodec, avAudioTracks: tracks)
                .map { Outcome.notice(words: $0, tracks: tracks) } ?? .fine
        } catch {
            result = .unreadable(error.localizedDescription)
        }
        return isCurrent(ticket) ? result : .stale
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
