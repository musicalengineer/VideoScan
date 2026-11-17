// BalancedCopyProofCoverageTests.swift
// The attacks Codex review #298 found covered "by inspection" but with no
// fixture of their own: a longer copy, reordered packets, a dropped
// subtitle or attachment, two picture streams the wrong way round, a
// sound-only pair, big-endian against little-endian PCM, a real mono and a
// real 5.1 original, and a same-size replacement of the copy mid-run.
// Real ffmpeg media throughout (tones and test patterns only). Each test
// first shows the job's OWN copy of that shape is judged as pinned here,
// then that the damaged one is refused.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Balanced copy proof — coverage of the attacks Codex listed", .serialized)
struct BalancedCopyProofCoverageTests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    private func streamsDiffer(_ outcome: Proof.Outcome) -> Bool {
        if case .notProven(.streamsDiffer) = outcome { return true }
        return false
    }
    private func notProven(_ outcome: Proof.Outcome) -> Bool {
        if case .notProven = outcome { return true }
        return false
    }

    @Test("A LONGER copy — the original's two seconds and one more — is not proven", .timeLimit(.minutes(2)))
    func longerCopyIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("longer")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_two.mov", in: dir)
        let longer = try Lab.make("test_three.mov", in: dir, seconds: 3)
        let longerBalanced = try await Media.balance(longer)

        let outcome = await Proof.measure(original: original, balanced: longerBalanced)
        #expect(Lab.timing(outcome) == "video stream 0 has 50 packets, the balanced copy 75", "\(outcome)")
        // And each with its own copy is a good pair.
        #expect(await Proof.measure(original: longer, balanced: longerBalanced).isProven)
    }

    @Test("REORDERED packets — the second half played first, nothing added or lost — are not proven",
          .timeLimit(.minutes(2)))
    func reorderedPacketsAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("reorder")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_order.mov", in: dir)
        let balanced = try await Media.balance(original)
        let head = try Media.derive("head", from: balanced, ["-t", "1", "-map", "0", "-c", "copy"])
        let tail = dir.appendingPathComponent("tail.mov").path
        try BalanceAudioTestMedia.runFFmpeg(["-ss", "1", "-i", balanced, "-map", "0", "-c", "copy"], output: tail)
        let list = dir.appendingPathComponent("list.txt")
        try "file '\(tail)'\nfile '\(head)'\n".write(to: list, atomically: true, encoding: .utf8)
        let reordered = dir.appendingPathComponent("reordered_balanced.mov").path
        try BalanceAudioTestMedia.runFFmpeg(["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy"],
                                            output: reordered)
        let outcome = await Proof.measure(original: original, balanced: reordered)
        #expect(notProven(outcome), "expected not proven, got \(outcome)")
    }

    @Test("A dropped SUBTITLE stream is not proven; the job's own copy, subtitles carried, is", .timeLimit(.minutes(2)))
    func droppedSubtitleIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("subtitle")
        defer { try? fm.removeItem(at: dir) }
        let captions = dir.appendingPathComponent("captions.srt")
        try "1\n00:00:00,200 --> 00:00:00,900\nhello\n\n2\n00:00:01,100 --> 00:00:01,800\nworld\n"
            .write(to: captions, atomically: true, encoding: .utf8)
        let original = dir.appendingPathComponent("test_subtitled.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
             "-f", "lavfi", "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2", "-i", captions.path,
             "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-c:s", "srt"],
            output: original)
        let balanced = try await Media.balance(original)

        guard case .proven(let evidence) = await Proof.measure(original: original, balanced: balanced) else {
            Issue.record("the job carries the subtitles; its copy must be proven")
            return
        }
        #expect(evidence.carried.map(\.kind) == ["video", "subtitle"])
        #expect(evidence.carried.map(\.packets) == [50, 2])

        let dropped = try Media.derive("no_subtitle_balanced", from: balanced, ["-map", "0:v", "-map", "0:a", "-c", "copy"])
        let outcome = await Proof.measure(original: original, balanced: dropped)
        #expect(streamsDiffer(outcome), "\(outcome)")
    }

    @Test("A dropped ATTACHMENT is not proven; an attachment carried is COULD NOT CHECK (it has no packets to hash)",
          .timeLimit(.minutes(2)))
    func droppedAttachmentIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("attachment")
        defer { try? fm.removeItem(at: dir) }
        let note = dir.appendingPathComponent("note.txt")
        try "a note kept with the tape\n".write(to: note, atomically: true, encoding: .utf8)
        let original = try Lab.make(
            "test_attached.mkv", in: dir, video: ["-c:v", "ffv1"],
            extra: ["-attach", note.path, "-metadata:s:t", "mimetype=text/plain"])
        let balanced = try await Media.balance(original)
        #expect(await Lab.entry("codec_type", of: balanced, stream: "t:0") == "attachment", "the job carries it")

        let dropped = try Media.derive("no_attachment_balanced", from: balanced, ["-map", "0:v", "-map", "0:a", "-c", "copy"])
        let outcome = await Proof.measure(original: original, balanced: dropped)
        #expect(streamsDiffer(outcome), "\(outcome)")
        // PIN: carried faithfully it still cannot be vouched for — fail closed.
        let carried = await Proof.measure(original: original, balanced: balanced)
        #expect(Lab.reason(carried) == "attachment stream 2 gave no packets to compare", "\(carried)")
    }

    @Test("TWO picture streams the wrong way round are not proven; in the original's order they are",
          .timeLimit(.minutes(2)))
    func reorderedPictureStreamsAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("twovideo")
        defer { try? fm.removeItem(at: dir) }
        let original = dir.appendingPathComponent("test_two_pictures.mov").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
             "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=25",
             "-f", "lavfi", "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2",
             "-map", "0:v", "-map", "1:v", "-map", "2:a", "-c:v", "prores_ks", "-profile:v", "0",
             "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le"],
            output: original)
        let balanced = try await Media.balance(original)
        guard case .proven(let evidence) = await Proof.measure(original: original, balanced: balanced) else {
            Issue.record("two picture streams in order must be proven")
            return
        }
        #expect(evidence.carried.map(\.kind) == ["video", "video"])
        #expect(evidence.carried[0].packetSHA256 != evidence.carried[1].packetSHA256)

        let swapped = try Media.derive("swapped_balanced", from: balanced,
                                       ["-map", "0:1", "-map", "0:0", "-map", "0:2", "-c", "copy", "-write_tmcd", "0"])
        let outcome = await Proof.measure(original: original, balanced: swapped)
        guard case .notProven(.carriedStreamDiffers(let kind, let index, _, _)) = outcome else {
            Issue.record("expected the first picture stream to be refused, got \(outcome)")
            return
        }
        #expect(kind == "video" && index == 0)
    }

    @Test("PIN: a sound-only PCM pair (WAV) is PROVEN — everything the original has is its one channel",
          .timeLimit(.minutes(2)))
    func soundOnlyPairIsProven() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("wav")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_sound_only.wav", in: dir, video: nil)
        let balanced = try await Media.balance(original)
        #expect(await Lab.entry("channel_layout", of: balanced, stream: "a:0") == "unknown",
                "WAV states no layout for plain stereo — the measured case the layout rule allows")

        guard case .proven(let evidence) = await Proof.measure(original: original, balanced: balanced) else {
            Issue.record("a sound-only pair holds everything the original has")
            return
        }
        #expect(evidence.carried.isEmpty && !evidence.gainedTimecodeTrack)
        #expect(evidence.soundSamples == 96_000)
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
        // Not proven by having nothing to compare: a different tone is refused.
        let other = try Lab.make("test_other.wav", in: dir, video: nil, channels: "0.4*sin(660*2*PI*t)|0")
        let otherBalanced = try await Media.balance(other)
        guard case .notProven(.soundDiffers) = await Proof.measure(original: original, balanced: otherBalanced) else {
            Issue.record("another recording's copy must be refused")
            return
        }
    }

    @Test("BIG-endian original, LITTLE-endian copy: not proven (the codec changed); the job's big-endian copy is",
          .timeLimit(.minutes(2)))
    func bigEndianOriginalLittleEndianCopy() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("endian")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_big_endian.mov", in: dir, audio: ["-c:a", "pcm_s16be"])
        let balanced = try await Media.balance(original)
        #expect(await Lab.entry("codec_name", of: balanced, stream: "a:0") == "pcm_s16be")
        #expect(await Proof.measure(original: original, balanced: balanced).isProven)

        let little = try Media.derive("little_balanced", from: balanced, ["-map", "0", "-c", "copy", "-c:a", "pcm_s16le"])
        let samples = await Lab.channelHash(of: original, channel: 0)
        #expect(samples.hasPrefix("SHA256="))
        #expect(await Lab.channelHash(of: little, channel: 0) == samples,
                "the samples are the same; only their byte order on disk differs")
        #expect(await Proof.measure(original: original, balanced: little)
                == .notProven(.soundFormatChanged("codec pcm_s16be → pcm_s16le")))
    }

    @Test("A real MONO original is proven against its two-channel copy; a real 5.1 original is not one-sided",
          .timeLimit(.minutes(2)))
    func monoAndSurroundOriginals() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("monosurround")
        defer { try? fm.removeItem(at: dir) }
        let mono = try Lab.make("test_mono.mov", in: dir, channels: Media.tone)
        #expect(await Lab.entry("channels", of: mono, stream: "a:0") == "1")
        let monoBalanced = try await Media.balance(mono)
        guard case .proven(let evidence) = await Proof.measure(original: mono, balanced: monoBalanced) else {
            Issue.record("a mono original spread to two channels must be proven")
            return
        }
        #expect(evidence.originalClass == .mono && evidence.liveChannel == 0)
        #expect(evidence.discarded == nil, "one channel: nothing is left behind")
        #expect(Proof.logLine(original: mono, balanced: monoBalanced, outcome: .proven(evidence))
            .contains("original has one channel, nothing left behind"))

        let surround = try Lab.make("test_surround.mov", in: dir,
                                    channels: Array(repeating: Media.tone, count: 6).joined(separator: "|"))
        #expect(await Lab.entry("channels", of: surround, stream: "a:0") == "6")
        let folded = try Media.derive("folded_balanced", from: surround,
                                      ["-map", "0", "-c", "copy", "-af", "pan=stereo|c0=c0|c1=c0", "-c:a", "pcm_s16le"])
        #expect(await Proof.measure(original: surround, balanced: folded)
                == .notProven(.originalNotOneSided(.multichannel)))
    }

    @Test("A copy REPLACED mid-run by a byte-identical file of the same size is COULD NOT CHECK",
          .timeLimit(.minutes(2)))
    func sameSizeReplacementMidRunIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("replaced")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM16)
        let balanced = try await Media.balance(original)
        let twin = dir.appendingPathComponent("twin.mov").path
        try fm.copyItem(atPath: balanced, toPath: twin)
        #expect(try Media.sha256(ofFile: twin) == Media.sha256(ofFile: balanced))
        let before = try #require(FileIdentityStamp.capture(path: balanced))

        // ffmpeg: before the first pass, move the twin over the copy.
        let hasher = try Lab.script("replace", tool: "ffmpeg", in: dir, """
        if [ -f "\(twin)" ]; then /bin/mv -f "\(twin)" "\(balanced)"; fi
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """)
        let outcome = await Proof.measure(original: original, balanced: balanced,
                                          tools: Proof.Tools(ffmpeg: hasher, ffprobe: ToolLocator.ffprobePath))
        #expect(outcome == .couldNotCheck("a file changed while it was being checked"))
        let after = try #require(FileIdentityStamp.capture(path: balanced))
        #expect(after.size == before.size && after.inode != before.inode, "same size, another file")
        // Left alone, the replacement is a good copy.
        #expect(await Proof.measure(original: original, balanced: balanced).isProven)
    }
}
