// VideoScanModel+ArchivePlayable.swift
// THE one resolver behind every door on an Archive tab item — play / open,
// Reveal in Finder, the detail sheet's file facts (Rick 2026-10-16).
//
// The bug: the Archive timeline shows a promotion SOURCE row (the file
// Promote read from), and its doors opened the source's own path. Row
// AAB6EF57 was a symlink in ~/Movies whose target had moved, so every door
// said "does not exist" while the archived copy sat on FamilyArchive with
// a recorded fixity. The card already resolved the copy for its folder
// name (ArchiveView+Timeline.timelineItem); the doors did not.
//
// The rule, in order:
//   1. a promotion source → its archived copy, when the copy is on disk;
//   2. else the row itself, when ITS file is on disk;
//   3. else `.missing` — and the words name the ARCHIVE path, never the
//      source path, and say Verify Archive.
// A row with no archived copy at all is simply itself (the ordinary
// looks-moved story handles a gone file there).
//
// One `stat` per door click — never in a view body.

import Foundation

/// What an Archive door acts on.
enum ArchivePlayable {
    /// Open / reveal THIS record — the archived copy for a promotion
    /// source whose copy is on disk, else the row itself.
    case record(VideoRecord)
    /// Neither the row's file nor its archived copy is on disk.
    /// `archivePath` is the archived copy's path (the only path the words
    /// may name); `message` is what the person reads.
    case missing(archivePath: String, message: String)

    var record: VideoRecord? {
        if case .record(let rec) = self { return rec }
        return nil
    }

    var message: String? {
        if case .missing(_, let words) = self { return words }
        return nil
    }

    /// The path a door would act on (the archive path when missing).
    var path: String {
        switch self {
        case .record(let rec): return rec.fullPath
        case .missing(let archivePath, _): return archivePath
        }
    }
}

extension VideoScanModel {

    /// "Is a regular file there?" — injectable so the rule is testable
    /// without a disk. The default follows symlinks (a dangling link is
    /// "not there"), which is exactly Rick's case.
    typealias FileExistsProbe = (String) -> Bool

    /// Resolve the record an Archive door should open for `rec`.
    func archivePlayableRecord(for rec: VideoRecord,
                               fileExists: FileExistsProbe = { FileManager.default.fileExists(atPath: $0) }) -> ArchivePlayable {
        // PROVEN copy only (GH #327): a sampled-signature match may be
        // other bytes, so the door never opens it in this row's place.
        let copy = isArchiveCopy(rec) ? rec : provenArchivedCopy(of: rec)
        guard let copy else { return .record(rec) }
        if fileExists(copy.fullPath) { return .record(copy) }
        if copy.id != rec.id, fileExists(rec.fullPath) { return .record(rec) }
        return .missing(archivePath: copy.fullPath,
                        message: Self.archiveMissingWords(filename: copy.filename, archivePath: copy.fullPath))
    }

    /// The words for a file the archive should hold but does not — the
    /// archive path, and the door that checks every copy. Pure.
    nonisolated static func archiveMissingWords(filename: String, archivePath: String) -> String {
        "\(filename): the archived file is not at its path — run Verify Archive. Expected at \(archivePath)"
    }
}
