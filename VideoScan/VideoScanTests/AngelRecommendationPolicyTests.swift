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
}
