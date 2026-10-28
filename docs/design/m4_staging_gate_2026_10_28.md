# The M4 staging gate — design

*2026-10-28. Rick: "yes" (write the design). Implements the 2026-10-26 ruling in
`docs/DECISIONS.md`: "The M4 is the staging gate before GitHub." Review
before anything is built.*

## In one sentence

Every commit that leaves the Ultra is tested on the M4, automatically and in
depth, on that exact commit, and nothing reaches GitHub without a green
verdict and Rick's word.

## Why now

- GitHub's runners cannot build or test the app (no Xcode 27 / Apple silicon
  fleet image), so GitHub stays lint, static analysis and metrics
  (DECISIONS 2026-07-25).
- Today the M4 sees a commit only at the 02:00 nightly. A red found at 05:00
  is eight hours old and mixed with everything merged that day.
- The Ultra move is done; both Macs sign with "VideoScan Local"; tests no
  longer touch real volumes (the 2026-10-28 privacy-prompt hangs). The M4 is
  free all day.

## What changes for Rick

Nothing in how he works. Today I sync main to the M4 by hand after each merge;
that same push now starts the gate. The morning digest and the metrics page
gain one line: the newest green commit and the newest red one, with counts.
GitHub is pushed only when Rick says "happy" (standing rule), and then it
pushes the newest *green* main, never an untested one.

## Shape

```
Ultra (rapid-dev: work on main)          M4 (headless, always logged in)
──────────────────────────────          ──────────────────────────────────────
git push m4 main:staging   ──TB bridge──▶ ~/git/VideoScan.git  (bare)
                                            post-receive: write queue/<sha>  (≤1 s, no build)
                                          launchd agent com.videoscan.gate
                                            WatchPaths queue/ → scripts/staging_gate.sh
                                              worktree ~/gate/work @ <sha>
                                              DerivedData ~/Library/Caches/videoscan-gate-dd
                                              stages 0–4 (below)
                                            verdict → ~/Library/Logs/VideoScan/gate/<sha>.json
                                            green  → refs/gate/green (ff-only), bare main ff-only
Ultra: scripts/gate_status.sh  ◀──ssh──── reads the newest verdicts
Rick says "happy" → scripts/publish_main.sh pushes the newest green main to origin
```

- **One code path.** The gate reuses the nightly's pieces: the machine-setup
  preflight, `run_sensors.sh`, the suite runners and the process-group
  watchdog (which now samples the whole process tree). No second test
  harness.
- **The hook never builds.** `post-receive` only writes a queue file, so a
  push returns in a second whatever the gate is doing.
- **Latest wins.** One run at a time. A newer push replaces anything queued
  but not started; a running gate finishes (its verdict still matters for its
  commit).
- **The nightly outranks the gate.** The gate takes the nightly's lock (added
  if the nightly lacks one) and waits; it never starts between 01:45 and the
  nightly's end.
- **Ad-hoc signing in the gate**, like the nightly: tests need no privacy
  grants, and a launchd job must never wait for a click.

## Stages and budget (first cut; tune by measurement)

| # | Stage | Reuses | Budget | Red when |
|---|---|---|---|---|
| 0 | Preflight: Xcode first-launch, automation mode, disk space, toolchain changed → wipe DerivedData | nightly machine-setup checks | 1 min | `machine-setup:<what>`: the Mac, not the code |
| 1 | Sensors | `run_sensors.sh` | 3 min | any failure, warning ratchet, or no count |
| 2 | Full Debug suites: app (≈12,400) + Core (≈1,740), `.scale` tests serial | nightly suite lanes | 35 min | any failure, or a lane that prints no number |
| 3 | Tooling: python tests, gauntlet `inventory.swift --validate`, manifest floor | existing commands | 3 min | any failure |
| 4 | Hallie strict lane (67) | `nightly_hallie_replay.sh --strict-only` | 5 min | any strict defect |

Total ≈ 45 min. Rule 9 holds: a zero-test lane is red, a lane that prints no
number is red. Later stages (separate designs): the real-media testbed SSD and
overnight UI runs (BACKLOG, 2026-10-28).

## Verdict

One JSON per commit: SHA, the tree it ran, stage-by-stage status with
counts and times, the first failure's name and log path, and the machine
facts (macOS, Xcode, model digest). Green moves `refs/gate/green` forward
(fast-forward only; a non-ancestor is refused, never forced). Red changes
nothing on main.

**In rapid-dev mode a red is loud but not blocking:** it shows on the
next `gate_status.sh`, in the digest and on the page, and the rule "red is
fixed now" applies. In staging mode (when Rick switches us to it) a red
commit cannot be promoted.

## Failure modes

| What | What the gate does |
|---|---|
| M4 asleep / off / bridge down | the push fails on the Ultra, which says so; retry over the `.local` name |
| Xcode updated, needs first launch | stage 0 red `machine-setup:xcode-first-launch` (today's 10/28 M4 failure) |
| A test hangs | the watchdog samples the stuck tree, kills it at the stage budget, red with the stack |
| A privacy prompt appears | cannot wait for a click: watchdog red, and the sample names the call |
| Disk full | stage 0 red before building |
| Nightly running | waits for its lock; queued commit runs after |
| Stale DerivedData after a toolchain change | stage 0 wipes it |
| Two pushes in a minute | the first runs, the second replaces anything queued |

## Tests for the gate itself (red first)

`tests/test_staging_gate.py`, driving the gate script with stub stages:
latest-wins queueing; ff-only promotion refuses a non-ancestor; a zero-count
lane is red; a stage over budget is red with the watchdog's sample; the
nightly lock defers the gate; the verdict JSON is complete for every outcome
(green, red, machine-setup, incomplete).

## Phases

- **A.** Bare repo, hook, launchd agent, stages 0–1, verdict file,
  `gate_status.sh`. My hand sync becomes `git push m4 main:staging`.
- **B.** Stages 2–4, the digest and page line.
- **C.** `refs/gate/green`, `publish_main.sh` (pushes the newest green main on
  Rick's word).
- **D.** The real-media testbed and UI runs as further stages (their own
  designs).

## For Rick to decide

1. **Budget:** about 45 minutes per commit. Fine, or sensors-only per commit
   with the full suites batched (newest commit every 2 hours)?
2. **Where a red reaches you during the day:** the digest and page only, or
   also a notification on the Ultra?
3. **When we leave rapid-dev mode** for staging mode (red blocks promotion):
   now, or after phase B has run green for a week?
