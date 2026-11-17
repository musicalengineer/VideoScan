// BalancedCopyProofDecisionTests.swift
// The PURE half of BalancedCopyProof: the decision table over measured
// facts, the ffprobe/streamhash parsers, the ffmpeg argument builders and
// the log line. No file, no subprocess.
//
// Dimensions here: LOGIC (every outcome, every reason) · ISOLATION (one
// poisoned fact at a time never yields "proven") · SCALE (100k decisions
// inside a budget) · SENSOR (the engine source writes nothing and launches
// processes only through the app's one runner). MEDIA and TRUTH are in
// BalancedCopyProofMediaTests. The rules added after Codex review #301
// (discarded channel, timing, decoder configuration, layout, whole reads,
// the hash pass's log) are table-tested in BalancedCopyProofRuleTests.

import Foundation
import Testing
@testable import VideoScan

@Suite("Balanced copy proof — the decision table")
struct BalancedCopyProofDecisionTests {

    typealias Proof = BalancedCopyProof

    // Three distinct, well-formed digests.
    static let pictureHash = String(repeating: "a1", count: 32)
    static let timecodeHash = String(repeating: "b2", count: 32)
    static let soundHash = String(repeating: "c3", count: 32)
    static let otherHash = String(repeating: "d4", count: 32)

    static let movie = "mov,mp4,m4a,3gp,3g2,mj2"

    static func timing(packets: Int? = 50, start: Double? = 0, duration: Double? = 2, real: String = "25/1",
                       average: String = "25/1", tick: Double? = 1.0 / 12_800) -> Proof.StreamTiming {
        Proof.StreamTiming(startSeconds: start, durationSeconds: duration, tickSeconds: tick, realFrameRate: real,
                           averageFrameRate: average, packets: packets)
    }
    static func picture(width: Int? = 320, extradata: String = "") -> Proof.PictureConfiguration {
        Proof.PictureConfiguration(extradataSHA256: extradata, width: width, height: 240, pixelFormat: "yuv422p10le",
                                   sampleAspect: "1:1", displayAspect: "4:3", fieldOrder: "progressive",
                                   colorRange: "tv")
    }
    static func video(_ index: Int = 0, codec: String = "prores", hash: String? = pictureHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "video", codec: codec, tag: "apco", packetSHA256: hash,
                            timing: timing(), configuration: picture())
    }
    static func timecode(_ index: Int, hash: String? = timecodeHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "data", codec: "", tag: "tmcd", packetSHA256: hash,
                            timing: timing(packets: 1, real: "0/0"),
                            configuration: Proof.PictureConfiguration(extradataSHA256: "SHA256:" + otherHash))
    }
    /// `layout` nil = what a QuickTime file states: "mono" for one channel, else "stereo".
    static func sound(_ index: Int = 1, codec: String = "pcm_s16le", format: String = "s16", rate: Int = 48_000,
                      channels: Int = 2, layout: String? = nil) -> Proof.SoundStream {
        Proof.SoundStream(index: index, codec: codec, sampleFormat: format, sampleRateHz: rate, channels: channels,
                          channelLayout: layout ?? (channels == 1 ? "mono" : "stereo"),
                          timing: timing(packets: 94, real: "0/0", average: "0/0", tick: 1.0 / 48_000))
    }

    /// A hash pass that read exactly what the layout says is there. For the
    /// original: the live channel peaks at −3.1 dBFS, the other is digital
    /// silence.
    static func wholeRead(of file: Proof.FileLayout, liveChannel: Int? = nil) -> Proof.ReadReport {
        var report = Proof.ReadReport()
        for stream in file.carried {
            report.streams[stream.index] = Proof.StreamRead(packets: stream.timing.packets ?? 0)
        }
        for stream in file.sound {
            let samples = Int64(((stream.timing.durationSeconds ?? 0) * Double(stream.sampleRateHz)).rounded())
            report.streams[stream.index] = Proof.StreamRead(packets: stream.timing.packets ?? 0, samples: samples,
                                                            decodeErrors: 0)
        }
        if let liveChannel { report.channelPeaksDBFS = liveChannel == 0 ? [-3.1, -.infinity] : [-.infinity, -3.1] }
        return report
    }

    /// A left-only PCM original and a faithful balanced copy.
    static func goodFacts() -> Proof.Facts {
        var f = Proof.Facts(
            original: Proof.FileLayout(carried: [video()], sound: [sound()], container: movie, durationSeconds: 2),
            balanced: Proof.FileLayout(carried: [video()], sound: [sound()], container: movie, durationSeconds: 2),
            originalClass: .leftOnly, originalMeasuredInFull: true,
            originalLiveSHA256: soundHash, balancedLeftSHA256: soundHash, balancedRightSHA256: soundHash)
        f.originalRead = wholeRead(of: f.original, liveChannel: 0)
        f.balancedRead = wholeRead(of: f.balanced)
        return f
    }

    /// Good facts with `change` applied, then both reads made WHOLE again for
    /// the changed layouts — so what a test changes is the one thing wrong.
    static func facts(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
        var f = goodFacts()
        change(&f)
        f.originalRead = wholeRead(of: f.original, liveChannel: Proof.liveChannel(for: f.originalClass) ?? 0)
        f.balancedRead = wholeRead(of: f.balanced)
        return f
    }

    /// Good facts with `change` applied and NOTHING re-derived: for poisoning
    /// what the hash passes themselves reported.
    static func poisoned(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
        var f = goodFacts()
        change(&f)
        return f
    }

    // MARK: Proven

    @Test("Proven: picture packets equal, copy left = copy right = the original's live channel, PCM in and out")
    func provenWhenEverythingHolds() throws {
        guard case .proven(let evidence) = Proof.decide(Self.goodFacts()) else {
            Issue.record("a faithful copy must be proven, got \(Proof.decide(Self.goodFacts()))")
            return
        }
        #expect(evidence.liveChannel == 0)
        #expect(evidence.originalClass == .leftOnly)
        #expect(evidence.soundSHA256 == Self.soundHash)
        #expect(evidence.soundCodec == "pcm_s16le")
        #expect(evidence.sampleFormat == "s16")
        #expect(evidence.sampleRateHz == 48_000)
        #expect(evidence.carried == [Proof.Evidence.Stream(kind: "video", codec: "prores", originalIndex: 0,
                                                           balancedIndex: 0, packetSHA256: Self.pictureHash,
                                                           packets: 50)])
        #expect(!evidence.gainedTimecodeTrack)
        #expect(evidence.soundSamples == 96_000)
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
        #expect(Proof.decide(Self.goodFacts()).isProven)
    }

    @Test("Proven for a right-only original (live channel 1) and for a mono original spread to two channels")
    func provenForRightOnlyAndMono() {
        let right = Proof.decide(Self.facts { $0.originalClass = .rightOnly })
        guard case .proven(let rightEvidence) = right else { Issue.record("right-only: \(right)"); return }
        #expect(rightEvidence.liveChannel == 1)
        #expect(rightEvidence.discarded?.channel == 0, "a right-only original leaves its LEFT channel behind")

        let mono = Proof.decide(Self.facts {
            $0.originalClass = .mono
            $0.original.sound = [Self.sound(channels: 1)]
        })
        guard case .proven(let monoEvidence) = mono else { Issue.record("mono: \(mono)"); return }
        #expect(monoEvidence.liveChannel == 0)
        #expect(monoEvidence.discarded == nil, "one channel: nothing is left behind")
    }

    @Test("Live channel table follows the balance job's pan filter; every other class has none")
    func liveChannelTable() {
        #expect(Proof.liveChannel(for: .leftOnly) == 0)
        #expect(Proof.liveChannel(for: .mono) == 0)
        #expect(Proof.liveChannel(for: .rightOnly) == 1)
        for c in [AudioChannelClass.dualMono, .trueStereo, .silent, .multichannel] {
            #expect(Proof.liveChannel(for: c) == nil)
            #expect(BalanceAudioFix.panFilter(for: c) == nil, "the job refuses \(c.rawValue) too")
        }
        #expect(BalanceAudioFix.panFilter(for: .leftOnly) == "pan=stereo|c0=c0|c1=c0")
        #expect(BalanceAudioFix.panFilter(for: .rightOnly) == "pan=stereo|c0=c1|c1=c1")
    }

    // MARK: Not proven — every reason

    @Test("Not proven: an original that is not one-sided, or has 0 / several sound tracks")
    func notProvenOriginalShape() {
        for c in [AudioChannelClass.dualMono, .trueStereo, .silent, .multichannel] {
            #expect(Proof.decide(Self.facts { $0.originalClass = c }) == .notProven(.originalNotOneSided(c)))
        }
        #expect(Proof.decide(Self.facts { $0.original.sound = [Self.sound(1), Self.sound(2)] })
                == .notProven(.originalSoundTracks(2)))
        #expect(Proof.decide(Self.facts { $0.original.sound = [] }) == .notProven(.originalSoundTracks(0)))
    }

    @Test("Not proven by design: a lossy original — the reason names the codec, in plain words")
    func notProvenLossyOriginal() {
        for codec in ["aac", "mp3", "ac3", "alac", ""] {
            let outcome = Proof.decide(Self.facts {
                $0.original.sound = [Self.sound(codec: codec, format: "fltp")]
                $0.balanced.sound = [Self.sound(codec: codec, format: "fltp")]
            })
            #expect(outcome == .notProven(.soundReencoded(codec: codec)))
        }
        #expect(Proof.NotProven.soundReencoded(codec: "aac").message
                == "the sound was re-encoded (aac) — the original is kept")
        // Every PCM flavour passes this rule.
        for codec in ["pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_f32le", "PCM_S16LE"] {
            let outcome = Proof.decide(Self.facts {
                $0.original.sound = [Self.sound(codec: codec)]
                $0.balanced.sound = [Self.sound(codec: codec)]
            })
            #expect(outcome.isProven, "\(codec): \(outcome)")
        }
    }

    @Test("Not proven: the copy's sound track count, codec, sample format, rate or channel count is wrong")
    func notProvenBalancedSoundShape() {
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [] }) == .notProven(.balancedSoundTracks(0)))
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [Self.sound(1), Self.sound(2)] })
                == .notProven(.balancedSoundTracks(2)))
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [Self.sound(codec: "pcm_s24le")] })
                == .notProven(.soundFormatChanged("codec pcm_s16le → pcm_s24le")))
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [Self.sound(format: "s32")] })
                == .notProven(.soundFormatChanged("sample format s16 → s32")))
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [Self.sound(rate: 44_100)] })
                == .notProven(.soundFormatChanged("sample rate 48000 → 44100 Hz")))
        #expect(Proof.decide(Self.facts { $0.balanced.sound = [Self.sound(channels: 1)] })
                == .notProven(.soundFormatChanged("1 channels, expected 2")))
    }

    @Test("Not proven: a missing stream, an extra stream, a stream of another kind or codec")
    func notProvenStreamSet() {
        func isStreamsDiffer(_ o: Proof.Outcome) -> Bool {
            if case .notProven(.streamsDiffer) = o { return true }
            return false
        }
        // The copy lost its picture.
        #expect(isStreamsDiffer(Proof.decide(Self.facts { $0.balanced.carried = [] })))
        // The copy has a second picture stream.
        #expect(isStreamsDiffer(Proof.decide(Self.facts { $0.balanced.carried = [Self.video(0), Self.video(2)] })))
        // The copy has two streams more.
        #expect(isStreamsDiffer(Proof.decide(Self.facts {
            $0.balanced.carried = [Self.video(0), Self.timecode(2), Self.timecode(3)]
        })))
        // Same count, other codec (the picture was re-encoded to another codec).
        #expect(isStreamsDiffer(Proof.decide(Self.facts { $0.balanced.carried = [Self.video(codec: "h264")] })))
        // Same count, other kind.
        #expect(isStreamsDiffer(Proof.decide(Self.facts { $0.balanced.carried = [Self.timecode(0)] })))
        // An extra data stream that is not a timecode track.
        #expect(isStreamsDiffer(Proof.decide(Self.facts {
            $0.balanced.carried = [Self.video(0), Proof.CarriedStream(index: 2, kind: "data", codec: "bin_data",
                                                                     tag: "gpmd", packetSHA256: Self.otherHash)]
        })))
        // The original's timecode track is not in the copy.
        #expect(isStreamsDiffer(Proof.decide(Self.facts { $0.original.carried = [Self.video(0), Self.timecode(2)] })))
    }

    @Test("Not proven: picture packets differ; the reason carries both hashes")
    func notProvenPictureDiffers() {
        let outcome = Proof.decide(Self.facts { $0.balanced.carried = [Self.video(hash: Self.otherHash)] })
        #expect(outcome == .notProven(.carriedStreamDiffers(kind: "video", originalIndex: 0,
                                                            original: Self.pictureHash, balanced: Self.otherHash)))
        guard case .notProven(let why) = outcome else { return }
        #expect(why.message.contains(Proof.short(Self.pictureHash)))
        #expect(why.message.contains(Proof.short(Self.otherHash)))
        #expect(why.message.hasSuffix("— the original is kept"))
    }

    @Test("Not proven: the copy's channels differ from each other, or both differ from the original's live channel")
    func notProvenSoundDiffers() {
        #expect(Proof.decide(Self.facts { $0.balancedRightSHA256 = Self.otherHash })
                == .notProven(.channelsDiffer(left: Self.soundHash, right: Self.otherHash)))
        #expect(Proof.decide(Self.facts { $0.balancedLeftSHA256 = Self.otherHash })
                == .notProven(.channelsDiffer(left: Self.otherHash, right: Self.soundHash)))
        #expect(Proof.decide(Self.facts {
            $0.balancedLeftSHA256 = Self.otherHash
            $0.balancedRightSHA256 = Self.otherHash
        }) == .notProven(.soundDiffers(original: Self.soundHash, balanced: Self.otherHash)))
        // The picture is judged first: a copy wrong in both says the picture.
        let both = Proof.decide(Self.facts {
            $0.balanced.carried = [Self.video(hash: Self.otherHash)]
            $0.balancedRightSHA256 = Self.otherHash
        })
        guard case .notProven(.carriedStreamDiffers) = both else { Issue.record("\(both)"); return }
    }

    // MARK: The timecode track rule

    @Test("Timecode: a muxer-made tmcd track is the ONE stream a copy may gain, and only when the original has none")
    func timecodeTrackRule() {
        // Raw DV → QuickTime: the copy gains a tmcd track.
        let gained = Proof.decide(Self.facts { $0.balanced.carried = [Self.video(0), Self.timecode(2)] })
        guard case .proven(let evidence) = gained else { Issue.record("gained tmcd: \(gained)"); return }
        #expect(evidence.gainedTimecodeTrack)
        #expect(evidence.carried.count == 1)

        // The original's own timecode track, carried and equal.
        let carried = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.timecode(2)]
        })
        guard case .proven(let both) = carried else { Issue.record("carried tmcd: \(carried)"); return }
        #expect(!both.gainedTimecodeTrack)
        #expect(both.carried.map(\.kind) == ["video", "data"])

        // Carried, and not the original's.
        #expect(Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.timecode(2, hash: Self.otherHash)]
        }) == .notProven(.carriedStreamDiffers(kind: "data", originalIndex: 2,
                                               original: Self.timecodeHash, balanced: Self.otherHash)))

        // The original has one, the copy two: not the tolerated gain.
        let two = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.timecode(2), Self.timecode(3)]
        })
        guard case .notProven(.streamsDiffer) = two else { Issue.record("two tmcd: \(two)"); return }
    }

    // MARK: Could not check — unknown is never proven

    @Test("Could not check: a partly measured original, a missing hash, the hash of nothing, an unreadable format")
    func couldNotCheckTable() {
        func unchecked(_ o: Proof.Outcome) -> Bool {
            if case .couldNotCheck(let reason) = o { return !reason.isEmpty }
            return false
        }
        #expect(unchecked(Proof.decide(Self.facts { $0.originalMeasuredInFull = false })))
        #expect(unchecked(Proof.decide(Self.facts { $0.originalLiveSHA256 = nil })))
        #expect(unchecked(Proof.decide(Self.facts { $0.balancedLeftSHA256 = nil })))
        #expect(unchecked(Proof.decide(Self.facts { $0.balancedRightSHA256 = nil })))
        #expect(unchecked(Proof.decide(Self.facts { $0.original.carried = [Self.video(hash: nil)] })))
        #expect(unchecked(Proof.decide(Self.facts { $0.balanced.carried = [Self.video(hash: nil)] })))
        #expect(unchecked(Proof.decide(Self.facts {
            $0.original.sound = [Self.sound(format: "s24x")]
            $0.balanced.sound = [Self.sound(format: "s24x")]
        })))
        #expect(unchecked(Proof.decide(Self.facts {
            $0.original.sound = [Self.sound(rate: 0)]
            $0.balanced.sound = [Self.sound(rate: 0)]
        })))
        // Three equal hashes OF NOTHING are not a proof: no sample was compared.
        #expect(unchecked(Proof.decide(Self.facts {
            $0.originalLiveSHA256 = Proof.emptySHA256
            $0.balancedLeftSHA256 = Proof.emptySHA256
            $0.balancedRightSHA256 = Proof.emptySHA256
        })))
        // Likewise two pictures that delivered no packet.
        #expect(unchecked(Proof.decide(Self.facts {
            $0.original.carried = [Self.video(hash: Proof.emptySHA256)]
            $0.balanced.carried = [Self.video(hash: Proof.emptySHA256)]
        })))
        // A digest that is not a SHA-256.
        #expect(unchecked(Proof.decide(Self.facts {
            $0.originalLiveSHA256 = "abc"
            $0.balancedLeftSHA256 = "abc"
            $0.balancedRightSHA256 = "abc"
        })))
        // A partly measured original outranks everything else it would say.
        #expect(unchecked(Proof.decide(Self.facts {
            $0.originalMeasuredInFull = false
            $0.originalClass = .dualMono
        })))
    }

    @Test("ISOLATION: poisoning any one fact of a proven pair never leaves it proven")
    func onePoisonedFactNeverProves() {
        let poisons: [(String, (inout Proof.Facts) -> Void)] = [
            ("class", { $0.originalClass = .trueStereo }),
            ("unmeasured", { $0.originalMeasuredInFull = false }),
            ("original codec", { $0.original.sound[0].codec = "aac" }),
            ("copy codec", { $0.balanced.sound[0].codec = "aac" }),
            ("original format", { $0.original.sound[0].sampleFormat = "s32" }),
            ("copy format", { $0.balanced.sound[0].sampleFormat = "flt" }),
            ("original rate", { $0.original.sound[0].sampleRateHz = 32_000 }),
            ("copy rate", { $0.balanced.sound[0].sampleRateHz = 32_000 }),
            ("copy channels", { $0.balanced.sound[0].channels = 6 }),
            ("original sound gone", { $0.original.sound = [] }),
            ("copy sound gone", { $0.balanced.sound = [] }),
            ("copy second sound", { $0.balanced.sound.append(Self.sound(2)) }),
            ("original second sound", { $0.original.sound.append(Self.sound(2)) }),
            ("original picture hash", { $0.original.carried[0].packetSHA256 = Self.otherHash }),
            ("copy picture hash", { $0.balanced.carried[0].packetSHA256 = Self.otherHash }),
            ("copy picture hash nil", { $0.balanced.carried[0].packetSHA256 = nil }),
            ("copy picture kind", { $0.balanced.carried[0].kind = "subtitle" }),
            ("copy picture codec", { $0.balanced.carried[0].codec = "dvvideo" }),
            ("copy picture gone", { $0.balanced.carried = [] }),
            ("original extra stream", { $0.original.carried.append(Self.video(3)) }),
            ("copy extra picture", { $0.balanced.carried.append(Self.video(3)) }),
            ("live hash", { $0.originalLiveSHA256 = Self.otherHash }),
            ("live hash nil", { $0.originalLiveSHA256 = nil }),
            ("left hash", { $0.balancedLeftSHA256 = Self.otherHash }),
            ("right hash", { $0.balancedRightSHA256 = Self.otherHash }),
            ("right hash empty", { $0.balancedRightSHA256 = "" }),
            ("copy layout", { $0.balanced.sound[0].channelLayout = "2 channels (FC+LFE)" }),
            ("copy layout unset in QuickTime", { $0.balanced.sound[0].channelLayout = "" }),
            ("original layout", { $0.original.sound[0].channelLayout = "2 channels (FC+LFE)" }),
            ("original channels", { $0.original.sound[0].channels = 3 }),
            ("copy picture width", { $0.balanced.carried[0].configuration.width = 304 }),
            ("copy picture extradata", { $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:ab" }),
            ("original picture size unread", { $0.original.carried[0].configuration.width = nil }),
            ("copy picture packets", { $0.balanced.carried[0].timing.packets = 49 }),
            ("copy picture packets uncounted", { $0.balanced.carried[0].timing.packets = nil }),
            ("copy picture start", { $0.balanced.carried[0].timing.startSeconds = 0.04 }),
            ("copy picture duration", { $0.balanced.carried[0].timing.durationSeconds = 4 }),
            ("copy picture duration unstated", { $0.balanced.carried[0].timing.durationSeconds = nil }),
            ("copy frame rate", { $0.balanced.carried[0].timing.realFrameRate = "25/2" }),
            ("copy average frame rate", { $0.balanced.carried[0].timing.averageFrameRate = "1250/99" }),
            ("copy sound start", { $0.balanced.sound[0].timing.startSeconds = 0.5 }),
            ("copy sound duration", { $0.balanced.sound[0].timing.durationSeconds = 1.99 }),
            ("copy file duration", { $0.balanced.durationSeconds = 2.5 })
        ]
        #expect(Proof.decide(Self.goodFacts()).isProven, "the baseline must be proven or this test proves nothing")
        for (name, poison) in poisons {
            let outcome = Proof.decide(Self.facts(poison))
            #expect(!outcome.isProven, "poisoned \(name) must not be proven")
        }
        // What the hash passes themselves report, poisoned with the layouts left alone.
        let reads: [(String, (inout Proof.Facts) -> Void)] = [
            ("no original read", { $0.originalRead = nil }),
            ("no copy read", { $0.balancedRead = nil }),
            ("original picture read short", { $0.originalRead?.streams[0]?.packets = 25 }),
            ("copy picture read short", { $0.balancedRead?.streams[0]?.packets = 25 }),
            ("copy sound read short", { $0.balancedRead?.streams[1]?.packets = 47 }),
            ("original sound samples short", { $0.originalRead?.streams[1]?.samples = 48_000 }),
            ("original sound samples missing", { $0.originalRead?.streams[1]?.samples = nil }),
            ("copy sound decode error", { $0.balancedRead?.streams[1]?.decodeErrors = 1 }),
            ("original stream unaccounted", { $0.originalRead?.streams[0] = nil }),
            ("no peaks", { $0.originalRead?.channelPeaksDBFS = [] }),
            ("one peak", { $0.originalRead?.channelPeaksDBFS = [-3.1] }),
            ("peak not a number", { $0.originalRead?.channelPeaksDBFS = [-3.1, .nan] }),
            ("other channel loud", { $0.originalRead?.channelPeaksDBFS = [-3.1, -48.2] }),
            ("other channel just over", { $0.originalRead?.channelPeaksDBFS = [-3.1, -59.99] })
        ]
        for (name, poison) in reads {
            let outcome = Proof.decide(Self.poisoned(poison))
            #expect(!outcome.isProven, "poisoned \(name) must not be proven")
        }
    }

    @Test("layoutVerdict decides lossy and mis-shaped pairs before any hash exists; a good layout waits for hashes")
    func layoutVerdictNeedsNoHashes() {
        func unhashed(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
            var f = Self.facts(change)
            f.originalLiveSHA256 = nil
            f.balancedLeftSHA256 = nil
            f.balancedRightSHA256 = nil
            f.originalRead = nil
            f.balancedRead = nil
            for i in f.original.carried.indices { f.original.carried[i].packetSHA256 = nil }
            for i in f.balanced.carried.indices { f.balanced.carried[i].packetSHA256 = nil }
            return f
        }
        #expect(Proof.layoutVerdict(unhashed {
            $0.original.sound = [Self.sound(codec: "aac", format: "fltp")]
        }) == .notProven(.soundReencoded(codec: "aac")))
        #expect(Proof.layoutVerdict(unhashed { $0.balanced.sound = [] }) == .notProven(.balancedSoundTracks(0)))
        #expect(Proof.layoutVerdict(unhashed { $0.originalClass = .dualMono })
                == .notProven(.originalNotOneSided(.dualMono)))
        // Good layout: nothing to say yet — and decide() refuses to prove without hashes.
        let good = unhashed { _ in }
        #expect(Proof.layoutVerdict(good) == nil)
        guard case .couldNotCheck = Proof.decide(good) else { Issue.record("\(Proof.decide(good))"); return }
    }

    // MARK: Log line

    @Test("logLine: one line naming both files, the verdict and the hashes compared")
    func logLineNamesFilesVerdictAndHashes() {
        let original = "/Volumes/Tapes/1994 Xmas.mov"
        let copy = "/Volumes/Tapes/1994 Xmas_balanced.mov"

        let proven = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.goodFacts()))
        #expect(proven.hasPrefix("balanced copy proof: PROVEN — "))
        #expect(proven.contains("original \"\(original)\""))
        #expect(proven.contains("balanced copy \"\(copy)\""))
        #expect(proven.contains("video 0→0 sha256 \(Self.pictureHash)"))
        #expect(proven.contains("original left = copy left = copy right sha256 \(Self.soundHash)"))
        #expect(proven.contains("pcm_s16le 48000 Hz"))
        #expect(proven.contains("(50 packets, timing and decoder configuration equal)"))
        #expect(proven.contains("(96000 samples)"))
        #expect(proven.contains("original right: digital silence, not in the copy"))
        let quiet = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.poisoned {
            $0.originalRead?.channelPeaksDBFS = [-3.1, -71.3]
        }))
        #expect(quiet.contains("original right: peak −71.3 dBFS, not in the copy"), "\(quiet)")
        let mono = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.facts {
            $0.originalClass = .mono
            $0.original.sound = [Self.sound(channels: 1)]
        }))
        #expect(mono.contains("original has one channel, nothing left behind"), "\(mono)")
        #expect(!proven.contains("\n"))

        let right = Proof.logLine(original: original, balanced: copy,
                                  outcome: Proof.decide(Self.facts { $0.originalClass = .rightOnly }))
        #expect(right.contains("original right = copy left = copy right"))
        #expect(right.contains("original left: digital silence, not in the copy"))

        let gained = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.facts {
            $0.balanced.carried = [Self.video(0), Self.timecode(2)]
        }))
        #expect(gained.contains("muxer-made timecode track"))

        let not = Proof.logLine(original: original, balanced: copy,
                                outcome: Proof.decide(Self.facts { $0.balancedRightSHA256 = Self.otherHash }))
        #expect(not.hasPrefix("balanced copy proof: NOT PROVEN — "))
        #expect(not.contains(original) && not.contains(copy))
        #expect(not.contains(Proof.short(Self.soundHash)) && not.contains(Proof.short(Self.otherHash)))
        #expect(not.hasSuffix("— the original is kept"))
        #expect(!not.contains("\n"))

        let unchecked = Proof.logLine(original: original, balanced: copy,
                                      outcome: .couldNotCheck("the balanced copy is not on disk, or cannot be read"))
        #expect(unchecked == "balanced copy proof: COULD NOT CHECK — original \"\(original)\" · balanced copy \"\(copy)\""
                + " — the balanced copy is not on disk, or cannot be read")
    }

    @Test("F8: logLine is ONE line whatever a file name or a reason holds — a newline cannot forge a PROVEN record")
    func logLineIsAlwaysOneLine() {
        let line = Proof.logLine(original: "a.mov\nbalanced copy proof: PROVEN — forged", balanced: "b.mov",
                                 outcome: .couldNotCheck("unreadable"))
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("balanced copy proof: COULD NOT CHECK — "))
        let hostile = "x\r\ny\u{2028}z\u{0085}w\u{0007}\tq"
        for outcome in [Proof.Outcome.couldNotCheck(hostile), .notProven(.soundReencoded(codec: hostile)),
                        .notProven(.streamsDiffer(hostile)), Proof.decide(Self.goodFacts())] {
            let record = Proof.logLine(original: hostile, balanced: hostile, outcome: outcome)
            #expect(record.unicodeScalars.allSatisfy { !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) },
                    "\(record.debugDescription)")
        }
    }

    @Test("Every not-proven reason has its own plain sentence, ending the same way")
    func everyReasonHasASentence() {
        let reasons: [Proof.NotProven] = [
            .originalNotOneSided(.trueStereo), .originalSoundTracks(2), .soundReencoded(codec: "mp3"),
            .balancedSoundTracks(0), .soundFormatChanged("codec a → b"), .streamsDiffer("x"),
            .channelLayoutNotStereo(file: "the balanced copy", layout: "2 channels (FC+LFE)"),
            .pictureConfigurationDiffers("video stream 0: width 320 → 304"),
            .timingDiffers("the sound starts at 0.000000 s, in the balanced copy at 0.500000 s"),
            .discardedChannelNotSilent(channel: 1, peakDBFS: -48.2),
            .carriedStreamDiffers(kind: "video", originalIndex: 0, original: Self.pictureHash, balanced: Self.otherHash),
            .channelsDiffer(left: Self.soundHash, right: Self.otherHash),
            .soundDiffers(original: Self.soundHash, balanced: Self.otherHash)
        ]
        let messages = reasons.map(\.message)
        #expect(Set(messages).count == reasons.count)
        for message in messages {
            #expect(message.hasSuffix(" — the original is kept"))
            #expect(message.count > 40)
        }
        #expect(Proof.NotProven.soundReencoded(codec: "").message.contains("unknown codec"))
        #expect(Proof.NotProven.originalNotOneSided(.trueStereo).message.contains("trueStereo"))
        #expect(Proof.NotProven.discardedChannelNotSilent(channel: 1, peakDBFS: -48.2).message
                == "the original's other channel is not silent (peak −48.2 dBFS) — the original is kept")
    }

    // MARK: Parsers and argument builders

    @Test("streamHashes: one digest per output stream, in order; anything short, doubled or malformed is nil")
    func streamHashesParse() {
        let a = Self.pictureHash, b = Self.soundHash
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(a)\n1,a,SHA256=\(b)\n", expected: 2) == [a, b])
        // Order is by stream number, not by line; hex is lowercased.
        #expect(Proof.streamHashes(fromStdout: "1,a,SHA256=\(b.uppercased())\r\n0,v,SHA256=\(a)", expected: 2) == [a, b])
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(a)\n", expected: 2) == nil)
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(a)\n0,v,SHA256=\(b)\n", expected: 2) == nil)
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(a)\n2,a,SHA256=\(b)\n", expected: 2) == nil)
        #expect(Proof.streamHashes(fromStdout: "0,v,MD5=\(a)\n", expected: 1) == nil)
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(a.dropLast())\n", expected: 1) == nil)
        #expect(Proof.streamHashes(fromStdout: "0,v,SHA256=\(String(repeating: "zz", count: 32))\n", expected: 1) == nil)
        #expect(Proof.streamHashes(fromStdout: "", expected: 0) == nil)
        #expect(Proof.streamHashes(fromStdout: "garbage", expected: 1) == nil)
    }

    @Test("layout(fromProbeJSON:): audio apart from carried streams, with timing, packet counts and decoder configuration")
    func layoutParse() throws {
        let json = Data("""
        {"streams":[
          {"index":0,"codec_name":"h264","codec_type":"video","codec_tag_string":"avc1","width":320,"height":240,
           "pix_fmt":"yuv420p","sample_aspect_ratio":"1:1","display_aspect_ratio":"4:3","field_order":"progressive",
           "color_range":"tv","color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709",
           "r_frame_rate":"25/1","avg_frame_rate":"25/1","time_base":"1/12800","start_time":"0.000000",
           "duration":"2.000000","nb_read_packets":"50","extradata_hash":"SHA256:abcd"},
          {"index":1,"codec_name":"pcm_s24le","codec_type":"audio","codec_tag_string":"in24",
           "sample_fmt":"s32","sample_rate":"48000","channels":2,"channel_layout":"stereo","r_frame_rate":"0/0",
           "avg_frame_rate":"0/0","time_base":"1/48000","start_time":"0.500000","duration":"2.000000",
           "nb_read_packets":"94"},
          {"index":2,"codec_type":"data","codec_tag_string":"tmcd","nb_read_packets":"1",
           "tags":{"DURATION":"00:00:01.800000000"}}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"2.500000"}}
        """.utf8)
        let layout = try #require(Proof.layout(fromProbeJSON: json))
        #expect(layout.container == Self.movie)
        #expect(layout.containerWords.contains("mov"))
        #expect(layout.durationSeconds == 2.5)
        #expect(layout.carried.map(\.index) == [0, 2])
        let video = layout.carried[0]
        #expect(video.kind == "video" && video.codec == "h264" && video.tag == "avc1" && video.packetSHA256 == nil)
        #expect(video.timing == Proof.StreamTiming(startSeconds: 0, durationSeconds: 2, tickSeconds: 1.0 / 12_800,
                                                   realFrameRate: "25/1", averageFrameRate: "25/1", packets: 50))
        #expect(video.configuration == Proof.PictureConfiguration(
            extradataSHA256: "SHA256:abcd", width: 320, height: 240, pixelFormat: "yuv420p", sampleAspect: "1:1",
            displayAspect: "4:3", fieldOrder: "progressive", colorRange: "tv", colorSpace: "bt709",
            colorTransfer: "bt709", colorPrimaries: "bt709"))
        let timecode = layout.carried[1]
        #expect(timecode.isTimecodeTrack && timecode.codec.isEmpty && !video.isTimecodeTrack)
        // No `duration`: Matroska's DURATION tag is the stream's stated length. No start: nil, not 0.
        #expect(timecode.timing.durationSeconds == 1.8)
        #expect(timecode.timing.startSeconds == nil && timecode.timing.tickSeconds == nil)
        #expect(timecode.configuration == Proof.PictureConfiguration())
        let sound = try #require(layout.sound.first)
        #expect(layout.sound.count == 1)
        #expect(sound.index == 1 && sound.codec == "pcm_s24le" && sound.sampleFormat == "s32")
        #expect(sound.sampleRateHz == 48_000 && sound.channels == 2 && sound.channelLayout == "stereo")
        #expect(sound.timing.startSeconds == 0.5 && sound.timing.packets == 94)
        #expect(abs(sound.timingSlackSeconds - 1.0 / 48_000) < 1e-12)
        #expect(Proof.layout(fromProbeJSON: Data("{}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("{\"streams\":[]}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("not json".utf8)) == nil)
        // Unreadable numbers are unknown, never zero.
        #expect(Proof.seconds("N/A") == nil && Proof.seconds(nil) == nil && Proof.seconds("nan") == nil)
        #expect(Proof.tick("0/1") == nil && Proof.tick("1/0") == nil && Proof.tick("x") == nil)
        // The request counts packets and hashes extradata.
        let args = Proof.layoutArgs(input: "/in/a.mov")
        #expect(args.contains("-count_packets") && args.last == "/in/a.mov")
        #expect(args.joined(separator: " ").contains("-show_data_hash sha256"))
    }

    @Test("hashCodec: each decoded sample format maps to the raw PCM codec that holds it exactly; unknown is nil")
    func hashCodecTable() {
        #expect(Proof.hashCodec(forSampleFormat: "s16") == "pcm_s16le")
        #expect(Proof.hashCodec(forSampleFormat: "s16p") == "pcm_s16le")
        #expect(Proof.hashCodec(forSampleFormat: "s32") == "pcm_s32le")
        #expect(Proof.hashCodec(forSampleFormat: "flt") == "pcm_f32le")
        #expect(Proof.hashCodec(forSampleFormat: "fltp") == "pcm_f32le")
        #expect(Proof.hashCodec(forSampleFormat: "dbl") == "pcm_f64le")
        #expect(Proof.hashCodec(forSampleFormat: "u8") == "pcm_u8")
        #expect(Proof.hashCodec(forSampleFormat: "s64") == "pcm_s64le")
        #expect(Proof.hashCodec(forSampleFormat: "") == nil)
        #expect(Proof.hashCodec(forSampleFormat: "p") == nil)
        #expect(Proof.hashCodec(forSampleFormat: "s24") == nil)
    }

    @Test("hashArgs: packets are stream-copied, sound is hashed as raw PCM with no resample, errors are fatal, input options precede -i")
    func hashArgsVector() throws {
        let args = Proof.hashArgs(
            input: "/in/tape.dv", inputArgs: ["-r", "30000/1001"], carriedIndices: [0, 2],
            soundFilter: Proof.originalSoundFilter(streamIndex: 1, liveChannel: 1, runTag: "vsabc"),
            soundOutputs: ["live"], hashCodec: "pcm_s16le")
        #expect(args == [
            "-v", "repeat+level+verbose", "-nostdin", "-nostats", "-hide_banner", "-xerror", "-err_detect", "explode",
            "-r", "30000/1001", "-i", "/in/tape.dv",
            "-filter_complex",
            "[0:1]astats@vsabc=measure_perchannel=Peak_level:measure_overall=none,channelmap=map=1:channel_layout=mono[live]",
            "-map", "0:0", "-map", "0:2", "-map", "[live]",
            "-c", "copy", "-c:a", "pcm_s16le", "-f", "streamhash", "-hash", "sha256", "-"
        ])
        // Nothing that resamples, re-times or writes a file.
        for forbidden in ["-ar", "-af", "-y", "-ac", "-sample_fmt"] { #expect(!args.contains(forbidden)) }
        #expect(args.last == "-", "the only output is stdout")
        let input = try #require(args.firstIndex(of: "-i"))
        for option in ["-xerror", "-err_detect"] {
            #expect(try #require(args.firstIndex(of: option)) < input, "\(option) must apply to the read")
        }

        let copy = Proof.hashArgs(
            input: "/in/tape_balanced.mov", inputArgs: [], carriedIndices: [0],
            soundFilter: Proof.balancedSoundFilter(streamIndex: 1),
            soundOutputs: ["left", "right"], hashCodec: "pcm_s32le")
        #expect(copy.contains("[0:1]asplit[a][b];[a]channelmap=map=0:channel_layout=mono[left];"
                              + "[b]channelmap=map=1:channel_layout=mono[right]"))
        let left = try #require(copy.firstIndex(of: "[left]"))
        let right = try #require(copy.firstIndex(of: "[right]"))
        #expect(left < right, "left is hashed before right — the parse depends on the order")
        // The proof picks channels with channelmap, never with the filter the job rendered with.
        #expect(!copy.joined(separator: " ").contains("pan="))
    }

    // MARK: Scale

    @Test("SCALE: 100,000 decisions and log lines inside 5 s", .timeLimit(.minutes(1)))
    func hundredThousandDecisions() {
        let good = Self.goodFacts()
        let bad = Self.facts { $0.balancedRightSHA256 = Self.otherHash }
        let clock = ContinuousClock()
        var proven = 0
        var characters = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 {
                let outcome = Proof.decide(i.isMultiple(of: 2) ? good : bad)
                if outcome.isProven { proven += 1 }
                characters += Proof.logLine(original: "/a/\(i).mov", balanced: "/a/\(i)_balanced.mov",
                                            outcome: outcome).count
            }
        }
        #expect(proven == 50_000)
        #expect(characters > 0)
        #expect(elapsed < .seconds(5), "100k decisions took \(elapsed)")
    }

    // MARK: Sensor

    @Test("SENSOR: the proof engine is read-only and launches processes only through the app's one runner")
    func engineSourceIsReadOnly() throws {
        // The engine is three files; every one is held to the same rule.
        let files = ["BalancedCopyProof.swift", "BalancedCopyProofRules.swift", "BalancedCopyProofMeasure.swift"]
        let code = try files.map { try SourceTree.appCode(named: $0) }.joined(separator: "\n")
        #expect(code.contains("enum BalancedCopyProof"))
        // No file is created, moved, removed or trashed; nothing is stored.
        let forbidden = [
            "removeItem", "moveItem", "copyItem", "trashItem", "createFile", "createDirectory", "replaceItem",
            ".write(", "FileHandle(forWriting", "FileHandle(forUpdating", "unlink(", "rename(", "truncate(",
            "setAttributes", "UserDefaults", "NotificationCenter", "appLog.", "CatalogCommit", "placeRecord",
            "MediaTrash", "extension VideoScanModel", "symlink(", "O_WRONLY", "O_RDWR", "O_CREAT"
        ]
        for word in forbidden {
            #expect(!code.contains(word), "the balanced-copy proof must not use \(word)")
        }
        // One process runner, one tool locator — no second road to ffmpeg.
        #expect(!code.contains("Process()"))
        #expect(code.components(separatedBy: "ProcessRunner.runProcess(").count == 3, "one ffprobe call, one ffmpeg call")
        #expect(code.contains("ToolLocator.ffmpegPath") && code.contains("ToolLocator.ffprobePath"))
        // ffmpeg is asked for hashes on stdout only: no overwrite flag, no output path.
        #expect(!code.contains("\"-y\""))
        #expect(code.contains("\"-f\", \"streamhash\", \"-hash\", \"sha256\", \"-\""))
        // The hash pass may not be softened: read and decode errors stay fatal, and
        // the last thing before a verdict is the cancellation check.
        #expect(code.contains("\"-xerror\"") && code.contains("\"-err_detect\", \"explode\""))
        let stamped = try #require(code.range(of: "tools.afterFinalStamps?()"))
        let verdict = try #require(code.range(of: "guard case .proven(var evidence)"))
        let check = try #require(code.range(of: "try Task.checkCancellation()", range: stamped.upperBound..<code.endIndex))
        #expect(check.lowerBound < verdict.lowerBound, "cancellation is checked after the closing stamps, before the verdict")
    }
}
