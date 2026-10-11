// RetireGate.swift
// The disk half of "may this drive be retired?" — pure values plus one
// nonisolated evaluation that runs OFF the main actor (QA round 1 m2,
// 2026-10-11): the model projects the catalog into a `RetireGateInput` on
// the main actor (catalog facts only, O(records)), `evaluate` does the stats
// on a background task, and the sheet commits only if the catalog still
// projects to the same input (`VideoScanModel.commitRetire`).
//
// A record on the drive is DISPOSED for Retire only when
//   (b) one of its witnesses holds NOW — a live row off this drive, on
//       another physical drive (the device + inode rule), on disk at the
//       file's size; or
//   (a) it is labelled deleted and its file is PROVABLY gone:
//       * the drive is connected — asked from the kernel mount table, fresh,
//         before AND after the stats (QA m1: a drive that leaves during the
//         loop turns every later stat into ENOENT);
//       * it is the drive the catalog scanned — the mounted volume's
//         persistent UUID equals the one the catalog recorded for this drive
//         (ScanContext.volumeUUID, written at scan time). No recorded UUID,
//         or records that disagree: absence proves nothing (QA M3);
//       * stat says ENOENT AND the file's parent folder is still a folder on
//         the drive root's own device (QA M1): ENOENT under a renamed or
//         vanished folder — or a renamed scan-target subfolder — proves only
//         that the PATH is gone, not the bytes.
//     Known gap, by design not closed here: a file renamed INSIDE its own
//     folder still reads as gone (its folder is there, its name is not).
//     Closing it means reading the folder for a same-size file — a fixity
//     question, not a stat.
// Anything else that rests on a label is refused, by name.
//
// (For Rick: `Sendable` ≈ "safe to hand to another thread" — plain values
// and @Sendable closures only. `nonisolated static` ≈ a free function that
// does not need the UI thread.)

import Darwin
import Foundation
import VideoScanCore

// MARK: - The drive probe (seam)

/// How the gate asks about the DRIVE (not the files): its persistent UUID
/// and whether a path is a folder, and on which device. Injectable so tests
/// never depend on the host's disks.
struct RetireDriveProbe: Sendable {
    /// Persistent volume UUID of the volume holding `path` (uppercase), or nil.
    var volumeUUID: @Sendable (String) -> String?
    /// `st_dev` of `path` when it is a directory; nil when missing or not a folder.
    var directoryDevice: @Sendable (String) -> UInt64?

    static let live = RetireDriveProbe(
        volumeUUID: { VolumeIdentity.uuid(forPath: $0) },
        directoryDevice: { retireDirectoryDevice($0) })
}

extension ShowAgainDisk {
    /// The disk seam as the retire gate uses it: the same one-stat file
    /// probe, but "is the drive connected" read FRESH from the kernel mount
    /// table — never the 5 s reachability cache (QA m1).
    static let retireLive = ShowAgainDisk(
        volumeOnline: { RetireGate.mountedNow($0) },
        stat: { ShowAgainDisk.statPath($0) })
}

private func retireDirectoryDevice(_ path: String) -> UInt64? {
    var sb = stat()
    guard stat(path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return UInt64(bitPattern: Int64(sb.st_dev))
}

// MARK: - Values

/// The catalog's side of the question, projected on the main actor.
/// Equatable so a commit can prove the catalog did not change while the
/// disk was being checked.
struct RetireGateInput: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        let path: String
        let size: Int64
        let labelled: Bool
        /// Witnesses that are live rows off this drive (catalog facts);
        /// the disk check is the gate's.
        let witnesses: [String]
    }
    let volumeRootPath: String
    /// Records on the drive, and how many catalog facts account for.
    let total: Int
    let disposed: Int
    /// Labelled rows and rows resting on a witness — the ones the disk decides.
    let rows: [Row]
    /// The one UUID the catalog recorded for this drive; nil = none or conflicting.
    let recordedVolumeUUID: String?
}

/// The files that hold a drive back from Retire, by why (full paths).
struct RetireUnprovenFiles: Sendable, Equatable {
    /// Rest on a witness and none of them holds on disk on another drive now.
    var witnessGone: [String] = []
    /// Labelled deleted, the file is still on this drive (or stat can't say
    /// it is gone), no witness holds.
    var labelledStillHere: [String] = []
    /// Labelled deleted, no witness holds, and absence can't be proved: the
    /// drive isn't connected (before or after the stats), isn't the drive
    /// the catalog scanned, or the file's folder is gone.
    var labelledUnchecked: [String] = []

    var all: [String] { witnessGone + labelledStillHere + labelledUnchecked }
    var isEmpty: Bool { witnessGone.isEmpty && labelledStillHere.isEmpty && labelledUnchecked.isEmpty }

    /// How many names each clause lists before "and N more".
    static let namesShown = 10

    /// One clause per non-empty bucket, naming files relative to the drive.
    func refusalText(volumeRootPath: String) -> String {
        let clauses: [(paths: [String], words: String)] = [
            (witnessGone, "no longer have a copy on disk on another drive"),
            (labelledStillHere, "labelled deleted are still on this drive, with no copy on another drive"),
            (labelledUnchecked, "labelled deleted can't be checked (the drive isn't connected or isn't the one we catalogued, or the file's folder is gone) and have no copy on another drive"),
        ]
        return clauses.filter { !$0.paths.isEmpty }
            .map { "\($0.paths.count) file(s) \($0.words): \(Self.names($0.paths, under: volumeRootPath))" }
            .joined(separator: "; ")
    }

    private static func names(_ paths: [String], under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let shown = paths.prefix(namesShown).map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        let more = paths.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }
}

/// One click's answer: what was judged, why not (nil = may retire), and
/// which files hold it back — computed ONCE and used for the sheet, the
/// log and the commit.
struct RetireCheck: Sendable, Equatable {
    let input: RetireGateInput
    let refusal: String?
    let unproven: RetireUnprovenFiles
}

// MARK: - Evaluation (off the main actor)

enum RetireGate {

    /// Is the volume holding `path` in the kernel mount table right now?
    /// A fresh getmntinfo read (in-memory, no disk I/O), no cache.
    nonisolated static func mountedNow(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let mounted = VolumeReachability.currentMountedRoots()
        return mounted.contains(VolumeReachability.volumeRootKey(forPath: path, mountedRoots: mounted))
    }

    /// The drive's side of the absence proof, asked once per evaluation.
    private struct AbsenceGround {
        let rootDevice: UInt64?
        init(_ input: RetireGateInput, disk: ShowAgainDisk, drive: RetireDriveProbe) {
            rootDevice = RetireGate.driveIsTheCataloguedOne(input, disk: disk, drive: drive)
                ? drive.directoryDevice(input.volumeRootPath) : nil
        }
    }

    /// Connected (fresh) AND the mounted volume's UUID is the recorded one.
    nonisolated static func driveIsTheCataloguedOne(_ input: RetireGateInput, disk: ShowAgainDisk,
                                                    drive: RetireDriveProbe) -> Bool {
        guard let recorded = input.recordedVolumeUUID, disk.volumeOnline(input.volumeRootPath) else { return false }
        return drive.volumeUUID(input.volumeRootPath).flatMap(VolumeIdentity.normalized) == recorded
    }

    /// The whole check. Stats only — never touches the model.
    nonisolated static func evaluate(_ input: RetireGateInput, independence: WitnessIndependenceProbe,
                                     disk: ShowAgainDisk, drive: RetireDriveProbe) -> RetireCheck {
        if input.disposed < input.total {
            let why = "\(input.total - input.disposed) file(s) on this drive are not accounted for — no proven copy elsewhere"
            return RetireCheck(input: input, refusal: why, unproven: RetireUnprovenFiles())
        }
        var out = RetireUnprovenFiles()
        var ground: AbsenceGround?
        var restedOnAbsence: [String] = []
        let root = input.volumeRootPath
        for row in input.rows {
            let held = row.witnesses.contains { w in
                disk.stat(w) == .file(size: row.size) && independence(w, row.path, root)
            }
            if held { continue }
            guard row.labelled else { out.witnessGone.append(row.path); continue }
            let g = ground ?? AbsenceGround(input, disk: disk, drive: drive)
            ground = g
            switch absence(of: row.path, rootDevice: g.rootDevice, disk: disk, drive: drive) {
            case .proved: restedOnAbsence.append(row.path)
            case .present: out.labelledStillHere.append(row.path)
            case .unproved: out.labelledUnchecked.append(row.path)
            }
        }
        // QA m1: still the same connected drive AFTER the stats, or no
        // absence read in the loop counts.
        if !restedOnAbsence.isEmpty && !driveIsTheCataloguedOne(input, disk: disk, drive: drive) {
            out.labelledUnchecked += restedOnAbsence
        }
        return RetireCheck(input: input, refusal: out.isEmpty ? nil : out.refusalText(volumeRootPath: root),
                           unproven: out)
    }

    enum Absence: Equatable { case proved, present, unproved }

    /// One labelled file: gone (ENOENT under a folder that is still on the
    /// drive's own device), present (stat finds something, or can't read),
    /// or unproved (no ground, or ENOENT under a missing / foreign folder).
    nonisolated static func absence(of path: String, rootDevice: UInt64?, disk: ShowAgainDisk,
                                    drive: RetireDriveProbe) -> Absence {
        guard let rootDevice else { return .unproved }
        guard disk.stat(path) == .missing else { return .present }
        let parent = (path as NSString).deletingLastPathComponent
        return drive.directoryDevice(parent) == rootDevice ? .proved : .unproved
    }
}
