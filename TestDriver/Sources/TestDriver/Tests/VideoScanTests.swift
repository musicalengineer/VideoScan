// VideoScanTests.swift
//
// Initial set of tests TestDriver runs against VideoScan. All black-box —
// invokes external tools, reads prefs, samples the running process,
// scans crash logs. No linkage to VideoScan's Swift module.
//
// Add new tests by appending to `registerAll`.

import Foundation

enum VideoScanTests {

    static let bundleID = "Rick-Breen.VideoScan"
    static let runningProcessName = "VideoScan.app/Contents/MacOS/VideoScan"
    static let projectDir = NSHomeDirectory() + "/dev/VideoScan"

    /// Process-wide coverage request. Set by the UI/CLI from the
    /// `coverageEnabled` / `coverageIncludeAll` model toggles before each
    /// run loop. Read at the start of `runXcodebuildTest` so individual
    /// test closures don't need new parameters. Defaults to off, so a
    /// stray test invocation behaves exactly as before.
    nonisolated(unsafe) static var coverageContext: (enabled: Bool, includeAll: Bool) = (false, false)

    /// Shared across every xcodebuild test invocation in this process so
    /// the 2nd→Nth suite picks up cached build products instead of paying
    /// a full ~90s cold build each time. Auto-discovery surfaces ~130
    /// suites, and the run loop is sequential — without sharing this
    /// path, a "run all" pass would re-link the entire test bundle once
    /// per suite and never finish (the "all-day hang" symptom).
    /// Unique-per-launch to avoid collisions with a concurrent TestDriver
    /// instance, but stable across all runs within a single launch.
    static let sharedDerivedDataPath: String = {
        let p = NSTemporaryDirectory() + "testdriver-dd-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()

    /// Register every test in this file with the global registry.
    static func registerAll() {
        TestRegistry.shared.register([
            // Smoke
            smokeAppBinaryExists,
            smokeArcFaceModelPresent,
            smokeReachabilityCachePresent,
            // Diagnostic
            diagnosticDefaultsPollutionCheck,
            diagnosticRecentCrashScan,
            diagnosticMainThreadStuckSyscalls,
            // Unit (XCTest suite via xcodebuild)
            unitFullSuiteDebug,
            unitFullSuiteRelease,
            // Regression (focused XCTest runs)
            regressionArcFaceCacheTests,
            regressionPersonFinderEngineDispatch,
            regressionVolumeReachabilityCache
        ])

        // Auto-discover @Suite declarations from VideoScanTests source files.
        // Skip suites already covered by manual regression entries above.
        SuiteDiscovery.registerDiscoveredSuites(excluding: [
            "PersonFinderEngineDispatchTests",
            "VolumeReachabilityBoundaryTests",
            "ArcFaceModelLoaderTests"
        ])
    }

    /// Public entry point for auto-discovered suites. Delegates to the
    /// shared xcodebuild helper with Debug config.
    static func runDiscoveredSuite(
        suiteName: String,
        host: TestHost,
        log: @escaping @Sendable (String) -> Void
    ) async -> TestResult {
        await runXcodebuildTest(
            host: host,
            configuration: "Debug",
            onlyTesting: "VideoScanTests/\(suiteName)",
            entrySupportsCoverage: true,
            log: log,
            timeoutSeconds: 600
        )
    }

    // MARK: - Smoke

    static var smokeAppBinaryExists: TestEntry {
        TestEntry(
            group: .smoke,
            module: "Build artifacts",
            name: "VideoScan binary built and present",
            description: "Locate the most recent Xcode-built VideoScan.app binary"
        ) { _, log in
            let started = Date()
            log("Searching ~/Library/Developer/Xcode/DerivedData for VideoScan.app...")
            let result = await Subprocess.run("/usr/bin/find", [
                NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData",
                "-name", "VideoScan.app",
                "-type", "d",
                "-maxdepth", "8"
            ], timeoutSeconds: 30,
               stdoutLine: { line in log(line) })
            let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
            let elapsed = Date().timeIntervalSince(started)
            log("Found \(lines.count) VideoScan.app instance(s)")
            if lines.isEmpty {
                return .failed("No VideoScan.app found in DerivedData — build the app from Xcode first",
                               duration: elapsed)
            }
            return .passed(elapsed, log: result.stdout)
        }
    }

    static var smokeArcFaceModelPresent: TestEntry {
        TestEntry(
            group: .smoke,
            module: "Assets",
            name: "ArcFace CoreML model present",
            description: "w600k_r50.mlmodelc or .mlpackage exists in expected location"
        ) { _, log in
            let started = Date()
            let modelsDir = NSHomeDirectory() + "/dev/VideoScan/models"
            let compiled = modelsDir + "/w600k_r50.mlmodelc"
            let pkg = modelsDir + "/w600k_r50.mlpackage"
            let fm = FileManager.default
            log("Checking \(compiled)")
            log("Checking \(pkg)")
            let elapsed = Date().timeIntervalSince(started)
            if fm.fileExists(atPath: compiled) || fm.fileExists(atPath: pkg) {
                return .passed(elapsed, log: "ArcFace model present")
            }
            return .failed("Neither w600k_r50.mlmodelc nor .mlpackage found in \(modelsDir)",
                           duration: elapsed)
        }
    }

    static var smokeReachabilityCachePresent: TestEntry {
        TestEntry(
            group: .smoke,
            module: "Source-level invariants",
            name: "VolumeReachability cache code present",
            description: "Source mentions invalidateCache/cacheTTL/cacheLock — issue #87 fix landed"
        ) { _, log in
            let started = Date()
            let path = projectDir + "/VideoScan/VideoScan/VolumeReachability.swift"
            log("Reading \(path)")
            let elapsed = Date().timeIntervalSince(started)
            guard let content = try? String(contentsOfFile: path) else {
                return .failed("Couldn't read source file", duration: elapsed)
            }
            let needles = ["invalidateCache", "cacheTTL", "cacheLock"]
            let missing = needles.filter { !content.contains($0) }
            if !missing.isEmpty {
                return .failed("Source missing: \(missing.joined(separator: ", "))",
                               duration: elapsed)
            }
            return .passed(elapsed, log: "All cache-related symbols present")
        }
    }

    // MARK: - Diagnostic

    static var diagnosticDefaultsPollutionCheck: TestEntry {
        TestEntry(
            group: .diagnostic,
            module: "Pref pollution",
            name: "Defaults pollution check",
            description: "Inspects pf_ keys in Rick-Breen.VideoScan defaults for stress-test residue"
        ) { _, log in
            let started = Date()
            let plist = NSHomeDirectory() + "/Library/Preferences/\(bundleID).plist"
            log("Reading \(plist)")
            let result = await Subprocess.run("/usr/bin/defaults", ["read", plist],
                                              timeoutSeconds: 5)
            let elapsed = Date().timeIntervalSince(started)
            if !result.didSucceed {
                return .skipped("No defaults plist found at \(plist)",
                                log: result.stderr)
            }
            let suspicious: [(String, String, String)] = [
                ("pf_previewRate", "25", "Codex stress harness sets 25; default is 5"),
                ("pf_frameStep",   "1",  "frameStep=1 means every frame sampled (5x normal load)"),
                ("pf_concurrency", "32", "concurrency=32 is the stress value; default is 4")
            ]
            var hits: [String] = []
            for (key, val, why) in suspicious {
                if result.stdout.contains("\"\(key)\" = \(val)") ||
                   result.stdout.contains("\"\(key)\" = \"\(val)\"") {
                    hits.append("  \(key) = \(val)  — \(why)")
                }
            }
            if !hits.isEmpty {
                let body = "Defaults look polluted by a recent stress-test run:\n" +
                           hits.joined(separator: "\n") +
                           "\n\nFix: defaults delete \(bundleID) <key>"
                log(body)
                return .failed("Suspicious pf_ values present", duration: elapsed, log: body)
            }
            return .passed(elapsed, log: "No suspicious pf_ values detected")
        }
    }

    static var diagnosticRecentCrashScan: TestEntry {
        TestEntry(
            group: .diagnostic,
            module: "Crash reports",
            name: "Recent VideoScan crash logs",
            description: "Scans ~/Library/Logs/DiagnosticReports for VideoScan-*.ips in last 24h"
        ) { _, log in
            let started = Date()
            let dir = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
            let result = await Subprocess.run("/usr/bin/find", [
                dir, "-name", "VideoScan-*.ips",
                "-mtime", "-1"
            ], timeoutSeconds: 10)
            let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
            let elapsed = Date().timeIntervalSince(started)
            if lines.isEmpty {
                return .passed(elapsed, log: "No VideoScan crash reports in the last 24h")
            }
            var body = "Found \(lines.count) crash report(s) in last 24h:\n"
            for ln in lines.prefix(10) {
                body += "  \(ln)\n"
            }
            log(body)
            return .failed("\(lines.count) crash report(s) in last 24h", duration: elapsed, log: body)
        }
    }

    static var diagnosticMainThreadStuckSyscalls: TestEntry {
        TestEntry(
            group: .diagnostic,
            module: "Liveness",
            name: "Main thread stuck in syscall (issue #87 signature)",
            description: "Samples running VideoScan for 3s; flags if main is in stat()/read()/select()"
        ) { _, log in
            let started = Date()
            let pgrep = await Subprocess.run("/usr/bin/pgrep", ["-f", runningProcessName])
            let pidStr = pgrep.stdout.split(separator: "\n").first.map(String.init) ?? ""
            guard let pid = Int(pidStr.trimmingCharacters(in: .whitespaces)) else {
                return .skipped("VideoScan not running", log: "pgrep returned no PID")
            }
            log("Sampling PID \(pid) for 3 seconds...")
            let sample = await Subprocess.run("/usr/bin/sample", [String(pid), "3"], timeoutSeconds: 15)
            let elapsed = Date().timeIntervalSince(started)
            let stuckSignatures = ["stat ", "__select", "psynch_cvwait", "fileExists"]
            let mainBlock = sample.stdout
                .components(separatedBy: "\n")
                .filter { $0.contains("com.apple.main-thread") || $0.contains("4182 ") }
            let suspectLines = mainBlock.filter { line in
                stuckSignatures.contains { line.contains($0) }
            }
            if suspectLines.isEmpty {
                return .passed(elapsed, log: "Main thread not blocked in any tracked syscall")
            }
            return .failed("Main thread appears blocked in: \(stuckSignatures.joined(separator: ", "))",
                           duration: elapsed,
                           log: suspectLines.prefix(20).joined(separator: "\n"))
        }
    }

    // MARK: - Unit (delegates to xcodebuild)

    static var unitFullSuiteDebug: TestEntry {
        TestEntry(
            group: .unit,
            module: "VideoScanTests (Debug)",
            name: "Full XCTest suite (Debug)",
            description: "Runs xcodebuild test against VideoScanTests, Debug config",
            supportsCoverage: true
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests",
                entrySupportsCoverage: true,
                log: log,
                timeoutSeconds: 1800
            )
        }
    }

    static var unitFullSuiteRelease: TestEntry {
        TestEntry(
            group: .unit,
            module: "VideoScanTests (Release)",
            name: "Full XCTest suite (Release optimizer smoke)",
            description: "Same suite under Release optimization — catches optimizer-only bugs",
            supportsCoverage: true
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Release",
                onlyTesting: "VideoScanTests",
                entrySupportsCoverage: true,
                log: log,
                timeoutSeconds: 1800
            )
        }
    }

    // MARK: - Regression

    static var regressionArcFaceCacheTests: TestEntry {
        TestEntry(
            group: .regression,
            module: "ArcFace",
            name: "ArcFace reference embedding cache",
            description: "PersonFinderEngineDispatchTests — pins the 2026-05-12 crash fix",
            supportsCoverage: true
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/PersonFinderEngineDispatchTests",
                entrySupportsCoverage: true,
                log: log,
                timeoutSeconds: 600
            )
        }
    }

    static var regressionPersonFinderEngineDispatch: TestEntry {
        TestEntry(
            group: .regression,
            module: "Person Finder",
            name: "Engine dispatch bail paths",
            description: "Force-unwrap restructure + cancel + missing-python coverage",
            supportsCoverage: true
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/PersonFinderEngineDispatchTests",
                entrySupportsCoverage: true,
                log: log,
                timeoutSeconds: 600
            )
        }
    }

    static var regressionVolumeReachabilityCache: TestEntry {
        TestEntry(
            group: .regression,
            module: "Catalog",
            name: "VolumeReachability cache (issue #87)",
            description: "Pins the per-volume TTL cache contract that fixed the beachball",
            supportsCoverage: true
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/VolumeReachabilityBoundaryTests",
                entrySupportsCoverage: true,
                log: log,
                timeoutSeconds: 600
            )
        }
    }

    // MARK: - xcodebuild helper

    /// Runs xcodebuild test on the chosen host. Reads `coverageContext` to
    /// decide whether to pass `-enableCodeCoverage YES` and capture an
    /// xcresult for `xccov` parsing.
    private static func runXcodebuildTest(
        host: TestHost,
        configuration: String,
        onlyTesting: String,
        entrySupportsCoverage: Bool,
        log: @escaping @Sendable (String) -> Void,
        timeoutSeconds: TimeInterval
    ) async -> TestResult {
        let started = Date()
        // Compute whether THIS entry should collect coverage. Unit entries
        // always count when coverage is on; regression entries only when
        // the "Include All" toggle is set (they're useful for delta-style
        // coverage runs).
        let ctx = coverageContext
        let collectCoverage: Bool = {
            guard ctx.enabled, entrySupportsCoverage else { return false }
            // Both unit + regression entries flip this flag in registerAll.
            // includeAll==true means "let regression entries contribute";
            // includeAll==false means "only the two unit-suite entries".
            if ctx.includeAll { return true }
            // Detect unit vs. regression by inspecting the onlyTesting string:
            // unit runs target the whole "VideoScanTests" bundle; regression
            // runs scope to "VideoScanTests/SomeClass".
            return !onlyTesting.contains("/")
        }()

        // MBP path: SSH + launchctl submit. Remote handles its own
        // derivedDataPath under /tmp on the MBP. Same SubprocessResult
        // shape comes back, so the parsing/summary code below is shared.
        if host == .mbp {
            log("Running xcodebuild test on \(host.displayName)")
            log("  scheme: VideoScan")
            log("  configuration: \(configuration)")
            log("  only-testing: \(onlyTesting)")
            if collectCoverage { log("  coverage: ON (remote)") }
            let result = await MBPRemote.runXcodebuildTest(
                configuration: configuration,
                onlyTesting: onlyTesting,
                coverage: collectCoverage,
                log: log,
                timeoutSeconds: timeoutSeconds
            )
            return summarize(result: result,
                             log: log,
                             elapsed: Date().timeIntervalSince(started),
                             xcresultPath: nil)
        }

        // Reuse a single derivedDataPath for every xcodebuild invocation
        // in this process so incremental builds kick in for suite #2 and
        // beyond. xcresult bundles still need to be unique per call —
        // xcodebuild errors if `-resultBundlePath` points at an existing
        // directory.
        let dd = sharedDerivedDataPath
        let xcresultPath = dd + "/Coverage-\(UUID().uuidString.prefix(8)).xcresult"
        log("Running xcodebuild test")
        log("  scheme: VideoScan")
        log("  configuration: \(configuration)")
        log("  only-testing: \(onlyTesting)")
        log("  derivedDataPath: \(dd) (shared this session)")
        if collectCoverage { log("  coverage: ON -> \(xcresultPath)") }
        log("(this may take several minutes — output streamed below)")

        // Release config doesn't build with `-enable-testing` by default,
        // so `@testable import VideoScan` in the test target fails to link.
        // ENABLE_TESTABILITY=YES forces the flag for this build invocation
        // without changing project settings. The CI workflow has the same
        // setting in ci.yml line ~196. xcodebuild exit 65 with 0/0 tests
        // and "incompatible module" in the log is the symptom.
        var args = [
            "test",
            "-project", projectDir + "/VideoScan/VideoScan.xcodeproj",
            "-scheme", "VideoScan",
            "-configuration", configuration,
            "-destination", "platform=macOS",
            "-derivedDataPath", dd,
            "-only-testing:\(onlyTesting)",
            "CODE_SIGNING_ALLOWED=NO"
        ]
        if configuration == "Release" {
            args.append("ENABLE_TESTABILITY=YES")
        }
        if collectCoverage {
            args.append("-enableCodeCoverage")
            args.append("YES")
            args.append("-resultBundlePath")
            args.append(xcresultPath)
        }

        let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        let localResult = await Subprocess.run(
            xcodebuild,
            args,
            timeoutSeconds: timeoutSeconds,
            // Only stream lines that look meaningful — xcodebuild emits
            // many tens of thousands of build-system lines that would
            // flood the UI. We surface test events from both XCTest
            // (`Test Case`, `Test Suite`) and Swift Testing (◇ / ✔ / ✘),
            // plus errors and the final summary.
            stdoutLine: { line in
                if line.contains("Test Case") ||
                   line.contains("Test Suite") ||
                   line.contains("TEST SUCCEEDED") ||
                   line.contains("TEST FAILED") ||
                   line.contains("◇ Test") ||
                   line.contains("✔ Test") ||
                   line.contains("✘ Test") ||
                   line.contains("Test run with") ||
                   line.contains("error:") ||
                   line.contains("warning:") && line.contains("VideoScan") {
                    log(line)
                }
            },
            stderrLine: nil
        )
        return summarize(result: localResult,
                         log: log,
                         elapsed: Date().timeIntervalSince(started),
                         xcresultPath: collectCoverage ? xcresultPath : nil)
    }

    /// Convert a SubprocessResult from xcodebuild test (local OR remote)
    /// into a TestResult. Counts of underlying XCTest methods flow into
    /// `methodCounts` so the banner can sum them.
    private static func summarize(
        result: SubprocessResult,
        log: @escaping @Sendable (String) -> Void,
        elapsed: Double,
        xcresultPath: String?
    ) -> TestResult {
        let counts = parseTestCounts(from: result.stdout)
        let passed = counts.passed
        let failed = counts.failed

        if result.timedOut {
            log("--- summary --- TIMED OUT")
            return .failed("Timed out (\(Int(elapsed))s)",
                           duration: elapsed,
                           log: String(result.stdout.suffix(2000)),
                           methodCounts: counts)
        }

        log("--- summary ---")
        log("Passed: \(passed), Failed: \(failed), xcodebuild exit: \(result.exitCode)")

        // Pull coverage if we have an xcresult and the run produced output.
        let coverage = xcresultPath.flatMap { extractCoveragePercent(xcresultPath: $0, log: log) }
        if let cov = coverage {
            log(String(format: "Coverage (logic): %.2f%%", cov))
        }

        if result.exitCode != 0 || failed > 0 {
            let tail = String(result.stdout.split(separator: "\n").suffix(40).joined(separator: "\n"))
            // Known exit-65 with 0 passes pattern: testability flag missing.
            if result.exitCode == 65, passed == 0,
               result.stdout.contains("module built without '-enable-testing'") ||
               result.stdout.contains("Unable to resolve Swift module dependency") {
                return .failed(
                    "Build was not built with -enable-testing (Release defaults to off). " +
                    "TestDriver passes ENABLE_TESTABILITY=YES for Release.",
                    duration: elapsed,
                    log: tail,
                    methodCounts: counts,
                    coveragePercent: coverage)
            }
            // SSH-specific: connection failure shows up as exit 255.
            if result.exitCode == 255 {
                return .failed(
                    "SSH connection failed (exit 255). Check that the MBP is awake, " +
                    "logged in, and reachable at ricksmacbookpro.local.",
                    duration: elapsed,
                    log: result.stderr.isEmpty ? tail : result.stderr,
                    methodCounts: counts,
                    coveragePercent: coverage)
            }
            return .failed("\(failed) failed of \(passed + failed) (xcodebuild exit \(result.exitCode))",
                           duration: elapsed,
                           log: tail,
                           methodCounts: counts,
                           coveragePercent: coverage)
        }
        if passed == 0 {
            return .failed("0 tests executed — Swift Testing discovery may have skipped silently",
                           duration: elapsed,
                           log: String(result.stdout.suffix(1000)),
                           methodCounts: counts,
                           coveragePercent: coverage)
        }
        return .passed(elapsed,
                       log: "\(passed) tests passed",
                       methodCounts: counts,
                       coveragePercent: coverage)
    }

    /// Tally passed and failed test methods from xcodebuild's stdout.
    /// Handles both runtimes:
    ///   - XCTest lines look like:
    ///       Test Case '-[FooTests testBar]' passed on 'My Mac' (0.001 seconds)
    ///   - Swift Testing lines look like:
    ///       ✔ Test sha256Matches() passed after 0.001 seconds.
    ///       ✘ Test foo() recorded an issue at Foo.swift:42
    ///       ✘ Test foo() failed after 0.001 seconds with 1 issue.
    ///       ✘ Suite FooTests failed after 0.001 seconds with 1 issue.
    ///       ✘ Test run with 2 tests in 1 suite failed after ...
    /// xcodebuild's own bookkeeping (`Executed N tests`) only sees XCTest
    /// methods and silently reports 0 for Swift Testing suites, so the
    /// previous parser was returning a phantom "0 tests executed" failure
    /// even when every Swift Testing case passed.
    ///
    /// For Swift Testing we match only the canonical per-test summary
    /// markers — `passed after ` / `failed after ` — and explicitly
    /// exclude the run-level summary (`✘ Test run with …`) and the
    /// recorded-issue marker (which can fire multiple times for one
    /// failing test). Without those filters a single failing test was
    /// counted 3× (recorded + failed + run-summary).
    private static func parseTestCounts(from stdout: String) -> (passed: Int, failed: Int) {
        // XCTest format (legacy).
        let xcPassed = stdout.components(separatedBy: " passed on ").count - 1
        let xcFailed = stdout.components(separatedBy: " failed on ").count - 1

        // Swift Testing — line-oriented so we can exclude the run-summary
        // and recorded-issue noise.
        var stPassed = 0
        var stFailed = 0
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // Skip the test-run-wide summary so it doesn't double-count.
            if line.contains("Test run with ") { continue }
            if line.contains("✔ Test "), line.contains(" passed after ") {
                stPassed += 1
            } else if line.contains("✘ Test "), line.contains(" failed after ") {
                // `failed after` only appears on the per-test summary line,
                // not on `recorded an issue at …` lines. So this counts
                // each failing test exactly once.
                stFailed += 1
            }
        }

        return (passed: xcPassed + stPassed, failed: xcFailed + stFailed)
    }

    /// Invoke `xcrun xccov view --report --json <xcresult>` and aggregate
    /// `executableLines` / `coveredLines` across non-UI-test targets.
    /// Returns nil if anything goes wrong — coverage is best-effort.
    private static func extractCoveragePercent(xcresultPath: String,
                                               log: @escaping @Sendable (String) -> Void) -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["xccov", "view", "--report", "--json", xcresultPath]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            log("xccov launch failed: \(error.localizedDescription)")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = json["targets"] as? [[String: Any]] else {
            log("xccov produced no parseable report")
            return nil
        }
        var totalExecutable = 0
        var totalCovered = 0
        for target in targets {
            let name = (target["name"] as? String) ?? ""
            // Skip UI test targets — they don't represent code under test.
            if name.hasSuffix("UITests") || name.contains("UITests.xctest") { continue }
            let executable = (target["executableLines"] as? Int) ?? 0
            let covered = (target["coveredLines"] as? Int) ?? 0
            totalExecutable += executable
            totalCovered += covered
        }
        guard totalExecutable > 0 else { return nil }
        return (Double(totalCovered) / Double(totalExecutable)) * 100.0
    }
}
