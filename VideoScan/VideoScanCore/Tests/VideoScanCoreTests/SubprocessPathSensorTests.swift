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
    /// `text` with string literals (plain, multi-line, raw `#"…"#`), block
    /// comments (nested) and line comments blanked to spaces, newlines kept
    /// (Codex #233 F2, #234: documentation is not code). A tiny Swift lexer;
    /// string interpolation is blanked with its string (it cannot hold a
    /// worker configuration that matters here). O(n) over the characters.
    static func codeOnly(_ text: String) -> String {
        let c = Array(text)
        var out = c
        var i = 0
        func blank(_ from: Int, _ to: Int) {
            for k in from..<min(to, c.count) where c[k] != "\n" { out[k] = " " }
        }
        func at(_ k: Int, _ word: String) -> Bool {
            let w = Array(word)
            return k + w.count <= c.count && Array(c[k..<(k + w.count)]) == w
        }
        while i < c.count {
            if at(i, "//") {
                var e = i
                while e < c.count, c[e] != "\n" { e += 1 }
                blank(i, e); i = e
            } else if at(i, "/*") {
                var depth = 0, e = i
                repeat {
                    if at(e, "/*") { depth += 1; e += 2 } else if at(e, "*/") { depth -= 1; e += 2 } else { e += 1 }
                } while depth > 0 && e < c.count
                blank(i, e); i = e
            } else if c[i] == "#" || c[i] == "\"" {
                var hashes = 0, q = i
                while q < c.count, c[q] == "#" { hashes += 1; q += 1 }
                guard q < c.count, c[q] == "\"" else { i = q; continue }
                let multi = at(q, "\"\"\"")
                let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                var e = q + (multi ? 3 : 1)
                while e < c.count, !at(e, close) {
                    if !multi, c[e] == "\n" { break }
                    e += (hashes == 0 && c[e] == "\\") ? 2 : 1
                }
                e = min(c.count, e + (at(e, close) ? close.count : 0))
                blank(i, e); i = e
            } else {
                i += 1
            }
        }
        return String(out)
    }

    /// Counted per construction, not per file (Codex #232 F7): every
    /// `PythonClipWorker.Configuration(…)` / `.repo(…)` needs its own `mediaTools(` call.
    static func configuresAWorkerWithoutMediaTools(_ text: String) -> Bool {
        let code = codeOnly(text)
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

    /// Codex #233 F2: comments and string literals are not code.
    @Test func commentsAndStringsAreNotCode() {
        #expect(!Self.configuresAWorkerWithoutMediaTools("/** Example: PythonClipWorker.Configuration(python: p) */"), "a doc comment")
        #expect(!Self.configuresAWorkerWithoutMediaTools(#"let s = "PythonClipWorker.Configuration(python: p)""#), "a string")
        #expect(Self.configuresAWorkerWithoutMediaTools("""
            let b = PythonClipWorker.Configuration(python: p, script: s, factory: f) // TODO: SubprocessEnvironment.mediaTools(
            """), "a trailing comment does not supply the environment")
    }

    /// Codex #234: a multi-line string and a nested block comment are not code either.
    @Test func multiLineStringsAndNestedCommentsAreNotCode() {
        let q = String(repeating: "\"", count: 3)
        let multi = "let example = \(q)\nSubprocessEnvironment.mediaTools(inheriting: e)\n\(q)\n"
            + "let b = PythonClipWorker.Configuration(python: p, script: s, factory: f)\n"
        #expect(Self.configuresAWorkerWithoutMediaTools(multi), "the call inside a multi-line string supplies nothing")
        let nested = "/* outer /* inner */ SubprocessEnvironment.mediaTools(inheriting: e) */\n"
            + "let b = PythonClipWorker.Configuration(python: p, script: s, factory: f)\n"
        #expect(Self.configuresAWorkerWithoutMediaTools(nested), "the call inside a nested comment supplies nothing")
        #expect(Self.codeOnly("a /* x /* y */ z */ b").filter { !$0.isWhitespace } == "ab")
    }
}
