# Operations — machines, storage, the deep-test host

*Rewritten in place. Consolidated 2026-11-01 from two machine notes in `guides/ops/` and the M4 deep-test host design; originals under `docs/archive/`. Who may use which machine when is a rule, in `docs/PROCESS.md` §8 (the M4 is the default testbed, 2026-10-31; the Ultra only in a declared window); machine names are in `CLAUDE.md`.*

The fleet: the **M5 Ultra** Mac Studio (`RicksUltra`, Rick's interactive machine since 2026-10-27/28), the **M4** Max Mac Studio (`RicksM4`, the headless deep-test host), the **M5 Pro** MacBook (`ricksm5.local`) and the **M1** MacBook Pro for overflow. This guide holds the operational facts that are not rules: how the deep-test host runs, how storage is laid out, how to check the Thunderbolt 5 link. The background helper's launchd job is in `docs/design/background_service.md`; where every App Support file lives, and what each catalog table holds, is in `docs/design/data_organization_2026_10_31.md`; backups of the catalog are `sqlite3 … ".backup"` only (CLAUDE.md), and the off-site copy plan is a STATUS date (2026-11-01).

## Contents
1. The M4 deep-test host (built 2026-10-28; what is still planned) · 1a. The real-data corpus on the M4 · 2. Storage layout (the facts that hold) · 3. Thunderbolt 5 link check

## 1. The M4 deep-test host

*Rewritten 2026-11-01 (Codex docs review F12) to separate what is built from what the 2026-10-28 design still plans.
The design, whole (why, the shape diagram, failure modes, phases, what was cut), is
`docs/archive/design/m4_staging_gate_2026_10_28.md`. Rule behind it: DECISIONS 2026-10-26 and 2026-10-28 — the M4 runs
deep and UI tests **on demand**, not on every commit; per-commit checking is the sensor lane on the Ultra.*

### Built: `scripts/m4_run.sh` (the header comment is the reference)

| Rick says | The Ultra runs | The host runs |
|---|---|---|
| "deep test on the M4" / "run the gauntlet" | `scripts/m4_run.sh deep` | `scripts/run_gauntlet.sh --away --machine m4 --queue-only` (all non-UI stages; off the metrics branch) |
| "run the UI tests on the M4" | `scripts/m4_run.sh ui [--only <UITestClass>[,…]]` | a Debug build-for-testing, then the VideoScan-UI (Smoke) and VideoScan-Gauntlet plans, each under a watchdog |
| "everything on the M4" | `scripts/m4_run.sh all` | deep, then ui (not the suite) |
| "run the full suite on the M4 for this branch" | `scripts/m4_run.sh suite --ref <rev> [--wait]` | the nightly's own runner, `nightly_local_tests.sh --on-demand`: machine preflight, Core (`swift test`, Release), Release build, the whole app suite; **nothing published** |
| "run the testbed on the M4 for this branch" | `scripts/m4_run.sh testbed --ref <rev> [--wait]` | the suite lane, then corpus `check`, then corpus `proof` (§1a), under ONE hold of the lock; one summary block, one verdict. M4 only |
| "… on the M5 Ultra" | add `--host ultra` | the same, in the Ultra's testbed worktree (never the testbed or corpus lanes) |
| "how's the M4 run?" | `scripts/m4_run.sh status [--json]` | reads `<root>/latest` back; `--json` is one object for machines |

What it does: resolves `--ref` (default `main`) to a commit; refuses if a run holds the host's lock or it is the
nightly window (01:30–06:00 host time; `--force` overrides) or the quiet window before the M4's 14:00 scheduled run
(below); on the M4 pushes `<sha>:refs/m4run/<sha>` (a new ref per
commit, never forced, never a branch); checks the host's testbed worktree out at the commit (detached; refuses a dirty
one); installs itself under `<root>/bin`; and starts a one-shot LaunchAgent in the host's GUI session (an ssh job has
no window server and a locked keychain). The host writes `<root>/out/<stamp>-<lane>/` (`run.log` with START/OUTCOME,
`summary.txt`, per-plan logs, `.xcresult`, `.tests.tsv`) and points `<root>/latest` at it. Roots: M4 `~/m4run`, Ultra
`~/ultrarun`; one Debug DerivedData per host (~15 GB). Builds are
ad-hoc signed; the UI suites run against the gauntlet fixtures and a temp catalog, never a real catalog or volume.
Tests: `tests/test_m4_run.py`, `tests/test_m4_run_deep_lane.py`, `tests/test_m4_run_suite_lane.py`.

**The suite lane** (2026-11-17, DECISIONS: the idle M4 is part of the merge workflow). One engine: the scheduled
run's script in a mode, installed per run beside `m4_run.sh` (the commit under test need not have it), pointed at the
testbed worktree. It writes its row to `<out>/suite-row.json` instead of the metrics branch and skips everything that
is not the verdict (fetch/pull, page summary, coverage, person/Hallie lanes, model smoke, complexity baseline, repo
traffic), so an on-demand run never changes the nightly tile. Own caches (`~/Library/Caches/videoscan-<root>-dd-suite/`
`{app,core}`, 6.9 GB on the M4) and own logs in `<out>` (`suite.log`, `suite-app-test.log`, `suite-core-test.log`,
`suite-app.xcresult`); the scheduled run's checkout, caches and `/tmp` files are untouched. Verdict
(`m4_run_summary.py --suite`): `suite: GREEN|RED <why> — app P passed, F failed, S skipped; core … (sha, seconds, log)`,
then one line per failed or crashed test with the file and line that declares it in the worktree (or `NOT FOUND`).
RED also when either lane has no number (zero app tests, zero Core tests). `OUTCOME NORUN` = the machine preflight
stopped it (automation mode, Xcode first launch, Metal toolchain): the machine, not the code. `status` shows the last
suite run even after a later ui/deep run (`<root>/latest-suite`). `--wait` exits 0 GREEN · 1 RED · 2 could not run
(refused on the host, NORUN, or the wait gave up); a run that never started exits 3 busy / 4 testbed / 5 window as
for the other lanes. Timing budgets are strict, as in the scheduled run. Measured on the M4, 2026-11-17, warm caches:
56 min (Core 16, Release build 10, app tests 30; 13,941 + 2,587 tests); the first run's cold builds add ~8 min.

**The testbed lane** (2026-11-18). `testbed` is the three lanes above run back to back by the same functions (no
second implementation), each judged on its own; a later lane still runs after an earlier RED. The summary opens with
one block, e.g.

```
testbed: AMBER at 5112b8697 — 3 lanes, wall 5400s
  suite         GREEN   3360s  app 13941 passed, 0 failed, 14 skipped; core 2587 passed, 0 failed, 0 skipped
  corpus check  AMBER    621s  234 files — probe: probed 208, unopenable 26 · check: … · audio: … · pair: …
                               against its accepted baseline <run> at <commit>: 2 of 234 files changed (new 0, absent 0)
                                 check: OK -> Problem x2
                                 3f9a1c0b7d2e check: OK -> Problem
  corpus proof  GREEN   1221s  8 files — balance: balanced 8 · proof: …
```

RED if any lane is RED, else NORUN if any lane could not run (the machine preflight; a ref with no engine for the
lane), else AMBER, else GREEN. `--wait` exits 0 only for GREEN or AMBER (1 RED · 2 NORUN / refused / the wait gave
up). `status` shows the last testbed run's block after a later run of another lane (`<root>/latest-testbed`). Each
corpus lane's files are in `<out>/corpus-<lane>/`. `verbs` (§1a) is not part of `testbed`; run it by itself.

**Housekeeping, the quiet window, `status --json`** (2026-11-18; `scripts/testbed_host.py`).
- *Prune.* Every lane, at its start and under the lock, removes old run folders from `<root>/out`: the newest 10 of
  each lane, every RED run and whatever `<root>/latest*` names stay, with their `bin/<stamp>` and agent plist. The
  corpus lanes do the same for `~/corpus/reports/<lane>/` (the newest 20, every RED run and the baseline stay) and
  remove work folders older than six hours that a dead run left.
- *The 50% floor* (DECISIONS 2026-11-18; `testbed_host.py clean`). A run uses as much disk as it needs. Once its
  verdict and summary are written, its scratch goes: xcresult bundles, overlays, patched test-run files; each log is
  cut to its last 200 lines under its own name; `run.log`, `summary.txt`, the verdict files and `*.tests.tsv` stay
  (a few KB; `tidy.txt` records it). The summary gets one line, e.g. `disk: free 52% after cleanup (lowest 38% during
  the run, 47% at the start; floor 50%) — removed 0.41 GB: this run 0.41 GB`. At the start and the end, under the
  lock: finished runs not yet tidied are tidied, `~/corpus/work/<stamp>-<lane>` folders removed, and the coverage
  lane's two caches (`videoscan-m4run-dd-coverage` 5.6 GB, `-dd-coverage-core` 1.3 GB: an opt-in lane, a cold build
  ~3 min, so scratch rather than warm) removed whatever the disk says; below 50% free,
  unfinished runs go oldest first, then `videoscan-<root>-dd-suite` and `-dd` — only when that reaches the floor
  (a cold build costs 10-25 min). M4 only (`<root>` must be `$HOME/m4run`). Every folder is opened from `$HOME` down
  with `O_NOFOLLOW` on the home volume, and every unlink, rename and write is relative to those descriptors (Codex
  #322: a name swapped for a link after a check cannot redirect anything; a mount is never entered); the only folders
  it holds are `~/m4run/out`, `~/corpus/work` and those four caches, each by its fixed name and only as a real folder. A `~/corpus` that is not a folder of its own, or
  a protected corpus name that is a link, stops the whole cleanup (the disk line says `cleanup refused`); a tree that
  cannot be scanned whole, or holds a protected folder by inode, is not touched.
  Never the corpus media, documents, reports, state or `live/`; no lock flag is ever cleared (a locked file stays and
  is counted); only one-name, unlocked files count as reclaimable; before every unlink, rename or write the folder is
  asked where it is now (`F_GETPATH`) and must still be inside those roots; a tree with a mount anywhere in it is
  refused whole; the stop marker and the disk line are written by the helper through the run folder descriptor;
  refused unless the lock names the run; 900 s budget. The scheduled jobs' caches (`videoscan-nightly-*`, `-analysis-dd`,
  `~/Library/Caches/VideoScan/*`) and `~/Library/Logs/VideoScan` are theirs, not this cleanup's.
- *The quiet window.* The M4's 14:00 scheduled run does **not** wait for the lock: `scripts/nightly_gauntlet.sh` runs
  its suite anyway and skips only its gauntlet, so a lane still running at 14:00 means two suites at once. A lane
  therefore refuses to START (exit 5; `--force` overrides) when the scheduled run begins within the lane's own
  expected length: testbed 120 min, all 90, suite 75, deep 60, corpus 45, ui 30.
- *`<root>/testbed.conf`* on the host (optional; `KEY=value`, never executed): `KEEP=10`, `SCHEDULED=1400` (HHMM, comma
  separated), `QUIET_MINUTES=90`.
- *What a caller reads back* (2026-11-18, Codex #315): a run folder is made NEW by the run (an existing one is refused,
  exit 4; `~/m4run` and `~/m4run/out` must not be symlinks); every log is opened without following a link and only
  with one name; a corpus lane's summary is copied into the run's summary only when the helper finished its lane, and
  `status` prints run files only through `testbed_host.py show` (no link, one name, lines that could carry a file name,
  a corpus path or a digest withheld). The caller passes `--start-by` (when the next window opens); the host refuses a
  run that reaches its lock after it. The watcher's runs pass `--unless-ran`: the host refuses (exit 6, `OUTCOME
  REFUSED already-run <verdict>`) a commit a run under `out/` already took to a verdict, checked under the lock.
- *Deletion receipts in the `verbs` lane:* Move to Trash and Delete Duplicates write their receipt where the engine
  chooses — under a test host the system temporary folder on the M4, outside the run — and take no folder for it. The
  lane records each receipt's place as a word and a count in the summary; it moves none and changes no engine.
- *`status --json`*: the lock (`idle` / `running` and the holder's words) and, for the last run, the last suite run
  and the last testbed run: lane, commit, START and OUTCOME times, verdict word, summary lines, a testbed run's lanes,
  and the push watcher's verdict line.

**The push trigger** (`scripts/m4_watch.py`; DECISIONS 2026-11-17: the suite runs on every push to `main`). *Built and
tested 2026-11-18; NOT installed on the M4 — installing a standing agent there is Rick's to do or to allow (the table
below is the whole of it).* One tick
every 300 s from a LaunchAgent in the M4's GUI session (`com.videoscan.m4watch`). A tick fetches `origin/main` into
its own ref (`refs/m4watch/main` in the M4's `~/dev/VideoScan`; no branch or worktree moves) and starts **at most
one** `m4_run.sh suite --host m4local --ref <sha>` for the newest commit — the same lane, lock and quiet window as a
run by hand, nothing published. It never runs a commit twice (its own verdicts, and any suite or testbed run under
`~/m4run/out` that reached GREEN / AMBER / RED), skips a range that is docs-only since the last commit it settled,
waits when the testbed is busy or inside a window, retries once a run that ended without an OUTCOME, and gives up
after three refused starts. `scripts/m4_run.sh status` shows `push watcher: <time> <commit> suite <VERDICT> — <the
suite line>` and the last tick; the files are `~/m4run/watch/{verdict.txt, tick.txt, history.log, state.json}`.

| | |
|---|---|
| Install / reinstall | `scripts/m4_watch_install.sh install` — a pinned copy of the scripts in `~/m4run/bin/watch` (the commit in `VERSION`; never run from a checkout), the plist in `~/Library/LaunchAgents/com.videoscan.m4watch.plist`, `launchctl bootstrap gui/<uid>` |
| Uninstall (rollback) | `scripts/m4_watch_install.sh uninstall` — boots the agent out and moves the plist to `~/m4run/watch/uninstalled/`; a run it started keeps going |
| Look | `scripts/m4_watch_install.sh status` |

It refuses any Mac but the M4. To update the pinned scripts after a change, install again.

**A logout of the host's GUI session stops a run** (any lane): launchd SIGTERMs the agent's shell, the app-hosted
test host dies mid-test, and no OUTCOME is written (2026-11-17, the first real suite run, 55 minutes in). `status` then
says `ENDED WITHOUT AN OUTCOME` and `--wait` exits (suite: 2) instead of polling out its budget. Do not log the M4's
console session out, or restart it, while `status` says RUNNING.

**One-time UI setup on a host** (a person at the screen once): Accessibility + Automation for the XCUITest runner; the
display never sleeps while a run holds the lock (`caffeinate -dimsu`, in the gauntlet); automation mode without a
password (testing.md §4).

### Planned, not built (the 10/28 design; BACKLOG "UI tests, next increment")

- **The verdict file:** one JSON per run (commit, lane, stage-by-stage status with counts and times, the first failure
  and its log/xcresult, UI screenshots on failure, macOS/Xcode facts) and the **commit range since the last green
  run**. Today the evidence is `run.log` + `summary.txt`.
- **`refs/m4run/green`** moved forward fast-forward only on a green run, and **`scripts/publish_main.sh`** (on Rick's
  "happy": the newest green commit and what main has on top of it; shows, never blocks).
- **Failure classes** `machine-setup:<what>` (Xcode first launch, a modal or privacy prompt, with a screenshot) instead
  of a generic red; the UI stage of `scripts/gauntlet/manifest.json` adapted from "blocked" suite by suite.
- The PROCESS.md wording for which merges wait for the M4's verdict (Rick reviews it). The real-media testbed SSD
  (BACKLOG).

### 1a. The real-data corpus on the M4 (`scripts/corpus_run.sh`; phase 1 built 2026-11-17, phase 2 2026-11-18, two roots 2026-11-19)

*Rules: DECISIONS 2026-11-17, "The M4 holds a real-data test corpus"; 2026-11-19, the corpus on the SSD and the
Crucial X10. The header comments of `scripts/corpus_run.py` and `scripts/corpus/CorpusDriverSupport.swift` are the
reference.*

**What it is.** A copy of real family media on the M4, on **two roots**, with the documents that describe it and a
`.backup` of the catalog, marked `THIS_IS_TEST_DATA.txt`. v1 (234 files, ~130 GB) was chosen by stratum (one-sided
sound, edit lists, Avid halves, codec/container combinations, …). v2 added every other distinct content of the live
catalog (6,351 files, ~1.96 TB: 6,096 on the **external** root, the Crucial X10; 255 on the **internal** root, the SSD).
From 2026-11-24 the corpus is a stratified **sample** of that (below: `scripts/corpus_select.py`), with a third root,
`ro`, for what fits neither drive. Automation runs the app's own engines across it and reports counts.

| Where, on the M4 | What |
|---|---|
| `~/corpus/media/Volumes/<VolumeName>/…` | the internal root's copies: v1 and v2's large files (read-only for the harness) |
| `/Volumes/crucial10_testdata/corpus/media/Volumes/<VolumeName>/…` | the external root's copies (read-only; the volume carries its own `THIS_IS_TEST_DATA.txt`) |
| `~/corpus/corpus-manifest-v2.json` | THE manifest when present: every file's SHA-256, size, original path, stratum and `root` (v1's rows included) |
| `~/corpus/corpus-manifest-v1.json`, `corpus-sha-v1.txt` | v1's manifest and SHA-256 list (relative to `~/corpus`) |
| `~/corpus/corpus-sha-v2-internal.txt`; `<X10>/corpus/corpus-sha-v2-external.txt` | v2's lists, each relative to its root's `media/` |
| `~/corpus/catalog-source-backup-v2.sqlite` (v1: `catalog-source-backup.sqlite`) | the catalog backup the manifest was chosen from and the sealed catalog is derived from (never written) |
| `~/corpus/external-volume.json` | the adopted external volume: its mount point and volume UUID (`adopt-volume`, once) |
| `state/` | the sealed state `prepare` builds: the corpus catalog, `prepare.json`, the test host's home |
| `work/<run>/` | a run's working files (the `verbs` lane's clones, scratch Trash and scratch archive); removed when the run ends |
| `reports/<lane>/<commit>/<run>/` | `report.json`, `report.txt`, per-file `outcomes.json` keyed by SHA-256 |
| `reports/<lane>/baseline.json` | the run `accept` blessed as the lane's baseline (the run, its commit, who, when, the SHA-256 of its outcomes); `baseline-history.jsonl` beside it |

**Hard rules** (each is a guard in code, pinned by `tests/test_corpus_run.py`):
- Nothing of the corpus goes into git, a commit message, a pushed log or a report to a person or a model beyond: file
  counts, sizes, durations, container/codec names, outcome words and a SHA-256 prefix. No filenames, no paths below the
  corpus root, no caption or transcript text, no frames, no audio. Reports stay on the M4.
- The harness refuses to start unless the hostname is the M4's and its state root is under `~/corpus/state/`. It never
  runs on the M5 Ultra, never opens the live catalog, never touches the Master Archive, never starts catalog sync or
  viewer publishing; the sealed catalog names no Master Archive.
- The corpus sources are read-only. Engines that write, write under `~/corpus/work/<run>/`. The verbs that move, trash
  or promote run only in the `verbs` lane and only on **clones** under that folder: never on `~/corpus/media`, never
  into the Finder Trash, never into an archive root outside `~/corpus/work`. The Trash is the run's own folder
  (`work/<run>/trash`), given to each engine through the engine's own injectable Trash step (Delete Duplicates:
  `hooks.trashItem`; Move to Trash: the routine's `fileOperation` seam, which records the row as removed outright) —
  the app's own Trash call under a test host lands in the system's temporary folder, outside the run, and macOS gives
  no way to move it; that folder is counted afterwards and a file found there is RED. The lane sweeps the size,
  modification time, flags, link count and inode of every corpus file before and after; any difference is RED.
- **The external root** is accepted only while the adopted volume is mounted at its path, that path is not reached
  through a link, the volume carries the marker, and its volume UUID is the one in `~/corpus/external-volume.json`.
  Nothing writes on it, mounted or not (the seal, and `testbed_host.py clean` never enters a mount or `/Volumes`).
  **Unplugged**: `prepare` ingests what it can reach; a lane runs the internal files and says *"external volume NOT MOUNTED: N files
  on it NOT RUN"* — **AMBER** (no engine failed and no copy is at risk, but those files proved nothing), and such a
  run is never a baseline. **Another volume there**, unmarked, or through a link: the lane is refused and runs nothing.
  **Privacy prompt**: before the first read of the external root, a child of the same Python reads its marker and one media
  file (20 s, `ACCESS_PROBE_TIMEOUT_S`); no answer (macOS is showing "Python would like to access files on a removable volume"
  on the headless M4) or EPERM refuses the run (rc 2, the lock released, the interpreter's real path named) instead of hanging
  to the watchdog. Grant once in System Settings › Privacy & Security › Files and Folders (or Full Disk Access) for that path;
  it is per interpreter path, so a Homebrew Python upgrade (a new Cellar path) needs it again.
  The proof (that volume, by UUID) is made again before every launch and, in the test host, before every engine on every
  file. Everything the harness writes, moves or removes is on the **home volume** — checked at every folder on the way, so
  a volume mounted inside or over a corpus folder is refused — and an internal copy must itself be on the home volume.
  Moves are renames only; a removal (`remove_tree`, the one way the harness deletes a tree) never enters another volume.
- The seal is checked twice: `Seal` in `scripts/corpus_run.py`, and `scripts/corpus/CorpusSeal.swift` inside the test
  host (one pure function, pinned by behaviour: `tests/test_corpus_run.py` compiles it and asks it about real folders,
  and about a real disk image as the external volume, case by case beside the Python seal).
  The corpus folders must be themselves (a `work` that is a symlink is refused); a run's work folder is made new; what
  the harness reads back as its own (the sealed catalog, a stored run, a baseline) is refused if it is a link.
- No credential is in the repo. The harness never signals a process: a file past its deadline is cut by the test host
  exiting itself, and the lane sits under `m4_run.sh`'s lane watchdog.

| From the Ultra | What happens on the M4 |
|---|---|
| `scripts/corpus_run.sh adopt-volume /Volumes/<name>` | once, by a person: pins that volume (mounted directly in `/Volumes`, marked, with `corpus/media`) as the external root by its volume UUID. Refused when one is already adopted (move `~/corpus/external-volume.json` into `~/corpus/.trash` to adopt another) |
| `scripts/corpus_run.sh prepare` | builds the sealed catalog from the backup over EVERY file on both roots: only the manifest's rows, each path rewritten to its copy on its root; verifies every file has a row and every row's file exists at its size. Idempotent; refused while the external volume is away |
| `scripts/corpus_run.sh run check [--ref <rev>]` | probe · Check Media (quick) · Verify Audio · the A/V pair link, on every file of both roots, at that commit |
| `scripts/corpus_run.sh run proof --ref <rev>` | Balance Audio into `work/`, then the balanced-copy proof, on v1's one-sided-sound files plus those the newest whole check run heard one-sided (left or right only), smallest first, 40 at most; refused if the largest balanced copy would take the SSD past 95% used; says so when the ref has no proof engine |
| `scripts/corpus_run.sh run verbs [--ref <rev>]` | ~20 files of the **internal** root (APFS clones are made within one volume), stratified and sized to fit, cloned (`cp -c`, no extra space) into `work/<run>/vol/`; a catalog over the clones; then the app's real engines: Update Catalog + Find Duplicates + Delete Duplicates on three byte-identical clones, Move to Trash on an extra copy and on the last copy, Remove and Remove from Catalog each followed by a rescan (does the row come back?), Promote into a scratch archive; every clone re-hashed afterwards; the media sweep covers both roots |
| `scripts/corpus_run.sh run coverage [--ref <rev>]` | opt-in, ~2 h: `check`, `proof` and `verbs` on ONE instrumented Debug build (`<DerivedData>-coverage`), the same build's unit suite (CI plan, drivers skipped) and Core's `swift test --enable-code-coverage` (`<DerivedData>-coverage-core`); LCOV per side, compared over our sources: suite / corpus / union line and function %, what only the corpus runs by area and lane, the functions the suite never enters ranked by size. Each lane still stores its own run. Raw profiles go with the run's work folder; the report stays in `reports/coverage/<commit>/<run>/` (`scripts/corpus_coverage.py`) |
| `scripts/m4_run.sh testbed --smoke` · `scripts/corpus_run.sh run <check\|proof\|verbs> --smoke` | SMOKE (DECISIONS 2026-11-19, target ≤ 15 min with builds): the sensor lane instead of the full suite, then check on one present file per stratum and codec mix (at most 60), proof on two, verbs with every verb once. Says SMOKE in every line and the block; the verdict means the harness, the host and the code run end to end; never a baseline, never what proof picks its files from; works with files missing |
| `scripts/corpus_run.sh status` | the lock, then each lane's newest run judged against its baseline: counts, outcome-word transitions, each changed file by SHA-256 prefix |
| `scripts/corpus_run.sh accept <check\|proof\|verbs>` | blesses the lane's newest run as its baseline; refused for a run that crashed or timed out, a `--limit` run, or a run with no engine |

**A lane's verdict is the diff.** Each run is compared, file by file, with the lane's baseline — the accepted run, or
until one is accepted the lane's first whole clean run. **AMBER**: some file's outcome word moved; each is listed
(`<sha prefix> <engine>: <old> -> <new>`, 40 in a summary, all of them in the run's `report.json` on the M4). **RED**:
a file crashed an engine or ran past its deadline (whatever the baseline holds), a clone was lost or changed, the
corpus media was touched, or the accepted baseline cannot be read back. **GREEN**: nothing moved. An engine's own
`error:…` word is an outcome like any other. After looking at an AMBER run and agreeing with it: `accept`.

**One build per commit** (Charter §7): the overlay holds every lane's driver; the first corpus lane at a commit runs `build-for-testing` and leaves `corpus-build.json` in its DerivedData (commit, config, coverage, the drivers' and the built test binary's SHA-256); every later lane at that commit runs `test-without-building` on its own patched copy of the `.xctestrun` (the gauntlet's Runner pattern) and says "the build reused". Another build into that folder (the ui lane, the smoke testbed's sensor lane) changes the binary and the next lane builds again. The full suite builds Release into its own folder without the drivers, so a testbed run makes two builds. Options: `--wait`, `--dry-run`, `--deadline <seconds per file>`, `--limit <n files>`. `--smoke`. It runs through
`scripts/m4_run.sh corpus` — the same lock, per-run LaunchAgent and `--ref` checkout as the other lanes — so it waits
its turn behind a suite or gauntlet run. The engines run in the app's unit-test host (the shared catalog store, sync
and the background service are inert there) with its home redirected into `~/corpus/state/home`; the driver sources
(`scripts/corpus/*.swift`) are laid over the testbed as untracked files for the run, so a commit that predates the
harness can be run. A crash or a deadline in one file is recorded and the run goes on.

First real `verbs` run, M4, 2026-11-17 23:11 (`2b65a9575`): 170 s (the build 143 s), 20 files / 30 clones, the media
sweep 0 changed of 234, 6 files in the run's Trash folder = 6 the engines reported, 0 in the app's own test-host Trash,
the work folder removed afterwards. `prepare` (transform 2) on the real backup: 94 pair links carried, 6 pairs with both
halves in the corpus, 82 halves whose partner is not.

What the sealed catalog carries beyond the rows: each file's A/V pair link (transform 2: one `row_knowledge` 'pair'
row per paired file, the way the app writes a link; the import evidence itself cannot be carried — a finished import
run is refused by the schema). A half whose partner is not in the corpus keeps its link and reads
`paired_partner_absent`. Not carried: other copies and removed rows of the same content, captions, transcripts, notes,
people. Volume ids and identity stamps still describe the original drive. After a harness change that bumps the
transform, run `prepare` once; a lane refuses a sealed catalog built by another version. The harness trusts the
corpus's own SHA-256 lists (verified with `shasum -c` when the copy was made) and checks sizes; it does not re-hash
1.95 TB per run.

**The manifest is a wish list** (DECISIONS 2026-11-19: "run the testbed even with some of the media missing … each
time it would have more files"). `prepare` ingests what has arrived: each new file whose size is the manifest's is
read once and its SHA-256 checked, into `~/corpus/state/corpus-ledger.json` (root, size, mtime, inode; each file is
checked again right before a lane's launch); it is cheap when
nothing is new and rebuilds the sealed catalog only when the proven set changed. Every summary says, per root,
`present N · missing M` and any of: **mismatched** (bytes are not the manifest's), **vanished** (proven, now gone),
**changed** (proven, size or mtime moved; the next `prepare` reads it again) — those three are AMBER and named by
SHA-256 prefix; missing never moves a verdict. A lane runs only present files. The baseline diff compares the files
both runs had; new ones are counted. `accept` takes a run with missing files, not a `--limit` run or one with the
external volume away.

**The corpus is a stratified SAMPLE** (DECISIONS 2026-11-24; the rules are `scripts/corpus_select.py`'s header).
Stratum = container, video codec, audio codec plus the odd cases the catalog states (no sound, sound decode short,
odd frame rate or size, damaged, under 5 s or over 2 h); each stratum gives ceil(12%), at least 3 (a stratum of 3 or
fewer whole), spread across size and source drive, and at most one file of 8 GB or more per stratum (its large files stand
as one candidate: the copy already made, else the smallest); pins (`scripts/corpus_pins.json`: a file a bug or a test is tied
to) and v1's hand-curated rows are always taken. Roots: a copy already in place keeps its root; otherwise under 8 GB
onto the X10 (1.8 TB of copies), 8 GB and over onto the SSD (400 GB of copies; ~100 GB stays for run scratch) if it
fits, and what fits neither is `ro` — read from the Ultra over a read-only share, NOT RUN (AMBER, never a baseline)
until that share is set up. Measured on the v2 backup, 2026-11-24: 6,351 files / 1.96 TB → 1,043 files / 551 GB
(201 strata) from the copies already made; ~1,078 files / ~1.9 TB if every uncopied large original is readable
(an estimate: small strata of large files are taken whole).

1. On the Ultra (or the M4 for an estimate, `--assume-readable`): `scripts/corpus_select.py select --catalog <fresh
   .backup> --current <the installed manifest> --out <scratch>` writes the sample manifest
   (`corpus-manifest-v2.json`, every row with its `root`) and the copy lists of what each root does not hold yet
   (`v2_<root>.sha` / `.files`) into a scratch folder (never the repo: they hold real paths). Prints counts only.
2. `rsync -a --files-from` the new copies to each root (never `--delete`), `shasum -a 256 -c` on the M4; put the
   sample manifest and the backup (as `catalog-source-backup-v2.sqlite`) in `~/corpus`; `prepare`. The old SHA-256
   lists may still name dropped files: that is not a disagreement.
3. On the M4: `corpus_select.py plan-shrink --sample ~/corpus/corpus-manifest-v2.json --current <the previous
   manifest> --out <scratch>` lists the present copies the sample dropped, per root, with bytes. Deletes nothing.
4. A whole `run check` on the installed sample (every sample file present, nothing NOT RUN, GREEN). Then
   `corpus_select.py apply-shrink --plan <scratch>/shrink-plan.json --after-green <that run's stamp>` deletes the
   planned copies — refused unless the run is GREEN, ran this very manifest (its `manifest_sha256`) and found every
   sample file present; only under `~/corpus/media` and `<X10>/corpus/media`, through folder descriptors that never
   follow a link or leave the root's volume; a file the sample names, a link, a second name, a lock or another size is
   left and counted. A receipt (counts only) goes to `~/corpus/state/shrink-history.jsonl`. Originals are never
   touched (`scripts/corpus_shrink.py`).

Disk (DECISIONS 2026-11-24): the X10 holds the sample (up to ~2 TB during a run); the SSD gives the testbed ~500 GB and
rests ≤ 60% used once a run's regenerable scratch is gone.

## 2. Storage layout

*Rewritten 2026-11-01 (F12) to the facts that still hold. The 8/13–8/15 incident narratives (the LaCie power-supply
scare and its rescue copy, the UPS installation, the M4 boot-drive investigation, the Pegasus DEXT discovery) are
archived whole in `docs/archive/guides/ops/storage_layout_2026_08_13.md`. Machine names below are as of August, before
the Ultra; check the desk before relying on a port.*

- **Pegasus32 R4 RAID** (decided 2026-08-13): factory RAID5, 4×4 TB = 12.0 TB usable; one APFS container, two volumes
  sharing all space with reserves only — `FamilyArchive` (6 TB reserve) and `Projects` (3 TB). The "available"
  figures of the two volumes sum to more than the disk because the unreserved slack is counted by both.
  **`-reserve` / `-quota` are creation-time only** (no `resizeVolume` / `setQuota` on this macOS): changing a reserve
  means `deleteVolume` + `addVolume`, destroying that volume.
- **The RAID is invisible until its DriverKit extension is enabled:** System Settings → General → Login Items &
  Extensions → Driver Extensions → Promise ON; check `systemextensionsctl list` for `[activated enabled]`.
- **Media Patrol weekly, Sunday 10 PM** (set in Promise Utility; `promiseutil` has no scheduler); a pass takes 12–20 h
  and yields to foreground I/O. After each pass, `sudo promiseutil -C event`: rising media errors on one member means
  source a replacement while redundancy remains.
- **Device speeds, so nobody chases cables:** the LaCie d2 Professional is one 7200 rpm HDD over USB-C (~207 MB/s
  sustained); the Crucial X9/X10 are USB 3.2 (~1 GB/s); copies off the LaCie are source-limited. USB drives go on the
  CalDigit dock or the USB hub, not daisy-chained off the Pegasus.
- **Power:** the Pegasus, the LaCie and the Mac Studio are on the CyberPower CP1500PFCRM2U (pure sine wave) since
  2026-08-15; the 8/13 LaCie dropouts were a bad power strip, not the drive.
- **Disk-space rule:** `df` / `du` count blocks, Finder counts logical size (it follows symlinks, counts clones twice,
  reports sparse files at their maximum); when they disagree, blocks win. Docker's sparse `Docker.raw` is the classic
  phantom — never reset Docker to "reclaim" it.
- **Open since 8/13 (unverified since):** the Studio's 10GbE linked at 1000baseT; the CalDigit ethernet showed no link.

## 3. Thunderbolt 5 link check

*From `guides/ops/tb5_diag.md` (baseline 2026-07-06), whole.*

<!-- moved from Claude memory (reference_tb5_diag) on 2026-10-23; operational reference, rewrite in place -->

When Rick says **"test TB 5 connection"** (or similar): run `~/dev/VideoScan/scripts/tb5_diag.sh [peer-ssh-host]` (default peer ricksm5.local). Takes ~1 min. Checks: TB link + negotiated speed (80/120 Gb/s = TB5; 40 = cable not TB5-rated or too long — passive limit ≈1 m, active/optical needed beyond), Thunderbolt Bridge IPs both ends, RTT (<1 ms), and 4 GB TCP throughput BOTH directions (STRONG ≥55 Gbit/s, PASS ≥30, <8 = routing over Wi-Fi).

**Baseline (2026-07-06, OWC short passive TB5 cable, M4 Studio receptacle 4 ↔ M5 Pro MBP):** 80 Gb/s link · TX 65.1 / RX 63.1 Gbit/s · RTT 0.53 ms · verdict YES.

Gotchas encoded in the script: uses `/usr/bin/python3` on BOTH ends — Apple-signed python is exempt from macOS 26 **Local Network privacy (TCC)**, which blocks Homebrew/venv binaries with silent `Errno 65 No route to host` on link-local (this blocked MLX ring 2026-07-06; fix = one-time GUI "Allow" per machine for the venv python). MLX cluster demo: `scripts/mlx_cluster_demo.py`, launch via `venv-mlx/bin/mlx.launch --backend ring --hosts <bridgeIPs> --python .../venv-mlx/bin/python`; jaccl/RDMA backend awaits `rdma_ctl enable` in Recovery on both machines. Related: [[analysis-ledger-arc]].
