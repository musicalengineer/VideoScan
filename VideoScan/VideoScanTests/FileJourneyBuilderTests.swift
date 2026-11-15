// FileJourneyBuilderTests.swift
// The File Journey sheet's one value (Rick 2026-11-14): the evidence behind
// each tick of Catalogued · Analyzed · Reviewed · Archived (· Offsite), the
// timeline, and the detail sections — FileJourneyBuilder, through the
// model's pure seam `VideoScanModel.buildFileJourney`.
//
// Dimensions (hard rule 8):
//   LOGIC      the family (row, archived copy, its source); each step's evidence
//   TRUTH      a tick or a sentence only from a dated field or a stat; the
//              machine's writes are never the person's review; the journey's
//              "Analyzed" agrees with Catalog Status's count for the same file
//   SCALE      100,000 records in the catalog, one sheet, inside a time budget
//   ISOLATION  poisoned records: junk and future dates, broken note lines
//   SENSOR     the builder reads no store; the sheet shows no hash line
// Media matrix: not applicable — nothing here decodes media.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private enum LadderFixture {
    static let sha = String(repeating: "ef", count: 32)
    static let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }
    static let now = day(2026, 11, 14)

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }

    static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_journey_builder_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func record(path: String, bytes: Int64 = 4096) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = bytes
        return r
    }

    /// A source on "Projects" and its promoted copy in the archive, both real
    /// files; the copy carries the SHA-256 Promote recorded on Sep 23.
    static func pair(in dir: URL) throws -> (source: VideoRecord, copy: VideoRecord, root: String) {
        let root = dir.appendingPathComponent("Archive").path
        let sourceURL = dir.appendingPathComponent("Projects/Movies/Dicky-1985-3.mp4")
        let copyURL = URL(fileURLWithPath: root).appendingPathComponent("30_Video/1980-1989/1984/1984-xx-xx_Dicky-1985-3.mp4")
        for url in [sourceURL, copyURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }
        let source = record(path: sourceURL.path)
        source.scanContext.scannedAt = day(2026, 9, 1)
        let copy = record(path: copyURL.path)
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archivedAt = day(2026, 9, 23)
        copy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: day(2026, 9, 23), sizeBytes: 4096)
        copy.notes = "Promote 2026-09-23T17:47:00Z: promoted from \(sourceURL.path) · sha256 \(sha) · readiness: audio verified, codec archival-safe"
        return (source, copy, root)
    }

    static func extras(root: String? = nil, name: String? = "FamilyArchive") -> FileJourneyBuilder.Extras {
        var e = FileJourneyBuilder.Extras()
        e.archiveRootPath = root
        e.archiveName = name
        e.now = now
        return e
    }

    static func journey(_ rec: VideoRecord, _ all: [VideoRecord], extras: FileJourneyBuilder.Extras = extras()) -> FileJourney {
        VideoScanModel.buildFileJourney(for: rec, allRecords: all, resolveVolumeSafety: neutral, extras: extras)
    }

    static func step(_ kind: PreservationStep.Kind, _ journey: FileJourney) throws -> PreservationStep {
        try #require(journey.preservation.first { $0.kind == kind }, "no \(kind) step")
    }
}

// MARK: - Logic: the family and each step's evidence

@Suite("File Journey builder — the ladder answers for the footage", .serialized)
@MainActor
struct FileJourneyBuilderLadderTests {

    @Test("LOGIC: opened on the source or on the archive copy, the ladder is the same and Archived names the place and the day")
    func bothRowsOfOneFootageAgree() throws {
        let dir = try LadderFixture.scratch("family")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        let extras = LadderFixture.extras(root: root)

        let fromSource = LadderFixture.journey(source, [source, copy], extras: extras)
        let fromCopy = LadderFixture.journey(copy, [source, copy], extras: extras)

        #expect(fromSource.preservation == fromCopy.preservation, "one footage, one ladder")
        let archived = try LadderFixture.step(.archived, fromCopy)
        #expect(archived.done && archived.detail == "FamilyArchive" && archived.date == LadderFixture.day(2026, 9, 23))
        let catalogued = try LadderFixture.step(.catalogued, fromCopy)
        #expect(catalogued.date == LadderFixture.day(2026, 9, 1) && catalogued.datePrefix == "by ",
                "the source's Sep 1 scan is the earliest date held for the footage")
    }

    @Test("LOGIC: a file under the archive root that Promote did not make is archived by the same proof — on disk, whole-file SHA-256")
    func aFileInsideTheArchiveRoot() throws {
        let dir = try LadderFixture.scratch("inroot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, copy, root) = try LadderFixture.pair(in: dir)
        // Dropped in by hand and found by a scan: nothing of Promote's on it,
        // only the whole-file fingerprint Full Hashes computed.
        copy.derivedFrom = nil
        copy.derivationKind = nil
        copy.archivedAt = nil
        copy.archiveFixity = nil
        copy.notes = ""
        copy.contentFixity = ContentFixity(digest: LadderFixture.sha, byteCount: 4096,
                                           stamp: FileIdentityStamp(device: 1, inode: 1, size: 4096, mtimeNs: 1),
                                           computedAt: LadderFixture.day(2026, 10, 2))

        let inside = LadderFixture.journey(copy, [copy], extras: LadderFixture.extras(root: root))
        let archived = try LadderFixture.step(.archived, inside)
        #expect(archived.done && archived.date == nil, "in the archive and fingerprinted; no archive day is known")
        #expect(inside.events.first { $0.kind == .archived }?.sentence
                == "In FamilyArchive as 30_Video/1980-1989/1984/1984-xx-xx_Dicky-1985-3.mp4. A whole-file fingerprint is recorded for it.")
        #expect(!inside.events.contains { $0.kind == .archiveChecked })
        let unknownRoot = LadderFixture.journey(copy, [copy], extras: LadderFixture.extras(root: nil))
        #expect(try !LadderFixture.step(.archived, unknownRoot).done, "with no archive root known, a path alone is not an archive")
    }

    @Test("LOGIC: a later full read-back is said under Archived and as its own event; the promote's own read-back is not")
    func aLaterReadBack() throws {
        let dir = try LadderFixture.scratch("readback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        let extras = LadderFixture.extras(root: root)
        #expect(!LadderFixture.journey(copy, [source, copy], extras: extras).events.contains { $0.kind == .archiveChecked })

        copy.archiveFixity = ArchiveFixity(digest: LadderFixture.sha, verifiedAt: LadderFixture.day(2026, 10, 15), sizeBytes: 4096)
        let journey = LadderFixture.journey(copy, [source, copy], extras: extras)
        let archived = try LadderFixture.step(.archived, journey)
        #expect(archived.date == LadderFixture.day(2026, 9, 23), "the archive day, not the check")
        #expect(archived.detail == "FamilyArchive\nchecked \(PreservationChecklist.shortDate(LadderFixture.day(2026, 10, 15)))")
        let checked = try #require(journey.events.first { $0.kind == .archiveChecked })
        #expect(checked.timestamp == LadderFixture.day(2026, 10, 15))
        #expect(checked.sentence == "The archived copy was read in full again and still matches.")
    }

    @Test("LOGIC: each of the person's acts ticks Reviewed, on either row of the footage, with the latest dated act")
    func reviewEvidence() throws {
        let dir = try LadderFixture.scratch("review")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        let extras = LadderFixture.extras(root: root)
        #expect(try !LadderFixture.step(.reviewed, LadderFixture.journey(copy, [source, copy], extras: extras)).done)

        // On the SOURCE row; the sheet is opened on the copy.
        source.userNotes = "Dad and the boys in the yard"
        source.confirmedByUserPeople = [ConfirmedTag(name: "Dicky", confirmedAt: LadderFixture.day(2026, 10, 2)),
                                        ConfirmedTag(name: "Dad", confirmedAt: LadderFixture.day(2026, 10, 2))]
        copy.footageDecisions = [FootageDecision(otherID: source.id, verdict: .same, decidedAt: LadderFixture.day(2026, 10, 20))]
        let journey = LadderFixture.journey(copy, [source, copy], extras: extras)

        let reviewed = try LadderFixture.step(.reviewed, journey)
        #expect(reviewed.done && reviewed.date == LadderFixture.day(2026, 10, 20))
        #expect(reviewed.detail == "2 people confirmed · note · +1")
        let lines = journey.events.filter { $0.kind == .review }.map(\.sentence)
        #expect(lines == ["You confirmed Dad and Dicky are in this.",
                          "You said this is the same footage as \(source.filename)."], "\(lines)")
    }

    @Test("LOGIC: an Update of the archived file and the confirmed provenance are the person's acts too")
    func updateProvenanceAndRole() throws {
        let dir = try LadderFixture.scratch("update")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        copy.notes += "\npromote: Update 2026-10-30T14:00:00Z: Name: A → B · 30_Video/a.mp4 → 30_Video/b.mp4 · sha256 verified before and after"
        var extras = LadderFixture.extras(root: root)
        extras.provenanceConfirmed = true

        // Opened on the SOURCE: the Update lives in the copy's notes.
        let journey = LadderFixture.journey(source, [source, copy], extras: extras)
        let reviewed = try LadderFixture.step(.reviewed, journey)
        #expect(reviewed.done && reviewed.date == ISO8601DateFormatter().date(from: "2026-10-30T14:00:00Z"))
        #expect(reviewed.detail == "archived file updated · provenance confirmed")
        #expect(journey.events.contains { $0.kind == .review && $0.sentence == "You updated the archived file — Name: A → B." })
    }

    @Test("LOGIC: Offsite appears only when the person answered cloud or off-site — yes is their word, no is open, n/a is no step")
    func offsiteIsTheAttestation() throws {
        let dir = try LadderFixture.scratch("offsite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        let extras = LadderFixture.extras(root: root)
        func ladder() -> [PreservationStep] { LadderFixture.journey(copy, [source, copy], extras: extras).preservation }

        #expect(!ladder().contains { $0.kind == .offsite })
        source.backupAttestations = [BackupAttestation(kind: .cloud, answer: .notApplicable, attestedAt: LadderFixture.day(2026, 10, 1))]
        #expect(!ladder().contains { $0.kind == .offsite }, "'not applicable' is not a step")

        source.backupAttestations = [BackupAttestation(kind: .cloud, answer: .no, attestedAt: LadderFixture.day(2026, 10, 1))]
        #expect(ladder().last?.state == .open)

        // A newer "yes" on the other row of the footage wins.
        copy.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: LadderFixture.day(2026, 10, 9))]
        let yes = try #require(ladder().last)
        #expect(yes.kind == .offsite && yes.state == .attested && yes.detail == "your word · iCloud")
        #expect(yes.date == BackupAttestation.Timestamp.quantized(LadderFixture.day(2026, 10, 9)))
    }
}

// MARK: - Truth

@Suite("File Journey builder — TRUTH: only what a dated field or a stat says", .serialized)
@MainActor
struct FileJourneyBuilderTruthTests {

    @Test("TRUTH: what Promote and the analyzers write is never the person's review — stars, classification, the stage stamp")
    func machineWritesAreNotReview() throws {
        let dir = try LadderFixture.scratch("notreview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        // Exactly what Promote does to both rows (VideoScanModel+MasterArchive).
        for row in [source, copy] {
            row.starRating = 3
            row.mediaDisposition = .important
            row.archiveStage = .masterAssigned
        }
        let journey = LadderFixture.journey(copy, [source, copy], extras: LadderFixture.extras(root: root))
        let reviewed = try LadderFixture.step(.reviewed, journey)
        #expect(!reviewed.done && reviewed.todo == PreservationChecklist.reviewTodo)
        #expect(!journey.events.contains { $0.kind == .review })
    }

    @Test("TRUTH: the journey's Analyzed agrees with Catalog Status's own count for the same file, done or not")
    func analyzedAgreesWithCatalogStatus() throws {
        let dir = try LadderFixture.scratch("agree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 3, count: 4096).write(to: url)

        let bare = LadderFixture.record(path: url.path)
        let partial = LadderFixture.record(path: url.path)
        partial.contentHash = "v1:" + LadderFixture.sha
        partial.dupAnalyzedAt = LadderFixture.day(2026, 9, 2)
        let full = LadderFixture.record(path: url.path)
        full.contentHash = "v1:" + LadderFixture.sha
        full.contentHashAt = LadderFixture.day(2026, 9, 2)
        full.dupAnalyzedAt = LadderFixture.day(2026, 9, 2)
        full.dossierProcessedAt = LadderFixture.day(2026, 9, 5)
        full.sceneCaptionDate = LadderFixture.day(2026, 9, 5)
        full.audioTranscriptDate = LadderFixture.day(2026, 9, 5)
        full.audioTranscript = "hello"
        full.contentFixity = ContentFixity(digest: LadderFixture.sha, byteCount: 4096,
                                           stamp: FileIdentityStamp(device: 1, inode: 1, size: 4096, mtimeNs: 1),
                                           computedAt: LadderFixture.day(2026, 9, 3))
        full.audioFingerprint = AudioFingerprintStamp(computedAt: LadderFixture.day(2026, 9, 4),
                                                      contentDigest: "sha256:" + LadderFixture.sha, sizeBytes: 4096,
                                                      outcome: .fingerprinted, analyzedSeconds: 60, complete: true,
                                                      landmarks: 400, bytes: 2048)

        var verdicts: [Bool] = []
        for record in [bare, partial, full] {
            let report = AnalyzeCoverageCalculator.compute(inputs: [AnalyzeCoverageInput(record: record)], volumes: [],
                                                           mountedRoots: [], scope: AnalysisScope())
            let statusSaysAnalyzed = report.contentFiles.eligible == 1 && report.contentFiles.remaining == 0
            let analyzed = try LadderFixture.step(.analyzed, LadderFixture.journey(record, [record]))
            #expect(analyzed.done == statusSaysAnalyzed,
                    "the sheet and Catalog Status disagree about one file: \(analyzed.detail) vs \(report.contentFiles.line)")
            verdicts.append(analyzed.done)
        }
        #expect(verdicts == [false, false, true], "the three fixtures must cover both answers: \(verdicts)")
        let waiting = try LadderFixture.step(.analyzed, LadderFixture.journey(partial, [partial]))
        #expect(waiting.state == .waiting && waiting.todo.contains("whole-file fingerprint"), Comment(rawValue: waiting.todo))
        #expect(!waiting.todo.contains("quick signature") && !waiting.todo.contains("duplicate check"), "those two have run")
    }

    @Test("TRUTH: every timeline line comes from a dated field of the footage — the whole journey of Rick's file, in order")
    func theWholeTimeline() throws {
        let dir = try LadderFixture.scratch("timeline")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        copy.dateModifiedRaw = LadderFixture.day(2025, 5, 9)
        copy.originVolume = "Projects"
        copy.originalFullPath = source.fullPath
        copy.scanContext.scannedAt = LadderFixture.day(2026, 11, 5)   // the Ultra's rescan
        copy.sceneCaptionDate = LadderFixture.day(2026, 10, 3)
        copy.sceneCaptions = []
        copy.audioTranscriptDate = LadderFixture.day(2026, 10, 3).addingTimeInterval(60)
        copy.audioTranscript = ""
        copy.audioVerifyStatus = "ok"
        copy.audioVerifyDate = LadderFixture.day(2026, 9, 20)
        copy.archiveFixity = ArchiveFixity(digest: LadderFixture.sha, verifiedAt: LadderFixture.day(2026, 10, 15), sizeBytes: 4096)
        copy.notes += "\nffprobe: [mov,mp4,m4a,3gp,3g2,mj2 @ 0xb21034000] UDTA parsing failed retrying raw"
        let era = JourneyMachineEra(sentence: "Estimated era: 1985–1995 — the 8B model's guess from the pictures alone, not confirmed.",
                                    observed: LadderFixture.day(2026, 11, 1))

        let journey = VideoScanModel.buildFileJourney(for: copy, allRecords: [source, copy], resolveVolumeSafety: LadderFixture.neutral,
                                                      machineEra: era, extras: LadderFixture.extras(root: root))

        #expect(journey.events.map(\.kind) == [.origin, .catalogued, .analysis, .archived, .analysis, .analysis,
                                               .archiveChecked, .machineEstimate, .currentState],
                "\(journey.events.map { "\($0.kind): \($0.sentence)" })")
        let sentences = journey.events.map(\.sentence)
        #expect(sentences[0].hasPrefix("File dated ") && sentences[0].contains("(from the file's own clock) — found on Projects at \(source.fullPath)"))
        #expect(sentences[1].hasPrefix("Catalogued by VideoScan. The first day was not recorded"))
        #expect(journey.events[1].timestamp == LadderFixture.day(2026, 9, 1), "never the Nov 5 rescan")
        #expect(sentences[2] == "Sound check: ok.")
        #expect(sentences[3] == "Archived to FamilyArchive as 30_Video/1980-1989/1984/1984-xx-xx_Dicky-1985-3.mp4. "
                + "The copy was read back and matched, bit for bit. "
                + "Checked before archiving: audio verified, codec archival-safe.",
                "the first line already says where the file was found — the path is not said twice")
        // Without that first line naming it, the archive line says where it was copied from.
        copy.originalFullPath = nil
        let unnamed = LadderFixture.journey(copy, [source, copy], extras: LadderFixture.extras(root: root))
        #expect(unnamed.events.first { $0.kind == .archived }?.sentence.contains("Copied from \(source.fullPath).") == true)
        #expect(sentences[4] == "The machine looked for scenes to describe and found none.")
        #expect(sentences[5] == "The machine listened for speech and heard none.")
        #expect(sentences[8] == "Now at \(copy.fullPath) · the copy it was made from is still at \(source.fullPath)")
        #expect(journey.events[8].displayStamp == "Now")

        // The ffprobe line is kept, apart, at the bottom.
        let technical = try #require(journey.details.first { $0.title == "Technical notes" })
        #expect(technical.isMachineText && technical.text.contains("UDTA parsing failed"))
        #expect(journey.details.map(\.title) == ["This file", "Status", "Technical notes"], "most useful first")
    }

    @Test("TRUTH: an archive copy with no whole-file check says so, and where the source went is asked of the disk")
    func noCheckRecordedAndASourceThatIsGone() throws {
        let dir = try LadderFixture.scratch("nocheck")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        copy.archiveFixity = nil
        try FileManager.default.removeItem(atPath: source.fullPath)

        let journey = LadderFixture.journey(copy, [source, copy], extras: LadderFixture.extras(root: root))
        let archived = try LadderFixture.step(.archived, journey)
        #expect(!archived.done && archived.todo.hasPrefix("Run Verify Archive — no whole-file check"))
        let event = try #require(journey.events.first { $0.kind == .archived })
        #expect(event.sentence.contains("No whole-file check is recorded for the copy."))
        #expect(!event.sentence.contains("matched"))
        #expect(journey.events.last?.sentence
                == "Now at \(copy.fullPath) · the copy it was made from is no longer at \(source.fullPath)")
    }

    @Test("TRUTH: the other copy is named by where it is, in each presence's own words")
    func otherCopyWords() {
        let path = "/Volumes/Projects/Movies/X.mov"
        #expect(JourneyPresence.otherCopyWords(path: path, presence: .regularFile) == "the copy on Projects is still at \(path)")
        #expect(JourneyPresence.otherCopyWords(path: path, presence: .missing) == "the copy on Projects is no longer at \(path)")
        #expect(JourneyPresence.otherCopyWords(path: path, presence: .volumeOffline(volume: "Projects"))
                == "the copy on Projects could not be checked — Projects is not connected")
        #expect(JourneyPresence.otherCopyWords(path: path, presence: .unknown(reason: "Permission denied"))
                == "the copy on Projects could not be checked at \(path): Permission denied")
        #expect(!JourneyPresence.otherCopyWords(path: path, presence: .missing).contains("this copy"))
    }
}

// MARK: - Scale, isolation, sensors

@Suite("File Journey builder — scale, poisoned records, sensors", .serialized)
@MainActor
struct FileJourneyBuilderRobustnessTests {

    @Test("SCALE: one sheet over a 100,000-record catalog builds inside 0.5 s")
    func oneSheetInAHundredThousand() throws {
        let dir = try LadderFixture.scratch("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, copy, root) = try LadderFixture.pair(in: dir)
        var all: [VideoRecord] = []
        all.reserveCapacity(100_002)
        for i in 0..<100_000 { all.append(LadderFixture.record(path: "/Volumes/Bulk/clip_\(i).mov")) }
        all += [source, copy]   // last: the worst case for the lookups
        let extras = LadderFixture.extras(root: root)

        let clock = ContinuousClock()
        var journey: FileJourney?
        let elapsed = clock.measure { journey = LadderFixture.journey(copy, all, extras: extras) }

        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
        #expect(try LadderFixture.step(.archived, #require(journey)).done)
    }

    @Test("ISOLATION: junk dates, future dates and broken note lines never become a date, a tick or an event")
    func poisonedRecord() throws {
        let dir = try LadderFixture.scratch("poison")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 9, count: 4096).write(to: url)
        let row = LadderFixture.record(path: url.path)
        row.scanContext.scannedAt = Date(timeIntervalSince1970: 0)            // 1970: no catalog existed
        row.contentHashAt = LadderFixture.now.addingTimeInterval(86_400 * 400) // next year
        row.dupAnalyzedAt = LadderFixture.day(2026, 8, 1)
        row.notes = ["Promote not-a-date: promoted to Master Archive as x.mov",
                     "promote: Update : ",
                     "promote: Update garbage",
                     "Reconcile 2026-13-45T99:99:99Z: source file not found",
                     " · readiness: ",
                     "\u{0}\u{FFFD} binary junk",
                     ""].joined(separator: "\n")

        let journey = LadderFixture.journey(row, [row])

        let catalogued = try LadderFixture.step(.catalogued, journey)
        #expect(catalogued.date == LadderFixture.day(2026, 8, 1), "the only believable date the catalog holds")
        #expect(journey.preservation.filter(\.done).map(\.kind) == [.catalogued])
        #expect(!journey.events.contains { $0.kind == .archived || $0.kind == .review })
        for event in journey.events {
            if let at = event.timestamp { #expect(at <= LadderFixture.now.addingTimeInterval(1), "\(event.sentence)") }
            #expect(!event.sentence.isEmpty)
        }
        #expect(journey.events.first?.kind == .origin && journey.events.last?.kind == .currentState)
        // A history line whose stamp cannot be read is kept as a technical note, never an undated event.
        #expect(journey.events.dropFirst().dropLast().allSatisfy { $0.timestamp != nil },
                "\(journey.events.map { "\($0.kind): \($0.sentence)" })")
        let technical = try #require(journey.details.first { $0.title == "Technical notes" })
        #expect(technical.text.contains("Reconcile 2026-13-45T99:99:99Z") && technical.text.contains("Promote not-a-date"))
    }

    @Test("ISOLATION: an archive copy whose source row is gone from the catalog still builds, and claims no source")
    func orphanCopy() throws {
        let dir = try LadderFixture.scratch("orphan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, copy, root) = try LadderFixture.pair(in: dir)

        let journey = LadderFixture.journey(copy, [copy], extras: LadderFixture.extras(root: root))
        #expect(try LadderFixture.step(.archived, journey).done)
        #expect(journey.events.last?.sentence == "Now at \(copy.fullPath)", "nothing is said about a row that is not there")
    }

    @Test("SENSOR: the sheet shows no hash line and no 'Signed'; the builder reads no store, ledger or catalog")
    func sourceSensors() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
        func source(_ relative: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(relative), encoding: .utf8)
        }
        let code: (String) -> String = { text in
            text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let sheet = code(try source("Catalog/FileJourneySheet.swift"))
        let ladder = code(try source("Archive/PreservationChecklist.swift"))
        let builder = code(try source("Catalog/FileJourneyBuilder.swift"))
        for token in ["partialMD5", "hashStatusLine", "\"Signed\"", "sha256"] {
            #expect(!sheet.contains(token) && !ladder.contains(token), "the sheet states \(token)")
        }
        #expect(!builder.contains("partialMD5"), "the sampled MD5 is not evidence of anything here")
        for token in ["mediaLedger", "repository", "catalogCutover", "provenanceEstimates", "machineEras", "FileManager"] {
            #expect(!builder.contains(token), "the builder reaches outside what it is handed (\(token))")
        }
        // No O(records) work in the view: the sheet never sees a record.
        #expect(!sheet.contains("VideoRecord") && !sheet.contains("allRecords"))
        // One sheet: the Archive tab's details item opens the journey.
        let menu = try source("Archive/ArchiveView+Table.swift")
        #expect(menu.contains("fileJourneyPayload = model.makeFileJourney(for: rec)"))
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Archive/ArchiveView+DetailSheet.swift").path),
                "the second sheet, with its second ladder, is retired")
    }
}
