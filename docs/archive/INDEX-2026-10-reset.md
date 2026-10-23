# Retired on 2026-10-23 (context reset)

Every file below was removed from the tree in commit `chore/context-reset`. The archive of record is git: `git show pre-reset-2026-10-23:<path>` prints any of them, `git log --follow -- <path>` their history. A convenience copy of all of them sits in `docs/archive/retired-2026-10-reset.zip` (gitignored; also under `.trash/retired-2026-10-reset/`). The same list, machine-readable, is `docs/archive/RETIRED.txt`; the docs link checker accepts citations of these paths so code comments keep their references.

A file comes back only if its topic becomes live again AND the eight living docs cannot hold it. Rulings from these documents are in `docs/DECISIONS.md`; live ideas in `docs/BACKLOG.md`.

## Non-review documents (102)

- `archive/2026-Q2/Ideas.md` — April ideas; everything moved to GitHub
- `archive/2026-Q2/gh_issue_61874_safety_critical_mode.md` — already archived
- `archive/2026-Q2/issue-01-mp4-compilation-fix.md` — already archived
- `archive/2026-Q2/refactor-view-extraction.md` — already archived
- `archive/2026-Q3/qwen_metrics_2026_08_27.md` — Aug Hallie planning benchmark; paused
- `briefs/back_on_our_feet_2026_10_16.md` — dated plan; integrity_first + retrospective supersede
- `briefs/cloud-credit-review-program-2026-10-05.md` — program context; credits expire 11/05 — ledger kept in reviews/cloud/LEDGER.md
- `briefs/cloud/C01-steward-and-device-id.md` — executed; report in reviews/cloud
- `briefs/cloud/C02-archive-promote-recovery.md` — executed; findings → GH #286
- `briefs/cloud/C03-python-run-and-review.md` — never run; Python writers since retired
- `briefs/cloud/C04-sensors-that-cannot-fail.md` — executed; findings → GH #287
- `briefs/cloud/C05-delete-excess-design-review.md` — executed; design since superseded
- `briefs/cloud/C06-switch-to-types.md` — executed; census in reviews/census
- `briefs/cloud/C07-angel-floors-plan.md` — never run; Angel fate open (Q8)
- `briefs/cloud/C08-av-sync-check-prototype.md` — executed; GH #309 tracks
- `briefs/cloud/CONTRACT_FREEZE.md` — step B done
- `briefs/cloud/CONTRACT_FREEZE_R2.md` — step B done
- `briefs/cloud/CONTRACT_FREEZE_R3.md` — step B done
- `briefs/cloud/CUTOVER_REGRESSION.md` — suite written and proven
- `briefs/cloud/IMPORT_PURE_PIECES.md` — merged cb62c6c37
- `briefs/cloud/P0_REGRESSION_SUITE.md` — suite on main; run sheet kept in reviews
- `briefs/cutover_morning_2026_10_18.md` — cutover done 10/18; its decisions go to the log
- `briefs/local/R1-catalog-row-context-menu.md` — executed night brief
- `design/adaface-plugin.md` — recognition-engine design; machinery frozen (Q9)
- `design/agent_dashboard.md` — July sketch on the retired Engineering Room
- `design/analysis_ledger_design.md` — July directive; lives on in cyclers/freshness stamps
- `design/archive_angel_consolidation_plan.md` — Sept plan; Angel fate open (Q8)
- `design/archive_angel_curation_direction.md` — Sept direction; Angel fate open (Q8)
- `design/archive_angel_recommendation_problem.md` — problem statement answered by wise_design
- `design/archive_angel_wise_design.md` — stages 1–3 built; rest pending Q8
- `design/catalog_window_architecture_2026_10_06.md` — VSplit focus plan executed (reviews/local/catalog-focus-vsplit)
- `design/catalog_write_safety_design.md` — JSON generation guard; superseded by SQLite commit door
- `design/delete_excess_copies_2026_10_06.md` — superseded by cleanup_kiss + pruneplan_simple
- `design/events_v1_plan_2026_10_14.md` — v1 built 10/14; events_design holds authority
- `design/family-tagging-and-search-roadmap.md` — June roadmap; built or superseded
- `design/family_map_design_2026-09-29.md` — GH #227 built; stages 3–4 to backlog
- `design/find_original_design.md` — Phase 1 built; related_score/folders supersede
- `design/footage_groups_gap_plan_2026-09-26.md` — Sept gap plan; landed or superseded
- `design/footage_spectrum_design_2026-10-03.md` — Compare Footage built; folds into Compare Media
- `design/gauntlet-design-codex-2026-09-27.md` — proposal; guides/gauntlet.md is the guide
- `design/hallie_agent_lane_2026_10_10.md` — PROPOSED; Hallie paused 10/16 (Q7)
- `design/hallie_compound_and_filter_queries_2026_10_09.md` — design; Hallie paused
- `design/hallie_e1_experiment.md` — harness spec; Hallie paused
- `design/hallie_improvement_and_refactor_2026_09_13.md` — Sept plan; done or superseded
- `design/hallie_proposer_with_tools_design.md` — rev 6; Phase 0 never built; paused
- `design/hallie_response_commit_refactor_2026_09_13.md` — merged 9/15 handoff
- `design/hallie_two_mode_design.md` — implemented Sept; hallie.md covers it
- `design/ios_port.md` — exploratory, low priority (#42 parked)
- `design/issue-05-auto-wake-volumes.md` — old proposal; #169 umbrella tracks it
- `design/offline_family_tree_cache.md` — built Sept (tree-cache lifecycle review)
- `design/overnight_review_plan_2026_09_12.md` — dated codex handoff
- `design/people_uuid_folders_design.md` — migration done 9/13
- `design/perceptual_compare.md` — June branch notes; Compare engine merged
- `design/relocate_volume_plan.md` — May plan; Relocate/Retire built
- `design/remote_use_design.md` — Aug proposal; viewer mode unused; family-viewer question open
- `design/scene_captions_plan.md` — May plan; captions built
- `design/tree_ingest_compile_plan_2026_08_28.md` — ingest/compile built Aug
- `design/triage_delete_streamline_2026_10_09.md` — superseded by cleanup_kiss + one_removal_marker
- `design/vs_app_gets_gedcom_data_using_own_script.md` — Aug decision landed; gedcom.md covers
- `design/web_interface.md` — not implemented; Hallie/web paused (#244 parked)
- `guides/architecture-overview.md` — April; retrospective says retire it
- `guides/compilation-bucketing.md` — April; clip compilation deferred to a Create window
- `guides/compute-assignments.md` — May fleet map; pre-M4/M5, stale
- `guides/database_design.md` — self-declared superseded by SQLite; carry POI/bundle/runbook into the new schema doc
- `guides/development.md` — Sept pointer page citing retired Engineering Room; fold into Process doc
- `guides/documentation-map.md` — Sept-16 reorg record; recovery pointers stay in git
- `guides/hallie-local-neural-voice.md` — Kokoro install; voice sub-product fate open (Q7)
- `guides/hallie_live_failures.md` — 72 KB miss ledger; harvested into eval corpus; paused
- `guides/import_export.md` — April bundle strategy; pre-SQLite (bundle needs catalog.sqlite)
- `guides/settings-apple-menu.md` — April shipped note
- `hallie_testbed.jsonl` — Aug-18 testbed snapshot; Hallie paused 10/16
- `history.jsonl` — April metrics relic; live metrics are on the `metrics` branch
- `ops/analysis/stage0-codeql-triage-2026-09-29.md` — dated triage
- `ops/analysis/stage0-static-triage-2026-09-29.md` — dated triage
- `ops/archive_angel_benchmark.md` — opt-in benchmark notes; Angel Q8
- `ops/codex_restart_handoff_2026_09_13.md` — dated handoff
- `ops/findings_2026_09_14_overnight.md` — dated findings
- `ops/incident_2026_09_14_sandbox_rename_wedge.md` — P0 fixed; lesson lives in playbook/invariants
- `ops/mac-hw-inventory-2026-08-21.md` — M4 port map; M5 Ultra arriving
- `ops/metrics/periphery_2026_09_22.md` — 200 KB dump; dead_code_survey 10/11 is newer
- `ops/metrics/strict_concurrency_survey_2026_09_22.md` — dated survey
- `ops/metrics/tsan_run_2026_09_22.md` — dated run
- `ops/morning_brief_2026-09-08.md` — dated brief
- `ops/morning_brief_2026-09-09.md` — dated brief
- `ops/morning_brief_2026-09-11.md` — dated brief
- `ops/morning_brief_2026-09-26.md` — dated brief
- `ops/morning_brief_2026-09-27.md` — dated brief
- `ops/morning_brief_2026-10-02.md` — dated brief
- `ops/people_photo_rename_fix_2026_09_12.md` — fix note; UUID folders superseded it
- `ops/perf/search_profile_2026-07-20.md` — July profile
- `ops/recovery-2026-09-28.md` — incident note
- `practices/overnight_themes.md` — Sept protocol + theme log; fold night protocol into Process doc
- `practices/software_dev_policy.md` — folded into docs/PROCESS.md (one process doc)
- `research/Media_Analyzer.md` — face-recognition research; direction abandoned
- `research/README.md` — stale reading map; fold its four rules into the new index
- `research/footage_tech_survey_2026-09-26.md` — fed the audio-fingerprint decision; done
- `research/irish_genealogy_integration_2026-09-29.md` — superseded by irish_records_design
- `research/pronunciation_training_research.md` — Hallie voice; paused
- `research/sota_research_2026-07-17.md` — July survey; dated
- `research/storage_raid_recommendations.md` — Aug purchase decision made
- `team-operations/rick-availability.local.md` — machines/hours folded into docs/PROCESS.md §8; Engineering Room retired

## Reviews (233)

Dated records of codex passes, briefs, cloud runs, QA audits and nightly reviews. Findings were closed red-first or filed as GH issues when they were made; the record is history. Kept in place under `docs/reviews/`: the P0 truth-regression run sheet, the tab-charter audit, the reading guide (best vs worst module), the cutover acceptance audit, the latest adversarial open-findings list, the GH issue triage, the NDSA self-score, the dead-code survey, the live cloud-credit ledger (to 2026-11-05) and `BRIEF_TEMPLATE.md`.

## Agent configuration (in the zip under their original paths)

The Manager protocol (`.claude/MANAGER.md`), the eight subagent definitions, the three slash commands, the Codex agent TOMLs, the morning digest hook, `codex_focus.md`, `ricksnotes.txt`, `scripts/verify-claude-setup.sh`, and copies of the pre-reset `CLAUDE.md`, `AGENTS.md` and `.claude/settings.json`. Replaced by one `CLAUDE.md`, two agents (`reviewer`, `worker`) and `.claude/scripts/session_start.sh`.

## Tests retired with the morning hook

- `tests/test_local_review_morning_line.py`, `tests/test_adversarial_morning_line.py` — pinned the line formats of `.claude/scripts/session_morning_hook.sh`, which `session_start.sh` replaced; a test for the new script is on the backlog.
