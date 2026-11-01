# VideoScan documentation — start here

One entry point. Five documents say what the project is and how it moves; everything else is a reference you open when a task needs it. Retired documents are under `archive/`, never deleted.

## Read in this order

| # | File | Why |
|---|---|---|
| 1 | [`Purpose-and-Charter.md`](Purpose-and-Charter.md) | Rick's purpose, the tabs, INGEST → MANAGE → ARCHIVE, process expectations, in his words. Rick edits this; agents add only **Claude Feedback** blocks when asked. |
| 2 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | How it is built: the spine, the tabs, the subsystems, the data-risk map. |
| 3 | [`PROCESS.md`](PROCESS.md) | How work moves: roles, the merge gate, tests, review and Codex, rhythm, machines, documents. |
| 4 | [`STATUS.md`](STATUS.md) | What is in flight this week, what is waiting on Rick, what is next. Rewritten, never appended; read it at every session start. |
| 5 | [`DECISIONS.md`](DECISIONS.md) | Dated rulings. Settled is settled; do not relitigate. |

Then, as needed: [`DESIGN.md`](DESIGN.md) (the contracts each module keeps — read before changing a module), [`BACKLOG.md`](BACKLOG.md) (park an idea in one line), [`project_goals.md`](project_goals.md) (Rick's seven goals and Hallie's purpose). The standing rules for every agent are [`../CLAUDE.md`](../CLAUDE.md) (`../AGENTS.md` points at it).

## Designs (`design/`)

One file per approved design; retired to `archive/` when built or dropped. The ones still carrying weight:

| File | One line |
|---|---|
| [`models.md`](design/models.md) | **The one list of models** (captioner, era expert, Hallie, Whisper, face engines, embeddings): size, where it runs, what it is for, status, evidence; how a model earns a seat; what a model may never see; where its outputs live. |
| [`data_organization_2026_10_31.md`](design/data_organization_2026_10_31.md) | How the data is organized: every App Support file and every catalog table, column by column (also rendered as `.html` for Rick). |
| [`catalog_sqlite_schema_v1.sql`](design/catalog_sqlite_schema_v1.sql) (+ [`_checks.sql`](design/catalog_sqlite_schema_v1_checks.sql)) | The catalog schema as code, and the invariants checked against it. |
| [`background_service_2026_10_30.md`](design/background_service_2026_10_30.md) | VideoScan Background, the analyzer helper that keeps running after quit; §0.7 names observations vs decisions and where each lives. Step 0 built. |
| [`video_llm_lab_2026_10_30.md`](design/video_llm_lab_2026_10_30.md) | The pluggable video-model lab: samplers, approaches A0–A6, the Judge, the evidence inventory (§11), Rick's §9 rulings. Phases 0–2 built; results in `reviews/video_llm_benchmarks.md`. |
| [`provenance_lightweight_2026_10_22.md`](design/provenance_lightweight_2026_10_22.md) → [`provenance_retroactive_2026_10_26.md`](design/provenance_retroactive_2026_10_26.md) | Provenance: the records and the Ingest → Identify → Confirm → Archive walk, then the retroactive backfill (schema v13 Set Role built; v14 assertions pending). Policy words: `guides/provenance_roles.md`. |
| [`integrity_first_2026_10_16.md`](design/integrity_first_2026_10_16.md) → [`catalog_sqlite_migration_2026_10_16.md`](design/catalog_sqlite_migration_2026_10_16.md) → [`catalog_contract_freeze_2026_10_17.md`](design/catalog_contract_freeze_2026_10_17.md) → [`catalog_cutover_f_prime_2026_10_17.md`](design/catalog_cutover_f_prime_2026_10_17.md) | The catalog's move to SQLite, in the order it happened: trust gate, plan, frozen contract, cutover to the one commit door. Built 10/18; still the authority on the committer. |
| [`catalog_status_freshness_2026_10_16.md`](design/catalog_status_freshness_2026_10_16.md) | Catalog Status: how fresh each kind of knowledge is (built). |
| [`one_removal_marker_and_trash_engine.md`](design/one_removal_marker_and_trash_engine.md), [`cleanup_kiss_2026_10_12.md`](design/cleanup_kiss_2026_10_12.md), [`pruneplan_simple_2026-10-21.md`](design/pruneplan_simple_2026-10-21.md) | Letting copies go safely: the one marker and the one Trash engine; Cleanup; PrunePlan. Data-risk; all built. |
| [`events_design.md`](design/events_design.md), [`related_score_2026_10_14.md`](design/related_score_2026_10_14.md), [`audio_fingerprint_2026_10_14.md`](design/audio_fingerprint_2026_10_14.md), [`event_analyzer_compare_media_2026_10_15.md`](design/event_analyzer_compare_media_2026_10_15.md), [`footage_folders_2026_10_16.md`](design/footage_folders_2026_10_16.md), [`segments_and_content_coverage_2026_10_10.md`](design/segments_and_content_coverage_2026_10_10.md) | "Which recordings belong to the same family memory?": Events, the related-score ladder, the audio fingerprint engine (built), Compare Media, footage folders, segments. |
| [`check_media_and_menu_cleanup_2026_10_07.md`](design/check_media_and_menu_cleanup_2026_10_07.md), [`audit_archive_2026_10_15.md`](design/audit_archive_2026_10_15.md) | Check Media (built) and Audit Archive (proposed). |
| [`analyze_knowledge_and_storage_actions_2026-10-02.md`](design/analyze_knowledge_and_storage_actions_2026-10-02.md), [`tab_charters.md`](design/tab_charters.md) | The workflow redesign of Analyze / Knowledge / Storage actions, and the one question each tab answers. |
| [`cyberbrain_design.md`](design/cyberbrain_design.md), [`kinship_inference_design.md`](design/kinship_inference_design.md) | Family knowledge: CyberBrain (testimony, attestations) and kinship inference across the tree and the People tab. |
| [`swift6_migration_2026_10_25.md`](design/swift6_migration_2026_10_25.md), [`vsm_split_plan_2026_10_19.md`](design/vsm_split_plan_2026_10_19.md), [`m4_staging_gate_2026_10_28.md`](design/m4_staging_gate_2026_10_28.md), [`nightly_adversarial_review_design_2026-10-01.md`](design/nightly_adversarial_review_design_2026-10-01.md) | Engineering: the Swift 6 migration (done), the `VideoScanModel` split (#337, waiting on Rick), the M4 testbed, the nightly adversarial review. |
| [`October_Design_Retrospective.md`](design/October_Design_Retrospective.md) | The long form of `ARCHITECTURE.md`, as built in October, with Rick's open design questions. |

## Guides (`guides/`)

Correct, read on demand; a guide exists where a reader would otherwise have to read code.

| File | One line |
|---|---|
| [`source_layout.md`](guides/source_layout.md) | Where the app source lives, folder by folder. |
| [`testing.md`](guides/testing.md), [`gauntlet.md`](guides/gauntlet.md) | The five test categories; the Release gauntlet and how to run it in an away window. |
| [`media-archive.md`](guides/media-archive.md), [`archive_angel_policy.md`](guides/archive_angel_policy.md), [`provenance_roles.md`](guides/provenance_roles.md) | The Master Archive: preservation, promotion, cleanup; the Archive Angel's rule set (data, not code); what each file's role means in Rick's words. |
| [`date_inference_catchup_and_propagation.md`](guides/date_inference_catchup_and_propagation.md), [`notes_authorship.md`](guides/notes_authorship.md) | Inferred dates (catch-up, propagation, folder-year prior); who said what in a note. |
| [`Avid-Format-Reverse-Engineering.md`](guides/Avid-Format-Reverse-Engineering.md), [`drive_health.md`](guides/drive_health.md) | The native Avid bin/media parsers; SMART data per scan target. |
| [`gedcom.md`](guides/gedcom.md) | GEDCOM export and import: the family tree is the fact store. |
| [`hallie.md`](guides/hallie.md) (paused 2026-10-16), [`facial-recognition.md`](guides/facial-recognition.md) (frozen 2026-10-23) | Hallie's architecture and operations; person search and Find & Tag. Models for both are in `design/models.md`. |
| [`ops/`](guides/ops/) | Machine how-tos: test-Mac setup, gauntlet TCC and exit masking, the M1 runner, lldb fifo control, storage layout, TB5 diagnostics, Python paths, the complexity counter's source of truth. |

## Practices (`practices/`)

[`swift_playbook.md`](practices/swift_playbook.md) (patterns and in-repo exemplars for the jobs we do again and again) · [`testing_retrospective_2026_07_05.md`](practices/testing_retrospective_2026_07_05.md) (the five dimensions) · [`invariants/`](practices/invariants/) (what the nightly adversarial review attacks, one file per area) · [`nightly-metrics-setup.md`](practices/nightly-metrics-setup.md) (what feeds the metrics page, `index.html`).

## Reviews and evidence (`reviews/`)

Live evidence, overwritten in place: [`video_llm_benchmarks.md`](reviews/video_llm_benchmarks.md) (the model ladder's numbers), [`hallie_benchmarks.md`](reviews/hallie_benchmarks.md) (Hallie's replay), [`household_roster_feasibility.md`](reviews/household_roster_feasibility.md) (the roster as a filter, not a namer). [`BRIEF_TEMPLATE.md`](reviews/BRIEF_TEMPLATE.md) is the Codex brief shape.

Records kept for the rulings that cite them: [`tab_charter_audit_2026_10_11.md`](reviews/tab_charter_audit_2026_10_11.md), [`gh_issue_triage_2026_10_11.md`](reviews/gh_issue_triage_2026_10_11.md), [`p0-regression-2026-10-17.md`](reviews/p0-regression-2026-10-17.md), [`cutover_acceptance_audit_2026_10_19.md`](reviews/cutover_acceptance_audit_2026_10_19.md), [`qa/ndsa_self_score_2026-10-02.md`](reviews/qa/ndsa_self_score_2026-10-02.md), [`adversarial/`](reviews/adversarial/), [`swift-expert/2026-10-18-reading-guide-best-vs-worst.md`](reviews/swift-expert/2026-10-18-reading-guide-best-vs-worst.md), [`cloud/LEDGER.md`](reviews/cloud/LEDGER.md) (credits to 2026-11-05). `reviews/codex/` holds Codex pass records from 10/25–10/30 that Swift test headers cite (#404); `PROCESS.md` §5 says new verdicts go in the PR, not here.

## Research (`research/`)

One per study; still cited by code or by a live design: [`familysearch_api_notes.md`](research/familysearch_api_notes.md) (and its production-key blocker), [`irish_records_design_2026-09-30.md`](research/irish_records_design_2026-09-30.md) and [`uk_scotland_records_survey_2026-10-01.md`](research/uk_scotland_records_survey_2026-10-01.md) (the Record Finder's sources), [`provenance_deep_dive_2026-10-23.md`](research/provenance_deep_dive_2026-10-23.md) and [`provenance_retroactive_fingerprinting_2026-10-25.md`](research/provenance_retroactive_fingerprinting_2026-10-25.md) (what the provenance designs rest on). Model and LLM research was folded into `design/models.md` on 2026-10-31; the originals are in `archive/research/`.

## Also in this folder

`briefs/cloud/` (the nightly cloud-session brief and its standing rules, through 2026-11-04) · `hallie_tools.schema.json` (Hallie's tool schema, read by `scripts/hallie_e1/`) · `poi-cycles/metrics.jsonl` (machine data for the POI sensor replay) · `index.html` (the published metrics page, written by `tools/publish_metrics.py`).

## Archive (`archive/`)

Retired documents, never deleted: [`archive/README.md`](archive/README.md) lists what was moved here and why; [`archive/INDEX-2026-10-reset.md`](archive/INDEX-2026-10-reset.md) lists the 2026-10-23 reset (`git show pre-reset-2026-10-23:<path>` prints any of them); `archive/RETIRED.txt` is the machine-readable list the docs-links guard consults.
