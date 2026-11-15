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
//     Catalogued and Archived ticked (the ladder is Catalogued · Analyzed ·
//     Reviewed · Archived since 2026-11-14), first event "File dated…", a
//     separate "Catalogued" event, last event "Not at … link … the archived
//     copy is at …";
//   * a plain live row → 1 of 4, "Now at <path>", two events.

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

    @Test func deadLinkSourceWithArchivedCopyIsArchived() throws {
        let dir = try JourneyFixture.scratch("deadlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy) = try JourneyFixture.deadLinkSourceWithArchivedCopy(in: dir)

        let journey = VideoScanModel.buildFileJourney(for: source, allRecords: [source, copy],
                                                      resolveVolumeSafety: neutralResolver)

        let done = journey.preservation.filter(\.done).map(\.kind)
        #expect(done == [.catalogued, .archived],
                "ladder must answer for the CONTENT (its archived copy carries the SHA-256): \(journey.preservation.map { "\($0.kind)=\($0.done)" })")
        #expect(journey.preservation.map(\.kind) == [.catalogued, .analyzed, .reviewed, .archived],
                "no Offsite step until the person has answered")
        #expect(PreservationChecklist.nextAction(journey.preservation) == PreservationChecklist.reviewTodo,
                "Next: must follow from the ladder — the person's first open step")
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
        let when = try #require(catalogued?.timestamp)
        #expect(Calendar.current.isDate(when, inSameDayAs: JourneyFixture.day(2026, 8, 12)))
        #expect(catalogued?.displayStamp.hasPrefix("On or before ") == true,
                "the first day was never recorded — the date is a bound and says so")
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

    /// codex P1 (2026-10-16): "Archived locally" ticked on ANY non-nil
    /// archiveFixity. A copy record with a valid SHA-256 whose file is no
    /// longer on disk proves nothing about a local copy; the ladder must
    /// say so and point at Verify Archive.
    @Test func archivedCopyGoneFromDiskDoesNotCompleteArchivedLocally() throws {
        let dir = try JourneyFixture.scratch("copygone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy) = try JourneyFixture.deadLinkSourceWithArchivedCopy(in: dir)
        try FileManager.default.removeItem(atPath: copy.fullPath)

        let journey = VideoScanModel.buildFileJourney(for: source, allRecords: [source, copy],
                                                      resolveVolumeSafety: neutralResolver)

        let local = try #require(journey.preservation.first { $0.kind == .archived })
        #expect(!local.done, "the copy's file is gone — a recorded digest is not a copy on disk")
        #expect(local.todo.contains("Verify Archive"), Comment(rawValue: local.todo))
        #expect(journey.preservation.filter(\.done).count < 3)
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

    /// codex P2 (2026-10-16): the ancestor-link check compared the resolved
    /// folder's device with the FILE's — always equal, the file sits inside
    /// that folder — so ~/Movies → /Volumes/Media/Movies was never named.
    /// The test disk is one device, so the device seam stands in for two:
    /// whatever RESOLVES under the pretend volume is disk 2, the rest disk 1.
    @Test func ancestorLinkOntoAnotherDiskIsNamed() throws {
        let dir = try JourneyFixture.scratch("xdisk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = dir.appendingPathComponent("Volume/Media/Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: volume.appendingPathComponent("a.mov"))
        let link = dir.appendingPathComponent("Movies")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: volume)
        let file = link.appendingPathComponent("a.mov").path
        let twoDisks: (String) -> dev_t? = { path in
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real).contains("/Volume/") ? 2 : 1
        }

        #expect(JourneyPresence.linkedAncestorOnAnotherDisk(of: file, device: twoDisks) == link.path)
        #expect(JourneyPresence.probe(file, device: twoDisks) == .regularFileThroughLink(at: link.path))
        let words = JourneyPresence.currentSentence(path: file, presence: .regularFileThroughLink(at: link.path), archivedCopy: nil)
        #expect(words == "Now at \(file) — reached through a link at \(link.path)")
        // Same-disk plumbing (/var → /private/var) is not news.
        #expect(JourneyPresence.probe(file, device: { _ in 1 }) == .regularFile)
        #expect(JourneyPresence.linkedAncestorOnAnotherDisk(of: file, device: { _ in 1 }) == nil)
    }

    /// codex P1 (2026-10-16): every failed lstat read as `.missing`. A
    /// parent folder we may not read (EACCES) says nothing about whether
    /// the file is there — presence is UNKNOWN, never "gone", and the
    /// words must not offer Fix Links for a file that may well exist.
    @Test func permissionDeniedIsUnknownNeverGone() throws {
        let dir = try JourneyFixture.scratch("eacces")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("a.mov")
        try Data(repeating: 1, count: 16).write(to: file)
        try #require(geteuid() != 0, "root ignores mode bits — this pin needs an ordinary user")
        try #require(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }

        let presence = JourneyPresence.probe(file.path)
        #expect(presence != .missing, "EACCES is not ENOENT: \(presence)")
        #expect(!presence.isPresent)
        let words = JourneyPresence.currentSentence(path: file.path, presence: presence, archivedCopy: nil)
        #expect(!words.contains("gone"), Comment(rawValue: words))
        #expect(!words.contains("Fix Links"), Comment(rawValue: words))
        #expect(words.contains("Could not check \(file.path)"), Comment(rawValue: words))
        #expect(words.contains("Permission denied"), Comment(rawValue: words))
        #expect(words.hasSuffix("presence unknown"), Comment(rawValue: words))
    }

    /// codex P1 (2026-10-16): the archived copy's presence was reduced to
    /// a Bool, so a copy on an unplugged drive read "not there either —
    /// run Verify Archive". Each presence of the copy has its own words.
    @Test func archivedCopyPresenceIsSaidInItsOwnWords() {
        let path = "/Volumes/FamilyArchive/A/X.mov"
        func sentence(_ presence: JourneyPresence) -> String {
            JourneyPresence.currentSentence(path: "/Users/rickb/Movies/X.mov", presence: .missing,
                                            archivedCopy: JourneyPresence.ArchivedCopy(path: path, presence: presence))
        }
        let offline = sentence(.volumeOffline(volume: "FamilyArchive"))
        #expect(offline.hasSuffix("the archived copy is on FamilyArchive, which is not connected"), Comment(rawValue: offline))
        #expect(!offline.contains("Verify Archive"), "an unplugged drive is not a lost copy: \(offline)")

        let gone = sentence(.missing)
        #expect(gone.hasSuffix("the archived copy is not at its path (\(path)) — run Verify Archive"), Comment(rawValue: gone))

        let dead = sentence(.brokenLink(target: "/Volumes/Old/X.mov"))
        #expect(dead.contains("run Verify Archive"), Comment(rawValue: dead))
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
        #expect(bothGone.hasSuffix("the archived copy is not at its path (/Volumes/FamilyArchive/A/X.mov) — run Verify Archive"))

        #expect(JourneyPresence.currentSentence(path: "/V/a.mov", presence: .regularFile, archivedCopy: nil) == "Now at /V/a.mov")
        #expect(JourneyPresence.currentSentence(path: "/V/a.mov", presence: .linkToFile(target: "/W/a.mov"), archivedCopy: nil)
                == "Now at /V/a.mov — a link to /W/a.mov, where the file is")
        #expect(JourneyPresence.currentSentence(path: "/Volumes/L/a.mov", presence: .volumeOffline(volume: "L"), archivedCopy: nil)
                .hasPrefix("Not reachable — L is not connected"))
    }
}

@Suite("File Journey — Archived is a copy on disk with a whole-file SHA-256")
@MainActor
struct PreservationChecklistContentTests {

    private func rec(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    @Test func archivedCopyFixityOnDiskArchivesTheFootage() {
        let copy = rec("/Volumes/FamilyArchive/A/1990_X.mov")
        copy.derivationKind = ArchivePromotion.derivationKind   // Promote made it: its fixity is a read-back
        copy.archiveFixity = ArchiveFixity(digest: JourneyFixture.sha, verifiedAt: JourneyFixture.day(2026, 8, 12), sizeBytes: 10)

        #expect(FileJourneyBuilder.archiveStanding(copy, presence: .regularFile, place: "FamilyArchive")
                == .archived(place: "FamilyArchive", at: nil, checkedAt: JourneyFixture.day(2026, 8, 12)),
                "with no archive day on record, the fixity's date is a check, not the day it was archived")
        // The same copy, not seen on disk: a record alone ticks nothing.
        for presence in [JourneyPresence.missing, .volumeOffline(volume: "FamilyArchive"), .unknown(reason: "Permission denied")] {
            guard case .unproven(let todo) = FileJourneyBuilder.archiveStanding(copy, presence: presence, place: "FamilyArchive") else {
                Issue.record("\(presence) ticked Archived")
                continue
            }
            #expect(!todo.isEmpty)
        }
        #expect(FileJourneyBuilder.archiveStanding(copy, presence: .volumeOffline(volume: "FamilyArchive"), place: "FamilyArchive")
                == .unproven(todo: "Connect FamilyArchive — the archived copy could not be checked."))
        #expect(FileJourneyBuilder.archiveStanding(copy, presence: nil, place: "FamilyArchive")
                == .unproven(todo: "Run Verify Archive — the archived copy has not been checked on disk."))
    }

    @Test func withoutACopyNothingIsArchived() {
        #expect(FileJourneyBuilder.archiveStanding(nil, presence: nil, place: "the archive") == .notArchived)
    }

    /// codex P1 (2026-10-16): an archived copy that carries only an MD5 —
    /// or no fixity at all — proves nothing. The ladder must not tick on a
    /// promise, whatever else the source row carries.
    @Test func aCopyWithoutAWholeFileSHA256ProvesNothing() {
        let copy = rec("/Volumes/FamilyArchive/A/1990_X.mov")
        let noCheck = JourneyArchiveStanding.unproven(
            todo: "Run Verify Archive — no whole-file check (SHA-256) is recorded for the archived copy.")
        #expect(FileJourneyBuilder.archiveStanding(copy, presence: .regularFile, place: "FamilyArchive") == noCheck)
        copy.archiveFixity = ArchiveFixity(algorithm: "md5", digest: "d41d8cd98f00b204e9800998ecf8427e", verifiedAt: Date(), sizeBytes: 10)
        #expect(FileJourneyBuilder.archiveStanding(copy, presence: .regularFile, place: "FamilyArchive") == noCheck,
                "an MD5 fixity is not a whole-file SHA-256")
    }

    /// The fields that once ticked "Archived locally" / "Archived offsite"
    /// with no evidence behind them: the legacy stage stamp and a recorded
    /// BackupEntry (neither has had a writer since 2026-09-22).
    @Test func legacyStampsTickNothing() throws {
        let dir = try JourneyFixture.scratch("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 1, count: 2048).write(to: url)
        let row = JourneyFixture.record(path: url.path)
        row.archiveStage = .archived
        row.backupDestinations = [BackupEntry(name: "Master RAID", kind: .local, date: Date()),
                                  BackupEntry(name: "Backblaze", kind: .cloud, date: Date())]

        let journey = VideoScanModel.buildFileJourney(for: row, allRecords: [row], resolveVolumeSafety: neutralResolver)

        #expect(journey.preservation.filter(\.done).map(\.kind) == [.catalogued])
        #expect(!journey.preservation.contains { $0.kind == .offsite }, "a BackupEntry is not the person's answer")
    }
}
