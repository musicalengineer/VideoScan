// ArchiveAngelCodex1643Tests.swift
// codex #1643 (independent review of Archive Angel S3, 2026-09-23;
// docs/codex-review-1633-1638-2026-09-23.md, A1–A5). Red first:
//
//   A1  a user regex in policy.json could hang VALIDATION (`^[a1_-]*…b$`)
//       or pass it and hang SCORING on the main actor (`^a*a*…a*b$`) —
//       the policy language now has no regex (AngelStemMatcher);
//   A2  an optional floor recorded first masked the offline SAFETY floor
//       under `useAngelFloors: false` — safety is its own pass now;
//   A3  the badge / class accessor read stored evidence while the counts
//       applied the live refusal — one effective class for all;
//   A4  Prepare filtered by cached class before live keeper selection —
//       a Keep chosen after the sweep now wins before a rescore;
//   A5  policy.json was read whole before the 1 MB cap — bounded read.
//
// Every hang-shaped check runs the work on its own thread with a deadline,
// so a regression FAILS (and the abandoned thread dies with the test
// process) instead of wedging the suite.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Result box for `within` (written once by the worker, read after the signal).
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// `work` on a detached thread; nil when it did not finish within
/// `seconds`. The thread cannot be killed — a regression leaves it
/// spinning until the test process exits, which is the point: the test
/// fails in bounded time.
private func within<T>(_ seconds: Double, _ work: @escaping @Sendable () -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        box.value = work()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("angel-1643-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writePolicy(_ json: String, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("policy.json")
    try Data(json.utf8).write(to: url)
    return url
}

// MARK: - A1 / A5: the policy language and the policy file

@Suite("codex #1643 A1/A5 — no user regex, bounded validation, scoring and file read", .serialized)
struct ArchiveAngelPolicyNoRegexTests {

    /// codex's two patterns, verbatim.
    static let validationHang = #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^[a1_-]*[a1_-]*[a1_-]*[a1_-]*[a1_-]*b$"}}"#
    static let scoringHang = #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^a*a*a*a*a*a*a*a*a*b$"}}"#

    @Test("RED A1: codex's validation-hang pattern is refused — and loading finishes within 2 s",
          arguments: [validationHang, scoringHang])
    func codexPatternsRefused(_ json: String) throws {
        let dir = try tempDir("regex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePolicy(json, in: dir)
        let loaded = within(2) { AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil) }
        guard let loaded else {
            Issue.record("loading \(json) did not finish within 2 s — validation ran an unbounded regex")
            return
        }
        #expect(loaded.source == .builtIn, "the whole file is refused")
        #expect(loaded.notices.contains { $0.contains("appCacheNamePattern") }, "\(loaded.notices)")
        #expect(loaded.policy == .builtIn)
    }

    @Test("RED A1: whatever a catastrophic-pattern override loads as, scoring a 10k-character adversarial stem takes under 2 s")
    func scoringBounded() throws {
        let dir = try tempDir("score")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePolicy(Self.scoringHang, in: dir)
        let adversarial = String(repeating: "a", count: 10_000) + "!"
        let hit = within(2) { () -> Bool in
            let policy = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil).policy
            return ArchiveAngelScorer.looksLikeAppCache(filename: adversarial + ".mov",
                                                        fullPath: "/Volumes/X/" + adversarial + ".mov",
                                                        tables: policy.tables)
        }
        #expect(hit == false, "scoring must finish in bounded time and not call this an app cache (nil = timed out)")
    }

    @Test("SENSOR A5: a policy.json that is not a regular file (a FIFO) is refused without blocking")
    func fifoRefused() throws {
        let dir = try tempDir("fifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        #expect(mkfifo(url.path, 0o600) == 0)
        let loaded = within(2) { AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil) }
        #expect(loaded?.source == .builtIn, "nil = the read blocked")
        #expect(loaded?.notices.first?.contains("refused") == true, "\(String(describing: loaded?.notices))")
    }
}

// MARK: - A2: safety floors are their own pass

@Suite("codex #1643 A2 — a safety floor excludes whatever optional floor fired first", .serialized)
@MainActor
struct ArchiveAngelSafetyPassTests {

    static let dated = Date(timeIntervalSince1970: 773_000_000)   // 1994

    private func sweepOnce(_ candidates: [ArchiveAngelCandidate], policy: AngelRecommendationPolicy,
                           now: Date = Date()) async -> (ArchiveAngelEvidenceStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("angel-1643-sweep-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let store = ArchiveAngelEvidenceStore(directory: dir, policyFingerprint: policy.fingerprint)
        let sweep = ArchiveAngelSweep(store: store)
        var cfg = ArchiveAngelSweep.Configuration(candidates: { candidates }, isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.policy = policy
        cfg.now = { now }
        cfg.quietSeconds = 0
        sweep.configure(cfg, enabled: true)
        await sweep.runAndWait(reason: "test")
        sweep.stop()
        return (store, dir)
    }

    private func noFloors() throws -> AngelRecommendationPolicy {
        let dir = try tempDir("nofloors")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = AngelRecommendationPolicy.load(
            overrideURL: try writePolicy(#"{"schemaVersion":2,"recommend":{"useAngelFloors":false}}"#, in: dir), bundledURL: nil)
        #expect(loaded.source == .userOverride, "\(loaded.notices)")
        #expect(loaded.policy.recommend.useAngelFloors == false)
        return loaded.policy
    }

    @Test("RED A2: codex's case — offline, 30 s, ★★★, dated, useAngelFloors false → Excluded, not Ready")
    func offlineShortStarredExcluded() async throws {
        let p = try noFloors()
        let c = ArchiveAngelCandidate(filename: "tape.mov", fullPath: "/Volumes/Off/tape.mov", durationSeconds: 30,
                                      starRating: 3, volumeOnline: false, captureDate: Self.dated)
        let (store, dir) = await sweepOnce([c], policy: p)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ev = try #require(store.record(for: c.id))
        #expect(ev.rejection == .tooShort, "the displayed reason keeps the policy order")
        #expect(ev.recommendationClass == .excluded, "the offline safety floor holds — \(ev.summary())")
        #expect(!store.candidateIDs.contains(c.id))
    }

    @Test("RED A2: every optional floor that fires before volumeOffline — the offline file is still Excluded")
    func offlineBehindEveryOptionalFloor() async throws {
        let p = try noFloors()
        func offline(_ name: String, _ build: (inout ArchiveAngelCandidate) -> Void) -> ArchiveAngelCandidate {
            var c = ArchiveAngelCandidate(filename: name + ".mov", fullPath: "/Volumes/Off/\(name).mov",
                                          durationSeconds: 1800, starRating: 3, volumeOnline: false,
                                          captureDate: Self.dated)
            build(&c)
            return c
        }
        let cases = [
            offline("short") { $0.durationSeconds = 30 },
            offline("unplayable") { $0.isPlayable = "No" },
            offline("paired") { $0.isPairedHalf = true },
            offline("proxy") { $0.sizeBytes = 1_000 },
            offline("junk") { $0.mediaDisposition = .confirmedJunk },
            offline("extra") { $0.duplicateDisposition = .extraCopy },
            offline("resting") { var att = ArchiveAngelAttention(); att.skipped = [Date(), Date(), Date(), Date()]; $0.attention = att },
        ]
        let (store, dir) = await sweepOnce(cases, policy: p)
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in cases {
            let ev = store.record(for: c.id)
            #expect(ev?.recommendationClass == .excluded, "\(c.filename): \(ev?.summary() ?? "no evidence")")
        }
    }
}

// MARK: - A3: one effective class

@Suite("codex #1643 A3 — badge, class, counts and filter read ONE effective class", .serialized)
@MainActor
struct ArchiveAngelEffectiveClassTests {

    private func model() throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-1643-effective")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    private func ready(_ score: Int) -> ArchiveAngelEvidenceRecord {
        var r = ArchiveAngelEvidenceRecord(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date())
        r.recommendation = .ready
        r.year = 1994
        return r
    }

    @Test("RED A3: a set-aside / purged former Ready loses its Promote me badge with its count")
    func liveRefusalReachesTheBadge() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let recs = ["a.mov", "b.mov"].map { n -> VideoRecord in
            let r = VideoRecord(); r.filename = n; r.fullPath = "/Volumes/T/" + n; return r
        }
        model.records = recs
        let angel = model.archiveAngel
        angel.store.replace(with: ArchiveAngelEvidenceFile(records: [recs[0].id: ready(150), recs[1].id: ready(140)]))
        #expect(angel.badge(for: recs[1].id)?.text == "Promote me")
        recs[1].purgedAt = Date()
        angel.rebuildRecommendations()
        let s = angel.recommendations
        #expect(s.count(.ready) == 1 && !s.candidateIDs.contains(recs[1].id), "the counts apply the live refusal")
        #expect(angel.recommendationClass(for: recs[1].id) == .excluded, "the class accessor agrees with the counts")
        #expect(angel.badge(for: recs[1].id) == nil, "no Promote me on a record the counts excluded")
        #expect(angel.badge(for: recs[0].id)?.text == "Promote me")
    }

    @Test("RED A3: a promoted former Ready shows no Promote me")
    func promotedOverlayReachesTheBadge() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = VideoRecord(); r.filename = "p.mov"; r.fullPath = "/Volumes/T/p.mov"
        model.records = [r]
        let angel = model.archiveAngel
        angel.store.replace(with: ArchiveAngelEvidenceFile(records: [r.id: ready(150)]))
        var s = angel.recommendations
        s.promotedIDs = [r.id]
        angel.publishRecommendations(s)
        #expect(angel.recommendationClass(for: r.id) == .promoted)
        #expect(angel.badge(for: r.id) == nil)
    }
}

// MARK: - A4: Prepare follows a Keep chosen after the sweep

@Suite("codex #1643 A4 — Prepare reclassifies the duplicate group live before the class filter", .serialized)
@MainActor
struct ArchiveAngelPrepareLiveKeeperTests {

    @Test("RED A4: A = Ready, B = Another copy; B marked Keep before a rescore → Prepare takes B")
    func newKeeperWins() async throws {
        let now = Date()
        let g = UUID(), d = Date(timeIntervalSince1970: 773_000_000)
        let a = ArchiveAngelCandidate(filename: "xmas.mov", fullPath: "/Volumes/A/xmas.mov", durationSeconds: 1800,
                                      starRating: 3, confirmedPeople: ["Donna"], duplicateGroupID: g, captureDate: d,
                                      duplicateGroupCount: 2)
        let b = ArchiveAngelCandidate(filename: "xmas.mov", fullPath: "/Volumes/B/xmas.mov", durationSeconds: 1800,
                                      starRating: 3, duplicateGroupID: g, captureDate: d, duplicateGroupCount: 2)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("angel-1643-keeper-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let sweep = ArchiveAngelSweep(store: store)
        var cfg = ArchiveAngelSweep.Configuration(candidates: { [a, b] }, isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.now = { now }
        cfg.quietSeconds = 0
        sweep.configure(cfg, enabled: true)
        await sweep.runAndWait(reason: "test")
        sweep.stop()
        #expect(store.record(for: a.id)?.recommendation == .ready, "\(store.record(for: a.id)?.summary() ?? "-")")
        #expect(store.record(for: b.id)?.recommendation == .anotherCopy, "\(store.record(for: b.id)?.summary() ?? "-")")

        // The person marks B the Keep copy; A stays Review. No rescore.
        var liveB = b
        liveB.duplicateDisposition = .keep
        let live = [a.id: a, b.id: liveB]
        let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 1, now: now) { live[$0] }
        #expect(pick?.selection.picks.map(\.id) == [b.id], "the Keep copy is prepared, not the cached Ready A")

        // Unchanged catalog: the cached decision stands (A).
        let same = ArchiveAngelJob.selectFromEvidence(store: store, count: 1, now: now) { [a.id: a, b.id: b][$0] }
        #expect(same?.selection.picks.map(\.id) == [a.id])
    }
}

// MARK: - A1: the stem matcher (post-fix: the language that replaced the regex)

@Suite("codex #1643 A1 — AngelStemMatcher: parity with the retired regex, linear time, closed language", .serialized)
struct AngelStemMatcherTests {

    /// The retired default — compiled HERE only, as the oracle.
    static let oracle = try! NSRegularExpression(pattern: AngelStemMatcher.retiredDefaultPattern, options: [.caseInsensitive])
    static func oracleMatches(_ s: String) -> Bool {
        oracle.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    let matcher = AngelPolicyTables.standard.appCacheStemMatcher

    @Test("LOGIC: the default names give exactly the retired pattern's answers — nouns × case × separators × digits × line ends × Unicode")
    func parityCorpus() {
        let nouns = AngelPolicyTables.standard.appCacheStemNames
        var variants: [String] = []
        for n in nouns {
            variants += [n, n.uppercased(), n.prefix(1).uppercased() + n.dropFirst(),
                         n.replacingOccurrences(of: "s", with: "\u{017F}"),   // ſ folds to s
                         n.replacingOccurrences(of: "i", with: "\u{0130}"),   // İ does not
                         String(n.dropLast()), n + n]
        }
        let suffixes = ["", "1", "07", "123", " 1", "_1", "-1", "  1", "_", "-", " ", "1a", "a", "\u{0663}", "\u{FF13}",
                        " \u{0663}", "\n", "\r\n", "1\n", "\n\n", "\u{2028}", "\u{0085}", "\r", "x1", "_-1", "1_2",
                        "\u{0301}", "1\u{0301}", " Cod 1998", ".mov"]
        let prefixes = ["", " ", "a", ".", "\u{FEFF}"]
        var checked = 0
        for v in variants {
            for p in prefixes {
                for s in suffixes {
                    let stem = p + v + s
                    #expect(matcher.matches(stem) == Self.oracleMatches(stem), "\(stem.debugDescription)")
                    checked += 1
                }
            }
        }
        #expect(checked > 9_000)
        // The live files the rule was written for (Rick 2026-09-10).
        for s in ["Cache", "Cache-30", "render-12", "proxy_007", "thumb", "TMP", "Thumbnail 3"] { #expect(matcher.matches(s), "\(s)") }
        for s in ["Cache Cod 1998", "Rendering", "tmp_", "proxy--1", "my cache", ""] { #expect(!matcher.matches(s), "\(s)") }
    }

    @Test("LOGIC: seeded fuzz — 20,000 random stems over the pattern's alphabet agree with the retired regex")
    func parityFuzz() {
        var rng = SplitMix64(seed: 1643)
        let alphabet = Array("cachrendpoxyivwtumblTMPCAHRX_- 0123456789\n\r") + ["\u{017F}", "\u{0663}", "\u{212A}", "\u{2028}"]
        let nouns = AngelPolicyTables.standard.appCacheStemNames
        for i in 0..<20_000 {
            var stem = ""
            if i % 3 == 0 { stem = nouns[Int(rng.next() % UInt64(nouns.count))] }
            for _ in 0..<Int(rng.next() % 6) { stem.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
            #expect(matcher.matches(stem) == Self.oracleMatches(stem), "\(stem.debugDescription)")
        }
    }

    @Test("BOUND: the worst table validation allows × a 10k-character adversarial stem — under 250 ms per stem (Debug)")
    func worstCaseBounded() throws {
        let a100 = String(repeating: "a", count: 100)
        let names = (0..<AngelStemMatcher.maxNames).map { i in String(repeating: "a", count: 99) + String(i % 10) }
        var globs: [String] = []
        for i in 0..<AngelStemMatcher.maxGlobs {
            switch i % 4 {
            case 0: globs.append("*" + String(repeating: "a", count: 97) + "b*")   // contains: KMP's worst prefix
            case 1: globs.append(String(a100.dropLast()) + "*")
            case 2: globs.append("*" + String(a100.dropLast()))
            default: globs.append(String(repeating: "a", count: 49) + "*" + String(repeating: "a", count: 49) + "b")
            }
        }
        #expect(AngelStemMatcher.problems(names: names, globs: globs).isEmpty, "the worst VALID table")
        let m = AngelStemMatcher(names: names, numbered: true, globs: globs)
        let stems = [String(repeating: "a", count: 10_000) + "!",
                     String(repeating: "a", count: 99) + String(repeating: "1", count: 10_000),
                     String(repeating: "aab", count: 3_400)]
        for stem in stems {
            let started = ContinuousClock.now
            _ = m.matches(stem)
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < .milliseconds(250), "\(stem.prefix(12))… took \(elapsed)")
        }
        #expect(m.matches(String(repeating: "a", count: 99) + "3" + "_" + String(repeating: "7", count: 5_000)),
                "a numbered noun over a long digit tail still matches")
    }

    @Test("LOGIC: globs — exact, prefix, suffix, pre*post, *contains*; case-insensitive; whole stem")
    func globs() {
        let m = AngelStemMatcher(names: [], numbered: false, globs: ["Render*", "*_PROXY", "clip*final", "*cache*", "exact"])
        for s in ["render", "RENDER 7", "shot_proxy", "Clip 12 final", "my Cache 2", "EXACT"] { #expect(m.matches(s), "\(s)") }
        for s in ["pre-render", "proxy_shot", "clipfina", "cach", "exactly", ""] { #expect(!m.matches(s), "\(s)") }
    }

    @Test("VALIDATION: more than one `*` (unless *text*), only `*`, empty, too long, a `*` in a name, too many entries — each named")
    func validation() {
        let bad = AngelStemMatcher.problems(names: ["ok", "st*r", ""], globs: ["a*b*c", "**", "*", "", String(repeating: "x", count: 101), "*ok*", "ok*"])
        #expect(bad.count == 7, "\(bad)")
        #expect(bad.contains { $0.contains("appCacheStemNames[1]") && $0.contains("`*`") })
        #expect(bad.contains { $0.contains("appCacheStemGlobs[0]") && $0.contains("more than one") })
        #expect(bad.contains { $0.contains("appCacheStemGlobs[2]") && $0.contains("every file") })
        #expect(!AngelStemMatcher.problems(names: Array(repeating: "n", count: 501), globs: []).isEmpty)
        #expect(!AngelStemMatcher.problems(names: [], globs: Array(repeating: "g*", count: 101)).isEmpty)
    }

    private func load(_ json: String) throws -> AngelRecommendationPolicy.Loaded {
        let dir = try tempDir("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        return AngelRecommendationPolicy.load(overrideURL: try writePolicy(json, in: dir), bundledURL: nil)
    }

    @Test("MIGRATION: the retired default pattern (a copied bundled file) is read as the same rule, with a note; a plain anchored alternation too; anything else is refused")
    func retiredPatternMigration() throws {
        let copied = #"{"schemaVersion":2,"name":"copied","tables":{"appCacheNamePattern":"^(cache|render|proxy|proxies|preview|thumb|thumbnail|temp|tmp)([ _-]?\\d+)?$"}}"#
        let a = try load(copied)
        #expect(a.source == .userOverride, "\(a.notices)")
        #expect(a.policy.tables == AngelPolicyTables.standard)
        #expect(a.notices.contains { $0.contains("no longer read") }, "\(a.notices)")
        #expect(!a.notices.contains { $0.contains("does not read") }, "not also listed as an unknown key")

        let plain = try load(#"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^(Scratch|Render Temp)$"}}"#)
        #expect(plain.source == .userOverride, "\(plain.notices)")
        #expect(plain.policy.tables.appCacheStemNames == ["Scratch", "Render Temp"])
        #expect(!plain.policy.tables.appCacheStemNumbered)
        #expect(plain.policy.tables.appCacheStemMatcher.matches("scratch") && !plain.policy.tables.appCacheStemMatcher.matches("scratch1"))

        for json in [#"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^cache.mov$"}}"#,          // `.` is not literal
                     #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"cache|render"}}"#,          // unanchored = contains
                     #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^(a+)+$"}}"#,
                     #"{"schemaVersion":2,"tables":{"appCacheNamePattern":7}}"#,
                     #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"^(x)$","appCacheStemNames":["y"]}}"#] {
            let r = try load(json)
            #expect(r.source == .builtIn, "\(json)")
            #expect(r.notices.first?.contains("appCacheNamePattern") == true, "\(r.notices)")
        }
        let nouns = try load(#"{"schemaVersion":2,"tables":{"appCacheStemNames":["scratch"],"appCacheStemGlobs":["*_proxy"]}}"#)
        #expect(nouns.source == .userOverride && nouns.notices.count == 1, "\(nouns.notices)")
        #expect(ArchiveAngelScorer.looksLikeAppCache(filename: "shot_PROXY.mov", fullPath: "/Volumes/X/shot_PROXY.mov",
                                                     tables: nouns.policy.tables))
    }

    @Test("A5: the reader holds at most maxFileBytes + 1 bytes; a 5 MB file is refused as too large; /dev/zero behind a symlink is refused unread; a symlink to a real policy works")
    func boundedRead() throws {
        let dir = try tempDir("bounded")
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("policy.json")
        try Data(count: 5_000_000).write(to: big)
        let bytes = try AngelRecommendationPolicy.readPolicyFile(big)
        #expect(bytes.count == AngelRecommendationPolicy.maxFileBytes + 1)
        let loaded = AngelRecommendationPolicy.load(overrideURL: big, bundledURL: nil)
        #expect(loaded.source == .builtIn)
        #expect(loaded.notices.first?.contains("more than \(AngelRecommendationPolicy.maxFileBytes) bytes") == true, "\(loaded.notices)")

        let zero = dir.appendingPathComponent("zero.json")
        try FileManager.default.createSymbolicLink(atPath: zero.path, withDestinationPath: "/dev/zero")
        let z = within(2) { AngelRecommendationPolicy.load(overrideURL: zero, bundledURL: nil) }
        #expect(z?.source == .builtIn, "nil = it read /dev/zero")
        #expect(z?.notices.first?.contains("not a regular file") == true, "\(String(describing: z?.notices))")

        let real = dir.appendingPathComponent("real.json")
        try Data(#"{"schemaVersion":2,"name":"linked"}"#.utf8).write(to: real)
        let link = dir.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        #expect(AngelRecommendationPolicy.load(overrideURL: link, bundledURL: nil).policy.name == "linked")
    }

    @Test("OFF-MAIN: loadOffMain reads and validates policy.json off the main thread")
    @MainActor
    func loadsOffMain() async throws {
        let dir = try tempDir("offmain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePolicy(#"{"schemaVersion":2,"name":"off main"}"#, in: dir)
        let onMain = Box<Bool>()
        let loaded = await AngelRecommendationPolicy.loadOffMain(overrideURL: url, bundledURL: nil) { u in
            onMain.value = Thread.isMainThread
            return try AngelRecommendationPolicy.readPolicyFile(u)
        }
        #expect(loaded.policy.name == "off main")
        #expect(onMain.value == false, "the read ran on the main thread")
    }
}

/// Deterministic RNG for the fuzz (≈ splitmix64 from Vigna).
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Scale sensors (100k)

@Suite("codex #1643 — scale sensors: effective class and the live-group pick at 100k", .serialized)
@MainActor
struct ArchiveAngelCodex1643ScaleTests {

    @Test("SENSOR A3: over 100k evidence records the pure effective class agrees with the summary's counts and filter; the summary builds in under 2 s (Debug)")
    func effectiveAgreesAtScale() {
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var refused = Set<UUID>(), prepared = Set<UUID>(), promoted = Set<UUID>()
        let kinds: [ArchiveAngelRecommendationClass] = [.ready, .needsDate, .worthALook, .notNow, .excluded, .anotherCopy]
        for i in 0..<100_000 {
            let id = UUID()
            var r = ArchiveAngelEvidenceRecord(score: i % 150, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date())
            r.recommendation = kinds[i % kinds.count]
            records[id] = r
            if i % 7 == 0 { refused.insert(id) }
            if i % 101 == 0 { prepared.insert(id) }
            if i % 103 == 0 { promoted.insert(id) }
        }
        let live: (UUID) -> String? = { refused.contains($0) ? nil : "f.mov" }
        let started = ContinuousClock.now
        let s = ArchiveAngelRecommendationSummary.make(evidence: records, prepared: prepared, promoted: promoted.subtracting(prepared),
                                                       revision: 1, live: live)
        let elapsed = ContinuousClock.now - started
        var mismatches = 0
        var counts: [ArchiveAngelRecommendationClass: Int] = [:]
        for (id, r) in records {
            guard let e = ArchiveAngelRecommendationSummary.effective(stored: r.recommendationClass, prepared: prepared.contains(id),
                                                                      promoted: promoted.contains(id) && !prepared.contains(id),
                                                                      live: { live(id) }) else { continue }
            if e.kind == .prepared { continue }
            counts[e.kind, default: 0] += 1
            if s.candidateIDs.contains(id) != e.kind.isRecommended { mismatches += 1 }
        }
        #expect(mismatches == 0, "the filter and the effective class disagree on \(mismatches) records")
        for k in ArchiveAngelRecommendationClass.allCases where k != .prepared { #expect(s.count(k) == (counts[k] ?? 0), "\(k)") }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test("SENSOR A4: a 100k-record evidence file, 30k of them in 3-copy groups — the pick of 25 reclassifies groups live in under 2 s (Debug)")
    func liveGroupPickAtScale() {
        let now = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-1643-scale-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var live: [UUID: ArchiveAngelCandidate] = [:]
        let d = Date(timeIntervalSince1970: 773_000_000)
        var group = UUID()
        for i in 0..<100_000 {
            let id = UUID()
            if i % 3 == 0 { group = UUID() }
            let grouped = i < 30_000
            var r = ArchiveAngelEvidenceRecord(score: 100 + (i % 97), lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
            r.recommendation = grouped && i % 3 != 0 ? .anotherCopy : .ready
            r.copyKey = grouped ? "group:" + group.uuidString : nil
            records[id] = r
            live[id] = ArchiveAngelCandidate(id: id, filename: "v\(i).mov", fullPath: "/Volumes/T/v\(i).mov", durationSeconds: 1800,
                                             starRating: 3, duplicateGroupID: grouped ? group : nil, captureDate: d,
                                             duplicateGroupCount: grouped ? 3 : 0,
                                             duplicateDisposition: grouped && i % 3 == 2 ? .keep : .none)
        }
        store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, complete: true, considered: 100_000, eligible: 100_000, records: records))
        let started = ContinuousClock.now
        let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 25, now: now) { live[$0] }
        let elapsed = ContinuousClock.now - started
        #expect(pick?.selection.picks.count == 25)
        for p in pick?.selection.picks ?? [] where p.candidate.duplicateGroupID != nil {
            #expect(p.candidate.duplicateDisposition == .keep, "a grouped pick is the group's Keep copy")
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}
