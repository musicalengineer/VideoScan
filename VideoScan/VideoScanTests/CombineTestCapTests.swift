import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineTestCapTests
//
// Covers VideoScanModel.applyTestPairCap — the pure helper that honors the
// VS_COMBINE_LIMIT_N env var to bound a real ffmpeg run during the bulk
// UI test. Driven entirely by an injected env dict; never reads
// ProcessInfo, so the test is hermetic.

@MainActor
struct CombineTestCapTests {

    private let sample: [Int] = Array(1...100)

    @Test
    func noEnvVarReturnsInputUnchanged() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample, env: [:])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func nonIntegerEnvVarReturnsInputUnchanged() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "twenty"])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func zeroEnvVarReturnsInputUnchanged() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "0"])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func negativeEnvVarReturnsInputUnchanged() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "-5"])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func capLargerThanInputReturnsInputUnchanged() {
        // No point in "capping" to a larger value — original input is fine.
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "500"])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func capEqualToInputReturnsInputUnchanged() {
        // Cap == count is also a no-op (no useful slicing).
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "100"])
        #expect(out == sample)
        #expect(info == nil)
    }

    @Test
    func validCapTakesFirstN() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "20"])
        #expect(out == Array(1...20))
        #expect(info?.original == 100)
        #expect(info?.cap == 20)
    }

    @Test
    func capOfOneReturnsSingleElement() {
        let (out, info) = VideoScanModel.applyTestPairCap(sample,
                                                          env: ["VS_COMBINE_LIMIT_N": "1"])
        #expect(out == [1])
        #expect(info?.cap == 1)
    }

    @Test
    func emptyInputAlwaysReturnsEmpty() {
        let (out, info) = VideoScanModel.applyTestPairCap([Int](),
                                                          env: ["VS_COMBINE_LIMIT_N": "20"])
        #expect(out.isEmpty)
        #expect(info == nil)  // pairs.count (0) is not < cap (20) only because we guard 0
    }
}
