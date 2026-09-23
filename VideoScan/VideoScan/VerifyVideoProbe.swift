import Foundation
import os

// MARK: - Verify Video — the I/O half (Rick 2026-09-23)
//
// Three passes, all through ProcessRunner (the one shell-out module —
// never a bare Process() here), every one READ-ONLY on the media:
//
//   1. Header probe (ffprobe JSON, sub-second) → VideoVerifyFacts.
//      A probe that FAILS on a file that is still on disk and whose
//      stderr blames the content ("moov atom not found", "Invalid data
//      found…") is itself a verdict: Broken, can't be opened. A probe
//      that fails because the file/drive went away is NOT — it throws,
//      and nothing is persisted (the Verify Audio "couldn't check is not
//      a verdict" rule, GH #128 / QA finding 1).
//   2. Packet samples (ffprobe, ≤ 300 packets at the start and ≤ 300 at
//      the middle) → timestamp order/gaps + the stored-frame rate when
//      the container records no frame count.
//   3. Full decode (ffmpeg -v error … -map 0:v:0 -f null -) counting the
//      decoder's complaints, with live progress from `-progress pipe:1`
//      and a wall-clock budget (VerifyVideoRules.decodeBudgetSeconds).
//      Budget hit → "partially checked", never a failure. Skipped when
//      passes 1–2 already prove the file broken in a way decoding can't
//      change (e.g. the 46 GB duplicate-frame file: reading it end to end
//      would tie up a spinning disk for the better part of an hour to
//      learn nothing new).
//
// Memory (worst case, per diagnosis): ffprobe JSON ≤ 1 MB (stdout cap);
// packet text ≤ 2 × 64 KB (stdout caps; ≤ 300 short lines each); the
// decode keeps NO stdout/stderr copies beyond ProcessRunner's small caps
// (16 KB / 64 KB here) — lines are counted as they stream, and at most 5
// sample error lines are retained. ≈ 1.2 MB total, independent of file
// size. ffmpeg itself streams the file; its own RSS is bounded by one
// decoder's frame pool.
//
// Concurrency: `diagnose` is `@concurrent` — in this repo's Approachable
// Concurrency mode a plain `nonisolated async` func runs on the CALLER's
// actor, so called from the @MainActor job it would block the UI thread
// (the documented trap). `@concurrent` forces the global executor.
// (For Rick: ≈ explicitly punting the work to a background thread pool
// instead of inheriting the caller's thread.)

private let verifyVideoLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "verifyVideo")

/// Thread-safe tally for the decode's stderr/stdout callbacks, which
/// arrive on GCD threads. (≈ C++: a struct guarded by a std::mutex.
/// `@unchecked Sendable` = "I promise the lock makes this safe".)
final class VideoDecodeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = 0
    private var samples: [String] = []
    private var lastSeconds: Double = 0
    static let maxSamples = 5

    func noteError(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        errors += 1
        if samples.count < Self.maxSamples {
            samples.append(VerifyVideoRules.cleanErrorLine(line))
        }
    }

    /// Returns the new position when it advanced.
    func noteProgress(_ seconds: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard seconds > lastSeconds else { return nil }
        lastSeconds = seconds
        return seconds
    }

    var snapshot: (errors: Int, samples: [String], seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (errors, samples, lastSeconds)
    }
}

enum VerifyVideoProbe {

    /// Progress sink: 0…1 of the decode pass (called off-main).
    typealias Progress = @Sendable (Double) -> Void

    // MARK: Argument builders (pure — pinned by tests)

    static func headerArgs(input: String) -> [String] {
        [
            "-hide_banner", "-v", "error",
            "-show_entries",
            "stream=codec_type,codec_name,width,height,sample_aspect_ratio,display_aspect_ratio,r_frame_rate,avg_frame_rate,nb_frames,duration,bit_rate:stream_disposition=attached_pic:format=format_name,duration,size:format_tags=encoder",
            "-of", "json",
            input,
        ]
    }

    /// `startSeconds` nil = from the top. `maxPackets` bounds the read —
    /// never a whole-file walk.
    static func packetSampleArgs(input: String, startSeconds: Double?, maxPackets: Int = 300) -> [String] {
        let start = startSeconds.map { String(format: "%.3f", $0) } ?? ""
        return [
            "-hide_banner", "-v", "error",
            "-select_streams", "v:0",
            "-read_intervals", "\(start)%+#\(maxPackets)",
            "-show_entries", "packet=pts_time,dts_time,size",
            "-of", "compact=p=0",
            input,
        ]
    }

    static func decodeArgs(input: String) -> [String] {
        [
            "-nostdin", "-hide_banner", "-v", "error",
            "-i", input,
            "-map", "0:v:0",
            "-f", "null", "-",
            "-progress", "pipe:1", "-nostats",
        ]
    }

    // MARK: Full diagnosis

    /// Test seams (the VerifyAudioProbe convention) — production passes
    /// none of them.
    typealias SourceRecheck = @Sendable (String) async -> Bool

    #if compiler(>=6.2)
    @concurrent
    #endif
    static func diagnose(path: String,
                         control: ProcessControl? = nil,
                         progress: Progress? = nil,
                         decodeBudgetOverride: Double? = nil,
                         sourceRecheckOverride: SourceRecheck? = nil
    ) async throws -> VideoVerifyDiagnosis {
        let ffprobe = ToolLocator.ffprobePath
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw VideoVerifyProbeError.toolUnavailable(
                "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }
        let name = (path as NSString).lastPathComponent
        let recheck = sourceRecheckOverride ?? { await sourceStillReadable(path: $0) }

        // ---- 1. Header probe.
        let header = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: headerArgs(input: path),
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: 60,
            control: control)
        try Task.checkCancellation()
        guard header.exitCode == 0, let stdout = header.stdout,
              let data = stdout.data(using: .utf8) else {
            // Content or I/O? Only a still-readable file whose probe
            // complained about its CONTENT earns a Broken verdict.
            if !header.timedOut,
               VerifyVideoRules.stderrBlamesContent(header.stderr),
               await recheck(path) {
                let detail = VerifyVideoRules.unopenableDetail(fromProbeStderr: header.stderr)
                verifyVideoLog.notice("verifyVideo: \(name, privacy: .public) cannot be opened (\(detail, privacy: .public)) — Broken")
                var facts = VideoVerifyFacts()
                facts.fileSizeBytes = fileSize(path)
                return VideoVerifyDiagnosis(
                    findings: [.unopenable(detail: detail)], facts: facts,
                    sample: nil,
                    decode: VideoDecodeFacts(coverage: .skipped(reason: "the file can't be opened")))
            }
            verifyVideoLog.notice("verifyVideo: header probe failed for \(name, privacy: .public) (exit \(header.exitCode), timedOut=\(header.timedOut)) — no verdict")
            throw VideoVerifyProbeError.probeFailed(header.timedOut
                ? "the drive did not answer in time — no verdict was recorded; try again when it is less busy"
                : "ffprobe could not read the file (exit \(header.exitCode)) and the drive may be unavailable — no verdict was recorded")
        }
        let facts = try VerifyVideoRules.facts(fromProbeJSON: data)
        guard facts.hasVideo else { throw VideoVerifyProbeError.noVideoStream }

        // ---- 2. Packet samples (start + middle).
        var windows: [VideoPacketSample] = []
        var starts: [Double?] = [nil]
        if facts.videoDurationSeconds > 20 { starts.append(facts.videoDurationSeconds / 2) }
        for start in starts {
            let r = await ProcessRunner.runProcess(
                executable: ffprobe,
                arguments: packetSampleArgs(input: path, startSeconds: start),
                stdoutLimitBytes: 64 * 1024,
                deadlineSeconds: 60,
                control: control)
            try Task.checkCancellation()
            // A failed sample is not evidence — it just means fewer facts.
            guard r.exitCode == 0, let text = r.stdout else { continue }
            windows.append(VerifyVideoRules.packetSample(
                from: VerifyVideoRules.packetRows(fromCompact: text)))
        }
        let sample = VerifyVideoRules.merge(windows)

        // ---- 3. Full decode (unless already pointless).
        let pre = VerifyVideoRules.preDecodeFindings(facts: facts, sample: sample)
        let decode: VideoDecodeFacts
        if VerifyVideoRules.decodeIsPointless(pre) {
            decode = VideoDecodeFacts(coverage: .skipped(
                reason: "already known broken — decoding \(VerifyVideoRules.sizeText(facts.fileSizeBytes)) would add nothing"))
        } else {
            decode = try await runDecode(path: path, ffmpeg: ffmpeg, facts: facts,
                                         control: control, progress: progress,
                                         budget: decodeBudgetOverride
                                            ?? VerifyVideoRules.decodeBudgetSeconds(
                                                durationSeconds: facts.videoDurationSeconds),
                                         recheck: recheck)
        }

        let findings = VerifyVideoRules.findings(facts: facts, sample: sample, decode: decode)
        let diagnosis = VideoVerifyDiagnosis(findings: findings, facts: facts,
                                             sample: sample, decode: decode)
        verifyVideoLog.info("verifyVideo: \(name, privacy: .public) → \(diagnosis.verdict.rawValue, privacy: .public): \(diagnosis.persistedNote.isEmpty ? "clean" : diagnosis.persistedNote, privacy: .public) (codec=\(facts.videoCodec, privacy: .public) \(facts.width)x\(facts.height), frames=\(facts.frameCount ?? -1), decodeErrors=\(decode.errorCount))")
        return diagnosis
    }

    /// The full decode pass. Throws only for cancellation and for an I/O
    /// failure (file/drive gone) — a decoder that gives up on a still-
    /// readable file is a finding, not an exception.
    private static func runDecode(path: String,
                                  ffmpeg: String,
                                  facts: VideoVerifyFacts,
                                  control: ProcessControl?,
                                  progress: Progress?,
                                  budget: Double,
                                  recheck: SourceRecheck) async throws -> VideoDecodeFacts {
        let tally = VideoDecodeTally()
        let total = facts.videoDurationSeconds
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: decodeArgs(input: path),
            stdoutLine: { line in
                guard let s = VerifyVideoRules.progressSeconds(fromLine: line),
                      let advanced = tally.noteProgress(s), total > 0 else { return }
                progress?(min(1, advanced / total))
            },
            stderrLine: { line in tally.noteError(line) },
            stdoutLimitBytes: 16 * 1024,
            stderrLimitBytes: 64 * 1024,
            deadlineSeconds: budget,
            control: control)
        try Task.checkCancellation()
        let snap = tally.snapshot
        var facts = VideoDecodeFacts(coverage: .complete,
                                     errorCount: snap.errors,
                                     sampleErrors: snap.samples)
        if result.exitCode == 0 {
            return facts
        }
        if result.timedOut {
            facts.coverage = .partial(checkedSeconds: snap.seconds)
            verifyVideoLog.notice("verifyVideo: decode hit its \(Int(budget))s budget at \(snap.seconds)s of \(total)s — partially checked")
            return facts
        }
        // Non-zero on its own: the decoder gave up — or the drive went
        // away. Only a still-readable source makes it evidence.
        guard await recheck(path) else {
            throw VideoVerifyProbeError.probeFailed(
                "the file or its drive stopped responding while the picture was being read — no verdict was recorded; try again when the drive is reachable")
        }
        facts.failedToFinish = true
        facts.stoppedAtSeconds = snap.seconds
        return facts
    }

    /// Post-failure reachability recheck: on disk, and its first bytes
    /// still readable (a sleeping/ejected drive fails here). A 4 KB read
    /// — never a write.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func sourceStillReadable(path: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        // A throw = the read itself failed (I/O). An empty file reads
        // fine (nil/empty) — its emptiness is the CONTENT problem.
        do {
            _ = try handle.read(upToCount: 4096)
            return true
        } catch {
            return false
        }
    }

    static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
