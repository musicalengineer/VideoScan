import Foundation

// MARK: - Caption Runner
//
// Engine-agnostic abstraction for vision-language captioning. The Swift
// app calls a CaptionRunner with a video path and a set of frame
// timestamps; the runner extracts those frames, sends them to a VLM,
// and returns one caption per frame.
//
// Two implementations are planned:
//
// 1. MLXVLMCaptionRunner — preferred path, uses Apple's mlx-swift-lm
//    via the MLXVLM library. Qwen2.5-VL-3B-Instruct-4bit is a first-
//    class pre-registered configuration (see docs/scene_captions_plan.md
//    + the S4 research summary). Native Swift, no Python dependency.
//
// 2. PythonSubprocessCaptionRunner — fallback path, wraps the
//    already-shipping scripts/vlm_caption.py via Process(). Plan B
//    per the integration doc; here as a safety net if the MLX path
//    hits a wall we can't engineer around.
//
// Both ship as stubs in this step. Engine wiring follows in a later
// commit so the abstraction layer can be reviewed and tested without
// pulling in the mlx-swift-lm Swift package dependency yet.

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

// MARK: - MLX-swift engine (stub)

/// Stub for the preferred mlx-swift implementation. Will use
/// `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` via the MLXVLM library
/// from mlx-swift-lm. Currently throws `notImplemented` — the actual
/// wiring is its own commit so adding the mlx-swift-lm Swift package
/// can be reviewed in isolation.
struct MLXVLMCaptionRunner: CaptionRunner {

    /// The Hugging Face model id used as both the runtime identifier
    /// and the provenance string written to VideoRecord. Matches the
    /// id pre-registered in MLXVLM's VLMRegistry.qwen2_5VL3BInstruct4Bit
    /// (S4 research finding).
    let modelID: String = "qwen2.5-vl-3b-4bit"

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        // Until S6 wires MLXVLM, every call lands here. Log so the
        // stub-throws path is observable in videoscan.log (failure
        // mode is "user sees 'engine not yet wired' in the log"
        // rather than "captioning silently no-ops").
        let filename = (videoPath as NSString).lastPathComponent
        appLog.write("CaptionRunner(MLXVLM) stub for \(filename) (\(timestamps.count) frame(s)) — engine not yet wired (S6)")
        throw CaptionRunnerError.notImplemented(engine: "MLXVLM")
    }
}

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
