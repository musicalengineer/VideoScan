// FileJourneyReviewRedTests.swift
// The independent review of the File Journey rework (2026-11-14): six findings,
// each a test the reviewer ran RED on 7d6e5143e (6 tests, 6 failed), green since
// the fixes. Kept as the reviewer wrote them.
// Review of feat/file-journey-ladder (2026-11-14): each test pins one place
// where the File Journey sheet states something its evidence does not
// support. Every test is expected RED on 7d6e5143e.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

@Suite("File Journey — review findings (red on 7d6e5143e)", .serialized)
@MainActor
struct FileJourneyReviewRedTests {

    private static let sha = String(repeating: "ab", count: 32)
    private static let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }
    private static let now = day(2026, 11, 14)

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }

    private static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_journey_review_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A record whose file really exists (4096 bytes).
    private static func record(at url: URL) throws -> VideoRecord {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: url)
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 4096
        return r
    }

    private static func fullHash(at when: Date) -> ContentFixity {
        ContentFixity(digest: sha, byteCount: 4096,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: 4096, mtimeNs: 1), computedAt: when)
    }

    /// A promoted copy exactly as registerPromotedCopy leaves it.
    private static func promotedCopy(at url: URL, from source: VideoRecord) throws -> VideoRecord {
        let copy = try record(at: url)
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.originalFullPath = source.fullPath
        copy.archivedAt = day(2026, 9, 23)
        copy.lifecycleStage = .archived
        copy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: day(2026, 9, 23), sizeBytes: 4096)
        copy.notes = "Promote 2026-09-23T17:47:00Z: promoted from \(source.fullPath) · sha256 \(sha)"
        return copy
    }

    private static func extras(root: String?) -> FileJourneyBuilder.Extras {
        var e = FileJourneyBuilder.Extras()
        e.archiveRootPath = root
        e.archiveName = "FamilyArchive"
        e.now = now
        return e
    }

    // Pins FileJourneyBuilder.swift:384-386 (and :118, which makes any row under the root "the copy").
    @Test("TRUTH: a file nobody promoted, hashed once by Full Hashes, is never said to have been 'read back and matched'")
    func aHandPlacedFileWasNeverReadBack() throws {
        let dir = try Self.scratch("handplaced")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Archive").path
        // Dragged into the archive folder in Finder, found by a scan, hashed by
        // the Full Hashes analyzer. No promote, no source, nothing compared.
        let rec = try Self.record(at: URL(fileURLWithPath: root).appendingPathComponent("30_Video/Undated/dropped-in.mov"))
        rec.scanContext.scannedAt = Self.day(2026, 10, 1)
        rec.contentFixity = Self.fullHash(at: Self.day(2026, 10, 2))

        let journey = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: Self.neutral,
                                                      extras: Self.extras(root: root))

        let said = journey.events.filter { $0.sentence.contains("read back and matched") }.map(\.sentence)
        #expect(said.isEmpty, "one hash of one file is not a read-back that matched anything: \(said)")
    }

    // Pins FileJourneyBuilder.swift:380-383.
    @Test("TRUTH: 'Copied from' names the path Promote read (the copy's own record), never another row's present path")
    func copiedFromIsWhatPromoteRead() throws {
        let dir = try Self.scratch("copiedfrom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Archive").path
        let promoted = try Self.record(at: dir.appendingPathComponent("Projects/tape7.mov"))
        let copy = try Self.promotedCopy(at: URL(fileURLWithPath: root).appendingPathComponent("30_Video/1990-1999/tape7.mov"),
                                         from: promoted)
        // A byte-identical sibling on another drive, moved there by Migrate. It
        // is tied to the archive copy by whole-file SHA-256 only — which is what
        // provenArchivedCopy(of:) hands the builder.
        let sibling = try Self.record(at: dir.appendingPathComponent("Backup/tape7.mov"))
        sibling.originalFullPath = "/Volumes/OldDrive/tape7.mov"
        sibling.contentFixity = Self.fullHash(at: Self.day(2026, 9, 2))

        let journey = VideoScanModel.buildFileJourney(for: sibling, allRecords: [promoted, sibling, copy],
                                                      resolveVolumeSafety: Self.neutral, archivedCopy: copy,
                                                      extras: Self.extras(root: root))

        let archived = try #require(journey.events.first { $0.kind == .archived })
        #expect(!archived.sentence.contains("Copied from \(sibling.fullPath)"),
                "Promote read \(promoted.fullPath); the sheet says: \(archived.sentence)")
    }

    // Pins FileJourneyBuilder.swift:280-282.
    @Test("TRUTH: machine text sitting in userNotes (GH #176) is not the person's note and does not tick Reviewed")
    func machineTextInUserNotesIsNotReview() throws {
        let dir = try Self.scratch("usernotes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try Self.record(at: dir.appendingPathComponent("Projects/clip.mov"))
        let line = "ffprobe: [mov,mp4,m4a,3gp,3g2,mj2 @ 0xb21034000] UDTA parsing failed retrying raw"
        try #require(MachineNote.isMachineLine(line))
        rec.userNotes = line

        let journey = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: Self.neutral,
                                                      extras: Self.extras(root: nil))

        let reviewed = try #require(journey.preservation.first { $0.kind == .reviewed })
        #expect(!reviewed.done, "Reviewed ticked on ffprobe's words: \(reviewed.detail)")
    }

    // Pins FileJourneyBuilder.swift:187 (AnalyzeCoverageInput(record:) = unreadable: .none).
    @Test("TRUTH: the journey's Analyzed uses Catalog Status's rule for bytes another copy proved undecodable")
    func analyzedAgreesWhenACopyCannotBeDecoded() throws {
        let dir = try Self.scratch("undecodable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Archive").path
        let source = try Self.record(at: dir.appendingPathComponent("Projects/avid.mxf"))
        source.needsReformat = true                       // the dossier batch could not decode these bytes
        source.contentFixity = Self.fullHash(at: Self.day(2026, 9, 2))
        let copy = try Self.promotedCopy(at: URL(fileURLWithPath: root).appendingPathComponent("30_Video/Undated/avid.mxf"),
                                         from: source)

        // Catalog Status: captions do NOT apply to the archive copy (same bytes, flagged on the live copy).
        let inputs = AnalyzeCoverageCalculator.project([source, copy])
        let copyInput = try #require(inputs.first { $0.fullPath == copy.fullPath })
        try #require(!AnalyzeDossierVerdict(copyInput, scope: AnalysisScope()).video,
                     "fixture: Catalog Status must call the copy 'cannot decode'")

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy], resolveVolumeSafety: Self.neutral,
                                                      extras: Self.extras(root: root))
        let analyzed = try #require(journey.preservation.first { $0.kind == .analyzed })
        #expect(!analyzed.todo.contains("scene descriptions"),
                "a batch skips these bytes for ever, yet the sheet says: \(analyzed.detail) — \(analyzed.todo)")
    }

    // Pins FileJourneyBuilder.swift:455 and :478 (String.split on "\n" does not split "\r\n").
    @Test("ISOLATION: notes with CRLF line ends still yield the person's Update")
    func crlfNotesStillYieldTheUpdate() throws {
        let dir = try Self.scratch("crlf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Archive").path
        let source = try Self.record(at: dir.appendingPathComponent("Projects/a.mov"))
        let copy = try Self.promotedCopy(at: URL(fileURLWithPath: root).appendingPathComponent("30_Video/Undated/a.mov"),
                                         from: source)
        copy.notes += "\r\npromote: Update 2026-10-30T14:00:00Z: Name: A → B · 30_Video/a.mov → 30_Video/b.mov · sha256 verified before and after"

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy], resolveVolumeSafety: Self.neutral,
                                                      extras: Self.extras(root: root))
        let reviewed = try #require(journey.preservation.first { $0.kind == .reviewed })
        #expect(reviewed.done && reviewed.detail.contains("archived file updated"), "detail: '\(reviewed.detail)'")
    }

    // Pins FileJourneyBuilder.swift:117 (VolumeDashboardCalculator.isUnder is a raw string test).
    @Test("ISOLATION: an archive root written with a trailing slash is the same root")
    func trailingSlashRoot() throws {
        let dir = try Self.scratch("slash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Archive").path
        let rec = try Self.record(at: URL(fileURLWithPath: root).appendingPathComponent("30_Video/Undated/x.mov"))
        rec.contentFixity = Self.fullHash(at: Self.day(2026, 10, 2))

        let plain = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: Self.neutral,
                                                    extras: Self.extras(root: root))
        let slashed = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: Self.neutral,
                                                      extras: Self.extras(root: root + "/"))
        #expect(plain.preservation == slashed.preservation, "'\(root)' and '\(root)/' are one folder")
    }
}
