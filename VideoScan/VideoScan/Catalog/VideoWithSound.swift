// VideoWithSound.swift
// Show ▸ Videos with Sound (DECISIONS 2026-11-18, "Videos with Sound
// returns"; Rick: "show me the videos with good audio", the name "for now").
//
// THE RULE. A file the scan found to have a real picture stream AND at least
// one sound track: `streamType == .videoAndAudio`. PRESENCE ONLY — the stored
// sound check is never read here, so a left-only, mono, silent, damaged or
// never-checked track still counts, and so does a file with several tracks
// (the scan sets .videoAndAudio as soon as one audio stream exists). A paired
// picture half (.videoOnly, its sound in another file) is NOT listed: the file
// itself has no sound track.
//
// COVER ART IS NOT A PICTURE. The scanner (ScanEngine.extractMetadata, since
// 545258f) skips a video stream flagged `disposition.attached_pic`, so a song
// with album art scans as .audioOnly. Rows catalogued BEFORE that fix may still
// read .videoAndAudio with an mjpeg/png "video" codec; they are excluded here
// by the ONE rule that already names them, `CoverArtMusicPurge.isCandidate`
// (audio extension + cover-art codec + video stream type). No second rule.
//
// EVIDENCE. `streamTypeRaw` is written only from an ffprobe (or MXF header)
// read of the file. Empty, unknown or garbage → `.ffprobeFailed` → not listed.
//
// COST. O(1) per record from stored fields: one enum parse, and for a
// .videoAndAudio row one extension lookup and one codec compare. No disk.

import Foundation
import VideoScanCore

enum VideoWithSound {

    /// THE Show ▸ Videos with Sound test for one record.
    nonisolated static func matches(_ rec: VideoRecord) -> Bool {
        rec.streamType == .videoAndAudio && !CoverArtMusicPurge.isCandidate(rec)
    }
}
