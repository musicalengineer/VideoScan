// RelocatePathGuard.swift
// GH #109 — Migrate must never run with the destination equal to, inside,
// or containing the source. On 2026-07-06 a dry run went LaCieWorkspace →
// LaCieWorkspace (18,878 records, an hour of hashing toward a meaningless
// plan); on 2026-08-17 a run with dest == source reported "done" having
// copied nothing. The sheet's 2026-08-17 check compared path STRINGS, so a
// symlinked alias, the data-volume firmlink spelling
// (/System/Volumes/Data/…) or a different letter case got through, and the
// model layer accepted anything.
//
// This guard decides by WHERE THE PATHS LIVE: each path is resolved
// physically (symlinks followed for the part that exists BEFORE any ".."
// is applied, as the kernel does; loops and dangling links refused), its
// volume identified by UUID (or the filesystem id when there is none), and
// the path compared as components below that volume's mount point —
// case- and Unicode-folded when the volume is case-insensitive. Two paths
// on different volumes are never nested. A path that cannot be resolved
// is refused (refuse over guess).
//
// Called by the model (`enqueueRelocate`), again by the runner before the
// reconcile starts (`runRelocate(jobID:)`), and by the sheet to gate the
// Migrate / Dry Run / Reconcile preview buttons. I/O: realpath + statfs +
// two resource-value reads per path — no directory walks.

import Foundation

/// Where a path really lives.
struct RelocatePathLocation: Equatable, Sendable {
    /// Volume UUID, else "fsid:<a>:<b>". Equal keys ⇒ the same filesystem.
    let volumeKey: String
    /// Path components below the volume's mount point.
    let components: [String]
    /// True unless the volume says it is case-sensitive (unknown ⇒ fold,
    /// which can only refuse more, never less).
    let caseInsensitive: Bool
    /// The resolved path, for log lines.
    let resolvedPath: String
}

enum RelocatePathGuard {

    enum Refusal: Equatable, Sendable {
        case identical
        case destinationInsideSource
        case sourceInsideDestination
        case unresolvable(String)

        var message: String {
            switch self {
            case .identical:
                return "The destination is the source folder itself — choose a different volume or folder."
            case .destinationInsideSource:
                return "The destination is inside the source — that would copy the folder into itself."
            case .sourceInsideDestination:
                return "The destination contains the source — files are already there; choose a different folder."
            case .unresolvable(let path):
                return "Could not tell which volume \(path) is on, so Migrate cannot prove it is not the source — check that the drive is connected."
            }
        }

        /// Stable refusal code for persistent logs.
        var code: String {
            switch self {
            case .identical: return "identical"
            case .destinationInsideSource: return "destination-inside-source"
            case .sourceInsideDestination: return "source-inside-destination"
            case .unresolvable: return "unresolvable"
            }
        }

        /// The reason WITHOUT any path — for catalog.log / videoscan.log
        /// (codex 2026-10-02 #7). `message`, which may name a folder, is
        /// for the UI only.
        var logReason: String {
            switch self {
            case .identical, .destinationInsideSource, .sourceInsideDestination:
                return message
            case .unresolvable:
                return "One of the two folders could not be located on a connected volume, so Migrate cannot prove it is not the source."
            }
        }
    }

    /// Test seam (task-local, never process-global): how a path is located.
    /// Production resolves it on the live filesystem.
    @TaskLocal static var locate: @Sendable (String) -> RelocatePathLocation? = { liveLocation($0) }

    /// nil = the pair is a valid migration as far as overlap goes.
    static func refusal(source: String, destination: String) -> Refusal? {
        // An empty path would resolve to the process's working directory.
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return .unresolvable("(no source)") }
        guard !destination.trimmingCharacters(in: .whitespaces).isEmpty else { return .unresolvable("(no destination)") }
        guard let s = locate(source) else { return .unresolvable(source) }
        guard let d = locate(destination) else { return .unresolvable(destination) }
        guard s.volumeKey == d.volumeKey else { return nil }
        let fold = s.caseInsensitive || d.caseInsensitive
        let sc = fold ? s.components.map(folded) : s.components
        let dc = fold ? d.components.map(folded) : d.components
        if sc == dc { return .identical }
        if dc.starts(with: sc) { return .destinationInsideSource }
        if sc.starts(with: dc) { return .sourceInsideDestination }
        return nil
    }

    private static func folded(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Live resolution

    /// Resolve `path` on the live filesystem with PHYSICAL-path semantics
    /// (codex 2026-10-02 #3): symlinks are followed component by component
    /// BEFORE any `..` is applied, exactly as the kernel does — so
    /// `other/alias/..` with alias → source/sub is `source`, not `other`.
    /// The path is never standardized first (that collapses `..`
    /// lexically and changes its meaning after a symlink).
    ///
    /// The destination usually does not exist yet, so the deepest EXISTING
    /// ancestor is realpath'ed and the missing tail re-appended. Refused
    /// (nil) — never guessed — when:
    ///   • realpath fails for any reason but ENOENT (ELOOP = a symlink
    ///     loop, ENOTDIR, EACCES …);
    ///   • a component that does not resolve nevertheless EXISTS (a
    ///     dangling symlink: its target is unknown territory, possibly
    ///     inside the source);
    ///   • the missing tail contains `..` (it would climb back into the
    ///     resolved part through names that do not exist).
    nonisolated static func liveLocation(_ path: String) -> RelocatePathLocation? {
        let absolute = path.hasPrefix("/")
            ? path
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        var existing = absolute
        var tail: [String] = []
        var resolvedExisting: String?
        while true {
            errno = 0
            if let raw = realpath(existing, nil) {
                resolvedExisting = String(cString: raw)
                free(raw)
                break
            }
            guard errno == ENOENT else { return nil }               // loop, not-a-dir, no access
            var st = stat()
            if lstat(existing, &st) == 0 { return nil }             // exists but unresolvable: dangling link
            guard existing != "/", !existing.isEmpty else { break }
            let last = (existing as NSString).lastPathComponent
            existing = (existing as NSString).deletingLastPathComponent
            if last == "." || last.isEmpty { continue }
            if last == ".." { return nil }                           // climbing through names that do not exist
            tail.insert(last, at: 0)
        }
        guard let base = resolvedExisting else { return nil }

        var fs = statfs()
        guard statfs(base, &fs) == 0 else { return nil }
        let mountPoint = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let values = try? URL(fileURLWithPath: base)
            .resourceValues(forKeys: [.volumeUUIDStringKey, .volumeSupportsCaseSensitiveNamesKey])
        let volumeKey = values?.volumeUUIDString
            ?? "fsid:\(fs.f_fsid.val.0):\(fs.f_fsid.val.1)"
        let caseInsensitive = !(values?.volumeSupportsCaseSensitiveNames ?? false)

        let baseComponents = URL(fileURLWithPath: base).pathComponents   // ["/", …]
        let mountComponents = URL(fileURLWithPath: mountPoint).pathComponents
        // Below the mount point. A firmlinked spelling ("/Users/x",
        // "/private/var/…") resolves to a path that is NOT under the data
        // volume's mount ("/System/Volumes/Data") — it is the same tree
        // seen from the root, so its components ARE the volume-relative
        // ones. Either spelling lands on the same list.
        let below: [String]
        if baseComponents.starts(with: mountComponents) {
            below = Array(baseComponents.dropFirst(mountComponents.count))
        } else {
            below = Array(baseComponents.dropFirst())   // drop "/"
        }
        let components = below + tail
        let resolvedPath = ([base] + tail).joined(separator: "/")
        return RelocatePathLocation(volumeKey: volumeKey, components: components,
                                    caseInsensitive: caseInsensitive,
                                    resolvedPath: resolvedPath)
    }
}

// MARK: - The model's gate (one refusal wording, one log path)

extension VideoScanModel {

    /// The job-layer check every Migrate passes — at enqueue AND again when
    /// the runner starts the job. Logs the refusal through the one sink
    /// (console + catalog.log via `log`, videoscan.log via `appLog`) and
    /// returns its message; nil = the pair does not overlap.
    ///
    /// The logged line carries the refusal CODE and a path-free reason only
    /// (codex 2026-10-02 #7: no media paths in persistent logs). The
    /// returned message — shown in the Migrate sheet / job row — keeps the
    /// detail.
    func refuseOverlappingMigrate(source: String, destination: URL, when: String) -> String? {
        guard let refusal = RelocatePathGuard.refusal(source: source, destination: destination.path) else {
            return nil
        }
        let line = "Migrate refused \(when) [\(refusal.code)]: \(refusal.logReason) Nothing was queued, read or copied (GH #109)."
        log(line)
        appLog.write(line)
        return refusal.message
    }
}
