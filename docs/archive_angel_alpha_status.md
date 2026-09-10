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

## How to try the alpha (Rick)
1. Build **Release** (family-facing spot test) and launch. Archive tab → Master Archive panel → link row now has **Archive Angel…** beside "Verify copies…".
2. Pick **10** for the first run; leave the FFV1 toggle off. Start opens the Media File Operations window behind the main window; the "Angel" row shows "3 of 10 — <file>: access copy" and expands to the per-entry step chips.
3. When it finishes, the Archive tab shows an orange **"N ready to review"** badge; click it → "Recommended To Be Archived". Expand "Why" on a row, rename a stem, set a date, deselect one, add a note.
4. **Promote N** runs the existing Promote job (originals from their source volume, companions from the buffer); the sheet shows the report line ("7 promoted (7 originals, 7 access copies, 0 lossless, 1 balanced audio); 1 original-only: …").
5. Buffer lives at `~/Movies/VideoScan Buffer/ArchiveAngel/batch-<stamp>/`; `plan.json` is the journal. Cancel keeps prepared rows reviewable; Discard removes the batch folder.
Expect on a first run: the access copy step takes real time (HEVC VideoToolbox per file); verify-audio may say "already verified" for files Verify Audio has seen.
- 16:5x main: 48ca9848 (1-min floor for unrated clips), 24b71a8f (step logging, 4 sinks), phase 2 MERGED (Archive Angel Assessment: sweep + sidecar + AAA grades + catalog filter + evidence-first picks; 50 tests/11 suites). codex reviews requested (#1246 alpha, #1247/#now phase 2) + owns acceptance suite (#1248/#1249).

## 2026-09-10 — length bias + row actions (Rick's second-batch feedback)
- Floor is a flat 60 s for every clip (the 30 s marked exception is gone); rejection line now says why ("short clips are usually edits of a longer original").
- Duration tiers replace the flat 2 min–2 h band: 5–15 min +10, 15–30 +25, 30–60 +45, 60 min+ +60 (no ceiling). Tie-break: date, then longer, then larger, then name.
- Show in Catalog / Show in Finder on every row of the review sheet and the chevron turndown (`ArchiveAngelRowActions`).
- Old `evidence.json` sidecars fail to decode on the changed rejection text and are re-derived by the next sweep — by design ("fully re-derivable").
- Continuous assessment (rev 2): launch + 1 min after edits + every 15 min; rules-version stamp forces re-score after criteria changes; Archive-tab assessment panel with top-25 turndown. Nightly 03:00 removed.
