// BalancedCopyProofTotalityTests.swift
// GH #483 item 3 (Codex #310, P2): "`decide` can trap on absurd integers
// (abs(Int64.min), sample-count overflow) instead of returning an outcome."
//
// Swift integer arithmetic TRAPS on overflow (≈ C++ compiled with
// -ftrapv: the process dies), and `Int(aDouble)` traps when the value does
// not fit. A proof that crashes the app on one hostile or damaged file is
// not "total". Every case below is a number no healthy file has, in a place
// a file's own header or ffmpeg's own output puts numbers:
//   - a sound timeline whose runs sum past Int64.max;
//   - sound placed at Int64.min (ffmpeg prints an unset timestamp that way);
//   - frame counts that sum past Int.max in a "did not all arrive" sentence;
//   - a stated or stored length too long to be written as h:mm:ss;
//   - a length that is not a number (never agreement);
//   - framehash lines whose time plus duration does not fit in 64 bits.
// The contract: an outcome every time, and never "the same".
//
// RED before the fix = the test process dies (xcodebuild reports the crash
// in the first trapping test); the NaN cases were red as wrong answers.

import Foundation
import Testing
@testable import VideoScan

@Suite("Balanced copy proof — total over absurd numbers (GH #483 item 3)")
struct BalancedCopyProofTotalityTests {

    typealias Proof = BalancedCopyProof
    typealias Table = BalancedCopyProofDecisionTests

    private func refuses(_ name: String, _ change: (inout Proof.Facts) -> Void) {
        let outcome = Proof.decide(Table.poisoned(change))
        #expect(!outcome.playsTheSame, "\(name) must not play the same: \(outcome)")
        // The log line is part of the answer: it must be writable too.
        #expect(!Proof.logLine(original: "/a", balanced: "/b", outcome: outcome).isEmpty)
    }

    @Test("TOTAL: a sound timeline whose runs sum past Int64.max is an outcome, never a trap, never the same")
    func timelineSumOverflow() {
        let huge = [Proof.SoundSegment(start: 0, samples: .max), Proof.SoundSegment(start: 5, samples: .max)]
        #expect(Proof.ReadReport(soundSegments: huge).soundSamples == nil, "a sum that does not fit is no count")
        #expect(Proof.ReadReport(soundSegments: [Proof.SoundSegment(start: 0, samples: 7)]).soundSamples == 7)
        refuses("original timeline overflows") { $0.originalRead?.soundSegments = huge }
        refuses("copy timeline overflows") { $0.balancedRead?.soundSegments = huge }
        refuses("both timelines overflow") {
            $0.originalRead?.soundSegments = huge
            $0.balancedRead?.soundSegments = huge
        }
        refuses("negative run") { $0.balancedRead?.soundSegments = [Proof.SoundSegment(start: 0, samples: -96_000)] }
        // A sample rate of zero divides nothing: no samples, whether or not a length is stated.
        var unrated = Table.sound(rate: 0)
        unrated.statedSeconds = nil
        let good = Table.goodFacts()
        #expect(Proof.readShortfall(good.balanced, read: good.balancedRead, kept: unrated) == .noSoundSamples)
        #expect(Proof.readShortfall(good.balanced, read: good.balancedRead, kept: good.balanced.sound[0]) == nil)
    }

    @Test("TOTAL: sound placed at Int64.min or Int64.max is compared without a trap — and a real difference is still a difference")
    func placementAtTheEdgesOfInt64() {
        func at(_ start: Int64) -> [Proof.SoundSegment] { [Proof.SoundSegment(start: start, samples: 96_000)] }
        refuses("copy at Int64.min") { $0.balancedRead?.soundSegments = at(.min) }
        refuses("copy at Int64.max") { $0.balancedRead?.soundSegments = at(.max) }
        refuses("original at Int64.min") { $0.originalRead?.soundSegments = at(.min) }
        refuses("opposite ends") {
            $0.originalRead?.soundSegments = at(.min)
            $0.balancedRead?.soundSegments = at(.max)
        }
        // Both at the same absurd place: equal placement is equal placement; the answer is an outcome.
        let same = Proof.decide(Table.poisoned {
            $0.originalRead?.soundSegments = at(.min)
            $0.balancedRead?.soundSegments = at(.min)
        })
        #expect(!Proof.logLine(original: "/a", balanced: "/b", outcome: same).isEmpty)
        // The one-sample tolerance is unchanged at ordinary values.
        func copyAt(_ start: Int64) -> Proof.Outcome {
            Proof.decide(Table.poisoned { $0.balancedRead?.soundSegments = at(start) })
        }
        #expect(copyAt(1).isProven && copyAt(-1).isProven)
        #expect(!copyAt(2).playsTheSame && !copyAt(-2).playsTheSame)
    }

    @Test("TOTAL: frame counts that sum past Int.max are written into the sentence saturated, not trapped on")
    func frameCountSumOverflow() {
        let outcome = Proof.decide(Table.poisoned {
            $0.balancedRead?.muxed = [0: .max, 1: .max, 2: 2, 3: 2]
        })
        #expect(outcome == .couldNotCheck("the balanced copy's decoded frames did not all arrive (ffmpeg wrote \(Int.max), 148 were read)"))
        refuses("folded overflows") { $0.originalRead?.folded = [0: .max, 1: .max] }
    }

    @Test("TOTAL: a length too long for h:mm:ss, or not a number, is written plainly — and a length that is not a number is never agreement")
    func absurdLengths() {
        #expect(Proof.length(1e300) == "more than 31 million years")
        #expect(Proof.length(Double.greatestFiniteMagnitude) == "more than 31 million years")
        #expect(Proof.length(.infinity) == "inf s" && Proof.length(-.infinity) == "-inf s")
        #expect(Proof.length(.nan) == "nan s")
        #expect(Proof.length(-1e300).hasSuffix(" s"))
        #expect(Proof.length(514) == "8:34" && Proof.length(3723) == "1:02:03" && Proof.length(1.9686) == "1.969 s")
        for absurd in [1e300, Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan, -1e300] {
            refuses("copy picture states \(absurd)") { $0.balanced.carried[0].statedSeconds = absurd }
            refuses("original picture states \(absurd)") { $0.original.carried[0].statedSeconds = absurd }
            refuses("copy sound states \(absurd)") { $0.balanced.sound[0].statedSeconds = absurd }
            refuses("original sound states \(absurd)") { $0.original.sound[0].statedSeconds = absurd }
            refuses("copy picture played to \(absurd)") { $0.balancedRead?.pictures[0]?.endSeconds = absurd }
            refuses("original picture played from \(absurd)") { $0.originalRead?.pictures[0]?.firstSeconds = absurd }
            // A STORED length is named, never compared: the pair still plays the same, and the sentence is writable.
            let stored = Proof.decide(Table.poisoned { $0.balanced.sound[0].storedSeconds = absurd })
            #expect(!Proof.logLine(original: "/a", balanced: "/b", outcome: stored).isEmpty, "\(absurd)")
            #expect(!stored.isProven || !(absurd > 2), "a stored length of \(absurd) beyond what plays must be named")
        }
        // The slack itself: a time base that is not a number never widens it into agreement.
        refuses("copy picture time base absurd and length off") {
            $0.balanced.carried[0].timeBase = "nan/1"
            $0.balancedRead?.pictures[0]?.endSeconds = 3
        }
    }

    // MARK: The typed evidence behind the sentences

    @Test("EVIDENCE: displayDifferences lists EVERY display field the copy states differently; readShortfall names the rule with its numbers; both are what the sentences are made from")
    func evidenceIsTypedAndComplete() {
        var copy = Table.picture()
        #expect(Table.picture().displayDifferences(from: copy).isEmpty && Table.picture().displayDifference(from: copy) == nil)
        copy.fieldOrder = "tt"
        copy.colorSpace = "smpte170m"
        copy.sideData = "[{}]"
        copy.extradataSHA256 = "SHA256:ab"          // the decoder's, not a display field
        let all = Table.picture().displayDifferences(from: copy)
        #expect(all.map(\.name) == ["field order", "colour space", "side data"])
        #expect(all[0] == Proof.PictureConfiguration.FieldDifference(name: "field order", original: "progressive", copy: "tt"))
        #expect(all[1].original.isEmpty && all[1].copy == "smpte170m")
        #expect(Table.picture().displayDifference(from: copy) == "field order progressive → tt")

        let good = Table.goodFacts()
        let kept = good.balanced.sound[0]
        func shortfall(_ change: (inout Proof.ReadReport) -> Void) -> Proof.ReadShortfall? {
            var read = good.balancedRead ?? Proof.ReadReport()
            change(&read)
            return Proof.readShortfall(good.balanced, read: read, kept: kept)
        }
        #expect(shortfall { _ in } == nil)
        #expect(Proof.readShortfall(good.balanced, read: nil, kept: kept) == .noAccount)
        #expect(shortfall { $0.streams[1]?.packets = 47 } == .packetCount(stream: 1, read: 47, listed: 94))
        #expect(shortfall { $0.streams[0] = nil } == .packetsNotCounted(stream: 0))
        #expect(shortfall { $0.streams[1]?.decodeErrors = 2 } == .decodeErrors(stream: 1))
        #expect(shortfall { $0.folded[0] = 49 } == .framesNotAllFolded(muxed: 148, folded: 147))
        #expect(shortfall { $0.pictures[0] = nil } == .noPictureFrames(stream: 0))
        #expect(shortfall { $0.pictures[0]?.endSeconds = 1 } == .pictureLength(stream: 0, decodedSeconds: 1, statedSeconds: 2))
        #expect(shortfall { $0.soundSegments = [] } == .noSoundSamples)
        #expect(shortfall { $0.soundSegments = [Proof.SoundSegment(start: 0, samples: 95_000)] }
                == .soundLength(decodedSamples: 95_000, statedSeconds: 2))
        // The sentence IS the verdict's, word for word.
        let short = Proof.ReadShortfall.soundLength(decodedSamples: 78_610_936, statedSeconds: 1637.7065)
        #expect(short.sentence(called: "the balanced copy")
                == "the balanced copy was not read to the end (78610936 sound samples decoded, 27:18 stated)")
        #expect(Proof.decide(Table.poisoned { $0.balancedRead?.streams[1]?.packets = 47 })
                == .couldNotCheck(Proof.ReadShortfall.packetCount(stream: 1, read: 47, listed: 94).sentence(called: "the balanced copy")))
    }

    // MARK: The decode pass's fold (the numbers come from ffmpeg's own output)

    private static let h = String(repeating: "ab", count: 32)
    private func fold(_ lines: [String]) -> Proof.FrameLedger {
        let ledger = Proof.FrameLedger(roles: [.picture(input: 0), .timeline, .channel(0)], sampleRateHz: 48_000)
        (["#tb 0: 1/30000", "#dimensions 0: 720x480", "#sar 0: 8/9", "#tb 1: 1/48000", "#tb 2: 1/48000"] + lines).forEach(ledger.note)
        return ledger
    }
    private func line(_ stream: Int, _ pts: Int64, _ duration: Int64, _ size: Int = 4096) -> String {
        "\(stream), \(pts), \(pts), \(duration), \(size), \(Self.h)"
    }

    @Test("TOTAL: framehash lines whose time plus duration does not fit in 64 bits end the pass as a fault — the fold never traps")
    func frameLedgerNeverTraps() {
        // Picture: pts + duration past Int64.max.
        #expect(fold([line(0, .max, 1001)]).fault != nil)
        #expect(fold([line(0, .max - 1000, 1001)]).fault != nil)
        // Timeline: the run's end past Int64.max; a timestamp at Int64.min (ffmpeg's "no timestamp") after a run.
        #expect(fold([line(1, .max - 10, 1024), line(1, 0, 1024)]).fault != nil)
        // A run that starts at Int64.min after another is a second run, a place like any other: no trap, no fault.
        let backwards = fold([line(1, 0, 1024), line(1, .min, 1024)])
        #expect(backwards.fault == nil)
        #expect(backwards.played.soundSegments == [Proof.SoundSegment(start: 0, samples: 1024), Proof.SoundSegment(start: .min, samples: 1024)])
        #expect(fold([line(1, .max - 2000, 1024), line(1, .max - 976, 1024)]).fault != nil)
        #expect(fold([line(1, 0, .max), line(1, .max, .max)]).fault != nil)
        // A hashed channel whose sample count does not fit.
        #expect(fold([line(2, 0, .max), line(2, 0, .max)]).fault != nil)
        // A fault is kept, and what was folded before it can still be read without a trap.
        let faulted = fold([line(1, 0, 1024), line(1, .max - 10, 1024)])
        #expect(faulted.fault != nil)
        #expect(faulted.played.soundSegments == [Proof.SoundSegment(start: 0, samples: 1024)])
        // Ordinary lines are folded exactly as before.
        let good = fold([line(0, 0, 1001), line(1, 0, 1024), line(1, 1024, 1024), line(1, 4096, 1024), line(2, 0, 48_000)])
        #expect(good.fault == nil)
        #expect(good.played.soundSegments == [Proof.SoundSegment(start: 0, samples: 2048), Proof.SoundSegment(start: 4096, samples: 1024)])
        #expect(good.played.channelSamples == [48_000] && good.played.pictures[0]?.frames == 1)
        // A timestamp at Int64.min as the FIRST line is a place like any other; the next line is judged against it.
        #expect(fold([line(1, .min, 1024)]).fault == nil)
    }

    @Test("TOTAL: fraction() — the reduced time of a packet — returns nil rather than trap at the edges")
    func fractionEdges() {
        #expect(Proof.fraction(ticks: .min, numerator: 1, denominator: 30_000) == nil)
        #expect(Proof.fraction(ticks: .max, numerator: 1001, denominator: 30_000) == nil)
        #expect(Proof.fraction(ticks: .min, numerator: -1, denominator: 30_000) == nil)
        #expect(Proof.fraction(ticks: 2002, numerator: 1, denominator: 60_000) == "1001/30000")
        #expect(Proof.fraction(ticks: 0, numerator: 1001, denominator: 30_000) == "0/1")
    }
}
