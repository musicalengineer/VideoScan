// ArcFaceAlignmentTests.swift
// Pins the similarity-transform math behind 5-landmark ArcFace alignment.
// The Vision/warp geometry needs visual spot-checking, but the closed-form
// estimator is fully deterministic and unit-testable.

import Testing
import CoreGraphics
@testable import VideoScan

@Suite("ArcFace alignment — similarity transform estimator")
struct ArcFaceAlignmentTests {

    /// Applies a CGAffineTransform to a point.
    private func apply(_ t: CGAffineTransform, _ p: CGPoint) -> CGPoint {
        CGPoint(x: t.a * p.x + t.c * p.y + t.tx, y: t.b * p.x + t.d * p.y + t.ty)
    }

    private func expectClose(_ a: CGPoint, _ b: CGPoint, eps: CGFloat = 1e-4, _ msg: String = "") {
        #expect(abs(a.x - b.x) < eps && abs(a.y - b.y) < eps, "\(msg) got (\(a.x),\(a.y)) want (\(b.x),\(b.y))")
    }

    @Test("Identity correspondence yields identity transform")
    func identity() throws {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        let t = try #require(pfEstimateSimilarityTransform(from: pts, to: pts))
        for p in pts { expectClose(apply(t, p), p, "identity") }
    }

    @Test("Pure translation is recovered")
    func translation() throws {
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 3)]
        let dst = src.map { CGPoint(x: $0.x + 10, y: $0.y - 5) }
        let t = try #require(pfEstimateSimilarityTransform(from: src, to: dst))
        for (s, d) in zip(src, dst) { expectClose(apply(t, s), d, "translation") }
    }

    @Test("Uniform scale + translation is recovered")
    func scaleAndTranslate() throws {
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        let dst = src.map { CGPoint(x: $0.x * 3 + 4, y: $0.y * 3 + 4) }
        let t = try #require(pfEstimateSimilarityTransform(from: src, to: dst))
        for (s, d) in zip(src, dst) { expectClose(apply(t, s), d, eps: 1e-3, "scale+translate") }
    }

    @Test("90° rotation is recovered")
    func rotation90() throws {
        let src = [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1)]
        // 90° CCW: (x,y) -> (-y, x)
        let dst = src.map { CGPoint(x: -$0.y, y: $0.x) }
        let t = try #require(pfEstimateSimilarityTransform(from: src, to: dst))
        for (s, d) in zip(src, dst) { expectClose(apply(t, s), d, eps: 1e-3, "rot90") }
    }

    @Test("Scale + rotation + translation on the real 5-point template")
    func full5Point() throws {
        // Synthesize a known similarity (scale 2, 30°, shift), map the template
        // through it to make a src set, then confirm we recover the inverse.
        let angle: CGFloat = .pi / 6
        let scale: CGFloat = 2.0
        let known = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle),
                                      c: -scale * sin(angle), d: scale * cos(angle),
                                      tx: 15, ty: -7)
        let dst = arcfaceTemplate112
        let src = dst.map { apply(known, $0) }
        let t = try #require(pfEstimateSimilarityTransform(from: src, to: dst))
        for (s, d) in zip(src, dst) { expectClose(apply(t, s), d, eps: 1e-2, "full") }
    }

    @Test("Degenerate (coincident) source points return nil")
    func degenerate() {
        let same = Array(repeating: CGPoint(x: 5, y: 5), count: 5)
        #expect(pfEstimateSimilarityTransform(from: same, to: arcfaceTemplate112) == nil)
    }

    @Test("Mismatched counts return nil")
    func mismatched() {
        #expect(pfEstimateSimilarityTransform(from: [CGPoint(x: 0, y: 0)], to: arcfaceTemplate112) == nil)
    }
}
