// FileJourneyTruthTests.swift
// Bug (Rick 2026-10-16): the File Journey sheet lied about the content it
// was following. For the promotion-source row AAB6EF57 (a dangling symlink
// in ~/Movies) it showed PRESERVATION "1 of 4" with Signed / Archived
// locally empty and "Next: Compute a file signature…" — while the SAME
// sheet's timeline said "promoted to Master Archive as 30_Video/…" and the
// archived copy exists with a recorded SHA-256 fixity; the first event read
// "Feb 22, 2024 — Scanned on M4drive at …" (that is the file's mtime, not a
// scan); and the last event said "Now at /Users/rickb/Movies/…" although
// nothing is there.
//
// Pins (RED on the old builder, all through the existing pure seam
// `VideoScanModel.buildFileJourney(for:allRecords:resolveVolumeSafety:)`):
//   * a source row with a dead link path + an archived copy with fixity →
//     ladder 3 of 4 (Catalogued, Signed, Archived locally), first event
//     "File dated…", a separate "Catalogued" event, last event
//     "Not at … link … the archived copy is at …";
//   * a plain live row → unchanged: 1 of 4, "Now at <path>", two events.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

private enum JourneyFixture {
    static let sha = String(repeating: "ab", count: 32)

    static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_journey_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }

    @MainActor
    static func record(path: String, bytes: Int64 = 4096) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = bytes
        r.partialMD5 = "abcd0001"
        return r
    }

    /// Rick's case: the source is a symlink whose target moved; the
    /// archived copy is a real file with a recorded whole-file SHA-256.
    @MainActor
    static func deadLinkSourceWithArchivedCopy(in dir: URL) throws -> (source: VideoRecord, copy: VideoRecord) {
        let target = dir.appendingPathComponent("gone/Christmas-1990.mov")
        let link = dir.appendingPathComponent("Christmas-1990.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let copyURL = dir.appendingPathComponent("Archive/30_Video/1990-1999/1990/1990_Christmas-1990.mov")
        try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: copyURL)

        let source = record(path: link.path)
        source.archiveStage = .masterAssigned
        source.dateModifiedRaw = day(2024, 2, 22)
        source.scanContext.scannedAt = day(2026, 8, 12)
        source.notes = "Promote 2026-08-12T15:00:00Z: promoted to Master Archive as 30_Video/1990-1999/1990/1990_Christmas-1990.mov"

        let copy = record(path: copyURL.path)
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: day(2026, 8, 12), sizeBytes: 4096)
        return (source, copy)
    }
}

private let neutralResolver: VolumeSafetyResolver = { _ in VolumeSafety.unknown }

// MARK: - The sheet's truth

@Suite("File Journey — tells the truth about the content", .serialized)
@MainActor
struct FileJourneyTruthTests {

    @Test func deadLinkSourceWithArchivedCopyIsSignedAndArchivedLocally() throws {
        let dir = try JourneyFixture.scratch("deadlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy) = try JourneyFixture.deadLinkSourceWithArchivedCopy(in: dir)

        let journey = VideoScanModel.buildFileJourney(for: source, allRecords: [source, copy],
                                                      resolveVolumeSafety: neutralResolver)

        let done = journey.preservation.filter(\.done).map(\.kind)
        #expect(done == [.catalogued, .signed, .archivedLocally],
                "ladder must answer for the CONTENT (its archived copy carries the SHA-256): \(journey.preservation.map { "\($0.kind)=\($0.done)" })")
        #expect(journey.preservation.first { !$0.done }?.kind == .archivedOffsite,
                "Next: must follow from the ladder — the only open step is the offsite copy")
    }

    @Test func firstEventIsTheFilesOwnDateNeverAScan() throws {
        let dir = try JourneyFixture.scratch("firstevent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy) = try JourneyFixture.deadLinkSourceWithArchivedCopy(in: dir)

        let journey = VideoScanModel.buildFileJourney(for: source, allRecords: [source, copy],
                                                      resolveVolumeSafety: neutralResolver)

        let first = try #require(journey.events.first)
        #expect(first.sentence.hasPrefix("File dated"), "an mtime is not a scan: \(first.sentence)")
        #expect(first.sentence.contains("from the file's own clock"), Comment(rawValue: first.sentence))
        #expect(!first.sentence.hasPrefix("Scanned"), Comment(rawValue: first.sentence))
        let catalogued = journey.events.first { $0.sentence.hasPrefix("Catalogued") }
        #expect(catalogued != nil, "the catalog's own date is its own event: \(journey.events.map(\.sentence))")
        #expect(catalogued?.timestamp == JourneyFixture.day(2026, 8, 12))
    }

    @Test func lastEventIsAVerifiedPresenceThatNamesTheArchivedCopy() throws {
        let dir = try JourneyFixture.scratch("lastevent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy) = try JourneyFixture.deadLinkSourceWithArchivedCopy(in: dir)

        let journey = VideoScanModel.buildFileJourney(for: source, allRecords: [source, copy],
                                                      resolveVolumeSafety: neutralResolver)

        let last = try #require(journey.events.last)
        #expect(last.kind == .notAtPath, "a gone file is drawn orange, never the green pin")
        #expect(last.sentence.hasPrefix("Not at \(source.fullPath)"), Comment(rawValue: last.sentence))
        #expect(last.sentence.contains("link"), "a dead symlink must be called a link: \(last.sentence)")
        #expect(last.sentence.contains("which is gone"), Comment(rawValue: last.sentence))
        #expect(last.sentence.contains("the archived copy is at \(copy.fullPath)"), Comment(rawValue: last.sentence))
        #expect(!last.sentence.hasPrefix("Now at"), "nothing is there: \(last.sentence)")
    }

    /// A plain live row (a real file, nothing archived, no catalog date on
    /// the record): the ladder and the timeline read as before.
    @Test func plainLiveRowIsUnchanged() throws {
        let dir = try JourneyFixture.scratch("live")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 1, count: 2048).write(to: url)
        let rec = JourneyFixture.record(path: url.path)

        let journey = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec],
                                                      resolveVolumeSafety: neutralResolver)

        #expect(journey.preservation.filter(\.done).map(\.kind) == [.catalogued])
        #expect(journey.events.count == 2, Comment(rawValue: journey.events.map(\.sentence).joined(separator: " | ")))
        #expect(journey.events.last?.sentence == "Now at \(url.path)")
    }
}

// MARK: - Pure helpers: presence words and the ladder (no model)

@Suite("File Journey — JourneyPresence", .serialized)
struct JourneyPresenceTests {

    @Test func probeTellsARegularFileFromALinkFromNothing() throws {
        let dir = try JourneyFixture.scratch("presence")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mov")
        try Data(repeating: 1, count: 16).write(to: file)
        let live = dir.appendingPathComponent("live-link.mov")
        try FileManager.default.createSymbolicLink(at: live, withDestinationURL: file)
        let dead = dir.appendingPathComponent("dead-link.mov")
        try FileManager.default.createSymbolicLink(at: dead, withDestinationURL: dir.appendingPathComponent("gone.mov"))

        #expect(JourneyPresence.probe(file.path) == .regularFile)
        #expect(JourneyPresence.probe(live.path) == .linkToFile(target: file.path))
        #expect(JourneyPresence.probe(dead.path) == .brokenLink(target: dir.appendingPathComponent("gone.mov").path))
        #expect(JourneyPresence.probe(dir.appendingPathComponent("nothing.mov").path) == .missing)
        #expect(JourneyPresence.probe(dir.path) == .notAFile)
        #expect(JourneyPresence.probe("") == .missing)
        #expect(JourneyPresence.probe("/Volumes/NoSuchDrive_\(UUID().uuidString.prefix(6))/x.mov",
                                      isVolumeMounted: { _ in false }).isPresent == false)
    }

    @Test func wordsNameTheLinkTheGapAndTheArchivedCopy() {
        let archive = JourneyPresence.ArchivedCopy(path: "/Volumes/FamilyArchive/A/1990_X.mov", presence: .regularFile)
        let dead = JourneyPresence.currentSentence(path: "/Users/rickb/Movies/X.mov",
                                                   presence: .brokenLink(target: "/Volumes/Projects/X.mov"),
                                                   archivedCopy: archive)
        #expect(dead == "Not at /Users/rickb/Movies/X.mov — it is a link to /Volumes/Projects/X.mov, which is gone · the archived copy is at /Volumes/FamilyArchive/A/1990_X.mov")

        let gone = JourneyPresence.currentSentence(path: "/Volumes/L/X.mov", presence: .missing, archivedCopy: nil)
        #expect(gone == "Not at /Volumes/L/X.mov — the file is gone · Catalog Status ▸ Fix Links can relink or forget this row")

        let bothGone = JourneyPresence.currentSentence(
            path: "/Volumes/L/X.mov", presence: .missing,
            archivedCopy: JourneyPresence.ArchivedCopy(path: "/Volumes/FamilyArchive/A/X.mov", presence: .missing))
        #expect(bothGone.hasSuffix("the archived copy should be at /Volumes/FamilyArchive/A/X.mov but is not there either — run Verify Archive"))

        #expect(JourneyPresence.currentSentence(path: "/V/a.mov", presence: .regularFile, archivedCopy: nil) == "Now at /V/a.mov")
        #expect(JourneyPresence.currentSentence(path: "/V/a.mov", presence: .linkToFile(target: "/W/a.mov"), archivedCopy: nil)
                == "Now at /V/a.mov — a link to /W/a.mov, where the file is")
        #expect(JourneyPresence.currentSentence(path: "/Volumes/L/a.mov", presence: .volumeOffline(volume: "L"), archivedCopy: nil)
                .hasPrefix("Not reachable — L is not connected"))
    }
}

@Suite("File Journey — the ladder answers for the content")
@MainActor
struct PreservationChecklistContentTests {

    private func rec(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    @Test func archivedCopyFixitySignsAndArchivesTheSource() {
        let source = rec("/Users/rickb/Movies/X.mov")
        source.archiveStage = .masterAssigned
        let copy = rec("/Volumes/FamilyArchive/A/1990_X.mov")
        copy.archiveFixity = ArchiveFixity(digest: JourneyFixture.sha, verifiedAt: JourneyFixture.day(2026, 8, 12), sizeBytes: 10)

        let steps = PreservationChecklist.steps(for: source, archivedCopy: copy)
        #expect(steps.map(\.done) == [true, true, true, false])
        #expect(steps[1].date == JourneyFixture.day(2026, 8, 12), "Signed carries the fixity's date")
        #expect(steps[2].date == JourneyFixture.day(2026, 8, 12))
        #expect(PreservationChecklist.completion(for: source, archivedCopy: copy) == 0.75)
        #expect(PreservationChecklist.nextAction(for: source, archivedCopy: copy)?.contains("out of the building") == true)
    }

    @Test func withoutACopyTheLadderIsAsBefore() {
        let source = rec("/Users/rickb/Movies/X.mov")
        #expect(PreservationChecklist.steps(for: source).map(\.done) == [true, false, false, false])
        #expect(PreservationChecklist.nextAction(for: source)?.contains("signature") == true)
    }

    /// A copy whose fixity is not a whole-file SHA-256 (or absent) proves
    /// nothing — the ladder must not tick on a promise.
    @Test func aCopyWithoutFixityProvesNothing() {
        let source = rec("/Users/rickb/Movies/X.mov")
        let copy = rec("/Volumes/FamilyArchive/A/1990_X.mov")
        #expect(PreservationChecklist.steps(for: source, archivedCopy: copy).map(\.done) == [true, false, false, false])
        copy.archiveFixity = ArchiveFixity(algorithm: "md5", digest: "abcd", verifiedAt: Date(), sizeBytes: 10)
        let steps = PreservationChecklist.steps(for: source, archivedCopy: copy)
        #expect(steps[1].done == false, "an md5 is not a whole-file SHA-256 signature")
    }
}
