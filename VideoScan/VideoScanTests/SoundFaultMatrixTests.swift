// SoundFaultMatrixTests.swift
// The sound fault matrix (Rick 2026-11-12: "create a matrix with test cases to
// demonstrate all the reasonable cases ... backed up by evidence and testing").
//
// Each row is one way a file's sound can be wrong; each column is a container
// from the media matrix. Every cell is a generated file (tones — no family
// media) taken through the PRODUCTION checks:
//
//   * Promote's sound gate — VerifyAudioProbe.diagnose → PromoteSoundGate
//     .finding → .decide, with no owner tag and no tick;
//   * Check Media's sound rows — lengths (quick tier), Sound, Sound
//     continuity, and the four level rows.
//
// and lands in exactly one class:
//
//   refused  — Promote will not archive it (the code is pinned);
//   flagged  — it promotes, and the named Check Media row is a Warning or a
//              Problem (or the promoted row carries a note);
//   missed   — it promotes and no sound row says anything. A KNOWN GAP,
//              pinned here so that closing it has to change this table.
//
// The table below IS the claim. `theTableAddsUp` pins the totals quoted in
// docs/STATUS.md, so the documented number cannot drift from the tested one.
//
// Not in the table, because the outcome depends on where an encoder happens
// to put its bytes: random overwrites, scattered bit flips, a cut inside the
// last 1 %. They were measured once (2026-11-12, .scratch) and are described
// in STATUS.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias G = PromoteSoundGate
private typealias R = CheckMediaRules

enum SoundFaultMatrix {

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
            case .mxf: return ["-g", "15", "-b:v", "2M"]
            case .avi: return []
            }
        }
        var audioCodec: String { self == .mp4 ? "aac" : "pcm_s16le" }
        var size: String { self == .mxf ? "720x576" : "320x240" }
    }

    /// What the production checks did with one file.
    enum Outcome: Sendable, Equatable, CustomStringConvertible {
        case clean
        case refused(PromoteSoundGate.Code)
        case flagged(MediaCheckKind)
        /// Promoted with a note on the row (one-sided sound).
        case noted
        case missed

        var description: String {
            switch self {
            case .clean: return "clean"
            case .refused(let c): return "refused(\(c.rawValue))"
            case .flagged(let k): return "flagged(\(k.rawValue))"
            case .noted: return "noted"
            case .missed: return "MISSED"
            }
        }
        var isCaught: Bool { self != .missed && self != .clean }
    }

    enum Damage: Sendable { case none, cutAt60Percent, zerosTenPercentMid }

    struct Fault: Sendable, CustomTestStringConvertible {
        let name: String
        /// aevalsrc expression; nil = no sound track at all.
        let expr: String?
        var audioSeconds: Double? = nil
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
    // Two different programme-like signals (a moving tone plus a higher one).
    static let left = "0.25*sin(2*PI*220*t)*(0.6+0.4*sin(2*PI*0.7*t))+0.1*sin(2*PI*1320*t)"
    static let right = "0.25*sin(2*PI*330*t)*(0.6+0.4*sin(2*PI*0.5*t))+0.1*sin(2*PI*990*t)"
    /// `x`, but zero while `condition` holds (commas escaped for lavfi).
    static func gated(_ x: String, _ condition: String) -> String {
        "if(\(condition.replacingOccurrences(of: ",", with: "\\,"))\\,0\\,\(x))"
    }

    static let healthy = Fault(name: "healthy", expr: "\(left)|\(right)", expect: .clean)

    static let faults: [Fault] = [
        // Refused at the Promote gate.
        Fault(name: "no sound track", expr: nil, expect: .refused(.noTrack)),
        Fault(name: "silent all through (digital zero)", expr: "0|0", expect: .refused(.silent)),
        Fault(name: "under the floor all through (-70 dBFS)",
              expr: "0.0003*sin(2*PI*220*t)|0.0003*sin(2*PI*330*t)", expect: .refused(.silent)),
        Fault(name: "file cut off at 60 % of its bytes", expr: "\(left)|\(right)", damage: .cutAt60Percent,
              expect: .refused(.unchecked)),
        Fault(name: "sound half as long as the picture", expr: "\(left)|\(right)", audioSeconds: seconds / 2,
              expect: .refused(.damaged),
              // Not refused: Matroska and AVI state the lengths another way, and only
              // Check Media reads that (the gate's rule is the owner's to widen).
              except: [.mkv: .flagged(.avDuration), .avi: .flagged(.avDuration)],
              skip: [.mxf]),                                    // ffmpeg's MXF writer cuts the picture to match
        Fault(name: "10 % of the file's bytes zeroed, mid-file", expr: "\(left)|\(right)", damage: .zerosTenPercentMid,
              expect: .refused(.unchecked),
              except: [.mov: .missed]),                         // KNOWN GAP: PCM zeros decode as 2–10 s of silence

        // Promoted, and Check Media says so.
        Fault(name: "left channel dead all through", expr: "0|\(right)", expect: .flagged(.sound)),
        Fault(name: "right channel dies halfway", expr: "\(left)|\(gated(right, "gte(t,15)"))",
              expect: .flagged(.soundContinuity)),
        Fault(name: "right channel out for 12 s mid-file", expr: "\(left)|\(gated(right, "between(t,9,21)"))",
              expect: .flagged(.soundContinuity)),
        Fault(name: "50 ms dropout on both channels",
              expr: "\(gated(left, "between(t,15,15.05)"))|\(gated(right, "between(t,15,15.05)"))",
              expect: .flagged(.soundContinuity)),
        Fault(name: "clipped", expr: "clip(8*(\(left))\\,-1\\,1)|clip(8*(\(right))\\,-1\\,1)", expect: .flagged(.sound)),
        Fault(name: "DC offset", expr: "0.3+0.5*(\(left))|0.3+0.5*(\(right))", expect: .flagged(.dcOffset)),
        Fault(name: "one channel inverted", expr: "\(left)|-1*(\(left))", expect: .flagged(.channels)),
        Fault(name: "very quiet programme (-50 dBFS)",
              expr: "0.003*sin(2*PI*220*t)|0.003*sin(2*PI*330*t)", expect: .flagged(.loudness)),
        Fault(name: "hiss only (-40 dBFS noise)", expr: "0.01*(2*random(0)-1)|0.01*(2*random(1)-1)",
              expect: .flagged(.loudness)),

        Fault(name: "both channels die halfway",
              expr: "\(gated(left, "gte(t,15)"))|\(gated(right, "gte(t,15)"))", expect: .flagged(.soundContinuity)),
        Fault(name: "both channels out for 12 s mid-file",
              expr: "\(gated(left, "between(t,9,21)"))|\(gated(right, "between(t,9,21)"))",
              expect: .flagged(.soundContinuity)),

        // KNOWN GAPS: promoted with no sound row saying anything.
        Fault(name: "mains hum only (60 Hz, -26 dBFS)", expr: "0.05*sin(2*PI*60*t)|0.05*sin(2*PI*60*t)", expect: .missed),
        Fault(name: "right channel out for 5 s (under the 10 s rule)",
              expr: "\(left)|\(gated(right, "between(t,9,14)"))", expect: .missed),
    ]

    /// The Check Media rows that are about the sound.
    static let soundKinds: [MediaCheckKind] = [.avDuration, .audioSamples, .sound, .soundContinuity,
                                               .loudness, .dcOffset, .channels, .clipping]

    static func generate(_ fault: Fault, _ c: Container, into dir: URL) throws -> String {
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_sfm_\(UUID().uuidString.prefix(6)).\(c.rawValue)",
            videoCodec: c.videoCodec, extraVideoArgs: c.videoArgs,
            audioCodec: fault.expr == nil ? nil : c.audioCodec, audioExpr: fault.expr ?? "0|0",
            size: c.size, videoDuration: seconds, audioDuration: fault.audioSeconds)
        guard fault.damage != .none else { return path }
        let size = ((try FileManager.default.attributesOfItem(atPath: path))[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        switch fault.damage {
        case .none: break
        case .cutAt60Percent:
            try handle.truncate(atOffset: size * 6 / 10)
        case .zerosTenPercentMid:
            try handle.seek(toOffset: size * 45 / 100)
            try handle.write(contentsOf: Data(count: Int(size / 10)))
        }
        return path
    }

    /// One file through Promote's gate and Check Media's sound rows.
    static func outcome(path: String) async throws -> (Outcome, detail: String) {
        var audio: Result<AudioVerifyDiagnosis, CheckMediaSkip>
        let finding: G.Finding
        do {
            let d = try await VerifyAudioProbe.diagnose(path: path)
            audio = .success(d)
            finding = G.finding(from: d)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            audio = .failure(CheckMediaSkip(reason: CheckMediaProbe.reason(for: error)))
            finding = .unchecked(G.uncheckedReason(error))
        }
        let decision = G.decide(finding: finding, mark: .absent, soundPartnerName: nil, recordedYear: nil, digestPrefix: "")
        if case .refuse(let code, let detail, _) = decision { return (.refused(code), detail) }

        var rows: [MediaCheck] = []
        if case .measured(let quick) = try await CheckMediaProbe.quick(path: path) {
            rows = [R.checkAVDuration(quick), R.checkAudioSamples(quick)]
            if quick.facts.audio != nil {
                let continuity = try await CheckMediaProbe.soundContinuity(path: path, facts: quick.facts)
                rows.append(R.checkSound(audio, facts: quick.facts))
                rows.append(R.checkSoundContinuity(continuity, facts: quick.facts))
                rows += R.levelChecks(continuity, facts: quick.facts)
            }
        }
        let loud = rows.filter { soundKinds.contains($0.kind) && $0.verdict.rank >= MediaCheckVerdict.warning.rank }
        let detail = loud.map { "\($0.kind.rawValue): \($0.sentence)" }.joined(separator: " | ")
        // The row that names the fault most directly comes first in `soundKinds`' order of the table's claims.
        if let first = loud.first { return (.flagged(first.kind), detail) }
        if case .promote(let note?, _) = decision { return (.noted, note) }
        return (.missed, "")
    }
}

@Suite("Sound fault matrix — what the sound checks catch, and what they do not", .serialized)
struct SoundFaultMatrixTests {
    typealias M = SoundFaultMatrix

    @Test("CONTROL: a healthy file promotes and no sound row says anything, in every container",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func healthy() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("sfm")
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in M.Container.allCases {
            let (outcome, detail) = try await M.outcome(path: try M.generate(M.healthy, c, into: dir))
            #expect(outcome == .missed, "\(c.rawValue): a healthy file read \(outcome) — \(detail)")
        }
    }

    @Test("each fault lands in its pinned class in each container",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)), arguments: M.faults)
    func fault(_ fault: M.Fault) async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("sfm")
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

    @Test("the table adds up: the totals quoted in STATUS are the table's own")
    func theTableAddsUp() {
        var refused = 0, flagged = 0, missed = 0
        for fault in M.faults {
            for c in M.Container.allCases where !fault.skip.contains(c) {
                switch fault.expected(in: c) {
                case .refused: refused += 1
                case .flagged, .noted: flagged += 1
                case .missed: missed += 1
                case .clean: Issue.record("a fault row expects 'clean': \(fault.name)")
                }
            }
        }
        #expect(M.faults.count == 19)
        #expect(refused + flagged + missed == 94)
        #expect(refused == 26, "refused at the Promote gate: \(refused)")
        #expect(flagged == 57, "promoted, with a Check Media warning: \(flagged)")
        #expect(missed == 11, "KNOWN GAPS — promoted with nothing said: \(missed)")
    }
}
