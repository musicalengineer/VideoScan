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

    @Test func everyChildPATHComesFromTheOneBuilder() throws {
        let sources = Self.productionSources()
        try #require(sources.count > 500, "the walk found the app's sources (\(sources.count) files)")
        var offenders: [String] = []
        for (name, text) in sources where name != "Sources/SubprocessEnvironment.swift" {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains("\"/opt/homebrew/bin:") { offenders.append("\(name):\(i + 1) builds a Homebrew PATH by hand") }
                guard code.contains("[\"PATH\"] =") else { continue }
                let window = lines[i..<min(lines.count, i + 3)].joined(separator: " ")
                if !(window.contains("augmentedPathWithHomebrew(") || window.contains("SubprocessEnvironment.")) {
                    offenders.append("\(name):\(i + 1) sets PATH without the one builder: \(code)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func everyPythonClipWorkerConfigurationGetsTheMediaToolsEnvironment() throws {
        let configuring = Self.productionSources().filter { name, text in
            name != "Sources/PythonClipWorker.swift"
                && (text.contains("PythonClipWorker.Configuration.repo(") || text.contains("PythonClipWorker.Configuration("))
        }
        try #require(!configuring.isEmpty, "the era factory configures a worker (BackgroundJob.swift)")
        let missing = configuring.filter { !$0.text.contains("SubprocessEnvironment.mediaTools(") }.map(\.name)
        #expect(missing.isEmpty, "a worker started without the media-tools environment inherits launchd's PATH: \(missing)")
    }
}
