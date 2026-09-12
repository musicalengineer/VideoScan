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
        Root(root).contains(path)
    }

    /// Strip trailing slashes, preserving a lone "/" and the empty string.
    /// "/Volumes/Drive/" -> "/Volumes/Drive"; "/" -> "/"; "" -> "".
    nonisolated static func normalize(_ path: String) -> String {
        var s = path
        // `hasSuffix` first: it is O(1) on the last byte, while
        // `String.count` is O(n) — this runs per record per target in
        // the catalog-wide projections (codex #1393).
        while s.hasSuffix("/") && s.count > 1 {
            s.removeLast()
        }
        return s
    }

    /// A root prepared ONCE for many `contains` tests — the normalized
    /// root and its "root/" form, so a loop over 100k records does not
    /// re-normalize and re-concatenate the root per record. This IS the
    /// `contains(_:within:)` rule (that function delegates here), so a
    /// caller holding a `Root` gets byte-identical semantics.
    struct Root: Sendable, Equatable {
        /// `normalize(root)`.
        let normalized: String
        /// `normalized + "/"`; only meaningful when `isValid`.
        let withSlash: String
        /// False for "" and "/" — a scope that would match everything.
        let isValid: Bool

        init(_ root: String) {
            let r = PathScope.normalize(root)
            normalized = r
            isValid = !r.isEmpty && r != "/"
            withSlash = r + "/"
        }

        /// Same rule as `PathScope.contains(path, within: root)`.
        func contains(_ path: String) -> Bool {
            containsNormalized(PathScope.normalize(path))
        }

        /// `contains` for a path the caller has ALREADY passed through
        /// `PathScope.normalize` — lets a records × targets loop
        /// normalize each path once, not once per target. `normalize`
        /// is idempotent, so the result is identical to `contains`.
        func containsNormalized(_ p: String) -> Bool {
            guard isValid else { return false }
            if p == normalized { return true }
            return p.hasPrefix(withSlash)
        }
    }
}
