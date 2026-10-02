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
// (symlinks followed for the part that exists, "."/".." collapsed), its
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

    /// Resolve `path` on the live filesystem. The destination usually does
    /// not exist yet, so the deepest EXISTING ancestor is realpath'ed and
    /// the missing tail re-appended. nil only when even that fails.
    nonisolated static func liveLocation(_ path: String) -> RelocatePathLocation? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var existing = standardized
        var tail: [String] = []
        var resolvedExisting: String?
        while true {
            if let raw = realpath(existing, nil) {
                resolvedExisting = String(cString: raw)
                free(raw)
                break
            }
            guard existing != "/", !existing.isEmpty else { break }
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
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
    func refuseOverlappingMigrate(source: String, destination: URL, when: String) -> String? {
        guard let refusal = RelocatePathGuard.refusal(source: source, destination: destination.path) else {
            return nil
        }
        let line = "Migrate refused \(when): \(refusal.message) (source \(source) → destination \(destination.path)). Nothing was queued, read or copied (GH #109)."
        log(line)
        appLog.write(line)
        return refusal.message
    }
}
