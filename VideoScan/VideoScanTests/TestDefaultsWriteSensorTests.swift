// TestDefaultsWriteSensorTests.swift — source sensor (2026-11-25).
//
// A hosted test's standard defaults ARE the app's real domain
// (Rick-Breen.VideoScan): the sealed home does not move them, because cfprefsd
// writes the real user's ~/Library/Preferences whatever HOME /
// CFFIXED_USER_HOME say. Tests that set the Ollama hosts key to a poison and
// "restored" it in a `defer` left Rick's real value at "poison.invalid" when
// their suites crossed in parallel. TestPreferences.swift is the replacement
// (an in-memory override, a scratch suite, a read of the real plist).
//
// This sensor holds the line in every test source — the app tests, the UI
// tests, VideoScanCore's tests — and in scripts/, tests/ and tools/:
//
//   1. no mutating call on the standard instance (set…, removeObject,
//      set/removePersistentDomain, set/removeVolatileDomain);
//   2. no binding of the standard instance to a name (`let d = UserDefaults
//      .standard` hides every later `d.set` from rule 1 — read it in place);
//   3. no `defaults:` argument of `.standard` (hands the real domain to code
//      under test that may write it);
//   4. no UserDefaults suite, and no persistent-domain write, naming the app's
//      bundle domain;
//   5. no `defaults write|delete|import|rename` of the app's domain in a script.
//
// ALLOW-LIST (each entry: file, rule, why — nothing else is exempt):
//   * TestPreferences.swift, rule 1 — its set/removeVolatileDomain calls ARE
//     the in-memory override (the volatile argument domain is never persisted).
//   * ArchiveAngelFacadeTests.swift, rule 3 — passes the real domain on purpose
//     to prove ArchiveAngel's test-host gate refuses to write it, and asserts
//     the value is unchanged.
//   * this file — its patterns and fixtures spell the forbidden shapes.
//
// (C++: a lint rule over the test tree, run as a unit test so it gates merges.)

import Foundation
import Testing

@Suite("Tests never write the app's real preferences")
struct TestDefaultsWriteSensorTests {

    struct Rule: Sendable {
        let id: Int
        let what: String
        let pattern: String
    }

    static let appDomain = #"Rick-Breen\.VideoScan(?![\w.])"#

    static let swiftRules: [Rule] = [
        Rule(id: 1, what: "mutates the standard instance",
             pattern: #"UserDefaults\s*\.\s*standard\s*\.\s*(set\w*|removeObject|removePersistentDomain|removeVolatileDomain)\s*\("#),
        Rule(id: 2, what: "binds the standard instance to a name",
             pattern: #"\b(let|var)\s+\w+\s*(:\s*UserDefaults\s*=\s*(UserDefaults\s*)?|=\s*UserDefaults\s*)\.\s*standard\b(?!\s*\.)"#),
        Rule(id: 3, what: "passes the standard instance as a defaults argument",
             pattern: #"\b\w*[dD]efaults\w*\s*:\s*(UserDefaults)?\s*\.standard\b"#),
        Rule(id: 4, what: "names the app's bundle domain as a suite or persistent domain",
             pattern: #"(UserDefaults\s*\(\s*suiteName:|PersistentDomain\s*\([^)]*forName:)\s*(""# + appDomain
                 + #""|Bundle\.main\.bundleIdentifier|TestPreferences\.appDomain)"#),
    ]

    static let scriptRule = Rule(
        id: 5, what: "a defaults write/delete of the app's domain",
        pattern: #"defaults["',\s]+(write|delete|import|rename)["',\s]+("# + appDomain + #"|\$\{?APP_DEFAULTS)"#)

    /// (file name, rule id) pairs that are exempt — see the header for why.
    static let allowed: Set<String> = [
        "TestPreferences.swift#1",
        "ArchiveAngelFacadeTests.swift#3",
        "TestDefaultsWriteSensorTests.swift#1", "TestDefaultsWriteSensorTests.swift#2",
        "TestDefaultsWriteSensorTests.swift#3", "TestDefaultsWriteSensorTests.swift#4",
        "TestDefaultsWriteSensorTests.swift#5",
    ]

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // VideoScanTests/
        .deletingLastPathComponent()        // VideoScan/ (project dir)
        .deletingLastPathComponent()        // repo root

    /// Every file under `relative` (from the repo root) with one of `extensions`.
    static func files(under relative: String, extensions: Set<String>) -> [URL] {
        let root = repoRoot.appendingPathComponent(relative, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in walk where extensions.contains(url.pathExtension) {
            if url.path.contains("/.build/") || url.path.contains("/__pycache__/") { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    static let swiftTestRoots = ["VideoScan/VideoScanTests", "VideoScan/VideoScanUITests",
                                 "VideoScan/VideoScanCore/Tests"]
    static let scriptRoots = ["scripts", "tests", "tools"]

    /// `file:line: what` for every match of `rules` in `text` not on the allow-list.
    static func violations(in text: String, file: String, rules: [Rule]) -> [String] {
        var out: [String] = []
        for rule in rules where !allowed.contains("\(file)#\(rule.id)") {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else {
                out.append("\(file): rule \(rule.id) does not compile")
                continue
            }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text) else { continue }
                let line = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                out.append("\(file):\(line): rule \(rule.id), \(rule.what): \(text[r])")
            }
        }
        return out
    }

    @Test("no test source writes the app's real preferences (rules 1–4)")
    func swiftTestSourcesNeverWriteTheRealDomain() throws {
        var scanned = 0
        var found: [String] = []
        for root in Self.swiftTestRoots {
            for url in Self.files(under: root, extensions: ["swift"]) {
                let code = SourceTree.strippingComments(try String(contentsOf: url, encoding: .utf8))
                found += Self.violations(in: code, file: url.lastPathComponent, rules: Self.swiftRules)
                scanned += 1
            }
        }
        #expect(scanned > 1_000, "read only \(scanned) test sources — the walk lost the tree")
        #expect(found.isEmpty, Comment(rawValue: """
            A test wrote (or may write) the app's real preferences — a hosted test's standard \
            defaults are Rick's plist, the sealed home does not redirect them. Use \
            TestPreferences.overriding/begin (in memory), TestPreferences.scratch (a throwaway suite) \
            or TestPreferences.persistedAppValue (a read):
            \(found.joined(separator: "\n"))
            """))
    }

    @Test("no script or Python test writes the app's defaults domain (rule 5)")
    func scriptsNeverWriteTheRealDomain() throws {
        var scanned = 0
        var found: [String] = []
        for root in Self.scriptRoots {
            for url in Self.files(under: root, extensions: ["py", "sh", "zsh", "bash"]) {
                let text = try String(contentsOf: url, encoding: .utf8)
                found += Self.violations(in: text, file: url.lastPathComponent, rules: [Self.scriptRule])
                scanned += 1
            }
        }
        #expect(scanned > 100, "read only \(scanned) scripts — the walk lost the tree")
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    /// The rules catch the shapes the 2026-11-25 tests used, and pass the
    /// shapes TestPreferences offers — so a green scan is not a blind one.
    @Test("the rules catch every forbidden shape and pass the allowed ones")
    func rulesCatchTheForbiddenShapes() {
        let std = "UserDefaults" + ".standard"
        let forbidden: [(String, Int)] = [
            ("\(std).set(\"x\", forKey: k)", 1),
            ("\(std).removeObject(forKey: k)", 1),
            ("\(std) . setValue(1, forKey: k)", 1),
            ("\(std).removePersistentDomain(forName: n)", 1),
            ("let defaults = \(std)", 2),
            ("var d: UserDefaults = \(std)", 2),
            ("let d: UserDefaults = .standard", 2),
            ("env(root, defaults: .standard)", 3),
            ("Store(userDefaults: \(std))", 3),
            ("UserDefaults(suiteName: \"Rick-Breen.VideoScan\")", 4),
            ("UserDefaults(suiteName: Bundle.main.bundleIdentifier)", 4),
            ("d.setPersistentDomain([:], forName: \"Rick-Breen.VideoScan\")", 4),
        ]
        for (text, id) in forbidden {
            let hits = Self.violations(in: text, file: "Fixture.swift", rules: Self.swiftRules)
            #expect(hits.contains { $0.contains("rule \(id),") }, Comment(rawValue: "missed: \(text)"))
        }
        let scripts = ["defaults write Rick-Breen.VideoScan archivist.ollamaHosts x",
                       "[\"defaults\", \"delete\", \"Rick-Breen.VideoScan\", \"k\"]",
                       "defaults write \"$APP_DEFAULTS\" k v"]
        for text in scripts {
            #expect(!Self.violations(in: text, file: "fixture.sh", rules: [Self.scriptRule]).isEmpty,
                    Comment(rawValue: "missed: \(text)"))
        }
        let fine = [
            "let v = \(std).string(forKey: k)",
            "#expect(\(std).object(forKey: k) == nil)",
            "let p = TestPreferences.scratch(\"x\"); p.defaults.set(1, forKey: k)",
            "TestPreferences.overriding([k: \"v\"]) { }",
            "UserDefaults(suiteName: \"VideoScanTests.x.\\(UUID())\")",
            "UserDefaults(suiteName: \"Rick-Breen.VideoScanTests.scratch\")",
            "Logger(subsystem: \"Rick-Breen.VideoScan\", category: \"x\")",
        ]
        for text in fine {
            #expect(Self.violations(in: text, file: "Fixture.swift", rules: Self.swiftRules).isEmpty,
                    Comment(rawValue: "false alarm: \(text)"))
        }
        #expect(Self.violations(in: "defaults read Rick-Breen.VideoScan archivist.ollamaModel",
                                file: "fixture.sh", rules: [Self.scriptRule]).isEmpty)
    }
}
