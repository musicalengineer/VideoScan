// BalancedCopyProof.swift
// "Does this balanced copy play what the original plays — and what else is
// different between the two files?" — answered from the two files on disk,
// NOW. READ ONLY: both files are opened for reading through ffprobe/ffmpeg
// and nothing is written, anywhere. It has NO caller yet; nothing is
// trashed, promoted or stored because of it.
//
// Workflow (Rick): "When a file's sound is on one side only, the app makes a
// balanced copy; once that copy is proven to hold everything the original
// holds, the original may be let go."
//
// The rule behind every rule: a false "the same" can cost a family
// recording; "not the same" and "could not check" only cost keeping the
// original. Every doubt resolves to one of those two.
//
// The answer has three shapes (DECISIONS 2026-11-17):
//   PROVEN THE SAME            what plays is identical and nothing else differs;
//   SAME CONTENT, DIFFERS IN…  what plays is identical; everything else
//                              either file holds is NAMED per file and NOT
//                              compared;
//   NOT THE SAME / COULD NOT CHECK.
//
// WHAT PLAYS (required for the first two shapes) — both files are decoded
// the way a player reads them (edit lists applied, ffmpeg's defaults), one
// pass each (BalancedCopyProofMeasure.swift, "the decode pass"):
//   1. PICTURE. Every picture stream decodes to the same number of frames,
//      and frame i has the same presentation time, the same duration and
//      the same SHA-256 of its decoded pixels (palette included), at the
//      same size and sample aspect ratio. Times are exact reduced fractions,
//      so raw DV (1/60000) and QuickTime (1/30000) agree to the tick. The
//      pixel format is PINNED to the one the header states and ffmpeg may
//      insert no conversion: a frame that would need converting ends the
//      pass, which is "could not check".
//   2. SOUND. Decoded with no resampling and no arithmetic (the format is
//      pinned the same way; channels are picked with `channelmap`), the
//      copy's LEFT, its RIGHT and the original's LIVE channel are the same
//      samples (SHA-256 per second of raw PCM, folded), placed at the same
//      times: the decoded timeline — where each run of contiguous samples
//      starts and how long it is — is equal within one sample.
//   3. THE DISCARDED CHANNEL HELD NOTHING. Its PEAK, measured in the same
//      pass, is at or under `discardedChannelPeakCeilingDBFS` (provisional).
//   4. NOTHING ELSE CHANGES THE DISPLAY. Per picture stream the header
//      states the same size, pixel format, aspect ratios, field order,
//      colour range/space/transfer/primaries and stream side data (display
//      matrix, …) — one exception, named and not refused: a YUV picture's
//      colour range stated `tv` by one file and left unstated by the other
//      is displayed limited-range by FFmpeg either way; the sound has one PCM track of the same format laid out
//      plainly as left + right; and no decoded track that plays by default
//      in the original has lost that flag (a QuickTime track switched off).
//   5. BOTH READS WERE WHOLE. ffmpeg exited 0 with nothing at error level,
//      ended with its own clean-exit line, read of every decoded stream the
//      packets the packet pass listed, decoded with zero errors, muxed as
//      many frames as were folded here, and the decoded length of each
//      stream is the length its header states (where it states one: raw
//      DV states none — ffprobe's figure for it is an estimate from the
//      bit rate, kept only to budget the decode's time). The ORIGINAL's
//      decode may be LONGER than stated by less than one frame or one
//      sound packet — an edit list that ends inside the last frame, which
//      FFmpeg plays whole; that is named for the original, and the copy
//      is held to all FFmpeg played. The copy's own read gets no such
//      allowance.
//   6. BOTH FILES STAYED PUT (resolved paths, identity stamps, no
//      cancellation — unchanged from the first design).
//
// SECOND EVIDENCE, bit-exact, for the PICTURE — the packet pass (ffprobe
// `-show_packets -show_data_hash`): per picture stream, the count and
// running SHA-256 of every packet's (size, payload hash, side data) and
// (time, duration). A picture whose packets are NOT identical but whose
// frames are is a named difference (encoding).
//
// THE PROOF CLAIMS EQUALITY OF TWO THINGS ONLY (re-scoped 2026-11-17 after
// Codex #307/#308 both landed in per-kind comparisons of everything else):
// (a) every picture stream as played, (b) the kept sound on the timeline —
// with the discarded channel's measured peak and the DV rule below.
// Everything else a file carries — any other track (timecode, text, data,
// attachment), media an edit list does not play, track flags, chapter
// marks, tags — is NOT compared, in either direction. Each is NAMED for the
// file that holds it (`Difference.heldBy`, "… — not compared with the other
// file"), whether or not the other file holds something like it.
//
// So `.proven` means: plays the same, AND neither file holds ANYTHING
// outside (a) and (b) — no other track, no hidden media, no track flag, no
// chapter mark, no tag — AND same container, picture packets identical,
// same decoder configuration. Nothing ancillary may be present under
// `.proven`. The real balance job's normal pair is therefore `.sameContent`
// (every real file has tags; raw DV → QuickTime also gains a timecode track,
// track flags and another container). A Trash offer for a file names every
// difference whose `heldBy` is that file.
//
// THE DV RULE (DECISIONS 2026-11-17): an original with more than one sound
// track is accepted only when every other track is MEASURED at or under the
// ceiling in the decode pass AND every picture stream is DV and
// packet-identical in the copy. The dropped track is then a named
// difference held by the original.
//
// RAW DV SOUND (GH #482, measured 2026-11-18): raw DV holds its sound inside
// each picture frame, with no timestamps of its own, and a camcorder's
// sample clock is not locked to its picture. FFmpeg stamps that sound by
// the running sample count and RE-ANCHORS it to the picture whenever the two
// are a whole frame apart, so a real tape's sound decodes in several runs
// that overlap (clock fast) or leave a gap (slow) — one in 27 minutes on
// the tape that showed it (inferred: 1,602 samples, a frame's worth, lay
// outside its copy's edit list). The job's QuickTime copy plays the same
// samples back to back. Rule 2 holds the copy to the original's RUNS,
// so such a pair is NOT THE SAME; `NotProven.soundReanchored` says exactly
// that, with the counts. The rule is not relaxed here: whether a sound that
// ends some tens of milliseconds later against the picture may stand for
// the original is the owner's to rule. A re-anchor that steps back past the
// start of the packet before it cannot be written as a timeline at all
// (ffmpeg: "Non-monotonic DTS"): COULD NOT CHECK.
//
// What it does NOT prove (said plainly so no caller assumes it):
//   - anything a player other than FFmpeg does with fields FFmpeg ignores
//     (a QuickTime `mvhd`/`mdhd` duration that disagrees with the sample
//     tables, track volume, movie rate, clean aperture, alternate groups,
//     Matroska editions);
//   - per-frame flags that change after the header was read (field order,
//     colour tags): the header's are compared, the pixels of every frame;
//   - sound placement finer than one sample, or finer than the container's
//     own time base where ffmpeg smooths rounding (1 ms in Matroska);
//   - that the discarded channel is digital silence: it may hold anything
//     under the ceiling; the evidence states the measured peak;
//   - a parent directory swapped and swapped back mid-run; text on stderr
//     that imitates a metadata continuation line;
//   - independence from FFmpeg: every pass is the same library.
//
// Shape: the facts and outcomes (here); pure `decide` over measured `Facts`
// (BalancedCopyProofRules.swift); one `@concurrent` `measure` that gathers
// them (BalancedCopyProofMeasure.swift, and the decode pass's log read back
// in BalancedCopyProofReadLog.swift) through ProcessRunner / ToolLocator.
// (An `enum` with no cases is Swift's namespace ≈ a C++ struct of statics.)
//
// Cost: FIVE whole-file reads — the levels pass over the original
// (AudioBalanceProbe.analyze), one packet pass and one decode pass per
// file — plus header reads. The decode passes dominate (every frame is
// decoded and hashed). Memory: see BalancedCopyProofMeasure.swift.

import Foundation
import VideoScanCore

enum BalancedCopyProof {

    // MARK: - Named numbers

    /// The loudest PEAK a discarded channel — or a dropped spare sound
    /// track — may hold and still count as "held nothing". PROVISIONAL
    /// (DECISIONS 2026-11-17): confirmed or changed from the dry run.
    /// Measured 2026-11-16 (16-bit, 48 kHz): digital silence −∞; a steady
    /// 0.0005 sine peaks at −66.2; ±0.001 noise at −59.9.
    static let discardedChannelPeakCeilingDBFS: Double = -60.0

    /// How far the sound's placement, and a stream's stated length against
    /// its decoded length, may differ, in sample periods. Measured
    /// 2026-11-17: 0 on every job output of the matrix.
    static let soundTimingToleranceSamples: Double = 1

    /// How far the sound's DECODED length may be from the length its header
    /// states, in sample periods. Raw DV states the picture's length for the
    /// sound, and DV packs 48 kHz sound 1600/1602/1602/1602/1602 samples a
    /// frame, so the two differ by up to 1.6 samples part-way through that
    /// cadence (measured 2026-11-17 on a 4:47 file: 1.6). This slack is only
    /// for "was the read whole"; what plays is compared sample for sample.
    static let statedLengthToleranceSamples: Double = 2

    /// The most any time base may widen a timing slack: 1 ms, Matroska's tick.
    static let timingSlackCeilingSeconds: Double = 0.001

    /// ffprobe `format_name` words of the containers that state NO channel
    /// layout for plain 2-channel PCM (measured on the job's own output).
    static let containersLeavingLayoutUnset: Set<String> = ["matroska", "mxf", "avi", "wav"]

    /// Runs of contiguous sound a file may have before its timeline is
    /// "could not check" (bounds memory: 16 bytes each).
    static let soundSegmentLimit = 4096

    /// Tag names listed in one metadata difference before "+N more".
    static let namedTagLimit = 6

    // MARK: - Measured facts

    /// What a decoder and a display are told about a stream besides its packets.
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
        /// The stream's `side_data_list` as canonical JSON (keys sorted); "" = none.
        var sideData: String = ""

        /// The colour range FFmpeg DISPLAYS this picture in: the one the
        /// header states, or — when it states none — limited range ("tv")
        /// for a YUV pixel format. nil = unstated in a format whose default
        /// this proof does not vouch for (the full-range `yuvj…` formats,
        /// RGB, grey, palette).
        var displayedColorRange: String? {
            if !colorRange.isEmpty { return colorRange }
            return pixelFormat.hasPrefix("yuv") && !pixelFormat.hasPrefix("yuvj") ? "tv" : nil
        }

        /// The colour range is stated by ONE of the two headers, and the
        /// other's picture is displayed in that range anyway — in practice
        /// `tv` against unstated, for YUV. A named difference, not a display
        /// difference. (Found on real media 2026-11-18: an Avid `ACLR` atom
        /// on DV in QuickTime; FFmpeg's QuickTime muxer cannot write a range
        /// for DV, so the job's copy states none.) Full range against
        /// anything else is never this.
        func statesRangeOnOneSideOnly(against copy: PictureConfiguration) -> Bool {
            (colorRange.isEmpty != copy.colorRange.isEmpty)
                && displayedColorRange != nil && displayedColorRange == copy.displayedColorRange
        }

        /// A picture stream whose size and pixel format ffprobe could read.
        var describesAPicture: Bool { (width ?? 0) > 0 && (height ?? 0) > 0 && !pixelFormat.isEmpty }

        /// One DISPLAY field the two headers state differently ("" = unstated).
        struct FieldDifference: Sendable, Equatable {
            var name: String
            var original: String
            var copy: String
        }

        /// Every DISPLAY field `copy` states differently, in the order they
        /// are checked. Extradata is not one: it is the decoder's, and the
        /// decoded frames answer for it.
        func displayDifferences(from copy: PictureConfiguration) -> [FieldDifference] {
            func text(_ n: Int?) -> String { n.map(String.init) ?? "" }
            let fields: [FieldDifference] = [
                .init(name: "width", original: text(width), copy: text(copy.width)),
                .init(name: "height", original: text(height), copy: text(copy.height)),
                .init(name: "pixel format", original: pixelFormat, copy: copy.pixelFormat),
                .init(name: "sample aspect ratio", original: sampleAspect, copy: copy.sampleAspect),
                .init(name: "display aspect ratio", original: displayAspect, copy: copy.displayAspect),
                .init(name: "field order", original: fieldOrder, copy: copy.fieldOrder),
                .init(name: "colour range", original: colorRange, copy: copy.colorRange),
                .init(name: "colour space", original: colorSpace, copy: copy.colorSpace),
                .init(name: "colour transfer", original: colorTransfer, copy: copy.colorTransfer),
                .init(name: "colour primaries", original: colorPrimaries, copy: copy.colorPrimaries),
                .init(name: "side data", original: sideData, copy: copy.sideData)
            ]
            return fields.filter { $0.original != $0.copy }
        }

        /// The first field by which `copy` would be DISPLAYED differently
        /// ("width 320 → 304") — every field of `displayDifferences` but a
        /// colour range stated on one side only (`statesRangeOnOneSideOnly`).
        func displayDifference(from copy: PictureConfiguration) -> String? {
            let sameRange = statesRangeOnOneSideOnly(against: copy)
            guard let field = displayDifferences(from: copy).first(where: { !(sameRange && $0.name == "colour range") })
            else { return nil }
            func shown(_ value: String) -> String {
                value.isEmpty ? "none" : (value.count > 96 ? String(value.prefix(96)) + "…" : value)
            }
            return "\(field.name) \(shown(field.original)) → \(shown(field.copy))"
        }
    }

    /// One non-audio stream of a file: its header, and its packets folded.
    struct CarriedStream: Sendable, Equatable {
        /// Container-wide stream index (what `-map 0:N` addresses).
        var index: Int
        /// ffprobe `codec_type`: "video", "data", "subtitle", "attachment".
        var kind: String
        /// ffprobe `codec_name`; "" when ffprobe names none (a `tmcd` track).
        var codec: String
        /// ffprobe `codec_tag_string` ("tmcd", "apco", …).
        var tag: String
        /// SHA-256 over the SEQUENCE of the stream's packets as (size,
        /// SHA-256 of payload, side data). nil = not read.
        var packetSHA256: String?
        /// SHA-256 over the sequence of (presentation time, duration), each
        /// an exact reduced fraction of a second. nil = not read.
        var timingSHA256: String?
        /// Packets the packet pass listed. nil = not counted.
        var packets: Int?
        /// ffprobe `time_base` ("1/12800") — how the packets' times are read.
        var timeBase: String = ""
        /// The length the header states (`duration`, or Matroska's DURATION
        /// tag), seconds. nil = it states none.
        var statedSeconds: Double?
        /// QuickTime family only: the length the file's own index holds with
        /// the edit list IGNORED — what is stored, played or not. nil = not
        /// that kind of container.
        var storedSeconds: Double?
        var configuration = PictureConfiguration()
        var tags: [String: String] = [:]
        /// The ffprobe `disposition` flags that are set ("default",
        /// "attached_pic", …). QuickTime's "track enabled" switch is `default`.
        var flags: Set<String> = []

        var isPicture: Bool { kind == "video" }
        /// The timecode track the mov muxer writes.
        var isTimecodeTrack: Bool { kind == "data" && tag == "tmcd" }

        /// How far this stream's stated length may be from its decoded one:
        /// one tick of its time base, at least 1 µs (ffprobe prints six
        /// decimals), never more than 1 ms.
        var timingSlackSeconds: Double {
            min(BalancedCopyProof.timingSlackCeilingSeconds, max(BalancedCopyProof.tick(timeBase) ?? 0, 0.000_001))
        }
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
        /// ffprobe `channel_layout`; "" = the container states none.
        var channelLayout: String = ""
        /// The stream's `side_data_list` as canonical JSON; "" = none.
        var sideData: String = ""
        /// The length the header states, seconds. nil = unstated (AVI).
        var statedSeconds: Double?
        /// See `CarriedStream.storedSeconds`.
        var storedSeconds: Double?
        /// One tick of the stream's `time_base`, seconds.
        var tickSeconds: Double?
        /// Packets the packet pass listed. nil = not counted.
        var packets: Int?
        var tags: [String: String] = [:]
        /// See `CarriedStream.flags`.
        var flags: Set<String> = []

        /// One sample period, or one tick of the time base when that is
        /// coarser, capped at 1 ms.
        var timingSlackSeconds: Double {
            let sample = sampleRateHz > 0 ? BalancedCopyProof.soundTimingToleranceSamples / Double(sampleRateHz) : 0
            return min(BalancedCopyProof.timingSlackCeilingSeconds, max(sample, tickSeconds ?? 0))
        }

        /// How far the decoded length may be from `statedSeconds`.
        var statedLengthSlackSeconds: Double {
            let samples = sampleRateHz > 0 ? BalancedCopyProof.statedLengthToleranceSamples / Double(sampleRateHz) : 0
            return min(BalancedCopyProof.timingSlackCeilingSeconds, max(samples, tickSeconds ?? 0))
        }
    }

    /// The streams of one file.
    struct FileLayout: Sendable, Equatable {
        var carried: [CarriedStream] = []
        var sound: [SoundStream] = []
        /// ffprobe `format_name` ("mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm").
        var container: String = ""
        /// The container's own tags.
        var tags: [String: String] = [:]
        /// How many chapter marks it has.
        var chapters = 0
        /// Raw DV only: the length ffprobe ESTIMATES from the bit rate (the
        /// file states none). Used to budget the decode's time, never to
        /// judge a read: measured 2026-11-18, the estimate is exact for a
        /// 3-minute file, one tick of 1/60000 s short at 19 minutes and two
        /// at an hour. nil = the container states its lengths.
        var estimatedSeconds: Double?

        var containerWords: Set<String> { Set(container.split(separator: ",").map { $0.lowercased() }) }
        /// The QuickTime family: the one whose edit lists can hide stored media.
        var hasEditLists: Bool { containerWords.contains("mov") }
        var pictures: [CarriedStream] { carried.filter(\.isPicture) }
    }

    /// One picture stream as the decode pass played it.
    struct PictureRead: Sendable, Equatable {
        var frames: Int
        /// SHA-256 over the stream's size and sample aspect ratio, then
        /// "<time> <duration> <bytes> <sha256 of decoded pixels>" per frame.
        var sha256: String
        /// Presentation time of the first frame, and the end of the last.
        var firstSeconds: Double
        var endSeconds: Double
    }

    /// A run of contiguous decoded sound: its first sample's presentation
    /// time in sample periods, and its length in samples.
    struct SoundSegment: Sendable, Equatable {
        var start: Int64
        var samples: Int64
    }

    /// What ffmpeg's own log says it read of one input stream.
    struct StreamRead: Sendable, Equatable {
        var packets: Int
        var decodeErrors: Int?
    }

    /// One decode pass: ffmpeg's own account of its read (from its log), and
    /// what was folded here from the frames it wrote.
    struct ReadReport: Sendable, Equatable {
        /// By container-wide input stream index.
        var streams: [Int: StreamRead] = [:]
        /// Frames ffmpeg says it muxed, and frames folded here, by OUTPUT
        /// stream number. A pass is whole only when they are equal.
        var muxed: [Int: Int] = [:]
        var folded: [Int: Int] = [:]
        /// Every channel's peak in dBFS (−∞ = every sample zero), by sound
        /// stream index — measured for the original's streams only.
        var peaksDBFS: [Int: [Double]] = [:]
        /// By container-wide input stream index.
        var pictures: [Int: PictureRead] = [:]
        /// The kept sound's timeline. nil = not read.
        var soundSegments: [SoundSegment]?
        /// One digest per hashed channel (original: the live one; copy:
        /// left, right): SHA-256 over "<bytes> <sha256>" per second of raw PCM.
        var channelSHA256: [String] = []
        /// Samples behind each of those digests.
        var channelSamples: [Int64] = []

        /// Samples on the timeline. nil = not read, or a total that does not
        /// fit in 64 bits (no file has one; a count that cannot be held is no
        /// count — and adding past Int64.max would TRAP, GH #483 item 3).
        var soundSamples: Int64? {
            guard let soundSegments else { return nil }
            var total: Int64 = 0
            for run in soundSegments {
                let (sum, overflow) = total.addingReportingOverflow(run.samples)
                guard !overflow else { return nil }
                total = sum
            }
            return total
        }
    }

    /// Everything `decide` looks at. Built by `measure`; built by hand in
    /// the decision-table tests.
    struct Facts: Sendable, Equatable {
        var original: FileLayout
        var balanced: FileLayout
        /// The analyzer's class for the original's program audio.
        var originalClass: AudioChannelClass
        /// The levels pass covered every channel of every stream. False =
        /// the class above is not a measurement.
        var originalMeasuredInFull: Bool
        /// Index of the original's sound stream the balance job reads. nil =
        /// its first.
        var keptSoundIndex: Int?
        /// What each decode pass found; nil = no pass.
        var originalRead: ReadReport?
        var balancedRead: ReadReport?
    }

    // MARK: - Outcome

    /// One thing that keeps a pair that PLAYS the same from being "the same":
    /// something about how a picture is stored (compared), or something one
    /// file holds outside the picture and the kept sound (never compared).
    struct Difference: Sendable, Equatable {
        enum Kind: String, Sendable {
            case track, container, encoding, decoderConfiguration = "decoder configuration"
            case playback = "playback instructions", metadata
        }
        enum Holder: String, Sendable {
            case original = "the original", balancedCopy = "the balanced copy"
        }
        var kind: Kind
        /// The file that HOLDS the thing — what a Trash offer must name
        /// before that file goes. It says nothing about the other file: the
        /// thing was not compared (one exception says so in its own words:
        /// a colour range tag the other file does not state, compared and
        /// found to display the same). nil = not a holding at all: the two
        /// files store the same pictures differently (container, encoding,
        /// decoder configuration).
        var heldBy: Holder?
        /// Plain words.
        var what: String
    }

    /// What a "same" verdict stands on.
    struct Evidence: Sendable, Equatable {
        /// One picture stream.
        struct Stream: Sendable, Equatable {
            var codec: String
            var originalIndex: Int
            var balancedIndex: Int
            /// Frames played, and the one SHA-256 both files' decoded frames
            /// (time, duration, pixels) folded to.
            var frames: Int
            var framesSHA256: String
            /// The stored packets are identical too, byte for byte and time
            /// for time.
            var packetIdentical: Bool
            /// The original's packet digest and count.
            var packetSHA256: String
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
        var streams: [Stream]
        var originalClass: AudioChannelClass
        /// 0 = left, 1 = right: the original channel the copy was held to.
        var liveChannel: Int
        var soundCodec: String
        var sampleFormat: String
        var sampleRateHz: Int
        /// The one digest that the original's live channel, the copy's left
        /// and the copy's right all folded to (see `ReadReport.channelSHA256`).
        var soundSHA256: String
        /// Samples per channel, and where the first one plays (seconds).
        var soundSamples: Int64
        var soundStartSeconds: Double
        /// nil = the original has one channel; nothing was discarded.
        var discarded: Discarded?
        /// Both files as they were when measured (nil in hand-built facts).
        /// A caller that acts on the proof later must find them unchanged.
        var originalStamp: FileIdentityStamp?
        var balancedStamp: FileIdentityStamp?
        var originalResolvedPath: String?
        var balancedResolvedPath: String?
    }

    /// Why a pair that WAS measured does not play the same.
    /// (≈ a C++ `std::variant` of small structs; `message` is its visitor.
    /// It is an `Error` only so `Result` can carry it; nothing throws it.)
    enum NotProven: Error, Sendable, Equatable {
        /// The original is not one-sided, so no balanced copy stands for it.
        case originalNotOneSided(AudioChannelClass)
        /// The original has no sound track (or none the job reads).
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
        /// The two files do not have the same picture streams.
        case streamsDiffer(String)
        /// A picture would not be displayed as the original's.
        case pictureConfigurationDiffers(String)
        /// A picture does not play the original's frames at the original's times.
        case pictureDiffers(originalIndex: Int, String)
        /// The sound is not placed on the timeline as the original's is.
        case soundPlacementDiffers(String)
        /// The same placement difference, in the one shape a raw DV tape
        /// gives it (GH #482): every sample is the original's, in order, but
        /// FFmpeg reads the ORIGINAL's sound as re-anchored to the picture
        /// `times` times — runs that overlap (the tape's sample clock ran
        /// fast) or leave a gap (slow) — and the copy plays back to back.
        case soundReanchored(times: Int, overlapSamples: Int64, gapSamples: Int64, sampleRateHz: Int)
        /// The channel the copy leaves behind is not silent.
        case discardedChannelNotSilent(channel: Int, peakDBFS: Double)
        /// A sound track the copy leaves behind is not silent, or the DV
        /// rule does not cover the file.
        case spareSoundTrack(String)
        /// The copy's two channels are not the same samples.
        case channelsDiffer(left: String, right: String)
        /// The copy's sound is not the original's live channel.
        case soundDiffers(original: String, balanced: String)

        /// The plain sentence a caller may show or log.
        var message: String { detail + " — the original is kept" }

        private var detail: String { placementDetail ?? soundDetail ?? pictureDetail }

        /// The reasons that are about the sound. nil = it is about the picture or the tracks.
        private var soundDetail: String? {
            switch self {
            case .originalNotOneSided(let c):
                return "the original's sound is not one-sided (\(c.rawValue))"
            case .originalSoundTracks(let n):
                return "the original has \(n) sound tracks the balance job reads, expected exactly 1"
            case .soundReencoded(let codec):
                return "the sound was re-encoded (\(codec.isEmpty ? "unknown codec" : codec))"
            case .balancedSoundTracks(let n):
                return "the balanced copy has \(n) sound tracks, expected exactly 1"
            case .soundFormatChanged(let what):
                return "the balanced copy's sound format is not the original's (\(what))"
            case .channelLayoutNotStereo(let file, let layout):
                return "\(file)'s channels are not laid out as plain left and right "
                    + "(\(layout.isEmpty ? "no layout stated" : layout))"
            case .discardedChannelNotSilent(_, let peak):
                return "the original's other channel is not silent (peak \(BalancedCopyProof.level(peak)))"
            case .spareSoundTrack(let what):
                return "the original has a sound track the balanced copy leaves behind (\(what))"
            case .channelsDiffer(let left, let right):
                return "the balanced copy's left and right channels are not the same sound "
                    + "(sha256 \(BalancedCopyProof.short(left)) ≠ \(BalancedCopyProof.short(right)))"
            case .soundDiffers(let original, let balanced):
                return "the balanced copy's sound is not the original's live channel, sample for sample "
                    + "(sha256 \(BalancedCopyProof.short(original)) ≠ \(BalancedCopyProof.short(balanced)))"
            case .streamsDiffer, .pictureConfigurationDiffers, .pictureDiffers, .soundPlacementDiffers, .soundReanchored:
                return nil
            }
        }

        /// The reasons that are about WHERE the sound sits on the timeline.
        private var placementDetail: String? {
            switch self {
            case .soundPlacementDiffers(let what):
                return "the balanced copy's sound does not play at the original's times (\(what))"
            case .soundReanchored(let times, let overlap, let gap, let rate):
                let net = Double(overlap) - Double(gap)
                let ends = net == 0 ? "at the same time"
                    : String(format: "%.1f ms ", abs(net) / Double(max(rate, 1)) * 1000) + (net > 0 ? "later" : "earlier")
                return "the original is raw DV and its sound is re-anchored to the picture \(times) time\(times == 1 ? "" : "s") "
                    + "as FFmpeg reads it (\(overlap) samples overlap, \(gap) samples of gap); the balanced copy plays the "
                    + "same samples back to back, so its sound ends \(ends) against the picture"
            default:
                return nil
            }
        }

        private var pictureDetail: String {
            switch self {
            case .streamsDiffer(let what):
                return "the two files do not have the same picture streams (\(what))"
            case .pictureConfigurationDiffers(let what):
                return "the balanced copy would not be displayed as the original is (\(what))"
            case .pictureDiffers(let index, let what):
                return "picture stream \(index) does not play the same in the balanced copy (\(what))"
            default:
                return "the balanced copy is not the same"
            }
        }
    }

    enum Outcome: Sendable, Equatable {
        /// What plays is identical, the pictures are stored identically, and
        /// neither file holds anything else at all.
        case proven(Evidence)
        /// What plays is identical; the things named (never empty) are
        /// stored differently, or held by one file and NOT compared. A
        /// caller offering a file for the Trash names every difference
        /// whose `heldBy` is that file.
        case sameContent(Evidence, differs: [Difference])
        /// Measured, and the copy does not play what the original plays.
        case notProven(NotProven)
        /// Not measured (missing file, tool failed, unreadable, stopped).
        /// Never "the same"; the reason is a plain sentence.
        case couldNotCheck(String)

        /// Identical in everything compared. `sameContent` is NOT this.
        var isProven: Bool { if case .proven = self { return true }; return false }

        /// The copy plays what the original plays (either "same" shape).
        var playsTheSame: Bool { evidence != nil }

        var evidence: Evidence? {
            switch self {
            case .proven(let evidence), .sameContent(let evidence, _): return evidence
            case .notProven, .couldNotCheck: return nil
            }
        }

        var differences: [Difference] {
            if case .sameContent(_, let differs) = self { return differs }
            return []
        }
    }
}
