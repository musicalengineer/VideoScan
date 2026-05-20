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

    static func scan() -> [DiscoveredSuite] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: testSourceDir) else { return [] }

        let pattern = try! NSRegularExpression(
            pattern: #"@Suite[^)]*\s+struct\s+(\w+)"#
        )

        var suites: [DiscoveredSuite] = []
        for file in files.sorted() where file.hasSuffix(".swift") {
            let path = (testSourceDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            let range = NSRange(content.startIndex..., in: content)
            let matches = pattern.matches(in: content, range: range)
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: content) else { continue }
                let name = String(content[nameRange])
                suites.append(DiscoveredSuite(name: name, filename: file))
            }

            // Also catch bare `struct FooTests` without @Suite — Swift Testing
            // discovers these too if they contain @Test methods.
            if matches.isEmpty {
                let barePattern = try! NSRegularExpression(
                    pattern: #"^struct\s+(\w+Tests?)\s*[:{]"#,
                    options: .anchorsMatchLines
                )
                let bareMatches = barePattern.matches(in: content, range: range)
                let hasTestAnnotation = content.contains("@Test ")
                if hasTestAnnotation {
                    for match in bareMatches {
                        guard let nameRange = Range(match.range(at: 1), in: content) else { continue }
                        let name = String(content[nameRange])
                        if !suites.contains(where: { $0.name == name }) {
                            suites.append(DiscoveredSuite(name: name, filename: file))
                        }
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
