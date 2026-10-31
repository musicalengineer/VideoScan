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
command in that worktree's `docs/models_research/README.md`, not on main); the agent sandbox cannot reach Ollama.

## Landed 10/30 (late, on main)
- **Charter reorganized** into seven sections; duplicates folded; line 148 (4 MB hash) gone (Rick ruled);
  reading lists replaced by pointers; Claude Feedback blocks: MoE-vs-rulings, duplicates need no model,
  `A7 Household Roster` for people, FT-view assistance items, background service summary, local review models.
- **Background service designed:** `docs/design/background_service_2026_10_30.md` — helper app in the bundle as an
  `SMAppService` launchd agent; never writes the catalog (sidecars + journal, app's committer applies); engines move
  not copy; XPC control, files for state; backoff; five sensors; five-step move with the app whole at every step.
- **Video-LLM design moved** to `docs/design/video_llm_lab_2026_10_30.md` (was `docs/proposed_…`); review and
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
- **Modes draft**, branch `docs/process-modes` — yes or edits.
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
