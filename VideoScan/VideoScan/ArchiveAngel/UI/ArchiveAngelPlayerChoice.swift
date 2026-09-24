// ArchiveAngelPlayerChoice.swift
// "Play" on an Archive Angel row (Rick 2026-09-24): pick the player
// intelligently — QuickTime where it plays picture AND sound, VLC for what
// QuickTime can't (mkv, avi, raw dv, mxf, flv, wmv, vob, mpeg-2, ogg/webm,
// off-list codecs), and SAY so when VLC is needed but not installed.
//
// NOT a second player policy: the decision is MediaOpener.preferredPlayer
// (CatalogHelpers.swift — the catalog's double-click, Hallie's Play and
// Person Finder all use it), and the launch is MediaOpener.open. This file
// only adds the plain-words reason and the log line for this surface.
// MediaOpener decides from cataloged ffprobe fields with zero runtime
// probing — deliberately; a runtime AVURLAsset.isPlayable probe on a
// sleeping drive is the beachball class (codex #303/#305). An unknown or
// unlisted container/codec already falls through to VLC.

import AppKit
import Foundation

enum ArchiveAngelPlayerChoice {

    struct Decision: Equatable, Sendable {
        var choice: MediaPlayerChoice
        /// Plain words for the console: where it plays and why.
        var sentence: String
    }

    /// Pure. `ext` is the file extension (any case), codecs are ffprobe
    /// codec_name values ("" = none / unknown).
    static func decide(filename: String, ext: String, videoCodec: String, audioCodec: String,
                       hasVLC: Bool) -> Decision {
        let choice = MediaOpener.preferredPlayer(container: ext, videoCodec: videoCodec,
                                                 audioCodec: audioCodec, hasVLC: hasVLC)
        // Why QuickTime was ruled out: the container itself (probe the
        // policy with a codec pair it always accepts), or the codecs inside.
        let containerOK = MediaOpener.preferredPlayer(container: ext, videoCodec: "h264",
                                                      audioCodec: "aac", hasVLC: true) == .quickTime
        let kind = ext.isEmpty ? "this kind of file" : ".\(ext.lowercased()) files"
        let why = containerOK
            ? "QuickTime can't reliably play its picture or sound (\(codecText(videoCodec, audioCodec)))"
            : "QuickTime can't open \(kind)"
        switch choice {
        case .quickTime:
            return Decision(choice: choice, sentence: "Playing \(filename) in QuickTime Player.")
        case .vlc:
            return Decision(choice: choice, sentence: "Playing \(filename) in VLC — \(why).")
        case .systemDefault:
            return Decision(choice: choice,
                            sentence: "\(filename) needs VLC — \(why) — but VLC is not installed "
                                + "(videolan.org). Trying the Mac's default player instead.")
        }
    }

    private static func codecText(_ v: String, _ a: String) -> String {
        let parts = [v.isEmpty ? "video codec unknown" : v, a.isEmpty ? "no audio codec listed" : a]
        return parts.joined(separator: " / ")
    }

    /// Main-actor launch: says where it plays (console + unified log via
    /// `log`), then hands the record to the shared opener. An offline
    /// volume is said, not attempted.
    @MainActor
    static func play(_ rec: VideoRecord, log: @escaping (String) -> Void) {
        // The drive question from the mount table (QA P2-2) — a missing
        // file on a mounted disk is "not found", not "offline".
        guard VolumeReachability.isVolumeReachable(path: rec.fullPath) else {
            let volume = MediaVolumeGatePolicy.volumeRoot(forPath: rec.fullPath)
            log("Archive Angel: \(rec.filename) is on an offline drive (\(volume)) — connect it to play.")
            return
        }
        let d = decide(filename: rec.filename, ext: rec.ext, videoCodec: rec.videoCodec,
                       audioCodec: rec.audioCodec, hasVLC: MediaOpener.hasVLC)
        let path = rec.fullPath
        Task { @MainActor in
            // One stat, off the main actor (a spun-down disk can take seconds).
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard exists else {
                log("Archive Angel: \(rec.filename) was not found — its drive is connected but the file is not there (moved or deleted since cataloging).")
                return
            }
            log("Archive Angel: " + d.sentence)
            MediaOpener.open([rec])
        }
    }
}
