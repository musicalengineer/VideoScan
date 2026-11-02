// VolumeIdentity+Record.swift
// Which volume a catalog record's file is on, from the record's own
// evidence (#401, 2026-10-30; strict rule 2026-11-02).
//
// A path alone does not say which disk a file is on: `/Users/rickb/Movies`
// exists on the M4's boot disk and on the Ultra's, and the scan locations
// carried over from the M4 credited the M4's files to the Ultra's folder.
// A scan location owns a record only when the path is under it AND the
// volumes agree (`agree`).
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
    /// Do a record's volume and a scan location's volume agree?
    ///
    ///   both known      → equal (normalized)
    ///   neither known   → true: nothing claims the file is elsewhere, and
    ///                     the path is the only evidence there is (a
    ///                     pre-provenance catalog; 1 row of 23,060 on
    ///                     2026-11-02)
    ///   exactly one     → false: a record that names its volume is never
    ///                     credited to a location that cannot name its
    ///                     own, and a location that knows its volume never
    ///                     shows a file that cannot say it is there
    ///
    /// The last case is the #401 P0 fixed on 2026-11-02: the first cut let
    /// the path decide whenever either side was unknown, so an unmounted
    /// location still showed another disk's files at the same path.
    public static func agree(_ a: String?, _ b: String?) -> Bool {
        switch (a.flatMap(normalized), b.flatMap(normalized)) {
        case let (a?, b?): return a == b
        case (nil, nil):   return true
        default:           return false
        }
    }
}
