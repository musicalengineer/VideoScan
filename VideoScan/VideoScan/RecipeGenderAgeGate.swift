// RecipeGenderAgeGate.swift
// Sex/age attribute gate for the native Donna recipe (Rick 2026-08-05:
// "add gender detection for Donna — her case is obvious"). Restores the
// python reference recipe's sex gate (recipe_smoke.py kept female faces
// only) and extends it with the adult-age veto that attacks the
// dominant measured confusion class from the other side: the overnight
// precision sample's false positives were the BOYS' videos, and child
// faces read androgynously — but they also read as children, and Donna
// is never a child in this archive.
//
// Model: insightface buffalo_l `genderage` converted to CoreML ML
// Program FP16 (2026-08-05, scratch venv; parity vs onnxruntime max
// abs diff 0.0013; 6/6 real-face agreement with the python pipeline,
// female logit margins 2.4–5.0 on Donna gallery faces). Input: raw RGB
// 0–255, 1×3×96×96 (normalization is baked into the graph). Output:
// [femaleLogit, maleLogit, age/100].
//
// Preprocessing replicates insightface Attribute.get(): bbox-CENTERED
// square crop with side = max(w,h)×1.5, resized to 96 — NOT the
// 5-point landmark warp ArcFace uses. Caveat carried into calibration:
// Vision r3 boxes are tighter than the SCRFD boxes the model saw in
// its own pipeline, so veto thresholds are calibrated with Vision
// boxes (--recipe-calibrate --sex-gate), never copied from insightface
// defaults.
//
// GATE DISCIPLINE (channel #196): attributes are gates on which faces
// may VOTE — never identity evidence. Rick's loss function: never lose
// Donna — so the gate is PERMISSIVE: it vetoes only confident child
// reads and confident male reads; any failure to assess keeps the face.
//
// Concurrency: predictions go through the app-wide
// arcfacePredictionLock like every other CoreML call (MLE5 rule).

import CoreGraphics
import CoreImage
import CoreML
import Foundation
import Vision
import os

private let genderAgeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "genderage")

/// One face's attribute reading. `femaleMargin` = femaleLogit −
/// maleLogit (positive = female, magnitude = confidence).
struct GenderAgeReading: Sendable {
    let femaleMargin: Float
    let age: Int
}

/// Compiles and caches the converted genderage model. Same layout
/// conventions as ArcFaceModelLoader (models dir, .mlmodelc cache,
/// fresh MLModel per getModel — cheap once compiled).
actor GenderAgeModelLoader {
    static let shared = GenderAgeModelLoader()
    private var compiledURL: URL?

    func getModel() -> (MLModel?, String?) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        if let url = compiledURL {
            if let m = try? MLModel(contentsOf: url, configuration: config) {
                return (m, nil)
            }
            compiledURL = nil
        }
        let modelsDir = NSHomeDirectory() + "/dev/VideoScan/models"
        let compiledPath = modelsDir + "/genderage.mlmodelc"
        let packagePath = modelsDir + "/genderage.mlpackage"
        let fm = FileManager.default
        if fm.fileExists(atPath: compiledPath) {
            let url = URL(fileURLWithPath: compiledPath)
            if let m = try? MLModel(contentsOf: url, configuration: config) {
                compiledURL = url
                return (m, nil)
            }
        }
        if fm.fileExists(atPath: packagePath) {
            do {
                let tmp = try MLModel.compileModel(at: URL(fileURLWithPath: packagePath))
                let dest = URL(fileURLWithPath: compiledPath)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                let m = try MLModel(contentsOf: dest, configuration: config)
                compiledURL = dest
                return (m, nil)
            } catch {
                return (nil, "genderage compile failed: \(error.localizedDescription)")
            }
        }
        return (nil, "genderage model not found (models/genderage.mlpackage)")
    }
}

private let genderAgeCIContext = CIContext(options: [.cacheIntermediates: false])

/// Assess one detected face. nil on any failure — callers treat nil as
/// "keep the face" (permissive gate).
nonisolated func genderAgeAssess(face: VNFaceObservation,
                                 in image: CGImage,
                                 model: MLModel) -> GenderAgeReading? {
    let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
    let bbox = face.boundingBox
    let w = bbox.width * imgW, h = bbox.height * imgH
    let cx = (bbox.origin.x + bbox.width / 2) * imgW
    let cy = (bbox.origin.y + bbox.height / 2) * imgH
    let side = max(w, h) * 1.5
    guard side > 4 else { return nil }

    // Render the padded square's WINDOW at 96×96 (CIImage space =
    // bottom-left origin, same convention as pfNormalizeFaceCrop).
    // No cropped(to:) — that clips at the image edge and would SHIFT
    // edge faces; rendering the intended window keeps the face
    // centered and black-pads out-of-bounds, matching the reference
    // transform's border behavior.
    let scale = 96.0 / side
    let ci = CIImage(cgImage: image)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let window = CGRect(x: (cx - side / 2) * scale,
                        y: (cy - side / 2) * scale,
                        width: 96, height: 96)
    guard let crop = genderAgeCIContext.createCGImage(ci, from: window)
    else { return nil }

    // RGBA render → planar RGB float 0–255 (the graph normalizes).
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: 96, height: 96,
                              bitsPerComponent: 8, bytesPerRow: 96 * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 96, height: 96))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: 96 * 96 * 4)

    guard let arr = try? MLMultiArray(shape: [1, 3, 96, 96], dataType: .float32)
    else { return nil }
    let base = arr.dataPointer.bindMemory(to: Float32.self, capacity: 3 * 96 * 96)
    let plane = 96 * 96
    // CGContext rows are top-down; the reference blob is also built
    // from a top-down image (cv2), so row order matches directly.
    for y in 0..<96 {
        for x in 0..<96 {
            let p = (y * 96 + x) * 4
            let i = y * 96 + x
            base[i]             = Float32(px[p])       // R
            base[plane + i]     = Float32(px[p + 1])   // G
            base[2 * plane + i] = Float32(px[p + 2])   // B
        }
    }

    let out: MLFeatureProvider
    do {
        arcfacePredictionLock.lock()
        defer { arcfacePredictionLock.unlock() }
        out = try model.prediction(from: try MLDictionaryFeatureProvider(
            dictionary: ["data": MLFeatureValue(multiArray: arr)]))
    } catch {
        return nil
    }
    guard let name = out.featureNames.first,
          let v = out.featureValue(for: name)?.multiArrayValue,
          v.count >= 3 else { return nil }
    let female = v[0].floatValue, male = v[1].floatValue
    let age = Int((v[2].floatValue * 100).rounded())
    return GenderAgeReading(femaleMargin: female - male, age: age)
}
