// SuiteDiscovery.swift
//
// Scans VideoScanTests/**/*.swift for `@Suite` declarations and auto-registers
// a TestEntry per suite. This keeps TestDriver in sync with the test target
// without manual edits — add a new @Suite, relaunch TestDriver, it appears.

import Foundation

enum SuiteDiscovery {

    static var testSourceDir: String {
        VideoScanTests.projectDir + "/VideoScan/VideoScanTests"
    }

    struct DiscoveredSuite {
        let name: String
        let relativePath: String
        let group: TestGroup
        let module: String
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
        let root = URL(fileURLWithPath: testSourceDir, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

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

        let files = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            guard url.pathExtension == "swift" else { return nil }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }

        for url in files {
            let relativePath = Self.relativePath(of: url, under: root)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(content.startIndex..., in: content)
            let group = Self.group(for: relativePath)
            let module = Self.moduleName(for: relativePath)

            for match in suitePattern.matches(in: content, range: range) {
                guard let r = Range(match.range(at: 1), in: content) else { continue }
                let name = String(content[r])
                if seen.insert(name).inserted {
                    suites.append(DiscoveredSuite(name: name,
                                                  relativePath: relativePath,
                                                  group: group,
                                                  module: module))
                }
            }

            let hasTest = testAnnotation.firstMatch(in: content, range: range) != nil
            if hasTest {
                for match in barePattern.matches(in: content, range: range) {
                    guard let r = Range(match.range(at: 1), in: content) else { continue }
                    let name = String(content[r])
                    if seen.insert(name).inserted {
                        suites.append(DiscoveredSuite(name: name,
                                                      relativePath: relativePath,
                                                      group: group,
                                                      module: module))
                    }
                }
            }
        }
        return suites
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func group(for relativePath: String) -> TestGroup {
        let components = relativePath.split(separator: "/").map(String.init)
        if relativePath.localizedCaseInsensitiveContains("Performance") { return .performance }
        if components.contains("StressTests") ||
            relativePath.localizedCaseInsensitiveContains("StressTests") {
            return .stress
        }
        if relativePath.localizedCaseInsensitiveContains("Regression") { return .regression }
        if relativePath.localizedCaseInsensitiveContains("Integration") { return .integration }
        return .unit
    }

    private static func moduleName(for relativePath: String) -> String {
        let withoutExtension = (relativePath as NSString).deletingPathExtension
        let components = withoutExtension.split(separator: "/").map(String.init)
        if components.count <= 1 { return components.first ?? "VideoScanTests" }
        return components.dropLast().joined(separator: " / ")
    }

    static func registerDiscoveredSuites(excluding manualSuites: Set<String> = []) {
        let discovered = scan()
        let entries: [TestEntry] = discovered.compactMap { suite -> TestEntry? in
            if manualSuites.contains(suite.name) { return nil }

            return TestEntry(
                group: suite.group,
                module: suite.module,
                name: suite.name,
                description: "Auto-discovered from \(suite.relativePath)",
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
