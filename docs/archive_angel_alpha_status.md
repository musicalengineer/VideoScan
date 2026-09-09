# Archive Angel — alpha status (2026-09-09, target 16:00 ET)

Branch: `feature/archive-angel-alpha`. Design: `docs/archive_angel_design.md`.
Rick 9/09 12:20: "alpha version by 4:00pm"; AMPAS/LOC practice; FFV1 optional
(off by default for speed, later pass); codex only for serious issues.

## Alpha scope (what ships today)
1. `ArchiveAngelScorer` — pure core: eligibility, hard floor, evidence lines, selection. Tests: logic + 100k scale.
2. `ArchiveAngelPlan` + store — batch `plan.json` (atomic), buffer under `~/Movies/VideoScan Buffer/ArchiveAngel/`.
3. `.archiveAngel` MFO job — candidate walk (off-main), preparation per candidate: verify audio → balanced audio (only on a problem) → access copy (always) → lossless (only if enabled AND format at risk); resumable; free-space stop.
4. Review sheet "Recommended To Be Archived" — rows with why-lines, companion chips, rename, deselect, notes; Promote → existing Promote job for originals + companions; report.
5. Archive tab entry point: "Archive Angel…" (count picker 10/25/35/50, lossless toggle) + "N ready to review" badge.

## Deferred (not in alpha)
- Refile (rename/redate existing archive files) — design §7, slice 0 → next.
- Final-approval badge, Hallie "waiting for approval" answer.
- In-app playCount fields (Spotlight use count is read at score time instead).
- Overnight time-budget stop (count is the only stop rule in alpha).

## Progress log
- 12:28 branch created; API map (Explore) running; scorer + tests written; plan model written.
- 12:36 9c03b87d scorer suites green (14 tests, incl. 100k scale).
- 12:45 API map done (MFO job pattern, Promote needs catalog IDs → companions are catalogued by Transcode/Balance jobs, startTranscode takes an outputURL, Balance takes plannedOutput). Plan gained sourceContentHash/sourceModifiedAt (codex guardrail 1) and StepOutcome.recordID.
- 12:50 two forks dispatched: A = ArchiveAngelJob (walk + preparation + journal + MFO detail), B = start sheet + Archive-tab entry + review sheet + ArchiveAngelPromoter (identity re-check → buildPromotePlan → startPromote → report). Rick 12:20: AMPAS/LOC practice; FFV1 optional, off by default.
- 13:00 1d923efe: both forks integrated; 32 tests / 6 suites green in one derivedData; codex checkpoint (a)+(b) posted (#1241). Full VideoScanTests target running for regression before merge.
- 13:30 full VideoScanTests target on 1d923efe: 32/32 Angel tests green; 3 non-Angel failures, all pre-existing or environmental — ArchivistTranscriptRenderSensorTests.appendAndMutate… (row-rebuild sensor 17 vs 2, firing since 8/31 per memory + codex's CI baseline list), BalanceAudio real Clip 28.dv tests (60 s / 300 s time limits under a loaded M4), FamilyTreeLaunchBundleTests.prewarm… (63 s); run then stalled >15 min on MasterArchiveHardeningTests R5-B1 (viaBundle → true) with no output — stopped. Merge per 8/29 policy (focused suites green; full battery = nightly/codex M5).
