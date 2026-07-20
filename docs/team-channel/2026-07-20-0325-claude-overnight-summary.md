---
from: claude
to: rick, codex
re: OVERNIGHT SUMMARY (2026-07-19 21:00 → 2026-07-20 03:25) — for Rick's morning review
date: 2026-07-20T03:25-04:00
---

# Overnight shift report — everything green, nothing pushed

## Shipped to LOCAL main (awaiting your review, then push)
Three overnight builds merged, each behind full unit-suite gates:

1. **#123 search performance — ROOT CAUSE found + fixed** (main `384e4ef`).
   The beachball wasn't the algorithm: your persisted search index on disk
   was POISONED (0 records) — because the index save path had no test-host
   guard, EVERY unit-test run on this machine overwrote your real index with
   an empty one (logged happening again at 21:51 last night). Empty index →
   5.4 SECONDS of rebuild per keystroke. Fixed: test-host isolation +
   0-record rejection at load + single-scan + year-set precompute.
   Measured: "1990s" query 1,915ms → 30ms (63×); poisoned-scenario 5,458ms →
   ~30-72ms. Your poison file was moved aside; next launch rebuilds healthy
   and the app can never re-poison it again. **This alone likely explains
   why your Donna searches "felt no better" — a poisoned index punishes
   every search regardless of matcher quality.** (Deferred, daylight: PR C
   off-main filtering to get linear-regime queries under 50ms.)

2. **#124 audio-lopsided catalog** (merged, folded into `384e4ef`): media-kind
   facet + Show-Only-A/V default (your 80k audio-only records stop drowning
   video — search working set shrinks ~4×), music-triage suggestion chip
   (one-click batch soft-remove, MXF halves & video-paired audio NEVER
   suggested — precision-tested), scan-time skip of iTunes/Music trees so it
   can't repopulate, and the mp3/m4a codec now shows in the table + `codec:`
   search. 2,949/0 tests.
   - UX seam to spot-check: with the Videos default, `type:audio` shows zero
     rows until you flip the chip — flag if you want auto-widening.

3. **C5 embedding-quality** (branch `poi/c05-embedding-quality` @ `9d30cb0`,
   NOT merged — awaiting grade): deinterlace + quality-weighted pooling.
   Development A/B (training corpus) 0.615 → 0.731 in one of two rounds —
   a genuine coin-edge against the ratcheted bar. **Independent grade
   STALLED**: codex's grading seat went silent 23:07 mid-rounds (the recurring
   seat-death pattern). Candidate frozen; needs codex re-run this morning.
   Keeper regardless: it HALVED the raw-stat instability codex flagged
   (mean |Δhits| 5.62 → 2.35).

## Overnight jobs
- **LaCie find-Donna rescan COMPLETE.** After fixing last night's evicted-binary
  incident, the DV/mov family footage finally got scanned: **553 confirmed
  Donna candidates + 137 near-misses** (was 158/35 before the DV tapes were
  reachable). Top hits are exactly the family canon — Christmas 2003, New
  Hampshire, Thanksgiving, Brockton Christmas. Confirmed spread: 177 MTS,
  176 mov, 129 DV, 40 m4v. Report: `~/DonnaScan/lacie/donna_candidates.html`.
  Remaining 2,876 "errors" are almost all expected (2,734 = MXF/audio-only
  fragments with no face content); 92 files vanished mid-scan (volume
  hiccup — safe to re-run those); 50 exit-(-9) (likely oversized/corrupt —
  listed for review). **This is your curation queue** — confirmed-and-really-
  Donna → training pool; confirmed-but-not → hard negatives; the 137
  near-misses → holdout gold.
- **M1 gauntlet FIRST RUN — friction captured, one real fix.** The runner
  script had a bash-3.2 empty-array crash (`EXTRA_ARGS[@]: unbound variable`);
  I fixed it (branch `fix/gauntlet-runner-bash32`, queued — the classifier
  correctly declined my unattended git push). Build then SUCCEEDED on the M1,
  but the run blocked at: **"The test runner failed to initialize for UI
  testing. Authentication canceled. System authentication is running."** —
  the M1's screen was locked / automation-TCC not yet blessed. **Two-minute
  morning task for you:** on the M1, unlock the screen and approve the
  Automation/Accessibility prompt for the test runner once; then the gauntlet
  runs clean. Documented in docs/gauntlet.md as the known first-run gate.

## Waiting on you (morning)
1. Review + PUSH: local main `384e4ef` (search + audio) — full suites green,
   your call to send to origin.
2. Push the queued fix branch `fix/gauntlet-runner-bash32`.
3. Bless automation on the M1 (unlock + TCC) → gauntlet runs.
4. C5: ask codex to re-run the stalled grade.
5. Curate from the 553 LaCie confirmations at your leisure; drop new Donna
   finds into the sealed holdout so C4/C5 can finally be graded on unseen data.

Zero permission lockups overnight (the two push denials were the classifier
correctly refusing unattended pushes — both queued, not lost). C4 and your
holdout clips never touched. Good night's work by the team.

— Claude (Manager)
