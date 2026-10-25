import Foundation
import Testing
@testable import VideoScan

/// `availableMemory()` stopped reading the Darwin global `vm_kernel_page_size`
/// (Swift 6 stage 4, #376) and asks `host_page_size` instead. Truth tests on
/// the seam: the page size is the one `vm_statistics64` counts in, and the
/// available figure is a whole number of those pages.
@Suite("MemoryPressureMonitor page size")
struct MemoryPressurePageSizeTests {

    @Test func kernelPageSizeIsTheOneVMStatisticsCountIn() {
        let page = MemoryPressureMonitor.kernelPageSize()
        #if arch(arm64)
        // Apple silicon: 16 KiB. 4096 would mean the x86/Rosetta user page
        // was read instead — a 4x undercount of free memory.
        #expect(page == 16_384)
        #endif
        #expect(page > 0)
    }

    @Test func availableMemoryIsAWholeNumberOfKernelPages() {
        let page = MemoryPressureMonitor.kernelPageSize()
        let available = MemoryPressureMonitor.shared.availableMemory()
        #expect(page > 0)
        #expect(available > 0)
        #expect(available % page == 0)
    }
}
