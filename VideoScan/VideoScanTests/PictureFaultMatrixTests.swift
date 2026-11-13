// PictureFaultMatrixTests.swift
// The picture fault matrix — the sibling of SoundFaultMatrixTests (2026-11-12).
// TEST-ONLY: it pins what the production picture checks do TODAY, including
// what they miss. It changes no production code.
//
// Each row is one way a file's picture can be wrong; each column is a
// container from the media matrix. Every cell is a generated file (testsrc2
// and tones — no family media) taken through the PRODUCTION checks:
//
//   * Check Media's quick tier — CheckMediaProbe.quick → CheckMediaRules
//     .quickChecks;
//   * Check Media's full tier — CheckMediaProbe.full (Verify Video's decode,
//     VerifyVideoProbe.diagnose, with the signal filters riding along, and
//     the packet census) → CheckMediaRules.fullChecks, merged onto the quick
//     rows exactly as the job does (CheckMediaRules.merging).
//
// and lands in exactly one class:
//
//   unopenable — ffprobe cannot open it: the card is one Problem row
//                ("It can't be opened: …"), every other row not run;
//   flagged    — the named picture row is a Warning or a Problem;
//   notChecked — no picture row has a verdict; each reads "Not checked — …"
//                with its reason (a file with no picture). Said, not flagged;
//   missed     — every picture row that ran reads OK. A KNOWN GAP, pinned
//                here so that closing it has to change this table.
//
// There is NO "refused" class. Promote has a sound gate (PromoteSoundGate)
// and no picture gate: PromoteToArchiveJob+Guards runs the date refusals, the
// duplicate claim, the digest proof and the sound gate, and nothing there
// reads a picture verdict. So every cell below still promotes as far as its
// PICTURE is concerned (a byte-damaged file may be refused for its sound —
// that is the sound matrix's claim, not this one's).
//
// The table below IS the claim. `theTableAddsUp` pins the totals.
//
// Not in the table, because the outcome depends on where an encoder happens
// to put its bytes: random overwrites, scattered bit flips, a cut inside the
// last 1 %. Only "cut at 60 %" and "10 % zeroed mid-file" are kept, as in the
// sound matrix.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias R = CheckMediaRules

enum PictureFaultMatrix {

    enum Container: String, CaseIterable, Sendable {
        case mov, mp4, mkv, mxf, avi

        var videoCodec: String {
            switch self {
            case .mov: return "prores"
            case .mp4: return "libx264"
            case .mkv: return "ffv1"
            case .mxf: return "mpeg2video"
            case .avi: return "mpeg4"
            }
        }
        var videoArgs: [String] {
            switch self {
            case .mov: return []
            case .mp4: return ["-preset", "ultrafast", "-pix_fmt", "yuv420p"]
            case .mkv: return []
            // 720×576 is a tape-era frame: without the 4:3 flag the healthy
            // file is (rightly) warned as square-pixel SD.
            case .mxf: return ["-g", "15", "-b:v", "2M", "-aspect", "4:3"]
            case .avi: return []
            }
        }
        var audioCodec: String { self == .mp4 ? "aac" : "pcm_s16le" }
        var size: String { self == .mxf ? "720x576" : "320x240" }
    }

    /// What the production checks did with one file.
    enum Outcome: Sendable, Equatable, CustomStringConvertible {
        case clean
        case unopenable
        case flagged(MediaCheckKind)
        case notChecked
        case missed

        var description: String {
            switch self {
            case .clean: return "clean"
            case .unopenable: return "unopenable"
            case .flagged(let k): return "flagged(\(k.rawValue))"
            case .notChecked: return "notChecked"
            case .missed: return "MISSED"
            }
        }
    }

    enum Damage: Sendable { case none, cutAt60Percent, zerosTenPercentMid }

    struct Fault: Sendable, CustomTestStringConvertible {
        let name: String
        /// lavfi graph for the picture (`{S}` = the container's frame size);
        /// nil = no picture track at all.
        let graph: String?
        /// Encoder / muxer arguments added after the container's own.
        var args: [String] = []
        var audioSeconds: Double = PictureFaultMatrix.seconds
        var damage: Damage = .none
        /// The expected outcome everywhere…
        let expect: Outcome
        /// …except in these containers.
        var except: [Container: Outcome] = [:]
        /// Containers ffmpeg cannot write this fault into.
        var skip: Set<Container> = []

        var testDescription: String { name }
        func expected(in c: Container) -> Outcome { except[c] ?? expect }
    }

    static let seconds: Double = 30
    /// Moving content, so black / freeze / repeat detection has a real
    /// picture to compare against. Softened (gblur): raw testsrc2 has
    /// one-pixel lines that ffmpeg's idet reads as combing, and the healthy
    /// file then carried "Labelled progressive, but the picture is
    /// interlaced" in every container that has a label (measured 2026-11-12:
    /// 692 of 750 frames judged interlaced raw, 0 of 750 softened).
    static func moving(_ d: Double = seconds, rate: String = "25") -> String {
        "testsrc2=duration=\(d):size={S}:rate=\(rate),gblur=sigma=2"
    }
    /// The whole frame painted black while `condition` holds (commas escaped for lavfi).
    static func blackWhile(_ condition: String) -> String {
        "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable="
            + condition.replacingOccurrences(of: ",", with: "\\,")
    }
    /// `still` s of moving picture, the last frame held for `held` s, then moving again.
    static func frozenMidFile(after still: Double, held: Double) -> String {
        "\(moving(still)),tpad=stop_mode=clone:stop_duration=\(held)[a];\(moving(seconds - still - held))[b];"
            + "[a][b]concat=n=2:v=1:a=0"
    }

    static let healthy = Fault(name: "healthy", graph: moving(), expect: .clean)

    static let faults: [Fault] = [
        // Said, not flagged: every picture row reads "Not checked — this file has no picture".
        Fault(name: "no picture track", graph: nil, expect: .notChecked,
              skip: [.mxf]),                                    // ffmpeg's MXF writer writes nothing without a picture

        // Black.
        Fault(name: "black all through", graph: "color=c=black:size={S}:rate=25:duration=\(seconds)",
              expect: .flagged(.black)),
        Fault(name: "black from 12 s to the end (60 %)", graph: "\(moving()),\(blackWhile("gte(t,12)"))",
              expect: .flagged(.black)),
        // KNOWN GAP: the rule warns at 50 % and blackdetect ends a stretch at the
        // last black frame's START, so exactly half reads 14.96 s of 30 s = 49.9 %
        // ("1 short black stretch — normal between scenes"). One frame under.
        Fault(name: "black for the second half", graph: "\(moving()),\(blackWhile("gte(t,15)"))", expect: .missed),
        // KNOWN GAP: under the 50 % rule, by design — 12 s of black reads
        // "1 short black stretch — normal between scenes".
        Fault(name: "black for 12 s mid-file", graph: "\(moving()),\(blackWhile("between(t,9,21)"))", expect: .missed),

        // Frozen.
        Fault(name: "frozen for 18 s mid-file (60 %)", graph: frozenMidFile(after: 6, held: 18),
              expect: .flagged(.freeze),
              // KNOWN GAP: x264's copy of the held picture keeps changing a little
              // until its next keyframe (at 10 s), so freezedetect counts 14 s of
              // the 18 s = 47 % ("1 short frozen stretch — normal between scenes").
              except: [.mp4: .missed]),
        // KNOWN GAP: freezedetect prints a stretch's length only when the picture
        // moves again; a freeze that lasts to the end of the file is never
        // counted ("No frozen stretches."). True for any length of freeze.
        Fault(name: "frozen picture for the second half",
              graph: "\(moving(15)),tpad=stop_mode=clone:stop_duration=15", expect: .missed),
        // KNOWN GAP: under the 50 % rule, by design.
        Fault(name: "frozen for 12 s mid-file", graph: frozenMidFile(after: 9, held: 12), expect: .missed),

        // Lengths and bytes.
        Fault(name: "picture half as long as the sound", graph: moving(15), expect: .flagged(.avDuration),
              skip: [.mxf]),                                    // ffmpeg's MXF writer cuts the sound to match
        Fault(name: "file cut off at 60 % of its bytes", graph: moving(), damage: .cutAt60Percent,
              expect: .unopenable,                              // mov, mp4: the index at the end is gone
              except: [.mkv: .flagged(.decode),                 // "1 decode error (minor glitches)" — nothing says cut short
                       .mxf: .flagged(.decode),
                       // KNOWN GAP: every row OK — "The file is whole", "Every frame decoded
                       // cleanly", and the frame rate reads 41.67 (the header's 750 frames
                       // over the 18 s that are left).
                       .avi: .missed]),
        Fault(name: "10 % of the file's bytes zeroed, mid-file", graph: moving(), damage: .zerosTenPercentMid,
              expect: .flagged(.decode),
              except: [.mkv: .flagged(.packetTiming),           // a 3 s hole in the packets
                       .mxf: .flagged(.packetTiming),
                       // KNOWN GAP: every row OK. 76 of the 750 frames are gone (674 packets,
                       // 674 frames decode, no error line); AVI packets carry no timestamps of
                       // their own, so the rest close up and nothing counts them against the header.
                       .avi: .missed]),

        // Shape.
        // KNOWN GAP: a display shape between 0.4 and 4 is taken as meant; only the
        // tape-era 720-wide frame is checked for square pixels (so mxf is caught).
        Fault(name: "wrong shape flag (1:1 on a 4:3 picture)", graph: moving(), args: ["-aspect", "1:1"],
              expect: .missed, except: [.mxf: .flagged(.aspect)]),
        Fault(name: "absurd shape flag (5:1)", graph: moving(), args: ["-aspect", "5:1"], expect: .flagged(.aspect),
              skip: [.mxf]),                                    // MPEG-2 can only say 1:1, 4:3, 16:9 or 2.21:1

        // Frames and timing.
        Fault(name: "every frame stored five times (5 fps upsampled to 25)",
              graph: "\(moving(seconds, rate: "5")),fps=25", expect: .flagged(.distinctFrames)),
        Fault(name: "one keyframe in 600 frames (24 s apart)", graph: moving(), args: ["-g", "600"],
              expect: .flagged(.keyframes),
              skip: [.mov, .mkv,                                // prores and ffv1: every frame is a keyframe
                     .mxf]),                                    // ffmpeg's MXF index cannot hold a GOP that long
        Fault(name: "timestamps jump 5 s mid-file", graph: "\(moving()),setpts=PTS+gte(T\\,15)*5/TB",
              args: ["-fps_mode", "passthrough"], audioSeconds: 35, expect: .flagged(.timestamps),
              skip: [.mxf,                                      // constant frame rate only: the jump is not written
                     .avi]),                                    // the AVI writer fills the hole with repeated frames

        // Interlacing.
        Fault(name: "interlaced picture labelled progressive",
              graph: "\(moving(seconds, rate: "50")),interlace,setfield=prog", expect: .flagged(.interlace),
              skip: [.avi]),                                    // AVI carries no field-order label to be wrong
        Fault(name: "progressive picture labelled interlaced", graph: "\(moving()),setfield=tff",
              args: ["-flags", "+ilme+ildct"], expect: .flagged(.interlace), skip: [.avi]),

        // Bits.
        // KNOWN GAP: the size row only asks "too big for the picture?"; nothing
        // asks "too small to be watchable?".
        Fault(name: "starved of bits (20 kbit/s asked)", graph: moving(), args: ["-b:v", "20k"], expect: .missed,
              skip: [.mov, .mkv]),                              // prores and ffv1 take no bitrate
        Fault(name: "far too many bits for the picture", graph: "\(moving()),noise=alls=100:allf=t",
              args: ["-q:v", "1", "-qp", "0"], expect: .flagged(.bitrate),
              skip: [.mov, .mkv]),                              // their bands (15 and 64 bits a pixel) are out of a real picture's reach
    ]

    /// The Check Media rows that are about the picture (the lengths row is
    /// about both, and is the one that can see a picture that stops early).
    static let pictureKinds: [MediaCheckKind] = [
        .bitrate, .frameRate, .timestamps, .avDuration, .aspect, .truncation, .distinctFrames,
        .decode, .black, .freeze, .interlace, .packetTiming, .keyframes, .dataRate, .sync, .timecode, .colour,
    ]

    static func generate(_ fault: Fault, _ c: Container, into dir: URL) throws -> String {
        let out = dir.appendingPathComponent("test_pfm_\(UUID().uuidString.prefix(6)).\(c.rawValue)").path
        let sound = ["-f", "lavfi", "-i",
                     "aevalsrc=\(SoundFaultMatrix.left)|\(SoundFaultMatrix.right):s=48000:d=\(fault.audioSeconds)"]
        var args: [String]
        if let graph = fault.graph {
            args = ["-f", "lavfi", "-i", graph.replacingOccurrences(of: "{S}", with: c.size)] + sound
            args += ["-map", "0:v:0", "-map", "1:a:0", "-c:v", c.videoCodec] + c.videoArgs + fault.args
            args += ["-c:a", c.audioCodec]
        } else {
            args = sound + ["-c:a", c.audioCodec]
        }
        try CleanupTestMedia.runFFmpeg(args, output: out)
        try damage(out, fault.damage)
        return out
    }

    private static func damage(_ path: String, _ damage: Damage) throws {
        guard damage != .none else { return }
        let size = ((try FileManager.default.attributesOfItem(atPath: path))[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        switch damage {
        case .none: break
        case .cutAt60Percent:
            try handle.truncate(atOffset: size * 6 / 10)
        case .zerosTenPercentMid:
            try handle.seek(toOffset: size * 45 / 100)
            try handle.write(contentsOf: Data(count: Int(size / 10)))
        }
    }

    /// One file through Check Media's quick and full tiers; the picture rows only.
    static func outcome(path: String) async throws -> (Outcome, detail: String) {
        let quick: CheckMediaQuickInputs
        switch try await CheckMediaProbe.quick(path: path) {
        case .unopenable(let detail, _): return (.unopenable, detail)
        case .measured(let q): quick = q
        }
        let full = try await CheckMediaProbe.full(path: path, facts: quick.facts)
        let rows = R.merging(R.quickChecks(quick), with: R.fullChecks(full, facts: quick.facts))
            .filter { pictureKinds.contains($0.kind) }
        func words(_ rows: [MediaCheck]) -> String {
            rows.map { "\($0.kind.rawValue): \($0.sentence)" }.joined(separator: " | ")
        }
        // Every row that spoke is in `detail`; a cell is pinned to ONE of them by name.
        let loud = rows.filter { $0.verdict.rank >= MediaCheckVerdict.warning.rank }
        if let first = loud.first { return (.flagged(first.kind), words(loud)) }
        let noPicture = rows.first { $0.kind == .decode }?.verdict == .notRun(reason: R.noPicture)
        return (noPicture ? .notChecked : .missed, words(rows))
    }
}

@Suite("Picture fault matrix — what the picture checks catch, and what they do not", .serialized)
struct PictureFaultMatrixTests {
    typealias M = PictureFaultMatrix

    @Test("CONTROL: a healthy file has no picture row saying anything, in every container",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func healthy() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("pfm")
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in M.Container.allCases {
            let (outcome, detail) = try await M.outcome(path: try M.generate(M.healthy, c, into: dir))
            #expect(outcome == .missed, "\(c.rawValue): a healthy file read \(outcome) — \(detail)")
        }
    }

    @Test("each fault lands in its pinned class in each container",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)), arguments: M.faults)
    func fault(_ fault: M.Fault) async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("pfm")
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in M.Container.allCases where !fault.skip.contains(c) {
            let path = try M.generate(fault, c, into: dir)
            let (outcome, detail) = try await M.outcome(path: path)
            let want = fault.expected(in: c)
            switch (want, outcome) {
            case (.flagged(let kind), .flagged):
                // The named row must be among the ones that spoke.
                #expect(detail.contains("\(kind.rawValue): "), "\(fault.name) / \(c.rawValue): wanted \(kind.rawValue), got \(detail)")
            default:
                #expect(outcome == want, "\(fault.name) / \(c.rawValue): wanted \(want), got \(outcome) — \(detail)")
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test("the table adds up: the totals are the table's own")
    func theTableAddsUp() {
        var unopenable = 0, flagged = 0, notChecked = 0, missed = 0
        for fault in M.faults {
            for c in M.Container.allCases where !fault.skip.contains(c) {
                switch fault.expected(in: c) {
                case .unopenable: unopenable += 1
                case .flagged: flagged += 1
                case .notChecked: notChecked += 1
                case .missed: missed += 1
                case .clean: Issue.record("a fault row expects 'clean': \(fault.name)")
                }
            }
        }
        #expect(M.faults.count == 20)
        #expect(unopenable + flagged + notChecked + missed == 86)
        #expect(unopenable == 2, "cannot be opened — one Problem row: \(unopenable)")
        #expect(flagged == 50, "a picture row is a Warning or a Problem: \(flagged)")
        #expect(notChecked == 4, "no picture — every picture row says not checked: \(notChecked)")
        #expect(missed == 30, "KNOWN GAPS — every picture row reads OK: \(missed)")
    }
}
