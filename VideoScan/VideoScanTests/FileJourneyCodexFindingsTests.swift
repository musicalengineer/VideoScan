// FileJourneyCodexFindingsTests.swift
// Codex cycle #292 on d6955ee6b..f997a9146 (2026-11-14, verdict "fix",
// 9 findings, all reasoned — Codex cannot run tests). Eight are pinned here,
// each seen RED on f997a9146 before its fix; the tests are Codex's own, with
// the reason for each spelled out. The ninth of its findings (F5: a rescan
// carries a person's date onto different footage at the same path) is in
// RescanPreservedFields, outside the sheet, and is filed as an issue.
//
// The fake disk answers every path the same way, so no file is written.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

@Suite("File Journey — Codex #292 findings (red on f997a9146)", .serialized)
@MainActor
struct FileJourneyCodexFindingsTests {

    private static let sha = String(repeating: "ab", count: 32)
    private static let otherSHA = String(repeating: "cd", count: 32)
    private static let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }
    private static let now = day(2026, 11, 14)

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }

    private static func row(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = 4096
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    private static func fullHash(_ digest: String = sha) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: 4096,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: 4096, mtimeNs: 1), computedAt: now)
    }

    /// Every content analyzer that applies has run (the dossier stamp included).
    private static func analyzedRow(_ path: String, digest: String) -> VideoRecord {
        let r = row(path)
        r.contentHash = "v1:" + digest
        r.contentHashAt = now
        r.dupAnalyzedAt = now
        r.dossierProcessedAt = now
        r.contentFixity = fullHash(digest)
        r.audioFingerprint = AudioFingerprintStamp(computedAt: now, contentDigest: "sha256:" + digest, sizeBytes: 4096,
                                                   outcome: .fingerprinted, analyzedSeconds: 60, complete: true,
                                                   landmarks: 400, bytes: 2048)
        return r
    }

    private static func journey(_ rec: VideoRecord, _ all: [VideoRecord]? = nil,
                                presence: JourneyPresence = .regularFile) -> FileJourney {
        var extras = FileJourneyBuilder.Extras()
        extras.archiveRootPath = "/Archive"
        extras.archiveName = "FamilyArchive"
        extras.now = now
        return VideoScanModel.buildFileJourney(for: rec, allRecords: all ?? [rec], resolveVolumeSafety: neutral,
                                               extras: extras, probe: { _ in presence })
    }

    private static func step(_ kind: PreservationStep.Kind, _ j: FileJourney) throws -> PreservationStep {
        try #require(j.preservation.first { $0.kind == kind })
    }

    // F1 — a path in the archive that is a LINK to the bytes elsewhere is not a copy in the archive.
    @Test("F1 TRUTH: a link in the archive (or a file reached through a folder link onto another disk) never ticks Archived")
    func aLinkIsNotAnArchiveCopy() throws {
        for presence in [JourneyPresence.linkToFile(target: "/Projects/clip.mov"), .regularFileThroughLink(at: "/Archive")] {
            let r = Self.row("/Archive/clip.mov")
            r.contentFixity = Self.fullHash()
            let archived = try Self.step(.archived, Self.journey(r, presence: presence))
            #expect(!archived.done, "\(presence): removing the file it points at destroys the 'archive copy'")
            #expect(archived.todo.contains("link"), Comment(rawValue: archived.todo))
        }
    }

    // F2 — the purge exclusion applied only to ANOTHER row's copy, not to the row itself.
    @Test("F2 TRUTH: a purged row, opened directly, never ticks Archived")
    func aPurgedRowIsNotArchived() throws {
        let r = Self.row("/Archive/clip.mov")
        r.derivationKind = ArchivePromotion.derivationKind
        r.archiveFixity = ArchiveFixity(digest: Self.sha, verifiedAt: Self.now, sizeBytes: 4096)
        r.purgedAt = Self.now
        #expect(try !Self.step(.archived, Self.journey(r)).done)
    }

    // F3 — the promote link alone made a source "the same footage" after its bytes had changed.
    @Test("F3 TRUTH: a linked row whose whole-file hash differs is other footage — it lends no passes, no review, and no archive copy")
    func differentBytesAreNotTheFamily() throws {
        let source = Self.analyzedRow("/Projects/replaced.mov", digest: Self.otherSHA)
        source.userNotes = "Reviewed the replacement footage"
        let copy = Self.row("/Archive/original.mov")
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = source.id
        copy.archiveFixity = ArchiveFixity(digest: Self.sha, verifiedAt: Self.now, sizeBytes: 4096)

        let fromCopy = Self.journey(copy, [source, copy])
        #expect(try !Self.step(.analyzed, fromCopy).done, "the passes ran on other bytes")
        #expect(try !Self.step(.reviewed, fromCopy).done, "the note is about other bytes")

        // And from the changed source: the archive holds the OLD bytes, not these.
        let fromSource = Self.journey(source, [source, copy])
        #expect(try !Self.step(.archived, fromSource).done, "this file's bytes are not what the archive holds")
        #expect(!fromSource.events.contains { $0.kind == .archived })
    }

    // F4 — "read back" was read off the archive fixity's ALGORITHM while the digest came from elsewhere.
    @Test("F4 TRUTH: a malformed archive fixity beside a valid fingerprint is a fingerprint, never 'read back and matched'")
    func malformedArchiveFixityIsNotAReadBack() {
        let r = Self.row("/Archive/clip.mov")
        r.derivationKind = ArchivePromotion.derivationKind
        r.contentFixity = Self.fullHash()
        r.archiveFixity = ArchiveFixity(digest: "v1:" + Self.sha, verifiedAt: Self.now, sizeBytes: 4096)
        #expect(FileJourneyBuilder.archiveProof(r) == .fingerprintOnly)
        let j = Self.journey(r)
        #expect(!j.events.contains { $0.sentence.contains("read back and matched") || $0.kind == .archiveChecked })
    }

    // F6 — the 2000…now filter guarded "catalogued by" and nothing else.
    @Test("F6 TRUTH: a date in 1970 or in the future proves no act and dates no event")
    func impossibleDatesAreNotEvidence() throws {
        for date in [Date(timeIntervalSince1970: 0), Self.now.addingTimeInterval(2 * 86_400)] {
            let r = Self.row("/Projects/clip.mov")
            r.repairConfirmedDate = date
            let j = Self.journey(r)
            #expect(try !Self.step(.reviewed, j).done, "\(date)")
            #expect(!j.events.contains { $0.kind == .review })
        }
        let copy = Self.row("/Archive/clip.mov")
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archivedAt = Self.day(2026, 9, 23)
        copy.archiveFixity = ArchiveFixity(digest: Self.sha, verifiedAt: Self.now.addingTimeInterval(2 * 86_400), sizeBytes: 4096)
        copy.sceneCaptionDate = Self.now.addingTimeInterval(86_400 * 30)
        copy.confirmedByUserPeople = [ConfirmedTag(name: "Dad", confirmedAt: Date(timeIntervalSince1970: 5))]
        let j = Self.journey(copy)
        for event in j.events.dropFirst().dropLast() {
            if let at = event.timestamp { #expect(at <= Self.now && at.timeIntervalSince1970 >= 946_684_800, "\(event.sentence)") }
        }
        #expect(!j.events.contains { $0.kind == .archiveChecked }, "a check dated in the future is not a check")
        let archived = try Self.step(.archived, j)
        #expect(archived.done && !archived.detail.contains("checked"), "the copy is still archived; the impossible check is not stated")
        // The confirmed person is still the person's act — the tag exists — it just has no date to show.
        let reviewed = try Self.step(.reviewed, j)
        #expect(reviewed.done && reviewed.date == nil && reviewed.detail == "1 person confirmed")
    }

    // F7 — the ladder knew the file was gone; the timeline still said it was in the archive.
    @Test("F7 TRUTH: a hand-placed file that is gone is not said to be 'In' the archive")
    func aMissingHandPlacedFileIsNotInTheArchive() throws {
        let r = Self.row("/Archive/dropped-in.mov")
        r.contentFixity = Self.fullHash()
        let j = Self.journey(r, presence: .missing)
        #expect(!j.events.contains { $0.kind == .archived }, "\(j.events.map(\.sentence))")
        #expect(try !Self.step(.archived, j).done)
        #expect(j.events.last?.kind == .notAtPath)
    }

    // F8 — the fallback named the source row's PRESENT path, which Migrate moves.
    @Test("F8 TRUTH: 'Copied from' is the path Promote recorded (the copy's own field, else its promote note) or is not said")
    func copiedFromIsNeverTheSourcesLaterPath() throws {
        let source = Self.row("/Backup/new.mov")
        source.originalFullPath = "/Projects/old.mov"
        let copy = Self.row("/Archive/clip.mov")
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = source.id
        copy.originalFullPath = nil
        copy.notes = "Promote 2026-09-23T17:47:00Z: promoted from /Projects/old.mov · sha256 \(Self.sha)"

        let archived = try #require(Self.journey(copy, [source, copy]).events.first { $0.kind == .archived })
        #expect(!archived.sentence.contains(source.fullPath), Comment(rawValue: archived.sentence))
        #expect(archived.sentence.contains("Copied from /Projects/old.mov."), "the promote note names what Promote read")

        copy.notes = ""
        let unsaid = try #require(Self.journey(copy, [source, copy]).events.first { $0.kind == .archived })
        #expect(!unsaid.sentence.contains("Copied from"), "with no record of what Promote read, nothing is said: \(unsaid.sentence)")
    }

    // F9 — Catalog Status reads "cannot decode" off the whole catalog; the sheet read three rows.
    @Test("F9 TRUTH: bytes any copy in the catalog proved undecodable are not 'in the queue' — as Catalog Status counts them")
    func anUnreadableSiblingAnywhereInTheCatalogCounts() throws {
        let r = Self.analyzedRow("/Projects/a.mov", digest: Self.sha)
        r.dossierProcessedAt = nil
        let sibling = Self.row("/Backup/b.mov")
        sibling.contentFixity = Self.fullHash()
        sibling.needsReformat = true

        let inputs = AnalyzeCoverageCalculator.project([r, sibling]).filter { $0.fullPath == r.fullPath }
        let report = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [], mountedRoots: [], scope: AnalysisScope())
        try #require(report.contentFiles.covered == 1, "fixture: Catalog Status counts this file analyzed")

        #expect(try Self.step(.analyzed, Self.journey(r, [r, sibling])).done)
    }

    // Found by FileJourneyNonsenseDataTests (52 of 1,000 cases): a promote note on a row with no
    // archive-copy record still put the raw log line, hash and all, in the timeline.
    @Test("TRUTH: a promote note shown as history is a sentence — never the log line with its hash")
    func aKeptPromoteNoteIsNotTheRawLine() throws {
        let r = Self.row("/Projects/clip.mov")
        r.notes = "Promote 2026-09-23T17:47:00Z: promoted from /Volumes/Projects/Movies/x.mov · sha256 \(Self.sha) · readiness: audio verified"
        let event = try #require(Self.journey(r).events.first { $0.kind == .promote })
        #expect(event.sentence == "Promoted from /Volumes/Projects/Movies/x.mov")
    }
}
