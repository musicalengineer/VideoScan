// BalancedCopyProofRules.swift
// The PURE half of BalancedCopyProof: `decide` over measured `Facts`, the
// rules it is made of, and the one-line log record. No file, no subprocess.
// What PROVEN means, rule by rule, is the header of BalancedCopyProof.swift;
// the facts are gathered in BalancedCopyProofMeasure.swift.

import Foundation
import VideoScanCore

extension BalancedCopyProof {

    // MARK: - Pure rules: small helpers

    /// SHA-256 of zero bytes: what a stream that delivered nothing hashes to.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// First 12 hex digits, for reasons (the full digest is in Evidence).
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }

    /// "−48.2 dBFS"; "digital silence" for −∞.
    static func level(_ dBFS: Double) -> String {
        guard dBFS.isFinite else { return dBFS < 0 ? "digital silence" : "unreadable" }
        return String(format: "%.1f dBFS", dBFS).replacingOccurrences(of: "-", with: "−")
    }

    /// "1.968633 s"; "no stated time" for nil.
    static func time(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.6f s", $0) } ?? "no stated time"
    }

    static func side(_ channel: Int) -> String { channel == 0 ? "left" : "right" }

    /// The original channel a balanced copy must equal: 0 = left, 1 = right.
    /// nil = the class is not one the balance job fixes. Mirrors
    /// BalanceAudioFix.panFilter (leftOnly/mono read c0, rightOnly reads c1).
    static func liveChannel(for c: AudioChannelClass) -> Int? {
        switch c {
        case .leftOnly, .mono: return 0
        case .rightOnly: return 1
        case .dualMono, .trueStereo, .silent, .multichannel: return nil
        }
    }

    /// The raw PCM codec that holds a DECODED sample format without changing
    /// a bit ("s16"/"s16p" → pcm_s16le). nil = a format this proof does not
    /// know how to hash exactly.
    static func hashCodec(forSampleFormat format: String) -> String? {
        let packed = format.hasSuffix("p") ? String(format.dropLast()) : format
        switch packed {
        case "u8": return "pcm_u8"
        case "s16": return "pcm_s16le"
        case "s32": return "pcm_s32le"
        case "s64": return "pcm_s64le"
        case "flt": return "pcm_f32le"
        case "dbl": return "pcm_f64le"
        default: return nil
        }
    }

    /// A digest that can be compared: present, and not the hash of nothing
    /// (a stream that delivered no bytes proves nothing about itself).
    static func comparable(_ digest: String?) -> String? {
        guard let digest, digest.count == 64, digest != emptySHA256 else { return nil }
        return digest
    }

    /// Two statements of one time disagree: stated on one side only, or
    /// further apart than `tolerance`. Unstated on BOTH sides agrees (the
    /// container has no such field — WAV has no start time).
    static func moved(_ original: Double?, _ copy: Double?, tolerance: Double) -> Bool {
        switch (original, copy) {
        case (nil, nil): return false
        case (let a?, let b?): return abs(a - b) > tolerance
        default: return true
        }
    }

    // MARK: - Pure rules: streams

    /// Which copy stream answers for which original stream.
    struct Pairing: Sendable, Equatable {
        /// Positions in `original.carried` / `balanced.carried`.
        struct Pair: Sendable, Equatable {
            var original: Int
            var balanced: Int
        }
        var pairs: [Pair]
        var gainedTimecodeTrack: Bool
    }

    /// Pair the non-audio streams, in order. The copy may hold exactly one
    /// more than the original — a `tmcd` timecode track — and only when the
    /// original has none. Kind and codec must agree pairwise (the codec TAG
    /// may not: raw DV's is empty, QuickTime's is "dvc ").
    static func pairing(original: [CarriedStream], balanced: [CarriedStream]) -> Result<Pairing, NotProven> {
        var copyPositions = Array(balanced.indices)
        var gained = false
        if balanced.count == original.count + 1,
           !original.contains(where: \.isTimecodeTrack),
           let extra = balanced.lastIndex(where: \.isTimecodeTrack) {
            copyPositions.remove(at: extra)
            gained = true
        }
        guard copyPositions.count == original.count else {
            return .failure(.streamsDiffer(
                "the original has \(original.count) picture/data streams, the balanced copy \(balanced.count)"))
        }
        for (o, b) in zip(original.indices, copyPositions)
        where original[o].kind != balanced[b].kind || original[o].codec != balanced[b].codec {
            return .failure(.streamsDiffer(
                "stream \(original[o].index) is \(describe(original[o])), the balanced copy has \(describe(balanced[b]))"))
        }
        return .success(Pairing(pairs: zip(original.indices, copyPositions).map { Pairing.Pair(original: $0, balanced: $1) },
                                gainedTimecodeTrack: gained))
    }

    private static func describe(_ s: CarriedStream) -> String {
        s.codec.isEmpty ? "\(s.kind) (\(s.tag))" : "\(s.kind) (\(s.codec))"
    }

    // MARK: - Pure rules: sound format and layout

    /// A layout this proof takes for plain left + right ("mono" for one
    /// channel): stated so, or unstated in a container measured to leave
    /// it unstated.
    static func layoutIsPlain(_ sound: SoundStream, in file: FileLayout) -> Bool {
        if sound.channelLayout == (sound.channels == 1 ? "mono" : "stereo") { return true }
        let unset = sound.channelLayout.isEmpty || sound.channelLayout == "unknown"
        return unset && !file.containerWords.isDisjoint(with: containersLeavingLayoutUnset)
    }

    /// The original's side of the sound rules: one-sided, one track, PCM,
    /// one or two channels laid out plainly.
    static func originalSoundVerdict(_ facts: Facts) -> Outcome? {
        guard facts.originalMeasuredInFull else {
            return .couldNotCheck("the original's sound was only partly measured")
        }
        guard liveChannel(for: facts.originalClass) != nil else {
            return .notProven(.originalNotOneSided(facts.originalClass))
        }
        guard facts.original.sound.count == 1, let sound = facts.original.sound.first else {
            return .notProven(.originalSoundTracks(facts.original.sound.count))
        }
        guard sound.codec.lowercased().hasPrefix("pcm_") else {
            return .notProven(.soundReencoded(codec: sound.codec))
        }
        guard hashCodec(forSampleFormat: sound.sampleFormat) != nil, sound.sampleRateHz > 0 else {
            return .couldNotCheck("the original's sound format could not be read "
                + "(sample format \"\(sound.sampleFormat)\", \(sound.sampleRateHz) Hz)")
        }
        guard (1...2).contains(sound.channels) else {
            return .couldNotCheck("the original's sound has \(sound.channels) channels, which a one-sided track cannot have")
        }
        guard layoutIsPlain(sound, in: facts.original) else {
            return .notProven(.channelLayoutNotStereo(file: "the original", layout: sound.channelLayout))
        }
        return nil
    }

    /// The copy's side: one track, two channels, the original's format,
    /// laid out as stereo. Call after `originalSoundVerdict` returned nil.
    static func balancedSoundVerdict(_ facts: Facts) -> Outcome? {
        guard let original = facts.original.sound.first else { return .notProven(.originalSoundTracks(0)) }
        guard facts.balanced.sound.count == 1, let copy = facts.balanced.sound.first else {
            return .notProven(.balancedSoundTracks(facts.balanced.sound.count))
        }
        guard copy.codec == original.codec else {
            return .notProven(.soundFormatChanged("codec \(original.codec) → \(copy.codec)"))
        }
        guard copy.sampleFormat == original.sampleFormat else {
            return .notProven(.soundFormatChanged("sample format \(original.sampleFormat) → \(copy.sampleFormat)"))
        }
        guard copy.sampleRateHz == original.sampleRateHz else {
            return .notProven(.soundFormatChanged("sample rate \(original.sampleRateHz) → \(copy.sampleRateHz) Hz"))
        }
        guard copy.channels == 2 else {
            return .notProven(.soundFormatChanged("\(copy.channels) channels, expected 2"))
        }
        guard layoutIsPlain(copy, in: facts.balanced) else {
            return .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: copy.channelLayout))
        }
        return nil
    }

    // MARK: - Pure rules: decoder configuration and timing

    /// Every paired stream — and the sound — must be configured for its
    /// decoder and its display as the original is (header, PROVEN 2).
    static func configurationVerdict(_ facts: Facts, pairing: Pairing) -> Outcome? {
        if let original = facts.original.sound.first, let copy = facts.balanced.sound.first,
           original.sideData != copy.sideData {
            return .notProven(.pictureConfigurationDiffers(
                "audio stream \(original.index): side data \(original.sideData.isEmpty ? "none" : original.sideData.prefix(96))"
                + " → \(copy.sideData.isEmpty ? "none" : copy.sideData.prefix(96))"))
        }
        for pair in pairing.pairs {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            if original.kind == "video", !original.configuration.describesAPicture {
                return .couldNotCheck("video stream \(original.index)'s size and pixel format could not be read")
            }
            if let what = original.configuration.firstDifference(from: copy.configuration) {
                return .notProven(.pictureConfigurationDiffers("\(original.kind) stream \(original.index): \(what)"))
            }
        }
        return nil
    }

    /// The sound's stated start, duration and the file's whole duration,
    /// each within the slack (header, PROVEN 3). The sound's distance from
    /// the picture needs no rule of its own: the picture's packet times are
    /// held exactly, so the sound's start is that distance. (The sound's
    /// PACKET count is not compared: PCM packets are the muxer's chunking.)
    static func soundTimingVerdict(_ facts: Facts) -> Outcome? {
        guard let original = facts.original.sound.first, let copy = facts.balanced.sound.first else { return nil }
        let slack = max(original.timingSlackSeconds, copy.timingSlackSeconds)
        if moved(original.timing.startSeconds, copy.timing.startSeconds, tolerance: slack) {
            return .notProven(.timingDiffers("the sound starts at \(time(original.timing.startSeconds)), "
                + "in the balanced copy at \(time(copy.timing.startSeconds))"))
        }
        if moved(original.timing.durationSeconds, copy.timing.durationSeconds, tolerance: slack) {
            return .notProven(.timingDiffers("the sound lasts \(time(original.timing.durationSeconds)), "
                + "in the balanced copy \(time(copy.timing.durationSeconds))"))
        }
        if moved(facts.original.durationSeconds, facts.balanced.durationSeconds, tolerance: slack) {
            return .notProven(.timingDiffers(
                "the file lasts \(time(facts.original.durationSeconds)), "
                + "the balanced copy \(time(facts.balanced.durationSeconds))"))
        }
        return nil
    }

    /// Everything that can be decided BEFORE the sound is decoded: format,
    /// streams, configuration, every carried packet, the sound's stated
    /// times. nil = go on to the sound pass. `measure` asks this first so a
    /// lossy, mis-shaped, re-timed or re-configured pair never costs it.
    static func layoutVerdict(_ facts: Facts) -> Outcome? {
        if let verdict = headerVerdict(facts) { return verdict }
        guard case .success(let pairing) = pairing(original: facts.original.carried,
                                                   balanced: facts.balanced.carried) else { return nil }
        if case .refused(let outcome) = carriedEvidence(facts, pairing: pairing) { return outcome }
        return soundTimingVerdict(facts)
    }

    /// What the two HEADERS alone decide — sound format and layout, the
    /// stream set, decoder and display configuration — before a single
    /// packet is read. `measure` asks this first, so a lossy or mis-shaped
    /// pair costs no whole-file read at all.
    static func headerVerdict(_ facts: Facts) -> Outcome? {
        if let verdict = originalSoundVerdict(facts) ?? balancedSoundVerdict(facts) { return verdict }
        switch pairing(original: facts.original.carried, balanced: facts.balanced.carried) {
        case .failure(let why): return .notProven(why)
        case .success(let pairing): return configurationVerdict(facts, pairing: pairing)
        }
    }

    // MARK: - Pure rules: the reads, the hashes, the discarded channel

    /// One sound pass must have read, of EVERY stream, the packets the
    /// packet pass listed (header, PROVEN 7).
    static func readVerdict(_ file: FileLayout, read: ReadReport?, called name: String) -> Outcome? {
        guard let read else { return .couldNotCheck("\(name)'s hash pass gave no account of what it read") }
        let counted = file.carried.map { ($0.index, $0.packets) } + file.sound.map { ($0.index, $0.timing.packets) }
        for (index, expected) in counted {
            guard let expected, let got = read.streams[index]?.packets else {
                return .couldNotCheck("\(name) was not read to the end (stream \(index): packets not counted)")
            }
            guard got == expected else {
                return .couldNotCheck("\(name) was not read to the end (stream \(index): \(got) of \(expected) packets)")
            }
        }
        guard let sound = file.sound.first, let decoded = read.streams[sound.index] else { return nil }
        guard (decoded.decodeErrors ?? 0) == 0, let samples = decoded.samples, samples > 0 else {
            return .couldNotCheck("\(name)'s sound did not decode cleanly")
        }
        if let stated = sound.timing.durationSeconds,
           abs(Double(samples) / Double(sound.sampleRateHz) - stated) > sound.timingSlackSeconds {
            return .couldNotCheck("\(name) was not read to the end (\(samples) sound samples decoded, "
                + "\(time(stated)) stated)")
        }
        return nil
    }

    /// `carriedEvidence`'s answer: the streams held, or the outcome that ends
    /// the decision.
    enum CarriedCheck: Sendable, Equatable {
        case held([Evidence.Stream])
        case refused(Outcome)
    }

    /// Hold each paired stream against the original's, packet by packet
    /// (header, PROVEN 1): the same count, the same sequence of (size,
    /// payload SHA-256), the same sequence of (presentation time, duration).
    static func carriedEvidence(_ facts: Facts, pairing: Pairing) -> CarriedCheck {
        var out: [Evidence.Stream] = []
        for pair in pairing.pairs {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            let name = "\(original.kind) stream \(original.index)"
            guard let packets = original.packets, let copyPackets = copy.packets else {
                return .refused(.couldNotCheck("\(name)'s packets could not be counted"))
            }
            guard packets == copyPackets else {
                return .refused(.notProven(.timingDiffers("\(name) has \(packets) packets, the balanced copy \(copyPackets)")))
            }
            guard packets > 0, let a = comparable(original.packetSHA256), let b = comparable(copy.packetSHA256),
                  let times = comparable(original.timingSHA256), let copyTimes = comparable(copy.timingSHA256) else {
                return .refused(.couldNotCheck("\(name) gave no packets to compare"))
            }
            guard a == b else {
                return .refused(.notProven(.carriedStreamDiffers(
                    kind: original.kind, originalIndex: original.index, original: a, balanced: b)))
            }
            guard times == copyTimes else {
                return .refused(.notProven(.timingDiffers(
                    "\(name): its packets are not presented at the original's times, each for the original's duration")))
            }
            out.append(Evidence.Stream(kind: original.kind, codec: original.codec, originalIndex: original.index,
                                       balancedIndex: copy.index, packetSHA256: a, timingSHA256: times,
                                       packets: packets))
        }
        return .held(out)
    }

    /// `discardedCheck`'s answer.
    enum DiscardedCheck: Sendable, Equatable {
        /// nil = a one-channel original: nothing is left behind.
        case held(Evidence.Discarded?)
        case refused(Outcome)
    }

    /// The channel the copy leaves behind must have held nothing (header,
    /// PROVEN 6): its measured peak at or under the ceiling.
    static func discardedCheck(_ facts: Facts, liveChannel: Int) -> DiscardedCheck {
        guard let sound = facts.original.sound.first else { return .refused(.notProven(.originalSoundTracks(0))) }
        if sound.channels == 1 { return .held(nil) }
        let other = 1 - liveChannel
        guard sound.channels == 2, let peaks = facts.originalRead?.channelPeaksDBFS, peaks.count == 2,
              !peaks[other].isNaN else {
            return .refused(.couldNotCheck("the original's other channel was not measured"))
        }
        guard peaks[other] <= discardedChannelPeakCeilingDBFS else {
            return .refused(.notProven(.discardedChannelNotSilent(channel: other, peakDBFS: peaks[other])))
        }
        return .held(Evidence.Discarded(channel: other, peakDBFS: peaks[other]))
    }

    /// THE decision. Pure: the same facts always give the same answer.
    /// Order: what is known before the sound is decoded (format, streams,
    /// configuration, every carried packet, the sound's stated times), then
    /// whether both sound passes read everything, then the channel left
    /// behind, then the copy's two channels against each other and against
    /// the original.
    static func decide(_ facts: Facts) -> Outcome {
        if let verdict = layoutVerdict(facts) { return verdict }
        guard let live = liveChannel(for: facts.originalClass), let sound = facts.original.sound.first,
              case .success(let pairing) = pairing(original: facts.original.carried,
                                                   balanced: facts.balanced.carried) else {
            return .couldNotCheck("the two files' streams could not be lined up")
        }
        if let verdict = readVerdict(facts.original, read: facts.originalRead, called: "the original")
            ?? readVerdict(facts.balanced, read: facts.balancedRead, called: "the balanced copy") {
            return verdict
        }
        let carried: [Evidence.Stream]
        switch carriedEvidence(facts, pairing: pairing) {
        case .refused(let outcome): return outcome
        case .held(let streams): carried = streams
        }
        let discarded: Evidence.Discarded?
        switch discardedCheck(facts, liveChannel: live) {
        case .refused(let outcome): return outcome
        case .held(let measured): discarded = measured
        }
        guard let source = comparable(facts.originalLiveSHA256), let left = comparable(facts.balancedLeftSHA256),
              let right = comparable(facts.balancedRightSHA256) else {
            return .couldNotCheck("the sound gave no samples to compare")
        }
        guard left == right else { return .notProven(.channelsDiffer(left: left, right: right)) }
        guard left == source else { return .notProven(.soundDiffers(original: source, balanced: left)) }
        return .proven(Evidence(
            carried: carried, gainedTimecodeTrack: pairing.gainedTimecodeTrack,
            originalClass: facts.originalClass, liveChannel: live, soundCodec: sound.codec,
            sampleFormat: sound.sampleFormat, sampleRateHz: sound.sampleRateHz, soundSHA256: source,
            soundSamples: facts.originalRead?.streams[sound.index]?.samples ?? 0, discarded: discarded))
    }

    // MARK: - The log line (pure; the future caller writes it)

    /// Characters that would break a one-line record or hide in it: line
    /// and paragraph separators, control and format characters.
    private static func breaksALine(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value >= 0x20 && scalar.value < 0x7F { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// `text` with every such character written out as `\u{XXXX}`.
    static func singleLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: breaksALine) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if breaksALine(scalar) {
                out.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// A path between double quotes, with `\` and `"` escaped so the quotes
    /// that end it are always the record's own.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func provenDetail(_ e: Evidence) -> String {
        let streams = e.carried.map {
            "\($0.kind) \($0.originalIndex)→\($0.balancedIndex) sha256 \($0.packetSHA256) (\($0.packets) packets, "
                + "each one's time, duration, size and bytes equal; times sha256 \(short($0.timingSHA256)); "
                + "configuration and side data equal)"
        }
        let sound = "sound \(e.soundCodec) \(e.sampleRateHz) Hz: original \(side(e.liveChannel)) = copy left = copy right "
            + "sha256 \(e.soundSHA256) (\(e.soundSamples) samples)"
        let discarded = e.discarded.map {
            "original \(side($0.channel)): \($0.isDigitalSilence ? "digital silence" : "peak \(level($0.peakDBFS))")"
                + ", not in the copy"
        } ?? "original has one channel, nothing left behind"
        let timecode = e.gainedTimecodeTrack ? ["copy has a muxer-made timecode track"] : []
        return (streams + [sound, discarded] + timecode).joined(separator: "; ")
    }

    /// ONE line naming both files, the verdict, and what was compared.
    /// Whatever a file name, a codec name or a tool's message holds, the
    /// result has no line break and no control character in it.
    static func logLine(original: String, balanced: String, outcome: Outcome) -> String {
        let files = "original \(quoted(original)) · balanced copy \(quoted(balanced))"
        let line: String
        switch outcome {
        case .proven(let e):
            line = "balanced copy proof: PROVEN — \(files) — \(provenDetail(e))"
        case .notProven(let why):
            line = "balanced copy proof: NOT PROVEN — \(files) — \(why.message)"
        case .couldNotCheck(let reason):
            line = "balanced copy proof: COULD NOT CHECK — \(files) — \(reason)"
        }
        return singleLine(line)
    }
}
