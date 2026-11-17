// BalancedCopyProofDecisionTests.swift
// The PURE half of BalancedCopyProof: the decision table over measured
// facts, the ffprobe/streamhash parsers, the ffmpeg argument builders and
// the log line. No file, no subprocess.
//
// Dimensions here: LOGIC (every outcome, every reason) · ISOLATION (one
// poisoned fact at a time never yields "proven") · SCALE (100k decisions
// inside a budget) · SENSOR (the engine source writes nothing and launches
// processes only through the app's one runner). MEDIA and TRUTH are in
// BalancedCopyProofMediaTests.

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

    static func video(_ index: Int = 0, codec: String = "prores", hash: String? = pictureHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "video", codec: codec, tag: "apco", packetSHA256: hash)
    }
    static func timecode(_ index: Int, hash: String? = timecodeHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "data", codec: "", tag: "tmcd", packetSHA256: hash)
    }
    static func sound(_ index: Int = 1, codec: String = "pcm_s16le", format: String = "s16", rate: Int = 48_000,
                      channels: Int = 2) -> Proof.SoundStream {
        Proof.SoundStream(index: index, codec: codec, sampleFormat: format, sampleRateHz: rate, channels: channels)
    }

    /// A left-only PCM original and a faithful balanced copy.
    static func goodFacts() -> Proof.Facts {
        Proof.Facts(
            original: Proof.FileLayout(carried: [video()], sound: [sound()]),
            balanced: Proof.FileLayout(carried: [video()], sound: [sound()]),
            originalClass: .leftOnly, originalMeasuredInFull: true,
            originalLiveSHA256: soundHash, balancedLeftSHA256: soundHash, balancedRightSHA256: soundHash)
    }

    static func facts(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
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
                                                           balancedIndex: 0, packetSHA256: Self.pictureHash)])
        #expect(!evidence.gainedTimecodeTrack)
        #expect(Proof.decide(Self.goodFacts()).isProven)
    }

    @Test("Proven for a right-only original (live channel 1) and for a mono original spread to two channels")
    func provenForRightOnlyAndMono() {
        let right = Proof.decide(Self.facts { $0.originalClass = .rightOnly })
        guard case .proven(let rightEvidence) = right else { Issue.record("right-only: \(right)"); return }
        #expect(rightEvidence.liveChannel == 1)

        let mono = Proof.decide(Self.facts {
            $0.originalClass = .mono
            $0.original.sound = [Self.sound(channels: 1)]
        })
        guard case .proven(let monoEvidence) = mono else { Issue.record("mono: \(mono)"); return }
        #expect(monoEvidence.liveChannel == 0)
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
            ("right hash empty", { $0.balancedRightSHA256 = "" })
        ]
        #expect(Proof.decide(Self.goodFacts()).isProven, "the baseline must be proven or this test proves nothing")
        for (name, poison) in poisons {
            let outcome = Proof.decide(Self.facts(poison))
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
        #expect(!proven.contains("\n"))

        let right = Proof.logLine(original: original, balanced: copy,
                                  outcome: Proof.decide(Self.facts { $0.originalClass = .rightOnly }))
        #expect(right.contains("original right = copy left = copy right"))

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

    @Test("Every not-proven reason has its own plain sentence, ending the same way")
    func everyReasonHasASentence() {
        let reasons: [Proof.NotProven] = [
            .originalNotOneSided(.trueStereo), .originalSoundTracks(2), .soundReencoded(codec: "mp3"),
            .balancedSoundTracks(0), .soundFormatChanged("codec a → b"), .streamsDiffer("x"),
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

    @Test("layout(fromProbeJSON:): audio apart from carried streams; a tmcd track has no codec name; junk is nil")
    func layoutParse() throws {
        let json = Data("""
        {"streams":[
          {"index":0,"codec_name":"prores","codec_type":"video","codec_tag_string":"apco"},
          {"index":1,"codec_name":"pcm_s24le","codec_type":"audio","codec_tag_string":"in24",
           "sample_fmt":"s32","sample_rate":"48000","channels":2},
          {"index":2,"codec_type":"data","codec_tag_string":"tmcd"}]}
        """.utf8)
        let layout = try #require(Proof.layout(fromProbeJSON: json))
        #expect(layout.carried == [
            Proof.CarriedStream(index: 0, kind: "video", codec: "prores", tag: "apco", packetSHA256: nil),
            Proof.CarriedStream(index: 2, kind: "data", codec: "", tag: "tmcd", packetSHA256: nil)
        ])
        #expect(layout.sound == [Proof.SoundStream(index: 1, codec: "pcm_s24le", sampleFormat: "s32",
                                                   sampleRateHz: 48_000, channels: 2)])
        #expect(layout.carried[1].isTimecodeTrack)
        #expect(!layout.carried[0].isTimecodeTrack)
        #expect(Proof.layout(fromProbeJSON: Data("{}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("{\"streams\":[]}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("not json".utf8)) == nil)
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

    @Test("hashArgs: packets are stream-copied, sound is hashed as raw PCM with no resample, input options precede -i")
    func hashArgsVector() throws {
        let args = Proof.hashArgs(
            input: "/in/tape.dv", inputArgs: ["-r", "30000/1001"], carriedIndices: [0, 2],
            soundFilter: Proof.originalSoundFilter(streamIndex: 1, liveChannel: 1),
            soundOutputs: ["live"], hashCodec: "pcm_s16le")
        #expect(args == [
            "-v", "error", "-nostdin", "-r", "30000/1001", "-i", "/in/tape.dv",
            "-filter_complex", "[0:1]channelmap=map=1:channel_layout=mono[live]",
            "-map", "0:0", "-map", "0:2", "-map", "[live]",
            "-c", "copy", "-c:a", "pcm_s16le", "-f", "streamhash", "-hash", "sha256", "-"
        ])
        // Nothing that resamples, re-times or writes a file.
        for forbidden in ["-ar", "-af", "-y", "-ac", "-sample_fmt"] { #expect(!args.contains(forbidden)) }
        #expect(args.last == "-", "the only output is stdout")

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
        let code = try SourceTree.appCode(named: "BalancedCopyProof.swift")
        #expect(code.contains("enum BalancedCopyProof"))
        // No file is created, moved, removed or trashed; nothing is stored.
        let forbidden = [
            "removeItem", "moveItem", "copyItem", "trashItem", "createFile", "createDirectory", "replaceItem",
            ".write(", "FileHandle(forWriting", "FileHandle(forUpdating", "unlink(", "rename(", "truncate(",
            "setAttributes", "UserDefaults", "NotificationCenter", "appLog.", "CatalogCommit", "placeRecord",
            "MediaTrash", "extension VideoScanModel"
        ]
        for word in forbidden {
            #expect(!code.contains(word), "BalancedCopyProof.swift must not use \(word)")
        }
        // One process runner, one tool locator — no second road to ffmpeg.
        #expect(!code.contains("Process()"))
        #expect(code.contains("ProcessRunner.runProcess("))
        #expect(code.contains("ToolLocator.ffmpegPath") && code.contains("ToolLocator.ffprobePath"))
        // ffmpeg is asked for hashes on stdout only: no overwrite flag, no output path.
        #expect(!code.contains("\"-y\""))
        #expect(code.contains("\"-f\", \"streamhash\", \"-hash\", \"sha256\", \"-\""))
    }
}
