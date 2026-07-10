// PersonFinderCompilation.swift
// Clip extraction, compatibility bucketing, and ffmpeg/AVFoundation
// compilation helpers extracted from PersonFinderModel.swift.
//
// Step 5 of 6 in the PersonFinderModel decomposition (bundled — originally
// planned as 5a + 5b). Pure code movement from PersonFinderModel.swift —
// no logic changes. This file holds both:
//   • the free funcs/types that implement bucketed compilation, AND
//   • the four PersonFinderModel methods that drive them (startCompilation,
//     cancelCompilation, runCompilation, compileAndCleanup), relocated as
//     an extension on PersonFinderModel at the bottom of this file.
//
// Bundling avoids four throwaway visibility widenings that splitting would
// have required: pfExtractAllClips, pfCompileBuckets, pfMergeBucketsToSingleFile,
// and pfFileSize stay `private` because their callers move in the same step.
//
// Three narrow widenings (private → internal) were applied as authorized
// by the testing agent's gap log so that PersonFinderBoundaryTests can
// exercise the sort-by-year and year-extraction contracts:
//   - pfBuildSortedClipEntries
//   - pfExtractYear
//   - pfClipEntry
// Each carries a `// MARK: - test-internal` guardrail comment at its
// declaration site.

import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - Clip extraction

func pfExtractAllClips(
    results: inout [pfVideoResult],
    personName: String,
    outputDir: String,
    concurrency: Int,
    logFn: @escaping @Sendable (String) async -> Void
) async {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    struct Work { let ri: Int; let si: Int; let clipName: String; let url: URL; let asset: AVURLAsset; let start: Double; let end: Double }
    var items: [Work] = []
    for ri in 0..<results.count {
        guard !results[ri].segments.isEmpty else { continue }
        let asset = AVURLAsset(url: URL(fileURLWithPath: results[ri].filePath),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let stem = pfSanitize((results[ri].filename as NSString).deletingPathExtension)
        results[ri].clipFiles = Array(repeating: "", count: results[ri].segments.count)
        for (si, seg) in results[ri].segments.enumerated() {
            let ts = Int(seg.startSecs)
            let name = String(format: "%@_%@_%02dh%02dm%02ds_%03d.mov",
                              pfSanitize(personName), stem, ts/3600, (ts%3600)/60, ts%60, si+1)
            let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
            if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
            items.append(Work(ri: ri, si: si, clipName: name, url: outURL, asset: asset,
                              start: seg.startSecs, end: seg.endSecs))
        }
    }

    let workCount = items.count
    await withTaskGroup(of: (Int, Bool).self) { group in
        var submitted = 0
        for i in 0..<min(concurrency, workCount) {
            let w = items[i]; group.addTask { (i, await pfExtractClip(asset: w.asset, start: w.start, end: w.end, to: w.url)) }
            submitted += 1
        }
        for await (idx, ok) in group {
            let w = items[idx]
            if ok { await logFn("  → Saved: \(w.clipName)"); results[w.ri].clipFiles[w.si] = w.clipName }
            if submitted < workCount {
                let nw = items[submitted]; let ni = submitted
                group.addTask { (ni, await pfExtractClip(asset: nw.asset, start: nw.start, end: nw.end, to: nw.url)) }
                submitted += 1
            }
        }
    }
}

private func pfExtractClip(asset: AVURLAsset, start: Double, end: Double, to url: URL) async -> Bool {
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
    session.timeRange = CMTimeRangeMake(start: CMTimeMakeWithSeconds(start, preferredTimescale: 600),
                                        duration: CMTimeMakeWithSeconds(end - start, preferredTimescale: 600))
    if #available(macOS 15.0, *) {
        do { try await session.export(to: url, as: .mov); return true } catch { return false }
    } else {
        session.outputURL = url
        session.outputFileType = .mov
        return await withCheckedContinuation { cont in
            session.exportAsynchronously { cont.resume(returning: session.status == .completed) }
        }
    }
}

// MARK: - Concatenation

// MARK: - Decade helpers

// MARK: - test-internal — promoted to enable PersonFinderBoundaryTests coverage
func pfExtractYear(from path: String) -> Int {
    // Try 4-digit year in path/filename
    let pattern = try? NSRegularExpression(pattern: #"\b(19[5-9]\d|20[0-3]\d)\b"#)
    let s = path as NSString
    if let m = pattern?.firstMatch(in: path, range: NSRange(location: 0, length: s.length)) {
        return Int(s.substring(with: m.range)) ?? 0
    }
    // Fall back to file creation date
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let created = attrs[.creationDate] as? Date {
        return Calendar.current.component(.year, from: created)
    }
    return 0
}

private func pfDecadeLabel(for year: Int) -> String {
    guard year > 0 else { return "Unknown" }
    let decade = (year / 10) * 10
    return "\(decade)s"
}

// MARK: - test-internal — promoted to enable PersonFinderBoundaryTests coverage
struct pfClipEntry {
    let clipPath: String
    let year: Int
    let decade: String
}

// MARK: - test-internal — promoted to enable PersonFinderBoundaryTests coverage
func pfBuildSortedClipEntries(results: [pfVideoResult], outputDir: String) -> [pfClipEntry] {
    var entries: [pfClipEntry] = []
    for r in results {
        let year = pfExtractYear(from: r.filePath)
        let decade = pfDecadeLabel(for: year)
        for name in r.clipFiles where !name.isEmpty {
            let fullPath = (outputDir as NSString).appendingPathComponent(name)
            entries.append(pfClipEntry(clipPath: fullPath, year: year, decade: decade))
        }
    }
    return entries.sorted { a, b in a.year == b.year ? a.clipPath < b.clipPath : a.year < b.year }
}

// MARK: - Compatibility bucketing
//
// See docs/compilation-bucketing.md for design rationale. The short version:
// the ffmpeg concat demuxer requires every input to share identical stream
// parameters (codec, pix_fmt, resolution, SAR, audio layout, etc). With
// mixed family-archive material that condition fails about ten minutes
// into a typical compilation. Instead of forcing a lossy re-encode, we
// group consecutive clips by a CompatKey and stream-copy each group into
// its own output file. Multiple files, but every byte preserved.

/// All the stream parameters that the concat demuxer cares about for
/// stream copy. Two clips are concat-copy compatible iff their CompatKey
/// values are equal. The fields are intentionally strict — better to
/// over-bucket than to silently produce a broken file.
struct CompatKey: Hashable {
    // Video
    let vCodec: String   // "h264", "hevc", "dvvideo", "mpeg2video", "none"
    let vProfile: String   // "High", "Main", ""
    let pixFmt: String   // "yuv420p", "yuv422p10le"
    let width: Int
    let height: Int
    let sar: String   // "1:1", "10:11"
    let fpsRational: String   // "30000/1001", "25/1", "0/0" if VFR
    let colorSpace: String
    let colorRange: String
    // Audio
    let aCodec: String   // "aac", "pcm_s16le", "ac3", "none"
    let aSampleRate: Int      // 0 if no audio
    let aChannels: Int      // 0 if no audio
    let aLayout: String
    // Container shape
    let hasAudio: Bool

    /// Filename-safe short label, e.g. "h264_1080p2997_aac48k_2ch".
    var shortLabel: String {
        let codecShort: String = {
            switch vCodec {
            case "h264":       return "h264"
            case "hevc":       return "hevc"
            case "dvvideo":    return "dv"
            case "mpeg2video": return "mpeg2"
            case "prores":     return "prores"
            case "mjpeg":      return "mjpeg"
            case "vp9":        return "vp9"
            case "av1":        return "av1"
            default:           return vCodec.isEmpty ? "novideo" : vCodec
            }
        }()
        let res = "\(height)p"
        let fps: String = {
            // r_frame_rate "num/den" → rounded label
            let parts = fpsRational.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return "vfr" }
            let f = parts[0] / parts[1]
            if abs(f - 23.976) < 0.05 { return "2398" }
            if abs(f - 24)     < 0.05 { return "24" }
            if abs(f - 25)     < 0.05 { return "25" }
            if abs(f - 29.97)  < 0.05 { return "2997" }
            if abs(f - 30)     < 0.05 { return "30" }
            if abs(f - 50)     < 0.05 { return "50" }
            if abs(f - 59.94)  < 0.05 { return "5994" }
            if abs(f - 60)     < 0.05 { return "60" }
            return String(format: "%.0f", f)
        }()
        let audio: String = {
            guard hasAudio else { return "noaudio" }
            let codecShort: String = {
                switch aCodec {
                case "aac":       return "aac"
                case "pcm_s16le": return "pcm"
                case "pcm_s24le": return "pcm24"
                case "ac3":       return "ac3"
                case "eac3":      return "eac3"
                case "mp3":       return "mp3"
                case "opus":      return "opus"
                default:          return aCodec.isEmpty ? "audio" : aCodec
                }
            }()
            let kHz = aSampleRate / 1000
            return "\(codecShort)\(kHz)k_\(aChannels)ch"
        }()
        return pfSanitize("\(codecShort)_\(res)\(fps)_\(audio)")
    }

    /// True iff every codec/pixfmt in this key can legally live inside an
    /// `.mp4` (ISO BMFF) container. Anything exotic gets `.mov`, which is
    /// the more permissive of the two.
    var preferredExtension: String {
        let mp4Codecs: Set<String> = ["h264", "hevc", "mpeg2video", "mpeg4", "av1"]
        let mp4Audio: Set<String> = ["aac", "ac3", "eac3", "mp3", "opus"]
        let mp4PixFmt: Set<String> = ["yuv420p", "yuvj420p", "nv12", "yuv420p10le"]
        if !mp4Codecs.contains(vCodec) { return "mov" }
        if hasAudio && !mp4Audio.contains(aCodec) { return "mov" }
        if !mp4PixFmt.contains(pixFmt) { return "mov" }
        return "mp4"
    }
}

/// Run ffprobe on a clip and parse out a CompatKey. Returns nil if the
/// probe failed or the file lacks a video stream.
private func pfProbeCompatKey(path: String) async -> CompatKey? {
    let fm = FileManager.default
    guard let ffprobePath = ToolLocator.firstExecutable(in: ToolLocator.ffprobeCandidates) else { return nil }
    guard fm.fileExists(atPath: path) else { return nil }

    // ProcessRunner (codex finding #3): drains stdout continuously instead of
    // reading after waitUntilExit (which blocked a cooperative thread AND
    // could deadlock if the JSON outgrew the 64KB pipe buffer).
    let result = await ProcessRunner.runProcess(
        executable: ffprobePath,
        arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            path
        ]
    )
    guard result.exitCode == 0,
          let stdout = result.stdout,
          let data = stdout.data(using: .utf8) else { return nil }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = root["streams"] as? [[String: Any]] else { return nil }

    let video = streams.first(where: { ($0["codec_type"] as? String) == "video" })
    let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

    guard let v = video else { return nil }

    func str(_ d: [String: Any]?, _ k: String) -> String { (d?[k] as? String) ?? "" }
    func int(_ d: [String: Any]?, _ k: String) -> Int {
        if let i = d?[k] as? Int { return i }
        if let s = d?[k] as? String, let i = Int(s) { return i }
        return 0
    }

    let vCodec     = str(v, "codec_name")
    let vProfile   = str(v, "profile")
    let pixFmt     = str(v, "pix_fmt")
    let width      = int(v, "width")
    let height     = int(v, "height")
    let sar        = str(v, "sample_aspect_ratio").isEmpty ? "1:1" : str(v, "sample_aspect_ratio")
    let fps        = str(v, "r_frame_rate").isEmpty ? "0/0" : str(v, "r_frame_rate")
    let colorSpace = str(v, "color_space")
    let colorRange = str(v, "color_range")

    let hasAudio  = audio != nil
    let aCodec    = hasAudio ? str(audio, "codec_name")     : "none"
    let aRate     = hasAudio ? int(audio, "sample_rate")    : 0
    let aChannels = hasAudio ? int(audio, "channels")       : 0
    let aLayout   = hasAudio ? str(audio, "channel_layout") : ""

    return CompatKey(
        vCodec: vCodec, vProfile: vProfile, pixFmt: pixFmt,
        width: width, height: height, sar: sar, fpsRational: fps,
        colorSpace: colorSpace, colorRange: colorRange,
        aCodec: aCodec, aSampleRate: aRate, aChannels: aChannels, aLayout: aLayout,
        hasAudio: hasAudio
    )
}

/// One bucket worth of clips, all sharing a CompatKey, in timeline order.
private struct pfBucket {
    let key: CompatKey
    var entries: [pfClipEntry]
    var totalDurationSecs: Double
}

/// Strict-adjacent bucketing: walks the timeline-sorted entries and starts
/// a new bucket whenever the next clip's key differs from the current
/// bucket's key, OR appending it would exceed `maxSecs`. Probes via
/// ffprobe; logs and skips clips that fail to probe.
private func pfBucketByCompat(
    entries: [pfClipEntry],
    maxSecs: Double,
    logFn: @escaping @Sendable (String) async -> Void
) async -> [pfBucket] {
    var buckets: [pfBucket] = []
    var current: pfBucket?

    for entry in entries {
        guard let key = await pfProbeCompatKey(path: entry.clipPath) else {
            await logFn("  ⚠ ffprobe failed for \((entry.clipPath as NSString).lastPathComponent) — skipping")
            continue
        }
        // Cheap duration probe via AVAsset (already used elsewhere in this file).
        let asset = AVURLAsset(url: URL(fileURLWithPath: entry.clipPath),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0

        if var b = current,
           b.key == key,
           b.totalDurationSecs + dur <= maxSecs {
            b.entries.append(entry)
            b.totalDurationSecs += dur
            current = b
        } else {
            if let b = current { buckets.append(b) }
            current = pfBucket(key: key, entries: [entry], totalDurationSecs: dur)
        }
    }
    if let b = current { buckets.append(b) }
    return buckets
}

/// Top-level driver for the bucketed compilation pipeline. Returns one
/// CompiledOutput per bucket actually written to disk.
func pfCompileBuckets(
    results: [pfVideoResult],
    outputDir: String,
    jobName: String,
    stamp: String,
    logFn: @escaping @Sendable (String) async -> Void
) async -> [CompiledOutput] {
    let entries = pfBuildSortedClipEntries(results: results, outputDir: outputDir)
    guard !entries.isEmpty else {
        await logFn("  No clips to compile.")
        return []
    }

    let maxBucketSecs: Double = 30 * 60   // 30-minute soft cap per bucket
    let buckets = await pfBucketByCompat(entries: entries, maxSecs: maxBucketSecs, logFn: logFn)
    guard !buckets.isEmpty else { return [] }

    await logFn("  Found \(entries.count) clip(s) → \(buckets.count) compatibility bucket(s).")

    guard let ffmpegPath = ToolLocator.firstExecutable(in: ToolLocator.ffmpegCandidates) else {
        await logFn("  ⚠ ffmpeg not found — install via: brew install ffmpeg")
        return []
    }

    var outputs: [CompiledOutput] = []
    for (idx, bucket) in buckets.enumerated() {
        let ordinal = String(format: "%02d", idx + 1)
        let label   = bucket.key.shortLabel
        let ext     = bucket.key.preferredExtension
        let outName = "\(jobName)_compilation_\(ordinal)_\(label)_\(stamp).\(ext)"
        let outPath = (outputDir as NSString).appendingPathComponent(outName)

        await logFn("  → Bucket \(ordinal)/\(buckets.count): \(label) — \(bucket.entries.count) clip(s), \(pfFormatDuration(bucket.totalDurationSecs))")

        if let written = await pfStreamCopyConcat(
            ffmpegPath: ffmpegPath,
            entries: bucket.entries,
            outputPath: outPath,
            logFn: logFn
        ) {
            outputs.append(CompiledOutput(
                path: written,
                label: label,
                clipCount: bucket.entries.count,
                durationSecs: bucket.totalDurationSecs,
                bytesOnDisk: pfFileSize(at: written)
            ))
        }
    }
    return outputs
}

/// Stream-copy a list of clips into one output file via the ffmpeg concat
/// demuxer. Returns the output path on success, nil on failure.
private func pfStreamCopyConcat(
    ffmpegPath: String,
    entries: [pfClipEntry],
    outputPath: String,
    logFn: @escaping @Sendable (String) async -> Void
) async -> String? {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let listPath = (tmp as NSString).appendingPathComponent("pf_bucket_\(ts).txt")

    // ffmpeg concat demuxer requires single-quoted paths with internal
    // single quotes escaped as '\''.
    let listContent = entries.map { e -> String in
        let escaped = e.clipPath.replacingOccurrences(of: "'", with: "'\\''")
        return "file '\(escaped)'"
    }.joined(separator: "\n")
    do { try listContent.write(toFile: listPath, atomically: true, encoding: .utf8) } catch {
        await logFn("  ⚠ Could not write concat list: \(error.localizedDescription)")
        return nil
    }

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    // ProcessRunner (codex finding #3): keeps the continuous stderr drain
    // (mixed-input archives emit floods of warnings) and adds cancellation
    // awareness — cancelling the compilation task now terminates ffmpeg
    // instead of letting it run to completion.
    let result = await ProcessRunner.runProcess(
        executable: ffmpegPath,
        arguments: [
            "-hide_banner", "-nostdin",
            "-f", "concat", "-safe", "0", "-i", listPath,
            "-map", "0:v?", "-map", "0:a?",
            "-c", "copy",
            "-movflags", "+faststart",
            "-y", outputPath
        ],
        stderrLimitBytes: nil   // full transcript, matching pre-refactor pfStderrBox
    )
    try? fm.removeItem(atPath: listPath)

    // Launch failure: stdout nil + synthetic -1 (vs. a real ffmpeg exit code).
    if result.exitCode == -1, result.stdout == nil, result.stderr != "cancelled" {
        await logFn("  ⚠ Could not launch ffmpeg: \(result.stderr)")
        return nil
    }

    if result.exitCode == 0 {
        await logFn("    ✓ \((outputPath as NSString).lastPathComponent)")
        return outputPath
    } else {
        await logFn("    ⚠ ffmpeg exited with code \(result.exitCode)")
        for line in result.stderr.components(separatedBy: .newlines).suffix(8) where !line.isEmpty {
            await logFn("      stderr: \(line)")
        }
        return nil
    }
}

/// Merge multiple bucket compilation files into ONE single output file via
/// hardware-accelerated re-encode (h264_videotoolbox on Apple Silicon).
///
/// Two-pass strategy:
///   1. Re-encode each bucket file to a normalized format (1280×720, h264,
///      30fps, AAC 128k 48kHz stereo). Writes to a temp dir.
///   2. Stream-copy concat the normalized files into the final output path
///      (fast — no second re-encode).
///
/// Returns true on success, false on any failure (caller should keep the
/// original bucket files as fallback).
func pfMergeBucketsToSingleFile(
    bucketPaths: [String],
    outputPath: String,
    targetHeight: Int = 720,
    logFn: @escaping @Sendable (String) async -> Void
) async -> Bool {
    let fm = FileManager.default
    guard let ffmpegPath = ToolLocator.firstExecutable(in: ToolLocator.ffmpegCandidates) else {
        await logFn("  ⚠ ffmpeg not found for merge step")
        return false
    }

    let workDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("pf_merge_\(Int(Date().timeIntervalSince1970 * 1000))")
    try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: workDir) }

    var normalizedPaths: [String] = []
    for (idx, src) in bucketPaths.enumerated() {
        let dst = (workDir as NSString)
            .appendingPathComponent("norm_\(String(format: "%04d", idx)).mp4")
        let ok = await pfRunFFmpeg(
            ffmpegPath: ffmpegPath,
            args: [
                "-hide_banner", "-nostdin", "-y",
                "-hwaccel", "videotoolbox",
                "-i", src,
                "-vf", "scale=-2:\(targetHeight),setsar=1,format=yuv420p",
                "-c:v", "h264_videotoolbox",
                "-b:v", "4M",
                "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
                "-r", "30",
                "-movflags", "+faststart",
                dst
            ]
        )
        if ok && fm.fileExists(atPath: dst) {
            normalizedPaths.append(dst)
            await logFn("  Normalized \(idx + 1)/\(bucketPaths.count) bucket(s)")
        } else {
            await logFn("  ⚠ Normalize failed for bucket \(idx + 1) — aborting merge")
            return false
        }
    }
    guard !normalizedPaths.isEmpty else { return false }

    // Concat the normalized files (stream-copy, fast)
    let listPath = (workDir as NSString).appendingPathComponent("concat.txt")
    let listContent = normalizedPaths
        .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        .joined(separator: "\n")
    do { try listContent.write(toFile: listPath, atomically: true, encoding: .utf8) } catch {
        await logFn("  ⚠ Could not write merge concat list: \(error.localizedDescription)")
        return false
    }

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    let ok = await pfRunFFmpeg(
        ffmpegPath: ffmpegPath,
        args: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "concat", "-safe", "0", "-i", listPath,
            "-c", "copy",
            "-movflags", "+faststart",
            outputPath
        ]
    )
    return ok && fm.fileExists(atPath: outputPath)
}

/// Run ffmpeg with the given args. Returns true if exit status was 0.
/// ProcessRunner drains both pipes (avoiding the 64KB pipe-buffer deadlock)
/// and terminates ffmpeg on task cancellation (codex finding #3 — previously
/// a cancelled merge let ffmpeg run to completion unattended).
private func pfRunFFmpeg(ffmpegPath: String, args: [String]) async -> Bool {
    let result = await ProcessRunner.runProcess(executable: ffmpegPath, arguments: args)
    return result.exitCode == 0
}

private func pfFileSize(at path: String) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
}

// MARK: - PersonFinderModel compilation methods
//
// Relocated from PersonFinderModel.swift in step 5 of 6. This is the first
// time an extension on PersonFinderModel lives in a separate file from the
// class declaration. @Observable / @Published semantics are preserved by
// Swift's extension model — extensions cannot add stored properties (so no
// @Published can be added here), but the published `compilationSettings`
// itself stays on the class in PersonFinderModel.swift. Method annotations
// (@MainActor implicit via the class, nonisolated, async, etc.) are
// preserved byte-for-byte.

extension PersonFinderModel {

    func startCompilation(job: ScanJob) {
        guard job.status.isDone else { return }
        guard !job.recognitionResults.isEmpty else {
            job.appendLog("⚠ No recognition results to compile.")
            return
        }
        guard !job.compilationStatus.isActive else { return }

        let results = job.recognitionResults
        let outputDir = job.recognitionOutputDir
        let personName = job.assignedProfile?.name ?? "Unknown"
        let compSettings = compilationSettings
        let scanSettings = settings
        let totalSegs = results.reduce(0) { $0 + $1.segments.count }
        osLog.info("Compilation started: person=\(personName, privacy: .public) mode=\(compSettings.mode.rawValue, privacy: .public) segments=\(totalSegs) videos=\(results.count)")

        job.compilationStatus = .extracting
        job.compilationProgress = 0
        job.compilationPhase = "Extracting clips…"
        job.compilationClipsTotal = results.reduce(0) { $0 + $1.segments.count }
        job.compilationClipsDone = 0
        job.compiledVideoPaths = []
        job.appendLog("\n━ Compilation started ━━━━━━━━━━━━━━━━━━━━━")

        job.compilationTask = Task.detached(priority: .userInitiated) {
            await Self.runCompilation(
                job: job,
                results: results,
                outputDir: outputDir,
                personName: personName,
                compilationSettings: compSettings,
                scanSettings: scanSettings
            )
        }
    }

    func cancelCompilation(job: ScanJob) {
        osLog.info("Compilation cancelled by user")
        job.compilationTask?.cancel()
        job.compilationStatus = .idle
        job.compilationPhase = ""
        job.compilationProgress = 0
    }

    private nonisolated static func runCompilation(
        job: ScanJob,
        results: [pfVideoResult],
        outputDir: String,
        personName: String,
        compilationSettings: CompilationSettings,
        scanSettings: PersonFinderSettings
    ) async {
        let totalClips = results.reduce(0) { $0 + $1.segments.count }
        osLog.info("Extraction phase: \(totalClips) clip(s) from \(results.count) video(s) → \(outputDir, privacy: .public)")
        await job.appendLog("Extracting \(totalClips) clip(s) to: \(outputDir)")

        var workResults = results
        var clipsDone = 0
        let clipTotal = totalClips

        for i in 0..<workResults.count {
            if Task.isCancelled {
                await MainActor.run { job.compilationStatus = .idle; job.compilationPhase = "Cancelled" }
                return
            }
            let r = workResults[i]
            let segCount = r.segments.count
            if segCount == 0 { continue }

            await MainActor.run {
                job.compilationPhase = "Extracting from \(r.filename) (\(clipsDone + 1)–\(clipsDone + segCount) of \(clipTotal))"
            }

            // Extract clips for this single video result
            var single = [workResults[i]]
            await pfExtractAllClips(
                results: &single, personName: personName,
                outputDir: outputDir, concurrency: compilationSettings.concurrency,
                logFn: { line in await job.appendLog(line) }
            )
            workResults[i] = single[0]
            clipsDone += segCount
            await MainActor.run {
                job.compilationClipsDone = clipsDone
                job.compilationProgress = Double(clipsDone) / Double(clipTotal)
            }
        }

        if Task.isCancelled {
            await MainActor.run { job.compilationStatus = .idle; job.compilationPhase = "Cancelled" }
            return
        }

        let clipResults: [ClipResult] = workResults.compactMap { r -> ClipResult? in
            guard !r.segments.isEmpty else { return nil }
            return ClipResult(
                videoFilename: r.filename,
                videoPath: r.filePath,
                videoDuration: r.durationSeconds,
                presenceSecs: r.totalPresenceSecs,
                segmentCount: r.segments.count,
                bestDistance: r.segments.map(\.bestDistance).min() ?? 0,
                clipFiles: r.clipFiles,
                outputDir: outputDir
            )
        }
        let foundClips = workResults.reduce(0) { $0 + $1.clipFiles.filter { !$0.isEmpty }.count }
        osLog.info("Extraction done: \(foundClips) clip file(s) — entering compile phase")

        await MainActor.run {
            // Carry identity-plausibility annotations over from the rows
            // being replaced — the extraction rebuild only adds clipFiles,
            // the identity evidence for each video hasn't changed.
            let priorAnnotations = Dictionary(
                job.results.map { ($0.videoPath, ($0.plausibility, $0.plausibilityReason)) },
                uniquingKeysWith: { first, _ in first }
            )
            var annotated = clipResults
            for i in annotated.indices {
                if let prior = priorAnnotations[annotated[i].videoPath] {
                    annotated[i].plausibility = prior.0
                    annotated[i].plausibilityReason = prior.1
                }
            }
            job.results = annotated
            job.clipsFound = foundClips
        }

        let allClipPaths = workResults.flatMap(\.clipFiles).filter { !$0.isEmpty }
            .map { (outputDir as NSString).appendingPathComponent($0) }

        let compiled = await compileAndCleanup(
            workResults: workResults,
            foundClips: foundClips,
            compilationSettings: compilationSettings,
            personName: personName,
            outputDir: outputDir,
            allClipPaths: allClipPaths,
            job: job
        )

        await MainActor.run {
            job.compiledVideoPaths = compiled
            job.compilationStatus = .done
            job.compilationProgress = 1.0
            let totalDur = compiled.reduce(0.0) { $0 + $1.durationSecs }
            job.compilationPhase = compiled.isEmpty
                ? "No clips to compile"
                : "\(compiled.count) video(s), \(pfFormatDuration(totalDur))"
            job.appendLog("\n━ Compilation complete: \(compiled.count) output(s), \(foundClips) clip(s) ━")
        }
        let totalBytes = compiled.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
        osLog.info("Compilation done: \(compiled.count) output(s), \(foundClips) clip(s), \(totalBytes) bytes on disk")
    }

    /// Build bucketed compilations and remove now-redundant intermediate clips.
    /// Returns the compiled outputs (empty if compilation was not requested or produced nothing).
    private nonisolated static func compileAndCleanup(
        workResults: [pfVideoResult],
        foundClips: Int,
        compilationSettings: CompilationSettings,
        personName: String,
        outputDir: String,
        allClipPaths: [String],
        job: ScanJob
    ) async -> [CompiledOutput] {
        guard foundClips > 0 else { return [] }

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        let name = pfSanitize(personName)
        await job.appendLog("\nBuilding compatibility-bucketed compilations…")
        await MainActor.run { job.compilationStatus = .compiling; job.compilationProgress = 0; job.compilationPhase = "Building compilations…" }
        let bucketCompiled = await pfCompileBuckets(
            results: workResults,
            outputDir: outputDir,
            jobName: name,
            stamp: stamp,
            logFn: { line in await job.appendLog(line) }
        )

        var compiled = bucketCompiled
        if bucketCompiled.count > 1 && compilationSettings.mode == .singleVideo {
            await MainActor.run { job.compilationStatus = .merging; job.compilationProgress = 0; job.compilationPhase = "Merging \(bucketCompiled.count) bucket(s) into single file…" }
            await job.appendLog("\nMerging \(bucketCompiled.count) bucket(s) into a single compilation…")
            let mergedName = "\(name)_compilation_\(stamp).mp4"
            let mergedPath = (outputDir as NSString).appendingPathComponent(mergedName)
            if await pfMergeBucketsToSingleFile(
                bucketPaths: bucketCompiled.map(\.path),
                outputPath: mergedPath,
                logFn: { line in await job.appendLog(line) }
            ) {
                let fm = FileManager.default
                let totalDur = bucketCompiled.reduce(0.0) { $0 + $1.durationSecs }
                let totalClips = bucketCompiled.reduce(0) { $0 + $1.clipCount }
                for b in bucketCompiled { try? fm.removeItem(atPath: b.path) }
                compiled = [CompiledOutput(
                    path: mergedPath,
                    label: "merged",
                    clipCount: totalClips,
                    durationSecs: totalDur,
                    bytesOnDisk: pfFileSize(at: mergedPath)
                )]
                await job.appendLog("  ✓ Merged into \(mergedName) (\(pfFormatDuration(totalDur)))")
            } else {
                await job.appendLog("  ⚠ Merge failed; keeping \(bucketCompiled.count) bucket files as fallback")
            }
        }

        if !compiled.isEmpty {
            let outputPaths = Set(compiled.map(\.path))
            let fm = FileManager.default
            var removed = 0
            for clipPath in allClipPaths where !outputPaths.contains(clipPath) {
                try? fm.removeItem(atPath: clipPath)
                removed += 1
            }
            await job.appendLog("  Cleaned up \(removed) intermediate clip file(s)")
        }
        return compiled
    }
}
