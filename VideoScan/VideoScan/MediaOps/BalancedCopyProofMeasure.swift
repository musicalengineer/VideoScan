// BalancedCopyProofMeasure.swift
// The measuring half of BalancedCopyProof (rules, outcomes and the header
// that says what PROVEN means: BalancedCopyProof.swift). READ ONLY: both
// files are opened for reading through ffprobe/ffmpeg; nothing is written.
//
// Three things are gathered per file, each by its own tool run:
//   1. ffprobe `-count_packets -show_data_hash sha256`: the stream list,
//      each stream's timing, packet count and decoder configuration.
//   2. ONE ffmpeg pass that hashes every stream (`-f streamhash`), run with
//      `-xerror -err_detect explode` so a read or decode error ends it.
//   3. That same pass's own account of what it read, from its log: packets
//      per input stream, sound samples decoded, and (original only) the
//      peak level of every channel from an `astats` instance named for the
//      run. `decide` holds (3) against (1), so a pass that stopped early
//      cannot agree with a copy that is short.
//
// Why the hash pass logs at `repeat+level+verbose` and not `error`: the
// per-stream read counts exist only at verbose. Every line then carries its
// level, and the rule the review asked for ("anything on stderr at -v error
// is could-not-check") is kept as: any line at error/fatal/panic, any line
// that carries no level and is not an indented metadata continuation, and
// any output that does not END with ffmpeg's own "Exiting with exit code 0"
// — each one is COULD NOT CHECK, quoting the line.
//
// Memory: two ffprobe JSON documents (1 MiB cap each), the hash lines
// (64 KiB cap) and one pass's log at a time (ProcessRunner's 256 KiB cap;
// a log that long has lost its closing lines and is refused) — under
// 3 MiB whatever the size of the media.

import Darwin
import Foundation
import os
import VideoScanCore

private let proofLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "balancedCopyProof")

extension BalancedCopyProof {

    // MARK: - ffprobe layout (pure parse)

    /// ffprobe request for one file: streams, timing, packet counts
    /// (`-count_packets` demuxes the whole file) and extradata hashes.
    static func layoutArgs(input: String) -> [String] {
        ["-v", "error", "-count_packets", "-show_data_hash", "sha256",
         "-show_entries",
         "stream=index,codec_type,codec_name,codec_tag_string,channels,channel_layout,sample_rate,sample_fmt,"
            + "start_time,duration,time_base,r_frame_rate,avg_frame_rate,nb_read_packets,extradata_hash,"
            + "width,height,pix_fmt,sample_aspect_ratio,display_aspect_ratio,field_order,"
            + "color_range,color_space,color_transfer,color_primaries"
            + ":stream_tags=DURATION:format=format_name,duration",
         "-of", "json", input]
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
        let r_frame_rate: String?
        let avg_frame_rate: String?
        let nb_read_packets: String?
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
                tickSeconds: BalancedCopyProof.tick(time_base),
                realFrameRate: r_frame_rate ?? "", averageFrameRate: avg_frame_rate ?? "",
                packets: nb_read_packets.flatMap { Int($0) })
        }

        var configuration: PictureConfiguration {
            PictureConfiguration(
                extradataSHA256: extradata_hash ?? "", width: width, height: height, pixelFormat: pix_fmt ?? "",
                sampleAspect: sample_aspect_ratio ?? "", displayAspect: display_aspect_ratio ?? "",
                fieldOrder: field_order ?? "", colorRange: color_range ?? "", colorSpace: color_space ?? "",
                colorTransfer: color_transfer ?? "", colorPrimaries: color_primaries ?? "")
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

    /// Decode ffprobe's JSON into a layout; nil when it is not that JSON or
    /// lists no stream at all (not a media file).
    static func layout(fromProbeJSON data: Data) -> FileLayout? {
        guard let report = try? JSONDecoder().decode(ProbeReport.self, from: data),
              let streams = report.streams, !streams.isEmpty else { return nil }
        var layout = FileLayout(container: report.format?.format_name ?? "",
                                durationSeconds: seconds(report.format?.duration))
        for (position, s) in streams.enumerated() {
            let index = s.index ?? position
            if s.codec_type == "audio" {
                layout.sound.append(SoundStream(
                    index: index, codec: s.codec_name ?? "", sampleFormat: s.sample_fmt ?? "",
                    sampleRateHz: s.sample_rate.flatMap { Int($0) } ?? 0, channels: s.channels ?? 0,
                    channelLayout: s.channel_layout ?? "", timing: s.timing))
            } else {
                layout.carried.append(CarriedStream(
                    index: index, kind: s.codec_type ?? "", codec: s.codec_name ?? "",
                    tag: s.codec_tag_string ?? "", packetSHA256: nil,
                    timing: s.timing, configuration: s.configuration))
            }
        }
        return layout
    }

    // MARK: - ffmpeg hash pass (pure builders + parse)

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

    /// One pass that hashes every carried stream's packets (`-c copy`) and
    /// each named filter output as raw PCM (`-c:a <hashCodec>`, no `-ar`, so
    /// nothing is resampled). The streamhash muxer prints one line per
    /// OUTPUT stream, in map order: carried streams first, then the sound.
    /// `-xerror` and `-err_detect explode` make a read or decode error
    /// fatal; the log level is explained in the file header. `inputArgs`
    /// are demuxer options (the raw-DV `-r`), before `-i`.
    static func hashArgs(input: String, inputArgs: [String], carriedIndices: [Int], soundFilter: String,
                         soundOutputs: [String], hashCodec: String) -> [String] {
        var args = ["-v", "repeat+level+verbose", "-nostdin", "-nostats", "-hide_banner", "-xerror",
                    "-err_detect", "explode"]
            + inputArgs + ["-i", input, "-filter_complex", soundFilter]
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
            original: try await layout(of: files.original, bytes: files.stamps[0].size, called: "the original",
                                       tools: tools, control: control),
            balanced: try await layout(of: files.balanced, bytes: files.stamps[1].size, called: "the balanced copy",
                                       tools: tools, control: control),
            originalClass: analysis.classification,
            originalMeasuredInFull: analysis.measuredSilent != nil)
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

    /// Run both hash passes and write what they found into `facts`.
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
        for i in facts.original.carried.indices { facts.original.carried[i].packetSHA256 = source.digests[i] }
        for i in facts.balanced.carried.indices { facts.balanced.carried[i].packetSHA256 = copy.digests[i] }
        facts.originalLiveSHA256 = source.digests[facts.original.carried.count]
        facts.balancedLeftSHA256 = copy.digests[facts.balanced.carried.count]
        facts.balancedRightSHA256 = copy.digests[facts.balanced.carried.count + 1]
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

    /// The layout pass reads the whole container (`-count_packets`), so its
    /// deadline is the levels pass's, scaled to the file's size.
    private static func layout(of path: String, bytes: Int64, called name: String, tools: Tools,
                               control: ProcessControl?) async throws -> FileLayout {
        let result = await ProcessRunner.runProcess(
            executable: tools.ffprobe, arguments: layoutArgs(input: path),
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes), control: control)
        try Task.checkCancellation()
        guard result.exitCode == 0, let data = result.stdout?.data(using: .utf8),
              let layout = layout(fromProbeJSON: data) else {
            throw Unchecked(reason: "\(name) could not be read as media (ffprobe status \(result.exitCode))")
        }
        return layout
    }

    /// What one hash pass gave: the digests (carried streams in order, then
    /// one per sound output) and its own account of the read.
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
                                         expected: carried.count + soundOutputs.count) else {
            throw Unchecked(reason: "\(name) did not give a hash for every stream")
        }
        return HashPass(digests: digests, read: read)
    }
}
