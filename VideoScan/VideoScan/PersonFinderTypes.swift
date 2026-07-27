// PersonFinderTypes.swift
// Pure value types used by PersonFinderModel and its UI.
//
// Extracted from PersonFinderModel.swift as step 1 of 6 in a planned
// decomposition. Pure code movement — no logic changes, no visibility
// changes, no conformance changes. See git log on
// refactor/personfinder-split for context.

import Foundation
import Vision
import CoreGraphics
import SwiftUI
import os

/// Same subsystem/category as PersonFinderModel+Identity.swift's logger
/// (file-private there), so identity-metadata events land in one place
/// in videoscan.log.
private let identityLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "identity"
)

// MARK: - Perf accumulator

struct FramePerfAccumulator {
    var decodeMs: Double = 0
    var faceDetectMs: Double = 0
    var orientMs: Double = 0
    var matchMs: Double = 0
    var frameCount: Int = 0
    var skippedFrames: Int = 0
    var videoOpenMs: Double = 0

    mutating func addFrame(decode: Double, detect: Double, orient: Double, match: Double) {
        decodeMs += decode * 1000
        faceDetectMs += detect * 1000
        orientMs += orient * 1000
        matchMs += match * 1000
        frameCount += 1
    }

    var totalMs: Double { decodeMs + faceDetectMs + orientMs + matchMs }

    func summary(filename: String, wallMs: Double) -> String {
        let idle = wallMs - totalMs
        return String(format: """
            PERF %@ — %d frames in %.1fs wall \
            | decode %.0fms (%.0f%%) \
            | faceDetect %.0fms (%.0f%%) \
            | orient %.0fms (%.0f%%) \
            | match %.0fms (%.0f%%) \
            | idle/await %.0fms (%.0f%%) \
            | skipped %d | open %.0fms
            """,
            filename, frameCount, wallMs / 1000,
            decodeMs, wallMs > 0 ? decodeMs / wallMs * 100 : 0,
            faceDetectMs, wallMs > 0 ? faceDetectMs / wallMs * 100 : 0,
            orientMs, wallMs > 0 ? orientMs / wallMs * 100 : 0,
            matchMs, wallMs > 0 ? matchMs / wallMs * 100 : 0,
            idle, wallMs > 0 ? idle / wallMs * 100 : 0,
            skippedFrames, videoOpenMs)
    }
}

// MARK: - Settings

// MARK: - Recognition Engine Registry
//
// To add a new engine:
//   1. Add a case below.
//   2. Add a matching case in the `switch settings.recognitionEngine` block
//      inside `processOne(idx:)` further down in this file.
//   3. (Optional) Add per-engine memory/concurrency tuning to MemoryPressureMonitor.
//
// Each engine implements the same async contract:
//   (filePath, settings, callbacks) -> pfVideoResult?
// so the dispatcher and the rest of the pipeline (clipping, compilation,
// dashboards) stay engine-agnostic.

enum RecognitionEngine: String, CaseIterable, Identifiable {
    case vision  = "Vision (fast)"
    case arcface = "ArcFace (CoreML)"
    case adaface = "AdaFace (CoreML)"
    case hybrid  = "Hybrid (Vision + AdaFace fallback)"
    var id: String { rawValue }

    /// Deterministic migration for PERSISTED engine tokens (GH #144).
    /// dlib's registry seat was replaced by AdaFace on 2026-07-27, and
    /// hybrid's rawValue changed because the fallback engine is named in
    /// the token. Every decode-from-storage site must go through here
    /// instead of `RecognitionEngine(rawValue:)` so old plists/JSON land
    /// on a supported engine instead of silently vanishing.
    /// Returns nil for unknown/poisoned tokens — callers keep their
    /// existing fallback (`.vision`), exactly as before.
    static func migratePersisted(_ raw: String?) -> RecognitionEngine? {
        guard let raw else { return nil }
        if let current = RecognitionEngine(rawValue: raw) { return current }
        switch raw {
        // dlib was the "accurate second opinion" seat; AdaFace inherits it.
        case "dlib/Python (accurate)":          return .adaface
        // Same engine, renamed persistence token (fallback is now AdaFace).
        case "Hybrid (Vision + dlib fallback)": return .hybrid
        default:                                return nil
        }
    }

    var title: String {
        switch self {
        case .vision:  return "VISION"
        case .arcface: return "ARCFACE"
        case .adaface: return "ADAFACE"
        case .hybrid:  return "HYBRID"
        }
    }

    /// Prose-friendly mixed-case name without the parenthetical descriptor —
    /// "Vision" / "ArcFace" / "AdaFace" / "Hybrid". Used inline in summary
    /// sentences ("using algorithm: ArcFace") where the parenthetical from
    /// rawValue would create double-paren awkwardness or just noise.
    var displayName: String {
        switch self {
        case .vision:  return "Vision"
        case .arcface: return "ArcFace"
        case .adaface: return "AdaFace"
        case .hybrid:  return "Hybrid"
        }
    }

    /// Short label for compact UI / chip overlays.
    var shortLabel: String {
        switch self {
        case .vision:  return "VISION"
        case .arcface: return "ARCFACE"
        case .adaface: return "ADAFACE"
        case .hybrid:  return "HYBRID"
        }
    }

    var subtitle: String {
        switch self {
        case .vision:
            return "Built-in macOS detector for quick whole-library scans."
        case .arcface:
            return "ArcFace face identity model via CoreML — accurate, runs on ANE, fully local."
        case .adaface:
            return "AdaFace identity model via CoreML — quality-adaptive margin, strong on low-quality VHS-era faces, fully local."
        case .hybrid:
            return "VISION first; ADAFACE second look on videos VISION misses."
        }
    }

    var capabilitySummary: String {
        switch self {
        case .vision:  return "Fastest — Apple Neural Engine"
        case .arcface: return "Accurate — ArcFace on ANE (local CoreML)"
        case .adaface: return "Accurate on degraded footage — AdaFace on ANE (local CoreML)"
        case .hybrid:  return "Balanced — multi-engine fallback"
        }
    }

    var requirementsSummary: String {
        switch self {
        case .vision:  return "No extra dependencies"
        case .arcface: return "Requires w600k_r50.mlpackage in models/ directory"
        case .adaface: return "Requires adaface_ir50_webface4m.mlpackage in models/ directory"
        case .hybrid:  return "Uses AdaFace when its model is installed, otherwise VISION-only"
        }
    }

    var symbolName: String {
        switch self {
        case .vision:  return "video"
        case .arcface: return "brain"
        case .adaface: return "brain.head.profile"
        case .hybrid:  return "square.stack.3d.forward.dottedline"
        }
    }
}

struct PersonFinderSettings: Equatable {
    var personName: String = "Donna"
    var referencePath: String = ""
    var outputDir: String = ""          // empty → Desktop/<name>_clips
    var threshold: Float = 0.52
    var minFaceConfidence: Float = 0.55
    var frameStep: Int = 5
    var pad: Double = 2.0
    var minDuration: Double = 1.0
    var minPresenceSecs: Double = 5.0
    var requirePrimary: Bool = false
    var concurrency: Int = 8
    var skipBundles: Bool = false       // when true, skip .fcpbundle, .imovielibrary, etc.
    var skipCatalogBadFiles: Bool = true // skip audio-only, no-streams, ffprobe-failed from catalog
    var largestFaceOnly: Bool = false   // use only the largest detected face per reference photo
    var previewRate: Int = 5            // show preview every N sampled frames (1 = every frame)

    /// "Match Confidence Floor" — how many matched face observations a whole
    /// video needs (pfVideoResult.totalHits) before the person counts as
    /// FOUND in it. 1 = a single match is enough (the pre-2026-07 any-hit
    /// behavior, kept as the opt-out). Default 7 = the graded POI cycle-03
    /// operating point (balanced accuracy 0.615 vs 0.500 legacy, zero Donna
    /// misses in both grading rounds) — it exists to stop one drive-by
    /// look-alike frame from flagging a whole video. The decision logic is
    /// shared with the eval CLI via EvalPresenceRule; see
    /// PersonFinderModel.matchFloorDecision for the short-clip safeguard.
    var matchConfidenceFloor: Int = 7

    // Reference photo management
    var rejectedReferenceFiles: [String] = []  // filenames removed by user, excluded on reload

    // ArcFace engine
    var arcfaceThreshold: Float = 0.40    // cosine similarity threshold (higher = stricter)

    /// EXPERIMENTAL: when true, warp each face to ArcFace's canonical 112x112
    /// via a 5-landmark similarity transform (norm_crop) before embedding,
    /// instead of the plain bounding-box crop. This is how the w600k_r50 model
    /// was trained, so it should improve match quality; falls back to the
    /// bbox crop when Vision can't recover landmarks. Off by default pending
    /// visual validation. See ArcFaceAlignment.
    var arcfaceLandmarkAlignment: Bool = false

    /// EXPERIMENTAL: number of concurrent ArcFace inference slots. 1 (default)
    /// = the long-standing serialized behavior (single global lock) that guards
    /// the MLE5 crash. >1 enables a pool of K individually-locked model
    /// instances for parallel inference (P0-1). Validate with the arcface
    /// stress scripts before raising in production. See ArcFacePredictor.
    var arcfaceInferenceConcurrency: Int = 1

    // AdaFace engine (GH #144 — replaced dlib's seat)
    /// Cosine similarity threshold for AdaFace matches (higher = stricter).
    /// AdaFace same-identity cosines run lower than ArcFace's on hard pairs;
    /// 0.30 is the literature-derived starting point (IR-50-class operating
    /// points sit around 0.25–0.40). Tune on the Donna eval before any
    /// default-engine promotion. See docs/design/adaface-plugin.md §4.
    var adafaceThreshold: Float = 0.30

    var recognitionEngine: RecognitionEngine = .vision

    /// Threshold consumed by a given engine — the CoreML engines each use
    /// their own cosine threshold; Vision (and Hybrid's primary pass) uses
    /// the feature-print distance `threshold`. Cache keys and scan logs use
    /// this so rows are keyed by the knob that actually shaped them (#144).
    func thresholdForEngine(_ engine: RecognitionEngine) -> Float {
        switch engine {
        case .arcface:         return arcfaceThreshold
        case .adaface:         return adafaceThreshold
        case .vision, .hybrid: return threshold
        }
    }

    // MARK: - Persistence

    private static let defaults = UserDefaults.standard
    private static let prefix = "pf_"

    /// Restore settings from UserDefaults. Missing keys use struct defaults.
    /// The suite is injectable (defaulting to .standard) so persistence tests
    /// can run against a throwaway `UserDefaults(suiteName:)` and never touch
    /// the real prefs plist — same pattern as AnalysisScope.restored(from:).
    static func restored(from defaults: UserDefaults = Self.defaults) -> PersonFinderSettings {
        // Test hosts asked for the REAL suite get pristine defaults instead
        // — a UI-test app process must neither inherit Rick's saved search
        // settings nor depend on them (settings-pollution class; same
        // `defaults === .standard` guard as CaptionOrchestrator). Tests
        // that inject their own throwaway suite are unaffected.
        if TestEnvironment.isTestHost && defaults === UserDefaults.standard {
            return PersonFinderSettings()
        }
        var s = PersonFinderSettings()
        restoreStrings(&s, from: defaults)
        restoreNumericValues(&s, from: defaults)
        restoreBoolValues(&s, from: defaults)
        return s
    }

    private static func restoreStrings(_ s: inout PersonFinderSettings, from defaults: UserDefaults) {
        let d = defaults; let p = prefix
        if let v = d.string(forKey: "\(p)personName") { s.personName = v }
        if let v = d.string(forKey: "\(p)referencePath") { s.referencePath = v }
        if let v = d.string(forKey: "\(p)outputDir") { s.outputDir = v }
        if let v = d.string(forKey: "\(p)recognitionEngine") {
            // migratePersisted maps legacy dlib/hybrid tokens onto their
            // replacement seats; garbage still degrades to .vision (#144).
            s.recognitionEngine = RecognitionEngine.migratePersisted(v) ?? .vision
        }
        if let rejected = d.stringArray(forKey: "\(p)rejectedReferenceFiles") { s.rejectedReferenceFiles = rejected }
    }

    private static func restoreNumericValues(_ s: inout PersonFinderSettings, from defaults: UserDefaults) {
        let d = defaults; let p = prefix
        if d.object(forKey: "\(p)threshold") != nil { s.threshold = d.float(forKey: "\(p)threshold") }
        if d.object(forKey: "\(p)minFaceConfidence") != nil { s.minFaceConfidence = d.float(forKey: "\(p)minFaceConfidence") }
        if d.object(forKey: "\(p)frameStep") != nil { s.frameStep = d.integer(forKey: "\(p)frameStep") }
        if d.object(forKey: "\(p)pad") != nil { s.pad = d.double(forKey: "\(p)pad") }
        if d.object(forKey: "\(p)minDuration") != nil { s.minDuration = d.double(forKey: "\(p)minDuration") }
        if d.object(forKey: "\(p)minPresenceSecs") != nil { s.minPresenceSecs = d.double(forKey: "\(p)minPresenceSecs") }
        if d.object(forKey: "\(p)concurrency") != nil { s.concurrency = d.integer(forKey: "\(p)concurrency") }
        if d.object(forKey: "\(p)previewRate") != nil { s.previewRate = max(1, d.integer(forKey: "\(p)previewRate")) }
        if d.object(forKey: "\(p)arcfaceThreshold") != nil { s.arcfaceThreshold = d.float(forKey: "\(p)arcfaceThreshold") }
        if d.object(forKey: "\(p)adafaceThreshold") != nil { s.adafaceThreshold = d.float(forKey: "\(p)adafaceThreshold") }
        if d.object(forKey: "\(p)arcfaceInferenceConcurrency") != nil { s.arcfaceInferenceConcurrency = max(1, d.integer(forKey: "\(p)arcfaceInferenceConcurrency")) }
        // Clamp poisoned values (0, negatives, non-numeric → 0) back to the
        // legal minimum: 1 = any-hit. A bad plist must never disable matching.
        if d.object(forKey: "\(p)matchConfidenceFloor") != nil { s.matchConfidenceFloor = max(1, d.integer(forKey: "\(p)matchConfidenceFloor")) }
    }

    private static func restoreBoolValues(_ s: inout PersonFinderSettings, from defaults: UserDefaults) {
        let d = defaults; let p = prefix
        if d.object(forKey: "\(p)requirePrimary") != nil { s.requirePrimary = d.bool(forKey: "\(p)requirePrimary") }
        if d.object(forKey: "\(p)skipBundles") != nil { s.skipBundles = d.bool(forKey: "\(p)skipBundles") }
        if d.object(forKey: "\(p)skipCatalogBadFiles") != nil { s.skipCatalogBadFiles = d.bool(forKey: "\(p)skipCatalogBadFiles") }
        if d.object(forKey: "\(p)largestFaceOnly") != nil { s.largestFaceOnly = d.bool(forKey: "\(p)largestFaceOnly") }
        if d.object(forKey: "\(p)arcfaceLandmarkAlignment") != nil { s.arcfaceLandmarkAlignment = d.bool(forKey: "\(p)arcfaceLandmarkAlignment") }
    }

    /// Extract a POI profile from the current settings.
    func toProfile(coverImageFilename: String? = nil, notes: String = "", aliases: [String] = []) -> POIProfile {
        POIProfile(
            name: personName,
            referencePath: referencePath,
            rejectedFiles: rejectedReferenceFiles,
            engine: recognitionEngine.rawValue,
            visionThreshold: threshold,
            arcfaceThreshold: arcfaceThreshold,
            adafaceThreshold: adafaceThreshold,
            minFaceConfidence: minFaceConfidence,
            largestFaceOnly: largestFaceOnly,
            coverImageFilename: coverImageFilename,
            notes: notes,
            aliases: aliases
        )
    }

    /// Apply a POI profile to these settings.
    mutating func applyProfile(_ profile: POIProfile) {
        personName = profile.name
        referencePath = profile.referencePath
        rejectedReferenceFiles = profile.rejectedFiles
        // migratePersisted: profile.json written before #144 may carry the
        // dlib or old-hybrid token — land on the replacement seat, never
        // silently keep the previous engine for a known-legacy token.
        if let eng = RecognitionEngine.migratePersisted(profile.engine) {
            recognitionEngine = eng
        }
        threshold = profile.visionThreshold
        arcfaceThreshold = profile.arcfaceThreshold
        adafaceThreshold = profile.adafaceThreshold
        minFaceConfidence = profile.minFaceConfidence
        largestFaceOnly = profile.largestFaceOnly
    }

    /// Save all settings to UserDefaults. Injectable suite for the same
    /// test-isolation reason as `restored(from:)`.
    func save(to defaults: UserDefaults = Self.defaults) {
        // Mirror of the restored(from:) gate: never WRITE the real prefs
        // plist from a test host (settings-pollution class).
        if TestEnvironment.isTestHost && defaults === UserDefaults.standard {
            return
        }
        let d = defaults
        let p = Self.prefix
        d.set(personName, forKey: "\(p)personName")
        d.set(referencePath, forKey: "\(p)referencePath")
        d.set(outputDir, forKey: "\(p)outputDir")
        d.set(recognitionEngine.rawValue, forKey: "\(p)recognitionEngine")
        d.set(threshold, forKey: "\(p)threshold")
        d.set(minFaceConfidence, forKey: "\(p)minFaceConfidence")
        d.set(frameStep, forKey: "\(p)frameStep")
        d.set(pad, forKey: "\(p)pad")
        d.set(minDuration, forKey: "\(p)minDuration")
        d.set(minPresenceSecs, forKey: "\(p)minPresenceSecs")
        d.set(concurrency, forKey: "\(p)concurrency")
        d.set(requirePrimary, forKey: "\(p)requirePrimary")
        d.set(skipBundles, forKey: "\(p)skipBundles")
        d.set(skipCatalogBadFiles, forKey: "\(p)skipCatalogBadFiles")
        d.set(largestFaceOnly, forKey: "\(p)largestFaceOnly")
        d.set(arcfaceLandmarkAlignment, forKey: "\(p)arcfaceLandmarkAlignment")
        d.set(previewRate, forKey: "\(p)previewRate")
        d.set(arcfaceThreshold, forKey: "\(p)arcfaceThreshold")
        d.set(adafaceThreshold, forKey: "\(p)adafaceThreshold")
        d.set(arcfaceInferenceConcurrency, forKey: "\(p)arcfaceInferenceConcurrency")
        d.set(rejectedReferenceFiles, forKey: "\(p)rejectedReferenceFiles")
        d.set(matchConfidenceFloor, forKey: "\(p)matchConfidenceFloor")
    }
}

// MARK: - Identity metadata (POI priors)
//
// Small fixed palettes for the identity fields on POIProfile. The raw
// String value is what lands in profile.json, so renaming a case is a
// persistence-format change — don't do it casually.
//
// These feed pfIdentityCandidates (IdentityNarrowing.swift) as
// plausibility priors: sex mismatches demote, hair/eye matches boost.
// See that file's header for the scoring doctrine.

/// Binary by explicit design decision (Rick, 2026-07) — family archive
/// priors, not a demographic form. nil ⇒ not set / no filtering.
enum PersonSex: String, Codable, CaseIterable, Sendable {
    case female, male

    var label: String {
        switch self {
        case .female: return "Female"
        case .male:   return "Male"
        }
    }
}

/// Coarse hair-color palette. Scoring only ever BOOSTS on a match —
/// hair changes across decades (gold in 1979, gray in 2010) and old
/// B&W/faded footage lies about color, so a mismatch never penalizes.
enum HairColor: String, Codable, CaseIterable, Sendable {
    case blonde, brown, black, red, gray, white, bald

    var label: String {
        switch self {
        case .blonde: return "Blonde"
        case .brown:  return "Brown"
        case .black:  return "Black"
        case .red:    return "Red"
        case .gray:   return "Gray"
        case .white:  return "White"
        case .bald:   return "Bald"
        }
    }
}

/// Eye-color palette. Same boost-only rule as HairColor.
enum EyeColor: String, Codable, CaseIterable, Sendable {
    case blue, brown, green, hazel, gray

    var label: String {
        switch self {
        case .blue:  return "Blue"
        case .brown: return "Brown"
        case .green: return "Green"
        case .hazel: return "Hazel"
        case .gray:  return "Gray"
        }
    }
}

// MARK: - POI Profile (Person of Interest)

struct POIProfile: Codable, Identifiable, Equatable {
    var id: String { name.lowercased() }
    var name: String
    var referencePath: String
    var rejectedFiles: [String] = []
    var engine: String = RecognitionEngine.vision.rawValue
    var visionThreshold: Float = 0.52
    var arcfaceThreshold: Float = 0.40
    var adafaceThreshold: Float = 0.30
    var minFaceConfidence: Float = 0.55
    var largestFaceOnly: Bool = false
    /// Filename of the best reference photo — used as the avatar in the People gallery.
    var coverImageFilename: String?
    /// Free-form notes about this person (relationship, maiden name, etc.)
    var notes: String = ""
    /// Alternate names / spellings that might appear in video filenames or metadata.
    var aliases: [String] = []
    /// Cover photo crop: pan offset (normalized, 0 = centered).
    var coverCropOffsetX: Double = 0
    var coverCropOffsetY: Double = 0
    /// Cover photo crop: zoom scale (1.0 = fill, >1 = zoomed in).
    var coverCropScale: Double = 1.0
    /// Manual sort position in the People gallery (lower = further left).
    var sortOrder: Int = Int.max
    /// Date of birth. Used by pfIdentityCandidates to eliminate
    /// impossible identities (a person born 1994 cannot be in a video
    /// from 1991) and to age-match candidates against VLM scene
    /// descriptions like "baby ~1yr". nil ⇒ unknown, no filtering.
    /// Editable by hand in the POI profile JSON file.
    var birthdate: Date?
    /// Date of death, if applicable. Same logic as birthdate but on
    /// the upper end — a person who died in 2010 cannot be in a 2024
    /// video. nil ⇒ alive or unknown.
    var deathdate: Date?
    /// Sex, used by pfIdentityCandidates to demote (never eliminate)
    /// candidates when a VLM scene description clearly says the other
    /// ("a boy", "a woman"). nil ⇒ not set, no sex signal.
    var sex: PersonSex?
    /// Hair color prior — boost-only signal (a match raises plausibility,
    /// a mismatch never lowers it; hair changes across decades and
    /// B&W footage lies). nil ⇒ not set.
    var hairColor: HairColor?
    /// Eye color prior — same boost-only rule as hairColor.
    var eyeColor: EyeColor?
    /// Free-text identity notes ("blonde hair blue eyes, always wore
    /// glasses"). Stored for Rick's own reference and future evidence
    /// fusion — NOT consumed by any algorithm yet. Separate from `notes`
    /// (relationship / maiden name) on purpose.
    var identityNotes: String?

    // MARK: Codable — tolerate missing keys from older JSON files

    init(name: String, referencePath: String, rejectedFiles: [String] = [],
         engine: String = RecognitionEngine.vision.rawValue,
         visionThreshold: Float = 0.52, arcfaceThreshold: Float = 0.40,
         adafaceThreshold: Float = 0.30,
         minFaceConfidence: Float = 0.55, largestFaceOnly: Bool = false,
         coverImageFilename: String? = nil, notes: String = "", aliases: [String] = [],
         coverCropOffsetX: Double = 0, coverCropOffsetY: Double = 0, coverCropScale: Double = 1.0,
         sortOrder: Int = Int.max, birthdate: Date? = nil, deathdate: Date? = nil,
         sex: PersonSex? = nil, hairColor: HairColor? = nil, eyeColor: EyeColor? = nil,
         identityNotes: String? = nil) {
        self.name = name
        self.referencePath = referencePath
        self.rejectedFiles = rejectedFiles
        self.engine = engine
        self.visionThreshold = visionThreshold
        self.arcfaceThreshold = arcfaceThreshold
        self.adafaceThreshold = adafaceThreshold
        self.minFaceConfidence = minFaceConfidence
        self.largestFaceOnly = largestFaceOnly
        self.coverImageFilename = coverImageFilename
        self.notes = notes
        self.aliases = aliases
        self.coverCropOffsetX = coverCropOffsetX
        self.coverCropOffsetY = coverCropOffsetY
        self.coverCropScale = coverCropScale
        self.sortOrder = sortOrder
        self.birthdate = birthdate
        self.deathdate = deathdate
        self.sex = sex
        self.hairColor = hairColor
        self.eyeColor = eyeColor
        self.identityNotes = identityNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name              = try c.decode(String.self, forKey: .name)
        referencePath     = try c.decode(String.self, forKey: .referencePath)
        rejectedFiles     = try c.decodeIfPresent([String].self, forKey: .rejectedFiles) ?? []
        engine            = try c.decodeIfPresent(String.self, forKey: .engine) ?? RecognitionEngine.vision.rawValue
        visionThreshold   = try c.decodeIfPresent(Float.self, forKey: .visionThreshold) ?? 0.52
        arcfaceThreshold  = try c.decodeIfPresent(Float.self, forKey: .arcfaceThreshold) ?? 0.40
        adafaceThreshold  = try c.decodeIfPresent(Float.self, forKey: .adafaceThreshold) ?? 0.30
        minFaceConfidence = try c.decodeIfPresent(Float.self, forKey: .minFaceConfidence) ?? 0.55
        largestFaceOnly   = try c.decodeIfPresent(Bool.self, forKey: .largestFaceOnly) ?? false
        coverImageFilename = try c.decodeIfPresent(String.self, forKey: .coverImageFilename)
        notes             = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        aliases           = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        coverCropOffsetX  = try c.decodeIfPresent(Double.self, forKey: .coverCropOffsetX) ?? 0
        coverCropOffsetY  = try c.decodeIfPresent(Double.self, forKey: .coverCropOffsetY) ?? 0
        coverCropScale    = try c.decodeIfPresent(Double.self, forKey: .coverCropScale) ?? 1.0
        sortOrder         = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? Int.max
        birthdate         = try c.decodeIfPresent(Date.self, forKey: .birthdate)
        deathdate         = try c.decodeIfPresent(Date.self, forKey: .deathdate)
        // Identity metadata (2026-07) — all decodeIfPresent so profile.json
        // files written before the feature load unchanged. An unrecognized
        // rawValue (future palette addition) throws, so degrade that FIELD
        // to nil — a bad color must never brick a profile load — but log
        // the drop so a vanishing value is visible, not silent.
        sex               = Self.decodeIdentityField(PersonSex.self, forKey: .sex, from: c)
        hairColor         = Self.decodeIdentityField(HairColor.self, forKey: .hairColor, from: c)
        eyeColor          = Self.decodeIdentityField(EyeColor.self, forKey: .eyeColor, from: c)
        identityNotes     = try c.decodeIfPresent(String.self, forKey: .identityNotes)
    }

    /// Lenient per-field decode for the identity enums. Replaces bare
    /// `try?` (which degraded silently): the load still succeeds with the
    /// field nil'd, but the drop leaves a notice in videoscan.log so a
    /// future-palette value disappearing on load can be diagnosed.
    /// Generic over the key type because the compiler-synthesized
    /// CodingKeys enum can't be named in another member's signature.
    private static func decodeIdentityField<T: Decodable, K: CodingKey>(
        _ type: T.Type,
        forKey key: K,
        from c: KeyedDecodingContainer<K>
    ) -> T? {
        do {
            return try c.decodeIfPresent(T.self, forKey: key)
        } catch {
            identityLog.notice("POIProfile load: dropped unrecognized '\(key.stringValue, privacy: .public)' value (written by a newer app version?) — field left unset. \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: File-based persistence
    //
    // Storage layout lives in POIStorage — each POI gets its own folder
    // under ~/Library/Application Support/VideoScan/POI/<name>/ holding
    // profile.json plus its reference photos. See POIStorage.swift.
    //
    // referencePath in the JSON is kept for backwards compatibility but
    // is ALWAYS rewritten on save to point at the POI's own folder, so
    // moving the user's home directory can't break things.

    func save() throws {
        let folder = POIStorage.folder(for: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep referencePath in sync with actual location.
        var copy = self
        copy.referencePath = folder.path
        let data = try JSONEncoder().encode(copy)
        try data.write(to: POIStorage.profileURL(for: name), options: .atomic)
    }

    static func load(name: String) throws -> POIProfile {
        let data = try Data(contentsOf: POIStorage.profileURL(for: name))
        var profile = try JSONDecoder().decode(POIProfile.self, from: data)
        // Heal referencePath — its folder is implicit, always the POI's own folder.
        profile.referencePath = POIStorage.folder(for: profile.name).path
        return profile
    }

    /// Soft-delete the POI by moving its folder into ~/dev/VideoScan/.trash/.
    /// Project policy forbids unconditional removeItem on POI data — see
    /// POIStorage.trashPOIFolder for the rationale.
    ///
    /// Returns silently when the folder doesn't exist (idempotent). Throws
    /// only when the folder exists but the move-to-trash fails (e.g.
    /// permission denied on .trash/).
    static func delete(name: String) throws {
        let folder = POIStorage.folder(for: name)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if POIStorage.trashPOIFolder(named: name) == nil {
            throw NSError(
                domain: "POIProfile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not move \(folder.path) into .trash/"]
            )
        }
    }

    static func listAll() -> [POIProfile] {
        // Trigger lazy migration on first read.
        _ = POIStorage.migrateLegacyIfNeeded()
        return POIStorage.allPOIFolders().compactMap { folder in
            let profileURL = folder.appendingPathComponent("profile.json")
            guard let data = try? Data(contentsOf: profileURL),
                  var p = try? JSONDecoder().decode(POIProfile.self, from: data)
            else { return nil }
            // Heal referencePath on read — the folder location is authoritative.
            p.referencePath = folder.path
            return p
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolve the cover image to an NSImage by looking in the reference folder.
    /// Returns nil if no cover is set or the file doesn't exist.
    var coverImage: NSImage? {
        guard let filename = coverImageFilename else { return nil }
        let url = URL(fileURLWithPath: referencePath).appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }

    /// Same engine→threshold mapping as PersonFinderSettings.thresholdForEngine,
    /// for profile-driven cache restores (#144).
    func thresholdForEngine(_ engine: RecognitionEngine) -> Float {
        switch engine {
        case .arcface:         return arcfaceThreshold
        case .adaface:         return adafaceThreshold
        case .vision, .hybrid: return visionThreshold
        }
    }

    /// Whether custom crop parameters have been set.
    var hasCoverCrop: Bool {
        coverCropScale != 1.0 || coverCropOffsetX != 0 || coverCropOffsetY != 0
    }

    /// List image filenames in the reference folder (for cover photo picking).
    /// profile.json lives in the same folder and is filtered out by the
    /// extension whitelist below — no explicit skip needed.
    var referenceImageFilenames: [String] {
        guard !referencePath.isEmpty else { return [] }
        let url = URL(fileURLWithPath: referencePath)
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Load an NSImage for a filename in the reference folder.
    func referenceImage(named filename: String) -> NSImage? {
        let url = URL(fileURLWithPath: referencePath).appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }

    /// Pick the best reference photo filename for the cover — highest confidence, frontal.
    static func bestCoverFilename(from faces: [ReferenceFace]) -> String? {
        faces.max { a, b in
            // Returns true when a is "less" than b, so max() picks the largest.
            // Prefer good quality, then highest confidence.
            if a.quality != b.quality {
                let rank: (ReferenceFace.Quality) -> Int = { q in
                    switch q { case .good: return 2; case .fair: return 1; case .poor: return 0 }
                }
                return rank(a.quality) < rank(b.quality)
            }
            return a.confidence < b.confidence
        }?.sourceFilename
    }
}

// MARK: - Job Status

enum ScanJobStatus: Equatable {
    case idle, loading, scanning, paused, done, cancelled
    case failed(String)

    var label: String {
        switch self {
        case .idle:       return "Idle"
        case .loading:    return "Loading reference…"
        case .scanning:   return "Scanning…"
        case .paused:     return "Paused"
        case .done:       return "Done"
        case .cancelled:  return "Stopped"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        switch self { case .loading, .scanning, .paused: return true; default: return false }
    }
    var isIdle: Bool { self == .idle }
    var isDone: Bool { if case .done = self { return true }; if case .cancelled = self { return true }; return false }
    var isCompleted: Bool { if case .done = self { return true }; return false }
    var isTerminal: Bool { isDone || isFailed }
    var isPaused: Bool { self == .paused }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

// MARK: - Compilation

enum CompilationMode: String, CaseIterable, Identifiable {
    case singleVideo = "One video"
    case perBucket   = "Separate by codec/resolution"
    var id: String { rawValue }
}

struct CompilationSettings: Equatable {
    var mode: CompilationMode = .singleVideo
    var pad: Double = 2.0
    var concurrency: Int = 8

    private static let defaults = UserDefaults.standard
    private static let prefix = "comp_"

    static func restored() -> CompilationSettings {
        // Same test-host prefs gate as PersonFinderSettings above.
        if TestEnvironment.isTestHost { return CompilationSettings() }
        var s = CompilationSettings()
        let d = defaults; let p = prefix
        if let v = d.string(forKey: "\(p)mode"), let m = CompilationMode(rawValue: v) { s.mode = m }
        if d.object(forKey: "\(p)pad") != nil { s.pad = d.double(forKey: "\(p)pad") }
        if d.object(forKey: "\(p)concurrency") != nil { s.concurrency = d.integer(forKey: "\(p)concurrency") }
        return s
    }

    func save() {
        // Same test-host prefs gate as PersonFinderSettings above.
        if TestEnvironment.isTestHost { return }
        let d = Self.defaults; let p = Self.prefix
        d.set(mode.rawValue, forKey: "\(p)mode")
        d.set(pad, forKey: "\(p)pad")
        d.set(concurrency, forKey: "\(p)concurrency")
    }
}

enum CompilationStatus: Equatable {
    case idle
    case extracting
    case compiling
    case merging
    case done
    case failed(String)

    var isActive: Bool {
        switch self { case .extracting, .compiling, .merging: return true; default: return false }
    }

    var label: String {
        switch self {
        case .idle:       return ""
        case .extracting: return "Extracting clips…"
        case .compiling:  return "Building compilations…"
        case .merging:    return "Merging to single file…"
        case .done:       return "Complete"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}

// MARK: - Reference Face

struct ReferenceFace: Identifiable {
    let id = UUID()
    let featurePrint: VNFeaturePrintObservation
    let thumbnail: CGImage              // 256×256 normalized crop
    let sourceFilename: String
    let confidence: Float
    let rollDeg: Double                 // head tilt in degrees
    let yawDeg: Double                  // left/right turn
    let pitchDeg: Double                // up/down tilt
    let faceAreaPct: Float              // face bbox as % of source image area

    enum Quality { case good, fair, poor }

    var quality: Quality {
        if confidence >= 0.80 && abs(yawDeg) < 30 && abs(rollDeg) < 25 { return .good }
        if confidence >= 0.60 { return .fair }   // confidence is the primary gate; angle is a bonus
        return .poor
    }

    var angleDescription: String {
        var parts: [String] = []
        if abs(yawDeg) < 15 { parts.append("frontal") } else if yawDeg < -15 { parts.append("left profile") } else { parts.append("right profile") }
        if abs(pitchDeg) > 20 { parts.append(pitchDeg > 0 ? "looking up" : "looking down") }
        if abs(rollDeg) > 20 { parts.append("tilted") }
        return parts.joined(separator: ", ")
    }
}

/// A reference photo that failed face detection — surfaced to the user.
struct ReferenceLoadFailure: Identifiable {
    let id = UUID()
    let filename: String
    let reason: String
}

// MARK: - Clip Result (shown in results table)

struct ClipResult: Identifiable {
    let id = UUID()
    let videoFilename: String
    let videoPath: String
    let videoDuration: Double
    let presenceSecs: Double
    let segmentCount: Int
    let bestDistance: Float
    var clipFiles: [String]
    let outputDir: String

    // MARK: Identity plausibility (POI priors × dossier evidence)
    //
    // Computed AFTER the face-match pipeline by
    // PersonFinderModel.annotateIdentityPlausibility — never in a view
    // body (GH #104 rule). nil ⇒ not evaluated (no priors set, no
    // catalog evidence, or the annotate pass hasn't run yet).
    /// 0.0 = impossible (born after / died before the video's inferred
    /// date); higher = scene cues fit this person better. See
    /// IdentityNarrowing.swift for the scoring doctrine.
    var plausibility: Float?
    /// Human-readable explanation for the score — surfaced as a tooltip
    /// on the results row ("born 1983 — after video date 1981").
    var plausibilityReason: String?

    /// Sort key for the results table: unevaluated rows sort as neutral
    /// (0.5) so they sit between "likely" and "demoted" rows.
    var plausibilitySortKey: Float { plausibility ?? 0.5 }
}

// MARK: - Compiled Output (one per bucket — see docs/compilation-bucketing.md)

struct CompiledOutput: Identifiable, Equatable, Hashable {
    let id = UUID()
    let path: String          // absolute path to the .mp4/.mov on disk
    let label: String         // shortLabel from CompatKey, e.g. "h264_1080p2997_aac48k_2ch"
    let clipCount: Int
    let durationSecs: Double
    let bytesOnDisk: Int64

    static func == (lhs: CompiledOutput, rhs: CompiledOutput) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Internal data types

struct pfVideoResult {
    let filename: String
    let filePath: String
    let durationSeconds: Double
    let fps: Double
    let totalHits: Int
    let segments: [pfSegment]
    /// Total face observations examined while sampling this video, regardless
    /// of identity match. Kept separate from totalHits so the evaluator can
    /// distinguish "no people" from "people, but not the target person."
    let facesDetected: Int
    var clipFiles: [String] = []

    init(filename: String, filePath: String, durationSeconds: Double, fps: Double,
         totalHits: Int, segments: [pfSegment], facesDetected: Int = 0,
         clipFiles: [String] = []) {
        self.filename = filename
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.fps = fps
        self.totalHits = totalHits
        self.segments = segments
        self.facesDetected = facesDetected
        self.clipFiles = clipFiles
    }

    nonisolated var totalPresenceSecs: Double { segments.map { $0.endSecs - $0.startSecs }.reduce(0, +) }
}

struct pfSegment {
    var startSecs: Double
    var endSecs: Double
    var bestDistance: Float
    var avgDistance: Float
    var duration: Double { endSecs - startSecs }
}
