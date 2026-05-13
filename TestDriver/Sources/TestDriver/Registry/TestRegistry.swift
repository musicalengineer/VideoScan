// TestRegistry.swift
//
// Generic registry of tests, grouped by category and module. The UI reads
// this; a CLI mode reads the same registry. Tests are black-box — they
// invoke external tooling (subprocess, defaults read, sample, xcodebuild)
// rather than linking the target app's Swift module. That keeps TestDriver
// independent of any one app's build setup.

import Foundation

/// Coarse grouping shown as the top-level outline rows.
enum TestGroup: String, CaseIterable, Identifiable, Hashable, Codable {
    case smoke       = "Smoke"
    case unit        = "Unit"
    case regression  = "Regression"
    case integration = "Integration"
    case stress      = "Stress"
    case performance = "Performance"
    case diagnostic  = "Diagnostic"

    var id: String { rawValue }

    /// Stress tests can pollute prefs / consume RAM / bring the OS down.
    /// Hidden behind a "I know what I'm doing" toggle in the UI.
    var requiresOptIn: Bool {
        self == .stress
    }
}

/// Where the test will execute. Hardwired to local for now; SSH-to-MBP
/// path lands when we wire it up. Reachable hosts are surfaced in the
/// UI's "Run on" picker.
enum TestHost: String, CaseIterable, Identifiable, Codable, Hashable {
    case macStudio = "Mac Studio (local)"
    case mbp       = "M1 MBP (over SSH)"

    var id: String { rawValue }
    /// Hostname or "local" — used by tests that need to know where to run.
    var sshHost: String? {
        switch self {
        case .macStudio: return nil
        case .mbp:       return "ricksmacbookpro.local"
        }
    }
    /// Both hosts are wired up: local Mac Studio runs xcodebuild directly;
    /// MBP runs it via SSH + launchctl submit (see MBPRemote.swift).
    var isImplemented: Bool { true }
}

/// Outcome of a single test run.
enum TestStatus: Equatable {
    case notRun
    case running
    case passed(durationSeconds: Double)
    case failed(message: String, durationSeconds: Double)
    case unclear(message: String, durationSeconds: Double)   // harness error, timeout, infrastructure flake
    case skipped(reason: String)

    var symbol: String {
        switch self {
        case .notRun:  return "—"
        case .running: return "⌛"
        case .passed:  return "✓"
        case .failed:  return "✗"
        case .unclear: return "⚠"
        case .skipped: return "↷"
        }
    }
}

/// Result returned by a test's `run` closure. Non-throwing: tests that
/// want to fail must return `.failed(...)`. The closure's responsibility
/// is to convert any internal error into a TestStatus — that way a
/// registered test can never hard-crash the harness.
struct TestResult {
    let status: TestStatus
    /// Full log text (stdout/stderr) the user can expand to inspect.
    let log: String

    static func passed(_ duration: Double, log: String = "") -> TestResult {
        TestResult(status: .passed(durationSeconds: duration), log: log)
    }
    static func failed(_ message: String, duration: Double, log: String = "") -> TestResult {
        TestResult(status: .failed(message: message, durationSeconds: duration), log: log)
    }
    static func unclear(_ message: String, duration: Double, log: String = "") -> TestResult {
        TestResult(status: .unclear(message: message, durationSeconds: duration), log: log)
    }
    static func skipped(_ reason: String, log: String = "") -> TestResult {
        TestResult(status: .skipped(reason: reason), log: log)
    }
}

/// One registered test entry. `module` is a second-level grouping for the
/// outline ("Unit ▸ PersonFinder ▸ pfRunArcFaceEngineBail()"). Optional;
/// nil-module tests sit directly under the group.
struct TestEntry: Identifiable {
    let id: String                 // stable identifier (group/module/name)
    let group: TestGroup
    let module: String?
    let name: String
    let description: String
    /// Async runner. Receives a logger closure for streaming output and
    /// the host the user selected.
    let run: (_ host: TestHost, _ logLine: @escaping @Sendable (String) -> Void) async -> TestResult

    init(group: TestGroup,
         module: String? = nil,
         name: String,
         description: String,
         run: @escaping (_ host: TestHost, _ logLine: @escaping @Sendable (String) -> Void) async -> TestResult) {
        let modulePart = module ?? "_"
        self.id = "\(group.rawValue)/\(modulePart)/\(name)"
        self.group = group
        self.module = module
        self.name = name
        self.description = description
        self.run = run
    }
}

/// Global registry. Tests register via `TestRegistry.shared.register(...)`
/// at app launch.
final class TestRegistry {
    static let shared = TestRegistry()

    private var entries: [TestEntry] = []
    private let queue = DispatchQueue(label: "com.testdriver.registry")

    private init() {}

    func register(_ entry: TestEntry) {
        queue.sync { entries.append(entry) }
    }
    func register(_ newEntries: [TestEntry]) {
        queue.sync { entries.append(contentsOf: newEntries) }
    }
    func all() -> [TestEntry] {
        queue.sync { entries }
    }
    func entry(id: String) -> TestEntry? {
        all().first { $0.id == id }
    }

    /// Hierarchical view: [(group, [(module?, [entry])])]. Modules within
    /// a group are sorted alphabetically; the nil-module bucket (group-level
    /// tests with no module) comes first.
    func hierarchy() -> [(TestGroup, [(String?, [TestEntry])])] {
        let all = self.all()
        return TestGroup.allCases.compactMap { group in
            let inGroup = all.filter { $0.group == group }
            if inGroup.isEmpty { return nil }
            // Bucket by module.
            var buckets: [String?: [TestEntry]] = [:]
            for e in inGroup {
                buckets[e.module, default: []].append(e)
            }
            // Sort: nil-module first, then alphabetical.
            let sorted: [(String?, [TestEntry])] = buckets
                .sorted { lhs, rhs in
                    switch (lhs.key, rhs.key) {
                    case (nil, _):    return true
                    case (_, nil):    return false
                    case let (a?, b?): return a < b
                    default: return false
                    }
                }
            return (group, sorted)
        }
    }

    /// Total count by group (for the chevron label).
    func count(group: TestGroup) -> Int {
        all().filter { $0.group == group }.count
    }

    /// Total count by group + module.
    func count(group: TestGroup, module: String?) -> Int {
        all().filter { $0.group == group && $0.module == module }.count
    }
}
