import Testing
import Foundation
@testable import VideoScan

// Characterization of "Copy All Metadata" (InspectorPanel.formatAllMetadata)
// — written BEFORE the C → B refactor (2026-11-07) and green on the old
// monolith, so the per-section formatters that replaced it are proven to
// produce the same text byte for byte: every section, its order, its
// omissions, across the media matrix (mp4/h264, mov/prores, mkv/ffv1+pcm,
// mxf, avi/dv) plus bare, partial, dossier and duplicate records.
//
// Golden strings are exact. Two lines depend on the host's locale and time
// zone (the inferred day-precise date and "Processed: … on …"), so the
// goldens carry a token for them and the test fills it with the same
// DateFormatter configuration the code uses. Paths sit under a volume that
// is never mounted, so the volume label and the (offline) marker are fixed.

@MainActor
struct InspectorMetadataTextCharacterizationTests {

    static let vol = "/Volumes/CharzNeverMounted"

    // MARK: Fixtures

    static func bare() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "bare.bin"
        r.fullPath = "\(vol)/bare.bin"
        return r
    }

    static func mp4H264() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "Birthday.mp4"
        r.fullPath = "\(vol)/Family/Birthday.mp4"
        r.directory = "\(vol)/Family"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.size = "1.1 GB"; r.duration = "00:12:01"; r.container = "MPEG-4"; r.ext = "mp4"
        r.resolution = "1920x1080"; r.videoCodec = "h264"; r.frameRate = "29.97"
        r.videoBitrate = "12 Mb/s"; r.totalBitrate = "12.3 Mb/s"; r.colorSpace = "bt709"
        r.bitDepth = "8"; r.scanType = "Progressive"
        r.audioCodec = "aac"; r.audioChannels = "2"; r.audioSampleRate = "48000"
        r.dateCreated = "2011-06-15 10:00"; r.dateModified = "2011-06-16 11:00"
        r.starRating = 4
        r.tags = ["birthday", "backyard"]
        r.userDate = "2011-06-15"; r.userDateConfidence = "known"
        r.embeddedCreationDate = Date(timeIntervalSince1970: 1_308_132_000) // 2011-06-15 10:00 UTC
        r.embeddedCreationSource = "QuickTime creation_time"
        r.originMake = "Apple"; r.originModel = "iPhone 4"
        r.partialMD5 = "abc123"
        r.contentHash = "sha256:deadbeef"
        return r
    }

    static func movProRes() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "Telecine_Reel3.mov"
        r.fullPath = "\(vol)/Scans/Telecine_Reel3.mov"
        r.directory = "\(vol)/Scans"
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        r.size = "48 GB"; r.duration = "00:21:40"; r.container = "QuickTime"; r.ext = "mov"
        r.resolution = "1440x1080"; r.videoCodec = "prores"; r.frameRate = "18"
        r.timecode = "01:00:00:00"; r.tapeName = "REEL3"
        r.userDate = "1968"   // no confidence = best guess
        r.userNotes = "Grandpa's Super 8, Cape Cod"
        r.notes = "probe: no audio stream"
        return r
    }

    static func mkvFFV1() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "VHS_Tape12.mkv"
        r.fullPath = "\(vol)/Captures/VHS_Tape12.mkv"
        r.directory = "\(vol)/Captures"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.size = "60 GB"; r.duration = "01:58:00"; r.container = "Matroska"; r.ext = "mkv"
        r.resolution = "720x486"; r.videoCodec = "ffv1"; r.frameRate = "29.97"
        r.scanType = "Interlaced (TFF)"
        r.audioCodec = "pcm_s24le"; r.audioChannels = "2"; r.audioSampleRate = "48000"
        r.inferredRecordDate = Date(timeIntervalSince1970: 771_681_600) // 1994-06-15 12:00 UTC
        r.inferredDateRange = InferredDateRange(year: 1994)
        r.inferredDateConfidence = 0.8125
        r.sceneCaptions = [SceneCaption(timestamp: 5, text: "a child blowing out candles"),
                           SceneCaption(timestamp: 125.9, text: "people at a table")]
        r.audioTranscript = "Happy birthday to you\n\nMake a wish!"
        r.ocrText = [SceneCaption(timestamp: 61, text: "JUN 15 1994")]
        r.ocrDateCandidates = [SceneCaption(timestamp: 61, text: "JUN 15 1994"),
                               SceneCaption(timestamp: 62, text: "!!!!!!!!!!!!")]
        r.dossierProcessedBy = "Qwen2.5-VL"
        r.dossierProcessedAt = Date(timeIntervalSince1970: 1_790_000_000)
        return r
    }

    static func mxfAvid() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "A001C003.mxf"
        r.fullPath = "\(vol)/Avid MediaFiles/MXF/1/A001C003.mxf"
        r.directory = "\(vol)/Avid MediaFiles/MXF/1"
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        r.container = "MXF"; r.ext = "mxf"; r.videoCodec = "dnxhd"
        r.avidClipName = "Interview_01"; r.avidMobType = "MasterMob"; r.avidBinFile = "Project.avb"
        r.avidTapeName = "A001"; r.avidTracks = "V1, A1-A2"; r.avidEditRate = 29.97
        r.avidMobID = "060a2b34-mob"; r.avidMaterialUUID = "mat-uuid-1"
        r.avidMediaPath = "/Volumes/MacPro/Avid MediaFiles/MXF/1/A001C003.mxf"
        return r
    }

    static func aviDV() -> (VideoRecord, partner: VideoRecord) {
        let r = VideoRecord()
        r.filename = "Christmas97.avi"
        r.fullPath = "\(vol)/DV/Christmas97.avi"
        r.directory = "\(vol)/DV"
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        r.size = "13 GB"; r.duration = "01:00:00"; r.container = "AVI"; r.ext = "avi"
        r.resolution = "720x480"; r.videoCodec = "dvvideo"; r.frameRate = "29.97"
        let partner = VideoRecord()
        partner.filename = "Christmas97.wav"
        partner.fullPath = "\(vol)/DV/Christmas97.wav"
        r.pairedWith = partner
        r.pairConfidence = .medium
        r.duplicateDisposition = .keep
        r.duplicateReasons = "Same size and duration"
        r.duplicateConfidence = .high
        return (r, partner)
    }

    static func dayPreciseInferred() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "Stamp.mp4"
        r.fullPath = "\(vol)/Stamp.mp4"
        r.inferredRecordDate = Date(timeIntervalSince1970: 771_681_600)
        return r
    }

    static func panel(_ rec: VideoRecord,
                      group: [VideoRecord] = [],
                      same: [VideoRecord] = [],
                      possible: [VideoRecord] = []) -> InspectorPanel {
        InspectorPanel(record: rec, duplicateGroupMembers: group,
                       sameFootageMembers: same, possibleSameFootage: possible,
                       previewImage: nil, previewOfflineVolumeName: nil)
    }

    static func other(_ name: String, codec: String) -> VideoRecord {
        let o = VideoRecord()
        o.filename = name
        o.fullPath = "\(vol)/Other/\(name)"
        o.videoCodec = codec
        o.duplicateDisposition = .extraCopy
        return o
    }

    // MARK: Locale-dependent tokens

    static func processedToken(_ at: Date) -> String {
        let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
        return fmt.string(from: at)
    }

    static func mediumDate(_ d: Date) -> String {
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    private func check(_ name: String, _ actual: String, _ golden: String) {
        guard actual != golden else { return }
        // Leave the actual text where a human can diff it: the per-process
        // temporary directory (sandbox-safe), and say if that write failed.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-charz", isDirectory: true)
            .appendingPathComponent("\(name).txt")
        var artefact = "actual text in \(file.path)"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try actual.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            artefact = "could not save the actual text to \(file.path): \(error)"
        }
        #expect(actual == golden, "\(name) differs — \(artefact)")
    }

    // MARK: Goldens

    @Test func bareRecordShowsOnlyHeaderAndEmptySections() {
        check("bare", Self.panel(Self.bare()).formatAllMetadata(Self.bare()), Golden.bare)
    }

    @Test func mp4H264FullTechnicalAndDates() {
        let r = Self.mp4H264()
        check("mp4", Self.panel(r).formatAllMetadata(r), Golden.mp4)
    }

    @Test func movProResPartialWithNotes() {
        let r = Self.movProRes()
        check("mov", Self.panel(r).formatAllMetadata(r), Golden.mov)
    }

    @Test func mkvFFV1DossierSection() throws {
        let r = Self.mkvFFV1()
        let at = try #require(r.dossierProcessedAt)
        let golden = Golden.mkv.replacingOccurrences(of: "<PROCESSED>", with: Self.processedToken(at))
        check("mkv", Self.panel(r).formatAllMetadata(r), golden)
    }

    @Test func mxfAvidHeaderAndAvidSection() {
        let r = Self.mxfAvid()
        check("mxf", Self.panel(r).formatAllMetadata(r), Golden.mxf)
    }

    @Test func aviDVCorrelationAndDuplicates() {
        let (r, _) = Self.aviDV()
        let p = Self.panel(r,
                           group: [Self.other("Christmas97 copy.avi", codec: "dvvideo")],
                           same: [Self.other("Christmas97.mp4", codec: "h264")],
                           possible: [Self.other("Xmas.mov", codec: "prores")])
        check("avi", p.formatAllMetadata(r), Golden.avi)
    }

    @Test func sameFootageAloneOpensDuplicatesWithoutStatus() {
        let r = Self.bare()
        let p = Self.panel(r, same: [Self.other("Twin.mov", codec: "h264")])
        check("sameOnly", p.formatAllMetadata(r), Golden.sameOnly)
    }

    @Test func dayPreciseInferredDateUsesMediumDate() throws {
        let r = Self.dayPreciseInferred()
        let inferred = try #require(r.inferredRecordDate)
        let golden = Golden.dayPrecise.replacingOccurrences(of: "<MEDIUM>", with: Self.mediumDate(inferred))
        check("dayPrecise", Self.panel(r).formatAllMetadata(r), golden)
    }
}

/// Captured from the pre-refactor monolith (2026-11-07), one element per line.
private enum Golden {
    static let bare: String = [
        "bare.bin",
        "  Stream Type:  \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > bare.bin",
        "",
        "[General]",
        "",
        "[Video]",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/bare.bin",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let mp4: String = [
        "Birthday.mp4",
        "  Stream Type: Video+Audio \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > Birthday.mp4",
        "  Rating: \u{2605}\u{2605}\u{2605}\u{2605}",
        "  Tags: birthday, backyard",
        "",
        "[General]",
        "  Size: 1.1 GB",
        "  Duration: 00:12:01",
        "  Container: MPEG-4",
        "  Extension: mp4",
        "",
        "[Video]",
        "  Resolution: 1920x1080",
        "  Codec: h264",
        "  Frame Rate: 29.97",
        "  Bitrate: 12 Mb/s",
        "  Total Bitrate: 12.3 Mb/s",
        "  Color Space: bt709",
        "  Bit Depth: 8",
        "  Scan Type: Progressive",
        "",
        "[Audio]",
        "  Codec: aac",
        "  Channels: 2",
        "  Sample Rate: 48000",
        "",
        "[Timestamps]",
        "  Your Date: 2011-06-15 (known)",
        "  Embedded: 2011-06-15 10:00 UTC (QuickTime creation_time)",
        "  Origin: Apple iPhone 4",
        "  Created: 2011-06-15 10:00",
        "  Modified: 2011-06-16 11:00",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/Family/Birthday.mp4",
        "  Directory: /Volumes/CharzNeverMounted/Family",
        "  MD5 (partial): abc123",
        "  File Signature: sha256:deadbeef",
    ].joined(separator: "\n")
    static let mov: String = [
        "Telecine_Reel3.mov",
        "  Stream Type: Video only \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > Telecine_Reel3.mov",
        "",
        "[General]",
        "  Size: 48 GB",
        "  Duration: 00:21:40",
        "  Container: QuickTime",
        "  Extension: mov",
        "",
        "[Video]",
        "  Resolution: 1440x1080",
        "  Codec: prores",
        "  Frame Rate: 18",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "  Your Date: 1968 (best guess)",
        "  Timecode: 01:00:00:00",
        "  Tape Name: REEL3",
        "",
        "[Your Notes]",
        "  Grandpa's Super 8, Cape Cod",
        "",
        "[Notes]",
        "  probe: no audio stream",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/Scans/Telecine_Reel3.mov",
        "  Directory: /Volumes/CharzNeverMounted/Scans",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let mkv: String = [
        "VHS_Tape12.mkv",
        "  Stream Type: Video+Audio \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > VHS_Tape12.mkv",
        "",
        "[General]",
        "  Size: 60 GB",
        "  Duration: 01:58:00",
        "  Container: Matroska",
        "  Extension: mkv",
        "",
        "[Video]",
        "  Resolution: 720x486",
        "  Codec: ffv1",
        "  Frame Rate: 29.97",
        "  Scan Type: Interlaced (TFF)",
        "",
        "[Audio]",
        "  Codec: pcm_s24le",
        "  Channels: 2",
        "  Sample Rate: 48000",
        "",
        "[Timestamps]",
        "",
        "[Dossier]",
        "  Inferred Record Date: 1994 (confidence 0.81)",
        "  Processed: Qwen2.5-VL on <PROCESSED>",
        "",
        "  Scene Captions (2):",
        "    [0:05] a child blowing out candles",
        "    [2:05] people at a table",
        "",
        "  Audio Transcript:",
        "    Happy birthday to you",
        "    ",
        "    Make a wish!",
        "",
        "  OCR Text (1):",
        "    [1:01] JUN 15 1994",
        "",
        "  OCR Date Candidates (1):",
        "    [1:01] JUN 15 1994",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/Captures/VHS_Tape12.mkv",
        "  Directory: /Volumes/CharzNeverMounted/Captures",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let mxf: String = [
        "A001C003.mxf",
        "  Stream Type: Video only \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > A001C003.mxf",
        "  Tape: A001",
        "  Clip: Interview_01",
        "",
        "[General]",
        "  Container: MXF",
        "  Extension: mxf",
        "",
        "[Video]",
        "  Codec: dnxhd",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "",
        "[Avid Project]",
        "  Clip Name: Interview_01",
        "  Mob Type: MasterMob",
        "  Bin File: Project.avb",
        "  Tape: A001",
        "  Tracks: V1, A1-A2",
        "  Edit Rate: 29.97 fps",
        "  Mob ID: 060a2b34-mob",
        "  Material UUID: mat-uuid-1",
        "  Original Path: /Volumes/MacPro/Avid MediaFiles/MXF/1/A001C003.mxf",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/Avid MediaFiles/MXF/1/A001C003.mxf",
        "  Directory: /Volumes/CharzNeverMounted/Avid MediaFiles/MXF/1",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let avi: String = [
        "Christmas97.avi",
        "  Stream Type: Video only \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > Christmas97.avi",
        "",
        "[General]",
        "  Size: 13 GB",
        "  Duration: 01:00:00",
        "  Container: AVI",
        "  Extension: avi",
        "",
        "[Video]",
        "  Resolution: 720x480",
        "  Codec: dvvideo",
        "  Frame Rate: 29.97",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "",
        "[Correlation]",
        "  Paired With: Christmas97.wav",
        "  Pair Volume: CharzNeverMounted > Christmas97.wav",
        "  Pair Path: /Volumes/CharzNeverMounted/DV/Christmas97.wav",
        "  Confidence: Medium",
        "",
        "[Duplicates]",
        "  Same footage as: Christmas97.mp4 (H.264, MP4)",
        "  Same footage as (possible): Xmas.mov (ProRes, MOV)",
        "  Status: Keep",
        "  Reasons: Same size and duration",
        "  Confidence: High",
        "",
        "  Duplicate Group (2 total):",
        "    \u{2605} Christmas97.avi  [CharzNeverMounted]  Keep",
        "    \u{B7} Christmas97 copy.avi  [CharzNeverMounted] (offline)  Extra copy",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/DV/Christmas97.avi",
        "  Directory: /Volumes/CharzNeverMounted/DV",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let sameOnly: String = [
        "bare.bin",
        "  Stream Type:  \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > bare.bin",
        "",
        "[General]",
        "",
        "[Video]",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "",
        "[Duplicates]",
        "  Same footage as: Twin.mov (H.264, MOV)",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/bare.bin",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
    static let dayPrecise: String = [
        "Stamp.mp4",
        "  Stream Type:  \u{2014} ffprobe at scan",
        "  Volume: CharzNeverMounted > Stamp.mp4",
        "",
        "[General]",
        "",
        "[Video]",
        "",
        "[Audio]",
        "",
        "[Timestamps]",
        "",
        "[Dossier]",
        "  Inferred Record Date: <MEDIUM>",
        "",
        "[Location]",
        "  Path: /Volumes/CharzNeverMounted/Stamp.mp4",
        "  File Signature: not computed yet",
    ].joined(separator: "\n")
}
