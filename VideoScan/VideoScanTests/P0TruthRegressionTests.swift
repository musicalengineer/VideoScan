// P0TruthRegressionTests.swift
// The cumulative P0 suite (GH #327; docs/design/integrity_first_2026_10_16.md
// §2, §5, §6a): every surface that on 2026-10-16 STATED A FACT IT HAD NOT
// VERIFIED gets one test here, named after the fall, driving the REAL
// surface model (never the view) over the shared fixture catalog
// (P0TruthFixture.swift). Each test's title names its evidence source and
// each asserts the WORDS the surface shows, not only a Bool.
//
//   1. File Journey — "Now at <dead link>", ladder 1 of 4, "Scanned on <mtime>"
//   2. Archive doors — played the source row's path, not the archived copy
//   3. Player — MP3 in an MPEG-4 container played silently with no notice
//   4. Compare Media — "promote the longer one" on a pair with no whole-file hash
//   5. Footage folders — a sampled `v1:` hash must never make two files copies
//   6. Audit Catalog — a link row is listed for Fix Links, never marked
//   7. Sound — a Video+Audio header whose sound print heard nothing
//   + source sensors pinning the one door each surface goes through.
//
// RED RUNS (docs/reviews/p0-regression-2026-10-17.md). The suite is run at
// the commit before each fix. Some surfaces did not EXIST before their fix,
// so a red build passes one compilation condition and the absent API is
// compiled out (its test records that the surface is absent):
//   P0_RED_JOURNEY  at d864951be (parent of 53c71c593)
//   P0_RED_AUDIT    at 46c66aae9 (parent of 572d74bb0)
//   P0_RED_COMPARE  at b03c3ce6b (parent of f94c392d7)
//   P0_RED_FOLDER_MUTANT  on main: the folder test reads a copy of the copy
//                   predicate with its `v1:` guard removed (no commit ever
//                   had that defect, so the red is a seam).
// A plain `xcodebuild test` (no condition) is the green run.
//
// (For Rick: `#expect` ≈ EXPECT_* (keeps going); `#require` ≈ ASSERT_*.
// `#if FLAG` is the C preprocessor's `#ifdef`, set per build with
// SWIFT_ACTIVE_COMPILATION_CONDITIONS.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("P0 truth regressions — a surface states only what it verified (GH #327)", .serialized)
@MainActor
struct P0TruthRegressionTests {

    // MARK: 1. File Journey (VideoScanModel.buildFileJourney)

    @Test("File Journey (buildFileJourney + lstat of the row's path): a dead link is 'Not at … link …', and names the archived copy")
    func journeyNeverSaysNowAtForADeadLink() throws {
        let catalog = try P0TruthFixtureCatalog.build("journey_last")
        defer { catalog.cleanup() }
        let source = try catalog.require(.deadLinkSource)
        let copy = try catalog.require(.deadLinkArchivedCopy)

        let last = try #require(Self.journey(source, in: catalog).events.last)

        #expect(String(describing: last.kind) == "notAtPath", "a gone file is drawn orange, never the green pin: \(last.sentence)")
        #expect(last.sentence.hasPrefix("Not at \(source.fullPath)"), Comment(rawValue: last.sentence))
        #expect(last.sentence.contains("link"), "a dead symlink is called a link: \(last.sentence)")
        #expect(last.sentence.contains("the archived copy is at \(copy.fullPath)"), Comment(rawValue: last.sentence))
        #expect(!last.sentence.hasPrefix("Now at"), "nothing is at that path: \(last.sentence)")
    }

    @Test("Preservation ladder (buildFileJourney.preservation + the archived copy's SHA-256 fixity on disk): answers for the CONTENT")
    func ladderAnswersForTheContent() throws {
        let catalog = try P0TruthFixtureCatalog.build("ladder")
        defer { catalog.cleanup() }
        let source = try catalog.require(.deadLinkSource)
        let copy = try catalog.require(.deadLinkArchivedCopy)

        let ladder = Self.journey(source, in: catalog).preservation
        let ticked = ladder.filter(\.done).map(\.title)
        let next = ladder.first { !$0.done }

        #expect(ticked == ["Catalogued", "Signed", "Archived locally"], "the copy's fixity signs the content: \(ladder.map { "\($0.title)=\($0.done)" })")
        #expect(next?.title == "Archived offsite", "Next: follows from the ladder — only the offsite copy is open")
        #if !P0_RED_JOURNEY && !P0_RED_AUDIT && !P0_RED_COMPARE
        let steps = PreservationChecklist.steps(for: source, archivedCopy: copy,
                                                archivedCopyPresence: JourneyPresence.probe(copy.fullPath))
        #expect(steps.map(\.done) == [true, true, true, false])
        let action = PreservationChecklist.nextAction(for: source, archivedCopy: copy,
                                                      archivedCopyPresence: JourneyPresence.probe(copy.fullPath))
        #expect(action?.contains("out of the building") == true, "Next: \(action ?? "nil")")
        #else
        _ = copy
        #endif
    }

    @Test("File Journey (buildFileJourney: dateModifiedRaw vs scanContext.scannedAt): the first event is the file's own date, never 'Scanned on'")
    func firstJourneyEventIsTheFilesOwnDate() throws {
        let catalog = try P0TruthFixtureCatalog.build("journey_first")
        defer { catalog.cleanup() }
        let row = try catalog.require(.mtimeYearsBeforeCatalogue)

        let events = Self.journey(row, in: catalog).events
        let first = try #require(events.first)
        let catalogued = events.first { $0.sentence.hasPrefix("Catalogued") }
        let scanned = events.filter { $0.sentence.hasPrefix("Scanned") }.map(\.sentence)

        #expect(first.sentence.hasPrefix("File dated"), "an mtime is not a scan: \(first.sentence)")
        #expect(first.sentence.contains("from the file's own clock"), Comment(rawValue: first.sentence))
        #expect(first.timestamp == P0TruthFixtureCatalog.fileDate)
        #expect(catalogued != nil, "the catalog's own date is its own event: \(events.map(\.sentence))")
        #expect(catalogued?.timestamp == P0TruthFixtureCatalog.cataloguedDate)
        #expect(scanned.isEmpty, "never 'Scanned on': \(scanned)")
    }

    // MARK: 2. Archive doors (VideoScanModel.archivePlayableRecord)

    @Test("Archive doors (archivePlayableRecord + FileManager.fileExists on both paths): play the archived copy; when both are gone, name the ARCHIVE path")
    func archivePlayResolvesToTheArchivedCopy() throws {
        let catalog = try P0TruthFixtureCatalog.build("doors")
        defer { catalog.cleanup() }
        let source = try catalog.require(.deadLinkSource)
        let copy = try catalog.require(.deadLinkArchivedCopy)
        let lostSource = try catalog.require(.sourceWithoutCopy)
        let lostCopy = try catalog.require(.sourceWithoutCopyArchivedCopy)
        #if !P0_RED_JOURNEY && !P0_RED_AUDIT && !P0_RED_COMPARE
        let playable = catalog.model.archivePlayableRecord(for: source)
        #expect(playable.record?.id == copy.id, "the door opens the archived copy, not the dead link")
        #expect(playable.path == copy.fullPath)

        let lost = catalog.model.archivePlayableRecord(for: lostSource)
        let words = try #require(lost.message, "both files gone → the missing words")
        #expect(lost.path == lostCopy.fullPath)
        #expect(words.contains(lostCopy.fullPath), "the words name the ARCHIVE path: \(words)")
        #expect(words.contains("Verify Archive"), Comment(rawValue: words))
        #expect(!words.contains(lostSource.fullPath), "never the source path: \(words)")
        #else
        Issue.record("archivePlayableRecord(for:) does not exist at this commit: the Archive doors opened \(source.fullPath) / \(lostSource.fullPath) directly (copies: \(copy.fullPath), \(lostCopy.fullPath))")
        #endif
    }

    // MARK: 3. Player (PlaybackAudioMismatch, real ffmpeg media)

    @Test("Player (AVURLAsset audio tracks vs the catalog row's audioCodec, real ffmpeg fixtures): MP3 in .m4v gets the notice; AAC/PCM do not; MKV never reaches AVPlayer",
          .timeLimit(.minutes(3)))
    func playerNoticesMP3InM4V() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required for the media matrix")
        let catalog = try P0TruthFixtureCatalog.build("player", withMedia: true)
        defer { catalog.cleanup() }
        let mp3 = try catalog.require(.mp3InM4V)
        let aac = try catalog.require(.aacInMP4)
        let pcm = try catalog.require(.pcmInMOV)
        let mkv = try catalog.require(.ffv1InMKV)
        #if !P0_RED_JOURNEY && !P0_RED_AUDIT && !P0_RED_COMPARE
        try await Self.expectMP3Notice(mp3)
        try await Self.expectNoNotice(aac)
        try await Self.expectNoNotice(pcm)
        try await Self.expectNotPlayableRoute(mkv)
        #else
        Issue.record("PlaybackAudioMismatch does not exist at this commit: \(mp3.filename) played with no sound and no notice (also built: \(aac.filename), \(pcm.filename), \(mkv.filename))")
        #endif
    }

    // MARK: 4. Compare Media (RelatedLadder.judge + EventRecommendation.recommend)

    @Test("Compare Media (RelatedLadder + EventRecommendation over relatedSide of two v1:-only rows): ask for the full hash, never 'promote the longer one'")
    func compareMediaAsksForTheHashOnASampledPair() throws {
        let catalog = try P0TruthFixtureCatalog.build("compare")
        defer { catalog.cleanup() }
        let evidence = try Self.pairEvidence(catalog)
        let verdict = RelatedLadder.judge(evidence)
        let reco = EventRecommendation.recommend(verdict, evidence: evidence)
        let missing = verdict.lines.filter { $0.kind == .missing }.map(\.words)

        #expect(evidence.a.digest == nil, "a sampled v1: hash is never a whole-file digest")
        #expect(evidence.b.digest == nil)
        #expect(!verdict.isIdenticalCopy, "no byte-for-byte proof without the whole-file hash")
        #expect(reco.rule == .r8, "\(reco.rule): \(reco.words)")
        #expect(reco.door == .fingerprint, "\(reco.door): \(reco.words)")
        #expect(reco.words.hasPrefix("Fill in full hashes first"), Comment(rawValue: reco.words))
        #expect(!reco.words.contains("longer"), Comment(rawValue: reco.words))
        #expect(missing.contains { $0.hasPrefix("No whole-file SHA-256 for either file") }, "the ladder names the gap: \(missing)")
    }

    // MARK: 5. Footage folders (FootageFolders.index)

    @Test("Footage folders (FootageFolders.index over footageFolderRows of two v1:-only rows): the pair is never '= copy · byte for byte'")
    func folderViewNeverCallsASampledPairCopies() throws {
        let catalog = try P0TruthFixtureCatalog.build("folders")
        defer { catalog.cleanup() }
        let a = try catalog.require(.sampledOnlyA)
        let b = try catalog.require(.sampledOnlyB)
        #if !P0_RED_AUDIT && !P0_RED_COMPARE
        let rowA = catalog.model.footageFolderRow(a)
        let rowB = catalog.model.footageFolderRow(b)
        let event = FootageFolders.Event(title: "Christmas c1990s", contentKeys: [rowA.contentKey, rowB.contentKey])
        let index = FootageFolders.index(rows: catalog.model.footageFolderRows(), events: [event])
        let pair: Set<UUID> = [a.id, b.id]
        let relations = index.families.flatMap(\.members).filter { pair.contains($0.id) }.map(\.relation)
        let words = relations.compactMap(\.words)

        #expect(Self.copyKey(rowA, sampledHash: a.contentHash) == nil, "a v1: hash is no copy identity")
        #expect(Self.copyKey(rowB, sampledHash: b.contentHash) == nil, "a v1: hash is no copy identity")
        #expect(relations.count == 2, "both files sit in the event's folder: \(relations)")
        #expect(!relations.contains { $0.isCopy }, "never '= copy': \(relations)")
        #expect(!words.contains { $0.contains("byte for byte") }, "\(words)")
        #else
        Issue.record("FootageFolders does not exist at this commit (\(a.filename) / \(b.filename))")
        #endif
    }

    // MARK: 6. Audit Catalog (applyCatalogAudit → CatalogAuditProof)

    @Test("Audit Catalog (stat + the proof through a directory handle, no where-seen stamp): a link row and a never-seen row are listed, never marked")
    func auditListsALinkRowForFixLinksAndMarksNothing() throws {
        let catalog = try P0TruthFixtureCatalog.build("audit")
        defer { catalog.cleanup() }
        let link = try catalog.require(.deadLinkSource)
        let unseen = try catalog.require(.sourceWithoutCopy)

        let linkResult = try Self.audit(link, in: catalog)
        #expect(linkResult.stat == .gone, "the first pass follows the link and finds nothing")
        #expect(["couldNotCheck", "neverSeenByAnAudit"].contains(linkResult.result), "\(linkResult.result): \(linkResult.detail)")
        #expect(linkResult.detail.contains("link"), Comment(rawValue: linkResult.detail))
        #expect(!linkResult.marked, "no mark for a link")
        #expect(link.removal == nil, "the row is not marked Missing")

        let unseenResult = try Self.audit(unseen, in: catalog)
        #expect(unseenResult.result == "neverSeenByAnAudit", "\(unseenResult.result): \(unseenResult.detail)")
        #expect(unseenResult.detail.contains("Fix Links decides"), Comment(rawValue: unseenResult.detail))
        #expect(!unseenResult.detail.contains("not connected"), "the drive IS connected: \(unseenResult.detail)")
        #expect(!unseenResult.marked, "no mark without a where-seen stamp")
        #expect(unseen.removal == nil)
    }

    // MARK: 7. Sound (the fingerprint stamp)

    @Test("Sound (AudioFingerprintStamp: analyzedSeconds > 0, landmarks == 0; Compare Media's relatedSide): a silent header is not 'has sound'")
    func silentHeaderIsNotHasSound() throws {
        let catalog = try P0TruthFixtureCatalog.build("silent")
        defer { catalog.cleanup() }
        let row = try catalog.require(.silentHeader)
        let stamp = try #require(row.audioFingerprint)

        // The pure facts: the header says Video+Audio; the sound print
        // analysed seconds and heard nothing.
        #expect(row.streamTypeRaw == "Video+Audio")
        #expect(stamp.outcome == .fingerprinted)
        #expect(stamp.analyzedSeconds > 0)
        #expect(stamp.landmarks == 0, "no landmark = nothing was heard")

        // The one surface that reads the stamp today (Compare Media's side)
        // still counts analysed seconds as audible ones. The surface that
        // says "silent" is TO BUILD (GH #327 case 5); when it lands this
        // known issue stops reproducing and the test fails — update it then.
        let side = VideoScanModel.relatedSide(row, isArchiveFile: false, isArchived: false, now: Date())
        withKnownIssue("relatedSide reads a fingerprinted stamp with 0 landmarks as \(stamp.analyzedSeconds) s of sound") {
            #expect(side.audibleSeconds == 0)
        }
    }

    // MARK: Source sensors

    @Test("Source sensor (FileJourneySheet.swift, VideoScanModel+Provenance.swift): no path is rendered as presence without a stat")
    func journeyRendersNoPathAsPresenceWithoutAStat() throws {
        let sheet = try Self.code("VideoScan/Catalog/FileJourneySheet.swift")
        let provenance = try Self.code("VideoScan/Catalog/VideoScanModel+Provenance.swift")
        let unverified = (sheet + provenance).filter(Self.statesPresenceUnverified)
        let scanned = provenance.filter { $0.contains("\"Scanned on") }

        #expect(unverified.isEmpty, "a path stated as presence with no stat: \(unverified)")
        #expect(scanned.isEmpty, "an mtime is not a scan: \(scanned)")
        #expect(provenance.contains { $0.contains("JourneyPresence.currentSentence(") },
                "the journey's last event must come from the verified presence")
    }

    @Test("Source sensor (FootageFolders.swift, MediaOps/Cleanup/*, VideoScanCore RelatedScore.swift): no sampled v1: hash in a copy/identical equality")
    func noSampledHashDecidesACopy() throws {
        var files = ["VideoScan/Catalog/FootageFolders.swift", "VideoScanCore/Sources/VideoScanCore/RelatedScore.swift"]
        files += try Self.swiftFiles(in: "VideoScan/MediaOps/Cleanup")
        try #require(files.count > 2, "MediaOps/Cleanup moved — update the sensor")
        for file in files {
            let lines = try Self.code(file)
            let sampled = lines.filter { $0.contains("contentHash") }
            let v1 = lines.filter { $0.contains("\"v1:\"") && !Self.refusesV1($0) }
            #expect(sampled.isEmpty, "\(file) reads the sampled contentHash: \(sampled)")
            #expect(v1.isEmpty, "\(file) uses a v1: hash other than to refuse it: \(v1)")
        }
    }

    @Test("Source sensor (Catalog/CatalogHelpers.swift): every in-app player start checks the AVFoundation audio tracks")
    func everyPlayerStartChecksTheAudio() throws {
        let lines = try Self.code("VideoScan/Catalog/CatalogHelpers.swift")
        let starts = lines.filter { $0.contains("AVPlayer(url:") }.count
        let checks = lines.filter { $0.contains("checkPlaybackAudio(") }.count
        #expect(starts >= 2, "the preview player's AVPlayer starts moved — update the sensor")
        #expect(checks >= 2, "\(starts) AVPlayer starts, \(checks) audio checks — an MP3-in-MP4 file plays silently")
    }

    @Test("Source sensor (Archive/ArchiveView*.swift): open and reveal go only through archivePlayableRecord")
    func archiveDoorsGoOnlyThroughTheResolver() throws {
        let views = try Self.swiftFiles(in: "VideoScan/Archive").filter { ($0 as NSString).lastPathComponent.hasPrefix("ArchiveView") }
        try #require(!views.isEmpty, "the Archive view files moved — update the sensor")
        for file in views where !file.hasSuffix("ArchiveView+Doors.swift") {
            let direct = try Self.code(file).filter { $0.contains("MediaOpener.open(") || $0.contains("NSWorkspace.shared.selectFile(") }
            #expect(direct.isEmpty, "\(file) opens or reveals a row directly: \(direct)")
        }
        let doors = try Self.code("VideoScan/Archive/ArchiveView+Doors.swift")
        #expect(doors.contains { $0.contains("archivePlayableRecord(for:") }, "the door file must resolve through archivePlayableRecord(for:)")
    }
}

// MARK: - Helpers (each one surface call; kept out of the tests' bodies)

extension P0TruthRegressionTests {

    static func journey(_ rec: VideoRecord, in catalog: P0TruthFixtureCatalog) -> FileJourney {
        VideoScanModel.buildFileJourney(for: rec, allRecords: catalog.model.records,
                                        resolveVolumeSafety: { _ in VolumeSafety.unknown })
    }

    /// The pair as Compare Media projects it (VideoScanModel.relatedAnswer):
    /// each side from the catalog row, on-disk from a stat, and the sound
    /// print's answer for two copies of one recording.
    static func pairEvidence(_ catalog: P0TruthFixtureCatalog) throws -> RelatedEvidence {
        let a = try catalog.require(.sampledOnlyA)
        let b = try catalog.require(.sampledOnlyB)
        return RelatedEvidence(a: side(a, in: catalog), b: side(b, in: catalog), audio: .sameRecording, audioCoverage: 1.0)
    }

    private static func side(_ r: VideoRecord, in catalog: P0TruthFixtureCatalog) -> RelatedEvidence.Side {
        let model = catalog.model
        var side = VideoScanModel.relatedSide(r, isArchiveFile: model.isArchiveCopy(r) || model.isInsideMasterArchive(path: r.fullPath),
                                              isArchived: model.isArchived(r), now: Date())
        side.isOnDisk = FileManager.default.fileExists(atPath: r.fullPath)
        side.audibleSeconds = r.durationSeconds
        return side
    }

    #if !P0_RED_AUDIT && !P0_RED_COMPARE
    /// The folder view's copy identity. Under P0_RED_FOLDER_MUTANT this is
    /// a copy of `FootageFolders.Row.copyKey` with its `v1:` guard removed
    /// — the defect the folder view must never have — so the red half of
    /// the folder test can be shown on main.
    static func copyKey(_ row: FootageFolders.Row, sampledHash: String) -> String? {
        #if P0_RED_FOLDER_MUTANT
        if !sampledHash.isEmpty, row.sizeBytes > 0 { return "d:\(sampledHash):\(row.sizeBytes)" }
        #endif
        return row.copyKey
    }
    #endif

    /// One audit row, as the job does it: plan (lane = the fixture root),
    /// the first-pass stat, then the model's one apply (the proof at the
    /// mark). Result as its raw value so the red builds compile.
    static func audit(_ rec: VideoRecord, in catalog: P0TruthFixtureCatalog) throws
        -> (stat: CatalogAuditStat, result: String, detail: String, marked: Bool) {
        #if P0_RED_COMPARE
        let plan = catalog.model.catalogAuditPlan()   // b03c3ce6b: no lane-root seam yet
        #else
        let root = catalog.root.path
        let plan = catalog.model.catalogAuditPlan(laneRoot: { _ in root })
        #endif
        let item = try #require(plan.lanes.flatMap(\.items).first { $0.id == rec.id }, "the audit did not plan \(rec.filename)")
        let stat = CatalogAuditStat.of(item.path)
        let applied = catalog.model.applyCatalogAudit(stat, to: item)
        return (stat, applied.apply.result.rawValue, applied.apply.detail, applied.mark != nil)
    }

    // MARK: Player helpers

    #if !P0_RED_JOURNEY && !P0_RED_AUDIT && !P0_RED_COMPARE
    static func expectMP3Notice(_ row: VideoRecord) async throws {
        let codec = PlaybackAudioMismatch.catalogCodec(of: row)
        let tracks = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: row.fullPath))
        let words = PlaybackAudioMismatch.words(catalogCodec: codec, avAudioTracks: tracks)
        #expect(codec == "mp3", "the catalog row says MP3 sound")
        #expect(tracks == 0, "AVFoundation does not read MP3 in an MPEG-4 container")
        #expect(words == "This file's MP3 sound can't be played by QuickTime. Open in IINA/VLC, or make an access copy (AAC).")
    }

    static func expectNoNotice(_ row: VideoRecord) async throws {
        let codec = PlaybackAudioMismatch.catalogCodec(of: row)
        let tracks = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: row.fullPath))
        #expect(tracks == 1, "\(row.filename): AVFoundation reads its \(codec) track")
        #expect(PlaybackAudioMismatch.words(catalogCodec: codec, avAudioTracks: tracks) == nil, "\(row.filename) plays with sound")
    }

    /// MKV is the existing not-playable route: the preview never starts an
    /// AVPlayer on it (filmstrip), and AVFoundation cannot open it at all.
    static func expectNotPlayableRoute(_ row: VideoRecord) async throws {
        let route = PreviewFrameRouter.previewRoute(container: "Matroska / WebM", videoCodec: row.videoCodec, likelyUnanalyzable: false)
        #expect(PreviewPlayAction.forRoute(route) == .filmstrip, "\(row.filename) never instantiates an AVPlayer")
        await #expect(throws: (any Error).self, "AVFoundation cannot open Matroska") {
            _ = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: row.fullPath))
        }
    }
    #endif

    // MARK: Sensor helpers

    /// The app project folder (…/VideoScan/VideoScan.xcodeproj's sibling folders).
    private static var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Code lines only — comments may (and do) quote the old calls.
    static func code(_ relative: String) throws -> [String] {
        try String(contentsOf: project.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    static func swiftFiles(in relative: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(relative).path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { relative + "/" + $0 }
    }

    /// "Now at <a path>" or a bare path in a Text — a location stated as
    /// presence. JourneyPresence (outside these files) is the one place
    /// allowed to say "Now at", after its lstat.
    static func statesPresenceUnverified(_ line: String) -> Bool {
        line.contains("\"Now at \\(") || line.contains("Text(rec.fullPath)") || line.contains("Text(record.fullPath)")
    }

    /// A line that mentions "v1:" only to refuse it.
    static func refusesV1(_ line: String) -> Bool {
        line.contains("!") && line.contains("hasPrefix(\"v1:\")")
    }
}
