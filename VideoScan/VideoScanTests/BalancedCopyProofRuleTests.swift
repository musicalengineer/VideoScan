// BalancedCopyProofRuleTests.swift
// The rules BalancedCopyProof gained after Codex review #301, as pure
// tables: the discarded channel (F1), timing (F2), whole reads and the hash
// pass's log (F3), decoder configuration (F5), channel layout (F6). No
// file, no subprocess — the same rules on real media are in
// BalancedCopyProofHardeningTests.

import Foundation
import Testing
@testable import VideoScan

@Suite("Balanced copy proof — the rules added after Codex #301")
struct BalancedCopyProofRuleTests {

    typealias Proof = BalancedCopyProof
    typealias Table = BalancedCopyProofDecisionTests

    private func timingReason(_ outcome: Proof.Outcome) -> String? {
        if case .notProven(.timingDiffers(let what)) = outcome { return what }
        return nil
    }
    private func unchecked(_ outcome: Proof.Outcome) -> String? {
        if case .couldNotCheck(let why) = outcome { return why }
        return nil
    }

    // MARK: F1 — the discarded channel

    @Test("F1: the channel left behind must PEAK at or under the ceiling; above it the original is kept")
    func discardedChannelTable() {
        #expect(Proof.discardedChannelPeakCeilingDBFS == -60.0, "Rick rules on this number; a change is his")
        func decide(_ peaks: [Double], class c: AudioChannelClass = .leftOnly) -> Proof.Outcome {
            Proof.decide(Table.poisoned {
                $0.originalClass = c
                $0.originalRead?.channelPeaksDBFS = peaks
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
            #expect(unchecked(decide(peaks))?.contains("other channel was not measured") == true, "\(peaks)")
        }
        // A one-channel original leaves nothing behind, whatever was (not) measured.
        let mono = Proof.decide(Table.facts {
            $0.originalClass = .mono
            $0.original.sound = [Table.sound(channels: 1)]
        })
        guard case .proven(let evidence) = mono else { Issue.record("\(mono)"); return }
        #expect(evidence.discarded == nil)
    }

    @Test("F1: level() writes a peak the way the log shows it")
    func levelText() {
        #expect(Proof.level(-48.24) == "−48.2 dBFS")
        #expect(Proof.level(-71.3) == "−71.3 dBFS")
        #expect(Proof.level(0) == "0.0 dBFS")
        #expect(Proof.level(-.infinity) == "digital silence")
        #expect(Proof.level(.nan) == "unreadable")
    }

    // MARK: F2 — timing

    @Test("F2: a paired stream that starts, lasts, counts or runs differently is not proven, naming what moved")
    func pictureTimingTable() {
        func decide(_ change: @escaping (inout Proof.StreamTiming) -> Void) -> Proof.Outcome {
            Proof.decide(Table.facts { change(&$0.balanced.carried[0].timing) })
        }
        #expect(timingReason(decide { $0.packets = 49 }) == "video stream 0 has 50 packets, the balanced copy 49")
        #expect(timingReason(decide { $0.startSeconds = 0.04 })
                == "video stream 0 starts at 0.000000 s, in the balanced copy at 0.040000 s")
        #expect(timingReason(decide { $0.durationSeconds = 3.96 })
                == "video stream 0 lasts 2.000000 s, in the balanced copy 3.960000 s")
        #expect(timingReason(decide { $0.realFrameRate = "25/2" }) == "video stream 0 frame rate 25/1 → 25/2")
        #expect(timingReason(decide { $0.averageFrameRate = "1250/99" })
                == "video stream 0 average frame rate 25/1 → 1250/99")
        // Stated on one side only is a difference; unstated on both is not.
        #expect(timingReason(decide { $0.durationSeconds = nil })?.contains("no stated time") == true)
        #expect(timingReason(decide { $0.startSeconds = nil })?.contains("no stated time") == true)
        #expect(Proof.decide(Table.facts {
            $0.original.carried[0].timing.durationSeconds = nil
            $0.balanced.carried[0].timing.durationSeconds = nil
        }).isProven)
        // Uncounted packets are could-not-check on either side.
        #expect(unchecked(decide { $0.packets = nil })?.contains("could not be counted") == true)
        #expect(unchecked(Proof.decide(Table.facts { $0.original.carried[0].timing.packets = nil })) != nil)
        // The tolerance is ffprobe's printing resolution: one microsecond.
        #expect(Proof.pictureTimingToleranceSeconds == 0.000_001)
        #expect(decide { $0.durationSeconds = 2.000_000_5 }.isProven)
        #expect(!decide { $0.durationSeconds = 2.000_002 }.isProven)
        // A time base may differ (raw DV 1/60000 → QuickTime 1/30000): seconds are what is compared.
        #expect(decide { $0.tickSeconds = 1.0 / 30_000 }.isProven)
    }

    @Test("F2: the sound's start, length, distance from the picture and the file's length are held within one sample period")
    func soundTimingTable() {
        func decide(_ change: @escaping (inout Proof.Facts) -> Void) -> Proof.Outcome { Proof.decide(Table.facts(change)) }
        let sample = 1.0 / 48_000
        // Codex's reproduction: the sound alone starts half a second late.
        #expect(timingReason(decide { $0.balanced.sound[0].timing.startSeconds = 0.5 })
                == "the sound starts at 0.000000 s, in the balanced copy at 0.500000 s")
        #expect(timingReason(decide { $0.balanced.sound[0].timing.durationSeconds = 1.99 })
                == "the sound lasts 2.000000 s, in the balanced copy 1.990000 s")
        #expect(timingReason(decide { $0.balanced.durationSeconds = 2.5 })
                == "the file lasts 2.000000 s, the balanced copy 2.500000 s")
        #expect(timingReason(decide { $0.balanced.durationSeconds = nil })?.contains("no stated time") == true)
        // Within one sample period: the raw DV → QuickTime case (1.968633 s against 1.968625 s).
        #expect(decide { $0.balanced.sound[0].timing.durationSeconds = 2 - 0.4 * sample }.isProven)
        #expect(!decide { $0.balanced.sound[0].timing.durationSeconds = 2 - 1.5 * sample }.isProven)
        #expect(!decide { $0.balanced.sound[0].timing.startSeconds = 1.5 * sample }.isProven)
        // Picture and sound both moved by the same amount inside the picture's
        // tolerance cannot happen; moved apart is caught as the offset.
        let apart = decide {
            $0.original.carried[0].timing.startSeconds = 0.000_000_6
            $0.balanced.sound[0].timing.startSeconds = 0.000_020
            $0.balanced.carried[0].timing.startSeconds = 0
            $0.original.sound[0].timing.startSeconds = 0.000_000_2
        }
        #expect(apart.isProven, "all inside the tolerances: \(apart)")
        // A coarse time base widens the slack to its tick — never past 1 ms.
        #expect(Table.sound().timingSlackSeconds == sample)
        var matroska = Table.sound()
        matroska.timing.tickSeconds = 0.001
        #expect(matroska.timingSlackSeconds == 0.001)
        matroska.timing.tickSeconds = 1
        #expect(matroska.timingSlackSeconds == Proof.soundTimingSlackCeilingSeconds)
        #expect(decide {
            $0.balanced.sound[0].timing.tickSeconds = 0.001
            $0.balanced.sound[0].timing.durationSeconds = 2.0004
            $0.balanced.durationSeconds = 2.0004
        }.isProven, "Matroska rounds a stream's length to the millisecond")
        // The sound's PACKET count is the muxer's chunking and is not compared (raw DV 59 → mov 118).
        #expect(decide { $0.balanced.sound[0].timing.packets = 188 }.isProven)
    }

    @Test("F2: when the container changed, the copy's average frame rate is held to the original's REAL rate")
    func containerChangeFrameRateRule() {
        func rawDV(_ change: @escaping (inout Proof.Facts) -> Void) -> Proof.Outcome {
            Proof.decide(Table.facts {
                $0.original.container = "dv"
                $0.original.carried[0].timing.realFrameRate = "30000/1001"
                $0.original.carried[0].timing.averageFrameRate = "60000/1"      // the raw-DV demuxer's bogus average
                $0.balanced.carried[0].timing.realFrameRate = "30000/1001"
                $0.balanced.carried[0].timing.averageFrameRate = "30000/1001"
                change(&$0)
            })
        }
        #expect(rawDV { _ in }.isProven)
        #expect(timingReason(rawDV { $0.balanced.carried[0].timing.averageFrameRate = "60000/1" })
                == "video stream 0 average frame rate 30000/1001 → 60000/1")
        #expect(timingReason(rawDV { $0.balanced.carried[0].timing.realFrameRate = "25/1" }) != nil)
        // The same two rates in an UNCHANGED container are a difference.
        #expect(timingReason(rawDV { $0.original.container = Table.movie }) != nil)
    }

    // MARK: F5 — decoder configuration

    @Test("F5: every decoder parameter of a paired stream must be equal; the reason names the first that is not")
    func configurationTable() {
        func reason(_ change: @escaping (inout Proof.PictureConfiguration) -> Void) -> String? {
            let outcome = Proof.decide(Table.facts { change(&$0.balanced.carried[0].configuration) })
            if case .notProven(.pictureConfigurationDiffers(let what)) = outcome { return what }
            return nil
        }
        #expect(reason { $0.width = 304 } == "video stream 0: width 320 → 304")
        #expect(reason { $0.height = 232 } == "video stream 0: height 240 → 232")
        #expect(reason { $0.pixelFormat = "yuv420p" } == "video stream 0: pixel format yuv422p10le → yuv420p")
        #expect(reason { $0.sampleAspect = "8:9" } == "video stream 0: sample aspect ratio 1:1 → 8:9")
        #expect(reason { $0.displayAspect = "19:15" } == "video stream 0: display aspect ratio 4:3 → 19:15")
        #expect(reason { $0.fieldOrder = "tt" } == "video stream 0: field order progressive → tt")
        #expect(reason { $0.colorRange = "pc" } == "video stream 0: colour range tv → pc")
        #expect(reason { $0.colorSpace = "bt709" } == "video stream 0: colour space none → bt709")
        #expect(reason { $0.colorTransfer = "bt709" } == "video stream 0: colour transfer none → bt709")
        #expect(reason { $0.colorPrimaries = "bt709" } == "video stream 0: colour primaries none → bt709")
        // Extradata: gained, lost or changed — all refused (no job output of the matrix gains any).
        #expect(reason { $0.extradataSHA256 = "SHA256:0123456789abcdef" } == "video stream 0: codec extradata none → SHA256:0123456789ab")
        let lost = Proof.decide(Table.facts { $0.original.carried[0].configuration.extradataSHA256 = "SHA256:aa" })
        guard case .notProven(.pictureConfigurationDiffers) = lost else { Issue.record("\(lost)"); return }
        #expect(Proof.decide(Table.facts {
            $0.original.carried[0].configuration.extradataSHA256 = "SHA256:aa"
            $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:aa"
        }).isProven)
        // A timecode track's extradata is held too.
        let timecode = Proof.decide(Table.facts {
            $0.original.carried = [Table.video(0), Table.timecode(2)]
            $0.balanced.carried = [Table.video(0), Table.timecode(2)]
            $0.balanced.carried[1].configuration.extradataSHA256 = "SHA256:bb"
        })
        guard case .notProven(.pictureConfigurationDiffers(let what)) = timecode else { Issue.record("\(timecode)"); return }
        #expect(what.hasPrefix("data stream 2: codec extradata"))
        // A picture whose size ffprobe could not read is could-not-check, even when both sides agree.
        #expect(unchecked(Proof.decide(Table.facts {
            $0.original.carried[0].configuration.width = nil
            $0.balanced.carried[0].configuration.width = nil
        }))?.contains("could not be read") == true)
    }

    // MARK: F6 — channel layout

    @Test("F6: stereo means FL+FR — an unset layout is accepted only in a container measured to leave it unset")
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
        #expect(unchecked(Proof.decide(Table.facts { $0.original.sound[0].channels = 3 })) != nil)
    }

    // MARK: F3 — whole reads

    @Test("F3: each hash pass must have read exactly what ffprobe counted, or the pair could not be checked")
    func readVerdictTable() {
        func why(_ change: @escaping (inout Proof.Facts) -> Void) -> String? { unchecked(Proof.decide(Table.poisoned(change))) }
        #expect(why { $0.originalRead = nil } == "the original's hash pass gave no account of what it read")
        #expect(why { $0.balancedRead = nil } == "the balanced copy's hash pass gave no account of what it read")
        #expect(why { $0.originalRead?.streams[0]?.packets = 25 }
                == "the original was not read to the end (stream 0: 25 of 50 packets)")
        #expect(why { $0.balancedRead?.streams[1]?.packets = 47 }
                == "the balanced copy was not read to the end (stream 1: 47 of 94 packets)")
        #expect(why { $0.originalRead?.streams[0] = nil }?.contains("packets not counted") == true)
        #expect(why { $0.original.sound[0].timing.packets = nil }?.contains("packets not counted") == true)
        #expect(why { $0.originalRead?.streams[1]?.samples = 48_000 }
                == "the original was not read to the end (48000 sound samples decoded, 2.000000 s stated)")
        #expect(why { $0.balancedRead?.streams[1]?.samples = nil } == "the balanced copy's sound did not decode cleanly")
        #expect(why { $0.balancedRead?.streams[1]?.samples = 0 } == "the balanced copy's sound did not decode cleanly")
        #expect(why { $0.originalRead?.streams[1]?.decodeErrors = 2 } == "the original's sound did not decode cleanly")
        // An older ffmpeg that prints no error count is not held against the read.
        let noErrorCount = Proof.decide(Table.poisoned { $0.originalRead?.streams[1]?.decodeErrors = nil })
        #expect(noErrorCount.isProven, "\(noErrorCount)")
        // Within one sample of the stated length (raw DV: 94494 samples for 1.968633 s).
        #expect(Proof.decide(Table.poisoned {
            $0.original.sound[0].timing.durationSeconds = 2.000_008
            $0.balanced.sound[0].timing.durationSeconds = 2.000_008
        }).isProven)
        #expect(why { $0.originalRead?.streams[1]?.samples = 95_990 } != nil)
        // A partial read outranks what the hashes would say.
        #expect(why {
            $0.balancedRead?.streams[0]?.packets = 25
            $0.balanced.carried[0].packetSHA256 = Table.otherHash
        }?.contains("not read to the end") == true)
    }

    // MARK: F3 — the hash pass's log

    static let tag = "vs0123"
    /// A real ffmpeg 9.0 log of one hash pass, shortened.
    static let cleanLog = """
    [verbose] Routing option err_detect to both codec and muxer layer
    [in#0/dv @ 0x7861038000] [warning] Estimating duration from bitrate, this may be inaccurate
    [info] Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/tmp/a.mov':
    [info]   Metadata:
    [info]     comment         : first line
                              : second line
    [aost#0:1 @ 0x7868ca4300] [warning] Multiple -codec/-c/-acodec/-vcodec/-scodec/-dcodec options specified for stream 1, only the last option '-codec:a pcm_s16le' will be used.
    [aost#0:1/pcm_s16le @ 0x7868ca4300] [verbose]
    [aist#0:1/pcm_s16le @ 0x786901c480] [dec:pcm_s16le @ 0x786903c3c0] [verbose] Decoder returned EOF, finishing
    [astats@\(tag) @ 0x7869030cc0] [info] Channel: 1
    [astats@\(tag) @ 0x7869030cc0] [info] Peak level dB: -3.099895
    [astats@\(tag) @ 0x7869030cc0] [info] Channel: 2
    [astats@\(tag) @ 0x7869030cc0] [info] Peak level dB: -inf
    [out#0/streamhash @ 0x7869030480] [verbose]   Output stream #0:0 (video): 50 packets muxed (439967 bytes);
    [in#0/mov,mp4,m4a,3gp,3g2,mj2 @ 0x786903c000] [verbose] Input file #0 (/tmp/a.mov):
    [in#0/mov,mp4,m4a,3gp,3g2,mj2 @ 0x786903c000] [verbose]   Input stream #0:0 (video): 50 packets read (439967 bytes);
    [in#0/mov,mp4,m4a,3gp,3g2,mj2 @ 0x786903c000] [verbose]   Input stream #0:1 (audio): 94 packets read (384000 bytes); 94 frames decoded; 0 decode errors (96000 samples);
    [in#0/mov,mp4,m4a,3gp,3g2,mj2 @ 0x786903c000] [verbose]   Total: 144 packets (823967 bytes) demuxed
    [verbose]
    [verbose] Exiting with exit code 0

    """

    private func report(_ log: String, tag: String? = BalancedCopyProofRuleTests.tag) -> Proof.ReadReport? {
        try? Proof.readReport(fromStderr: log, runTag: tag).get()
    }
    private func fault(_ log: String) -> String? {
        if case .failure(let fault) = Proof.readReport(fromStderr: log, runTag: Self.tag) { return fault.line }
        return nil
    }

    @Test("F3: a clean hash-pass log gives each stream's packets, the sound's samples and every channel's peak")
    func readReportFromACleanLog() throws {
        let read = try #require(report(Self.cleanLog), "\(String(describing: fault(Self.cleanLog)))")
        #expect(read.streams == [
            0: Proof.StreamRead(packets: 50, samples: nil, decodeErrors: nil),
            1: Proof.StreamRead(packets: 94, samples: 96_000, decodeErrors: 0)
        ])
        #expect(read.channelPeaksDBFS == [-3.099895, -.infinity])
        // Without a run tag (the copy's pass) no peak is read.
        #expect(report(Self.cleanLog, tag: nil)?.channelPeaksDBFS == [])
        // An ffmpeg 6-style line (no error count) still gives packets and samples.
        let older = Proof.streamRead(fromPayload: "  Input stream #0:12 (audio): 94 packets read (384000 bytes); 94 frames decoded (96000 samples); ")
        #expect(older?.index == 12)
        #expect(older?.read == Proof.StreamRead(packets: 94, samples: 96_000, decodeErrors: nil))
        #expect(Proof.streamRead(fromPayload: "  Output stream #0:0 (video): 50 packets muxed (1 bytes); ") == nil)
        #expect(Proof.streamRead(fromPayload: "  Input stream #0:0 (video): packets read") == nil)
    }

    @Test("F3: ANY line -v error would have printed, any line with no level, or a log that does not end with ffmpeg's clean exit refuses the pass")
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
        // One input stream accounted for twice (a forged line in a metadata KEY) is refused.
        let forged = "[verbose]   Input stream #0:0 (video): 50 packets read (1 bytes); "
        #expect(fault(with(forged, at: 4)) != nil)
        // Peaks: out of order, doubled, unreadable, or a peak before any channel.
        let peak = "[astats@\(Self.tag) @ 0x1] [info] Peak level dB: -3.0"
        #expect(fault(with(peak, at: 11)) == peak, "two peaks for one channel")
        #expect(fault(with(peak, at: 9)) == peak, "a peak before its channel")
        #expect(fault(with("[astats@\(Self.tag) @ 0x1] [info] Channel: 3", at: 9)) != nil)
        #expect(fault(Self.cleanLog.replacingOccurrences(of: "dB: -inf", with: "dB: quiet")) != nil)
        // Lines from an astats instance of ANOTHER name (the file cannot know the tag) are not peaks.
        let foreign = with("[astats@other @ 0x1] [info] Peak level dB: -99.0", at: 9)
        #expect(report(foreign)?.channelPeaksDBFS == [-3.099895, -.infinity])
    }

    @Test("F3: logRecord reads components, level and payload; a line that does not start that way is nil")
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
        #expect(Proof.count(before: " samples)", in: "(96000 samples)") == 96_000)
        #expect(Proof.count(before: " nothing", in: "12 something") == nil)
    }

    // MARK: F8 — one line

    @Test("F8: singleLine writes out every line break and control character; quoted keeps a path inside its quotes")
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
        #expect(line == "balanced copy proof: COULD NOT CHECK — original \"a\\\" — PROVEN \\\"x.mov\" · balanced copy \"b.mov\" — r")
    }

    // MARK: Scale

    @Test("SCALE: 100,000 decisions with every rule, and a 2,000-line hash-pass log, inside their budgets",
          .timeLimit(.minutes(1)))
    func rulesAtScale() {
        let good = Table.goodFacts()
        let shifted = Table.facts { $0.balanced.sound[0].timing.startSeconds = 0.5 }
        let loud = Table.poisoned { $0.originalRead?.channelPeaksDBFS = [-3.1, -48.2] }
        let clock = ContinuousClock()
        var proven = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 where Proof.decide([good, shifted, loud][i % 3]).isProven { proven += 1 }
        }
        #expect(proven == 33_334)
        #expect(elapsed < .seconds(5), "100k decisions took \(elapsed)")

        // A file with 2,000 lines of metadata: the log is read once, line by line.
        let lines = Self.cleanLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let padding = (0..<2_000).map { "[info]     tag\($0)           : value \($0)" }
        let long = (lines.prefix(4) + padding + lines.dropFirst(4)).joined(separator: "\n")
        var read: Proof.ReadReport?
        let parse = clock.measure { read = report(long) }
        #expect(read?.streams[1]?.samples == 96_000)
        #expect(parse < .seconds(2), "a 2,000-line log took \(parse)")
    }
}
