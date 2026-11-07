# Status — rewritten, never appended

*Updated 2026-11-06 (Friday ~17:15). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
0. **How work moves now (PROCESS §2 item 1, Rick 2026-11-06).** Rick works on and spot-tests `main` only. A feature merges
   to `main` WITHOUT waiting to be asked once its checklist, its own tests, the touched suites and the sensor lane are
   green — as ONE `--no-ff` merge commit (undo: `git revert -m 1 <merge>`) — then its branch, worktree and DerivedData
   are deleted. Data-risk code (CLAUDE.md rule 10) still gets its Codex pass first. Run testbed scripts from an
   up-to-date worktree of `main`, never from Rick's checkout (it lags; on 11/06 an old `m4_run.sh` ran from it).
1. **The testbed schedule (DECISIONS 2026-11-05).** M5 Ultra 02:00 nightly suite; M4 14:00 the FULL testbed (suite, then
   the deep gauntlet, both published, then a "done" line in `~/Library/Logs/VideoScan/testbed_latest.txt` on the M4 and
   an `osascript` notification to the Ultra — the notification does not show; Rick to check Notifications settings).
   M4 04:30 Swift 6 analysis lane installed 11/06. Both runs test `main` from GitHub, never a checkout.
2. **11/06's first 14:00 run was RED, all causes fixed and merged the same day:** the gauntlet's new `swift test list`
   cross-check compared an unfiltered listing with filtered runs (`9fd8afb6d`; M4 re-run AMBER 16:58); a red test
   pinning a helper-status race sat on `main` since 11/04 (`d67a5686c`); two production-shape tests encoded a one-time
   catalog state (`a27aab8d7`); the gauntlet inventory went invalid after the metrics merges (`0f3421c6c`). Metrics page
   stale cards fixed (`48f73c291` CI history stream, `7a7355737` Codex count reads the archive, `44b8daffe` summary
   rebuilt after the 14:00 run). Expect AMBER tonight and tomorrow (7 known issues, 880 unadapted suites, ui not run).
3. **Merged 11/05–11/06 for Rick's spot test (Release):** Realtime Content Analysis viewer (`ae1d2c653`; Content
   Analysis ▸ Realtime…, or right-click an Analyze row in MFO), the Realtime Catalog Scan tiles (Not media / Gone / Not
   accessible / Failed = Errors; `a5674d9dd`), the file dossier view, the Results sheet, the Whisper red/green smoke.
   Reports and mockups: `~/dev/VideoScan/.scratch/kept-2026-11-06/`.
   **Overnight 11/06→07 (experiment, streamlined process):** the **Observations window** — Content Analysis ▸
   Observations…, the Realtime window's "See what we learned" after a pass, or right-click rows ▸ Observations…: what the
   machine found across many files in three chevrons (Technical · Patterns & events · Across the collection), one search
   over every observation (captions, transcripts, on-screen text, eras, people found, events, format readings), a filter
   per tier, hits open the file or its dossier. Machine observations only — never a file name, note or tag (Rick 11/06).
   Design: `docs/design/file_dossier_view.md` Part II (the embedding search and SigLIP 2 frame search are designed there,
   not built). Report and mockups: the night-shift worktree's `.scratch/reports/observations-2026-11-07.md`.
4. **Catalog went red for ~3 min at 17:02 (#441):** Update runs the catalog check BEFORE Detect Duplicates, so 262
   sampled-hash groups whose members now have different full hashes (revealed by #434's re-hashing) turned the chip
   Unhealthy until the next check; Detect Duplicates had already fixed them a second later. Fix: verify last.

## Next (in order)
1. **#441** Update's verify runs last (red test: an Update that leaves a clean catalog never goes red).
2. **#434** rescans throw away known whole-file hashes and re-hash unchanged files (TB per rescan). Catalog writer →
   rule 8 writer tests + production-shape test on a `.backup` + Codex pass before merge.
3. **C → B module lift using Rick's Anthropic Console API credits** (Rick 2026-11-06; ~$197 left; key in Keychain
   item `anthropic-api-key`, no dedicated key wanted). A module with any function over CCN 30 is capped at C
   (docs/index.html GRADE.capAtC); 15 functions hold 8 modules at C (list: `ci/baselines/complexity_debt.json`, ccn > 30;
   check each module's other sub-grades before promising B). Build `scripts/claude_api_session.sh`: reads the key from
   the Keychain, sets `ANTHROPIC_API_KEY`, opens a `claude` session on a brief (billed to the Console, usable when the
   plan's Fable/Claude run out Wed/Thu). One function per merge: characterization tests first, split to ≤ 25, same tests
   green. Non-data-risk first: InspectorPanel.formatAllMetadata, CatalogContent.previewPlayer, FindTagCLI.run,
   TreeIdentityDeriver.deriveWithResolvedPointerPins, GedcomFamilyGraph.applyingFactOverlay, BirthplaceUnitResolver
   Scan.apply. Data-risk later with safety-critical + Codex: ArchiveAngel ×5, ArchiveVolumeProtection.make,
   DeleteDuplicatesJob.finishRun, runRelocate, POIStorage.migrateToUUIDFoldersIfNeeded.
4. **`tools/claude_review.py`**: a fresh-context reviewer on the same API key, twin of `tools/codex_review.py` (same brief
   and output contract), code and diffs only (rule 13), per-review cost cap and running total, reuses
   `scripts/hallie_e1/costs.py` prices. Batch API for overnight reviews.
5. Issues from 11/06: #435 (cancelled probe shows Failed; vanished extensionless file audited wrong), #436 (gauntlet
   Python adapter — four script regressions stay blocked), #439 (nightly calls expectation failures "crashed"),
   #440 (M4: `scriptedSessionsMatchTheirRecordedSnapshots` failed).
6. Carried: the worker records its exit signal (jetsam must not count as a try); `CaptionRunnerError` on Avid MXF;
   #418; #413, #412, #408.

## Waiting on Rick
- **Realtime viewer questions:** (1) should Stop confirm first? (2) helper counts: today, last 24 h, or since start?
- **"Gone" tile wording/icon** (Realtime Catalog Scan).
- **Notifications:** allow Script Editor notifications on the Ultra, or pick another route for the 14:00 done line.
- Carried: the "Does it settle?" checklist line; #415; M4 `OLLAMA_HOST`; whether `run_catalog_tests.sh` follows the
  AMBER rule; #327's two rulings; #332.

## Ideas parked (BACKLOG)
- Layer 3's north star (Rick 2026-11-06): the Rick & Donna Breen family's story told by evidence, answerable by plain
  questions; prerequisites are people on footage, events with dates, speaker identity.
- Living family in the Family Tree view (sons, siblings) from a local-only store, behind a "show children/siblings"
  chevron — needs a schema addition and Rick's approval.

## Dates
- Mid-November: grade B or better in every module (the C → B lift above). 2026-12 soft / 2027-01 target: Public view
  link for family (Charter §5).
