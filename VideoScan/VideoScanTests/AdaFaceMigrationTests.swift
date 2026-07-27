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

        let arc = PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .arcface,
            threshold: 0.40, refFilenames: ["a.jpg"])
        let ada = PersonFinderCache.makeKey(
            videoPath: tmp, personName: "Donna", engine: .adaface,
            threshold: 0.40, refFilenames: ["a.jpg"])
        let arcKey = try #require(arc)
        let adaKey = try #require(ada)
        #expect(arcKey.engine != adaKey.engine,
                "Engine column must separate backend rows in the per-video cache")
    }
}
