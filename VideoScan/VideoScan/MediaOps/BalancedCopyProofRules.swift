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
    static func length(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return String(format: "%.3f s", seconds) }
        let whole = Int(seconds.rounded())
        let (h, m, s) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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

    /// Which copy stream answers for which original stream. Positions are
    /// into `original.carried` / `balanced.carried`.
    struct Pairing: Sendable, Equatable {
        struct Pair: Sendable, Equatable {
            var original: Int
            var balanced: Int
        }
        /// Picture streams, in order.
        var pictures: [Pair]
        /// Timecode / text / data tracks both files have.
        var others: [Pair]
        /// Such tracks only one file has.
        var onlyInOriginal: [Int]
        var onlyInBalanced: [Int]
    }

    /// Pair the non-audio streams. Pictures pair in order and their number
    /// must agree — a picture more or less is not the same content. Every
    /// other track pairs with the first unused track of the same kind,
    /// codec and tag; what is left over on either side is a named difference.
    static func pairing(original: [CarriedStream], balanced: [CarriedStream]) -> Result<Pairing, NotProven> {
        let ours = original.indices.filter { original[$0].isPicture }
        let theirs = balanced.indices.filter { balanced[$0].isPicture }
        guard ours.count == theirs.count else {
            return .failure(.streamsDiffer(
                "the original has \(ours.count) picture streams, the balanced copy \(theirs.count)"))
        }
        var out = Pairing(pictures: zip(ours, theirs).map { Pairing.Pair(original: $0, balanced: $1) },
                          others: [], onlyInOriginal: [], onlyInBalanced: [])
        var unused = balanced.indices.filter { !balanced[$0].isPicture }
        for o in original.indices where !original[o].isPicture {
            let like = unused.firstIndex {
                balanced[$0].kind == original[o].kind && balanced[$0].codec == original[o].codec
                    && balanced[$0].tag == original[o].tag
            }
            if let like {
                out.others.append(Pairing.Pair(original: o, balanced: unused.remove(at: like)))
            } else {
                out.onlyInOriginal.append(o)
            }
        }
        out.onlyInBalanced = unused
        return .success(out)
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

    /// What the packet pass decides: every carried stream was counted, and a
    /// timecode / text / data track both files have is the same packet for
    /// packet (it is not decoded, so its packets are all the proof there is).
    /// A PICTURE whose packets differ is not refused here: its decoded
    /// frames decide, and the difference is named.
    static func packetVerdict(_ facts: Facts, pairing: Pairing) -> Outcome? {
        for pair in pairing.pictures + pairing.others {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            let name = "\(original.kind) stream \(original.index)"
            guard let a = packets(of: original), let b = packets(of: copy) else {
                return .couldNotCheck("\(name) gave no packets to compare")
            }
            guard !original.isPicture else { continue }
            // Not decoded here, so nothing answers for its configuration but
            // the configuration itself (a subtitle's styles are in its extradata).
            guard original.configuration == copy.configuration else {
                return .notProven(.carriedStreamDiffers(kind: original.kind, originalIndex: original.index,
                                                        "its codec configuration is not the original's"))
            }
            guard a.count == b.count else {
                return .notProven(.carriedStreamDiffers(kind: original.kind, originalIndex: original.index,
                                                        "\(a.count) packets, the balanced copy \(b.count)"))
            }
            guard a.bytes == b.bytes else {
                return .notProven(.carriedStreamDiffers(kind: original.kind, originalIndex: original.index,
                                                        "sha256 \(short(a.bytes)) ≠ \(short(b.bytes))"))
            }
            guard a.times == b.times else {
                return .notProven(.carriedStreamDiffers(kind: original.kind, originalIndex: original.index,
                                                        "its packets are not at the original's times"))
            }
        }
        return nil
    }

    // MARK: - The decode pass: was the read whole

    /// One decode pass must have read, of every stream it decoded, the
    /// packets the packet pass listed, with no decode error; ffmpeg must
    /// have muxed exactly the frames folded here; and each decoded stream's
    /// length must be the length its header states, where it states one
    /// (header, WHAT PLAYS 5). A short read is never agreement.
    static func readVerdict(_ file: FileLayout, read: ReadReport?, kept: SoundStream?, called name: String) -> Outcome? {
        guard let read else { return .couldNotCheck("\(name)'s decode pass gave no account of what it read") }
        let decoded = file.pictures.map { ($0.index, $0.packets) } + file.sound.map { ($0.index, $0.packets) }
        for (index, expected) in decoded {
            guard let expected, let got = read.streams[index] else {
                return .couldNotCheck("\(name) was not read to the end (stream \(index): packets not counted)")
            }
            guard got.packets == expected else {
                return .couldNotCheck("\(name) was not read to the end (stream \(index): \(got.packets) of \(expected) packets)")
            }
            guard got.decodeErrors == 0 else {
                return .couldNotCheck("\(name) did not decode cleanly (stream \(index))")
            }
        }
        guard !read.folded.isEmpty, read.muxed == read.folded else {
            return .couldNotCheck("\(name)'s decoded frames did not all arrive (ffmpeg wrote \(read.muxed.values.reduce(0, +)), "
                + "\(read.folded.values.reduce(0, +)) were read)")
        }
        for picture in file.pictures {
            guard let played = read.pictures[picture.index], played.frames > 0 else {
                return .couldNotCheck("\(name)'s picture stream \(picture.index) gave no frames")
            }
            if let stated = picture.statedSeconds,
               abs(played.endSeconds - played.firstSeconds - stated) > picture.timingSlackSeconds {
                return .couldNotCheck("\(name) was not read to the end (picture stream \(picture.index): "
                    + "\(length(played.endSeconds - played.firstSeconds)) decoded, \(length(stated)) stated)")
            }
        }
        guard let kept, let samples = read.soundSamples, samples > 0 else {
            return .couldNotCheck("\(name)'s sound gave no samples")
        }
        if let stated = kept.statedSeconds,
           abs(Double(samples) / Double(kept.sampleRateHz) - stated) > kept.statedLengthSlackSeconds {
            return .couldNotCheck("\(name) was not read to the end (\(samples) sound samples decoded, "
                + "\(length(stated)) stated)")
        }
        return nil
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
                kind: original.kind, codec: original.codec, originalIndex: original.index, balancedIndex: copy.index,
                frames: a.frames, framesSHA256: ours,
                packetIdentical: stored.count == copied.count && stored.bytes == copied.bytes && stored.times == copied.times,
                packetSHA256: stored.bytes, packets: stored.count))
        }
        for pair in pairing.others {
            let original = facts.original.carried[pair.original]
            guard let stored = packets(of: original) else {
                return .refused(.couldNotCheck("\(original.kind) stream \(original.index) gave no packets to compare"))
            }
            out.append(Evidence.Stream(
                kind: original.kind, codec: original.codec, originalIndex: original.index,
                balancedIndex: facts.balanced.carried[pair.balanced].index, frames: nil, framesSHA256: nil,
                packetIdentical: true, packetSHA256: stored.bytes, packets: stored.count))
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
            return .refused(.notProven(.soundPlacementDiffers(
                "the original's sound plays in \(segments.count) unbroken runs, the balanced copy's in \(copied.count)")))
        }
        for (i, (a, b)) in zip(segments, copied).enumerated()
        where a.samples != b.samples || abs(a.start - b.start) > Int64(soundTimingToleranceSamples) {
            return .refused(.notProven(.soundPlacementDiffers(
                "run \(i + 1): \(a.samples) samples from sample time \(a.start), "
                + "in the balanced copy \(b.samples) from \(b.start)")))
        }
        return .held(source)
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
            let pictures = streams.filter { $0.kind == "video" }
            guard !pictures.isEmpty, pictures.allSatisfy({ $0.codec == "dvvideo" && $0.packetIdentical }) else {
                return .refused(.notProven(.spareSoundTrack(
                    "stream \(spare.index) is silent, but the picture is not DV carried bit for bit")))
            }
            out.append(Difference(
                kind: .track, heldOnlyBy: .original,
                what: "a second sound track (stream \(spare.index), \(spare.channels) channels), measured silent: "
                    + (peak == -.infinity ? "digital silence" : "peak \(level(peak))")))
        }
        return .held(out)
    }

    // MARK: - Named differences

    /// How long a file's stream STORES beyond what it plays. 0 = nothing
    /// hidden, or the container has no edit lists.
    private static func hidden(stored: Double?, played: Double) -> Double {
        guard let stored, stored - played > timingSlackCeilingSeconds else { return 0 }
        return stored - played
    }

    /// Media a file STORES and an edit list does not play, one difference per
    /// file that has any. The hidden part is not decoded and (the packet
    /// pass reads through the edit list) not hashed, so two files that hide
    /// the same LENGTH are not known to hide the same media: each is named
    /// as holding its own (Codex #307-2).
    private static func hiddenDifferences(_ thing: String, originalStored: Double?, originalPlayed: Double,
                                          copyStored: Double?, copyPlayed: Double) -> [Difference] {
        let sides: [(Difference.Holder, Double?, Double)] = [(.original, originalStored, originalPlayed),
                                                             (.balancedCopy, copyStored, copyPlayed)]
        return sides.compactMap { holder, stored, played in
            guard let stored, hidden(stored: stored, played: played) > 0 else { return nil }
            return Difference(kind: .playback, heldOnlyBy: holder,
                              what: "stored \(thing) an edit list does not play: \(length(stored)) stored, \(length(played)) "
                                + "played — the hidden part is not compared with the other file")
        }
    }

    /// Every "key=value" in these tag sets.
    private static func pairs(_ tags: [[String: String]]) -> Set<String> {
        Set(tags.flatMap { $0.map { "\($0.key)=\($0.value)" } })
    }

    /// Where the two files' tags are compared.
    private struct TagTally {
        var found: [Difference.Holder: [String]] = [:]

        /// Tags one file has and the other has not, or states differently.
        /// `scope` names where they are ("", "stream 1 "). A tag is not
        /// missing when the other file states it with the SAME value across
        /// the container/track line — `originalHas` / `copyHas`: for the
        /// container's tags, what the other file's tracks state; for a
        /// track's, what the other file's container states (raw DV's
        /// timecode is the container's, QuickTime's the track's). One track
        /// never answers for another (Codex #308-4).
        mutating func compare(_ original: [String: String], _ copy: [String: String], scope: String,
                              originalHas: Set<String>, copyHas: Set<String>) {
            for key in Set(original.keys).union(copy.keys).sorted() {
                switch (original[key], copy[key]) {
                case (let a?, let b?):
                    // Another value: each file holds one the other has not.
                    if a != b {
                        found[.original, default: []].append("\(scope)\(key) (\"\(a.prefix(40))\")")
                        found[.balancedCopy, default: []].append("\(scope)\(key) (\"\(b.prefix(40))\")")
                    }
                case (let a?, nil): if !copyHas.contains("\(key)=\(a)") { found[.original, default: []].append(scope + key) }
                case (nil, let b?): if !originalHas.contains("\(key)=\(b)") { found[.balancedCopy, default: []].append(scope + key) }
                case (nil, nil): break
                }
            }
        }
    }

    /// "picture stream 0 (the balanced copy only: default)" — nil when both
    /// tracks have the same flags set.
    private static func flagPhrase(_ thing: String, _ original: Set<String>, _ copy: Set<String>) -> String? {
        guard original != copy else { return nil }
        let ours = original.subtracting(copy).sorted(), theirs = copy.subtracting(original).sorted()
        let said = [ours.isEmpty ? nil : "the original only: \(ours.joined(separator: ", "))",
                    theirs.isEmpty ? nil : "the balanced copy only: \(theirs.joined(separator: ", "))"]
        return "\(thing) (\(said.compactMap { $0 }.joined(separator: "; ")))"
    }

    private static func named(_ tags: [String]) -> String {
        let shown = tags.prefix(namedTagLimit).joined(separator: ", ")
        return tags.count > namedTagLimit ? "\(shown) +\(tags.count - namedTagLimit) more" : shown
    }

    /// Tracks only one file has, and the container.
    private static func trackDifferences(_ facts: Facts, pairing: Pairing) -> [Difference] {
        var out = pairing.onlyInOriginal.map {
            Difference(kind: .track, heldOnlyBy: .original, what: describe(facts.original.carried[$0]))
        }
        out += pairing.onlyInBalanced.map {
            Difference(kind: .track, heldOnlyBy: .balancedCopy, what: describe(facts.balanced.carried[$0]))
        }
        if facts.original.container != facts.balanced.container {
            func word(_ file: FileLayout) -> String { file.container.split(separator: ",").first.map(String.init) ?? "unknown" }
            out.append(Difference(kind: .container, heldOnlyBy: nil,
                                  what: "the original is a \(word(facts.original)) file, the balanced copy a \(word(facts.balanced)) file"))
        }
        return out
    }

    /// How one paired picture is STORED differently: codec or packets, then
    /// decoder configuration, then media an edit list hides.
    private static func storageDifferences(_ facts: Facts, original: CarriedStream, copy: CarriedStream,
                                           held: Evidence.Stream) -> [Difference] {
        var out: [Difference] = []
        let every = "every decoded frame is the same"
        if original.codec != copy.codec {
            out.append(Difference(kind: .encoding, heldOnlyBy: nil,
                                  what: "picture stream \(original.index) is stored as \(original.codec) in the original "
                                    + "and as \(copy.codec) in the balanced copy; \(every)"))
        } else if !held.packetIdentical {
            out.append(Difference(kind: .encoding, heldOnlyBy: nil,
                                  what: "picture stream \(original.index) (\(original.codec)) is not stored in the same "
                                    + "packets (\(original.packets ?? 0) in the original, \(copy.packets ?? 0) in the "
                                    + "balanced copy); \(every)"))
        }
        if original.configuration.extradataSHA256 != copy.configuration.extradataSHA256 {
            out.append(Difference(kind: .decoderConfiguration, heldOnlyBy: nil,
                                  what: "picture stream \(original.index)'s decoder configuration (extradata) is "
                                    + "written differently; \(every)"))
        }
        if let a = facts.originalRead?.pictures[original.index], let b = facts.balancedRead?.pictures[copy.index] {
            out += hiddenDifferences("picture", originalStored: original.storedSeconds,
                                     originalPlayed: a.endSeconds - a.firstSeconds,
                                     copyStored: copy.storedSeconds, copyPlayed: b.endSeconds - b.firstSeconds)
        }
        return out
    }

    /// Sound an edit list hides, and track flags set in one file only.
    private static func soundPlaybackDifferences(_ facts: Facts, pairing: Pairing, kept: SoundStream,
                                                 copySound: SoundStream) -> [Difference] {
        var out = hiddenDifferences(
            "sound", originalStored: kept.storedSeconds,
            originalPlayed: Double(facts.originalRead?.soundSamples ?? 0) / Double(max(kept.sampleRateHz, 1)),
            copyStored: copySound.storedSeconds,
            copyPlayed: Double(facts.balancedRead?.soundSamples ?? 0) / Double(max(copySound.sampleRateHz, 1)))
        // A paired text/data track is not decoded: what it plays is what its header states (Codex #308-2).
        for pair in pairing.others {
            let (original, copy) = (facts.original.carried[pair.original], facts.balanced.carried[pair.balanced])
            out += hiddenDifferences("\(original.kind) stream \(original.index)", originalStored: original.storedSeconds,
                                     originalPlayed: original.statedSeconds ?? original.storedSeconds ?? 0,
                                     copyStored: copy.storedSeconds,
                                     copyPlayed: copy.statedSeconds ?? copy.storedSeconds ?? 0)
        }
        var flags = (pairing.pictures + pairing.others).compactMap { pair -> String? in
            let original = facts.original.carried[pair.original]
            return flagPhrase("\(original.isPicture ? "picture" : original.kind) stream \(original.index)", original.flags,
                              facts.balanced.carried[pair.balanced].flags)
        }
        if let phrase = flagPhrase("the sound", kept.flags, copySound.flags) { flags.append(phrase) }
        if !flags.isEmpty {
            out.append(Difference(kind: .playback, heldOnlyBy: nil, what: "track flags differ: \(flags.joined(separator: "; "))"))
        }
        return out
    }

    /// Chapter marks and tags one file has and the other has not.
    private static func metadataDifferences(_ facts: Facts, pairing: Pairing, kept: SoundStream,
                                            copySound: SoundStream) -> [Difference] {
        var out: [Difference] = []
        // A chapter mark is one file's alone unless the other has the same mark (times and title).
        let sides: [(Difference.Holder, [String], [String])] = [(.original, facts.original.chapters, facts.balanced.chapters),
                                                               (.balancedCopy, facts.balanced.chapters, facts.original.chapters)]
        for (holder, mine, others) in sides {
            let alone = mine.filter { !others.contains($0) }
            if !alone.isEmpty {
                out.append(Difference(kind: .metadata, heldOnlyBy: holder,
                                      what: "\(alone.count) chapter marks the other file does not have: \(named(alone))"))
            }
        }
        var tags = TagTally()
        func tracks(_ file: FileLayout) -> Set<String> { pairs(file.carried.map(\.tags) + file.sound.map(\.tags)) }
        tags.compare(facts.original.tags, facts.balanced.tags, scope: "",
                     originalHas: tracks(facts.original), copyHas: tracks(facts.balanced))
        let (ours, theirs) = (pairs([facts.original.tags]), pairs([facts.balanced.tags]))
        tags.compare(kept.tags, copySound.tags, scope: "sound ", originalHas: ours, copyHas: theirs)
        for pair in pairing.pictures + pairing.others {
            let original = facts.original.carried[pair.original]
            tags.compare(original.tags, facts.balanced.carried[pair.balanced].tags, scope: "stream \(original.index) ",
                         originalHas: ours, copyHas: theirs)
        }
        if let only = tags.found[.original] {
            out.append(Difference(kind: .metadata, heldOnlyBy: .original, what: "tags the balanced copy does not have: \(named(only))"))
        }
        if let only = tags.found[.balancedCopy] {
            out.append(Difference(kind: .metadata, heldOnlyBy: .balancedCopy, what: "tags the original does not have: \(named(only))"))
        }
        return out
    }

    /// Everything that differs between two files that PLAY the same, each
    /// in plain words, with the file that holds what the other does not.
    /// Order: tracks, container, encoding, decoder configuration, playback
    /// instructions, metadata.
    static func differences(_ facts: Facts, pairing: Pairing, kept: SoundStream, copySound: SoundStream,
                            streams: [Evidence.Stream], spare: [Difference]) -> [Difference] {
        let stored = zip(pairing.pictures, streams).flatMap {
            storageDifferences(facts, original: facts.original.carried[$0.original],
                               copy: facts.balanced.carried[$0.balanced], held: $1)
        }
        let order: [Difference.Kind] = [.encoding, .decoderConfiguration, .playback]
        return spare + trackDifferences(facts, pairing: pairing)
            + order.flatMap { kind in stored.filter { $0.kind == kind } }
            + soundPlaybackDifferences(facts, pairing: pairing, kept: kept, copySound: copySound)
            + metadataDifferences(facts, pairing: pairing, kept: kept, copySound: copySound)
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
        if let verdict = packetVerdict(facts, pairing: pairing)
            ?? readVerdict(facts.original, read: facts.originalRead, kept: kept, called: "the original")
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
            guard let frames = s.frames, let digest = s.framesSHA256 else {
                return "\(s.kind) \(s.originalIndex)→\(s.balancedIndex): \(packets)"
            }
            return "picture \(s.originalIndex)→\(s.balancedIndex): \(frames) decoded frames, each one's time, duration "
                + "and pixels equal, sha256 \(digest); \(packets)"
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
        "[\(d.kind.rawValue)] " + (d.heldOnlyBy.map { "\($0.rawValue) holds \(d.what)" } ?? d.what)
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
            line = "\(head) PROVEN THE SAME — \(pair) — \(evidenceDetail(e)); nothing else differs"
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
