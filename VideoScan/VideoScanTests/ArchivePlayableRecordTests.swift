// ArchivePlayableRecordTests.swift
// Bug (Rick 2026-10-16): the Archive tab played the promotion SOURCE's
// path instead of the archived copy. Row AAB6EF57 was a symlink in
// ~/Movies whose target had moved; double-click / Play / Reveal said
// "does not exist" while the archived copy sat on FamilyArchive with a
// recorded fixity. The timeline card already resolved the COPY for its
// folder name (ArchiveView+Timeline.timelineItem) but every door — play,
// reveal, open, the detail sheet's file facts — used the source row.
//
// Pins:
//   * SOURCE SENSOR (red on the old code): no Archive door calls
//     MediaOpener / Finder reveal directly — they all go through the one
//     resolver, `archivePlayableRecord(for:)`.
//   * LOGIC: a source row with a gone path and an archived copy on disk
//     → the play target IS the copy; both gone → the words name the
//     ARCHIVE path (never the source path) and say Verify Archive; a
//     copy on disk beats a source on disk; a row with no copy is itself.
//   * ISOLATION: the real symptom — a dangling symlink as the source,
//     a real file as the copy — under a temp dir, no model sandbox.
//
// (For Rick: `#expect` ≈ EXPECT_* (keeps going); `#require` ≈ ASSERT_*.)

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Source sensor

@Suite("Archive doors — source sensor")
struct ArchiveDoorSourceSensors {

    private static var archiveDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/Archive", isDirectory: true)
    }

    /// Code lines only — comments may (and do) quote the old calls.
    private static func code(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Every ArchiveView file: opening and revealing go through the ONE
    /// door file, never straight to MediaOpener or Finder.
    @Test func everyArchiveViewDoorGoesThroughTheResolver() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.archiveDir,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ArchiveView") && $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "the Archive view files moved — update the sensor")
        for file in files where file.lastPathComponent != "ArchiveView+Doors.swift" {
            let lines = try Self.code(file)
            let direct = lines.filter {
                $0.contains("MediaOpener.open(") || $0.contains("NSWorkspace.shared.selectFile(")
            }
            #expect(direct.isEmpty,
                    "\(file.lastPathComponent) opens or reveals a row directly, bypassing archivePlayableRecord(for:): \(direct)")
        }
        let doors = try Self.code(Self.archiveDir.appendingPathComponent("ArchiveView+Doors.swift"))
        #expect(doors.contains { $0.contains("archivePlayableRecord(for:") },
                "the door file must resolve through archivePlayableRecord(for:)")
    }
}

// MARK: - Logic (no disk — the probe is injected)

@Suite("Archive doors — archivePlayableRecord(for:)")
@MainActor
struct ArchivePlayableRecordTests {

    private static func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 4096
        return r
    }

    /// Rick's row AAB6EF57: a promotion source (Master stage) whose file is
    /// gone, and its archived copy on FamilyArchive.
    private static func sourceAndCopy() -> (model: VideoScanModel, source: VideoRecord, copy: VideoRecord) {
        let model = VideoScanModel()
        let source = record("/Users/rickb/Movies/Christmas-1990-something.mov")
        source.archiveStage = .masterAssigned
        let copy = record("/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1990-1999/1990/1990_Christmas-1990-something.mov")
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: String(repeating: "ab", count: 32), verifiedAt: Date(), sizeBytes: 4096)
        model.records = [source, copy]
        return (model, source, copy)
    }

    @Test func sourceGoneCopyOnDiskPlaysTheCopy() {
        let (model, source, copy) = Self.sourceAndCopy()
        let onDisk: Set<String> = [copy.fullPath]
        let playable = model.archivePlayableRecord(for: source, fileExists: { onDisk.contains($0) })
        #expect(playable.record?.id == copy.id, "the play target is the archived copy")
        #expect(playable.path == copy.fullPath)
    }

    @Test func bothGoneNamesTheArchivePathNeverTheSource() throws {
        let (model, source, copy) = Self.sourceAndCopy()
        let playable = model.archivePlayableRecord(for: source, fileExists: { _ in false })
        #expect(playable.record == nil)
        let words = try #require(playable.message)
        #expect(words.contains(copy.fullPath), "the words name the ARCHIVE path")
        #expect(!words.contains(source.fullPath), "never the source path")
        #expect(words.contains("Verify Archive"))
        #expect(words.contains("not at its path"))
        #expect(playable.path == copy.fullPath)
    }

    @Test func copyOnDiskBeatsASourceThatIsAlsoThere() {
        let (model, source, copy) = Self.sourceAndCopy()
        let playable = model.archivePlayableRecord(for: source, fileExists: { _ in true })
        #expect(playable.record?.id == copy.id, "the Archive tab plays the archived file")
    }

    @Test func copyGoneSourceOnDiskFallsBackToTheRow() {
        let (model, source, _) = Self.sourceAndCopy()
        let onDisk: Set<String> = [source.fullPath]
        let playable = model.archivePlayableRecord(for: source, fileExists: { onDisk.contains($0) })
        #expect(playable.record?.id == source.id)
    }

    @Test func anArchiveCopyRowResolvesToItself() {
        let (model, _, copy) = Self.sourceAndCopy()
        #expect(model.archivePlayableRecord(for: copy, fileExists: { _ in true }).record?.id == copy.id)
        let gone = model.archivePlayableRecord(for: copy, fileExists: { _ in false })
        #expect(gone.message?.contains(copy.fullPath) == true)
    }

    @Test func aRowWithNoArchivedCopyIsItselfEvenWhenGone() {
        let model = VideoScanModel()
        let plain = Self.record("/Volumes/LaCieWorkspace/clip.mov")
        model.records = [plain]
        let playable = model.archivePlayableRecord(for: plain, fileExists: { _ in false })
        #expect(playable.record?.id == plain.id, "no archive copy → the ordinary looks-moved story, not Verify Archive")
    }

    @Test func missingWordsArePureAndNameTheArchive() {
        let words = VideoScanModel.archiveMissingWords(filename: "1990_X.mov", archivePath: "/Volumes/FamilyArchive/A/1990_X.mov")
        #expect(words.hasPrefix("1990_X.mov: the archived file is not at its path"))
        #expect(words.contains("Verify Archive"))
        #expect(words.hasSuffix("/Volumes/FamilyArchive/A/1990_X.mov"))
    }
}

// MARK: - The detail sheet's file facts (codex P2, 2026-10-16)

@Suite("Archive detail sheet — one file's facts never beside another's")
@MainActor
struct ArchiveDetailSheetWordsTests {

    private static func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    /// The door substituted the archived copy: the header says so and
    /// names both files with the row's own state; the Volume facts name
    /// each file's own volume.
    @Test func aSubstitutedCopyIsSaidSoWithBothPathsAndBothVolumes() {
        let source = Self.record("/Users/rickb/Movies/Christmas-1990.mov")
        let copy = Self.record("/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1990/1990_Christmas-1990.mov")
        let header = ArchiveDetailWords.headerPath(row: source, playable: .record(copy),
                                                   rowPresence: .brokenLink(target: "/Volumes/Projects/Christmas-1990.mov"))
        #expect(header == "Playing the archived copy: \(copy.fullPath) (this row: \(source.fullPath), a dead link)")
        let volumes = ArchiveDetailWords.volumeFacts(row: source, playable: .record(copy))
        #expect(volumes.map(\.label) == ["Volume (archived copy)", "Volume (this row)"])
        #expect(volumes.map(\.value) == [copy.volumeName, source.volumeName])
        #expect(copy.volumeName != source.volumeName, "the fixture must put the two files on different volumes")
    }

    @Test func theRowItselfKeepsItsOwnPathAndOneVolume() {
        let row = Self.record("/Volumes/FamilyArchive/A/1990_X.mov")
        #expect(ArchiveDetailWords.headerPath(row: row, playable: .record(row), rowPresence: .regularFile) == row.fullPath)
        #expect(ArchiveDetailWords.headerPath(row: row, playable: nil, rowPresence: nil) == row.fullPath)
        let volumes = ArchiveDetailWords.volumeFacts(row: row, playable: .record(row))
        #expect(volumes.map(\.label) == ["Volume"])
        #expect(volumes.map(\.value) == [row.volumeName])
    }

    @Test func aLostFileShowsTheArchiveWords() {
        let row = Self.record("/Users/rickb/Movies/X.mov")
        let words = VideoScanModel.archiveMissingWords(filename: "1990_X.mov", archivePath: "/Volumes/FamilyArchive/A/1990_X.mov")
        let playable = ArchivePlayable.missing(archivePath: "/Volumes/FamilyArchive/A/1990_X.mov", message: words)
        #expect(ArchiveDetailWords.headerPath(row: row, playable: playable, rowPresence: .missing) == words)
    }

    @Test func rowStateWordsCoverEveryPresence() {
        #expect(ArchiveDetailWords.rowState(.missing) == "not at its path")
        #expect(ArchiveDetailWords.rowState(.regularFile) == "also on disk")
        #expect(ArchiveDetailWords.rowState(.linkToFile(target: "/V/x.mov")) == "also on disk")
        #expect(ArchiveDetailWords.rowState(.brokenLink(target: "/V/x.mov")) == "a dead link")
        #expect(ArchiveDetailWords.rowState(.notAFile) == "not a file at its path")
        #expect(ArchiveDetailWords.rowState(.volumeOffline(volume: "LaCie")) == "on LaCie, not connected")
        #expect(ArchiveDetailWords.rowState(.unknown(reason: "Permission denied")) == "could not be checked: Permission denied")
        #expect(ArchiveDetailWords.rowState(nil) == "not checked")
    }
}

// MARK: - Isolation: the real symptom on a real disk (temp dir only)

@Suite("Archive doors — a dangling symlink source on disk", .serialized)
@MainActor
struct ArchivePlayableRecordIsolationTests {

    /// The source is a symlink whose target moved (Rick's ~/Movies row);
    /// the copy is a real file. The DEFAULT probe (FileManager, follows
    /// links) must pick the copy.
    @Test func danglingSymlinkSourcePlaysTheRealCopy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_archivedoor_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("Christmas-1990.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("moved/Christmas-1990.mov"))
        let copyURL = dir.appendingPathComponent("Archive/1990_Christmas-1990.mov")
        try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: copyURL)

        let model = VideoScanModel()
        let source = VideoRecord()
        source.filename = "Christmas-1990.mov"
        source.fullPath = link.path
        source.archiveStage = .masterAssigned
        let copy = VideoRecord()
        copy.filename = "1990_Christmas-1990.mov"
        copy.fullPath = copyURL.path
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        model.records = [source, copy]

        #expect(model.archivePlayableRecord(for: source).record?.id == copy.id)
        try FileManager.default.removeItem(at: copyURL)
        let gone = model.archivePlayableRecord(for: source)
        #expect(gone.record == nil)
        #expect(gone.message?.contains(copyURL.path) == true)
        #expect(gone.message?.contains(link.path) == false)
    }
}
