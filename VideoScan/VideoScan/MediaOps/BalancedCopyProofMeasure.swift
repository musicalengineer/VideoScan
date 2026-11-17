// BalancedCopyProofMeasure.swift
// The measuring half of BalancedCopyProof (rules, outcomes and the header
// that says what each answer means: BalancedCopyProof.swift). READ ONLY:
// both files are opened for reading through ffprobe/ffmpeg; nothing is
// written.
//
// Per file, each by its own tool run:
//   1. THE HEADER — ffprobe `-show_streams -show_format -show_data_hash`:
//      the stream list, each stream's decoder and display configuration,
//      side data, time base, stated length and tags. For the QuickTime
//      family a second header read with `-ignore_editlist 1` gives the
//      length each track STORES, played or not.
//   2. THE PACKET PASS — ffprobe `-show_packets -show_data_hash sha256`,
//      one CSV line per packet, folded as it arrives by `PacketLedger` into
//      two running SHA-256 per carried stream and a count per stream.
//   3. THE DECODE PASS — one ffmpeg run that decodes every picture stream
//      and the sound as a player would (`-copyts`: times as the container
//      gives them, edit lists applied) and writes one line per decoded
//      frame through the `framehash` muxer: time, duration, size, SHA-256
//      of the raw frame. `FrameLedger` folds the lines as they arrive.
//        · Pixel and sample formats are PINNED (`format=` / `aformat=` to
//          what the header states) and `-noauto_conversion_filters` forbids
//          ffmpeg from converting to satisfy them: a frame in any other
//          format ends the run. The only conversions are the two written
//          here — interleaved ⇄ planar samples around `channelmap` (which
//          takes planar only): the same samples in another memory order.
//        · `-fps_mode passthrough -enc_time_base:v demux`: no frame is
//          dropped or duplicated, and each keeps its own time in the
//          stream's own time base.
//        · The sound leaves three ways: the kept channel as decoded (its
//          frame times are the TIMELINE), and each hashed channel cut into
//          one-second pieces (`asetnsamples`), so the digest does not
//          depend on how a container packs samples into packets.
//        · `astats`, named for the run so nothing in a file can forge its
//          lines, reads every channel's peak of every sound track of the
//          original — before the kept channel is picked.
//        · `-xerror -err_detect explode`; logged at `repeat+level+verbose`
//          because ffmpeg's per-stream read counts exist only there. Any
//          line at error/fatal/panic, any line with no level that is not an
//          indented metadata continuation, or a log that does not END with
//          ffmpeg's own clean-exit line is COULD NOT CHECK.
//
// Memory, whatever the size of the media: two or three ffprobe JSON
// documents (1 MiB cap each); the packet ledger (two SHA-256 states and
// three integers per stream); the frame ledger (one SHA-256 state per
// output stream, at most `soundSegmentLimit` × 16 bytes of timeline); one
// decode pass's log at a time (256 KiB cap). Under 4 MiB here. The ffmpeg
// child holds a few decoded frames and one second of sound per channel.

import CryptoKit
import Darwin
import Foundation
import os
import VideoScanCore

private let proofLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "balancedCopyProof")

extension BalancedCopyProof {

    // MARK: - ffprobe layout (pure parse)

    /// ffprobe request for one file's streams, format and chapters, whole (so
    /// that every stream's `side_data_list` is there), with extradata
    /// hashes. Reads the header only.
    static func layoutArgs(input: String) -> [String] {
        ["-v", "error", "-show_data_hash", "sha256", "-show_streams", "-show_format", "-show_chapters", "-of", "json", input]
    }

    /// ffprobe request for the length each QuickTime track STORES: the same
    /// header read with the edit list ignored.
    static func storedArgs(input: String) -> [String] {
        ["-v", "error", "-ignore_editlist", "1", "-show_entries", "stream=index,duration", "-of", "json", input]
    }

    /// ffprobe request for every packet of one file, one CSV line each:
    /// "stream_index,pts,duration,size,SHA256:<hex>" and, after those, the
    /// packet's side data when it has any. Reads the whole file.
    static func packetArgs(input: String) -> [String] {
        ["-v", "error", "-show_packets", "-show_data_hash", "sha256",
         "-show_entries", "packet=stream_index,pts,duration,size,data_hash", "-of", "csv=p=0", input]
    }

    private struct ProbedStream: Decodable {
        let index: Int?
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let channels: Int?
        let channel_layout: String?
        let sample_rate: String?
        let sample_fmt: String?
        let duration: String?
        let time_base: String?
        let extradata_hash: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let sample_aspect_ratio: String?
        let display_aspect_ratio: String?
        let field_order: String?
        let color_range: String?
        let color_space: String?
        let color_transfer: String?
        let color_primaries: String?
        let tags: [String: String]?
        let disposition: [String: Int]?

        var flags: Set<String> { Set((disposition ?? [:]).filter { $0.value != 0 }.keys) }

        /// Matroska states a stream's length only as a DURATION tag.
        var statedSeconds: Double? {
            BalancedCopyProof.seconds(duration) ?? AudioBalanceProbe.seconds(fromDurationTag: tags?["DURATION"])
        }

        func configuration(sideData: String) -> PictureConfiguration {
            PictureConfiguration(
                extradataSHA256: extradata_hash ?? "", width: width, height: height, pixelFormat: pix_fmt ?? "",
                sampleAspect: sample_aspect_ratio ?? "", displayAspect: display_aspect_ratio ?? "",
                fieldOrder: field_order ?? "", colorRange: color_range ?? "", colorSpace: color_space ?? "",
                colorTransfer: color_transfer ?? "", colorPrimaries: color_primaries ?? "", sideData: sideData)
        }
    }
    private struct ProbedFormat: Decodable {
        let format_name: String?
        let tags: [String: String]?
    }
    private struct ProbedChapter: Decodable {
        let start_time: String?
        let end_time: String?
        let tags: [String: String]?
    }
    private struct ProbeReport: Decodable {
        let streams: [ProbedStream]?
        let format: ProbedFormat?
        let chapters: [ProbedChapter]?
    }

    /// "1.968633" → seconds; nil for absent, "N/A" or a non-finite number.
    static func seconds(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// ffprobe `time_base` ("1/48000") → the length of one tick in seconds.
    static func tick(_ timeBase: String?) -> Double? {
        guard let parts = timeBase?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              numerator > 0, denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Each stream's `side_data_list`, in stream order, as canonical JSON
    /// (keys sorted). "" = the stream lists none. nil = the document is not
    /// ffprobe's, or a list cannot be written back out.
    static func sideData(fromProbeJSON data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { return nil }
        var out: [String] = []
        for stream in streams {
            guard let list = stream["side_data_list"] else { out.append(""); continue }
            guard JSONSerialization.isValidJSONObject(list),
                  let bytes = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
                  let text = String(bytes: bytes, encoding: .utf8) else { return nil }
            out.append(text)
        }
        return out
    }

    /// Decode ffprobe's JSON into a layout; nil when it is not that JSON or
    /// lists no stream at all (not a media file). Packets and stored
    /// lengths are not in it: later reads fill them in.
    static func layout(fromProbeJSON data: Data) -> FileLayout? {
        guard let report = try? JSONDecoder().decode(ProbeReport.self, from: data),
              let streams = report.streams, !streams.isEmpty,
              let sideData = sideData(fromProbeJSON: data), sideData.count == streams.count else { return nil }
        var layout = FileLayout(
            container: report.format?.format_name ?? "", tags: report.format?.tags ?? [:],
            chapters: (report.chapters ?? []).map { "\($0.start_time ?? "?")–\($0.end_time ?? "?") \($0.tags?["title"] ?? "")" })
        for (position, s) in streams.enumerated() {
            let index = s.index ?? position
            if s.codec_type == "audio" {
                layout.sound.append(SoundStream(
                    index: index, codec: s.codec_name ?? "", sampleFormat: s.sample_fmt ?? "",
                    sampleRateHz: s.sample_rate.flatMap { Int($0) } ?? 0, channels: s.channels ?? 0,
                    channelLayout: s.channel_layout ?? "", sideData: sideData[position],
                    statedSeconds: s.statedSeconds, tickSeconds: tick(s.time_base), tags: s.tags ?? [:], flags: s.flags))
            } else {
                layout.carried.append(CarriedStream(
                    index: index, kind: s.codec_type ?? "", codec: s.codec_name ?? "",
                    tag: s.codec_tag_string ?? "", timeBase: s.time_base ?? "", statedSeconds: s.statedSeconds,
                    configuration: s.configuration(sideData: sideData[position]), tags: s.tags ?? [:], flags: s.flags))
            }
        }
        return layout
    }

    /// `layout` with every stream's STORED length written in from the
    /// edit-list-ignoring header read. nil = that read is not ffprobe's, or
    /// does not state a length for every stream it lists.
    static func withStoredLengths(_ layout: FileLayout, fromProbeJSON data: Data) -> FileLayout? {
        guard let report = try? JSONDecoder().decode(ProbeReport.self, from: data), let streams = report.streams,
              streams.count == layout.carried.count + layout.sound.count else { return nil }
        var stored: [Int: Double] = [:]
        for s in streams {
            guard let index = s.index else { return nil }
            stored[index] = seconds(s.duration)
        }
        var out = layout
        for i in out.carried.indices { out.carried[i].storedSeconds = stored[out.carried[i].index] }
        for i in out.sound.indices { out.sound[i].storedSeconds = stored[out.sound[i].index] }
        return out
    }

    // MARK: - The packet pass (pure fold)

    /// What the packet pass found of one stream.
    struct PacketSequence: Sendable, Equatable {
        var packets: Int
        /// SHA-256 over "<pts> <duration>\n" per packet, each an exact
        /// reduced fraction of a second ("1001/30000").
        var timingSHA256: String
        /// SHA-256 over "<size> <payload sha256>[ <packet side data>]\n" per packet.
        var packetSHA256: String
    }

    /// `ticks × numerator/denominator` as a reduced fraction "p/q" (q > 0).
    /// nil = overflow. 2002 ticks of 1/60000 and 1001 ticks of 1/30000 are
    /// both "1001/30000".
    static func fraction(ticks: Int64, numerator: Int64, denominator: Int64) -> String? {
        let (product, overflow) = ticks.multipliedReportingOverflow(by: numerator)
        guard !overflow, denominator > 0, product != .min else { return nil }
        var a = abs(product), b = denominator
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(a, 1)
        return "\(product / divisor)/\(denominator / divisor)"
    }

    private static func hex(_ hasher: SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A 64-digit hex SHA-256, lowercased; nil for anything else.
    private static func digest(_ text: Substring) -> String? {
        text.count == 64 && text.allSatisfy(\.isHexDigit) ? text.lowercased() : nil
    }

    /// Folds the packet pass's lines as they arrive. Bounded: per stream,
    /// two SHA-256 states and a count — never the lines. The first line
    /// that cannot be read is kept as the fault and ends the proof.
    /// (`@unchecked Sendable`: every field is touched under `lock`; the
    /// runner calls `note` from its pipe-reader thread. ≈ a C++ class whose
    /// members are guarded by one std::mutex.)
    final class PacketLedger: @unchecked Sendable {
        private struct Stream {
            var numerator: Int64 = 0
            var denominator: Int64 = 0
            /// Carried streams are folded; the sound is only counted.
            var folded = false
            var packets = 0
            var timing = SHA256()
            var payload = SHA256()
        }
        private let lock = NSLock()
        private var streams: [Int: Stream] = [:]
        private var firstFault: String?

        /// `layout`'s carried streams are folded with their time bases; its
        /// sound streams are counted.
        init(layout: FileLayout) {
            for stream in layout.carried {
                var entry = Stream()
                entry.folded = true
                let parts = stream.timeBase.split(separator: "/").compactMap { Int64($0) }
                if parts.count == 2 { (entry.numerator, entry.denominator) = (parts[0], parts[1]) }
                streams[stream.index] = entry
            }
            for stream in layout.sound { streams[stream.index] = Stream() }
        }

        /// One CSV line of the packet pass.
        func note(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            guard firstFault == nil, !line.isEmpty else { return }
            if !fold(line) { firstFault = line }
        }

        private func fold(_ line: String) -> Bool {
            // Five fields, then — only when a packet carries side data (a
            // palette, new extradata, skipped samples) — that side data,
            // which is folded with the packet's bytes.
            let fields = line.split(separator: ",", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count >= 5, let index = Int(fields[0]), var stream = streams[index] else { return false }
            let sideData = fields.count > 5 ? " " + fields[5] : ""
            stream.packets += 1
            if stream.folded {
                guard let pts = Int64(fields[1]), let duration = Int64(fields[2]), let size = Int64(fields[3]), size >= 0,
                      stream.numerator > 0,
                      let at = BalancedCopyProof.fraction(ticks: pts, numerator: stream.numerator, denominator: stream.denominator),
                      let lasting = BalancedCopyProof.fraction(ticks: duration, numerator: stream.numerator,
                                                              denominator: stream.denominator),
                      fields[4].hasPrefix("SHA256:"), let payload = BalancedCopyProof.digest(fields[4].dropFirst(7)) else {
                    return false
                }
                stream.timing.update(data: Data("\(at) \(lasting)\n".utf8))
                stream.payload.update(data: Data("\(size) \(payload)\(sideData)\n".utf8))
            }
            streams[index] = stream
            return true
        }

        /// The line that could not be read, if any.
        var fault: String? {
            lock.lock()
            defer { lock.unlock() }
            return firstFault
        }

        /// What was folded, by stream index (a stream with no packet has
        /// count 0 and the digests of nothing).
        var sequences: [Int: PacketSequence] {
            lock.lock()
            defer { lock.unlock() }
            return streams.mapValues {
                PacketSequence(packets: $0.packets, timingSHA256: BalancedCopyProof.hex($0.timing),
                               packetSHA256: BalancedCopyProof.hex($0.payload))
            }
        }
    }

    /// Write the packet pass's findings into a layout.
    static func filled(_ layout: FileLayout, with sequences: [Int: PacketSequence]) -> FileLayout {
        var out = layout
        for i in out.carried.indices {
            let found = sequences[out.carried[i].index]
            out.carried[i].packets = found?.packets
            out.carried[i].packetSHA256 = found?.packetSHA256
            out.carried[i].timingSHA256 = found?.timingSHA256
        }
        for i in out.sound.indices { out.sound[i].packets = sequences[out.sound[i].index]?.packets }
        return out
    }

    // MARK: - The decode pass (pure builders)

    /// What one decode pass is asked to play.
    struct DecodePlan: Sendable, Equatable {
        struct Picture: Sendable, Equatable {
            var index: Int
            var pixelFormat: String
        }
        var pictures: [Picture]
        /// The sound stream that is hashed, and its header's format.
        var soundIndex: Int
        var sampleFormat: String
        var sampleRateHz: Int
        /// Channels hashed, in order (original: the live one; copy: 0, 1).
        /// The first is also the timeline.
        var channels: [Int]
        /// Sound streams whose every channel's peak is measured (the
        /// original's: the kept one and any spare). Empty for the copy.
        var measured: [Int] = []
        /// Names this run's astats instances.
        var runTag: String = ""

        /// What each framehash output stream holds, in map order.
        var roles: [FrameLedger.Role] {
            pictures.map { .picture(input: $0.index) } + [.timeline] + channels.indices.map { .channel($0) }
        }
    }

    private static func peakFilter(_ plan: DecodePlan, stream: Int) -> String {
        "astats@\(plan.runTag)s\(stream)=measure_perchannel=Peak_level:measure_overall=none"
    }

    /// The filter graph of one decode pass (see the file header).
    static func decodeFilter(_ plan: DecodePlan) -> String {
        let packed = packedSampleFormat(plan.sampleFormat)
        // `channelmap` moves samples; it never does arithmetic on them. It
        // takes planar input only, hence the two explicit re-orderings.
        func pick(_ channel: Int) -> String {
            "aresample=osf=\(packed)p,channelmap=map=\(channel):channel_layout=mono,aresample=osf=\(packed)"
        }
        var parts = plan.pictures.map { "[0:\($0.index)]format=pix_fmts=\($0.pixelFormat)[p\($0.index)]" }
        let branches = ["[t]"] + plan.channels.indices.map { "[c\($0)]" }
        var head = "[0:\(plan.soundIndex)]aformat=sample_fmts=\(plan.sampleFormat):sample_rates=\(plan.sampleRateHz),"
        if plan.measured.contains(plan.soundIndex) { head += peakFilter(plan, stream: plan.soundIndex) + "," }
        parts.append(head + "asplit=\(branches.count)" + branches.joined())
        parts.append("[t]\(pick(plan.channels.first ?? 0))[timeline]")
        for (n, channel) in plan.channels.enumerated() {
            parts.append("[c\(n)]\(pick(channel)),asetnsamples=n=\(plan.sampleRateHz):p=0[ch\(n)]")
        }
        for spare in plan.measured where spare != plan.soundIndex {
            parts.append("[0:\(spare)]\(peakFilter(plan, stream: spare)),anullsink")
        }
        return parts.joined(separator: ";")
    }

    /// One pass: every picture and the sound decoded as a player reads the
    /// file, one framehash line per decoded frame on stdout. `inputArgs` are
    /// demuxer options (the raw-DV `-r`), before `-i`.
    static func decodeArgs(input: String, inputArgs: [String], plan: DecodePlan, hashCodec: String) -> [String] {
        var args = ["-v", "repeat+level+verbose", "-nostdin", "-nostats", "-hide_banner", "-xerror",
                    "-err_detect", "explode", "-noauto_conversion_filters", "-copyts"]
            + inputArgs + ["-i", input, "-filter_complex", decodeFilter(plan)]
        for picture in plan.pictures { args += ["-map", "[p\(picture.index)]"] }
        args += ["-map", "[timeline]"]
        for n in plan.channels.indices { args += ["-map", "[ch\(n)]"] }
        if !plan.pictures.isEmpty {
            // `-noautoscale`: a picture that changes size mid-stream is NOT
            // scaled back to its first size before it is hashed (Codex #307-1;
            // measured: with ffmpeg's default both halves hash as 64×48).
            args += ["-c:v", "rawvideo", "-noautoscale", "-fps_mode", "passthrough", "-enc_time_base:v", "demux"]
        }
        return args + ["-c:a", hashCodec, "-f", "framehash", "-hash", "sha256", "-"]
    }

    /// How long a decode pass may take: the levels pass's deadline (it
    /// scales with the file's size), or twice the longest stated length
    /// when that is more — decoding and hashing every frame of a
    /// long-GOP recording is slower than reading its bytes.
    static func decodeDeadlineSeconds(bytes: Int64, layout: FileLayout) -> Double {
        let stated = (layout.carried.compactMap(\.statedSeconds) + layout.sound.compactMap(\.statedSeconds)).max() ?? 0
        return max(AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes), 2 * stated)
    }

    // MARK: - The decode pass (pure fold)

    /// What the decode pass's frames folded to.
    struct Played: Sendable, Equatable {
        /// By input stream index.
        var pictures: [Int: PictureRead] = [:]
        var soundSegments: [SoundSegment] = []
        var channelSHA256: [String] = []
        var channelSamples: [Int64] = []
        /// Lines folded, by output stream number.
        var folded: [Int: Int] = [:]
    }

    /// Folds the decode pass's framehash lines as they arrive. Bounded: one
    /// SHA-256 state and a few numbers per output stream, and the sound's
    /// timeline (at most `soundSegmentLimit` runs). The first line that
    /// cannot be read is kept as the fault and ends the proof.
    /// (`@unchecked Sendable`: as `PacketLedger`.)
    final class FrameLedger: @unchecked Sendable {
        enum Role: Sendable, Equatable {
            case picture(input: Int)
            case timeline
            case channel(Int)
        }
        private struct Stream {
            var role: Role
            var numerator: Int64 = 0
            var denominator: Int64 = 0
            var lines = 0
            var hash = SHA256()
            var samples: Int64 = 0
            var firstSeconds = 0.0
            var endSeconds = 0.0
        }
        private let lock = NSLock()
        private var streams: [Stream]
        private var segments: [SoundSegment] = []
        private var firstFault: String?
        private let sampleRateHz: Int64
        private let tolerance: Int64

        init(roles: [Role], sampleRateHz: Int) {
            streams = roles.map { Stream(role: $0) }
            self.sampleRateHz = Int64(sampleRateHz)
            tolerance = Int64(BalancedCopyProof.soundTimingToleranceSamples)
        }

        /// One line of the framehash muxer's output.
        func note(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            guard firstFault == nil, !line.isEmpty else { return }
            if !(line.hasPrefix("#") ? header(line) : frame(line)) { firstFault = line }
        }

        /// "#tb 0: 1/12800", "#dimensions 0: 320x240", "#sar 0: 1/1": the
        /// time base is needed to read a stream's times; a picture's size
        /// and sample aspect ratio are part of what is shown, so they are
        /// folded in. Every other "#" line describes the muxer.
        private func header(_ line: String) -> Bool {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count == 3, words[1].hasSuffix(":"), let number = Int(words[1].dropLast()),
                  ["#tb", "#dimensions", "#sar"].contains(words[0]) else { return true }
            guard streams.indices.contains(number), streams[number].lines == 0 else { return false }
            if words[0] == "#tb" {
                let parts = words[2].split(separator: "/").compactMap { Int64($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return false }
                (streams[number].numerator, streams[number].denominator) = (parts[0], parts[1])
            } else if case .picture = streams[number].role {
                streams[number].hash.update(data: Data("\(words[0]) \(words[2])\n".utf8))
            }
            return true
        }

        /// "stream, dts, pts, duration, size, sha256".
        private func frame(_ line: String) -> Bool {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6, let number = Int(fields[0]), streams.indices.contains(number),
                  let pts = Int64(fields[2]), let duration = Int64(fields[3]), duration >= 0,
                  let size = Int64(fields[4]), size > 0, let pixels = BalancedCopyProof.digest(fields[5][...]) else {
                return false
            }
            var stream = streams[number]
            guard stream.numerator > 0 else { return false }
            stream.lines += 1
            switch stream.role {
            case .picture:
                guard let at = BalancedCopyProof.fraction(ticks: pts, numerator: stream.numerator,
                                                          denominator: stream.denominator),
                      let lasting = BalancedCopyProof.fraction(ticks: duration, numerator: stream.numerator,
                                                              denominator: stream.denominator) else { return false }
                stream.hash.update(data: Data("\(at) \(lasting) \(size) \(pixels)\n".utf8))
                let tick = Double(stream.numerator) / Double(stream.denominator)
                if stream.lines == 1 { stream.firstSeconds = Double(pts) * tick }
                stream.endSeconds = max(stream.endSeconds, Double(pts + duration) * tick)
            case .timeline:
                // The sound's times must be in sample periods: then a
                // frame's duration IS its sample count.
                guard stream.numerator == 1, stream.denominator == sampleRateHz, duration > 0 else { return false }
                if let last = segments.indices.last, abs(pts - (segments[last].start + segments[last].samples)) <= tolerance {
                    segments[last].samples += duration
                } else {
                    guard segments.count < BalancedCopyProof.soundSegmentLimit else { return false }
                    segments.append(SoundSegment(start: pts, samples: duration))
                }
            case .channel:
                guard stream.numerator == 1, stream.denominator == sampleRateHz else { return false }
                stream.hash.update(data: Data("\(size) \(pixels)\n".utf8))
                stream.samples += duration
            }
            streams[number] = stream
            return true
        }

        /// The line that could not be read, if any.
        var fault: String? {
            lock.lock()
            defer { lock.unlock() }
            return firstFault
        }

        var played: Played {
            lock.lock()
            defer { lock.unlock() }
            var out = Played(soundSegments: segments)
            for (number, stream) in streams.enumerated() {
                out.folded[number] = stream.lines
                switch stream.role {
                case .picture(let input):
                    out.pictures[input] = PictureRead(frames: stream.lines, sha256: BalancedCopyProof.hex(stream.hash),
                                                      firstSeconds: stream.firstSeconds, endSeconds: stream.endSeconds)
                case .timeline: break
                case .channel:
                    out.channelSHA256.append(BalancedCopyProof.hex(stream.hash))
                    out.channelSamples.append(stream.samples)
                }
            }
            return out
        }
    }

    // MARK: - The decode pass's log (pure parse)

    /// One ffmpeg log line under `-v level+…`:
    /// "[in#0/mov @ 0x…] [verbose] payload" → components, level, payload.
    struct LogRecord: Equatable {
        var components: [Substring]
        var level: Substring
        var payload: Substring
    }

    /// Levels `-v error` would have kept quiet.
    static let quietLogLevels: Set<Substring> = ["warning", "info", "verbose", "debug", "trace"]
    /// Levels `-v error` prints. One line at any of them refuses the pass.
    static let loudLogLevels: Set<Substring> = ["error", "fatal", "panic"]
    /// What ffmpeg logs last, at verbose, when it finished in order.
    static let cleanExitPayload = "Exiting with exit code 0"

    /// Split a log line into its "[component @ 0x…]" prefixes, its level and
    /// its payload. nil = the line does not START that way.
    static func logRecord(_ line: Substring) -> LogRecord? {
        var rest = line
        var components: [Substring] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            let tail = after.hasPrefix(" ") ? after.dropFirst() : after
            if quietLogLevels.contains(inner) || loudLogLevels.contains(inner) {
                return LogRecord(components: components, level: inner, payload: tail)
            }
            guard inner.contains(" @ 0x") else { return nil }
            components.append(inner)
            rest = tail
        }
        return nil
    }

    /// A line with no level of its own that ffmpeg legitimately prints: the
    /// continuation of a multi-line METADATA value, which its dump indents.
    /// Tolerated only straight after an info-level line, and never parsed.
    static func isMetadataContinuation(_ line: Substring) -> Bool {
        let blanks = line.prefix(while: { $0 == " " }).count
        return blanks >= 16 && line.dropFirst(blanks).hasPrefix(": ")
    }

    /// The digits straight before `marker` in `text` ("94 packets read").
    static func count(before marker: String, in text: Substring) -> Int64? {
        guard let found = text.range(of: marker) else { return nil }
        let digits = text[..<found.lowerBound].reversed().prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int64(String(digits.reversed()))
    }

    /// "Input stream #0:1 (audio): 94 packets read (…); 94 frames decoded; 0
    /// decode errors (…);" → (1, "packets read" count, decode errors), or
    /// "Output stream #0:0 (video): 50 frames encoded; 50 packets muxed (…);"
    /// → (0, "packets muxed" count, nil). nil = not such a line.
    static func streamCount(fromPayload payload: Substring, side: String, counting marker: String)
        -> (index: Int, count: Int, decodeErrors: Int?)? {
        let text = payload.drop(while: { $0 == " " })
        let opening = "\(side) stream #0:"
        guard text.hasPrefix(opening) else { return nil }
        let rest = text.dropFirst(opening.count)
        guard let index = Int(rest.prefix(while: { $0.isASCII && $0.isNumber })),
              let found = count(before: marker, in: rest) else { return nil }
        return (index, Int(found), count(before: " decode errors", in: rest).map { Int($0) })
    }

    /// Why a decode pass's log does not vouch for the read; `line` is quoted.
    struct ReadFault: Error, Equatable {
        var line: String
    }

    /// Read one decode pass's whole log into the log's half of a
    /// `ReadReport`. Success = every line was one `-v error` would have kept
    /// quiet, the log ends with ffmpeg's own clean exit line, and no stream
    /// is accounted for twice. `runTag` names this run's astats instances.
    static func readReport(fromStderr text: String, runTag: String) -> Result<ReadReport, ReadFault> {
        var report = ReadReport()
        var announced: [Int: Int] = [:]
        var last: LogRecord?
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let record = logRecord(line) else {
                if last?.level == "info", isMetadataContinuation(line) { continue }
                return .failure(ReadFault(line: String(line)))
            }
            guard quietLogLevels.contains(record.level) else { return .failure(ReadFault(line: String(line))) }
            last = record
            let peaks = "astats@\(runTag)s"
            if !runTag.isEmpty, let component = record.components.first, component.hasPrefix(peaks) {
                guard let stream = Int(component.dropFirst(peaks.count).prefix(while: { $0.isASCII && $0.isNumber })),
                      notePeak(record.payload, stream: stream, announced: &announced, in: &report) else {
                    return .failure(ReadFault(line: String(line)))
                }
            } else if let read = streamCount(fromPayload: record.payload, side: "Input", counting: " packets read") {
                let entry = StreamRead(packets: read.count, decodeErrors: read.decodeErrors)
                guard report.streams.updateValue(entry, forKey: read.index) == nil else {
                    return .failure(ReadFault(line: String(line)))
                }
            } else if let wrote = streamCount(fromPayload: record.payload, side: "Output", counting: " packets muxed") {
                guard report.muxed.updateValue(wrote.count, forKey: wrote.index) == nil else {
                    return .failure(ReadFault(line: String(line)))
                }
            }
        }
        guard let last, last.payload == cleanExitPayload else {
            return .failure(ReadFault(line: text.split(whereSeparator: \.isNewline).last.map(String.init)
                                        ?? "ffmpeg reported nothing about what it read"))
        }
        return .success(report)
    }

    /// One line of a run's astats for one sound stream: "Channel: N" opens
    /// channel N (they come 1, 2, … in order), "Peak level dB: v" is its
    /// peak. false = not exactly one peak per channel, in order.
    private static func notePeak(_ payload: Substring, stream: Int, announced: inout [Int: Int],
                                 in report: inout ReadReport) -> Bool {
        let measured = report.peaksDBFS[stream]?.count ?? 0
        if payload.hasPrefix("Channel:") {
            let number = Int(payload.dropFirst("Channel:".count).trimmingCharacters(in: .whitespaces))
            announced[stream, default: 0] += 1
            return number == announced[stream] && measured == (announced[stream] ?? 0) - 1
        }
        if payload.hasPrefix("Peak level dB:") {
            guard let peak = AstatsOutputParser.parsedDB(String(payload.dropFirst("Peak level dB:".count))),
                  measured == (announced[stream] ?? 0) - 1 else { return false }
            report.peaksDBFS[stream, default: []].append(peak)
        }
        return true
    }

    // MARK: - Measurement (I/O, read only)

    /// The two tools. `located` is production; a test points one at
    /// /usr/bin/false, or at a script, to see a failure path.
    struct Tools: Sendable {
        var ffmpeg: String
        var ffprobe: String
        /// Test seam: called once, right after the closing identity stamps
        /// were taken and before they are judged. Production leaves it nil.
        var afterFinalStamps: (@Sendable () -> Void)?

        init(ffmpeg: String, ffprobe: String, afterFinalStamps: (@Sendable () -> Void)? = nil) {
            self.ffmpeg = ffmpeg
            self.ffprobe = ffprobe
            self.afterFinalStamps = afterFinalStamps
        }

        static var located: Tools { Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: ToolLocator.ffprobePath) }
    }

    /// A measurement step's failure, already in the caller's words.
    private struct Unchecked: Error { let reason: String }

    /// Both files as found: each given path resolved once (`realpath`), and
    /// the identity stamp of what it resolved to.
    private struct Located {
        var original: String
        var balanced: String
        var stamps: [FileIdentityStamp]

        /// The same two paths resolve to the same two unchanged files.
        func stillDescribes(_ now: Located) -> Bool {
            original == now.original && balanced == now.balanced
                && stamps[0].describesSameFile(now: now.stamps[0], volume: .sameOperation)
                && stamps[1].describesSameFile(now: now.stamps[1], volume: .sameOperation)
        }
    }

    /// Measure both files and decide. Never throws: every failure is an
    /// `Outcome` (`couldNotCheck` when nothing could be measured). The
    /// caller writes `startLine` before and `logLine` after, through the
    /// app's one log sink.
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
        // Every tool below is handed the RESOLVED paths, never the given ones.
        let files = try located(original: original, balanced: balanced)
        guard FileManager.default.isExecutableFile(atPath: tools.ffmpeg),
              FileManager.default.isExecutableFile(atPath: tools.ffprobe) else {
            throw Unchecked(reason: "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }
        let analysis: AudioBalanceAnalysis
        do {
            analysis = try await AudioBalanceProbe.analyze(path: files.original, control: control)
        } catch AudioBalanceProbeError.noAudioStream {
            return .notProven(.originalSoundTracks(0))
        } catch let error as AudioBalanceProbeError {
            throw Unchecked(reason: "the original's sound could not be measured — \(error.localizedDescription)")
        }
        var facts = Facts(
            original: try await header(of: files.original, called: "the original", tools: tools, control: control),
            balanced: try await header(of: files.balanced, called: "the balanced copy", tools: tools, control: control),
            originalClass: analysis.classification,
            originalMeasuredInFull: analysis.measuredSilent != nil,
            keptSoundIndex: analysis.programStreamIndex)
        if let verdict = headerVerdict(facts) { return verdict }
        facts.original = try await packets(of: files.original, bytes: files.stamps[0].size, called: "the original",
                                           layout: facts.original, tools: tools, control: control)
        facts.balanced = try await packets(of: files.balanced, bytes: files.stamps[1].size, called: "the balanced copy",
                                           layout: facts.balanced, tools: tools, control: control)
        if case .success(let pairing) = pairing(original: facts.original.carried, balanced: facts.balanced.carried),
           let verdict = packetVerdict(facts, pairing: pairing) {
            return verdict
        }
        try await decode(&facts, files: files, analysis: analysis, tools: tools, control: control)

        // Both given paths must still resolve to the files that were opened
        // at the start, unchanged: a file rewritten, swapped or re-pointed
        // mid-measurement was not measured.
        let after = try located(original: original, balanced: balanced)
        tools.afterFinalStamps?()
        guard files.stillDescribes(after) else {
            throw Unchecked(reason: "a file changed while it was being checked")
        }
        // The last word before any verdict: a check that was stopped — even
        // during the closing stamps — proves nothing.
        try Task.checkCancellation()
        func stamped(_ evidence: Evidence) -> Evidence {
            var out = evidence
            out.originalStamp = files.stamps[0]
            out.balancedStamp = files.stamps[1]
            out.originalResolvedPath = files.original
            out.balancedResolvedPath = files.balanced
            return out
        }
        switch decide(facts) {
        case .proven(let evidence): return .proven(stamped(evidence))
        case .sameContent(let evidence, let differs): return .sameContent(stamped(evidence), differs: differs)
        case let other: return other
        }
    }

    /// Run both decode passes and write what they found into `facts`.
    private static func decode(_ facts: inout Facts, files: Located, analysis: AudioBalanceAnalysis,
                               tools: Tools, control: ProcessControl?) async throws {
        guard let live = liveChannel(for: facts.originalClass), let kept = keptSound(facts),
              let copySound = facts.balanced.sound.first,
              let codec = hashCodec(forSampleFormat: kept.sampleFormat) else {
            throw Unchecked(reason: "the two files' streams could not be lined up")
        }
        func pictures(_ file: FileLayout) -> [DecodePlan.Picture] {
            file.pictures.map { DecodePlan.Picture(index: $0.index, pixelFormat: $0.configuration.pixelFormat) }
        }
        let source = DecodePlan(
            pictures: pictures(facts.original), soundIndex: kept.index, sampleFormat: kept.sampleFormat,
            sampleRateHz: kept.sampleRateHz, channels: [live], measured: facts.original.sound.map(\.index),
            runTag: AstatsOutputParser.newRunTag())
        let copy = DecodePlan(
            pictures: pictures(facts.balanced), soundIndex: copySound.index, sampleFormat: copySound.sampleFormat,
            sampleRateHz: copySound.sampleRateHz, channels: [0, 1])
        facts.originalRead = try await played(
            files.original, bytes: files.stamps[0].size, called: "the original", layout: facts.original,
            inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape), plan: source, hashCodec: codec,
            tools: tools, control: control)
        facts.balancedRead = try await played(
            files.balanced, bytes: files.stamps[1].size, called: "the balanced copy", layout: facts.balanced,
            inputArgs: [], plan: copy, hashCodec: codec, tools: tools, control: control)
    }

    /// Resolve both given paths and stamp what they resolve to.
    private static func located(original: String, balanced: String) throws -> Located {
        let a = try resolved(original, called: "the original")
        let b = try resolved(balanced, called: "the balanced copy")
        return Located(original: a, balanced: b, stamps: try fileStamps(original: a, balanced: b))
    }

    /// `realpath` of a given path — refused when the path's last component
    /// is itself a symbolic link (`lstat`): a link can be pointed at another
    /// file between two opens without the file it named ever changing.
    private static func resolved(_ path: String, called name: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Unchecked(reason: "\(name) is not on disk, or cannot be read")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw Unchecked(reason: "\(name) is a symbolic link — the check needs the file itself, not a link to it")
        }
        guard let real = realpath(path, nil) else {
            throw Unchecked(reason: "\(name) is not on disk, or cannot be read")
        }
        defer { free(real) }
        return String(cString: real)
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
        // hard link to the original is the original.
        guard !a.describesSameFile(now: b, volume: .sameOperation) else {
            throw Unchecked(reason: "the original and the balanced copy are the same file")
        }
        return [a, b]
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// One header read: ffprobe's JSON, or nil when it failed.
    private static func probed(_ arguments: [String], tools: Tools, control: ProcessControl?) async throws -> Data? {
        let run = await ProcessRunner.runProcess(
            executable: tools.ffprobe, arguments: arguments,
            stdoutLimitBytes: 1 << 20, deadlineSeconds: 60, control: control)
        try Task.checkCancellation()
        return run.exitCode == 0 ? run.stdout?.data(using: .utf8) : nil
    }

    /// One file's streams, from its header — and, for the QuickTime family,
    /// what each track stores with the edit list ignored.
    private static func header(of path: String, called name: String, tools: Tools,
                               control: ProcessControl?) async throws -> FileLayout {
        guard let data = try await probed(layoutArgs(input: path), tools: tools, control: control),
              let layout = layout(fromProbeJSON: data) else {
            throw Unchecked(reason: "\(name) could not be read as media")
        }
        guard layout.hasEditLists else { return layout }
        guard let stored = try await probed(storedArgs(input: path), tools: tools, control: control),
              let full = withStoredLengths(layout, fromProbeJSON: stored) else {
            throw Unchecked(reason: "\(name)'s stored track lengths could not be read")
        }
        return full
    }

    /// The packet pass over one file, folded into its layout. It reads the
    /// whole container, so its deadline is the levels pass's, scaled to the
    /// file's size. ffprobe is not given the decode pass's raw-DV `-r`: raw
    /// DV's packet times are k × 1001/30000 without it (measured), the same
    /// fractions the job's QuickTime copy states.
    private static func packets(of path: String, bytes: Int64, called name: String, layout: FileLayout,
                                tools: Tools, control: ProcessControl?) async throws -> FileLayout {
        let ledger = PacketLedger(layout: layout)
        let deadline = AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes)
        let pass = await ProcessRunner.runProcess(
            executable: tools.ffprobe, arguments: packetArgs(input: path),
            stdoutLine: { ledger.note($0) }, stdoutLimitBytes: 0, deadlineSeconds: deadline, control: control)
        try Task.checkCancellation()
        guard pass.exitCode == 0 else {
            throw Unchecked(reason: pass.timedOut
                ? "reading \(name) ran out of time after \(Int(deadline)) seconds"
                : "\(name) could not be read packet by packet (ffprobe status \(pass.exitCode))")
        }
        // ffprobe ran at `-v error`: one word on stderr is an error.
        if let said = pass.stderr.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) {
            throw Unchecked(reason: "\(name) could not be read packet by packet (ffprobe exited 0 but said: \(said))")
        }
        if let fault = ledger.fault {
            throw Unchecked(reason: "\(name) could not be read packet by packet (unreadable packet line: \(fault))")
        }
        return filled(layout, with: ledger.sequences)
    }

    /// Cap on a decode pass's collected log. The log is a few KiB plus the
    /// file's metadata; one that fills the cap has lost its closing lines.
    private static let decodeLogLimitBytes = 256 * 1024

    /// One decode pass over one file: ffmpeg's account of the read, joined
    /// with what its frames folded to.
    private static func played(_ path: String, bytes: Int64, called name: String, layout: FileLayout,
                               inputArgs: [String], plan: DecodePlan, hashCodec: String, tools: Tools,
                               control: ProcessControl?) async throws -> ReadReport {
        let ledger = FrameLedger(roles: plan.roles, sampleRateHz: plan.sampleRateHz)
        let deadline = decodeDeadlineSeconds(bytes: bytes, layout: layout)
        let result = await ProcessRunner.runProcess(
            executable: tools.ffmpeg,
            arguments: decodeArgs(input: path, inputArgs: inputArgs, plan: plan, hashCodec: hashCodec),
            stdoutLine: { ledger.note($0) }, stdoutLimitBytes: 0, stderrLimitBytes: decodeLogLimitBytes,
            deadlineSeconds: deadline, control: control)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            if result.timedOut {
                throw Unchecked(reason: "decoding \(name) ran out of time after \(Int(deadline)) seconds")
            }
            let tail = result.stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " · ")
            throw Unchecked(reason: "\(name) could not be decoded to the end (ffmpeg status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)"))")
        }
        guard result.stderr.utf8.count < decodeLogLimitBytes else {
            throw Unchecked(reason: "\(name) could not be decoded to the end (ffmpeg said more than can be checked)")
        }
        var read: ReadReport
        switch readReport(fromStderr: result.stderr, runTag: plan.runTag) {
        case .success(let report): read = report
        case .failure(let fault):
            throw Unchecked(reason: "\(name) could not be decoded to the end (ffmpeg exited 0 but said: \(fault.line))")
        }
        if let fault = ledger.fault {
            throw Unchecked(reason: "\(name) could not be decoded to the end (unreadable frame line: \(fault))")
        }
        let frames = ledger.played
        read.folded = frames.folded
        read.pictures = frames.pictures
        read.soundSegments = frames.soundSegments
        read.channelSHA256 = frames.channelSHA256
        read.channelSamples = frames.channelSamples
        return read
    }
}
