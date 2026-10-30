# Status — rewritten, never appended

*Updated 2026-10-30 (evening, before session restart). Rick corrects this file; agents read it at session start.*

## Next session
**Deep Design with Fable: video LLM / "Breen media expert".** Mode: Rapid Dev + Deep Design. Read in order: `docs/reviews/video_llm_design.md` → `docs/proposed_video_llms_for_breen_media.md` → `docs/research/video_llm_for_family_media_2026-10-29.md` → `~/Downloads/video_intelligence_architecture.pdf` (not in repo yet). Settle first: the model lab and Content Analysis share **one engine**, hosted by a **background service** (runs after quit, one supervisor, visible/stoppable with the app closed, journals only, own name and icon in Activity Monitor, backs off while Rick works, no extra permission grants). Phase 0 = baseline the existing 3B captioner against held answers (no schema, no rulings). Also in scope: Provenance Grade #396; the Family Tree AI helper (BACKLOG). Privacy rule 13 holds: no living family pixels/audio to a cloud model. Main is pushed; push after each merge.

## State of the machines (10/30 evening)
- **02:00 nightly 10/30 GREEN on both** (M4 app 12,577/0, Ultra 12,576/0, Core 1,962/0 each).
- **M4 = mirror test host:** catalog `.backup` of the Ultra's (schema 13, 14:26); GEDCOM copy at `~/Library/Application Support/VideoScan/test-host/GEDCOM`; media stays on the Ultra (over TB5). **M4 Hallie strict 56/56** with that copy (`ebf34dce`, `--gedcom`). The copies are snapshots: a `sync_test_host_data.sh` is still to write.
- **Tonight's nightly** carries the new GEDCOM row: each Mac's pulls (date + short SHA) on the metrics page, green when they match, yellow when not. Over SSH both Macs hash the pulls the same (11151ff3, e83bed92). Surnames are kept off the public page (repo is PUBLIC).
- SSH Ultra → M4 works (key re-added 10/30 14:23). M4 deep gauntlet 5,282 / 0 but RED by runner policy (withKnownIssue counted as failures; BLOCKED stages) — Rick's call.

## Landed 10/30 (on main, pushed)
- **#401 (P0)** a scan location counts and removes only its own volume's files (`eeb50f9d`, Codex fix `b9bcc6dc` → merge/0). Follow-up to file: 6 live rows with stale `volume_uuid` after cross-volume moves.
- **GEDCOM pull dates** (`f4984529`): "Breen GEDCOM 26 Aug 2026 / Hudson GEDCOM 28 Aug 2026" under the Family Tree title (labels from each pull's first person, dates from its header, matched by SHA-256 to the compiled manifest; ingest date in the tooltip); one `[family-tree] gedcom pull` log line per pull per load. Rick to spot-test in Debug: confirm `ingest=`/`generation=` are not `unknown` (shared-cache path not covered by a test).
- **AI sparkle** shared view `Shared/AISparkleIcon.swift` (Hallie's gradient/twinkle/glow), now also on the Family Tree memories button.
- #400 filed (hooks miss new tests in existing files); gauntlet manifest fixed `a8e62bb1`.
- Hallie grade C→B, baselines (`docs/reviews/hallie_benchmarks.md`), live replay viewer, Find Tag daemon off (#395) — 10/29.

## Waiting on Rick
- **Uncommitted:** `docs/Purpose-and-Charter.md` in Rick's checkout (his edit, 17:09 10/30).
- **Modes draft**, branch `docs/process-modes` — yes or edits.
- **Rulings:** strict-034; #397 help route; gauntlet runner policy; toolchain list (`tools/toolchain.json`, Xcode 27.1 vs 27.0, Ollama brew vs app); Charter line 148 (4 MB hash vs rule 6).
- **Allowlist:** read-only ssh/status commands for unattended nights.
- **Spot tests (Debug):** GEDCOM dates + sparkle; Hallie after the refactor; Provenance ▸ Set Role and Find Master; Archive 144 Masters; #375 nickname; #345 no-sound mark; People row removal; arrow keys in lists; Migrate summary words; ⌘⌫ on a duplicate pair; #383 Tidy Catalog….

## To file
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed (interaction ~200, question_testbed 67, live_misses ~45, acceptance ~25); 557 Thread Performance Checker traces (`CatalogLaunchWait.run`) — check against existing issues first.

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
