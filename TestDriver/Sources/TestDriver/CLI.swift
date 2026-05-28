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
//   TestDriver --cli --coverage            # add -enableCodeCoverage to xcodebuild
//   TestDriver --cli --coverage-all        # implies --coverage + include regression
//
// Exit code: 0 if all selected passed, 1 if any failed, 3 if a harness/CLI
// error occurred. (`.unclear` is gone — formerly-unclear cases now report
// as failed with an explanatory message.)

import Foundation

enum CLI {

    static func run(arguments: [String]) async -> Int32 {
        VideoScanTests.registerAll()
        let opts = parse(arguments)

        // Wire the CLI's coverage flags into the same context the UI uses.
        VideoScanTests.coverageContext = (enabled: opts.coverage,
                                          includeAll: opts.coverageAll)

        if opts.listOnly {
            return printRegistry(opts)
        }

        let entries = pick(opts)
        if entries.isEmpty {
            print("No tests matched the given options.")
            return 3
        }

        print("TestDriver CLI")
        print("  host:    \(opts.host.displayName)")
        print("  tests:   \(entries.count)")
        print("  groups:  \(Set(entries.map(\.group.rawValue)).sorted().joined(separator: ", "))")
        if opts.coverage {
            print("  coverage: ON\(opts.coverageAll ? " (include all)" : " (unit only)")")
        }
        // Snapshot what we're about to test — same info the UI banner shows.
        let repo = await RepoInspector.inspect(host: opts.host)
        print("  repo:    \(repo.oneLine)")
        print("  path:    \(repo.projectDir)")
        if !repo.commitSubject.isEmpty, repo.commitSubject != "—" {
            print("  subject: \(repo.commitSubject)")
        }
        print(String(repeating: "─", count: 70))

        var methodsPassed = 0
        var methodsFailed = 0
        var entriesSkipped = 0
        var coverageSamples: [Double] = []
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
                if let mc = result.methodCounts {
                    methodsPassed += mc.passed
                    methodsFailed += mc.failed
                } else {
                    methodsPassed += 1
                }
                let detail = result.log.split(separator: "\n")
                    .first(where: { $0.contains("tests passed") || $0.contains("passed") })
                    .map { " — \($0)" } ?? ""
                print(String(format: "    ✓ pass  (%.2fs)%@", dur, detail))
            case .failed(let msg, _):
                if let mc = result.methodCounts {
                    methodsPassed += mc.passed
                    methodsFailed += mc.failed
                    if mc.passed == 0 && mc.failed == 0 { methodsFailed += 1 }
                } else {
                    methodsFailed += 1
                }
                print(String(format: "    ✗ FAIL  (%.2fs) — %@", dur, msg))
                if !opts.verbose, !result.log.isEmpty {
                    let tail = result.log.split(separator: "\n").suffix(20).joined(separator: "\n")
                    print("    │ \(tail.replacingOccurrences(of: "\n", with: "\n    │ "))")
                }
            case .skipped(let reason):
                entriesSkipped += 1
                print("    ↷ skipped — \(reason)")
            default:
                break
            }
            if let cov = result.coveragePercent {
                coverageSamples.append(cov)
                print(String(format: "    │ coverage: %.2f%%", cov))
            }
        }

        let total = Date().timeIntervalSince(started)
        let coveragePct: Double? = coverageSamples.isEmpty
            ? nil
            : coverageSamples.reduce(0, +) / Double(coverageSamples.count)

        // Build a RunSummary so MetricsPublisher's gates apply identically
        // to the UI path. opts.publish defaults to true; --no-publish
        // disables. The publisher itself still gates on main + clean +
        // synced, so a pollute-attempt from a feature branch is silently
        // skipped even if --publish is on.
        let summary = RunSummary(
            methodsPassed: methodsPassed,
            methodsFailed: methodsFailed,
            entriesSkipped: entriesSkipped,
            entriesTotal: entries.count,
            elapsedSeconds: total,
            host: opts.host,
            repo: repo,
            startedAt: started,
            coveragePercent: coveragePct
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
            if methodsFailed > 0 { return "✗ FAILED" }
            if methodsPassed > 0 { return "✓ PASSED" }
            return "— EMPTY"
        }()
        print(String(format: "%@   %d executed   %d passed   %d failed   %d skipped   (%.1fs)",
                     banner, summary.total, methodsPassed, methodsFailed, entriesSkipped, total))
        if let cov = coveragePct {
            print(String(format: "Coverage: %.2f%%", cov))
        }
        print("Host:   \(opts.host.displayName)")
        print("Repo:   \(repo.oneLine)")
        print("Date:   \(ISO8601DateFormatter().string(from: started))")
        print(publishLine)
        print(String(repeating: "═", count: 70))

        if methodsFailed > 0 { return 1 }
        return 0
    }

    // MARK: - Options

    struct Options {
        var host: TestHost = .local
        var group: TestGroup? = nil
        var filter: String? = nil
        var includeStress: Bool = false
        var listOnly: Bool = false
        var verbose: Bool = false
        var publish: Bool = true   // pushes metrics under hard gates; --no-publish to disable
        var coverage: Bool = false
        var coverageAll: Bool = false
    }

    static func parse(_ arguments: [String]) -> Options {
        var opts = Options()
        for arg in arguments {
            if arg == "--list" { opts.listOnly = true; continue }
            if arg == "--verbose" || arg == "-v" { opts.verbose = true; continue }
            if arg == "--include-stress" { opts.includeStress = true; continue }
            if arg == "--no-publish" { opts.publish = false; continue }
            if arg == "--coverage" { opts.coverage = true; continue }
            if arg == "--coverage-all" { opts.coverage = true; opts.coverageAll = true; continue }
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
                    opts.host = .local
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
