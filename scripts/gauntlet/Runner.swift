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
    if counts["passed", default: 0] + counts["failed", default: 0] < max(1, floor) { return ("failed", "executed count below expected floor \(max(1, floor))") }
    return ("passed", nil)
}
func countsFromSummary(_ object: [String: Any]) -> [String: Int]? {
    guard let passed = object["passedTests"] as? Int, let failed = object["failedTests"] as? Int, let skipped = object["skippedTests"] as? Int else { return nil }
    guard passed >= 0 && failed >= 0 && skipped >= 0 else { return nil }
    guard let total = object["totalTestCount"] as? Int, total == passed + failed + skipped,
          (object["expectedFailures"] as? Int ?? 0) == 0,
          let verdict = object["result"] as? String, ["Passed", "Failed", "Skipped"].contains(verdict),
          verdict != "Failed" || failed > 0 else { return nil }
    return ["passed": passed, "failed": failed, "skipped": skipped]
}
func stageResult(_ name: String, _ status: String, _ reason: String?, floor: Int = 0) -> [String: Any] {
    ["name": name, "status": status, "reason": reason as Any? ?? NSNull(), "exit_code": NSNull(), "elapsed_s": 0.0, "expected": floor, "passed": NSNull(), "failed": NSNull(), "skipped": NSNull(), "incomplete": status == "passed" ? 0 : 1, "artifacts": []]
}

func main() throws -> Int32 {
    let script = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repo = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var arguments = Array(CommandLine.arguments.dropFirst())
    var away = false; var dry = false; var queueOnly = false; var machine = "m4"
    var only = Set(stageOrder)
    var manifestPath = repo.appendingPathComponent("scripts/gauntlet/manifest.json")
    var resultsRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan/gauntlet")
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
            return 0
        default: throw RunError("unknown argument: \(flag)")
        }
    }
    guard away || dry else { throw RunError("--away required; test hosts must run only in an authorized away window") }
    guard ["m4", "m5", "m1"].contains(machine), !only.isEmpty, only.isSubset(of: Set(stageOrder)) else { throw RunError("invalid machine or stage selection") }
    let manifest = try readObject(manifestPath)
    guard let stages = manifest["stages"] as? [[String: Any]], Set(stages.compactMap { $0["name"] as? String }) == Set(stageOrder), stages.count == stageOrder.count else { throw RunError("manifest must declare each stage exactly once") }
    let stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0["name"] as! String, $0) })
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
    let validationLog = URL(fileURLWithPath: "/private/tmp/gauntlet-inventory-\(UUID().uuidString).json")
    let validationCache = "/private/tmp/gauntlet-inventory-cache-\(UUID().uuidString)"
    let validationRun = try command(["/usr/bin/swift", "-module-cache-path", validationCache, repo.appendingPathComponent("scripts/gauntlet/inventory.swift").path, "--validate", repo.path, manifestPath.path], log: validationLog, timeout: 120)
    guard !validationRun.timedOut && !validationRun.contaminated else { throw RunError("inventory watchdog failure") }
    let validation = (try? String(contentsOf: validationLog, encoding: .utf8)) ?? ""
    guard let validationData = validation.data(using: .utf8), let validationObject = try? JSONSerialization.jsonObject(with: validationData) as? [String: Any], let validationErrors = validationObject["errors"] as? [String] else { throw RunError("inventory validation unavailable: \(validation.prefix(500))") }
    if dry {
        print("GAUNTLET DRY RUN machine=\(machine) configuration=Release")
        print("Inventory: \(validationErrors.isEmpty ? "valid" : validationErrors.joined(separator: "; "))")
        print("Isolation: per-run home, App Support, catalog, preferences, caches, logs, archive, fixtures; canonical write allowlist")
        print("Build: ONE xcodebuild build-for-testing -scheme VideoScan -testPlan VideoScan-CI -configuration Release -derivedDataPath <run>/DerivedData")
        for name in stageOrder {
            let entry = stageMap[name]!
            let selectors = entry["selectors"] as? [String] ?? []
            let blocked = entry["blocked"] as? [[String: Any]] ?? []
            print("\(name): \(name == "ui" ? "UI not run (phase 2)" : !only.contains(name) ? "not_run (not selected)" : "test-without-building selectors=\(selectors.count) expected_floor=\(entry["expected_floor"] ?? 0) blocked=\(blocked.count)")")
        }
        print("Results: \(resultsRoot.path)/<run-id>/result.json; history.jsonl; metrics publication queued on failure")
        return validationErrors.isEmpty ? 0 : 1
    }
    // Only runner-owned storage is created; canonical checks precede every write.
    let allowedParents = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan"), URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()]
    guard let parent = allowedParents.first(where: { resultsRoot.path.hasPrefix($0.path + "/") }) else { throw RunError("results root must be under VideoScan logs or scratch") }
    _ = try guarded(resultsRoot, under: parent)
    try fm.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let runID = stamp.replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
    let run = try guarded(resultsRoot.appendingPathComponent(runID), under: resultsRoot)
    try fm.createDirectory(at: run, withIntermediateDirectories: false)
    let totalStart = monotonic()
    var environment = ProcessInfo.processInfo.environment.filter { key, _ in
        !key.hasPrefix("VS_") && !key.hasPrefix("VIDEOSCAN_") && !key.hasPrefix("TEST_RUNNER_") && !key.hasPrefix("XCTest")
    }
    var roots: [String: String] = [:]
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
    for entry in stages {
        for (key, value) in entry["environment"] as? [String: String] ?? [:] {
            guard ["VIDEOSCAN_PERF", "VIDEOSCAN_PERF_FILE_COUNT", "VIDEOSCAN_PERF_DURATION", "VIDEOSCAN_PERF_TIME_LIMIT_MIN", "VIDEOSCAN_PERF_RESULTS"].contains(key) else { throw RunError("unsupported adapter environment key: \(key)") }
            let expanded = value.replacingOccurrences(of: "{run_dir}", with: run.path)
            if key == "VIDEOSCAN_PERF_RESULTS" { _ = try guarded(URL(fileURLWithPath: expanded), under: run) }
            environment[key] = expanded
        }
    }
    var result: [String: Any] = ["schema": 1, "run_id": runID, "ts": stamp, "commit": capture(["git", "-C", repo.path, "rev-parse", "HEAD"]), "branch": capture(["git", "-C", repo.path, "branch", "--show-current"]), "dirty": !capture(["git", "-C", repo.path, "status", "--porcelain"]).isEmpty, "machine": machine, "configuration": "Release", "binary_sha256": NSNull(), "status": "failed", "build_s": 0.0, "roots": roots, "inventory_errors": validationErrors]
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
    var outputs: [[String: Any]] = []
    var buildOK = false; var contaminated = false; var fatalReason: String? = validationErrors.isEmpty ? nil : "manifest inventory mismatch"
    do {
        if fatalReason == nil {
            let cmd = ["xcodebuild", "build-for-testing", "-project", repo.appendingPathComponent("VideoScan/VideoScan.xcodeproj").path, "-scheme", "VideoScan", "-testPlan", "VideoScan-CI", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", roots["DerivedData"]!, "-skip-testing:VideoScanUITests", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS="]
            let build = try command(cmd, log: run.appendingPathComponent("build.log"), timeout: 3600, environment: environment)
            result["build_s"] = build.elapsed; result["build_exit_code"] = build.code
            buildOK = build.code == 0; contaminated = build.contaminated
            if !buildOK { fatalReason = build.timedOut ? "build watchdog timeout" : "build exit \(build.code)" }
        }
        let productRoot = URL(fileURLWithPath: roots["DerivedData"]!).appendingPathComponent("Build/Products")
        var xctestrun: URL?
        if buildOK {
            xctestrun = try fm.contentsOfDirectory(at: productRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }.first
            guard let testRun = xctestrun else { throw RunError("build produced no .xctestrun") }
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: testRun), format: nil)
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
            plist = patch(plist)
            try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: testRun, root: run)
            let binary = productRoot.appendingPathComponent("Release/VideoScan.app/Contents/MacOS/VideoScan")
            result["binary_sha256"] = capture(["/usr/bin/shasum", "-a", "256", binary.path]).split(separator: " ").first.map(String.init) as Any? ?? NSNull()
        }
        for name in stageOrder {
            let entry = stageMap[name]!
            let floor = entry["expected_floor"] as? Int ?? 1
            if name == "ui" { outputs.append(stageResult(name, "not_run", "phase 2", floor: floor)); continue }
            if !only.contains(name) { outputs.append(stageResult(name, "not_run", "not selected", floor: floor)); continue }
            if contaminated || interrupted != 0 || !buildOK { outputs.append(stageResult(name, "blocked", contaminated ? "unreaped process contamination" : interrupted != 0 ? "interrupted" : fatalReason, floor: floor)); continue }
            let selectors = entry["selectors"] as? [String] ?? []
            let blocked = entry["blocked"] as? [[String: Any]] ?? []
            let missingTools = (entry["requires_tools"] as? [String] ?? []).filter { !fm.isExecutableFile(atPath: $0) }
            if !missingTools.isEmpty { outputs.append(stageResult(name, "blocked", "required fixture tools unavailable", floor: floor)); continue }
            if selectors.isEmpty { outputs.append(stageResult(name, "blocked", blocked.isEmpty ? "no safe phase 1 adapter" : "unsafe or unadapted suites: \(blocked.count)", floor: floor)); continue }
            let bundle = run.appendingPathComponent("\(name).xcresult")
            let cmd = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun!.path, "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO", "-resultBundlePath", bundle.path, "-skip-testing:VideoScanUITests"] + selectors.map { "-only-testing:\($0)" }
            var output = stageResult(name, "failed", nil, floor: floor)
            output["blocked_details"] = blocked
            if let modes = entry["modes"] { output["modes"] = modes }
            let start = monotonic()
            do {
                let execution = try command(cmd, log: run.appendingPathComponent("\(name).log"), timeout: Double(entry["timeout_s"] as? Int ?? 1800), environment: environment)
                contaminated = execution.contaminated
                output["exit_code"] = execution.code
                let summary = run.appendingPathComponent("\(name)-summary.json")
                let extraction = try command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle.path], log: summary, timeout: 60)
                let counts = extraction.code == 0 ? (try? readObject(summary)).flatMap(countsFromSummary) : nil
                let verdict = classify(exitCode: execution.code, counts: counts, floor: floor)
                output["status"] = verdict.0
                output["reason"] = verdict.1 as Any? ?? NSNull()
                if let counts { for (key, value) in counts { output[key] = value } }
                if execution.timedOut { output["reason"] = "stage watchdog timeout" }
                if execution.contaminated || extraction.contaminated { contaminated = true; output["status"] = "failed"; output["reason"] = "unreaped process contamination" }
                if verdict.0 == "passed" && !blocked.isEmpty { output["status"] = "blocked"; output["reason"] = "safe subset passed; unsafe or unadapted suites: \(blocked.count)" }
                output["incomplete"] = output["status"] as? String == "passed" ? 0 : 1
            } catch { output["reason"] = String(describing: error) }
            output["elapsed_s"] = monotonic() - start
            output["artifacts"] = [bundle.lastPathComponent, "\(name).log", "\(name)-summary.json"]
            outputs.append(output)
        }
    } catch { fatalReason = String(describing: error) }
    for name in stageOrder where !outputs.contains(where: { $0["name"] as? String == name }) { outputs.append(stageResult(name, name == "ui" ? "not_run" : "blocked", name == "ui" ? "phase 2" : fatalReason ?? "interrupted")) }
    outputs.sort { stageOrder.firstIndex(of: $0["name"] as! String)! < stageOrder.firstIndex(of: $1["name"] as! String)! }
    for index in outputs.indices {
        let entry = stageMap[outputs[index]["name"] as! String]!
        outputs[index]["blocked_details"] = entry["blocked"] ?? []
        if let modes = entry["modes"] { outputs[index]["modes"] = modes }
    }
    result["stages"] = outputs; result["elapsed_s"] = monotonic() - totalStart
    let failed = fatalReason != nil || outputs.contains { $0["status"] as? String == "failed" }
    result["status"] = failed ? "failed" : outputs.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "incomplete"
    if let fatalReason { result["reason"] = fatalReason }
    result["publish"] = "queued"
    if interrupted != 0 { result["interrupted_signal"] = interrupted; interrupted = 0 }
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
    print("GAUNTLET \((result["status"] as! String).uppercased()) sha=\(String((result["commit"] as! String).prefix(8))) total=\(Int(monotonic() - totalStart))s \(labels) UI not run (phase 2) results=\(resultPath.path) publish=\(result["publish"]!)")
    return result["status"] as? String == "passed" ? 0 : 1
}
do { exit(try main()) } catch { fputs("GAUNTLET FAILED preflight: \(error)\n", stderr); exit(1) }
