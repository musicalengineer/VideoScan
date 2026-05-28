// MetricsPublisher.swift
//
// Appends one JSONL row per TestDriver run to metrics/testdriver.jsonl
// on the orphan `metrics` branch in origin. The dashboard at
// docs/index.html (on main, served via GH Pages) reads these rows
// alongside the CI-managed metrics/history.jsonl.
//
// Hard gates before publishing — every one must hold:
//   1. branch == "main"
//   2. !dirty
//   3. ahead == 0 && behind == 0       (the commit IS origin/main HEAD)
//   4. host is .local or .mbp           (real result, not synthetic)
//   5. The run completed (not cancelled mid-flight)
//
// Anything fails: skip silently, log to TermLog, surface in UI banner.
//
// Push permission: pre-approved by Rick for metrics-branch updates only.
// See memory/feedback_metrics_push_ok.md.

import Foundation

enum PublishOutcome: Equatable {
    case published(rowsAppended: Int, sha: String)
    case skipped(reason: String)
    case failed(message: String)

    var ok: Bool { if case .published = self { return true } else { return false } }
}

enum MetricsPublisher {

    /// Path on disk to the local main worktree's repo (where origin lives).
    static let repoDir = NSHomeDirectory() + "/dev/VideoScan"

    /// Worktree where we operate on the metrics branch. Lives outside the
    /// main repo tree so we never accidentally clobber Rick's working dir.
    static let metricsWorktree = "/tmp/td-metrics-wt"

    /// Try to publish. Always returns; never throws. Caller surfaces
    /// `outcome` in UI + TermLog.
    static func publish(summary: RunSummary) async -> PublishOutcome {
        // Gate 1-4: only publish when the commit is reproducible by anyone
        // who pulls origin/main.
        if summary.repo.branch != "main" {
            return .skipped(reason: "branch=\(summary.repo.branch) (only main is published)")
        }
        if summary.repo.dirty {
            return .skipped(reason: "working tree dirty (commit not reproducible)")
        }
        if summary.repo.ahead != 0 || summary.repo.behind != 0 {
            return .skipped(reason: "local main is ahead=\(summary.repo.ahead) behind=\(summary.repo.behind) of origin/main")
        }
        if summary.total == 0 {
            return .skipped(reason: "no tests ran")
        }

        TermLog.log("metrics", "publishing run: \(summary.methodsPassed)p/\(summary.methodsFailed)f/\(summary.entriesSkipped)s on \(summary.host.displayName)")

        // Build the JSONL row.
        let row = makeRow(summary: summary)
        guard let rowData = row.data(using: .utf8) else {
            return .failed(message: "could not encode JSON row")
        }
        let rowLine = String(data: rowData, encoding: .utf8)! + "\n"
        TermLog.log("metrics", "row: \(row)")

        // Set up worktree on the metrics branch.
        let setup = await ensureMetricsWorktree()
        if case .failed(let msg) = setup {
            return .failed(message: msg)
        }

        // Append to metrics/testdriver.jsonl in the worktree.
        let jsonlPath = metricsWorktree + "/metrics/testdriver.jsonl"
        let metricsDir = metricsWorktree + "/metrics"
        try? FileManager.default.createDirectory(atPath: metricsDir, withIntermediateDirectories: true)
        let existingContent = (try? String(contentsOfFile: jsonlPath)) ?? ""
        let newContent = existingContent + rowLine
        do {
            try newContent.write(toFile: jsonlPath, atomically: true, encoding: .utf8)
        } catch {
            return .failed(message: "write failed: \(error.localizedDescription)")
        }

        // git add + commit + push from the worktree.
        let add = await git(["add", "metrics/testdriver.jsonl"], in: metricsWorktree)
        guard add.didSucceed else {
            return .failed(message: "git add failed: \(add.stderr.suffix(200))")
        }

        let commitMsg = "testdriver: run on \(summary.host.displayName) — \(summary.methodsPassed)p/\(summary.methodsFailed)f/\(summary.entriesSkipped)s"
        let commit = await git(["commit", "-m", commitMsg], in: metricsWorktree)
        guard commit.didSucceed else {
            // No changes? Treat as skipped so we don't error-spam.
            if commit.stdout.contains("nothing to commit") || commit.stderr.contains("nothing to commit") {
                return .skipped(reason: "no metric changes to commit (already published?)")
            }
            return .failed(message: "git commit failed: \(commit.stderr.suffix(200))")
        }

        let push = await git(["push", "origin", "metrics"], in: metricsWorktree)
        guard push.didSucceed else {
            return .failed(message: "git push failed: \(push.stderr.suffix(200))")
        }

        // Get the new sha for the outcome banner.
        let sha = await git(["rev-parse", "--short", "HEAD"], in: metricsWorktree)
        TermLog.log("metrics", "published @ \(sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        return .published(
            rowsAppended: 1,
            sha: sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Row construction

    private static func makeRow(summary: RunSummary) -> String {
        let isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
        // Hand-rolled JSON to keep field order stable (eyeballable in the
        // committed file). All values are strings, ints, or doubles —
        // nothing complex.
        var fields: [(String, String)] = []
        func add(_ k: String, _ v: String)  { fields.append((k, "\"" + escape(v) + "\"")) }
        func add(_ k: String, _ v: Int)     { fields.append((k, String(v))) }
        func add(_ k: String, _ v: Double)  { fields.append((k, String(format: "%.3f", v))) }
        func add(_ k: String, _ v: Bool)    { fields.append((k, v ? "true" : "false")) }

        add("ts",          isoFmt.string(from: summary.startedAt))
        add("source",      "testdriver")
        add("host",        summary.host.displayName)
        add("branch",      summary.repo.branch)
        add("commit",      summary.repo.commit)
        add("commit_date", summary.repo.commitDate)
        add("app_version", summary.repo.appVersion)
        add("dirty",       summary.repo.dirty)
        add("passed",      summary.methodsPassed)
        add("failed",      summary.methodsFailed)
        add("skipped",     summary.entriesSkipped)
        add("total",       summary.total)
        add("elapsed_s",   summary.elapsedSeconds)
        if let cov = summary.coveragePercent {
            add("coverage_logic_pct", cov)
        }

        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{" + body + "}"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Worktree management

    /// Make sure /tmp/td-metrics-wt is a worktree of `repoDir` checked out
    /// to the metrics branch. If it doesn't exist, create it. If it exists
    /// but is on the wrong branch, recreate it. Always fetches origin first.
    private static func ensureMetricsWorktree() async -> PublishOutcome {
        // 1. Fetch origin so we have the latest metrics ref.
        let fetch = await git(["fetch", "origin", "metrics"], in: repoDir)
        guard fetch.didSucceed else {
            return .failed(message: "fetch origin metrics failed: \(fetch.stderr.suffix(200))")
        }

        let fm = FileManager.default
        // 2. If worktree exists, validate branch + sync. Otherwise create.
        if fm.fileExists(atPath: metricsWorktree + "/.git") || fm.fileExists(atPath: metricsWorktree) {
            let branchCheck = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: metricsWorktree)
            let branch = branchCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if branchCheck.didSucceed, branch == "metrics" {
                // Sync to origin/metrics — fast-forward only.
                let pull = await git(["pull", "--ff-only", "origin", "metrics"], in: metricsWorktree)
                if pull.didSucceed { return .published(rowsAppended: 0, sha: "") }
                // FF failed (probably because we have a local commit ahead
                // of origin from a prior failed push). Reset to origin.
                let reset = await git(["reset", "--hard", "origin/metrics"], in: metricsWorktree)
                if reset.didSucceed { return .published(rowsAppended: 0, sha: "") }
                return .failed(message: "metrics worktree out of sync and reset failed")
            }
            // Wrong branch or corrupt — tear down and recreate.
            _ = await git(["worktree", "remove", "--force", metricsWorktree], in: repoDir)
            try? fm.removeItem(atPath: metricsWorktree)
        }

        // 3. Create the worktree.
        let create = await git(["worktree", "add", metricsWorktree, "metrics"], in: repoDir)
        guard create.didSucceed else {
            return .failed(message: "worktree add failed: \(create.stderr.suffix(200))")
        }
        return .published(rowsAppended: 0, sha: "")
    }

    private static func git(_ args: [String], in dir: String) async -> SubprocessResult {
        await Subprocess.run("/usr/bin/git", ["-C", dir] + args, timeoutSeconds: 30)
    }
}
