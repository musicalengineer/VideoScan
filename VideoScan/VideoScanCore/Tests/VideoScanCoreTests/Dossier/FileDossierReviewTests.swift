// FileDossierReviewTests.swift — review findings on feat/file-dossier-view
// (193f4710c, 2026-11-05). Each test was RED on that commit and names the
// line it pinned; all green on the fix. The Dossier run check allows the
// restored time of day after the local day.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FileDossier — review (red on 193f4710c)")
struct FileDossierReviewTests {

    static let now = TechnicalReadingTests.now

    static func build(_ r: VideoRecord, _ rows: [CatalogRow.ProvenanceAssertionReading] = []) -> FileDossier {
        FileDossier.build(record: r, digest: String(repeating: "a", count: 64), assertions: rows, now: now)
    }

    // FileDossier+Build.swift:195 and :205 — "none read" keys off
    // `dossierProcessedAt`, which a transcript-only pass also stamps
    // (VideoScanModel+AudioTranscript.swift:47 → stampDossierProvenance).
    // The VLM never looked at this file; "none read" is a stated fact that is false.
    @Test func aTranscriptOnlyRunDoesNotClaimTheBurnInReaderFoundNothing() {
        let r = FileDossierTests.dvRecord()
        r.audioTranscript = "open that one next"
        r.audioTranscriptModel = "whisper-medium"
        r.audioTranscriptDate = Self.now
        r.dossierProcessedAt = Self.now
        r.dossierProcessedBy = "whisper-medium"
        let p = Self.build(r).patterns
        #expect(p.line("Scene")?.value == "not described yet")
        #expect(p.line("On-screen dates")?.value != "none read", "the VLM never ran on this file")
        #expect(p.line("On-screen text")?.value != "none read", "the VLM never ran on this file")
    }

    // FileDossier+Build.swift:133-135 — a fused era Rick rejected (or one whose
    // value did not parse) falls to "not analyzed yet" with the reading
    // "VideoScan Background has not reached this file". It did reach it.
    @Test func aRejectedEraDoesNotSayTheAnalyzerNeverReachedTheFile() throws {
        let rows = [FileDossierTests.row(1, "era.fused", "1990-1995"),
                    FileDossierTests.row(2, "era.fused", "1990-1995", by: "rick", state: "rejected")]
        let era = try #require(Self.build(FileDossierTests.dvRecord(), rows).patterns.line("Era"))
        #expect(era.value != "not analyzed yet", "\(era.value)")
        #expect(era.reading != "VideoScan Background has not reached this file")
    }

    // FileDossier+Build.swift:169 — every non-video stream type is called
    // "(audio only)", including "No A/V streams" (DocumentIngest rows).
    @Test func aFileWithNoStreamsIsNotCalledAudioOnly() {
        let r = FileDossierTests.dvRecord()
        r.streamTypeRaw = StreamType.noStreams.rawValue
        let scene = Self.build(r).patterns.line("Scene")?.value ?? ""
        #expect(!scene.contains("audio only"), "\(scene)")
    }

    // TechnicalReading.swift:272-273 — `bitRate ?? 0` prints an unknown total
    // bit rate as the fact "0.0 Mb/s".
    @Test func anUnknownBitRateIsNotShownAsZero() throws {
        let f = TechnicalFacts(container: "dv", codec: "dvvideo", width: 720, height: 480, duration: 9540, bitRate: nil)
        let line = try #require(TechnicalReading.interpret(f, now: Self.now).first { $0.label == "Duration / rate" })
        #expect(!line.value.contains("0.0 Mb/s"), "\(line.value)")
    }

    // TechnicalReading.swift:383 — `fps ?? 0` prints an unknown frame rate as "0 fps".
    @Test func anUnknownFrameRateIsNotShownAsZero() {
        let summary = TechnicalReading.oneLiner(TechnicalFacts(container: "mp4", codec: "h264", width: 1920, height: 1080, fps: nil))
        #expect(!summary.contains("0 fps"), "\(summary)")
    }

    // TechnicalReading.swift:401-404 — `day` is the UTC calendar day, unlabelled.
    // The inspector's Timestamps ▸ Modified row (VideoRecord+Row.swift:23-36) is
    // the LOCAL one, so one panel shows two days for an evening mtime; the same
    // for "Dossier run" and the captioned/transcribed evidence dates, which are
    // wall-clock events on Rick's machine.
    @Test(.enabled(if: TimeZone.current.secondsFromGMT() != 0))
    func aLocalEveningMtimeShowsTheSameDayAsTheInspector() throws {
        var c = DateComponents()
        c.year = 2003; c.month = 2; c.day = 11; c.minute = 30
        c.hour = TimeZone.current.secondsFromGMT() < 0 ? 23 : 0     // the hour whose UTC day differs
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let stamp = try #require(local.date(from: c))
        let inspectorDay = DateFormatter()                           // the Timestamps row's zone
        inspectorDay.dateFormat = "yyyy-MM-dd"
        let expected = inspectorDay.string(from: stamp)

        let r = FileDossierTests.dvRecord()
        r.dateModifiedRaw = stamp
        r.dossierProcessedAt = stamp
        r.dossierProcessedBy = "qwen3-vl"
        let d = Self.build(r)
        #expect(d.technical.line("File modified")?.value == expected, "\(d.technical.line("File modified")?.value ?? "")")
        // The run keeps the old footer's time of day (coordinator 11/05, item 3): the LOCAL day, then the time.
        #expect(d.patterns.line("Dossier run")?.value.hasPrefix(expected + " ") == true, "\(d.patterns.line("Dossier run")?.value ?? "")")
    }
}
