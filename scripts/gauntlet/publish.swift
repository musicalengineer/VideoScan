#!/usr/bin/env swift
// Gauntlet metrics share the nightly metrics branch/file but keep a separate
// durable queue. No artifact paths, failure text, hostnames or media names leave
// the machine. Standalone script processes are intentionally outside app code.
import Foundation
import Darwin

enum PublishError: Error { case invalid(String), command(Int32) }
let fm = FileManager.default
let arguments = Array(CommandLine.arguments.dropFirst())
let queueOnly = arguments.contains("--queue-only")
let dryRun = arguments.contains("--dry-run")
let operands = arguments.filter { !$0.hasPrefix("--") }

func runGit(_ args: [String], at repo: URL) throws -> String {
    let environment = ProcessInfo.processInfo.environment.merging([
        "GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -oBatchMode=yes -oConnectTimeout=10"
    ]) { _, new in new }
    // git output is small; redirect to a scratch file to avoid pipe deadlocks.
    let output = fm.temporaryDirectory.appendingPathComponent("gauntlet-git-\(UUID().uuidString)")
    fm.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close(); try? fm.removeItem(at: output) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    let argv = (["/usr/bin/git", "-C", repo.path] + args).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
        posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, av.baseAddress!, ev.baseAddress!)
    } }
    guard spawned == 0 else { throw PublishError.command(spawned) }
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    var status: Int32 = 0
    while true {
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { break }
        if waited < 0 && errno != EINTR { throw PublishError.command(errno) }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            kill(-pid, SIGKILL)
            // Never let an uninterruptible child hold the durable queue lock.
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw PublishError.command(124)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard status == 0 else { throw PublishError.command(status) }
    return String(data: try Data(contentsOf: output), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func number(_ value: Any?) -> Double {
    guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
    return max(0, number.doubleValue)
}

func sanitized(_ result: [String: Any]) throws -> [String: Any] {
    let names = ["unit", "regression", "integration", "performance", "hallie", "stress", "ui"]
    let statuses = ["passed", "failed", "not_run", "blocked", "incomplete"]
    let timestampFormatter = ISO8601DateFormatter()
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let id = result["run_id"] as? String,
          id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
          let ts = result["ts"] as? String,
          timestampFormatter.date(from: ts) != nil || fractionalFormatter.date(from: ts) != nil else {
        throw PublishError.invalid("invalid run identity")
    }
    let stages = (result["stages"] as? [[String: Any]] ?? []).compactMap { stage -> [String: Any]? in
        guard let name = stage["name"] as? String, names.contains(name) else { return nil }
        let state = stage["status"] as? String ?? "blocked"
        var row: [String: Any] = ["name": name, "status": statuses.contains(state) ? state : "blocked"]
        row["elapsed_s"] = number(stage["elapsed_s"])
        for key in ["expected", "passed", "failed", "skipped", "incomplete"] {
            row[key] = stage[key] is NSNumber ? number(stage[key]) : NSNull()
        }
        if name == "ui" { row["status"] = "not_run"; row["reason"] = "phase 2" }
        return row
    }
    var row: [String: Any] = ["schemaVersion": 1, "source": "gauntlet", "run_id": id, "ts": ts,
        "configuration": "Release", "dirty": result["dirty"] as? Bool ?? true,
        "elapsed_s": number(result["elapsed_s"]), "build_s": number(result["build_s"]), "stages": stages,
        "status": stages.contains { $0["status"] as? String == "failed" } || result["status"] as? String == "failed" ? "failed" : "incomplete",
        "ui_label": "UI not run (phase 2)"]
    let machine = result["machine"] as? String ?? "unknown"
    row["machine"] = ["m4", "m5", "m1"].contains(machine) ? machine : "unknown"
    let commit = result["commit"] as? String ?? ""
    if commit.range(of: "^[a-fA-F0-9]{7,40}$", options: .regularExpression) != nil { row["commit"] = commit }
    return row
}

do {
    guard operands.count == 1 else { throw PublishError.invalid("usage: publish.swift RESULT_JSON [--queue-only|--dry-run]") }
    let resultURL = URL(fileURLWithPath: operands[0]).standardizedFileURL
    let root = resultURL.deletingLastPathComponent().deletingLastPathComponent()
    // Refuse canonical-path escapes before opening any writable queue surface.
    guard root.path == root.resolvingSymlinksInPath().path,
          resultURL.path == resultURL.resolvingSymlinksInPath().path,
          let result = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any] else {
        throw PublishError.invalid("symlink escape or invalid result")
    }
    let row = try sanitized(result)
    var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    line.append(0x0a)
    if dryRun { FileHandle.standardOutput.write(line); exit(0) }
    let queue = root.appendingPathComponent("pending-metrics.jsonl")
    let lock = root.appendingPathComponent("pending-metrics.lock")
    let lockFD = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw PublishError.invalid("cannot lock queue") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else { throw PublishError.invalid("cannot lock queue") }
    let queueFD = open(queue.path, O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW, 0o600)
    guard queueFD >= 0 else { throw PublishError.invalid("cannot open queue") }
    let queueHandle = FileHandle(fileDescriptor: queueFD, closeOnDealloc: true)
    try queueHandle.write(contentsOf: line)
    try queueHandle.synchronize()
    try queueHandle.close()
    if queueOnly { print("queued"); exit(1) }
    // Queue before network work; any fetch/commit/push failure leaves it intact.
    do {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wt = root.appendingPathComponent("metrics-worktree-\(UUID().uuidString)")
        defer { _ = try? runGit(["worktree", "remove", "--force", wt.path], at: repo) }
        _ = try runGit(["fetch", "origin", "metrics", "--quiet"], at: repo)
        _ = try runGit(["worktree", "add", "--detach", wt.path, "origin/metrics", "--quiet"], at: repo)
        let target = wt.appendingPathComponent("metrics/testdriver.jsonl")
        guard target.resolvingSymlinksInPath().path == target.path else {
            throw PublishError.invalid("metrics target symlink escape")
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Bound queue memory to 8 MiB; failed publication can never grow RAM without limit.
        let size = (try fm.attributesOfItem(atPath: queue.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 8 * 1024 * 1024 else { throw PublishError.invalid("queue exceeds publication batch limit") }
        let backlog = try String(contentsOf: queue, encoding: .utf8).split(separator: "\n")
        let queuedIDs = Set(backlog.compactMap { entry -> String? in
            (try? JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])?["run_id"] as? String
        })
        var existingIDs = Set<String>()
        if fm.fileExists(atPath: target.path) {
            // Stream history rather than buffering an unbounded metrics file.
            if let input = fopen(target.path, "r") {
                defer { fclose(input) }
                var buffer: UnsafeMutablePointer<CChar>?; var capacity = 0
                defer { free(buffer) }
                while getline(&buffer, &capacity, input) >= 0 {
                    if let buffer, let data = String(cString: buffer).data(using: .utf8),
                       let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       old["source"] as? String == "gauntlet", let id = old["run_id"] as? String,
                       queuedIDs.contains(id) { existingIDs.insert(id) }
                }
            }
        } else { fm.createFile(atPath: target.path, contents: nil) }
        let output = try FileHandle(forWritingTo: target)
        try output.seekToEnd()
        var added = false
        for entry in backlog {
            let data = Data(entry.utf8)
            guard let pending = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = pending["run_id"] as? String else { throw PublishError.invalid("invalid queued row") }
            let clean = try JSONSerialization.data(withJSONObject: sanitized(pending), options: [.sortedKeys])
            if existingIDs.insert(id).inserted { try output.write(contentsOf: clean + Data([0x0a])); added = true }
        }
        try output.close()
        if added {
            _ = try runGit(["add", "metrics/testdriver.jsonl"], at: wt)
            _ = try runGit(["commit", "-m", "metrics: gauntlet results [skip ci]", "--quiet"], at: wt)
            _ = try runGit(["push", "origin", "HEAD:metrics", "--quiet"], at: wt)
        }
        try Data().write(to: queue, options: .atomic)
        print("published")
    } catch { print("queued"); exit(1) }
} catch { fputs("gauntlet metrics: \(error)\n", stderr); exit(2) }
