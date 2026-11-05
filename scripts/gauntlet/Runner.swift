#!/usr/bin/swift
// Phase 1 orchestration only. This CLI intentionally does not launch UI tests.
import Foundation
import Darwin

let fm = FileManager.default
let stageOrder = ["unit", "regression", "integration", "performance", "hallie", "stress", "ui"]
var interrupted: Int32 = 0
func onSignal(_ value: Int32) { interrupted = value }
func monotonic() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
struct RunError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
func readObject(_ path: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else { throw RunError("invalid JSON object: \(path.path)") }
    return object
}
// Resolve existing ancestors too: appending a not-yet-created child to a symlink
// must not turn the checked lexical path into permission to write elsewhere.
func canonicalPath(_ url: URL) throws -> String {
    var existing = url.path
    var suffix: [String] = []
    while !fm.fileExists(atPath: existing) {
        suffix.insert(URL(fileURLWithPath: existing).lastPathComponent, at: 0)
        let parent = URL(fileURLWithPath: existing).deletingLastPathComponent().path
        guard parent != existing else { throw RunError("cannot resolve write path") }
        existing = parent
    }
    guard let resolved = realpath(existing, nil) else { throw RunError("cannot canonicalize write path") }
    defer { free(resolved) }
    return ([String(cString: resolved)] + suffix).joined(separator: "/")
}
func guarded(_ path: URL, under root: URL) throws -> URL {
    let canonicalRoot = try canonicalPath(root)
    let canonical = try canonicalPath(path)
    guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else { throw RunError("write allowlist refused: \(path.path)") }
    guard canonical == path.path else { throw RunError("symlink write escape refused: \(path.path)") }
    return URL(fileURLWithPath: canonical)
}
func write(_ data: Data, to path: URL, root: URL) throws {
    let safe = try guarded(path, under: root)
    try data.write(to: safe, options: .atomic)
}
func append(_ data: Data, to path: URL, root: URL) throws {
    let safe = try guarded(path, under: root)
    if !fm.fileExists(atPath: safe.path) { try write(Data(), to: safe, root: root) }
    let handle = try FileHandle(forWritingTo: safe)
    defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: data)
}
struct CommandResult { var code: Int32; var timedOut = false; var contaminated = false; var elapsed: Double }
// Same ownership protocol as nightly_local_tests.sh: private process group,
// retain the unreaped leader throughout TERM/grace/KILL to reserve its PGID.
// posix_spawn is used here because Foundation Process cannot atomically set PGID.
func command(_ arguments: [String], log: URL, timeout: Double, environment: [String: String]? = nil) throws -> CommandResult {
    let start = monotonic()
    guard log.path == (try canonicalPath(log)) else { throw RunError("symlink command log refused") }
    let fd = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw RunError("cannot open command log") }
    defer { close(fd) }
    var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, fd)
    var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attr, 0)
    let argStrings = arguments.map { strdup($0) }
    let envStrings = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
    defer { argStrings.forEach { free($0) }; envStrings.forEach { free($0) } }
    var argv = argStrings + [nil]; var envp = envStrings + [nil]; var pid: pid_t = 0
    let launched = posix_spawnp(&pid, arguments[0], &actions, &attr, &argv, &envp)
    guard launched == 0 else { throw RunError("spawn \(arguments[0]): \(String(cString: strerror(launched)))") }
    var status: Int32 = 0
    var orphanedDescendants = false
    while monotonic() - start < timeout && interrupted == 0 {
        var information = siginfo_t()
        let found = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if found == 0 && information.si_pid == pid {
            // Keep the exited leader reserved until its group is empty. A
            // daemonized child still in this group must not overlap a stage.
            if kill(-pid, 0) == 0 { orphanedDescendants = true; break }
            guard waitpid(pid, &status, WNOHANG) == pid else { throw RunError("could not reap exited leader") }
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return CommandResult(code: code, elapsed: monotonic() - start)
        }
        if found < 0 && errno != EINTR { throw RunError("waitpid failed") }
        usleep(100_000)
    }
    let timeoutReached = interrupted == 0 && !orphanedDescendants
    _ = kill(-pid, SIGTERM)
    usleep(500_000)
    _ = kill(-pid, SIGKILL)
    let end = monotonic() + 1
    while kill(-pid, 0) == 0 && monotonic() < end { usleep(10_000) }
    let alive = kill(-pid, 0) == 0
    let reaped = alive ? false : waitpid(pid, &status, WNOHANG) == pid
    return CommandResult(code: orphanedDescendants ? 125 : timeoutReached ? 124 : 128 + interrupted, timedOut: timeoutReached, contaminated: !reaped || orphanedDescendants, elapsed: monotonic() - start)
}
func capture(_ arguments: [String]) -> String {
    let pipe = Pipe(); let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } catch { return "" }
}
func classify(exitCode: Int32, counts: [String: Int]?, floor: Int) -> (String, String?) {
    if exitCode != 0 { return ("failed", "command exit \(exitCode)") }
    guard let counts else { return ("failed", "structured test counts unavailable") }
    if counts["failed", default: 0] > 0 { return ("failed", "test failures") }
    if counts["skipped", default: 0] > 0 { return ("failed", "unexpected skipped tests") }
    let known = counts["known_issues", default: 0]
    if counts["passed", default: 0] + counts["failed", default: 0] + known < max(1, floor) { return ("failed", "executed count below expected floor \(max(1, floor))") }
    // A withKnownIssue is a tracked bug, never a pass — and never a failure
    // either: AMBER (Rick 2026-11-05, DECISIONS). Said by name and count.
    if known > 0 { return ("amber", "\(known) known issue\(known == 1 ? "" : "s") (withKnownIssue) — tracked, not a pass") }
    return ("passed", nil)
}
func countsFromSummary(_ object: [String: Any]) -> [String: Int]? {
    guard let passed = object["passedTests"] as? Int, let failed = object["failedTests"] as? Int, let skipped = object["skippedTests"] as? Int else { return nil }
    guard passed >= 0 && failed >= 0 && skipped >= 0 else { return nil }
    let known = object["expectedFailures"] as? Int ?? 0
    guard known >= 0, let total = object["totalTestCount"] as? Int, total == passed + failed + skipped + known,
          let verdict = object["result"] as? String, ["Passed", "Failed", "Skipped"].contains(verdict),
          verdict != "Failed" || failed > 0 else { return nil }
    return ["passed": passed, "failed": failed, "skipped": skipped, "known_issues": known]
}
// The package adapter's counts (2026-11-05). The console is for humans: a
// concurrent test's stdout can split a result line (M4 deep run at 2c8fa9777
// counted 774 of 775) or forge one. Swift Testing is counted from its event
// stream (`swift test --event-stream-output-path`: one JSON record a line,
// written by the testing library to its own file, so test stdout never
// touches it); XCTest, which has no stream and runs serially, from its own
// "Test Case '-[…]' passed/failed/skipped (" lines, matched anywhere in a line.
// One count per test function (a parameterized test is one, its cases are
// not), the same unit the floors are declared in. nil = counts unavailable
// (a RED stage): no runEnded, a torn record, or an event for an undeclared id.
// Memory: the stream is read whole; ~6 records per test, ~300 B each, so a
// 1,000-test stage is ~2 MB and the 20k-test scale sensor ~40 MB.
func countsFromPackageRun(eventStream: String, console: String) -> [String: Int]? {
    guard var counts = SwiftTestingTally(eventStream: eventStream)?.counts else { return nil }
    let xctest = try! NSRegularExpression(pattern: #"Test Case '-\[[^\]]+\]' (passed|failed|skipped) \("#)
    for match in xctest.matches(in: console, range: NSRange(console.startIndex..., in: console)) {
        let word = (console as NSString).substring(with: match.range(at: 1))
        counts[word == "passed" ? "passed" : word == "failed" ? "failed" : "skipped", default: 0] += 1
    }
    return counts
}

/// Swift Testing outcomes per function id, from one event stream. Sets, so a
/// repeated event never double counts (like a std::set keyed by test id).
struct SwiftTestingTally {
    var kinds: [String: String] = [:]                                  // id -> "function" / "suite"
    var ended = Set<String>(), skipped = Set<String>(), failed = Set<String>(), known = Set<String>()
    var unattributedFailures = 0

    /// nil = unavailable: a torn record, an event for an undeclared id, no runEnded.
    init?(eventStream: String) {
        var events: [[String: Any]] = []
        for line in eventStream.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return nil }
            if object["kind"] as? String == "test", let id = payload["id"] as? String { kinds[id] = payload["kind"] as? String ?? "" }
            if object["kind"] as? String == "event" { events.append(payload) }
        }
        var sawRunEnded = false
        for payload in events {
            if payload["kind"] as? String == "runEnded" { sawRunEnded = true; continue }
            guard record(payload) else { return nil }
        }
        guard sawRunEnded else { return nil }
    }

    /// Fold one event in; false when it names a test the stream never declared.
    mutating func record(_ payload: [String: Any]) -> Bool {
        let id = payload["testID"] as? String
        if let id, kinds[id] == nil { return false }
        guard let id, kinds[id] == "function" else {
            // Not a function (suite / run level): only a failure matters, and it is RED.
            if Self.isFailure(payload) { unattributedFailures += 1 }
            return true
        }
        switch payload["kind"] as? String ?? "" {
        case "issueRecorded":
            if Self.isFailure(payload) { failed.insert(id) } else if (payload["issue"] as? [String: Any])?["isKnown"] as? Bool == true { known.insert(id) }
        case "testEnded": ended.insert(id)
        case "testSkipped": skipped.insert(id)
        case "testCancelled", "testCaseCancelled": failed.insert(id)       // cancelled is not a pass
        default: break
        }
        return true
    }

    /// A failing issue or a cancel. Stream v0 has no isFailure: any issue not known fails there.
    static func isFailure(_ payload: [String: Any]) -> Bool {
        switch payload["kind"] as? String ?? "" {
        case "testCancelled", "testCaseCancelled": return true
        case "issueRecorded":
            let issue = payload["issue"] as? [String: Any] ?? [:]
            return !(issue["isKnown"] as? Bool ?? false) && (issue["isFailure"] as? Bool ?? true)
        default: return false
        }
    }

    /// A failure wins over a known issue; a failure counts ended or not.
    var counts: [String: Int] {
        let knownOnly = ended.subtracting(failed).intersection(known)
        return ["passed": ended.subtracting(failed).subtracting(knownOnly).subtracting(skipped).count,
                "failed": failed.count + unattributedFailures,
                "skipped": skipped.subtracting(failed).count, "known_issues": knownOnly.count]
    }
}
func stageResult(_ name: String, _ status: String, _ reason: String?, floor: Int = 0) -> [String: Any] {
    ["name": name, "status": status, "reason": reason as Any? ?? NSNull(), "exit_code": NSNull(), "elapsed_s": 0.0, "expected": floor, "passed": NSNull(), "failed": NSNull(), "skipped": NSNull(), "incomplete": status == "passed" ? 0 : 1, "artifacts": []]
}

// A value-type run context; mutating methods are like non-const C++ members.
struct GauntletRunner {
    let repo: URL
    var arguments: [String]
    var away = false
    var dry = false
    var queueOnly = false
    var machine = "m4"
    var only = Set(stageOrder)
    var manifestPath: URL
    var resultsRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan/gauntlet")
    var stages: [[String: Any]] = []
    var stageMap: [String: [String: Any]] = [:]
    var validationErrors: [String] = []
    var stamp = ""
    var runID = ""
    var run = URL(fileURLWithPath: "/")
    var totalStart = 0.0
    var environment: [String: String] = [:]
    var roots: [String: String] = [:]
    var result: [String: Any] = [:]
    var outputs: [[String: Any]] = []
    var buildOK = false
    var contaminated = false
    var fatalReason: String?
    var xctestrun: URL?
    /// The package adapter's one build (nil = not needed / not attempted).
    var packageBuildOK: Bool?
    var packageBuildReason: String?
    var packagePath: URL { repo.appendingPathComponent("VideoScan/VideoScanCore") }
    var packageScratch: String { run.appendingPathComponent("PackageBuild").path }

    init(repo: URL, arguments: [String]) {
        self.repo = repo
        self.arguments = arguments
        manifestPath = repo.appendingPathComponent("scripts/gauntlet/manifest.json")
    }

    mutating func parseOptions() throws -> Bool {
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--away": away = true
            case "--dry-run": dry = true
            case "--queue-only": queueOnly = true
            case "--machine", "--only", "--manifest", "--results-root":
                guard !arguments.isEmpty else { throw RunError("missing value for \(flag)") }
                let value = arguments.removeFirst()
                if flag == "--machine" { machine = value }
                if flag == "--only" { only = Set(value.split(separator: ",").map(String.init)) }
                if flag == "--manifest" { manifestPath = URL(fileURLWithPath: value).standardizedFileURL }
                if flag == "--results-root" { resultsRoot = URL(fileURLWithPath: value).standardizedFileURL }
            case "--help", "-h":
                print("run_gauntlet.sh --away [--machine m4|m5|m1] [--dry-run] [--only stage,...] [--manifest PATH] [--results-root PATH] [--queue-only]")
                return false
            default: throw RunError("unknown argument: \(flag)")
            }
        }
        return true
    }

    mutating func validateInventory() throws {
        guard away || dry else { throw RunError("--away required; test hosts must run only in an authorized away window") }
        guard ["m4", "m5", "m1"].contains(machine), !only.isEmpty, only.isSubset(of: Set(stageOrder)) else { throw RunError("invalid machine or stage selection") }
        let manifest = try readObject(manifestPath)
        guard let declaredStages = manifest["stages"] as? [[String: Any]], Set(declaredStages.compactMap { $0["name"] as? String }) == Set(stageOrder), declaredStages.count == stageOrder.count else { throw RunError("manifest must declare each stage exactly once") }
        stages = declaredStages
        stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0["name"] as! String, $0) })
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
        let validationLog = URL(fileURLWithPath: "/private/tmp/gauntlet-inventory-\(UUID().uuidString).json")
        let validationCache = "/private/tmp/gauntlet-inventory-cache-\(UUID().uuidString)"
        let validationRun = try command(["/usr/bin/swift", "-module-cache-path", validationCache, repo.appendingPathComponent("scripts/gauntlet/inventory.swift").path, "--validate", repo.path, manifestPath.path], log: validationLog, timeout: 120)
        guard !validationRun.timedOut && !validationRun.contaminated else { throw RunError("inventory watchdog failure") }
        let validation = (try? String(contentsOf: validationLog, encoding: .utf8)) ?? ""
        guard let validationData = validation.data(using: .utf8), let validationObject = try? JSONSerialization.jsonObject(with: validationData) as? [String: Any], let errors = validationObject["errors"] as? [String] else { throw RunError("inventory validation unavailable: \(validation.prefix(500))") }
        validationErrors = errors
    }

    func printPlan() {
        print("GAUNTLET DRY RUN machine=\(machine) configuration=Release")
        print("Inventory: \(validationErrors.isEmpty ? "valid" : validationErrors.joined(separator: "; "))")
        print("Isolation: per-run home, App Support, catalog, preferences, caches, logs, archive, fixtures; canonical write allowlist")
        print("Build: ONE xcodebuild build-for-testing -scheme VideoScan -testPlan VideoScan-CI -configuration Release ENABLE_TESTABILITY=YES -derivedDataPath <run>/DerivedData")
        print("Package: ONE swift build --build-tests -c release -Xswiftc -enable-testing --package-path VideoScan/VideoScanCore --scratch-path <run>/PackageBuild, then swift test --skip-build per stage with package_selectors")
        for name in stageOrder {
            let entry = stageMap[name]!
            let selectors = entry["selectors"] as? [String] ?? []
            let blocked = entry["blocked"] as? [[String: Any]] ?? []
            let packageSelectors = entry["package_selectors"] as? [String] ?? []
            let package = packageSelectors.isEmpty ? "" : " package_selectors=\(packageSelectors.count) package_expected_floor=\(entry["package_expected_floor"] ?? 0)"
            print("\(name): \(name == "ui" ? "UI not run (phase 2)" : !only.contains(name) ? "not_run (not selected)" : "test-without-building selectors=\(selectors.count) expected_floor=\(entry["expected_floor"] ?? 0)\(package) blocked=\(blocked.count)")")
        }
        print("Results: \(resultsRoot.path)/<run-id>/result.json; history.jsonl; metrics publication queued on failure")


    }

    mutating func prepareRoots() throws {
        // Only runner-owned storage is created; canonical checks precede every write.
        let allowedParents = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan"), URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()]
        guard let parent = allowedParents.first(where: { resultsRoot.path.hasPrefix($0.path + "/") }) else { throw RunError("results root must be under VideoScan logs or scratch") }
        _ = try guarded(resultsRoot, under: parent)
        try fm.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        stamp = ISO8601DateFormatter().string(from: Date())
        runID = stamp.replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        run = try guarded(resultsRoot.appendingPathComponent(runID), under: resultsRoot)
        try fm.createDirectory(at: run, withIntermediateDirectories: false)
        totalStart = monotonic()
        environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("VS_") && !key.hasPrefix("VIDEOSCAN_") && !key.hasPrefix("TEST_RUNNER_") && !key.hasPrefix("XCTest")
        }
        for key in ["home", "app-support", "catalog", "preferences", "caches", "logs", "archive", "fixtures", "tmp", "DerivedData"] {
            let path = try guarded(run.appendingPathComponent(key), under: run)
            try fm.createDirectory(at: path, withIntermediateDirectories: false)
            let probe = path.appendingPathComponent(".write-probe"); try write(Data("ok".utf8), to: probe, root: run)
            roots[key] = path.path
        }
        environment["HOME"] = roots["home"]; environment["CFFIXED_USER_HOME"] = roots["home"]; environment["TMPDIR"] = roots["tmp"]! + "/"
        // SwiftPM's manifest compiler can derive its default cache from the account
        // database rather than HOME. Give both it and Clang explicit per-run caches.
        for key in ["CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "XDG_CACHE_HOME"] {
            environment[key] = roots["caches"]!
        }
        environment["VS_UI_TEST"] = "1"; environment["CI"] = "1"
        // App test-host gates suppress production stores; these explicit roots also
        // document the future adapters' contract, not an OS-wide confinement claim.
        for (key, value) in roots { environment["VS_GAUNTLET_" + key.uppercased().replacingOccurrences(of: "-", with: "_") + "_ROOT"] = value }
    }

    mutating func prepareAdapterEnvironment() throws {
        for entry in stages {
            for (key, value) in entry["environment"] as? [String: String] ?? [:] {
                guard ["VIDEOSCAN_PERF", "VIDEOSCAN_PERF_FILE_COUNT", "VIDEOSCAN_PERF_DURATION", "VIDEOSCAN_PERF_TIME_LIMIT_MIN", "VIDEOSCAN_PERF_RESULTS"].contains(key) else { throw RunError("unsupported adapter environment key: \(key)") }
                let expanded = value.replacingOccurrences(of: "{run_dir}", with: run.path)
                if key == "VIDEOSCAN_PERF_RESULTS" { _ = try guarded(URL(fileURLWithPath: expanded), under: run) }
                environment[key] = expanded
            }
        }
    }

    mutating func initializeResult() {
        result = ["schema": 1, "run_id": runID, "ts": stamp, "commit": capture(["git", "-C", repo.path, "rev-parse", "HEAD"]), "branch": capture(["git", "-C", repo.path, "branch", "--show-current"]), "dirty": !capture(["git", "-C", repo.path, "status", "--porcelain"]).isEmpty, "machine": machine, "configuration": "Release", "binary_sha256": NSNull(), "status": "failed", "build_s": 0.0, "roots": roots, "inventory_errors": validationErrors]
    }

    /// Builds see the real HOME: since Xcode 27.1 the Metal Toolchain is a
    /// per-user downloaded component, and a build under the confined HOME fails
    /// with "missing Metal Toolchain" (M5, 2026-10-21). Confinement exists to
    /// keep TESTS away from real stores, so the test commands keep `environment`.
    var buildEnvironment: [String: String] {
        var env = environment
        let real = ProcessInfo.processInfo.environment
        for key in ["HOME", "CFFIXED_USER_HOME"] { env[key] = real[key] ?? NSHomeDirectory() }
        return env
    }

    mutating func build() throws {
        if fatalReason == nil {
            let cmd = ["xcodebuild", "build-for-testing", "-project", repo.appendingPathComponent("VideoScan/VideoScan.xcodeproj").path, "-scheme", "VideoScan", "-testPlan", "VideoScan-CI", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", roots["DerivedData"]!, "-skip-testing:VideoScanUITests", "ENABLE_TESTABILITY=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS="]
            let build = try command(cmd, log: run.appendingPathComponent("build.log"), timeout: 3600, environment: buildEnvironment)
            result["build_s"] = build.elapsed; result["build_exit_code"] = build.code
            buildOK = build.code == 0; contaminated = build.contaminated
            if !buildOK { fatalReason = build.timedOut ? "build watchdog timeout" : "build exit \(build.code)" }
        }
        let productRoot = URL(fileURLWithPath: roots["DerivedData"]!).appendingPathComponent("Build/Products")
        if buildOK {
            xctestrun = try fm.contentsOfDirectory(at: productRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }.first
            guard let testRun = xctestrun else { throw RunError("build produced no .xctestrun") }
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: testRun), format: nil)
            plist = patch(plist)
            try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: testRun, root: run)
            let binary = productRoot.appendingPathComponent("Release/VideoScan.app/Contents/MacOS/VideoScan")
            result["binary_sha256"] = capture(["/usr/bin/shasum", "-a", "256", binary.path]).split(separator: " ").first.map(String.init) as Any? ?? NSNull()
        }
    }

    /// The package adapter's ONE build (2026-10-18): the VideoScanCore
    /// package's tests in Release, in the run's own scratch path and isolated
    /// environment, only when a selected stage has package selectors. Like
    /// the app build it is never repeated between stages.
    mutating func buildPackage() throws {
        let wanted = stages.contains { entry in
            only.contains(entry["name"] as? String ?? "") && !((entry["package_selectors"] as? [String] ?? []).isEmpty)
        }
        guard wanted, fatalReason == nil, !contaminated else { return }
        let cmd = ["swift", "build", "--build-tests", "-c", "release", "-Xswiftc", "-enable-testing", "--package-path", packagePath.path, "--scratch-path", packageScratch]
        let build = try command(cmd, log: run.appendingPathComponent("package-build.log"), timeout: 3600, environment: buildEnvironment)
        result["package_build_s"] = build.elapsed; result["package_build_exit_code"] = build.code
        if build.contaminated { contaminated = true }
        packageBuildOK = build.code == 0
        if build.code != 0 { packageBuildReason = build.timedOut ? "package build watchdog timeout" : "package build exit \(build.code)" }
    }

    /// One stage's package suites: `swift test --skip-build` on the build
    /// above, one `--filter` per suite (`VideoScanCoreTests.<Suite>/`, the
    /// slash so a suite never matches a longer name), counted from the log.
    mutating func runPackageSuites(_ name: String, selectors: [String], floor: Int, timeout: Double) -> [String: Any] {
        var output: [String: Any] = ["selectors": selectors.count, "expected": floor, "status": "failed", "reason": NSNull(), "exit_code": NSNull()]
        guard packageBuildOK == true else {
            // A package build that failed is RED (Rick 2026-11-05), never "blocked".
            output["status"] = "failed"; output["reason"] = packageBuildReason ?? "package build did not run"
            return output
        }
        let filters = selectors.flatMap { ["--filter", NSRegularExpression.escapedPattern(for: $0) + "/"] }
        let log = run.appendingPathComponent("\(name)-package.log")
        let events = run.appendingPathComponent("\(name)-package-events.jsonl")
        let cmd = ["swift", "test", "--skip-build", "-c", "release", "--package-path", packagePath.path, "--scratch-path", packageScratch,
                   "--event-stream-output-path", events.path] + filters
        do {
            let execution = try command(cmd, log: log, timeout: timeout, environment: environment)
            if execution.contaminated { contaminated = true }
            output["exit_code"] = execution.code
            output["elapsed_s"] = execution.elapsed
            let counts = countsFromPackageRun(eventStream: (try? String(contentsOf: events, encoding: .utf8)) ?? "",
                                              console: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
            let verdict = classify(exitCode: execution.code, counts: counts, floor: floor)
            output["status"] = verdict.0
            output["reason"] = verdict.1 as Any? ?? NSNull()
            if let counts { for (key, value) in counts { output[key] = value } }
            if execution.timedOut { output["status"] = "failed"; output["reason"] = "package watchdog timeout" }
            if execution.contaminated { output["status"] = "failed"; output["reason"] = "unreaped process contamination" }
        } catch { output["reason"] = String(describing: error) }
        return output
    }

    func patch(_ object: Any) -> Any {
        if let list = object as? [Any] { return list.map(patch) }
        guard var dict = object as? [String: Any] else { return object }
        for (key, value) in dict { dict[key] = patch(value) }
        if dict["TestBundlePath"] != nil {
            var env = dict["EnvironmentVariables"] as? [String: String] ?? [:]
            for (key, value) in environment where key.hasPrefix("VS_") || key.hasPrefix("VIDEOSCAN_") || ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "CI"].contains(key) { env[key] = value }
            dict["EnvironmentVariables"] = env
        }
        return dict
    }

    func unavailableStage(_ name: String, entry: [String: Any], floor: Int) -> [String: Any]? {
        if name == "ui" { return stageResult(name, "not_run", "phase 2", floor: floor) }
        if !only.contains(name) { return stageResult(name, "not_run", "not selected", floor: floor) }
        if contaminated || interrupted != 0 || !buildOK { return stageResult(name, "blocked", contaminated ? "unreaped process contamination" : interrupted != 0 ? "interrupted" : fatalReason, floor: floor) }
        let selectors = entry["selectors"] as? [String] ?? []
        let blocked = entry["blocked"] as? [[String: Any]] ?? []
        let missingTools = (entry["requires_tools"] as? [String] ?? []).filter { !fm.isExecutableFile(atPath: $0) }
        // A missing tool is a broken host, not an unadapted suite: RED, not AMBER.
        if !missingTools.isEmpty { return stageResult(name, "failed", "required fixture tools unavailable: \(missingTools.joined(separator: ", "))", floor: floor) }
        let packageSelectors = entry["package_selectors"] as? [String] ?? []
        if selectors.isEmpty && packageSelectors.isEmpty { return stageResult(name, "blocked", blocked.isEmpty ? "no safe phase 1 adapter" : "unsafe or unadapted suites: \(blocked.count)", floor: floor) }
        return nil
    }

    /// Fold the package sub-run into the stage: counts add up, a package
    /// failure (or a package-only stage's verdict) decides the status, and
    /// both reasons are kept.
    func mergePackage(_ package: [String: Any], into output: inout [String: Any], xcodeRan: Bool) {
        output["package"] = package
        for key in ["passed", "failed", "skipped", "known_issues"] {
            if let value = package[key] as? Int { output[key] = (output[key] as? Int ?? 0) + value }
        }
        let packageStatus = package["status"] as? String ?? "failed"
        let packageReason = (package["reason"] as? String).map { "package: \($0)" }
        if !xcodeRan {
            output["status"] = packageStatus
            output["reason"] = packageReason as Any? ?? NSNull()
            output["exit_code"] = package["exit_code"] ?? NSNull()
        } else if packageStatus != "passed" {
            let xcodeReason = output["reason"] as? String
            output["status"] = (output["status"] as? String == "failed" || packageStatus == "failed") ? "failed" : packageStatus
            output["reason"] = [xcodeReason, packageReason].compactMap { $0 }.joined(separator: "; ")
        }
    }

    mutating func executeStage(_ name: String) -> [String: Any] {
        let entry = stageMap[name]!
        let floor = entry["expected_floor"] as? Int ?? 1
        if let unavailable = unavailableStage(name, entry: entry, floor: floor) { return unavailable }
        let selectors = entry["selectors"] as? [String] ?? []
        let packageSelectors = entry["package_selectors"] as? [String] ?? []
        let blocked = entry["blocked"] as? [[String: Any]] ?? []
        let timeout = Double(entry["timeout_s"] as? Int ?? 1800)
        let bundle = run.appendingPathComponent("\(name).xcresult")
        var output = stageResult(name, "failed", nil, floor: floor)
        output["blocked_details"] = blocked
        if let modes = entry["modes"] { output["modes"] = modes }
        let start = monotonic()
        var artifacts: [String] = []
        if !selectors.isEmpty {
            let cmd = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun!.path, "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO", "-resultBundlePath", bundle.path, "-skip-testing:VideoScanUITests"] + selectors.map { "-only-testing:\($0)" }
            do {
                let execution = try command(cmd, log: run.appendingPathComponent("\(name).log"), timeout: timeout, environment: environment)
                contaminated = execution.contaminated
                output["exit_code"] = execution.code
                let summary = run.appendingPathComponent("\(name)-summary.json")
                let extraction = try command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle.path], log: summary, timeout: 60)
                applyVerdict(execution, extraction: extraction, summary: summary, floor: floor, output: &output)
            } catch { output["reason"] = String(describing: error) }
            artifacts += [bundle.lastPathComponent, "\(name).log", "\(name)-summary.json"]
        }
        if !packageSelectors.isEmpty && !contaminated {
            let package = runPackageSuites(name, selectors: packageSelectors,
                                           floor: entry["package_expected_floor"] as? Int ?? 1, timeout: timeout)
            mergePackage(package, into: &output, xcodeRan: !selectors.isEmpty)
            artifacts += ["package-build.log", "\(name)-package.log", "\(name)-package-events.jsonl"]
        }
        // Safe subset passed, but the stage still holds unadapted suites
        // (AMBER-class); an AMBER stage keeps its status and says both.
        if output["status"] as? String == "passed" && !blocked.isEmpty {
            output["status"] = "blocked"; output["reason"] = "safe subset passed; unsafe or unadapted suites: \(blocked.count)"
        } else if output["status"] as? String == "amber" && !blocked.isEmpty {
            output["reason"] = "\(output["reason"] as? String ?? "amber"); unsafe or unadapted suites: \(blocked.count)"
        }
        output["incomplete"] = output["status"] as? String == "passed" ? 0 : 1
        output["elapsed_s"] = monotonic() - start
        output["artifacts"] = artifacts
        return output
    }

    mutating func applyVerdict(_ execution: CommandResult, extraction: CommandResult, summary: URL, floor: Int, output: inout [String: Any]) {
        let counts = extraction.code == 0 ? (try? readObject(summary)).flatMap(countsFromSummary) : nil
        let verdict = classify(exitCode: execution.code, counts: counts, floor: floor)
        output["status"] = verdict.0
        output["reason"] = verdict.1 as Any? ?? NSNull()
        if let counts { for (key, value) in counts { output[key] = value } }
        if execution.timedOut { output["reason"] = "stage watchdog timeout" }
        if execution.contaminated || extraction.contaminated { contaminated = true; output["status"] = "failed"; output["reason"] = "unreaped process contamination" }
    }

    mutating func aggregateResults() {
        for name in stageOrder where !outputs.contains(where: { $0["name"] as? String == name }) { outputs.append(stageResult(name, name == "ui" ? "not_run" : "blocked", name == "ui" ? "phase 2" : fatalReason ?? "interrupted")) }
        outputs.sort { stageOrder.firstIndex(of: $0["name"] as! String)! < stageOrder.firstIndex(of: $1["name"] as! String)! }
        for index in outputs.indices {
            let entry = stageMap[outputs[index]["name"] as! String]!
            outputs[index]["blocked_details"] = entry["blocked"] ?? []
            if let modes = entry["modes"] { outputs[index]["modes"] = modes }
        }
        result["stages"] = outputs; result["elapsed_s"] = monotonic() - totalStart
        let failed = fatalReason != nil || outputs.contains { $0["status"] as? String == "failed" }
        // GREEN = every stage passed; RED = a failure (test, floor, inventory,
        // build, watchdog); AMBER = only tracked known issues, unadapted
        // ("blocked") suites and stages not run (Rick 2026-11-05).
        result["status"] = failed ? "failed" : outputs.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "amber"
        result["amber_reasons"] = failed ? [] : amberReasons(outputs)
        if let fatalReason { result["reason"] = fatalReason }
        result["publish"] = "queued"
        if interrupted != 0 { result["interrupted_signal"] = interrupted; interrupted = 0 }
    }

    /// Why a run is AMBER, with counts: "7 known issues (regression 7)",
    /// "6 stages blocked (912 suites)", "ui not run (phase 2)".
    func amberReasons(_ stages: [[String: Any]]) -> [String] {
        var reasons: [String] = []
        let known = stages.compactMap { stage -> (String, Int)? in
            let n = stage["known_issues"] as? Int ?? 0
            return n > 0 ? (stage["name"] as? String ?? "?", n) : nil
        }
        let total = known.reduce(0) { $0 + $1.1 }
        if total > 0 { reasons.append("\(total) known issue\(total == 1 ? "" : "s") (\(known.map { "\($0.0) \($0.1)" }.joined(separator: ", ")))") }
        let held = stages.filter { ["blocked", "amber"].contains($0["status"] as? String ?? "") && !($0["blocked_details"] as? [Any] ?? []).isEmpty }
        let suites = held.reduce(0) { $0 + ($1["blocked_details"] as? [Any] ?? []).count }
        if !held.isEmpty { reasons.append("\(held.count) stage\(held.count == 1 ? "" : "s") blocked (\(suites) unadapted suites)") }
        let empty = stages.filter { $0["status"] as? String == "blocked" && ($0["blocked_details"] as? [Any] ?? []).isEmpty }
        if !empty.isEmpty { reasons.append("\(empty.count) stage\(empty.count == 1 ? "" : "s") without an adapter (\(empty.compactMap { $0["name"] as? String }.joined(separator: ", ")))") }
        for stage in stages where stage["status"] as? String == "not_run" {
            reasons.append("\(stage["name"] as? String ?? "?") not run (\(stage["reason"] as? String ?? "?"))")
        }
        return reasons
    }

    mutating func publishResults() throws -> Int32 {
        let resultPath = run.appendingPathComponent("result.json")
        try write(json(result), to: resultPath, root: run)
        let publishCommand = ["/usr/bin/swift", "-module-cache-path", run.appendingPathComponent("swift-cache").path, repo.appendingPathComponent("scripts/gauntlet/publish.swift").path, resultPath.path] + (queueOnly ? ["--queue-only"] : [])
        let published = try? command(publishCommand, log: run.appendingPathComponent("publish.log"), timeout: 180)
        result["publish"] = published?.code == 0 ? "published" : published?.code == 1 ? "queued" : "queue_failed"
        if result["publish"] as? String == "queue_failed" { result["status"] = "failed"; result["publish_reason"] = "publisher could not confirm durable queue; retry result.json manually" }
        try write(json(result), to: resultPath, root: run)
        var row = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); row.append(0x0a)
        try append(row, to: resultsRoot.appendingPathComponent("history.jsonl"), root: resultsRoot)
        let labels = outputs.map { "\($0["name"]!)=\(($0["status"] as! String).uppercased())" }.joined(separator: " ")
        let amber = (result["amber_reasons"] as? [String] ?? []).joined(separator: "; ")
        let status = result["status"] as! String
        print("GAUNTLET \(status.uppercased()) sha=\(String((result["commit"] as! String).prefix(8))) total=\(Int(monotonic() - totalStart))s \(labels) UI not run (phase 2)\(status == "amber" ? " amber=\"\(amber)\"" : "") results=\(resultPath.path) publish=\(result["publish"]!)")
        // AMBER is not a failure for a caller (exit 0); the line says AMBER.
        return ["passed", "amber"].contains(status) ? 0 : 1
    }

    mutating func execute() throws -> Int32 {
        guard try parseOptions() else { return 0 }
        try validateInventory()
        if dry { printPlan(); return validationErrors.isEmpty ? 0 : 1 }
        try prepareRoots()
        try prepareAdapterEnvironment()
        initializeResult()
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
        fatalReason = validationErrors.isEmpty ? nil : "manifest inventory mismatch"
        do {
            try build()
            try buildPackage()
            for name in stageOrder { outputs.append(executeStage(name)) }
        } catch { fatalReason = String(describing: error) }
        aggregateResults()
        return try publishResults()
    }
}

func main() throws -> Int32 {
    // Test seam: count one package run's outputs, print the counts (or null).
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--count-package-output", arguments.count == 3 {
        let read = { (path: String) in (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let counts = countsFromPackageRun(eventStream: read(arguments[1]), console: read(arguments[2]))
        print(counts.map { String(data: try! json($0), encoding: .utf8)! } ?? "null")
        return counts == nil ? 1 : 0
    }
    let script = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repo = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var runner = GauntletRunner(repo: repo, arguments: Array(CommandLine.arguments.dropFirst()))
    return try runner.execute()
}

do { exit(try main()) } catch { fputs("GAUNTLET FAILED preflight: \(error)\n", stderr); exit(1) }
