# Codex review — TimingBudget tier-aware busy rule

- Range: `main..fix/timing-budget-tiers`
- Credits spent: unavailable
- Tokens: 67960
- Finding count: 0
- Verdict: merge
- Run: 2026-10-28T00:59:48Z (cycle #161, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0

- `TimingBudget.swift`: read, no findings.
- `TimingBudgetTests.swift`: read, no findings.
- `PerformanceLane.swift`: read, no findings.

The strict override still wins over load and GitHub detection. Both reference-budget wrappers use that override, and the nightly exports both environment spellings. The M4 reference host keeps threshold 8; legacy Release ceilings remain unchanged.

There is one busy-threshold calculation. Both live load-factor paths supply the fast-tier probe; no live caller retaining the old calculation was found. Missing sysctl keys, failed reads and invalid tier counts fall back to half the logical cores.

The injected tests meaningfully pin Ultra boundaries, M4 compatibility, fallback behavior and strict precedence. Given the supplied measurements, 0.7 is defensible as a heuristic: idle load 5–6 remains strict. Local busy runs can still soften real regressions up to 3× by design; the reference nightly retains enforcement.

Validation: attempted `swift test --filter TimingBudget`; sandbox permissions stopped Swift before execution. **0 tests ran.** The commit’s reported 29-test pass was not independently reproduced.

Verdict: merge

## Brief

# Codex review brief — tier-aware TimingBudget busy/quiet rule

Range: main..fix/timing-budget-tiers (commit c037904f). Files:
VideoScan/VideoScanCore/Sources/VideoScanCore/TimingBudget.swift,
VideoScan/VideoScanCore/Tests/VideoScanCoreTests/TimingBudgetTests.swift,
VideoScan/VideoScanTests/PerformanceLane.swift.

Context: on the M5 Ultra (30 logical cores: 10 "Super" perflevel0 + 20
"Performance" perflevel1) timing tests ran strict ("quiet") at load 8–14
because busy = load ≥ 50% of logical cores (15). Measured on the Ultra: thread
CPU time of a fixed workload rises ~20% with 2 spinning neighbours and +44–80%
at 8–14. Change: busy threshold = min(0.5 × logical, 0.7 × fast cores) where
fast = hw.perflevel0.logicalcpu when hw.nperflevels > 1. M4 Max (16, 12 fast)
stays 8; single-tier hosts unchanged. No budget numbers changed.

Review adversarially:
1. Can this hide a real regression? Busy runs record known issues (≤3×) rather
   than fail; is VIDEOSCAN_TIMING_STRICT / the reference-run path still strict
   where it must be? Does the nightly reference host's behaviour change?
2. Is there still exactly one busy rule (TimingBudget, loadFactor path, the
   app's PerformanceLane forwarder)? Any caller left on the old rule?
3. sysctl reading: failure modes (missing keys, Intel, VMs, GitHub runners);
   does it fall back safely to the old rule?
4. Are the new tests meaningful (injected core counts), and do the existing
   TimingBudgetTests still pin M4 behaviour?
5. Is 0.7 defensible, given the Ultra's idle load average sits around 5–6?
Out of scope: the 50 ms keystroke budget (separate issue), keeping .scale tests
out of in-process parallel runs (separate issue).

## Output contract
First line of your answer exactly: `Credits spent: <amount> | Finding count: <N>`
Then findings (file:line, failure scenario, severity), then a line `Verdict: <merge | fix | block>`.
