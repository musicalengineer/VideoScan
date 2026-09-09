# Morning brief — 2026-09-09 (overnight theme T1: GitHub High Priority sweep)

Owner: Claude (overnight lead). Reviewer: codex (files issues, no edits).

## Status line (10:55 ET 9/09)
- 🔴 **CI Build & Test: RED but for the first time since 09-01 it builds and runs tests** (run 34296771692 on b06c5570: 137 run, 6 skipped, 1 failure — a Debug perf ceiling on the shared virtual M1, fix below).
- ✅ nightly-analysis: GREEN (dispatch 34296771594 + schedule 34333938972) — first green since 08-20. Strict-concurrency built; lint jobs built.
- 🔴 **CodeQL still fiction: 82 of 1,311 files scanned.** SARIF: 1,875 extractor errors, one shape — Xcode 26's explicitly-built clang PCMs rejected by CodeQL 2.26.4's frontend ("built from a different branch (clang-1700.6.4.2)"). Attempt 8 = explicit modules OFF for the CodeQL build (hypothesis).
- python-tests: run 34296771725 (not checked).
- M4 nightly lane: not checked (codex owns from 10:52 — #1229).
- 09:00 codex's nightly local review of 25 commits: 0 flagged (#1228).

## Handoff 10:52 ET
Rick assigned codex QA lead (#1229). From the attempt-8 SHA, codex owns .github/, VideoScanTests/, tests/, TestDriver/, GH #171/#173, the M4 lane timeout and Hallie replay restoration (#1231). Claude stays on app code.

## Plan (written 2026-09-08 19:25 ET before starting)
1. GH #171 — nightly-analysis red since 08-20; CodeQL scanned 1/1,283 files. Attempts 1–2 (Metal Toolchain download, -runFirstLaunch) failed; attempt 3 (skip *.metal in analysis builds + pipefail) dispatched.
2. GH #172 — Hallie servers pane probes by hostname; M4 shows idle / model "(not installed)" while the M4 is actually serving.
3. Next oldest High Priority issue with a repro, if #171/#172 close before the cap (3 issues / 4 h).

## Merges
(SHA · one line · suites)
- ebf76cde · #172 Hallie servers pane probes local hosts on loopback; closed with summary · OllamaLocalServerBootstrapTests 10/10
- (no code) · #89 closed with evidence: cache short-circuit + ScanJobsStorage restore already built; tests cited
- 9802f078 · #151 ReferencePhotoImporter: outcome-reporting copy, rename on same-name-different-photo, orange failure line · ReferencePhotoImporterTests 6 + POIFamilyNameFieldsTests

## #171 trail (nightly-analysis red since 08-20)
- 3626e88f download Metal Toolchain → still "missing Metal Toolchain" (run 34284885188)
- f357efc5 + -runFirstLaunch → same (34287385119); `xcrun -f metal` resolves, xcodebuild's CompileMetalFile does not
- "attempt 3" never landed (edit script aborted; run 34288856384 = attempt 2 workflow) — lesson: verify the diff before dispatching
- strict-concurrency's OTHER cause found from its artifact: FamilyTreeView.swift:144 "unable to type-check this expression in reasonable time" → body split (pure extraction), pushed; attempt 4 = run with the split
- a4d57f50 EXCLUDED_SOURCE_FILE_NAMES='*.metal' in all 5 build steps + pipefail → attempt 5 = run 34290562942

- f616dd4d · #173 CI Build & Test red since 09-01 (80/80): VolumeDetailPane optional Double; + FamilyTreeView 3-stage modifier chain; + arm64-only analysis builds → attempt 6 = run 34295862360 (nightly) + 34295862288 (CI): BOTH RED, one cause — ContentView.swift:490 CatalogView.body (495 lines) "unable to type-check this expression in reasonable time" on the runner's Swift 6.2.4 (Xcode 26.3, same as local; local compiles it). All three nightly build jobs (strict, lint-warn Periphery build, lint-strict Periphery build) die on it.
- b06c5570 · CatalogView.body split into rootSplit/bottomPane/catalogToolbar/catalogContent + withCatalogObservers/withSheets/withAlerts — pure extraction, modifier order preserved; local Debug build green → attempt 7

## Not done and why
- #133 People column reliability: no repro on file; not started (needs a repro from Rick).
- #170 archive portability: waits on Rick's two decisions (filed 9/08).
- CodeQL real coverage: attempt 8 dispatched but unverified at hand-off; if 82/1311 persists, next lever is pinning codeql-action `tools: latest` (Swift 5.4–6.3 is documented as supported) or building for CodeQL with a private MODULE_CACHE_DIR.

## Decisions for Rick (max 3)
