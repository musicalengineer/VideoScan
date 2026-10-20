// AudioFingerprintBackfillSilenceTests.swift
// "Fingerprint Sound…" and silence (2026-10-20): Verify Catalog tier 3 said
// "heard nothing (silent)" for 8 AVCHD clips with real sound (a print with no
// landmark is not silence) and for 6 files whose decode gave 0 samples
// (version-2 "no sound" stamps). Stamp rule 4: a zero-landmark stamp is
// written only for MEASURED silence; "heard too little" is listed, never
// stamped; old stamps that are not evidence are redone.
//
//   LOGIC  — heard too little is never stamped; measured silence is; old
//            zero-landmark stamps are re-decided; a zero-landmark sidecar row
//            is never shared; a 0-sample decode stays a failed decode.
//   MEDIA  — real ffmpeg + the real job: short AC-3 .mts tone, AAC .mov
//            tones, DV digital silence, a TS naming AC-3 with no sound.
//   SCALE / ISOLATION / SENSOR for the job stay in
//            AudioFingerprintBackfillTests.swift (unchanged paths); the
//            verdict sensor at 100k rows is SoundPrintSilentVerdictTests.
//
// Suites (filter by SUITE): AudioFingerprintBackfillSilenceTests ·
//   AudioFingerprintBackfillSilenceMediaTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Harness (the AudioFingerprintBackfillTests shape, file-private here)

@MainActor
private func runSilenceJob(_ model: VideoScanModel, pass: AudioFingerprintBackfillJob.Pass?,
                           configure: (AudioFingerprintBackfillJob) -> Void = { _ in }) async -> AudioFingerprintBackfillJob {
    let job = AudioFingerprintBackfillJob(model: model)
    job.volumeOnline = { _ in true }
    job.tickMilliseconds = 20
    job.passForTesting = pass
    // A stubbed pass never runs ffmpeg; any executable satisfies the preflight.
    job.ffmpegPath = "/bin/ls"
    configure(job)
    job.start()
    await job.task?.value
    return job
}

/// A printable stub print (120 landmarks).
private let printablePass: AudioFingerprintBackfillJob.Pass = { item in
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: item.durationSeconds,
                     hashes: (0..<120).map { UInt32($0) &* 2_654_435_761 }, times: (0..<120).map { UInt32($0 * 2) })
}

private actor SilencePassLog {
    private(set) var paths: [String] = []
    func append(_ p: String) { paths.append(p) }
}

@MainActor
private extension ShowAgainSandbox {
    /// A Video+Audio record with a sampled digest, a duration and an audio codec.
    func clip(_ name: String, seconds: Double = 60, codec: String, fullHash: String? = nil) throws -> VideoRecord {
        let r = try record(name, bytes: 2_000, onDisk: true, stage: .none)
        r.contentHash = "v1:" + name
        if let fullHash {
            r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: String(repeating: fullHash, count: 64), byteCount: 2_000)
        }
        r.durationSeconds = seconds
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioCodec = codec
        return r
    }

    func soundStore() throws -> AudioFingerprintStore { try AudioFingerprintStore(directory: catalogDir) }
}

// MARK: - Logic

/// A print with no landmark, a (gain-relative) bitmap and the ABSOLUTE
/// measurement `loud` (seconds above −60 dBFS at gain 1; nil = a blob).
private func zeroLandmarkPrint(active: [Bool], seconds: Double, loud: Int?) -> AudioFingerprint {
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds,
                     activeSeconds: active, hashes: [], times: [], secondsAboveSilenceCeiling: loud)
}

/// Group B of 10/20 — 00085.MTS: 1.504 s of AC-3 that peaks at −0.1 dB,
/// both seconds audible, no landmark.
private let heardTooLittlePass: AudioFingerprintBackfillJob.Pass = { _ in
    zeroLandmarkPrint(active: [true, true], seconds: 1.504, loud: 2)
}

/// Group A of 10/20 — an iMovie theme clip: decoded, every second zero.
private let measuredSilencePass: AudioFingerprintBackfillJob.Pass = { _ in
    zeroLandmarkPrint(active: [false, false, false], seconds: 3, loud: 0)
}

/// QA P1: −92 dBFS dither — the ×100 gain lifts it into the bitmap, yet
/// no second peaks above −60 dBFS. Measured silence.
private let ditherPass: AudioFingerprintBackfillJob.Pass = { _ in
    zeroLandmarkPrint(active: [true, true, true], seconds: 3, loud: 0)
}

@Suite("Fingerprint sound — silence is measured, never inferred (2026-10-20)", .serialized)
@MainActor
struct AudioFingerprintBackfillSilenceTests {

    @Test("RED 2026-10-20 (group B): a print that HEARD sound but made no landmark is never stamped — listed 'heard too little', logged, kept out of the sidecar, retried next run")
    func heardTooLittleIsNeverStampedSilent() async throws {
        let sb = try ShowAgainSandbox.make("afb_heard"); defer { sb.cleanup() }
        let clip = try sb.clip("00085.MTS", seconds: 1.5, codec: "ac3")
        let job = await runSilenceJob(sb.model, pass: heardTooLittlePass)
        #expect(job.totals[.heardTooLittle] == 1 && job.totals[.fingerprinted] == 0, Comment(rawValue: job.totals.line))
        #expect(clip.audioFingerprint == nil, "no stamp — nothing may read this as silent")
        let why = job.problems.first { $0.path == clip.fullPath }?.detail ?? "(no problem row)"
        #expect(why.contains("too little to fingerprint") && why.contains("not silent") && why.contains("2 audible seconds"), Comment(rawValue: why))
        #expect(job.problems.first { $0.path == clip.fullPath }?.result == .heardTooLittle)
        #expect(sb.catalogLogText().contains("HEARD TOO LITTLE \(clip.fullPath)"))
        #expect(try sb.soundStore().count() == 0, "not kept: a later 'shared' must not stamp it either")
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 1, "retried next run")
        #expect(!AudioFingerprintBackfillResult.heardTooLittle.isStamped)
        #expect(job.totals.line.contains("1 heard sound, too little to fingerprint"), Comment(rawValue: job.totals.line))
    }

    @Test("group A: a print that decoded and MEASURED every second quiet is stamped (rule 4, 0 landmarks) and reads as measured silence; it is not retried")
    func measuredSilenceIsStamped() async throws {
        let sb = try ShowAgainSandbox.make("afb_measured"); defer { sb.cleanup() }
        let theme = try sb.clip("Fog 02.dv", seconds: 3, codec: "pcm_s16le")
        let job = await runSilenceJob(sb.model, pass: measuredSilencePass)
        #expect(job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        let stamp = try #require(theme.audioFingerprint)
        #expect(stamp.outcome == .fingerprinted && stamp.landmarks == 0 && stamp.engineVersion == 4)
        #expect(stamp.hearing(headerHasAudio: true) == .measuredSilence)
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 0)
        // QA P3b: a measured-silent print is never "N s of sound".
        let detail = job.sample.first { $0.path == theme.fullPath }?.detail ?? "(no sample row)"
        #expect(detail == "3 s, measured silent", Comment(rawValue: detail))
    }

    @Test("QA P1: dither the normalising gain lifts into the bitmap is MEASURED silence (stamped, not 'heard too little', not retried nightly)")
    func ditherIsMeasuredSilenceNotARetryLoop() async throws {
        let sb = try ShowAgainSandbox.make("afb_dither"); defer { sb.cleanup() }
        let render = try sb.clip("Donna_render.mov", seconds: 3, codec: "aac")
        let job = await runSilenceJob(sb.model, pass: ditherPass)
        #expect(job.totals[.heardTooLittle] == 0 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(render.audioFingerprint?.hearing(headerHasAudio: true) == .measuredSilence)
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 0, "not re-planned")
    }

    @Test("a print with no loudness measurement (a stub that skipped compute) is not judged: a named failure, never a stamp")
    func unmeasuredPrintIsNotJudged() async throws {
        let sb = try ShowAgainSandbox.make("afb_unmeasured"); defer { sb.cleanup() }
        let clip = try sb.clip("x.mov", seconds: 3, codec: "aac")
        let job = await runSilenceJob(sb.model, pass: { _ in zeroLandmarkPrint(active: [false, false, false], seconds: 3, loud: nil) })
        #expect(job.totals[.failed] == 1 && clip.audioFingerprint == nil, Comment(rawValue: job.totals.line))
        #expect(job.problems.first?.detail == AudioFingerprintBackfillJob.notMeasuredWords)
    }

    @Test("EXISTING STAMPS: a pre-4 zero-landmark print is re-printed — heard sound → stays unstamped-as-evidence (old stamp is not evidence), measured silence → replaced by a rule-4 stamp; a pre-4 print with landmarks stands")
    func existingZeroLandmarkStampsAreRedecided() async throws {
        let sb = try ShowAgainSandbox.make("afb_reprint"); defer { sb.cleanup() }
        func v2(_ digest: String, landmarks: Int) -> AudioFingerprintStamp {
            AudioFingerprintStamp(engineVersion: 2, contentDigest: digest, sizeBytes: 2_000, outcome: .fingerprinted,
                                  analyzedSeconds: 1.5, complete: true, landmarks: landmarks, bytes: 40 + 8 * landmarks)
        }
        let avchd = try sb.clip("a_00085.MTS", codec: "ac3"); avchd.audioFingerprint = v2("v1:a_00085.MTS", landmarks: 0)
        let theme = try sb.clip("b_Fog.dv", codec: "pcm_s16le"); theme.audioFingerprint = v2("v1:b_Fog.dv", landmarks: 0)
        let printed = try sb.clip("c_printed.mov", codec: "aac"); printed.audioFingerprint = v2("v1:c_printed.mov", landmarks: 30)
        let planned = sb.model.audioFingerprintBackfillPlan().lanes.first?.items.map(\.filename) ?? []
        #expect(planned == ["a_00085.MTS", "b_Fog.dv"], Comment(rawValue: "\(planned)"))
        let job = await runSilenceJob(sb.model, pass: { item in
            item.filename == "a_00085.MTS" ? try await heardTooLittlePass(item) : try await measuredSilencePass(item)
        })
        #expect(job.totals[.heardTooLittle] == 1 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(avchd.audioFingerprint?.engineVersion == 2, "not overwritten by a verdict it cannot support")
        #expect(avchd.audioFingerprint?.hearing(headerHasAudio: true) == .notEvidence, "and never read as silent")
        #expect(theme.audioFingerprint?.engineVersion == 4 && theme.audioFingerprint?.hearing(headerHasAudio: true) == .measuredSilence)
        #expect(printed.audioFingerprint?.engineVersion == 2, "a v2 print with landmarks is not redone")
    }

    @Test("a sidecar row with NO landmark (possibly pre-rule-4) is never shared to a copy — the copy is decoded and decided again")
    func zeroLandmarkSidecarRowIsNotShared() async throws {
        let sb = try ShowAgainSandbox.make("afb_noshare"); defer { sb.cleanup() }
        let copy = try sb.clip("copy.mts", codec: "ac3", fullHash: "e")
        let key = AudioFingerprintStore.Key(contentDigest: AudioFingerprintStamp.fullDigest(String(repeating: "e", count: 64)), sizeBytes: 2_000)
        try sb.soundStore().put([.init(key: key, fingerprint: zeroLandmarkPrint(active: [], seconds: 1.5, loud: nil), sourcePath: "/elsewhere/original.mts")])
        let calls = SilencePassLog()
        let job = await runSilenceJob(sb.model, pass: { item in await calls.append(item.path); return try await printablePass(item) })
        #expect(await calls.paths == [copy.fullPath], "decoded, not stamped 'shared' from a zero-landmark row")
        #expect(job.totals[.shared] == 0 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(copy.audioFingerprint?.landmarks == 120)
    }

    @Test("group C: a decode that gives 0 samples on an audio header stays a FAILED decode; the old version-2 'no sound' stamp is left alone and reads as not evidence")
    func zeroSampleDecodeIsCouldNotCheck() async throws {
        let sb = try ShowAgainSandbox.make("afb_zero"); defer { sb.cleanup() }
        let preview = try sb.clip("IMG_0164.MOV", seconds: 8.4, codec: "aac")
        preview.audioFingerprint = AudioFingerprintStamp(engineVersion: 2, contentDigest: "v1:IMG_0164.MOV", sizeBytes: 2_000,
                                                         outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
        let job = await runSilenceJob(sb.model, pass: { _ in throw AudioPCMDecoder.Failure.noAudioStream })
        #expect(job.totals[.failed] == 1 && job.totals[.noAudio] == 0, Comment(rawValue: job.totals.line))
        #expect(job.problems.first?.detail.contains("could not decode the sound (0 samples)") == true)
        #expect(preview.audioFingerprint?.engineVersion == 2)
        #expect(preview.audioFingerprint?.hearing(headerHasAudio: true) == .notEvidence)
        #expect(CatalogFileFacts.stream(preview).value == "Video+Audio", "the Stream column never says 'silent' for it")
    }
}

@Suite("Fingerprint sound — silence media matrix (real ffmpeg, 2026-10-20)", .serialized)
@MainActor
struct AudioFingerprintBackfillSilenceMediaTests {

    private static let picture = ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=25"]
    private static let h264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]

    @Test("short AC-3 .mts with a tone → heard too little, NOT stamped; AAC .mov with tones → fingerprinted; DV digital silence → measured silence; a TS naming AC-3 with no decodable sound → failed (0 samples); media unchanged",
          .timeLimit(.minutes(2)))
    func silenceMatrix() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("afb_silence")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        func add(_ name: String, codec: String, seconds: Double) throws -> VideoRecord {
            let path = dir.appendingPathComponent(name).path
            let r = VideoRecord()
            r.fullPath = path; r.filename = name; r.directory = dir.path
            r.sizeBytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            r.contentHash = "v1:" + name
            r.durationSeconds = seconds
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.audioCodec = codec
            model.records.append(r)
            return r
        }
        try CleanupTestMedia.runFFmpeg(Self.picture + ["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000", "-t", "0.3",
                                                       "-map", "0:v", "-map", "1:a"] + Self.h264 + ["-c:a", "ac3", "-ac", "2", "-f", "mpegts"],
                                       output: dir.appendingPathComponent("test_short_tone_ac3.mts").path)
        try CleanupTestMedia.runFFmpeg(Self.picture + ["-f", "lavfi", "-i",
                                                       "aevalsrc=0.4*sin(2*PI*(400+300*floor(4*t))*t)+0.2*sin(2*PI*(1500-200*floor(3*t))*t):s=48000",
                                                       "-t", "4", "-map", "0:v", "-map", "1:a"] + Self.h264 + ["-c:a", "aac", "-ac", "1"],
                                       output: dir.appendingPathComponent("test_tone_aac.mov").path)
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                                        "-t", "3", "-map", "0:v", "-map", "1:a", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le", "-f", "dv"],
                                       output: dir.appendingPathComponent("test_digital_silence.dv").path)
        let sourcePath = dir.appendingPathComponent("test_tone_ac3_source.mts").path
        try CleanupTestMedia.runFFmpeg(Self.picture + ["-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(400+300*floor(4*t))*t):s=48000", "-t", "2",
                                                       "-map", "0:v", "-map", "1:a"] + Self.h264 + ["-c:a", "ac3", "-ac", "2", "-f", "mpegts"],
                                       output: sourcePath)
        // Group C's shape: the PMT names AC-3; every audio packet (PID 0x101) is gone.
        let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        var stripped = Data(capacity: source.count)
        var offset = 0
        while offset + 188 <= source.count {
            let pid = (Int(source[offset + 1] & 0x1F) << 8) | Int(source[offset + 2])
            if pid != 0x101 { stripped.append(source[offset..<(offset + 188)]) }
            offset += 188
        }
        #expect(stripped.count < source.count, "the audio packets were found and removed")
        try stripped.write(to: dir.appendingPathComponent("test_undecodable_sound.mts"))

        let short = try add("test_short_tone_ac3.mts", codec: "ac3", seconds: 0.3)
        let aac = try add("test_tone_aac.mov", codec: "aac", seconds: 4)
        let silence = try add("test_digital_silence.dv", codec: "pcm_s16le", seconds: 3)
        let undecodable = try add("test_undecodable_sound.mts", codec: "ac3", seconds: 2)
        let before = try model.records.map { try MediaFingerprint.of($0.fullPath) }

        let job = await runSilenceJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath }
        let words = job.problems.map { "\($0.filename): \($0.detail)" }.joined(separator: " | ")
        #expect(job.totals[.heardTooLittle] == 1 && job.totals[.fingerprinted] == 2 && job.totals[.failed] == 1,
                Comment(rawValue: job.totals.line + " — " + words))
        #expect(short.audioFingerprint == nil, "a 0.3 s tone was heard: never a silent stamp")
        #expect(job.problems.first { $0.path == short.fullPath }?.result == .heardTooLittle, Comment(rawValue: words))
        #expect(aac.audioFingerprint?.hearing(headerHasAudio: true) == .heardSound)
        #expect(silence.audioFingerprint?.hearing(headerHasAudio: true) == .measuredSilence)
        #expect(undecodable.audioFingerprint == nil)
        #expect(job.problems.first { $0.path == undecodable.fullPath }?.detail.contains("0 samples") == true, Comment(rawValue: words))
        #expect(try model.records.map { try MediaFingerprint.of($0.fullPath) } == before, "no media file changed")
    }
}
