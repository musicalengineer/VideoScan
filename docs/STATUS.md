# Status — rewritten, never appended

*Updated 2026-10-30 (afternoon). Rick corrects this file; agents read it at session start.*

## Today
**Until 16:00: verify, no new features.** Rick's goal: 100 % stability on both Studios (M4 = headless test/LLM host, `RicksM4`; M5 Ultra = Rick's machine, `RicksUltra`). **After 16:00: Rapid Dev + deep design** on the video LLM approach lab (Fable available). Main is pushed again (local-only hold ended 10/29); push after each merge, pull at session start. No FamilyArchive rescan until Rick says so.

## State of the machines (10/30)
- **02:00 nightly 10/30 GREEN on both:** M4 `a86bb5fc` app 12,577 pass / 0 fail / 63 skip, Core 1,962 / 0; Ultra `604fd5fc` app 12,576 / 0, Core 1,962 / 0. #381/#385 did not recur.
- **SSH Ultra → M4** was refused 10/29 night (Ultra key missing from the M4's `authorized_keys`; no repo script touches that file); Rick re-added it 10/30 14:23. Works.
- **M4 catalog copy** replaced 10/30 14:26 with a sqlite `.backup` of the Ultra's (schema 13, integrity ok, SHA-256 `a790a9fd…`); old copy kept as `catalog.schema12-20261030.sqlite`. This is why the M4's nightly Hallie replay read 0/56 since 10/27 (Ollama 0.40.12 and both models are fine there).
- **M4 deep gauntlet:** first run 10/30 BLOCKED (manifest missing 5 new Python tests) → fixed `a8e62bb1`, #400 filed for the hook gap; rerun in progress. Then: push main, run the M4 Hallie strict replay to prove the nightly lane.
- Gauntlet cannot go green as built: its regression stage counts `withKnownIssue` tests as failures, and "blocked" stages report "safe subset passed" — a runner-policy question for Rick.
- 557 Thread Performance Checker priority-inversion traces in the Ultra test log (main waiting on Default QoS via `CatalogLaunchWait.run`); not failures; not yet checked against issues.

## Landed 10/29–30 (on main, pushed except `a8e62bb1`)
- **Hallie grade C → B** (`night/hallie-grade`): 8 functions over CCN 30 split (max 41 → 14), characterization tests first, Codex merge/0 per slice. The B is marginal (mean 2.50; bug density 39.5 of 40). #397 (dead "how" help route — Rick's call), #398 (lizard mis-measures nested interpolation with an apostrophe).
- **Hallie baselines** (`docs/reviews/hallie_benchmarks.md`, Ultra): qwen3.8:27b-mlx strict 56/56 twice, advisory 671/826, median 0.54 s / p90 1.9 s; llama3.3:70b 55/56 (strict-034 is wording-dependent — Rick to rule), 633/826, 3× slower. Per-turn `latencyMs` in the transcript; 9 harvested questions added. M4 half still to run.
- **Live replay viewer:** `scripts/nightly_hallie_replay.sh --live [--strict-only|--advisory-only] [--speech]` — queries cyan, answers green, blank line after each answer.
- **Find Tag (POI) background daemon switched off** (setting `findTag.backgroundEnabled` false; DECISIONS 10/23 froze recognition). #395: its journal ingest rejects every journal as "different catalog".
- Docs: `docs/proposed_video_llms_for_breen_media.md` (design, cloud session), `docs/research/video_llm_for_family_media_2026-10-29.md`, `docs/reviews/video_llm_design.md` (Claude's plain-language review: what to settle first).

## Waiting on Rick
- **Modes draft**, branch `docs/process-modes` (day: Rapid Dev / Safety Critical / Bug Fix / Deep Design; night: Testbed / Hardening / Research & Dev) — yes or edits.
- **Rulings:** strict-034 (advisory or template answer); #397 (turn on the help route).
- **Spot tests (Debug):** Hallie after the refactor; Provenance ▸ Set Role and Find Master; Archive 144 Masters; #375 nickname (Timmy); #345 no-sound mark; People row removal; arrow keys in lists; Migrate summary words; ⌘⌫ on a duplicate pair. #383: Tidy Catalog…, then Skip Small Files back on.
- **Allowlist:** read-only ssh/status commands for unattended nights (a permission prompt stalled the 10/29 night shift); Claude proposes, Rick approves.

## After 16:00 — video LLM deep design (read first)
1. `docs/reviews/video_llm_design.md` — settle first: the model lab and Content Analysis share **one engine**, hosted by a **background service** that runs after quit (needs list from 10/29: what runs after quit, one supervisor, visible/stoppable with the app closed, journals only, own name in Activity Monitor, backs off while Rick works, no extra permission grants unless unavoidable).
2. Phase 0 of the design (baseline the existing 3B captioner against held answers) needs no schema and no rulings.
3. **Provenance Grade** (auto-generated, per file, evidence-only): #396.

## In flight (unchanged)
- `fix/committer-lost-writes-codex141`: Codex round 3 block/3; parked (two writers on one catalog only).
- Swift 6 (#376): close once #381/#385 are called. Analysis lane not installed (`scripts/install_analysis_lane.sh`, M4).
- Open: #384 ledger atomicity · #389 foreign writer during open · #377 floor gap · #379 · #380 · #381 · Step G (JSON gone) · #338, #339 · VideoScanModel split #337 (plan → Rick's go).
- Old remote branches with commits not in main (`feat/167-catalog-versioning` 25, `wip/r4-untested`, `parked/show-again-review`, `feature/metrics-work-board`, `fix/ci-main-green`, `cloud/N1019-R-week`, an agent branch): triage as a night task; nothing deleted.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.
- Mid-November: Rick's target of grade A in every module.

## Open rulings wanted from Rick
1. Schema v14 (provenance assertions + veto trigger, Phase C) and Phase B picture timeline numbering.
2. Provenance gate at ingest or at Promote; hard or soft for the first month; role list; July 2026 device chain.
3. Charter: line 148 "SHA-256 over first and last 4 MB" contradicts rule 6 (whole-file); GRDB named but unverified; Triage keep / fold / cut.
4. Video LLM design §9: cloud for derived text only?; 50 place labels; Qwen or Gemma first; v14 timing.
5. #327 remainder; People engines; Archive Angel; two-copy edit conflict policy.
