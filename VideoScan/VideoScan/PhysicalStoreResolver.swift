// PhysicalStoreResolver.swift
// Maps mount roots to their PHYSICAL whole-disk identifier ("disk10"),
// so schedulers can recognize two mounted volumes that share one
// spindle. Motivating find (codex #108, 2026-08-04): /Volumes/
// LaCieWorkspace (disk11s1) and /Volumes/MediaExpansion (disk11s2) are
// APFS siblings in container disk11 whose physical store is disk10s2 —
// ONE 8TB LaCie d2 HDD. Root-keyed policies (volume gates, the
// read-ahead warmer) were granting them independent heavy-reader
// slots, which thrashes the single head assembly.
//
// Resolution: statfs → BSD dev node ("disk11s1") → `diskutil info
// -plist` → APFSPhysicalStores (APFS) or ParentWholeDisk (HFS/other)
// → whole-disk prefix ("disk10"). One diskutil spawn per unique mount
// root, cached for the app's lifetime (device topology doesn't change
// under a mounted volume; a re-mount gets a fresh entry because
// resolution is keyed by root and re-requested per job).
//
// Consumers read the SYNC cache (lock-guarded) — resolution is kicked
// async before scanning starts (FindPersonJob.run). Unknown roots
// resolve to nil and callers fall back to root-equality, the old
// behavior — never worse, never blocking.

import Darwin
import Foundation
import os

private let storeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "physical-store")

enum PhysicalStoreResolver {

    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Cached physical whole-disk id ("disk10") for a mount root, or
    /// nil if not (yet) resolved. Sync and lock-cheap — safe from any
    /// scheduler hot path.
    static func spindleID(forRoot root: String) -> String? {
        cache.withLock { $0[root] }
    }

    /// True when the two roots are KNOWN to live on one physical disk
    /// (or are the same root). Unknown ⇒ false — callers keep their
    /// root-based behavior.
    static func sameSpindle(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ia = spindleID(forRoot: a), let ib = spindleID(forRoot: b) else {
            return false
        }
        return ia == ib
    }

    /// Resolve (and cache) the given mount roots. Cheap to call
    /// repeatedly — cached roots are skipped; each new root costs one
    /// statfs + one diskutil spawn (~100 ms).
    static func resolve(roots: Set<String>) async {
        for root in roots {
            if spindleID(forRoot: root) != nil { continue }
            guard let devNode = bsdDevNode(forMountPath: root) else { continue }
            guard let whole = await physicalWholeDisk(forDevNode: devNode) else { continue }
            cache.withLock { $0[root] = whole }
            storeLog.info("resolved \(root, privacy: .public) → \(whole, privacy: .public)")
        }
    }

    /// "/Volumes/MediaExpansion" → "disk11s2" (BSD node, no /dev/).
    private static func bsdDevNode(forMountPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst("/dev/".count))
    }

    /// "disk11s1" → "disk10" via diskutil: APFSPhysicalStores for APFS
    /// volumes (the container's backing partition), ParentWholeDisk for
    /// everything else.
    private static func physicalWholeDisk(forDevNode node: String) async -> String? {
        let result = await ProcessRunner.runProcess(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", node],
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: 15)
        guard result.exitCode == 0, let stdout = result.stdout,
              let data = stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else { return nil }

        if let stores = plist["APFSPhysicalStores"] as? [[String: Any]],
           let firstStore = stores.first?["APFSPhysicalStore"] as? String {
            return wholeDiskPrefix(of: firstStore)
        }
        if let parent = plist["ParentWholeDisk"] as? String {
            return wholeDiskPrefix(of: parent)
        }
        return nil
    }

    /// "disk10s2" → "disk10"; already-whole ids pass through.
    static func wholeDiskPrefix(of identifier: String) -> String {
        guard let sRange = identifier.range(of: "s", options: .backwards),
              sRange.lowerBound > identifier.index(identifier.startIndex, offsetBy: 4),
              identifier[identifier.index(after: sRange.lowerBound)...].allSatisfy(\.isNumber),
              identifier.hasPrefix("disk") else { return identifier }
        return String(identifier[..<sRange.lowerBound])
    }
}
