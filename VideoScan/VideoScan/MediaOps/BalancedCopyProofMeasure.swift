// BalancedCopyProofMeasure.swift
// The measuring half of BalancedCopyProof (rules, outcomes and the header
// that says what PROVEN means: BalancedCopyProof.swift). READ ONLY: both
// files are opened for reading through ffprobe/ffmpeg; nothing is written.
//
// Per file, each by its own tool run:
//   1. ffprobe `-show_streams -show_format -show_data_hash sha256` (header
//      only): the stream list, each stream's decoder configuration, side
//      data and time base, the sound's stated times.
//   2. THE PACKET PASS — ffprobe `-show_packets -show_data_hash sha256`,
//      one CSV line per packet (stream, pts, duration, size, SHA-256 of
//      payload). An hour of DV is ~108,000 lines, so the lines are never
//      collected: ProcessRunner hands each one to `PacketLedger` as it
//      arrives, which folds it into two running SHA-256 per carried stream
//      (times; sizes + payload hashes) and a count per stream. Anything on
//      its stderr, a line it cannot read, or a time it cannot express as
//      an exact fraction is COULD NOT CHECK.
//   3. THE SOUND PASS — one ffmpeg run that hashes the sound's channels
//      (`-f streamhash`) and, in the same read, stream-copies every other
//      stream to the null muxer, run with `-xerror -err_detect explode`.
//      From its log: packets read per input stream, sound samples decoded,
//      and (original only) every channel's peak from an `astats` instance
//      named for the run. `decide` holds those packet counts against the
//      packet pass's, so a sound pass that stopped early is refused.
//
// Why the sound pass logs at `repeat+level+verbose` and not `error`: the
// per-stream read counts exist only at verbose. Every line then carries its
// level, and the rule the review asked for ("anything on stderr at -v error
// is could-not-check") is kept as: any line at error/fatal/panic, any line
// that carries no level and is not an indented metadata continuation, and
// any output that does not END with ffmpeg's own "Exiting with exit code 0"
// — each one is COULD NOT CHECK, quoting the line.
//
// Memory: two ffprobe JSON documents (1 MiB cap each), the packet ledger
// (two SHA-256 states and three integers per stream — the packet lines
// themselves are not kept), the sound-hash lines (64 KiB cap) and one
// pass's log at a time (256 KiB cap; a log that long has lost its closing
// lines and is refused) — under 3 MiB whatever the size of the media.

import CryptoKit
import Darwin
import Foundation
import os
import VideoScanCore

private let proofLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "balancedCopyProof")

extension BalancedCopyProof {

    // MARK: - ffprobe layout (pure parse)

    /// ffprobe request for one file's streams and format, whole (so that
    /// every stream's `side_data_list` is there), with extradata hashes.
    /// Reads the header only.
    static func layoutArgs(input: String) -> [String] {
        ["-v", "error", "-show_data_hash", "sha256", "-show_streams", "-show_format", "-of", "json", input]
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
        let start_time: String?
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

        var timing: StreamTiming {
            StreamTiming(
                startSeconds: BalancedCopyProof.seconds(start_time),
                // Matroska states a stream's length only as a DURATION tag.
                durationSeconds: BalancedCopyProof.seconds(duration)
                    ?? AudioBalanceProbe.seconds(fromDurationTag: tags?["DURATION"]),
                tickSeconds: BalancedCopyProof.tick(time_base), packets: nil)
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
        let duration: String?
    }
    private struct ProbeReport: Decodable {
        let streams: [ProbedStream]?
        let format: ProbedFormat?
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
    /// (keys sorted) — whatever it holds: a display matrix and its
    /// rotation, CPB properties, … "" = the stream lists none. nil = the
    /// document is not ffprobe's, or a list cannot be written back out.
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
    /// lists no stream at all (not a media file). Packets are not in it:
    /// the packet pass fills them in.
    static func layout(fromProbeJSON data: Data) -> FileLayout? {
        guard let report = try? JSONDecoder().decode(ProbeReport.self, from: data),
              let streams = report.streams, !streams.isEmpty,
              let sideData = sideData(fromProbeJSON: data), sideData.count == streams.count else { return nil }
        var layout = FileLayout(container: report.format?.format_name ?? "",
                                durationSeconds: seconds(report.format?.duration))
        for (position, s) in streams.enumerated() {
            let index = s.index ?? position
            if s.codec_type == "audio" {
                layout.sound.append(SoundStream(
                    index: index, codec: s.codec_name ?? "", sampleFormat: s.sample_fmt ?? "",
                    sampleRateHz: s.sample_rate.flatMap { Int($0) } ?? 0, channels: s.channels ?? 0,
                    channelLayout: s.channel_layout ?? "", sideData: sideData[position], timing: s.timing))
            } else {
                layout.carried.append(CarriedStream(
                    index: index, kind: s.codec_type ?? "", codec: s.codec_name ?? "",
                    tag: s.codec_tag_string ?? "", timeBase: s.time_base ?? "",
                    configuration: s.configuration(sideData: sideData[position])))
            }
        }
        return layout
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
            // which is folded with the packet's bytes: equal, or refused.
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
                      fields[4].hasPrefix("SHA256:"), fields[4].count == 71,
                      fields[4].dropFirst(7).allSatisfy(\.isHexDigit) else { return false }
                stream.timing.update(data: Data("\(at) \(lasting)\n".utf8))
                stream.payload.update(data: Data("\(size) \(fields[4].dropFirst(7).lowercased())\(sideData)\n".utf8))
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
            func hex(_ hasher: SHA256) -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
            return streams.mapValues {
                PacketSequence(packets: $0.packets, timingSHA256: hex($0.timing), packetSHA256: hex($0.payload))
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
        for i in out.sound.indices { out.sound[i].timing.packets = sequences[out.sound[i].index]?.packets }
        return out
    }

    // MARK: - ffmpeg sound pass (pure builders + parse)

    /// Filter graph for the ORIGINAL's audio stream: measure every channel's
    /// peak (`astats` reads the samples and passes them on untouched; the
    /// instance is named for this run so nothing in the file can forge its
    /// lines), then pick the one live channel. `channelmap` moves samples;
    /// it never does arithmetic on them.
    static func originalSoundFilter(streamIndex: Int, liveChannel: Int, runTag: String) -> String {
        "[0:\(streamIndex)]astats@\(runTag)=measure_perchannel=Peak_level:measure_overall=none,"
            + "channelmap=map=\(liveChannel):channel_layout=mono[live]"
    }

    /// Filter graph that splits the copy's audio into its two channels.
    static func balancedSoundFilter(streamIndex: Int) -> String {
        "[0:\(streamIndex)]asplit[a][b];"
            + "[a]channelmap=map=0:channel_layout=mono[left];"
            + "[b]channelmap=map=1:channel_layout=mono[right]"
    }

    /// One pass, two outputs. First: each named filter output hashed as raw
    /// PCM (`-c:a <hashCodec>`, no `-ar`, so nothing is resampled) by the
    /// streamhash muxer, one line per output, in map order. Second, when
    /// the file has carried streams: all of them stream-copied to the null
    /// muxer — nothing is kept of them here (the packet pass holds them);
    /// they are mapped so that THIS read's per-stream packet counts cover
    /// every stream. `-xerror` and `-err_detect explode` make a read or
    /// decode error fatal; the log level is explained in the file header.
    /// `inputArgs` are demuxer options (the raw-DV `-r`), before `-i`.
    static func hashArgs(input: String, inputArgs: [String], carriedIndices: [Int], soundFilter: String,
                         soundOutputs: [String], hashCodec: String) -> [String] {
        var args = ["-v", "repeat+level+verbose", "-nostdin", "-nostats", "-hide_banner", "-xerror",
                    "-err_detect", "explode"]
            + inputArgs + ["-i", input, "-filter_complex", soundFilter]
        for output in soundOutputs { args += ["-map", "[\(output)]"] }
        args += ["-c:a", hashCodec, "-f", "streamhash", "-hash", "sha256", "-"]
        guard !carriedIndices.isEmpty else { return args }
        for index in carriedIndices { args += ["-map", "0:\(index)"] }
        return args + ["-c", "copy", "-f", "null", "-"]
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

    // MARK: - The hash pass's log (pure parse)

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
    /// its payload. nil = the line does not START that way (it carries no
    /// level of its own).
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
    /// continuation of a multi-line METADATA value, which its dump indents
    /// ("<indent>  <16 blanks>: rest"). Tolerated only straight after an
    /// info-level line, and never parsed for anything.
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

    /// "Input stream #0:1 (audio): 94 packets read (384000 bytes); 94 frames
    /// decoded; 0 decode errors (96000 samples);" → stream 1's read. nil =
    /// not such a line, or one that names no packet count.
    static func streamRead(fromPayload payload: Substring) -> (index: Int, read: StreamRead)? {
        let marker = "Input stream #0:"
        let text = payload.drop(while: { $0 == " " })
        guard text.hasPrefix(marker) else { return nil }
        let rest = text.dropFirst(marker.count)
        guard let index = Int(rest.prefix(while: { $0.isASCII && $0.isNumber })),
              let packets = count(before: " packets read", in: rest) else { return nil }
        return (index, StreamRead(packets: Int(packets), samples: count(before: " samples)", in: rest),
                                  decodeErrors: count(before: " decode errors", in: rest).map { Int($0) }))
    }

    /// Why a hash pass's log does not vouch for the read; `line` is quoted.
    struct ReadFault: Error, Equatable {
        var line: String
    }

    /// Read one hash pass's whole log. Success = every line was one `-v
    /// error` would have kept quiet, the log ends with ffmpeg's own clean
    /// exit line, and no input stream is accounted for twice. `runTag`
    /// names this run's astats instance (nil = the pass has none).
    static func readReport(fromStderr text: String, runTag: String?) -> Result<ReadReport, ReadFault> {
        var report = ReadReport()
        var last: LogRecord?
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let record = logRecord(line) else {
                if last?.level == "info", isMetadataContinuation(line) { continue }
                return .failure(ReadFault(line: String(line)))
            }
            guard quietLogLevels.contains(record.level) else { return .failure(ReadFault(line: String(line))) }
            last = record
            if let runTag, record.components.first?.hasPrefix("astats@\(runTag) @ ") == true {
                guard notePeak(record.payload, in: &report) else { return .failure(ReadFault(line: String(line))) }
            } else if let stream = streamRead(fromPayload: record.payload) {
                guard report.streams.updateValue(stream.read, forKey: stream.index) == nil else {
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

    /// One line of this run's astats: "Channel: N" opens channel N (they
    /// come 1, 2, … in order), "Peak level dB: v" is its peak. false = the
    /// lines do not read as exactly one peak per channel, in order.
    private static func notePeak(_ payload: Substring, in report: inout ReadReport) -> Bool {
        if payload.hasPrefix("Channel:") {
            let number = Int(payload.dropFirst("Channel:".count).trimmingCharacters(in: .whitespaces))
            report.channelsAnnounced += 1
            return number == report.channelsAnnounced && report.channelPeaksDBFS.count == report.channelsAnnounced - 1
        }
        if payload.hasPrefix("Peak level dB:") {
            guard let peak = AstatsOutputParser.parsedDB(String(payload.dropFirst("Peak level dB:".count))),
                  report.channelPeaksDBFS.count == report.channelsAnnounced - 1 else { return false }
            report.channelPeaksDBFS.append(peak)
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
            originalMeasuredInFull: analysis.measuredSilent != nil)
        if let verdict = headerVerdict(facts) { return verdict }
        facts.original = try await packets(of: files.original, bytes: files.stamps[0].size, called: "the original",
                                           layout: facts.original, tools: tools, control: control)
        facts.balanced = try await packets(of: files.balanced, bytes: files.stamps[1].size, called: "the balanced copy",
                                           layout: facts.balanced, tools: tools, control: control)
        if let verdict = layoutVerdict(facts) { return verdict }
        try await hash(&facts, files: files, analysis: analysis, tools: tools, control: control)

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
        let outcome = decide(facts)
        guard case .proven(var evidence) = outcome else { return outcome }
        evidence.originalStamp = files.stamps[0]
        evidence.balancedStamp = files.stamps[1]
        evidence.originalResolvedPath = files.original
        evidence.balancedResolvedPath = files.balanced
        return .proven(evidence)
    }

    /// Run both sound passes and write what they found into `facts`.
    private static func hash(_ facts: inout Facts, files: Located, analysis: AudioBalanceAnalysis,
                             tools: Tools, control: ProcessControl?) async throws {
        guard let live = liveChannel(for: facts.originalClass), let sourceSound = facts.original.sound.first,
              let copySound = facts.balanced.sound.first,
              let codec = hashCodec(forSampleFormat: sourceSound.sampleFormat) else {
            throw Unchecked(reason: "the two files' streams could not be lined up")
        }
        let runTag = AstatsOutputParser.newRunTag()
        let source = try await hashes(
            of: files.original, bytes: files.stamps[0].size, called: "the original",
            carried: facts.original.carried.map(\.index),
            inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape),
            soundFilter: originalSoundFilter(streamIndex: sourceSound.index, liveChannel: live, runTag: runTag),
            soundOutputs: ["live"], hashCodec: codec, runTag: runTag, tools: tools, control: control)
        let copy = try await hashes(
            of: files.balanced, bytes: files.stamps[1].size, called: "the balanced copy",
            carried: facts.balanced.carried.map(\.index),
            inputArgs: [], soundFilter: balancedSoundFilter(streamIndex: copySound.index),
            soundOutputs: ["left", "right"], hashCodec: codec, runTag: nil, tools: tools, control: control)
        facts.originalLiveSHA256 = source.digests[0]
        facts.balancedLeftSHA256 = copy.digests[0]
        facts.balancedRightSHA256 = copy.digests[1]
        facts.originalRead = source.read
        facts.balancedRead = copy.read
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

    /// One file's streams, from its header.
    private static func header(of path: String, called name: String, tools: Tools,
                               control: ProcessControl?) async throws -> FileLayout {
        let header = await ProcessRunner.runProcess(
            executable: tools.ffprobe, arguments: layoutArgs(input: path),
            stdoutLimitBytes: 1 << 20, deadlineSeconds: 60, control: control)
        try Task.checkCancellation()
        guard header.exitCode == 0, let data = header.stdout?.data(using: .utf8),
              let layout = layout(fromProbeJSON: data) else {
            throw Unchecked(reason: "\(name) could not be read as media (ffprobe status \(header.exitCode))")
        }
        return layout
    }

    /// The packet pass over one file, folded into its layout. It reads the
    /// whole container, so its deadline is the levels pass's, scaled to the
    /// file's size. ffprobe is not given the sound pass's raw-DV `-r`: raw
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

    /// What one sound pass gave: one digest per sound output, and its own
    /// account of the read.
    private struct HashPass {
        var digests: [String]
        var read: ReadReport
    }

    /// Cap on the hash pass's collected log. The log is a few KiB plus the
    /// file's metadata; one that fills the cap has lost its closing lines.
    private static let hashLogLimitBytes = 256 * 1024

    /// One hash pass over one file. The deadline is the levels pass's (it
    /// scales with the file's size — both read the whole container).
    private static func hashes(of path: String, bytes: Int64, called name: String, carried: [Int],
                               inputArgs: [String], soundFilter: String, soundOutputs: [String],
                               hashCodec: String, runTag: String?, tools: Tools,
                               control: ProcessControl?) async throws -> HashPass {
        let deadline = AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes)
        let result = await ProcessRunner.runProcess(
            executable: tools.ffmpeg,
            arguments: hashArgs(input: path, inputArgs: inputArgs, carriedIndices: carried,
                                soundFilter: soundFilter, soundOutputs: soundOutputs, hashCodec: hashCodec),
            stdoutLimitBytes: 1 << 16, stderrLimitBytes: hashLogLimitBytes, deadlineSeconds: deadline,
            control: control)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            if result.timedOut {
                throw Unchecked(reason: "reading \(name) ran out of time after \(Int(deadline)) seconds")
            }
            let tail = result.stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " · ")
            throw Unchecked(reason: "\(name) could not be read to the end (ffmpeg status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)"))")
        }
        guard result.stderr.utf8.count < hashLogLimitBytes else {
            throw Unchecked(reason: "\(name) could not be read to the end (ffmpeg said more than can be checked)")
        }
        let read: ReadReport
        switch readReport(fromStderr: result.stderr, runTag: runTag) {
        case .success(let report): read = report
        case .failure(let fault):
            throw Unchecked(reason: "\(name) could not be read to the end (ffmpeg exited 0 but said: \(fault.line))")
        }
        guard let digests = streamHashes(fromStdout: result.stdout ?? "",
                                         expected: soundOutputs.count) else {
            throw Unchecked(reason: "\(name) did not give a hash for every stream")
        }
        return HashPass(digests: digests, read: read)
    }
}
