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
// The rule behind every rule: a false PROVEN can cost a family recording;
// "not proven" and "could not check" only cost keeping the original. Every
// doubt resolves to one of those two.
//
// PROVEN means ALL of:
//   1. STREAMS, PACKET BY PACKET. Every non-audio stream of the original
//      (video, timecode/data, subtitles — what the job's `-map 0` carries)
//      is in the copy, same kind and codec, in the same order, with the
//      same number of packets, and for packet i of each: the same
//      presentation time, the same duration, the same size and the same
//      SHA-256 of its payload (ffprobe `-show_packets -show_data_hash`,
//      folded line by line into two running digests per stream). Times
//      are compared as exact reduced fractions (pts × time_base), so a
//      container that re-expresses the time base still agrees: measured
//      2026-11-17, every job output of the matrix is equal to the tick,
//      raw DV (1/60000) → QuickTime (1/30000) included — there is no
//      tolerance. That one comparison is the picture's whole timing: its
//      start, length, frame rate, an edit list, a re-time in the middle.
//      The copy may hold ONE stream the original has not: the `tmcd`
//      timecode track the mov muxer makes from DV timecode, and only when
//      the original has no timecode track.
//   2. DECODER AND DISPLAY CONFIGURATION. For each paired stream ffprobe
//      states the same extradata SHA-256 (or none on both sides), width,
//      height, pixel format, sample and display aspect ratio, field order,
//      colour range, space, transfer and primaries, and the same stream
//      side data (display matrix / rotation, CPB properties, whatever
//      `side_data_list` holds; the sound's too). Gained or lost is a
//      difference: measured, no job output of the matrix gains or loses
//      extradata or side data.
//   3. SOUND TIMING. The sound's start, its duration and the file's
//      duration, each within `timingSlackSeconds` (one sample period, or
//      one tick of the stream's time base, never more than 1 ms). With the
//      picture's times exact (1), the sound's start IS its distance from
//      the picture. A time stated on one side only is a difference.
//   4. SOUND FORMAT. The original has exactly one audio stream, `pcm_*`,
//      1 or 2 channels, measured in full by AudioBalanceProbe as leftOnly /
//      rightOnly / mono. The copy has exactly one: 2 channels, same codec,
//      sample format and rate. Both state a plain layout — "stereo" (FL+FR;
//      "mono" for a 1-channel original) — or state none in a container
//      measured to leave it unset (`containersLeavingLayoutUnset`).
//   5. SOUND SAMPLES. Decoded with no resampling and no format change, the
//      copy's LEFT samples, its RIGHT samples and the original's LIVE
//      channel hash to the same SHA-256 (equal hashes of the raw PCM bytes
//      ⇒ equal sample counts). The channels are picked with `channelmap`
//      (a remap, no arithmetic) — not with the `pan` filter the job
//      renders with. (The sound is NOT compared packet by packet: PCM
//      packets are the muxer's chunking — raw DV's 59 become 118.)
//   6. THE DISCARDED CHANNEL HELD NOTHING. The original's other channel was
//      measured in the SAME pass that hashed the live one, and its PEAK is
//      at or under `discardedChannelPeakCeilingDBFS`. Peak, not whole-track
//      RMS: a short quiet passage in a long silent channel has a tiny RMS
//      and an honest peak. The evidence and the log line carry the
//      measured peak (or "digital silence").
//   7. BOTH READS WERE WHOLE. The packet pass (ffprobe) exited 0 and wrote
//      nothing at all on stderr. The sound pass (ffmpeg) exited 0, logged
//      nothing at error level or above, ended with ffmpeg's own clean-exit
//      line, read exactly the packet count the packet pass listed for
//      EVERY stream, decoded the sound with zero decode errors, and — where
//      the container states the sound stream's duration (AVI does not) —
//      decoded as many samples as that duration holds, within the same
//      slack. A stream with no packets at all (a Matroska attachment)
//      cannot be held this way: "could not check".
//   8. BOTH FILES STAYED PUT. Neither given path ends in a symbolic link;
//      each is resolved once (`realpath`) and every tool reads the resolved
//      path; at the end both given paths resolve to the same place and both
//      files' identity stamps (device, inode, size, mtime, ctime) are
//      unchanged; and the check was not cancelled, even during those
//      closing stamps.
// Anything unmeasured is "could not check". Unknown is never proven.
//
// What it does NOT prove (said plainly so no caller assumes it):
//   - decode timestamps (dts) and packet flags: presentation time,
//     duration, size and bytes are what is held, per packet;
//   - container metadata (creation date, tags, timecode VALUE beyond the
//     timecode track's packets) — `-map_metadata 0` is the job's promise,
//     not checked here;
//   - display information ffprobe does not list as stream side data or as
//     one of the fields in (2) (a QuickTime clean-aperture atom, say);
//   - that the discarded channel is digital silence: it may hold anything
//     whose peak is under the ceiling (hiss, hum, or sound that quiet);
//   - a PARENT DIRECTORY swapped for another and swapped back mid-run:
//     that leaves both resolved paths and both files' stamps as they were.
//     (A file renamed away and back changes its ctime and is caught.)
//   - that the two packet counts are independent of ffmpeg's demuxer: the
//     packet pass and the sound pass are separate runs of the same
//     library, so a fault that ends BOTH at the same packet, silently, on
//     both files alike, is not seen;
//   - text written to stderr mid-run of the sound pass by something other
//     than ffmpeg's own logger is not told apart from a metadata
//     continuation line when it happens to look like one;
//   - An original with more than one audio stream (12-bit DV, two pairs) is
//     "not proven": the copy drops the silent pair, and this engine does
//     not decide that a dropped stream held nothing.
//
// Shape (the repo's engine split), three files: the facts and outcomes
// (here); pure `decide` over measured `Facts`, table-tested, no I/O
// (BalancedCopyProofRules.swift); one `@concurrent` `measure` that gathers
// them (BalancedCopyProofMeasure.swift) with the app's one process runner
// (ProcessRunner.runProcess, tools from ToolLocator — the same road as
// AudioBalanceProbe / VerifyAudioProbe).
// (An `enum` with no cases is Swift's namespace ≈ a C++ struct of statics.)
//
// Cost: FIVE whole-file reads — one levels pass over the original
// (AudioBalanceProbe.analyze), one ffprobe packet pass per file (demux +
// SHA-256 of every payload), one ffmpeg sound pass per file (demux + sound
// decode). Plus one ffprobe header read per file.
//
// Memory: see BalancedCopyProofMeasure.swift — under 3 MiB whatever the
// size of the media; nothing here holds more than the two stream lists.

import Foundation
import VideoScanCore

enum BalancedCopyProof {

    // MARK: - Named numbers

    /// The loudest PEAK the original's discarded channel may hold and still
    /// count as "held nothing". Rick rules on this number.
    /// Measured 2026-11-16 (16-bit, 48 kHz): digital silence −∞; a steady
    /// 0.0005-amplitude sine (−69 dBFS RMS, Codex #298 F1) peaks at −66.2;
    /// ±0.001 uniform noise (−64.8 RMS) peaks at −59.9; ±0.0001 noise at
    /// −80.8; a 0.004 tone burst of 50 ms in 2 s (−67 RMS) peaks at −48.
    static let discardedChannelPeakCeilingDBFS: Double = -60.0

    /// How far the SOUND's start and duration (and the file's duration) may
    /// differ, in sample periods. (The picture has no tolerance: its
    /// packets' times are compared as exact fractions.) Measured: 0 for mov/mkv/mxf/avi; raw DV → mov
    /// states 1.968633 s against 1.968625 s (0.4 of a 48 kHz sample — the
    /// raw-DV demuxer's 1/14112000 time base against whole samples).
    static let soundTimingToleranceSamples: Double = 1

    /// The most any time base may widen that slack: 1 ms, Matroska's tick
    /// (its DURATION tags round the last sample to the millisecond).
    static let soundTimingSlackCeilingSeconds: Double = 0.001

    /// ffprobe `format_name` words of the containers that state NO channel
    /// layout for plain 2-channel PCM, measured on Balance Audio's own
    /// output 2026-11-16 (mov and raw DV say "stereo"). An unset layout is
    /// accepted only in these. Each was also given FC+LFE: avi and wav then
    /// state it (refused); Matroska and MXF cannot store one at all.
    static let containersLeavingLayoutUnset: Set<String> = ["matroska", "mxf", "avi", "wav"]

    // MARK: - Measured facts

    /// When the SOUND plays, as ffprobe states it.
    struct StreamTiming: Sendable, Equatable {
        /// `start_time`, seconds. nil = the container states none (WAV).
        var startSeconds: Double?
        /// `duration` (or Matroska's DURATION tag), seconds. nil = unstated.
        var durationSeconds: Double?
        /// One tick of the stream's `time_base`, seconds.
        var tickSeconds: Double?
        /// Packets the packet pass listed for the stream. nil = not counted.
        var packets: Int?
    }

    /// What a decoder is told about a stream besides its packets.
    struct PictureConfiguration: Sendable, Equatable {
        /// ffprobe `extradata_hash` ("SHA256:…"); "" = the stream has none.
        var extradataSHA256: String = ""
        var width: Int?
        var height: Int?
        var pixelFormat: String = ""
        var sampleAspect: String = ""
        var displayAspect: String = ""
        var fieldOrder: String = ""
        var colorRange: String = ""
        var colorSpace: String = ""
        var colorTransfer: String = ""
        var colorPrimaries: String = ""
        /// The stream's `side_data_list` as canonical JSON (keys sorted):
        /// display matrix / rotation, CPB properties, …; "" = none.
        var sideData: String = ""

        /// A picture stream whose size and pixel format ffprobe could read.
        var describesAPicture: Bool { (width ?? 0) > 0 && (height ?? 0) > 0 && !pixelFormat.isEmpty }

        /// The first thing `copy` states differently ("width 320 → 304").
        func firstDifference(from copy: PictureConfiguration) -> String? {
            func text(_ n: Int?) -> String { n.map(String.init) ?? "" }
            let fields: [(name: String, original: String, copy: String)] = [
                ("codec extradata", extradataSHA256, copy.extradataSHA256),
                ("width", text(width), text(copy.width)), ("height", text(height), text(copy.height)),
                ("pixel format", pixelFormat, copy.pixelFormat),
                ("sample aspect ratio", sampleAspect, copy.sampleAspect),
                ("display aspect ratio", displayAspect, copy.displayAspect),
                ("field order", fieldOrder, copy.fieldOrder), ("colour range", colorRange, copy.colorRange),
                ("colour space", colorSpace, copy.colorSpace), ("colour transfer", colorTransfer, copy.colorTransfer),
                ("colour primaries", colorPrimaries, copy.colorPrimaries), ("side data", sideData, copy.sideData)
            ]
            guard let field = fields.first(where: { $0.original != $0.copy }) else { return nil }
            func shown(_ value: String) -> String {
                if value.isEmpty { return "none" }
                if value.hasPrefix("SHA256:") { return String(value.prefix(19)) }
                return value.count > 96 ? String(value.prefix(96)) + "…" : value
            }
            return "\(field.name) \(shown(field.original)) → \(shown(field.copy))"
        }
    }

    /// One non-audio stream of a file and its packets, folded.
    struct CarriedStream: Sendable, Equatable {
        /// Container-wide stream index (what `-map 0:N` addresses).
        var index: Int
        /// ffprobe `codec_type`: "video", "data", "subtitle", "attachment".
        var kind: String
        /// ffprobe `codec_name`; "" when ffprobe names none (a `tmcd` track).
        var codec: String
        /// ffprobe `codec_tag_string` ("tmcd", "apco", …).
        var tag: String
        /// SHA-256 (lowercase hex) over the SEQUENCE of the stream's packets
        /// as (size, SHA-256 of payload) — so it holds every packet's bytes
        /// AND where one packet ends and the next begins. nil = not read.
        var packetSHA256: String?
        /// SHA-256 over the sequence of (presentation time, duration), each
        /// an exact reduced fraction of a second. nil = not read.
        var timingSHA256: String?
        /// Packets the packet pass listed. nil = not counted.
        var packets: Int?
        /// ffprobe `time_base` ("1/12800") — how the packets' times are read.
        var timeBase: String = ""
        var configuration = PictureConfiguration()

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
        /// ffprobe `channel_layout` ("stereo", "2 channels (FC+LFE)"); "" =
        /// the container states none.
        var channelLayout: String = ""
        /// The stream's `side_data_list` as canonical JSON; "" = none.
        var sideData: String = ""
        var timing = StreamTiming()

        /// How far this stream's stated times may be from another statement
        /// of the same times: one sample period, or one tick of its time
        /// base when that is coarser, capped at 1 ms.
        var timingSlackSeconds: Double {
            let sample = sampleRateHz > 0 ? BalancedCopyProof.soundTimingToleranceSamples / Double(sampleRateHz) : 0
            return min(BalancedCopyProof.soundTimingSlackCeilingSeconds, max(sample, timing.tickSeconds ?? 0))
        }
    }

    /// The streams of one file.
    struct FileLayout: Sendable, Equatable {
        var carried: [CarriedStream] = []
        var sound: [SoundStream] = []
        /// ffprobe `format_name` ("mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm").
        var container: String = ""
        /// ffprobe's duration of the whole file, seconds.
        var durationSeconds: Double?

        var containerWords: Set<String> { Set(container.split(separator: ",").map { $0.lowercased() }) }
    }

    /// What a hash pass says it read of one input stream.
    struct StreamRead: Sendable, Equatable {
        var packets: Int
        /// Sound only: samples decoded, and decode errors met.
        var samples: Int64?
        var decodeErrors: Int?
    }

    /// One hash pass's own account of its read (from its log).
    struct ReadReport: Sendable, Equatable {
        /// By container-wide stream index.
        var streams: [Int: StreamRead] = [:]
        /// The original's pass only: every channel's peak level in dBFS, in
        /// channel order; −∞ = every sample of that channel is zero.
        var channelPeaksDBFS: [Double] = []
        /// Parser state: how many "Channel: N" lines were seen.
        var channelsAnnounced = 0
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
        /// What each hash pass says it read; nil = no pass, or no account.
        var originalRead: ReadReport?
        var balancedRead: ReadReport?
    }

    // MARK: - Outcome

    /// What a PROVEN verdict stands on.
    struct Evidence: Sendable, Equatable {
        struct Stream: Sendable, Equatable {
            var kind: String
            var codec: String
            var originalIndex: Int
            var balancedIndex: Int
            /// The one SHA-256 both files' packet sequences (size + payload
            /// SHA-256 of each packet) folded to.
            var packetSHA256: String
            /// The one SHA-256 both files' packet times (presentation time +
            /// duration of each packet, exact fractions) folded to.
            var timingSHA256: String
            /// The one packet count the packet pass and both sound passes agree on.
            var packets: Int
        }
        /// The original's channel that is NOT in the copy, as measured.
        struct Discarded: Sendable, Equatable {
            /// 0 = left, 1 = right.
            var channel: Int
            /// Peak level, dBFS; −∞ when every sample is zero.
            var peakDBFS: Double
            var isDigitalSilence: Bool { peakDBFS == -.infinity }
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
        /// Samples per channel the original's pass decoded.
        var soundSamples: Int64
        /// nil = the original has one channel; nothing was discarded.
        var discarded: Discarded?
        /// Both files as they were when measured (nil in hand-built facts):
        /// where each given path resolved to, and that file's stamp. A
        /// caller that acts on the proof later must find them unchanged.
        var originalStamp: FileIdentityStamp?
        var balancedStamp: FileIdentityStamp?
        var originalResolvedPath: String?
        var balancedResolvedPath: String?
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
        /// A file's channels are not laid out as plain left + right.
        case channelLayoutNotStereo(file: String, layout: String)
        /// A stream is missing from the copy, or the copy has one too many.
        case streamsDiffer(String)
        /// A paired stream would not decode, or not be displayed, as the original's.
        case pictureConfigurationDiffers(String)
        /// Something plays at another time, speed or length.
        case timingDiffers(String)
        /// A carried stream's packets are not the original's.
        case carriedStreamDiffers(kind: String, originalIndex: Int, original: String, balanced: String)
        /// The channel the copy leaves behind is not silent.
        case discardedChannelNotSilent(channel: Int, peakDBFS: Double)
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
            case .channelLayoutNotStereo(let file, let layout):
                return "\(file)'s channels are not laid out as plain left and right "
                    + "(\(layout.isEmpty ? "no layout stated" : layout))"
            case .streamsDiffer(let what):
                return "the balanced copy does not hold the original's streams (\(what))"
            case .pictureConfigurationDiffers(let what):
                return "the balanced copy would not decode or display as the original does (\(what))"
            case .timingDiffers(let what):
                return "the balanced copy does not play at the original's times (\(what))"
            case .carriedStreamDiffers(let kind, let index, let original, let balanced):
                return "\(kind) stream \(index) is not the original's, packet for packet "
                    + "(sha256 \(BalancedCopyProof.short(original)) ≠ \(BalancedCopyProof.short(balanced)))"
            case .discardedChannelNotSilent(_, let peak):
                return "the original's other channel is not silent (peak \(BalancedCopyProof.level(peak)))"
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
}
