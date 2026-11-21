// ScriptedExecutorTesting.swift — the test-side half of ScriptedExecutor
// (Core source, ScriptedExecutor.swift): bind the mock for one body and turn
// its failures (unmatched commands, escapes) into test issues. The app's
// VideoScanTests has the same ten lines (Core cannot import Testing).

import Testing
@testable import VideoScanCore

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
