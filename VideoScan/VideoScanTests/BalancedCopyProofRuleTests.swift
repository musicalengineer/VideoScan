// BalancedCopyProofRuleTests.swift
// The measuring rules of BalancedCopyProof as pure tables: the discarded
// channel, how a picture is displayed, the channel layout, whether a decode
// pass was whole, the two folds (the packet pass's lines, the decode pass's
// frame lines) and the decode pass's log. No file, no subprocess — the same
// rules on real media are in the media suites.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

@Suite("Balanced copy proof — the measuring rules")
struct BalancedCopyProofRuleTests {

    typealias Proof = BalancedCopyProof
    typealias Table = BalancedCopyProofDecisionTests

    private func unchecked(_ outcome: Proof.Outcome) -> String? {
        if case .couldNotCheck(let why) = outcome { return why }
        return nil
    }

    // MARK: The discarded channel

    @Test("The channel left behind must PEAK at or under the ceiling; above it the original is kept")
    func discardedChannelTable() {
        #expect(Proof.discardedChannelPeakCeilingDBFS == -60.0, "provisional (DECISIONS 2026-11-17); a change is Rick's")
        func decide(_ peaks: [Double], class c: AudioChannelClass = .leftOnly) -> Proof.Outcome {
            Proof.decide(Table.poisoned {
                $0.originalClass = c
                $0.originalRead?.peaksDBFS[1] = peaks
            })
        }
        // Digital silence, and quiet under the ceiling: proven, and the evidence says how quiet.
        for peak in [-Double.infinity, -90.3, -66.2, -60.0] {
            guard case .proven(let evidence) = decide([-3.1, peak]) else {
                Issue.record("peak \(peak) must be proven: \(decide([-3.1, peak]))")
                continue
            }
            #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: peak))
            #expect(evidence.discarded?.isDigitalSilence == (peak == -.infinity))
        }
        // Over the ceiling, by a lot or by a hair.
        for peak in [-59.99, -48.2, -3.1, 0.0, Double.infinity] {
            #expect(decide([-3.1, peak]) == .notProven(.discardedChannelNotSilent(channel: 1, peakDBFS: peak)))
        }
        // A right-only original leaves its LEFT channel behind.
        #expect(decide([-48.2, -3.1], class: .rightOnly)
                == .notProven(.discardedChannelNotSilent(channel: 0, peakDBFS: -48.2)))
        #expect(decide([-.infinity, -3.1], class: .rightOnly).isProven)
        // Unmeasured is could-not-check, never "silent".
        for peaks in [[], [-3.1], [-3.1, .nan], [-3.1, -.infinity, -.infinity]] as [[Double]] {
            #expect(unchecked(decide(peaks)) == "the original's other channel was not measured", "\(peaks)")
        }
        // Peaks of ANOTHER stream do not answer for the kept one.
        #expect(unchecked(Proof.decide(Table.poisoned {
            $0.originalRead?.peaksDBFS = [2: [-3.1, -.infinity]]
        })) == "the original's other channel was not measured")
        // A one-channel original leaves nothing behind, whatever was (not) measured.
        let mono = Proof.decide(Table.facts {
            $0.originalClass = .mono
            $0.original.sound = [Table.sound(channels: 1)]
        })
        guard case .proven(let evidence) = mono else { Issue.record("\(mono)"); return }
        #expect(evidence.discarded == nil)
    }

    @Test("level() writes a peak the way the log shows it")
    func levelText() {
        #expect(Proof.level(-48.24) == "−48.2 dBFS")
        #expect(Proof.level(-71.3) == "−71.3 dBFS")
        #expect(Proof.level(0) == "0.0 dBFS")
        #expect(Proof.level(-.infinity) == "digital silence")
        #expect(Proof.level(.nan) == "unreadable")
    }

    // MARK: The packet pass's fold

    private func sequences(_ lines: [String], carried: [(Int, String)] = [(0, "1/12800")], sound: [Int] = [1])
        -> (fault: String?, found: [Int: Proof.PacketSequence]) {
        var layout = Proof.FileLayout()
        for (index, timeBase) in carried {
            layout.carried.append(Proof.CarriedStream(index: index, kind: "video", codec: "prores", tag: "apco",
                                                      timeBase: timeBase))
        }
        for index in sound { layout.sound.append(Table.sound(index)) }
        let ledger = Proof.PacketLedger(layout: layout)
        lines.forEach(ledger.note)
        return (ledger.fault, ledger.sequences)
    }
    private static let a = "SHA256:" + String(repeating: "a1", count: 32)
    private static let b = "SHA256:" + String(repeating: "b2", count: 32)

    @Test("PACKETS: the fold tells apart another time, another duration, another boundary, another order — and nothing else")
    func packetLedgerFold() throws {
        let base = ["0,0,512,100,\(Self.a)", "1,0,1024,4096,\(Self.b)", "0,512,512,200,\(Self.b)"]
        let good = sequences(base)
        #expect(good.fault == nil)
        let video = try #require(good.found[0])
        #expect(video.packets == 2 && good.found[1]?.packets == 1)
        #expect(video.timingSHA256.count == 64 && video.packetSHA256.count == 64)
        #expect(video.timingSHA256 != Proof.emptySHA256 && video.timingSHA256 != video.packetSHA256)
        // The sound is counted, not folded: its lines change nothing of the picture's digests …
        #expect(good.found[1]?.packetSHA256 == Proof.emptySHA256)
        #expect(sequences(base + ["1,1024,768,3072,\(Self.a)"]).found[0] == video)
        // … and a stream with no packet at all has count 0 and the digests of nothing.
        #expect(sequences([]).found[0] == Proof.PacketSequence(packets: 0, timingSHA256: Proof.emptySHA256,
                                                               packetSHA256: Proof.emptySHA256))

        func fold(_ lines: [String], timeBase: String = "1/12800") -> Proof.PacketSequence? {
            sequences(lines, carried: [(0, timeBase)]).found[0]
        }
        // Another presentation time, or duration: the times digest moves, the bytes digest does not.
        for changed in [["0,0,512,100,\(Self.a)", "0,1024,512,200,\(Self.b)"],
                        ["0,0,1024,100,\(Self.a)", "0,512,512,200,\(Self.b)"]] {
            let other = try #require(fold(changed))
            #expect(other.timingSHA256 != video.timingSHA256 && other.packetSHA256 == video.packetSHA256)
        }
        // Another boundary (the same 300 bytes as 150 + 150), another payload, another order: the bytes digest moves.
        for changed in [["0,0,512,150,\(Self.a)", "0,512,512,150,\(Self.b)"],
                        ["0,0,512,100,\(Self.b)", "0,512,512,200,\(Self.b)"],
                        ["0,0,512,200,\(Self.b)", "0,512,512,100,\(Self.a)"]] {
            let other = try #require(fold(changed))
            #expect(other.packetSHA256 != video.packetSHA256 && other.timingSHA256 == video.timingSHA256)
        }
        // The same instants in another time base are the SAME: raw DV 1/60000 against QuickTime 1/30000.
        let rawDV = try #require(fold(["0,0,2002,100,\(Self.a)", "0,2002,2002,200,\(Self.b)"], timeBase: "1/60000"))
        let movie = try #require(fold(["0,0,1001,100,\(Self.a)", "0,1001,1001,200,\(Self.b)"], timeBase: "1/30000"))
        #expect(rawDV == movie)
        let oneTickOff = try #require(fold(["0,0,1001,100,\(Self.a)", "0,1002,1001,200,\(Self.b)"], timeBase: "1/30000"))
        #expect(oneTickOff.timingSHA256 != movie.timingSHA256, "one tick (33 µs) is a difference: no tolerance")
        #expect(Proof.fraction(ticks: 2002, numerator: 1, denominator: 60_000) == "1001/30000")
        #expect(Proof.fraction(ticks: 60, numerator: 1001, denominator: 30_000) == "1001/500")
        #expect(Proof.fraction(ticks: 0, numerator: 1, denominator: 25) == "0/1")
        #expect(Proof.fraction(ticks: -512, numerator: 1, denominator: 12_800) == "-1/25")
        #expect(Proof.fraction(ticks: .max, numerator: 1001, denominator: 30_000) == nil)
        #expect(Proof.fraction(ticks: 1, numerator: 1, denominator: 0) == nil)
    }

    @Test("PACKETS: a line that cannot be read ends the proof — the first one is kept, nothing after it counts")
    func packetLedgerFaults() {
        let good = "0,0,512,100,\(Self.a)"
        for bad in ["0,N/A,512,100,\(Self.a)", "0,0,N/A,100,\(Self.a)", "0,0,512,100",
                    "7,0,512,100,\(Self.a)", "x,0,512,100,\(Self.a)", "0,0,512,-1,\(Self.a)", "0,0,512,100,MD5:abcd",
                    "0,0,512,100,SHA256:zz", "0,0,512,100,\(Self.a)0", "garbage"] {
            let result = sequences([good, bad, good])
            #expect(result.fault == bad)
            #expect(result.found[0]?.packets == 1, "nothing is folded after a fault: \(bad)")
        }
        // A carried stream whose time base ffprobe did not state cannot have its times expressed.
        #expect(sequences([good], carried: [(0, "")]).fault == good)
        #expect(sequences([good], carried: [(0, "0/1")]).fault == good)
        // A packet's own side data is folded with its bytes: present on one side only, or different, is a difference.
        let plain = sequences([good]).found[0]
        let withSide = sequences([good + ",Palette,1024"])
        #expect(withSide.fault == nil && withSide.found[0]?.packetSHA256 != plain?.packetSHA256)
        #expect(withSide.found[0]?.timingSHA256 == plain?.timingSHA256)
        // The sound's lines need only name their stream: its times are not folded (some are N/A in AVI).
        #expect(sequences(["1,N/A,N/A,4096,\(Self.b)"]).fault == nil)
        #expect(sequences(["", good]).fault == nil, "an empty line is not a packet")
    }

    // MARK: The decode pass's fold

    private static let h1 = String(repeating: "a1", count: 32)
    private static let h2 = String(repeating: "b2", count: 32)
    /// What the framehash muxer writes before the frames of a picture (0),
    /// the timeline (1) and one hashed channel (2).
    private static func head(pictureTimeBase: String = "1/12800", size: String = "320x240", sar: String = "1/1") -> [String] {
        ["#format: frame checksums", "#version: 2", "#hash: SHA256", "#software: Lavf63.1.102",
         "#tb 0: \(pictureTimeBase)", "#media_type 0: video", "#codec_id 0: rawvideo", "#dimensions 0: \(size)", "#sar 0: \(sar)",
         "#tb 1: 1/48000", "#media_type 1: audio", "#codec_id 1: pcm_s16le", "#sample_rate 1: 48000",
         "#channel_layout_name 1: mono", "#tb 2: 1/48000", "#media_type 2: audio", "#codec_id 2: pcm_s16le",
         "#sample_rate 2: 48000", "#channel_layout_name 2: mono",
         "#stream#, dts,        pts, duration,     size, hash"]
    }
    private func played(_ lines: [String], roles: [Proof.FrameLedger.Role] = [.picture(input: 0), .timeline, .channel(0)])
        -> (fault: String?, found: Proof.Played) {
        let ledger = Proof.FrameLedger(roles: roles, sampleRateHz: 48_000)
        lines.forEach(ledger.note)
        return (ledger.fault, ledger.played)
    }
    /// Frame lines padded as ffmpeg pads them.
    private static func frame(_ stream: Int, _ pts: Int, _ duration: Int, _ size: Int, _ hash: String = h1) -> String {
        "\(stream), \(String(repeating: " ", count: 9))\(pts), \(String(repeating: " ", count: 9))\(pts),   \(duration),   \(size), \(hash)"
    }

    @Test("FRAMES: the picture fold is the SEQUENCE of (time, duration, size, pixels) under its size and aspect — truth-checked against a digest made here")
    func frameLedgerPictureFold() throws {
        let frames = [Self.frame(0, 0, 512, 460_800), Self.frame(0, 512, 512, 460_800, Self.h2)]
        let good = played(Self.head() + frames)
        #expect(good.fault == nil)
        let picture = try #require(good.found.pictures[0])
        #expect(picture.frames == 2 && picture.firstSeconds == 0 && abs(picture.endSeconds - 0.08) < 1e-9)
        #expect(good.found.folded == [0: 2, 1: 0, 2: 0])
        // TRUTH: exactly these bytes, hashed here.
        var by = SHA256()
        by.update(data: Data("#dimensions 320x240\n#sar 1/1\n0/1 1/25 460800 \(Self.h1)\n1/25 1/25 460800 \(Self.h2)\n".utf8))
        #expect(picture.sha256 == by.finalize().map { String(format: "%02x", $0) }.joined())

        func digest(_ lines: [String]) -> String? { played(lines).found.pictures[0]?.sha256 }
        let base = try #require(digest(Self.head() + frames))
        // Another time, another duration, other pixels, another size, another order, a frame less: each moves it.
        for changed in [[Self.frame(0, 0, 512, 460_800), Self.frame(0, 513, 512, 460_800, Self.h2)],
                        [Self.frame(0, 0, 512, 460_800), Self.frame(0, 512, 1024, 460_800, Self.h2)],
                        [Self.frame(0, 0, 512, 460_800), Self.frame(0, 512, 512, 460_800, Self.h1)],
                        [Self.frame(0, 0, 512, 460_800), Self.frame(0, 512, 512, 460_801, Self.h2)],
                        [Self.frame(0, 0, 512, 460_800, Self.h2), Self.frame(0, 512, 512, 460_800, Self.h1)],
                        [Self.frame(0, 0, 512, 460_800)]] {
            #expect(digest(Self.head() + changed) != base)
        }
        // The same pixels shown at another size or stretched to another aspect are another picture.
        #expect(digest(Self.head(size: "240x320") + frames) != base)
        #expect(digest(Self.head(sar: "8/9") + frames) != base)
        // The same instants in another time base are the SAME: raw DV 1/60000 against QuickTime 1/30000.
        let rawDV = digest(Self.head(pictureTimeBase: "1/60000") + [Self.frame(0, 0, 2002, 9), Self.frame(0, 2002, 2002, 9)])
        let movie = digest(Self.head(pictureTimeBase: "1/30000") + [Self.frame(0, 0, 1001, 9), Self.frame(0, 1001, 1001, 9)])
        #expect(rawDV != nil && rawDV == movie)
        #expect(digest(Self.head(pictureTimeBase: "1/30000") + [Self.frame(0, 0, 1001, 9), Self.frame(0, 1002, 1001, 9)]) != movie,
                "one tick is a difference: no tolerance")
        // Frames of other streams change nothing of the picture.
        #expect(digest(Self.head() + frames + [Self.frame(1, 0, 1024, 2048), Self.frame(2, 0, 48_000, 96_000)]) == base)
        // A negative first time (a frame an edit list starts inside) is read, not refused.
        #expect(abs((played(Self.head() + [Self.frame(0, -512, 512, 9)]).found.pictures[0]?.firstSeconds ?? 0) + 0.04) < 1e-9)
    }

    @Test("FRAMES: the sound's TIMELINE is its runs of contiguous samples — independent of how a container packs them")
    func frameLedgerTimeline() {
        func runs(_ frames: [String]) -> [Proof.SoundSegment]? {
            let result = played(Self.head() + frames)
            return result.fault == nil ? result.found.soundSegments : nil
        }
        // 96,000 samples as 94 packets of 1024, or as 60 of 1600: one run from 0.
        let quickTime = (0..<93).map { Self.frame(1, $0 * 1024, 1024, 2048) } + [Self.frame(1, 95_232, 768, 1536)]
        let dv = (0..<60).map { Self.frame(1, $0 * 1600, 1600, 3200) }
        #expect(runs(quickTime) == [Proof.SoundSegment(start: 0, samples: 96_000)])
        #expect(runs(dv) == runs(quickTime))
        // A late start is a later run; one sample of rounding inside a run is the same run …
        #expect(runs([Self.frame(1, 24_000, 1024, 2048)]) == [Proof.SoundSegment(start: 24_000, samples: 1024)])
        #expect(runs([Self.frame(1, 0, 1024, 2048), Self.frame(1, 1025, 1024, 2048)]) == [Proof.SoundSegment(start: 0, samples: 2048)])
        // … and that rounding cannot add up: the third frame is held to the RUN's own line, not to the frame before.
        #expect(runs([Self.frame(1, 0, 1024, 2048), Self.frame(1, 1025, 1024, 2048), Self.frame(1, 2050, 1024, 2048)])
                == [Proof.SoundSegment(start: 0, samples: 2048), Proof.SoundSegment(start: 2050, samples: 1024)])
        // Codex #304-3: packets moved 10 ms each inside the recording, then back — every moved packet starts a run.
        let retimed = (0..<20).map { Self.frame(1, $0 * 1024 + 480 * max(0, min($0 - 5, 15 - $0)), 1024, 2048) }
        #expect((runs(retimed)?.count ?? 0) > 5, "\(String(describing: runs(retimed)))")
        #expect(runs((0..<20).map { Self.frame(1, $0 * 1024, 1024, 2048) })?.count == 1)
        // An overlap is a break too.
        #expect(runs([Self.frame(1, 0, 1024, 2048), Self.frame(1, 512, 1024, 2048)])?.count == 2)
        // More broken than can be held: could not check, never a truncated timeline.
        let shattered = (0..<(Proof.soundSegmentLimit + 1)).map { Self.frame(1, $0 * 2000, 1024, 2048) }
        #expect(played(Self.head() + shattered).fault == shattered.last)
        #expect(played(Self.head() + shattered.dropLast()).fault == nil)
        #expect(MemoryLayout<Proof.SoundSegment>.size * Proof.soundSegmentLimit <= 65_536, "the timeline is bounded")
    }

    @Test("FRAMES: each hashed channel folds its one-second pieces; the digest and the sample count are what is compared")
    func frameLedgerChannelFold() throws {
        let pieces = [Self.frame(2, 0, 48_000, 96_000), Self.frame(2, 48_000, 46_494, 92_988, Self.h2)]
        let good = played(Self.head() + pieces)
        #expect(good.fault == nil && good.found.channelSamples == [94_494] && good.found.folded[2] == 2)
        var by = SHA256()
        by.update(data: Data("96000 \(Self.h1)\n92988 \(Self.h2)\n".utf8))
        #expect(good.found.channelSHA256 == [by.finalize().map { String(format: "%02x", $0) }.joined()])
        // Where a piece is in time is the timeline's to say, not the digest's.
        #expect(played(Self.head() + [Self.frame(2, 480, 48_000, 96_000), Self.frame(2, 48_480, 46_494, 92_988, Self.h2)])
            .found.channelSHA256 == good.found.channelSHA256)
        // Other samples, or the same cut elsewhere: another digest.
        #expect(played(Self.head() + [Self.frame(2, 0, 48_000, 96_000, Self.h2), pieces[1]]).found.channelSHA256 != good.found.channelSHA256)
        #expect(played(Self.head() + [Self.frame(2, 0, 47_000, 94_000), pieces[1]]).found.channelSHA256 != good.found.channelSHA256)
        // Two channels are folded apart, in map order.
        let roles: [Proof.FrameLedger.Role] = [.timeline, .channel(0), .channel(1)]
        let two = played(["#tb 0: 1/48000", "#tb 1: 1/48000", "#tb 2: 1/48000", Self.frame(0, 0, 1024, 2048),
                          Self.frame(1, 0, 1024, 2048), Self.frame(2, 0, 1024, 2048, Self.h2)], roles: roles)
        #expect(two.fault == nil && two.found.channelSHA256.count == 2 && two.found.channelSHA256[0] != two.found.channelSHA256[1])
        #expect(two.found.pictures.isEmpty && two.found.soundSegments == [Proof.SoundSegment(start: 0, samples: 1024)])
    }

    @Test("FRAMES: a line that cannot be read ends the proof — a short, malformed or misnumbered line is never skipped")
    func frameLedgerFaults() {
        let good = Self.frame(0, 0, 512, 460_800)
        for bad in ["0, 0, 0, 512, 460800", "0, 0, 0, 512, 460800, \(Self.h1.dropLast())", "0, 0, 0, 512, 460800, \(Self.h1)0",
                    "0, 0, N/A, 512, 460800, \(Self.h1)", "0, 0, 0, 512, 0, \(Self.h1)", "0, 0, 0, -1, 460800, \(Self.h1)",
                    "9, 0, 0, 512, 460800, \(Self.h1)", "x, 0, 0, 512, 460800, \(Self.h1)", "garbage",
                    "0, 0, 0, 512, 460800, \(String(repeating: "zz", count: 32))", "0, 0, 0, 512, 460800, \(Self.h1), extra"] {
            let result = played(Self.head() + [good, bad, good])
            #expect(result.fault == bad)
            #expect(result.found.folded[0] == 1, "nothing is folded after a fault: \(bad)")
        }
        // No time base stated before a stream's first frame: its times cannot be read.
        #expect(played([good]).fault == good)
        #expect(played(["#tb 0: 0/1", good]).fault == "#tb 0: 0/1")
        #expect(played(["#tb 7: 1/25"]).fault == "#tb 7: 1/25", "a time base for a stream that was not asked for")
        // A header that arrives AFTER a stream's frames (a re-configured picture) is refused.
        #expect(played(Self.head() + [good, "#dimensions 0: 640x480"]).fault == "#dimensions 0: 640x480")
        // The sound's times must be in sample periods, and a sound frame holds samples.
        let coarse = Self.head().map { $0 == "#tb 1: 1/48000" ? "#tb 1: 1/1000" : $0 }
        #expect(played(coarse + [Self.frame(1, 0, 21, 2048)]).fault != nil)
        #expect(played(Self.head() + [Self.frame(1, 0, 0, 2048)]).fault != nil)
        // Every other "#" line describes the muxer; an empty line is not a frame.
        #expect(played(Self.head() + ["#extradata 0: 4, abcd", "", good]).fault == nil)
    }

    @Test("SCALE: an hour of DV — 108,000 packet lines, 108,000 frame lines and the sound's — folds inside 10 s in constant memory",
          .timeLimit(.minutes(1)))
    func ledgersAtScale() {
        var layout = Proof.FileLayout()
        layout.carried = [Proof.CarriedStream(index: 0, kind: "video", codec: "dvvideo", tag: "dvsd", timeBase: "1001/30000")]
        layout.sound = [Table.sound(1)]
        let packets = Proof.PacketLedger(layout: layout)
        let frames = Proof.FrameLedger(roles: [.picture(input: 0), .timeline, .channel(0)], sampleRateHz: 48_000)
        Self.head(pictureTimeBase: "1001/30000").forEach(frames.note)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<108_000 {
                packets.note("0,\(i),1,120000,\(Self.a)")
                packets.note("1,\(i * 1600),1600,6400,\(Self.b)")
                frames.note(Self.frame(0, i, 1, 518_400))
                frames.note(Self.frame(1, i * 1600, 1600, 3200))
                if i.isMultiple(of: 30) { frames.note(Self.frame(2, i * 1600, 48_000, 96_000)) }
            }
        }
        #expect(packets.fault == nil && frames.fault == nil)
        #expect(packets.sequences[0]?.packets == 108_000 && packets.sequences[1]?.packets == 108_000)
        let played = frames.played
        #expect(played.pictures[0]?.frames == 108_000 && played.folded == [0: 108_000, 1: 108_000, 2: 3_600])
        #expect(played.soundSegments == [Proof.SoundSegment(start: 0, samples: 172_800_000)], "one run, however many frames")
        #expect(abs((played.pictures[0]?.endSeconds ?? 0) - 3603.6) < 0.001)
        #expect(elapsed < .seconds(10), "435,600 lines took \(elapsed)")
        #expect(MemoryLayout<Proof.PacketSequence>.size < 64, "what is kept per stream is a count and two digests")
    }

    // MARK: How a picture is displayed

    @Test("DISPLAY: every display parameter of a paired picture must be equal; the reason names the first that is not")
    func displayTable() {
        func reason(_ change: @escaping (inout Proof.PictureConfiguration) -> Void) -> String? {
            let outcome = Proof.decide(Table.facts { change(&$0.balanced.carried[0].configuration) })
            if case .notProven(.pictureConfigurationDiffers(let what)) = outcome { return what }
            return nil
        }
        #expect(reason { $0.width = 304 } == "picture stream 0: width 320 → 304")
        #expect(reason { $0.height = 232 } == "picture stream 0: height 240 → 232")
        #expect(reason { $0.pixelFormat = "yuv420p" } == "picture stream 0: pixel format yuv422p10le → yuv420p")
        #expect(reason { $0.sampleAspect = "8:9" } == "picture stream 0: sample aspect ratio 1:1 → 8:9")
        #expect(reason { $0.displayAspect = "19:15" } == "picture stream 0: display aspect ratio 4:3 → 19:15")
        #expect(reason { $0.fieldOrder = "tt" } == "picture stream 0: field order progressive → tt")
        #expect(reason { $0.colorRange = "pc" } == "picture stream 0: colour range tv → pc")
        #expect(reason { $0.colorSpace = "bt709" } == "picture stream 0: colour space none → bt709")
        #expect(reason { $0.colorTransfer = "bt709" } == "picture stream 0: colour transfer none → bt709")
        #expect(reason { $0.colorPrimaries = "bt709" } == "picture stream 0: colour primaries none → bt709")
        // Side data: a display matrix gained, lost or changed.
        let upsideDown = #"[{"rotation":-180,"side_data_type":"Display Matrix"}]"#
        #expect(reason { $0.sideData = upsideDown } == "picture stream 0: side data none → \(upsideDown)")
        let both = Proof.decide(Table.facts {
            $0.original.carried[0].configuration.sideData = upsideDown
            $0.balanced.carried[0].configuration.sideData = upsideDown
        })
        #expect(both.isProven, "the same rotation on both sides is the same picture: \(both)")
        let lostRotation = Proof.decide(Table.facts { $0.original.carried[0].configuration.sideData = upsideDown })
        guard case .notProven(.pictureConfigurationDiffers) = lostRotation else { Issue.record("\(lostRotation)"); return }
        let soundSide = Proof.decide(Table.facts { $0.balanced.sound[0].sideData = "[{\"side_data_type\":\"x\"}]" })
        #expect(soundSide == .notProven(.pictureConfigurationDiffers(
            "audio stream 1: side data none → [{\"side_data_type\":\"x\"}]")))
        // Extradata is the DECODER's: the decoded frames answer for it, and a
        // difference is named — never a refusal on its own, never silence.
        #expect(reason { $0.extradataSHA256 = "SHA256:0123456789abcdef" } == nil)
        #expect(Proof.decide(Table.facts { $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:ab" })
            .differences.map(\.kind) == [.decoderConfiguration])
        #expect(Proof.decide(Table.facts {
            $0.original.carried[0].configuration.extradataSHA256 = "SHA256:aa"
            $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:aa"
        }).isProven)
        // A picture whose size ffprobe could not read is could-not-check, even when both sides agree.
        #expect(unchecked(Proof.decide(Table.facts {
            $0.original.carried[0].configuration.width = nil
            $0.balanced.carried[0].configuration.width = nil
        })) == "picture stream 0's size and pixel format could not be read")
    }

    // MARK: Channel layout

    @Test("LAYOUT: stereo means FL+FR — an unset layout is accepted only in a container measured to leave it unset")
    func channelLayoutTable() {
        func decide(_ layout: String, container: String = Table.movie, original: Bool = false) -> Proof.Outcome {
            Proof.decide(Table.facts {
                if original {
                    $0.original.sound[0].channelLayout = layout
                    $0.original.container = container
                } else {
                    $0.balanced.sound[0].channelLayout = layout
                    $0.balanced.container = container
                    $0.original.container = container
                    if !$0.original.containerWords.isDisjoint(with: Proof.containersLeavingLayoutUnset) {
                        $0.original.sound[0].channelLayout = ""
                    }
                }
            })
        }
        #expect(decide("stereo").isProven)
        for odd in ["2 channels (FC+LFE)", "FC+LFE", "mono", "downmix", "2 channels"] {
            #expect(decide(odd) == .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: odd)))
            #expect(decide(odd, container: "matroska,webm") == .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: odd)))
            #expect(decide(odd, original: true) == .notProven(.channelLayoutNotStereo(file: "the original", layout: odd)))
        }
        // Unset: only where Balance Audio's own output was measured to leave it unset.
        #expect(Proof.containersLeavingLayoutUnset == ["matroska", "mxf", "avi", "wav"])
        for container in ["matroska,webm", "mxf", "avi", "wav"] {
            #expect(decide("", container: container).isProven, "\(container)")
            #expect(decide("unknown", container: container).isProven, "\(container)")
        }
        for container in [Table.movie, "dv", "", "mpegts"] {
            #expect(decide("", container: container) == .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: "")),
                    "\(container)")
        }
        // A one-channel original says "mono".
        #expect(Proof.layoutIsPlain(Table.sound(channels: 1), in: Proof.FileLayout(container: Table.movie)))
        #expect(!Proof.layoutIsPlain(Table.sound(channels: 1, layout: "stereo"), in: Proof.FileLayout(container: Table.movie)))
        // An original with any other channel count is not a one-sided stereo track at all.
        #expect(unchecked(Proof.decide(Table.facts { $0.original.sound[0].channels = 3 }))
                == "the original's sound has 3 channels, which a one-sided track cannot have")
    }

    // MARK: Whole reads

    @Test("WHOLE READS: a decode pass that stopped short, dropped a frame on the way, met a decode error, or decoded another length than the header states is COULD NOT CHECK")
    func readVerdictTable() {
        func why(_ change: @escaping (inout Proof.Facts) -> Void) -> String? { unchecked(Proof.decide(Table.poisoned(change))) }
        #expect(why { $0.originalRead = nil } == "the original's decode pass gave no account of what it read")
        #expect(why { $0.balancedRead = nil } == "the balanced copy's decode pass gave no account of what it read")
        #expect(why { $0.originalRead?.streams[0]?.packets = 25 }
                == "the original was not read to the end (stream 0: 25 of 50 packets)")
        #expect(why { $0.balancedRead?.streams[1]?.packets = 47 }
                == "the balanced copy was not read to the end (stream 1: 47 of 94 packets)")
        #expect(why { $0.originalRead?.streams[0] = nil }?.contains("packets not counted") == true)
        #expect(why { $0.original.sound[0].packets = nil }?.contains("packets not counted") == true)
        #expect(why { $0.originalRead?.streams[1]?.decodeErrors = 2 } == "the original did not decode cleanly (stream 1)")
        #expect(why { $0.balancedRead?.streams[0]?.decodeErrors = nil } == "the balanced copy did not decode cleanly (stream 0)")
        // ffmpeg says it wrote 50 frames; 49 arrived.
        #expect(why { $0.balancedRead?.folded[0] = 49 }
                == "the balanced copy's decoded frames did not all arrive (ffmpeg wrote 148, 147 were read)")
        #expect(why { $0.originalRead?.muxed[2] = nil } != nil)
        #expect(why { $0.originalRead?.muxed = [:]; $0.originalRead?.folded = [:] } != nil, "nothing at all is not agreement")
        // A header duration that lies, either way: the picture's …
        #expect(why { $0.balanced.carried[0].statedSeconds = 4 }
                == "the balanced copy was not read to the end (picture stream 0: 2.000 s decoded, 4.000 s stated)")
        #expect(why { $0.original.carried[0].statedSeconds = 1 }
                == "the original was not read to the end (picture stream 0: 2.000 s decoded, 1.000 s stated)")
        #expect(why { $0.originalRead?.pictures[0]?.frames = 0 } == "the original's picture stream 0 gave no frames")
        // … and the sound's.
        #expect(why { $0.originalRead?.soundSegments = [Proof.SoundSegment(start: 0, samples: 48_000)] }
                == "the original was not read to the end (48000 sound samples decoded, 2.000 s stated)")
        #expect(why { $0.balanced.sound[0].statedSeconds = 2.5 }?.contains("96000 sound samples decoded, 2.500 s stated") == true)
        #expect(why { $0.balancedRead?.soundSegments = nil } == "the balanced copy's sound gave no samples")
        #expect(why { $0.balancedRead?.soundSegments = [] } == "the balanced copy's sound gave no samples")
        // A container that states no length (AVI's sound, raw streams) is held by everything else.
        #expect(Proof.decide(Table.poisoned {
            $0.original.sound[0].statedSeconds = nil
            $0.original.carried[0].statedSeconds = nil
        }).isProven)
        // Within the slack: one sample for the sound (raw DV: 94494 samples for 1.968633 s), one tick for the picture.
        #expect(Proof.decide(Table.poisoned {
            $0.original.sound[0].statedSeconds = 2.000_008
            $0.original.carried[0].statedSeconds = 2.000_07
        }).isProven)
        #expect(why { $0.original.carried[0].statedSeconds = 2.000_09 } != nil)
        #expect(why { $0.originalRead?.soundSegments = [Proof.SoundSegment(start: 0, samples: 95_990)] } != nil)
        // Raw DV states the PICTURE's length for its sound; part-way through DV's 1600/1602 cadence
        // the sound is up to 1.6 samples short of it (measured on a 4:47 file). Two samples is the slack; three is short.
        #expect(Proof.statedLengthToleranceSamples == 2)
        #expect(Proof.decide(Table.poisoned { $0.original.sound[0].statedSeconds = 2 + 1.6 / 48_000 }).isProven)
        #expect(why { $0.original.sound[0].statedSeconds = 2 + 3.0 / 48_000 } != nil)
        // A coarse time base widens the slack to its tick — never past 1 ms.
        var matroska = Table.sound()
        matroska.tickSeconds = 0.001
        #expect(matroska.timingSlackSeconds == 0.001)
        matroska.tickSeconds = 1
        #expect(matroska.timingSlackSeconds == Proof.timingSlackCeilingSeconds)
        // A partial read outranks what the digests would say.
        #expect(why {
            $0.balancedRead?.streams[0]?.packets = 25
            $0.balancedRead?.channelSHA256[0] = Table.otherHash
        }?.contains("not read to the end") == true)
        // The sound's PACKET count is the muxer's chunking and is not compared across files (raw DV 59 → mov 118).
        #expect(Proof.decide(Table.facts { $0.balanced.sound[0].packets = 188 }).isProven)
    }

    // MARK: The decode pass's log

    static let tag = "vs0123"
    /// A real ffmpeg 9.0 log of one decode pass over a two-track DV file, shortened.
    static let cleanLog = """
    [verbose] Routing option err_detect to both codec and muxer layer
    [in#0/dv @ 0x7861038000] [warning] Estimating duration from bitrate, this may be inaccurate
    [info] Input #0, dv, from '/tmp/a.dv':
    [info]   Metadata:
    [info]     comment         : first line
                              : second line
    [info]   Stream #0:2 (pcm_s16le) -> astats:default
    [aist#0:1/pcm_s16le @ 0x786901c480] [dec:pcm_s16le @ 0x786903c3c0] [verbose] Decoder returned EOF, finishing
    [astats@\(tag)s2 @ 0x7908c021c0] [info] Channel: 1
    [astats@\(tag)s2 @ 0x7908c021c0] [info] Peak level dB: -inf
    [astats@\(tag)s2 @ 0x7908c021c0] [info] Channel: 2
    [astats@\(tag)s2 @ 0x7908c021c0] [info] Peak level dB: -71.250000
    [astats@\(tag)s1 @ 0x7908c01b00] [info] Channel: 1
    [astats@\(tag)s1 @ 0x7908c01b00] [info] Peak level dB: -3.099895
    [astats@\(tag)s1 @ 0x7908c01b00] [info] Channel: 2
    [astats@\(tag)s1 @ 0x7908c01b00] [info] Peak level dB: -inf
    [out#0/framehash @ 0x7908c00b40] [verbose] Output file #0 (pipe:):
    [out#0/framehash @ 0x7908c00b40] [verbose]   Output stream #0:0 (video): 59 frames encoded; 59 packets muxed (40780800 bytes);
    [out#0/framehash @ 0x7908c00b40] [verbose]   Output stream #0:1 (audio): 59 frames encoded (94494 samples); 59 packets muxed (188988 bytes);
    [out#0/framehash @ 0x7908c00b40] [verbose]   Output stream #0:2 (audio): 2 frames encoded (94494 samples); 2 packets muxed (188988 bytes);
    [in#0/dv @ 0x7908c14000] [verbose] Input file #0 (/tmp/a.dv):
    [in#0/dv @ 0x7908c14000] [verbose]   Input stream #0:0 (video): 59 packets read (14160000 bytes); 59 frames decoded; 0 decode errors;
    [in#0/dv @ 0x7908c14000] [verbose]   Input stream #0:1 (audio): 59 packets read (377976 bytes); 59 frames decoded; 0 decode errors (94494 samples);
    [in#0/dv @ 0x7908c14000] [verbose]   Input stream #0:2 (audio): 59 packets read (377976 bytes); 59 frames decoded; 0 decode errors (94494 samples);
    [in#0/dv @ 0x7908c14000] [verbose]   Total: 177 packets (14915952 bytes) demuxed
    [verbose]
    [verbose] Exiting with exit code 0

    """

    private func report(_ log: String, tag: String = BalancedCopyProofRuleTests.tag) -> Proof.ReadReport? {
        try? Proof.readReport(fromStderr: log, runTag: tag).get()
    }
    private func fault(_ log: String) -> String? {
        if case .failure(let fault) = Proof.readReport(fromStderr: log, runTag: Self.tag) { return fault.line }
        return nil
    }

    @Test("LOG: a clean decode-pass log gives each input stream's packets and decode errors, each output's frames, and every channel's peak of every measured sound track")
    func readReportFromACleanLog() throws {
        let read = try #require(report(Self.cleanLog), "\(String(describing: fault(Self.cleanLog)))")
        #expect(read.streams == [
            0: Proof.StreamRead(packets: 59, decodeErrors: 0), 1: Proof.StreamRead(packets: 59, decodeErrors: 0),
            2: Proof.StreamRead(packets: 59, decodeErrors: 0)
        ])
        #expect(read.muxed == [0: 59, 1: 59, 2: 2])
        #expect(read.peaksDBFS == [1: [-3.099895, -.infinity], 2: [-.infinity, -71.25]])
        // The log's half only: what was folded comes from the frames.
        #expect(read.folded.isEmpty && read.pictures.isEmpty && read.soundSegments == nil)
        // Without a run tag (the copy's pass) no peak is read.
        #expect(report(Self.cleanLog, tag: "")?.peaksDBFS == [:])
        // A line that names no error count gives none — and the read is then not whole.
        let older = Proof.streamCount(fromPayload: "  Input stream #0:12 (audio): 94 packets read (384000 bytes); 94 frames decoded (96000 samples); ",
                                      side: "Input", counting: " packets read")
        #expect(older?.index == 12 && older?.count == 94 && older?.decodeErrors == nil)
        #expect(Proof.streamCount(fromPayload: "  Output stream #0:0 (video): 50 packets muxed (1 bytes); ", side: "Input",
                                  counting: " packets read") == nil)
        #expect(Proof.streamCount(fromPayload: "  Input stream #0:0 (video): packets read", side: "Input", counting: " packets read") == nil)
    }

    @Test("LOG: ANY line -v error would have printed, any line with no level, or a log that does not end with ffmpeg's clean exit refuses the pass")
    func readReportRefusals() {
        let lines = Self.cleanLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func with(_ extra: String, at position: Int) -> String {
            var copy = lines
            copy.insert(extra, at: position)
            return copy.joined(separator: "\n")
        }
        // Error, fatal, panic — wherever they fall.
        for level in ["error", "fatal", "panic"] {
            let line = "[in#0/mov @ 0x7861038000] [\(level)] Error during demuxing: Input/output error"
            for position in [0, 5, lines.count - 2] {
                #expect(fault(with(line, at: position)) == line, "\(level) at \(position)")
            }
            #expect(fault(with("[\(level)] bare", at: 3)) == "[\(level)] bare")
        }
        // What a pinned format prints when a frame would need converting.
        let convert = "[fc#0 @ 0x7b4ec08000] [error] Error reinitializing filters!"
        #expect(fault(with(convert, at: 8)) == convert)
        // #308-1: a picture or sound that changes shape mid-stream restarts the filter graph. framehash
        // states a stream's size once, so what follows cannot be held: the pass is refused.
        for change in ["[fc#0 @ 0x7624c04000] [info] Reconfiguring filter graph because video parameters changed to yuv420p(unknown, unknown), 32x96, unspecified alpha",
                       "[fc#0 @ 0x1] [info] Reconfiguring filter graph because audio parameters changed to 44100 Hz, stereo, s16"] {
            #expect(fault(with(change, at: 8)) == change)
        }
        // A line that carries no level: a wrapper's complaint, a library's own stderr.
        for stray in ["Error during demuxing: Input/output error", "[in#0/mov @ 0x0] Error during demuxing",
                      "dyld: warning", "[not a level] text"] {
            #expect(fault(with(stray, at: 0)) == stray, "first line: \(stray)")
            #expect(fault(with(stray, at: 9)) == stray, "mid-log: \(stray)")
        }
        // … after ffmpeg's last line too (the injected-wrapper reproduction).
        #expect(fault(Self.cleanLog + "[in#0/mov @ 0x0] Error during demuxing: Input/output error\n") != nil)
        #expect(fault(Self.cleanLog + "[info] anything at all\n") == "[info] anything at all")
        // A metadata continuation is tolerated ONLY straight after an info line, and only in its indented shape.
        #expect(Proof.isMetadataContinuation("                      : second line"))
        #expect(!Proof.isMetadataContinuation("  : second line"))
        #expect(!Proof.isMetadataContinuation("                      second line"))
        #expect(fault(with("                      : orphan", at: 0)) != nil)
        #expect(fault(with("                      : after a verbose line", at: 1)) != nil)
        // No clean exit line: killed, truncated, or exit code not 0.
        #expect(fault(lines.dropLast(2).joined(separator: "\n")) != nil)
        #expect(fault(Self.cleanLog.replacingOccurrences(of: "exit code 0", with: "exit code 1")) != nil)
        #expect(fault("") == "ffmpeg reported nothing about what it read")
        // One stream accounted for twice (a forged line in a metadata KEY) is refused — input or output.
        #expect(fault(with("[verbose]   Input stream #0:0 (video): 50 packets read (1 bytes); ", at: 4)) != nil)
        #expect(fault(with("[verbose]   Output stream #0:1 (audio): 9 packets muxed (1 bytes); ", at: 4)) != nil)
        // Peaks: out of order, doubled, unreadable, a peak before any channel, a stream that cannot be read.
        let peak = "[astats@\(Self.tag)s1 @ 0x1] [info] Peak level dB: -3.0"
        #expect(fault(with(peak, at: 14)) == peak, "two peaks for one channel")
        #expect(fault(with(peak, at: 12)) == peak, "a peak before its channel")
        #expect(fault(with("[astats@\(Self.tag)s1 @ 0x1] [info] Channel: 3", at: 12)) != nil)
        #expect(fault(with("[astats@\(Self.tag)sx @ 0x1] [info] Channel: 1", at: 12)) != nil)
        #expect(fault(Self.cleanLog.replacingOccurrences(of: "dB: -71.250000", with: "dB: quiet")) != nil)
        // Lines from an astats instance of ANOTHER name (the file cannot know the tag) are not peaks.
        let foreign = with("[astats@other @ 0x1] [info] Peak level dB: -99.0", at: 9)
        #expect(report(foreign)?.peaksDBFS == [1: [-3.099895, -.infinity], 2: [-.infinity, -71.25]])
    }

    @Test("LOG: logRecord reads components, level and payload; a line that does not start that way is nil")
    func logRecordParse() {
        let record = Proof.logRecord("[aist#0:1/pcm_s16le @ 0x1] [dec:pcm_s16le @ 0x2] [verbose] Decoder returned EOF")
        #expect(record?.components == ["aist#0:1/pcm_s16le @ 0x1", "dec:pcm_s16le @ 0x2"])
        #expect(record?.level == "verbose" && record?.payload == "Decoder returned EOF")
        #expect(Proof.logRecord("[info]   Metadata:")?.payload == "  Metadata:")
        #expect(Proof.logRecord("[verbose]")?.payload.isEmpty == true)
        #expect(Proof.logRecord("[error] x")?.level == "error")
        for line in ["plain text", "", "[", "[unclosed", "[x] [info] not a component", " [info] indented",
                     "text [error] inside", "[in#0 @ 0x1] no level"] {
            #expect(Proof.logRecord(Substring(line)) == nil, "\(line)")
        }
        #expect(Proof.count(before: " packets read", in: "x: 94 packets read") == 94)
        #expect(Proof.count(before: " packets read", in: "x: packets read") == nil)
        #expect(Proof.count(before: " nothing", in: "12 something") == nil)
    }

    // MARK: One line

    @Test("ONE LINE: singleLine writes out every line break and control character; quoted keeps a path inside its quotes")
    func singleLineAndQuoted() {
        #expect(Proof.singleLine("plain — text é 日本") == "plain — text é 日本")
        #expect(Proof.singleLine("a\nb") == "a\\u{A}b")
        #expect(Proof.singleLine("a\r\nb\tc") == "a\\u{D}\\u{A}b\\u{9}c")
        #expect(Proof.singleLine("a\u{2028}b\u{2029}c\u{0085}d") == "a\\u{2028}b\\u{2029}c\\u{85}d")
        #expect(Proof.singleLine("a\u{202E}b\u{0000}c\u{007F}d") == "a\\u{202E}b\\u{0}c\\u{7F}d")
        #expect(Proof.quoted("/a/b.mov") == "\"/a/b.mov\"")
        #expect(Proof.quoted("a\" · balanced copy \"b") == "\"a\\\" · balanced copy \\\"b\"")
        #expect(Proof.quoted("a\\b") == "\"a\\\\b\"")
        let line = Proof.logLine(original: "a\" — PROVEN \"x.mov", balanced: "b.mov", outcome: .couldNotCheck("r"))
        #expect(line == "balanced copy proof: OUTCOME COULD NOT CHECK — original \"a\\\" — PROVEN \\\"x.mov\" · balanced copy \"b.mov\" — r")
    }

    @Test("SCALE: a 2,000-line decode-pass log is read once, inside its budget", .timeLimit(.minutes(1)))
    func logAtScale() {
        let lines = Self.cleanLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let padding = (0..<2_000).map { "[info]     tag\($0)           : value \($0)" }
        let long = (lines.prefix(4) + padding + lines.dropFirst(4)).joined(separator: "\n")
        var read: Proof.ReadReport?
        let parse = ContinuousClock().measure { read = report(long) }
        #expect(read?.streams[1]?.packets == 59 && read?.muxed.count == 3)
        #expect(parse < .seconds(2), "a 2,000-line log took \(parse)")
    }
}
