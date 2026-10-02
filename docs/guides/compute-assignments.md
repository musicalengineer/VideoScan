# Compute Assignments

**Status:** Living document
**Last updated:** 2026-05-12
**Author:** Codex

## TL;DR

GitHub is the repo and coordination system. Real test execution belongs on real Apple Silicon hardware.

## Assignment Map

| Place | Owns | Does not own |
|---|---|---|
| Local Mac Studio | Daily development, fast unit/regression tests, focused bug reproduction, final local verification before handoff | Long unattended shared test windows |
| M1 Max MBP / self-hosted runner | Full suite, TSan, coverage, performance/stress runs, Xcode/AppKit-dependent automation | Repo coordination, issue tracking, long-term metrics hosting |
| GitHub-hosted Actions | Repository checks, pull request visibility, CodeQL, strict-concurrency build warnings, SwiftLint/Periphery reports, metrics publishing | Unit tests, TSan, coverage, UI tests, performance results |
| GitHub web | Issues, project board, PR review, releases, code scanning alerts, Pages dashboard | Source of truth for test pass/fail while GH-hosted macOS runners remain affected |

## Agent Work Lanes

Claude's hardening work owns app behavior, Swift model refactors, tests, QA review, and performance findings.

Codex's `codex/ci-infra` worktree owns CI and repo plumbing:

- `.github/workflows/`
- `docs/`
- `scripts/ci_*`
- `scripts/collect_metrics.sh`
- `docs/index.html` metrics dashboard plumbing
- GitHub issue / PR metadata via `gh`

Codex should avoid production Swift and Swift test files in this lane unless Rick explicitly redirects the work.

## Current Rule

If a job runs `xcodebuild test`, needs AppKit behavior, produces coverage from an `.xcresult`, or relies on Thread Sanitizer, run it on local hardware or the self-hosted MBP runner.

If a job is repository metadata, issue tracking, CodeQL/code scanning, Markdown/YAML checks, or static analysis that only requires a build and produces warnings, GitHub-hosted Actions is still useful.

## Why

As of 2026-05-11, GitHub-hosted macOS runners are not reliable for VideoScan's Swift Testing unit suite. The observed failure mode is not just slow execution; it can make test results misleading enough that GitHub should not be treated as the authoritative test runner.

The useful split is therefore:

- **GitHub = coordination and static signal.**
- **Mac hardware = correctness, runtime, and performance signal.**

## GitHub Nightly Static Analysis

Still useful:

- Swift strict-concurrency build warnings.
- CodeQL security-and-quality analysis.
- SwiftLint strict reports.
- Periphery aggressive unused-code reports.
- Metrics branch updates for dashboard history.

Not useful on GH-hosted runners:

- Thread Sanitizer test runs.
- Any unit-test-derived pass/fail or coverage number.

TSan should come back only when the workflow runs on `[self-hosted, macOS]` or when GitHub-hosted macOS test execution is proven reliable again.
