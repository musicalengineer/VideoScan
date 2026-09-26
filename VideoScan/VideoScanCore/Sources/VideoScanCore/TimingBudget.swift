import Foundation

/// How far a wall-clock TEST budget may stretch, and when. The one copy of
/// the rule, shared by the app's test target (`PerformanceLane` forwards
/// here) and VideoScanCoreTests (which cannot see the app test target).
///
/// Lives in the library, not a test target, because it is the only place
/// both test targets can import: VideoScanCoreTests is a SwiftPM test
/// target and VideoScanTests is an Xcode target, and a rule that decides
/// whether a timing failure is real must not exist in two drifting copies
/// (see PerformanceLane's header). Foundation-only, pure, no state; the
/// product never calls it.
///
/// Two widening factors, both off by default and both measured, never
/// guessed:
///   - GitHub-hosted runner (`GITHUB_ACTIONS=true`, set only by GitHub):
///     ×3. Shared virtual M1s, measured 2–3× slower than the fleet.
///   - A busy Debug run (1-minute load ≥ half the active cores): ×headroom
///     (default 1.5). A full battery runs suites in parallel on every core.
/// A quiet local run is held to the budget exactly.
public enum TimingBudget {

    #if DEBUG
    public static let isDebugBuild = true
    #else
    public static let isDebugBuild = false
    #endif

    public static func hostedRunnerFactor(environment: [String: String]) -> Int {
        environment["GITHUB_ACTIONS"] == "true" ? 3 : 1
    }

    /// The budget, ×3 on a GitHub-hosted runner only.
    public static func debugCeiling(
        _ budget: Duration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Duration {
        budget * hostedRunnerFactor(environment: environment)
    }

    /// `debugCeiling`, further ×`loadedHeadroom` when this is a Debug build
    /// AND the machine is measurably busy. Release never stretches for load.
    public static func loadAwareDebugCeiling(
        _ budget: Duration,
        debugBuild: Bool = isDebugBuild,
        loadedHeadroom: Double = 1.5
    ) -> Duration {
        let factor = loadFactor(debugBuild: debugBuild, loadAverage: currentLoadAverage(),
                                activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
                                loadedHeadroom: loadedHeadroom)
        return debugCeiling(budget) * factor
    }

    /// Pure form of the load rule.
    public static func loadFactor(debugBuild: Bool, loadAverage: Double?, activeProcessors: Int,
                                  loadedHeadroom: Double) -> Double {
        guard debugBuild, let load = loadAverage, activeProcessors > 0,
              load >= Double(activeProcessors) / 2 else { return 1 }
        return max(1, loadedHeadroom)
    }

    /// The 1-minute load average, or nil when the kernel won't say.
    public static func currentLoadAverage() -> Double? {
        var samples = [Double](repeating: 0, count: 1)
        return getloadavg(&samples, 1) == 1 ? samples[0] : nil
    }

    /// "Debug, load 9.3 on 16 cores" — for failure messages.
    public static func loadDescription(debugBuild: Bool = isDebugBuild) -> String {
        let load = currentLoadAverage().map { String(format: "%.1f", $0) } ?? "?"
        return "\(debugBuild ? "Debug" : "Release"), load \(load) on \(ProcessInfo.processInfo.activeProcessorCount) cores"
    }

    /// Seconds as a Double, for messages and Double-typed budgets.
    public static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
