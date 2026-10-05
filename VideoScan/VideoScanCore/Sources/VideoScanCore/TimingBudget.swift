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
///
/// GH #208 (2026-10-02): new and migrated budget checks use `judge` /
/// `judgeNow` below (strict when quiet, known issue up to 3× when busy)
/// instead of `loadAwareDebugCeiling`; the ceiling functions stay for the
/// app suites not yet migrated.
public enum TimingBudget {

    #if DEBUG
    public static let isDebugBuild = true
    #else
    public static let isDebugBuild = false
    #endif

    public static func hostedRunnerFactor(environment: [String: String]) -> Int {
        environment["GITHUB_ACTIONS"] == "true" ? 3 : 1
    }

    /// Set by scripts/weekly_sanitizer.py (as TEST_RUNNER_VIDEOSCAN_SANITIZER,
    /// which xcodebuild forwards) to "address" or "thread" (2026-10-04).
    public static let sanitizerEnvironmentKey = "VIDEOSCAN_SANITIZER"

    /// How much slower instrumented code runs: Address Sanitizer ~2–3×
    /// (×4 here), Thread Sanitizer ~5–15× (×15). 1 when no sanitizer.
    /// A sanitizer run is about memory and races, not speed — but a hang
    /// beyond this headroom still fails.
    public static func sanitizerFactor(environment: [String: String]) -> Int {
        switch environment[sanitizerEnvironmentKey] {
        case "address": return 4
        case "thread": return 15
        default: return 1
        }
    }

    /// The budget, ×3 on a GitHub-hosted runner, ×the sanitizer factor
    /// under a sanitizer run; exactly the budget otherwise.
    public static func debugCeiling(
        _ budget: Duration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Duration {
        // Two steps: Swift 6.2 (CI's Xcode 26.3) can't type-check
        // `Duration * (Int * Int)` in one expression.
        let factor: Int = hostedRunnerFactor(environment: environment) * sanitizerFactor(environment: environment)
        return budget * factor
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

    // MARK: Strict on a quiet machine, known issue on a busy one (GH #208)
    //
    // Rick's ruling 2026-10-02. The 2 AM Release nightly on a quiet M4
    // passed every timing test; the same tests failed only when the host
    // was busy (parallel agent builds, `swift test --parallel`, a full app
    // battery, GitHub runners). So a budget is judged in one of two modes:
    //
    //   STRICT — the 1-minute load average stays below half the logical
    //   cores, sampled before AND after the measurement (or
    //   VIDEOSCAN_TIMING_STRICT=1, which the nightly pins). Any miss fails.
    //
    //   BUSY — either sample at or above half the cores, or a GitHub-hosted
    //   runner. A miss up to `busyMissLimit`× the budget is a KNOWN ISSUE
    //   (visible, run stays green); a miss beyond that still FAILS — that is
    //   a hang or a regression no amount of load explains.
    //
    // No budget number moves: the budget is compared as written, and the
    // only widening is the busy-mode band, which never passes silently.
    // The verdict is pure (`judge`), so it is unit-tested with injected
    // load and cores; test targets map it onto Swift Testing / XCTest.

    /// Forces strict mode regardless of load (the 2 AM nightly sets it).
    public static let strictEnvironmentKey = "VIDEOSCAN_TIMING_STRICT"
    /// Busy = 1-minute load at or above this fraction of the logical cores.
    public static let busyLoadFraction = 0.5
    /// On a busy machine, a miss up to this multiple of the budget is a
    /// known issue; beyond it the test fails.
    public static let busyMissLimit: Double = 3

    /// One 1-minute load-average reading and the core count it is judged
    /// against. `load` is nil when the kernel won't say.
    public struct LoadSample: Sendable, Equatable {
        public var load: Double?
        public var logicalCores: Int
        public init(load: Double?, logicalCores: Int) {
            self.load = load
            self.logicalCores = logicalCores
        }
        public var isBusy: Bool {
            guard let load, logicalCores > 0 else { return false }
            return load >= Double(logicalCores) * TimingBudget.busyLoadFraction
        }
        var text: String { load.map { String(format: "%.1f", $0) } ?? "?" }
    }

    public enum Verdict: String, Sendable, Equatable {
        case pass
        case knownIssue = "known-issue"
        case fail
    }

    public struct Judgement: Sendable, Equatable {
        public let label: String
        public let budget: Duration
        public let measured: Duration
        public let before: LoadSample
        public let after: LoadSample
        /// True when a miss fails outright (quiet machine or the override).
        public let strict: Bool
        /// Why this mode: "quiet", "VIDEOSCAN_TIMING_STRICT=1", "busy", "GitHub-hosted runner".
        public let modeReason: String
        public let verdict: Verdict

        public var ratio: Double {
            let b = TimingBudget.seconds(budget)
            return b > 0 ? TimingBudget.seconds(measured) / b : .infinity
        }

        /// The single line logged per measurement: budget, measured, load, verdict.
        public var logLine: String {
            let ms = { (d: Duration) in String(format: "%.1f ms", TimingBudget.seconds(d) * 1_000) }
            return "[timing-budget] \(label): budget \(ms(budget)), measured \(ms(measured)) "
                + "(\(String(format: "%.2f", ratio))×), load \(before.text)→\(after.text) on "
                + "\(after.logicalCores) cores, \(strict ? "strict" : "busy") (\(modeReason)) → \(verdict.rawValue)"
        }
    }

    /// Reads the current 1-minute load and logical core count.
    public static func sampleLoad() -> LoadSample {
        LoadSample(load: currentLoadAverage(),
                   logicalCores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// The pure rule. `before` is sampled before the measured work starts,
    /// `after` once it ends; either one busy makes the run busy.
    public static func judge(
        _ label: String,
        budget: Duration,
        measured: Duration,
        before: LoadSample,
        after: LoadSample,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Judgement {
        let strict: Bool
        let reason: String
        let sanitizer = sanitizerFactor(environment: environment)
        if sanitizer > 1 {
            // Instrumented code: judge against the budget × the sanitizer's
            // known slowdown; a miss within the busy band of THAT is a known
            // issue, beyond it a failure (a hang no instrumentation explains).
            let scaled: Duration = budget * sanitizer
            let verdict: Verdict = measured < scaled ? .pass
                : (measured <= scaled * busyMissLimit ? .knownIssue : .fail)
            return Judgement(label: label, budget: budget, measured: measured,
                             before: before, after: after, strict: false,
                             modeReason: "\(sanitizerEnvironmentKey)=\(environment[sanitizerEnvironmentKey] ?? "")",
                             verdict: verdict)
        }
        if environment[strictEnvironmentKey] == "1" {
            strict = true; reason = "\(strictEnvironmentKey)=1"
        } else if before.isBusy || after.isBusy {
            strict = false; reason = "busy"
        } else if hostedRunnerFactor(environment: environment) > 1 {
            strict = false; reason = "GitHub-hosted runner"
        } else {
            strict = true; reason = "quiet"
        }
        let verdict: Verdict
        if measured < budget {
            verdict = .pass
        } else if strict {
            verdict = .fail
        } else if measured <= budget * busyMissLimit {
            verdict = .knownIssue
        } else {
            verdict = .fail
        }
        return Judgement(label: label, budget: budget, measured: measured,
                         before: before, after: after, strict: strict,
                         modeReason: reason, verdict: verdict)
    }

    /// `judge` with the after-sample taken now, and the line logged.
    public static func judgeNow(
        _ label: String, budget: Duration, measured: Duration, loadBefore: LoadSample
    ) -> Judgement {
        let j = judge(label, budget: budget, measured: measured,
                      before: loadBefore, after: sampleLoad())
        print(j.logLine)
        return j
    }

    // MARK: Thread CPU time (GH #208, 2026-09-27)
    //
    // A wall-clock budget on a pure-CPU loop measures the loop AND whatever
    // else the host is doing: DateTriangulatorScaleTests took 35.8 s against
    // 25 s at load ~16 (four concurrent xcodebuilds), 19.2 s alone. The
    // load-aware ×1.5 cannot cover an arbitrarily saturated host. The CPU
    // time the measuring thread itself consumed is what an O(n) regression
    // changes and what load mostly does not — time spent runnable-but-
    // waiting is not counted. (C++ analogy: std::clock() per thread, i.e.
    // CLOCK_THREAD_CPUTIME_ID, instead of steady_clock.)
    //
    // Use it ONLY for a synchronous, single-threaded body: work done on
    // other threads (a TaskGroup, a DispatchQueue, an async hop) is not
    // counted, and I/O waits are not counted either — where I/O or
    // fan-out is the thing being budgeted, keep wall time.

    /// CPU time consumed so far by the calling thread.
    public static func currentThreadCPUTime() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    /// CPU time the calling thread spent inside `body`. `body` is
    /// synchronous, so it runs start to finish on this thread.
    public static func measureThreadCPUTime(_ body: () throws -> Void) rethrows -> Duration {
        let start = currentThreadCPUTime()
        try body()
        return currentThreadCPUTime() - start
    }

    /// Seconds as a Double, for messages and Double-typed budgets.
    public static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
