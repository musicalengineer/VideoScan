// BalancedCopyProofPresentationTests.swift
// The proof compares WHAT PLAYS (DECISIONS 2026-11-17). Codex review #304
// blocked the packet-by-packet design with three ways to a false PROVEN
// that share one cause — equal stored packets are not equal playback:
//   1. a QuickTime edit list that hides half the picture, packets identical;
//   2. a palette change the packet listing prints identically;
//   3. sound packets re-timed inside the recording, samples identical.
// Each is rebuilt here with real ffmpeg media (test patterns and tones
// only), first shown by another road to agree in everything the packet
// design compared, then refused by the decoded frames themselves.
//
// The rest of the ruling is here too, on real media: stored-but-not-played
// media is NAMED with the file that stores it; a two-track DV recording's
// silent spare track may be left behind and is named; a header that states
// another length than decodes is could-not-check; every other difference
// between two files that play the same is named, with who holds what.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Balanced copy proof — what plays (Codex #304, DECISIONS 2026-11-17)", .serialized)
struct BalancedCopyProofPresentationTests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    /// Long-GOP H.264 with B-frames + 16-bit PCM in QuickTime — the shape
    /// whose packets an edit list can hide without removing them.
    private static let longGOP = ["-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "250", "-pix_fmt", "yuv420p"]

    // MARK: #304-1 — an edit list hides picture, packets identical

    @Test("#304-1: a copy whose edit list plays only the first half of the picture — every stored packet identical — is NOT THE SAME",
          .timeLimit(.minutes(2)))
    func editListHidingPictureWithIdenticalPacketsIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p1elst")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_long_gop.mov", in: dir, video: Self.longGOP)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame, "the job's own copy is the same")
        let (hiding, _) = try Lab.patched(balanced, as: "hiding_balanced.mov", after: "elst", offset: 8) { $0 / 2 }

        // By another road: the packet pass's rows are IDENTICAL — time, duration, size, bytes of all 50 packets …
        let rows = await Lab.packetRows(of: original, stream: "v:0")
        #expect(rows.split(separator: "\n").count == 50)
        #expect(await Lab.packetRows(of: hiding, stream: "v:0") == rows)
        // … only a flag the packet design did not read says half of them are not shown …
        let flagged = await Lab.packetRows(of: original, stream: "v:0", flags: true)
        #expect(await Lab.packetRows(of: hiding, stream: "v:0", flags: true) != flagged)
        // … and a player is given 25 pictures instead of 50.
        #expect(await Lab.playedFrames(of: original) == "50")
        #expect(await Lab.playedFrames(of: hiding) == "25")

        let outcome = await Proof.measure(original: original, balanced: hiding)
        #expect(!outcome.playsTheSame, "half the picture is hidden and the copy was still the same: \(outcome)")
        #expect(outcome == .notProven(.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy")))
    }

    // MARK: #304-2 — a palette change

    /// A two-second paletted raw-video AVI: one grey picture whose palette is
    /// all red for the first second and all `second` afterwards (a palette
    /// CHANGE packet half way). Every pixel is index 0 throughout.
    private func paletted(_ name: String, second: String, channels: String, in dir: URL) throws -> String {
        func palette(_ colour: String) throws -> String {
            let out = dir.appendingPathComponent("palette_\(colour).png").path
            if !fm.fileExists(atPath: out) {
                try BalanceAudioTestMedia.runFFmpeg(["-f", "lavfi", "-i", "color=\(colour):s=16x16:d=1", "-frames:v", "1"], output: out)
            }
            return out
        }
        let out = dir.appendingPathComponent(name).path
        let grey = "color=gray:s=64x48:r=25:d=1"
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", grey, "-i", try palette("red"), "-f", "lavfi", "-i", grey, "-i", try palette(second),
             "-f", "lavfi", "-i", "aevalsrc=\(channels):s=48000:d=2",
             "-filter_complex", "[0:v][1:v]paletteuse[a];[2:v][3:v]paletteuse[b];[a][b]concat=n=2:v=1:a=0[v]",
             "-map", "[v]", "-map", "4:a", "-c:v", "rawvideo", "-pix_fmt", "pal8", "-c:a", "pcm_s16le"],
            output: out)
        return out
    }

    @Test("#304-2: a copy whose palette turns blue where the original's turns green — identical packets, identical packet listing — is NOT THE SAME",
          .timeLimit(.minutes(2)))
    func changedPaletteIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p2palette")
        defer { try? fm.removeItem(at: dir) }
        let original = try paletted("test_palette.avi", second: "green", channels: Media.leftOnly, in: dir)
        #expect(await Lab.entry("pix_fmt", of: original, stream: "v:0") == "pal8")
        let balanced = try await Media.balance(original)
        let faithful = await Proof.measure(original: original, balanced: balanced)
        #expect(faithful.playsTheSame, "the job carries the palette change; its copy is the same: \(faithful)")
        let blue = try paletted("blue_balanced.avi", second: "blue", channels: "\(Media.tone)|\(Media.tone)", in: dir)

        // By another road: everything the packet pass lists is identical, palette-change packet included …
        let rows = await Lab.packetRows(of: balanced, stream: "v:0")
        #expect(rows.split(separator: "\n").count == 50 && rows.contains("Palette"))
        #expect(await Lab.packetRows(of: blue, stream: "v:0") == rows)
        // … and the pictures shown in the second half are not the same colour.
        func shown(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffmpegPath, ["-v", "error", "-i", path, "-map", "0:v:0", "-pix_fmt", "rgb24",
                                                      "-f", "hash", "-hash", "sha256", "-"])
        }
        let colours = await shown(balanced)
        let blueColours = await shown(blue)
        #expect(colours.hasPrefix("SHA256=") && blueColours.hasPrefix("SHA256=") && blueColours != colours)

        let outcome = await Proof.measure(original: original, balanced: blue)
        #expect(!outcome.playsTheSame, "a picture of another colour was the same: \(outcome)")
        guard case .notProven(.pictureDiffers(0, let what)) = outcome else {
            Issue.record("expected the decoded frames to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("its frames are not the original's"), "\(what)")
    }

    // MARK: #304-3 — sound re-timed inside the recording

    @Test("#304-3: a copy whose sound packets drift up to 300 ms inside the recording and come back — same samples, same start, same end — is NOT THE SAME",
          .timeLimit(.minutes(2)))
    func interiorSoundRetimeIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p3setts")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .mkvFFV1PCM16)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame, "the faithful pair is the same")
        let retimed = try Media.derive("retimed_balanced", from: balanced,
                                       ["-map", "0", "-c", "copy", "-bsf:a", "setts=ts=TS+10*max(0\\,min(N-10\\,70-N))"])

        // By another road: the samples, their number, the packets' number, the first and the last time agree …
        let live = await Lab.channelHash(of: original, channel: 0)
        #expect(live.hasPrefix("SHA256="))
        #expect(await Lab.channelHash(of: retimed, channel: 0) == live)
        #expect(await Lab.channelHash(of: retimed, channel: 1) == live)
        func times(_ path: String) async -> [Int] {
            await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "a:0", "-show_entries", "packet=pts",
                                                       "-of", "csv=p=0", path]).split(separator: "\n").compactMap { Int($0) }
        }
        let (was, now) = (await times(balanced), await times(retimed))
        #expect(was.count == 94 && now.count == 94 && was.first == now.first && was.last == now.last)
        // … and in between a packet plays up to 300 ms late.
        #expect(zip(was, now).map { $1 - $0 }.max() == 300)

        let outcome = await Proof.measure(original: original, balanced: retimed)
        #expect(!outcome.playsTheSame, "sound moved against the picture and the copy was still the same: \(outcome)")
        guard case .notProven(.soundPlacementDiffers(let what)) = outcome else {
            Issue.record("expected the sound's placement to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("the original's sound plays in 1 unbroken runs, the balanced copy's in "), "\(what)")
    }

    // MARK: Stored but not played

    @Test("HIDDEN MEDIA: an original that stores two seconds of picture and plays one (the NH-Part-4 shape) — its copy holds only what plays, and the difference is NAMED as held by the original",
          .timeLimit(.minutes(2)))
    func storedButNotPlayedMediaIsNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("hidden")
        defer { try? fm.removeItem(at: dir) }
        // All-intra ProRes: the demuxer leaves the hidden packets out, so the job's copy does not carry them.
        let whole = try Lab.make("whole.mov", in: dir)
        let (original, _) = try Lab.patched(whole, as: "test_hides_half.mov", after: "elst", offset: 8) { $0 / 2 }
        #expect(await Lab.playedFrames(of: original) == "25")
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .sameContent(let evidence, let differs) = outcome else {
            Issue.record("what plays is the same and the original stores more: expected a named difference, got \(outcome)")
            return
        }
        #expect(evidence.streams.first?.frames == 25 && evidence.soundSamples == 96_000)
        #expect(differs.filter { $0.what.hasPrefix("stored ") } == [Proof.Difference(
            kind: .playback, heldBy: .original,
            what: "stored picture (stream 0) an edit list does not play: 2.000 s stored, 1.000 s played — not compared with the other file")], "\(differs)")
        let line = Proof.logLine(original: original, balanced: balanced, outcome: outcome)
        #expect(line.contains("SAME CONTENT, DIFFERS IN ") && line.contains("[playback instructions] the original holds stored picture"))

        // Long-GOP H.264: the hidden packets ARE carried by the job's copy, under the same edit list.
        // Both files store two seconds and play the same one — and since the hidden second is neither
        // decoded nor hashed, each is named as holding its own (Codex #307-2). Never "proven".
        let long = try Lab.make("whole_long.mov", in: dir, video: Self.longGOP)
        let (hides, _) = try Lab.patched(long, as: "test_hides_long.mov", after: "elst", offset: 8) { $0 / 2 }
        let carried = try await Media.balance(hides)
        let same = await Proof.measure(original: hides, balanced: carried)
        #expect(same.differences.filter { $0.what.hasPrefix("stored ") }.map(\.heldBy) == [.original, .balancedCopy] && !same.isProven,
                "\(same)")
        #expect(same.evidence?.streams.first?.frames == 25 && same.evidence?.streams.first?.packets == 50,
                "25 frames play; all 50 stored packets are in the copy, identical")
        // And against the copy that plays ALL of it, the hiding original is not the same.
        let wholeCopy = try await Media.balance(long)
        #expect(await Proof.measure(original: hides, balanced: wholeCopy)
                == .notProven(.pictureDiffers(originalIndex: 0, "25 frames play in the original, 50 in the balanced copy")))
    }

    @Test("#307-2: two files that hide the SAME LENGTH of DIFFERENT pictures (a green tail, a blue tail) are never PROVEN — the original's hidden media is named as its own",
          .timeLimit(.minutes(2)))
    func equalLengthsOfDifferentHiddenMediaAreNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p72tails")
        defer { try? fm.removeItem(at: dir) }
        /// One second of red, then one second of `tail`, all-intra ProRes.
        func film(_ name: String, tail: String, channels: String) throws -> String {
            let out = dir.appendingPathComponent(name).path
            try BalanceAudioTestMedia.runFFmpeg(
                ["-f", "lavfi", "-i", "color=red:s=320x240:r=25:d=1", "-f", "lavfi", "-i", "color=\(tail):s=320x240:r=25:d=1",
                 "-f", "lavfi", "-i", "aevalsrc=\(channels):s=48000:d=2",
                 "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-map", "2:a",
                 "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"], output: out)
            return try Lab.patched(out, as: "hides_" + name, after: "elst", offset: 8) { $0 / 2 }.path
        }
        let original = try film("test_green.mov", tail: "green", channels: Media.leftOnly)
        let copy = try film("blue_balanced.mov", tail: "blue", channels: "\(Media.tone)|\(Media.tone)")
        // By another road: what plays is the same red second; what is STORED is not the same.
        #expect(await Lab.playedFrames(of: original) == "25")
        #expect(await Lab.packetRows(of: copy, stream: "v:0") == (await Lab.packetRows(of: original, stream: "v:0")))
        func stored(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-ignore_editlist", "1", "-select_streams", "v:0", "-show_packets",
                                                       "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "csv=p=0", path])
        }
        let (ours, theirs) = (await stored(original), await stored(copy))
        #expect(ours.split(separator: "\n").count == 50 && ours != theirs)

        let outcome = await Proof.measure(original: original, balanced: copy)
        #expect(!outcome.isProven, "a green tail only the original stores went unnamed: \(outcome)")
        #expect(outcome.differences.contains { $0.kind == .playback && $0.heldBy == .original
            && $0.what.hasPrefix("stored picture (stream 0) an edit list does not play: 2.000 s stored, 1.000 s played") }, "\(outcome)")
    }

    // MARK: #307-1 — a picture that changes size

    @Test("#307-1: an original whose picture doubles in size half way, and a copy scaled back to the first size throughout, are NOT THE SAME — nothing is scaled before it is hashed",
          .timeLimit(.minutes(2)))
    func aPictureScaledBackToItsFirstSizeIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p71scale")
        defer { try? fm.removeItem(at: dir) }
        func part(_ name: String, size: String) throws -> String {
            let out = dir.appendingPathComponent(name).path
            try BalanceAudioTestMedia.runFFmpeg(
                ["-f", "lavfi", "-i", "testsrc2=s=\(size):r=25:d=1", "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0",
                 "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                 "-f", "h264"], output: out)
            return out
        }
        let joined = dir.appendingPathComponent("joined.h264")
        try (Data(contentsOf: URL(fileURLWithPath: try part("small.h264", size: "64x48")))
             + Data(contentsOf: URL(fileURLWithPath: try part("large.h264", size: "128x96")))).write(to: joined)
        let original = dir.appendingPathComponent("test_grows.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-r", "25", "-i", joined.path, "-f", "lavfi", "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2",
             "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le"], output: original)
        // The copy: sound balanced, picture re-encoded losslessly — with ffmpeg's default scaling back to 64×48.
        let copy = try Media.derive("scaled_balanced", from: original,
                                    ["-map", "0", "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", "-pix_fmt", "yuv420p",
                                     "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                                     "-af", "pan=stereo|c0=c0|c1=c0", "-c:a", "pcm_s16le"])
        // By another road: the original really shows two sizes, the copy one.
        func sizes(_ path: String) async -> Set<String> {
            Set(await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "v:0", "-show_frames",
                                                           "-show_entries", "frame=width", "-of", "csv=p=0", path])
                .split(separator: "\n").compactMap { $0.split(separator: ",").first.map(String.init) })
        }
        #expect(await sizes(original) == ["64", "128"])
        #expect(await sizes(copy) == ["64"])

        let outcome = await Proof.measure(original: original, balanced: copy)
        #expect(!outcome.playsTheSame, "half the picture lost its size and detail and the copy was the same: \(outcome)")
        // (End to end the original's pass is could-not-check first: the size change restarts the
        // filter graph and the peak meter reports twice. So the scaler is pinned on the decode
        // pass itself:) the production arguments, run on both files, must fold to DIFFERENT
        // picture digests — with ffmpeg's default scaler they fold to the same one.
        func pictureDigest(_ path: String) async -> Proof.PictureRead? {
            let plan = Proof.DecodePlan(pictures: [.init(index: 0, pixelFormat: "yuv420p")], soundIndex: 1,
                                        sampleFormat: "s16", sampleRateHz: 48_000, channels: [0])
            let ledger = Proof.FrameLedger(roles: plan.roles, sampleRateHz: 48_000)
            let run = await ProcessRunner.runProcess(
                executable: ToolLocator.ffmpegPath,
                arguments: Proof.decodeArgs(input: path, inputArgs: [], plan: plan, hashCodec: "pcm_s16le"),
                stdoutLine: { ledger.note($0) }, stdoutLimitBytes: 0, deadlineSeconds: 60)
            return run.exitCode == 0 && ledger.fault == nil ? ledger.played.pictures[0] : nil
        }
        let grows = try #require(await pictureDigest(original), "the growing picture decodes")
        let scaled = try #require(await pictureDigest(copy))
        #expect(grows.frames == 50 && scaled.frames == 50)
        #expect(grows.sha256 != scaled.sha256, "a picture scaled back to its first size hashed as the original")
    }

    @Test("#308-1: a COPY whose picture changes shape half way to one of the same byte count (64×48 → 32×96) — every frame hash equal — is not the same: a pass whose picture changes shape is COULD NOT CHECK",
          .timeLimit(.minutes(2)))
    func aPictureThatChangesShapeMidStreamIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p81shape")
        defer { try? fm.removeItem(at: dir) }
        // One YUV 4:2:0 buffer that is a 64×48 picture and, read another way, a 32×96 one.
        var buffer = Data((0..<(64 * 48)).map { UInt8(16 + 3 * ($0 % 64)) })
        buffer.append(Data(repeating: 128, count: 64 * 48 / 2))
        let raw = dir.appendingPathComponent("buffer.yuv")
        try Data(Array(repeating: buffer, count: 25).joined()).write(to: raw)
        func stream(_ name: String, size: String) throws -> Data {
            let out = dir.appendingPathComponent(name).path
            try BalanceAudioTestMedia.runFFmpeg(
                ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", size, "-r", "25", "-i", raw.path, "-c:v", "libx264",
                 "-preset", "ultrafast", "-qp", "0", "-vf", "setsar=1", "-pix_fmt", "yuv420p", "-f", "h264"], output: out)
            return try Data(contentsOf: URL(fileURLWithPath: out))
        }
        let (wide, tall) = (try stream("wide.h264", size: "64x48"), try stream("tall.h264", size: "32x96"))
        func film(_ name: String, picture: Data, channels: String) throws -> String {
            let joined = dir.appendingPathComponent(name + ".h264")
            try picture.write(to: joined)
            let out = dir.appendingPathComponent(name + ".mkv").path
            try BalanceAudioTestMedia.runFFmpeg(
                ["-r", "25", "-i", joined.path, "-f", "lavfi", "-i", "aevalsrc=\(channels):s=48000:d=2", "-map", "0:v", "-map", "1:a",
                 "-c:v", "copy", "-af", "asetnsamples=n=48000:p=0", "-c:a", "pcm_s16le"], output: out)
            return out
        }
        let original = try film("test_wide", picture: wide + wide, channels: Media.leftOnly)
        let copy = try film("shape_balanced", picture: wide + tall, channels: "\(Media.tone)|\(Media.tone)")
        // By another road: the copy shows two shapes, and its frames are the same bytes.
        let heights = Set(await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "v:0", "-show_frames",
                                                                      "-show_entries", "frame=height", "-of", "csv=p=0", copy])
            .split(separator: "\n").compactMap { $0.split(separator: ",").first.map(String.init) })
        #expect(heights == ["48", "96"])
        func frames(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffmpegPath, ["-v", "error", "-i", path, "-map", "0:v:0", "-f", "framehash", "-hash", "sha256", "-"])
                .split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        }
        let (ours, theirs) = (await frames(original), await frames(copy))
        #expect(ours.split(separator: "\n").count == 50 && theirs.split(separator: "\n").count == 50)

        let outcome = await Proof.measure(original: original, balanced: copy)
        #expect(!outcome.playsTheSame, "a picture shown in another shape was the same: \(outcome)")
        #expect(Lab.reason(outcome)?.contains("Reconfiguring filter graph because video parameters changed") == true, "\(outcome)")
    }

    // MARK: #307-3 — a subtitle's styles

    @Test("#307-3: a copy whose captions are the same packets in another STYLE is never PROVEN: each file's text track is named as its own, not compared",
          .timeLimit(.minutes(2)))
    func changedSubtitleConfigurationIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("p73ass")
        defer { try? fm.removeItem(at: dir) }
        let captions = dir.appendingPathComponent("captions.srt")
        try "1\n00:00:00,200 --> 00:00:00,900\nhello\n\n2\n00:00:01,100 --> 00:00:01,800\nworld\n"
            .write(to: captions, atomically: true, encoding: .utf8)
        let original = dir.appendingPathComponent("test_styled.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
             "-f", "lavfi", "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2", "-i", captions.path,
             "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-c:s", "ass"],
            output: original)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame, "the job carries captions and their styles")
        // The same captions with the default style's colour changed: only the track's header differs.
        let script = dir.appendingPathComponent("styles.ass")
        try BalanceAudioTestMedia.runFFmpeg(["-i", balanced, "-map", "0:s:0", "-c", "copy"], output: script.path)
        let white = try String(contentsOf: script, encoding: .utf8)
        #expect(white.contains("&Hffffff") || white.contains("&H00FFFFFF"), "the default style is white")
        let red = white.replacingOccurrences(of: "&Hffffff,&Hffffff", with: "&H0000ff,&Hffffff")
            .replacingOccurrences(of: "&H00FFFFFF,&H00FFFFFF", with: "&H000000FF,&H00FFFFFF")
        #expect(red != white)
        try red.write(to: script, atomically: true, encoding: .utf8)
        let restyled = try Media.derive("restyled_balanced", from: balanced,
                                        ["-map", "0:v", "-map", "0:a", "-map", "1:s", "-c", "copy"], secondInput: script.path)
        #expect(await Lab.packetRows(of: restyled, stream: "s:0") == (await Lab.packetRows(of: balanced, stream: "s:0")),
                "the caption packets are untouched")

        // RE-SCOPED 2026-11-17: a text track is named for each file and NOT compared — see the header of
        // BalancedCopyProof.swift. The restyled copy plays the same picture and sound; it is never "proven",
        // and the original's text track is named as the original's.
        let outcome = await Proof.measure(original: original, balanced: restyled)
        #expect(outcome.playsTheSame && !outcome.isProven, "\(outcome)")
        #expect(outcome.differences.filter { $0.kind == .track }.map(\.heldBy) == [.original, .balancedCopy], "\(outcome.differences)")
    }

    // MARK: Two-track DV

    /// A raw DV recording with two sound tracks (DVCPRO50 — the only
    /// two-track shape ffmpeg's dv muxer writes; see BalanceAudioTestMedia).
    private func twoTrackDV(_ label: String, spare: String, in dir: URL) throws -> String {
        try BalanceAudioTestMedia.generateTwoAudioPairs(into: dir, label: label, pair1: Media.leftOnly, pair2: spare, container: .dv)
    }

    @Test("DV RULE: a two-track DV recording whose spare track is MEASURED silent plays the same in the job's one-track copy; the dropped track is named as held by the original",
          .timeLimit(.minutes(3)))
    func twoTrackDVWithASilentSpareTrack() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("dvspare")
        defer { try? fm.removeItem(at: dir) }
        let original = try twoTrackDV("silent", spare: "0|0", in: dir)
        #expect(await Lab.entry("codec_name", of: original, stream: "v:0") == "dvvideo")
        #expect(await Lab.entry("codec_type", of: original, stream: "2") == "audio", "two sound tracks")
        let balanced = try await Media.balance(original)
        #expect(await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                                           "-of", "csv=p=0", balanced]) == "1", "the job's copy has one")

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .sameContent(let evidence, let differs) = outcome else {
            Issue.record("expected the same content with the spare track named, got \(outcome)")
            return
        }
        #expect(differs.prefix(3) == [
            Proof.Difference(kind: .track, heldBy: .original,
                             what: "a second sound track (stream 2, 2 channels), measured silent: digital silence"),
            Proof.Difference(kind: .track, heldBy: .balancedCopy, what: "a timecode track — not compared with the other file"),
            Proof.Difference(kind: .container, heldBy: nil, what: "the original is a dv file, the balanced copy a mov file")
        ], "\(differs)")
        #expect(differs.filter { $0.heldBy == .original }.map(\.kind) == [.track, .metadata], "the spare track and its tags are all the original holds")
        let picture = try #require(evidence.streams.first)
        #expect(picture.codec == "dvvideo" && picture.packetIdentical && picture.frames == picture.packets)
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
    }

    @Test("DV RULE: a spare track that holds a 50 ms passage (whole-track level under the job's floor, so the job drops it) is NOT THE SAME — measured, not assumed",
          .timeLimit(.minutes(3)))
    func twoTrackDVWithSoundOnTheSpareTrackIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("dvloud")
        defer { try? fm.removeItem(at: dir) }
        let burst = "0.004*sin(880*2*PI*t)*gt(t\\,1)*lt(t\\,1.05)"
        let original = try twoTrackDV("burst", spare: "0|\(burst)", in: dir)
        let analysis = try await AudioBalanceProbe.analyze(path: original)
        #expect(analysis.droppedStreamIndices == [2], "the fixture must be one the job balances by dropping track 2")
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        #expect(!outcome.playsTheSame, "sound on the dropped track was certified as nothing: \(outcome)")
        guard case .notProven(.spareSoundTrack(let what)) = outcome else {
            Issue.record("expected the spare track to be the reason, got \(outcome)")
            return
        }
        #expect(what == "stream 2 is not silent: peak −48.0 dBFS", "\(what)")
    }

    // MARK: A header that lies

    @Test("HEADER LIE: a header that states twice the length that decodes — in the copy, or in the original — is COULD NOT CHECK, never agreement",
          .timeLimit(.minutes(2)))
    func headerDurationThatLiesIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("lie")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .aviDVPCM16)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame)
        // AVI's stream header: dwLength, 36 bytes after the first `strh` name (the picture's), little-endian.
        let (lying, frames) = try Lab.patched(balanced, as: "lying_balanced.avi", after: "strh", offset: 36, littleEndian: true) { $0 * 2 }
        #expect(frames == 60)
        #expect(await Lab.entry("duration", of: balanced, stream: "v:0") == "2.002000")
        #expect(await Lab.entry("duration", of: lying, stream: "v:0") == "4.004000")
        // Every packet and every decoded frame is still the original's.
        #expect(await Lab.packetRows(of: lying, stream: "v:0") == (await Lab.packetRows(of: balanced, stream: "v:0")))
        #expect(await Lab.playedFrames(of: lying) == "60")

        let outcome = await Proof.measure(original: original, balanced: lying)
        #expect(outcome == .couldNotCheck(
            "the balanced copy was not read to the end (picture stream 0: 2.002 s decoded, 4.004 s stated)"), "\(outcome)")
        // The same lie in the original.
        let (lyingOriginal, _) = try Lab.patched(original, as: "test_lying.avi", after: "strh", offset: 36, littleEndian: true) { $0 * 2 }
        let other = await Proof.measure(original: lyingOriginal, balanced: balanced)
        #expect(Lab.reason(other)?.hasPrefix("the original was not read to the end (picture stream 0: 2.002 s decoded") == true, "\(other)")
    }

    // MARK: A track switched off

    @Test("SWITCHED OFF: a QuickTime copy whose sound track is disabled — every packet, frame and sample still there — is NOT THE SAME: a player plays it silent",
          .timeLimit(.minutes(2)))
    func aTrackSwitchedOffIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("disabled")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM16)
        let balanced = try await Media.balance(original)
        // QuickTime's track header: flags are the three bytes after the version; bit 0 is "enabled".
        // The picture's `tkhd` comes first, the sound's second.
        var bytes = try Data(contentsOf: URL(fileURLWithPath: balanced))
        let first = try #require(bytes.range(of: Data("tkhd".utf8)))
        let second = try #require(bytes.range(of: Data("tkhd".utf8), in: first.upperBound..<bytes.endIndex))
        #expect(bytes[second.upperBound + 3] & 1 == 1, "the job writes the sound track enabled")
        bytes[second.upperBound + 3] &= 0xFE
        let silent = dir.appendingPathComponent("silent_balanced.mov").path
        try bytes.write(to: URL(fileURLWithPath: silent))

        // By another road: ffmpeg still decodes the same sound from it, the same picture packets …
        #expect(await Lab.channelHash(of: silent, channel: 0) == (await Lab.channelHash(of: original, channel: 0)))
        #expect(await Lab.packetRows(of: silent, stream: "v:0") == (await Lab.packetRows(of: original, stream: "v:0")))
        // … and the track is no longer marked to play.
        func plays(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                                       "stream_disposition=default", "-of", "default=nw=1:nk=1", path])
        }
        #expect(await plays(balanced) == "1")
        #expect(await plays(silent) == "0")

        let outcome = await Proof.measure(original: original, balanced: silent)
        #expect(outcome == .notProven(.pictureConfigurationDiffers(
            "audio stream 1: the balanced copy's track is not marked to play by default")), "\(outcome)")
    }

    // MARK: The same recording, later

    @Test("LATE START: a copy whose picture AND sound both start half a second late — nothing moved against anything else — is NOT THE SAME",
          .timeLimit(.minutes(2)))
    func aCopyThatStartsLateAsAWholeIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("late")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM16)
        let balanced = try await Media.balance(original)
        let late = dir.appendingPathComponent("late_balanced.mov").path
        try BalanceAudioTestMedia.runFFmpeg(["-itsoffset", "0.5", "-i", balanced, "-map", "0", "-c", "copy", "-write_tmcd", "0"],
                                            output: late)
        // By another road: both streams start at 0.5 s, sound against picture is unchanged, the packets are the same.
        #expect(await Lab.entry("start_time", of: late, stream: "v:0") == "0.500000")
        #expect(await Lab.entry("start_time", of: late, stream: "a:0") == "0.500000")
        #expect(await Lab.packetHash(of: late, stream: "v:0") == (await Lab.packetHash(of: original, stream: "v:0")))

        let outcome = await Proof.measure(original: original, balanced: late)
        #expect(!outcome.playsTheSame, "a recording that starts half a second late was the same: \(outcome)")
        guard case .notProven(.pictureDiffers(0, let what)) = outcome else {
            Issue.record("expected the frames' times to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("its frames are not the original's, each at the original's time"), "\(what)")
    }

    // MARK: A pass whose output cannot be believed

    @Test("WHOLE READS: a packet pass or a decode pass that exits non-zero, says anything it should not, writes a line that cannot be read, or loses a line on the way is COULD NOT CHECK — for a faithful pair",
          .timeLimit(.minutes(3)))
    func aPassThatCannotBeBelievedIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("passes")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM16)
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame)

        /// An ffprobe that does the real work and, for the PACKET pass only, `after` as well.
        func probe(_ name: String, after: String) throws -> Proof.Tools {
            Proof.Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: try Lab.script(name, tool: "ffprobe", in: dir, """
            case "$*" in *-show_packets*) "\(ToolLocator.ffprobePath)" "$@"; \(after) ;; esac
            exec "\(ToolLocator.ffprobePath)" "$@"
            """))
        }
        func why(_ tools: Proof.Tools) async -> String? {
            Lab.reason(await Proof.measure(original: original, balanced: balanced, tools: tools))
        }
        let junkLine = try probe("junk", after: "echo 'garbage line'; exit 0")
        #expect(await why(junkLine) == "the original could not be read packet by packet (unreadable packet line: garbage line)")
        let noise = try probe("noise", after: "echo 'a read error' >&2; exit 0")
        #expect(await why(noise) == "the original could not be read packet by packet (ffprobe exited 0 but said: a read error)")
        let status = try probe("status", after: "exit 3")
        #expect(await why(status) == "the original could not be read packet by packet (ffprobe status 3)")

        // The decode pass: one line more than ffmpeg wrote …
        let junk = try Lab.script("framejunk", tool: "ffmpeg", in: dir, """
        "\(ToolLocator.ffmpegPath)" "$@"
        status=$?
        echo "9, garbage"
        exit $status
        """)
        #expect(await why(Proof.Tools(ffmpeg: junk, ffprobe: ToolLocator.ffprobePath))
                == "the original could not be decoded to the end (unreadable frame line: 9, garbage)")
        // … and one line less: its last frame never arrived, though it exited 0 with a clean log.
        let lossy = try Lab.script("framelost", tool: "ffmpeg", in: dir, """
        "\(ToolLocator.ffmpegPath)" "$@" | /usr/bin/sed '$d'
        """)
        let lost = await why(Proof.Tools(ffmpeg: lossy, ffprobe: ToolLocator.ffprobePath))
        #expect(lost?.hasPrefix("the original's decoded frames did not all arrive (ffmpeg wrote 146, 145 were read)") == true, "\(String(describing: lost))")
    }

    // MARK: Pinned formats

    @Test("PINNED FORMAT: a picture that would have to be converted to match its header's pixel format ends the pass — COULD NOT CHECK, never a silent conversion",
          .timeLimit(.minutes(2)))
    func aFrameThatNeedsConvertingIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("pinned")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .mkvFFV1PCM16)
        let balanced = try await Media.balance(original)
        // An ffmpeg told to pin GREY: what the proof's own arguments would do
        // to a file whose decoder gives another format than its header states.
        // Converted silently, both files would hash equal in grey — colour gone unseen.
        let grey = try Lab.script("grey", tool: "ffmpeg", in: dir, """
        n=$#
        i=0
        while [ $i -lt $n ]; do
          a=$(printf '%s' "$1" | /usr/bin/sed 's/format=pix_fmts=[a-z0-9]*/format=pix_fmts=gray/g'); shift
          set -- "$@" "$a"
          i=$((i+1))
        done
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """)
        let outcome = await Proof.measure(original: original, balanced: balanced,
                                          tools: Proof.Tools(ffmpeg: grey, ffprobe: ToolLocator.ffprobePath))
        let why = try #require(Lab.reason(outcome), "expected could not check, got \(outcome)")
        #expect(why.hasPrefix("the original could not be decoded to the end (ffmpeg status "), "\(why)")
        // The same pin on the SOUND: a sample format other than the header's.
        let wide = try Lab.script("wide", tool: "ffmpeg", in: dir, """
        n=$#
        i=0
        while [ $i -lt $n ]; do
          a=$(printf '%s' "$1" | /usr/bin/sed 's/aformat=sample_fmts=s16:/aformat=sample_fmts=s32:/g'); shift
          set -- "$@" "$a"
          i=$((i+1))
        done
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """)
        let sound = await Proof.measure(original: original, balanced: balanced,
                                        tools: Proof.Tools(ffmpeg: wide, ffprobe: ToolLocator.ffprobePath))
        #expect(Lab.reason(sound)?.hasPrefix("the original could not be decoded to the end (ffmpeg status ") == true, "\(sound)")
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame, "left alone, the pair is the same")
    }

    // MARK: Every other difference, named on real media

    @Test("NAMED: a picture stored in other packets, or in another codec, with every decoded frame the same — the same content, the encoding named",
          .timeLimit(.minutes(2)))
    func losslessReencodeIsNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("encoding")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_ffv1.mkv", in: dir, video: ["-c:v", "ffv1", "-pix_fmt", "yuv420p"])
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame)

        // The same codec, cut into other slices: other bytes, the same pictures.
        let recut = try Media.derive("recut_balanced", from: balanced,
                                     ["-map", "0", "-c", "copy", "-c:v", "ffv1", "-level", "3", "-slices", "16", "-g", "1"])
        #expect(await Lab.packetRows(of: recut, stream: "v:0") != (await Lab.packetRows(of: balanced, stream: "v:0")))
        let sameCodec = await Proof.measure(original: original, balanced: recut)
        #expect(sameCodec.playsTheSame && !sameCodec.isProven, "\(sameCodec)")
        #expect(sameCodec.differences.contains { $0.kind == .encoding && $0.heldBy == nil
            && $0.what.hasPrefix("picture stream 0 (ffv1) is not stored in the same packets") }, "\(sameCodec.differences)")
        #expect(sameCodec.evidence?.streams.first?.packetIdentical == false && sameCodec.evidence?.streams.first?.frames == 50)

        // Another lossless codec.
        let huffyuv = try Media.derive("huffyuv_balanced", from: balanced, ["-map", "0", "-c", "copy", "-c:v", "ffvhuff"])
        let otherCodec = await Proof.measure(original: original, balanced: huffyuv)
        #expect(otherCodec.differences.contains(Proof.Difference(
            kind: .encoding, heldBy: nil,
            what: "picture stream 0 is stored as ffv1 in the original and as ffvhuff in the balanced copy; every decoded frame is the same")),
                "\(otherCodec)")
        #expect(otherCodec.differences.contains { $0.kind == .decoderConfiguration }, "another codec has another configuration")
        // A LOSSY re-encode in the same codec family is not the same at all.
        let lossy = try Media.derive("lossy_balanced", from: balanced,
                                     ["-map", "0", "-c", "copy", "-c:v", "mpeg4", "-q:v", "5"])
        #expect(!(await Proof.measure(original: original, balanced: lossy)).playsTheSame)
    }

    @Test("NAMED: decoder configuration written differently (an H.264 level in the extradata), packets and frames identical — named, neither file holds more",
          .timeLimit(.minutes(2)))
    func decoderConfigurationIsNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("extradata")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_level.mov", in: dir, video: Self.longGOP)
        let balanced = try await Media.balance(original)
        let relabelled = try Media.derive("level_balanced", from: balanced,
                                          ["-map", "0", "-c", "copy", "-bsf:v", "h264_metadata=level=5.1"])
        #expect(await Lab.packetRows(of: relabelled, stream: "v:0") == (await Lab.packetRows(of: balanced, stream: "v:0")))
        func extradata(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-show_data_hash", "sha256", "-select_streams", "v:0",
                                                       "-show_entries", "stream=extradata_hash", "-of", "default=nw=1:nk=1", path])
        }
        let (was, now) = (await extradata(balanced), await extradata(relabelled))
        #expect(was.hasPrefix("SHA256:") && now.hasPrefix("SHA256:") && was != now)

        let outcome = await Proof.measure(original: original, balanced: relabelled)
        #expect(Lab.differs(outcome).filter { $0.hasPrefix("[decoder") } == ["[decoder configuration] picture stream 0's decoder "
            + "configuration (extradata) is written differently; every decoded frame is the same"], "\(outcome)")
        #expect(outcome.differences.filter { $0.heldBy == nil }.count == 1, "nothing else about the picture differs")
        #expect(outcome.evidence?.streams.first?.packetIdentical == true)
    }

    @Test("NAMED: another container, and tags only one file has — each named, with the file that holds them",
          .timeLimit(.minutes(2)))
    func containerAndMetadataAreNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("tags")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_tagged.mkv", in: dir, video: ["-c:v", "ffv1"],
                                    extra: ["-metadata", "title=Christmas 1994", "-metadata", "tape=7"])
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).playsTheSame, "the job carries the tags")

        // The copy lost the original's tags and gained one of its own.
        let retagged = try Media.derive("retagged_balanced", from: balanced,
                                        ["-map", "0", "-c", "copy", "-map_metadata", "-1", "-metadata", "note=balanced"])
        let tags = await Proof.measure(original: original, balanced: retagged)
        #expect(tags.playsTheSame && !tags.isProven, "\(tags)")
        let lost = try #require(tags.differences.first { $0.kind == .metadata && $0.heldBy == .original }, "\(tags.differences)")
        #expect(lost.what.contains("TAPE") && lost.what.contains("title"), "\(lost.what)")
        let gained = try #require(tags.differences.first { $0.kind == .metadata && $0.heldBy == .balancedCopy }, "\(tags.differences)")
        #expect(gained.what.contains("NOTE") && !gained.what.contains("TAPE"), "\(gained.what)")

        // Chapter marks: counted and named for each file that has any.
        let marks = dir.appendingPathComponent("marks.txt")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n"
            .write(to: marks, atomically: true, encoding: .utf8)
        let chaptered = dir.appendingPathComponent("test_chapters.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(["-i", original, "-i", marks.path, "-map", "0", "-map_metadata", "0", "-map_chapters", "1", "-c", "copy"],
                                            output: chaptered)
        let withMarks = try await Media.balance(chaptered)
        let unmarked = try Media.derive("unmarked_balanced", from: withMarks, ["-map", "0", "-c", "copy", "-map_chapters", "-1"])
        func chapters(_ outcome: Proof.Outcome) -> [Proof.Difference] { outcome.differences.filter { $0.what.contains("chapter marks") } }
        let two = Proof.Difference(kind: .metadata, heldBy: .original, what: "2 chapter marks — not compared with the other file")
        #expect(chapters(await Proof.measure(original: chaptered, balanced: unmarked)) == [two])
        #expect(chapters(await Proof.measure(original: chaptered, balanced: withMarks)).map(\.heldBy) == [.original, .balancedCopy])

        // PIN: the same streams remuxed to QuickTime lose the picture's colour-range
        // statement (full range → unstated). That changes how the same pixels are
        // SHOWN, so it is not a named difference: it is not the same. (A container
        // change that keeps the display — raw DV → QuickTime — is named: the matrix.)
        let movie = dir.appendingPathComponent("moved_balanced.mov").path
        try BalanceAudioTestMedia.runFFmpeg(["-i", balanced, "-map", "0", "-c", "copy"], output: movie)
        #expect(await Proof.measure(original: original, balanced: movie)
                == .notProven(.pictureConfigurationDiffers("picture stream 0: colour range pc → none")))
    }
}
