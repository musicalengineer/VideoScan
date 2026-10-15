// DriveAllocationProbe.swift
// What the disk says about each VOLUME for the Storage tab's "Media
// Allocation by Drive" table (Rick 2026-10-15: "one view to see the
// distribution of the media" — type, reliability, capacity, % free, and
// the physical unit two volumes may share: FamilyArchive and Projects are
// both on the Pegasus; LaCieWorkspace and MediaExpansion on the LaCie).
//
//   capacity / free   statfs on the mount (only when it is reachable; a
//                     drive that is off keeps the editor's TB figure)
//   physical unit     `diskutil info -plist <mount>` → the APFS physical
//                     store (or the device identifier) → its whole disk
//                     ("disk4") → `diskutil info -plist disk4` → MediaName
//                     ("Promise Pegasus3 R4 Media" → "Promise Pegasus3 R4")
//                     and SolidState for a volume whose type is unknown.
//
// Runs off the main actor, one pass per recompute, one diskutil pair per
// volume (cached per whole disk within the pass). Nothing here fails the
// page: a probe that cannot answer leaves the column "—". The parsing
// functions are pure and tested; only `facts(for:)` touches the system.

import Foundation
import VideoScanCore

/// One volume's row facts, keyed by the distribution's volume label.
struct DriveAllocationFacts: Sendable, Equatable {
    /// "RAID-5", "HDD", "SSD", "Network", "Cloud" — the editor's media
    /// tech, else what diskutil's SolidState says, else "Unknown".
    var typeLabel: String
    /// The physical unit's name, as diskutil reports it (minus " Media").
    var unitName: String?
    /// "disk4" — the same string for every volume on one unit.
    var wholeDisk: String?
    var capacityBytes: Int64?
    var freeBytes: Int64?

    var freePercent: Double? {
        guard let c = capacityBytes, c > 0, let f = freeBytes else { return nil }
        return Double(f) / Double(c) * 100
    }
}

enum DriveAllocationProbe {

    /// What `facts(for:)` needs about one live target, captured on the main actor.
    struct Request: Sendable, Equatable {
        let label: String
        let path: String
        let mediaTech: VolumeMediaTech
        let isReachable: Bool
        let capacityTB: Double?
    }

    /// The physical unit a mount sits on, as diskutil describes it.
    struct Unit: Sendable, Equatable {
        let wholeDisk: String
        let name: String?
        let solidState: Bool?
    }

    /// The disk's answers, by label. Off the main actor. Several targets can
    /// share a label ("Mac (home)"): the first reachable answer wins; a later
    /// unreachable one never blanks it.
    static func facts(for requests: [Request]) async -> [String: DriveAllocationFacts] {
        var out: [String: DriveAllocationFacts] = [:]
        var units: [String: Unit] = [:]
        for r in requests {
            let f = await facts(for: r, units: &units)
            if out[r.label] == nil || (out[r.label]?.freeBytes == nil && f.freeBytes != nil) { out[r.label] = f }
        }
        return out
    }

    /// One volume's facts: the editor's figures, then — when the volume is
    /// reachable — the filesystem's and the disk's.
    private static func facts(for r: Request, units: inout [String: Unit]) async -> DriveAllocationFacts {
        var f = DriveAllocationFacts(typeLabel: r.mediaTech == .unknown ? "Unknown" : r.mediaTech.rawValue,
                                     unitName: nil, wholeDisk: nil,
                                     capacityBytes: r.capacityTB.map { Int64($0 * 1_000_000_000_000) },
                                     freeBytes: nil)
        guard r.isReachable else { return f }
        if let space = filesystemSpace(atPath: r.path) {
            f.capacityBytes = space.capacity
            f.freeBytes = space.free
        }
        // diskutil answers for a MOUNT, not a folder: the home folder's
        // targets ask about the boot volume.
        guard let unit = await unit(forMount: r.path.hasPrefix("/Users/") ? "/" : r.path, cache: &units) else { return f }
        f.wholeDisk = unit.wholeDisk
        f.unitName = unit.name
        if r.mediaTech == .unknown, let ssd = unit.solidState {
            f.typeLabel = ssd ? VolumeMediaTech.ssd.rawValue : VolumeMediaTech.hdd.rawValue
        }
        return f
    }

    /// statfs: capacity and free bytes of the volume holding `path`.
    private static func filesystemSpace(atPath path: String) -> (capacity: Int64?, free: Int64?)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        let size = (attrs[.systemSize] as? NSNumber)?.int64Value
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        return (size.flatMap { $0 > 0 ? $0 : nil }, free)
    }

    /// The unit under a mount, one diskutil pair per whole disk per pass.
    private static func unit(forMount mount: String, cache: inout [String: Unit]) async -> Unit? {
        guard let volume = await diskutilInfo(mount), let disk = wholeDisk(fromVolumeInfo: volume) else { return nil }
        if let known = cache[disk] { return known }
        let info = await diskutilInfo(disk)
        let unit = Unit(wholeDisk: disk,
                        name: info.flatMap { unitName(fromMediaName: $0["MediaName"] as? String) },
                        solidState: info?["SolidState"] as? Bool)
        cache[disk] = unit
        return unit
    }

    // MARK: Pure parsing (tested)

    /// The whole disk a volume lives on: the first APFS physical store if
    /// there is one (an APFS volume's own identifier is a virtual disk),
    /// else the volume's device identifier — either way without its slice.
    nonisolated static func wholeDisk(fromVolumeInfo plist: [String: Any]) -> String? {
        if let stores = plist["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first?["APFSPhysicalStore"] as? String, !first.isEmpty {
            return DriveHealthProbe.stripSliceSuffix(from: first)
        }
        if let ident = plist["DeviceIdentifier"] as? String, !ident.isEmpty {
            return DriveHealthProbe.stripSliceSuffix(from: ident)
        }
        return nil
    }

    /// "Promise Pegasus3 R4 Media" → "Promise Pegasus3 R4"; "LaCie d2 Professional Media"
    /// → "LaCie d2 Professional"; nil / blank → nil.
    nonisolated static func unitName(fromMediaName raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.lowercased().hasSuffix(" media") { s = String(s.dropLast(6)).trimmingCharacters(in: .whitespaces) }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    // MARK: diskutil

    private static func diskutilInfo(_ target: String) async -> [String: Any]? {
        let result = await ProcessRunner.runProcess(executable: "/usr/sbin/diskutil",
                                                    arguments: ["info", "-plist", target],
                                                    deadlineSeconds: 10)
        guard let stdout = result.stdout, let data = stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }
}
