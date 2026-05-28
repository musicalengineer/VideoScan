// SuiteDiscovery.swift
//
// Scans VideoScanTests/*.swift for `@Suite` declarations and auto-registers
// a TestEntry per suite. This keeps TestDriver in sync with the test target
// without manual edits — add a new @Suite, relaunch TestDriver, it appears.

import Foundation

enum SuiteDiscovery {

    static let testSourceDir = NSHomeDirectory() + "/dev/VideoScan/VideoScan/VideoScanTests"

    struct DiscoveredSuite {
        let name: String
        let filename: String
    }

    /// Walk every `*.swift` under VideoScanTests and pull out the names
    /// of Swift Testing suites we can address with `-only-testing:`.
    ///
    /// Two passes per file, results deduped by name:
    ///   1. `@Suite ... struct Foo` — including `@Suite("name")`,
    ///      `@Suite(.serialized)`, `@Suite @MainActor`, and multi-line
    ///      forms where `struct` lands on the line after the attribute.
    ///   2. bare `struct FooTests {` declarations in any file that also
    ///      contains `@Test` annotations — Swift Testing discovers these
    ///      without an explicit `@Suite`.
    ///
    /// The old implementation made pass-2 conditional on pass-1 finding
    /// nothing, and used `content.contains("@Test ")` (literal space).
    /// Newer test files use `@Test("name")` / `@Test(.tags(...))`, so
    /// 17 files silently fell out of the registry. Both passes now run
    /// every time and dedupe at the end.
    static func scan() -> [DiscoveredSuite] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: testSourceDir) else { return [] }

        // Pass 1: `@Suite`, optional `(...args...)`, optional `@Modifier`s,
        // then `struct Name`. `[^()]*` (no parens at all in attribute args)
        // matches the common shapes; the optional `(...)` group catches
        // `@Suite("title")` and `@Suite(.serialized)`. `\s+` between
        // tokens includes newlines, so multi-line declarations work.
        let suitePattern = try! NSRegularExpression(
            pattern: #"@Suite(?:\([^)]*\))?(?:\s+@\w+)*\s+struct\s+(\w+)"#
        )
        let barePattern = try! NSRegularExpression(
            pattern: #"^struct\s+(\w+Tests?)\s*[:{]"#,
            options: .anchorsMatchLines
        )
        // `@Test\b` matches `@Test `, `@Test(`, and `@Test\n` — anything
        // that's the `@Test` macro, not a longer identifier like `@TestX`.
        let testAnnotation = try! NSRegularExpression(pattern: #"@Test\b"#)

        var suites: [DiscoveredSuite] = []
        var seen: Set<String> = []

        for file in files.sorted() where file.hasSuffix(".swift") {
            let path = (testSourceDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let range = NSRange(content.startIndex..., in: content)

            for match in suitePattern.matches(in: content, range: range) {
                guard let r = Range(match.range(at: 1), in: content) else { continue }
                let name = String(content[r])
                if seen.insert(name).inserted {
                    suites.append(DiscoveredSuite(name: name, filename: file))
                }
            }

            let hasTest = testAnnotation.firstMatch(in: content, range: range) != nil
            if hasTest {
                for match in barePattern.matches(in: content, range: range) {
                    guard let r = Range(match.range(at: 1), in: content) else { continue }
                    let name = String(content[r])
                    if seen.insert(name).inserted {
                        suites.append(DiscoveredSuite(name: name, filename: file))
                    }
                }
            }
        }
        return suites
    }

    static func registerDiscoveredSuites(excluding manualSuites: Set<String> = []) {
        let discovered = scan()
        let entries: [TestEntry] = discovered.compactMap { suite -> TestEntry? in
            if manualSuites.contains(suite.name) { return nil }

            let moduleName = suite.filename
                .replacingOccurrences(of: ".swift", with: "")

            return TestEntry(
                group: .unit,
                module: moduleName,
                name: suite.name,
                description: "Auto-discovered from \(suite.filename)",
                supportsCoverage: true
            ) { host, log in
                await VideoScanTests.runDiscoveredSuite(
                    suiteName: suite.name,
                    host: host,
                    log: log
                )
            }
        }

        if !entries.isEmpty {
            TestRegistry.shared.register(entries)
        }
    }
}
