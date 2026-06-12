import Foundation
import os

#if canImport(MLX)
import MLX
#endif

// MARK: - MLX shutdown coordination
//
// Why this file exists: MLX's C++ core registers a static Scheduler
// whose destructor runs during `exit()` → `__cxa_finalize_ranges`. The
// destructor calls `mlx::core::synchronize` → `gpu::synchronize` →
// `MTL::CommandBuffer::waitUntilCompleted` — i.e. it talks to Metal
// AFTER AppKit/Metal teardown has begun. On quit, that segfaults:
//
//     exit → __cxa_finalize_ranges → Scheduler::~Scheduler()
//          → mlx::core::synchronize → MTL::CommandBuffer::waitUntilCompleted
//          → SIGSEGV
//
// See crash reports VideoScan-2026-06-12-143757.ips (dtor variant) and
// VideoScan-2026-06-11-232946.ips (mid-inference qmm dispatch variant)
// in ~/Library/Logs/DiagnosticReports. The crash only fires when MLX
// inference actually ran this session (the VLM dossier/caption engine
// in CaptionRunner.swift) — quits on sessions that never loaded the
// model are clean.
//
// The fix has three layers (see AppDelegate in VideoScanApp.swift):
//   1. Drain: applicationShouldTerminate cancels the dossier/VLM batch
//      and waits (bounded) for in-flight inference to settle.
//   2. Synchronize: applicationWillTerminate flushes MLX's GPU stream
//      while Metal is still healthy, so no work is queued at exit().
//   3. Backstop: after all explicit persistence completes, `_exit(0)`
//      bypasses C++ static destructors entirely, so the Scheduler dtor
//      never runs. Gated on `mlxInferenceWasUsed()` so sessions that
//      never touched the VLM keep the normal exit path.
//
// In C++ terms: this is the classic "static destruction order fiasco"
// across dylib boundaries; since we can't reorder MLX's statics vs
// Metal's teardown, we make sure the GPU is quiesced and then skip
// finalization altogether.

private let mlxShutdownLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "shutdown")

private let mlxUsageLock = NSLock()
/// `nonisolated(unsafe)` ≈ "I synchronize this myself" — guarded by
/// `mlxUsageLock` above, same pattern as MLXSafety.swift's error slot.
nonisolated(unsafe) private var mlxInferenceUsedFlag = false

/// Record that in-process MLX inference ran this session. Called from
/// `MLXVLMCaptionRunner.ensureContainer()` — the single funnel every
/// VLM caption/dossier call goes through. Thread-safe.
func noteMLXInferenceUsed() {
    mlxUsageLock.withLock { mlxInferenceUsedFlag = true }
}

/// True if MLX inference ran at any point this session. Drives the
/// quit-time synchronize + `_exit` backstop in AppDelegate.
func mlxInferenceWasUsed() -> Bool {
    mlxUsageLock.withLock { mlxInferenceUsedFlag }
}

/// Test hook — clears the usage flag so tests can assert both branches.
func resetMLXInferenceUsedForTesting() {
    mlxUsageLock.withLock { mlxInferenceUsedFlag = false }
}

/// Flush MLX's GPU stream while Metal is still healthy (i.e. before
/// `exit()` starts tearing the process down). No-op when MLX inference
/// never ran. Callers should SKIP this when the quit-time drain timed
/// out — synchronizing behind a still-running generation could block
/// quit for many seconds; the `_exit` backstop covers that case.
func synchronizeMLXForShutdown() {
    guard mlxInferenceWasUsed() else { return }
    #if canImport(MLX)
    let started = CFAbsoluteTimeGetCurrent()
    do {
        // runMLX (MLXSafety.swift) converts any deferred MLX C++ error
        // surfaced by the sync into a Swift throw instead of fatalError.
        try runMLX {
            MLX.Stream.gpu.synchronize()
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        mlxShutdownLog.info("MLX GPU stream synchronized for shutdown in \(String(format: "%.0f", ms))ms")
    } catch {
        // Log and continue — quit must proceed; the _exit backstop
        // still prevents the static-dtor segfault.
        mlxShutdownLog.error("MLX shutdown synchronize failed: \(error.localizedDescription, privacy: .public)")
    }
    #endif
}
