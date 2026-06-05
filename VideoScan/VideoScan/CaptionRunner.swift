import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import os

#if canImport(MLXVLM)
import MLX
import MLXLMCommon
import MLXVLM
#endif

// MARK: - Caption Runner
//
// Engine-agnostic abstraction for vision-language captioning. The Swift
// app calls a CaptionRunner with a video path and a set of frame
// timestamps; the runner extracts those frames, sends them to a VLM,
// and returns one caption per frame.
//
// Stage 6a: MLXVLMCaptionRunner is now wired end-to-end using
// `mlx-swift-examples` (specifically the MLXVLM library at tag 2.29.1)
// to run `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` natively. The
// Python subprocess runner remains as a stub-only fallback; per the
// integration doc, "do not start there." Path decision documented in
// the engine-wiring report.
//
// Build-config note: the `#if canImport(MLXVLM)` guard exists so the
// captioning protocol still compiles in build contexts where the SPM
// dep is not yet wired (e.g. someone running a metrics-only build off
// the bare `feature/scene-captions` schema branch). When the dep is
// absent, MLXVLMCaptionRunner throws .notImplemented just like the
// pre-6a stub did. Once the dep is established on main this fence can
// come out.

/// Vision-language captioning interface. Implementations should be
/// `Sendable` so the captioning loop can ferry them across actors.
protocol CaptionRunner: Sendable {

    /// Identifier written into `VideoRecord.sceneCaptionModel` as
    /// provenance. Suggested format: short, stable, machine-readable
    /// (e.g. "qwen2.5-vl-3b-4bit", "python-vlm-qwen25vl-3b-4bit").
    /// Lets the UI later filter "captioned with X" or offer a
    /// "re-caption with current model" action.
    var modelID: String { get }

    /// Caption a single video file at the given frame timestamps
    /// (seconds into the clip). The runner is responsible for frame
    /// extraction — keeping the AVFoundation/ffmpeg detail behind the
    /// engine boundary so the catalog layer doesn't have to care.
    ///
    /// Returns one `SceneCaption` per input timestamp, in the same
    /// order. May return fewer if specific frames fail to decode (the
    /// runner should log + skip rather than fail the whole run).
    ///
    /// Throws `CaptionRunnerError` on engine failure (model load,
    /// out-of-memory, inability to open the file). Cancellation
    /// honored via `Task.checkCancellation()` between frames so the
    /// UI's "Cancel Captioning" action can stop a run mid-file.
    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption]

    /// Multi-signal dossier extraction. Runs three targeted prompts
    /// per frame (date / scene / text) and returns the results split
    /// into the three matching arrays. Date and text prompts emit
    /// only non-NONE responses; the scene prompt emits one entry per
    /// successfully-decoded frame.
    ///
    /// Default impl wraps `caption(...)` and returns scenes only —
    /// engines that can natively support targeted prompts (e.g. the
    /// MLXVLM runner) should override to issue the three prompts as
    /// a tight per-frame batch sharing one model load.
    ///
    /// See `docs/family-tagging-and-search-roadmap.md` (item #4) and
    /// `scripts/dossier_batch.py` (the original Python prototype) for
    /// the prompt wording and parse semantics this is parity with.
    func dossier(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> DossierExtraction
}

extension CaptionRunner {
    /// Default dossier impl. Engines without targeted-prompt support
    /// get scene-only dossiers, which still feed `pfInferRecordDate`'s
    /// path-year + file-mtime fallbacks. The MLXVLM runner overrides.
    func dossier(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> DossierExtraction {
        let scenes = try await caption(videoPath: videoPath, atTimestamps: timestamps)
        return DossierExtraction(scenes: scenes, dates: [], texts: [])
    }
}

// MARK: - DossierExtraction
//
// Three independent signal channels from one VLM batch. Shape mirrors
// `VideoRecord`'s dossier fields so the writeback layer can plop the
// arrays in directly without re-shaping.

/// Result of a multi-prompt dossier pass over one video. Each array is
/// keyed by frame timestamp via the `SceneCaption.timestamp` field, so
/// the UI can later highlight which frame the OCR date came from.
struct DossierExtraction: Sendable, Equatable {
    /// Scene descriptions — one per successfully-captioned frame.
    /// Same semantic as the existing `caption()` result; replaces
    /// `VideoRecord.sceneCaptions` wholesale.
    let scenes: [SceneCaption]

    /// OCR date candidates — burn-in timestamps the model read.
    /// Only includes frames whose response is non-NONE. Fed to
    /// `pfParseOcrDate` for triangulation.
    let dates: [SceneCaption]

    /// Other on-screen text — signs, captions, screen content. Only
    /// includes frames whose response is non-NONE. Searchable via the
    /// universal matcher.
    let texts: [SceneCaption]

    /// Empty extraction — useful for engines that return no signals
    /// (e.g. when frame extraction yielded zero usable frames).
    static let empty = DossierExtraction(scenes: [], dates: [], texts: [])
}

// MARK: - Errors

/// Typed errors the captioning UI can pattern-match on for user
/// messaging. Other failures (decode failure for a single frame)
/// should be logged and skipped, not thrown.
enum CaptionRunnerError: Error, CustomStringConvertible {
    /// Engine not yet wired — stub implementation. Will go away once
    /// MLXVLMCaptionRunner / PythonSubprocessCaptionRunner are real.
    case notImplemented(engine: String)

    /// VLM model couldn't be loaded (missing weights, version mismatch,
    /// OOM during weight load).
    case modelLoadFailed(reason: String)

    /// Video file could not be opened (missing, corrupt, unreadable).
    case videoUnreadable(path: String)

    /// Engine threw something unrecognized; preserves the underlying
    /// error for diagnostic logging.
    case underlying(Error)

    var description: String {
        switch self {
        case .notImplemented(let engine):
            return "Caption engine '\(engine)' is not yet implemented."
        case .modelLoadFailed(let reason):
            return "Caption model load failed: \(reason)"
        case .videoUnreadable(let path):
            return "Could not read video at \(path)"
        case .underlying(let err):
            return "Captioning engine error: \(err)"
        }
    }
}

// MARK: - Frame extraction
//
// AVFoundation-based frame extraction shared by the MLX runner (and
// any future runner). Mirrors the seek-and-grab pattern in
// SeekingFrameProvider but is one-shot per timestamp rather than a
// streaming provider — we want exact placement, not throughput.
//
// Worst-case memory footprint: one CGImage at the video's native
// resolution per call. Caller releases by letting the CGImage go out
// of scope between frames. The downstream MLX path immediately
// converts to CIImage and the VLM resamples to 512×512 — so the
// transient peak is the decoded frame, not a buffer of frames.

private let captionLogger = Logger(subsystem: "Rick-Breen.VideoScan", category: "captions")

/// Result of extracting a single frame. Decode failures yield
/// `.failed` so the caller can log + skip without aborting the batch.
private enum FrameExtraction {
    case success(CGImage)
    case failed(reason: String)
}

/// Extracts one CGImage per timestamp. Returns the same number of
/// entries as input, in order — `.failed` slots are placeholders so
/// the caller knows which timestamp dropped out. Tolerances are tight
/// (100 ms) to keep captions aligned with what the user would see if
/// they scrubbed to that point in the video.
///
/// Swift's `[(Double, FrameExtraction)]` ≈ a C++ `std::vector<std::pair<double, ...>>`.
private func extractFrames(
    from videoURL: URL,
    atTimestamps timestamps: [Double]
) async throws -> [(timestamp: Double, frame: FrameExtraction)] {
    let asset = AVURLAsset(url: videoURL)
    // Cheap reachability check — duration of 0 (unreadable / missing) lets
    // us fail fast with the right error type before we burn time per-frame.
    let duration: CMTime
    do {
        duration = try await asset.load(.duration)
    } catch {
        throw CaptionRunnerError.videoUnreadable(path: videoURL.path)
    }
    let durSec = CMTimeGetSeconds(duration)
    if !durSec.isFinite || durSec <= 0 {
        throw CaptionRunnerError.videoUnreadable(path: videoURL.path)
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tol
    generator.requestedTimeToleranceAfter = tol

    var results: [(Double, FrameExtraction)] = []
    results.reserveCapacity(timestamps.count)

    for ts in timestamps {
        try Task.checkCancellation()

        // Clamp the timestamp to the video range so requesting (say) 5s on
        // a 3s clip doesn't fail — we silently land on the last frame.
        let clamped = max(0.0, min(ts, max(0.0, durSec - 0.05)))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)

        do {
            // `generateCGImageAsynchronously` is the modern API on macOS 13+;
            // copyCGImage (sync) is deprecated and prints a runtime warning.
            // Wrap the callback in a continuation to keep the function async.
            let cg: CGImage = try await withCheckedThrowingContinuation { cont in
                generator.generateCGImageAsynchronously(for: cmTime) { image, _, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let image = image {
                        cont.resume(returning: image)
                    } else {
                        cont.resume(throwing: CaptionRunnerError.videoUnreadable(path: videoURL.path))
                    }
                }
            }
            results.append((ts, .success(cg)))
        } catch {
            // Single-frame decode failure: log + skip per the protocol contract.
            // The whole-batch failure mode is "couldn't even open the asset",
            // which fired above.
            captionLogger.warning("Frame extract failed at \(String(format: "%.2f", ts))s in \(videoURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            results.append((ts, .failed(reason: error.localizedDescription)))
        }
    }

    return results
}

// MARK: - MLX-swift engine
//
// Stage 6a implementation. Loads Qwen2.5-VL-3B-Instruct-4bit via
// `mlx-swift-examples`' VLMRegistry/loadModelContainer pair, then
// feeds one CIImage per frame through ChatSession.respond(to:image:).
//
// One model instance per `caption()` call. Per the plan doc and the
// ArcFace concurrency bug history, sharing a single MLX model across
// concurrent calls is something to verify rather than assume; for 6a
// we take the conservative path of fresh-load-per-call. Stage 6b can
// optimize once batch UI exists and the cost is measurable.
//
// Worst-case memory footprint: model weights (~3 GB for the 4-bit
// quantized Qwen2.5-VL-3B) plus one CIImage at native frame size
// plus the KV cache the chat session builds during generation
// (bounded by max_tokens × hidden_dim, typically <100 MB for 200
// tokens). First call also triggers HuggingFace weight download
// (~3 GB) into the user's HuggingFace cache, which is one-time.

#if canImport(MLXVLM)

/// Prompt fixed for stage 6a — we mirror the Python prototype's prompt
/// for shape comparability. Stage 6b's UI may make this user-tunable.
private let kCaptionPrompt = "Describe this video frame in one sentence: setting, activity, count of people, any visible text."

/// Three targeted prompts for the dossier pass. Lifted verbatim from
/// `scripts/dossier_batch.py`'s PROMPTS dict so the Swift and Python
/// pipelines produce comparable output across the schema fields:
///
///   - `.date`  → `ocrDateCandidates` (after parsing via pfParseOcrDate)
///   - `.scene` → `sceneCaptions`
///   - `.text`  → `ocrText`
///
/// Wording PROVEN 2026-06-04 on Clip 03_converted.mov: 11 of 15 frames
/// agreed on "JUN 21 1991" for the date prompt. Don't drift these
/// without re-validating against the same fixture set — small wording
/// changes meaningfully shift VLM behavior.
private enum DossierPromptKind: String, CaseIterable {
    case date
    case scene
    case text

    var promptText: String {
        switch self {
        case .date:
            return "What date or time is shown anywhere in this image, including any timestamp burned into the video? If you see a date or time, give exactly what you see (e.g. 'MAR 14 1991 03:42PM'). If no date/time visible, answer just 'NONE'."
        case .scene:
            return "Briefly describe what you see in this image: people (with apparent ages and roles), location, what they're doing, and any era cues (decor, technology, fashion). 2-3 sentences."
        case .text:
            return "List all text visible in this image — burned-in subtitles, signs, screen content, anything readable. If no text, answer 'NONE'."
        }
    }
}

/// Hidden default — Qwen2.5-VL-3B-Instruct-4bit, the configuration
/// pre-registered in `VLMRegistry`. Matches the existing modelID
/// string written to `VideoRecord.sceneCaptionModel`.
///
/// Stage 6b note: this was a `struct` in 6a and loaded the model
/// container on every `caption(...)` call. The orchestrator (S6b) wants
/// a session-scoped container that survives across files in a batch.
/// `actor` ≈ a class with implicit mutex around all members — the
/// container is lazily loaded inside ensureContainer() and cached for
/// the actor's lifetime. The orchestrator builds one runner instance
/// per batch, so a batch of N videos hits exactly one model load.
actor MLXVLMCaptionRunner: CaptionRunner {

    nonisolated let modelID: String = "qwen2.5-vl-3b-4bit"

    /// Max tokens per caption. Captions are deliberately short
    /// ("one sentence") so a tight budget keeps inference fast and
    /// avoids the model running on into rambling territory. The
    /// Python prototype defaults to 120; we match for parity.
    nonisolated let maxTokens: Int

    /// Cached model container. nil until the first `caption(...)` call
    /// (or explicit `prewarm()`); reused across every subsequent call
    /// on this actor instance. Drops with the actor when the batch
    /// ends — the orchestrator does not retain runners across batches,
    /// so memory does not leak between Caption Videos invocations.
    private var cachedContainer: ModelContainer?

    init(maxTokens: Int = 120) {
        self.maxTokens = maxTokens
    }

    /// Optional: explicitly load the container before the first
    /// `caption(...)` call. The orchestrator can call this to show
    /// "Loading model…" in the progress UI before the per-file loop
    /// starts. Subsequent caption() calls hit the cached instance.
    func prewarm() async throws {
        _ = try await ensureContainer()
    }

    /// Lazily load (or return cached) container. Single point of model
    /// load — every code path that needs the container goes through
    /// here. Wrap in runMLX to keep the load itself crash-safe.
    private func ensureContainer() async throws -> ModelContainer {
        if let cached = cachedContainer { return cached }
        captionLogger.info("MLXVLMCaptionRunner: loading model container (first call this session)")
        // GPU memory cache cap — keeps the model from ballooning if
        // the host machine is shared with other GPU workloads (FD
        // pipeline running at the same time, e.g.).
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024) // 20 MB
        do {
            let container = try await runMLX {
                try await VLMModelFactory.shared.loadContainer(
                    configuration: VLMRegistry.qwen2_5VL3BInstruct4Bit
                ) { progress in
                    // Progress is from HubApi during weight download;
                    // quiet unless we're actively downloading. Once
                    // cached this never fires after the first call.
                    if progress.totalUnitCount > 0 && progress.completedUnitCount % (progress.totalUnitCount / 20 + 1) == 0 {
                        captionLogger.info("VLM weight download: \(progress.completedUnitCount)/\(progress.totalUnitCount)")
                    }
                }
            }
            cachedContainer = container
            captionLogger.info("MLXVLMCaptionRunner: model container loaded and cached")
            return container
        } catch {
            captionLogger.error("VLM model load failed: \(error.localizedDescription, privacy: .public)")
            throw CaptionRunnerError.modelLoadFailed(reason: error.localizedDescription)
        }
    }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        let filename = (videoPath as NSString).lastPathComponent
        let started = CFAbsoluteTimeGetCurrent()

        let videoURL = URL(fileURLWithPath: videoPath)
        // Up-front existence check — AVURLAsset is happy to lazily fail
        // later, but the protocol contract says videoUnreadable should
        // surface as a typed error.
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw CaptionRunnerError.videoUnreadable(path: videoPath)
        }

        // 1. Extract frames first. This is cheap relative to model
        //    loading, and failing here means we never paid the load
        //    cost. Order preserved; failed slots will be skipped below.
        let frames = try await extractFrames(from: videoURL, atTimestamps: timestamps)

        // 2. Resolve the VLM container. Lazily loaded the first time;
        //    subsequent files in the same batch hit the actor-cached
        //    instance. See ensureContainer() for the load path.
        let container = try await ensureContainer()

        // 3. Caption each successful frame. Cancellation honored
        //    between frames so a user-cancelled batch stops promptly
        //    rather than running through every timestamp first.
        //
        // NOTE on the invocation pattern: we use the lower-level
        // `MLXLMCommon.generate(input:parameters:context:)` stream
        // (collected here) instead of `ChatSession.respond`. Reason:
        // ChatSession's default UserInput.Processing.resize is
        // 512×512, and Qwen2.5-VL hits a "broadcast_shapes" mismatch
        // at that resolution on mlx-swift 0.29.1 (sequence-length
        // alignment in the vision-text fusion). The VLMEval sample
        // uses 448×448, which is what Qwen2.5-VL is trained against
        // — works cleanly. See engine-wiring report's "surprises"
        // section.
        let generateParameters = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens, temperature: 0.2, topP: 0.9
        )
        // Deterministic-ish: seed once per call so repeat captions of
        // the same frame are stable for testing. Stage 6b may make
        // this user-tunable.
        MLXRandom.seed(0xCAFE_F00D)

        var captions: [SceneCaption] = []
        captions.reserveCapacity(frames.count)

        for (ts, extraction) in frames {
            try Task.checkCancellation()
            switch extraction {
            case .failed(let reason):
                captionLogger.warning("Skipping ts=\(String(format: "%.2f", ts))s in \(filename, privacy: .public): \(reason, privacy: .public)")
                continue
            case .success(let cg):
                let ciImage = CIImage(cgImage: cg)
                let images: [UserInput.Image] = [.ciImage(ciImage)]
                let chat: [Chat.Message] = [
                    .system("You are an image understanding model capable of describing the salient features of any image."),
                    .user(kCaptionPrompt, images: images, videos: [])
                ]

                do {
                    // `runMLX` wraps the entire MLX/MLXVLM/MLXLMCommon
                    // call chain in `MLX.withError`, converting any C++
                    // layer error (shape mismatch, OOM, malformed
                    // tensor) into a Swift throw of MLXError.caught
                    // instead of letting it land in fatalError → SIGTRAP.
                    // See MLXSafety.swift for the underlying mechanism.
                    let text: String = try await runMLX {
                        try await container.perform { context in
                            var userInput = UserInput(chat: chat)
                            userInput.processing.resize = .init(width: 448, height: 448)
                            let lmInput = try await context.processor.prepare(input: userInput)

                            let stream = try MLXLMCommon.generate(
                                input: lmInput, parameters: generateParameters, context: context
                            )

                            var buffer = ""
                            for await item in stream {
                                if let chunk = item.chunk {
                                    buffer += chunk
                                }
                            }
                            // Force GPU to sync before returning so we
                            // don't pipeline several frames worth of
                            // generation in flight and burn RAM. Also
                            // forces any deferred MLX errors to surface
                            // inside the withError scope rather than on
                            // a later op.
                            MLX.Stream.gpu.synchronize()
                            return buffer
                        }
                    }

                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        captions.append(SceneCaption(timestamp: ts, text: trimmed))
                    } else {
                        captionLogger.warning("VLM returned empty caption at ts=\(String(format: "%.2f", ts))s in \(filename, privacy: .public)")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // VLM-side per-frame failure: log + skip, do not
                    // abort the whole batch. Matches the protocol
                    // contract for decode-failure handling.
                    captionLogger.warning("VLM call failed at ts=\(String(format: "%.2f", ts))s: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        appLog.write(String(format: "CaptionRunner(MLXVLM) captioned %@ at %d frames in %.1fs",
                            filename, captions.count, elapsed))
        return captions
    }

    /// Multi-signal dossier — three targeted prompts per frame, single
    /// model load shared across them. Wall-time-per-frame is ~3× the
    /// single-prompt `caption()` cost (33s/15-frame clip on M4 Max per
    /// the Python prototype baseline).
    ///
    /// Override of the protocol-extension default. The default would
    /// give scene-only via `caption()`; this version produces real OCR
    /// date + text channels too, so the catalog-wide pass actually
    /// populates `ocrDateCandidates` + `ocrText` from this engine.
    func dossier(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> DossierExtraction {
        let filename = (videoPath as NSString).lastPathComponent
        let started = CFAbsoluteTimeGetCurrent()

        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw CaptionRunnerError.videoUnreadable(path: videoPath)
        }

        let frames = try await extractFrames(from: videoURL, atTimestamps: timestamps)
        let container = try await ensureContainer()

        // Per-prompt token budgets diverge from caption's flat
        // maxTokens: date responses are short ("MAR 14 1991 03:42PM"
        // ≈ 10 tokens), text responses can be a short list, scene
        // responses run 2-3 sentences. Tighter budgets keep wall-time
        // down on the prompts that don't need length.
        let dateParams  = MLXLMCommon.GenerateParameters(maxTokens: 32,  temperature: 0.0, topP: 0.9)
        let scnParams   = MLXLMCommon.GenerateParameters(maxTokens: 180, temperature: 0.2, topP: 0.9)
        let textParams  = MLXLMCommon.GenerateParameters(maxTokens: 96,  temperature: 0.0, topP: 0.9)
        MLXRandom.seed(0xCAFE_F00D)

        var scenes: [SceneCaption] = []
        var dates:  [SceneCaption] = []
        var texts:  [SceneCaption] = []
        scenes.reserveCapacity(frames.count)

        for (ts, extraction) in frames {
            try Task.checkCancellation()
            guard case .success(let cg) = extraction else {
                if case .failed(let reason) = extraction {
                    captionLogger.warning("Skipping ts=\(String(format: "%.2f", ts))s in \(filename, privacy: .public): \(reason, privacy: .public)")
                }
                continue
            }
            let ciImage = CIImage(cgImage: cg)
            let images: [UserInput.Image] = [.ciImage(ciImage)]

            for kind in DossierPromptKind.allCases {
                try Task.checkCancellation()
                let params: MLXLMCommon.GenerateParameters = {
                    switch kind {
                    case .date:  return dateParams
                    case .scene: return scnParams
                    case .text:  return textParams
                    }
                }()
                let chat: [Chat.Message] = [
                    .system("You are an image understanding model capable of describing the salient features of any image."),
                    .user(kind.promptText, images: images, videos: [])
                ]
                do {
                    let text: String = try await runMLX {
                        try await container.perform { context in
                            var userInput = UserInput(chat: chat)
                            userInput.processing.resize = .init(width: 448, height: 448)
                            let lmInput = try await context.processor.prepare(input: userInput)
                            let stream = try MLXLMCommon.generate(
                                input: lmInput, parameters: params, context: context
                            )
                            var buffer = ""
                            for await item in stream {
                                if let chunk = item.chunk { buffer += chunk }
                            }
                            MLX.Stream.gpu.synchronize()
                            return buffer
                        }
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    // NONE filtering — match the Python POC: date/text
                    // responses of "NONE" (case-insensitive, optionally
                    // with surrounding punctuation) are dropped here.
                    // Scene captions always retained.
                    let upper = trimmed.uppercased()
                    let isNoneAnswer = upper == "NONE"
                        || upper.hasPrefix("NONE.")
                        || upper.hasPrefix("NONE ")
                    switch kind {
                    case .date:
                        if !isNoneAnswer {
                            dates.append(SceneCaption(timestamp: ts, text: trimmed))
                        }
                    case .scene:
                        scenes.append(SceneCaption(timestamp: ts, text: trimmed))
                    case .text:
                        if !isNoneAnswer {
                            texts.append(SceneCaption(timestamp: ts, text: trimmed))
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    captionLogger.warning("VLM dossier call (\(kind.rawValue, privacy: .public)) failed at ts=\(String(format: "%.2f", ts))s: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        appLog.write(String(format: "CaptionRunner(MLXVLM) dossier %@ — %d scenes, %d dates, %d text in %.1fs",
                            filename, scenes.count, dates.count, texts.count, elapsed))
        return DossierExtraction(scenes: scenes, dates: dates, texts: texts)
    }
}

#else

/// Stub that fires only when the MLXVLM SPM dep is unavailable in the
/// build configuration. Lets the protocol surface compile cleanly on
/// branches that haven't yet adopted the dep — the actual production
/// build always has `canImport(MLXVLM)` true.
actor MLXVLMCaptionRunner: CaptionRunner {
    nonisolated let modelID: String = "qwen2.5-vl-3b-4bit"

    init(maxTokens: Int = 120) {
        _ = maxTokens   // silence unused warning under the stub path
    }

    func prewarm() async throws {
        throw CaptionRunnerError.notImplemented(engine: "MLXVLM")
    }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        let filename = (videoPath as NSString).lastPathComponent
        appLog.write("CaptionRunner(MLXVLM) stub for \(filename) (\(timestamps.count) frame(s)) — MLXVLM SPM dep not available in this build")
        throw CaptionRunnerError.notImplemented(engine: "MLXVLM")
    }
}

#endif

// MARK: - Python subprocess engine (stub)

/// Stub for the fallback Python subprocess implementation. Will wrap
/// `scripts/vlm_caption.py` via `Process()` (same pattern PersonFinder
/// uses for `face_recognize.py`). Only used if the MLX-swift path
/// proves unworkable; per the plan, "do not start there."
struct PythonSubprocessCaptionRunner: CaptionRunner {

    let modelID: String = "python-vlm-qwen25vl-3b-4bit"

    /// Path to the Python executable that has `mlx-vlm` installed.
    /// User-configured (mirrors PersonFinder's `pythonPath` setting).
    let pythonPath: String

    /// Path to scripts/vlm_caption.py in the repo / user environment.
    let scriptPath: String

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        let filename = (videoPath as NSString).lastPathComponent
        appLog.write("CaptionRunner(Python) stub for \(filename) (\(timestamps.count) frame(s)) — engine not yet wired")
        throw CaptionRunnerError.notImplemented(engine: "PythonSubprocess")
    }
}
