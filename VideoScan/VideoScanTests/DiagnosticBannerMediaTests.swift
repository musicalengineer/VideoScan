// DiagnosticBannerMediaTests.swift
// The add-sound repair and the "No sound" banner against REAL ffmpeg
// (Rick 2026-10-10). Pure logic: DiagnosticBannerTests.swift.
//
//   MEDIA   the add-sound pass through the REAL Repair engine on synthetic
//           `test_*` fixtures in a temp dir (never family media): m2v + ac3,
//           mp4/h264 + wav, mov/prores + wav, mxf/mpeg2 + wav. The picture
//           and sound files' SHA-256 never change; one new file, two streams.
//   SENSOR  the real Verify job on a 2009 .m2v with a same-length .ac3 in
//           its folder ends with the banner naming that file as a measured
//           match, and the Repair prefill it carries runs end to end.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Through the real engine (media matrix)

@Suite("Repair add sound — real engine, media matrix", .serialized)
struct MediaRepairAddSoundEngineTests {

    typealias R = RepairFixtures

    enum Picture: String, CaseIterable, Sendable, CustomStringConvertible {
        case m2vMPEG2, mp4H264, movProRes, mxfMPEG2
        var description: String { rawValue }

        var file: String {
            switch self {
            case .m2vMPEG2: return "test_Thanksgiving2009-DVD.m2v"
            case .mp4H264: return "test_pic.mp4"
            case .movProRes: return "test_pic.mov"
            case .mxfMPEG2: return "test_pic.mxf"
            }
        }

        var args: [String] {
            let src = ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25"]
            switch self {
            case .m2vMPEG2: return src + ["-c:v", "mpeg2video", "-an", "-f", "mpeg2video"]
            case .mp4H264: return src + ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-an"]
            case .movProRes: return src + ["-c:v", "prores_ks", "-profile:v", "0", "-an"]
            case .mxfMPEG2:
                return ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x576:rate=25",
                        "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "5M", "-an"]
            }
        }

        /// The DVD's own sound is AC-3; the rest pair with a PCM .wav.
        var sound: (file: String, args: [String]) {
            let sine = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-ac", "2"]
            return self == .m2vMPEG2
                ? ("test_Thanksgiving2009-Blu-ray.ac3", sine + ["-c:a", "ac3"])
                : ("test_snd.wav", sine + ["-c:a", "pcm_s16le"])
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: Picture.allCases)
    func addsTheSoundIntoANewFileAndTouchesNothingElse(_ kind: Picture) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try R.makeDir("addsound_\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture = dir.appendingPathComponent(kind.file)
        try R.ffmpeg(kind.args + [picture.path])
        let sound = dir.appendingPathComponent(kind.sound.file)
        try R.ffmpeg(kind.sound.args + [sound.path])
        let before = (try R.sha256(picture), try R.sha256(sound))
        let listingBefore = R.listing(dir)

        let recipe = MediaRepairRecipe(fixes: [.addSound], balance: nil, soundFile: sound.path)
        let output = R.repairedURL(for: picture, ext: "mov")
        var req = MediaRepairRequest(sourcePath: picture.path, sourceSizeBytes: R.size(picture), sourceDurationSeconds: 2,
                                     output: output, recipe: recipe, outputProtectionNote: nil, archiveCheck: nil)
        req.addedSoundSizeBytes = R.size(sound)
        let outcome = await R.run(req)

        guard case .repaired(let url, let proof) = outcome else { Issue.record("\(kind): \(outcome)"); return }
        #expect(url == output)
        #expect(proof.contains("sound added, nothing re-encoded"), "\(proof)")
        // One picture, one sound. (From an MXF the QuickTime muxer also
        // writes the source's timecode as a data track — Combine does too.)
        let streams = try await MediaRepairProbe.summary(path: url.path, control: nil).streams.map(\.codecType)
        #expect(streams.filter { $0 == "video" }.count == 1 && streams.filter { $0 == "audio" }.count == 1,
                "\(kind): \(streams)")
        #expect(streams.allSatisfy { ["video", "audio", "data"].contains($0) }, "\(kind): \(streams)")
        #expect(try R.sha256(picture) == before.0, "the picture file is never changed")
        #expect(try R.sha256(sound) == before.1, "the sound file is never changed")
        #expect(R.listing(dir) == (listingBefore + [output.lastPathComponent]).sorted(), "one run, one new file")
        #expect(!R.hasPartialOrKept(dir))
    }
}

extension MediaRepairAddSoundEngineTests {

    /// ffprobe prints packet fields in ITS order (stream_index, duration,
    /// size), whatever order -show_entries names them in. Pinned on real
    /// output: the census's bytes are the packets' sizes.
    @Test(.timeLimit(.minutes(1)))
    func theCensusReadsFfprobesFieldOrder() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try R.makeDir("census_order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("test_census.mov")
        try R.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
                      "-c:v", "prores_ks", "-profile:v", "0", clip.path])
        let tallies = try await MediaRepairProbe.streamTallies(path: clip.path, control: nil)
        let video = try #require(tallies.first { $0.codecType == "video" })
        #expect(video.packets == 25)
        #expect(abs(video.seconds - 1.0) < 0.01, "25 frames of 1/25 s: \(video.seconds) s")
        // The payload, not the tick count: ProRes 422 Proxy at 320x240 is
        // kilobytes a frame, far more than 25 frames' worth of ticks.
        // The QuickTime time base is 1/12800 s: swapped, "bytes" would read
        // 25 × 512 = 12,800.
        #expect(video.bytes > 25 * 1_000 && video.bytes < R.size(clip), "\(video.bytes) bytes")
    }
}

// MARK: - SENSOR: Verify → banner → Repair, end to end

@Suite("Diagnostic banner — Verify to Repair sensor", .serialized)
@MainActor
struct DiagnosticBannerVerifySensorTests {

    typealias R = RepairFixtures

    /// Rick's case: a 2009 DVD .m2v (picture only, no length in its header)
    /// beside its .ac3. The full Verify measures the picture, so the job's
    /// banner names the sound file as a measured match, and the prefill it
    /// carries runs through the Repair engine to a new file with sound.
    @Test(.timeLimit(.minutes(3)))
    func fullVerifyOfTheM2vEndsWithTheBannerAndItsRepairRuns() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let sb = try MasterArchiveTestSupport.makeSandbox("diagbanner_sensor")
        defer { sb.cleanup() }
        let dir = try R.makeDir("diagbanner_sensor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture = dir.appendingPathComponent("test_Thanksgiving2009-DVD.m2v")
        try R.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=30000/1001",
                      "-c:v", "mpeg2video", "-an", "-f", "mpeg2video", picture.path])
        let sound = dir.appendingPathComponent("test_Thanksgiving2009-Blu-ray.ac3")
        try R.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-ac", "2",
                      "-c:a", "ac3", sound.path])

        let model = MasterArchiveTestSupport.makeModel(sb)
        let pic = Self.record(picture, stream: .videoOnly, seconds: 0)
        let snd = Self.record(sound, stream: .audioOnly, seconds: 2.0)
        model.records = [pic, snd]

        let job = CheckMediaJob(records: [pic], tier: .full, model: model, center: nil)
        job.start()
        await job.task?.value

        #expect(NoSoundSummary(job.items).chipText == "1 of 1 has no sound")
        let banner = try #require(job.items.first?.banner)
        #expect(banner.headline == "No sound")
        #expect(banner.nextStep.hasPrefix("Its sound is probably test_Thanksgiving2009-Blu-ray.ac3 (same folder"), "\(banner.nextStep)")
        #expect(banner.nextStep.hasSuffix("same length). Use Repair\u{2026} to add it."), "\(banner.nextStep)")
        guard case .repair(let prefill)? = banner.action, let match = prefill.soundSource?.measured else {
            Issue.record("the banner must carry the measured candidate: \(String(describing: banner.action))"); return
        }
        #expect(match.audio.id == snd.id)

        // What the Repair sheet does with it: the plan ticks Add sound…
        let card = try #require(pic.mediaReportCard)
        let offers = MediaRepairPlan.allOffers(for: card, sound: MediaRepairSoundFacts(), hasPicture: true, hasSound: false,
                                               soundSource: prefill.soundSource)
        let sel = MediaRepairSelection(offers: offers)
        #expect(sel.chosen == [.addSound], "\(sel.chosen)")
        // …and the center's request runs it (the sheet's Repair Now).
        let center = MediaFileOperationsCenter()
        let output = R.repairedURL(for: picture, ext: "mov")
        let req = center.repairRequest(record: pic, fixes: Array(sel.chosen), output: output, model: model,
                                       addingSound: match.audio)
        #expect(req.recipe.addedSoundPath == sound.path)
        #expect(req.addedSoundSizeBytes == snd.sizeBytes)
        let before = try R.sha256(picture)
        guard case .repaired = await R.run(req) else { Issue.record("add sound did not publish"); return }
        #expect(try R.sha256(picture) == before)
        let streams = try await MediaRepairProbe.summary(path: output.path, control: nil).streams.map(\.codecType)
        #expect(streams == ["video", "audio"])
    }

    static func record(_ url: URL, stream: StreamType, seconds: Double) -> VideoRecord {
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.streamTypeRaw = stream.rawValue
        r.durationSeconds = seconds
        r.sizeBytes = RepairFixtures.size(url)
        return r
    }
}
