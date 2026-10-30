// VolumeIdentity+Record.swift
// Which volume a catalog record's file is on, from the record's own
// evidence (#401, 2026-10-30).
//
// A path alone does not say which disk a file is on: `/Users/rickb/Movies`
// exists on the M4's boot disk and on the Ultra's, and the scan locations
// carried over from the M4 credited the M4's files to the Ultra's folder.
// A scan location now owns a record only when the path is under it AND
// the volumes agree (`mayBeSameVolume`).
//
// Evidence, freshest first:
//   1. `auditSeenOn` — the last time a presence check saw the file; the
//      `fullPath` setter clears it when the row moves, so it is never stale.
//   2. `contentFixity.stamp` — the volume the bytes were hashed on.
//   3. `scanContext` — the volume of the original scan. Can be stale after
//      a cross-volume move (6 live rows on 2026-10-30), hence last.

import Foundation

extension VideoRecord {
    /// The persistent volume UUID this record's file is evidenced on
    /// (uppercase), or nil when the record carries no volume evidence.
    public var evidencedVolumeUUID: String? {
        auditSeenOn.flatMap { VolumeIdentity.normalized($0.volumeUUID) }
            ?? contentFixity?.stamp.volumeUUID.flatMap(VolumeIdentity.normalized)
            ?? VolumeIdentity.normalized(scanContext.volumeUUID)
    }
}

extension VolumeIdentity {
    /// False only when BOTH volumes are known and differ. Unknown on either
    /// side leaves the decision to the path, exactly as before #401.
    public static func mayBeSameVolume(_ a: String?, _ b: String?) -> Bool {
        guard let a = a.flatMap(normalized), let b = b.flatMap(normalized) else { return true }
        return a == b
    }
}
