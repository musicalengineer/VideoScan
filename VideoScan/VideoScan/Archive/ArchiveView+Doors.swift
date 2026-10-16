// ArchiveView+Doors.swift
// The Archive tab's doors — play / open and Reveal in Finder — for the
// Timeline cards, their version chips, the Files table and the Family
// Music shelf. Every one resolves through `archivePlayableRecord(for:)`
// (VideoScanModel+ArchivePlayable.swift) so a promotion source whose own
// file is gone opens its archived copy, and a file the archive has lost
// says so with the ARCHIVE path (Rick 2026-10-16). The source sensor in
// ArchivePlayableRecordTests keeps every other ArchiveView file out of
// MediaOpener and Finder.

import AppKit
import SwiftUI

extension ArchiveView {

    /// Play / open `ids` (double-click, the card tap, a version chip, ⌘O
    /// on the table). Resolved rows go to MediaOpener's smart chooser in
    /// one batch; a row the archive has lost is reported, never launched.
    func openArchiveItems(_ ids: [UUID]) {
        var targets: [VideoRecord] = []
        var viaCopy = 0
        var missing: [String] = []
        for id in ids {
            guard let rec = model.record(forID: id) else { continue }
            switch model.archivePlayableRecord(for: rec) {
            case .record(let target):
                if target.id != rec.id { viaCopy += 1 }
                targets.append(target)
            case .missing(_, let message):
                missing.append(message)
            }
        }
        reportArchiveDoor(verb: "Open", viaCopy: viaCopy, missing: missing)
        if !targets.isEmpty { MediaOpener.open(targets) }
    }

    /// Reveal in Finder — the archived copy for a promotion source.
    func revealArchiveItem(_ rec: VideoRecord) {
        switch model.archivePlayableRecord(for: rec) {
        case .record(let target):
            reportArchiveDoor(verb: "Reveal", viaCopy: target.id == rec.id ? 0 : 1, missing: [])
            NSWorkspace.shared.selectFile(target.fullPath, inFileViewerRootedAtPath: "")
        case .missing(_, let message):
            reportArchiveDoor(verb: "Reveal", viaCopy: 0, missing: [message])
        }
    }

    /// Console + catalog.log through the one sink, and the alert for a
    /// lost file. Quiet when a door simply opened the row it was given.
    private func reportArchiveDoor(verb: String, viaCopy: Int, missing: [String]) {
        if viaCopy > 0 {
            model.log("Archive \(verb): \(viaCopy) file(s) through the archived copy — the source row's own file is not used on this tab.")
        }
        guard !missing.isEmpty else { return }
        for words in missing { model.log("Archive \(verb): \(words)") }
        playRefusal = missing.joined(separator: "\n")
    }
}
