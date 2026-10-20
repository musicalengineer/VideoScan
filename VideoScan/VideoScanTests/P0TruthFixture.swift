// P0TruthFixture.swift
// The fixture catalog the P0 truth-regression suite grows from (GH #327,
// docs/briefs/cloud/P0_REGRESSION_SUITE.md): one TABLE of rows, each the
// smallest catalog shape that made a surface state an unverified fact on
// 2026-10-16. A new case is one new row in `P0TruthFixtureCatalog.table`.
//
// Privacy: nothing here is family media. Every file is synthetic — a few
// KB of seeded bytes, an empty data file, or (only when a test asks for
// media) a 3-second ffmpeg test pattern — and lives under a per-run temp
// folder; nothing is written under the home folder.
//
// The tree, under the PHYSICAL temp root (realpath'd: the audit refuses a
// symlink anywhere in a path, and /var → /private/var is one):
//   FamilyArchive/Test_Family_Archive/30_Video/1990-1999/1990/   archived copies
//   Workspace/                                                    a working drive
//   Movies/                                                       a ~/Movies-like folder
//   VolumeA/, VolumeB/                                            two "volumes" for the pair
//
// The model is ShowAgainSandbox's (isolated catalog store, ledger and
// logs); the rows are set on it as the catalog.
//
// This file must compile at the RED commits too (the suite is run there
// for its red half — see docs/reviews/p0-regression-2026-10-17.md), so it
// uses only API that exists at b03c3ce6b and later.
//
// (For Rick: the table is a constant array of plain structs — think a
// `static const` C++ array of PODs — and `build` walks it once.)

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - The table's vocabulary

/// One row of the fixture catalog, named after the fall it reproduces.
enum P0TruthRowKind: String, CaseIterable, Sendable {
    /// A promotion source whose path is a dangling symlink (the target was deleted).
    case deadLinkSource
    /// Its archived copy, on disk under the fake archive, with a SHA-256 fixity of its real bytes.
    case deadLinkArchivedCopy
    /// Two byte-identical files on two volumes, carrying only a sampled `v1:` hash.
    case sampledOnlyA
    case sampledOnlyB
    /// Real ffmpeg media (only when built `withMedia`), catalogued Video+Audio.
    case mp3InM4V
    case aacInMP4
    case pcmInMOV
    case ffv1InMKV
    /// A promotion source whose archived copy ROW exists but whose files are both gone.
    case sourceWithoutCopy
    case sourceWithoutCopyArchivedCopy
    /// Catalogued Video+Audio; the sound stamp analysed seconds and found no landmarks.
    case silentHeader
    /// A file whose mtime (2024-02-22) is years before it was catalogued (2026-08-12).
    case mtimeYearsBeforeCatalogue
    /// A working file with only a sampled `v1:` hash that EQUALS an archive
    /// copy's — but whose bytes differ (the windows agree, the rest does
    /// not). No promote link, no whole-file SHA-256 (GH #327, 2026-10-19).
    case sampledMatchSource
    /// That archive copy: promoted from some other row (not in this
    /// catalog), SHA-256 fixity of ITS bytes, the same `v1:` signature.
    case sampledMatchArchiveCopy
}

/// Which folder of the tree a row's file sits in.
enum P0TruthFolder: Sendable {
    case archiveYear, workspace, movies, volumeA, volumeB
}

/// What is on disk at a row's path.
enum P0TruthDisk: Sendable, Equatable {
    /// Seeded bytes (the same seed → byte-identical files).
    case bytes(seed: UInt64)
    /// A symlink whose target was written and then deleted.
    case danglingLink
    /// Nothing: the file is gone.
    case nothing
    /// A 3-second ffmpeg fixture (an empty data file unless built `withMedia`).
    case media(P0TruthMedia)
}

/// The synthetic media matrix (CLAUDE.md feature checklist, dimension 3).
enum P0TruthMedia: Sendable, Equatable {
    case mp3InM4V, aacInMP4, pcmInMOV, ffv1InMKV

    /// ffmpeg codec arguments after the two lavfi inputs.
    var ffmpegArgs: [String] {
        switch self {
        case .mp3InM4V: return ["-c:v", "libx264", "-c:a", "libmp3lame", "-preset", "ultrafast", "-f", "mp4"]
        case .aacInMP4: return ["-c:v", "libx264", "-c:a", "aac", "-preset", "ultrafast"]
        case .pcmInMOV: return ["-c:v", "prores", "-c:a", "pcm_s16le"]
        case .ffv1InMKV: return ["-c:v", "ffv1", "-c:a", "pcm_s16le"]
        }
    }

    /// MP3 wants 44.1 kHz; the rest take 48 kHz.
    var sampleRate: String { self == .mp3InM4V ? "44100" : "48000" }
}

/// One row of the table: the file, what is on disk, and the catalog facts
/// that made a surface speak.
struct P0TruthRowSpec: Sendable {
    let kind: P0TruthRowKind
    let folder: P0TruthFolder
    let filename: String
    let disk: P0TruthDisk
    var videoCodec = "h264"
    var audioCodec = "aac"
    /// Master-assigned (a promotion source).
    var isPromotionSource = false
    /// This row is the archived copy of that row (derivedFrom + the promote kind).
    var archivedCopyOf: P0TruthRowKind?
    /// The row carries only the sampled `v1:` hash.
    var sampledHashOnly = false
    /// The sound stamp says it analysed seconds and found no landmarks.
    var silentStamp = false
    /// The catalog's duration (Compare Media's sides read it).
    var durationSeconds = 3.0
    /// An archive copy (Promote's derivation kind + the SHA-256 fixity of
    /// its bytes) whose source row is NOT in the catalog.
    var orphanArchiveCopy = false
    /// Carry this row's sampled `v1:` hash (a sampled collision).
    var sharesSampledHashWith: P0TruthRowKind?
}

// MARK: - The catalog

@MainActor
struct P0TruthFixtureCatalog {

    /// Every case is one row. Add a row; never a builder branch.
    static let table: [P0TruthRowSpec] = [
        P0TruthRowSpec(kind: .deadLinkSource, folder: .movies, filename: "Christmas-1990.mov", disk: .danglingLink,
                       isPromotionSource: true),
        P0TruthRowSpec(kind: .deadLinkArchivedCopy, folder: .archiveYear, filename: "1990_Christmas-1990.mov",
                       disk: .bytes(seed: 1990), archivedCopyOf: .deadLinkSource),
        P0TruthRowSpec(kind: .sampledOnlyA, folder: .volumeA, filename: "Christmas-c1990s.flv", disk: .bytes(seed: 7),
                       sampledHashOnly: true, durationSeconds: 9553),
        P0TruthRowSpec(kind: .sampledOnlyB, folder: .volumeB, filename: "Christmas-c1990s.flv", disk: .bytes(seed: 7),
                       sampledHashOnly: true, durationSeconds: 9553),
        P0TruthRowSpec(kind: .mp3InM4V, folder: .workspace, filename: "test_mp3_in_m4v.m4v", disk: .media(.mp3InM4V),
                       audioCodec: "mp3"),
        P0TruthRowSpec(kind: .aacInMP4, folder: .workspace, filename: "test_aac_in_mp4.mp4", disk: .media(.aacInMP4)),
        P0TruthRowSpec(kind: .pcmInMOV, folder: .workspace, filename: "test_pcm_in_mov.mov", disk: .media(.pcmInMOV),
                       videoCodec: "prores", audioCodec: "pcm_s16le"),
        P0TruthRowSpec(kind: .ffv1InMKV, folder: .workspace, filename: "test_ffv1_in_mkv.mkv", disk: .media(.ffv1InMKV),
                       videoCodec: "ffv1", audioCodec: "pcm_s16le"),
        P0TruthRowSpec(kind: .sourceWithoutCopy, folder: .movies, filename: "Easter-1991.mov", disk: .nothing,
                       isPromotionSource: true),
        P0TruthRowSpec(kind: .sourceWithoutCopyArchivedCopy, folder: .archiveYear, filename: "1991_Easter-1991.mov",
                       disk: .nothing, archivedCopyOf: .sourceWithoutCopy),
        P0TruthRowSpec(kind: .silentHeader, folder: .workspace, filename: "test_silent_header.mov", disk: .bytes(seed: 11),
                       silentStamp: true),
        P0TruthRowSpec(kind: .mtimeYearsBeforeCatalogue, folder: .workspace, filename: "Birthday-1993.mov",
                       disk: .bytes(seed: 1993)),
        P0TruthRowSpec(kind: .sampledMatchSource, folder: .workspace, filename: "Picnic-1992.mov",
                       disk: .bytes(seed: 1992), sampledHashOnly: true),
        P0TruthRowSpec(kind: .sampledMatchArchiveCopy, folder: .archiveYear, filename: "1992_Picnic-1992.mov",
                       disk: .bytes(seed: 2992), orphanArchiveCopy: true, sharesSampledHashWith: .sampledMatchSource),
    ]

    /// The file's own clock and the catalog's, for every row (2024-02-22
    /// mtime; catalogued 2026-08-12) — Rick's AAB6EF57 dates.
    static let fileDate = day(2024, 2, 22)
    static let cataloguedDate = day(2026, 8, 12)
    static let fileBytes = 4096

    let sandbox: ShowAgainSandbox
    /// The physical fixture root (no symlink in any component).
    let root: URL
    let rows: [P0TruthRowKind: VideoRecord]

    var model: VideoScanModel { sandbox.model }

    func url(_ folder: P0TruthFolder) -> URL { Self.url(folder, in: root) }

    /// The row, or a test failure naming the missing kind.
    func require(_ kind: P0TruthRowKind) throws -> VideoRecord {
        try #require(rows[kind], "the fixture table has no \(kind.rawValue) row")
    }

    func cleanup() { sandbox.cleanup() }

    /// Build the whole table under a fresh temp root. `withMedia` runs
    /// ffmpeg for the four media rows; without it they are empty files.
    static func build(_ label: String, withMedia: Bool = false) throws -> P0TruthFixtureCatalog {
        let sandbox = try ShowAgainSandbox.make("p0truth_\(label)")
        let root = physical(sandbox.root).appendingPathComponent("fixture", isDirectory: true)
        for folder in [P0TruthFolder.archiveYear, .workspace, .movies, .volumeA, .volumeB] {
            try FileManager.default.createDirectory(at: url(folder, in: root), withIntermediateDirectories: true)
        }
        var rows: [P0TruthRowKind: VideoRecord] = [:]
        for spec in table {
            let path = url(spec.folder, in: root).appendingPathComponent(spec.filename)
            try writeDisk(spec.disk, at: path, withMedia: withMedia)
            rows[spec.kind] = record(spec, path: path)
        }
        for spec in table {
            if let source = spec.archivedCopyOf, let copy = rows[spec.kind], let original = rows[source] {
                linkArchivedCopy(copy, to: original)
            }
            if let other = spec.sharesSampledHashWith, let row = rows[spec.kind], let twin = rows[other] {
                row.contentHash = twin.contentHash
            }
        }
        sandbox.model.records = table.compactMap { rows[$0.kind] }
        return P0TruthFixtureCatalog(sandbox: sandbox, root: root, rows: rows)
    }

    // MARK: Building one row

    private static func url(_ folder: P0TruthFolder, in root: URL) -> URL {
        switch folder {
        case .archiveYear:
            return root.appendingPathComponent("FamilyArchive/Test_Family_Archive/30_Video/1990-1999/1990", isDirectory: true)
        case .workspace: return root.appendingPathComponent("Workspace", isDirectory: true)
        case .movies: return root.appendingPathComponent("Movies", isDirectory: true)
        case .volumeA: return root.appendingPathComponent("VolumeA", isDirectory: true)
        case .volumeB: return root.appendingPathComponent("VolumeB", isDirectory: true)
        }
    }

    private static func writeDisk(_ disk: P0TruthDisk, at url: URL, withMedia: Bool) throws {
        switch disk {
        case .bytes(let seed):
            try MasterArchiveTestSupport.writeBlob(at: url, bytes: fileBytes, seed: seed)
            try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: url.path)
        case .danglingLink:
            let target = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Workspace/moved-away-\(url.lastPathComponent)")
            try MasterArchiveTestSupport.writeBlob(at: target, bytes: fileBytes, seed: 99)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            try FileManager.default.removeItem(at: target)
        case .nothing:
            break
        case .media(let media):
            if withMedia { try makeMedia(media, at: url) } else { try Data().write(to: url) }
        }
    }

    /// A 3-second test pattern + two-tone sound, the PlaybackAudioMismatch
    /// matrix's recipe.
    private static func makeMedia(_ media: P0TruthMedia, at url: URL) throws {
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25",
            "-f", "lavfi", "-i", "aevalsrc=0.5*sin(440*2*PI*t)|0.5*sin(987*2*PI*t):s=\(media.sampleRate):d=3",
            "-map", "0:v:0", "-map", "1:a:0",
        ] + media.ffmpegArgs, output: url.path)
    }

    private static func record(_ spec: P0TruthRowSpec, path: URL) -> VideoRecord {
        let r = VideoRecord()
        r.filename = spec.filename
        r.fullPath = path.path
        r.directory = path.deletingLastPathComponent().path
        r.ext = path.pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.videoCodec = spec.videoCodec
        r.audioCodec = spec.audioCodec
        r.resolution = "320x240"
        r.durationSeconds = spec.durationSeconds
        // A link's own size is not the file's: a dead link keeps the size it was catalogued at.
        r.sizeBytes = spec.disk == .danglingLink ? Int64(fileBytes) : (onDiskSize(path) ?? Int64(fileBytes))
        r.partialMD5 = "p0\(spec.kind.rawValue.prefix(6))"
        r.dateModifiedRaw = fileDate
        r.scanContext.scannedAt = cataloguedDate
        if spec.isPromotionSource { markPromotionSource(r) }
        if spec.sampledHashOnly { r.contentHash = sampledHash(path) }
        if spec.silentStamp { r.audioFingerprint = silentStamp(sizeBytes: r.sizeBytes) }
        if spec.orphanArchiveCopy { markOrphanArchiveCopy(r) }
        return r
    }

    private static func markPromotionSource(_ r: VideoRecord) {
        r.archiveStage = .masterAssigned
        r.notes = "Promote 2026-08-12T15:00:00Z: promoted to Master Archive as 30_Video/1990-1999/1990/1990_\(r.filename)"
    }

    /// The archived copy: derived from the source by Promote, with the
    /// SHA-256 of its REAL bytes when they are on disk.
    private static func linkArchivedCopy(_ copy: VideoRecord, to source: VideoRecord) {
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        let digest = sha256(ofFile: copy.fullPath) ?? String(repeating: "ab", count: 32)
        copy.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: cataloguedDate, sizeBytes: copy.sizeBytes)
    }

    /// An archive copy whose source row is not in this catalog: Promote's
    /// kind, a source id nobody has, the SHA-256 of its own bytes.
    private static func markOrphanArchiveCopy(_ copy: VideoRecord) {
        copy.derivedFrom = UUID()
        copy.derivationKind = ArchivePromotion.derivationKind
        let digest = sha256(ofFile: copy.fullPath) ?? String(repeating: "cd", count: 32)
        copy.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: cataloguedDate, sizeBytes: copy.sizeBytes)
    }

    /// A stamp that analysed the whole 3 s and found no landmark — the
    /// header said "audio", the sound said nothing.
    private static func silentStamp(sizeBytes: Int64) -> AudioFingerprintStamp {
        AudioFingerprintStamp(computedAt: cataloguedDate, contentDigest: "v1:silent", sizeBytes: sizeBytes,
                              outcome: .fingerprinted, analyzedSeconds: 3, complete: true, landmarks: 0, bytes: 0)
    }

    /// The scan's sampled hash shape ("v1:" + hex) — here the SHA-256 of
    /// the bytes stands in for head ‖ middle ‖ tail ‖ size, so the two
    /// identical files agree, exactly as the real pair did.
    private static func sampledHash(_ url: URL) -> String {
        "v1:" + String((sha256(ofFile: url.path) ?? "").prefix(32))
    }

    static func sha256(ofFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func onDiskSize(_ url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// realpath(3) of an existing folder (ShowAgainSandbox.physical is not
    /// at every red commit, so the fixture carries its own).
    static func physical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = 12
        return Calendar.current.date(from: c) ?? .distantPast
    }
}

// MARK: - The fixture's own suite

@Suite("P0 truth fixture — the table builds what it says", .serialized)
@MainActor
struct P0TruthFixtureTests {

    @Test("every table row becomes one catalog row on the sandbox model")
    func everyRowOfTheTableIsBuilt() throws {
        let catalog = try P0TruthFixtureCatalog.build("rows")
        defer { catalog.cleanup() }
        #expect(catalog.rows.count == P0TruthFixtureCatalog.table.count)
        #expect(catalog.model.records.count == P0TruthFixtureCatalog.table.count)
        #expect(Set(P0TruthFixtureCatalog.table.map(\.kind)) == Set(P0TruthRowKind.allCases))
        #expect(!catalog.root.path.hasPrefix(NSHomeDirectory() + "/Movies"), "nothing under ~/Movies")
        #expect(catalog.root.path.contains("test_showagain_p0truth_rows"))
    }

    @Test("lstat sees the dead link; stat does not; the archived copy's fixity is the SHA-256 of its bytes")
    func deadLinkAndArchivedCopyAreWhatTheySay() throws {
        let catalog = try P0TruthFixtureCatalog.build("deadlink")
        defer { catalog.cleanup() }
        let source = try catalog.require(.deadLinkSource)
        let copy = try catalog.require(.deadLinkArchivedCopy)
        var sb = stat()
        let linkThere = lstat(source.fullPath, &sb) == 0
        let isLink = (sb.st_mode & S_IFMT) == S_IFLNK
        #expect(linkThere, "the link itself is there")
        #expect(isLink, "lstat says S_IFLNK")
        #expect(!FileManager.default.fileExists(atPath: source.fullPath), "its target is gone")
        #expect(copy.derivedFrom == source.id)
        #expect(copy.derivationKind == ArchivePromotion.derivationKind)
        let fixity = try #require(copy.archiveFixity)
        #expect(fixity.digest == P0TruthFixtureCatalog.sha256(ofFile: copy.fullPath))
        #expect(copy.fullPath.contains("/30_Video/1990-1999/1990/"))
    }

    @Test("the sampled pair: identical bytes, a v1: hash each, no whole-file digest")
    func sampledPairIsByteIdenticalWithOnlyAV1Hash() throws {
        let catalog = try P0TruthFixtureCatalog.build("pair")
        defer { catalog.cleanup() }
        let a = try catalog.require(.sampledOnlyA)
        let b = try catalog.require(.sampledOnlyB)
        #expect(FileManager.default.contentsEqual(atPath: a.fullPath, andPath: b.fullPath))
        #expect(a.contentHash.hasPrefix("v1:"))
        #expect(a.contentHash == b.contentHash)
        #expect(a.contentFixity == nil)
        #expect(a.archiveFixity == nil)
        #expect(a.directory != b.directory, "two places, not one")
    }

    @Test("the file's own clock is 2024-02-22 on disk and in the row; the catalogue date is 2026-08-12")
    func mtimeRowCarriesBothClocks() throws {
        let catalog = try P0TruthFixtureCatalog.build("mtime")
        defer { catalog.cleanup() }
        let row = try catalog.require(.mtimeYearsBeforeCatalogue)
        let attrs = try FileManager.default.attributesOfItem(atPath: row.fullPath)
        let mtime = attrs[.modificationDate] as? Date
        #expect(mtime == P0TruthFixtureCatalog.fileDate)
        #expect(row.dateModifiedRaw == P0TruthFixtureCatalog.fileDate)
        #expect(row.scanContext.scannedAt == P0TruthFixtureCatalog.cataloguedDate)
    }

    @Test("the sampled collision: the same v1: hash, different bytes; the copy has a SHA-256 fixity and no source row")
    func sampledMatchIsACollisionNotACopy() throws {
        let catalog = try P0TruthFixtureCatalog.build("collision")
        defer { catalog.cleanup() }
        let source = try catalog.require(.sampledMatchSource)
        let copy = try catalog.require(.sampledMatchArchiveCopy)
        #expect(source.contentHash.hasPrefix("v1:"))
        #expect(source.contentHash == copy.contentHash, "the sampled signatures agree")
        #expect(!FileManager.default.contentsEqual(atPath: source.fullPath, andPath: copy.fullPath), "the bytes do not")
        #expect(source.contentFixity == nil, "no whole-file SHA-256 on the source")
        #expect(copy.derivationKind == ArchivePromotion.derivationKind)
        #expect(copy.derivedFrom != source.id)
        #expect(copy.archiveFixity?.digest == P0TruthFixtureCatalog.sha256(ofFile: copy.fullPath))
    }

    @Test("the silent header: Video+Audio in the catalog, a stamp with seconds analysed and no landmarks")
    func silentHeaderStampSaysNothingWasHeard() throws {
        let catalog = try P0TruthFixtureCatalog.build("silent")
        defer { catalog.cleanup() }
        let row = try catalog.require(.silentHeader)
        let stamp = try #require(row.audioFingerprint)
        #expect(row.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(stamp.analyzedSeconds > 0)
        #expect(stamp.landmarks == 0)
    }
}
