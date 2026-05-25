import Foundation
import Testing
@testable import VideoScan

#if canImport(MLX)
import MLX
#endif

// MARK: - MLX safety wrapper tests
//
// Verifies that MLX C++ errors (the kind that previously SIGTRAPed
// VideoScan when the VLM hit a shape/broadcast mismatch — see
// ~/Library/Logs/DiagnosticReports/VideoScan-2026-05-25-170604.ips)
// are converted into catchable Swift errors via `runMLX { ... }`.
//
// These tests do NOT load the full 3GB VLM; they trigger the same
// error pipeline using cheap in-memory MLXArray ops. Same code path
// (mlx_set_error_handler → errorHandlerTrampoline → ErrorHandler.dispatch),
// same crash before the fix.
//
// Cheap enough to run on every full suite sweep — no VS_RUN_VLM gating.
// The point of these tests is to be there on every CI run to catch
// regressions in the safety wrapper itself.

#if canImport(MLX)

@Suite("MLX crash safety — runMLX wrapper")
struct MLXSafetyTests {

    /// The headline test: a shape-mismatched MLX op MUST come back as
    /// a Swift error, not as a SIGTRAP that kills the test host. Before
    /// MLXSafety.swift landed, this test would crash the process.
    @Test("shape mismatch throws instead of crashing the process")
    func mlxShapeErrorDoesNotCrashTheProcess() async throws {
        // Provoke the same kind of broadcast error MLXVLM was hitting:
        // two MLXArrays whose shapes can't be broadcast together. This
        // is exactly the example mlx-swift's own ErrorHandler.swift
        // documents as a triggering case (see lines 33-39 of that file
        // in mlx-swift 0.29.1).
        //
        // Without runMLX, the addition below calls into
        // mlx_fast / broadcast_shapes, hits _mlx_error, trampolines
        // into ErrorHandler.dispatch → fatalError → SIGTRAP.
        //
        // With runMLX, the trampoline finds our task-local handler at
        // the top of the stack, captures the message into ErrorBox,
        // and `withError`'s scope-exit throws MLXError.caught.

        do {
            _ = try await runMLX {
                let a = MLXArray(0 ..< 10, [2, 5])
                let b = MLXArray(0 ..< 15, [3, 5])
                let result = a + b
                // Force evaluation so the error fires before we leave
                // the runMLX scope. MLX is lazy; without eval the
                // graph could be deferred past withError's exit.
                eval(result)
                return result
            }
            Issue.record("Expected MLX shape mismatch to throw, but the call returned normally")
        } catch let err as MLXError {
            switch err {
            case .caught(let message):
                let lower = message.lowercased()
                #expect(
                    lower.contains("shape") || lower.contains("broadcast") || lower.contains("dim"),
                    "Expected shape/broadcast/dim in error, got: \(message)"
                )
            }
        } catch {
            // Any Swift error type is acceptable per the task brief
            // ("a Swift error back — exactly what we want"). Surface
            // it so we know what we got.
            let desc = error.localizedDescription.lowercased()
            #expect(
                desc.contains("shape") || desc.contains("broadcast") || desc.contains("dim") || desc.contains("mlx"),
                "Got non-MLXError Swift error: \(error)"
            )
        }
    }

    /// Regression check: a normal MLX op inside runMLX should still
    /// work and return its value. The wrapper must not break the
    /// happy path.
    @Test("happy-path MLX call inside runMLX returns normally")
    func happyPathRoundtrip() async throws {
        let result: [Int32] = try await runMLX {
            let a = MLXArray([1, 2, 3, 4, 5])
            let b = MLXArray([10, 20, 30, 40, 50])
            let sum = a + b
            eval(sum)
            return sum.asArray(Int32.self)
        }
        #expect(result == [11, 22, 33, 44, 55])
    }

    /// Synchronous variant smoke test — same happy path, the
    /// non-async overload.
    @Test("synchronous runMLX returns normally")
    func happyPathRoundtripSync() throws {
        let result: [Int32] = try runMLX {
            let a = MLXArray([1, 2, 3])
            let b = MLXArray([4, 5, 6])
            let sum = a + b
            eval(sum)
            return sum.asArray(Int32.self)
        }
        #expect(result == [5, 7, 9])
    }

    /// Errors from inside runMLX must propagate without polluting
    /// subsequent runMLX scopes. Each call gets a fresh ErrorBox via
    /// the task-local stack.
    @Test("error in one runMLX does not contaminate the next")
    func errorIsolation() async throws {
        // First call: should throw.
        do {
            _ = try await runMLX {
                let a = MLXArray(0 ..< 6, [2, 3])
                let b = MLXArray(0 ..< 8, [2, 4])
                let r = a + b
                eval(r)
                return r
            }
            Issue.record("Expected the first call to throw")
        } catch {
            // expected
        }

        // Second call: should succeed cleanly.
        let result: [Int32] = try await runMLX {
            let a = MLXArray([100, 200])
            eval(a)
            return a.asArray(Int32.self)
        }
        #expect(result == [100, 200])
    }

    /// Belt-and-suspenders: if `installMLXSafetyNet()` runs, then a
    /// later unwrapped MLX error (one that didn't go through runMLX)
    /// should land in our global handler instead of crashing.
    ///
    /// This test deliberately calls MLX OUTSIDE a runMLX wrapper to
    /// exercise that fallback path. Before the fix, this would also
    /// SIGTRAP. After the fix with the global handler installed, we
    /// observe a `recentGlobalMLXError()` and the process continues.
    ///
    /// Note: the order matters — the safety net must be installed
    /// before the unwrapped MLX call. We install it here explicitly
    /// since the test host's AppDelegate.applicationDidFinishLaunching
    /// is short-circuited by `isRunningTests`.
    @Test("global safety net catches unwrapped MLX errors")
    @MainActor
    func globalSafetyNetCatchesUnwrappedErrors() async throws {
        installMLXSafetyNet()
        clearRecentGlobalMLXError()

        // Cause an unwrapped error. We expect the process to survive
        // because the global handler logs + stores instead of calling
        // fatalError.
        let a = MLXArray(0 ..< 12, [3, 4])
        let b = MLXArray(0 ..< 10, [2, 5])
        let bad = a + b
        eval(bad)

        // Give the C side a tick to finish dispatching the error
        // callback. eval() is synchronous, but the handler runs on
        // whatever thread MLX chose. A short sleep is fine for the
        // assertion; production code never relies on this path.
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s

        let recent = recentGlobalMLXError()
        #expect(recent != nil, "Expected global safety net to capture the unwrapped MLX error")
        if let recent {
            // The MLX error pipeline can cascade — once an op produces
            // an invalid array, subsequent ops on that array fire their
            // own errors. We capture the most recent (which may be a
            // downstream cascade like "expected a non-empty mlx_array").
            // The point of this test is that the process is still alive
            // to read `recent` at all — without the safety net, the
            // first call would have SIGTRAPed before this assertion.
            // Sanity-check that we got SOMETHING MLX-ish; the exact
            // message text is unstable across mlx-swift versions.
            #expect(!recent.isEmpty, "Captured global MLX error was empty")
            // The most important assertion: the process survived. If
            // we got here, the global safety net is doing its job.
        }
    }
}

#endif  // canImport(MLX)
