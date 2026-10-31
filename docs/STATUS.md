# Status — rewritten, never appended

*Updated 2026-10-31 10:55 (Saturday morning, after the Fable night shift). Rick corrects this file; agents read it at session start.*

## 🔴 First: last night's nightly was RED, and a model process held the Ultra's GPU for 12 hours
- **What happened.** An A2 smoke run (Qwen3-VL-8B, 12 frames per window) wedged inside `mlx_vlm.generate` at 22:26 — 100 % GPU,
  6.5 GB, no output — and was not terminated until 10:33 this morning (the agent's `kill` of its own PID sat at a permission prompt all
  night). It held the GPU through the 02:00 nightly. Filed **#406** (per-generation timeout + run deadline for `bench.py`; the same
  watchdog shape the background service's model lane will need).
- **Nightly 20261031_020005 (Ultra, main `30e41529`): status failed.** App 12,645 / 0 failed. **Core 2,133 / 1 failed** — my new
  `JobSupervisorTests` pause/resume test raced the supervisor (100 ms unit vs. actor hops under load; the supervisor is right).
  **Fixed this morning**: the lane is now held inside a unit by a gate the test owns (`fix/jobsupervisor-pause-race`, `6891a20c`;
  Debug 20/20, Release 20/20, 8 repeats 0 fails; sensor lane running at write time, merge follows). **Hallie replay failed:** strict
  52 / 56 (53 / 56 the night before — the 3–4 strict fails predate tonight; route_mismatch ×4) and **advisory collapsed to 145 / 826
  (817 the night before), median latency 42 s, lane hit its 3600 s cap** — consistent with the wedged process starving Ollama on the same
  GPU; circumstantial, not proven. Voice OK (similarity 1.000). Expect tomorrow's nightly to be the real reading.
- **GPU is free now.** No model or build process of mine is running on the Ultra. The 32B weight download stalled at 23:04 (10 of
  19.6 GB on disk, two `.incomplete` shards) and was stopped; `snapshot_download` resumes from the partial blobs when rerun.

## Video-LLM lab — where it stands (`docs/reviews/video_llm_benchmarks.md`, `tools/video-llm-bench/README.md`)
- **A0 baseline (3B, stills) — published.** OCR any-frame exact 92 %; ERA names a year for 18 % of clips; Rick-dated MAE 6.9 y on the 36 % answered.
- **A1 (3B, windows + strict JSON contracts) — published, merged `fa70aec0`.** ERA answered 18 % → 98 % but MAE where it answers did not
  improve (Rick-dated 5.9 y, inside-range 81 %; 2020s phone clips MAE 36 y). Windows cost OCR 4–6 points → one engine, two samplers.
- **A2 (Qwen3-VL-8B-4bit) — code merged `ad682964`, full run NOT done.** Code: same windows/contracts for ERA, A0's five stills for OCR,
  an approach registry, run record carries both sampler ids (19 pytest, 137 bench tests green). Smoke on 3 Rick-dated clips: the 8B model
  loads in venv-mlx as is (mlx-vlm 0.5.0), schema-valid 18/18 at N=4, 17/18 at N=6 and N=8, **0/5 at N=12 and it wedges** (#406).
  Rule picks **N=8**; N=6 would isolate the model as the only change — Rick's call, default N=8. Estimate 70–100 min for 327 clips.
  **Run it in the next away window, with a wall clock on it:**
  `nice -n 15 /Users/rickb/dev/VideoScan/venv-mlx/bin/python3 tools/video-llm-bench/bench.py run --approach a2-py --frames 8 --manifest <worktree>/.scratch/bench/manifest.json --model-dir ~/.cache/huggingface/hub/models--mlx-community--Qwen3-VL-8B-Instruct-4bit/snapshots/defcdea7cc7a4b0858fea563cbbce171d328e457 --out <worktree>/.scratch/bench/runs/full-a2-py-r3-n8`
  then `summarize` with the A0 (`20261030T201824-a0-py`) and A1 (`full-a1-py-r3-n6`) runs under `VideoScan-wt/bench-a1/.scratch/bench/runs/`.
  The watchdog (#406) should land first so a second wedge cannot take another night.
- **32B:** weights half-downloaded; worth one run on the 72 Rick-dated clips only (the single stratum with era truth) after A2 reads.
- **Household Roster (A7) feasibility — published `2cb31fa5`** (`docs/reviews/household_roster_feasibility.md`): sex + age band alone
  is unambiguous for 42 % of tags on Rick-dated files; every tie is same-sex, same-generation, 1–3 years apart → A7 is a *filter*, not a
  namer; the tie-breaker must be identity-bearing. Truth set is 41 files; camera stamps agree with Rick's year 1 time in 4.

## Landed on main last night (all pushed; checkout clean; lane GREEN 596 on `85fe3140`)
- **Background service step 0** `dfafcc98` + reviewer fixes `5c9686d8`: helper target `VideoScan Background` (SMAppService login item,
  launchd plist, XPC with `setCodeSigningRequirement`, same-binary CLI), Core `Background/` (supervisor, backoff, idle-exit policy,
  file-backed queue/checkpoints, `JobResourceProfile`, peer trust), registrar **off by default** behind `background.service.enabled`.
  45 Core tests + sensors. **Rick's spot test (Debug build):**
  `defaults write Rick-Breen.VideoScan background.service.enabled -bool true` → launch the app once →
  `launchctl print gui/$(id -u)/Rick-Breen.VideoScan.Background` →
  `"…/VideoScan.app/Contents/Library/LoginItems/VideoScan Background.app/Contents/MacOS/VideoScan Background" --status` and
  `--enqueue noop 120 1000` → `tail -f ~/Library/Logs/VideoScan/background.log` → quit the app and watch it keep counting.
- **Model-lab Core types** `2a2c3c5f` (73 tests): samplers, approach registry, fail-closed contracts, `EvidenceAssertion`,
  `model-lab.sqlite` store, `LocalHost` validated type.
- **#402 part A + readers** `85fe3140` (25 Core + 195 app tests): `CaptionTextQuality` verdict refuses degenerate captioner output
  (`!!!!`, `1111111111`, `hahahaha…`, periodic loops) at the three write routes; every OCR-date reader uses `usableOCRDates`; propagation
  and carry-over no longer spread junk; Catalog Status shows "N degenerate OCR captions stored before this build refused them".
  **Behaviour change to spot-test:** junk no longer counts as date evidence (expect some rows to lose a phantom OCR date). The supersede
  pass over the 2,850 stored rows is a separate brief (#402 comment 2).
- Guards: catalog-naming guard green `b6fe2b2a`; `model-lab.sqlite` classified in the App Support inventory; Xcode's pbxproj
  normalization committed `1acaef99` so builds stop dirtying the checkout. Filed #403 (iMovie reference movies on an unmounted
  "InternalRaid" shown as videos), #404 (docs-links guard: six test headers cite retired review docs), #406 (above).

## Waiting on Rick
- **Rulings (new):** background service design §7 — item 1 (one extra FDA grant) agreed; **2** name/icon badge, **3** exit-when-idle
  default, **4** step order. Video-LLM design §9 — cloud on derived text · 50 place labels · Qwen vs Gemma first · v14 timing.
  A2 frame count N=8 (rule) vs N=6 (A1's N).
- **Terminal run** of Codex's attended review pilot (`VideoScan-wt/attended-model-review`, `tools/model-fitness/attended_review.py --execute`);
  the agent sandbox cannot reach Ollama. This is the "local model as overnight code reviewer" idea — pursue after the pilot's grades.
- **Modes draft**, the `process-modes` docs branch — yes or edits.
- **Rulings (older):** strict-034; #397 help route; gauntlet runner policy; toolchain list (`tools/toolchain.json`).
- **Allowlist:** read-only ssh/status commands for unattended nights; a `kill <own pid>` shape for agents' own model processes (last
  night's prompt is why the GPU stayed held).
- **Spot tests (Debug):** background helper (above); #402 behaviour change; GEDCOM dates + sparkle; Hallie after the refactor;
  Provenance ▸ Set Role and Find Master; Archive 144 Masters; #375 nickname; #345 no-sound mark; People row removal; arrow keys in
  lists; Migrate summary words; ⌘⌫ on a duplicate pair; #383 Tidy Catalog….

## Next (when Rick says go)
1. #406 watchdog in `bench.py`, then the A2 full run (away window), then the 32B on the Rick-dated stratum.
2. Background service step 1 (first real job moves into the helper; design §5 order pending ruling 4).
3. #402 supersede pass brief → Codex.
4. `AudioCatalogIndexScaleTests` sits at its 15 s budget on the Ultra under load — file it before it flakes a nightly.

## State of the machines (10/31 morning)
- Ultra: GPU free; no agent builds running except the pre-merge sensor lane for the pause-race fix (short).
- M4 = mirror test host (catalog `.backup` of the Ultra's, schema 13; GEDCOM copy under `test-host/`). `sync_test_host_data.sh` still to write.
- Worktrees under `VideoScan-wt/` are all landed branches except `attended-model-review` (Codex pilot, dirty) and `process-modes`
  (draft); `bg-service-0` carries the pause-race fix until merged. Nothing deleted; prune is Rick's call.

## To file
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed; 557 Thread Performance Checker traces (`CatalogLaunchWait.run`);
  Hallie strict route_mismatch ×4 (two nights running) — check against existing issues first.

## In flight (unchanged)
- `fix/committer-lost-writes-codex141`: parked (two writers on one catalog only).
- Swift 6 (#376): close once #381/#385 are called. Analysis lane not installed (`scripts/install_analysis_lane.sh`, M4).
- Open: #384 ledger atomicity · #389 foreign writer during open · #377 floor gap · #379 · #380 · #381 · Step G (JSON gone) · #338,
  #339 · VideoScanModel split #337 (plan → Rick's go).
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
