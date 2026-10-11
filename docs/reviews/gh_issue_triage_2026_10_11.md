# GitHub issue triage — 2026-10-11

Read-only proposal. No issue was closed, edited, labelled or commented on.
Source: `gh issue list -R musicalengineer/VideoScan --state open` on 2026-10-11 (170 open), checked against main @ 46aa89744, `git log` (every SHA cited below is on main unless it says otherwise), `docs/design/tab_charters.md`, `docs/project_goals.md`, `docs/reviews/tab_charter_audit_2026_10_11.md`, and the 2026-10-11 nightly-findings ticket (#308) for the CodeQL and strict-concurrency state.

Rick approves before anything is run. The close script at the end touches only the CLOSE set.

## Summary

| Verdict | Count | What happens |
|---|---:|---|
| CLOSE: done | 31 | closed as completed, with the evidence as the comment |
| CLOSE: obsolete | 16 | closed as not planned, naming the decision that superseded it |
| CLOSE: duplicate | 1 | closed as duplicate |
| MERGE into an umbrella | 47 | folded into 23 umbrella issues (by hand, after approval; not in the script) |
| GROUP (bot-managed) | 24 | 8 CodeQL + 15 strict-concurrency trackers + today's nightly ticket. Left open: the bot closes them after 3 clean nights; closing by hand as completed would get them reopened |
| KEEP | 36 | ranked below by Rick's five jobs (umbrellas included) |
| PARK (`idea`) | 15 | stay open with the `idea` label |
| **Total** | **170** | |

After the closes and merges, the working list is **36 KEEP** plus 15 parked ideas and the bot trackers, down from 170.

Note: the brief mentioned "5.2 steps"; no doc in the repo defines a 5.2 step list (the only 5.2 sections are in the Hallie and segments design docs), so KEEPs are placed by tab and by Rick's five jobs.

## CLOSE: done

| # | Title | Evidence |
|---|---|---|
| #44 | Cache Person Finder results for repeated same-volume same-person scans | `PersonFinderCache` (People/PersonFinderCache.swift) caches per-video results keyed by engine/ref-hash; re-runs skip unchanged files. |
| #98 | Copy Metadata should include audio transcripts and scene captions | Copy Metadata (`InspectorPanel.formatAllMetadata`) now appends scene captions, transcript and OCR (InspectorPanel.swift:194-238). |
| #102 | Decompose runDossierBatch / runDossierBatchSerial (complexity 24, 160–243 line bodies) | 03fe3347d refactor(dossier): split runDossierBatch / runDossierBatchSerial into shared steps (#281). |
| #105 | Integration ladder rung 0: nightly UI test runner hangs/times out — diagnose and fix | Diagnosed: the 2 AM launchd session cannot enable UI automation; nightly skips VideoScanUITests (scripts/nightly_local_tests.sh:50-63, sensor kept). UI runs live in the gauntlet (tools/gauntlet, run_gauntlet.sh). Rungs 1-3 stay in #140. |
| #113 | purgedAt not in RescanPreservedFields — purged records can resurrect on rescan | cc4562585 merge: preserve purge tombstones across rescans; `purgedAt` is in RescanPreservedFields (VideoScanModel+RescanPreservation.swift:159/345/446). Follow-ups live in #143. |
| #120 | Scan Catalog: merge Local/Network Volumes buttons into one "Volumes…" picker | No Local/Network Volumes buttons left in the scan pane (git grep finds only the Settings label); Storage tab owns volume entry. |
| #129 | MFO jobs: cancel() before start() still runs a full render | 84304006b merge: stop pre-cancelled audio jobs before rendering. The sweep to the other job classes is #142 (merged into #121). |
| #131 | Verify Audio follow-ups: no-audio-stream repair button + stale-record-instance re-lookup | de2a641ee merge: fix Verify Audio follow-ups (#131). Sibling stale-instance writes are #141 (merged into #121). |
| #134 | Restore meaningful-frame video preview across all media windows | Best-frame previews shipped: PreviewBestFramePlan / PreviewFrameScorer reject near-solid frames (Media/PreviewFrameScorer.swift:190), filmstrip plan, overnight preview cache; People rows use cached thumbnails (a3fb544d7). Confidence medium: Rick to confirm by eye. |
| #144 | Replace DLIB Search algorithm with AdaFace plugin | c38b8be2d merge: AdaFace plugin replaces dlib in Search, plus 6 codex follow-up commits. Remaining nits are in #148. |
| #150 | MFO: no verb can actually pause — wire SIGSTOP/SIGCONT into ProcessRunner so Pause All has teeth | 3e6598706 feat(mfo): real pause, SIGSTOP/SIGCONT via ProcessControl (GH #150); BalanceAudioJob.swift:340, CheckMediaJob.swift:38. |
| #156 | Find & Tag: survive a wedged clip — skip and continue instead of failing the whole batch | 4602d943c feat(find-tag): wedged clips skip-and-continue + 9c414429f stall-latch reset (GH #156). |
| #160 | Permanently deleted files: tombstone rows may be leaking into visible surfaces/counts | 7d1a99a1d fix(catalog): in-place purges announce a mutation so the cached table recomputes (#160). No further report since 08-15. The wider 'one gone shape' work is #143. |
| #161 | Catalog UI beachballs with a couple of MFO jobs running — triage the suspects | Suspects fixed: 4b8b6bff0 (manifest.sha256 refresh off-main), 156be1a10 (no fsync per lock acquire). Prime suspect was the transient 81k-record catalog, since removed. A new beachball gets a new issue with a sample. |
| #162 | Migrate: Reconcile PREVIEW writes nothing to relocate.log — log summary + per-file buckets tagged [PREVIEW] | 7b0f1c259 merge fix/162-preview-logging: [PREVIEW] reconcile logging, plan-based bytes-to-copy. |
| #166 | Inferred date off by a decade: OCR/captions/audio all say 1997, inference says 2007 (Clip 01.dv) | 27967cc52 merge fix/166-content-date-outvotes-stamp (content evidence outvotes copy-era stamps, catalog sensor). |
| #183 | Archive Angel: Close should not block during Promote — background the run, show completion in AA | Close is no longer modal over a running promote (ArchiveAngelReviewSheet.swift:446-453, Rick 2026-09-20: the job lives in MFO; Close keeps the batch). |
| #186 | Hallie People-tab precedence: picking a profile chip loops back to the namesake crowd, and the .profile fallback answers the uncorrected operation | 85e95f007 fix(hallie): GH #186, a profile chip answers and the corrected question is answered. |
| #187 | Hallie voice: "it's good to see you" is spoken as "good to Kye you" | 64957f3b7 fix(hallie-voice): learned pronunciations are for names, common-word guards (GH #187). |
| #191 | Person Finder stopJob cancels the scan task but never resumes the pause gate | d378c71b9 / 4b0c40793 merge fix/night-qa-pausegate: Stop on a paused PF job no longer leaks worker slots (#191). |
| #198 | Refresh from FamilySearch: audit-grade logging (console + catalog.log + videoscan.log), 'Refreshed on <date>' on the person, revert path | d85ce8cd0 merge fix/fs-refresh-logging: audit-grade logging for Refresh from FamilySearch (GH #198). |
| #208 | Timing budgets: 'load-aware' ceiling still fails under a saturated host (triangulator 100k: 35.8 s vs 25 s at load avg ~16) | 2f82780e7 merge #208 timing cap: TimingBudget.judge, strict when quiet and in the 2 AM nightly, known-issue under load (revisit with the Ultra). |
| #227 | Family map: after Walk Tree, click a place → map of where ancestors were born (US states, England, Scotland, Wales, Ireland, Canada) | Family map shipped: 05935bafa, a29d54034 (codex r3/r4), 4723c19bf (Western Europe). The scope in the issue (US states, England, Scotland, Wales, Ireland, Canada) is covered. |
| #229 | Family Tree: tiny country flag on person cards (esp. ancestors 4+ generations back with no photo) | 6b8e0834f merge feat/tree-card-flags + 5e3e51252 KISS follow-up (flag in the card header). |
| #230 | Need better integration with Irish Genealogical Sites | Record Finder covers the Irish sites as far as they allow: links + filing (RecordFinder+Registry.swift, ResearchRecordSources.swift, FamilyTreeDocumentsContext.swift), codex #18 fixes 793c2e9d1. Automated fetch is refused by the Irish state archives (403; FamilyTreeCards.swift:133-136). Rick's call: close, or re-file the automation wish as an `idea`. |
| #235 | Family map notes: keep ONLY the own-name rule for 'whose birth is this' (close codex r4 F1 for good) | d1aee8c51 merge fix/235-own-name-rule-only (opener rules deleted, codex r4 F1 closed). |
| #239 | Coverage is not measured: last xccov number is 2026-06-14; gauntlet/nightly results carry no coverage | 80764f509 tools: nightly coverage run on the M4 at 04:00 (per-folder logic vs view %, zero-coverage files, coverage.log; tests/test_nightly_coverage.py). |
| #260 | Footage Spectrum: a colour-over-time strip per video — the picture that shows which clips are the same footage, and the fingerprint that finds them | 14aa9eb0b merge Footage Spectrum trial (Compare Footage MFO job + window). Per the tab charter it now lives in Triage > Events (audit row 19, tracked in #155). |
| #272 | People tab: click a person → their videos (Known / Likely / Possible); demote live drive search | a3fb544d7 feat(people): 'Videos of <person>' is the People tab's primary view (tiers, decades, 100k sensor), then e37f0a1d5 / a88d3abed. The Yes/No triage on 'Maybe' rows was not built; it belongs with #133. |
| #288 | Prune device count + Angel quit-recovery 'landed' rule (P2 ×3, from CC N1011/N1016) | b83405e1e merge review/codex-batch-2026-10-07: prune device count (b6fa28fd9) and Angel quit-recovery fixes (5eb56e31b, 0f2f12c86, 096e3b40a). |
| #307 | Family Tree: right-click menu flickers / unclickable while a Research run is active | d8aac4c98 fix(family-tree): catalog publishes no longer rebuild the tree's cards and open right-click menus (#307), on main. |

## CLOSE: obsolete

| # | Title | Superseded by |
|---|---|---|
| #36 | As volumes are scanned, the RT Scan window should clear the completed volumes after say 3-5 minutes, so only In Progress volumes show | There is no RT Scan window any more (no such Window in VideoScanApp.swift); scan progress lives in Storage / Dashboard, and long work is MFO (CLAUDE.md, Long operations). |
| #71 | Benchmark scan performance and identify critical bottlenecks | Person Finder throughput benchmark from May. PersonFinder was demoted on 2026-09-26 and the People tab now leads with known videos (#272). Perf baselines exist (memory: perf baseline, I/O bound). |
| #81 | Investigate ImageIO crash while rendering VideoScan photo thumbnails | Crash of 2026-05-08 in FamilyTreeDemoView photo rendering; that view no longer exists (git grep: 0 hits) and no recurrence was reported. |
| #82 | Resume paused/in-progress searches across app restart | Resume Person Finder searches across restart: live drive search was demoted (9/26 ruling, #272 'Search the drives' at the bottom). |
| #83 | Configurable RAM pre-staging budget for Person Finder scans | RAM pre-staging slider for Person Finder scans: same demotion; the Angel RAM tier idea is #174. |
| #92 | DB integrity: mirror dossier JSONL deltas off Crucial2TB (single-disk failure) | Dossier fleet: the deltas on CrucialX9/dossier-deltas were last written 2026-06-10 and no worker runs; dossier work now runs in-app (CaptionOrchestrator, Analyze panel). The deltas are merged into catalog.json and its backups. |
| #94 | DB integrity: merger heartbeat + in-app stale-merger banner | Merger heartbeat for the dossier fleet: same reason as #92 (merge_dossier_jsonl.py last changed 08-15; no merger running). |
| #96 | Dossier fleet: 'Participating Computers' status panel (visibility-only) | Dossier fleet 'Participating Computers' panel: same reason as #92; background visibility is #195. |
| #97 | Dossier fleet: 'Resume Dossier Sweep' one-click button | Dossier fleet 'Resume Sweep' button: same reason as #92. |
| #110 | Volume list rows appear/disappear repeatedly — flapping-drive churn vs republish storm | Root cause was LACIE500 mount-flapping hardware (diskutil-confirmed); the volume list has since been rebuilt as the Storage tab (VolumesWindow). Re-file with a sample if rows churn again. |
| #112 | Set-aside browser polish — bulk restore by category | Set-aside browser polish for Tidy Catalog. Per the tab charter Tidy moves to Triage > Cleanup (audit row 14); design Cleanup there instead (#155). |
| #122 | find_donna_scan: self-stage the eval binary to eviction-proof storage + verify identity at launch | find_donna_scan self-staging: the overnight Person Finder batch driver; superseded by the 9/26 demotion and the People tab's known-videos view. |
| #157 | Find & Tag throughput: decode-ahead prefetch, RAM warming, measured concurrency | Find & Tag throughput (decode-ahead, multi-clip): Person Finder demoted 9/26; no live drive scans planned. |
| #196 | Triage tab: retire — Under Construction → MFO 'Review outputs'; disposition filters → Catalog Show ▸ menu | 'Retire the Triage tab' was overruled by the tab charter (2026-10-11): Triage stays as a side lane (All Needing Triage, Events, Cleanup, Angel recommender). |
| #251 | Design: Analyze menu + 'What the Catalog Knows' coverage view + Delete Duplicates on the Storage tab + queue-not-refuse scheduler | Phase A shipped (b72e503ce), but its 'Delete Duplicates on the Storage tab' is reversed by the tab charter: Storage does not decide deletes; delete moves to Triage > Cleanup (audit rows 1 and 22). Remaining placement work is in #155. |
| #257 | Content steward: payoff-ranked cases in the Triage tab (reclaim space · same footage · probably not worth keeping) — Archive Angel's shape, second instance | Content steward trial shipped (93a8ede62, 49b8ab2f2). The charter now defines its successor: Triage > Cleanup and Triage > Events, with mockups before code (tab_charters.md, 'Next'). Tracked in #155. |

## CLOSE: duplicate

- #193 Tests move test POIs into the REAL repo .trash (POIStorage.trashDir not sandboxed in a test host): duplicate of #256. Same bug as #256 item 2: POIStorage.trashDir is still the real ~/dev/VideoScan/.trash in a test host (POIStorage.swift:186-189).

## MERGE groups

Each umbrella keeps its number. Suggested new title in bold; members get closed with a pointer once the umbrella body lists them (a manual step after approval).

### #143 → **One delete engine and one 'gone' shape (audit 2026-10-11 section 2a/2b, red tests T1-T5)**
Currently: Tombstone durability follow-ups: identity-gate reapplication at reused paths; stop hard-pruning purged tombstones of deleted files
- #240 Archive What-next / Promote sheets: pin why rows are disabled (delete-choice screen has 7 incidental tests): What-next / Promote sheet row-state tests. The what-next bulk prune moves to Cleanup (audit row 24), so pin it on the one engine.
- #241 Media matrix: run Delete Duplicates and Prune Apply over the five-format fixtures (mp4/mov/mkv/mxf/dv): Media-format matrix for Delete Duplicates and Prune Apply: the tests the one engine needs.
- #268 Delete Duplicates: residual edge cases from codex round 6 (merged per Rick's ruling 2026-10-04): Delete Duplicates residual edge cases (codex r6): gates of the same engine.
- #278 Read-only mark on the boot volume (/) is shown as protecting the drive but the delete gate ignores it: Read-only mark on the boot volume ignored by the delete gate (ReadOnlyVolumeProtection.swift:149 still drops '/'). Needs Rick's (a)/(b) ruling.

### #121 → **Repair... one engine (audit section 2d): Combine, Balance, Rebuild, Clean Up, Reformat become R1 recipes**
Currently: MFO output-location symmetry: combine/Find Matching Audio defaults to in-place beside source, folder becomes override
- #119 Audio triage: persisted channel classification, Show Audio Details, filter/search facets, batch Balance Audio: Audio triage: batch Balance becomes a Repair recipe; the channel classifier is an Analyze cycler (no `audioBalanceClass` in code yet).
- #130 Startup/scan-time sweep for orphaned .vs-partial render files: Startup sweep for orphaned .vs-partial renders (no sweep in code; DerivativeOutputPublish.swift:86).
- #138 Surface superseded originals whose repaired copy is missing: Superseded originals whose repaired copy is gone: the RepairLifecycle adoption rules own this.
- #141 Stale-record-instance writes in BalanceAudioJob/RebuildAudioJob provenance notes (same class as #131 verdict fix): Stale-record writes in BalanceAudioJob / RebuildAudioJob notes (BalanceAudioJob.swift:783 still writes through the captured instance). R3/R4 fold into R1.
- #142 Pre-start cancel hole in remaining MFO job classes (sweep or hoist the #129 guard): Pre-start cancel hole in Reformat/Transcode/Cleanup/Trim... (no guard in ReformatJob/TranscodeJob); hoist it into the shared job lifecycle.
- #192 Stop does not end Combine batches appended while Combine is running: Stop does not end appended Combine batches (`if !appending { combineTask = newTask }`, VideoScanModel+Combine.swift:765). Combine becomes an R1 batch.

### #155 → **Tab-charter cleanup: move the 26 misplaced features, one door per shared action (audit 2026-10-11 section 1)**
Currently: Catalog view: menu cleanup
- #126 Catalog context menu: disable operations that do not apply to selected media: Disable context-menu operations that do not apply: part of the Catalog menu rewrite.

### #118 → **Dates are filming dates, not copy dates (date accuracy umbrella)**
Currently: Date plausibility gate: demote transfer dates on digitized tapes (2026-on-a-VHS case)
- #232 Date resolver: filename month matchers bypass the dimension/camera-counter exclusions (May_1920x1080.mov → 1920-05): Reproduced: filename month matchers bypass the dimension/counter exclusions (RecordDateResolver.swift:401 runs matchMonthName/matchYearMonth before matchBareYear's guard at :485).
- #209 Date sharing: a donor's user-date edit or a footage regroup never triggers a scoped date pass — stale shares live until next launch: Footage-shared dates go stale after a donor edit or regroup (applyFootage never calls catchUpInferredDates).

### #294 → **Archive identity and filing accuracy**
Currently: Archive identity drift: 17 already-archived files show 'Not Yet Archived'; 60 archive copies with vanished promote sources; stale manifest ids
- #293 Archive Year check findings: fingerprints never stored, Jan-1 date leak, 69 items filed by copy year: Items 1-2 fixed (b78d047fb, 2eb96ebff); items 3-5 (filed by copy year, within-year repeats, coverage) are the same archive-identity work.

### #286 → **Archive promote / refile / fixity hardening**
Currently: Archive promote/refile hardening — 9 findings from cloud review C02 (no P1; 3×P2)
- #248 Archive follow-ups from codex 10-02: 're-fingerprint source' action; remaining persistent log lines that carry media paths: Re-fingerprint action + media paths in persistent logs. The log-policy half also feeds the CodeQL group below.

### #221 → **Archived is read-only: every date writer goes through Update...**
Currently: Inspector date edit on an archived record should open Update… (keep folder/filename/manifest in step)
- #220 External Python date writers (merge_dossier_jsonl.py, propagate_dossier_by_md5.py, folder_date_interp.py) can write dates onto archived records when the app is closed: External Python date writers can touch archived records; recommend retiring them (the dossier fleet is idle since 06-10).

### #167 → **Catalog versioning and write safety (feat/167-catalog-versioning is NOT on main)**
Currently: Master Archive designation silently vanished from catalog.json (None designated; archive tree intact)
- #93 DB integrity: daily catalog snapshot rotation (replace single-step .prev): Daily catalog snapshot rotation: still only catalog.json.prev plus ad-hoc pre-* copies.
- #250 Catalog: sibling writers that bypass the newer-catalog gate (Relocate pre-snapshot, ArchiveLock marker, DateInference sidecars) + viewer-mode zero-write: Sibling writers that bypass the newer-catalog gate: follow-up of the #167 codex cycles.

### #256 → **Tests must never touch real state (test-host isolation)**
Currently: Settings-pollution: test hosts write to the REAL repo .trash (5,301 POI-* dirs, 9.7 GB) and read real validation labels; BundleImporter trashTarget per-second stamp collides
- #222 DuplicateReelectionStampTests.skippedRowsLeaveThePolicyUnstamped fails on local main (af04f46c) though CI is green: DuplicateReelectionStampTests fails locally, green on CI: likely the same isolation class.

### #169 → **Volumes come and go: wake, wait, resume**
Currently: Scan: auto-resume a target when its volume remounts (bumped drive) instead of waiting for a manual Resume
- #27 clicking media in the catalog window on an attached volume that is sleeping doesn't wake it: Clicking media on a sleeping drive does not wake it.
- #168 Archive Helper: verify/balance dispatched before external volume access is re-established after launch → false 'volume stopped responding': Angel/Helper dispatches verify before external volume access is back after launch.

### #195 → **Background work is visible: one Analyze surface for every cycler**
Currently: Background activity must be visible: one surface listing every BG task (last run / next / outcome / toggle) + solid START/OUTCOME logging
- #194 Refresh Embedded Dates is invisible and not quit-safe — make it an MFO job (progress, ETA, pause/stop, incremental save): Refresh Embedded Dates: invisible and not quit-safe. It is a metadata cycler, so per the 10-02 ruling (MFO = file ops, Analyze = cyclers) it belongs on this surface.

### #246 → **Nightly / CI tooling papercuts**
Currently: Type-check timing ratchet trips on runner jitter (personCardEntry 340 → 505 → <500 ms vs 500 ms gate)
- #212 test_nightly_review.sh case 10: abandoned-commits night produces an empty/over-long channel subject: test_nightly_review.sh case 10 empty channel subject.
- #247 Adversarial confirm step tests drafts against current main, not the reviewed head (10-02: 0 of 2 confirmed because fixes merged before 05:30): Adversarial confirm step tests drafts against current main, not the reviewed head.

### #262 → **Test quality: sensors that prove execution, coverage gaps on data paths**
Currently: Source sensors check textual presence, not execution: #if false, unused closures, loops and literals can satisfy them
- #245 Record Finder filing: remaining codex #19 coverage gaps — import read-back mismatch / sidecar publication failure; store START lines: Record Finder filing coverage gaps and missing START lines.

### #281 → **Tech debt: CCN over 30 to zero before the Ultra**
Currently: HIGH PRI: tech debt — 40 functions over complexity 30, 10 over 50; the complexity guards were warn-only
- #228 Copilot review of FootageGroups: three refactor suggestions (UnionFind.offer, FootageGrouping phases, job run()): Copilot FootageGroups refactor suggestions: do them when the code next changes, under the CCN ratchet.
- #146 Preview post-merge reconcile: shared requestedSeconds param, renderer dedup, best-tier upgrade gap: Preview renderer dedup (shared requestedSeconds param) and the long-session prune gap.

### #231 → **Codex 2026-09-30 residual P2s (Angel checks, people-folder undo)**
Currently: Angel Checks: busy/readiness gates go stale across the fileExists await; FamilyArchive-volume siblings of the archive root are not excluded
- #233 People-folder migration undo ignores directory symlinks; Angel buffer Clear still resolves paths on main: migrate_people_folders.py identity ignores directory symlinks (os.walk `dirs` not hashed, :290-299); Angel buffer claim resolves symlinks on main (ArchiveAngelLiveBatches.swift:65).

### #279 → **Adversarial-review P3s (UI truth and logging)**
Currently: Adversarial review 2026-10-05: five P3s (UI truth and logging)
- #269 Compare Footage cache: refuse a symlinked runs folder when WRITING (not only when pruning); log each pruned run folder: Compare Footage cache: refuse a symlinked runs folder when writing; log each pruned run (app cache only).

### #199 → **Housekeeping: log retention + docs retirement**
Currently: Log retention: nightly job prunes ~/Library/Logs/VideoScan (7 d test logs, 14 d audits/rotations, 30 d review scratch) into a dated _archive folder
- #95 docs/ cleanup pass — retire one-shot notes + shipped-feature plans: docs/ cleanup pass: same chore class, low priority.

### #185 → **Hallie: live and eval misses (judge against the frozen eval suite and the agent lane)**
Currently: Hallie live replay 2026-09-13 observations: royalty/title unflagged false negative, count follow-ups, 'longest video in the archive', correction turns, bare 'show me'
- #184 Hallie live misses 2026-09-11 spot test: children-of-couple, photo context, bare tree name, persona, KY teach wrote junk CyberBrain entry: Items 4-6 fixed (54eba9c1d, 434862151); items 1-3 (children of a couple, plural pronoun count, photo-context follow-ups) remain. The queries were harvested into the eval corpus (579c6a5ff).
- #159 Archivist: perspective-aware family biographies from GEDCOM, notes, and media: Perspective-aware biographies from GEDCOM: biographies, lineage chains and the persona road exist now (HallieLineageQuestion, #184 items 4-5); judge what is left against the eval suite.
- #158 Family Archivist: GEDCOM ancestor biographies with sourced photos: GEDCOM ancestor biographies with sourced photos: same user story as #159.
- #181 Hallie shell/eval cannot reach the model on the M4: ollama binds 127.0.0.1 only and RicksM4.local resolves to IPv6 link-local — every translator turn fails 'language helper unreachable': The headless shell still defaults to RicksM4.local (OllamaEndpoints.swift:43, HallieShellCLI.swift:11), so eval replays without --host report connection failures as model misses.

### #148 → **Person-finder engine follow-ups (PARKED: engine demoted 2026-09-26; fix only when the People tab needs it)** (PARK)
Currently: AdaFace follow-ups from QA review (post-#144)
- #114 Vertical (rotated) video: face pipeline ignores rotation metadata — 0 usable matches on portrait HEVC clip: Rotated (portrait) video ignored by the face pipeline.
- #145 Review sheet follow-ups: per-CSV write serialization, prefetch retry cap, re-answer counter: Holdout review sheet follow-ups.
- #147 Unrouted AVFoundation in person-finder scan paths (same disease previews had): Unrouted AVFoundation in person-finder scan paths.
- #149 Unified-review follow-ups (ConfirmPersonSheet split, main-actor scorer stall, pending-holdout exclusion): Unified-review follow-ups (item 1 blocked on a grading ruling).
- #152 FindPersonJob: stdout event Tasks can lose the final clip's verdict (priority-inversion on main actor): FindPersonJob event ordering (hotfix shipped; nicer shape wanted).
- #153 Public test corpus: synthetic-person + public-domain footage so CI/cloners can run realistic person-finding tests: Public synthetic test corpus for person finding.
- #99 Extract Frames phase 3: face preview overlay + POI matching: Extract Frames phase 3: face overlay + POI matching.
- #85 Include cluster data in bundle export/import: Cluster data in bundle export (Identify Family).

### #6 → **Face recognition research (PARKED)** (PARK)
Currently: Explore training a custom face recognition model on family media
- #22 How to deal with face detect on same person over years, from kid to adult to senior?: Same person across ages: same research question.

### #216 → **Tree walk ideas (PARKED)** (PARK)
Currently: Tree walk: interval inference for undated people (birth-year intervals to a fixpoint)
- #215 Tree walk: nightly 2 AM run on the M4 via a CLI: Nightly 2 AM tree walk via CLI.
- #217 Tree walk: region spellings still unknown ('Europa', 'Francia', 'Sctl.', 'Den.', bare English county names): Unknown region spellings.

### #236 → **Person of the Day stories (PARKED)** (PARK)
Currently: Story of the Day: 'Tell me a story' button + Hallie query built on Person of the Day
- #237 Roll Call v2: 3D credits — names, dates, places, photos drifting gently through depth: Roll Call v2, 3D credits.

### #223 → **Archive health: verify, then reversible remove**
Currently: Verify Archive: playable, dated, correctly filed, locked, matches the index (report only)
- #224 Remove from Archive: move a bad file to a Removed holding folder (reversible), not delete: Remove from Archive to a reversible _Removed folder: the fix half of Verify Archive. /safety-critical + codex.

### Bot-managed groups (no manual close)

`tools/nightly_findings_to_issues.py` keeps one tracker per (tool, rule, file), closes it after 3 clean nights, reopens it if an instance returns, and treats "closed as not planned" as a permanent wontfix. So these are grouped by root cause here and left open. Every one is still reported in the 2026-10-11 run (#308); the 9 "fixed" entries that night were fingerprint churn inside the same files.

**CodeQL, one root cause: family-tree facts (names, spouses, birth dates) flow into persistent log lines.** CodeQL's sensitive-data heuristic matches `spouse`, `spouselessMarriages`, `birthDate`; every hit is an `appLog` / `logLine` that interpolates a question, a person key or a document file name.

| # | File | Rule | Shape |
|---|---|---|---|
| #252 | `FamilyTree/FamilyAssetStore+Documents.swift` | cleartext-logging | document file names / person keys in log lines (4) |
| #253 | `FamilyTree/FamilyTreeLiveModel.swift` | cleartext-logging | 'select ignored — no person <id>' (:1333) |
| #254 | `FamilyTree/FamilyTreeLiveModel.swift` | cleartext-storage-preferences | UserDefaults key built from familySearchID (:1215) |
| #264 | `Hallie/HallieAppTurnCoordinator+Drill.swift` | cleartext-logging | drill words in log lines (3) |
| #265 | `Hallie/HallieAppTurnCoordinator+Picker.swift` | cleartext-logging | logLine(offered:) |
| #266 | `Hallie/HallieAppTurnCoordinator.swift` | cleartext-logging | turn log line |
| #274 | `Hallie/HallieLineageAnswer+GedcomAwareness.swift` | cleartext-logging | lineage answer log line |
| #275 | `Hallie/Shell/HallieShellCLI.swift` | cleartext-logging | logLine(question:ast:), effectiveQuestion (3) |

One decision for Rick (logging format is on the escalation list), which also answers #248 item 2 and #279 item 2: **(a, recommended)** one `LogRedact` helper that writes a stable person key or a hash instead of names, dates and questions in the persistent app log (the Hallie conversation JSONL stays as it is, it is the harvest source), then the trackers close themselves; or (b) declare the local logs private, and close these eight as not planned with that reason. #254 alone is low risk (an ID used as a defaults key) and can take (b) either way.

**Strict-concurrency, three shapes, all present on main today** (spot-checked at the reported lines; the nightly builds with Swift 6 checks on):

| Shape | Trackers |
|---|---|
| `sending 'self'` from a `[weak self]` Task closure in a non-isolated context | #276 ArchiveAngelJob, #282 ArchiveAngelBufferHygiene, #283 TriageSnapshot, #300 Thumbnail |
| closure passed as a `sending` parameter (`Task.detached` / `group.addTask` capturing main-actor or task state) | #284 FamilySearchPullCoordinator, #289 FamilyTreeLaunchBundle, #290 FamilyTreeLiveModel, #291 FamilyTreeRecompileCenter, #297 ThumbnailPrecache, #304 PersonFinderModel+JobLifecycle |
| non-Sendable value sent across isolation (`state.records`, `resolution`, `synthesizer`, `action`, `note`, an async closure) | #295 HallieShellCLI, #296 HallieSpeaker, #301 VerifyAudioSheet, #302 VideoScanModel (:1316), #305 MLXSafety |

Track the work under #273 (the 10/4 main-thread SIGSEGVs point at a data race). Fix by shape, one batch per shape, under the CCN-style ratchet. Each tracker closes itself.

#308 is tonight's rotating nightly ticket; tomorrow's run closes it.

## KEEP, ranked by Rick's five jobs

### 1. Catalog everything

| Rank | # | Tab | Title | Why it still matters |
|---:|---|---|---|---|
| 1 | #263 | Catalog | Possible real family data in a public test fixture (EventLabelerTests); ReclaimableCalculator counts every working copy; ContentView drops unknown viewFilters tokens | Public repo: EventLabelerTests.swift:93/:117 fixtures still look like real family data (privacy rule). Items 2-3 (Reclaimable over-count, viewFilters tokens) ride along. Smallest, most urgent fix on the list. |
| 2 | #164 | Catalog / Storage | Cancel mid-walk on a network root saves a partial-walk checkpoint as if complete | Cancel mid-walk on a network root still saves a checkpoint: user cancel `break`s without setting abortedDuringWalk (VideoScanModel+ProbeEngine.swift:121 vs :187). A resume can finalize a partial discovery and feed the prune chain. |
| 3 | #167 | Catalog | Master Archive designation silently vanished from catalog.json (None designated; archive tree intact) | Master Archive designation vanished; the fix branch feat/167-catalog-versioning (406983cc0) is still unmerged. Umbrella for #93, #250. |
| 4 | #169 | Storage | Scan: auto-resume a target when its volume remounts (bumped drive) instead of waiting for a manual Resume | Bumped drive: no auto-resume on remount; plus wake (#27) and wait-for-access (#168). |
| 5 | #271 | Catalog (analyzers) | Quit during a caption batch crashes: MLX token generation still running after shutdown drain starts (Metal validation abort) | Quit during a caption batch crashes (MLX generation outlives the shutdown drain). Release risk. |
| 6 | #261 | Catalog | ProcessRunner LineStreamer drops a whole stdout chunk when a read splits a multibyte UTF-8 character | ProcessRunner LineStreamer still decodes each chunk alone (ProcessRunner.swift:829-831): a split UTF-8 character drops whole lines, e.g. a DONE/OUTCOME line. |
| 7 | #189 | Archive / Storage | reresolveMasterArchiveMount() reads volume UUIDs on the main thread for every /Volumes entry | reresolveMasterArchiveMount still reads every /Volumes UUID on main (VideoScanModel+MasterArchive.swift:337-349): beachball on a hung share. |
| 8 | #273 | All tabs | Two main-thread SIGSEGVs in Swift runtime memory (Debug, 10/4) — suspected memory corruption / data race; needs ASan + TSan | Two main-thread SIGSEGVs, suspected data race. Umbrella for the 15 strict-concurrency trackers (all still reported 10-11). Sanitizer runs 10/4-10/11 found nothing (#310). |
| 9 | #256 | Tests | Settings-pollution: test hosts write to the REAL repo .trash (5,301 POI-* dirs, 9.7 GB) and read real validation labels; BundleImporter trashTarget per-second stamp collides | Test hosts still write to the real .trash (POIStorage.trashDir) and BundleImporter stamps to the second (BundleImporter.swift:805). Umbrella for #222; #193 is its duplicate. |

### 2. Identify, date, repair

| Rank | # | Tab | Title | Why it still matters |
|---:|---|---|---|---|
| 1 | #118 | Catalog (dates) | Date plausibility gate: demote transfer dates on digitized tapes (2026-on-a-VHS case) | Copy dates still masquerade as filming dates; the archive files by this date. Umbrella for #232 (reproduced resolver bug) and #209. |
| 2 | #121 | Triage > Repair... | MFO output-location symmetry: combine/Find Matching Audio defaults to in-place beside source, folder becomes override | Repair... one engine (audit 2d). Umbrella for #119, #130, #138, #141, #142, #192. |
| 3 | #133 | People | People column and person tags are not reliable | People column / tags not reliable (High Priority); also takes the Yes/No 'Maybe' triage left from #272. |
| 4 | #84 | People | Merge People: combine two POI profiles into one | Merge two People profiles: still no way to do it (no merge action in People/). |
| 5 | #309 | Verify / Repair... | Verify: check A/V sync on improved versions (Topaz etc.) | A/V sync check for improved versions (cloud brief C08 written today, 75a279c10). |
| 6 | #188 | Ask Hallie Mae | CyberBrain: one invalid source locator disables the whole brain; the writer does not validate what the loader refuses | One bad CyberBrain source locator still disables the whole brain; the writer does not run the loader's validateRelativePath (CyberBrainLoader.swift:55, :330 only). |
| 7 | #185 | Ask Hallie Mae | Hallie live replay 2026-09-13 observations: royalty/title unflagged false negative, count follow-ups, 'longest video in the archive', correction turns, bare 'show me' | Hallie misses umbrella (#184, #181); judge with the frozen eval suite. |

### 3. Archive the valuable

| Rank | # | Tab | Title | Why it still matters |
|---:|---|---|---|---|
| 1 | #294 | Archive | Archive identity drift: 17 already-archived files show 'Not Yet Archived'; 60 archive copies with vanished promote sources; stale manifest ids | 17 archived files show 'Not Yet Archived', 60 dangling lineage rows, stale manifest ids. Umbrella for #293. |
| 2 | #286 | Archive | Archive promote/refile hardening — 9 findings from cloud review C02 (no P1; 3×P2) | Promote/refile hardening, 3 x P2 (two promotes on one archive, torn index tail, incomplete backup marker). Umbrella for #248. |
| 3 | #249 | Storage / Archive | Off-site copy, done verifiably: 'Export critical set' to a drive (BagIt + checksums) and track which archive files have an off-site/cloud copy — target 2026-11-01 | Off-site copy, done verifiably, target 2026-11-01. |
| 4 | #223 | Archive | Verify Archive: playable, dated, correctly filed, locked, matches the index (report only) | Verify Archive: Rick reports archived files that do not play or lack audio. Umbrella for #224. |
| 5 | #280 | Archive / People | Access copies for archived originals: People tab plays them, the archive records them, the Angel offers them in bulk | Access copies for archived originals (People tab plays them; never promote one as a separate original). |
| 6 | #221 | Archive | Inspector date edit on an archived record should open Update… (keep folder/filename/manifest in step) | Inspector date edits on archived records bypass Update... Umbrella for #220. |
| 7 | #231 | Archive | Angel Checks: busy/readiness gates go stale across the fileExists await; FamilyArchive-volume siblings of the archive root are not excluded | Angel checks gates go stale across an await; FamilyArchive siblings of the root are not excluded (ArchiveAngel.swift:383 checks the root prefix only). Umbrella for #233. |
| 8 | #170 | Archive | Archive portability: family state lives on the archive volume; Adopt on a new Mac; first-run wizard for another family | Archive portability / adopt on a new Mac (High Priority, needed for the M5 Ultra move). The body is empty: needs Rick's paragraph. |

### 4. Delete excess

| Rank | # | Tab | Title | Why it still matters |
|---:|---|---|---|---|
| 1 | #143 | Triage > Cleanup | Tombstone durability follow-ups: identity-gate reapplication at reused paths; stop hard-pruning purged tombstones of deleted files | Umbrella for the one delete engine (E1) and one 'gone' shape: audit T1 (Retire trusts a false 'deleted' label), T3 (no only-copy warning on Cmd-Delete), T4, T5 (permanent unlink is the default). Members #240, #241, #268, #278. |
| 2 | #259 | Triage > Cleanup | Duplicate analysis over-claims: 408 'NOT a duplicate' refusals in one afternoon (same-size re-exports); the verdict is not remembered, so every run re-reads and re-refuses, and Reclaim numbers are inflated | Duplicate detector groups same-size re-exports; refusals are not remembered; Reclaim numbers overpromise. The primary goal's numbers are wrong until this lands. |

### 5. Clean workflows

| Rank | # | Tab | Title | Why it still matters |
|---:|---|---|---|---|
| 1 | #155 | All tabs | Catalog view: menu cleanup | Tab-charter cleanup umbrella: the audit's 26 misplaced features. Absorbs #126 and the Triage/steward successors of #196, #251, #257, #112. |
| 2 | #281 | Code health | HIGH PRI: tech debt — 40 functions over complexity 30, 10 over 50; the complexity guards were warn-only | CCN debt ratchet (nightly refactor). Umbrella for #228, #146. |
| 3 | #242 | MFO | Long operations that are not MFO jobs: FamilySearch pull/refresh, RescueFileCopier, Angel background sweep, Angel buffer Clear | Long operations that are not MFO jobs: FamilySearch pull (replaces the tree, 7-day timeout), RescueFileCopier, Angel sweep, Angel buffer Clear. |
| 4 | #195 | Analyze | Background activity must be visible: one surface listing every BG task (last run / next / outcome / toggle) + solid START/OUTCOME logging | One surface for background cyclers. Umbrella for #194. |
| 5 | #279 | Code health | Adversarial review 2026-10-05: five P3s (UI truth and logging) | Adversarial P3s (UI truth, logging). Umbrella for #269. |
| 6 | #246 | Nightly | Type-check timing ratchet trips on runner jitter (personCardEntry 340 → 505 → <500 ms vs 500 ms gate) | Nightly/CI tooling papercuts. Umbrella for #212, #247. |
| 7 | #262 | Tests | Source sensors check textual presence, not execution: #if false, unused closures, loops and literals can satisfy them | Source sensors prove presence, not execution. Umbrella for #245. |
| 8 | #140 | Tests | Integration ladder rungs 1–3: real-UI e2e tests (real-catalog launch, mkv transcript, rename-survival) | Integration ladder rungs 1-3 (real-UI e2e). Runs only in an interactive session (gauntlet). |
| 9 | #199 | Housekeeping | Log retention: nightly job prunes ~/Library/Logs/VideoScan (7 d test logs, 14 d audits/rotations, 30 d review scratch) into a dated _archive folder | Log retention is still manual (no prune script in scripts/ or tools/). Umbrella for #95. |
| 10 | #310 | Metrics | Metrics page: simplify to a few vital signs a person can read in 30 seconds | Metrics page: a few vital signs a person can read in 30 seconds. |

### The ten that matter most

1. #263 Possible real family data in a public test fixture (EventLabelerTests); ReclaimableCalculator counts every working copy; ContentView drops unknown viewFilters tokens: real family data in a public repo; an hour's fix.
2. #143 Tombstone durability follow-ups: identity-gate reapplication at reused paths; stop hard-pruning purged tombstones of deleted files: the primary goal (delete excess) runs through five trash engines; T1 lets a drive with an only copy be retired.
3. #164 Cancel mid-walk on a network root saves a partial-walk checkpoint as if complete: a cancelled network walk can resume as 'complete' and prune.
4. #167 Master Archive designation silently vanished from catalog.json (None designated; archive tree intact): the designation-loss fix is still on a branch.
5. #259 Duplicate analysis over-claims: 408 'NOT a duplicate' refusals in one afternoon (same-size re-exports); the verdict is not remembered, so every run re-reads and re-refuses, and Reclaim numbers are inflated: reclaim numbers and duplicate groups are wrong for re-exports.
6. #118 Date plausibility gate: demote transfer dates on digitized tapes (2026-on-a-VHS case): archive filing uses copy dates; #232 is a reproduced resolver bug.
7. #294 Archive identity drift: 17 already-archived files show 'Not Yet Archived'; 60 archive copies with vanished promote sources; stale manifest ids: archived files show as not archived; lineage dangles.
8. #286 Archive promote/refile hardening — 9 findings from cloud review C02 (no P1; 3×P2): three P2s on the promote path.
9. #249 Off-site copy, done verifiably: 'Export critical set' to a drive (BagIt + checksums) and track which archive files have an off-site/cloud copy — target 2026-11-01: off-site copy by 2026-11-01.
10. #121 MFO output-location symmetry: combine/Find Matching Audio defaults to in-place beside source, folder becomes override: Repair... one engine; carries the Combine Stop bug (#192) and the pre-start cancel hole (#142).

## PARK (keep the `idea` label)

| # | Title | Note |
|---|---|---|
| #6 | Explore training a custom face recognition model on family media | Custom face model research (with #22). |
| #42 | iOS/iPadOS port: browse and edit catalog on iPad | iPad companion. VideoScanCore (phase 0) exists; family web access (#244) may make it moot. |
| #127 | Catalog: open audio-only files in a user-selected audio editor | Open audio-only files in a chosen audio editor. |
| #148 | AdaFace follow-ups from QA review (post-#144) | Person-finder engine follow-ups umbrella (8 members). |
| #154 | Trim improvements: auto-detect non-blue span, typed time:frame entry, digit-wise arrow stepping | Trim improvements (auto-detect blue span, typed time:frame). Rick found Trim painful; revisit with Repair... (Improve, Nov-Dec). |
| #174 | Archive Angel: RAM scratch tier (Off/8/16/32 GB) — read the original once into RAM, run all steps from it | Archive Angel RAM scratch tier: measure on the M5 Ultra. |
| #213 | Archive: Misfiled filter + Catalog 'filed under X · dated Y' badge (deferred from Update…, 2026-09-27) | Archive Misfiled filter: 'only if Rick wants it after using Update...'. |
| #216 | Tree walk: interval inference for undated people (birth-year intervals to a fixpoint) | Tree walk ideas (with #215, #217). |
| #225 | idea: multi-signal file signature — same vs related footage | Multi-signal file signature: the segments design's FootageKey (docs/design/segments_and_content_coverage_2026_10_10.md section 3.3) may absorb it. |
| #236 | Story of the Day: 'Tell me a story' button + Hallie query built on Person of the Day | Story of the Day (with #237). Groundwork 7c14779e2. |
| #238 | Life & Times enrichment: who served in WWI, artists/writers vs labourers, lived through interesting times | Life & Times stages 2-3 (research queue). Stage 1 shipped 9ed39299e. |
| #243 | Research: screen DuckDuckGo web results like Wikipedia; nickname-aware name match (Ben↔Benjamin, Wm↔William, Polly↔Mary) | Research: DuckDuckGo screening + period nicknames. |
| #244 | Family web access: read-only Family Tree + People + Hallie + videos marked Public, for remote family | Family web access (auth and privacy gate before code). |
| #270 | Concurrency stress tester: Compare Footage + Hallie Q&A + captions at once, with memory red/green | Concurrency stress tester. The wedge that motivated it was fixed in 5fc5b7cf. |
| #299 | Improve (Nov–Dec): open restoration engines — QTGMC/VapourSynth, local upscale/interpolation, keep-frame-count rule | Improve (Nov-Dec): QTGMC, Real-ESRGAN, RIFE, keep-frame-count rule. |

## Close script (NOT run; Rick approves first)

Closes only the CLOSE set above, each with a comment naming the reason and the evidence. Dry run by default; pass `--apply` to write. Merges are not in the script: they need the umbrella bodies edited first.

```python
#!/usr/bin/env python3
"""Close the CLOSE set from docs/reviews/gh_issue_triage_2026_10_11.md.
Dry run unless --apply. Rick approves before --apply."""
import subprocess, sys

REPO = "musicalengineer/VideoScan"
DOC = "docs/reviews/gh_issue_triage_2026_10_11.md"

# (number, reason, duplicate_of, comment)
CLOSES = [
    (44, "completed", None, "Done. `PersonFinderCache` (People/PersonFinderCache.swift) caches per-video results keyed by engine/ref-hash; re-runs skip unchanged files."),
    (98, "completed", None, "Done. Copy Metadata (`InspectorPanel.formatAllMetadata`) now appends scene captions, transcript and OCR (InspectorPanel.swift:194-238)."),
    (102, "completed", None, "Done. 03fe3347d refactor(dossier): split runDossierBatch / runDossierBatchSerial into shared steps (#281)."),
    (105, "completed", None, "Done. Diagnosed: the 2 AM launchd session cannot enable UI automation; nightly skips VideoScanUITests (scripts/nightly_local_tests.sh:50-63, sensor kept). UI runs live in the gauntlet (tools/gauntlet, run_gauntlet.sh). Rungs 1-3 stay in #140."),
    (113, "completed", None, "Done. cc4562585 merge: preserve purge tombstones across rescans; `purgedAt` is in RescanPreservedFields (VideoScanModel+RescanPreservation.swift:159/345/446). Follow-ups live in #143."),
    (120, "completed", None, "Done. No Local/Network Volumes buttons left in the scan pane (git grep finds only the Settings label); Storage tab owns volume entry."),
    (129, "completed", None, "Done. 84304006b merge: stop pre-cancelled audio jobs before rendering. The sweep to the other job classes is #142 (merged into #121)."),
    (131, "completed", None, "Done. de2a641ee merge: fix Verify Audio follow-ups (#131). Sibling stale-instance writes are #141 (merged into #121)."),
    (134, "completed", None, "Done. Best-frame previews shipped: PreviewBestFramePlan / PreviewFrameScorer reject near-solid frames (Media/PreviewFrameScorer.swift:190), filmstrip plan, overnight preview cache; People rows use cached thumbnails (a3fb544d7). Confidence medium: Rick to confirm by eye."),
    (144, "completed", None, "Done. c38b8be2d merge: AdaFace plugin replaces dlib in Search, plus 6 codex follow-up commits. Remaining nits are in #148."),
    (150, "completed", None, "Done. 3e6598706 feat(mfo): real pause, SIGSTOP/SIGCONT via ProcessControl (GH #150); BalanceAudioJob.swift:340, CheckMediaJob.swift:38."),
    (156, "completed", None, "Done. 4602d943c feat(find-tag): wedged clips skip-and-continue + 9c414429f stall-latch reset (GH #156)."),
    (160, "completed", None, "Done. 7d1a99a1d fix(catalog): in-place purges announce a mutation so the cached table recomputes (#160). No further report since 08-15. The wider 'one gone shape' work is #143."),
    (161, "completed", None, "Done. Suspects fixed: 4b8b6bff0 (manifest.sha256 refresh off-main), 156be1a10 (no fsync per lock acquire). Prime suspect was the transient 81k-record catalog, since removed. A new beachball gets a new issue with a sample."),
    (162, "completed", None, "Done. 7b0f1c259 merge fix/162-preview-logging: [PREVIEW] reconcile logging, plan-based bytes-to-copy."),
    (166, "completed", None, "Done. 27967cc52 merge fix/166-content-date-outvotes-stamp (content evidence outvotes copy-era stamps, catalog sensor)."),
    (183, "completed", None, "Done. Close is no longer modal over a running promote (ArchiveAngelReviewSheet.swift:446-453, Rick 2026-09-20: the job lives in MFO; Close keeps the batch)."),
    (186, "completed", None, "Done. 85e95f007 fix(hallie): GH #186, a profile chip answers and the corrected question is answered."),
    (187, "completed", None, "Done. 64957f3b7 fix(hallie-voice): learned pronunciations are for names, common-word guards (GH #187)."),
    (191, "completed", None, "Done. d378c71b9 / 4b0c40793 merge fix/night-qa-pausegate: Stop on a paused PF job no longer leaks worker slots (#191)."),
    (198, "completed", None, "Done. d85ce8cd0 merge fix/fs-refresh-logging: audit-grade logging for Refresh from FamilySearch (GH #198)."),
    (208, "completed", None, "Done. 2f82780e7 merge #208 timing cap: TimingBudget.judge, strict when quiet and in the 2 AM nightly, known-issue under load (revisit with the Ultra)."),
    (227, "completed", None, "Done. Family map shipped: 05935bafa, a29d54034 (codex r3/r4), 4723c19bf (Western Europe). The scope in the issue (US states, England, Scotland, Wales, Ireland, Canada) is covered."),
    (229, "completed", None, "Done. 6b8e0834f merge feat/tree-card-flags + 5e3e51252 KISS follow-up (flag in the card header)."),
    (230, "completed", None, "Done. Record Finder covers the Irish sites as far as they allow: links + filing (RecordFinder+Registry.swift, ResearchRecordSources.swift, FamilyTreeDocumentsContext.swift), codex #18 fixes 793c2e9d1. Automated fetch is refused by the Irish state archives (403; FamilyTreeCards.swift:133-136). Rick's call: close, or re-file the automation wish as an `idea`."),
    (235, "completed", None, "Done. d1aee8c51 merge fix/235-own-name-rule-only (opener rules deleted, codex r4 F1 closed)."),
    (239, "completed", None, "Done. 80764f509 tools: nightly coverage run on the M4 at 04:00 (per-folder logic vs view %, zero-coverage files, coverage.log; tests/test_nightly_coverage.py)."),
    (260, "completed", None, "Done. 14aa9eb0b merge Footage Spectrum trial (Compare Footage MFO job + window). Per the tab charter it now lives in Triage > Events (audit row 19, tracked in #155)."),
    (272, "completed", None, "Done. a3fb544d7 feat(people): 'Videos of <person>' is the People tab's primary view (tiers, decades, 100k sensor), then e37f0a1d5 / a88d3abed. The Yes/No triage on 'Maybe' rows was not built; it belongs with #133."),
    (288, "completed", None, "Done. b83405e1e merge review/codex-batch-2026-10-07: prune device count (b6fa28fd9) and Angel quit-recovery fixes (5eb56e31b, 0f2f12c86, 096e3b40a)."),
    (307, "completed", None, "Done. d8aac4c98 fix(family-tree): catalog publishes no longer rebuild the tree's cards and open right-click menus (#307), on main."),
    (36, "not planned", None, "Obsolete. There is no RT Scan window any more (no such Window in VideoScanApp.swift); scan progress lives in Storage / Dashboard, and long work is MFO (CLAUDE.md, Long operations)."),
    (71, "not planned", None, "Obsolete. Person Finder throughput benchmark from May. PersonFinder was demoted on 2026-09-26 and the People tab now leads with known videos (#272). Perf baselines exist (memory: perf baseline, I/O bound)."),
    (81, "not planned", None, "Obsolete. Crash of 2026-05-08 in FamilyTreeDemoView photo rendering; that view no longer exists (git grep: 0 hits) and no recurrence was reported."),
    (82, "not planned", None, "Obsolete. Resume Person Finder searches across restart: live drive search was demoted (9/26 ruling, #272 'Search the drives' at the bottom)."),
    (83, "not planned", None, "Obsolete. RAM pre-staging slider for Person Finder scans: same demotion; the Angel RAM tier idea is #174."),
    (92, "not planned", None, "Obsolete. Dossier fleet: the deltas on CrucialX9/dossier-deltas were last written 2026-06-10 and no worker runs; dossier work now runs in-app (CaptionOrchestrator, Analyze panel). The deltas are merged into catalog.json and its backups."),
    (94, "not planned", None, "Obsolete. Merger heartbeat for the dossier fleet: same reason as #92 (merge_dossier_jsonl.py last changed 08-15; no merger running)."),
    (96, "not planned", None, "Obsolete. Dossier fleet 'Participating Computers' panel: same reason as #92; background visibility is #195."),
    (97, "not planned", None, "Obsolete. Dossier fleet 'Resume Sweep' button: same reason as #92."),
    (110, "not planned", None, "Obsolete. Root cause was LACIE500 mount-flapping hardware (diskutil-confirmed); the volume list has since been rebuilt as the Storage tab (VolumesWindow). Re-file with a sample if rows churn again."),
    (112, "not planned", None, "Obsolete. Set-aside browser polish for Tidy Catalog. Per the tab charter Tidy moves to Triage > Cleanup (audit row 14); design Cleanup there instead (#155)."),
    (122, "not planned", None, "Obsolete. find_donna_scan self-staging: the overnight Person Finder batch driver; superseded by the 9/26 demotion and the People tab's known-videos view."),
    (157, "not planned", None, "Obsolete. Find & Tag throughput (decode-ahead, multi-clip): Person Finder demoted 9/26; no live drive scans planned."),
    (196, "not planned", None, "Obsolete. 'Retire the Triage tab' was overruled by the tab charter (2026-10-11): Triage stays as a side lane (All Needing Triage, Events, Cleanup, Angel recommender)."),
    (251, "not planned", None, "Obsolete. Phase A shipped (b72e503ce), but its 'Delete Duplicates on the Storage tab' is reversed by the tab charter: Storage does not decide deletes; delete moves to Triage > Cleanup (audit rows 1 and 22). Remaining placement work is in #155."),
    (257, "not planned", None, "Obsolete. Content steward trial shipped (93a8ede62, 49b8ab2f2). The charter now defines its successor: Triage > Cleanup and Triage > Events, with mockups before code (tab_charters.md, 'Next'). Tracked in #155."),
    (193, "duplicate", 256, "Duplicate of #256. Same bug as #256 item 2: POIStorage.trashDir is still the real ~/dev/VideoScan/.trash in a test host (POIStorage.swift:186-189)."),
]

def main() -> int:
    apply = "--apply" in sys.argv
    failures = 0
    for number, reason, dup_of, comment in CLOSES:
        body = f"{comment}\n\nTriage 2026-10-11, approved by Rick ({DOC})."
        cmd = ["gh", "issue", "close", str(number), "-R", REPO, "--comment", body]
        if dup_of is not None:
            cmd += ["--duplicate-of", str(dup_of)]
        else:
            cmd += ["--reason", reason]
        if not apply:
            print(f"DRY RUN #{number} [{reason}]: {comment[:90]}")
            continue
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            failures += 1
            print(f"FAILED #{number}: {r.stderr.strip()}")
        else:
            print(f"closed #{number} [{reason}]")
    print(f"{len(CLOSES)} issues, {failures} failures" + ("" if apply else " (dry run)"))
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
```
