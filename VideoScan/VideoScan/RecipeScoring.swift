// RecipeScoring.swift
// The engine seam for Find & Tag (docs/find-and-tag-design.md).
//
// FindPersonJob talks to a per-person recipe scorer through this protocol
// so the python bridge (tools/donna-recipe/find_person_batch.py) and the
// Swift-native engine (NativeRecipeScorer) are interchangeable behind the
// SAME job. The scoring MATH lives here as pure nonisolated statics —
// two-tier size gates, top-K mean, centroid building — so codex can pin
// the recipe rules without CoreML, AVFoundation, or fixtures.
//
// Reference semantics being replicated: tools/donna-recipe/recipe_smoke.py
// (validated AUC 0.995 on DonnaTestVideos, docs/donna-recipe-smoke-2026-08-01.md).
//
// ── CALIBRATION NOTE (read before trusting any number) ─────────────────
// Cosine thresholds are properties of an EMBEDDING SPACE, not of the
// recipe. The python engine embeds with insightface ArcFace-w600k over
// ONNX; the native engine embeds with the app's AdaFace/ArcFace CoreML
// path (different alignment, different preprocessing). The smoke-derived
// python numbers (small-face bar 0.55, tag tiers 0.55/0.38) are NOT
// portable. Every threshold in RecipeParameters is injectable; native
// values are read off the calibration CLI:
//     VideoScan.app/Contents/MacOS/VideoScan --recipe-calibrate \
//         --gallery tests/fixtures/photos/Donna \
//         --corpus tests/fixtures/videos/DonnaTestVideos
// which prints per-clip score distributions, a small-face-bar sweep, and
// pairwise AUC for the native space.

import CoreGraphics
import Foundation

// MARK: - Results and progress

/// Per-clip verdict. Mirrors the python bridge's JSONL result line:
/// exactly one of `score` / `error` is meaningful. `score == 0.0` with no
/// error means "decoded fine, nothing gated in" (a real negative), while
/// `error` means the clip could not be judged at all (data, not a crash —
/// the job continues).
struct RecipeClipScore: Sendable, Equatable {
    var score: Double?
    var frameCount: Int = 0
    var gatedFaceCount: Int = 0
    var error: String?
    /// Calibration-only (params.collectFaceSamples): every record-tier
    /// face's (px, cosine) BEFORE the two-tier vote gate, so the CLI can
    /// re-score under candidate gates without re-decoding. Always nil in
    /// production — no embeddings and no per-face data leave a job
    /// (POI cycle-2 sensitive-data rule; cosines-to-centroid only, and
    /// only under the calibration flag).
    var faceSamples: [RecipeFaceSample]?
}

/// One record-tier face: its short bbox side in source pixels and its
/// best cosine against the era centroids.
struct RecipeFaceSample: Sendable, Equatable {
    var sidePx: Int
    var cosine: Double
}

/// Progress callbacks — the job maps these onto its stall-monitor ticks
/// and subtitle. Deliberately shaped like the python bridge's protocol
/// (prep chatter / ready / beat) so FindPersonJob treats both engines
/// identically.
enum RecipeProgressEvent: Sendable {
    case preparing(detail: String)
    case ready(eras: [String])
    case beat(clip: URL, frameIndex: Int)
}

typealias RecipeProgressHandler = @Sendable (RecipeProgressEvent) -> Void

struct RecipeError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Parameters

/// Every knob the recipe scorer uses. Structural constants default to the
/// python engine's production-tuned values (PhotoPrism-derived px tiers,
/// C1 top-K); the cosine bar defaults to the NATIVE-space value measured
/// by the calibration CLI — see the field note.
struct RecipeParameters: Sendable, Equatable {
    /// Faces below this short-side px are ignored entirely (detector
    /// noise floor). Pixel tiers ARE portable across engines — they gate
    /// on geometry, not on embedding space.
    var recordPx: Int = 25

    /// Faces at/above this short-side px may contribute ANY cosine.
    var votePx: Int = 60

    /// Two-tier rule: record-tier faces (recordPx..<votePx) only count
    /// when they match STRONGLY — they may confirm a known person, never
    /// smear weak evidence into the vote (the Donna-14 lesson).
    /// NATIVE-SPACE VALUE — measured by --recipe-calibrate on
    /// DonnaTestVideos (AdaFace backend); NOT the python engine's 0.55.
    /// Re-run the calibration if the backend or checkpoint changes.
    var smallFaceMinCos: Double = 0.55

    /// Frame sampling rate. ~2 fps matches the validated python run.
    var samplingFPS: Double = 2.0

    /// Per-clip aggregation: mean of the top-K gated-face cosines
    /// (C1 pattern — resistant to both single-frame flukes and dilution).
    var topK: Int = 5

    /// Vision detector confidence floor (same value the ArcFace/AdaFace
    /// reference loaders use).
    var minFaceConfidence: Float = 0.5

    /// Calibration only: collect per-face RecipeFaceSample lists. Leave
    /// false in production (see RecipeClipScore.faceSamples).
    var collectFaceSamples: Bool = false
}

// MARK: - Protocol

/// The seam FindPersonJob scores through. `prepare` must be called (and
/// succeed) before `score`. Implementations report per-clip failures as
/// data (`RecipeClipScore.error`), never by throwing — only setup
/// failures throw, matching the python bridge's exit-code contract.
protocol RecipeScoring: Sendable {
    /// Build era-banded gallery centroids from a reference folder whose
    /// SUBFOLDERS are decade bands of photos (e.g. Donna_70s/…).
    /// Returns the number of eras with a usable centroid.
    func prepare(galleryRoot: URL) async throws -> Int

    /// Score one clip. Cooperative: honors Task cancellation between
    /// frames and returns whatever it has (the job discards results that
    /// arrive after cancellation).
    func score(clip: URL) async -> RecipeClipScore
}

// MARK: - Pure recipe math (testable without CoreML)

enum RecipeMath {

    /// The two-tier MATCHING rule from recipe_smoke.py, whole and in one
    /// place: below recordPx never counts; at/above votePx always counts;
    /// in between only a strong match counts.
    nonisolated static func passesTierGate(sidePx: Int, cosine: Double,
                                           params: RecipeParameters) -> Bool {
        guard sidePx >= params.recordPx else { return false }
        if sidePx >= params.votePx { return true }
        return cosine >= params.smallFaceMinCos
    }

    /// Mean of the K largest values; 0.0 for an empty list (python:
    /// "no gated faces" scores 0.0, a legitimate negative).
    nonisolated static func topKMean(_ values: [Double], k: Int) -> Double {
        guard !values.isEmpty, k > 0 else { return 0.0 }
        let top = values.sorted(by: >).prefix(k)
        return top.reduce(0, +) / Double(top.count)
    }

    /// L2-normalized mean of L2-normalized embeddings; nil when empty or
    /// degenerate (zero-norm mean can't be normalized).
    nonisolated static func normalizedCentroid(of embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for emb in embeddings {
            guard emb.count == sum.count else { return nil }
            for i in 0..<sum.count { sum[i] += emb[i] }
        }
        let inv = 1.0 / Float(embeddings.count)
        for i in 0..<sum.count { sum[i] *= inv }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in 0..<sum.count { sum[i] /= norm }
        return sum
    }

    /// Max cosine of one embedding against all era centroids — the
    /// "era-banded" comparison: footage only has to match its OWN era's
    /// references well (weakest cross-era link is 70s↔2020s; see the G1
    /// report). -1 when there are no centroids.
    nonisolated static func maxCosine(_ embedding: [Float],
                                      centroids: [[Float]]) -> Double {
        var best: Float = -1
        for c in centroids {
            let cos = arcfaceCosine(embedding, c)
            if cos > best { best = cos }
        }
        return Double(best)
    }

    /// Re-score a clip from calibration samples under (possibly different)
    /// gate parameters — the CLI's threshold sweep uses this so one decode
    /// pass serves the whole grid.
    nonisolated static func clipScore(fromSamples samples: [RecipeFaceSample],
                                      params: RecipeParameters)
        -> (score: Double, gatedFaces: Int) {
        let gated = samples.filter {
            passesTierGate(sidePx: $0.sidePx, cosine: $0.cosine, params: params)
        }
        return (topKMean(gated.map(\.cosine), k: params.topK), gated.count)
    }

    /// Pairwise (Mann–Whitney) AUC: P(random positive > random negative),
    /// ties at half credit. nil when either side is empty. Same statistic
    /// recipe_smoke.py reports, so numbers compare directly.
    nonisolated static func pairwiseAUC(positives: [Double],
                                        negatives: [Double]) -> Double? {
        guard !positives.isEmpty, !negatives.isEmpty else { return nil }
        var wins = 0.0
        for p in positives {
            for n in negatives {
                if p > n { wins += 1 } else if p == n { wins += 0.5 }
            }
        }
        return wins / Double(positives.count * negatives.count)
    }
}

// MARK: - Gallery enumeration + centroid building

/// One era band's centroid (era = subfolder name, e.g. "Donna_80s").
struct RecipeEraCentroid: Sendable, Equatable {
    let era: String
    let centroid: [Float]
}

enum RecipeGallery {

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]

    /// Per-era L2-normalized centroids from the decade subfolders of
    /// `galleryRoot`. The EMBEDDER IS INJECTED: it must return the
    /// embedding of the single votable face in a photo, or nil to skip it
    /// (group shots, sub-voting-tier faces, unreadable files). Tests run
    /// this with a fake closure; production injects Vision + CoreML via
    /// NativeRecipeScorer.
    ///
    /// Matches build_era_centroids in recipe_smoke.py: subfolders sorted,
    /// files sorted, dotfiles skipped, eras with zero usable photos
    /// dropped. Group shots are deliberately skipped — centroids only
    /// need the unambiguous references.
    nonisolated static func buildEraCentroids(
        galleryRoot: URL,
        embedSingleVotableFace: (URL) -> [Float]?
    ) -> [RecipeEraCentroid] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: galleryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let eraDirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [RecipeEraCentroid] = []
        for era in eraDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: era, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            var embeddings: [[Float]] = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where imageExtensions.contains(file.pathExtension.lowercased()) {
                // One photo can hold a large decoded image + one crop +
                // one embedding — drain per photo so a 60-photo gallery
                // never accumulates decoded stills.
                autoreleasepool {
                    if let emb = embedSingleVotableFace(file) {
                        embeddings.append(emb)
                    }
                }
            }
            if let centroid = RecipeMath.normalizedCentroid(of: embeddings) {
                result.append(RecipeEraCentroid(era: era.lastPathComponent,
                                                centroid: centroid))
            }
        }
        return result
    }
}
