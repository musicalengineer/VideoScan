// PersonFinderDownsampleTests.swift
// Covers `pfDownsampledForDetection` — the resolution cap applied to the face-
// DETECTION pass so high-res (e.g. converted/upscaled 4K) frames stay cheap and
// memory-bounded. Feature-printing keeps the full-res frame, so this never
// affects identity-match accuracy; these tests pin the buffer geometry contract.

import Testing
import CoreVideo
@testable import VideoScan

@Suite("pfDownsampledForDetection")
struct PersonFinderDownsampleTests {

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary
        let r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb)
        precondition(r == kCVReturnSuccess, "test buffer alloc failed")
        return pb!
    }

    @Test func belowCapReturnsOriginalUntouched() {
        // The common case (all current catalog material): no allocation, no copy.
        let src = makeBuffer(1280, 720)
        let out = pfDownsampledForDetection(src, longEdgeCap: 1536)
        #expect(out === src)
        #expect(CVPixelBufferGetWidth(out) == 1280)
        #expect(CVPixelBufferGetHeight(out) == 720)
    }

    @Test func exactlyAtCapIsNoOp() {
        let src = makeBuffer(1536, 864)
        let out = pfDownsampledForDetection(src, longEdgeCap: 1536)
        #expect(out === src)
    }

    @Test func nilCapReturnsOriginal() {
        let src = makeBuffer(3840, 2160)
        let out = pfDownsampledForDetection(src, longEdgeCap: nil)
        #expect(out === src)
    }

    @Test func aboveCapDownsamplesLongEdgeToCapAspectPreserved() {
        let src = makeBuffer(3840, 2160) // 16:9 "4K"
        let out = pfDownsampledForDetection(src, longEdgeCap: 1536)
        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        #expect(out !== src)              // a new, smaller buffer
        #expect(max(w, h) == 1536)        // long edge capped exactly
        // 16:9 preserved within rounding
        #expect(abs(Double(w) / Double(h) - 3840.0 / 2160.0) < 0.02)
    }

    @Test func portraitCapsTheTallerEdge() {
        let src = makeBuffer(2160, 3840) // portrait
        let out = pfDownsampledForDetection(src, longEdgeCap: 1536)
        #expect(out !== src)
        #expect(CVPixelBufferGetHeight(out) == 1536) // height is the long edge
        #expect(CVPixelBufferGetWidth(out) < 1536)
    }

    @Test func zeroCapIsTreatedAsDisabled() {
        let src = makeBuffer(3840, 2160)
        let out = pfDownsampledForDetection(src, longEdgeCap: 0)
        #expect(out === src)
    }
}
