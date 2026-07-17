// BalanceAudioClassifierTests.swift
// LOGIC dimension for Balance Audio (GH #116): the pure classification
// rules, threshold boundaries, and the astats stderr parser — no media,
// no ffmpeg, no I/O.

import Testing
import Foundation
@testable import VideoScan

@Suite("Balance Audio — classifier (pure)")
struct BalanceAudioClassifierTests {

    private func ch(_ rms: Double, peak: Double = 0) -> AudioChannelLevels {
        AudioChannelLevels(rmsDBFS: rms, peakDBFS: peak)
    }
    private func classify(_ channels: [AudioChannelLevels],
                          diff: Double? = nil) -> AudioChannelClass {
        AudioBalanceClassifier.classify(
            AudioBalanceMeasurements(channels: channels, differenceRMSDBFS: diff))
    }

    // MARK: Channel-case table

    @Test("left-only: program left, silent right")
    func leftOnly() {
        #expect(classify([ch(-18), ch(-.infinity)]) == .leftOnly)
        #expect(classify([ch(-18), ch(-80)]) == .leftOnly)
    }

    @Test("right-only: silent left, program right")
    func rightOnly() {
        #expect(classify([ch(-.infinity), ch(-18)]) == .rightOnly)
        #expect(classify([ch(-75), ch(-12)]) == .rightOnly)
    }

    @Test("dual-mono: both live, difference far below program")
    func dualMono() {
        // Empirical AAC dual-mono: program ≈ −9, diff ≈ −99.
        #expect(classify([ch(-9), ch(-9)], diff: -99) == .dualMono)
    }

    @Test("true stereo: both live, difference near program level")
    func trueStereo() {
        #expect(classify([ch(-6), ch(-6)], diff: -9) == .trueStereo)
    }

    @Test("silent: nothing above the program floor")
    func silent() {
        #expect(classify([ch(-.infinity), ch(-.infinity)]) == .silent)
        #expect(classify([ch(-72), ch(-95)]) == .silent)
        #expect(classify([]) == .silent)
    }

    @Test("mono: single-channel stream, with and without program")
    func mono() {
        #expect(classify([ch(-20)]) == .mono)
        #expect(classify([ch(-.infinity)]) == .silent)
    }

    @Test("multichannel: >2 channels is classify-only")
    func multichannel() {
        #expect(classify(Array(repeating: ch(-20), count: 6)) == .multichannel)
        #expect(classify([ch(-20), ch(-20), ch(-20)]) == .multichannel)
    }

    // MARK: Threshold boundaries

    @Test("program floor boundary: −60 dBFS exactly is NOT program")
    func programFloorBoundary() {
        let floor = AudioBalanceClassifier.programFloorDBFS
        #expect(!AudioBalanceClassifier.carriesProgram(ch(floor)))
        #expect(AudioBalanceClassifier.carriesProgram(ch(floor + 0.1)))
        // A stereo pair straddling the floor classifies as one-sided.
        #expect(classify([ch(floor + 1), ch(floor)]) == .leftOnly)
        #expect(classify([ch(floor), ch(floor + 1)]) == .rightOnly)
    }

    @Test("dual-mono margin boundary: exactly 40 dB down IS dual-mono, 39.9 is not")
    func dualMonoMarginBoundary() {
        let margin = AudioBalanceClassifier.dualMonoDifferenceMarginDB
        // Louder channel −10 → threshold at −50.
        #expect(classify([ch(-10), ch(-14)], diff: -10 - margin) == .dualMono)
        #expect(classify([ch(-10), ch(-14)], diff: -10 - margin + 0.1) == .trueStereo)
    }

    @Test("unmeasured difference is conservatively true stereo (never fixable)")
    func unmeasuredDifferenceIsTrueStereo() {
        // THE safety default: without difference evidence, two live
        // channels must classify as the untouchable class.
        #expect(classify([ch(-9), ch(-9)], diff: nil) == .trueStereo)
    }

    // MARK: astats parser

    @Test("parses real astats stderr including -inf silence")
    func parserRealOutput() {
        let stderr = """
        [aist#0:0/aac @ 0x600002bc4000] Guessed Channel Layout: stereo
        [Parsed_astats_0 @ 0x80f050900] Channel: 1
        [Parsed_astats_0 @ 0x80f050900] Peak level dB: -4.011880
        [Parsed_astats_0 @ 0x80f050900] RMS level dB: -9.040315
        [Parsed_astats_0 @ 0x80f050900] Channel: 2
        [Parsed_astats_0 @ 0x80f050900] Peak level dB: -inf
        [Parsed_astats_0 @ 0x80f050900] RMS level dB: -inf
        size=N/A time=00:00:02.00 bitrate=N/A speed= 675x
        """
        let levels = AstatsOutputParser.perChannelLevels(fromStderr: stderr)
        #expect(levels.count == 2)
        #expect(abs(levels[0].rmsDBFS - -9.040315) < 0.0001)
        #expect(abs(levels[0].peakDBFS - -4.011880) < 0.0001)
        #expect(levels[1].rmsDBFS == -.infinity)
        #expect(levels[1].peakDBFS == -.infinity)
    }

    @Test("Overall section is ignored; missing values default to silence")
    func parserOverallAndDefaults() {
        let stderr = """
        [Parsed_astats_0 @ 0x1] Channel: 1
        [Parsed_astats_0 @ 0x1] Peak level dB: -1.0
        [Parsed_astats_0 @ 0x1] Overall
        [Parsed_astats_0 @ 0x1] RMS level dB: -3.0
        """
        let levels = AstatsOutputParser.perChannelLevels(fromStderr: stderr)
        #expect(levels.count == 1)
        // The Overall RMS must NOT be attributed to channel 1 —
        // the channel's own (absent) RMS defaults to silence.
        #expect(levels[0].rmsDBFS == -.infinity)
        #expect(levels[0].peakDBFS == -1.0)
    }

    @Test("garbage numeric text parses as silence, never as program")
    func parserGarbageIsSilent() {
        #expect(AstatsOutputParser.parseDB("banana") == -.infinity)
        #expect(AstatsOutputParser.parseDB("-inf") == -.infinity)
        #expect(AstatsOutputParser.parseDB("-18.5") == -18.5)
    }

    @Test("empty stderr yields no channels")
    func parserEmpty() {
        #expect(AstatsOutputParser.perChannelLevels(fromStderr: "").isEmpty)
    }

    // MARK: ffprobe shape decoding (pure)

    @Test("shape decodes streams, counts, bitrate, duration")
    func shapeDecoding() throws {
        let json = """
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"h264"},
            {"index":1,"codec_type":"audio","codec_name":"aac","channels":2,"bit_rate":"128000"}],
         "format":{"duration":"2.048000"}}
        """
        let data = Data(json.utf8)
        let shape = try AudioBalanceProbe.shape(fromProbeJSON: data)
        #expect(shape.videoCodec == "h264")
        #expect(shape.totalStreams == 2)
        #expect(shape.audioStreams == 1)
        #expect(shape.audioCodec == "aac")
        #expect(shape.audioChannels == 2)
        #expect(shape.audioBitRate == 128000)
        #expect(abs(shape.durationSeconds - 2.048) < 0.001)
    }

    @Test("shape with no audio stream throws noAudioStream")
    func shapeNoAudio() {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264"}],
         "format":{"duration":"2.0"}}
        """
        let data = Data(json.utf8)
        #expect(throws: AudioBalanceProbeError.noAudioStream) {
            _ = try AudioBalanceProbe.shape(fromProbeJSON: data)
        }
    }

    @Test("PCM-in-MOV shape: absent bit_rate decodes as nil")
    func shapePCMNoBitrate() throws {
        let json = """
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"h264"},
            {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2}],
         "format":{"duration":"2.0"}}
        """
        let data = Data(json.utf8)
        let shape = try AudioBalanceProbe.shape(fromProbeJSON: data)
        #expect(shape.audioBitRate == nil)
        #expect(shape.audioCodec == "pcm_s16le")
    }
}
