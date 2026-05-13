// CLI.swift
//
// Command-line runner for TestDriver. Same TestRegistry as the UI, just
// surfaced through a terminal instead of a window.
//
// Usage:
//   TestDriver --cli                       # run every visible test on local Mac Studio
//   TestDriver --cli --group=Smoke         # run one group
//   TestDriver --cli --group=Regression --host=mbp
//   TestDriver --cli --include-stress      # include the opt-in stress group
//   TestDriver --cli --list                # just print the registry
//   TestDriver --cli --filter=arcface      # substring match on id
//
// Exit code: 0 if all selected passed, 1 if any failed, 2 if any unclear,
// 3 if a harness/CLI error occurred.

import Foundation

enum CLI {

    static func run(arguments: [String]) async -> Int32 {
        VideoScanTests.registerAll()
        let opts = parse(arguments)

        if opts.listOnly {
            return printRegistry(opts)
        }

        let entries = pick(opts)
        if entries.isEmpty {
            print("No tests matched the given options.")
            return 3
        }

        print("TestDriver CLI")
        print("  host:    \(opts.host.rawValue)")
        print("  tests:   \(entries.count)")
        print("  groups:  \(Set(entries.map(\.group.rawValue)).sorted().joined(separator: ", "))")
        // Snapshot what we're about to test — same info the UI banner shows.
        let repo = await RepoInspector.inspect(host: opts.host)
        print("  repo:    \(repo.oneLine)")
        print("  path:    \(repo.projectDir)")
        if !repo.commitSubject.isEmpty, repo.commitSubject != "—" {
            print("  subject: \(repo.commitSubject)")
        }
        print(String(repeating: "─", count: 70))

        var counts = (passed: 0, failed: 0, unclear: 0, skipped: 0)
        let started = Date()
        for (idx, entry) in entries.enumerated() {
            let prefix = "[\(idx + 1)/\(entries.count)]"
            print("\n\(prefix) ▶ \(entry.id)")
            print("    \(entry.description)")
            let testStart = Date()
            let result = await entry.run(opts.host) { line in
                if opts.verbose { print("    │ \(line)") }
            }
            let dur = Date().timeIntervalSince(testStart)
            switch result.status {
            case .passed:
                counts.passed += 1
                // The test's result.log often contains an internal count
                // ("N tests passed"). Show it on one line for visibility
                // even in non-verbose mode.
                let detail = result.log.split(separator: "\n")
                    .first(where: { $0.contains("tests passed") || $0.contains("passed") })
                    .map { " — \($0)" } ?? ""
                print(String(format: "    ✓ pass  (%.2fs)%@", dur, detail))
            case .failed(let msg, _):
                counts.failed += 1
                print(String(format: "    ✗ FAIL  (%.2fs) — %@", dur, msg))
                if !opts.verbose, !result.log.isEmpty {
                    let tail = result.log.split(separator: "\n").suffix(20).joined(separator: "\n")
                    print("    │ \(tail.replacingOccurrences(of: "\n", with: "\n    │ "))")
                }
            case .unclear(let msg, _):
                counts.unclear += 1
                print(String(format: "    ⚠ unclear  (%.2fs) — %@", dur, msg))
            case .skipped(let reason):
                counts.skipped += 1
                print("    ↷ skipped — \(reason)")
            default:
                break
            }
        }

        let total = Date().timeIntervalSince(started)

        // Build a RunSummary so MetricsPublisher's gates apply identically
        // to the UI path. opts.publish defaults to true; --no-publish
        // disables. The publisher itself still gates on main + clean +
        // synced, so a pollute-attempt from a feature branch is silently
        // skipped even if --publish is on.
        let summary = RunSummary(
            passed: counts.passed, failed: counts.failed,
            unclear: counts.unclear, skipped: counts.skipped,
            elapsedSeconds: total,
            host: opts.host, repo: repo, startedAt: started
        )
        var publishLine = ""
        if opts.publish {
            let outcome = await MetricsPublisher.publish(summary: summary)
            switch outcome {
            case .published(_, let sha): publishLine = "📊 metrics published to origin/metrics @ \(sha)"
            case .skipped(let reason):   publishLine = "📊 metrics skipped — \(reason)"
            case .failed(let msg):       publishLine = "📊 metrics push FAILED — \(msg)"
            }
        } else {
            publishLine = "📊 metrics push disabled (--no-publish)"
        }

        print("")
        print(String(repeating: "═", count: 70))
        let banner: String = {
            if counts.failed > 0  { return "✗ FAILED" }
            if counts.unclear > 0 { return "⚠ UNCLEAR" }
            if counts.passed > 0  { return "✓ PASSED" }
            return "— EMPTY"
        }()
        print(String(format: "%@   %d passed   %d failed   %d unclear   %d skipped   (%.1fs)",
                     banner, counts.passed, counts.failed, counts.unclear, counts.skipped, total))
        print("Host:   \(opts.host.rawValue)")
        print("Repo:   \(repo.oneLine)")
        print("Date:   \(ISO8601DateFormatter().string(from: started))")
        print(publishLine)
        print(String(repeating: "═", count: 70))

        if counts.failed > 0 { return 1 }
        if counts.unclear > 0 { return 2 }
        return 0
    }

    // MARK: - Options

    struct Options {
        var host: TestHost = .macStudio
        var group: TestGroup? = nil
        var filter: String? = nil
        var includeStress: Bool = false
        var listOnly: Bool = false
        var verbose: Bool = false
        var publish: Bool = true   // pushes metrics under hard gates; --no-publish to disable
    }

    static func parse(_ arguments: [String]) -> Options {
        var opts = Options()
        for arg in arguments {
            if arg == "--list" { opts.listOnly = true; continue }
            if arg == "--verbose" || arg == "-v" { opts.verbose = true; continue }
            if arg == "--include-stress" { opts.includeStress = true; continue }
            if arg == "--no-publish" { opts.publish = false; continue }
            if arg.hasPrefix("--group=") {
                let raw = String(arg.dropFirst("--group=".count))
                opts.group = TestGroup.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
                continue
            }
            if arg.hasPrefix("--host=") {
                let raw = String(arg.dropFirst("--host=".count)).lowercased()
                if raw == "mbp" || raw.contains("mbp") {
                    opts.host = .mbp
                } else {
                    opts.host = .macStudio
                }
                continue
            }
            if arg.hasPrefix("--filter=") {
                opts.filter = String(arg.dropFirst("--filter=".count))
                continue
            }
        }
        return opts
    }

    static func pick(_ opts: Options) -> [TestEntry] {
        var entries = TestRegistry.shared.all()
        if let g = opts.group {
            entries = entries.filter { $0.group == g }
        } else if !opts.includeStress {
            entries = entries.filter { !$0.group.requiresOptIn }
        }
        if let f = opts.filter?.lowercased(), !f.isEmpty {
            entries = entries.filter {
                $0.id.lowercased().contains(f) ||
                $0.name.lowercased().contains(f) ||
                ($0.module?.lowercased().contains(f) ?? false)
            }
        }
        return entries
    }

    static func printRegistry(_ opts: Options) -> Int32 {
        let entries = pick(opts)
        print("TestDriver registry (\(entries.count) shown)")
        for entry in entries {
            print("  [\(entry.group.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))] \(entry.module ?? "—") / \(entry.name)")
        }
        return 0
    }
}
