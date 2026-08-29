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
    /// Cosine similarity threshold (higher = stricter). CHOKE POINT for
    /// poisoned values (codex adversarial #42): the didSet clamps EVERY
    /// assignment — plist restore, POI profile apply, bundle import, eval
    /// CLI, UI — to the legal band. Struct didSet is safe here (the
    /// @Observable-kills-didSet gotcha applies to classes) and doesn't
    /// recurse on self-assignment. It does NOT fire for the default value,
    /// which is valid by construction.
    var arcfaceThreshold: Float = 0.40 {
        didSet { arcfaceThreshold = Self.clampCosineThreshold(arcfaceThreshold) }
    }

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
    /// Same didSet choke-point clamp as arcfaceThreshold above.
    var adafaceThreshold: Float = 0.30 {
        didSet { adafaceThreshold = Self.clampCosineThreshold(adafaceThreshold) }
    }

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

    /// Legal band for a cosine-similarity threshold restored from a plist.
    /// 0.05 floor: 0.0 (the poisoned-decode value) would match every face;
    /// 0.95 ceiling: nothing real ever matches above it. In-band values
    /// pass through untouched.
    static func clampCosineThreshold(_ v: Float) -> Float {
        min(max(v, 0.05), 0.95)
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
        // Poisoned cosine thresholds (non-numeric decodes to 0.0 → every
        // face matches) are normalized by the properties' own didSet clamp
        // — the single choke point all assignment paths share (plist
        // restore here, POI applyProfile, bundle import, eval CLI, UI).
        if d.object(forKey: "\(p)arcfaceThreshold") != nil {
            s.arcfaceThreshold = d.float(forKey: "\(p)arcfaceThreshold")
        }
        if d.object(forKey: "\(p)adafaceThreshold") != nil {
            s.adafaceThreshold = d.float(forKey: "\(p)adafaceThreshold")
        }
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
    /// Typed, local-only family relationships ("sibling of Rick"), never
    /// written to GEDCOM/FamilySearch (director decision 2026-08-27 —
    /// living relatives stay out of the tree). Inverses, gendered words
    /// and composed relations are derived by FamilyKinshipOverlay, not
    /// stored. Missing in older profile.json ⇒ [] (additive schema).
    var kinships: [Kinship] = []
    /// Kinship rows this build could not read (newer relation word, damaged
    /// JSON). Kept verbatim and written back on save so nothing is silently
    /// lost (codex #778). Never shown as facts.
    var kinshipsQuarantined: [JSONValue] = []
    /// Durable identity (2026-08-28). `id` (name.lowercased()) is the UI /
    /// storage-folder identity and changes on rename; `uuid` never does, so
    /// other profiles' kinship rows anchor on it. Assigned on first load of
    /// an older profile.json and persisted by `load(name:)`.
    var uuid: UUID = UUID()
    /// Whether `uuid` is known to be on disk (codex #799/#800). False only
    /// when a legacy profile's minted uuid could NOT be written (read-only
    /// folder, full disk). TRANSIENT — deliberately absent from CodingKeys
    /// so it is never serialized; a decoded profile starts `true` and the
    /// loader flips it on write failure. Anchor to such a profile through
    /// `kinshipAnchor`, never `.profile(id: uuid)` directly, or the id
    /// dangles after restart ("a removed profile").
    var uuidPersisted: Bool = true
    /// Durable pin to ONE family-tree person (design amendment 1, 2026-08-29):
    /// the only profile→tree identity the inference engine accepts. nil =
    /// not pinned (name matches are review SUGGESTIONS, never identity).
    /// Additive: absent in older profile.json ⇒ nil; saved explicitly.
    var treeIdentity: TreeIdentity?
    /// A `treeIdentity` this build could not read, kept verbatim and written
    /// back so a newer build's pin is never lost (fail closed: the overlay
    /// treats the profile as unbridged with a pin problem, never a name).
    var treeIdentityQuarantined: JSONValue?
    /// How `treeIdentity` came to be (2026-08-29, auto-derived identity):
    /// "derived: owner setting", "derived: tree root", "picked: Rick, 2026-08-29".
    /// Additive; nil for pins written before the field existed.
    var treeIdentityAttestation: String?
    /// Rick said this person is NOT on the family tree (a living relative
    /// FamilySearch never carries). "Show in Family Tree" stops asking
    /// which record they are. Additive; absent ⇒ false.
    var notInFamilyTree: Bool = false
    /// When the cover photo was last chosen here (2026-08-29, one photo per
    /// person). Compared with the Family Tree's choice: the later explicit
    /// choice shows in BOTH views. nil in older files ⇒ no claim.
    var photoChosenAt: Date?

    /// The anchor other profiles should store for THIS profile: the durable
    /// uuid when it is on disk, otherwise the name (upgraded automatically
    /// by `listAll` once the uuid persists). The only sanctioned way to
    /// mint a `.profile(id:)` anchor from a profile.
    var kinshipAnchor: KinshipAnchor {
        uuidPersisted ? .profile(id: uuid) : .profileName(name)
    }

    // MARK: Codable — tolerate missing keys from older JSON files

    /// Explicit so the transient `uuidPersisted` stays out of profile.json.
    /// (C++: the serializer's field list, spelled out instead of reflected.)
    /// A new stored property MUST be added here or it silently won't save.
    enum CodingKeys: String, CodingKey {
        case name, referencePath, rejectedFiles, engine
        case visionThreshold, arcfaceThreshold, adafaceThreshold
        case minFaceConfidence, largestFaceOnly, coverImageFilename, notes, aliases
        case coverCropOffsetX, coverCropOffsetY, coverCropScale, sortOrder
        case birthdate, deathdate, sex, hairColor, eyeColor, identityNotes
        case kinships, kinshipsQuarantined, uuid, treeIdentity, treeIdentityQuarantined
        case treeIdentityAttestation, notInFamilyTree
        case photoChosenAt
    }

    init(name: String, referencePath: String, rejectedFiles: [String] = [],
         engine: String = RecognitionEngine.vision.rawValue,
         visionThreshold: Float = 0.52, arcfaceThreshold: Float = 0.40,
         adafaceThreshold: Float = 0.30,
         minFaceConfidence: Float = 0.55, largestFaceOnly: Bool = false,
         coverImageFilename: String? = nil, notes: String = "", aliases: [String] = [],
         coverCropOffsetX: Double = 0, coverCropOffsetY: Double = 0, coverCropScale: Double = 1.0,
         sortOrder: Int = Int.max, birthdate: Date? = nil, deathdate: Date? = nil,
         sex: PersonSex? = nil, hairColor: HairColor? = nil, eyeColor: EyeColor? = nil,
         identityNotes: String? = nil, kinships: [Kinship] = [],
         uuid: UUID = UUID(), treeIdentity: TreeIdentity? = nil) {
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
        self.kinships = kinships
        self.uuid = uuid
        self.treeIdentity = treeIdentity
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
        // Kinships (2026-08-27): absent in older files ⇒ []. Decoded ROW BY
        // ROW (codex #778): a row this build can't read is quarantined, not
        // dropped, so the readable rows stay usable and the odd one survives
        // the next save.
        let rows = Self.decodeIdentityField([JSONValue].self, forKey: .kinships, from: c) ?? []
        var readable: [Kinship] = []
        var quarantined = Self.decodeIdentityField([JSONValue].self, forKey: .kinshipsQuarantined, from: c) ?? []
        for row in rows {
            if let data = try? JSONEncoder().encode(row),
               let kinship = try? JSONDecoder().decode(Kinship.self, from: data) {
                readable.append(kinship)
            } else {
                identityLog.notice("POIProfile load: quarantined an unreadable kinship row (written by a newer app version?) — kept verbatim.")
                quarantined.append(row)
            }
        }
        kinships          = readable
        kinshipsQuarantined = quarantined
        uuid              = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID()
        photoChosenAt     = try c.decodeIfPresent(Date.self, forKey: .photoChosenAt)
        // Pin (2026-08-29): decoded as raw JSON first so an unreadable pin is
        // quarantined, not dropped and not silently replaced by a name match.
        let rawPin = Self.decodeIdentityField(JSONValue.self, forKey: .treeIdentity, from: c)
        if let rawPin, let data = try? JSONEncoder().encode(rawPin),
           let pin = try? JSONDecoder().decode(TreeIdentity.self, from: data) {
            treeIdentity = pin
            treeIdentityQuarantined = nil
        } else {
            treeIdentity = nil
            treeIdentityQuarantined = rawPin ?? Self.decodeIdentityField(JSONValue.self, forKey: .treeIdentityQuarantined, from: c)
            if rawPin != nil {
                identityLog.notice("POIProfile load: quarantined an unreadable treeIdentity pin (written by a newer app version?) — kept verbatim, not used.")
            }
        }
        treeIdentityAttestation = try c.decodeIfPresent(String.self, forKey: .treeIdentityAttestation)
        notInFamilyTree = Self.decodeIdentityField(Bool.self, forKey: .notInFamilyTree, from: c) ?? false
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
        // Remote viewer (Phase 1): POI/ is synced FROM the master; never
        // written here (the kinship attestations ride in profile.json).
        try ViewerWriteGuard.check("POIProfile.save")
        let folder = POIStorage.folder(for: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(profileJSONAt: POIStorage.profileURL(for: name), folder: folder)
    }

    /// The ONE writer for profile.json (atomic replace). `save()` and the
    /// uuid migration in `listAll` both go through here so a profile is
    /// never written two different ways. `folder` becomes the healed
    /// referencePath — the folder the JSON actually lives in, which for a
    /// legacy folder name can differ from `POIStorage.folder(for: name)`.
    private func write(profileJSONAt url: URL, folder: URL) throws {
        // Keep referencePath in sync with actual location.
        var copy = self
        copy.referencePath = folder.path
        let data = try JSONEncoder().encode(copy)
        try data.write(to: url, options: .atomic)
    }

    static func load(name: String) throws -> POIProfile {
        let data = try Data(contentsOf: POIStorage.profileURL(for: name))
        var profile = try JSONDecoder().decode(POIProfile.self, from: data)
        // Heal referencePath — its folder is implicit, always the POI's own folder.
        profile.referencePath = POIStorage.folder(for: profile.name).path
        // First load of a pre-uuid profile.json: persist the freshly minted
        // uuid so kinship anchors written later stay durable across renames.
        // Failure is logged, not thrown — the load itself still succeeds.
        if !Self.hasUUIDKey(data) {
            do { try profile.save() } catch {
                profile.uuidPersisted = false
                identityLog.error("POIProfile load: could not persist the minted uuid for '\(profile.name, privacy: .public)' — anchors to it stay name-based. \(String(describing: error), privacy: .public)")
            }
        }
        return profile
    }

    private static func hasUUIDKey(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["uuid"] != nil
    }

    /// Upgrade legacy `.profileName` kinship anchors to durable `.profile(id:)`
    /// anchors where the named profile exists in `profiles` (in memory; the
    /// upgraded form is written the next time that profile is saved). Names
    /// that match no profile are left as-is so the row still displays.
    ///
    /// Codex #791/#799: a uuid that was minted in memory but could NOT be
    /// written to disk (`uuidPersisted == false`, or listed in
    /// `unpersistedUUIDs`) is never anchored — the id would dangle after
    /// restart — so the row keeps its name anchor and gets another chance
    /// next launch. Both signals are honoured so a caller can't forget one.
    static func upgradingKinshipAnchors(_ profiles: [POIProfile],
                                        unpersistedUUIDs: Set<UUID> = []) -> [POIProfile] {
        let blocked = unpersistedUUIDs.union(profiles.filter { !$0.uuidPersisted }.map(\.uuid))
        let byName = Dictionary(profiles.map { (PersonResolver.normalize($0.name), $0.uuid) },
                                uniquingKeysWith: { first, _ in first })
        return profiles.map { profile in
            var copy = profile
            copy.kinships = profile.kinships.map { row in
                guard case .profileName(let name) = row.relativeTo,
                      let id = byName[PersonResolver.normalize(name)],
                      !blocked.contains(id) else { return row }
                var upgraded = row
                upgraded.relativeTo = .profile(id: id)
                return upgraded
            }
            return copy
        }
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
        let decoded = decodeProfilesTrackingLegacyUUIDs(in: POIStorage.allPOIFolders())
        // uuid migration (codex #791): a profile.json written before `uuid`
        // existed gets a fresh uuid on decode. Persist it NOW, through the
        // same atomic writer as save(), so the id other profiles anchor on
        // is the one on disk after restart — not a per-launch ephemeral.
        var unpersisted = Set<UUID>()
        for (profile, folder) in decoded.legacy {
            do {
                try profile.write(profileJSONAt: folder.appendingPathComponent("profile.json"),
                                  folder: folder)
                identityLog.notice("POIProfile listAll: persisted a minted uuid for '\(profile.name, privacy: .public)'.")
            } catch {
                unpersisted.insert(profile.uuid)
                identityLog.error("POIProfile listAll: could not persist the minted uuid for '\(profile.name, privacy: .public)' — kinship anchors to it stay name-based this launch. \(String(describing: error), privacy: .public)")
            }
        }
        // The returned profiles CARRY the failure (codex #799): anyone
        // minting an anchor from them (the edit sheet's picker) goes through
        // `kinshipAnchor`, which falls back to the name for these.
        let profiles = decoded.profiles.map { profile -> POIProfile in
            guard unpersisted.contains(profile.uuid) else { return profile }
            var copy = profile
            copy.uuidPersisted = false
            return copy
        }
        return upgradingKinshipAnchors(profiles, unpersistedUUIDs: unpersisted)
    }

    /// Decode profile.json in each folder; corrupt/missing entries are
    /// skipped, referencePath is healed to the folder (authoritative).
    /// Read-only — never writes (cachedSnapshot relies on that).
    private static func decodeProfiles(in folders: [URL]) -> [POIProfile] {
        decodeProfilesTrackingLegacyUUIDs(in: folders).profiles
    }

    /// `decodeProfiles` plus the subset whose JSON had no `uuid` key (their
    /// in-memory uuid was minted by the decoder and is not yet on disk),
    /// each with the folder it was read from.
    private static func decodeProfilesTrackingLegacyUUIDs(in folders: [URL])
        -> (profiles: [POIProfile], legacy: [(POIProfile, URL)]) {
        var legacy: [(POIProfile, URL)] = []
        let profiles = folders.compactMap { folder -> POIProfile? in
            let profileURL = folder.appendingPathComponent("profile.json")
            guard let data = try? Data(contentsOf: profileURL),
                  var p = try? JSONDecoder().decode(POIProfile.self, from: data)
            else { return nil }
            p.referencePath = folder.path
            if !hasUUIDKey(data) { legacy.append((p, folder)) }
            return p
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (profiles, legacy)
    }

    // MARK: Read-only snapshot (no migration)

    /// Cache for `cachedSnapshot`: the profile.json modification dates seen
    /// last time, and what they decoded to. A plain static ≈ a C++ function
    /// static; main-actor only (every caller is UI).
    @MainActor private static var snapshotKey: [String: Date] = [:]
    @MainActor private static var snapshotValue: [POIProfile] = []

    /// Profiles as currently on disk WITHOUT triggering the legacy
    /// migration (which can copy photos) — for hint handlers that run on
    /// the main actor (Family Tree focus). Re-decodes only when a
    /// profile.json appeared, vanished, or changed; otherwise returns the
    /// cached array. `root` is injectable for tests (never the real store).
    @MainActor
    static func cachedSnapshot(root: URL = POIStorage.storeDir) -> [POIProfile] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var key: [String: Date] = [:]
        for folder in folders {
            let url = folder.appendingPathComponent("profile.json")
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                key[url.path] = date
            }
        }
        if key == snapshotKey, !key.isEmpty { return snapshotValue }
        let value = decodeProfiles(in: folders)
        snapshotKey = key
        snapshotValue = value
        return value
    }

    /// Resolve the cover image to an NSImage by looking in the reference folder.
    /// Returns nil if no cover is set or the file doesn't exist.
    var coverImage: NSImage? {
        guard let filename = coverImageFilename else { return nil }
        let url = URL(fileURLWithPath: referencePath).appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }

    /// Same engine→threshold mapping as PersonFinderSettings.thresholdForEngine,
    /// for profile-driven cache restores (#144). Cosine thresholds are
    /// clamped HERE because this is the one path that reads the profile's
    /// raw stored values directly (a hand-edited/poisoned profile.json
    /// bypasses the PersonFinderSettings didSet choke point until
    /// applyProfile runs — codex adversarial #42).
    func thresholdForEngine(_ engine: RecognitionEngine) -> Float {
        switch engine {
        case .arcface:         return PersonFinderSettings.clampCosineThreshold(arcfaceThreshold)
        case .adaface:         return PersonFinderSettings.clampCosineThreshold(adafaceThreshold)
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
    /// The wall-clock watchdog ended this scan early — the result is
    /// PARTIAL and must NEVER be cached as complete (codex #290:
    /// pre-flag, a ceiling abort cached a partial no-hit forever).
    /// Retryable: the next run scans the file again.
    var watchdogAborted: Bool = false
    var clipFiles: [String] = []

    init(filename: String, filePath: String, durationSeconds: Double, fps: Double,
         totalHits: Int, segments: [pfSegment], facesDetected: Int = 0,
         watchdogAborted: Bool = false,
         clipFiles: [String] = []) {
        self.filename = filename
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.fps = fps
        self.totalHits = totalHits
        self.segments = segments
        self.facesDetected = facesDetected
        self.watchdogAborted = watchdogAborted
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
