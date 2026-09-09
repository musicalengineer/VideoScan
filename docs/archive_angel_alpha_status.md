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
