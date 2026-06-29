import Testing
import Foundation
@testable import VideoScan

// MARK: - PathScopeTests
//
// PathScope.contains replaces raw `fullPath.hasPrefix(root)` checks used
// throughout the catalog's destructive / state-changing operations
// (codex C2). Raw hasPrefix treats "/Volumes/Drive" as containing
// "/Volumes/Drive Backup/a.mov", so an op scoped to one volume could
// reach into a SIBLING volume — catastrophic for destructive ops on
// irreplaceable media. PathScope matches only at a real path-component
// boundary, rejects empty/root-everything scopes, and is trailing-slash
// tolerant.

@Suite struct PathScopeTests {

    // MARK: - The core defect: sibling-prefix must NOT match

    // regression: codex C2 — "/Volumes/Drive" must not contain "/Volumes/Drive Backup/...".
    @Test func siblingPrefixIsNotContained() {
        #expect(PathScope.contains("/Volumes/Drive Backup/a.mov",
                                   within: "/Volumes/Drive") == false)
        #expect(PathScope.contains("/Volumes/Volume99/a.mov",
                                   within: "/Volumes/Vol") == false)
    }

    // MARK: - Real nesting (positive case)

    @Test func realNestingIsContained() {
        #expect(PathScope.contains("/Volumes/Drive/a.mov",
                                   within: "/Volumes/Drive") == true)
        #expect(PathScope.contains("/Volumes/Drive/sub/deep.mov",
                                   within: "/Volumes/Drive") == true)
    }

    // MARK: - Exact path equals root

    @Test func exactPathIsContained() {
        #expect(PathScope.contains("/Volumes/Drive", within: "/Volumes/Drive") == true)
    }

    // MARK: - Trailing-slash tolerance on either side

    @Test func trailingSlashesNormalized() {
        #expect(PathScope.contains("/Volumes/Drive/a.mov",
                                   within: "/Volumes/Drive/") == true)
        #expect(PathScope.contains("/Volumes/Drive/",
                                   within: "/Volumes/Drive") == true)
        #expect(PathScope.contains("/Volumes/Drive Backup/a.mov",
                                   within: "/Volumes/Drive/") == false)
    }

    // MARK: - Empty / root scopes are rejected (never match-everything)

    // regression: codex C2 — an empty root must never match every record.
    @Test func emptyRootRejected() {
        #expect(PathScope.contains("/Volumes/Drive/a.mov", within: "") == false)
        #expect(PathScope.contains("/anything/at/all", within: "") == false)
    }

    @Test func bareRootSlashRejected() {
        // "/" is the ultimate match-everything scope; reject it so a
        // destructive op can never sweep the entire catalog.
        #expect(PathScope.contains("/Volumes/Drive/a.mov", within: "/") == false)
        #expect(PathScope.contains("/", within: "/") == false)
    }

    // MARK: - normalize helper

    @Test func normalizeStripsTrailingSlashesButKeepsRoot() {
        #expect(PathScope.normalize("/Volumes/Drive/") == "/Volumes/Drive")
        #expect(PathScope.normalize("/Volumes/Drive///") == "/Volumes/Drive")
        #expect(PathScope.normalize("/Volumes/Drive") == "/Volumes/Drive")
        #expect(PathScope.normalize("/") == "/")
        #expect(PathScope.normalize("").isEmpty)
    }
}
