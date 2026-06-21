// ArcFaceAlignment.swift
// 5-landmark norm_crop alignment for ArcFace (P0 / Immich item #1).
//
// The w600k_r50 (InsightFace buffalo_l) recognition model was trained on faces
// warped to a canonical 112x112 by a similarity transform that maps 5 facial
// landmarks (eyes, nose, mouth corners) onto a fixed reference template
// (InsightFace's `arcface_src`). Feeding it a plain bounding-box crop — as
// pfNormalizeFaceCrop does — leaves every embedding slightly off the
// distribution the model learned, costing match quality on every frame.
//
// This file reproduces that alignment: detect the 5 landmarks with Vision,
// estimate the least-squares similarity transform onto the template, and warp.
// When landmarks are unavailable (blurry / profile / tiny faces) the caller
// falls back to pfNormalizeFaceCrop so recall is never reduced.
//
// Coordinate conventions (verified against pfNormalizeFaceCrop's "no Y-flip"
// note): Vision normalized points and CIImage both use a bottom-left origin
// with y up, so landmark pixels map straight into CIImage space. The reference
// template below is InsightFace's y-DOWN (top-left) layout; we flip it to
// bottom-left for the transform, then render through CIContext (whose output
// CGImage is top-left), which lands the face upright exactly as ArcFace expects.

import Foundation
import Vision
import CoreImage
import CoreGraphics

/// InsightFace `arcface_src` 5-point template for a 112x112 crop, in the
/// model's native TOP-LEFT (y-down) convention: left-eye, right-eye, nose tip,
/// left-mouth-corner, right-mouth-corner (image order, smaller x = "left").
let arcfaceTemplate112: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963),
    CGPoint(x: 73.5318, y: 51.5014),
    CGPoint(x: 56.0252, y: 71.7366),
    CGPoint(x: 41.5493, y: 92.3655),
    CGPoint(x: 70.7299, y: 92.2041),
]

/// Least-squares 2D similarity transform (uniform scale + rotation +
/// translation, no reflection/shear) mapping `src[i]` onto `dst[i]`.
/// Closed-form solution — same family as skimage's SimilarityTransform that
/// InsightFace uses. Returns nil if the source points are degenerate
/// (collinear/coincident) so the caller can fall back.
func pfEstimateSimilarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
    guard src.count == dst.count, src.count >= 2 else { return nil }
    let n = CGFloat(src.count)

    var meanSrc = CGPoint.zero, meanDst = CGPoint.zero
    for i in src.indices { meanSrc.x += src[i].x; meanSrc.y += src[i].y; meanDst.x += dst[i].x; meanDst.y += dst[i].y }
    meanSrc.x /= n; meanSrc.y /= n; meanDst.x /= n; meanDst.y /= n

    // c = scale*cosθ, s = scale*sinθ, from the centered correspondences.
    var sumCos: CGFloat = 0   // Σ (a·b)
    var sumSin: CGFloat = 0   // Σ (a×b)
    var denom: CGFloat = 0    // Σ |a|²
    for i in src.indices {
        let ax = src[i].x - meanSrc.x, ay = src[i].y - meanSrc.y
        let bx = dst[i].x - meanDst.x, by = dst[i].y - meanDst.y
        sumCos += ax * bx + ay * by
        sumSin += ax * by - ay * bx
        denom += ax * ax + ay * ay
    }
    guard denom > 1e-8 else { return nil }
    let c = sumCos / denom
    let s = sumSin / denom
    guard c.isFinite, s.isFinite, (c * c + s * s) > 1e-12 else { return nil }

    // M = [[c, -s], [s, c]]; t = meanDst - M·meanSrc.
    let tx = meanDst.x - (c * meanSrc.x - s * meanSrc.y)
    let ty = meanDst.y - (s * meanSrc.x + c * meanSrc.y)
    // CGAffineTransform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
    return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
}

/// Average of a Vision landmark region's points, in image-pixel (bottom-left)
/// coordinates. `bbox` is the face bounding box in normalized image coords.
private func pfRegionCentroidPixels(_ region: VNFaceLandmarkRegion2D?,
                                    bbox: CGRect, imageW: CGFloat, imageH: CGFloat) -> CGPoint? {
    guard let region, region.pointCount > 0 else { return nil }
    let pts = region.normalizedPoints
    var sx: CGFloat = 0, sy: CGFloat = 0
    for p in pts { sx += p.x; sy += p.y }
    let nx = sx / CGFloat(pts.count), ny = sy / CGFloat(pts.count)
    return CGPoint(x: (bbox.minX + nx * bbox.width) * imageW,
                   y: (bbox.minY + ny * bbox.height) * imageH)
}

/// The two horizontal extremes of a region (min-x, max-x) in image pixels —
/// used to pull mouth corners out of the outerLips contour.
private func pfRegionXExtremesPixels(_ region: VNFaceLandmarkRegion2D?,
                                     bbox: CGRect, imageW: CGFloat, imageH: CGFloat) -> (CGPoint, CGPoint)? {
    guard let region, region.pointCount >= 2 else { return nil }
    let pts = region.normalizedPoints
    var lo = pts[0], hi = pts[0]
    for p in pts { if p.x < lo.x { lo = p }; if p.x > hi.x { hi = p } }
    func toPixels(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (bbox.minX + p.x * bbox.width) * imageW,
                y: (bbox.minY + p.y * bbox.height) * imageH)
    }
    return (toPixels(lo), toPixels(hi))
}

/// Aligned 112x112 ArcFace crop for one detected face, or nil if the 5
/// landmarks can't be recovered (caller falls back to pfNormalizeFaceCrop).
///
/// Runs a Vision landmarks pass restricted to `observation` (so only candidate
/// faces pay the cost), extracts the 5 reference points, fits the similarity
/// transform onto the template, and warps `orientedImage`.
nonisolated func arcfaceAlignedCrop(from orientedImage: CGImage, observation: VNFaceObservation) -> CGImage? {
    let imageW = CGFloat(orientedImage.width)
    let imageH = CGFloat(orientedImage.height)

    // Landmarks restricted to the already-detected face box.
    let req = VNDetectFaceLandmarksRequest()
    req.inputFaceObservations = [observation]
    let handler = VNImageRequestHandler(cgImage: orientedImage, options: [:])
    try? handler.perform([req])
    guard let result = req.results?.first, let lm = result.landmarks else { return nil }
    let bbox = result.boundingBox

    // Eyes: prefer pupils (single point) and fall back to eye-region centroids.
    let leftEye = pfRegionCentroidPixels(lm.leftPupil, bbox: bbox, imageW: imageW, imageH: imageH)
        ?? pfRegionCentroidPixels(lm.leftEye, bbox: bbox, imageW: imageW, imageH: imageH)
    let rightEye = pfRegionCentroidPixels(lm.rightPupil, bbox: bbox, imageW: imageW, imageH: imageH)
        ?? pfRegionCentroidPixels(lm.rightEye, bbox: bbox, imageW: imageW, imageH: imageH)
    let nose = pfRegionCentroidPixels(lm.nose, bbox: bbox, imageW: imageW, imageH: imageH)
    let mouth = pfRegionXExtremesPixels(lm.outerLips, bbox: bbox, imageW: imageW, imageH: imageH)

    guard let leftEye, let rightEye, let nose, let mouth else { return nil }

    // Assign by image-x so we never depend on Vision's anatomical left/right
    // labelling (which is mirrored vs. image order): template[0]/[3] are the
    // smaller-x eye/mouth-corner, [1]/[4] the larger-x.
    let (eyeLo, eyeHi) = leftEye.x <= rightEye.x ? (leftEye, rightEye) : (rightEye, leftEye)
    let (mouthLo, mouthHi) = mouth.0.x <= mouth.1.x ? (mouth.0, mouth.1) : (mouth.1, mouth.0)
    let srcPoints = [eyeLo, eyeHi, nose, mouthLo, mouthHi]

    // Template flipped to CIImage's bottom-left origin.
    let dstPoints = arcfaceTemplate112.map { CGPoint(x: $0.x, y: 112.0 - $0.y) }

    guard let transform = pfEstimateSimilarityTransform(from: srcPoints, to: dstPoints) else { return nil }

    let ci = CIImage(cgImage: orientedImage).transformed(by: transform)
    return pfCIContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: 112, height: 112))
}
