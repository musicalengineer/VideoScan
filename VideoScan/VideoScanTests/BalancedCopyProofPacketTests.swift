// BalancedCopyProofPacketTests.swift
// Codex re-review #301 (2026-11-17) of the hardened proof: three more ways
// to a false PROVEN, all from comparing a stream by its TOTALS — one hash
// over all its payload bytes, a packet count, a start and a duration.
//   1. picture packets re-timed INSIDE the recording, totals equal;
//   2. a display rotation added to the copy;
//   3. the same bytes cut into different packets.
// Each is rebuilt here with real ffmpeg media (test patterns and tones),
// was seen RED on dd4042d33, and first shows by another road that the
// damaged copy agrees with the original in everything that was compared.
// On the engine rebuilt 2026-11-17 the first is refused by the decoded
// frames' times, the second by the display configuration, the third by
// the packet pass (captions are not decoded; their packets are the proof).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Balanced copy proof — Codex #301: packet by packet", .serialized)
struct BalancedCopyProofPacketTests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    /// "stream_index,pts,duration,size" of every packet of one stream.
    private func packetTable(of path: String, stream: String) async -> String {
        await Lab.output(ToolLocator.ffprobePath,
                         ["-v", "error", "-select_streams", stream, "-show_entries", "packet=pts,duration,size",
                          "-of", "csv=p=0", path])
    }

    // MARK: 1 — timing inside the recording

    @Test("#301-1: one picture shown 40 ms late INSIDE the recording — same packets, count, start, duration and rates — is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func internalRetimeWithEqualTotalsIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("retime")
        defer { try? fm.removeItem(at: dir) }
        let plain = try Lab.make("test_plain.mov", in: dir)
        // The original is itself variable-rate: one 80 ms picture after frame 20.
        let original = try Media.derive("test_vfr", from: plain,
                                        ["-map", "0", "-c", "copy", "-bsf:v", "setts=ts=N*512+512*gt(N\\,20)"])
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame,
                "the job's own copy of a variable-rate original is a good pair")
        // The copy: the 80 ms picture comes after frame 30 instead.
        let retimed = try Media.derive("retimed_balanced", from: balanced,
                                       ["-map", "0", "-c", "copy", "-bsf:v", "setts=ts=N*512+512*gt(N\\,30)"])

        // By another road: every total the proof used to compare is equal …
        for entry in ["start_time", "duration", "r_frame_rate", "avg_frame_rate", "nb_frames", "width", "pix_fmt"] {
            let value = await Lab.entry(entry, of: original, stream: "v:0")
            #expect(!value.isEmpty)
            #expect(await Lab.entry(entry, of: retimed, stream: "v:0") == value, "\(entry)")
        }
        let payload = await Lab.packetHash(of: original, stream: "v:0")
        #expect(payload.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: retimed, stream: "v:0") == payload)
        // … and ten pictures are shown at another time.
        let times = await packetTable(of: original, stream: "v:0")
        #expect(times.split(separator: "\n").count == 50)
        #expect(await packetTable(of: retimed, stream: "v:0") != times)

        let outcome = await Proof.measure(original: original, balanced: retimed)
        #expect(!outcome.playsTheSame, "pictures moved against the sound and the copy was still the same: \(outcome)")
        guard case .notProven(.pictureDiffers(0, let what)) = outcome else {
            Issue.record("expected the frames' times to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("its frames are not the original's, each at the original's time"), "\(what)")
    }

    // MARK: 2 — display rotation

    @Test("#301-2: a copy that plays upside down — a 180° display matrix, the same packets — is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func changedDisplayMatrixIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("rotate")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_upright.mov", in: dir)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame)
        let rotated = dir.appendingPathComponent("rotated_balanced.mov").path
        try BalanceAudioTestMedia.runFFmpeg(["-display_rotation:v:0", "180", "-i", balanced, "-map", "0", "-c", "copy"],
                                            output: rotated)

        let payload = await Lab.packetHash(of: original, stream: "v:0")
        #expect(payload.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: rotated, stream: "v:0") == payload)
        for entry in ["width", "height", "sample_aspect_ratio", "display_aspect_ratio", "pix_fmt", "duration"] {
            let value = await Lab.entry(entry, of: original, stream: "v:0")
            #expect(await Lab.entry(entry, of: rotated, stream: "v:0") == value, "\(entry)")
        }
        let matrix = await Lab.output(ToolLocator.ffprobePath,
                                      ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream_side_data=rotation",
                                       "-of", "default=nw=1:nk=1", rotated])
        #expect(matrix == "-180", "the copy carries a 180° display matrix: \(matrix)")

        let outcome = await Proof.measure(original: original, balanced: rotated)
        #expect(!outcome.playsTheSame, "a picture shown upside down was the same: \(outcome)")
        guard case .notProven(.pictureConfigurationDiffers(let what)) = outcome else {
            Issue.record("expected the display configuration to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("picture stream 0: side data none → [{") && what.contains("displaymatrix"), "\(what)")
    }

    // MARK: 3 — packet boundaries

    @Test("#301-3: captions cut differently — \"hello\"/\"world\" against \"hellow\"/\"orld\" — are never PROVEN: each file's text track is named as its own, not compared",
          .timeLimit(.minutes(2)))
    func repartitionedSubtitlePacketsAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("captions")
        defer { try? fm.removeItem(at: dir) }
        func captions(_ name: String, _ first: String, _ second: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try "1\n00:00:00,200 --> 00:00:00,900\n\(first)\n\n2\n00:00:01,100 --> 00:00:01,800\n\(second)\n"
                .write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let original = dir.appendingPathComponent("test_captioned.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
             "-f", "lavfi", "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2", "-i", try captions("good.srt", "hello", "world"),
             "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-c:s", "srt"],
            output: original)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame)
        let recut = try Media.derive("recut_balanced", from: balanced,
                                     ["-i", try captions("recut.srt", "hellow", "orld"),
                                      "-map", "0:v", "-map", "0:a", "-map", "1:s", "-c", "copy", "-c:s", "srt"])

        // By another road: one hash over all the caption bytes agrees, the cue times agree …
        let bytes = await Lab.packetHash(of: original, stream: "s:0")
        #expect(bytes.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: recut, stream: "s:0") == bytes)
        let cues = await Lab.output(ToolLocator.ffprobePath,
                                    ["-v", "error", "-select_streams", "s:0", "-show_entries", "packet=pts,duration",
                                     "-of", "csv=p=0", original])
        #expect(cues.split(separator: "\n").count == 2)
        #expect(await Lab.output(ToolLocator.ffprobePath,
                                 ["-v", "error", "-select_streams", "s:0", "-show_entries", "packet=pts,duration",
                                  "-of", "csv=p=0", recut]) == cues)
        // … and the two captions are not the original's two captions.
        let sizes = await packetTable(of: original, stream: "s:0")
        #expect(await packetTable(of: recut, stream: "s:0") != sizes)

        // RE-SCOPED 2026-11-17: the proof no longer claims anything about a text track. Two rounds of
        // review (#307, #308) kept finding one more thing about such tracks that was not compared, so
        // none of it is: the pair plays the same picture and sound, each file's text track is NAMED as
        // its own and NOT compared, and the pair is never "proven". A Trash offer for the original
        // must therefore say that it holds a text track.
        let outcome = await Proof.measure(original: original, balanced: recut)
        #expect(outcome.playsTheSame && !outcome.isProven, "\(outcome)")
        #expect(outcome.differences.filter { $0.kind == .track } == [
            Proof.Difference(kind: .track, heldBy: .original, what: "a text track (subrip) — not compared with the other file"),
            Proof.Difference(kind: .track, heldBy: .balancedCopy, what: "a text track (subrip) — not compared with the other file")
        ], "\(outcome.differences)")
    }
}
