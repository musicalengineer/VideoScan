// FileJourneyLadderRegressionTests.swift
// Bugs (Rick 2026-11-14, his screen capture of the File Journey opened on
// 1984-xx-xx_DickyTheBoysDadBreen-1985-3.mp4 in the Archive tab):
//
//   1. PRESERVATION read "2 of 4 … Next: Copy to archival storage — the
//      master RAID" while the same sheet's last line said "Now at
//      /Volumes/FamilyArchive/…". The sheet was opened on the archive copy
//      itself; the ladder only looked for ANOTHER row that was its copy.
//   2. "Catalogued Nov 5 '26" was the day of the last rescan, on a file
//      archived on Sep 23: every scan re-stamps `scanContext.scannedAt`.
//   3. A raw "ffprobe: [mov,mp4,… @ 0xb21034000] UDTA parsing failed" line
//      sat in the timeline as if it were an event.
//
// Written against the parts of the journey's API that exist before and after
// the fix (`preservation`, a step's `title` / `done` / `date` / `todo`,
// `events`), so the same file was run RED on main d6955ee6b (3 tests, 3 failed, 6 issues)
// and is green on the fix.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

@Suite("File Journey — regressions of 2026-11-14 (the ladder and the timeline tell the truth)", .serialized)
@MainActor
struct FileJourneyLadderRegressionTests {

    private static let sha = String(repeating: "cd", count: 32)
    private static let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }

    private static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_journey_ladder_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func record(path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 4096
        return r
    }

    /// Rick's file: the archive copy, a real file on disk with the whole-file
    /// SHA-256 Promote recorded, and the row it was promoted from.
    private static func archiveCopyWithSource(in dir: URL) throws -> (copy: VideoRecord, source: VideoRecord) {
        let sourceURL = dir.appendingPathComponent("Projects/MoviesExpansion/DickyTheBoysDadBreen-1985-3.mp4")
        let copyURL = dir.appendingPathComponent("Archive/30_Video/1980-1989/1984/1984-xx-xx_DickyTheBoysDadBreen-1985-3.mp4")
        for url in [sourceURL, copyURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }
        let source = record(path: sourceURL.path)
        source.notes = "Promote 2026-09-23T17:47:00Z: promoted to Master Archive as 30_Video/1980-1989/1984/1984-xx-xx_DickyTheBoysDadBreen-1985-3.mp4"
        let copy = record(path: copyURL.path)
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: day(2026, 10, 15), sizeBytes: 4096)
        copy.dateModifiedRaw = day(2025, 5, 9)
        copy.scanContext.scannedAt = day(2026, 11, 5)
        copy.notes = "Promote 2026-09-23T17:47:00Z: promoted from \(sourceURL.path) · sha256 \(sha) · readiness: audio verified, codec archival-safe"
        return (copy, source)
    }

    @Test("BUG 1: opened on the archive copy itself, the ladder says Archived and never 'Copy to archival storage'")
    func theArchiveCopyIsArchived() throws {
        let dir = try Self.scratch("selfcopy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (copy, source) = try Self.archiveCopyWithSource(in: dir)

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy],
                                                      resolveVolumeSafety: Self.neutral)

        let archived = journey.preservation.filter { $0.title.hasPrefix("Archived") && $0.done }
        #expect(!archived.isEmpty,
                "the copy is on disk in the archive with a SHA-256: \(journey.preservation.map { "\($0.title)=\($0.done)" })")
        let nagging = journey.preservation.filter { $0.todo.contains("Copy to archival storage") }
        #expect(nagging.isEmpty, "a file in the archive is not told to be archived: \(nagging.map(\.todo))")
        #expect(journey.events.last?.sentence.hasPrefix("Now at \(copy.fullPath)") == true,
                "and the last line still says where it is: \(journey.events.last?.sentence ?? "none")")
    }

    @Test("BUG 2: Catalogued is not the day of the last rescan")
    func cataloguedIsNotTheLastScan() throws {
        let dir = try Self.scratch("rescan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (copy, source) = try Self.archiveCopyWithSource(in: dir)
        // The catalog held this footage on Sep 1 (its signature was computed
        // then); the Ultra rescanned it on Nov 5.
        source.contentHashAt = Self.day(2026, 9, 1)
        source.scanContext.scannedAt = Self.day(2026, 11, 5)

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy],
                                                      resolveVolumeSafety: Self.neutral)

        let catalogued = try #require(journey.preservation.first { $0.title == "Catalogued" })
        #expect(catalogued.date != Self.day(2026, 11, 5), "Nov 5 is a rescan, long after the file was archived")
        #expect(catalogued.date == Self.day(2026, 9, 1), "the earliest date the catalog holds for this footage")
    }

    @Test("BUG 3: ffprobe's own text is a technical note, never a timeline event")
    func machineNotesAreNotEvents() throws {
        let dir = try Self.scratch("machinenote")   // not "ffprobe": the path is in the sentences
        defer { try? FileManager.default.removeItem(at: dir) }
        let (copy, source) = try Self.archiveCopyWithSource(in: dir)
        copy.notes += "\nffprobe: [mov,mp4,m4a,3gp,3g2,mj2 @ 0xb21034000] UDTA parsing failed retrying raw"

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy],
                                                      resolveVolumeSafety: Self.neutral)

        let leaked = journey.events.filter { $0.sentence.contains("ffprobe:") || $0.sentence.contains("UDTA") }
        #expect(leaked.isEmpty, "machine text in the timeline: \(leaked.map(\.sentence))")
        let raw = journey.events.filter { $0.sentence.hasPrefix("promoted from") || $0.sentence.contains("sha256") }
        #expect(raw.isEmpty, "the promote log line, verbatim, is not a sentence: \(raw.map(\.sentence))")
    }
}
