import Foundation

// MARK: - Audio Balance analyzer (pure half)
//
// "Balance Audio" — GH #116, Rick 2026-07. Older tape ingests sometimes
// carry program on ONE channel of a stereo track (left-only being the
// classic Avid-ingest symptom). This file is the PURE half of the
// analyzer: classification rules, thresholds, and the astats output
// parser — no I/O, no ffmpeg, fully unit-testable without media (the
// same engine/commit split CleanupEngine documents).
//
// The ffmpeg invocation half lives in AudioBalanceProbe.swift.
//
// CLASSIFICATION RULES (thresholds validated empirically 2026-07-17
// against synthetic aevalsrc fixtures, AAC and PCM):
//
//   - A channel "carries program" when its RMS level is above
//     `programFloorDBFS` (−60 dBFS). A digitally-silent channel decodes
//     to −inf; AAC-encoded silence also decodes to exact digital
//     silence. Tape hiss on a dead channel measures far below −60;
//     real program (even quiet dialog) measures far above.
//
//   - leftOnly  = channel 1 carries program, channel 2 does not.
//   - rightOnly = the mirror.
//
//   - dualMono  = BOTH channels carry program AND are effectively
//     identical: the RMS of the sample-difference signal (L−R) is at
//     least `dualMonoDifferenceMarginDB` (40 dB) below the louder
//     channel's RMS. Measured margins: identical channels through AAC
//     ≈ 90 dB below program; decorrelated stereo ≈ 3 dB below. The
//     40 dB line sits in the middle of that enormous gap.
//     dualMono is ALREADY BALANCED — it must never be "fixed".
//
//   - trueStereo = both channels carry program and are NOT effectively
//     identical. NEVER modified. When the difference signal was not
//     measured (nil), classification is conservatively trueStereo —
//     unknown must never become something we'd alter.
//
//   - mono (single-channel stream) = the stream has exactly one
//     channel; actionable only as an OPTIONAL spread to dual-mono.
//   - silent = no channel carries program (nothing to fix).
//   - multichannel = more than 2 channels; classification only, no fix
//     in v1.

// MARK: - Classification

/// The analyzer's verdict for one audio stream.
enum AudioChannelClass: String, Sendable, Equatable {
    case trueStereo
    case leftOnly
    case rightOnly
    case dualMono
    /// Single-channel stream (distinct from a stereo stream with one
    /// live channel).
    case mono
    case silent
    /// More than 2 channels — classified, not fixable in v1.
    case multichannel

    /// Plain family language for the sheet's headline (friendly-language
    /// convention — no engineering jargon in the UI).
    var familyDescription: String {
        switch self {
        case .trueStereo:
            return "True stereo — both channels have their own sound. Nothing to fix."
        case .leftOnly:
            return "Left channel has sound, right is silent."
        case .rightOnly:
            return "Right channel has sound, left is silent."
        case .dualMono:
            return "Both channels carry the same sound — already balanced."
        case .mono:
            return "One-channel (mono) sound. It can be spread to both speakers."
        case .silent:
            return "No sound was found on any channel."
        case .multichannel:
            return "This file has surround (more than 2 channels) sound — balancing isn't supported for it yet."
        }
    }
}

// MARK: - Measurements

/// Per-channel loudness as measured by ffmpeg's astats filter.
/// Levels are dBFS; digital silence is `-Double.infinity`.
struct AudioChannelLevels: Sendable, Equatable {
    var rmsDBFS: Double
    var peakDBFS: Double
}

/// Everything the classifier consumes. Built by AudioBalanceProbe from
/// real astats output, or directly by tests.
struct AudioBalanceMeasurements: Sendable, Equatable {
    /// Index 0 = channel 1 (left), index 1 = channel 2 (right), …
    var channels: [AudioChannelLevels]
    /// RMS (dBFS) of the sample-difference signal (L−R), measured only
    /// for 2-channel streams where both channels carry program. nil =
    /// not measured → classification stays conservatively trueStereo.
    var differenceRMSDBFS: Double?
}

// MARK: - Classifier (pure)

enum AudioBalanceClassifier {

    /// RMS threshold below which a channel is considered to carry no
    /// program (dBFS). See the file header for the empirical basis.
    static let programFloorDBFS: Double = -60.0

    /// How far below the louder channel's RMS the difference signal
    /// must sit for two live channels to count as "effectively
    /// identical" (dual-mono), in dB.
    static let dualMonoDifferenceMarginDB: Double = 40.0

    /// True when the channel's RMS clears the program floor.
    static func carriesProgram(_ channel: AudioChannelLevels) -> Bool {
        channel.rmsDBFS > programFloorDBFS
    }

    /// The classification rules, verbatim from the file header.
    static func classify(_ m: AudioBalanceMeasurements) -> AudioChannelClass {
        switch m.channels.count {
        case 0:
            return .silent                       // defensive: no data = nothing to fix
        case 1:
            return carriesProgram(m.channels[0]) ? .mono : .silent
        case 2:
            break                                // the interesting case, below
        default:
            return .multichannel
        }

        let left = m.channels[0]
        let right = m.channels[1]
        switch (carriesProgram(left), carriesProgram(right)) {
        case (false, false):
            return .silent
        case (true, false):
            return .leftOnly
        case (false, true):
            return .rightOnly
        case (true, true):
            // Both live: identical (dual-mono) or genuinely stereo?
            // Unmeasured difference ⇒ trueStereo (conservative — we
            // never fix trueStereo, so unknown can never be altered).
            guard let diff = m.differenceRMSDBFS else { return .trueStereo }
            let louder = max(left.rmsDBFS, right.rmsDBFS)
            return diff <= louder - dualMonoDifferenceMarginDB ? .dualMono : .trueStereo
        }
    }
}

// MARK: - astats stderr parser (pure)

/// Parses ffmpeg astats stderr output into per-channel levels.
///
/// Expected shape (validated against ffmpeg 8.x, 2026-07-17):
///
///   [Parsed_astats_0 @ 0x...] Channel: 1
///   [Parsed_astats_0 @ 0x...] Peak level dB: -4.011880
///   [Parsed_astats_0 @ 0x...] RMS level dB: -9.040315
///   [Parsed_astats_0 @ 0x...] Channel: 2
///   [Parsed_astats_0 @ 0x...] Peak level dB: -inf
///   [Parsed_astats_0 @ 0x...] RMS level dB: -inf
///
/// "-inf" (digital silence) parses to `-Double.infinity`. An "Overall"
/// section, when present, is ignored. Channels missing a value default
/// to silence (−inf) — a parse gap must never inflate a level.
enum AstatsOutputParser {

    /// Parse the collected stderr text of an astats pass.
    static func perChannelLevels(fromStderr text: String) -> [AudioChannelLevels] {
        var levels: [AudioChannelLevels] = []
        var currentIndex: Int?          // 0-based index into `levels`
        var inOverall = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // Strip the "[Parsed_astats_N @ 0x…] " prefix if present.
            let payload: Substring
            if let close = line.range(of: "] ") {
                payload = line[close.upperBound...]
            } else {
                payload = Substring(line)
            }

            if let channelValue = value(of: "Channel:", in: payload) {
                inOverall = false
                // astats channel numbers are 1-based and sequential.
                if let n = Int(channelValue), n >= 1 {
                    while levels.count < n {
                        levels.append(AudioChannelLevels(
                            rmsDBFS: -.infinity, peakDBFS: -.infinity))
                    }
                    currentIndex = n - 1
                } else {
                    currentIndex = nil
                }
                continue
            }
            if payload.hasPrefix("Overall") {
                inOverall = true
                currentIndex = nil
                continue
            }
            guard !inOverall, let idx = currentIndex, idx < levels.count else { continue }

            if let v = value(of: "RMS level dB:", in: payload) {
                levels[idx].rmsDBFS = parseDB(v)
            } else if let v = value(of: "Peak level dB:", in: payload) {
                levels[idx].peakDBFS = parseDB(v)
            }
        }
        return levels
    }

    /// "Label: value" → "value" (trimmed), or nil when the line isn't
    /// that label.
    private static func value(of label: String, in payload: Substring) -> String? {
        guard payload.hasPrefix(label) else { return nil }
        return payload.dropFirst(label.count)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "-inf" → −∞; otherwise a plain Double, defaulting to silence on
    /// garbage (a parse failure must never read as a loud channel).
    static func parseDB(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "-inf" || s == "-infinity" { return -.infinity }
        if s == "inf" || s == "infinity" { return .infinity }
        return Double(s) ?? -.infinity
    }
}
