import Testing
import Foundation
@testable import VideoScan

// MARK: - AdaFace plugin migration & persistence tests (GH #144)
//
// Five-dimension coverage notes (docs/testing_retrospective_2026_07_05.md):
//  - Logic: token migration + threshold selection (here and in ModelTests /
//    PersonFinderLifecycleTests).
//  - Isolation / poisoned state: every persistence test below runs against
//    a fresh throwaway UserDefaults suite (settings-pollution rule) and
//    includes a garbage-token case.
//  - Sensor: ModelTests.dlibCannotReappearInSearchRegistry pins the
//    registry; storedDlibPreferenceMigratesOnRestore below pins the
//    preference path at the persistence boundary.
//  - Scale / media matrix: engine selection is O(1) config, not O(records);
//    media behavior rides the existing fixture stress suite, which now
//    accepts "adaface" in VIDEOSCAN_FIXTURE_STRESS_ENGINES.

// (No .serialized needed: the process-global embed-variant slot these tests
// once had to guard was removed — the variant is now passed explicitly
// through makeKey per-job; codex post-merge #2.)
struct AdaFaceMigrationTests {

    /// Fresh throwaway suite per test; removed on exit. Tests NEVER touch
    /// UserDefaults.standard (settings-pollution rule).
    private func withSuite<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "vs-test-adaface-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    // MARK: Persisted engine preference migration

    @Test func storedDlibPreferenceMigratesOnRestore() throws {
        try withSuite { defaults in
            // Exactly what a pre-#144 plist contains for a dlib user.
            defaults.set("dlib/Python (accurate)", forKey: "pf_recognitionEngine")
            let s = PersonFinderSettings.restored(from: defaults)
            #expect(s.recognitionEngine == .adaface,
                    "Saved dlib selection must land on AdaFace, not vanish")
        }
    }

    @Test func storedLegacyHybridPreferenceMigratesOnRestore() throws {
        try withSuite { defaults in
            defaults.set("Hybrid (Vision + dlib fallback)", forKey: "pf_recognitionEngine")
            let s = PersonFinderSettings.restored(from: defaults)
            #expect(s.recognitionEngine == .hybrid,
                    "Old hybrid token maps to the renamed hybrid seat")
        }
    }

    @Test func poisonedEnginePreferenceDegradesToVision() throws {
        try withSuite { defaults in
            defaults.set("💥 not an engine 💥", forKey: "pf_recognitionEngine")
            let s = PersonFinderSettings.restored(from: defaults)
            #expect(s.recognitionEngine == .vision,
                    "Garbage plist value must degrade to .vision, same as pre-#144")
        }
    }

    @Test func missingEngineKeyKeepsDefault() throws {
        try withSuite { defaults in
            #expect(PersonFinderSettings.restored(from: defaults).recognitionEngine == .vision)
        }
    }

    // MARK: adafaceThreshold persistence

    @Test func adafaceThresholdDefaultsAndRoundTrips() throws {
        #expect(PersonFinderSettings().adafaceThreshold == 0.30)
        try withSuite { defaults in
            // Missing key → struct default.
            #expect(PersonFinderSettings.restored(from: defaults).adafaceThreshold == 0.30)
            // Round trip.
            var s = PersonFinderSettings()
            s.adafaceThreshold = 0.42
            s.save(to: defaults)
            #expect(PersonFinderSettings.restored(from: defaults).adafaceThreshold == 0.42)
        }
    }

    @Test func poisonedCosineThresholdsClampOnRestore() throws {
        // A non-numeric plist value decodes as 0.0 via UserDefaults.float —
        // an unclamped 0.0 cosine threshold makes EVERY face a match.
        try withSuite { defaults in
            defaults.set("garbage", forKey: "pf_adafaceThreshold")
            defaults.set(-3.0, forKey: "pf_arcfaceThreshold")
            let s = PersonFinderSettings.restored(from: defaults)
            #expect(s.adafaceThreshold >= 0.05,
                    "Poisoned adafaceThreshold must clamp above the match-everything floor")
            #expect(s.arcfaceThreshold >= 0.05,
                    "Poisoned arcfaceThreshold must clamp too (same pre-existing flaw, fixed together)")
        }
        try withSuite { defaults in
            defaults.set(7.5, forKey: "pf_adafaceThreshold")
            #expect(PersonFinderSettings.restored(from: defaults).adafaceThreshold <= 0.95)
        }
        // In-band values pass through untouched.
        try withSuite { defaults in
            defaults.set(Float(0.42), forKey: "pf_adafaceThreshold")
            #expect(PersonFinderSettings.restored(from: defaults).adafaceThreshold == 0.42)
        }
    }

    // MARK: Poisoned thresholds through EVERY assignment path (codex adversarial #42)
    //
    // The clamp choke point is the PersonFinderSettings property didSet —
    // plist restore, POI profile apply, bundle import, eval CLI, and UI all
    // assign through it. The one direct-read bypass (restoreFromCache reads
    // POIProfile.thresholdForEngine before any settings overlay) clamps in
    // that accessor.

    @Test func poisonedProfileApplyClampsThresholds() {
        let profile = POIProfile(
            name: "T", referencePath: "/tmp/refs",
            engine: RecognitionEngine.adaface.rawValue,
            arcfaceThreshold: 7.7,     // absurd high
            adafaceThreshold: -9.0     // codex's adversarial value
        )
        var s = PersonFinderSettings()
        s.applyProfile(profile)
        #expect(s.adafaceThreshold == 0.05,
                "adafaceThreshold=-9 through applyProfile must clamp to the floor, not match every face")
        #expect(s.arcfaceThreshold == 0.95,
                "arcfaceThreshold=7.7 through applyProfile must clamp to the ceiling")
    }

    @Test func poisonedProfileDirectReadClampsThresholds() {
        // restoreFromCache reads the profile's thresholds directly (no
        // settings overlay) when rebuilding cache keys — the accessor must
        // clamp too or a hand-edited profile.json poisons the key namespace.
        let profile = POIProfile(
            name: "T", referencePath: "/tmp/refs",
            arcfaceThreshold: -3.0, adafaceThreshold: -9.0
        )
        #expect(profile.thresholdForEngine(.adaface) == 0.05)
        #expect(profile.thresholdForEngine(.arcface) == 0.05)
        // Vision threshold is NOT a cosine and keeps its own semantics.
        #expect(profile.thresholdForEngine(.vision) == profile.visionThreshold)
    }

    @Test func poisonedBundleImportClampsThresholds() throws {
        // Imported settings snapshot with hostile values — decode succeeds,
        // apply() lands them on the didSet choke point.
        let json = """
        {"version":1,"savedAt":700000000,"personName":"Donna","threshold":0.5,
         "minFaceConfidence":0.55,"frameStep":5,"pad":2,"minDuration":1,
         "minPresenceSecs":5,"requirePrimary":false,"concurrency":8,
         "skipBundles":false,"skipCatalogBadFiles":true,"largestFaceOnly":false,
         "previewRate":5,"arcfaceThreshold":-42.0,"adafaceThreshold":9000.0,
         "recognitionEngine":"AdaFace (CoreML)"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(SettingsSnapshot.self, from: Data(json.utf8))
        var target = PersonFinderSettings()
        snapshot.apply(to: &target)
        #expect(target.arcfaceThreshold == 0.05, "Bundle import must clamp the floor side")
        #expect(target.adafaceThreshold == 0.95, "Bundle import must clamp the ceiling side")
    }

    // MARK: POIProfile JSON compatibility (additive field)

    @Test func profileJSONWithoutAdafaceThresholdDecodesWithDefault() throws {
        // A profile.json written before #144 — no adafaceThreshold key.
        let legacyJSON = """
        {"name":"Donna","referencePath":"/tmp/refs",
         "engine":"dlib/Python (accurate)","visionThreshold":0.5,
         "arcfaceThreshold":0.4}
        """
        let profile = try JSONDecoder().decode(POIProfile.self, from: Data(legacyJSON.utf8))
        #expect(profile.adafaceThreshold == 0.30, "Missing key → default, load never bricks")

        // And applying it lands the engine on AdaFace with the default knob.
        var s = PersonFinderSettings()
        s.applyProfile(profile)
        #expect(s.recognitionEngine == .adaface)
        #expect(s.adafaceThreshold == 0.30)
    }

    @Test func profileRoundTripsAdafaceThreshold() throws {
        var s = PersonFinderSettings()
        s.personName = "Donna"
        s.recognitionEngine = .adaface
        s.adafaceThreshold = 0.35
        let profile = s.toProfile()
        #expect(profile.engine == RecognitionEngine.adaface.rawValue)
        #expect(profile.adafaceThreshold == 0.35)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(decoded.adafaceThreshold == 0.35)
        #expect(decoded.thresholdForEngine(.adaface) == 0.35)
    }

    // MARK: Cache-key backend separation (#144 — embeddings must be backend-keyed)

    @Test func cacheKeysDifferAcrossBackendsForSameVideo() throws {
        // Same video, person, threshold, refs — only the engine differs.
        // The keys MUST differ or AdaFace results would be served from
        // ArcFace rows (cross-backend vector confusion at the results level).
        let tmp = NSTemporaryDirectory() + "adaface_cachekey_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var arcSettings = PersonFinderSettings(); arcSettings.recognitionEngine = .arcface
        var adaSettings = PersonFinderSettings(); adaSettings.recognitionEngine = .adaface
        let arc = PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .arcface,
            threshold: 0.40, refFilenames: ["a.jpg"],
            embedVariant: PersonFinderCache.embedVariant(for: arcSettings))
        let ada = PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .adaface,
            threshold: 0.40, refFilenames: ["a.jpg"],
            embedVariant: PersonFinderCache.embedVariant(for: adaSettings))
        let arcKey = try #require(arc)
        let adaKey = try #require(ada)
        #expect(arcKey.engine != adaKey.engine,
                "Engine column must separate backend rows in the per-video cache")
    }

    // MARK: Portable settings snapshot (codex post-merge blocker 4)

    @Test func settingsSnapshotRoundTripsAdafaceThreshold() throws {
        var s = PersonFinderSettings()
        s.adafaceThreshold = 0.37
        s.arcfaceThreshold = 0.44
        s.recognitionEngine = .adaface

        let data = try JSONEncoder().encode(SettingsSnapshot(from: s))
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        var target = PersonFinderSettings()   // defaults: ada 0.30 / arc 0.40
        decoded.apply(to: &target)
        #expect(target.adafaceThreshold == 0.37,
                "Imported snapshot must carry adafaceThreshold, not reset to default")
        #expect(target.arcfaceThreshold == 0.44)
        #expect(target.recognitionEngine == .adaface)
    }

    @Test func preAdafaceSnapshotKeepsTargetThreshold() throws {
        // A snapshot exported before the field existed — no adafaceThreshold
        // key. Decode must succeed and apply() must leave the target's
        // current value untouched (mirror of the nil-means-no-change rule).
        let legacyJSON = """
        {"version":1,"savedAt":700000000,"personName":"Donna","threshold":0.5,
         "minFaceConfidence":0.55,"frameStep":5,"pad":2,"minDuration":1,
         "minPresenceSecs":5,"requirePrimary":false,"concurrency":8,
         "skipBundles":false,"skipCatalogBadFiles":true,"largestFaceOnly":false,
         "previewRate":5,"arcfaceThreshold":0.41,
         "recognitionEngine":"dlib/Python (accurate)"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(SettingsSnapshot.self, from: Data(legacyJSON.utf8))

        var target = PersonFinderSettings()
        target.adafaceThreshold = 0.33   // user's local tune must survive import
        snapshot.apply(to: &target)
        #expect(target.adafaceThreshold == 0.33,
                "Missing key in old snapshot must not clobber the local value")
        #expect(target.recognitionEngine == .adaface,
                "Snapshot engine token migrates like every other persisted token")
    }

    // MARK: Hybrid cache keying (QA #144 merge condition)
    //
    // Hybrid rows carry only the VISION threshold in the key's threshold
    // column, but the AdaFace fallback consumes adafaceThreshold and the
    // model checkpoint. embedVariant must fold both in, or moving the
    // AdaFace slider re-serves stale hybrid rows and a checkpoint bump
    // never busts them.

    @Test func hybridEmbedVariantChangesWithAdafaceThreshold() {
        var s = PersonFinderSettings()
        s.recognitionEngine = .hybrid
        s.adafaceThreshold = 0.30
        let v30 = PersonFinderCache.embedVariant(for: s)
        s.adafaceThreshold = 0.35
        let v35 = PersonFinderCache.embedVariant(for: s)
        #expect(v30 != v35,
                "Hybrid variant must change when the AdaFace fallback threshold changes")
        #expect(v30.contains(FaceEmbeddingBackend.adafaceCacheVariant),
                "Hybrid variant must carry the AdaFace model-version token so a checkpoint bump busts hybrid rows")
        // Alignment toggle is part of the embedding shape too.
        s.arcfaceLandmarkAlignment = true
        #expect(PersonFinderCache.embedVariant(for: s) != v35)
    }

    @Test func embedVariantPreservesLegacyNamespaces() {
        var s = PersonFinderSettings()
        // Vision: always "" (legacy rows stay valid).
        s.recognitionEngine = .vision
        #expect(PersonFinderCache.embedVariant(for: s).isEmpty)
        // ArcFace unaligned: "" (legacy); aligned: the historical lm-v1 token.
        s.recognitionEngine = .arcface
        #expect(PersonFinderCache.embedVariant(for: s).isEmpty)
        s.arcfaceLandmarkAlignment = true
        #expect(PersonFinderCache.embedVariant(for: s) == "lm-v1")
    }

    @Test func hybridCacheKeyRefHashChangesWithAdafaceThreshold() throws {
        // Full-path proof through makeKey: same video/person/refs/threshold
        // column, hybrid engine — different adafaceThreshold must yield a
        // different refHash. Variant passed explicitly (no global anymore).
        let tmp = NSTemporaryDirectory() + "hybrid_key_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var s = PersonFinderSettings()
        s.recognitionEngine = .hybrid
        s.adafaceThreshold = 0.30
        let key30 = try #require(PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .hybrid,
            threshold: s.thresholdForEngine(.hybrid), refFilenames: ["a.jpg"],
            embedVariant: PersonFinderCache.embedVariant(for: s)))

        s.adafaceThreshold = 0.35
        let key35 = try #require(PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .hybrid,
            threshold: s.thresholdForEngine(.hybrid), refFilenames: ["a.jpg"],
            embedVariant: PersonFinderCache.embedVariant(for: s)))

        #expect(key30.threshold == key35.threshold,
                "Precondition: hybrid's key threshold column is Vision's, unchanged")
        #expect(key30.refHash != key35.refHash,
                "Hybrid refHash must change with adafaceThreshold or stale rows get served")
    }

    // MARK: Legacy dlib replay arm (codex post-merge blocker 3)

    /// `--engine dlib` must keep replaying historical manifests through the
    /// ISOLATED CLI arm — while staying impossible to reach from Search
    /// (not a RecognitionEngine case; the registry sensor covers the UI).
    @Test func engineDlibParsesAsIsolatedLegacyArm() throws {
        let opts = try PersonEvaluationCLI.parse([
            "--person-eval", "--engine", "dlib", "--person", "Donna",
            "--references", "/tmp", "--video", "/tmp/x.mov"
        ])
        #expect(opts.legacyDlib, "Historical dlib manifests must stay replayable")
        #expect(opts.engine == .vision,
                "The registry engine stays at its default — dlib is CLI-only")
        #expect(!RecognitionEngine.allCases.contains {
            $0.displayName.lowercased() == "dlib"
        }, "The legacy token must NOT resurrect a registry seat")
    }

    @Test func legacyDlibToolingFlagsParse() throws {
        let opts = try PersonEvaluationCLI.parse([
            "--person-eval", "--engine", "dlib", "--person", "Donna",
            "--references", "/tmp", "--video", "/tmp/x.mov",
            "--python-path", "/opt/venv/bin/python",
            "--recognition-script", "/repo/scripts/face_recognize.py"
        ])
        #expect(opts.pythonPath == "/opt/venv/bin/python")
        #expect(opts.recognitionScript == "/repo/scripts/face_recognize.py")
    }

    @Test func unknownEngineTokenStillRejected() {
        // The legacy carve-out is for exactly "dlib" — everything else
        // unknown keeps failing loudly, same as before.
        #expect(throws: (any Error).self) {
            _ = try PersonEvaluationCLI.parse([
                "--person-eval", "--engine", "skynet", "--person", "D",
                "--references", "/tmp", "--video", "/tmp/x.mov"
            ])
        }
    }

    @Test func adafaceEngineTokenStillParses() throws {
        let opts = try PersonEvaluationCLI.parse([
            "--person-eval", "--engine", "adaface", "--person", "Donna",
            "--references", "/tmp", "--video", "/tmp/x.mov"
        ])
        #expect(opts.engine == .adaface)
        #expect(!opts.legacyDlib)
    }

    // MARK: Per-job variant through makeKey (codex post-merge blocker 2)

    /// A restored/rehydrated job must produce IDENTICAL cache keys to the
    /// live scan that wrote the rows. The descriptor persists the variant
    /// verbatim (no reconstruction logic to drift); pre-#144 descriptors
    /// decode with nil → the legacy "" namespace.
    @Test @MainActor func restoredDescriptorReproducesLiveCacheKeys() throws {
        let tmp = NSTemporaryDirectory() + "restore_key_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Live hybrid job with a tuned AdaFace fallback threshold.
        var s = PersonFinderSettings()
        s.personName = "Donna"
        s.recognitionEngine = .hybrid
        s.adafaceThreshold = 0.35
        let liveKey = try #require(PersonFinderCache.makeKey(
            videoPath: tmp, personName: s.personName, engine: .hybrid,
            threshold: s.thresholdForEngine(.hybrid), refFilenames: ["a.jpg"],
            embedVariant: PersonFinderCache.embedVariant(for: s)))

        // Persist via the production descriptor builder, JSON round-trip it
        // (what ScanJobsStorage does), then rebuild the key the way
        // rehydrateResultsFromCache does.
        let job = ScanJob(searchPath: "/tmp")
        job.assignedEngine = .hybrid
        let descriptor = PersonFinderModel.makeDescriptor(from: job, settings: s)
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(PersistedJobDescriptor.self, from: data)

        let restoredKey = try #require(PersonFinderCache.makeKey(
            videoPath: tmp, personName: s.personName,
            engine: RecognitionEngine.migratePersisted(decoded.engine) ?? .vision,
            threshold: decoded.threshold, refFilenames: ["a.jpg"],
            embedVariant: decoded.embedVariant ?? ""))

        #expect(restoredKey == liveKey,
                "Restored job must reproduce the live scan's cache keys exactly")

        // Pre-#144 descriptor (no embedVariant key) → legacy "" namespace.
        var legacyJSON = try #require(String(data: data, encoding: .utf8))
        legacyJSON = legacyJSON.replacingOccurrences(
            of: "\"embedVariant\":\"\(descriptor.embedVariant ?? "")\",", with: "")
        legacyJSON = legacyJSON.replacingOccurrences(
            of: ",\"embedVariant\":\"\(descriptor.embedVariant ?? "")\"", with: "")
        let legacy = try JSONDecoder().decode(
            PersistedJobDescriptor.self, from: Data(legacyJSON.utf8))
        #expect(legacy.embedVariant == nil,
                "Old descriptors decode with nil variant (callers fall back to \"\")")
    }

    /// Two concurrent jobs with different engines/thresholds can never
    /// cross-pollute keys: with the variant passed explicitly, interleaved
    /// key construction is pure — each key equals its isolated recompute.
    @Test func interleavedJobsProduceIndependentCacheKeys() throws {
        let tmp = NSTemporaryDirectory() + "interleave_key_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var jobA = PersonFinderSettings()   // AdaFace, tuned threshold
        jobA.recognitionEngine = .adaface
        jobA.adafaceThreshold = 0.42
        var jobB = PersonFinderSettings()   // Hybrid, different tuning
        jobB.recognitionEngine = .hybrid
        jobB.adafaceThreshold = 0.25

        func keyFor(_ s: PersonFinderSettings) -> PersonFinderCache.CacheKey? {
            PersonFinderCache.makeKey(
                videoPath: tmp, personName: "Donna",
                engine: s.recognitionEngine,
                threshold: s.thresholdForEngine(s.recognitionEngine),
                refFilenames: ["a.jpg"],
                embedVariant: PersonFinderCache.embedVariant(for: s))
        }

        // Interleave: A, B, A, B — the old global slot would have left the
        // second A keyed with B's variant (last-writer-wins).
        let a1 = try #require(keyFor(jobA))
        let b1 = try #require(keyFor(jobB))
        let a2 = try #require(keyFor(jobA))
        let b2 = try #require(keyFor(jobB))

        #expect(a1 == a2, "Job A's keys must be identical regardless of B's interleaving")
        #expect(b1 == b2, "Job B's keys must be identical regardless of A's interleaving")
        #expect(a1.refHash != b1.refHash,
                "Different engine/threshold configs must land in different namespaces")
    }
}
