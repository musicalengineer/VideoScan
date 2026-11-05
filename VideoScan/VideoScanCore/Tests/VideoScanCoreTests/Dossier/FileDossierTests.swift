// FileDossierTests.swift — the file dossier value (FileDossier.swift,
// FileDossier+Build.swift; docs/design/file_dossier_view.md, phase 1).
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      the three summaries (Technical's one-liner and duration,
//              Patterns' parts, "nothing analyzed yet", layer 3's "coming
//              next"); a DV file carries "DV clock: not read yet"; an era
//              agrees / disagrees with Rick's year; `era.none` is never an
//              era; a rejected era is not shown; a give-up says why; each
//              missing analyzer says why in words; the old inspector floor
//              (inferred date, transcript, captions, usable OCR, OCR text,
//              dossier run) is all carried.
//   TRUTH      a catalog with every table filled → FileDossier.read through
//              the repository's reader: every line equals its stored row
//              (value, source, evidence, body); the read changes nothing;
//              a field the catalog keeps for ONE stream (audio channels)
//              says so and never reads as the file's total (rule 1).
//   SCALE      100k files (each with captions, transcript, era) → opening
//              one dossier inside the budget (first measurement 1.7 ms on
//              the M5 Ultra, Debug; the design's ceiling was 100 ms; 20 ms).
//   ISOLATION  no probe data (never probed, ffprobe failed); an unknown
//              signer; a corrupt stored row (the dossier still builds and
//              says why); an unknown file id is nil.
//   MEDIA      the app's FileDossierMediaMatrixTests (ffprobe → the scan's
//              own mapping → these rules). SENSOR: the app's
//              FileDossierSensorTests (one door for three call sites).
// Synthetic names, paths and digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FileDossier")
struct FileDossierTests {

    static let now = TechnicalReadingTests.now
    static let by8B = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

    static func dvRecord() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "Christmas_1990.dv"; r.fullPath = "/V/tapes/Christmas_1990.dv"; r.ext = "dv"
        r.container = "DV (Digital Video)"; r.streamTypeRaw = "Video+Audio"; r.videoCodec = "dvvideo"
        r.resolution = "720x480"; r.frameRate = "29.97"; r.scanType = "bb"; r.audioCodec = "pcm_s16le"
        r.audioSampleRate = "48000 Hz"; r.audioChannels = "2"; r.durationSeconds = 9540; r.totalBitrate = "28800 kbps"
        r.dateModifiedRaw = TechnicalReadingTests.at("2003-02-11T12:00:00Z")
        return r
    }

    static func row(_ seq: Int64, _ field: String, _ value: String, by: String = by8B, state: String = "inferred",
                    evidence: String = "{}") -> CatalogRow.ProvenanceAssertionReading {
        .init(seq: seq, subjectKind: "content", subjectID: String(repeating: "a", count: 64), field: field, value: value, state: state,
              by: by, at: 1_762_000_000 + seq, confidence: state == "inferred" ? 0.6 : nil, evidenceJSON: evidence)
    }

    static func build(_ r: VideoRecord, _ rows: [CatalogRow.ProvenanceAssertionReading] = []) -> FileDossier {
        FileDossier.build(record: r, digest: String(repeating: "a", count: 64), assertions: rows, now: now)
    }

    // MARK: LOGIC — summaries

    @Test func theThreeSummaries() {
        let d = Self.build(Self.dvRecord())
        #expect(d.technical.summary == "DV camcorder/deck capture, NTSC 720×480 · 2 h 39 m")
        #expect(d.patterns.summary == "nothing analyzed yet")
        #expect(d.collection.summary == "coming next: the corpus rules (design §5)")
        #expect(d.collection.lines.isEmpty)
        #expect(d.sections.map(\.layer) == [.technical, .patterns, .collection])
        #expect(FileDossier.Layer.allCases.map(\.title) == ["Technical", "Patterns & events", "Across the collection"])

        let r = Self.dvRecord()
        r.sceneCaptions = [SceneCaption(timestamp: 1, text: "a tree"), SceneCaption(timestamp: 9, text: "a dog")]
        r.audioTranscript = "open that one next"
        r.confirmedByUserPeople = [ConfirmedTag(name: "Ann", confirmedAt: Self.now), ConfirmedTag(name: "Bo", confirmedAt: Self.now)]
        let full = Self.build(r, [Self.row(1, "era.fused", "1990-1995")])
        #expect(full.patterns.summary == "1990–1995 (8B, unconfirmed) · 2 scenes described · speech · 2 people")
        r.audioTranscript = ""
        r.confirmedByUserPeople = [ConfirmedTag(name: "Ann", confirmedAt: Self.now)]
        #expect(Self.build(r).patterns.summary == "2 scenes described · no speech · 1 person")
    }

    @Test func aDVFileCarriesTheDVClockLineUntilTheAnalyzerExists() throws {
        let lines = Self.build(Self.dvRecord()).technical.lines
        let clock = try #require(lines.first { $0.label == "DV clock" })
        #expect(clock.value == "not read yet" && clock.standing == .missing)
        let audio = try #require(lines.firstIndex { $0.label == "Audio" })
        #expect(lines[audio + 1].label == "DV clock", "beside the audio, as in the design's mock")
        let mp4 = Self.dvRecord()
        mp4.videoCodec = "h264"
        #expect(Self.build(mp4).technical.line("DV clock") == nil, "only a DV file has a DV clock")
        #expect(lines.allSatisfy { $0.label == "DV clock" || $0.standing == .fact })
    }

    // MARK: LOGIC — the era line

    @Test func anEraAgreesOrDisagreesWithRicksYear() throws {
        let r = Self.dvRecord()
        r.userDate = "1990"
        let era = try #require(Self.build(r, [Self.row(1, "era.fused", "1990-1995")]).patterns.line("Era"))
        #expect(era.value == "1990–1995" && era.reading == "agrees with your date (1990)")
        #expect(era.source == "8B era, unconfirmed" && era.standing == .observation)
        #expect(era.evidence?.contains("not a date") == true)
        r.userDate = "1975"
        #expect(Self.build(r, [Self.row(1, "era.fused", "1990-1995")]).patterns.line("Era")?.reading == "disagrees with your date (1975)")
        #expect(Self.build(r).patterns.line("Your date")?.value == "1975")
        #expect(Self.build(r).patterns.line("Your date")?.source == "Rick")
    }

    @Test func eraNoneIsNeverAnEraAndAGiveUpSaysWhy() throws {
        let none = try #require(Self.build(Self.dvRecord(), [Self.row(1, "era.none", "none", evidence: #"{"reason":"no era window passed"}"#)])
            .patterns.line("Era"))
        #expect(none.value == "no usable era" && none.reading == "no era window passed" && none.standing == .missing)
        #expect(!none.value.contains("none") || none.value == "no usable era")
        let gave = try #require(Self.build(Self.dvRecord(), [Self.row(1, "era.none", "none",
                                                                      evidence: #"{"reason":"gave up after 3 tries: frames would not decode","gaveUp":true}"#)])
            .patterns.line("Era"))
        #expect(gave.value == "no era: the analyzer gave up" && gave.reading?.hasPrefix("gave up after 3 tries") == true)
        // An era from one signer beats another's era.none.
        let both = Self.build(Self.dvRecord(), [Self.row(1, "era.none", "none"), Self.row(2, "era.fused", "1991-1993", by: "machine:other-32b/era-v1@r1")])
        #expect(both.patterns.line("Era")?.value == "1991–1993")
    }

    @Test func aRejectedEraIsNotShown() {
        let rows = [Self.row(1, "era.fused", "1990-1995"), Self.row(2, "era.fused", "1990-1995", by: "rick", state: "rejected")]
        #expect(Self.build(Self.dvRecord(), rows).patterns.line("Era")?.value == "not analyzed yet")
    }

    @Test func burnedInDatesAreObservationsNewestFirst() throws {
        let line = try #require(Self.build(Self.dvRecord(), [Self.row(1, "ocr.date", "1990-12-25", evidence: #"{"atS":12.5}"#),
                                                             Self.row(2, "ocr.date", "1990-12-26")]).patterns.line("Burned-in date"))
        #expect(line.value == "1990-12-26, 1990-12-25" && line.standing == .observation)
        #expect(line.body.map(\.at) == [nil, 12.5])
        #expect(Self.build(Self.dvRecord()).patterns.line("Burned-in date") == nil)
    }

    // MARK: LOGIC — every missing analyzer says why

    @Test func eachMissingReadingSaysWhyInWords() {
        let p = Self.build(Self.dvRecord()).patterns
        let words = Dictionary(uniqueKeysWithValues: p.lines.map { ($0.label, $0.value) })
        #expect(words["Era"] == "not analyzed yet")
        #expect(words["Inferred date"] == "not inferred yet")
        #expect(words["Scene"] == "not described yet")
        #expect(words["Speech"] == "not transcribed yet")
        #expect(words["People"] == "none confirmed")
        #expect(words["On-screen dates"] == "not read yet")
        #expect(words["On-screen text"] == "not read yet")
        #expect(words["Dossier run"] == "not run yet")
        #expect(p.lines.allSatisfy { $0.standing == .missing && !$0.value.isEmpty && !$0.source.isEmpty })

        let silent = Self.dvRecord()
        silent.streamTypeRaw = "Video only"
        #expect(Self.build(silent).patterns.line("Speech")?.value == "no audio track")
        let audio = Self.dvRecord()
        audio.streamTypeRaw = "Audio only"
        #expect(Self.build(audio).patterns.line("Scene")?.value == "no picture (audio only)")
        #expect(Self.build(audio).patterns.line("Era")?.value == "no picture to read")
        let ran = Self.dvRecord()
        ran.dossierProcessedAt = Self.now
        #expect(Self.build(ran).patterns.line("On-screen text")?.value == "none read")
    }

    // MARK: LOGIC — the old inspector's floor

    @Test func everythingTheOldInspectorShowedIsCarried() throws {
        let r = Self.dvRecord()
        r.inferredRecordDate = TechnicalReadingTests.at("1990-12-25T12:00:00Z")
        r.inferredDateConfidence = 0.62
        r.inferredDateReason = "OCR consensus 12/25/90 across 3 frames"
        r.inferredDateSource = "catch-up"
        r.audioTranscript = "open that one next"
        r.audioTranscriptModel = "whisper-medium"
        r.sceneCaptions = [SceneCaption(timestamp: 3, text: "a decorated tree"), SceneCaption(timestamp: 61, text: "a dog")]
        r.sceneCaptionModel = "qwen3-vl"
        r.ocrDateCandidates = [SceneCaption(timestamp: 5, text: "DEC 25 1990"), SceneCaption(timestamp: 6, text: "!!!!!!!!!!!!!!!!")]
        r.ocrText = [SceneCaption(timestamp: 8, text: "MERRY XMAS")]
        r.dossierProcessedAt = TechnicalReadingTests.at("2026-06-09T10:00:00Z")
        r.dossierProcessedBy = "qwen3-vl+whisper-medium"
        let p = Self.build(r).patterns

        let inferred = try #require(p.line("Inferred date"))
        #expect(inferred.value == "1990-12-25" && inferred.reading == "62 % confidence (fair)")
        #expect(inferred.evidence == "OCR consensus 12/25/90 across 3 frames" && inferred.source == "date triangulator · catch-up")
        let speech = try #require(p.line("Speech"))
        #expect(speech.value == "“open that one next”" && speech.source == "whisper-medium" && speech.body.map(\.text) == ["open that one next"])
        let scene = try #require(p.line("Scene"))
        #expect(scene.value == "2 frames described" && scene.source == "qwen3-vl")
        #expect(scene.body == [.init(at: 3, text: "a decorated tree"), .init(at: 61, text: "a dog")])
        let ocr = try #require(p.line("On-screen dates"))
        #expect(ocr.body == [.init(at: 5, text: "DEC 25 1990")], "GH #402: a degenerate read is not evidence")
        #expect(p.line("On-screen text")?.body == [.init(at: 8, text: "MERRY XMAS")])
        let run = try #require(p.line("Dossier run"))
        #expect(run.value == "2026-06-09" && run.source == "qwen3-vl+whisper-medium")

        r.inferredRecordDate = nil
        #expect(Self.build(r).patterns.line("Inferred date")?.value == "none", "examined, nothing found: says so with the reason")
        #expect(Self.build(r).patterns.line("Inferred date")?.reading == "OCR consensus 12/25/90 across 3 frames")
        #expect(FileDossier.confidenceWords(0.9) == "90 % confidence (strong)")
        #expect(FileDossier.confidenceWords(0.2) == "20 % confidence (weak)")
    }

    // MARK: TRUTH — every line equals its stored row

    @Test func everyLineEqualsItsStoredRow() async throws {
        var f = DossierFixture.File(n: 1, path: "/V/tapes/Christmas_1990.dv", duration: 9540)
        f.embedded = 1_044_957_600
        let fixture = try await DossierFixture.catalog([f, DossierFixture.File(n: 2, path: "/V/tapes/Bare.dv")])
        defer { fixture.remove() }
        var k = DossierFixture.Knowledge(captionModel: "qwen3-vl-test", transcript: "open that one next", transcriptModel: "whisper-medium",
                                         dossierBy: "vlm+whisper", userDate: "1990")
        k.captions = [("scene", 3, "a decorated tree"), ("scene", 61.5, "a dog"), ("ocrDate", 5, "DEC 25 1990"), ("ocrText", 8, "MERRY XMAS")]
        k.inferred = (662_083_200, 0.62, "catch-up", "OCR consensus")      // 1990-12-25
        k.people = [("Ann", "confirmed"), ("Bo", "detected"), ("Cy", "suspected")]
        k.assertions = [("era.yearRange", "1990-1995", Self.by8B, "inferred", #"{"frameTimesS":[5,12.5],"window":[0,60]}"#),
                        ("era.fused", "1990-1995", Self.by8B, "inferred", #"{"validEraWindows":1,"windows":[[0,60]]}"#),
                        ("ocr.date", "1990-12-25", Self.by8B, "inferred", #"{"atS":5}"#)]
        try DossierFixture.seed(fixture, 1, k)
        let repository = try await DossierFixture.open(fixture)
        let before = try DossierFixture.fingerprint(fixture)
        let now = Self.now
        let d = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: DossierFixture.fileID(1), now: now) })

        #expect(d.fileID == DossierFixture.fileID(1) && d.filename == "Christmas_1990.dv" && d.digest == DossierFixture.hex(1) && !d.removed)
        let t = d.technical
        #expect(t.line("Container")?.value == "DV (Digital Video)")
        #expect(t.line("Video codec")?.value == "dvvideo")
        #expect(t.line("Frame size")?.value == "720×480")
        #expect(t.line("Frame rate")?.value == "29.97")
        #expect(t.line("Scan")?.value == "interlaced, bottom field first (as flagged)")
        #expect(t.line("Audio")?.value == "first audio stream: pcm_s16le 32000 Hz 2 ch")
        #expect(t.line("Creation time")?.value == "2003-02-11" && t.line("Creation time")?.source == "embedded tag (format:creation_time)")
        #expect(t.line("File modified")?.value == "2003-02-11")
        #expect(t.line("Duration / rate")?.value == "2 h 39 m, 28.8 Mb/s")
        #expect(t.summary == "DV camcorder/deck capture, NTSC 720×480, 32 kHz audio (the 12-bit 4-ch camcorder mode) · 2 h 39 m")

        let p = d.patterns
        #expect(p.line("Era")?.value == "1990–1995" && p.line("Era")?.reading == "agrees with your date (1990)")
        #expect(p.line("Era")?.evidence?.contains("Frames: 2 at 5 s, 13 s.") == true)
        #expect(p.line("Your date")?.value == "1990")
        #expect(p.line("Inferred date")?.value == "1990-12-25" && p.line("Inferred date")?.evidence == "OCR consensus")
        #expect(p.line("Scene")?.body == [.init(at: 3, text: "a decorated tree"), .init(at: 61.5, text: "a dog")])
        #expect(p.line("Scene")?.source == "qwen3-vl-test")
        #expect(p.line("Speech")?.body.first?.text == "open that one next" && p.line("Speech")?.source == "whisper-medium")
        #expect(p.line("People")?.value == "1 confirmed: Ann")
        #expect(p.line("Recognized")?.value == "Bo" && p.line("Recognized")?.reading == "suspected: Cy")
        #expect(p.line("On-screen dates")?.body == [.init(at: 5, text: "DEC 25 1990")])
        #expect(p.line("On-screen text")?.body == [.init(at: 8, text: "MERRY XMAS")])
        #expect(p.line("Burned-in date")?.value == "1990-12-25")
        #expect(p.line("Dossier run")?.source == "vlm+whisper")

        // A content with nothing stored says so on every Patterns line.
        let bare = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: DossierFixture.fileID(2), now: now) })
        #expect(bare.patterns.lines.allSatisfy { $0.standing == .missing })
        #expect(bare.patterns.summary == "nothing analyzed yet")
        #expect(try DossierFixture.fingerprint(fixture) == before, "READ ONLY: the generation and every count unchanged")
        await repository.close()
    }

    // MARK: TRUTH — a partial field is never shown as the whole

    /// A consumer DV tape carries two stereo pairs (4 channels); the catalog
    /// keeps only the FIRST audio stream ("2"). Rule 1: the line must never
    /// read as the file's total — it says which stream it describes.
    @Test func aFourChannelDVFileNeverReadsAsPlainTwoChannels() async throws {
        let fixture = try await DossierFixture.catalog([DossierFixture.File(n: 4, path: "/V/tapes/Four_channel.dv")])
        defer { fixture.remove() }
        let repository = try await DossierFixture.open(fixture)
        let now = Self.now
        let d = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: DossierFixture.fileID(4), now: now) })
        let audio = try #require(d.technical.line("Audio"))
        #expect(audio.value == "first audio stream: pcm_s16le 32000 Hz 2 ch", "\(audio.value)")
        #expect(audio.value.range(of: #"^\S+ \d+ Hz \d+ ch$"#, options: .regularExpression) == nil, "never the bare total form")
        #expect(audio.source == "ffprobe (first audio stream)")
        // The video lines say which stream they read too.
        for label in ["Video codec", "Frame size", "Frame rate", "Scan"] {
            #expect(d.technical.line(label)?.source == "ffprobe (first video stream)", "\(label)")
        }
        // Whole-file facts keep the plain source.
        #expect(d.technical.line("Container")?.source == "ffprobe")
        #expect(d.technical.line("Duration / rate")?.source == "ffprobe")
        // The summary names the 32 kHz MODE, never a counted 4 channels.
        #expect(d.technical.summary.contains("32 kHz audio (the 12-bit 4-ch camcorder mode)"))
        await repository.close()
    }

    // MARK: ISOLATION

    @Test func noProbeDataSaysSoAndKeepsTheFileDates() async throws {
        let never = Self.dvRecord()
        never.streamTypeRaw = ""
        let t = Self.build(never).technical
        #expect(t.summary == "not probed yet")
        #expect(t.lines.map(\.label) == ["Probe", "File modified"])
        let failed = Self.dvRecord()
        failed.streamTypeRaw = "ffprobe failed"
        failed.isPlayable = "Damaged MXF file"
        #expect(Self.build(failed).technical.summary == "ffprobe could not read this file (Damaged MXF file)")
        #expect(Self.build(failed).technical.line("Video") == nil, "never 'no playable video' from a probe that did not run")
    }

    @Test func anUnknownSignerIsNamedAndAMalformedValueIsIgnored() throws {
        let rows = [Self.row(1, "era.fused", "garbage"), Self.row(2, "era.fused", "1980-1984", by: "machine:mystery-model@r9", evidence: "not json")]
        let era = try #require(Self.build(Self.dvRecord(), rows).patterns.line("Era"))
        #expect(era.value == "1980–1984" && era.source == "mystery-model era, unconfirmed")
        #expect(Self.build(Self.dvRecord(), [Self.row(1, "era.fused", "garbage")]).patterns.line("Era")?.value == "not analyzed yet")
    }

    @Test func aCorruptStoredRowStillBuildsAndSaysWhy() async throws {
        let fixture = try await DossierFixture.catalog([DossierFixture.File(n: 3, path: "/V/c/Corrupt.dv")])
        defer { fixture.remove() }
        // An imported caption whose value no longer decodes as a caption.
        try DossierFixture.execute(fixture, """
            INSERT INTO derived_unverified (digest, kind, seq, source_json_row_id, value_json) VALUES (?, 'scene', 0, ?, '42')
            """, [DossierFixture.hex(3), DossierFixture.fileID(3)])
        let repository = try await DossierFixture.open(fixture)
        let now = Self.now
        let d = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: DossierFixture.fileID(3), now: now) })
        #expect(d.technical.line("Video codec")?.value == "dvvideo", "the technical layer still reads")
        let problem = try #require(d.patterns.line("Stored analysis"))
        #expect(problem.value == "could not be read" && problem.reading?.contains("no longer decodes") == true)
        #expect(try await repository.read { try FileDossier.read(reader: $0, fileID: "00000000-0000-0000-0000-00000000FFFF", now: now) } == nil)
        await repository.close()
    }

    // MARK: SCALE

    @Test func scaleOpeningOneDossierIn100kFilesIsInsideTheBudget() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try DossierFixture.seedScale(fixture, count: 100_000)
        let repository = try await DossierFixture.open(fixture)
        let load = TimingBudget.sampleLoad()
        let now = Self.now
        let clock = ContinuousClock()
        var opened: [FileDossier] = []
        let took = try await clock.measure {
            for n in [1, 50_000, 100_000] {
                let id = DossierFixture.fileID(n)
                if let d = try await repository.read({ try FileDossier.read(reader: $0, fileID: id, now: now) }) { opened.append(d) }
            }
        }
        #expect(opened.count == 3)
        #expect(opened.allSatisfy { $0.patterns.line("Scene")?.body.count == 6 && $0.patterns.line("Era")?.standing == .observation })
        let each = took / 3
        print("FileDossier scale: 100k files — one dossier opens in \(each) (3 opens: \(took))")
        expectWithinTimingBudget("100k files: open one file dossier", measured: each,
                                 budget: TimingBudget.debugCeiling(.milliseconds(20)), loadBefore: load)
        await repository.close()
    }
}
