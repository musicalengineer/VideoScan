# Morning brief — 2026-10-02 (overnight theme: hardening / nightly adversarial review)

## Status first
- **CI on main: 🟢 green** at `f74155b9` (Preflight, VideoScanCore package tests, Build & Test). 🔴 It was **red from ~22:25 to 05:07**: the root-lock gap tests added with the codex #19 fixes flaked under parallel load. Root cause found and fixed (details below).
- **2 AM nightly (M4, Release): 9,762 tests in 1,428 suites in 19.5 min; 1 real failure.** A sensor flagged the two new Life & Times files as unregistered `.notes` writers. They only assign GEDCOM NOTE text inside their own value types, so I registered them (`fa313198`). The other 3 issues in the run were already marked as known.
- **Nightly Static Analysis (GitHub): ⏳ not fired yet** at 06:10. GitHub's 05:00Z schedule has been landing around 11:00Z. It is the first run with findings → issues, in **dry run**; its plan of which issues it would file goes in `metrics/nightly_findings_latest.json`.
- **Coverage, 04:00 on the M4: ✅ first numbers since June.** App code is at **51.2% of lines** (141,531 / 276,210). VideoScanCore has no numbers yet, because its tests failed under load at 04:00. That is fixed, so tonight's run should include it.

## 🔴 Decisions for you (one at a time is fine)
1. **Merge `fix/adversarial-2026-10-01-findings`?** It holds the fixes for all 12 dry-run findings, with green tests (app 347, Core 831). I held it because one commit changes the record-filing OUTCOME log line, which is on the escalation list. It adds a suffix, ` — document Documents/.trash/…`, and replaces an id that contained the person's name with "recorded". The `OUTCOME <kind> (<code>)` prefix is unchanged.
2. **Turn on issue filing:** after you've seen tonight's dry-run plan, set the repo variable `NIGHTLY_FINDINGS_WRITE=true`. Only high and medium findings get their own issue, at most 10 a night. Low findings go into one digest issue per tool.
3. **Confirm step, app tests:** the 05:30 job runs with `--no-app-run`, so drafted app tests compile but don't run, because running them launches VideoScan.app as the test host. Turn it on? It's one line.
4. **Timing budgets (#208):** one 100k-person CyberBrain timing test now fails under a full parallel run. Either the load allowance scales with measured load (this changes every timing test), or someone investigates that index build.
5. **Later (end of the shadow week, about 10/9):** amend the codex spend policy so gated nightly and weekly codex passes are pre-approved.

## How much better is the overnight system? (what you asked for)

| Area | Yesterday morning | This morning |
|---|---|---|
| **Adversarial review** | Manual only: Claude QA plus codex when you triggered it | **Unattended nightly** (00:30 under launchd, which proves the OAuth login works with the screen locked). It reviews only that day's data-path and truth-path changes against written invariants (`docs/practices/invariants/`), with drafted failing tests. Shadow mode: no issues filed yet. |
| — its results so far | — | Dry run (`9ed39299..05c2b9a5`): **12 findings, 12 real.** Unattended run 00:30 (codex #19 fixes): **3 findings, 3 real.** **Precision 15/15.** Cost ~$10.70 notional ($8.01 + $2.70). Every one of the 15 is fixed: 3 merged, 12 held for decision 1. |
| **Codex** | Ad hoc, with your kick | Two scoped passes from briefs (#18: 5 findings, #19: 4), all fixed red-first, with cycles closed. Codex also did the `docs/` reorganization. |
| **Static analysis** | Ran every night, but the dead-code count read 0 because of a bad option, and nothing became an issue | CodeQL proven at **931/931** app and Core files, with an 80% floor that fails the job if it drops. Dead-code count fixed (1,464). UBSan added: 4 real reports, all in vendored mlx C++. ASan added for VideoScanCore. Strict memory-safety build added: 1,590 warnings, all missing `unsafe` markers, low severity. **Findings → issues** built and gated by decision 2. |
| **Testing** | Example-based tests | **31 generated-input property tests** (seeded, with shrinking) on places, GEDCOM, dates, surnames and Hallie routing. They **found 14 real bugs**, all fixed. They now run in every suite. |
| **Coverage** | None since June 14 | Nightly at 04:00 on the M4, after the 2 AM run: per-folder all-lines % and logic-only % (SwiftUI views reported, never gated), plus zero-coverage logic files. |
| **Test hygiene** | Flaky timing tests made CI red | The flake root cause was GCD QoS starvation in the tests, not the lock. Separately, a **real parse slowdown** was found and fixed: the GEDCOM line split used a key path, so threads fought over one shared object (33 s vs 0.1 s per parse at 16 threads). The Core suite went from ~80 s to ~28 s. A sensor guards it. |

**What isn't working yet, plainly:**
- The 05:30 confirm step tested the drafts against current main, after the fixes had merged. So it reported "0 of 2 confirmed" for findings that were real. Filed as #247: it should build at the reviewed head.
- No Core coverage numbers until tonight.
- The GitHub nightly with findings → issues has never run on main; it is due this morning.
- The ASan app leg didn't fit the runner's time budget; Core only for now.
- The coverage view heuristic is coarse: a file that declares any SwiftUI view counts as a view. Treat logic % as an upper estimate until it's refined.

## Coverage snapshot (app; logic % excludes SwiftUI views)

| Folder | All % | Logic % | Zero-coverage logic files |
|---|---:|---:|---|
| ★ Hallie | 79.4 | 89.9 | HallieWebAccess.swift |
| ★ ArchiveAngel | 62.6 | 91.8 | — |
| ★ MediaOps | 52.5 | 85.9 | — |
| ★ Archive | 51.6 | 90.6 | — |
| ★ FamilyTree | 50.7 | 92.1 | — |
| ★ Volumes | 33.9 | 81.7 | PhysicalStoreResolver.swift |
| ★ Catalog | 33.1 | 92.5 | — |
| People | 29.2 | 54.6 | ConfirmPersonSheet+Candidates, PersonFinderInspectorTypes, RecipeCalibrationCLI, RecipeGenderAgeGate |

Full table: `~/Library/Logs/VideoScan/coverage/coverage-2026-10-02.md`. ★ marks a folder that will be gated with a floor and a no-drop rule.

## Merged overnight (all on main and pushed)

| SHA | What |
|---|---|
| `c9caac20` | `docs/` reorganization (codex): guides / practices / design / research / reviews / ops / archive, plus a link-check test |
| `ac127f8d` | Fixes for codex #19's 4 findings: rollback only undoes what it owns, failed note saves retry, legacy-readable document kinds |
| `c8955dfb` | Nightly adversarial review: invariants, tool, sandboxed confirm, LaunchAgents (shadow mode), morning line |
| (merge after c8955dfb) | Findings → issues (dry run), CodeQL floor, UBSan/ASan, strict memory safety, Periphery option fix |
| `6e3b81a0` | Fixes for the first unattended review's 3 findings: note conflicts get Keep mine / Keep theirs, re-runs keep your work |
| `fa313198` | Notes-writer sensor registration (the nightly's one failure) |
| `f74155b9` | Core flake fix plus the GEDCOM parse contention fix and its sensor |
| (tools) | `tools/nightly_coverage.py` plus LaunchAgent `com.videoscan.nightly-coverage` at 04:00 |

Held: `fix/adversarial-2026-10-01-findings` (decision 1). New issues: #245 (codex #19 leftover coverage gaps), #247 (confirm step should test at the reviewed head). #171 updated with the CodeQL evidence; #208 updated with the timing evidence.

## Housekeeping
- Merged agent worktrees pruned. Two remain: `fix/adversarial-2026-10-01-findings` (held) and an older `worktree-agent-a42cf181191b201ae` (unmerged, origin unknown; it's for the morning branch purge).
- A deliberately-deadlocked `swiftpm-testing-helper` (pid 81465) from last evening's lock tests may still be around. It's harmless; under the no-kill rule I left it alone.
