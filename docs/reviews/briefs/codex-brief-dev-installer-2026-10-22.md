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
