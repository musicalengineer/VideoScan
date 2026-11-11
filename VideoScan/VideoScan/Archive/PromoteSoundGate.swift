// PromoteSoundGate.swift
// THE rule for "may this file's sound go into the archive?" (Rick
// 2026-11-10): Promote measures a video's sound itself and refuses a video
// whose sound is missing, silent or damaged unless the owner has marked that
// file as acceptable without sound.
//
// ALWAYS measured, never reused, never stored (after Codex #280 / #281): a
// stored Verify Audio verdict carries neither the digest it was measured on
// nor whether the levels pass was complete, so no stored verdict is read
// here, and the gate writes none. Its record is the SOUND OUTCOME log line
// (per-channel levels + the sha256 of the bytes measured). The owner's tag
// is the only stored input.
//
// One rule, one caller: PromoteToArchiveJob.soundGate (+Guards), which every
// Promote door reaches — the Catalog / Triage / Archive buttons and Archive
// Angel all end in the same job. The gate runs after the source's bytes are
// proven (whole-file SHA-256) and before the first archive write.
//
// What counts as sound is a MEASUREMENT: a channel's decoded whole-track RMS
// above −60 dBFS (AudioBalanceClassifier.programFloorDBFS). Never the
// header's stream type or channel count (DECISIONS 2026-10-16: a header never
// says "has sound"). Mono and one-sided sound pass; one-sided leaves a note.
//
// The owner's word is the existing per-content tag "Silent — checked"
// (WorkflowTags.silentChecked). It accepts a file with no track or a silent
// track, never damaged sound and never "could not check".
//
// Pure: plain values in, one value out; no I/O, no catalog, no model. The
// job owns the measurement step and the log lines.
//
// (For Rick: a caseless `enum` with statics ≈ a C++ namespace of free
// functions; an `enum` with payloads ≈ std::variant.)

import Foundation
import VideoScanCore

enum PromoteSoundGate {

    /// The silence line, dBFS RMS. A channel carries sound only ABOVE it.
    static let floorDBFS: Double = AudioBalanceClassifier.programFloorDBFS
    /// The owner's "no sound is right for this one" mark.
    static let ownerTag: String = WorkflowTags.silentChecked

    enum Side: String, Sendable, Equatable { case left, right }

    /// What the sound of these bytes is.
    enum Finding: Sendable, Equatable {
        /// At least one channel of one stream carries sound. `levels` is the
        /// measured line.
        case present(oneSided: Side?, levels: String)
        /// ffprobe found no audio stream.
        case noTrack
        /// Every channel of every stream was measured at or under the line.
        case silent(levels: String, loudestDBFS: Double)
        /// Verify Audio's damage (reference movie, short audio, bad codec).
        case damaged(String)
        /// No measurement: the reason. Never a pass.
        case unchecked(String)
    }

    /// Whether the owner's tag speaks for the bytes being promoted.
    enum Mark: Sendable, Equatable {
        case absent
        case accepted
        /// The record carries the tag, but its stored fingerprint names
        /// different bytes than the ones proven now.
        case notTiedToTheseBytes
    }

    /// The refusal codes (the Promote job's `Refusal.Code` carries the same
    /// raw values; Archive Angel reads them to choose its words).
    enum Code: String, Sendable, Equatable, CaseIterable {
        case noTrack = "sound-none"
        case pairHalf = "sound-pair-half"
        case silent = "sound-silent"
        case damaged = "sound-damaged"
        case unchecked = "sound-unchecked"
    }

    enum Decision: Sendable, Equatable {
        /// Go on. `rowNote` is shown on the promoted file's outcome row;
        /// `logFacts` is the path-free OUTCOME text.
        case promote(rowNote: String?, logFacts: String)
        /// Stop before anything is written. `detail` may name files (UI
        /// only); `logFacts` never does.
        case refuse(code: Code, detail: String, logFacts: String)

        var isRefusal: Bool {
            if case .refuse = self { return true }
            return false
        }
    }

    /// The measurement step. Production is always `.live`; tests that
    /// promote random bytes pass a canned answer (PromoteSoundGateSensorTests
    /// pins that no production file assigns the job's `soundMeasure`).
    struct Measure: Sendable {
        let diagnose: @Sendable (String) async throws -> AudioVerifyDiagnosis
        static let live = Measure { try await VerifyAudioProbe.diagnose(path: $0) }
    }

    // MARK: Measurement → finding

    /// What a complete Verify Audio diagnosis says about the sound.
    /// Precedence: damage, then no track, then the levels.
    static func finding(from d: AudioVerifyDiagnosis) -> Finding {
        // Damage is a DECODED-and-bad result. The probe's "undecodable"
        // (`decodable: false`) only means its levels pass failed while the
        // header still read — a failed read looks the same — so on its own
        // it is "could not check", not damage (Codex #281 F1).
        let damage = d.findings.filter { VerifyAudioRules.isDamage($0) && failedLevelsPassCodec($0) == nil }
        if !damage.isEmpty {
            return .damaged(damage.map(VerifyAudioRules.noteFragment(for:)).joined(separator: "; "))
        }
        if let codec = d.findings.lazy.compactMap(failedLevelsPassCodec).first {
            return .unchecked("the sound track could not be decoded (\(codec.isEmpty ? "unknown codec" : codec)) — "
                + "a failed read, or sound that Repair… has to rebuild")
        }
        if d.shape.audioStreams <= 0 { return .noTrack }
        guard let analysis = d.balanceAnalysis else {
            return .unchecked("the sound track was not decoded")
        }
        // Completeness FIRST (Codex #280 F5): a live channel does not excuse
        // a pass that skipped a stream or could not read a channel — the
        // answer, and the verdict stored from it, must be about every channel.
        guard let silent = analysis.measuredSilent else {
            return .unchecked("the sound track was only partly measured")
        }
        let channels = analysis.measurements.channels
        let line = levelsLine(channels)
        if silent {
            return .silent(levels: line, loudestDBFS: channels.map(\.rmsDBFS).max() ?? -.infinity)
        }
        return .present(oneSided: oneSided(analysis), levels: line)
    }

    /// The codec of a levels pass that FAILED to run to the end, else nil.
    private static func failedLevelsPassCodec(_ finding: AudioVerifyFinding) -> String? {
        if case .unsupportedCodec(let codec, decodable: false) = finding { return codec }
        return nil
    }

    /// One side only: exactly one stream carries sound, it has two
    /// channels, both measured, and one of them is under the line.
    static func oneSided(_ analysis: AudioBalanceAnalysis) -> Side? {
        guard analysis.programStreamCount == 1, analysis.measurements.channels.count == 2,
              analysis.measurements.channels.allSatisfy(\.rmsMeasured) else { return nil }
        switch analysis.classification {
        case .leftOnly: return .left
        case .rightOnly: return .right
        default: return nil
        }
    }

    /// "2 ch: L -18.2, R -inf dBFS RMS" — numbers only, safe for logs.
    static func levelsLine(_ channels: [AudioChannelLevels]) -> String {
        let names = ["L", "R", "C", "LFE", "Ls", "Rs", "7", "8"]
        let parts = channels.enumerated().map { i, ch -> String in
            let name = channels.count == 1 ? "mono" : (i < names.count ? names[i] : "\(i + 1)")
            return "\(name) \(ch.rmsMeasured ? db(ch.rmsDBFS) : "not measured")"
        }
        return "\(channels.count) ch: " + parts.joined(separator: ", ") + " dBFS RMS"
    }

    /// "-68.1", or "-inf" for digital silence.
    static func db(_ value: Double) -> String {
        value == -.infinity ? "-inf" : String(format: "%.1f", value)
    }

    // MARK: The owner's mark

    /// Does the "Silent — checked" tag speak for the bytes proven now?
    /// The tag is stored per content digest, so: a record with a stored
    /// whole-file fingerprint carries it only when that fingerprint IS the
    /// proven digest; a record never fingerprinted carries it when its
    /// catalogued size is the proven byte count (this Promote's proof
    /// becomes its first fingerprint).
    static func mark(tags: [String], storedFixity: ContentFixity?, provenDigest: String,
                     recordSizeBytes: Int64, provenSizeBytes: Int64) -> Mark {
        guard WorkflowTags.contains(tags, ownerTag) else { return .absent }
        if let storedFixity {
            let same = storedFixity.algorithm == ContentFixity.sha256 && !provenDigest.isEmpty
                && storedFixity.digest.lowercased() == provenDigest.lowercased()
            return same ? .accepted : .notTiedToTheseBytes
        }
        return provenSizeBytes > 0 && recordSizeBytes == provenSizeBytes ? .accepted : .notTiedToTheseBytes
    }

    // MARK: The decision

    /// THE decision. Precedence: could not check → damaged → no track /
    /// silent (the owner's mark may accept) → present.
    /// `soundPartnerName`: the catalogued sound half when this is the
    /// picture half of a pair (words only — it never passes anything).
    /// `recordedYear`: for the "film before 1980 is often silent" hint only.
    static func decide(finding: Finding, mark: Mark,
                       soundPartnerName: String?, recordedYear: Int?,
                       digestPrefix: String) -> Decision {
        let sha = digestPrefix.isEmpty ? "" : ", sha256 \(digestPrefix)…"
        switch finding {
        case .unchecked(let why):
            return .refuse(code: .unchecked,
                           detail: "Not promoted — the sound could not be checked (\(why)). Could not check is not a pass. "
                               + "Nothing was copied; try again when the drive is connected and idle.",
                           logFacts: "the sound could not be checked (\(why)); nothing written")

        case .damaged(let what):
            return .refuse(code: .damaged,
                           detail: "Not promoted — the sound is damaged: \(what). Right-click ▸ Repair… shows the fix. Nothing was copied.",
                           logFacts: "damaged sound (\(what)); nothing written")

        case .present(let side, let levels):
            let measured = " — \(levels), floor \(db(floorDBFS))"
            switch side {
            case .none:
                return .promote(rowNote: nil, logFacts: "present\(measured)\(sha)")
            case .some(let s):
                return .promote(rowNote: "sound on the \(s.rawValue) side only",
                                logFacts: "present, \(s.rawValue) only\(measured)\(sha)")
            }

        case .noTrack:
            return decideNoTrack(mark: mark, partner: soundPartnerName.flatMap { $0.isEmpty ? nil : $0 },
                                 recordedYear: recordedYear, sha: sha)

        case .silent(let levels, let loudest):
            return decideSilent(levels: levels, loudest: loudest, mark: mark, recordedYear: recordedYear, sha: sha)
        }
    }

    /// No audio stream: accepted by the owner's tag, else refused — with the
    /// pair's words when a sound partner is catalogued.
    private static func decideNoTrack(mark: Mark, partner: String?, recordedYear: Int?, sha: String) -> Decision {
        if mark == .accepted {
            let partnerFact = partner == nil ? "" : "; a sound partner is catalogued"
            return .promote(rowNote: "no sound track — you tagged this file “\(ownerTag)”",
                            logFacts: "no audio stream, accepted — owner tag \"\(ownerTag)\"\(sha)\(partnerFact)")
        }
        if let partner {
            return .refuse(code: .pairHalf,
                           detail: "Not promoted — this is the picture half of a pair; its sound is in \(partner). "
                               + "Use Combine This Pair…, then promote the combined file. Nothing was copied."
                               + notTied(mark),
                           logFacts: "no audio stream, a sound partner is catalogued, \(tagFact(mark)); nothing written")
        }
        return .refuse(code: .noTrack,
                       detail: "Not promoted — this file has no sound track. " + tagHint(recordedYear) + " Nothing was copied."
                           + notTied(mark),
                       logFacts: "no audio stream, \(tagFact(mark)); nothing written")
    }

    /// Every channel under the line: accepted by the owner's tag, else
    /// refused with the measured number.
    private static func decideSilent(levels: String, loudest: Double, mark: Mark, recordedYear: Int?, sha: String) -> Decision {
        if mark == .accepted {
            return .promote(rowNote: "silent sound track — you tagged this file “\(ownerTag)”",
                            logFacts: "silent, accepted — owner tag \"\(ownerTag)\"\(sha); \(levels), floor \(db(floorDBFS))")
        }
        let loudestWords = loudest == -.infinity ? "digital silence" : "loudest \(db(loudest))"
        return .refuse(code: .silent,
                       detail: "Not promoted — the sound track is silent: every channel is under \(db(floorDBFS)) dBFS (\(loudestWords)). "
                           + tagHint(recordedYear) + " Nothing was copied." + notTied(mark),
                       logFacts: "every channel under \(db(floorDBFS)) dBFS RMS (\(levels)), \(tagFact(mark)); nothing written")
    }

    private static func tagHint(_ recordedYear: Int?) -> String {
        let era = (recordedYear.map { $0 < SoundPresencePolicy.silentFilmCutoffYear } ?? false)
            ? " (film before \(SoundPresencePolicy.silentFilmCutoffYear) is often silent)" : ""
        return "If that is right for this file\(era), tag it “\(ownerTag)” and promote again."
    }

    private static func notTied(_ mark: Mark) -> String {
        mark == .notTiedToTheseBytes
            ? " The “\(ownerTag)” tag on it was given to an earlier version of this file — tag it again if it still applies."
            : ""
    }

    private static func tagFact(_ mark: Mark) -> String {
        switch mark {
        case .absent: return "no owner tag"
        case .accepted: return "owner tag present"
        case .notTiedToTheseBytes: return "owner tag not tied to these bytes"
        }
    }

    // MARK: Words for "could not check"

    /// Why a measurement that threw gave no answer: (for the row, for the
    /// log). The probe's own sentences name no file.
    static func uncheckedReason(_ error: Error) -> String {
        switch error {
        case AudioVerifyProbeError.toolUnavailable:
            return "the audio tools (ffmpeg / ffprobe) are not available"
        case AudioVerifyProbeError.probeFailed(let detail):
            return detail
        case AudioBalanceProbeError.timedOut(let seconds):
            return "the check ran out of time after \(seconds) seconds"
        default:
            return "the check failed to run"
        }
    }
}
