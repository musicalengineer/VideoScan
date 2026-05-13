// TestRegistry.swift
//
// Generic registry of tests, grouped by category. The UI reads this; the
// CLI mode (planned) reads the same registry. Tests in the registry are
// black-box — they invoke external tooling (subprocess, defaults read,
// sample, xcodebuild) rather than linking the target app's Swift module.
// That keeps TestDriver independent of any one app's build setup.

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

/// Outcome of a single test run.
enum TestStatus: Equatable {
    case notRun
    case running
    case passed(durationSeconds: Double)
    case failed(message: String, durationSeconds: Double)
    case skipped(reason: String)

    var symbol: String {
        switch self {
        case .notRun:           return "—"
        case .running:          return "⌛"
        case .passed:           return "✓"
        case .failed:           return "✗"
        case .skipped:          return "↷"
        }
    }
}

/// Result returned by a test's `run` closure. Non-throwing: tests that
/// want to fail must return `.failed(...)`. We do this so a registered
/// test can never hard-crash the harness — the closure's responsibility
/// is to convert any internal error into a TestStatus.
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

    static func skipped(_ reason: String, log: String = "") -> TestResult {
        TestResult(status: .skipped(reason: reason), log: log)
    }
}

/// One registered test entry.
struct TestEntry: Identifiable {
    let id: String                 // stable identifier (group/name)
    let group: TestGroup
    let name: String
    let description: String
    /// Async runner. Receives a closure to stream live log lines into the UI.
    let run: (_ logLine: @escaping (String) -> Void) async -> TestResult

    init(group: TestGroup,
         name: String,
         description: String,
         run: @escaping (_ logLine: @escaping (String) -> Void) async -> TestResult) {
        self.id = "\(group.rawValue)/\(name)"
        self.group = group
        self.name = name
        self.description = description
        self.run = run
    }
}

/// Global registry. Tests register via `TestRegistry.shared.register(...)`
/// at module load (call from a static initializer or app launch).
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

    func grouped() -> [(TestGroup, [TestEntry])] {
        let all = self.all()
        return TestGroup.allCases.compactMap { group in
            let inGroup = all.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    func entry(id: String) -> TestEntry? {
        all().first { $0.id == id }
    }
}
