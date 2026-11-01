# Status — rewritten, never appended

*Updated 2026-11-01 (Sunday morning edition, written overnight 10/31). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
1. **Nothing was deleted overnight.** The cleanup proposal is `docs/design/cleanup_proposal_2026_10_31.md` (≈ 118 GB reclaimable if every DELETE is accepted; you rule, then `.trash/` first).
2. **Docs were reorganized**: `docs/README.md` is now the one entry point; `docs/design/models.md` is THE list of models (what, where, why, status); seven model/LLM research and review docs moved to `docs/archive/` with one-line stubs; `docs/design/data_organization_2026_10_31.md` is your file-locations map, filled in (your text kept, generated tables between markers), with the two-page diagram at `docs/design/data_organization_2026_10_31.html` and the PDF in `~/Downloads`. "Rick to rule" docs are listed in BACKLOG.
3. **The background service runs its first real job.** Step 1 (the 8B era/OCR job, schema v14, the journal and the applier, the inspector and Status lines, era words in search) merged 11/01 (`0656aee6`); 320 files analyzed in Rick's lunch window; first convergence reading 51 % close enough, 88 % inside the range. The helper is still started by hand (`--run era` / `--enqueue era`); no Settings toggle or Analyze-tab button yet (BACKLOG).
4. **Verdicts from the day:** seat the 8B as the era/OCR expert; the 32B is parked (worse on all 72 Rick-dated clips at 4.7× the cost); the model stays a pixels-only witness and the file's facts enter as deterministic bounds (telling it the codec moved a 1965 film to 1975–1985); "close enough" = midpoint within 5 y AND range ≤ 10 y wide; your 25 dates all stood in the review.

## Testbeds overnight (all against main unless said)
| Lane | Result |
|---|---|
| M4 Release gauntlet #1, `fc620035` | 5,494 passed · 0 failed · 7 known issues; runner stamps FAILED by policy (known issues count; phase-1 subsets "blocked") |
| M4 Release gauntlet #2, `ae3acedc` | 5,504 passed · 0 failed · 7 known issues; same stamp |
| Ultra Release gauntlet, `937de636` | **5,504 passed · 0 failed · 7 known issues** in 1,512 s — identical to the M4's, same policy stamp (first attempt refused to start: manifest inventory mismatch after the Codex-P2 test — resynced `937de636`); off the Ultra by 22:06 |
| Codex review of the day's Swift (`30e41529..d3d46db0`) | verdict **merge**, one P2 (the reference-only timing wrapper swallowed a hang off the pinned run) — **fixed red-first** `33a41214`, cycle closed; `docs/reviews/codex/codex-review-day-2026-10-31.md` |
| 02:00 nightly, both Macs, `4fc66b94` | **App 12,654 / 0** on both. **Core 2,135 / 1** on both — the one failure was the Codex-P2 test from 10/31 reading `VIDEOSCAN_TIMING_STRICT` from the process (the nightly pins it; a 1.5× miss IS a failure there, by design) — **fixed red-first `99fe0a04`** (environment injected into `judgeNow` and both wrapper copies; the test pins it both ways). **Hallie strict: M4 56 / 56 green; Ultra 54 / 56** (strict-033/034, the "how many from the 90s / 80s" follow-ups — right count, llama phrasing missed the regex; model flake, not code). **Advisory: M4 645 / 826, Ultra 627 / 826** — the first clean reading since the GPU hang. Voice ok on both. Ladders published. |

## Spot tests for Rick (Debug)
- **Catalog ▸ Show ▸ "Confirmed Date"**: the Showing box reads "… · Confirmed date · …" and every row's inspector says "Saved: … — you're sure / best guess". (Open: should the chip show its count? needs a debounced model-owned cache.)
- **Background helper (step 0)**: `defaults write Rick-Breen.VideoScan background.service.enabled -bool true` → launch once → `launchctl print gui/$(id -u)/Rick-Breen.VideoScan.Background` → helper `--status`, `--enqueue noop 120 1000` → `tail -f ~/Library/Logs/VideoScan/background.log` → quit the app, it keeps counting. Allow the login-item notification.
- **#402**: Catalog Status shows "N degenerate OCR captions stored before this build refused them"; junk no longer counts as date evidence.
- **Review page** (outside the app): `venv/bin/python3 tools/video-llm-bench/bench.py watch --run <bench-a2>/.scratch/bench/runs/review-a2-rickdated-25 --manifest <bench-a2>/.scratch/bench/manifest.json --port 8765 --open` — your 25 verdicts are in `verdicts.jsonl` beside the run.
- Older: GEDCOM dates + sparkle; Hallie after the refactor; Provenance ▸ Set Role and Find Master; Archive 144 Masters; #375; #345; People row removal; arrow keys; Migrate words; ⌘⌫ on a duplicate pair; #383.

## Landed 10/31 (all pushed; main `937de636` + this file)
- **Stability**: timing budgets strict only where the lane pins them (DECISIONS 2026-10-31; closes #407); the nightly card names every lane and counts Core failures; **lane ladders** on the dashboard (one per Mac, one rung per lane); the JobSupervisor pause/resume race test made deterministic; PROCESS §8: **the M4 is the default testbed**, the Ultra only in a declared window, "On the M4?" is fine.
- **Catalog ▸ Show ▸ Confirmed Date** (38 tests on five dimensions; the Show filters became a predicate table, CCN 27 → 18).
- **Video-LLM lab**: #406 watchdog (model in a worker process, per-generation cap, run deadline); **the mlx-vlm 0.5.0 prefill bug** (prompts over 2048 tokens chunked, the tail chunk dies in Metal — ten crashes; last night's N=12 collapse) fixed with one prefill step; **A2 published** (8B: Rick-dated MAE 3.6 y, inside-range 86 %, OCR 95 %, 7.0 s/clip); **A3 published** (32B, parked); `--context technical` / `picture` variants (the codec anchors the model; picture facts do no harm and little good); **the review page** (`watch`, `--keep-frames`; one binary question about Rick's date; the model's grade as a computed badge; stamp fusion collapses a padded range to a cited on-screen year — 7 of 25); lab design §11 evidence inventory.
- **Design**: background service §0.6 (goal in Rick's words, calibrated claims not percentiles, inputs, outputs, forensics read for bulk, step 1 as agreed) and §0.7 (**observations** is the name; the three homes; priorities 1960–2010 oldest first; people facts as constraints; the caching rule). Rulings given in conversation, to be written up with the step 1 brief: 8B era job first, captions second (on the 8B, uncaptioned first then backfill), **v14 lands with step 1**.
- **Household Roster (A7)** feasibility published; **evidence tests checked**: ExifTool dates first; DV datecode real (MediaInfo finds a date on 5 of 51 DV clips; the 1990s raw `.dv` captures need `dvrescue`, **Brewfile entry = Rick's install**); ENF dropped; PRNU grouping-only.
- Issues: #406 (fixed), #407 (fixed), #408 gauntlet UI flows (5 of 17 stale against today's UI), #403, #404.

## Background step 1 — MERGED 11/01 (`0656aee6`; branches `feat/bg-step1-era` + `feat/bg-step1-ui`)
- **Schema v14** `v9_provenance_assertions` (approved by Rick 11/01): the next launch of ANY build migrates the live catalog (additive; the app keeps its pre-migrate copies as on 10/27). The observation journal, `JournalApplier` (commit door; Codex #187: 3 P1 + 7 P2 fixed red-first), Python `ClipService` on the A2 code path, `PythonClipWorker` (watchdog), `EraJob` (oldest first, cached digests skipped, one `era.fused` line per file), `--enqueue era` / `--run era`. UI: inspector "Machine era: 1991–1995 · 8B, unconfirmed" under Saved; Catalog Status "Machine era agrees with your confirmed date within 5 y: N of M (p %)" beside "Background: N journal lines waiting · M refused"; search words "1990s" / "90s" / "early 90s" per era record (technical forms never indexed).
- **Proof:** sensors GREEN 599; M4 full Core suite on the branch, Release, serial: **1,975 / 0** (16 known issues); app suites touched 318 + 256; pytest 182 (bench) — the three Python reds on main are pre-existing (below). Live smoke: 2 clips, 3.4 s/clip, 6.6 GB resident, 4 assertions.
- **Not in step 1 (by design or deferred):** the DV camcorder-clock conflict wording ("re-recorded film") — nothing in the catalog stores the DV datecode yet (Phase D reader); Hallie's "from the 90s" uses date fields, not eras — needs a `machineEra` evidence basis cited as "the 8B's era guess, unconfirmed" (BACKLOG); no app button to start the job (BACKLOG).
- **First corpus runs, Rick's lunch window 11/01 (Ultra, the 8B, oldest first):** batch 1 120 files · 438 assertions · 12.0 s/clip · 2 windows refused by the contract; batch 2 120 · 442 · 8.2 s/clip · 5 refused; 0 failed, 0 timeouts, worker 6.7 GB. The open app applied the journal on its own (`[background-journal] OUTCOME applied … 0 refused`). **First convergence reading (34 files with both Rick's date and a machine era): Rick's year inside the range 30 (88 %) · midpoint within 5 y 28 (82 %) · "close enough" (midpoint ≤ 5 AND width ≤ 10) 15 (44 %)** — the Status line shows the strict one; 15 of 34 ranges are 15 y wide ("1960–1975" for a 1965 film): prompt r4 (narrowest range the evidence supports) is the fix, next after today's jobs. Run logs: `~/dev/VideoScan-dd/era-run/run-lunch*.log`; the helper used: the Debug build in `VideoScan-dd/bg-step1`.
- **The rest of the corpus (≈ 4,600 contents) runs in Rick's windows** (the media is local to the Ultra; the M4 has neither the volumes nor the 8B); resumable, cached digests skipped.
- (superseded) The corpus run waits for Rick's Ultra window (the media is local to the Ultra; the M4 has neither the volumes nor the 8B). Resumable; oldest first; `--run era limit N` on a `.backup` copy; the journal applies to the live catalog at the next app launch.

## Next
1. Corpus era run on the Ultra in Rick's window → first convergence reading → Rick's spot test (inspector line, Status line, search "90s", Hallie). DV date review page serving on 8767 (`tools/date-review/date_review.py`); verdicts in `VideoScan-wt/dv-date-review/.scratch/date-review/dv-25/verdicts.jsonl`. (after the v14 migration is on the branch); merge after Rick's DDL word and the Codex pass; M4 corpus run; first convergence reading.
2. **DV datecode measured** (`scripts/dv_datecode.py`, merged 11/01): 707 DV contents, **297 carry a recording date in the frames** (raw DV 262 of 348 = 75 %); on 231 the recording is earlier than the file's own date (137 by 14+ years) — the transfer-versus-content number. Next: ExifTool date tabulation over the corpus; pulldown detector; the DV date as a deterministic bound (Phase D) once Rick rules how it ranks against the embedded date.
3. Prompt r4 (a legible stamp = one year; narrowest range the evidence supports) on clips HELD OUT of the corpus.
4. #408: repoint the five gauntlet UI flows; turn the runner's UI stage on for the away window.
5. Cleanup execution after Rick's ruling on the proposal; the "Rick to rule" docs list (BACKLOG).

## Waiting on Rick
- **Catalog menu**: the proposed regrouping and the rename "Update Catalog…" → "Relink Moved Files…" (proposed 11/01 afternoon; the Catalog Database Info sheet is being built either way).
- **Rulings still open**: background service §7 items 2 (icon badge) and 3 (exit-when-idle default) — defaults proposed; video-LLM §9 items 1 (cloud on derived text) and 2 (the 50 place labels). Gauntlet runner policy (known issues as failures). CatalogSync `defaultMasterHostname` still `RicksM4.local` in code while the Ultra is the master by ruling (DECISIONS 2026-10-27) — fix the default.
- **Codex docs review 11/01** (`docs/reviews/codex/codex-review-docs-new-engineer-2026-11-01.md`): verdict fix, 23 findings; a worker applies the docs-only ones; two touch Rick's files — PROCESS "Escalate before" (F22: "non-additive schema changes" contradicts CLAUDE rule 6) and the Charter's "Claude Feedback" sections (F15: replace repeated explanation with links) — proposed as diffs for Rick.
- **Terminal run** of Codex's attended review pilot (`VideoScan-wt/attended-model-review`).

## State of the machines (11/01 morning)
- Ultra: free; the two review pages may still be serving on 8765/8766 (harmless `watch` processes). M4: idle after two gauntlets (`RicksM4.local`, main pulled).
- Worktrees under `VideoScan-wt/`: all landed except `attended-model-review` (Codex pilot, dirty) and `process-modes` (draft); `bench-a2/.scratch/` holds the bench runs and Rick's verdicts (KEEP). Prune per the cleanup proposal, after Rick's word.

## To file
- Era job re-analyzes a file that produced no `era.fused` line (12 of batch 1 were not "cached" in batch 2's plan — every window refused or empty); the caching rule (§0.7) says a digest the signer has seen is never recomputed: the plan should treat any journal/catalog row by that signer as seen, and a file with zero valid windows should get a `era.none` observation so it is not retried every run.
- Three Python tests red on main, pre-existing (11/01): `test_codeql_extraction_floor::test_sensor_real_repo_scope_is_app_plus_core`, `test_docs_links::test_tracked_docs_references_exist` (#404), `test_gauntlet_runner::test_poisoned_home_and_roots_replaced_in_child_and_xctestrun`.
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed; 557 Thread Performance Checker traces; Hallie strict route_mismatch ×4 two nights running; `findtag-journal/` unbounded; `previewSweepEnabled` stale key; `MediaPersonLinks.swift` uncalled.

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
