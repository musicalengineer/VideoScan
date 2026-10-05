# install_videoscan_dev_dependencies

Turns a fresh Apple Silicon Mac (macOS 27 + Xcode 27) into a VideoScan
development machine, and copies the data a new machine needs from an old one.
Written for the M4 → M5 Ultra move ([MIGRATION_PLAN.md](MIGRATION_PLAN.md)),
but it works for any new dev Mac.

## Quick start

```bash
# Rick first: Xcode 27 from the App Store (open it once), Homebrew, git identity.
git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan
~/dev/VideoScan/install_videoscan_dev_dependencies/install.sh --copy-from RicksM4.local --with-models
~/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh --from RicksM4.local        # dry run
~/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh --from RicksM4.local --go   # copy
~/dev/VideoScan/install_videoscan_dev_dependencies/install.sh --check                          # all green?
```

Then open `VideoScan/VideoScan.xcodeproj`, scheme **VideoScan**, **Debug**, ⌘R.

## What's in here

| File | Does |
|---|---|
| `install.sh` | Entry point. Runs the steps below in order, idempotently, and ends with a summary: already in place / installed now / needs Rick / failed. Exit 1 if anything failed. |
| `steps/10_preflight.sh` | arm64, macOS ≥ 26 (27 expected), Xcode 27 + license, Homebrew, checkout at `~/dev/VideoScan`, free disk. Stops the run if a hard prerequisite is missing. |
| `steps/20_homebrew.sh` | `brew bundle` against the repo-root **Brewfile** (the single list of brew packages); checks the `claude` and `codex` CLIs. |
| `steps/30_xcode.sh` | Metal Toolchain component; resolves the Swift packages from `Package.resolved`. Never builds the app. |
| `steps/40_python.sh` | Builds `venv` (Python 3.14, `requirements.txt` + `face_recognition_models`), `venv-mlx` (3.12, MLX Whisper/VLM) and `venv-genealogy` (3.14, getmyancestors), then proves each by importing its packages. |
| `steps/50_models.sh` | CoreML face models (not in git; `--copy-from`), Hugging Face Whisper + Qwen-VL, Ollama `qwen3.8:27b-mlx` (`--with-models`). |
| `steps/60_helpers.sh` | Hallie's Kokoro voice (runs `scripts/install_hallie_kokoro.sh`), the drivetemps menubar app, and checks for the root-owned `vs-drive-temps` helper and `promiseutil`. |
| `steps/70_devtools.sh` | git hooks, git-lfs, git identity, `gh` / codex sign-in, ssh to the fleet; LaunchAgents only with `--with-schedules`. |
| `steps/80_verify.sh` | ffprobe reads a fixture, the Xcode project lists its scheme, VideoScanCore resolves, pytest collects the Python suite. Under a minute. |
| `migrate_data.sh` | Pull-only, dry-run-by-default copy of App Support (catalog, People, CyberBrain, ledger…) and the git-ignored family photos/models in the checkout. |
| `lib.sh` | Shared output helpers and the pinned Python versions. |

## Options

```
install.sh --check                 report only, change nothing (safe on any machine, any time)
install.sh --only python,verify    run some steps
install.sh --skip helpers          run all but some
install.sh --with-models           pull Ollama (~18 GB) + Hugging Face (~2.5 GB) models
install.sh --copy-from HOST        copy the CoreML face models from another Mac over ssh
install.sh --with-schedules        install this Mac's LaunchAgents (nightly) — only after its role is decided
install.sh --repo DIR              act on another checkout (e.g. check the live one from a worktree)
```

## What stays with Rick

These need your accounts, your password or your eyes, so the scripts check them
and list them under "needs Rick" instead of doing them:

- Xcode 27 from the App Store; open it once to accept the license.
- Homebrew's installer (it asks for your password).
- Sign-ins: `gh auth login`, Claude Code, `codex login`, git identity.
- `ssh-copy-id` to the other Macs, and Remote Login on the old one.
- The root-owned `vs-drive-temps` helper and its sudoers rule (exact commands are printed).
- Promise Utility (vendor download), if the Pegasus moves to this Mac.
- Privacy & Security: Full Disk Access / Removable Volumes for VideoScan, Xcode and Terminal.
- Building and running the app.

## Verified

2026-10-05 on RicksM4 (macOS 27.0.1, Xcode 27.0): `install.sh --check --repo ~/dev/VideoScan`
→ 35 already in place, 0 failed, 3 for Rick (low disk, ssh to the sleeping laptops).
Against a bare clone it reports the missing venvs and models and exits 1. The
`migrate_data.sh` plumbing was dry-run M4 → M4 (0 files to transfer, as expected).
A true fresh-machine run hasn't happened yet: see the dress rehearsal in the migration plan.

## Relationship to setup.sh / INSTALL.md

`setup.sh` (repo root) predates this folder and covers about half of it: no
Ollama, models, genealogy venv, Kokoro, helpers or data. Its Metal check calls
`xcodebuild -showComponents`, which Xcode 27 does not have, so it re-downloads
every time. Suggest retiring it in favour of `install.sh` once the Ultra
migration has proven this folder.
