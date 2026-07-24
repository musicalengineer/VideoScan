// VerifyAudioRulesTests.swift
// LOGIC dimension (feature-test checklist item 1) for the Verify Audio
// diagnosis engine (GH #128) — the PURE half only. Every test here feeds
// VerifyAudioRules / VerifyAudioProbe.shape canned values; no process is
// ever launched (the I/O half is covered by VerifyAudioMediaMatrixTests).
//
// Coverage map (feature-dev's asks):
//   * referencedPaths(fromProbeStderr:) — marker parsing, separator
//     stripping, in-order dedupe, hand-built dref stderr fixture (the
//     canned-stderr seam is deliberate — real reference movies are not
//     synthesizable).
//   * hasDurationMismatch boundary — EXACTLY 10% must NOT fire;
//     unknown/zero durations must NEVER fire.
//   * status/note mapping — damage-first ordering; only invalid-codec/
//     undecodable, reference-movie, duration-mismatch produce "damaged".
//   * findings(...) composition — reference movie suppresses everything;
//     imbalance only when BalanceAudioFix.refusalReason is nil.
//   * bitDepth(fromCodecName:) + shape(fromProbeJSON:) decode rules.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Reference-movie stderr parsing

@Suite("VerifyAudioRules — dref stderr parsing")
struct VerifyAudioDrefParsingTests {

    /// Hand-built fixture mirroring what ffprobe's mov demuxer emits for
    /// an Avid/QuickTime reference movie (the JustPatsHouse.mov shape):
    /// banner noise, one marker line per external track, duplicate
    /// markers for the same alias, and unrelated stderr in between.
    private static let drefStderr = """
    [mov,mp4,m4a,3gp,3g2,mj2 @ 0x7f8a1c008200] Skipped opening external track: stream 0, alias: path='/Volumes/Media Drive 1/JustPats Media/JustPatsHouse Media.1.mov', dir=1
    [mov,mp4,m4a,3gp,3g2,mj2 @ 0x7f8a1c008200] Skipped opening external track: stream 1, alias: path='/Volumes/Media Drive 1/JustPats Media/JustPatsHouse Media.1.mov', dir=1
    [mov,mp4,m4a,3gp,3g2,mj2 @ 0x7f8a1c008200] Skipped opening external track: stream 0, alias: path='/Volumes/Media Drive 1/JustPats Media/JustPatsHouse Media.1.mov', dir=1
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'JustPatsHouse.mov':
      Duration: 00:12:31.20, start: 0.000000, bitrate: 1 kb/s
    """

    @Test func parsesOneEntryPerUniqueMarkerLine() {
        let paths = VerifyAudioRules.referencedPaths(
            fromProbeStderr: Self.drefStderr)
        // 3 marker lines, but line 3 duplicates line 1 → 2 unique
        // entries, in first-seen order.
        #expect(paths == [
            "stream 0, alias: path='/Volumes/Media Drive 1/JustPats Media/JustPatsHouse Media.1.mov', dir=1",
            "stream 1, alias: path='/Volumes/Media Drive 1/JustPats Media/JustPatsHouse Media.1.mov', dir=1",
        ])
    }

    @Test func stripsSeparatorVariants() {
        // The marker may be followed by ": ", ":", or spaces depending
        // on ffmpeg version — all must strip to the bare detail.
        for sep in [": ", ":", " : ", "  ", ":  "] {
            let stderr = "[mov @ 0x1] Skipped opening external track\(sep)alias detail here"
            #expect(VerifyAudioRules.referencedPaths(fromProbeStderr: stderr)
                    == ["alias detail here"],
                    "separator '\(sep)' not stripped")
        }
    }

    @Test func ignoresNonMarkerLinesAndEmptyDetails() {
        #expect(VerifyAudioRules.referencedPaths(fromProbeStderr: "").isEmpty)
        #expect(VerifyAudioRules.referencedPaths(
            fromProbeStderr: "[mov @ 0x1] moov atom not found\nDuration: 00:01:00").isEmpty)
        // A marker with nothing after it must not produce an empty entry.
        #expect(VerifyAudioRules.referencedPaths(
            fromProbeStderr: "[mov @ 0x1] Skipped opening external track:   ").isEmpty)
    }

    @Test func healthyFileStderrYieldsNoPaths() {
        // Default-verbosity stderr of a NORMAL file — the reason the
        // probe can't use -v error must not misfire on healthy noise.
        let healthy = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mov':
          Metadata:
            major_brand     : qt
          Duration: 00:01:00.00, start: 0.000000, bitrate: 8000 kb/s
            Stream #0:0[0x1]: Video: h264 (avc1 / 0x31637661), yuv420p, 720x480
            Stream #0:1[0x2]: Audio: pcm_s16le (sowt / 0x74776F73), 48000 Hz, stereo
        """
        #expect(VerifyAudioRules.referencedPaths(fromProbeStderr: healthy).isEmpty)
    }

    // The raw alias detail is ffprobe field soup; the sheet must never
    // show it (Rick hit exactly that on the real JustPatsHouse.mov,
    // 2026-07-24). displayReferencedPath reduces it to path + drive.

    /// The exact alias detail ffprobe emitted for JustPatsHouse.mov's
    /// video track — the line Rick saw leak into the dialog.
    private static let realAliasDetail =
        "stream 1, alias: path='/Avid MediaFiles/MXF/1/Thanksgiving2009-Pr4B189B28.mxf', dir='1', filename='Thanksgiving2009-Pr4B189B28.mxf', volume='Media250', nlvl_from=-1, nlvl_to=-1.Set enable_drefs to allow this."

    @Test func displayFormatsRealAliasAsPathAndDrive() {
        #expect(VerifyAudioRules.displayReferencedPath(Self.realAliasDetail)
                == "/Avid MediaFiles/MXF/1/Thanksgiving2009-Pr4B189B28.mxf — on drive “Media250”")
    }

    @Test func displayOmitsDriveWhenVolumeMissingOrEmpty() {
        #expect(VerifyAudioRules.displayReferencedPath(
            "stream 0, alias: path='/Users/Shared/clip.wav', dir='x'")
                == "/Users/Shared/clip.wav")
        #expect(VerifyAudioRules.displayReferencedPath(
            "alias: path='/a/b.mov', volume=''")
                == "/a/b.mov")
    }

    @Test func displayFallbackStripsEnableDrefsAdvice() {
        // No parseable path= field → raw detail survives, but the
        // developer advice sentence must not.
        #expect(VerifyAudioRules.displayReferencedPath(
            "stream 2, unparseable alias.Set enable_drefs to allow this.")
                == "stream 2, unparseable alias")
        // Nothing to strip → unchanged.
        #expect(VerifyAudioRules.displayReferencedPath("plain detail")
                == "plain detail")
    }

    @Test func displayNeverEmitsJargonForRealAlias() {
        // Sensor for the actual complaint: none of ffprobe's field
        // names may survive formatting of a well-formed alias line.
        let shown = VerifyAudioRules.displayReferencedPath(Self.realAliasDetail)
        for jargon in ["enable_drefs", "nlvl", "alias:", "filename=", "dir="] {
            #expect(!shown.contains(jargon), "jargon '\(jargon)' leaked")
        }
    }
}

// MARK: - Duration-mismatch boundary

@Suite("VerifyAudioRules — duration mismatch")
struct VerifyAudioDurationMismatchTests {

    @Test func exactlyTenPercentShorterDoesNotFire() {
        // The spec says STRICTLY more than 10% shorter. 90 s audio on
        // 100 s video is exactly 10% — must NOT fire.
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: 90, videoSeconds: 100))
    }

    @Test func justOverTenPercentFires() {
        #expect(VerifyAudioRules.hasDurationMismatch(audioSeconds: 89.9, videoSeconds: 100))
        // The #125 proof case: 2-minute audio on a 63-minute video.
        #expect(VerifyAudioRules.hasDurationMismatch(audioSeconds: 120, videoSeconds: 3780))
    }

    @Test func unknownOrZeroDurationsNeverFire() {
        // An unknown duration must never manufacture a damage verdict.
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: 0, videoSeconds: 100))
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: 100, videoSeconds: 0))
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: 0, videoSeconds: 0))
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: -5, videoSeconds: 100))
    }

    @Test func audioLongerThanVideoDoesNotFire() {
        // Longer audio (tail-padded captures) is not the #125 class.
        #expect(!VerifyAudioRules.hasDurationMismatch(audioSeconds: 110, videoSeconds: 100))
    }

    @Test func suspiciouslyTinyCorroboration() {
        // ≥60 s claimed duration in under 2 MiB → cannot hold essence.
        #expect(VerifyAudioRules.isSuspiciouslyTiny(fileSizeBytes: 100_000, durationSeconds: 751))
        #expect(!VerifyAudioRules.isSuspiciouslyTiny(fileSizeBytes: 100_000, durationSeconds: 59))
        #expect(!VerifyAudioRules.isSuspiciouslyTiny(fileSizeBytes: 0, durationSeconds: 751))
        #expect(!VerifyAudioRules.isSuspiciouslyTiny(fileSizeBytes: 2 << 20, durationSeconds: 751))
    }
}

// MARK: - Status / note mapping

@Suite("VerifyAudioRules — status/note mapping")
struct VerifyAudioStatusNoteTests {

    @Test func onlyTheThreeDamageFindingsProduceDamaged() {
        // Damage set: reference movie, duration mismatch, invalid codec
        // (both decodable and undecodable flavors).
        let damage: [AudioVerifyFinding] = [
            .referenceMovie(referencedPaths: ["x"]),
            .durationMismatch(audioSeconds: 2, videoSeconds: 60),
            .unsupportedCodec(codec: "qdm2", decodable: true),
            .unsupportedCodec(codec: "", decodable: false),
        ]
        for f in damage {
            #expect(VerifyAudioRules.isDamage(f), "\(f) must be damage")
            #expect(VerifyAudioRules.status(for: [f]) == "damaged")
        }
        // Everything else is an honest state, not a broken file.
        let notDamage: [AudioVerifyFinding] = [
            .channelImbalance(.leftOnly),
            .channelImbalance(.mono),
            .noAudioStream,
            .silentAudio,
            .surround(channels: 6),
            .multipleProgramTracks(count: 2),
        ]
        for f in notDamage {
            #expect(!VerifyAudioRules.isDamage(f), "\(f) must NOT be damage")
            #expect(VerifyAudioRules.status(for: [f]) == "ok")
        }
    }

    @Test func emptyFindingsAreOkNeverEmptyString() {
        // "" is reserved for never-verified — the mapper must never
        // produce it (a clean verify must be distinguishable from no
        // verify at all).
        #expect(VerifyAudioRules.status(for: []) == "ok")
        #expect(VerifyAudioRules.note(for: []) == "")
    }

    @Test func anyDamageFindingMakesTheWholeVerdictDamaged() {
        #expect(VerifyAudioRules.status(for: [
            .silentAudio, .durationMismatch(audioSeconds: 2, videoSeconds: 60),
        ]) == "damaged")
    }

    @Test func noteFragmentsExactStrings() {
        // These strings persist into catalog.json and drive the
        // notes:-token batch-finds — pin them exactly. Fragments are
        // UNPREFIXED: note(for:) adds "Damaged audio — " once for
        // damaged verdicts (see the sensor below), and the rebuild
        // job's File Journey reason uses the bare fragment.
        // referenceMovie uses a comma (not an em dash) so the prefixed
        // note doesn't read with two dashes.
        #expect(VerifyAudioRules.noteFragment(for: .referenceMovie(referencedPaths: []))
                == "reference movie, media missing")
        #expect(VerifyAudioRules.noteFragment(for: .unsupportedCodec(codec: "qdm2", decodable: true))
                == "invalid codec (qdm2)")
        #expect(VerifyAudioRules.noteFragment(for: .unsupportedCodec(codec: "cook", decodable: false))
                == "undecodable audio (cook)")
        #expect(VerifyAudioRules.noteFragment(for: .unsupportedCodec(codec: "", decodable: false))
                == "undecodable audio (unknown codec)")
        #expect(VerifyAudioRules.noteFragment(for: .durationMismatch(audioSeconds: 119.6, videoSeconds: 3780.4))
                == "audio shorter than video (120s vs 3780s)")
        #expect(VerifyAudioRules.noteFragment(for: .channelImbalance(.leftOnly))
                == "one-sided audio (left only)")
        #expect(VerifyAudioRules.noteFragment(for: .channelImbalance(.rightOnly))
                == "one-sided audio (right only)")
        #expect(VerifyAudioRules.noteFragment(for: .channelImbalance(.mono))
                == "mono audio")
        #expect(VerifyAudioRules.noteFragment(for: .noAudioStream) == "no audio stream")
        #expect(VerifyAudioRules.noteFragment(for: .silentAudio) == "silent audio")
        #expect(VerifyAudioRules.noteFragment(for: .surround(channels: 6))
                == "surround audio (6 channels)")
        #expect(VerifyAudioRules.noteFragment(for: .multipleProgramTracks(count: 2))
                == "2 live audio tracks")
    }

    @Test func noteOrdersDamageFirstAndPrefixesDamaged() {
        // A damaged record's note must LEAD with the standardized
        // "Damaged audio — " prefix, then why it's red — whatever
        // order the findings were produced in.
        let note = VerifyAudioRules.note(for: [
            .silentAudio,
            .unsupportedCodec(codec: "qdm2", decodable: true),
        ])
        #expect(note == "Damaged audio — invalid codec (qdm2); silent audio")

        let note2 = VerifyAudioRules.note(for: [
            .channelImbalance(.mono),
            .durationMismatch(audioSeconds: 2, videoSeconds: 63),
        ])
        #expect(note2 == "Damaged audio — audio shorter than video (2s vs 63s); mono audio")
    }

    @Test func batchDeleteSensorEveryDamagedNoteBeginsWithDamagedAudio() {
        // SENSOR (Manager decision 2026-07-24, the #128 batch-delete
        // flow): Rick finds ALL red rows with the ONE query
        // `notes:damaged`, which works iff every damaged-status note
        // begins with the common prefix. Any new damage finding that
        // forgets the prefix breaks batch-find silently — this pins it.
        let damageFindings: [AudioVerifyFinding] = [
            .referenceMovie(referencedPaths: ["x"]),
            .durationMismatch(audioSeconds: 120, videoSeconds: 3600),
            .unsupportedCodec(codec: "truespeech", decodable: true),
            .unsupportedCodec(codec: "", decodable: false),
        ]
        for f in damageFindings {
            let note = VerifyAudioRules.note(for: [f])
            #expect(VerifyAudioRules.status(for: [f]) == "damaged")
            #expect(note.hasPrefix(VerifyAudioRules.damagedNotePrefix),
                    "damaged note '\(note)' must begin with '\(VerifyAudioRules.damagedNotePrefix)'")
            // The prefix must also survive mixed damage + benign
            // findings, in any order.
            let mixed = VerifyAudioRules.note(for: [.silentAudio, f])
            #expect(mixed.hasPrefix(VerifyAudioRules.damagedNotePrefix),
                    "mixed-findings note '\(mixed)' must begin with '\(VerifyAudioRules.damagedNotePrefix)'")
        }
        // Pin the exact prefix spelling — `notes:damaged` matching
        // depends on the word itself, and the em dash is the
        // prefix/detail separator the tooltip relies on.
        #expect(VerifyAudioRules.damagedNotePrefix == "Damaged audio — ")

        // ok-status notes stay BARE — the prefix must never leak onto
        // repairable/benign findings, or `notes:damaged` would surface
        // rows that aren't red.
        let okFindings: [AudioVerifyFinding] = [
            .channelImbalance(.leftOnly),
            .noAudioStream,
            .silentAudio,
            .surround(channels: 6),
            .multipleProgramTracks(count: 2),
        ]
        for f in okFindings {
            let note = VerifyAudioRules.note(for: [f])
            #expect(VerifyAudioRules.status(for: [f]) == "ok")
            #expect(!note.localizedCaseInsensitiveContains("damaged"),
                    "ok-status note '\(note)' must not contain 'damaged'")
        }
    }
}

// MARK: - Findings composition

@Suite("VerifyAudioRules — findings composition")
struct VerifyAudioFindingsCompositionTests {

    // Canned-analysis factory. (≈ a C++ test fixture builder — the
    // struct's memberwise init plays the role of an aggregate initializer.)
    private func analysis(_ classification: AudioChannelClass,
                          channelCount: Int = 2,
                          programStreams: Int = 1) -> AudioBalanceAnalysis {
        let live = AudioChannelLevels(rmsDBFS: -20, peakDBFS: -3)
        return AudioBalanceAnalysis(
            classification: classification,
            measurements: AudioBalanceMeasurements(
                channels: Array(repeating: live, count: channelCount),
                differenceRMSDBFS: nil),
            shape: AudioBalanceStreamShape(
                videoCodec: "h264", totalStreams: 2, videoStreams: 1,
                audioStreams: 1, audioCodec: "aac", audioChannels: channelCount,
                audioBitRate: nil, durationSeconds: 60, audioStreamInfos: []),
            programStreamCount: programStreams,
            programStreamIndex: 1,
            droppedStreamIndices: [])
    }

    private func shape(audioStreams: Int = 1,
                       audioCodec: String = "aac",
                       audioSeconds: Double = 60,
                       videoSeconds: Double = 60) -> AudioVerifyShape {
        var s = AudioVerifyShape()
        s.videoCodec = "h264"
        s.videoDurationSeconds = videoSeconds
        s.audioStreams = audioStreams
        s.audioCodec = audioCodec
        s.audioDurationSeconds = audioSeconds
        return s
    }

    @Test func referenceMovieSuppressesEverythingElse() {
        // Even with no-audio + duration-mismatch + analyzeFailed all
        // signalling at once, a reference movie is the ONLY finding —
        // there is no essence, so every other measurement is noise.
        let out = VerifyAudioRules.findings(
            shape: shape(audioStreams: 0, audioCodec: "qdm2",
                         audioSeconds: 2, videoSeconds: 600),
            referencedPaths: ["stream 0, alias: path='/Volumes/Gone/x.mov'"],
            analysis: nil,
            analyzeFailed: true)
        #expect(out == [.referenceMovie(
            referencedPaths: ["stream 0, alias: path='/Volumes/Gone/x.mov'"])])
    }

    @Test func noAudioStreamIsItsOwnVerdict() {
        #expect(VerifyAudioRules.findings(
            shape: shape(audioStreams: 0), referencedPaths: [],
            analysis: nil, analyzeFailed: false) == [.noAudioStream])
    }

    @Test func healthyStereoProducesNoFindings() {
        for c in [AudioChannelClass.trueStereo, .dualMono] {
            #expect(VerifyAudioRules.findings(
                shape: shape(), referencedPaths: [],
                analysis: analysis(c), analyzeFailed: false).isEmpty,
                "\(c) must be healthy")
        }
    }

    @Test func legacyCodecFlagsInvalidDecodable() {
        // qdm2 decodes under ffmpeg but not AVFoundation → decodable
        // rebuild offer. Trimming + case-folding must hold.
        let out = VerifyAudioRules.findings(
            shape: shape(audioCodec: " QDM2 "), referencedPaths: [],
            analysis: analysis(.trueStereo), analyzeFailed: false)
        #expect(out == [.unsupportedCodec(codec: " QDM2 ", decodable: true)])
    }

    @Test func analyzeFailureFlagsUndecodable() {
        // The astats pass throwing is a FINDING (undecodable track),
        // never a diagnosis failure — and it wins over the legacy list.
        let out = VerifyAudioRules.findings(
            shape: shape(audioCodec: "qdm2"), referencedPaths: [],
            analysis: nil, analyzeFailed: true)
        #expect(out == [.unsupportedCodec(codec: "qdm2", decodable: false)])
    }

    @Test func durationMismatchIsIndependentOfLevels() {
        // #125: perfectly good stereo levels, wrong audio — 2-minute
        // track on a 63-minute video must still flag.
        let out = VerifyAudioRules.findings(
            shape: shape(audioSeconds: 120, videoSeconds: 3780),
            referencedPaths: [],
            analysis: analysis(.trueStereo), analyzeFailed: false)
        #expect(out == [.durationMismatch(audioSeconds: 120, videoSeconds: 3780)])
    }

    @Test func codecAndDurationFindingsCompose() {
        let out = VerifyAudioRules.findings(
            shape: shape(audioCodec: "mace3", audioSeconds: 120, videoSeconds: 3780),
            referencedPaths: [], analysis: nil, analyzeFailed: false)
        #expect(out == [
            .unsupportedCodec(codec: "mace3", decodable: true),
            .durationMismatch(audioSeconds: 120, videoSeconds: 3780),
        ])
    }

    @Test func imbalanceOfferedOnlyWhenBalanceWouldAccept() {
        // Actionable classes → channelImbalance carrying the class.
        for c in [AudioChannelClass.leftOnly, .rightOnly, .mono] {
            #expect(BalanceAudioFix.refusalReason(for: analysis(c)) == nil,
                    "precondition: \(c) is actionable")
            #expect(VerifyAudioRules.findings(
                shape: shape(), referencedPaths: [],
                analysis: analysis(c), analyzeFailed: false)
                == [.channelImbalance(c)])
        }
    }

    @Test func multiProgramTracksReportedInsteadOfImbalance() {
        // Two program-carrying streams: Balance would refuse, so the
        // sheet must never offer it — report the state instead.
        let a = analysis(.leftOnly, programStreams: 2)
        #expect(BalanceAudioFix.refusalReason(for: a) != nil,
                "precondition: multi-program is refused by the shared gate")
        #expect(VerifyAudioRules.findings(
            shape: shape(), referencedPaths: [],
            analysis: a, analyzeFailed: false)
            == [.multipleProgramTracks(count: 2)])
    }

    @Test func silentAndSurroundAreReportedHonestly() {
        #expect(VerifyAudioRules.findings(
            shape: shape(), referencedPaths: [],
            analysis: analysis(.silent), analyzeFailed: false) == [.silentAudio])
        #expect(VerifyAudioRules.findings(
            shape: shape(), referencedPaths: [],
            analysis: analysis(.multichannel, channelCount: 6),
            analyzeFailed: false) == [.surround(channels: 6)])
    }

    @Test func diagnosisConvenienceAccessors() {
        let healthy = AudioVerifyDiagnosis(findings: [], shape: shape(),
                                           balanceAnalysis: nil)
        #expect(healthy.isHealthy)
        #expect(healthy.persistedStatus == "ok")
        #expect(healthy.persistedNote == "")

        let damaged = AudioVerifyDiagnosis(
            findings: [.referenceMovie(referencedPaths: ["a"])],
            shape: shape(), balanceAnalysis: nil)
        #expect(!damaged.isHealthy)
        #expect(damaged.persistedStatus == "damaged")
        #expect(damaged.persistedNote == "Damaged audio — reference movie, media missing")
    }
}

// MARK: - Bit depth + probe-JSON decoding (pure)

@Suite("VerifyAudioProbe — shape decoding")
struct VerifyAudioShapeDecodingTests {

    @Test func bitDepthFromPCMCodecNames() {
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "pcm_s16le") == 16)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "pcm_s24be") == 24)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "pcm_f32le") == 32)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "pcm_u8") == 8)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "PCM_S16LE") == 16)
        // No guessing for lossy / non-numeric PCM variants.
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "aac") == nil)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "pcm_dvd") == nil)
        #expect(VerifyAudioRules.bitDepth(fromCodecName: "") == nil)
    }

    @Test func probeArgsKeepStderrSignal() {
        let args = VerifyAudioProbe.shapeArgs(input: "/x/clip.mov")
        // -v error would silence the dref marker lines — the reference-
        // movie detection signal. Pin its absence.
        #expect(!args.contains("-v"), "shapeArgs must not lower verbosity — dref markers ride default stderr")
        #expect(args.contains("-hide_banner"))
        #expect(args.suffix(3) == ["-of", "json", "/x/clip.mov"])
    }

    @Test func decodesFullShape() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264",
           "r_frame_rate":"30000/1001","duration":"63.500000"},
          {"index":1,"codec_type":"audio","codec_name":"pcm_s16le",
           "channels":2,"sample_rate":"48000","bits_per_raw_sample":"16",
           "duration":"63.500000"}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2",
                   "duration":"63.500000","size":"123456789"}}
        """
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.videoCodec == "h264")
        #expect(s.videoRFrameRate == "30000/1001")
        #expect(s.videoDurationSeconds == 63.5)
        #expect(s.audioStreams == 1)
        #expect(s.audioCodec == "pcm_s16le")
        #expect(s.audioChannels == 2)
        #expect(s.audioSampleRateHz == 48000)
        #expect(s.audioBitDepth == 16)
        #expect(s.audioDurationSeconds == 63.5)
        #expect(s.containerFormat == "mov,mp4,m4a,3gp,3g2,mj2")
        #expect(s.fileSizeBytes == 123_456_789)
    }

    @Test func bitDepthFallsBackToCodecNameWhenUnreported() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"audio","codec_name":"pcm_s24le",
                     "channels":2,"duration":"5"}],
         "format":{"format_name":"mov","duration":"5","size":"1000"}}
        """
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.audioBitDepth == 24)
    }

    @Test func noAudioDecodesFineHere() throws {
        // Unlike the balance probe, a file with NO audio is a valid
        // shape — no-audio IS a finding, not an error.
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264"}],
         "format":{"format_name":"mp4","duration":"10","size":"5000"}}
        """
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.audioStreams == 0)
        #expect(s.audioCodec.isEmpty)
    }

    @Test func containerDurationFallbackIsVideoOnly() throws {
        // MXF/elementary shapes without per-stream durations: the VIDEO
        // side may borrow the container duration, but the AUDIO side
        // must stay 0 so the mismatch rule can't fire on a guess.
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"mpeg2video"},
          {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2}],
         "format":{"format_name":"mxf","duration":"120.0","size":"90000000"}}
        """
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.videoDurationSeconds == 120.0)
        #expect(s.audioDurationSeconds == 0)
        #expect(!VerifyAudioRules.hasDurationMismatch(
            audioSeconds: s.audioDurationSeconds,
            videoSeconds: s.videoDurationSeconds),
            "an unknown audio duration must never look like a mismatch")
    }

    @Test func garbageJSONThrowsProbeFailed() {
        #expect(throws: AudioVerifyProbeError.probeFailed(
            "ffprobe output was not readable JSON")) {
            _ = try VerifyAudioProbe.shape(fromProbeJSON: Data("not json".utf8))
        }
    }
}
