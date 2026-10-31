# Status — rewritten, never appended

*Updated 2026-10-30 (late evening, Fable deep dive). Rick corrects this file; agents read it at session start.*

## Next session
**Rick reviews, then build starts.** Mode: Rapid Dev + Deep Design. Rick reads, in order: `docs/Purpose-and-Charter.md`
(reorganized; **Claude Feedback** blocks are his to keep, edit or strike) → `docs/design/background_service_2026_10_30.md`
(§7, four rulings) → `docs/design/video_llm_lab_2026_10_30.md` §9 (four rulings). First code when he says go:
**background service step 0** (helper target, `SMAppService` registration, XPC, supervisor with a no-op job,
`videoscan-bg`, Settings ▸ Background) and **model lab Phase 0** (wrap the 3B captioner as `A0`, publish baseline
numbers) — Phase 0 needs no ruling and can run on the M4 tonight if Rick prefers it first.
Also waiting on Rick: a Terminal run of Codex's attended review pilot (`VideoScan-wt/attended-model-review`,
command in that worktree's `models_research/README.md` under its docs folder, not on main); the agent sandbox cannot reach Ollama.

## 22:30 snapshot — main `db16b1e5`, pushed, **sensor lane GREEN (596 tests)** on that tree
- **Merged:** bench harness + A0 numbers (`93fadb8b`) · background service step 0 (`dfafcc98`, after the reviewer's 8 fixes:
  parked disk-full job resumable, CancellationError handling, OUTCOME through one door, `setCodeSigningRequirement` peer trust)
  · model-lab Core types (`2a2c3c5f`, after R1–R6: `LocalHost` by type, NUL-safe binds, real sampler floors, bare-decoder door shut).
  Merge fallout fixed on main: the two branches each defined a Core `ResourceProfile` → `JobResourceProfile` for the job queue
  (`496e3d7b`, unify later — BACKLOG); `model-lab.sqlite` classified in the App Support inventory sensor (`db16b1e5`).
- **A1 — DONE, merged `fa70aec0`** (`docs/reviews/video_llm_benchmarks.md`, 65 pytest): same 3B model, 3 chronological windows ×
  6 frames (N=8 collapses the model: 0/18 schema-valid — its ~2k image-token limit), strict JSON era/roomFeatures contracts decoded
  fail-closed. **Structure raised the ERA answered rate 18 % → 98 %** (era schema-valid 98 %, roomFeatures 81 %) **but not the
  accuracy where it answers** (MAE 20.2 → 22.8 y overall). On Rick-dated rows: answers every clip, MAE 5.9 y (A0 6.9), truth inside
  the range 81 %, median width 10 y — 1980s MAE 2.6, 1990s 5.0. On 2020s phone clips it is hopeless (MAE 36 y; it dates modern footage
  decades early — the codec/carrier floor in `DateTriangulator` must outrank it, as the design ranks it). **Windows cost OCR 4–6
  points** (92 → 86 % any-frame; h264 79 → 57 %): bunching frames into three stretches loses the burn-in that 5 spread stills caught →
  one engine, two samplers (stills for OCR, windows for era). Cost +15 % per clip. roomFeatures vocabulary 384 strings, all generic.
  Caveat: the prompt was tuned r1→r3 on 3 smoke clips that are in the corpus.
- **Running now (Opus worker, off the Ultra by 01:30):** **#402 part A** — refuse to store degenerate captioner output
  (`CaptionTextQuality` verdict in Core, filter before `applyCaptions`, OUTCOME count, red-first regression test, lane).
  **Household Roster feasibility — DONE, merged `2cb31fa5`** (`docs/reviews/household_roster_feasibility.md`, 36 pytest, roles not
  names): the roster cuts 10–13 people to 1–3 for any date; sex + age band alone is unambiguous for **42 %** of tags on Rick-dated
  files (69 % over the whole truth set, inflated by camera-dated clips of the spouse alone; 18 % once the owner's siblings join).
  Every tie is same-sex, same-generation, 1–3 years apart: the two older boys, the two younger boys, the two grandfathers, the two
  grandmothers. Verdict: A7 earns a place as a *filter*, not a namer; the model attribute that breaks ties must be identity-bearing
  (relative height / order in frame, glasses, within-occasion face similarity to Rick's confirmed references) — a better age guess
  cannot. Co-presence is the cheapest next rung (one identified grandparent settles the couple). Data gaps: truth set is only 41 files
  (54 of 73 Rick-dated files have no People tag); camera stamps agree with Rick's year 1 time in 4 (one DV stamp is 8 days after the
  tagged person's death — a transfer date). Guard tests on main fixed/filed: catalog-naming guard green (`b6fe2b2a`), docs-links #404.
- Worktrees for landed branches (`bg-service-0`, `model-lab-core`, `model-lab-bench`, and the older landed ones) are left in place —
  nothing deleted; prune is Rick's call.

## Built tonight (10/30 evening, three workers in worktrees; Rick's checkout untouched)
- **Video-LLM baseline harness — MERGED `93fadb8b`.** `tools/video-llm-bench/` (validate-corpus · run · summarize; qwen-bench
  run-record discipline; 45 pytest). **A0 numbers published** in `docs/reviews/video_llm_benchmarks.md` from a real run on the
  Ultra (Qwen2.5-VL-3B-4bit via mlx-vlm 0.5.0, the app's exact three prompts, 5 stills/clip, 1,506 frames, 0.91 s/frame, 3.7 GB):
  **OCR** (63 clips with a usable truth) any-frame exact 92 %, majority 90 %, year 97 %. **ERA** (248 clips): the free text names a
  year for only 18 % of clips; where it does on 1990s footage it is reading the burn-in (MAE 0.9 y); Rick-dated rows MAE 6.9 y on the
  36 % answered. That is the bar A1/A2 must beat. Corpus truths: 73 `user_dates` confirmed; **no VHS/1990s camera-dated stratum
  exists in the catalog** (the design's strata assumption was wrong — 80s/90s era truth is Rick's 54 dated rows only).
- **Two findings filed from the run:** #402 — 2,850 of 3,128 `ocrDate` caption rows are degenerate `!!!!…` output stored as captions;
  #403 — 24 iMovie QuickTime reference movies whose media is on an unmounted "InternalRaid" read as ordinary videos.
- **Model-lab Core types** (`feat/model-lab-core-types`, `4aeb28f5`, 58 tests): samplers, approach registry, fail-closed contracts,
  `EvidenceAssertion`, `PayloadGate`, `model-lab.sqlite` store. Reviewer: *merge after fixes* — R1 blocker: `.ollama` hosts were
  "local" by label (OllamaEndpoints admits https cloud hosts) → fixed by a validated `LocalHost` type; R2 NUL-truncating binds; R3–R6
  floors/inf/canonicalJSON/bare-decoder door. Worker applying; then I run the lane on the merged tree and merge.
- **Background service step 0** (`feat/background-service-step0`, `c7b7089d`, 37 Core tests, sensor lane GREEN 594): helper target
  `VideoScan Background` embedded as an `SMAppService` login item, launchd plist, XPC server + same-binary CLI, `JobSupervisor`,
  `Backoff`, `NoOpJob`, registrar off by default behind `background.service.enabled`. Reviewer: *merge after fixes 1–3* (parked
  disk-full job unresumable; CancellationError without cancellation strands a job; two START-without-OUTCOME paths) + peer trust via
  `setCodeSigningRequirement`. Worker applying; lane rerun; then merge. **Rick's spot test** (after merge, Debug build):
  `defaults write Rick-Breen.VideoScan background.service.enabled -bool true`, launch once, `launchctl print gui/$(id -u)/Rick-Breen.VideoScan.Background`,
  then `…/VideoScan.app/Contents/Library/LoginItems/VideoScan Background.app/Contents/MacOS/VideoScan Background --status` /
  `--enqueue noop 120 1000`, `tail -f ~/Library/Logs/VideoScan/background.log`, quit the app and watch it keep counting.

## Landed 10/30 (late, on main)
- **Charter reorganized** into seven sections; duplicates folded; line 148 (4 MB hash) gone (Rick ruled);
  reading lists replaced by pointers; Claude Feedback blocks: MoE-vs-rulings, duplicates need no model,
  `A7 Household Roster` for people, FT-view assistance items, background service summary, local review models.
- **Background service designed:** `docs/design/background_service_2026_10_30.md` — helper app in the bundle as an
  `SMAppService` launchd agent; never writes the catalog (sidecars + journal, app's committer applies); engines move
  not copy; XPC control, files for state; backoff; five sensors; five-step move with the app whole at every step.
- **Video-LLM design moved** to `docs/design/video_llm_lab_2026_10_30.md` (was the top-level `proposed_video_llms_for_breen_media.md`); review and
  BACKLOG repointed.
- DECISIONS: three dated lines (line 148 struck; background service shape; local review models as tooling).

## Landed 10/30 (day, pushed)
- **#401 (P0)** a scan location counts and removes only its own volume's files (`eeb50f9d`, Codex fix `b9bcc6dc`).
  Follow-up to file: 6 live rows with stale `volume_uuid` after cross-volume moves.
- **GEDCOM pull dates** (`f4984529`) under the Family Tree title; one `[family-tree] gedcom pull` log line per pull.
  Rick to spot-test in Debug: `ingest=`/`generation=` not `unknown`.
- **AI sparkle** shared view `Shared/AISparkleIcon.swift`, also on the Family Tree memories button.
- #400 filed; gauntlet manifest fixed `a8e62bb1`. Charter §Agentic Assistance (Rick, `93879392`).

## State of the machines (10/30 evening)
- **02:00 nightly 10/30 GREEN on both** (M4 app 12,577/0, Ultra 12,576/0, Core 1,962/0 each).
- **M4 = mirror test host:** catalog `.backup` of the Ultra's (schema 13, 14:26); GEDCOM copy at
  `~/Library/Application Support/VideoScan/test-host/GEDCOM`; media on the Ultra over TB5. M4 Hallie strict 56/56.
  `sync_test_host_data.sh` still to write.
- Tonight's nightly carries the GEDCOM row (pull date + short SHA per Mac; green when they match).
- SSH Ultra → M4 works. M4 deep gauntlet 5,282 / 0 but RED by runner policy (withKnownIssue counted) — Rick's call.

## Waiting on Rick
- **Rulings (new):** background service §7 (one extra FDA grant · name/icon · exit-when-idle · step order);
  video-LLM §9 (cloud on derived text · 50 place labels · Qwen or Gemma first · v14 timing).
- **Modes draft**, the `process-modes` docs branch — yes or edits.
- **Rulings (older):** strict-034; #397 help route; gauntlet runner policy; toolchain list (`tools/toolchain.json`).
- **Allowlist:** read-only ssh/status commands for unattended nights.
- **Spot tests (Debug):** GEDCOM dates + sparkle; Hallie after the refactor; Provenance ▸ Set Role and Find Master;
  Archive 144 Masters; #375 nickname; #345 no-sound mark; People row removal; arrow keys in lists; Migrate summary
  words; ⌘⌫ on a duplicate pair; #383 Tidy Catalog….

## To file
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed; 557 Thread Performance Checker traces
  (`CatalogLaunchWait.run`) — check against existing issues first.

## In flight (unchanged)
- `fix/committer-lost-writes-codex141`: parked (two writers on one catalog only).
- Swift 6 (#376): close once #381/#385 are called. Analysis lane not installed (`scripts/install_analysis_lane.sh`, M4).
- Open: #384 ledger atomicity · #389 foreign writer during open · #377 floor gap · #379 · #380 · #381 · Step G
  (JSON gone) · #338, #339 · VideoScanModel split #337 (plan → Rick's go).
- Worktrees under `VideoScan-wt/`: `attended-model-review` (Codex pilot, unmerged, dirty), `process-modes` (draft);
  the rest are landed branches to prune.
- Old remote branches with commits not in main: triage as a night task; nothing deleted.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.
- Mid-November: Rick's target of grade A in every module.
- 2026-12 (Christmas) soft / 2027-01 target: Public view link for family (BACKLOG; Charter §5 Web Interface).

## Open rulings wanted from Rick (older, still open)
1. Schema v14 (provenance assertions + veto trigger, Phase C) and Phase B picture timeline numbering.
2. Provenance gate at ingest or at Promote; hard or soft for the first month; role list; July 2026 device chain.
3. Charter: GRDB named but unverified; Triage keep / fold / cut.
4. #327 remainder; People engines; Archive Angel; two-copy edit conflict policy.
