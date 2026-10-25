import Foundation
import Testing
@testable import VideoScan

/// `availableMemory()` stopped reading the Darwin global `vm_kernel_page_size`
/// (Swift 6 stage 4, #376) and asks `host_page_size` instead. Truth test: the
/// figure is still a real one — positive, and never more than the machine
/// has (free + inactive pages cannot exceed physical RAM).
@Suite("MemoryPressureMonitor page size")
struct MemoryPressurePageSizeTests {

    @Test func availableMemoryIsPositiveAndBoundedByPhysicalRAM() {
        let available = MemoryPressureMonitor.shared.availableMemory()
        #expect(available > 0)
        #expect(available <= ProcessInfo.processInfo.physicalMemory)
        // A page-size slip (e.g. 4 KiB read as 16 KiB) would put a 64 GB
        // machine's free RAM far outside this band.
        #expect(available >= 64 * 1024 * 1024, "less than 64 MB free is not a plausible reading")
    }

    @Test func twoReadingsAgreeToWithinNormalChurn() {
        let a = MemoryPressureMonitor.shared.availableMemory()
        let b = MemoryPressureMonitor.shared.availableMemory()
        let drift = a > b ? a - b : b - a
        #expect(drift < 4 * 1024 * 1024 * 1024, "back-to-back readings differ by \(drift / (1024 * 1024)) MB")
    }
}
