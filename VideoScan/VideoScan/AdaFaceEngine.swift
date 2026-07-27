// AdaFaceEngine.swift
// CoreML-based AdaFace face recognition engine for VideoScan (GH #144).
//
// AdaFace (Kim et al., CVPR 2022) replaces dlib's seat in the Search
// algorithm registry. Its quality-adaptive margin loss keeps embeddings
// discriminative on low-quality faces — the VHS-era problem this archive
// actually has. Backbone: IR-50 trained on WebFace4M, converted to CoreML
// by tools/adaface/convert_adaface_coreml.py. Provenance, preprocessing,
// and score interpretation: docs/design/adaface-plugin.md.
//
// The converted model deliberately shares ArcFace's I/O contract
// ("faceImage" 112x112 image in, 512-d embedding out, preprocessing baked
// into the model), so the whole proven ArcFace video pipeline
// (pfProcessVideoWithArcFace and friends) is reused with three overrides:
// AdaFace's own cosine threshold, its own log tag, and useSharedPool:false
// (the ArcFace K>1 predictor pool holds ArcFace MLModel instances — the
// AdaFace path must never borrow one).
//
// Concurrency: same rules learned from the MLE5 crash history
// (project_arcface_concurrency_bug.md). AdaFaceModelLoader hands out a
// FRESH MLModel per getModel() call — one per worker, never shared — and
// every prediction is serialized under the global prediction lock.
//
// Memory (worst case per worker): model weights ~85 MB fp16 + one 112x112
// RGBA crop + one 512-float embedding per in-flight face. Budgeted at
// 768 MB/worker in MemoryPressureMonitor, same as ArcFace.

import Foundation
import CoreML
import os

/// Backend token for embedding storage/cache keying. AdaFace and ArcFace
/// vectors are both 512-d but are NOT comparable — every persisted or
/// job-cached embedding collection is keyed by a token like this so a
/// backend or checkpoint swap can never silently compare cross-backend
/// vectors. Bump the trailing version when the checkpoint changes.
enum FaceEmbeddingBackend {
    static let arcface = "arcface|w600k_r50"
    static let adaface = "adaface|ir50_webface4m_v1"

    /// Cache-namespace variant appended to the PersonFinderCache ref-hash
    /// for AdaFace rows (same mechanism as ArcFace's "lm-v1" alignment
    /// variant) — a future checkpoint bump busts stale per-video results.
    static let adafaceCacheVariant = "adaface-ir50wf4m-v1"
}

private let adafaceLogger = Logger(subsystem: "Rick-Breen.VideoScan", category: "AdaFace")

// MARK: - AdaFace CoreML Model Loader

/// Same shape as ArcFaceModelLoader: resolve/compile the model URL once,
/// then construct a FRESH MLModel on every getModel() call (per-worker
/// instances — Apple documents distinct MLModel instances as thread-safe;
/// sharing one across concurrent predictions is what crashed MLE5).
///
/// `actor` ≈ a class whose every member access is implicitly mutex-guarded
/// (callers `await` instead of blocking on the lock).
actor AdaFaceModelLoader {
    static let shared = AdaFaceModelLoader()

    static let modelBaseName = "adaface_ir50_webface4m"

    /// Cached URL of the compiled .mlmodelc — resolved on first successful
    /// load and reused across all subsequent getModel() calls.
    private var compiledURL: URL?

    /// Test seam: checked before the env var. Foundation snapshots the
    /// process environment, so tests can't reliably setenv() mid-run —
    /// they set this instead (and call `reset()` between cases).
    nonisolated(unsafe) static var modelsDirOverride: String?

    /// Models directory. Same convention as ArcFace (~/dev/VideoScan/models),
    /// overridable via VIDEOSCAN_MODELS_DIR for tests/worktrees so a test
    /// host never depends on (or pollutes) the real checkout's models dir.
    static var modelsDir: String {
        if let dir = modelsDirOverride, !dir.isEmpty { return dir }
        if let dir = ProcessInfo.processInfo.environment["VIDEOSCAN_MODELS_DIR"],
           !dir.isEmpty {
            return dir
        }
        return NSHomeDirectory() + "/dev/VideoScan/models"
    }

    /// Returns a freshly-constructed MLModel, or nil with an ACTIONABLE
    /// error message (names the exact expected path — GH #144 acceptance).
    func getModel() -> (MLModel?, String?) {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let url = compiledURL {
            // Fast path: URL already resolved — just rebuild the MLModel.
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                return (loaded, nil)
            }
            // Cached URL no longer valid (file moved/deleted) — re-resolve.
            compiledURL = nil
        }

        let base = Self.modelsDir + "/" + Self.modelBaseName
        let compiledPath = base + ".mlmodelc"
        let packagePath = base + ".mlpackage"
        let fm = FileManager.default

        // 1. Pre-compiled .mlmodelc (fastest)
        if fm.fileExists(atPath: compiledPath) {
            let url = URL(fileURLWithPath: compiledPath)
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                compiledURL = url
                return (loaded, nil)
            }
            // Corrupt/incompatible compile — fall through and rebuild from package.
        }

        // 2. Compile .mlpackage → .mlmodelc at runtime, cache beside it
        if fm.fileExists(atPath: packagePath) {
            do {
                let tempURL = try MLModel.compileModel(at: URL(fileURLWithPath: packagePath))
                let destURL = URL(fileURLWithPath: compiledPath)
                if fm.fileExists(atPath: compiledPath) {
                    try? fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: tempURL, to: destURL)
                let loaded = try MLModel(contentsOf: destURL, configuration: config)
                compiledURL = destURL
                return (loaded, nil)
            } catch {
                let msg = "Failed to compile AdaFace model at \(packagePath): \(error.localizedDescription)"
                adafaceLogger.error("\(msg, privacy: .public)")
                return (nil, msg)
            }
        }

        // 3. App-bundle fallback (same as ArcFace)
        if let bundlePath = Bundle.main.path(forResource: Self.modelBaseName, ofType: "mlmodelc") {
            do {
                let url = URL(fileURLWithPath: bundlePath)
                let loaded = try MLModel(contentsOf: url, configuration: config)
                compiledURL = url
                return (loaded, nil)
            } catch {
                return (nil, "Failed to load bundled AdaFace model: \(error.localizedDescription)")
            }
        }

        return (nil, "AdaFace model not found. Place \(Self.modelBaseName).mlpackage in \(Self.modelsDir)/ and restart. (Build it with tools/adaface/convert_adaface_coreml.py — see docs/design/adaface-plugin.md.)")
    }

    func reset() { compiledURL = nil }
}
