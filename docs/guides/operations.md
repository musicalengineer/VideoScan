# Operations — machines, storage, the deep-test host

*Rewritten in place. Consolidated 2026-11-01 from two machine notes in `guides/ops/` and the M4 deep-test host design; originals under `docs/archive/`. Who may use which machine when is a rule, in `docs/PROCESS.md` §8 (the M4 is the default testbed, 2026-10-31; the Ultra only in a declared window); machine names are in `CLAUDE.md`.*

The fleet: the **M5 Ultra** Mac Studio (`RicksUltra`, Rick's interactive machine since 2026-10-27/28), the **M4** Max Mac Studio (`RicksM4`, the headless deep-test host), the **M5 Pro** MacBook (`ricksm5.local`) and the **M1** MacBook Pro for overflow. This guide holds the operational facts that are not rules: how the deep-test host runs, how storage is laid out, how to check the Thunderbolt 5 link. The background helper's launchd job is in `docs/design/background_service.md`; where every App Support file lives, and what each catalog table holds, is in `docs/design/data_organization_2026_10_31.md`; backups of the catalog are `sqlite3 … ".backup"` only (CLAUDE.md), and the off-site copy plan is a STATUS date (2026-11-01).

## Contents
1. The M4 deep-test host (built 2026-10-28; what is still planned) · 2. Storage layout (the facts that hold) · 3. Thunderbolt 5 link check

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
| "everything on the M4" | `scripts/m4_run.sh all` | deep, then ui |
| "… on the M5 Ultra" | add `--host ultra` | the same, in the Ultra's testbed worktree |
| "how's the M4 run?" | `scripts/m4_run.sh status` | reads `<root>/latest` back |

What it does: resolves `--ref` (default `main`) to a commit; refuses if a run holds the host's lock or it is the
nightly window (01:30–06:00 host time; `--force` overrides); on the M4 pushes `<sha>:refs/m4run/<sha>` (a new ref per
commit, never forced, never a branch); checks the host's testbed worktree out at the commit (detached; refuses a dirty
one); installs itself under `<root>/bin`; and starts a one-shot LaunchAgent in the host's GUI session (an ssh job has
no window server and a locked keychain). The host writes `<root>/out/<stamp>-<lane>/` (`run.log` with START/OUTCOME,
`summary.txt`, per-plan logs, `.xcresult`, `.tests.tsv`) and points `<root>/latest` at it. Roots: M4 `~/m4run`, Ultra
`~/ultrarun`; one Debug DerivedData per host (~15 GB); xcresults are kept (prune `<root>/out` by hand). Builds are
ad-hoc signed; the UI suites run against the gauntlet fixtures and a temp catalog, never a real catalog or volume.
Tests: `tests/test_m4_run.py`.

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
- Later, only if wanted: an automatic trigger, the real-media testbed SSD (BACKLOG).

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
