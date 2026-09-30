import Foundation
import os

#if canImport(MLX)
import MLX
#endif

// MARK: - MLX crash-safety wrapper
//
// MLX's C++ layer (mlx_fast_scaled_dot_product_attention, broadcast
// checks, allocator OOM, etc.) reports errors by calling
// `mlx_set_error_handler`'s registered callback. mlx-swift trampolines
// that into a Swift `ErrorHandler` singleton whose default `dispatch`
// path is `fatalError(message)` — which lands in `_assertionFailure`
// and SIGTRAPs the process. See the crash trace at
// ~/Library/Logs/DiagnosticReports/VideoScan-2026-05-25-170604.ips:
//
//     EXC_BREAKPOINT (SIGTRAP)
//     libswiftCore        _assertionFailure
//     VideoScan           ErrorHandler.dispatch
//     VideoScan           errorHandlerTrampoline
//     VideoScan           _mlx_error
//     VideoScan           mlx_fast_scaled_dot_product_attention
//
// We can't catch this with `try/catch` (it's not a Swift throw) and we
// can't catch it with `ObjCExceptionCatcher` (it's not an NSException).
//
// mlx-swift 0.29.1 ships an official escape hatch: `withError { ... }`
// installs a task-local error-collecting handler that pre-empts the
// default fatalError path. When MLX's C++ layer calls into the
// trampoline while a `withError` scope is active, the message is
// captured into an `ErrorBox`, the op returns, and `errorBox.check()`
// at scope exit throws `MLXError.caught(message)` as a normal Swift
// error. See Source/MLX/ErrorHandler.swift in mlx-swift for the
// underlying mechanism.
//
// This file provides:
//   1. `runMLX(_:)` — the convenience wrapper VideoScan code should use
//      around any block that calls into MLX/MLXVLM/MLXLMCommon. Errors
//      come back as `CaptionRunnerError.underlying(MLXError.caught(...))`
//      instead of crashing the process.
//   2. `installMLXSafetyNet()` — a global belt-and-suspenders handler
//      registered at app launch. Catches messages from any MLX call
//      site that wasn't wrapped in `runMLX` (e.g. a static initializer,
//      a background eval loop) and logs them instead of crashing. Task-
//      local handlers from `runMLX` still take precedence over this
//      when a wrapped call is active — see ErrorHandler.dispatch in
//      mlx-swift.
//
// Worst-case memory footprint: the ErrorBox holds at most a single
// String message (typically <500 bytes). The global safety-net path
// also stores at most one most-recent message. No per-call buffering,
// no caching, no streaming.

private let mlxLogger = Logger(subsystem: "Rick-Breen.VideoScan", category: "mlx-safety")

/// Records the most recent MLX error message that escaped a wrapped
/// scope and hit the global safety net. Cleared whenever a new one
/// arrives. Diagnostic-only — production code path should be wrapping
/// MLX calls with `runMLX` so this stays nil.
///
/// Swift's `nonisolated(unsafe)` ≈ "I promise to synchronize accesses
/// myself" — we serialize via the lock below.
private let globalErrorLock = NSLock()
nonisolated(unsafe) private var lastGlobalMLXError: String? = nil

/// Returns the most recent message that hit the global safety net, or
/// nil. Useful for diagnostics. Thread-safe.
func recentGlobalMLXError() -> String? {
    globalErrorLock.withLock { lastGlobalMLXError }
}

/// Clears the recent-global-error slot. Tests use this to confirm a
/// subsequent call didn't trigger the safety net.
func clearRecentGlobalMLXError() {
    globalErrorLock.withLock { lastGlobalMLXError = nil }
}

#if canImport(MLX)

/// C callback installed via `mlx_set_error_handler`. Logs + stores the
/// message but does NOT call `fatalError`. This is the belt-and-
/// suspenders path; the per-call `runMLX` wrapper is the primary
/// defense.
///
/// `@convention(c)` means "ABI-compatible with a C function pointer"
/// — no Swift closure captures, no exception unwinding through it.
private let globalSafetyHandler:
    @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { msg, _ in
        let message = msg.map { String(cString: $0) } ?? "<no message>"
        globalErrorLock.withLock { lastGlobalMLXError = message }
        // os.Logger is signal-safe enough for this; we avoid appLog here
        // because the safety handler may fire from background threads
        // during teardown when appLog state is uncertain.
        mlxLogger.error("MLX global safety net caught: \(message, privacy: .public)")
    }

/// Installs the global safety net. Idempotent — safe to call multiple
/// times (mlx_set_error_handler overwrites). Call once at app launch
/// before any MLX code runs.
///
/// Note: mlx-swift's own `errorHandler` singleton lazy-installs its
/// trampoline the first time `withError` / `withErrorHandler` is
/// called. Our `setErrorHandler` here updates the SAME singleton's
/// `globalHandler` slot — it doesn't disrupt the trampoline. When a
/// task-local handler (from runMLX) is on the stack it still wins;
/// the global handler only fires when no scoped handler is active.
@MainActor
func installMLXSafetyNet() {
    // Touch a no-op MLX symbol to ensure the trampoline-installing
    // lazy var in mlx-swift fires before we override the global
    // handler slot. Reading GPU.cacheLimit is cheap and non-allocating.
    _ = MLX.GPU.cacheLimit

    // The deprecated `setErrorHandler` is the only public API to set
    // the global slot; the deprecation is a steer toward `withError`
    // for per-call use, which we're already doing. Suppress the
    // deprecation warning for this one intentional global install.
    @available(*, deprecated)
    func install() {
        setErrorHandler(globalSafetyHandler, data: nil, dtor: nil)
    }
    install()

    mlxLogger.info("MLX safety net installed")
}

/// Wraps a block of MLX calls. Errors raised inside the C++ layer that
/// would otherwise call `fatalError` are converted into thrown Swift
/// errors here. Use this around every MLX/MLXVLM/MLXLMCommon call site
/// that handles potentially untrusted input shapes (frame resolution,
/// token lengths, batch sizes).
///
/// `MLX.withError` is the underlying mlx-swift primitive — see
/// Source/MLX/ErrorHandler.swift in mlx-swift 0.29.1. We re-export it
/// under a project-local name (`runMLX`) so call sites stay readable
/// and so we can swap the implementation if mlx-swift's API shifts.
///
/// The returned error is `MLXError.caught(message)` — call sites can
/// re-wrap into `CaptionRunnerError.underlying(error)` for the typed
/// error surface the UI expects.
func runMLX<R>(_ body: () async throws -> R) async throws -> R {
    try await MLX.withError {
        try await body()
    }
}

/// Synchronous variant for non-async MLX call sites.
func runMLX<R>(_ body: () throws -> R) throws -> R {
    try MLX.withError {
        try body()
    }
}

#else

// MLX dep not present in this build configuration — provide no-op
// stand-ins so call sites compile cleanly. The dep is always present
// in the main build; this fence mirrors CaptionRunner's
// `#if canImport(MLXVLM)`.

@MainActor
func installMLXSafetyNet() {
    // No-op when MLX is unavailable.
}

func runMLX<R>(_ body: () async throws -> R) async throws -> R {
    try await body()
}

func runMLX<R>(_ body: () throws -> R) throws -> R {
    try body()
}

#endif
