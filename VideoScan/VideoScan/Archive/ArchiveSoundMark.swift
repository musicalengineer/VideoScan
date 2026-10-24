// ArchiveSoundMark.swift
// The Archive tab's yellow "no sound" mark (Rick 2026-10-23: "put a yellow
// mark in UI if audio is not there … only videos from 1980 and after").
//
// Which record is judged: the ARCHIVED copy — for a promotion-source row,
// its Master Archive copy (that is the file kept forever); for a copy row,
// itself. The answer is SoundPresencePolicy's (VideoScanCore, the one rule)
// over that record's stream type, its stored full-Verify sound measurement
// and its CURRENT date. No new rule lives here.
//
// (For Rick: a caseless `enum` with statics ≈ a C++ namespace of free
// functions; it cannot be instantiated.)

import VideoScanCore

@MainActor
enum ArchiveSoundMark {

    /// The policy's answer for the file the row stands for. O(1):
    /// `masterArchiveCopy(of:)` is the memoized index.
    static func presence(for rec: VideoRecord, model: VideoScanModel) -> SoundPresence {
        judged(rec, copy: model.isArchiveCopy(rec) ? nil : model.masterArchiveCopy(of: rec)).measuredSoundPresence
    }

    /// The record whose sound is judged: the archive copy when the row is
    /// its promotion source, else the row. Pure; the seam the tests use.
    nonisolated static func judged(_ rec: VideoRecord, copy: VideoRecord?) -> VideoRecord {
        copy ?? rec
    }
}
