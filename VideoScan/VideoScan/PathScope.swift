import Foundation

// MARK: - PathScope
//
// Component-boundary path containment for catalog scoping (codex C2).
//
// Replaces raw `fullPath.hasPrefix(root)` checks. Raw prefix matching
// treats "/Volumes/Drive" as containing "/Volumes/Drive Backup/a.mov",
// because "Drive Backup" starts with "Drive". For DISPLAY counts that is
// merely wrong; for DESTRUCTIVE / state-changing ops (record deletion,
// rescan wipe, duplicate deletion, phase repair) it means an operation
// scoped to one volume can reach into a SIBLING volume — unacceptable
// for Rick's irreplaceable family media.
//
// `contains` matches only when `path` IS `root`, or sits below it at a
// real path-component boundary ("root/..."). It also refuses empty and
// bare-"/" scopes outright, so a destructive op can never sweep the
// whole catalog through an accidental match-everything root.
//
// Pure `nonisolated static` funcs (C++: free functions in a namespace),
// so they are trivially unit-testable with no actor/model setup.

enum PathScope {

    /// True iff `path` is `root` itself, or lives underneath `root` at a
    /// component boundary.
    ///
    /// - Empty `root`, or a root that normalizes to "/" (the whole
    ///   filesystem), returns false — never match-everything.
    /// - Trailing slashes on either argument are normalized away first.
    /// - "/Volumes/Drive" does NOT contain "/Volumes/Drive Backup/a.mov".
    /// - Exact equality (path == root) returns true.
    ///
    /// Does not resolve symlinks: callers compare already-absolute catalog
    /// paths that share the same canonical form (the previous hasPrefix
    /// checks had the same assumption).
    nonisolated static func contains(_ path: String, within root: String) -> Bool {
        let r = normalize(root)
        // Reject "" and "/" — matching everything under the filesystem
        // root is exactly the catalog-wide data-loss footgun we remove.
        guard !r.isEmpty, r != "/" else { return false }
        let p = normalize(path)
        if p == r { return true }
        return p.hasPrefix(r + "/")
    }

    /// Strip trailing slashes, preserving a lone "/" and the empty string.
    /// "/Volumes/Drive/" -> "/Volumes/Drive"; "/" -> "/"; "" -> "".
    nonisolated static func normalize(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
