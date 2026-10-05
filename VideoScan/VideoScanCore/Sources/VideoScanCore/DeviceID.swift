// DeviceID.swift (VideoScanCore)
// ONE conversion from a stat `st_dev` (dev_t = Int32 on macOS) to the
// UInt64 the app stores and compares (2026-10-05). `UInt64(st_dev)` TRAPS
// ("Negative value is not representable") when the device number has its
// high bit set — devfs on GitHub's macOS VM did, crashing the test host in a
// Delete Duplicates suite; a network or unusual mount could do the same in
// the app. The bit pattern is kept (sign-extended, as PartialFileNaming
// always did), so every positive device number — all that could ever have
// been stored — converts exactly as before.

import Foundation

public enum DeviceID {
    /// `st_dev` as the app's UInt64 device id. Never traps.
    @inlinable
    public static func from(_ dev: dev_t) -> UInt64 {
        UInt64(bitPattern: Int64(dev))
    }
}
