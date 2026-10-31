# Status — rewritten, never appended

*Updated 2026-10-31 14:40 (Saturday, after the morning testbed and the stability fixes). Rick corrects this file; agents read it at session start.*

## Where main stands — `697237a2`, pushed, checkout clean
**Stability call for today: main is green on every lane that measures code.** The only reds of the day were two
measurement rules, both fixed on main:
- **Timing budgets are strict only where the lane pins them** (`VIDEOSCAN_TIMING_STRICT=1`, the 2 AM nightly on a dedicated
  Mac Studio); a load-average guess never makes a budget strict (Rick's ruling, DECISIONS 2026-10-31, closes #407). Everywhere
  else a miss up to 3× is a visible known issue, beyond 3× still a failure. Why: the daytime Ultra ran every search query ~35 %
  slower than at 02:00 on the same code, load 2.9 on 30 cores was called "quiet", and one 50 ms budget failed twice at 1.01–1.02×.
- **The nightly card names every lane.** Last night's card read "12,645 passed · 0 failed — broken" with "0 failing" above it;
  the Core lane (1 failed) and the Hallie replay (failed) were unnamed. The publisher now carries app / Core / Hallie per cell,
  one Core failure is WATCH like one app failure, and the tile says "2 AM run of <date>". **Lane ladders** (Rick's ask, afternoon):
  one vertical ladder per Mac on that tile, one rung per lane (App, Core, Hallie strict, Hallie advisory, Hallie voice), each
  rung by its own lane's rule, grey where the lane did not run; hover gives numbers and the reason code. Both show from the
  next nightly's publish (the publisher runs with it).
- **Testbed machine rule (PROCESS §8, Rick 2026-10-31):** the **M4 is the default testbed**; the Ultra during the day is rapid dev
  with Claude, nothing else, unless Rick declares a window. No machine named for a testbed means the M4; "On the M4?" is fine.

## Today's testbed, M5 Ultra, main `fc620035` (Rick's declared window, before the rule above)
| Lane | Result |
|---|---|
| App unit suite, Release, run 1 and run 2 | 12,637 passed · 1 failed both times: the 100k keystroke budget '1990s' at 50.8 / 50.5 ms vs 50 ms (host ~35 % slower than at 02:00; 13 known issues) |
| Core, Release, serial (the nightly's `--no-parallel`) | 1,918 passed · 0 failed · 13 known issues |
| Core, Release, parallel (two runs) | 2 failed both times: resident-size growth checks contaminated by sibling suites → #407, fixed by the timing ruling |
| UI smoke (`run_ui_smoke.sh`) | passed |
| Gauntlet UI plan, 17 flows on the real screen | 12 passed · 5 failed deterministically against today's UI → **#408** (three flows look for "Catalog Options" on the Catalog tab, one for File ▸ Catalog Info, one needs the face-photo fixture) |
| **Release gauntlet on the M4**, main `fc620035` (1,664 s) | **5,494 passed · 0 failed** — unit 3,647 · regression 634 (7 known issues) · integration 6 · performance 82 (the keystroke budget passes on the M4) · hallie 1,116 · stress 9. The runner stamps it FAILED by its own policy: known issues count as failures and phase-1 subsets are "blocked" (658 unadapted suites in unit). That policy is the open ruling below. |

Nightly 2026-10-31 02:00 (Ultra, `30e41529`): app 12,645 / 0; Core 2,133 / 1 (the pause/resume race test, fixed `6891a20c`);
Hallie strict 52 / 56 (pre-existing, route_mismatch ×4), advisory 145 / 826 in the 3600 s cap — the GPU was held all night by a
wedged model process (#406, fixed). Tonight's nightly is the first clean reading of both.

## Video-LLM lab — where it stands (`docs/reviews/video_llm_benchmarks.md`, `tools/video-llm-bench/README.md`)
- **A0 (3B, stills)** and **A1 (3B, windows + contracts)** published. A1 raised ERA answered 18 % → 98 % without improving accuracy
  where it answers (Rick-dated MAE 5.9 y); windows cost OCR 4–6 points → one engine, two samplers.
- **A2 (Qwen3-VL-8B-4bit)** code on main (`ad682964`); **#406 watchdog on main** (`fc620035`): the model runs in a worker
  process, `--generation-timeout` (120 s) kills a wedged generation and reloads, `--deadline HH:MM` stops between clips.
  **The full A2 run is 195 of 327 clips in** (`VideoScan-wt/bench-a2/.scratch/bench/runs/full-a2-py-r3-n8`, resume-safe, 0 timeouts,
  0.39 s/frame); it was stopped for the testbed. **Resume in the next declared window** (≈ 25 min for the remaining 132):
  `nice -n 15 venv-mlx/bin/python3 tools/video-llm-bench/bench.py run --approach a2-py --frames 8 --generation-timeout 120 --deadline 01:30 --manifest <bench-a2>/.scratch/bench/manifest.json --model-dir ~/.cache/huggingface/hub/models--mlx-community--Qwen3-VL-8B-Instruct-4bit/snapshots/defcdea7cc7a4b0858fea563cbbce171d328e457 --out <bench-a2>/.scratch/bench/runs/full-a2-py-r3-n8`
  then `summarize` with the A0 (`20261030T201800-a0-py`) and A1 (`full-a1-py-r3-n6`) runs under `VideoScan-wt/bench-a1/.scratch/bench/runs/`.
- **32B weights are cached** (18 GB, `models--mlx-community--Qwen3-VL-32B-Instruct-4bit`); one run on the 72 Rick-dated clips after A2 reads.
- **Household Roster (A7) feasibility** published `2cb31fa5`: a filter, not a namer; ties are same-sex same-generation siblings.

## Landed last night (all pushed)
- Background service step 0 (`dfafcc98` + `5c9686d8`): helper target, SMAppService, XPC with peer trust, supervisor, off by default
  behind `background.service.enabled`. **Spot test (Debug):** `defaults write Rick-Breen.VideoScan background.service.enabled -bool true`
  → launch once → `launchctl print gui/$(id -u)/Rick-Breen.VideoScan.Background` → helper `--status`, `--enqueue noop 120 1000` →
  `tail -f ~/Library/Logs/VideoScan/background.log` → quit the app, it keeps counting.
- Model-lab Core types (`2a2c3c5f`); **#402 part A + readers** (`85fe3140`): degenerate captioner output refused at the write routes,
  every OCR-date reader uses `usableOCRDates`, Catalog Status counts the stored junk. **Spot test:** junk no longer counts as date evidence.
- Issues filed: #402 (comments), #403 iMovie reference movies, #404 docs-links guard, #406 watchdog (fixed), #407 (fixed), #408 gauntlet UI flows.

## Waiting on Rick
- **Rulings:** background service design §7 — 2 name/icon badge, 3 exit-when-idle default, 4 step order (1 agreed). Video-LLM
  design §9 — cloud on derived text · 50 place labels · Qwen vs Gemma first · v14 timing. A2 N=8 (rule) vs N=6.
- **Terminal run** of Codex's attended review pilot (`VideoScan-wt/attended-model-review`, `tools/model-fitness/attended_review.py --execute`).
- **Modes draft** (`process-modes` branch). Older: strict-034; #397; gauntlet runner policy; toolchain list.
- **Spot tests (Debug):** background helper; #402; GEDCOM dates + sparkle; Hallie after the refactor; Provenance ▸ Set Role and
  Find Master; Archive 144 Masters; #375; #345; People row removal; arrow keys; Migrate words; ⌘⌫ on a duplicate pair; #383.
- **Allowlist:** read-only ssh/status commands; a `kill <own pid>` shape for an agent's own model process.

## Next
1. A2 resume (declared window) → summarize → 32B on the Rick-dated stratum.
2. #408: repoint the five gauntlet UI flows, then turn the runner's UI stage on for the away window.
3. Background service step 1 (first real job into the helper; §5 order pending ruling 4). #402 supersede pass brief → Codex.
4. Resource allocation for LLMs and visual LLMs across the fleet (Rick's agenda item, 10/31).

## State of the machines (10/31 afternoon)
- Ultra: free for rapid dev; no agent jobs. M4: idle after the gauntlet (`RicksM4.local`, main `fc620035` pulled, 259 GB free).
- Worktrees under `VideoScan-wt/`: all landed except `attended-model-review` (Codex pilot, dirty) and `process-modes` (draft).
  `bench-a2` holds the A2 run state under `.scratch/`. Nothing deleted; prune is Rick's call.

## To file
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed; 557 Thread Performance Checker traces; Hallie strict
  route_mismatch ×4 two nights running — check against existing issues first.

## In flight (unchanged)
- `fix/committer-lost-writes-codex141`: parked. Swift 6 (#376): close once #381/#385 are called.
- Open: #384 · #389 · #377 · #379 · #380 · #381 · Step G · #338, #339 · VideoScanModel split #337 (plan → Rick's go).

## Dates
- 2026-11-01: off-site copy plan due. 2026-11-05: cloud session credits expire. Mid-November: grade A in every module.
- 2026-12 soft / 2027-01 target: Public view link for family (BACKLOG; Charter §5).

## Open rulings wanted from Rick (older, still open)
1. Schema v14 (provenance assertions + veto trigger, Phase C) and Phase B picture timeline numbering.
2. Provenance gate at ingest or at Promote; hard or soft for the first month; role list; July 2026 device chain.
3. Charter: GRDB named but unverified; Triage keep / fold / cut.
4. #327 remainder; People engines; Archive Angel; two-copy edit conflict policy.
