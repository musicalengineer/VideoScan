import Foundation
import VideoScanCore

/// When a wall-clock performance budget is allowed to be authoritative.
///
/// Extracted 2026-08-30. `GedcomScaleSensorTests` introduced this rule
/// after a nightly compared Debug+coverage timings against Release budgets
/// and reported a false regression; the same night,
/// `ArchivistTranscriptRenderSensorTests` failed for exactly that reason
/// because it had no gate at all (scroll p95 0.073 s against a 0.050 s
/// budget). Two independent copies of a rule that decides whether a
/// timing failure is real is precisely the thing that drifts, so it lives
/// in one place.
///
/// Three conditions, all necessary:
///   - Release. Debug timings are not the product's timings.
///   - An explicit opt-in. Perf lanes are slow and machine-sensitive; they
///     run when someone asked for them, not by accident.
///   - Coverage OFF. Instrumentation inflates every measurement, so a
///     coverage run can only produce false alarms.
///
/// Coverage detection (fixed 2026-09-23): `xcodebuild test` sets
/// LLVM_PROFILE_FILE=/dev/null in the runner even with
/// `-enableCodeCoverage NO`. Treating "any value" as coverage-on meant no
/// Release budget was ever asserted. `/dev/null` and empty now mean OFF;
/// PerformanceLaneTests pins this against the binary's real
/// instrumentation (presence of the LLVM profile runtime).
///
/// Release test builds need ENABLE_TESTABILITY=YES on the xcodebuild
/// command line (the app project sets it, but the local VideoScanCore
/// package does not, and five suites `@testable import VideoScanCore`):
///
///     TEST_RUNNER_<OPT_IN>=1 xcodebuild test -configuration Release \
///       -enableCodeCoverage NO ENABLE_TESTABILITY=YES \
///       -only-testing:VideoScanTests/<Suite>
enum PerformanceLane {

    #if DEBUG
    static let isDebugBuild = true
    static let configurationName = "Debug"
    #else
    static let isDebugBuild = false
    static let configurationName = "Release"
    #endif

    /// Pure form, for tests of the rule itself.
    static func isAuthoritative(debugBuild: Bool,
                                optInKey: String,
                                environment: [String: String]) -> Bool {
        !debugBuild
            && environment[optInKey] == "1"
            && !coverageEnabled(environment: environment)
    }

    /// Coverage is on only when LLVM_PROFILE_FILE names a real profile
    /// destination. Unset, empty, and `/dev/null` (what Xcode sets when
    /// coverage is off) all mean off.
    static func coverageEnabled(environment: [String: String]) -> Bool {
        guard let path = environment["LLVM_PROFILE_FILE"] else { return false }
        return !path.isEmpty && path != "/dev/null"
    }

    static func isAuthoritative(optInKey: String) -> Bool {
        isAuthoritative(debugBuild: isDebugBuild,
                        optInKey: optInKey,
                        environment: ProcessInfo.processInfo.environment)
    }

    /// Non-authoritative lanes still keep a coarse "not catastrophically
    /// slow" ceiling on their Debug timings. GitHub-hosted macOS runners are
    /// shared virtual M1s, roughly 2–3× slower than the machines those
    /// Debug budgets were measured on: on 2026-09-09 the 100k surname-roster
    /// turn took 2.15 s against a 2 s budget on the first CI run that got
    /// as far as running tests (GH #173). The ceiling is scaled there, and
    /// only there — GITHUB_ACTIONS is set by GitHub and nothing else (the
    /// CI test plan injects CI=1 locally too, so CI can't distinguish).
    ///
    /// The rule itself lives in VideoScanCore's `TimingBudget` (2026-09-26)
    /// so VideoScanCoreTests use the SAME numbers; these forward to it.
    static func hostedRunnerFactor(environment: [String: String]) -> Int {
        TimingBudget.hostedRunnerFactor(environment: environment)
    }

    /// A Debug ceiling, widened on GitHub-hosted runners. Never use this on
    /// an authoritative (Release, opted-in) budget — those are the product's
    /// numbers and must not stretch to fit the hardware.
    static func debugCeiling(_ budget: Duration) -> Duration {
        debugCeiling(budget, environment: ProcessInfo.processInfo.environment)
    }

    /// Pure form, for tests of the rule itself: off a GitHub-hosted runner
    /// the ceiling IS the budget, to the attosecond.
    static func debugCeiling(_ budget: Duration, environment: [String: String]) -> Duration {
        budget * hostedRunnerFactor(environment: environment)
    }

    /// The same ceiling for suites that time with CFAbsoluteTime / Date and
    /// compare plain `Double` seconds or milliseconds. Same multiplier; the
    /// label only says which unit the caller is in.
    static func debugCeiling(seconds budget: Double) -> Double {
        budget * Double(hostedRunnerFactor(environment: ProcessInfo.processInfo.environment))
    }

    static func debugCeiling(milliseconds budget: Double) -> Double {
        debugCeiling(seconds: budget)
    }

    /// A Debug ceiling that also allows for a machine that is measurably
    /// busy — the full Debug battery runs suites in parallel on every core,
    /// and a pure-CPU 100k pass then takes longer than it does alone.
    ///
    /// Measured 2026-09-23 (Archive Angel 100k scale tests): each suite
    /// ALONE on the M5 Pro, Debug, passed with 24–33% headroom; the same
    /// tests in a full Debug battery on the M4 Max ran 1.42–1.64× their
    /// M5-alone times (machine difference and load together) and 4–20%
    /// over budget. Use this only where the measured time is honest
    /// per-record work with no algorithmic slack left — speed up first.
    /// `loadedHeadroom` (default 1.5×) applies only when the machine is
    /// busy (1-minute load average at or above half the active cores); a
    /// quiet Debug run is held to the plain budget. Release never
    /// stretches: it gets `budget` (× the hosted-runner factor only, as
    /// `debugCeiling`), so the product's numbers stay authoritative.
    static func loadAwareDebugCeiling(_ budget: Duration, loadedHeadroom: Double = 1.5) -> Duration {
        let factor = loadFactor(debugBuild: isDebugBuild, loadAverage: currentLoadAverage(),
                                activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
                                loadedHeadroom: loadedHeadroom)
        return debugCeiling(budget) * factor
    }

    /// Pure form of the load rule, for tests of the rule itself.
    static func loadFactor(debugBuild: Bool, loadAverage: Double?, activeProcessors: Int,
                           loadedHeadroom: Double) -> Double {
        TimingBudget.loadFactor(debugBuild: debugBuild, loadAverage: loadAverage,
                                activeProcessors: activeProcessors, loadedHeadroom: loadedHeadroom)
    }

    /// The 1-minute load average, or nil when the kernel won't say.
    static func currentLoadAverage() -> Double? {
        TimingBudget.currentLoadAverage()
    }

    /// "load 9.3 on 16 cores" — for a failure message that says whether the
    /// headroom was in play.
    static func loadDescription() -> String {
        let load = currentLoadAverage().map { String(format: "%.1f", $0) } ?? "?"
        return "\(configurationName), load \(load) on \(ProcessInfo.processInfo.activeProcessorCount) cores"
    }

    /// Why a run is not authoritative, for a skip message that says what to
    /// do rather than just "skipped".
    static func explanation(optInKey: String) -> String {
        "not an authoritative performance lane (\(configurationName)"
            + (coverageEnabled(environment: ProcessInfo.processInfo.environment) ? ", coverage on" : "")
            + "). Run Release with TEST_RUNNER_\(optInKey)=1, -enableCodeCoverage NO and ENABLE_TESTABILITY=YES."
    }
}
