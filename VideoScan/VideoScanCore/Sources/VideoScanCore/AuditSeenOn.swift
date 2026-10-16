// AuditSeenOn.swift
// Where "Audit Catalog" LAST SAW a file (codex r3 2026-10-16 F1, decision
// D5): the persistent UUID of the volume the file's folder was on when an
// audit found the file at its path, read through the same directory
// handle that found it (`fstatfs` + `fgetattrlist ATTR_VOL_UUID`).
//
// The ONE proof rule of the audit rests on it: a file is provably gone
// only when the folder it is not in is on the volume the file was last
// seen on. A row that carries no stamp has never been seen by an audit and
// is never marked — "not at its path, and no audit has seen it before";
// a folder on another volume (an unmounted drive's stub mount point, a
// nested volume that left, a relocated home) is "could not check".
//
// Written only by the audit, for every row it finds present; carried by
// the catalog file, clone and rescan preservation; nil until then. Not
// safety-relevant on its own: a lost stamp costs one more run, never a
// mark. (For Rick: a POD the record carries; `volumeUUID` is the key the
// proof compares, the other two are for the words.)

import Foundation

public struct AuditSeenOn: Codable, Hashable, Sendable {
    /// The volume's persistent UUID (uppercase, `VolumeIdentity.normalized`).
    public let volumeUUID: String
    /// What was mounted there (`f_mntfromname`: a device or a share), for the words.
    public let mountFrom: String?
    public let seenAt: Date

    public init(volumeUUID: String, mountFrom: String?, seenAt: Date) {
        self.volumeUUID = volumeUUID
        self.mountFrom = mountFrom
        self.seenAt = seenAt
    }
}
