// BalancedCopyProof.swift
// "Does this balanced copy carry everything the original has?" — answered
// from the two files on disk, NOW. READ ONLY: it opens both files for
// reading through ffprobe/ffmpeg and writes nothing, anywhere.
//
// Why it exists: Balance Audio (BalanceAudioJob) writes `<stem>_balanced`
// with the picture stream-copied and the one live channel copied to both
// sides. Such a copy is never byte-equal to its original, so the whole-file
// SHA-256 proof (ContentCopyProof) cannot vouch for it. This is the proof
// that can. It has NO caller yet; nothing is trashed, promoted or stored
// because of it.
//
// PROVEN means ALL of:
//   1. Every non-audio stream of the original (video, timecode/data,
//      subtitles — what the job's `-map 0` carries) is in the copy, same
//      kind and codec, in the same order, and the SHA-256 over that
//      stream's packet payloads is equal (ffmpeg `-c copy -f streamhash`:
//      no decode, timestamps not hashed). The copy may hold ONE stream the
//      original has not: the `tmcd` timecode track the mov muxer makes from
//      DV timecode (BalanceAudioFix.outputStreamMismatch tolerates the same
//      one), and only when the original has no timecode track of its own.
//   2. The original has exactly one audio stream, measured in full by
//      AudioBalanceProbe as leftOnly / rightOnly / mono. The copy has
//      exactly one, 2 channels, same codec, sample format and sample rate.
//      Decoded with no resampling and no format change, the copy's LEFT
//      samples, its RIGHT samples and the original's LIVE channel hash to
//      the same SHA-256 (equal hashes of the raw PCM bytes ⇒ equal sample
//      counts). The channels are picked with `channelmap` (a remap, no
//      arithmetic) — not with the `pan` filter the job renders with.
//   3. The original's audio codec is `pcm_*`. A lossy original is "not
//      proven" by design, before anything is hashed.
// Anything unmeasured is "could not check". Unknown is never proven.
//
// What it does NOT prove (said plainly so no caller assumes it):
//   - timestamps / frame rate (the job's own verification holds duration
//     to 1 s; packet payloads say nothing about timing);
//   - container metadata (creation date, tags) — `-map_metadata 0` is the
//     job's promise, not checked here;
//   - the original's DEAD channel: by the director's definition the copy
//     need not carry it. "Dead" is the analyzer's −60 dBFS floor, not
//     digital silence.
//   - An original with more than one audio stream (12-bit DV, two pairs) is
//     "not proven": the copy drops the silent pair, and this engine does
//     not decide that a dropped stream held nothing.
//
// Shape (the repo's engine split): pure `decide` over measured `Facts`
// (table-tested, no I/O) + one `@concurrent` `measure` that gathers them
// with the app's one process runner (ProcessRunner.runProcess, tools from
// ToolLocator — the same road as AudioBalanceProbe / VerifyAudioProbe).
// (An `enum` with no cases is Swift's namespace ≈ a C++ struct of statics.)
//
// Cost: one levels pass over the original (AudioBalanceProbe.analyze), two
// ffprobe calls, then ONE ffmpeg pass per file that hashes every stream at
// once. Each pass reads the whole container.
//
// Memory: ffmpeg streams and hashes in its own process. This process keeps
// two ffprobe JSON documents (capped 1 MiB each), the stream-hash lines
// (capped 64 KiB) and stderr (ProcessRunner's 256 KiB cap) — worst case
// under 3 MiB, whatever the size of the media.

import Foundation
import os
import VideoScanCore

private let proofLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "balancedCopyProof")

enum BalancedCopyProof {

    // MARK: - Measured facts

    /// One non-audio stream of a file and the SHA-256 of its packets.
    struct CarriedStream: Sendable, Equatable {
        /// Container-wide stream index (what `-map 0:N` addresses).
        var index: Int
        /// ffprobe `codec_type`: "video", "data", "subtitle", "attachment".
        var kind: String
        /// ffprobe `codec_name`; "" when ffprobe names none (a `tmcd` track).
        var codec: String
        /// ffprobe `codec_tag_string` ("tmcd", "apco", …).
        var tag: String
        /// SHA-256 (lowercase hex) over the stream's packet payloads; nil
        /// until the hash pass ran.
        var packetSHA256: String?

        /// The timecode track the mov muxer writes.
        var isTimecodeTrack: Bool { kind == "data" && tag == "tmcd" }
    }

    /// One audio stream as ffprobe states it.
    struct SoundStream: Sendable, Equatable {
        var index: Int
        var codec: String
        /// ffprobe `sample_fmt` — the format ffmpeg DECODES to ("s16",
        /// "s32" for 24-bit PCM, "flt", …).
        var sampleFormat: String
        var sampleRateHz: Int
        var channels: Int
    }

    /// The streams of one file.
    struct FileLayout: Sendable, Equatable {
        var carried: [CarriedStream] = []
        var sound: [SoundStream] = []
    }

    /// Everything `decide` looks at. Built by `measure`; built by hand in
    /// the decision-table tests.
    struct Facts: Sendable, Equatable {
        var original: FileLayout
        var balanced: FileLayout
        /// The analyzer's class for the original's program audio.
        var originalClass: AudioChannelClass
        /// The levels pass covered every channel of every stream
        /// (`AudioBalanceAnalysis.measuredSilent != nil`). False = the class
        /// above is not a measurement.
        var originalMeasuredInFull: Bool
        /// SHA-256 of the original's live channel as raw PCM; nil = not hashed.
        var originalLiveSHA256: String?
        /// SHA-256 of the copy's left / right channel as raw PCM.
        var balancedLeftSHA256: String?
        var balancedRightSHA256: String?
    }

    // MARK: - Outcome

    /// What a PROVEN verdict stands on.
    struct Evidence: Sendable, Equatable {
        struct Stream: Sendable, Equatable {
            var kind: String
            var codec: String
            var originalIndex: Int
            var balancedIndex: Int
            /// The one SHA-256 both files' packets hashed to.
            var packetSHA256: String
        }
        var carried: [Stream]
        /// The copy also holds a muxer-made timecode track.
        var gainedTimecodeTrack: Bool
        var originalClass: AudioChannelClass
        /// 0 = left, 1 = right: the original channel the copy was held to.
        var liveChannel: Int
        var soundCodec: String
        var sampleFormat: String
        var sampleRateHz: Int
        /// The one SHA-256 that the original's live channel, the copy's
        /// left and the copy's right all hashed to.
        var soundSHA256: String
        /// Both files as they were when measured (nil in hand-built facts).
        /// A caller that acts on the proof later must find them unchanged.
        var originalStamp: FileIdentityStamp?
        var balancedStamp: FileIdentityStamp?
    }

    /// Why a copy that WAS measured is not proven.
    /// (≈ a C++ `std::variant` of small structs; `message` is its visitor.
    /// It is an `Error` only so `Result` can carry it; nothing throws it.)
    enum NotProven: Error, Sendable, Equatable {
        /// The original is not one-sided, so no balanced copy stands for it.
        case originalNotOneSided(AudioChannelClass)
        /// The original has 0 or several audio streams.
        case originalSoundTracks(Int)
        /// Lossy source: the balance render re-encoded the sound.
        case soundReencoded(codec: String)
        /// The copy has 0 or several audio streams.
        case balancedSoundTracks(Int)
        /// Codec, sample format, sample rate or channel count is not what a
        /// lossless balanced copy has.
        case soundFormatChanged(String)
        /// A stream is missing from the copy, or the copy has one too many.
        case streamsDiffer(String)
        /// A carried stream's packets are not the original's.
        case carriedStreamDiffers(kind: String, originalIndex: Int, original: String, balanced: String)
        /// The copy's two channels are not the same samples.
        case channelsDiffer(left: String, right: String)
        /// The copy's sound is not the original's live channel.
        case soundDiffers(original: String, balanced: String)

        /// The plain sentence a caller may show or log.
        var message: String { detail + " — the original is kept" }

        private var detail: String {
            switch self {
            case .originalNotOneSided(let c):
                return "the original's sound is not one-sided (\(c.rawValue))"
            case .originalSoundTracks(let n):
                return "the original has \(n) sound tracks, and only one can be held against a balanced copy"
            case .soundReencoded(let codec):
                return "the sound was re-encoded (\(codec.isEmpty ? "unknown codec" : codec))"
            case .balancedSoundTracks(let n):
                return "the balanced copy has \(n) sound tracks, expected exactly 1"
            case .soundFormatChanged(let what):
                return "the balanced copy's sound format is not the original's (\(what))"
            case .streamsDiffer(let what):
                return "the balanced copy does not hold the original's streams (\(what))"
            case .carriedStreamDiffers(let kind, let index, let original, let balanced):
                return "\(kind) stream \(index) is not the original's, packet for packet "
                    + "(sha256 \(BalancedCopyProof.short(original)) ≠ \(BalancedCopyProof.short(balanced)))"
            case .channelsDiffer(let left, let right):
                return "the balanced copy's left and right channels are not the same sound "
                    + "(sha256 \(BalancedCopyProof.short(left)) ≠ \(BalancedCopyProof.short(right)))"
            case .soundDiffers(let original, let balanced):
                return "the balanced copy's sound is not the original's live channel, sample for sample "
                    + "(sha256 \(BalancedCopyProof.short(original)) ≠ \(BalancedCopyProof.short(balanced)))"
            }
        }
    }

    enum Outcome: Sendable, Equatable {
        case proven(Evidence)
        /// Measured, and the copy does not stand for the original.
        case notProven(NotProven)
        /// Not measured (missing file, tool failed, unreadable, stopped).
        /// Never proven; the reason is a plain sentence.
        case couldNotCheck(String)

        var isProven: Bool { if case .proven = self { return true }; return false }
    }

    // MARK: - Pure rules

    /// SHA-256 of zero bytes: what a stream that delivered nothing hashes to.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// First 12 hex digits, for reasons (the full digest is in Evidence).
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }

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

    /// The original's side of the sound rules: one-sided, one track, PCM.
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
        return nil
    }

    /// The copy's side: one track, two channels, the original's format.
    /// Call after `originalSoundVerdict` returned nil.
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
        return nil
    }

    /// Everything that can be decided BEFORE a hash is computed. nil = the
    /// layouts allow a proof; go on and hash. `measure` asks this first so a
    /// lossy or mis-shaped pair never costs two whole-file reads.
    static func layoutVerdict(_ facts: Facts) -> Outcome? {
        if let verdict = originalSoundVerdict(facts) ?? balancedSoundVerdict(facts) { return verdict }
        if case .failure(let why) = pairing(original: facts.original.carried, balanced: facts.balanced.carried) {
            return .notProven(why)
        }
        return nil
    }

    /// A digest that can be compared: present, and not the hash of nothing
    /// (a stream that delivered no bytes proves nothing about itself).
    static func comparable(_ digest: String?) -> String? {
        guard let digest, digest.count == 64, digest != emptySHA256 else { return nil }
        return digest
    }

    /// `carriedEvidence`'s answer: the streams held, or the outcome that ends
    /// the decision.
    enum CarriedCheck: Sendable, Equatable {
        case held([Evidence.Stream])
        case refused(Outcome)
    }

    /// Hold each paired stream's packets against the original's.
    static func carriedEvidence(_ facts: Facts, pairing: Pairing) -> CarriedCheck {
        var out: [Evidence.Stream] = []
        for pair in pairing.pairs {
            let original = facts.original.carried[pair.original]
            let copy = facts.balanced.carried[pair.balanced]
            guard let a = comparable(original.packetSHA256), let b = comparable(copy.packetSHA256) else {
                return .refused(.couldNotCheck("\(original.kind) stream \(original.index) gave no packets to compare"))
            }
            guard a == b else {
                return .refused(.notProven(.carriedStreamDiffers(
                    kind: original.kind, originalIndex: original.index, original: a, balanced: b)))
            }
            out.append(Evidence.Stream(kind: original.kind, codec: original.codec, originalIndex: original.index,
                                       balancedIndex: copy.index, packetSHA256: a))
        }
        return .held(out)
    }

    /// THE decision. Pure: the same facts always give the same answer.
    /// Order: what the layouts already rule out, then the picture, then the
    /// copy's two channels against each other, then against the original.
    static func decide(_ facts: Facts) -> Outcome {
        if let verdict = layoutVerdict(facts) { return verdict }
        guard let live = liveChannel(for: facts.originalClass), let sound = facts.original.sound.first,
              case .success(let pairing) = pairing(original: facts.original.carried,
                                                   balanced: facts.balanced.carried) else {
            return .couldNotCheck("the two files' streams could not be lined up")
        }
        let carried: [Evidence.Stream]
        switch carriedEvidence(facts, pairing: pairing) {
        case .refused(let outcome): return outcome
        case .held(let streams): carried = streams
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
            sampleFormat: sound.sampleFormat, sampleRateHz: sound.sampleRateHz, soundSHA256: source))
    }

    // MARK: - The log line (pure; the future caller writes it)

    /// One line naming both files, the verdict, and the hashes compared.
    static func logLine(original: String, balanced: String, outcome: Outcome) -> String {
        let files = "original \"\(original)\" · balanced copy \"\(balanced)\""
        switch outcome {
        case .proven(let e):
            let side = e.liveChannel == 0 ? "left" : "right"
            let streams = e.carried
                .map { "\($0.kind) \($0.originalIndex)→\($0.balancedIndex) sha256 \($0.packetSHA256)" }
            let sound = "sound \(e.soundCodec) \(e.sampleRateHz) Hz: original \(side) = copy left = copy right "
                + "sha256 \(e.soundSHA256)"
            let timecode = e.gainedTimecodeTrack ? ["copy has a muxer-made timecode track"] : []
            return "balanced copy proof: PROVEN — \(files) — "
                + (streams + [sound] + timecode).joined(separator: "; ")
        case .notProven(let why):
            return "balanced copy proof: NOT PROVEN — \(files) — \(why.message)"
        case .couldNotCheck(let reason):
            return "balanced copy proof: COULD NOT CHECK — \(files) — \(reason)"
        }
    }

    // MARK: - ffprobe layout (pure parse)

    /// ffprobe request for the stream list of one file.
    static func layoutArgs(input: String) -> [String] {
        ["-v", "error",
         "-show_entries", "stream=index,codec_type,codec_name,codec_tag_string,channels,sample_rate,sample_fmt",
         "-of", "json", input]
    }

    private struct ProbedStream: Decodable {
        let index: Int?
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let channels: Int?
        let sample_rate: String?
        let sample_fmt: String?
    }
    private struct ProbeReport: Decodable { let streams: [ProbedStream]? }

    /// Decode ffprobe's JSON into a layout; nil when it is not that JSON or
    /// lists no stream at all (not a media file).
    static func layout(fromProbeJSON data: Data) -> FileLayout? {
        guard let report = try? JSONDecoder().decode(ProbeReport.self, from: data),
              let streams = report.streams, !streams.isEmpty else { return nil }
        var layout = FileLayout()
        for (position, s) in streams.enumerated() {
            let index = s.index ?? position
            if s.codec_type == "audio" {
                layout.sound.append(SoundStream(
                    index: index, codec: s.codec_name ?? "", sampleFormat: s.sample_fmt ?? "",
                    sampleRateHz: s.sample_rate.flatMap { Int($0) } ?? 0, channels: s.channels ?? 0))
            } else {
                layout.carried.append(CarriedStream(
                    index: index, kind: s.codec_type ?? "", codec: s.codec_name ?? "",
                    tag: s.codec_tag_string ?? "", packetSHA256: nil))
            }
        }
        return layout
    }

    // MARK: - ffmpeg hash pass (pure builders + parse)

    /// Filter graph that picks ONE channel of the original's audio stream.
    /// `channelmap` moves samples; it never does arithmetic on them.
    static func originalSoundFilter(streamIndex: Int, liveChannel: Int) -> String {
        "[0:\(streamIndex)]channelmap=map=\(liveChannel):channel_layout=mono[live]"
    }

    /// Filter graph that splits the copy's audio into its two channels.
    static func balancedSoundFilter(streamIndex: Int) -> String {
        "[0:\(streamIndex)]asplit[a][b];"
            + "[a]channelmap=map=0:channel_layout=mono[left];"
            + "[b]channelmap=map=1:channel_layout=mono[right]"
    }

    /// One pass that hashes every carried stream's packets (`-c copy`) and
    /// each named filter output as raw PCM (`-c:a <hashCodec>`, no `-ar`, so
    /// nothing is resampled). The streamhash muxer prints one line per
    /// OUTPUT stream, in map order: carried streams first, then the sound.
    /// `inputArgs` are demuxer options (the raw-DV `-r`), before `-i`.
    static func hashArgs(input: String, inputArgs: [String], carriedIndices: [Int], soundFilter: String,
                         soundOutputs: [String], hashCodec: String) -> [String] {
        var args = ["-v", "error", "-nostdin"] + inputArgs + ["-i", input, "-filter_complex", soundFilter]
        for index in carriedIndices { args += ["-map", "0:\(index)"] }
        for output in soundOutputs { args += ["-map", "[\(output)]"] }
        return args + ["-c", "copy", "-c:a", hashCodec, "-f", "streamhash", "-hash", "sha256", "-"]
    }

    /// The digests the streamhash muxer printed ("0,v,SHA256=<hex>"), by
    /// output stream number. nil unless there are exactly `expected` lines,
    /// numbered 0..<expected, each a 64-digit hex SHA-256.
    static func streamHashes(fromStdout stdout: String, expected: Int) -> [String]? {
        var byStream: [Int: String] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", maxSplits: 2).map(String.init)
            guard fields.count == 3, let number = Int(fields[0]), fields[2].hasPrefix("SHA256="),
                  byStream[number] == nil else { return nil }
            let digest = String(fields[2].dropFirst("SHA256=".count)).lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
            byStream[number] = digest
        }
        guard expected > 0, byStream.count == expected else { return nil }
        let ordered = (0..<expected).compactMap { byStream[$0] }
        return ordered.count == expected ? ordered : nil
    }

    // MARK: - Measurement (I/O, read only)

    /// The two tools. `located` is production; a test points one at
    /// /usr/bin/false to see the failure path.
    struct Tools: Sendable {
        var ffmpeg: String
        var ffprobe: String
        static var located: Tools { Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: ToolLocator.ffprobePath) }
    }

    /// A measurement step's failure, already in the caller's words.
    private struct Unchecked: Error { let reason: String }

    /// Measure both files and decide. Never throws: every failure is an
    /// `Outcome` (`couldNotCheck` when nothing could be measured).
    ///
    /// `@concurrent`: runs on the global executor — this repo's Approachable
    /// Concurrency would otherwise run a `nonisolated async` on the CALLER's
    /// actor. (For Rick: ≈ posting the work to a thread pool instead of
    /// running it on the caller's thread.)
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func measure(original: String, balanced: String, tools: Tools = .located,
                        control: ProcessControl? = nil) async -> Outcome {
        do {
            return try await measured(original: original, balanced: balanced, tools: tools, control: control)
        } catch let unchecked as Unchecked {
            proofLog.notice("proof could not check \((original as NSString).lastPathComponent, privacy: .public) ↔ \((balanced as NSString).lastPathComponent, privacy: .public): \(unchecked.reason, privacy: .public)")
            return .couldNotCheck(unchecked.reason)
        } catch {
            return .couldNotCheck("the check was stopped")
        }
    }

    private static func measured(original: String, balanced: String, tools: Tools,
                                 control: ProcessControl?) async throws -> Outcome {
        let stamps = try fileStamps(original: original, balanced: balanced)
        guard FileManager.default.isExecutableFile(atPath: tools.ffmpeg),
              FileManager.default.isExecutableFile(atPath: tools.ffprobe) else {
            throw Unchecked(reason: "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }
        let analysis: AudioBalanceAnalysis
        do {
            analysis = try await AudioBalanceProbe.analyze(path: original, control: control)
        } catch AudioBalanceProbeError.noAudioStream {
            return .notProven(.originalSoundTracks(0))
        } catch let error as AudioBalanceProbeError {
            throw Unchecked(reason: "the original's sound could not be measured — \(error.localizedDescription)")
        }
        var facts = Facts(
            original: try await layout(of: original, called: "the original", tools: tools, control: control),
            balanced: try await layout(of: balanced, called: "the balanced copy", tools: tools, control: control),
            originalClass: analysis.classification,
            originalMeasuredInFull: analysis.measuredSilent != nil)
        if let verdict = layoutVerdict(facts) { return verdict }
        guard let live = liveChannel(for: facts.originalClass), let sourceSound = facts.original.sound.first,
              let copySound = facts.balanced.sound.first,
              let codec = hashCodec(forSampleFormat: sourceSound.sampleFormat) else {
            throw Unchecked(reason: "the two files' streams could not be lined up")
        }

        let originalHashes = try await hashes(
            of: original, called: "the original", carried: facts.original.carried.map(\.index),
            inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape),
            soundFilter: originalSoundFilter(streamIndex: sourceSound.index, liveChannel: live),
            soundOutputs: ["live"], hashCodec: codec, tools: tools, control: control)
        let balancedHashes = try await hashes(
            of: balanced, called: "the balanced copy", carried: facts.balanced.carried.map(\.index),
            inputArgs: [], soundFilter: balancedSoundFilter(streamIndex: copySound.index),
            soundOutputs: ["left", "right"], hashCodec: codec, tools: tools, control: control)
        for i in facts.original.carried.indices { facts.original.carried[i].packetSHA256 = originalHashes[i] }
        for i in facts.balanced.carried.indices { facts.balanced.carried[i].packetSHA256 = balancedHashes[i] }
        facts.originalLiveSHA256 = originalHashes[facts.original.carried.count]
        facts.balancedLeftSHA256 = balancedHashes[facts.balanced.carried.count]
        facts.balancedRightSHA256 = balancedHashes[facts.balanced.carried.count + 1]

        // Both files must be the files that were opened at the start: a
        // file rewritten or swapped mid-measurement was not measured.
        let after = try fileStamps(original: original, balanced: balanced)
        guard stamps[0].describesSameFile(now: after[0], volume: .sameOperation),
              stamps[1].describesSameFile(now: after[1], volume: .sameOperation) else {
            throw Unchecked(reason: "a file changed while it was being checked")
        }
        let outcome = decide(facts)
        guard case .proven(var evidence) = outcome else { return outcome }
        evidence.originalStamp = stamps[0]
        evidence.balancedStamp = stamps[1]
        return .proven(evidence)
    }

    /// Both files' identity stamps, [original, balanced]: each a readable
    /// regular file, and not one file under two names.
    private static func fileStamps(original: String, balanced: String) throws -> [FileIdentityStamp] {
        guard isRegularFile(original), let a = FileIdentityStamp.capture(path: original) else {
            throw Unchecked(reason: "the original is not on disk, or cannot be read")
        }
        guard isRegularFile(balanced), let b = FileIdentityStamp.capture(path: balanced) else {
            throw Unchecked(reason: "the balanced copy is not on disk, or cannot be read")
        }
        // Two stats of one operation (the repo's one stamp comparison): a
        // hard link or a symlink to the original is the original.
        guard !a.describesSameFile(now: b, volume: .sameOperation) else {
            throw Unchecked(reason: "the original and the balanced copy are the same file")
        }
        return [a, b]
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func layout(of path: String, called name: String, tools: Tools,
                               control: ProcessControl?) async throws -> FileLayout {
        let result = await ProcessRunner.runProcess(
            executable: tools.ffprobe, arguments: layoutArgs(input: path),
            stdoutLimitBytes: 1 << 20, deadlineSeconds: 60, control: control)
        try Task.checkCancellation()
        guard result.exitCode == 0, let data = result.stdout?.data(using: .utf8),
              let layout = layout(fromProbeJSON: data) else {
            throw Unchecked(reason: "\(name) could not be read as media (ffprobe status \(result.exitCode))")
        }
        return layout
    }

    /// One hash pass over one file: the carried streams' digests in order,
    /// then one per sound output. The deadline is the levels pass's (it
    /// scales with the file's size — both read the whole container).
    private static func hashes(of path: String, called name: String, carried: [Int], inputArgs: [String],
                               soundFilter: String, soundOutputs: [String], hashCodec: String,
                               tools: Tools, control: ProcessControl?) async throws -> [String] {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let deadline = AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes)
        let result = await ProcessRunner.runProcess(
            executable: tools.ffmpeg,
            arguments: hashArgs(input: path, inputArgs: inputArgs, carriedIndices: carried,
                                soundFilter: soundFilter, soundOutputs: soundOutputs, hashCodec: hashCodec),
            stdoutLimitBytes: 1 << 16, deadlineSeconds: deadline, control: control)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            if result.timedOut {
                throw Unchecked(reason: "reading \(name) ran out of time after \(Int(deadline)) seconds")
            }
            let tail = result.stderr.split(separator: "\n").suffix(2).joined(separator: " · ")
            throw Unchecked(reason: "\(name) could not be read to the end (ffmpeg status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)"))")
        }
        guard let digests = streamHashes(fromStdout: result.stdout ?? "",
                                         expected: carried.count + soundOutputs.count) else {
            throw Unchecked(reason: "\(name) did not give a hash for every stream")
        }
        return digests
    }
}
