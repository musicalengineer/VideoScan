# The M4 deep-test host — design

*2026-10-28, revised the same evening. Rick: "yes" (write the design), then
"in rapid dev mode, we don't want to be waiting on M4 builds and gates": the
M4 runs on demand, not on every commit. Implements the 2026-10-26 ruling in
`docs/DECISIONS.md` ("The M4 is the staging gate before GitHub") in its
on-demand form. Review before anything is built.*

## In one sentence

When Rick says "push the last few hours to the M4 and run the gauntlet" (or
"run the UI automation on the M4"), that exact commit is tested on the M4 in
depth, without Rick leaving his desk, and the verdict comes back to the
Ultra.

## Why

- **Rapid dev stays fast.** Per-commit checking is the Ultra's job and
  already exists: `run_sensors.sh` (~70 s) plus the suites touched (rule 9).
  Nobody waits on the M4.
- **Batches get the deep pass.** After a run of changes, before a "happy"
  push to GitHub, or whenever P0/P1 risk feels high, the M4 runs the full
  gauntlet (≈45 min) while work continues on the Ultra.
- **UI automation finally runs.** XCUITest drives the real screen, so until
  now "run the gauntlet including UI" meant Rick giving up the M4 for an
  hour. The M4 is now headless and always logged in: its screen is free.
  The gauntlet's UI stage has been "not run (phase 2)" since 2026-09-27; this
  is phase 2.
- **GitHub can't do it.** Its runners have no Xcode 27 / Apple-silicon image
  (DECISIONS 2026-07-25).

## What Rick says, what happens

| Rick says | Ultra runs | M4 runs |
|---|---|---|
| "deep test on the M4" / "run the gauntlet" | `scripts/m4_run.sh deep` | `run_gauntlet.sh` all non-UI stages |
| "run the UI automation on the M4" | `scripts/m4_run.sh ui` | `run_gauntlet.sh --only ui` |
| "everything on the M4" | `scripts/m4_run.sh all` | deep, then UI |
| "how's the M4 run?" | `scripts/m4_run.sh status` | reads the verdict |

Default commit is the Ultra's `main` HEAD; `--ref <sha>` picks another. The
run reports the commit range it covers since the last green run, so "the
last couple of hours" is visible, not guessed.

## Shape

```
Ultra                                     M4 (headless, logged in at the console)
─────                                     ───────────────────────────────────────
scripts/m4_run.sh deep|ui|all
  git push m4 <sha>:refs/m4run/<sha> ──TB bridge──▶ ~/dev/VideoScan (existing clone)
  ssh: write ~/m4run/request.json  {sha, lane, asked_at}
  ssh: launchctl kickstart gui/<uid>/com.videoscan.m4run
                                          LaunchAgent (runs in the GUI session)
                                            scripts/m4_run_host.sh
                                              takes the nightly lock
                                              worktree ~/m4run/work @ <sha>
                                              DerivedData ~/Library/Caches/videoscan-m4run-dd
                                              run_gauntlet.sh --machine m4 [--only …]
                                            verdict → ~/Library/Logs/VideoScan/m4run/<sha>-<lane>.json
                                            green → refs/m4run/green (ff-only)
scripts/m4_run.sh status ◀──ssh── reads the newest verdict
```

- **One engine.** The M4 runs the existing `run_gauntlet.sh` (one Release
  build-for-testing, serial stages, structured counts, process-group
  watchdog, manifest floors). No second harness. `m4_run_host.sh` is a thin
  wrapper: lock, worktree, call the gauntlet, write the verdict.
- **Why a LaunchAgent, not plain ssh.** A job started over ssh has no window
  server and a locked keychain (the 10/28 `errSecInternalComponent`). UI tests
  need the window server. An agent kicked in the GUI session has both.
- **One run at a time.** A second request while one is running is refused
  with what is running, since when, and its stage. No queue to reason about.
- **The nightly and an on-demand run share one lock.** Whoever holds it
  finishes; the other waits. A run asked for after 01:30 is refused with
  "the nightly starts at 02:00".
- **Ad-hoc signing** for the build, like the nightly. UI tests still need one
  grant (below).
- **Test fixtures only.** The UI suites run against the gauntlet fixtures
  and a temp catalog, never the M4's App Support catalog or a real volume
  (the 2026-10-28 test-host guard, extended to the UI runner).

## UI lane — one-time setup on the M4 (needs a person at the screen once)

1. Accessibility + Automation for the XCUITest runner (`run_ui_smoke.sh`
   exit 3 names it). Prove with `run_ui_smoke.sh` from the agent.
2. Screen never locks or sleeps the display while a run holds the lock
   (`caffeinate -dimsu`, already in the gauntlet).
3. A modal from anything else (Software Update, a privacy prompt) fails the
   run as `machine-setup:<what>` with a screenshot, never hangs.

Then the UI stage is adapted from "blocked" in `scripts/gauntlet/manifest.json`
suite by suite: Smoke first, then Gauntlet01–05, CatalogKeyboard, Combine.

## Verdict

One JSON per run: SHA, lane, commit range since the last green, stage-by-stage
status with counts and times, the first failure's name and log/xcresult path,
UI screenshots on failure, and the machine facts (macOS, Xcode). Green moves
`refs/m4run/green` forward (fast-forward only; a non-ancestor is refused,
never forced). Red changes nothing on main; "red is fixed now" applies.

`scripts/publish_main.sh` (on Rick's "happy") prints the newest green commit
and what main has on top of it, then pushes main. It does not block: a stale
or missing deep run is shown, and Rick decides.

## Failure modes

| What | What happens |
|---|---|
| M4 asleep / bridge down | the push fails on the Ultra, which says so; retry over `.local` |
| Run already in progress / nightly window | refused, says what and until when |
| Xcode updated, needs first launch | `machine-setup:xcode-first-launch` (the 10/28 M4 failure) |
| A test hangs | watchdog samples the tree, kills at the stage budget, red with the stack |
| A modal / privacy prompt | cannot wait for a click: red with screenshot + sample |
| Disk full / stale DerivedData after a toolchain change | preflight red / wipe |

## Tests (red first)

`tests/test_m4_run.py`, stub gauntlet: busy refusal; nightly-window refusal;
ff-only promotion refuses a non-ancestor; a zero-count stage is red; the
verdict is complete for every outcome (green, red, machine-setup, incomplete);
the commit range is right.

## Phases

- **A.** `m4_run.sh deep|status`, the LaunchAgent, `m4_run_host.sh`, the
  shared lock, verdict file. My hand sync stays as is.
- **B.** UI lane: the one-time grants, Smoke through the agent, then the UI
  suites adapted one by one.
- **C.** `refs/m4run/green` and `publish_main.sh`.
- **Later, only if wanted:** an automatic trigger (e.g. every N merges), the
  real-media testbed SSD (BACKLOG 2026-10-28).

## Cut from the first draft

Per-commit trigger, the bare repo and post-receive queue, newest-wins
queueing, and promotion blocking. Each existed to gate every commit; on
demand doesn't need them.
