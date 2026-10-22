# Codex review — Dev installer (Ultra bring-up)

- Range: `d7addb1bc..working-tree`
- Credits spent: unavailable (usage meter not exposed)
- Tokens: 60893
- Finding count: 5
- Verdict: fix — the documented fresh-Mac invocation can fail, and `--check` is not read-only.
- Run: 2026-10-22T16:44:46Z (cycle #121, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (usage meter not exposed) | Finding count: 5

Verdict: fix — the documented fresh-Mac invocation can fail, and `--check` is not read-only.

1. **P1 — Hook installation depends on the caller’s directory.** [70_devtools.sh:15](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/70_devtools.sh:15) invokes [install-git-hooks.sh:17](/Users/rickb/dev/VideoScan/scripts/install-git-hooks.sh:17), which discovers the repository from `$PWD`. Cloning does not change directories, so Rick’s documented sequence leaves this outside the checkout. **Reproduction:** invoking the helper from `/` exits 128: “not a git repository.” From another checkout, it can target that repository instead. **Fix:** run the helper inside `$REPO_ROOT`; likewise scope `git lfs install` with `git -C "$REPO_ROOT"`.

2. **P1 — `--check` creates directories and runs potentially writing probes.** [80_verify.sh:47](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/80_verify.sh:47) unconditionally creates `~/Library/Logs/VideoScan`. **Reproduction:** sourcing verification with `CHECK_ONLY=1` and a recording `mkdir` stub still calls `mkdir -p`. Python imports and pytest collection also lack bytecode/cache suppression; Xcode/SwiftPM probes are unguarded. **Fix:** guard directory creation and make check-mode probes strictly observational; skip probes whose filesystem effects cannot be prevented.

3. **P1 — Failed dependency probes can report ✓.** [20_homebrew.sh:11](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/20_homebrew.sh:11) filters output and discards Brew’s status; [80_verify.sh:39](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/80_verify.sh:39) ignores pytest’s status and examines only its final line. **Reproduction:** a Brew stub returning 2 with an error produces “every Brewfile entry is installed”; a pytest stub returning 5 with “no tests collected” also produces ✓. **Fix:** capture and test each command’s exit status before interpreting its output; retain diagnostic output on failure.

4. **P2 — Fresh installs are not version-reproducible.** [40_python.sh:68](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/40_python.sh:68) installs `face_recognition_models` from an unpinned Git revision, and line 80 installs unversioned `getmyancestors`. [Brewfile:11](/Users/rickb/dev/VideoScan/Brewfile:11) and [lib.sh:56](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/lib.sh:56) select Python minor branches, not patch releases; other Brew packages float. **Failure scenario:** upstream releases between the M4 setup and Ultra setup produce different environments; `--no-upgrade` preserves the M4’s older versions. **Fix:** pin Python package versions and Git SHAs, lock transitive dependencies, and explicitly define which interpreter/Homebrew version drift is acceptable.

5. **P2 — Install mode writes outside the stated directory boundary.** [40_python.sh:37](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/40_python.sh:37), [50_models.sh:66](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/50_models.sh:66), and [60_helpers.sh:21](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/steps/60_helpers.sh:21) write `/tmp/videoscan-install-*.log`; [install_hallie_kokoro.sh:15](/Users/rickb/dev/VideoScan/scripts/install_hallie_kokoro.sh:15) stages under `$TMPDIR`. **Failure scenario:** ordinary installation writes beyond `$HOME`, the repository, and Homebrew. **Fix:** place logs and temporary work beneath a dedicated `$HOME` directory, or explicitly permit system temporary storage.

Validation: all 13 shell files parse under Apple bash 3.2; its empty-array handling passed. No files were written. No full installation was attempted.

Read, no independent findings: `scripts/install_dev_tools.sh`, `install.sh`, `10_preflight.sh`, `30_xcode.sh`, and the README quick-start changes. Homebrew PATH recovery is present; default execution does not copy family data, invoke sudo, or install LaunchAgents.

## Brief

# Codex brief: the dev-machine installer — bring up the M5 Ultra as a VideoScan DEV box (2026-10-22; Rick asked for this pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `d7addb1bc..working-tree`. `scripts/install_dev_tools.sh` is new and uncommitted; the README quick start changed. Everything else is on main as of d7addb1bc.

## What it is for (read this first)

This is a **developer bring-up script, not a product installer.** Nobody installs VideoScan the app with it, and it copies no user data.

Rick's new Mac Studio (M5 Ultra, macOS 27, arm64) arrives 10/27. On it he does these steps by hand, in order:
1. Install Xcode 27 and his GUI apps, and Homebrew.
2. Run `gh auth login`.
3. Run `git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan`.
4. Run `~/dev/VideoScan/scripts/install_dev_tools.sh`.

The script then installs everything a developer needs to **build, run and test** VideoScan:
- brew packages from the repo Brewfile;
- Swift package resolution;
- three Python venvs at pinned versions;
- Hallie's Kokoro voice helper;
- git hooks and git-lfs;
- checks for sign-ins it cannot do itself.

It ends with a summary of what was already in place, what it installed now, what needs Rick, and what failed. Rick then opens the Xcode project and does a clean Debug build and ⌘R himself; the script never builds the app.

The design goal is that **any developer** on a clean Mac (same OS) gets a working environment, not only Rick. Family data (catalog, photos, models) moves later in a separate script that is **out of scope here**.

## Files (only these)

- `scripts/install_dev_tools.sh` (the new entry point; execs install.sh)
- `install_videoscan_dev_dependencies/install.sh`, `lib.sh`
- `install_videoscan_dev_dependencies/steps/10_preflight.sh` … `80_verify.sh` (8 files)
- the files those steps call: `Brewfile`, `scripts/install_hallie_kokoro.sh`, `scripts/install-git-hooks.sh`
- `install_videoscan_dev_dependencies/README.md` (Quick start)

**NOT in scope:** `install_videoscan_dev_dependencies/migrate_data.sh` (data copy; it has uncommitted edits and gets its own pass) and `MIGRATION_PLAN.md`.

## Evidence already run

- On the M4 (macOS 27, Xcode 27, fully set up), `install_dev_tools.sh --check` reports 37 in place, 0 failed, 1 needs-Rick (free disk).
- `install.sh --check` with `HOME` pointed at an empty sandbox reports three failures, each with the exact fix: the checkout is missing, Kokoro is missing, and git-lfs is not set up.
- The Xcode project references nothing git-ignored, so a fresh clone builds. The `models/` folder is loaded at run time only.
- Not yet run: a real install on a truly fresh Mac. The Ultra will be the first.

## Questions to attack

- **Q1 Fresh Mac.** Will step 4 work on a Mac that only has Xcode, Homebrew and a clone? Look for:
  - the `#!/usr/bin/env bash` shebang resolving to Apple's bash 3.2 before brew's bash exists (associative arrays, `${x,,}`, `mapfile`, `[[ -v ]]`);
  - brew not on PATH in a fresh zsh;
  - anything that silently assumes the M4's state, such as existing venvs, `~/.local/bin`, ssh keys or caches;
  - ordering, where one step needs something a later step installs.
- **Q2 `--check` changes nothing.** Does any step write, install, or create files or folders under `--check`?
- **Q3 Idempotent and honest.** Does a re-run leave a good install alone? Can anything be reported ✓ when it is broken (stderr swallowed, exit codes lost in pipes, `|| true` hiding a failure)?
- **Q4 Scope.** Does anything do one of these?
  - copy or require family data;
  - need sudo without saying so;
  - install LaunchAgents or nightly jobs without `--with-schedules`;
  - write outside `$HOME`, the repo and Homebrew;
  - hard-code Rick's hostnames or `/Users/rickb` in a way that breaks another developer.
- **Q5 Reproducible.** Are the Python and package versions pinned, or will the Ultra quietly get different ones than the M4?

At most FIVE findings, most serious first. P1 = the script fails or misreports on a fresh Mac, or changes something under `--check`. One-line failure scenario and the fix for each. Observations on simplifying it are welcome after the findings, in 3 lines or fewer.

## Known and declared, NOT findings

- Xcode, Homebrew itself, GUI apps, sign-ins (gh, codex, claude) and sudo steps are deliberately manual and listed under "needs Rick".
- The fleet ssh probe in `70_devtools.sh` names Rick's Macs. It only reports, and never fails the run.
- The checkout location `~/dev/VideoScan` is required; the app expects it.

**Do not explore outside the files listed above.**

## Closure (2026-10-22, Claude, same day)

Each claim checked against the source before fixing; all five held.

1. **Hooks / lfs depend on the caller's directory: fixed.** `70_devtools.sh` runs `install-git-hooks.sh` inside `$REPO_ROOT` and uses `git -C "$REPO_ROOT" lfs install`. The same bug was in the pytest probe (3 test files import `scripts.…` from the cwd; run from `~`, collection gave 1205 + 3 errors). `80_verify.sh` now collects from the checkout. Evidence: `install_dev_tools.sh --check` run from `/` gives 37 in place, 0 failed.
2. **`--check` writes: fixed.** The log folder is only created in install mode. pytest runs with `-p no:cacheprovider`. `install.sh` exports `PYTHONDONTWRITEBYTECODE=1` under `--check`. Evidence: no `__pycache__` under tests/ was created or changed by a check run. Declined: Homebrew and gh write their own caches under `~/Library/Caches` and `~/.local/state` on any invocation. That is tool behaviour, not ours.
3. **False ✓: fixed.** `brew bundle check`'s exit status now decides the verdict; an error with no "needs to be installed" line is a failure that shows brew's last line. pytest needs exit 0 AND "N tests collected" with N ≥ 1.
4. **Not reproducible: fixed for Python.** `install_videoscan_dev_dependencies/locks/{venv,venv-mlx,venv-genealogy}.txt` hold the M4's exact versions (`uv pip freeze`, 75 / 81 / 12 packages), and `40_python.sh` installs from them, falling back to the loose requirements if a lock is missing. `face_recognition_models` is pinned to e67de717. Evidence: all three locks and the SHA dry-run-resolve into fresh 3.14 / 3.12 venvs. Declined: Homebrew versions still float (no supported lock for formulae). Python is pinned to the minor version, so a patch bump is accepted.
5. **Logs outside the boundary: fixed.** The pip, Kokoro and ollama logs go to `~/Library/Logs/VideoScan/install/` (they survive a reboot, unlike /tmp). Kokoro's own `$TMPDIR` staging is declined: system temp is fine for scratch.

## Closed

Closed by `working-tree` at 2026-10-22T17:27:16Z. all 5 fixed (2 partial declines documented); locks from M4 venvs
