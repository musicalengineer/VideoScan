// ModelLabArchitectureSensorTests.swift
// SENSOR (architecture, source-reading — the pre-merge lane): two rule-13
// facts about Sources/VideoScanCore/ModelLab/ pinned as source scans, so a
// later edit cannot drift them quietly:
//   1. no file in the folder names a transport or a URL scheme — no
//      URLSession, NWConnection, the Network framework, or the letters
//      "http" — except the LocalHost validator, whose whole job is to judge a
//      host string. Core's ModelLab types plan, validate and record; they
//      never send.
//   2. every non-local case of `ApproachHost` (the arms of `isLocal` that
//      return false) is spelled by name on `PayloadGate`'s refusal path, so
//      a new host case cannot slip past the gate by being forgotten.
// The behaviour sensors (fake transport, near-miss JSON) stay in
// ModelLabSensorTests and the nightly.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ModelLabArchitectureSensor")
struct ModelLabArchitectureSensorTests {

    private static var modelLabSources: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }          // ModelLab → VideoScanCoreTests → Tests → VideoScanCore
        return url.appendingPathComponent("Sources/VideoScanCore/ModelLab", isDirectory: true)
    }

    private static func files() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: modelLabSources.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: modelLabSources.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func noTransportAndNoURLSchemeOutsideTheLocalHostValidator() throws {
        let files = try Self.files()
        #expect(files.count >= 6, "the folder has the six Phase 0 files")
        let forbidden = ["URLSession", "NWConnection", "import Network", "Network.", "http"]
        for file in files where file.name != "LocalHost.swift" {
            let found = forbidden.filter { file.text.contains($0) }
            #expect(found.isEmpty, Comment(rawValue: "\(file.name) names a transport or a URL scheme: \(found)"))
        }
        let validator = try #require(files.first { $0.name == "LocalHost.swift" }).text
        #expect(validator.contains("https://") && validator.contains("return nil"), "the validator is where https is judged, and it refuses it")
        #expect(!validator.contains("URLSession") && !validator.contains("NWConnection") && !validator.contains("import Network"))
    }

    @Test func everyNonLocalHostCaseIsNamedOnTheGateRefusalPath() throws {
        let registry = try #require(try Self.files().first { $0.name == "ApproachRegistry.swift" }).text
        // The enum's cases.
        let hostEnum = try #require(Self.body(of: "public enum ApproachHost", in: registry))
        let caseNames = Self.matches(#"^\s*case (\w+)"#, in: hostEnum)
        #expect(caseNames.sorted() == ["mlxSwift", "ollama", "pythonWorker", "remoteTextOnly"], Comment(rawValue: "\(caseNames)"))
        // The arms of isLocal that return false.
        let isLocal = try #require(Self.body(of: "public var isLocal: Bool", in: hostEnum))
        var nonLocal: Set<String> = []
        for line in isLocal.split(separator: "\n") where line.contains("return") && !line.contains("true") {
            for name in Self.matches(#"\.(\w+)"#, in: String(line)) where caseNames.contains(name) { nonLocal.insert(name) }
        }
        #expect(nonLocal.contains("remoteTextOnly"), Comment(rawValue: "\(nonLocal)"))
        // ollama's arm returns `!hosts.isEmpty`: not a literal true, so it is a (conditionally) non-local case.
        #expect(nonLocal.contains("ollama"), Comment(rawValue: "\(nonLocal)"))
        // Each is spelled on the gate's refusal path.
        let gate = try #require(Self.body(of: "public enum PayloadGate", in: registry))
        let refusalArm = try #require(gate.range(of: "throw .hostNotLocal")).lowerBound
        let before = String(gate[..<refusalArm])
        for name in nonLocal {
            #expect(before.contains(".\(name)"), Comment(rawValue: "PayloadGate.check does not name .\(name) before its hostNotLocal refusal"))
        }
    }

    /// The text from `header` to its matching closing brace.
    private static func body(of header: String, in text: String) -> String? {
        guard let start = text.range(of: header) else { return nil }
        var depth = 0
        var index = start.upperBound
        var opened = false
        while index < text.endIndex {
            let c = text[index]
            if c == "{" { depth += 1; opened = true }
            if c == "}" { depth -= 1; if opened && depth == 0 { return String(text[start.lowerBound...index]) } }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
