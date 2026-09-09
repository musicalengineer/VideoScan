import Foundation

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
            && environment["LLVM_PROFILE_FILE"] == nil
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
    static func hostedRunnerFactor(environment: [String: String]) -> Int {
        environment["GITHUB_ACTIONS"] == "true" ? 3 : 1
    }

    /// A Debug ceiling, widened on GitHub-hosted runners. Never use this on
    /// an authoritative (Release, opted-in) budget — those are the product's
    /// numbers and must not stretch to fit the hardware.
    static func debugCeiling(_ budget: Duration) -> Duration {
        budget * hostedRunnerFactor(environment: ProcessInfo.processInfo.environment)
    }

    /// Why a run is not authoritative, for a skip message that says what to
    /// do rather than just "skipped".
    static func explanation(optInKey: String) -> String {
        "not an authoritative performance lane (\(configurationName)"
            + (ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] == nil ? "" : ", coverage on")
            + "). Run Release with \(optInKey)=1 and coverage off."
    }
}
