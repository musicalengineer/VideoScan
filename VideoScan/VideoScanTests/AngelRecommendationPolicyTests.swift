// AngelRecommendationPolicyTests.swift
// The recommendation-policy seam (consolidation S2; Rick 2026-09-22: "the AA
// selection criteria should be easily programmable…"). Pins:
//   LOGIC     the default reproduces today's rules exactly (bundled JSON ==
//             built-in == ArchiveAngelWeights.standard); validation refuses
//             nonsense with a reason;
//   ISOLATION a poisoned override (bad JSON, other schema, bad numbers,
//             unreadable) is refused, logged, and the defaults are used; the
//             loader never creates a file; a test host never points at Rick's
//             real App Support policy.json;
//   SENSOR    an override actually reaches the scorer through the façade (the
//             seam is wired, not decorative).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel recommendation policy — default = today, overrides refused unless sound", .serialized)
@MainActor
struct ArchiveAngelRecommendationPolicyTests {

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("angel-policy-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var bundledURL: URL? {
        Bundle.main.url(forResource: AngelRecommendationPolicy.bundledResourceName, withExtension: "json")
    }

    @Test("the bundled default ships in the app and decodes to exactly the built-in rules (= ArchiveAngelWeights.standard)")
    func bundledEqualsBuiltIn() throws {
        let url = try #require(bundledURL, "ArchiveAngelPolicy.default.json is in the app bundle")
        let decoded = try JSONDecoder().decode(AngelRecommendationPolicy.self, from: Data(contentsOf: url))
        #expect(decoded == AngelRecommendationPolicy.builtIn)
        #expect(decoded.weights == ArchiveAngelWeights.standard)
        #expect(decoded.schemaVersion == AngelRecommendationPolicy.currentSchemaVersion)
        #expect(AngelRecommendationPolicy.builtIn.validationProblems().isEmpty)
    }

    @Test("with no override the loader uses the bundled default, silently")
    func noOverride() throws {
        let dir = try tempDir("none")
        defer { try? FileManager.default.removeItem(at: dir) }
        let override = dir.appendingPathComponent("policy.json")
        let loaded = AngelRecommendationPolicy.load(overrideURL: override, bundledURL: bundledURL)
        #expect(loaded.source == .bundled)
        #expect(loaded.policy == .builtIn)
        #expect(loaded.notices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: override.path), "the loader never creates policy.json")
        let bare = AngelRecommendationPolicy.load(overrideURL: override, bundledURL: nil)
        #expect(bare.source == .builtIn && bare.policy == .builtIn && bare.notices.isEmpty)
    }

    @Test("a sound override is used and announced by name")
    func soundOverride() throws {
        let dir = try tempDir("ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = AngelRecommendationPolicy.builtIn
        p.name = "tapes first"
        p.weights.minimumDurationSeconds = 30
        let url = dir.appendingPathComponent("policy.json")
        try p.encodedJSON().write(to: url)
        let loaded = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: bundledURL)
        #expect(loaded.source == .userOverride)
        #expect(loaded.policy.weights.minimumDurationSeconds == 30)
        #expect(loaded.notices.count == 1)
        #expect(loaded.notices.first?.contains("tapes first") == true)
    }

    @Test("POISONED: bad JSON, another schema, bad numbers or an unreadable file are refused with a reason; the defaults run", arguments: [
        "not json at all",
        #"{"schemaVersion": 99, "name": "future", "weights": {}}"#,
        "SCHEMA2",
        "NUMBERS",
        "UNREADABLE",
    ])
    func poisonedOverrideRefused(kind: String) throws {
        let dir = try tempDir("bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        switch kind {
        case "SCHEMA2":
            var p = AngelRecommendationPolicy.builtIn
            p.schemaVersion = 2
            try p.encodedJSON().write(to: url)
        case "NUMBERS":
            var p = AngelRecommendationPolicy.builtIn
            p.weights.fatigueFactor = 0
            p.weights.freshShare = 2
            p.weights.minimumDurationSeconds = -1
            try p.encodedJSON().write(to: url)
        case "UNREADABLE":
            try Data("{}".utf8).write(to: url)
            read = { u in
                if u == url { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: u)
            }
        default:
            try Data(kind.utf8).write(to: url)
        }
        let loaded = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: bundledURL, read: read)
        #expect(loaded.source == .bundled, "\(kind): fell back to the bundled default")
        #expect(loaded.policy == .builtIn)
        #expect(loaded.notices.count == 1)
        #expect(loaded.notices.first?.contains("refused") == true, "\(loaded.notices)")
        if kind == "NUMBERS" {
            let why = loaded.notices.first ?? ""
            #expect(why.contains("fatigueFactor") && why.contains("freshShare") && why.contains("minimumDurationSeconds"))
        }
    }

    @Test("validation names every out-of-range number (a typo cannot make every clip 'too short')")
    func validation() {
        var p = AngelRecommendationPolicy.builtIn
        p.weights.minimumDurationSeconds = 2 * 86_400
        p.weights.restAfterSkips = .infinity
        p.weights.twoStars = -1
        p.weights.sceneSeconds = 5_000   // above longSceneSeconds
        let problems = p.validationProblems()
        #expect(problems.contains { $0.contains("minimumDurationSeconds") })
        #expect(problems.contains { $0.contains("restAfterSkips") })
        #expect(problems.contains { $0.contains("twoStars") })
        #expect(problems.contains { $0.contains("duration tiers") })
    }

    @Test("ISOLATION: under a test host the environment never points at Rick's real policy.json, buffer or evidence")
    func testHostPaths() {
        let env = AngelEnvironment.app
        #expect(env.isTestHost)
        #expect(!env.policyOverrideURL.path.contains("/Library/Application Support/"))
        #expect(env.bufferRoot == ArchiveAngelPlanStore.testHostBufferRoot)
        #expect(!env.bufferRoot.path.contains("/Movies/VideoScan Buffer"))
        #expect(env.evidenceDirectory == AngelEnvironment.testHostEvidenceDirectory)
        #expect(env.defaults == UserDefaults.standard, "same defaults object as before S2")
        // The production formula is unchanged.
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(AngelEnvironment.productionBufferRoot(home: home).path == "/Users/someone/Movies/VideoScan Buffer/ArchiveAngel")
        #expect(AngelEnvironment.productionAngelSupportDirectory().path.hasSuffix("/Application Support/VideoScan/archive-angel"))
    }

    // MARK: SENSOR — an override reaches the scorer through the façade

    /// One 90-second clip: under today's 2-minute floor it is `.tooShort`;
    /// with a policy whose floor is 30 s it is graded.
    private func ninetySecondClipModel(_ dir: URL) throws -> (VideoScanModel, VideoRecord, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-policy-sensor")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let file = dir.appendingPathComponent("Family/clip_ninety.mov")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        let r = VideoRecord()
        r.filename = file.lastPathComponent
        r.fullPath = file.path
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.isPlayable = "Yes"
        r.durationSeconds = 90
        r.sizeBytes = 90 * 3_000_000 / 8     // 3 Mbit/s — clears the proxy floor
        r.starRating = 2
        model.records = [r]
        return (model, r, sb.root)
    }

    private func environment(root: URL, policy: URL) -> AngelEnvironment {
        var env = AngelEnvironment.app
        env.bufferRoot = root.appendingPathComponent("Buffer", isDirectory: true)
        env.evidenceDirectory = root.appendingPathComponent("evidence", isDirectory: true)
        env.policyOverrideURL = policy
        return env
    }

    @Test("SENSOR: the façade's policy is what the sweep scores with (default: 90 s is too short; override 30 s: graded)")
    func overrideReachesTheSweep() async throws {
        let dir = try tempDir("sensor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, rec, sandbox) = try ninetySecondClipModel(dir)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let plain = ArchiveAngel(model: model, environment: environment(root: dir, policy: dir.appendingPathComponent("absent.json")))
        #expect(plain.policySource == .bundled)
        plain.launch()
        await plain.sweep.runAndWait(reason: "test")
        plain.sweep.stop()
        #expect(plain.evidence(for: rec.id)?.rejection == .tooShort, "today's 2-minute floor")

        var p = AngelRecommendationPolicy.builtIn
        p.name = "short clips welcome"
        p.weights.minimumDurationSeconds = 30
        let url = dir.appendingPathComponent("policy.json")
        try p.encodedJSON().write(to: url)
        let custom = ArchiveAngel(model: model, environment: environment(root: dir, policy: url))
        #expect(custom.policySource == .userOverride)
        custom.launch()
        await custom.sweep.runAndWait(reason: "test")
        custom.sweep.stop()
        let ev = try #require(custom.evidence(for: rec.id))
        #expect(ev.rejection == nil, "the override's 30 s floor reached the scorer — \(ev.summary())")
        #expect(ev.score > 0)
    }

    // MARK: QA 2026-09-22 follow-ups

    @Test("QA RED: points near Int.max pass validation and would trap the scorer's sum/product (AngelRecommendationPolicy.swift:88)")
    func hugePointsRefused() {
        var p = AngelRecommendationPolicy.builtIn
        p.weights.threeStars = Int.max
        #expect(!p.validationProblems().isEmpty)
        var q = AngelRecommendationPolicy.builtIn
        q.weights.confirmedPersonEach = Int.max / 2 + 1
        #expect(!q.validationProblems().isEmpty)
    }

    @Test("every numeric field is bounded: out-of-range seconds, bitrates, days and skips are all named")
    func everyFieldBounded() {
        var p = AngelRecommendationPolicy.builtIn
        p.weights.explicitPickMinimumDurationSeconds = 1e12
        p.weights.downloadMinimumDurationSeconds = .nan
        p.weights.downloadMaxKilobitsPerSecond = 1e15
        p.weights.restDays = 1e9
        p.weights.restAfterSkips = 1e9
        p.weights.junkFloor = Int.max
        p.weights.recentPhoneClipYears = Int.min
        let problems = p.validationProblems().joined(separator: "\n")
        for name in ["explicitPickMinimumDurationSeconds", "downloadMinimumDurationSeconds", "downloadMaxKilobitsPerSecond",
                     "restDays", "restAfterSkips", "junkFloor", "recentPhoneClipYears"] {
            #expect(problems.contains(name), "\(name) is range-checked")
        }
    }

    @Test("DEFENCE IN DEPTH: the scorer saturates instead of trapping even with a policy validation would refuse")
    func scorerSaturates() {
        var w = ArchiveAngelWeights.standard
        w.threeStars = Int.max
        w.confirmedPersonEach = Int.max / 2 + 1
        w.confirmedPersonCap = Int.max
        w.dateKnown = Int.max
        let c = ArchiveAngelCandidate(durationSeconds: 7_200, starRating: 3, confirmedPeople: ["A", "B", "C"],
                                      userDate: "1994")
        guard case .eligible(let score, _) = ArchiveAngelScorer.verdict(c, weights: w) else {
            Issue.record("expected eligible"); return
        }
        #expect(score == Int.max)
        #expect(ArchiveAngelScorer.sum(Int.max, 1) == Int.max)
        #expect(ArchiveAngelScorer.sum(Int.min, -1) == Int.min)
        #expect(ArchiveAngelScorer.product(Int.max / 2 + 1, 3) == Int.max)
        #expect(ArchiveAngelScorer.product(-(Int.max / 2), 3) == Int.min)
        #expect(ArchiveAngelScorer.clampedInt(.infinity) == Int.max && ArchiveAngelScorer.clampedInt(.nan) == 0)
        #expect(ArchiveAngelScorer.clampedInt(41.0) == 41, "in range: identical to Int(_:)")
    }

    @Test("NIT: unknown keys in policy.json are named once, and the file is still used")
    func unknownKeysNamed() throws {
        let dir = try tempDir("unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        var obj = try #require(try JSONSerialization.jsonObject(with: AngelRecommendationPolicy.builtIn.encodedJSON()) as? [String: Any])
        obj["comment"] = "mine"
        var w = try #require(obj["weights"] as? [String: Any])
        w["threeStar"] = 150          // typo of threeStars
        obj["weights"] = w
        let url = dir.appendingPathComponent("policy.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        let loaded = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: bundledURL)
        #expect(loaded.source == .userOverride)
        let warn = loaded.notices.filter { $0.contains("does not read") }
        #expect(warn.count == 1)
        #expect(warn.first?.contains("comment") == true && warn.first?.contains("weights.threeStar") == true)
    }

    @Test("fingerprint: stable, and different for any change")
    func fingerprint() {
        #expect(AngelRecommendationPolicy.builtIn.fingerprint == AngelRecommendationPolicy.defaultFingerprint)
        #expect(AngelRecommendationPolicy().fingerprint == AngelRecommendationPolicy.builtIn.fingerprint)
        var p = AngelRecommendationPolicy.builtIn
        p.weights.minimumDurationSeconds = 119
        #expect(p.fingerprint != AngelRecommendationPolicy.defaultFingerprint)
        #expect(AngelRecommendationPolicy.defaultFingerprint.count == 16)
    }

    @Test("evidence.json is tied to the policy: same → loads; unstamped + default → loads (no forced re-score on upgrade); unstamped or other stamp + custom policy → ignored and logged")
    func evidenceTiedToPolicy() async throws {
        let dir = try tempDir("evidence")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let record = ArchiveAngelEvidenceRecord(score: 120, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date())
        var custom = AngelRecommendationPolicy.builtIn
        custom.weights.minimumDurationSeconds = 30

        func write(_ stamp: String?) async {
            let file = ArchiveAngelEvidenceFile(records: [id: record], policyFingerprint: stamp)
            _ = await ArchiveAngelEvidenceStore.saveOffMain(file, to: dir.appendingPathComponent(ArchiveAngelEvidenceStore.filename))
        }
        func loads(under fingerprint: String) async -> (Bool, [String]) {
            let store = ArchiveAngelEvidenceStore(directory: dir, policyFingerprint: fingerprint)
            var lines: [String] = []
            store.log = { lines.append($0) }
            return (await store.load(), lines)
        }

        await write(nil)
        #expect(await loads(under: AngelRecommendationPolicy.defaultFingerprint).0, "an old file + the default policy: kept")
        let (unstampedCustom, why) = await loads(under: custom.fingerprint)
        #expect(!unstampedCustom)
        #expect(why.first?.contains("policy changed: unstamped (default) → \(custom.fingerprint)") == true, "\(why)")

        await write(custom.fingerprint)
        #expect(await loads(under: custom.fingerprint).0)
        let (other, why2) = await loads(under: AngelRecommendationPolicy.defaultFingerprint)
        #expect(!other)
        #expect(why2.first?.contains("policy changed: \(custom.fingerprint) → \(AngelRecommendationPolicy.defaultFingerprint)") == true)
    }

    @Test("the sweep stamps the evidence it writes with its store's policy fingerprint")
    func sweepStamps() async throws {
        let dir = try tempDir("stamp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir, policyFingerprint: "feedfacefeedface")
        let sweep = ArchiveAngelSweep(store: store)
        var cfg = ArchiveAngelSweep.Configuration(candidates: { [ArchiveAngelCandidate()] }, isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.quietSeconds = 0
        sweep.configure(cfg, enabled: true)
        await sweep.runAndWait(reason: "test")
        sweep.stop()
        #expect(store.file?.policyFingerprint == "feedfacefeedface")
    }
}
