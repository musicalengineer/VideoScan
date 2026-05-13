// VideoScanTests.swift
//
// Initial set of tests TestDriver runs against VideoScan. All black-box —
// they invoke external tools, read prefs, sample the running process,
// scan crash logs. No linkage to VideoScan's Swift module.
//
// Add new tests by appending to `VideoScanTests.all` below.

import Foundation

enum VideoScanTests {

    /// Bundle ID of the VideoScan app, used for defaults reads and
    /// crash-log filtering.
    static let bundleID = "Rick-Breen.VideoScan"

    /// Path to the running app binary (Xcode-built debug/release).
    static let runningProcessName = "VideoScan.app/Contents/MacOS/VideoScan"

    /// Project directory — used for xcodebuild test invocations.
    static let projectDir = NSHomeDirectory() + "/dev/VideoScan"

    /// Register every test in this file with the global registry.
    static func registerAll() {
        TestRegistry.shared.register([
            smokeAppBinaryExists,
            smokeArcFaceModelPresent,
            smokeReachabilityCachePresent,
            diagnosticDefaultsPollutionCheck,
            diagnosticRecentCrashScan,
            diagnosticMainThreadStuckSyscalls,
            unitFullSuiteDebug,
            regressionArcFaceCacheTests,
            regressionPersonFinderEngineDispatch
        ])
    }

    // MARK: - Smoke

    static var smokeAppBinaryExists: TestEntry {
        TestEntry(
            group: .smoke,
            name: "VideoScan binary built and present",
            description: "Locate the most recent Xcode-built VideoScan.app binary"
        ) { log in
            let started = Date()
            log("Searching ~/Library/Developer/Xcode/DerivedData for VideoScan.app...")
            let result = await Subprocess.run("/usr/bin/find", [
                NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData",
                "-name", "VideoScan.app",
                "-type", "d",
                "-maxdepth", "8"
            ], timeoutSeconds: 30)
            let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
            log("Found \(lines.count) VideoScan.app instance(s)")
            for ln in lines.prefix(5) { log("  \(ln)") }
            let elapsed = Date().timeIntervalSince(started)
            if lines.isEmpty {
                return .failed("No VideoScan.app found in DerivedData — build the app from Xcode first",
                               duration: elapsed,
                               log: result.stdout + result.stderr)
            }
            return .passed(elapsed, log: result.stdout)
        }
    }

    static var smokeArcFaceModelPresent: TestEntry {
        TestEntry(
            group: .smoke,
            name: "ArcFace CoreML model present",
            description: "w600k_r50.mlmodelc or .mlpackage exists in expected location"
        ) { log in
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
            name: "VolumeReachability cache code present (issue #87 fix landed)",
            description: "Source file mentions invalidateCache, indicating the per-volume TTL fix is in place"
        ) { log in
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

    /// Detects pref-pollution like the codex incident (pf_previewRate=25).
    /// Reads the unsandboxed defaults plist and reports any pf_ key with a
    /// known-suspicious value. Easy to extend.
    static var diagnosticDefaultsPollutionCheck: TestEntry {
        TestEntry(
            group: .diagnostic,
            name: "Defaults pollution check",
            description: "Inspects pf_ keys in Rick-Breen.VideoScan defaults for stress-test residue"
        ) { log in
            let started = Date()
            let plist = NSHomeDirectory() + "/Library/Preferences/\(bundleID).plist"
            log("Reading \(plist)")
            let result = await Subprocess.run("/usr/bin/defaults", ["read", plist], timeoutSeconds: 5)
            let elapsed = Date().timeIntervalSince(started)
            if !result.didSucceed {
                return .skipped("No defaults plist found at \(plist)",
                                log: result.stderr)
            }

            // Suspicious values that suggest stress-test pollution.
            let suspicious: [(String, String, String)] = [
                ("pf_previewRate", "25", "Codex stress harness sets 25; default is 5"),
                ("pf_frameStep", "1",  "frameStep=1 means every frame sampled (5× normal load)"),
                ("pf_concurrency", "32", "concurrency=32 is the stress-test value; default is 4")
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

    /// Scans ~/Library/Logs/DiagnosticReports/ for VideoScan crash reports
    /// in the last 24 hours.
    static var diagnosticRecentCrashScan: TestEntry {
        TestEntry(
            group: .diagnostic,
            name: "Recent VideoScan crash logs",
            description: "Scans ~/Library/Logs/DiagnosticReports for VideoScan-*.ips files in last 24h"
        ) { log in
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

    /// Samples the running VideoScan process for 3 seconds and looks for
    /// the main thread stuck in a syscall (the issue #87 signature).
    static var diagnosticMainThreadStuckSyscalls: TestEntry {
        TestEntry(
            group: .diagnostic,
            name: "Main thread stuck in syscall (issue #87 signature)",
            description: "Samples running VideoScan for 3s; flags if main is 100% in stat() / read() / select()"
        ) { log in
            let started = Date()
            let pgrep = await Subprocess.run("/usr/bin/pgrep", ["-f", runningProcessName])
            let pidStr = pgrep.stdout.split(separator: "\n").first.map(String.init) ?? ""
            guard let pid = Int(pidStr.trimmingCharacters(in: .whitespaces)) else {
                return .skipped("VideoScan not running", log: "pgrep returned no PID")
            }
            log("Sampling PID \(pid) for 3 seconds...")
            let sample = await Subprocess.run("/usr/bin/sample", [String(pid), "3"], timeoutSeconds: 15)
            let elapsed = Date().timeIntervalSince(started)
            // Look for the issue #87 signature: main-thread frames whose
            // top is a blocking syscall.
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
            name: "Full XCTest suite (Debug)",
            description: "Runs xcodebuild test against VideoScanTests on this machine"
        ) { log in
            let started = Date()
            let dd = NSTemporaryDirectory() + "testdriver-dd"
            log("Building + running tests, derivedDataPath=\(dd)")
            log("(this may take several minutes)")
            let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
            let result = await Subprocess.run(xcodebuild, [
                "test",
                "-project", projectDir + "/VideoScan/VideoScan.xcodeproj",
                "-scheme", "VideoScan",
                "-destination", "platform=macOS",
                "-derivedDataPath", dd,
                "-only-testing:VideoScanTests"
            ], timeoutSeconds: 1800)
            let elapsed = Date().timeIntervalSince(started)
            let passed = result.stdout.components(separatedBy: " passed on ").count - 1
            let failed = result.stdout.components(separatedBy: " failed on ").count - 1
            log("Passed: \(passed), Failed: \(failed)")
            if !result.didSucceed || failed > 0 {
                let tail = result.stdout.split(separator: "\n").suffix(40).joined(separator: "\n")
                return .failed("Suite failed: \(failed) failed of \(passed + failed)",
                               duration: elapsed, log: String(tail))
            }
            return .passed(elapsed, log: "All \(passed) tests passed")
        }
    }

    static var regressionArcFaceCacheTests: TestEntry {
        TestEntry(
            group: .regression,
            name: "ArcFace reference cache tests",
            description: "Runs the two cache-invariant tests (PersonFinderEngineDispatchTests)"
        ) { log in
            await runOnly(testing: "VideoScanTests/PersonFinderEngineDispatchTests", log: log)
        }
    }

    static var regressionPersonFinderEngineDispatch: TestEntry {
        TestEntry(
            group: .regression,
            name: "PersonFinder engine dispatch bail paths",
            description: "Runs the dispatch coverage tests (force-unwrap, cancel, missing python)"
        ) { log in
            await runOnly(testing: "VideoScanTests/PersonFinderEngineDispatchTests", log: log)
        }
    }

    private static func runOnly(testing target: String, log: @escaping (String) -> Void) async -> TestResult {
        let started = Date()
        let dd = NSTemporaryDirectory() + "testdriver-dd"
        log("xcodebuild test -only-testing:\(target)")
        let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        let result = await Subprocess.run(xcodebuild, [
            "test",
            "-project", projectDir + "/VideoScan/VideoScan.xcodeproj",
            "-scheme", "VideoScan",
            "-destination", "platform=macOS",
            "-derivedDataPath", dd,
            "-only-testing:\(target)"
        ], timeoutSeconds: 600)
        let elapsed = Date().timeIntervalSince(started)
        let passed = result.stdout.components(separatedBy: " passed on ").count - 1
        let failed = result.stdout.components(separatedBy: " failed on ").count - 1
        if !result.didSucceed || failed > 0 {
            let tail = result.stdout.split(separator: "\n").suffix(20).joined(separator: "\n")
            return .failed("\(failed) failed of \(passed + failed)",
                           duration: elapsed, log: String(tail))
        }
        return .passed(elapsed, log: "\(passed) tests passed")
    }
}
