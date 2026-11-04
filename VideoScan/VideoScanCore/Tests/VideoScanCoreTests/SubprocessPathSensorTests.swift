// SubprocessPathSensorTests.swift — SENSOR: one PATH rule for every child
// process (rule 4; 2026-11-03: the helper's Python worker inherited
// launchd's PATH and every era unit failed on a bare `ffmpeg`).
//   * every production line that sets a child's PATH gets it from the one
//     builder (`augmentedPathWithHomebrew(` in the app, `SubprocessEnvironment.`
//     in Core) — no hand-built "/opt/homebrew/bin:…" anywhere else;
//   * every production file that configures a PythonClipWorker also builds
//     its environment with `SubprocessEnvironment.mediaTools(`.
// Reads the repo's own Swift sources (app, Core, the helper); fixtures and
// tests are not production.

import Foundation
import Testing

@Suite("SENSOR — one PATH rule for child processes")
struct SubprocessPathSensorTests {

    /// …/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/<this file> → the repo's VideoScan/ folder.
    static var sourceRoots: [URL] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return ["VideoScan", "VideoScanBackground", "VideoScanCore/Sources"].map { url.appendingPathComponent($0) }
    }

    /// (repo-relative-ish path, text) of every production .swift file.
    static func productionSources() -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for root in sourceRoots {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walk where file.pathExtension == "swift" {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    out.append((root.lastPathComponent + "/" + file.lastPathComponent, text))
                }
            }
        }
        return out
    }

    /// The PATH rule over one file's text (pure, so the mutation tests below feed it).
    static func pathOffenders(_ name: String, _ text: String) -> [String] {
        var offenders: [String] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if code.contains("\"/opt/homebrew/bin:") { offenders.append("\(name):\(i + 1) builds a Homebrew PATH by hand") }
            // A subscript write or a dictionary-literal key (Codex #232 F7).
            guard code.contains("[\"PATH\"] =") || code.contains("\"PATH\":") else { continue }
            let window = lines[i..<min(lines.count, i + 3)].joined(separator: " ")
            if !(window.contains("augmentedPathWithHomebrew(") || window.contains("SubprocessEnvironment.")) {
                offenders.append("\(name):\(i + 1) sets PATH without the one builder: \(code)")
            }
        }
        return offenders
    }

    /// The worker rule over one file's text: true when a PythonClipWorker is configured without the media-tools environment.
    /// Counted per construction, not per file (Codex #232 F7): every
    /// `PythonClipWorker.Configuration(…)` / `.repo(…)` needs its own `mediaTools(` call.
    static func configuresAWorkerWithoutMediaTools(_ text: String) -> Bool {
        let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        func occurrences(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        let built = occurrences("PythonClipWorker.Configuration.repo(") + occurrences("PythonClipWorker.Configuration(")
        return built > occurrences("SubprocessEnvironment.mediaTools(")
    }

    @Test func everyChildPATHComesFromTheOneBuilder() throws {
        let sources = Self.productionSources()
        try #require(sources.count > 500, "the walk found the app's sources (\(sources.count) files)")
        let offenders = sources.filter { $0.name != "Sources/SubprocessEnvironment.swift" }.flatMap { Self.pathOffenders($0.name, $0.text) }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func everyPythonClipWorkerConfigurationGetsTheMediaToolsEnvironment() throws {
        let configuring = Self.productionSources().filter { name, text in
            name != "Sources/PythonClipWorker.swift"
                && (text.contains("PythonClipWorker.Configuration.repo(") || text.contains("PythonClipWorker.Configuration("))
        }
        try #require(!configuring.isEmpty, "the era factory configures a worker (BackgroundJob.swift)")
        let missing = configuring.filter { Self.configuresAWorkerWithoutMediaTools($0.text) }.map(\.name)
        #expect(missing.isEmpty, "a worker started without the media-tools environment inherits launchd's PATH: \(missing)")
    }

    /// Codex #232 F7: the rules catch what they claim (mutations of real shapes).
    @Test func theRulesCatchTheirMutations() {
        #expect(!Self.pathOffenders("m.swift", "p.environment = [\"PATH\": \"/usr/bin\"]").isEmpty, "a dictionary-literal PATH")
        #expect(!Self.pathOffenders("m.swift", "env[\"PATH\"] = \"/usr/bin\"").isEmpty)
        #expect(Self.pathOffenders("m.swift", "env[\"PATH\"] = augmentedPathWithHomebrew(inheriting: nil)").isEmpty)
        let two = """
            var a = try PythonClipWorker.Configuration.repo(r, factory: f)
            a.environment = try SubprocessEnvironment.mediaTools(inheriting: e)
            let b = PythonClipWorker.Configuration(python: p, script: s, factory: f)
            """
        #expect(Self.configuresAWorkerWithoutMediaTools(two), "a second worker with no environment beside one that has it")
        #expect(!Self.configuresAWorkerWithoutMediaTools("""
            var a = try PythonClipWorker.Configuration.repo(r, factory: f)
            a.environment = try SubprocessEnvironment.mediaTools(inheriting: e)
            """))
    }
}
