// BalancedCopyProofRules.swift
// The PURE half of BalancedCopyProof: `decide` over measured `Facts`, the
// rules it is made of, the named differences, and the START / OUTCOME log
// lines. No file, no subprocess. What each answer means is the header of
// BalancedCopyProof.swift; the facts are gathered in
// BalancedCopyProofMeasure.swift.

import Foundation
import VideoScanCore

extension BalancedCopyProof {

    // MARK: - Small helpers

    /// SHA-256 of zero bytes: what a stream that delivered nothing hashes to.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// First 12 hex digits, for reasons (the full digest is in Evidence).
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }

    /// "−48.2 dBFS"; "digital silence" for −∞.
    static func level(_ dBFS: Double) -> String {
        guard dBFS.isFinite else { return dBFS < 0 ? "digital silence" : "unreadable" }
        return String(format: "%.1f dBFS", dBFS).replacingOccurrences(of: "-", with: "−")
    }

    /// A length in plain words: "1.969 s" under a minute, then "8:34", "1:02:03".
    /// Total: a length that is not a number is written as printf writes it
    /// ("nan s", "inf s"), and one too long to convert (`Int(aDouble)` traps
    /// past Int.max, GH #483 item 3) is said to be that.
    static func length(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return String(format: "%.3f s", seconds) }
        guard seconds < 1e15 else { return "more than 31 million years" }
        let whole = Int(seconds.rounded())
        let (h, m, s) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func side(_ channel: Int) -> String { channel == 0 ? "left" : "right" }

    /// |a − b|, for ANY two Int64: the difference of two 64-bit numbers
    /// always fits unsigned, where `abs(a - b)` traps on overflow and on
    /// Int64.min (GH #483 item 3). (`&-` is wrapping subtraction ≈ C's
    /// unsigned arithmetic; read back unsigned it is the true difference.)
    static func distance(_ a: Int64, _ b: Int64) -> UInt64 {
        a >= b ? UInt64(bitPattern: a &- b) : UInt64(bitPattern: b &- a)
    }

    /// The sum of some counts for a sentence; Int.max when it does not fit.
    static func total(_ counts: some Sequence<Int>) -> Int {
        var sum = 0
        for count in counts {
            let (next, overflow) = sum.addingReportingOverflow(count)
            guard !overflow else { return .max }
            sum = next
        }
        return sum
    }

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
        switch packedSampleFormat(format) {
        case "u8": return "pcm_u8"
        case "s16": return "pcm_s16le"
        case "s32": return "pcm_s32le"
        case "s64": return "pcm_s64le"
        case "flt": return "pcm_f32le"
        case "dbl": return "pcm_f64le"
        default: return nil
        }
    }

    /// "s16p" → "s16": the interleaved form of a sample format.
    static func packedSampleFormat(_ format: String) -> String {
        format.hasSuffix("p") ? String(format.dropLast()) : format
    }

    /// A digest that can be compared: present, and not the hash of nothing.
    static func comparable(_ digest: String?) -> String? {
        guard let digest, digest.count == 64, digest != emptySHA256 else { return nil }
        return digest
    }

    /// The original's sound stream the balance job reads.
    static func keptSound(_ facts: Facts) -> SoundStream? {
        guard let index = facts.keptSoundIndex else { return facts.original.sound.first }
        return facts.original.sound.first { $0.index == index }
    }

    // MARK: - Streams

    /// Which copy picture answers for which original picture. Positions are
    /// into `original.carried` / `balanced.carried`.
    struct Pairing: Sendable, Equatable {
        struct Pair: Sendable, Equatable {
            var original: Int
            var balanced: Int
        }
        /// Picture streams, in order.
        var pictures: [Pair]
    }

    /// Pair the PICTURE streams, in order. Their number must agree — a
    /// picture more or less is not the same content. No other track is
    /// paired: the proof claims nothing about them (see `ancillaries`).
    static func pairing(original: [CarriedStream], balanced: [CarriedStream]) -> Result<Pairing, NotProven> {
        let ours = original.indices.filter { original[$0].isPicture }
        let theirs = balanced.indices.filter { balanced[$0].isPicture }
        guard ours.count == theirs.count else {
            return .failure(.streamsDiffer(
                "the original has \(ours.count) picture streams, the balanced copy \(theirs.count)"))
        }
        return .success(Pairing(pictures: zip(ours, theirs).map { Pairing.Pair(original: $0, balanced: $1) }))
    }

    /// "a timecode track", "a text track (subrip)", "a data track (gpmd)".
    static func describe(_ s: CarriedStream) -> String {
        if s.isTimecodeTrack { return "a timecode track" }
        let name = s.codec.isEmpty ? s.tag : s.codec
        let suffix = name.isEmpty ? "" : " (\(name))"
        switch s.kind {
        case "subtitle": return "a text track\(suffix)"
        case "data": return "a data track\(suffix)"
        case "attachment": return "an attachment\(suffix)"
        default: return "a \(s.kind.isEmpty ? "nameless" : s.kind) track\(suffix)"
        }
    }

    /// A decoded track that plays by default in the original and not in
    /// the copy: QuickTime's "track enabled" switch is this flag, and a
    /// player skips a track that is switched off.
    static func switchedOff(_ original: Set<String>, _ copy: Set<String>) -> Bool {
        original.contains("default") && !copy.contains("default")
    }

    // MARK: - Sound format and layout

    /// A layout this proof takes for plain left + right ("mono" for one
    /// channel): stated so, or unstated in a container measured to leave
    /// it unstated.
    static func layoutIsPlain(_ sound: SoundStream, in file: FileLayout) -> Bool {
        if sound.channelLayout == (sound.channels == 1 ? "mono" : "stereo") { return true }
        let unset = sound.channelLayout.isEmpty || sound.channelLayout == "unknown"
        return unset && !file.containerWords.isDisjoint(with: containersLeavingLayoutUnset)
    }

    /// The original's side of the sound rules: one-sided, with the track the
    /// job reads: PCM, one or two channels laid out plainly. Further sound
    /// tracks are the DV rule's (`spareHeaderVerdict`, `spareCheck`).
    static func originalSoundVerdict(_ facts: Facts) -> Outcome? {
        guard facts.originalMeasuredInFull else {
            return .couldNotCheck("the original's sound was only partly measured")
        }
        guard liveChannel(for: facts.originalClass) != nil else {
            return .notProven(.originalNotOneSided(facts.originalClass))
        }
        guard let sound = keptSound(facts) else { return .notProven(.originalSoundTracks(0)) }
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
        guard let original = keptSound(facts) else { return .notProven(.originalSoundTracks(0)) }
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
        guard original.sideData == copy.sideData else {
            return .notProven(.pictureConfigurationDiffers(
                "audio stream \(original.index): side data \(original.sideData.isEmpty ? "none" : original.sideData.prefix(96))"
                + " → \(copy.sideData.isEmpty ? "none" : copy.sideData.prefix(96))"))
        }
        guard !switchedOff(original.flags, copy.flags) else {
            return .notProven(.pictureConfigurationDiffers(
                "audio stream \(original.index): the balanced copy's track is not marked to play by default"))
        }
        return nil
    }

    /// The DV rule, as far as the headers decide it: a file with more than
    /// one sound track must have a picture, and every picture must be DV on
    /// both sides (DECISIONS 2026-11-17).
    static func spareHeaderVerdict(_ facts: Facts, pairing: Pairing) -> Outcome? {
        guard facts.original.sound.count > 1 else { return nil }
        let codecs = pairing.pictures.flatMap {
            [facts.original.carried[$0.original].codec, facts.balanced.carried[$0.balanced].codec]
        }
        guard !codecs.isEmpty, codecs.allSatisfy({ $0 == "dvvideo" }) else {
            let found = codecs.isEmpty ? "it has no picture" : "its picture is \(Set(codecs).sorted().joined(separator: "/"))"
            return .notProven(.spareSoundTrack(
                "\(facts.original.sound.count) sound tracks; a spare one may be left behind only in a DV recording, and \(found)"))
        }
        return nil
    }

    /// Every paired picture must be DISPLAYED as the original is.
    static func displayVerdict(_ facts: Facts, pairing: Pairing) -> Outcome? {
        for pair in pairing.pictures {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            guard original.configuration.describesAPicture else {
                return .couldNotCheck("picture stream \(original.index)'s size and pixel format could not be read")
            }
            if let what = original.configuration.displayDifference(from: copy.configuration) {
                return .notProven(.pictureConfigurationDiffers("picture stream \(original.index): \(what)"))
            }
            if switchedOff(original.flags, copy.flags) {
                return .notProven(.pictureConfigurationDiffers(
                    "picture stream \(original.index): the balanced copy's track is not marked to play by default"))
            }
        }
        return nil
    }

    /// What the two HEADERS alone decide, before a single packet is read:
    /// sound format and layout, the picture streams, how they are displayed.
    /// `measure` asks this first, so a lossy or mis-shaped pair costs no
    /// whole-file read.
    static func headerVerdict(_ facts: Facts) -> Outcome? {
        if let verdict = originalSoundVerdict(facts) ?? balancedSoundVerdict(facts) { return verdict }
        switch pairing(original: facts.original.carried, balanced: facts.balanced.carried) {
        case .failure(let why): return .notProven(why)
        case .success(let pairing):
            return spareHeaderVerdict(facts, pairing: pairing) ?? displayVerdict(facts, pairing: pairing)
        }
    }

    // MARK: - The packet pass (second evidence)

    /// A stream's packets, when the packet pass read them: count and both digests.
    private static func packets(of s: CarriedStream) -> (count: Int, bytes: String, times: String)? {
        guard let count = s.packets, count > 0, let bytes = comparable(s.packetSHA256),
              let times = comparable(s.timingSHA256) else { return nil }
        return (count, bytes, times)
    }

    // MARK: - The decode pass: was the read whole

    /// Why one decode pass was not a whole read of its file. Every case
    /// carries the numbers it was decided on, so a caller that may not show
    /// the sentence (the corpus harness) can still say which rule fired.
    /// (≈ a C++ `std::variant` of small structs; `sentence` is its visitor.)
    enum ReadShortfall: Sendable, Equatable {
        /// There is no decode pass for the file.
        case noAccount
        /// The packet pass or ffmpeg's log has no count for a decoded stream.
        case packetsNotCounted(stream: Int)
        /// ffmpeg read another number of packets than the packet pass listed.
        case packetCount(stream: Int, read: Int, listed: Int)
        case decodeErrors(stream: Int)
        /// ffmpeg wrote another number of frames than were folded here.
        case framesNotAllFolded(muxed: Int, folded: Int)
        case noPictureFrames(stream: Int)
        /// A picture's decoded length is not the length its header states.
        case pictureLength(stream: Int, decodedSeconds: Double, statedSeconds: Double)
        case noSoundSamples
        /// The sound's decoded length is not the length its header states.
        case soundLength(decodedSamples: Int64, statedSeconds: Double)

        /// The plain sentence, about the file called `name`.
        func sentence(called name: String) -> String {
            switch self {
            case .noAccount:
                return "\(name)'s decode pass gave no account of what it read"
            case .packetsNotCounted(let index):
                return "\(name) was not read to the end (stream \(index): packets not counted)"
            case .packetCount(let index, let read, let listed):
                return "\(name) was not read to the end (stream \(index): \(read) of \(listed) packets)"
            case .decodeErrors(let index):
                return "\(name) did not decode cleanly (stream \(index))"
            case .framesNotAllFolded(let muxed, let folded):
                return "\(name)'s decoded frames did not all arrive (ffmpeg wrote \(muxed), \(folded) were read)"
            case .noPictureFrames(let index):
                return "\(name)'s picture stream \(index) gave no frames"
            case .pictureLength(let index, let decoded, let stated):
                return "\(name) was not read to the end (picture stream \(index): "
                    + "\(BalancedCopyProof.length(decoded)) decoded, \(BalancedCopyProof.length(stated)) stated)"
            case .noSoundSamples:
                return "\(name)'s sound gave no samples"
            case .soundLength(let samples, let stated):
                return "\(name) was not read to the end (\(samples) sound samples decoded, "
                    + "\(BalancedCopyProof.length(stated)) stated)"
            }
        }
    }

    /// One decode pass must have read, of every stream it decoded, the
    /// packets the packet pass listed, with no decode error; ffmpeg must
    /// have muxed exactly the frames folded here; and each decoded stream's
    /// length must be the length its header states, where it states one
    /// (header, WHAT PLAYS 5). A short read is never agreement. nil = whole.
    static func readShortfall(_ file: FileLayout, read: ReadReport?, kept: SoundStream?) -> ReadShortfall? {
        guard let read else { return .noAccount }
        let decoded = file.pictures.map { ($0.index, $0.packets) } + file.sound.map { ($0.index, $0.packets) }
        for (index, expected) in decoded {
            guard let expected, let got = read.streams[index] else { return .packetsNotCounted(stream: index) }
            guard got.packets == expected else { return .packetCount(stream: index, read: got.packets, listed: expected) }
            guard got.decodeErrors == 0 else { return .decodeErrors(stream: index) }
        }
        guard !read.folded.isEmpty, read.muxed == read.folded else {
            return .framesNotAllFolded(muxed: total(read.muxed.values), folded: total(read.folded.values))
        }
        for picture in file.pictures {
            guard let played = read.pictures[picture.index], played.frames > 0 else {
                return .noPictureFrames(stream: picture.index)
            }
            let decodedSeconds = played.endSeconds - played.firstSeconds
            // `!(… <= slack)`, not `… > slack`: a length that is not a number is never agreement.
            if let stated = picture.statedSeconds, !(abs(decodedSeconds - stated) <= picture.timingSlackSeconds) {
                return .pictureLength(stream: picture.index, decodedSeconds: decodedSeconds, statedSeconds: stated)
            }
        }
        guard let kept, kept.sampleRateHz > 0, let samples = read.soundSamples, samples > 0 else { return .noSoundSamples }
        if let stated = kept.statedSeconds,
           !(abs(Double(samples) / Double(kept.sampleRateHz) - stated) <= kept.statedLengthSlackSeconds) {
            return .soundLength(decodedSamples: samples, statedSeconds: stated)
        }
        return nil
    }

    /// `readShortfall` as an outcome: COULD NOT CHECK, in the file's name.
    static func readVerdict(_ file: FileLayout, read: ReadReport?, kept: SoundStream?, called name: String) -> Outcome? {
        readShortfall(file, read: read, kept: kept).map { .couldNotCheck($0.sentence(called: name)) }
    }

    // MARK: - The decode pass: what plays

    /// (≈ a C++ `std::variant<T, Outcome>`: the thing held, or the outcome
    /// that ends the decision.)
    enum Check<Held: Sendable & Equatable>: Sendable, Equatable {
        case held(Held)
        case refused(Outcome)
    }

    /// Every picture stream plays the original's frames at the original's
    /// times (header, WHAT PLAYS 1). Also notes whether its stored packets
    /// are identical — the second evidence.
    static func pictureCheck(_ facts: Facts, pairing: Pairing) -> Check<[Evidence.Stream]> {
        var out: [Evidence.Stream] = []
        for pair in pairing.pictures {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            guard let a = facts.originalRead?.pictures[original.index], let b = facts.balancedRead?.pictures[copy.index],
                  a.frames > 0, let ours = comparable(a.sha256), let theirs = comparable(b.sha256),
                  let stored = packets(of: original), let copied = packets(of: copy) else {
                return .refused(.couldNotCheck("picture stream \(original.index) gave no frames to compare"))
            }
            guard a.frames == b.frames else {
                return .refused(.notProven(.pictureDiffers(
                    originalIndex: original.index, "\(a.frames) frames play in the original, \(b.frames) in the balanced copy")))
            }
            guard ours == theirs else {
                return .refused(.notProven(.pictureDiffers(
                    originalIndex: original.index,
                    "its frames are not the original's, each at the original's time: sha256 \(short(ours)) ≠ \(short(theirs))")))
            }
            out.append(Evidence.Stream(
                codec: original.codec, originalIndex: original.index, balancedIndex: copy.index,
                frames: a.frames, framesSHA256: ours,
                packetIdentical: stored.count == copied.count && stored.bytes == copied.bytes && stored.times == copied.times,
                packetSHA256: stored.bytes, packets: stored.count))
        }
        return .held(out)
    }

    /// The channel the copy leaves behind must have held nothing: its
    /// measured peak at or under the ceiling. nil = a one-channel original.
    static func discardedCheck(_ facts: Facts, kept: SoundStream, liveChannel: Int) -> Check<Evidence.Discarded?> {
        if kept.channels == 1 { return .held(nil) }
        let other = 1 - liveChannel
        guard kept.channels == 2, let peaks = facts.originalRead?.peaksDBFS[kept.index], peaks.count == 2,
              !peaks[other].isNaN else {
            return .refused(.couldNotCheck("the original's other channel was not measured"))
        }
        guard peaks[other] <= discardedChannelPeakCeilingDBFS else {
            return .refused(.notProven(.discardedChannelNotSilent(channel: other, peakDBFS: peaks[other])))
        }
        return .held(Evidence.Discarded(channel: other, peakDBFS: peaks[other]))
    }

    /// The copy's left, its right and the original's live channel are the
    /// same samples, placed at the same times (header, WHAT PLAYS 2). Held:
    /// the one digest, and the original's timeline.
    static func soundCheck(_ facts: Facts) -> Check<String> {
        guard let ours = facts.originalRead, let theirs = facts.balancedRead,
              ours.channelSHA256.count == 1, theirs.channelSHA256.count == 2,
              let source = comparable(ours.channelSHA256[0]), let left = comparable(theirs.channelSHA256[0]),
              let right = comparable(theirs.channelSHA256[1]),
              let segments = ours.soundSegments, let copied = theirs.soundSegments, !segments.isEmpty,
              let samples = ours.soundSamples, ours.channelSamples == [samples],
              let copySamples = theirs.soundSamples, theirs.channelSamples == [copySamples, copySamples] else {
            return .refused(.couldNotCheck("the sound gave no samples to compare"))
        }
        guard left == right else { return .refused(.notProven(.channelsDiffer(left: left, right: right))) }
        guard left == source else { return .refused(.notProven(.soundDiffers(original: source, balanced: left))) }
        guard segments.count == copied.count else {
            if let reanchored = reanchored(facts, original: segments, copy: copied) { return .refused(.notProven(reanchored)) }
            return .refused(.notProven(.soundPlacementDiffers(
                "the original's sound plays in \(segments.count) unbroken runs, the balanced copy's in \(copied.count)")))
        }
        for (i, (a, b)) in zip(segments, copied).enumerated()
        where a.samples != b.samples || distance(a.start, b.start) > UInt64(soundTimingToleranceSamples) {
            return .refused(.notProven(.soundPlacementDiffers(
                "run \(i + 1): \(a.samples) samples from sample time \(a.start), "
                + "in the balanced copy \(b.samples) from \(b.start)")))
        }
        return .held(source)
    }

    /// A placement difference in the one shape a raw DV tape gives it
    /// (GH #482), so the refusal can say what it is: the original is raw DV
    /// — whose sound has no timestamps of its own; FFmpeg stamps it by the
    /// running sample count and re-anchors it to the picture whenever the
    /// two are a whole frame apart — its sound decodes in several runs, and
    /// the copy plays ONE run from the same start. Called only after the
    /// samples were found equal. Still NOT THE SAME: the placement rule is
    /// not relaxed, only named. nil = any other difference (the general
    /// reason stands), including runs whose ends do not fit in 64 bits.
    static func reanchored(_ facts: Facts, original: [SoundSegment], copy: [SoundSegment]) -> NotProven? {
        guard facts.original.containerWords == ["dv"], original.count > 1, copy.count == 1,
              let rate = keptSound(facts)?.sampleRateHz, let first = original.first,
              distance(first.start, copy[0].start) <= UInt64(soundTimingToleranceSamples) else { return nil }
        var overlap: Int64 = 0, gap: Int64 = 0
        for (before, after) in zip(original, original.dropFirst()) {
            let (end, endOverflows) = before.start.addingReportingOverflow(before.samples)
            let (step, stepOverflows) = after.start.subtractingReportingOverflow(end)
            guard !endOverflows, !stepOverflows, step != .min else { return nil }
            let (sum, sumOverflows) = (step < 0 ? overlap : gap).addingReportingOverflow(abs(step))
            guard !sumOverflows else { return nil }
            if step < 0 { overlap = sum } else { gap = sum }
        }
        return .soundReanchored(times: original.count - 1, overlapSamples: overlap, gapSamples: gap, sampleRateHz: rate)
    }

    /// The DV rule, measured (DECISIONS 2026-11-17): every sound track the
    /// copy leaves behind was measured at or under the ceiling, and every
    /// picture is DV and packet-identical. Held: one named difference per
    /// dropped track.
    static func spareCheck(_ facts: Facts, kept: SoundStream, streams: [Evidence.Stream]) -> Check<[Difference]> {
        var out: [Difference] = []
        for spare in facts.original.sound where spare.index != kept.index {
            guard let peaks = facts.originalRead?.peaksDBFS[spare.index], spare.channels > 0,
                  peaks.count == spare.channels, !peaks.contains(where: \.isNaN), let peak = peaks.max() else {
                return .refused(.couldNotCheck("the original's sound track \(spare.index) was not measured"))
            }
            guard peak <= discardedChannelPeakCeilingDBFS else {
                return .refused(.notProven(.spareSoundTrack(
                    "stream \(spare.index) is not silent: peak \(level(peak))")))
            }
            guard !streams.isEmpty, streams.allSatisfy({ $0.codec == "dvvideo" && $0.packetIdentical }) else {
                return .refused(.notProven(.spareSoundTrack(
                    "stream \(spare.index) is silent, but the picture is not DV carried bit for bit")))
            }
            out.append(Difference(
                kind: .track, heldBy: .original,
                what: "a second sound track (stream \(spare.index), \(spare.channels) channels), measured silent: "
                    + (peak == -.infinity ? "digital silence" : "peak \(level(peak))")))
        }
        return .held(out)
    }

    // MARK: - Named differences

    /// "a, b, c +2 more".
    private static func named(_ names: [String]) -> String {
        let shown = names.prefix(namedTagLimit).joined(separator: ", ")
        return names.count > namedTagLimit ? "\(shown) +\(names.count - namedTagLimit) more" : shown
    }

    /// Everything ONE file holds that is neither a picture as played nor the
    /// kept sound: other tracks, media an edit list does not play, track
    /// flags, chapter marks, tags. The proof makes NO equality claim about
    /// any of it — the other file may hold the same thing, another thing or
    /// nothing — so each is named for the file that holds it, and nothing
    /// here is ever compared (re-scoped 2026-11-17 after Codex #307/#308).
    /// `played` = how long each decoded stream played, by stream index.
    static func ancillaries(of file: FileLayout, heldBy holder: Difference.Holder, played: [Int: Double]) -> [Difference] {
        var out: [Difference] = []
        func add(_ kind: Difference.Kind, _ what: String) {
            out.append(Difference(kind: kind, heldBy: holder, what: what + " — not compared with the other file"))
        }
        for track in file.carried where !track.isPicture { add(.track, describe(track)) }
        // Stored but not played: a picture or the kept sound against what was
        // decoded; any other track against the length its header states.
        let lengths = file.carried.map { ($0.isPicture ? "picture" : $0.kind, $0.index, $0.storedSeconds, $0.statedSeconds) }
            + file.sound.map { ("sound", $0.index, $0.storedSeconds, $0.statedSeconds) }
        for (thing, index, stored, stated) in lengths {
            guard let stored, let plays = played[index] ?? stated, stored - plays > timingSlackCeilingSeconds else { continue }
            add(.playback, "stored \(thing) (stream \(index)) an edit list does not play: \(length(stored)) stored, \(length(plays)) played")
        }
        let flags = (file.carried.map { ($0.index, $0.flags) } + file.sound.map { ($0.index, $0.flags) })
            .filter { !$0.1.isEmpty }.sorted { $0.0 < $1.0 }
            .map { "stream \($0.0): \($0.1.sorted().joined(separator: " "))" }
        if !flags.isEmpty { add(.playback, "track flags (\(flags.joined(separator: "; ")))") }
        if file.chapters > 0 { add(.metadata, "\(file.chapters) chapter marks") }
        let tags = file.tags.keys.sorted()
            + file.carried.flatMap { s in s.tags.keys.sorted().map { "stream \(s.index) \($0)" } }
            + file.sound.flatMap { s in s.tags.keys.sorted().map { "stream \(s.index) \($0)" } }
        if !tags.isEmpty { add(.metadata, "\(tags.count) tags (\(named(tags)))") }
        return out
    }

    /// How one paired PICTURE is stored differently though every decoded
    /// frame is the same: codec or packets, then decoder configuration.
    private static func storageDifferences(original: CarriedStream, copy: CarriedStream, held: Evidence.Stream) -> [Difference] {
        var out: [Difference] = []
        let every = "every decoded frame is the same"
        if original.codec != copy.codec {
            out.append(Difference(kind: .encoding, heldBy: nil,
                                  what: "picture stream \(original.index) is stored as \(original.codec) in the original "
                                    + "and as \(copy.codec) in the balanced copy; \(every)"))
        } else if !held.packetIdentical {
            out.append(Difference(kind: .encoding, heldBy: nil,
                                  what: "picture stream \(original.index) (\(original.codec)) is not stored in the same "
                                    + "packets (\(original.packets ?? 0) in the original, \(copy.packets ?? 0) in the "
                                    + "balanced copy); \(every)"))
        }
        if original.configuration.extradataSHA256 != copy.configuration.extradataSHA256 {
            out.append(Difference(kind: .decoderConfiguration, heldBy: nil,
                                  what: "picture stream \(original.index)'s decoder configuration (extradata) is "
                                    + "written differently; \(every)"))
        }
        return out
    }

    /// How long each decoded stream of a file played, by stream index.
    private static func played(_ file: FileLayout, read: ReadReport?, kept: SoundStream) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for (index, picture) in read?.pictures ?? [:] { out[index] = picture.endSeconds - picture.firstSeconds }
        if let samples = read?.soundSamples { out[kept.index] = Double(samples) / Double(max(kept.sampleRateHz, 1)) }
        return out
    }

    /// Everything that is not "the same" between two files that PLAY the
    /// same. About the pictures (compared): container, encoding, decoder
    /// configuration. About everything else (NOT compared): what each file
    /// holds, per file. Order: tracks, container, encoding, decoder
    /// configuration, playback instructions, metadata; the original first.
    static func differences(_ facts: Facts, pairing: Pairing, kept: SoundStream, copySound: SoundStream,
                            streams: [Evidence.Stream], spare: [Difference]) -> [Difference] {
        var all = spare
        // A spare DV track was MEASURED, and is named by `spareCheck`; the other sound tracks of the original are those.
        all += ancillaries(of: facts.original, heldBy: .original,
                           played: played(facts.original, read: facts.originalRead, kept: kept))
        all += ancillaries(of: facts.balanced, heldBy: .balancedCopy,
                           played: played(facts.balanced, read: facts.balancedRead, kept: copySound))
        if facts.original.container != facts.balanced.container {
            func word(_ file: FileLayout) -> String { file.container.split(separator: ",").first.map(String.init) ?? "unknown" }
            all.append(Difference(kind: .container, heldBy: nil,
                                  what: "the original is a \(word(facts.original)) file, the balanced copy a \(word(facts.balanced)) file"))
        }
        for (pair, held) in zip(pairing.pictures, streams) {
            all += storageDifferences(original: facts.original.carried[pair.original],
                                      copy: facts.balanced.carried[pair.balanced], held: held)
        }
        let order: [Difference.Kind] = [.track, .container, .encoding, .decoderConfiguration, .playback, .metadata]
        return order.flatMap { kind in all.filter { $0.kind == kind } }
    }

    // MARK: - The decision

    /// THE decision. Pure and total: the same facts always give the same
    /// answer, and every combination of facts gives one. Order: the headers;
    /// the packet pass; whether both decode passes were whole; the picture;
    /// the channel left behind; the sound; a spare sound track; then, for a
    /// pair that plays the same, everything else that differs.
    static func decide(_ facts: Facts) -> Outcome {
        if let verdict = headerVerdict(facts) { return verdict }
        guard let live = liveChannel(for: facts.originalClass), let kept = keptSound(facts),
              let copySound = facts.balanced.sound.first,
              case .success(let pairing) = pairing(original: facts.original.carried,
                                                   balanced: facts.balanced.carried) else {
            return .couldNotCheck("the two files' streams could not be lined up")
        }
        if let verdict = readVerdict(facts.original, read: facts.originalRead, kept: kept, called: "the original")
            ?? readVerdict(facts.balanced, read: facts.balancedRead, kept: copySound, called: "the balanced copy") {
            return verdict
        }
        let streams: [Evidence.Stream]
        switch pictureCheck(facts, pairing: pairing) {
        case .refused(let outcome): return outcome
        case .held(let held): streams = held
        }
        let discarded: Evidence.Discarded?
        switch discardedCheck(facts, kept: kept, liveChannel: live) {
        case .refused(let outcome): return outcome
        case .held(let measured): discarded = measured
        }
        let sound: String
        switch soundCheck(facts) {
        case .refused(let outcome): return outcome
        case .held(let digest): sound = digest
        }
        let spare: [Difference]
        switch spareCheck(facts, kept: kept, streams: streams) {
        case .refused(let outcome): return outcome
        case .held(let dropped): spare = dropped
        }
        let evidence = Evidence(
            streams: streams, originalClass: facts.originalClass, liveChannel: live, soundCodec: kept.codec,
            sampleFormat: kept.sampleFormat, sampleRateHz: kept.sampleRateHz, soundSHA256: sound,
            soundSamples: facts.originalRead?.soundSamples ?? 0,
            soundStartSeconds: Double(facts.originalRead?.soundSegments?.first?.start ?? 0) / Double(kept.sampleRateHz),
            discarded: discarded)
        let differs = differences(facts, pairing: pairing, kept: kept, copySound: copySound, streams: streams, spare: spare)
        return differs.isEmpty ? .proven(evidence) : .sameContent(evidence, differs: differs)
    }

    // MARK: - The log lines (pure; the caller writes them through the one sink)

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

    private static func files(_ original: String, _ balanced: String) -> String {
        "original \(quoted(original)) · balanced copy \(quoted(balanced))"
    }

    private static func evidenceDetail(_ e: Evidence) -> String {
        let streams = e.streams.map { s -> String in
            let packets = s.packetIdentical
                ? "stored packets identical, sha256 \(s.packetSHA256) (\(s.packets))" : "stored packets differ"
            return "picture \(s.originalIndex)→\(s.balancedIndex): \(s.frames) decoded frames, each one's time, duration "
                + "and pixels equal, sha256 \(s.framesSHA256); \(packets)"
        }
        let sound = "sound \(e.soundCodec) \(e.sampleRateHz) Hz: original \(side(e.liveChannel)) = copy left = copy right, "
            + "\(e.soundSamples) samples at the same times, sha256 \(e.soundSHA256)"
        let discarded = e.discarded.map {
            "original \(side($0.channel)): \($0.isDigitalSilence ? "digital silence" : "peak \(level($0.peakDBFS))")"
                + ", not in the copy"
        } ?? "original has one channel, nothing left behind"
        return (streams + [sound, discarded]).joined(separator: "; ")
    }

    /// "[track] the original holds a timecode track".
    static func sentence(_ d: Difference) -> String {
        "[\(d.kind.rawValue)] " + (d.heldBy.map { "\($0.rawValue) holds \(d.what)" } ?? d.what)
    }

    /// The line written BEFORE the files are read.
    static func startLine(original: String, balanced: String) -> String {
        singleLine("balanced copy proof: START — \(files(original, balanced))")
    }

    /// ONE line naming both files, the verdict, the evidence and every
    /// difference. Whatever a file name, a codec name, a tag or a tool's
    /// message holds, the result has no line break and no control character.
    static func logLine(original: String, balanced: String, outcome: Outcome) -> String {
        let head = "balanced copy proof: OUTCOME"
        let pair = files(original, balanced)
        let line: String
        switch outcome {
        case .proven(let e):
            line = "\(head) PROVEN THE SAME — \(pair) — \(evidenceDetail(e)); neither file holds anything else"
        case .sameContent(let e, let differs):
            line = "\(head) SAME CONTENT, DIFFERS IN \(differs.count) — \(pair) — \(evidenceDetail(e)) — differs: "
                + differs.map(sentence).joined(separator: " | ")
        case .notProven(let why):
            line = "\(head) NOT THE SAME — \(pair) — \(why.message)"
        case .couldNotCheck(let reason):
            line = "\(head) COULD NOT CHECK — \(pair) — \(reason)"
        }
        return singleLine(line)
    }
}
