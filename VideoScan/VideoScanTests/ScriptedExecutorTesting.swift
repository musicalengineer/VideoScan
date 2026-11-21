// ScriptedExecutorTesting.swift — the test-side half of ScriptedExecutor
// (VideoScanCore/ScriptedExecutor.swift) for the app's tests: bind the mock
// for one body and turn its failures (unmatched commands, escapes) into
// test issues. Core's tests carry the same ten lines (Core cannot import
// Testing, and the two test bundles cannot share a source file).
//
// For Rick: this replaces the fake-ffmpeg-script-plus-setenv(VS_FFMPEG_PATH)
// pattern. The env var was one process-wide global, so every suite that
// used it had to be `.serialized`; a ScriptedExecutor is bound to the
// test's own task tree (a thread_local that follows the coroutine), so the
// suites run in parallel.

import Foundation
import Testing
import VideoScanCore

extension ScriptedExecutor {
    /// Run `body` with this mock as the task's executor; every unmatched or
    /// escaped command becomes an Issue at the caller's line.
    func scoped<R>(
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        defer {
            for failure in failures { Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation) }
        }
        return try await withInstalled(isolation: isolation, body)
    }
}
