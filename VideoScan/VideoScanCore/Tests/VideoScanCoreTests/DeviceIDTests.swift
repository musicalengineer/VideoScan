// DeviceIDTests.swift — st_dev → UInt64 never traps (2026-10-05: devfs on
// GitHub's macOS VM had a negative st_dev and `UInt64(st_dev)` crashed the
// test host inside a Delete Duplicates suite).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("DeviceID — st_dev conversion")
struct DeviceIDTests {
    @Test func positiveDeviceNumbersConvertExactlyAsBefore() {
        for dev: dev_t in [0, 1, 0x0100_0010, Int32.max] {
            #expect(DeviceID.from(dev) == UInt64(dev), "stored ids must not change")
        }
    }

    @Test func aNegativeDeviceNumberDoesNotTrapAndStaysDistinct() {
        let a = DeviceID.from(-1), b = DeviceID.from(Int32.min), c = DeviceID.from(Int32.max)
        #expect(a == UInt64.max)
        #expect(Set([a, b, c]).count == 3, "distinct devices stay distinct")
    }

    @Test func theLiveDevfsNumberConverts() {
        var st = stat()
        #expect(stat("/dev/null", &st) == 0)
        #expect(DeviceID.from(st.st_dev) == UInt64(bitPattern: Int64(st.st_dev)))
    }
}
