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

    @Test("the bundled file is byte-identical to the built-in rules' encoding (on a mismatch the expected JSON is written to the temp dir)")
    func bundledBytesMatch() throws {
        let url = try #require(bundledURL)
        let expected = try AngelRecommendationPolicy.builtIn.encodedJSON() + Data("\n".utf8)
        let actual = try Data(contentsOf: url)
        if actual != expected {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveAngelPolicy.default.expected.json")
            try expected.write(to: out)
            print("[angel-policy] bundled default is stale — expected JSON written to \(out.path)")
        }
        #expect(actual == expected, "regenerate ArchiveAngelPolicy.default.json from AngelRecommendationPolicy.builtIn")
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
        "SCHEMA3",
        "NUMBERS",
        "UNREADABLE",
    ])
    func poisonedOverrideRefused(kind: String) throws {
        let dir = try tempDir("bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        switch kind {
        case "SCHEMA3":
            var p = AngelRecommendationPolicy.builtIn
            p.schemaVersion = 3
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

    // MARK: S3b — schema 2: rules as data, addable and removable

    private func loadJSON(_ json: String, label: String) throws -> AngelRecommendationPolicy.Loaded {
        let dir = try tempDir(label)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: url)
        return AngelRecommendationPolicy.load(overrideURL: url, bundledURL: bundledURL)
    }

    @Test("a schema-1 file (weights only) is read: its weights, today's rules for the rest, and a notice")
    func schemaOneMigrated() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: AngelRecommendationPolicy.builtIn.encodedJSON()) as? [String: Any])
        var w = try #require(obj["weights"] as? [String: Any])
        w["minimumDurationSeconds"] = 30.0
        w.removeValue(forKey: "playHistoryPerDoubling")      // schema 1 never had it
        obj = ["schemaVersion": 1, "name": "old tapes", "weights": w]
        let loaded = try loadJSON(String(bytes: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8) ?? "", label: "v1")
        #expect(loaded.source == .userOverride)
        #expect(loaded.policy.schemaVersion == AngelRecommendationPolicy.currentSchemaVersion)
        #expect(loaded.policy.weights.minimumDurationSeconds == 30)
        #expect(loaded.policy.weights.playHistoryPerDoubling == 4, "a missing field takes the default")
        #expect(loaded.policy.floors == AngelRecommendationPolicy.builtIn.floors)
        #expect(loaded.notices.contains { $0.contains("schema 1") }, "\(loaded.notices)")
    }

    @Test("a partial override: only what it names changes; rule lists merge by id (edit in place, disable, add)")
    func partialAndMergeByID() throws {
        let loaded = try loadJSON(#"""
        {"schemaVersion": 2, "name": "partial",
         "weights": {"minimumDurationSeconds": 300},
         "floors": [{"id": "recentPhoneClip", "enabled": false}],
         "signals": [{"id": "boost", "kind": "match", "when": [{"field": "starRating", "op": ">=", "value": 1}],
                      "points": 7, "line": "starred"}],
         "grades": {"a": 120}}
        """#, label: "partial")
        #expect(loaded.source == .userOverride, "\(loaded.notices)")
        let p = loaded.policy
        let base = AngelRecommendationPolicy.builtIn
        #expect(p.weights.minimumDurationSeconds == 300 && p.weights.threeStars == base.weights.threeStars)
        #expect(p.floors.map(\.id) == base.floors.map(\.id), "edited in place — order kept")
        #expect(p.floors.first { $0.id == "recentPhoneClip" }?.enabled == false)
        #expect(p.floors.first { $0.id == "recentPhoneClip" }?.kind == "recentPhoneClip", "the kind survives the merge")
        let ids = p.signals.map(\.id)
        #expect(ids.firstIndex(of: "boost") == ids.firstIndex(of: "downloadCap").map { $0 - 1 }, "a new signal goes before the cap")
        #expect(p.grades == AngelGradeBands(a: 120, b: 60, c: 25, d: 1))
        #expect(p.recommend == base.recommend)
    }

    @Test("POISONED rules refuse the WHOLE file with the reason named — unknown kind, unknown field, a kind in the wrong list, a bad pattern, grades that do not rise", arguments: [
        (#"{"schemaVersion": 2, "floors": [{"id": "x", "kind": "frobnicate", "when": [{"field": "starRating", "op": ">", "value": 0}]}]}"#, "unknown kind \"frobnicate\""),
        (#"{"schemaVersion": 2, "floors": [{"id": "x", "kind": "match", "when": [{"field": "lenght", "op": "<", "value": 5}]}]}"#, "unknown field \"lenght\""),
        (#"{"schemaVersion": 2, "signals": [{"id": "x", "kind": "tooShort"}]}"#, "does not belong in signals"),
        (#"{"schemaVersion": 2, "floors": [{"id": "x", "kind": "match", "whne": []}]}"#, "needs at least one condition"),
        (#"{"schemaVersion": 2, "tables": {"appCacheNamePattern": "(unclosed"}}"#, "not a valid regular expression"),
        (#"{"schemaVersion": 2, "grades": {"a": 50, "b": 60}}"#, "grades must rise"),
        (#"{"schemaVersion": 2, "recommend": {"classes": [{"class": "maybe"}]}}"#, "unknown class"),
        (#"{"schemaVersion": 2, "recommend": {"classes": [{"class": "ready", "when": [{"field": "grade", "op": "==", "value": "E"}]}]}}"#, "is not a grade"),
        (#"{"name": "no version"}"#, "no \"schemaVersion\""),
    ])
    func poisonedRulesRefused(json: String, reason: String) throws {
        let loaded = try loadJSON(json, label: "poison")
        #expect(loaded.source == .bundled, "\(json)")
        #expect(loaded.policy == .builtIn)
        #expect(loaded.notices.count == 1)
        #expect(loaded.notices.first?.contains(reason) == true, "\(loaded.notices)")
    }

    // The three worked examples of docs/archive_angel_policy.md, verbatim.

    static let exampleUnderFive = #"""
    {
      "schemaVersion": 2,
      "name": "Rick: nothing under 5 minutes",
      "floors": [
        { "id": "underFiveMinutes", "kind": "match",
          "when": [ { "field": "durationMinutes", "op": "<", "value": 5 } ],
          "line": "Under 5 minutes — usually a piece of a longer original",
          "explicitPicks": false }
      ]
    }
    """#

    static let exampleDonna = #"""
    {
      "schemaVersion": 2,
      "name": "Rick: Donna first",
      "signals": [
        { "id": "donna", "kind": "match",
          "when": [ { "any": [ { "field": "people", "op": "contains", "value": "Donna" },
                               { "field": "machinePeople", "op": "contains", "value": "Donna" } ] } ],
          "points": 40, "line": "Donna is in it" }
      ]
    }
    """#

    static let examplePhone2020s = #"""
    {
      "schemaVersion": 2,
      "name": "Rick: no 2020s phone clips",
      "floors": [
        { "id": "phone2020s", "kind": "match",
          "when": [ { "field": "isPhoneClip", "op": "==", "value": true },
                    { "field": "captureYear", "op": ">=", "value": 2020 } ],
          "line": "A 2020s phone clip" }
      ]
    }
    """#

    @Test("WORKED EXAMPLE 1: never recommend clips under 5 minutes — a 4-minute clip is excluded with the rule's words; an explicit pick still goes")
    func exampleOne() throws {
        let loaded = try loadJSON(Self.exampleUnderFive, label: "ex1")
        #expect(loaded.source == .userOverride, "\(loaded.notices)")
        let p = loaded.policy
        let clip = ArchiveAngelCandidate(sizeBytes: 240 * 3_000_000 / 8, durationSeconds: 240, starRating: 3)
        let hit = ArchiveAngelScorer.floorHit(clip, policy: p)
        #expect(hit?.rejection == .policyRule && hit?.rule.displayLine.hasPrefix("Under 5 minutes") == true)
        #expect(ArchiveAngelScorer.hardFloor(clip, policy: .builtIn) == nil, "the default lets it through")
        #expect(ArchiveAngelScorer.hardFloor(clip, policy: p.forExplicitPicks()) == nil, "explicitPicks: false")
    }

    @Test("WORKED EXAMPLE 2: boost anything with Donna — +40, printed, before the download cap")
    func exampleTwo() throws {
        let p = try loadJSON(Self.exampleDonna, label: "ex2").policy
        let withDonna = ArchiveAngelCandidate(durationSeconds: 600, detectedPeople: ["Donna"])
        guard case .eligible(let score, let lines) = ArchiveAngelScorer.verdict(withDonna, policy: p),
              case .eligible(let plain, _) = ArchiveAngelScorer.verdict(withDonna, policy: .builtIn) else {
            Issue.record("expected eligible"); return
        }
        #expect(score == plain + 40)
        #expect(lines.contains { $0.line == "Donna is in it" && $0.points == 40 })
    }

    @Test("WORKED EXAMPLE 3: ignore 2020s phone clips — even a hand-picked one (the built-in 10-year rule spares explicit picks; this rule does not)")
    func exampleThree() throws {
        let p = try loadJSON(Self.examplePhone2020s, label: "ex3").policy
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let clip2021 = ArchiveAngelCandidate(durationSeconds: 600, deviceModel: "iPhone 12",
                                             captureDate: Date(timeIntervalSince1970: 1_620_000_000))
        #expect(ArchiveAngelScorer.hardFloor(clip2021, policy: p.forExplicitPicks(), now: now) == .policyRule)
        #expect(ArchiveAngelScorer.hardFloor(clip2021, policy: AngelRecommendationPolicy.builtIn.forExplicitPicks(), now: now) == nil)
        let clip2012 = ArchiveAngelCandidate(durationSeconds: 600, deviceModel: "iPhone 4S",
                                             captureDate: Date(timeIntervalSince1970: 1_340_000_000))
        #expect(ArchiveAngelScorer.hardFloor(clip2012, policy: p, now: now) == nil)
    }

    @Test("ISOLATION: a poisoned policy.json handed to a test-host façade is refused and logged, the bundled rules run, and nothing is written to the real App Support folder")
    func poisonedFacadeIsolated() async throws {
        let dir = try tempDir("iso")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = AngelEnvironment.productionAngelSupportDirectory().appendingPathComponent("policy.json")
        let realBefore = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        let bad = dir.appendingPathComponent("policy.json")
        try Data(#"{"schemaVersion": 2, "floors": [{"id": "x", "kind": "frobnicate"}]}"#.utf8).write(to: bad)
        let (model, _, sandbox) = try ninetySecondClipModel(dir)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let angel = ArchiveAngel(model: model, environment: environment(root: dir, policy: bad))
        #expect(angel.policySource == .bundled)
        #expect(angel.policy == .builtIn)
        angel.launch()
        await angel.sweep.runAndWait(reason: "test")
        angel.sweep.stop()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("evidence/evidence.json").path),
                "evidence went to the injected folder")
        let realAfter = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        #expect(realBefore == realAfter, "the real policy.json is never created or touched")
    }
}
