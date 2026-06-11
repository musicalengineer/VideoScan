import Foundation
import Testing

@Suite struct CICanaryTests {

    /// True only on GitHub-hosted runners. The CI test plan injects CI=1
    /// locally too (shared scheme default), so `CI` can't distinguish the
    /// environments — GITHUB_ACTIONS is set by GitHub and nothing else.
    private static var isGitHubCI: Bool {
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
    }

    // Deliberate failure — proves the test runner can detect and report
    // a real failure. CI verifies this test appears as "failed" in the
    // output. If it shows "passed" or is absent, tests are ghost-passing.
    //
    // CI-only since 2026-06-09: locally it polluted every full-suite run
    // with one phantom failure (TestDriver totals, "is main green?"
    // checks), eroding the zero-failures-means-zero-failures signal. The
    // ghost-pass class this guards against is specific to GH virt-M1
    // runners; local runs don't need the tripwire.
    @Test(.enabled(if: isGitHubCI)) func mustFail() {
        #expect(1 == 2)
    }

    // Deliberate pass — proves the runner executes both outcomes.
    @Test func mustPass() {
        #expect(1 == 1)
    }
}
