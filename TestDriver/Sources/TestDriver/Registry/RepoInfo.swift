// RepoInfo.swift
//
// Snapshots the repo + app build state for the host TestDriver is about
// to test against. Queries git for branch / commit / commit-date and
// reads CFBundleShortVersionString from VideoScan's Info.plist. Everything
// the user sees at the top of the UI ("you're about to test main @ 1f53bf1
// from 2026-05-13") flows from here.
//
// Local-host queries shell out to /usr/bin/git directly. MBP queries
// ride the existing SSH connection.

import Foundation

struct RepoInfo: Equatable {
    var hostLabel: String              // "Mac Studio (local)" or "M1 MBP (over SSH)"
    var projectDir: String             // ~/dev/VideoScan or /Users/rickb/developer/VideoScan
    var branch: String                 // "main", "feature/testdriver", "(detached)"
    var commit: String                 // short sha like "bd57cd1"
    var commitDate: String             // YYYY-MM-DD
    var commitSubject: String          // first line of the commit message
    var dirty: Bool                    // true if uncommitted changes
    var appVersion: String             // CFBundleShortVersionString
    var ahead: Int                     // commits ahead of origin/<branch>
    var behind: Int                    // commits behind origin/<branch>

    static let empty = RepoInfo(
        hostLabel: "—", projectDir: "—",
        branch: "—", commit: "—", commitDate: "—", commitSubject: "—",
        dirty: false, appVersion: "—",
        ahead: 0, behind: 0
    )

    /// Compact one-liner for the UI banner: "main @ bd57cd1 (2026-05-13) v1.0"
    var oneLine: String {
        var parts: [String] = []
        parts.append("\(branch) @ \(commit)")
        if dirty { parts.append("(dirty)") }
        parts.append("(\(commitDate))")
        if !appVersion.isEmpty, appVersion != "—" {
            parts.append("v\(appVersion)")
        }
        if ahead > 0 || behind > 0 {
            parts.append("[ahead \(ahead), behind \(behind)]")
        }
        return parts.joined(separator: " ")
    }

    /// Multi-line for the result-banner card.
    var multiLine: String {
        """
        Host:    \(hostLabel)
        Branch:  \(branch)\(dirty ? " (dirty)" : "")  ahead \(ahead), behind \(behind)
        Commit:  \(commit)  (\(commitDate))
        Subject: \(commitSubject)
        Version: v\(appVersion)
        Path:    \(projectDir)
        """
    }
}

enum RepoInspector {

    /// MBP path (matches MBPRemote.projectDir).
    static let mbpProjectDir = "/Users/rickb/developer/VideoScan"

    /// Inspect either host. Local case shells out directly; MBP case wraps
    /// the same git/plutil commands in an SSH invocation.
    static func inspect(host: TestHost) async -> RepoInfo {
        switch host {
        case .local:
            return await inspectLocal()
        case .mbp:
            return await inspectMBP()
        }
    }

    // MARK: - Local

    private static func inspectLocal() async -> RepoInfo {
        let dir = VideoScanTests.projectDir
        // Branch first because aheadBehind needs it; the rest run concurrently.
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        async let commit = git(["rev-parse", "--short", "HEAD"], in: dir)
        async let date = git(["log", "-1", "--format=%cd", "--date=short"], in: dir)
        async let subject = git(["log", "-1", "--format=%s"], in: dir)
        async let dirty = isDirty(in: dir)
        async let aheadBehind = computeAheadBehind(in: dir, branch: branch)
        let appVersion = readAppVersion(localProjectDir: dir)
        let ab = await aheadBehind
        return RepoInfo(
            hostLabel: TestHost.local.displayName,
            projectDir: dir,
            branch: branch,
            commit: await commit,
            commitDate: await date,
            commitSubject: await subject,
            dirty: await dirty,
            appVersion: appVersion,
            ahead: ab.ahead,
            behind: ab.behind
        )
    }

    private static func git(_ args: [String], in dir: String) async -> String {
        let result = await Subprocess.run("/usr/bin/git",
                                          ["-C", dir] + args,
                                          timeoutSeconds: 5)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDirty(in dir: String) async -> Bool {
        let result = await Subprocess.run("/usr/bin/git",
                                          ["-C", dir, "status", "--porcelain"],
                                          timeoutSeconds: 5)
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func computeAheadBehind(in dir: String, branch: String) async -> (ahead: Int, behind: Int) {
        let upstream = "origin/\(branch)"
        let result = await Subprocess.run("/usr/bin/git",
                                          ["-C", dir, "rev-list", "--left-right", "--count", "HEAD...\(upstream)"],
                                          timeoutSeconds: 5)
        let parts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        if parts.count == 2,
           let ahead = Int(parts[0]),
           let behind = Int(parts[1]) {
            return (ahead, behind)
        }
        return (0, 0)
    }

    /// Read CFBundleShortVersionString from the source Info.plist (or the
    /// .pbxproj if Info is generated). VideoScan's project uses an
    /// auto-generated Info.plist, so we extract from MARKETING_VERSION
    /// in project.pbxproj as a fallback.
    private static func readAppVersion(localProjectDir: String) -> String {
        let infoPath = localProjectDir + "/VideoScan/VideoScan/Info.plist"
        if FileManager.default.fileExists(atPath: infoPath) {
            if let dict = NSDictionary(contentsOfFile: infoPath),
               let v = dict["CFBundleShortVersionString"] as? String,
               !v.isEmpty {
                return v
            }
        }
        // Fallback: scan project.pbxproj for MARKETING_VERSION.
        let pbxPath = localProjectDir + "/VideoScan/VideoScan.xcodeproj/project.pbxproj"
        if let pbx = try? String(contentsOfFile: pbxPath) {
            for line in pbx.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("MARKETING_VERSION") {
                    let after = trimmed.split(separator: "=", maxSplits: 1).last ?? ""
                    let cleaned = after
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        return "(unknown)"
    }

    // MARK: - MBP (SSH)

    private static func inspectMBP() async -> RepoInfo {
        let dir = mbpProjectDir
        // One SSH round-trip with all the queries — minimizes latency.
        let script = """
        set -u
        cd '\(dir)' 2>/dev/null || exit 99
        echo "BRANCH:$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        echo "COMMIT:$(git rev-parse --short HEAD 2>/dev/null)"
        echo "DATE:$(git log -1 --format=%cd --date=short 2>/dev/null)"
        echo "SUBJECT:$(git log -1 --format=%s 2>/dev/null)"
        echo "DIRTY:$(git status --porcelain 2>/dev/null | head -1)"
        AB=$(git rev-list --left-right --count HEAD...origin/$(git rev-parse --abbrev-ref HEAD) 2>/dev/null)
        echo "AHEADBEHIND:$AB"
        # Marketing version from pbxproj.
        VERS=$(grep -m1 'MARKETING_VERSION' VideoScan/VideoScan.xcodeproj/project.pbxproj | sed 's/.*= //; s/[\";]//g' | tr -d ' ')
        echo "VERSION:$VERS"
        """
        let result = await Subprocess.run(
            "/usr/bin/ssh",
            ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
             MBPRemote.host, script],
            timeoutSeconds: 30
        )
        if result.exitCode != 0 {
            var info = RepoInfo.empty
            info.hostLabel = TestHost.mbp.displayName
            info.projectDir = dir
            info.branch = "(unreachable)"
            info.commit = "ssh exit \(result.exitCode)"
            return info
        }
        var info = RepoInfo.empty
        info.hostLabel = TestHost.mbp.displayName
        info.projectDir = dir
        for line in result.stdout.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let val = String(line[line.index(after: colon)...])
            switch key {
            case "BRANCH":  info.branch = val
            case "COMMIT":  info.commit = val
            case "DATE":    info.commitDate = val
            case "SUBJECT": info.commitSubject = val
            case "DIRTY":   info.dirty = !val.isEmpty
            case "VERSION": info.appVersion = val.isEmpty ? "(unknown)" : val
            case "AHEADBEHIND":
                let parts = val.split(separator: "\t")
                if parts.count == 2,
                   let a = Int(parts[0]), let b = Int(parts[1]) {
                    info.ahead = a; info.behind = b
                }
            default: break
            }
        }
        return info
    }

    /// Lists branches on a host (for the future Switch Branch picker).
    /// Returns local + remote-tracking branches, deduped.
    static func listBranches(host: TestHost) async -> [String] {
        switch host {
        case .local:
            let r = await Subprocess.run("/usr/bin/git",
                                         ["-C", VideoScanTests.projectDir,
                                          "for-each-ref", "--format=%(refname:short)",
                                          "refs/heads", "refs/remotes"],
                                         timeoutSeconds: 5)
            return parseBranches(r.stdout)
        case .mbp:
            let r = await Subprocess.run("/usr/bin/ssh",
                                         ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                                          MBPRemote.host,
                                          "cd '\(mbpProjectDir)' && git for-each-ref --format='%(refname:short)' refs/heads refs/remotes"],
                                         timeoutSeconds: 15)
            return parseBranches(r.stdout)
        }
    }

    private static func parseBranches(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for line in raw.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // Skip remote HEAD pointers like "origin/HEAD"
            if s.contains("HEAD") { continue }
            // Strip remote prefix for display dedup ("origin/main" -> "main")
            let display = s.hasPrefix("origin/") ? String(s.dropFirst("origin/".count)) : s
            if seen.insert(display).inserted {
                out.append(display)
            }
        }
        return out.sorted()
    }
}
