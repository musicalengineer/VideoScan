// BalancedCopyProofDecisionTests.swift
// The PURE half of BalancedCopyProof: the decision table over measured
// facts — the three shapes of the answer (DECISIONS 2026-11-17: the same;
// the same content but differing in named things; not the same / could not
// check) — the header parser, the decode pass's argument builder and the
// log lines. No file, no subprocess.
//
// Dimensions here: LOGIC (every outcome, every reason, every named
// difference) · ISOLATION (one poisoned fact at a time, and every pair of
// them, never yields "proven") · SCALE (100k decisions inside a budget) ·
// SENSOR (the engine source writes nothing and launches processes only
// through the app's one runner). MEDIA and TRUTH are in the media suites.
// The measuring rules (whole reads, the two ledgers, the log) are
// table-tested in BalancedCopyProofRuleTests.

import Foundation
import Testing
@testable import VideoScan

@Suite("Balanced copy proof — the decision table")
struct BalancedCopyProofDecisionTests {

    typealias Proof = BalancedCopyProof

    // Distinct, well-formed digests.
    static let pictureHash = String(repeating: "a1", count: 32)
    static let timecodeHash = String(repeating: "b2", count: 32)
    static let soundHash = String(repeating: "c3", count: 32)
    static let otherHash = String(repeating: "d4", count: 32)
    static let timesHash = String(repeating: "e5", count: 32)
    static let otherTimesHash = String(repeating: "f6", count: 32)
    static let framesHash = String(repeating: "07", count: 32)

    static let movie = "mov,mp4,m4a,3gp,3g2,mj2"

    static func picture(width: Int? = 320, extradata: String = "") -> Proof.PictureConfiguration {
        Proof.PictureConfiguration(extradataSHA256: extradata, width: width, height: 240, pixelFormat: "yuv422p10le",
                                   sampleAspect: "1:1", displayAspect: "4:3", fieldOrder: "progressive",
                                   colorRange: "tv")
    }
    static func video(_ index: Int = 0, codec: String = "prores", hash: String? = pictureHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "video", codec: codec, tag: "apco", packetSHA256: hash,
                            timingSHA256: timesHash, packets: 50, timeBase: "1/12800", statedSeconds: 2,
                            storedSeconds: 2, configuration: picture())
    }
    static func timecode(_ index: Int, hash: String? = timecodeHash) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "data", codec: "", tag: "tmcd", packetSHA256: hash,
                            timingSHA256: timesHash, packets: 1, timeBase: "1/25", statedSeconds: 2)
    }
    static func captions(_ index: Int) -> Proof.CarriedStream {
        Proof.CarriedStream(index: index, kind: "subtitle", codec: "subrip", tag: "[0][0][0][0]",
                            packetSHA256: otherHash, timingSHA256: timesHash, packets: 2, timeBase: "1/1000")
    }
    /// `layout` nil = what a QuickTime file states: "mono" for one channel, else "stereo".
    static func sound(_ index: Int = 1, codec: String = "pcm_s16le", format: String = "s16", rate: Int = 48_000,
                      channels: Int = 2, layout: String? = nil) -> Proof.SoundStream {
        Proof.SoundStream(index: index, codec: codec, sampleFormat: format, sampleRateHz: rate, channels: channels,
                          channelLayout: layout ?? (channels == 1 ? "mono" : "stereo"), statedSeconds: 2,
                          storedSeconds: 2, tickSeconds: 1.0 / 48_000, packets: 94)
    }

    /// A decode pass that read exactly what the layout says is there, and
    /// played two seconds of it. `hashed` = channels hashed (1 for the
    /// original, 2 for the copy). `liveChannel` non-nil = the original's
    /// pass: every sound stream's peaks are measured — the kept one's live
    /// channel at −3.1 dBFS, everything else digital silence.
    static func wholeRead(of file: Proof.FileLayout, hashed: Int, liveChannel: Int? = nil, kept: Int? = nil) -> Proof.ReadReport {
        var report = Proof.ReadReport()
        var output = 0
        for stream in file.pictures {
            report.streams[stream.index] = Proof.StreamRead(packets: stream.packets ?? 0, decodeErrors: 0)
            report.pictures[stream.index] = Proof.PictureRead(frames: 50, sha256: framesHash, firstSeconds: 0,
                                                              endSeconds: stream.statedSeconds ?? 2)
            (report.muxed[output], report.folded[output]) = (50, 50)
            output += 1
        }
        (report.muxed[output], report.folded[output]) = (94, 94)
        for n in 1...hashed { (report.muxed[output + n], report.folded[output + n]) = (2, 2) }
        for stream in file.sound {
            report.streams[stream.index] = Proof.StreamRead(packets: stream.packets ?? 0, decodeErrors: 0)
            guard let liveChannel else { continue }
            var peaks = [Double](repeating: -.infinity, count: max(stream.channels, 0))
            if stream.index == (kept ?? file.sound.first?.index), peaks.indices.contains(liveChannel) { peaks[liveChannel] = -3.1 }
            report.peaksDBFS[stream.index] = peaks
        }
        report.soundSegments = [Proof.SoundSegment(start: 0, samples: 96_000)]
        report.channelSHA256 = Array(repeating: soundHash, count: hashed)
        report.channelSamples = Array(repeating: 96_000, count: hashed)
        return report
    }

    static func withWholeReads(_ facts: Proof.Facts) -> Proof.Facts {
        var f = facts
        f.originalRead = wholeRead(of: f.original, hashed: 1, liveChannel: Proof.liveChannel(for: f.originalClass) ?? 0,
                                   kept: f.keptSoundIndex)
        f.balancedRead = wholeRead(of: f.balanced, hashed: 2)
        return f
    }

    /// A left-only PCM original and a faithful balanced copy, QuickTime both.
    static func goodFacts() -> Proof.Facts {
        withWholeReads(Proof.Facts(
            original: Proof.FileLayout(carried: [video()], sound: [sound()], container: movie, tags: ["encoder": "Lavf"]),
            balanced: Proof.FileLayout(carried: [video()], sound: [sound()], container: movie, tags: ["encoder": "Lavf"]),
            originalClass: .leftOnly, originalMeasuredInFull: true))
    }

    /// Good facts with `change` applied, then both reads made WHOLE again for
    /// the changed layouts — so what a test changes is the one thing wrong.
    static func facts(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
        var f = goodFacts()
        change(&f)
        return withWholeReads(f)
    }

    /// Good facts with `change` applied and NOTHING re-derived: for poisoning
    /// what the decode passes themselves reported.
    static func poisoned(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
        var f = goodFacts()
        change(&f)
        return f
    }

    /// A two-track DV original (raw DV: live sound on stream 1, the spare
    /// track on 2) and its QuickTime copy with one sound track and the
    /// muxer's timecode track.
    static func dvFacts(_ change: (inout Proof.Facts) -> Void = { _ in }) -> Proof.Facts {
        var f = Proof.Facts(
            original: Proof.FileLayout(carried: [video(codec: "dvvideo")], sound: [sound(1), sound(2)], container: "dv"),
            balanced: Proof.FileLayout(carried: [video(codec: "dvvideo"), timecode(2)], sound: [sound(1)], container: movie),
            originalClass: .leftOnly, originalMeasuredInFull: true, keptSoundIndex: 1)
        f.original.carried[0].storedSeconds = nil
        f.original.sound[0].storedSeconds = nil
        f.original.sound[1].storedSeconds = nil
        f = withWholeReads(f)
        change(&f)
        return f
    }

    static func differs(_ outcome: Proof.Outcome) -> [String] { outcome.differences.map(Proof.sentence) }

    // MARK: Shape 1 — proven the same

    @Test("PROVEN: every frame and sample plays the same and nothing else differs")
    func provenWhenEverythingHolds() throws {
        let outcome = Proof.decide(Self.goodFacts())
        guard case .proven(let evidence) = outcome else {
            Issue.record("a faithful copy in the same container must be proven the same, got \(outcome)")
            return
        }
        #expect(outcome.isProven && outcome.playsTheSame && outcome.differences.isEmpty)
        #expect(evidence.liveChannel == 0 && evidence.originalClass == .leftOnly)
        #expect(evidence.soundSHA256 == Self.soundHash && evidence.soundCodec == "pcm_s16le")
        #expect(evidence.sampleFormat == "s16" && evidence.sampleRateHz == 48_000)
        #expect(evidence.soundSamples == 96_000 && evidence.soundStartSeconds == 0)
        #expect(evidence.streams == [Proof.Evidence.Stream(
            kind: "video", codec: "prores", originalIndex: 0, balancedIndex: 0, frames: 50,
            framesSHA256: Self.framesHash, packetIdentical: true, packetSHA256: Self.pictureHash, packets: 50)])
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
        // Pure: the same facts, the same answer.
        #expect(Proof.decide(Self.goodFacts()) == outcome)
    }

    @Test("PROVEN for a right-only original (live channel 1) and for a mono original spread to two channels")
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

    // MARK: Shape 2 — the same content, differing in named things

    @Test("SAME CONTENT: a track only one file has is NAMED, with the file that holds it")
    func trackDifferences() {
        // Raw DV → QuickTime: the copy gains the muxer's timecode track.
        let gained = Proof.decide(Self.facts { $0.balanced.carried = [Self.video(0), Self.timecode(2)] })
        #expect(gained.playsTheSame && !gained.isProven)
        #expect(gained.differences == [Proof.Difference(kind: .track, heldOnlyBy: .balancedCopy, what: "a timecode track")])
        #expect(Self.differs(gained) == ["[track] the balanced copy holds a timecode track"])
        // The original's timecode track is not in the copy: the ORIGINAL holds something.
        let lost = Proof.decide(Self.facts { $0.original.carried = [Self.video(0), Self.timecode(2)] })
        #expect(lost.differences == [Proof.Difference(kind: .track, heldOnlyBy: .original, what: "a timecode track")])
        // A text track and a data track, each named for what it is.
        let text = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.captions(2),
                                   Proof.CarriedStream(index: 3, kind: "data", codec: "bin_data", tag: "gpmd",
                                                       packetSHA256: Self.otherHash, timingSHA256: Self.timesHash, packets: 9)]
        })
        #expect(Self.differs(text) == ["[track] the original holds a text track (subrip)",
                                       "[track] the original holds a data track (bin_data)"])
        // Carried in both, and equal: no difference at all.
        let both = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.timecode(2)]
        })
        guard case .proven(let evidence) = both else { Issue.record("carried tmcd: \(both)"); return }
        #expect(evidence.streams.map(\.kind) == ["video", "data"])
        #expect(evidence.streams[1].frames == nil && evidence.streams[1].packetIdentical && evidence.streams[1].packets == 1)
        // The original has one, the copy two: the second is the copy's alone.
        let two = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.timecode(2), Self.timecode(3)]
        })
        #expect(Self.differs(two) == ["[track] the balanced copy holds a timecode track"])
        // Tracks of another codec do not answer for each other: one missing, one extra.
        let swapped = Proof.decide(Self.facts {
            $0.original.carried = [Self.video(0), Self.timecode(2)]
            $0.balanced.carried = [Self.video(0), Self.captions(2)]
        })
        #expect(Self.differs(swapped) == ["[track] the original holds a timecode track",
                                          "[track] the balanced copy holds a text track (subrip)"])
    }

    @Test("SAME CONTENT: container, how the picture is stored, and decoder configuration are named — neither file holds more")
    func containerEncodingAndConfigurationDifferences() {
        let container = Proof.decide(Self.facts {
            $0.original.container = "dv"
            $0.original.sound[0].channelLayout = "stereo"
        })
        #expect(container.differences == [Proof.Difference(
            kind: .container, heldOnlyBy: nil, what: "the original is a dv file, the balanced copy a mov file")])
        // Another codec, every decoded frame the same.
        let codec = Proof.decide(Self.facts { $0.balanced.carried = [Self.video(codec: "ffv1", hash: Self.otherHash)] })
        #expect(Self.differs(codec) == ["[encoding] picture stream 0 is stored as prores in the original and as ffv1 in the "
                                        + "balanced copy; every decoded frame is the same"])
        #expect(codec.evidence?.streams[0].packetIdentical == false)
        // The same codec in other packets: bytes, count or times.
        for change in [{ $0.packetSHA256 = Self.otherHash }, { $0.packets = 75 }, { $0.timingSHA256 = Self.otherTimesHash }]
            as [(inout Proof.CarriedStream) -> Void] {
            let stored = Proof.decide(Self.facts { change(&$0.balanced.carried[0]) })
            #expect(stored.differences.map(\.kind) == [.encoding] && stored.differences[0].heldOnlyBy == nil, "\(stored)")
            #expect(stored.differences[0].what.hasPrefix("picture stream 0 (prores) is not stored in the same packets"))
            #expect(stored.evidence?.streams[0].packetIdentical == false)
        }
        // Extradata written differently, frames identical.
        let extradata = Proof.decide(Self.facts { $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:ab" })
        #expect(extradata.differences.map(\.kind) == [.decoderConfiguration])
        #expect(extradata.differences[0].heldOnlyBy == nil)
    }

    @Test("SAME CONTENT: media an edit list hides is named as STORED BUT NOT PLAYED, with the file that stores it")
    func playbackDifferences() {
        // Rick's NH-Part-4 shape: the original stores 10:52 and plays 8:34; the copy holds only what plays.
        func hides(_ f: inout Proof.Facts, original: Double?, copy: Double?, played: Double = 514) {
            for side in [\Proof.Facts.original, \Proof.Facts.balanced] {
                f[keyPath: side].carried[0].statedSeconds = played
                f[keyPath: side].sound[0].statedSeconds = 2
            }
            f.original.carried[0].storedSeconds = original
            f.balanced.carried[0].storedSeconds = copy
        }
        let hidden = Proof.decide(Self.facts { hides(&$0, original: 652, copy: 514) })
        #expect(hidden.differences == [Proof.Difference(
            kind: .playback, heldOnlyBy: .original,
            what: "stored picture an edit list does not play: the original stores 10:52 of picture and plays 8:34, "
                + "the balanced copy stores 8:34 of picture and plays 8:34")])
        // The other way round: the COPY stores media it does not play.
        let copyHides = Proof.decide(Self.facts { hides(&$0, original: 514, copy: 652) })
        #expect(copyHides.differences.map(\.heldOnlyBy) == [.balancedCopy])
        // Both store the same hidden media (the job carried it): not a difference between them.
        #expect(Proof.decide(Self.facts { hides(&$0, original: 652, copy: 652) }).isProven)
        // A container with no edit lists states no stored length: nothing is hidden there.
        #expect(Proof.decide(Self.facts { hides(&$0, original: nil, copy: nil) }).isProven)
        let fromMatroska = Proof.decide(Self.facts { hides(&$0, original: nil, copy: 652) })
        #expect(fromMatroska.differences.map(\.heldOnlyBy) == [.balancedCopy])
        // Within a millisecond is not hidden media.
        #expect(Proof.decide(Self.facts { hides(&$0, original: 514.0009, copy: 514) }).isProven)
        // Hidden SOUND is named the same way.
        let sound = Proof.decide(Self.facts { $0.original.sound[0].storedSeconds = 3.5 })
        #expect(Self.differs(sound) == ["[playback instructions] the original holds stored sound an edit list does not play: the original "
                                        + "stores 3.500 s of sound and plays 2.000 s, the balanced copy stores 2.000 s of sound and plays 2.000 s"])
    }

    @Test("TRACK FLAGS: a decoded track that plays by default in the original and is switched off in the copy is NOT THE SAME; any other flag difference is named")
    func trackFlags() {
        func on(_ f: inout Proof.Facts) {
            for side in [\Proof.Facts.original, \Proof.Facts.balanced] {
                f[keyPath: side].carried[0].flags = ["default"]
                f[keyPath: side].sound[0].flags = ["default"]
            }
        }
        #expect(Proof.decide(Self.facts { on(&$0) }).isProven)
        // QuickTime's "track enabled" switch, off in the copy: a player skips the track.
        #expect(Proof.decide(Self.facts { on(&$0); $0.balanced.sound[0].flags = [] }) == .notProven(.pictureConfigurationDiffers(
            "audio stream 1: the balanced copy's track is not marked to play by default")))
        #expect(Proof.decide(Self.facts { on(&$0); $0.balanced.carried[0].flags = ["forced"] }) == .notProven(.pictureConfigurationDiffers(
            "picture stream 0: the balanced copy's track is not marked to play by default")))
        // Decided from the headers, before a packet is read.
        #expect(Proof.headerVerdict(Self.facts { on(&$0); $0.balanced.sound[0].flags = [] }) != nil)
        // Raw DV states no flags; its QuickTime copy's tracks are switched on: named, neither file holds more.
        let gained = Proof.decide(Self.facts { $0.balanced.carried[0].flags = ["default"]; $0.balanced.sound[0].flags = ["default"] })
        #expect(gained.differences == [Proof.Difference(
            kind: .playback, heldOnlyBy: nil,
            what: "track flags differ: picture stream 0 (the balanced copy only: default); the sound (the balanced copy only: default)")])
        let mixed = Proof.decide(Self.facts {
            $0.original.sound[0].flags = ["dub", "comment"]
            $0.balanced.sound[0].flags = ["comment", "original"]
        })
        #expect(mixed.differences.map(\.what) == ["track flags differ: the sound (the original only: dub; the balanced copy only: original)"])
    }

    @Test("CHAPTERS: chapter marks one file has and the other has not, or that differ, are named")
    func chapterMarks() {
        let marks = ["0.000000–1.000000 One", "1.000000–2.000000 Two"]
        #expect(Proof.decide(Self.facts { $0.original.chapters = marks; $0.balanced.chapters = marks }).isProven)
        #expect(Proof.decide(Self.facts { $0.original.chapters = marks }).differences == [Proof.Difference(
            kind: .metadata, heldOnlyBy: .original, what: "chapter marks (2 in the original, 0 in the balanced copy)")])
        #expect(Proof.decide(Self.facts { $0.balanced.chapters = marks }).differences.map(\.heldOnlyBy) == [.balancedCopy])
        let renamed = Proof.decide(Self.facts {
            $0.original.chapters = marks
            $0.balanced.chapters = [marks[0], "1.000000–2.000000 Deux"]
        })
        #expect(renamed.differences == [Proof.Difference(
            kind: .metadata, heldOnlyBy: nil, what: "chapter marks (2 in the original, 2 in the balanced copy)")])
    }

    @Test("SAME CONTENT: tags one file has and the other has not, or states differently, are named — at most six, then a count")
    func metadataDifferences() {
        let outcome = Proof.decide(Self.facts {
            $0.original.tags = ["encoder": "Lavf", "creation_time": "1994-12-25", "make": "Sony"]
            $0.balanced.tags = ["encoder": "Lavf63", "major_brand": "qt  "]
            $0.original.carried[0].tags = ["timecode": "01:00:00:00"]
            $0.balanced.sound[0].tags = ["handler_name": "SoundHandler"]
        })
        #expect(outcome.differences == [
            Proof.Difference(kind: .metadata, heldOnlyBy: .original,
                             what: "tags the balanced copy does not have: creation_time, make, stream 0 timecode"),
            Proof.Difference(kind: .metadata, heldOnlyBy: .balancedCopy,
                             what: "tags the original does not have: major_brand, sound handler_name"),
            Proof.Difference(kind: .metadata, heldOnlyBy: nil, what: "tags with different values: encoder")
        ])
        // A tag the other file states with the SAME value somewhere else is not missing: raw DV's
        // timecode is the container's, QuickTime's is the picture track's.
        #expect(Proof.decide(Self.facts {
            $0.original.tags["timecode"] = "01:00:00:00"
            $0.balanced.carried[0].tags["timecode"] = "01:00:00:00"
        }).isProven)
        #expect(Self.differs(Proof.decide(Self.facts {
            $0.original.tags["timecode"] = "01:00:00:00"
            $0.balanced.carried[0].tags["timecode"] = "02:00:00:00"
        })) == ["[metadata] the original holds tags the balanced copy does not have: timecode",
                "[metadata] the balanced copy holds tags the original does not have: stream 0 timecode"])
        let many = Proof.decide(Self.facts {
            for n in 1...9 { $0.original.tags["key\(n)"] = "v" }
        })
        #expect(many.differences.map(\.what) == ["tags the balanced copy does not have: key1, key2, key3, key4, key5, key6 +3 more"])
        #expect(Proof.namedTagLimit == 6)
    }

    @Test("SAME CONTENT: differences come in one order — tracks, container, encoding, decoder configuration, playback, metadata")
    func differencesAreOrdered() {
        let outcome = Proof.decide(Self.dvFacts {
            $0.balanced.tags = ["major_brand": "qt  "]
            $0.balanced.carried[0].configuration.extradataSHA256 = "SHA256:ab"
            $0.balanced.carried[0].storedSeconds = 9
        })
        #expect(outcome.differences.map(\.kind) == [.track, .track, .container, .decoderConfiguration, .playback, .metadata],
                "\(outcome)")
        guard case .sameContent(let evidence, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(evidence.streams.count == 1 && evidence.streams[0].codec == "dvvideo")
    }

    // MARK: The DV rule

    @Test("DV RULE: a second sound track may be left behind ONLY when measured silent, in a DV recording carried bit for bit")
    func spareSoundTrackRule() {
        func spare(_ outcome: Proof.Outcome) -> String? {
            if case .notProven(.spareSoundTrack(let what)) = outcome { return what }
            return nil
        }
        // The real job's shape: accepted, and the dropped track is a named difference held by the original.
        let good = Proof.decide(Self.dvFacts())
        #expect(Self.differs(good) == [
            "[track] the original holds a second sound track (stream 2, 2 channels), measured silent: digital silence",
            "[track] the balanced copy holds a timecode track",
            "[container] the original is a dv file, the balanced copy a mov file"
        ], "\(good)")
        // Quiet under the ceiling: accepted, and the measured peak is stated.
        let hiss = Proof.decide(Self.dvFacts { $0.originalRead?.peaksDBFS[2] = [-71.3, -.infinity] })
        #expect(hiss.differences.first?.what == "a second sound track (stream 2, 2 channels), measured silent: peak −71.3 dBFS")
        // Over the ceiling on either channel: the original is kept.
        for peaks in [[-59.9, -.infinity], [-.infinity, -12.0]] {
            #expect(spare(Proof.decide(Self.dvFacts { $0.originalRead?.peaksDBFS[2] = peaks }))?
                .hasPrefix("stream 2 is not silent: peak ") == true)
        }
        // Not measured — no peaks, too few, not a number: could not check, never "silent".
        for peaks in [nil, [], [-.infinity], [-.infinity, .nan]] as [[Double]?] {
            guard case .couldNotCheck(let why) = Proof.decide(Self.dvFacts { $0.originalRead?.peaksDBFS[2] = peaks }) else {
                Issue.record("unmeasured spare track \(String(describing: peaks)) must be could-not-check")
                continue
            }
            #expect(why == "the original's sound track 2 was not measured")
        }
        // The picture is not DV (decided from the headers), on either side.
        #expect(spare(Proof.headerVerdict(Self.dvFacts { $0.original.carried[0].codec = "h264"; $0.balanced.carried[0].codec = "h264" })
                      ?? .couldNotCheck(""))
                == "2 sound tracks; a spare one may be left behind only in a DV recording, and its picture is h264")
        #expect(spare(Proof.decide(Self.dvFacts { $0.balanced.carried[0].codec = "prores" })) != nil)
        // No picture at all.
        #expect(spare(Proof.decide(Self.dvFacts { $0.original.carried = []; $0.balanced.carried = [] }))?
            .hasSuffix("it has no picture") == true)
        // DV, but the copy's picture packets are not the original's bytes: every frame decodes the same, and still no.
        for change in [{ $0.packetSHA256 = Self.otherHash }, { $0.timingSHA256 = Self.otherTimesHash }, { $0.packets = 49 }]
            as [(inout Proof.CarriedStream) -> Void] {
            #expect(spare(Proof.decide(Self.withWholeReads(Self.dvFacts { change(&$0.balanced.carried[0]) })))
                    == "stream 2 is silent, but the picture is not DV carried bit for bit")
        }
        // The job reads the SECOND track when that is the live one.
        let second = Proof.decide(Self.withWholeReads(Self.dvFacts { $0.keptSoundIndex = 2 }))
        #expect(second.differences.first?.what.hasPrefix("a second sound track (stream 1, ") == true, "\(second)")
        // A kept index that names no stream is no track at all.
        #expect(Proof.decide(Self.dvFacts { $0.keptSoundIndex = 7 }) == .notProven(.originalSoundTracks(0)))
    }

    // MARK: Shape 3 — not the same

    @Test("NOT THE SAME: an original that is not one-sided, or has no sound track")
    func notProvenOriginalShape() {
        for c in [AudioChannelClass.dualMono, .trueStereo, .silent, .multichannel] {
            #expect(Proof.decide(Self.facts { $0.originalClass = c }) == .notProven(.originalNotOneSided(c)))
        }
        #expect(Proof.decide(Self.facts { $0.original.sound = [] }) == .notProven(.originalSoundTracks(0)))
        // Two sound tracks and a picture that is not DV: the DV rule does not cover it.
        guard case .notProven(.spareSoundTrack) = Proof.decide(Self.facts { $0.original.sound = [Self.sound(1), Self.sound(2)] }) else {
            Issue.record("two sound tracks outside DV must be refused")
            return
        }
    }

    @Test("NOT THE SAME by design: a lossy original — the reason names the codec, in plain words")
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
        for codec in ["pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_f32le", "PCM_S16LE"] {
            let outcome = Proof.decide(Self.facts {
                $0.original.sound = [Self.sound(codec: codec)]
                $0.balanced.sound = [Self.sound(codec: codec)]
            })
            #expect(outcome.isProven, "\(codec): \(outcome)")
        }
    }

    @Test("NOT THE SAME: the copy's sound track count, codec, sample format, rate or channel count is wrong")
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

    @Test("NOT THE SAME: a picture stream more or less — a picture is content, never a named difference")
    func notProvenPictureStreamSet() {
        #expect(Proof.decide(Self.facts { $0.balanced.carried = [] })
                == .notProven(.streamsDiffer("the original has 1 picture streams, the balanced copy 0")))
        #expect(Proof.decide(Self.facts { $0.balanced.carried = [Self.video(0), Self.video(2)] })
                == .notProven(.streamsDiffer("the original has 1 picture streams, the balanced copy 2")))
        #expect(Proof.decide(Self.facts { $0.balanced.carried = [Self.timecode(0)] })
                == .notProven(.streamsDiffer("the original has 1 picture streams, the balanced copy 0")))
        #expect(Proof.decide(Self.facts { $0.original.carried.append(Self.video(3)) })
                == .notProven(.streamsDiffer("the original has 2 picture streams, the balanced copy 1")))
    }

    @Test("NOT THE SAME: the picture plays other frames, fewer frames, or the same frames at other times")
    func notProvenPictureDiffers() {
        // An edit list that hides half the picture: identical packets, 25 frames played instead of 50.
        let fewer = Proof.decide(Self.poisoned { $0.balancedRead?.pictures[0]?.frames = 25 })
        #expect(fewer == .notProven(.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy")))
        // Same count, another digest: other pixels (a changed palette), or other times.
        let other = Proof.decide(Self.poisoned { $0.balancedRead?.pictures[0]?.sha256 = Self.otherHash })
        guard case .notProven(.pictureDiffers(0, let what)) = other else { Issue.record("\(other)"); return }
        #expect(what.contains(Proof.short(Self.framesHash)) && what.contains(Proof.short(Self.otherHash)))
        // IDENTICAL PACKETS DO NOT RESCUE IT: the packet evidence is second, the frames decide.
        #expect(fewer.playsTheSame == false)
        // The picture is judged before the sound: a copy wrong in both says the picture.
        let both = Proof.decide(Self.poisoned {
            $0.balancedRead?.pictures[0]?.sha256 = Self.otherHash
            $0.balancedRead?.channelSHA256[1] = Self.otherHash
        })
        guard case .notProven(.pictureDiffers) = both else { Issue.record("\(both)"); return }
    }

    @Test("NOT THE SAME: a timecode or text track both files have must be the same packet for packet")
    func notProvenCarriedTrackDiffers() {
        func decide(_ change: @escaping (inout Proof.CarriedStream) -> Void) -> Proof.Outcome {
            Proof.decide(Self.facts {
                $0.original.carried = [Self.video(0), Self.timecode(2)]
                $0.balanced.carried = [Self.video(0), Self.timecode(2)]
                change(&$0.balanced.carried[1])
            })
        }
        #expect(decide { $0.packetSHA256 = Self.otherHash } == .notProven(.carriedStreamDiffers(
            kind: "data", originalIndex: 2, "sha256 \(Proof.short(Self.timecodeHash)) ≠ \(Proof.short(Self.otherHash))")))
        #expect(decide { $0.packets = 2 }
                == .notProven(.carriedStreamDiffers(kind: "data", originalIndex: 2, "1 packets, the balanced copy 2")))
        #expect(decide { $0.timingSHA256 = Self.otherTimesHash }
                == .notProven(.carriedStreamDiffers(kind: "data", originalIndex: 2, "its packets are not at the original's times")))
        // Unread, uncounted, or holding nothing (a Matroska attachment): could not check.
        for poison in [{ $0.packetSHA256 = nil }, { $0.packets = nil }, { $0.packets = 0 }, { $0.timingSHA256 = "abc" },
                       { $0.packetSHA256 = Proof.emptySHA256 }] as [(inout Proof.CarriedStream) -> Void] {
            #expect(decide(poison) == .couldNotCheck("data stream 2 gave no packets to compare"))
        }
    }

    @Test("NOT THE SAME: the copy's channels differ from each other, from the original's live channel, or are placed at other times")
    func notProvenSoundDiffers() {
        #expect(Proof.decide(Self.poisoned { $0.balancedRead?.channelSHA256[1] = Self.otherHash })
                == .notProven(.channelsDiffer(left: Self.soundHash, right: Self.otherHash)))
        #expect(Proof.decide(Self.poisoned { $0.balancedRead?.channelSHA256[0] = Self.otherHash })
                == .notProven(.channelsDiffer(left: Self.otherHash, right: Self.soundHash)))
        #expect(Proof.decide(Self.poisoned { $0.balancedRead?.channelSHA256 = [Self.otherHash, Self.otherHash] })
                == .notProven(.soundDiffers(original: Self.soundHash, balanced: Self.otherHash)))
        // The same samples, half a second late.
        func placement(_ segments: [Proof.SoundSegment]) -> Proof.Outcome {
            Proof.decide(Self.poisoned { $0.balancedRead?.soundSegments = segments })
        }
        #expect(placement([Proof.SoundSegment(start: 24_000, samples: 96_000)]) == .notProven(.soundPlacementDiffers(
            "run 1: 96000 samples from sample time 0, in the balanced copy 96000 from 24000")))
        // The same samples, moved INSIDE the recording and back (Codex #304-3): the runs are not the original's.
        #expect(placement([Proof.SoundSegment(start: 0, samples: 10_240), Proof.SoundSegment(start: 10_720, samples: 85_760)])
                == .notProven(.soundPlacementDiffers("the original's sound plays in 1 unbroken runs, the balanced copy's in 2")))
        // One sample period is the tolerance; two is a difference.
        #expect(placement([Proof.SoundSegment(start: 1, samples: 96_000)]).isProven)
        #expect(!placement([Proof.SoundSegment(start: 2, samples: 96_000)]).playsTheSame)
        // An original that itself has a gap is proven against a copy with the SAME gap.
        let gap = [Proof.SoundSegment(start: 0, samples: 48_000), Proof.SoundSegment(start: 72_000, samples: 48_000)]
        let sameGap = Proof.decide(Self.poisoned {
            $0.originalRead?.soundSegments = gap
            $0.balancedRead?.soundSegments = gap
        })
        let oneGap = Proof.decide(Self.poisoned { $0.originalRead?.soundSegments = gap })
        #expect(sameGap.isProven && !oneGap.playsTheSame)
    }

    // MARK: Could not check — unknown is never the same

    @Test("COULD NOT CHECK: a partly measured original, a missing digest, the digest of nothing, an unreadable format")
    func couldNotCheckTable() {
        func unchecked(_ o: Proof.Outcome) -> Bool {
            if case .couldNotCheck(let reason) = o { return !reason.isEmpty }
            return false
        }
        #expect(unchecked(Proof.decide(Self.facts { $0.originalMeasuredInFull = false })))
        #expect(unchecked(Proof.decide(Self.poisoned { $0.originalRead?.channelSHA256 = [] })))
        #expect(unchecked(Proof.decide(Self.poisoned { $0.balancedRead?.channelSHA256 = [Self.soundHash] })))
        #expect(unchecked(Proof.decide(Self.poisoned { $0.originalRead?.pictures[0] = nil })))
        #expect(unchecked(Proof.decide(Self.poisoned { $0.balancedRead?.pictures[0]?.sha256 = "abc" })))
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
        // Equal digests OF NOTHING are not a proof: no sample, no frame was compared.
        #expect(unchecked(Proof.decide(Self.poisoned {
            $0.originalRead?.channelSHA256 = [Proof.emptySHA256]
            $0.balancedRead?.channelSHA256 = [Proof.emptySHA256, Proof.emptySHA256]
        })))
        #expect(unchecked(Proof.decide(Self.poisoned {
            $0.originalRead?.pictures[0]?.sha256 = Proof.emptySHA256
            $0.balancedRead?.pictures[0]?.sha256 = Proof.emptySHA256
        })))
        #expect(unchecked(Proof.decide(Self.poisoned {
            $0.originalRead?.pictures[0]?.frames = 0
            $0.balancedRead?.pictures[0]?.frames = 0
        })))
        // A partly measured original outranks everything else it would say.
        #expect(unchecked(Proof.decide(Self.facts {
            $0.originalMeasuredInFull = false
            $0.originalClass = .dualMono
        })))
    }

    static let poisons: [(String, @Sendable (inout Proof.Facts) -> Void)] = [
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
        ("copy second sound", { $0.balanced.sound.append(sound(2)) }),
        ("original second sound", { $0.original.sound.append(sound(2)) }),
        ("kept sound nowhere", { $0.keptSoundIndex = 9 }),
        ("copy picture kind", { $0.balanced.carried[0].kind = "subtitle" }),
        ("copy picture gone", { $0.balanced.carried = [] }),
        ("original extra picture", { $0.original.carried.append(video(3)) }),
        ("copy extra picture", { $0.balanced.carried.append(video(3)) }),
        ("copy layout", { $0.balanced.sound[0].channelLayout = "2 channels (FC+LFE)" }),
        ("copy layout unset in QuickTime", { $0.balanced.sound[0].channelLayout = ""; $0.balanced.container = movie }),
        ("original layout", { $0.original.sound[0].channelLayout = "2 channels (FC+LFE)" }),
        ("original channels", { $0.original.sound[0].channels = 3 }),
        ("copy picture width", { $0.balanced.carried[0].configuration.width = 304 }),
        ("copy pixel format", { $0.balanced.carried[0].configuration.pixelFormat = "yuv420p" }),
        ("copy colour range", { $0.balanced.carried[0].configuration.colorRange = "pc" }),
        ("original picture size unread", { $0.original.carried[0].configuration.width = nil }),
        ("copy picture side data", { $0.balanced.carried[0].configuration.sideData = "[{\"rotation\":-180}]" }),
        ("copy sound side data", { $0.balanced.sound[0].sideData = "[{}]" }),
        ("copy sound switched off", { $0.original.sound[0].flags = ["default"] }),
        ("copy picture switched off", { $0.original.carried[0].flags = ["default"] }),
        ("copy picture packets uncounted", { $0.balanced.carried[0].packets = nil }),
        ("original picture packets unread", { $0.original.carried[0].packetSHA256 = nil }),
        ("copy packet times unread", { $0.balanced.carried[0].timingSHA256 = nil }),
        ("no original read", { $0.originalRead = nil }),
        ("no copy read", { $0.balancedRead = nil }),
        ("original picture read short", { $0.originalRead?.streams[0]?.packets = 25 }),
        ("copy picture read short", { $0.balancedRead?.streams[0]?.packets = 25 }),
        ("copy sound read short", { $0.balancedRead?.streams[1]?.packets = 47 }),
        ("copy sound decode error", { $0.balancedRead?.streams[1]?.decodeErrors = 1 }),
        ("copy decode errors uncounted", { $0.balancedRead?.streams[0]?.decodeErrors = nil }),
        ("original stream unaccounted", { $0.originalRead?.streams[0] = nil }),
        ("frames lost on the way", { $0.balancedRead?.folded[0] = 49 }),
        ("nothing folded", { $0.originalRead?.folded = [:]; $0.originalRead?.muxed = [:] }),
        ("copy frames", { $0.balancedRead?.pictures[0]?.frames = 25 }),
        ("copy frames digest", { $0.balancedRead?.pictures[0]?.sha256 = otherHash }),
        ("original frames digest", { $0.originalRead?.pictures[0]?.sha256 = timesHash }),
        ("copy picture unplayed", { $0.balancedRead?.pictures[0] = nil }),
        ("copy picture decoded short of its header", { $0.balancedRead?.pictures[0]?.endSeconds = 1 }),
        ("original picture decoded past its header", { $0.originalRead?.pictures[0]?.endSeconds = 4 }),
        ("live digest", { $0.originalRead?.channelSHA256 = [otherHash] }),
        ("left digest", { $0.balancedRead?.channelSHA256[0] = otherHash }),
        ("right digest", { $0.balancedRead?.channelSHA256[1] = otherHash }),
        ("right digest empty", { $0.balancedRead?.channelSHA256[1] = "" }),
        ("a third digest", { $0.balancedRead?.channelSHA256.append(soundHash) }),
        ("copy sound late", { $0.balancedRead?.soundSegments = [Proof.SoundSegment(start: 480, samples: 96_000)] }),
        ("copy sound broken in two", {
            $0.balancedRead?.soundSegments = [Proof.SoundSegment(start: 0, samples: 48_000),
                                              Proof.SoundSegment(start: 48_100, samples: 48_000)]
        }),
        ("copy sound short", { $0.balancedRead?.soundSegments = [Proof.SoundSegment(start: 0, samples: 95_000)] }),
        ("copy timeline unread", { $0.balancedRead?.soundSegments = nil }),
        ("original timeline empty", { $0.originalRead?.soundSegments = [] }),
        ("right channel short", { $0.balancedRead?.channelSamples = [96_000, 95_000] }),
        ("no peaks", { $0.originalRead?.peaksDBFS = [:] }),
        ("one peak", { $0.originalRead?.peaksDBFS[1] = [-3.1] }),
        ("peak not a number", { $0.originalRead?.peaksDBFS[1] = [-3.1, .nan] }),
        ("other channel loud", { $0.originalRead?.peaksDBFS[1] = [-3.1, -48.2] }),
        ("other channel just over", { $0.originalRead?.peaksDBFS[1] = [-3.1, -59.99] })
    ]

    @Test("ISOLATION: poisoning any one fact of a proven pair — or any TWO — never leaves it playing the same; decide is total")
    func poisonedFactsNeverProve() {
        #expect(Proof.decide(Self.goodFacts()).isProven, "the baseline must be proven or this test proves nothing")
        for (name, poison) in Self.poisons {
            let outcome = Proof.decide(Self.poisoned(poison))
            #expect(!outcome.playsTheSame, "poisoned \(name) must not play the same: \(outcome)")
        }
        // Every pair, in both orders: 4,000 decisions, none of them "the same", none a crash.
        var decided = 0
        for (first, a) in Self.poisons {
            for (second, b) in Self.poisons {
                var f = Self.goodFacts()
                // A poison that removes streams goes last, so the other still has its stream to poison.
                if ["original sound gone", "copy sound gone", "copy picture gone"].contains(first) { b(&f); a(&f) } else { a(&f); b(&f) }
                let outcome = Proof.decide(f)
                decided += 1
                if outcome.playsTheSame { Issue.record("\(first) + \(second) plays the same: \(outcome)") }
            }
        }
        #expect(decided == Self.poisons.count * Self.poisons.count && decided > 3_900)
    }

    @Test("ISOLATION: a named difference is never PROVEN — and never hides a refusal")
    func namedDifferencesAreNeverProven() {
        let named: [(String, (inout Proof.Facts) -> Void)] = [
            ("copy gained a timecode track", { $0.balanced.carried.append(Self.timecode(2)) }),
            ("original's captions dropped", { $0.original.carried.append(Self.captions(2)) }),
            ("container", { $0.balanced.container = "matroska,webm"; $0.balanced.sound[0].channelLayout = "" }),
            ("codec", { $0.balanced.carried[0].codec = "ffv1" }),
            ("packet bytes", { $0.balanced.carried[0].packetSHA256 = Self.otherHash }),
            ("packet count", { $0.original.carried[0].packets = 75 }),
            ("packet times", { $0.balanced.carried[0].timingSHA256 = Self.otherTimesHash }),
            ("extradata", { $0.original.carried[0].configuration.extradataSHA256 = "SHA256:ab" }),
            ("hidden picture", { $0.original.carried[0].storedSeconds = 9 }),
            ("hidden sound", { $0.balanced.sound[0].storedSeconds = 9 }),
            ("format tag", { $0.balanced.tags["encoder"] = "other" }),
            ("stream tag", { $0.original.carried[0].tags["timecode"] = "01:00:00:00" }),
            ("sound tag", { $0.balanced.sound[0].tags["handler_name"] = "x" }),
            ("track flag", { $0.balanced.carried[0].flags = ["forced"] }),
            ("chapter marks", { $0.original.chapters = ["0.000000–1.000000 One"] })
        ]
        for (name, change) in named {
            let outcome = Proof.decide(Self.facts(change))
            guard case .sameContent(_, let differs) = outcome else {
                Issue.record("\(name): expected same content with a named difference, got \(outcome)")
                continue
            }
            #expect(differs.count == 1 && !outcome.isProven, "\(name): \(differs)")
            // With any refusal on top, the refusal wins.
            for (poisonName, poison) in Self.poisons {
                var f = Self.facts(change)
                poison(&f)
                #expect(!Proof.decide(f).playsTheSame, "\(name) + \(poisonName)")
            }
        }
    }

    @Test("headerVerdict decides lossy and mis-shaped pairs before any packet is read; good headers wait for the reads")
    func headerVerdictNeedsNoReads() {
        func headersOnly(_ change: (inout Proof.Facts) -> Void) -> Proof.Facts {
            var f = Self.facts(change)
            f.originalRead = nil
            f.balancedRead = nil
            for side in [\Proof.Facts.original, \Proof.Facts.balanced] {
                for i in f[keyPath: side].carried.indices {
                    f[keyPath: side].carried[i].packets = nil
                    f[keyPath: side].carried[i].packetSHA256 = nil
                    f[keyPath: side].carried[i].timingSHA256 = nil
                }
            }
            return f
        }
        #expect(Proof.headerVerdict(headersOnly { $0.original.sound = [Self.sound(codec: "aac", format: "fltp")] })
                == .notProven(.soundReencoded(codec: "aac")))
        #expect(Proof.headerVerdict(headersOnly { $0.balanced.sound = [] }) == .notProven(.balancedSoundTracks(0)))
        #expect(Proof.headerVerdict(headersOnly { $0.originalClass = .dualMono }) == .notProven(.originalNotOneSided(.dualMono)))
        #expect(Proof.headerVerdict(headersOnly { $0.balanced.carried[0].configuration.sideData = "[{}]" }) != nil)
        #expect(Proof.headerVerdict(headersOnly { $0.balanced.carried = [] }) != nil)
        #expect(Proof.headerVerdict(headersOnly { _ in }) == nil, "good headers: go on and read the packets")
        // … and decide() refuses to say "the same" without them.
        guard case .couldNotCheck = Proof.decide(headersOnly { _ in }) else {
            Issue.record("headers without packets or frames are not a proof")
            return
        }
    }

    // MARK: Log lines

    @Test("LOGGING: one START line and one OUTCOME line naming both files, the verdict, the evidence and every difference")
    func logLinesNameFilesVerdictEvidenceAndDifferences() {
        let original = "/Volumes/Tapes/1994 Xmas.mov"
        let copy = "/Volumes/Tapes/1994 Xmas_balanced.mov"
        let pair = "original \"\(original)\" · balanced copy \"\(copy)\""
        #expect(Proof.startLine(original: original, balanced: copy) == "balanced copy proof: START — \(pair)")

        let proven = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.goodFacts()))
        #expect(proven.hasPrefix("balanced copy proof: OUTCOME PROVEN THE SAME — \(pair) — "))
        #expect(proven.contains("picture 0→0: 50 decoded frames, each one's time, duration and pixels equal, sha256 \(Self.framesHash); "
                                + "stored packets identical, sha256 \(Self.pictureHash) (50)"))
        #expect(proven.contains("sound pcm_s16le 48000 Hz: original left = copy left = copy right, 96000 samples at the same times, "
                                + "sha256 \(Self.soundHash)"))
        #expect(proven.contains("original right: digital silence, not in the copy"))
        #expect(proven.hasSuffix("; nothing else differs") && !proven.contains("\n"))

        let quiet = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.poisoned {
            $0.originalRead?.peaksDBFS[1] = [-3.1, -71.3]
        }))
        #expect(quiet.contains("original right: peak −71.3 dBFS, not in the copy"), "\(quiet)")
        let mono = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.facts {
            $0.originalClass = .mono
            $0.original.sound = [Self.sound(channels: 1)]
        }))
        #expect(mono.contains("original has one channel, nothing left behind"), "\(mono)")
        let right = Proof.logLine(original: original, balanced: copy,
                                  outcome: Proof.decide(Self.facts { $0.originalClass = .rightOnly }))
        #expect(right.contains("original right = copy left = copy right") && right.contains("original left: digital silence"))

        // The second shape names every difference, and who holds what.
        let dv = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.dvFacts()))
        #expect(dv.hasPrefix("balanced copy proof: OUTCOME SAME CONTENT, DIFFERS IN 3 — \(pair) — "))
        #expect(dv.hasSuffix(" — differs: [track] the original holds a second sound track (stream 2, 2 channels), measured silent: "
                             + "digital silence | [track] the balanced copy holds a timecode track | "
                             + "[container] the original is a dv file, the balanced copy a mov file"))
        #expect(!dv.contains("nothing else differs") && !dv.contains("PROVEN"))
        let stored = Proof.logLine(original: original, balanced: copy, outcome: Proof.decide(Self.facts {
            $0.balanced.carried[0].packetSHA256 = Self.otherHash
        }))
        #expect(stored.contains("stored packets differ") && !stored.contains("stored packets identical"))

        let not = Proof.logLine(original: original, balanced: copy,
                                outcome: Proof.decide(Self.poisoned { $0.balancedRead?.channelSHA256[1] = Self.otherHash }))
        #expect(not.hasPrefix("balanced copy proof: OUTCOME NOT THE SAME — \(pair) — "))
        #expect(not.contains(Proof.short(Self.soundHash)) && not.contains(Proof.short(Self.otherHash)))
        #expect(not.hasSuffix("— the original is kept") && !not.contains("\n"))

        let unchecked = Proof.logLine(original: original, balanced: copy,
                                      outcome: .couldNotCheck("the balanced copy is not on disk, or cannot be read"))
        #expect(unchecked == "balanced copy proof: OUTCOME COULD NOT CHECK — \(pair)"
                + " — the balanced copy is not on disk, or cannot be read")
    }

    @Test("LOGGING: every line is ONE line whatever a file name, a tag or a reason holds — a newline cannot forge a PROVEN record")
    func logLinesAreAlwaysOneLine() {
        let line = Proof.logLine(original: "a.mov\nbalanced copy proof: OUTCOME PROVEN THE SAME — forged", balanced: "b.mov",
                                 outcome: .couldNotCheck("unreadable"))
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("balanced copy proof: OUTCOME COULD NOT CHECK — "))
        let hostile = "x\r\ny\u{2028}z\u{0085}w\u{0007}\tq"
        let tagged = Proof.decide(Self.facts { $0.original.tags[hostile] = hostile; $0.original.carried.append(Self.captions(2)) })
        #expect(tagged.differences.count == 2)
        for outcome in [Proof.Outcome.couldNotCheck(hostile), .notProven(.soundReencoded(codec: hostile)),
                        .notProven(.streamsDiffer(hostile)), Proof.decide(Self.goodFacts()), tagged] {
            for record in [Proof.logLine(original: hostile, balanced: hostile, outcome: outcome),
                           Proof.startLine(original: hostile, balanced: hostile)] {
                #expect(record.unicodeScalars.allSatisfy { !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) },
                        "\(record.debugDescription)")
            }
        }
    }

    @Test("Every not-the-same reason has its own plain sentence, ending the same way")
    func everyReasonHasASentence() {
        let reasons: [Proof.NotProven] = [
            .originalNotOneSided(.trueStereo), .originalSoundTracks(0), .soundReencoded(codec: "mp3"),
            .balancedSoundTracks(0), .soundFormatChanged("codec a → b"), .streamsDiffer("x"),
            .channelLayoutNotStereo(file: "the balanced copy", layout: "2 channels (FC+LFE)"),
            .pictureConfigurationDiffers("picture stream 0: width 320 → 304"),
            .pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy"),
            .carriedStreamDiffers(kind: "subtitle", originalIndex: 2, "2 packets, the balanced copy 3"),
            .soundPlacementDiffers("run 1"), .discardedChannelNotSilent(channel: 1, peakDBFS: -48.2),
            .spareSoundTrack("stream 2 is not silent: peak −12.0 dBFS"),
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
        #expect(Proof.NotProven.discardedChannelNotSilent(channel: 1, peakDBFS: -48.2).message
                == "the original's other channel is not silent (peak −48.2 dBFS) — the original is kept")
        #expect(Proof.NotProven.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy").message
                == "picture stream 0 does not play the same in the balanced copy (50 frames play in the original, 25 in the "
                + "balanced copy) — the original is kept")
        // A difference's kind reads as plain words.
        #expect(Proof.Difference.Kind.playback.rawValue == "playback instructions")
        #expect(Proof.Difference.Kind.decoderConfiguration.rawValue == "decoder configuration")
        #expect(Proof.length(1.968633) == "1.969 s" && Proof.length(514) == "8:34" && Proof.length(652) == "10:52")
        #expect(Proof.length(3723.4) == "1:02:03" && Proof.length(59.9996) == "60.000 s")
    }

    // MARK: Parsers and argument builders

    @Test("layout(fromProbeJSON:): sound apart from carried streams, with configuration, side data, stated length and tags; stored lengths from the edit-list-ignoring read")
    func layoutParse() throws {
        let json = Data("""
        {"streams":[
          {"index":0,"codec_name":"h264","codec_type":"video","codec_tag_string":"avc1","width":320,"height":240,
           "pix_fmt":"yuv420p","sample_aspect_ratio":"1:1","display_aspect_ratio":"4:3","field_order":"progressive",
           "color_range":"tv","color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709",
           "r_frame_rate":"25/1","avg_frame_rate":"25/1","time_base":"1/12800","start_time":"0.000000",
           "duration":"1.000000","extradata_hash":"SHA256:abcd","disposition":{"default":1},
           "tags":{"handler_name":"VideoHandler","timecode":"01:00:00:00"},
           "side_data_list":[{"side_data_type":"Display Matrix","rotation":-180,"displaymatrix":"\\n0: -65536 0 0\\n"}]},
          {"index":1,"codec_name":"pcm_s24le","codec_type":"audio","codec_tag_string":"in24",
           "sample_fmt":"s32","sample_rate":"48000","channels":2,"channel_layout":"stereo","r_frame_rate":"0/0",
           "avg_frame_rate":"0/0","time_base":"1/48000","start_time":"0.500000","duration":"2.000000"},
          {"index":2,"codec_type":"data","codec_tag_string":"tmcd","time_base":"1/25",
           "tags":{"DURATION":"00:00:01.800000000"}}],
         "chapters":[{"id":1,"time_base":"1/1000","start":0,"start_time":"0.000000","end":1000,"end_time":"1.000000",
                      "tags":{"title":"One"}},{"id":2,"start_time":"1.000000","end_time":"2.000000"}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"2.500000","tags":{"encoder":"Lavf"}}}
        """.utf8)
        let layout = try #require(Proof.layout(fromProbeJSON: json))
        #expect(layout.container == Self.movie && layout.containerWords.contains("mov") && layout.hasEditLists)
        #expect(layout.tags == ["encoder": "Lavf"])
        #expect(layout.chapters == ["0.000000–1.000000 One", "1.000000–2.000000 "])
        #expect(layout.carried[0].flags == ["default"] && layout.carried[1].flags.isEmpty && layout.sound[0].flags.isEmpty)
        #expect(layout.carried.map(\.index) == [0, 2] && layout.pictures.map(\.index) == [0])
        let video = layout.carried[0]
        #expect(video.kind == "video" && video.codec == "h264" && video.tag == "avc1" && video.timeBase == "1/12800")
        #expect(video.isPicture && video.statedSeconds == 1 && video.storedSeconds == nil)
        #expect(video.tags == ["handler_name": "VideoHandler", "timecode": "01:00:00:00"])
        // Packets are the packet pass's to fill in: unknown until then.
        #expect(video.packetSHA256 == nil && video.timingSHA256 == nil && video.packets == nil)
        #expect(video.configuration == Proof.PictureConfiguration(
            extradataSHA256: "SHA256:abcd", width: 320, height: 240, pixelFormat: "yuv420p", sampleAspect: "1:1",
            displayAspect: "4:3", fieldOrder: "progressive", colorRange: "tv", colorSpace: "bt709",
            colorTransfer: "bt709", colorPrimaries: "bt709",
            sideData: #"[{"displaymatrix":"\n0: -65536 0 0\n","rotation":-180,"side_data_type":"Display Matrix"}]"#))
        let timecode = layout.carried[1]
        #expect(timecode.isTimecodeTrack && !timecode.isPicture && timecode.codec.isEmpty && !video.isTimecodeTrack)
        #expect(timecode.statedSeconds == 1.8, "Matroska states a stream's length as a DURATION tag")
        let sound = try #require(layout.sound.first)
        #expect(layout.sound.count == 1)
        #expect(sound.index == 1 && sound.codec == "pcm_s24le" && sound.sampleFormat == "s32")
        #expect(sound.sampleRateHz == 48_000 && sound.channels == 2 && sound.channelLayout == "stereo")
        #expect(sound.sideData.isEmpty && sound.statedSeconds == 2 && sound.packets == nil && sound.tags.isEmpty)
        #expect(abs(sound.timingSlackSeconds - 1.0 / 48_000) < 1e-12)
        #expect(abs(video.timingSlackSeconds - 1.0 / 12_800) < 1e-12)
        #expect(timecode.timingSlackSeconds == Proof.timingSlackCeilingSeconds, "a 40 ms tick is capped at 1 ms")
        #expect(Proof.layout(fromProbeJSON: Data("{}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("{\"streams\":[]}".utf8)) == nil)
        #expect(Proof.layout(fromProbeJSON: Data("not json".utf8)) == nil)
        // Unreadable numbers are unknown, never zero.
        #expect(Proof.seconds("N/A") == nil && Proof.seconds(nil) == nil && Proof.seconds("nan") == nil)
        #expect(Proof.tick("0/1") == nil && Proof.tick("1/0") == nil && Proof.tick("x") == nil)

        // What each track STORES, with the edit list ignored: the picture holds two seconds and plays one.
        let stored = Data(#"{"streams":[{"index":0,"duration":"2.000000"},{"index":1,"duration":"2.000000"},{"index":2,"duration":"N/A"}]}"#.utf8)
        let full = try #require(Proof.withStoredLengths(layout, fromProbeJSON: stored))
        #expect(full.carried.map(\.storedSeconds) == [2, nil] && full.sound[0].storedSeconds == 2)
        #expect(full.carried[0].statedSeconds == 1, "the stated (played) length is untouched")
        // Another stream count, or a stream with no index, is not this file's answer.
        #expect(Proof.withStoredLengths(layout, fromProbeJSON: Data(#"{"streams":[{"index":0,"duration":"2.0"}]}"#.utf8)) == nil)
        #expect(Proof.withStoredLengths(layout, fromProbeJSON: Data(#"{"streams":[{},{},{}]}"#.utf8)) == nil)
        #expect(Proof.withStoredLengths(layout, fromProbeJSON: Data("junk".utf8)) == nil)

        #expect(Proof.layoutArgs(input: "/in/a.mov")
                == ["-v", "error", "-show_data_hash", "sha256", "-show_streams", "-show_format", "-show_chapters", "-of", "json",
                    "/in/a.mov"])
        #expect(Proof.storedArgs(input: "/in/a.mov")
                == ["-v", "error", "-ignore_editlist", "1", "-show_entries", "stream=index,duration", "-of", "json", "/in/a.mov"])
        #expect(Proof.packetArgs(input: "/in/a.mov")
                == ["-v", "error", "-show_packets", "-show_data_hash", "sha256", "-show_entries",
                    "packet=stream_index,pts,duration,size,data_hash", "-of", "csv=p=0", "/in/a.mov"])
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
        #expect(Proof.packedSampleFormat("s32p") == "s32" && Proof.packedSampleFormat("flt") == "flt")
    }

    @Test("decodeArgs: every picture and the sound decoded as a player reads them, formats pinned, no conversion allowed, errors fatal")
    func decodeArgsVector() throws {
        let plan = Proof.DecodePlan(
            pictures: [Proof.DecodePlan.Picture(index: 0, pixelFormat: "yuv411p")], soundIndex: 1, sampleFormat: "s16",
            sampleRateHz: 48_000, channels: [1], measured: [1, 2], runTag: "vsabc")
        let args = Proof.decodeArgs(input: "/in/tape.dv", inputArgs: ["-r", "30000/1001"], plan: plan, hashCodec: "pcm_s16le")
        let peak = "=measure_perchannel=Peak_level:measure_overall=none"
        let pick = "aresample=osf=s16p,channelmap=map=1:channel_layout=mono,aresample=osf=s16"
        #expect(args == [
            "-v", "repeat+level+verbose", "-nostdin", "-nostats", "-hide_banner", "-xerror", "-err_detect", "explode",
            "-noauto_conversion_filters", "-copyts", "-r", "30000/1001", "-i", "/in/tape.dv",
            "-filter_complex",
            "[0:0]format=pix_fmts=yuv411p[p0];"
                + "[0:1]aformat=sample_fmts=s16:sample_rates=48000,astats@vsabcs1\(peak),asplit=2[t][c0];"
                + "[t]\(pick)[timeline];[c0]\(pick),asetnsamples=n=48000:p=0[ch0];"
                + "[0:2]astats@vsabcs2\(peak),anullsink",
            "-map", "[p0]", "-map", "[timeline]", "-map", "[ch0]",
            "-c:v", "rawvideo", "-fps_mode", "passthrough", "-enc_time_base:v", "demux",
            "-c:a", "pcm_s16le", "-f", "framehash", "-hash", "sha256", "-"
        ])
        #expect(plan.roles == [.picture(input: 0), .timeline, .channel(0)])
        // Nothing that resamples, rescales, re-times, drops a frame or writes a file.
        for forbidden in ["-ar", "-af", "-y", "-ac", "-sample_fmt", "-pix_fmt", "-vf", "-s", "-vsync", "-async", "-ss", "-t"] {
            #expect(!args.contains(forbidden), "\(forbidden)")
        }
        let input = try #require(args.firstIndex(of: "-i"))
        for option in ["-xerror", "-err_detect", "-noauto_conversion_filters", "-copyts"] {
            #expect(try #require(args.firstIndex(of: option)) < input, "\(option) must apply to the read")
        }
        // The channels are picked with channelmap, never with the filter the job rendered with.
        #expect(!args.joined(separator: " ").contains("pan="))

        // The copy: both channels hashed, left first (the parse depends on the order), nothing measured.
        let copy = Proof.DecodePlan(pictures: [Proof.DecodePlan.Picture(index: 0, pixelFormat: "yuv411p")], soundIndex: 1,
                                    sampleFormat: "s32", sampleRateHz: 44_100, channels: [0, 1])
        let filter = Proof.decodeFilter(copy)
        #expect(filter == "[0:0]format=pix_fmts=yuv411p[p0];[0:1]aformat=sample_fmts=s32:sample_rates=44100,asplit=3[t][c0][c1];"
                + "[t]aresample=osf=s32p,channelmap=map=0:channel_layout=mono,aresample=osf=s32[timeline];"
                + "[c0]aresample=osf=s32p,channelmap=map=0:channel_layout=mono,aresample=osf=s32,asetnsamples=n=44100:p=0[ch0];"
                + "[c1]aresample=osf=s32p,channelmap=map=1:channel_layout=mono,aresample=osf=s32,asetnsamples=n=44100:p=0[ch1]")
        #expect(!filter.contains("astats"))
        #expect(copy.roles == [.picture(input: 0), .timeline, .channel(0), .channel(1)])
        // A sound-only file asks for no picture options; two pictures are both played.
        let wav = Proof.decodeArgs(input: "/in/a.wav", inputArgs: [],
                                   plan: Proof.DecodePlan(pictures: [], soundIndex: 0, sampleFormat: "s16",
                                                          sampleRateHz: 48_000, channels: [0, 1]), hashCodec: "pcm_s16le")
        #expect(!wav.contains("rawvideo") && !wav.contains("-fps_mode") && wav.last == "-")
        let two = Proof.DecodePlan(pictures: [.init(index: 0, pixelFormat: "a"), .init(index: 3, pixelFormat: "b")],
                                   soundIndex: 1, sampleFormat: "fltp", sampleRateHz: 48_000, channels: [0])
        #expect(Proof.decodeFilter(two).hasPrefix("[0:0]format=pix_fmts=a[p0];[0:3]format=pix_fmts=b[p3];"
                                                  + "[0:1]aformat=sample_fmts=fltp:sample_rates=48000,asplit=2"))
        #expect(Proof.decodeFilter(two).contains("aresample=osf=fltp,channelmap=map=0:channel_layout=mono,aresample=osf=flt"))
        #expect(two.roles == [.picture(input: 0), .picture(input: 3), .timeline, .channel(0)])

        // The deadline follows the file's size, or twice its length when that is more.
        var long = Proof.FileLayout(carried: [Self.video()], sound: [Self.sound()])
        #expect(Proof.decodeDeadlineSeconds(bytes: 1 << 20, layout: long) == AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: 1 << 20))
        long.carried[0].statedSeconds = 14_400
        #expect(Proof.decodeDeadlineSeconds(bytes: 1 << 20, layout: long) == 28_800)
    }

    // MARK: Scale

    @Test("SCALE: 100,000 decisions and log lines, across all three shapes, inside 10 s", .timeLimit(.minutes(1)))
    func hundredThousandDecisions() {
        let cases = [Self.goodFacts(), Self.poisoned { $0.balancedRead?.channelSHA256[1] = Self.otherHash }, Self.dvFacts(),
                     Self.facts { $0.original.tags = ["a": "1", "b": "2"]; $0.original.carried.append(Self.timecode(2)) }]
        let clock = ContinuousClock()
        var proven = 0, same = 0, characters = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 {
                let outcome = Proof.decide(cases[i % 4])
                if outcome.isProven { proven += 1 }
                if outcome.playsTheSame { same += 1 }
                characters += Proof.logLine(original: "/a/\(i).mov", balanced: "/a/\(i)_balanced.mov", outcome: outcome).count
            }
        }
        #expect(proven == 25_000 && same == 75_000)
        #expect(characters > 0)
        #expect(elapsed < .seconds(10), "100k decisions took \(elapsed)")
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
        #expect(code.components(separatedBy: "ProcessRunner.runProcess(").count == 4,
                "the header reads, the packet pass, the decode pass")
        // Both whole-file passes are consumed line by line: nothing of them is collected.
        #expect(code.components(separatedBy: "stdoutLine: { ledger.note($0) }, stdoutLimitBytes: 0").count == 3)
        #expect(code.contains("ToolLocator.ffmpegPath") && code.contains("ToolLocator.ffprobePath"))
        // ffmpeg is asked for frame hashes on stdout only: no overwrite flag, no output path.
        #expect(!code.contains("\"-y\""))
        #expect(code.contains("\"-f\", \"framehash\", \"-hash\", \"sha256\", \"-\""))
        // The decode pass may not be softened: read and decode errors stay fatal, no
        // conversion may be inserted, no frame dropped or re-timed.
        #expect(code.contains("\"-xerror\"") && code.contains("\"-err_detect\", \"explode\""))
        #expect(code.contains("\"-noauto_conversion_filters\", \"-copyts\""))
        #expect(code.contains("\"-fps_mode\", \"passthrough\", \"-enc_time_base:v\", \"demux\""))
        // The last thing before a verdict is the cancellation check.
        let stamped = try #require(code.range(of: "tools.afterFinalStamps?()"))
        let verdict = try #require(code.range(of: "switch decide(facts)"))
        let check = try #require(code.range(of: "try Task.checkCancellation()", range: stamped.upperBound..<code.endIndex))
        #expect(check.lowerBound < verdict.lowerBound, "cancellation is checked after the closing stamps, before the verdict")
    }
}
