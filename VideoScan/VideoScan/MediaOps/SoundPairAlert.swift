// SoundPairAlert.swift
// When Correlate finds no audio pair for a video-only file (Find A/V Pair,
// Find Matching Audio), say which sound files MAY belong to it and why
// (Rick 2026-10-10: Thanksgiving2009-DVD.m2v "has no audio pair" while its
// .ac3 sits beside it). The candidates are SoundPairRanker's — same folder
// or same footage, a tight length match — listed with their reasons. The
// person chooses: the one button opens the existing Combine sheet for the
// top candidate, and only when the lengths were measured and agree.
// Nothing is paired or muxed here.

import AppKit
import VideoScanCore

enum SoundPairAlert {

    /// Shows the candidates for `rec` if there are any; returns false (and
    /// shows nothing) when there are none, so the caller's own "no match"
    /// alert runs. `combine` receives the picture and the chosen sound file.
    @MainActor
    static func offer(for rec: VideoRecord, model: VideoScanModel,
                      combine: (VideoRecord, VideoRecord) -> Void) -> Bool {
        let candidates = SoundCopyFinder.pairCandidates(for: rec, model: model)
        guard let top = candidates.first else { return false }
        appLog.write("sound pair candidates: \(rec.filename) — \(candidates.count) (top \(top.audio.filename): \(top.reason))")
        let alert = NSAlert()
        alert.messageText = "Correlate found no automatic pair"
        alert.informativeText = "\(rec.filename)\n\n" + SoundCopyFinder.alertText(candidates)
            + (top.lengthMatches ? "" : "\n\nThis picture's length isn't recorded, so the lengths can't be "
               + "compared yet. Run a full Verify… on it first.")
        alert.alertStyle = .informational
        if top.lengthMatches {
            alert.addButton(withTitle: "Combine with \(top.audio.filename)\u{2026}")
            alert.addButton(withTitle: "Not Now")
        } else {
            alert.addButton(withTitle: "OK")
        }
        guard alert.runModal() == .alertFirstButtonReturn, top.lengthMatches,
              let audio = model.record(forID: top.audio.id) else { return true }
        model.log("Combine with its sound: \(rec.filename) + \(audio.filename) — \(top.reason)")
        combine(rec, audio)
        return true
    }
}
