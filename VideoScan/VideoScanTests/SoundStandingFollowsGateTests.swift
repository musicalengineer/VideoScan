// SoundStandingFollowsGateTests.swift
// Codex review #300 (2026-11-16) on "mono is fine; one-sided goes through
// Prepare": the Promote sheet's sound line and Archive Angel's row are a
// FORECAST read from stored fields; Promote's sound gate is the measurement.
// These tests pin the forecast to the gate.
//
// Every diagnosis is built the way production builds it — levels →
// AudioBalanceClassifier.classify → VerifyAudioRules.findings →
// AudioVerifyDiagnosis.persistedStatus / persistedNote onto a record — and
// the SAME record goes to (i) PromoteSoundGate.finding / mark / decide and
// (ii) ArchiveReadiness.assess(record:) + the Angel's row model. No note
// string is typed by hand except where a test is about a stale or unknown
// stored note.
//
//   TRUTH      theSheetFollowsTheGate (the 56-cell walk), the F1 / F2 / F4
//              cases by name
//   LOGIC      soundBucketsPartitionTheSelection (F5)
//   ISOLATION  aStoredNoteNobodyRecognisesIsNeverGreen, stale mono
//   SCALE      100k standings under budget
// Pure: no files, no ffmpeg, no model.

import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
enum SoundStandingFixture {

    typealias Gate = PromoteSoundGate

    /// Every class the analyzer can return. The switch has no `default`, so
    /// a new class is a compile error here until it is given levels below.
    static let classes: [AudioChannelClass] = [.trueStereo, .dualMono, .leftOnly, .rightOnly, .mono, .silent, .multichannel]

    nonisolated static func levels(for c: AudioChannelClass) -> (rms: [Double], difference: Double?) {
        switch c {
        case .trueStereo: return ([-18, -19], -21)
        case .dualMono: return ([-18, -18], -95)
        case .leftOnly: return ([-18.2, -.infinity], nil)
        case .rightOnly: return ([-.infinity, -21], nil)
        case .mono: return ([-20], nil)
        case .silent: return ([-.infinity, -.infinity], nil)
        case .multichannel: return (Array(repeating: -20, count: 6), nil)
        case .notMeasured: return ([], nil)
        }
    }

    /// What Verify Audio would conclude from these levels. `tracks` audio
    /// streams; each carries the same sound (so 2 tracks of a live class =
    /// two program tracks). `complete` false = the pass did not cover
    /// everything.
    nonisolated static func diagnosis(rms: [Double], difference: Double? = nil, tracks: Int = 1, complete: Bool = true,
                                      audioSeconds: Double = 60) -> AudioVerifyDiagnosis {
        let channels = rms.map { AudioChannelLevels(rmsDBFS: $0, peakDBFS: $0 == -.infinity ? -.infinity : $0 + 6) }
        let measurements = AudioBalanceMeasurements(channels: channels, differenceRMSDBFS: difference)
        let live = channels.contains(where: AudioBalanceClassifier.carriesProgram)
        let shape = AudioBalanceStreamShape(
            videoCodec: "h264", totalStreams: 1 + tracks, videoStreams: 1, audioStreams: tracks,
            audioCodec: "pcm_s16le", audioChannels: rms.count, audioBitRate: nil, durationSeconds: 60,
            audioStreamInfos: (0..<tracks).map {
                AudioBalanceStreamInfo(absoluteIndex: 1 + $0, codec: "pcm_s16le", channels: rms.count, bitRate: nil)
            })
        var analysis = AudioBalanceAnalysis(
            classification: AudioBalanceClassifier.classify(measurements), measurements: measurements, shape: shape,
            programStreamCount: live ? tracks : 0, programStreamIndex: 1, droppedStreamIndices: [])
        analysis.levelsComplete = complete
        var vshape = AudioVerifyShape()
        vshape.videoCodec = "h264"
        vshape.videoDurationSeconds = 60
        vshape.audioStreams = tracks
        vshape.audioCodec = "pcm_s16le"
        vshape.audioChannels = rms.count
        vshape.audioDurationSeconds = audioSeconds
        vshape.containerDurationSeconds = 60
        let findings = VerifyAudioRules.findings(shape: vshape, referencedPaths: [], levels: .success(analysis))
        return AudioVerifyDiagnosis(findings: findings, shape: vshape, balanceAnalysis: analysis)
    }

    nonisolated static func diagnosis(_ c: AudioChannelClass, tracks: Int = 1, complete: Bool = true) -> AudioVerifyDiagnosis {
        let l = levels(for: c)
        return diagnosis(rms: l.rms, difference: l.difference, tracks: tracks, complete: complete)
    }

    /// A file with no audio stream at all.
    nonisolated static func noStreamDiagnosis() -> AudioVerifyDiagnosis {
        var vshape = AudioVerifyShape()
        vshape.videoCodec = "h264"
        vshape.videoDurationSeconds = 60
        let findings = VerifyAudioRules.findings(shape: vshape, referencedPaths: [], levels: nil)
        return AudioVerifyDiagnosis(findings: findings, shape: vshape, balanceAnalysis: nil)
    }

    /// A reference movie with no audio stream of its own: its media is on
    /// another disk. Damage, and no track — the gate puts damage first.
    nonisolated static func referenceMovieDiagnosis() -> AudioVerifyDiagnosis {
        var d = noStreamDiagnosis()
        d.findings = VerifyAudioRules.findings(shape: d.shape, referencedPaths: ["/missing/audio.aif"], levels: nil)
        return d
    }

    /// The catalog record of the file `d` was measured on: the scan's
    /// header fields, plus exactly what VerifyAudioJob stores for `d` (a
    /// not-checked diagnosis stores nothing).
    static func record(for d: AudioVerifyDiagnosis, tagged: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "test_sound.mov"
        r.fullPath = "/Volumes/Test/test_sound.mov"
        r.isPlayable = "Yes"
        r.videoCodec = "h264"
        r.userDate = "1992"
        r.sizeBytes = 4_096
        if d.shape.audioStreams > 0 {
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.audioCodec = "pcm_s16le"
            r.audioChannels = String(d.shape.audioChannels)
        } else {
            r.streamTypeRaw = StreamType.videoOnly.rawValue
        }
        // The production writer (Codex #302): nothing typed by hand.
        VerifyAudioJob.write(d, onto: r, at: Date(timeIntervalSince1970: 1_800_000_000))
        if tagged { r.tags = [WorkflowTags.silentChecked] }
        return r
    }

    /// The gate's decision for `d` measured on `r`'s file, its bytes proven
    /// to be the ones the record describes.
    static func gate(_ d: AudioVerifyDiagnosis, record r: VideoRecord) -> Gate.Decision {
        let mark = Gate.mark(tags: r.tags, storedFixity: r.contentFixity, provenDigest: String(repeating: "a", count: 64),
                             recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes)
        return Gate.decide(finding: Gate.finding(from: d), mark: mark, soundPartnerName: nil, recordedYear: nil,
                           digestPrefix: "")
    }

    static func row(_ r: VideoRecord) -> ArchiveAngelListRow {
        ArchiveAngelListRowBuilder.row(ArchiveAngelRowFacts.make(record: r, evidence: nil, kind: .ready))
    }

    static func isRed(_ readiness: ArchiveReadiness) -> Bool { PromoteToArchiveSheet.lineColor(readiness) == .red }
    static func isGreen(_ readiness: ArchiveReadiness) -> Bool { PromoteToArchiveSheet.lineColor(readiness) == .green }

    static func entry(_ r: VideoRecord) -> ArchivePromotePlan.Entry {
        .init(recordID: r.id, filename: r.filename, sizeBytes: r.sizeBytes, folder: "30_Video/1990s/1992",
              dateHint: .year(1992), lowConfidenceDate: false, readiness: ArchiveReadiness.assess(record: r))
    }
}

/// One cell of the walk.
struct SoundStandingCell: Sendable, CustomTestStringConvertible {
    /// What the file is: measured levels of a class, or one of the two
    /// states with no levels at all.
    enum Source: Sendable, Equatable {
        case levels(AudioChannelClass)
        case noStream
        case referenceMovie
    }
    let source: Source
    var tracks: Int = 1
    var complete: Bool = true
    let tagged: Bool

    init(channelClass: AudioChannelClass, tracks: Int, complete: Bool, tagged: Bool) {
        self.source = .levels(channelClass); self.tracks = tracks; self.complete = complete; self.tagged = tagged
    }
    init(_ source: Source, tagged: Bool) {
        self.source = source; self.tagged = tagged
    }

    var diagnosis: AudioVerifyDiagnosis {
        switch source {
        case .levels(let c): return SoundStandingFixture.diagnosis(c, tracks: tracks, complete: complete)
        case .noStream: return SoundStandingFixture.noStreamDiagnosis()
        case .referenceMovie: return SoundStandingFixture.referenceMovieDiagnosis()
        }
    }

    var testDescription: String {
        let tag = " · \(tagged ? "tagged Silent — checked" : "no tag")"
        switch source {
        case .levels(let c):
            return "\(c.rawValue) · \(tracks) track\(tracks == 1 ? "" : "s") · \(complete ? "measured in full" : "partly measured")" + tag
        case .noStream: return "no audio stream" + tag
        case .referenceMovie: return "reference movie, no audio stream (damaged)" + tag
        }
    }

    static let all: [SoundStandingCell] = {
        var out: [SoundStandingCell] = []
        for c in [AudioChannelClass.trueStereo, .dualMono, .leftOnly, .rightOnly, .mono, .silent, .multichannel] {
            for tracks in [1, 2] {
                for complete in [true, false] {
                    for tagged in [false, true] {
                        out.append(SoundStandingCell(channelClass: c, tracks: tracks, complete: complete, tagged: tagged))
                    }
                }
            }
        }
        // The states with no levels: no track, and damage with no track
        // (Codex #302 F1 — the tag accepts the first, never the second).
        for tagged in [false, true] {
            out.append(SoundStandingCell(.noStream, tagged: tagged))
            out.append(SoundStandingCell(.referenceMovie, tagged: tagged))
        }
        return out
    }()
}

@Suite("Sound standing follows the Promote gate (Codex #300)")
@MainActor
struct SoundStandingFollowsGateTests {
    typealias F = SoundStandingFixture

    // MARK: The agreement walk

    @Test("TRUTH: for every class × tracks × completeness × tag, the sheet's sound line agrees with the gate's decision",
          arguments: SoundStandingCell.all)
    func theSheetFollowsTheGate(_ cell: SoundStandingCell) {
        let d = cell.diagnosis
        if case .levels(let c) = cell.source {
            #expect(d.balanceAnalysis?.classification == c, "the fixture's levels classify as the cell says")
        }
        let record = F.record(for: d, tagged: cell.tagged)
        let decision = F.gate(d, record: record)
        let readiness = ArchiveReadiness.assess(record: record)
        let line = readiness.sheetLine(dateLabel: "1992")
        let said = ([line] + readiness.warnings).joined(separator: " | ")
        let row = F.row(record)

        switch decision {
        case .refuse(let code, _, _):
            // The gate refuses ⇒ the sheet is red — or, when nothing could be
            // stored because the measurement was incomplete, "not checked".
            if code == .unchecked {
                #expect(readiness.sound == .notChecked, "\(said)")
            } else {
                #expect(F.isRed(readiness), "the gate refuses (\(code.rawValue)) but the sheet says: \(said)")
            }
            #expect(!F.isGreen(readiness), "\(said)")
            #expect(!line.contains("Audio ✓"), "\(line)")
        case .promote(let rowNote, _):
            // The gate accepts ⇒ the sheet never says it will be refused.
            #expect(!F.isRed(readiness), "the gate accepts but the sheet is red: \(said)")
            #expect(!line.contains("✗"), "\(line)")
            #expect(!(readiness.warnings.first ?? "").contains("Promote refuses"), "\(said)")
            // Green ⇒ the gate has nothing of its own to say.
            if F.isGreen(readiness) || line.contains("Audio ✓") {
                #expect(rowNote == nil, "green on the sheet, but the gate notes: \(rowNote ?? "")")
            }
            // One side only ⇒ never Ready, never past Prepare.
            if rowNote?.contains("side only") == true {
                #expect(row.route == .prepare && !row.isReady, "\(row.statusWords)")
                #expect(line.contains("Audio ⚠"), "\(line)")
            }
        }
        // A row the Angel calls plainly Ready (and that its no-usable-sound
        // floor lets through) is one the gate promotes with nothing to add,
        // and the sheet shows green.
        let floored = ArchiveReadiness.lacksUsableSound(streamTypeRaw: record.streamTypeRaw,
                                                        audioVerifyStatus: record.audioVerifyStatus,
                                                        audioVerifyNote: record.audioVerifyNote)
        if row.statusWords == "Ready to archive", !floored {
            #expect(!decision.isRefusal, "\(decision)")
            if case .promote(let rowNote, _) = decision { #expect(rowNote == nil, "\(rowNote ?? "")") }
            #expect(F.isGreen(readiness), "plainly Ready, but the sheet says: \(said)")
        }
    }

    @Test("TRUTH: no audio stream and measured damage — refused by the gate, red on the sheet; the tag lifts only the first")
    func noStreamAndDamage() {
        for tagged in [false, true] {
            let none = F.noStreamDiagnosis()
            let record = F.record(for: none, tagged: tagged)
            let readiness = ArchiveReadiness.assess(record: record)
            #expect(F.gate(none, record: record).isRefusal == !tagged)
            #expect(F.isRed(readiness) == !tagged, "\(readiness.sheetLine(dateLabel: "1992")) | \(readiness.warnings)")

            // Sound a tenth as long as the picture: damage, tag or no tag.
            let short = F.diagnosis(rms: [-18, -19], difference: -21, audioSeconds: 6)
            let damaged = F.record(for: short, tagged: tagged)
            #expect(damaged.audioVerifyStatus == "damaged")
            #expect(F.gate(short, record: damaged).isRefusal)
            #expect(F.isRed(ArchiveReadiness.assess(record: damaged)))
        }
    }

    // MARK: F1 — layout notes

    @Test("F1: six silent channels are SILENT, not 'surround' — Verify Audio, the gate and the sheet agree")
    func silentSurroundIsSilent() {
        let d = F.diagnosis(rms: Array(repeating: -.infinity, count: 6))
        #expect(d.balanceAnalysis?.classification == .multichannel)
        #expect(d.findings == [.silentAudio], "\(d.findings)")
        let record = F.record(for: d)
        #expect(record.audioVerifyNote == "silent audio")
        guard case .refuse(let code, _, _) = F.gate(d, record: record) else { Issue.record("the gate accepts silence"); return }
        #expect(code == .silent)
        let readiness = ArchiveReadiness.assess(record: record)
        #expect(F.isRed(readiness))
        #expect(!readiness.sheetLine(dateLabel: "1992").contains("Audio ✓"))
        // Six LIVE channels are still surround.
        #expect(F.diagnosis(.multichannel).findings == [.surround(channels: 6)])
        // Under the floor counts as silent too (−70 dBFS on all six).
        #expect(F.diagnosis(rms: Array(repeating: -70, count: 6)).findings == [.silentAudio])
    }

    @Test("F1: a layout note (two live tracks, surround) is never 'Audio ✓' — the sheet says what was not measured, and the Angel's row says so too",
          arguments: [AudioChannelClass.leftOnly, .rightOnly, .trueStereo, .multichannel], [1, 2])
    func aLayoutNoteIsNotGreen(_ c: AudioChannelClass, tracks: Int) {
        // One live stereo track is the plain case, and one-sided has its own.
        if tracks == 1 && c != .multichannel { return }
        let d = F.diagnosis(c, tracks: tracks)
        let record = F.record(for: d)
        #expect(!record.audioVerifyNote.isEmpty, "precondition: Verify Audio stored a note")
        let readiness = ArchiveReadiness.assess(record: record)
        let line = readiness.sheetLine(dateLabel: "1992")
        #expect(!line.contains("Audio ✓"), "\(line)")
        #expect(!F.isGreen(readiness) && !F.isRed(readiness), "\(line)")
        #expect(line.contains(record.audioVerifyNote), "the note is shown: \(line)")
        #expect(readiness.warnings.first?.contains("not measured") == true, "\(readiness.warnings)")
        let row = F.row(record)
        #expect(row.statusWords != "Ready to archive", "plainly Ready hides the note")
        #expect(row.statusWords.contains("not measured"), "\(row.statusWords)")
        let sheet = ArchiveAngelReadinessExplanation.make(ArchiveAngelRowFacts.make(record: record, evidence: nil, kind: .ready))
        #expect(sheet.statusWords == row.statusWords)
        #expect(sheet.facts.contains { $0.label == "Sound" && $0.value.contains("not measured") }, "\(sheet.facts)")
    }

    @Test("ISOLATION: a stored note nobody recognises is never green and never 'refuses'")
    func aStoredNoteNobodyRecognisesIsNeverGreen() {
        for note in ["quadraphonic audio", "mono audio; quadraphonic audio", "MONO AUDIO", " ; "] {
            let d = F.diagnosis(.mono)
            let record = F.record(for: d)
            record.audioVerifyNote = note
            let readiness = ArchiveReadiness.assess(record: record)
            let line = readiness.sheetLine(dateLabel: "1992")
            #expect(!line.contains("Audio ✓") && !F.isGreen(readiness), "\(note): \(line)")
            #expect(!F.isRed(readiness), "\(note): \(line)")
        }
    }

    // MARK: F2 — a stored mono note on a file that is not one channel

    @Test("F2: 'mono audio' is fine only on a one-channel record; on a two-channel record the stored check does not describe the file",
          arguments: ["2", "6", "", "0", "stereo"])
    func staleMonoIsNotChecked(recordChannels: String) {
        let record = F.record(for: F.diagnosis(.mono))
        #expect(record.audioVerifyNote == "mono audio" && record.audioChannels == "1")
        #expect(F.isGreen(ArchiveReadiness.assess(record: record)))
        #expect(F.row(record).route == .direct)

        record.audioChannels = recordChannels
        let readiness = ArchiveReadiness.assess(record: record)
        #expect(readiness.sound == .notChecked, "\(readiness.sound)")
        #expect(!readiness.sheetLine(dateLabel: "1992").contains("Audio ✓"))
        #expect(!F.isGreen(readiness))
        let row = F.row(record)
        #expect(!row.isReady && row.route == .prepare, "\(row.statusWords)")
        #expect(row.statusWords == "Needs audio checked")
    }

    // MARK: F4 — the owner's tag

    @Test("F4: silence the owner's tag accepts is not shown as refused — the gate and the sheet read the same mark",
          arguments: [false, true])
    func acceptedSilenceIsNotAProblem(tagged: Bool) {
        for d in [F.diagnosis(.silent), F.noStreamDiagnosis()] {
            let record = F.record(for: d, tagged: tagged)
            let decision = F.gate(d, record: record)
            let readiness = ArchiveReadiness.assess(record: record)
            let line = readiness.sheetLine(dateLabel: "1992")
            #expect(decision.isRefusal == !tagged)
            #expect(F.isRed(readiness) == decision.isRefusal, "gate \(decision) vs sheet: \(line)")
            #expect(line.contains("✗") == decision.isRefusal, "\(line)")
            let plan = ArchivePromotePlan(rootPath: "/Volumes/A", entries: [F.entry(record)], skipped: [],
                                          totalBytes: 0, freeBytesAtRoot: nil)
            #expect(plan.audioProblemCount == (decision.isRefusal ? 1 : 0))
            if tagged {
                #expect(!F.isGreen(readiness), "accepted is said in neutral words, not shown as fine: \(line)")
                #expect(line.contains(WorkflowTags.silentChecked), "\(line)")
                #expect(readiness.warnings.first?.contains("refuses") != true, "\(readiness.warnings)")
            }
        }
        // The tag never lifts damage, on the sheet as at the gate.
        let short = F.diagnosis(rms: [-18, -19], difference: -21, audioSeconds: 6)
        let damaged = F.record(for: short, tagged: tagged)
        #expect(F.gate(short, record: damaged).isRefusal && F.isRed(ArchiveReadiness.assess(record: damaged)))
    }

    @Test("F4: a tag the gate would not tie to the file (not a SHA-256 fingerprint) accepts nothing on the sheet either")
    func aTagNotTiedToTheBytesAcceptsNothing() {
        let d = F.diagnosis(.silent)
        let record = F.record(for: d, tagged: true)
        record.sizeBytes = 0   // never fingerprinted, and no size to bind the tag to
        #expect(F.gate(d, record: record).isRefusal)
        #expect(F.isRed(ArchiveReadiness.assess(record: record)))
    }

    // Codex #302 F1: `assess` chose "no audio track" before it looked at the
    // stored "damaged", and the tag accepts no-track.
    @Test("F4: a stored refusal outranks everything — a tagged reference movie (stored 'attention' since v1.16, refused exactly like 'damaged') with no audio stream is refused, never 'accepted'")
    func damageOutranksTheTagEvenWithNoTrack() {
        let d = F.referenceMovieDiagnosis()
        let r = F.record(for: d, tagged: true)
        #expect(r.audioVerifyStatus == "attention" && r.streamTypeRaw == StreamType.videoOnly.rawValue)
        #expect(F.gate(d, record: r).isRefusal)
        let readiness = ArchiveReadiness.assess(record: r)
        let line = readiness.sheetLine(dateLabel: "1992")
        #expect(F.isRed(readiness), "\(line) | \(readiness.warnings)")
        #expect(line.contains("Audio ✗") && line.localizedCaseInsensitiveContains("reference movie"), "\(line)")
        #expect(readiness.sound.bucket == .refused)
        #expect(readiness.token.contains("audio=problem"), "\(readiness.token)")
        // An un-probeable record that stores damage is red on its sound too.
        r.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        #expect(ArchiveReadiness.assess(record: r).sound.bucket == .refused)
        // The row never reads Ready.
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        #expect(F.row(r).statusWords == "Needs audio repair")
    }

    // Codex #302 F4: the forecast compares the record with itself; the job
    // compares it with the bytes it proved. The sheet may forecast, not promise.
    @Test("F4: the accepted line is conditional — the forecast says 'as catalogued', the job's proven mark may still refuse")
    func theAcceptedLineDoesNotPromise() {
        let d = F.diagnosis(.silent)
        let r = F.record(for: d, tagged: true)
        #expect(r.sizeBytes == 4_096 && r.contentFixity == nil)
        #expect(ArchiveReadiness.forecastSoundMark(record: r) == .accepted)
        // The file on disk is one byte longer than the catalog says.
        let proven = PromoteSoundGate.mark(tags: r.tags, storedFixity: nil, provenDigest: String(repeating: "a", count: 64),
                                           recordSizeBytes: r.sizeBytes, provenSizeBytes: 4_097)
        #expect(proven == .notTiedToTheseBytes)
        #expect(PromoteSoundGate.decide(finding: PromoteSoundGate.finding(from: d), mark: proven, soundPartnerName: nil,
                                        recordedYear: nil, digestPrefix: "").isRefusal)
        let readiness = ArchiveReadiness.assess(record: r)
        let facts = ArchiveAngelReadinessExplanation.make(ArchiveAngelRowFacts.make(record: r, evidence: nil, kind: .ready)).facts
        let said = [readiness.sheetLine(dateLabel: "1992")] + readiness.warnings + facts.filter { $0.label == "Sound" }.map(\.value)
        for sentence in said {
            #expect(!sentence.contains("Promote archives it"), "an unconditional promise: \(sentence)")
            #expect(!sentence.contains("accepted by"), "\(sentence)")
        }
        #expect(readiness.warnings.first?.contains("as catalogued") == true, "\(readiness.warnings)")
        #expect(readiness.warnings.first?.contains("Promote checks the file is still that one") == true, "\(readiness.warnings)")
        #expect(!F.isRed(readiness) && !F.isGreen(readiness))
    }

    // MARK: F5 — counters

    @Test("F5: the sheet's audio counters partition the selection, and each row is counted where the gate puts it")
    func soundBucketsPartitionTheSelection() {
        let stereo = F.diagnosis(.trueStereo), mono = F.diagnosis(.mono), left = F.diagnosis(.leftOnly)
        let none = F.noStreamDiagnosis(), silent = F.diagnosis(.silent), partial = F.diagnosis(.trueStereo, complete: false)
        let surround = F.diagnosis(.multichannel)
        let cases: [(name: String, d: AudioVerifyDiagnosis, tagged: Bool)] = [
            ("clean stereo", stereo, false), ("mono", mono, false), ("video-only", none, false),
            ("one-sided", left, false), ("unchecked", partial, false), ("accepted-silent", silent, true),
            ("silent", silent, false), ("surround", surround, false),
        ]
        let records = cases.map { F.record(for: $0.d, tagged: $0.tagged) }
        let plan = ArchivePromotePlan(rootPath: "/Volumes/A", entries: records.map(F.entry), skipped: [],
                                      totalBytes: 0, freeBytesAtRoot: nil)
        let refusedByGate = zip(cases, records).filter { pair in
            if case .refuse(let code, _, _) = F.gate(pair.0.d, record: pair.1) { return code != .unchecked }
            return false
        }.count
        #expect(refusedByGate == 2, "video-only and silent")
        #expect(plan.audioProblemCount == refusedByGate, "a no-track refusal is counted with the refusals")
        #expect(plan.audioUnbalancedCount == 1)
        #expect(plan.audioNotVerifiedCount == 1)
        #expect(plan.audioFineCount == 2, "clean stereo and mono")
        #expect(plan.audioNotedCount == 2, "accepted silence and surround: said, not counted as a problem")
        let total = plan.audioFineCount + plan.audioNotedCount + plan.audioUnbalancedCount
            + plan.audioProblemCount + plan.audioNotVerifiedCount
        #expect(total == plan.entries.count, "every selected row is in exactly one audio bucket")
        for entry in plan.entries {
            #expect(ArchiveReadiness.SoundBucket.allCases.filter { $0 == entry.readiness.sound.bucket }.count == 1)
        }
    }

    // MARK: Scale

    @Test("SCALE: 100k sound standings under budget (the tag path builds the gate's decision)", .timeLimit(.minutes(1)))
    func scale() {
        var silent = ArchiveReadiness.Inputs()
        silent.isPlayable = "Yes"
        silent.streamTypeRaw = StreamType.videoOnly.rawValue
        silent.videoCodec = "h264"
        let t0 = CFAbsoluteTimeGetCurrent()
        var red = 0
        for _ in 0..<100_000 where PromoteToArchiveSheet.lineColor(ArchiveReadiness.assess(silent)) == .red { red += 1 }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(red == 100_000)
        #expect(ms < PerformanceLane.debugCeiling(milliseconds: 4_000), "100k standings took \(Int(ms)) ms")
    }
}
