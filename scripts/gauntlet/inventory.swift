#!/usr/bin/env swift
import Foundation
import Darwin

// Source inventory only: never launches the application or compiles its targets.
// Explicit checked-in assignments make a newly added file/test a preflight failure.
let stages = ["unit", "regression", "integration", "performance", "hallie", "stress", "ui"]
func matches(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
        $0.range(at: group).location == NSNotFound ? nil : ns.substring(with: $0.range(at: group))
    }
}
// A type is a suite when its name says so, it is marked @Suite (same or previous
// line, e.g. `@Suite(.serialized) struct X`), or it directly holds a test. The old
// line-start/"Tests"-only rule missed all three and silently deselected their tests
// (baseline 2026-09-28: 35 unit + 6 Hallie declarations never ran).
func swiftSuites(_ text: String) -> [String] {
    let typeDecl = #"^\s*(?:@\S.*?\s+)?(?:(?:final|private|fileprivate|public|internal)\s+)*(?:struct|class|extension|enum|actor)\s+([A-Za-z_][A-Za-z_0-9]*)"#
    var names: [String] = []
    var suiteAttributePending = false
    // Enclosing types by brace depth, so a test after a nested helper type
    // (`struct Boom: Error {}`) is credited to the suite, not the helper.
    var depth = 0
    var open: [(name: String, depth: Int)] = []
    var pendingType: String?
    func add(_ name: String?) { if let name, !names.contains(name) { names.append(name) } }
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        let isTestLine = trimmed.contains("@Test") || matches(#"\bfunc\s+test[A-Za-z_0-9]*\s*\("#, trimmed).count > 0
        if !isTestLine, let name = matches(typeDecl, line, group: 1).first {
            pendingType = name
            if name.contains("Tests") || suiteAttributePending || trimmed.contains("@Suite") { add(name) }
        }
        if isTestLine { add(open.last?.name) }
        for ch in line {
            if ch == "{" {
                depth += 1
                if let t = pendingType { open.append((t, depth)); pendingType = nil }
            } else if ch == "}" {
                depth -= 1
                while let last = open.last, last.depth > depth { open.removeLast() }
            }
        }
        suiteAttributePending = trimmed.hasPrefix("@Suite") && matches(typeDecl, line, group: 1).isEmpty
    }
    return names
}
func discover(_ root: URL) throws -> [[String: Any]] {
    let fm = FileManager.default
    var result: [[String: Any]] = []
    // Bounded to source trees: ignores build products, venvs and generated corpora.
    let roots = [""]
    var seen = Set<String>()
    for relative in roots {
        let base = root.appendingPathComponent(relative)
        guard let iterator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
        while let url = iterator.nextObject() as? URL {
            if [".build", "__pycache__", "fixtures", "venv", "node_modules", "DerivedData", "build", ".trash"].contains(url.lastPathComponent)
                || url.lastPathComponent.hasPrefix("venv-") { iterator.skipDescendants(); continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard seen.insert(path.lowercased()).inserted else { continue }
            let swift = url.pathExtension == "swift" && path.contains("Tests/")
            let stem = url.deletingPathExtension().lastPathComponent
            let script = ["py", "sh"].contains(url.pathExtension) && (stem.hasPrefix("test_") || stem.hasSuffix("_test"))
            guard swift || script else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let tests: [String]
            if swift {
                // Count declarations, not parameterized cases; runtime counts must meet this floor.
                let cleaned = text.replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
                let swiftTests = matches(#"@Test\b[\s\S]*?\bfunc\s+([A-Za-z_][A-Za-z_0-9]*)\s*\("#, cleaned, group: 1)
                let xctests = matches(#"\bfunc\s+(test[A-Za-z_0-9]*)\s*\("#, cleaned, group: 1)
                tests = (swiftTests + xctests.filter { !swiftTests.contains($0) }).sorted()
                if tests.isEmpty { continue }
            } else {
                tests = url.pathExtension == "py" ? matches(#"(?m)^\s*(?:async\s+)?def\s+(test_[A-Za-z_0-9]+)\s*\("#, text, group: 1).sorted() : ["shell_suite"]
            }
            let kind = swift ? (path.hasPrefix("VideoScan/VideoScanTests/") ? "xcode" : path.contains("UITests/") ? "ui" : "package") : url.pathExtension == "py" ? "python" : "shell"
            result.append(["path": path, "kind": kind, "tests": tests,
                           "suites": swift ? swiftSuites(text) : [url.lastPathComponent]])
        }
    }
    return result.sorted { ($0["path"] as! String) < ($1["path"] as! String) }
}
func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}
do {
    let args = CommandLine.arguments
    guard args.count >= 3 else { throw NSError(domain: "usage: inventory.swift --discover ROOT | --validate ROOT MANIFEST", code: 2) }
    guard let physicalRoot = realpath(args[2], nil) else { throw NSError(domain: "inventory root does not exist", code: 2) }
    let root = URL(fileURLWithPath: String(cString: physicalRoot))
    free(physicalRoot)
    let discovered = try discover(root)
    if args[1] == "--discover" { try emit(discovered) }
    else if args[1] == "--validate", args.count == 4 {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        let assignments = manifest["assignments"] as? [[String: Any]] ?? []
        var errors: [String] = []
        var byPath: [String: [String: Any]] = [:]
        for entry in assignments {
            guard let path = entry["path"] as? String else { errors.append("assignment missing path"); continue }
            if byPath.updateValue(entry, forKey: path) != nil { errors.append("duplicate assignment: \(path)") }
            if !stages.contains(entry["stage"] as? String ?? "") { errors.append("invalid stage: \(path)") }
        }
        for entry in discovered {
            let path = entry["path"] as! String
            guard let assigned = byPath.removeValue(forKey: path) else { errors.append("unassigned test file: \(path)"); continue }
            for field in ["tests", "suites"] {
                if (entry[field] as? [String] ?? []).sorted() != (assigned[field] as? [String] ?? []).sorted() { errors.append("\(field) inventory changed (unassigned or stale): \(path)") }
            }
            if entry["kind"] as? String != assigned["kind"] as? String { errors.append("kind changed: \(path)") }
        }
        errors += byPath.keys.sorted().map { "stale assignment: \($0)" }
        let configs = manifest["stages"] as? [[String: Any]] ?? []
        if configs.compactMap({ $0["name"] as? String }) != stages { errors.append("stages must be unique and in canonical order") }
        for stage in configs {
            if (stage["expected_floor"] as? Int ?? 0) <= 0 { errors.append("stage requires positive expected_floor: \(stage["name"] ?? "unknown")") }
            let name = stage["name"] as? String ?? ""
            let blockedAssignments = assignments.filter { $0["stage"] as? String == name && $0["blocked_reason"] != nil }
            let expectedBlocked = blockedAssignments.compactMap { entry -> String? in
                guard let path = entry["path"] as? String, let reason = entry["blocked_reason"] as? String, !reason.isEmpty else { return nil }
                return path + "\n" + reason
            }
            let actualBlocked = (stage["blocked"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let path = entry["name"] as? String, let reason = entry["reason"] as? String else { return nil }
                return path + "\n" + reason
            }
            if expectedBlocked.count != blockedAssignments.count || expectedBlocked.sorted() != actualBlocked.sorted() {
                errors.append("blocked/assignment mismatch: \(name)")
            }
            if assignments.contains(where: { $0["stage"] as? String == name && $0["kind"] as? String != "xcode" && $0["blocked_reason"] == nil }) {
                errors.append("unadapted component must be blocked: \(name)")
            }
            let runnable = assignments.filter { $0["stage"] as? String == name && $0["blocked_reason"] == nil && $0["kind"] as? String == "xcode" }
            let expectedSelectors = Set(runnable.flatMap { ($0["suites"] as? [String] ?? []).map { "VideoScanTests/" + $0 } })
            let selectors = stage["selectors"] as? [String] ?? []
            if Set(selectors) != expectedSelectors || Set(selectors).count != selectors.count { errors.append("selector/assignment mismatch: \(name)") }
            let declarations = runnable.reduce(0) { $0 + ($1["tests"] as? [String] ?? []).count }
            if (stage["expected_floor"] as? Int ?? 0) < max(1, declarations) { errors.append("expected_floor below declaration count: \(name)") }
            for selector in selectors {
                let suite = String(selector.dropFirst("VideoScanTests/".count))
                let fragments = assignments.filter { $0["kind"] as? String == "xcode" && ($0["suites"] as? [String] ?? []).contains(suite) }
                if fragments.contains(where: { $0["blocked_reason"] != nil || $0["stage"] as? String != name }) { errors.append("selector crosses blocked/stage boundary: \(selector)") }
            }
        }
        try emit(["errors": errors, "discovered_files": discovered.count, "test_count": discovered.reduce(0) { $0 + ($1["tests"] as? [String] ?? []).count }])
        if !errors.isEmpty { exit(1) }
    } else { throw NSError(domain: "invalid inventory arguments", code: 2) }
} catch { fputs("inventory: \(error)\n", stderr); exit(2) }
