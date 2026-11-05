// TechnicalReadingTests.swift — layer 1 of the file dossier
// (TechnicalReading.swift), ported from tools/dossier-demo's
// tests/test_dossier_demo.py "layer 1: interpretation rules" so the script
// and the app keep one meaning:
//   LOGIC   DV 32 kHz = consumer camcorder; a ProRes creation time is a
//           transfer stamp; a DV creation time is the capture; sentinel and
//           impossible dates are rejected; device tags make a camera date,
//           none a weak one; mtime is copy history; a silent file and an
//           upscaled transfer say so; no video stream is said plainly;
//           the stored-column parsers (rate, size, container key, Hz) and
//           the one-line verdict and duration words.
//   (The demo's mediainfo, PAR/DAR, VFR and GPS rows read facts the catalog
//   does not store; they are not ported — TechnicalReading.swift's header.)
// Synthetic facts only: no media, no catalog.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("TechnicalReading")
struct TechnicalReadingTests {

    /// 2026-11-05, the demo's NOW.
    static let now = Date(timeIntervalSince1970: 1_793_836_800)

    static func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso) ?? Date(timeIntervalSince1970: -1)
    }

    static func dv(_ edit: (inout TechnicalFacts) -> Void = { _ in }) -> TechnicalFacts {
        var f = TechnicalFacts(container: "dv", containerName: "DV (Digital Video)", hasVideo: true, codec: "dvvideo",
                               width: 720, height: 480, fps: 29.97, fieldOrder: "bb", audioCodec: "pcm_s16le",
                               audioRate: 32000, audioChannels: 2, duration: 600, bitRate: 28.8e6,
                               modified: at("2008-06-28T10:00:00Z"))
        edit(&f)
        return f
    }

    static func lines(_ f: TechnicalFacts) -> [String: TechnicalReadingLine] {
        Dictionary(TechnicalReading.interpret(f, now: now).map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Ported from the demo

    @Test func dv32kHzReadsAsAConsumerCamcorder() {
        let rows = Self.lines(Self.dv())
        #expect(rows["Audio"]?.suggests.contains("12-bit 4-channel") == true)
        #expect(rows["Audio"]?.suggests.contains("camcorder") == true)
        #expect(rows["Video codec"]?.suggests.contains("1995") == true)
        #expect(rows["Scan"]?.value.hasPrefix("interlaced, bottom field first") == true)
        #expect(rows["Frame size"]?.suggests.contains("NTSC") == true)
        #expect(TechnicalReading.oneLiner(Self.dv()).contains("12-bit 4-ch"))
    }

    @Test func aProResCreationTimeIsATransferStampNotACaptureDate() {
        let f = TechnicalFacts(container: "mov", hasVideo: true, codec: "prores", width: 720, height: 486,
                               creationTime: Self.at("2026-07-14T12:00:00Z"))
        let (kind, why) = TechnicalReading.classifyCreationTime(f, now: Self.now)
        #expect(kind == .transfer)
        #expect(why.contains("not when it was shot"))
        #expect(Self.lines(f)["Video codec"]?.suggests.contains("TRANSFER") == true)
    }

    @Test func aDVCreationTimeIsTheCaptureStamp() {
        let (kind, why) = TechnicalReading.classifyCreationTime(Self.dv { $0.creationTime = Self.at("2003-02-11T10:00:00Z") }, now: Self.now)
        #expect(kind == .capture)
        #expect(why.contains("DV clock"))
    }

    @Test(arguments: ["1904-01-01T00:00:00Z", "1970-01-01T00:00:00Z", "2000-01-01T00:00:00Z", "1979-06-01T00:00:00Z", "2031-01-01T00:00:00Z"])
    func sentinelAndImpossibleDatesAreRejected(_ raw: String) {
        let f = TechnicalFacts(hasVideo: true, codec: "h264", make: "Apple", creationTime: Self.at(raw))
        #expect(TechnicalReading.classifyCreationTime(f, now: Self.now).kind == .rejected)
    }

    @Test func deviceTagsMakeACameraDateAndNoTagAWeakOne() {
        let phone = TechnicalFacts(hasVideo: true, codec: "hevc", make: "Apple", model: "iPhone XS",
                                   creationTime: Self.at("2019-07-05T01:14:00Z"), creationSource: "quicktime:com.apple.quicktime.creationdate")
        #expect(TechnicalReading.classifyCreationTime(phone, now: Self.now).kind == .camera)
        let appleTagOnly = TechnicalFacts(hasVideo: true, codec: "hevc", creationTime: Self.at("2019-07-05T01:14:00Z"),
                                          creationSource: "quicktime:com.apple.quicktime.creationdate")
        #expect(TechnicalReading.classifyCreationTime(appleTagOnly, now: Self.now).kind == .camera)
        let bare = TechnicalFacts(hasVideo: true, codec: "h264", creationTime: Self.at("2012-05-01T00:00:00Z"))
        #expect(TechnicalReading.classifyCreationTime(bare, now: Self.now).kind == .weak)
        #expect(TechnicalReading.classifyCreationTime(TechnicalFacts(), now: Self.now).kind == .none)
    }

    @Test func mtimeSilenceAndAnUpscaledTransfer() {
        let f = TechnicalFacts(container: "matroska", hasVideo: true, codec: "ffv1", width: 1280, height: 720,
                               modified: Self.at("2026-07-01T09:00:00Z"))
        let rows = Self.lines(f)
        #expect(rows["File modified"]?.suggests.contains("never the shoot") == true)
        #expect(rows["File modified"]?.source == "file system")
        #expect(rows["Audio"]?.suggests.contains("silent") == true)
        #expect(rows["Frame size"]?.suggests.contains("upscaled") == true)
    }

    @Test func noVideoStreamIsSaidPlainly() {
        let rows = Self.lines(TechnicalFacts(container: "mxf", hasVideo: false))
        #expect(rows["Video"]?.suggests.contains("reference movie") == true)
        #expect(TechnicalReading.oneLiner(TechnicalFacts(hasVideo: false)).hasPrefix("no playable video"))
        #expect(rows["Audio"] == nil, "a file with no video and no audio codec has no silent-audio line")
    }

    // MARK: The rest of the table

    @Test func frameRatesAndSizesNameTheirSystem() {
        func fps(_ v: Double) -> String { Self.lines(TechnicalFacts(hasVideo: true, codec: "h264", fps: v))["Frame rate"]?.suggests ?? "" }
        #expect(fps(29.97).contains("NTSC"))
        #expect(fps(25).contains("PAL"))
        #expect(fps(23.976).contains("film"))
        #expect(fps(18).contains("Super 8"))
        #expect(fps(12).contains("webcam"))
        #expect(fps(30).contains("30 fps exactly"))
        func size(_ w: Int, _ h: Int, _ codec: String = "h264") -> String {
            Self.lines(TechnicalFacts(hasVideo: true, codec: codec, width: w, height: h))["Frame size"]?.suggests ?? ""
        }
        #expect(size(720, 576).contains("PAL"))
        #expect(size(320, 240).contains("VGA"))
        #expect(size(1920, 1080).contains("born-digital"))
        #expect(size(1920, 1080, "prores").contains("upscaled"))
        #expect(size(3840, 2160).contains("4K"))
        #expect(size(1000, 562).contains("uncommon"))
    }

    @Test func encodersAndTheCameraAreNamed() {
        let rows = Self.lines(TechnicalFacts(hasVideo: true, codec: "h264", encoder: "Lavf61.7.100", make: "Canon", model: "HF100"))
        #expect(rows["Encoder / muxer"]?.suggests.contains("ffmpeg") == true)
        #expect(rows["Make / model"]?.value == "Canon HF100")
        #expect(TechnicalReading.oneLiner(TechnicalFacts(hasVideo: true, codec: "h264", width: 1920, height: 1080, make: "Canon", model: "HF100"))
                == "camera-native h264 1920×1080 from Canon HF100")
        #expect(Self.lines(TechnicalFacts(hasVideo: true, codec: "h264", encoder: "HandBrake 1.7.3"))["Encoder / muxer"]?.suggests.contains("HandBrake") == true)
    }

    @Test func aDVCaptureIsAHighConstantRate() {
        #expect(Self.lines(Self.dv())["Duration / rate"]?.value == "10 m 0 s, 28.8 Mb/s")
        #expect(Self.lines(Self.dv())["Duration / rate"]?.suggests.contains("capture or master") == true)
        let web = TechnicalFacts(hasVideo: true, codec: "h264", width: 640, height: 480, duration: 60, bitRate: 1.2e6)
        #expect(Self.lines(web)["Duration / rate"]?.suggests.contains("distribution") == true)
    }

    // MARK: The stored-column parsers

    @Test func storedColumnsParse() {
        #expect(TechnicalReading.rate("30000/1001") == 29.97)
        #expect(TechnicalReading.rate("29.97") == 29.97)
        #expect(TechnicalReading.rate("0/0") == nil)
        #expect(TechnicalReading.rate("junk") == nil)
        #expect(TechnicalReading.frameSize("720x480").map { [$0.0, $0.1] } == [720, 480])
        #expect(TechnicalReading.frameSize("x480") == nil)
        #expect(TechnicalReading.leadingInt("48000 Hz") == 48000)
        #expect(TechnicalReading.leadingInt("") == nil)
        #expect(TechnicalReading.containerKey(container: "QuickTime / MOV", ext: "mp4") == "mp4")
        #expect(TechnicalReading.containerKey(container: "QuickTime / MOV", ext: "mov") == "mov")
        #expect(TechnicalReading.containerKey(container: "DV (Digital Video)", ext: "dv") == "dv")
        #expect(TechnicalReading.containerKey(container: "Matroska / WebM", ext: "mkv") == "matroska")
        #expect(TechnicalReading.containerKey(container: "MXF (Material eXchange Format)", ext: "mxf") == "mxf")
        #expect(TechnicalReading.containerKey(container: "AVI (Audio Video Interleaved)", ext: "avi") == "avi")
        #expect(TechnicalReading.containerKey(container: "", ext: "") == nil)
    }

    @Test func factsComeFromTheStoredRecordFields() {
        let r = VideoRecord()
        r.container = "DV (Digital Video)"; r.ext = "dv"; r.streamTypeRaw = "Video+Audio"; r.videoCodec = "dvvideo"
        r.resolution = "720x480"; r.frameRate = "29.97"; r.scanType = "bb"; r.audioCodec = "pcm_s16le"
        r.audioSampleRate = "32000 Hz"; r.audioChannels = "2"; r.totalBitrate = "28800 kbps"; r.durationSeconds = 9540
        r.originEncoder = "  "
        let f = TechnicalFacts(record: r)
        #expect(f == TechnicalFacts(container: "dv", containerName: "DV (Digital Video)", hasVideo: true, codec: "dvvideo",
                                    width: 720, height: 480, fps: 29.97, fieldOrder: "bb", audioCodec: "pcm_s16le",
                                    audioRate: 32000, audioChannels: 2, duration: 9540, bitRate: 28_800_000))
        #expect(TechnicalReading.oneLiner(f) == "DV camcorder/deck capture, NTSC 720×480, 12-bit 4-ch audio (consumer camcorder)")
        #expect(TechnicalReading.durationWords(9540) == "2 h 39 m")
        #expect(TechnicalReading.durationWords(252) == "4 m 12 s")
        #expect(TechnicalReading.durationWords(38) == "38 s")
    }
}
