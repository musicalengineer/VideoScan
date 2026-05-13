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
            description: "Runs xcodebuild test against VideoScanTests, Debug config"
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests",
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
            description: "Same suite under Release optimization — catches optimizer-only bugs"
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Release",
                onlyTesting: "VideoScanTests",
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
            description: "PersonFinderEngineDispatchTests — pins the 2026-05-12 crash fix"
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/PersonFinderEngineDispatchTests",
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
            description: "Force-unwrap restructure + cancel + missing-python coverage"
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/PersonFinderEngineDispatchTests",
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
            description: "Pins the per-volume TTL cache contract that fixed the beachball"
        ) { host, log in
            await runXcodebuildTest(
                host: host,
                configuration: "Debug",
                onlyTesting: "VideoScanTests/VolumeReachabilityBoundaryTests",
                log: log,
                timeoutSeconds: 600
            )
        }
    }

    // MARK: - xcodebuild helper

    /// Runs xcodebuild test on the chosen host. For now only `.macStudio`
    /// (local) is implemented; `.mbp` returns .unclear with a stub message
    /// so the user sees what's missing.
    private static func runXcodebuildTest(
        host: TestHost,
        configuration: String,
        onlyTesting: String,
        log: @escaping @Sendable (String) -> Void,
        timeoutSeconds: TimeInterval
    ) async -> TestResult {
        let started = Date()

        // MBP path: SSH + launchctl submit. Remote handles its own
        // derivedDataPath under /tmp on the MBP. Same SubprocessResult
        // shape comes back, so the parsing/summary code below is shared.
        if host == .mbp {
            log("Running xcodebuild test on \(host.rawValue)")
            log("  scheme: VideoScan")
            log("  configuration: \(configuration)")
            log("  only-testing: \(onlyTesting)")
            let result = await MBPRemote.runXcodebuildTest(
                configuration: configuration,
                onlyTesting: onlyTesting,
                log: log,
                timeoutSeconds: timeoutSeconds
            )
            return summarize(result: result, log: log,
                             elapsed: Date().timeIntervalSince(started))
        }

        // Unique derived data path per run to avoid colliding with any
        // VideoScan instance Rick has open + with concurrent TestDriver runs.
        let dd = NSTemporaryDirectory() + "testdriver-dd-\(UUID().uuidString.prefix(8))"
        log("Running xcodebuild test")
        log("  scheme: VideoScan")
        log("  configuration: \(configuration)")
        log("  only-testing: \(onlyTesting)")
        log("  derivedDataPath: \(dd)")
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

        let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        let localResult = await Subprocess.run(
            xcodebuild,
            args,
            timeoutSeconds: timeoutSeconds,
            // Only stream lines that look meaningful — xcodebuild emits
            // many tens of thousands of build-system lines that would
            // flood the UI. We surface test-case events, errors, and the
            // final summary.
            stdoutLine: { line in
                if line.contains("Test Case") ||
                   line.contains("Test Suite") ||
                   line.contains("TEST SUCCEEDED") ||
                   line.contains("TEST FAILED") ||
                   line.contains("error:") ||
                   line.contains("warning:") && line.contains("VideoScan") {
                    log(line)
                }
            },
            stderrLine: nil
        )
        return summarize(result: localResult, log: log,
                         elapsed: Date().timeIntervalSince(started))
    }

    /// Convert a SubprocessResult from xcodebuild test (local OR remote)
    /// into a TestResult. Same pass/fail/unclear logic for both paths.
    private static func summarize(
        result: SubprocessResult,
        log: @escaping @Sendable (String) -> Void,
        elapsed: Double
    ) -> TestResult {
        if result.timedOut {
            return .unclear("Timed out (\(Int(elapsed))s)",
                            duration: elapsed,
                            log: String(result.stdout.suffix(2000)))
        }

        let passed = result.stdout.components(separatedBy: " passed on ").count - 1
        let failed = result.stdout.components(separatedBy: " failed on ").count - 1
        log("--- summary ---")
        log("Passed: \(passed), Failed: \(failed), xcodebuild exit: \(result.exitCode)")

        if result.exitCode != 0 || failed > 0 {
            let tail = String(result.stdout.split(separator: "\n").suffix(40).joined(separator: "\n"))
            // Known exit-65 with 0 passes pattern: testability flag missing.
            if result.exitCode == 65, passed == 0,
               result.stdout.contains("module built without '-enable-testing'") ||
               result.stdout.contains("Unable to resolve Swift module dependency") {
                return .unclear(
                    "Build was not built with -enable-testing (Release defaults to off). " +
                    "TestDriver passes ENABLE_TESTABILITY=YES for Release.",
                    duration: elapsed,
                    log: tail)
            }
            // SSH-specific: connection failure shows up as exit 255.
            if result.exitCode == 255 {
                return .unclear(
                    "SSH connection failed (exit 255). Check that the MBP is awake, " +
                    "logged in, and reachable at ricksmacbookpro.local.",
                    duration: elapsed,
                    log: result.stderr.isEmpty ? tail : result.stderr)
            }
            return .failed("\(failed) failed of \(passed + failed) (xcodebuild exit \(result.exitCode))",
                           duration: elapsed, log: tail)
        }
        if passed == 0 {
            return .unclear("0 tests executed — Swift Testing discovery may have skipped silently",
                            duration: elapsed,
                            log: String(result.stdout.suffix(1000)))
        }
        return .passed(elapsed, log: "\(passed) tests passed")
    }
}
