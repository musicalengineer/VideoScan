import Foundation

// MARK: - Repair Now: every applicable fix, in a defined order, as ONE
// ffmpeg pass writing ONE new file (Rick 2026-10-08).
//
// The order (`MediaRepairRecipe.order`):
//   1. Remove repeated frames — the picture is rebuilt first, because it
//      decides the file's timing (and its re-encode is the one lossy step).
//   2. Lossless remux — sound beside picture. Any pass ffmpeg writes is
//      interleaved by its muxer, so after step 1 or a sound fix this is
//      already done by the same write; on its own it is a pure stream copy.
//   3. Rebuild the sound track (an old / unreadable sound format) → PCM.
//   4. Balance the sound (one live channel to both speakers).
// Steps 3 and 4 both rewrite the one sound track; when both are offered,
// the rebuild runs and Balance is reported as not combined (Repair on the
// new file offers it again once the sound can be measured).
//
// Pure: the plan says WHAT runs; MediaRepairJob runs it.

/// How the picture is written.
enum MediaRepairPicture: Equatable, Sendable {
    /// Copied packet for packet.
    case copy
    /// mpdecimate + re-time at the measured real rate, H.264 CRF 16.
    case removeRepeatedFrames
}

/// How the sound is written.
enum MediaRepairSound: Equatable, Sendable {
    case copy
    /// Re-encoded to 24-bit PCM (`rebuiltSoundCodec`).
    case rebuild
    /// The Balance Audio pan, re-encoded in the same codec family
    /// (BalanceAudioFix's own encoder rule).
    case balance(pan: String, encodeArgs: [String])
}

/// What the session knows about the sound, for the balance step: the
/// pan filter for its channel class and whether the file's sound layout
/// is one the combined pass may touch (one sound stream, not raw DV — the
/// dedicated Balance Audio job handles the rest).
struct MediaRepairBalanceInput: Equatable, Sendable {
    var pan: String?
    var encodeArgs: [String]
    var singleSoundStream: Bool
    var rawDV: Bool

    init(pan: String?, encodeArgs: [String], singleSoundStream: Bool, rawDV: Bool) {
        self.pan = pan
        self.encodeArgs = encodeArgs
        self.singleSoundStream = singleSoundStream
        self.rawDV = rawDV
    }

    init?(diagnosis: AudioVerifyDiagnosis?) {
        guard let analysis = diagnosis?.balanceAnalysis else { return nil }
        let shape = analysis.shape
        self.init(pan: BalanceAudioFix.panFilter(for: analysis.classification),
                  encodeArgs: BalanceAudioFix.audioEncodeArgs(sourceCodec: shape.audioCodec,
                                                             bitRateBitsPerSec: shape.audioBitRate),
                  singleSoundStream: shape.audioStreams <= 1,
                  rawDV: BalanceAudioFix.isRawDVContainer(shape.containerFormat))
    }
}

struct MediaRepairRecipe: Equatable, Sendable {

    /// The defined order every recipe applies its fixes in.
    static let order: [MediaRepairFix] = [.removeRepeatedFrames, .remux, .rebuildAudio, .balanceAudio]

    /// A fix that was asked for but is not in this pass, and why.
    struct Skipped: Equatable, Sendable {
        let fix: MediaRepairFix
        let reason: String
    }

    /// The fixes this pass applies, in `order`.
    private(set) var applied: [MediaRepairFix] = []
    private(set) var skipped: [Skipped] = []
    private(set) var picture: MediaRepairPicture = .copy
    private(set) var sound: MediaRepairSound = .copy

    /// Nothing is decoded: the remux's packet-for-packet proof applies.
    var isLossless: Bool { picture == .copy && sound == .copy }
    var isEmpty: Bool { applied.isEmpty }

    /// Build the pass from the fixes wanted (any order, duplicates ignored).
    init(fixes wanted: [MediaRepairFix], balance: MediaRepairBalanceInput?) {
        let wantedSet = Set(wanted)
        for fix in Self.order where wantedSet.contains(fix) {
            add(fix, balance: balance)
        }
    }

    private mutating func add(_ fix: MediaRepairFix, balance: MediaRepairBalanceInput?) {
        switch fix {
        case .removeRepeatedFrames:
            picture = .removeRepeatedFrames
            applied.append(fix)
        case .remux:
            applied.append(fix)
        case .rebuildAudio:
            sound = .rebuild
            applied.append(fix)
        case .balanceAudio:
            if let why = Self.balanceRefusal(balance, sound: sound) {
                skipped.append(Skipped(fix: fix, reason: why))
            } else if let balance, let pan = balance.pan {
                sound = .balance(pan: pan, encodeArgs: balance.encodeArgs)
                applied.append(fix)
            }
        }
    }

    /// Why the balance step can't ride this pass; nil = it can.
    static func balanceRefusal(_ balance: MediaRepairBalanceInput?, sound: MediaRepairSound) -> String? {
        if sound == .rebuild {
            return "the sound track is being rebuilt in this pass; run Repair on the new file to balance it once it can be measured"
        }
        guard let balance, balance.pan != nil else {
            return "this session has no channel measurement for the sound — run a full Verify, then Repair"
        }
        if !balance.singleSoundStream || balance.rawDV {
            return "this file's sound layout (several sound tracks, or raw DV) needs the dedicated Balance Audio job"
        }
        return nil
    }

    /// The new file's extension: a pure stream copy keeps the container;
    /// a re-encoded picture follows MediaRepairOutput's rule; rebuilt PCM
    /// sound needs QuickTime (or Matroska, which takes anything).
    func fileExtension(sourceExtension: String, audioCodec: String) -> String {
        let ext = sourceExtension.lowercased()
        if sound == .rebuild { return ext == "mkv" ? "mkv" : "mov" }
        if picture == .removeRepeatedFrames {
            return MediaRepairOutput.fileExtension(for: .removeRepeatedFrames, sourceExtension: sourceExtension,
                                                   audioCodec: audioCodec)
        }
        return sourceExtension
    }

    /// The one ffmpeg command for this pass — THE seam every encoder
    /// choice goes through (a hardware variant replaces `picture`'s encode
    /// args, nothing else). `picture` is the justified plan, required for
    /// `.removeRepeatedFrames` (nil there = the picture is copied).
    func ffmpegArgs(input: String, output: String, picture plan: MediaRepairPicturePlan?) -> [String] {
        if isLossless { return MediaRepairCommand.remuxArgs(input: input, output: output) }
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input]
        args += ["-map", "0:v:0?", "-map", sound == .copy ? "0:a?" : "0:a:0?"]
        args += picture == .removeRepeatedFrames ? (plan?.encodeArgs ?? ["-c:v", "copy"]) : ["-c:v", "copy"]
        args += soundArgs
        args += ["-map_metadata", "0", "-map_chapters", "0", "-progress", "pipe:2", output]
        return args
    }

    /// Rebuilt sound: 24-bit PCM, the decoded samples kept exactly; sample
    /// rate and channel layout are left as the source has them (codex
    /// consult #2 — PCM keeps what decoded; it cannot invent what is lost).
    static let rebuiltSoundCodec = "pcm_s24le"

    private var soundArgs: [String] {
        switch sound {
        case .copy: return ["-c:a", "copy"]
        case .rebuild: return ["-c:a", Self.rebuiltSoundCodec]
        case .balance(let pan, let encodeArgs): return ["-af", pan] + encodeArgs
        }
    }

    /// One plain line per applied step, for the confirmation, the job's
    /// detail and the log.
    var stepLines: [String] {
        applied.map { fix in
            switch fix {
            case .removeRepeatedFrames: return "Remove repeated frames: one picture per real frame at the file's own frame rate (re-encoded: H.264, CRF 16; the copy is shorter)."
            case .remux: return isLossless
                ? "Re-wrap every stream unchanged with sound stored beside picture (nothing re-encoded)."
                : "Store sound beside picture (done by the same write)."
            case .rebuildAudio: return "Rebuild the sound track as 24-bit PCM (the picture is \(picture == .copy ? "copied exactly" : "the step above"))."
            case .balanceAudio: return "Balance the sound: the live channel goes to both speakers."
            }
        }
    }
}
