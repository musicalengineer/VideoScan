// AngelEnvironment.swift
// The Archive Angel's view of the machine it runs on — the seam that
// replaces the `TestEnvironment.isTestHost` checks and hard-coded paths
// that used to be scattered through the plan store, the evidence store and
// the launch wiring. Injected into the façade; everything else asks the
// façade (or is handed the value by it).
//
// Defaults are EXACTLY the pre-S2 ones:
//   buffer root    ~/Movies/VideoScan Buffer/ArchiveAngel (test host: a
//                  per-process temp folder, never Rick's live buffer)
//   evidence dir   ~/Library/Application Support/VideoScan/archive-angel
//                  (test host: a per-process temp folder)
//   defaults       UserDefaults.standard
// New in S2, NOT created by default:
//   policy.json    ~/Library/Application Support/VideoScan/archive-angel/policy.json
//                  — Rick's optional override of the recommendation rules
//                  (AngelRecommendationPolicy). Test host: a per-process
//                  temp path, so a real override never leaks into a test.

import Foundation

struct AngelEnvironment {
    /// Where prepared batches live (`<root>/batch-…/plan.json`).
    var bufferRoot: URL
    /// Where evidence.json lives.
    var evidenceDirectory: URL
    /// Rick's optional recommendation-rule override. May not exist.
    var policyOverrideURL: URL
    /// The bundled default rule set (a copy of the built-in rules Rick can
    /// start an override from). nil = not in the bundle → the built-in rules.
    var bundledPolicyURL: URL?
    /// A unit-test process: no launch tasks, no real paths.
    var isTestHost: Bool
    /// Preferences (ArchiveAngelSettings' keys live here).
    var defaults: UserDefaults

    /// The running app's environment.
    static var app: AngelEnvironment {
        let testHost = TestEnvironment.isTestHost
        return AngelEnvironment(
            bufferRoot: testHost ? testHostBufferRoot : productionBufferRoot(home: FileManager.default.homeDirectoryForCurrentUser),
            evidenceDirectory: testHost ? testHostEvidenceDirectory : productionAngelSupportDirectory(),
            policyOverrideURL: testHost
                ? testHostScratch.appendingPathComponent("policy.json")
                : productionAngelSupportDirectory().appendingPathComponent(AngelRecommendationPolicy.overrideFilename),
            bundledPolicyURL: Bundle.main.url(forResource: AngelRecommendationPolicy.bundledResourceName,
                                              withExtension: "json"),
            isTestHost: testHost,
            defaults: .standard)
    }

    // MARK: Paths (pure — the production formulas are unit-tested)

    /// Default buffer root: the internal SSD (design §5). Rick 9/09: "we'll
    /// try with a fast ssd" — a setting can point this elsewhere.
    nonisolated static func productionBufferRoot(home: URL) -> URL {
        home.appendingPathComponent("Movies/VideoScan Buffer/ArchiveAngel", isDirectory: true)
    }

    /// Isolation (audit, 2026-09-19): under the test host, never Rick's
    /// live buffer — a test that starts a job through the normal entry
    /// point would otherwise write batches (and settle his!) there. One
    /// folder per test process, like CatalogStore.shared's guard.
    nonisolated static let testHostBufferRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_buffer_pid\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// App Support/VideoScan/archive-angel/ — the production home of
    /// evidence.json (and of an optional policy.json).
    nonisolated static func productionAngelSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/archive-angel", isDirectory: true)
    }

    /// Under a test host: a per-process scratch folder (the MediaLedger /
    /// IgnoredContentStore discipline). Found 2026-09-19: every test that
    /// builds a VideoScanModel enables the sweep, and a 60 s debounce or
    /// the 15 min periodic run wrote a 1.7 KB evidence.json over Rick's
    /// real one from inside the unit suite (CleanupIsolationTests caught
    /// the write; the nightly had been doing it since 09-14).
    nonisolated static let testHostEvidenceDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("VideoScan-tests/archive-angel-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    nonisolated static var testHostScratch: URL { testHostEvidenceDirectory }

    /// The buffer root the running process uses (production or test host).
    nonisolated static var currentBufferRoot: URL {
        TestEnvironment.isTestHost ? testHostBufferRoot
            : productionBufferRoot(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The evidence directory the running process uses.
    nonisolated static var currentEvidenceDirectory: URL {
        TestEnvironment.isTestHost ? testHostEvidenceDirectory : productionAngelSupportDirectory()
    }
}
