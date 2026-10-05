# VideoScan — Homebrew bundle
# Usage:  brew bundle --file=Brewfile
#         (or install_videoscan_dev_dependencies/install.sh, which runs it)
# Update: brew bundle --file=Brewfile --cleanup    (removes things not listed)
#
# Revised 2026-10-05 against what the M4 actually runs (see
# install_videoscan_dev_dependencies/README.md). Every entry names its caller.

# ---- Runtime dependencies (required to run VideoScan) ----
brew "ffmpeg"        # ffmpeg + ffprobe — FFmpegLocator.swift; media probing, mux/demux, clip extraction
brew "python@3.14"   # main venv/ and venv-genealogy/ — all requirements.txt packages import on 3.14
brew "python@3.12"   # venv-mlx/ only — the mlx-vlm / mlx-whisper stack
brew "uv"            # venv + package manager (brewed python ships no pip)
# Hallie's local LLM — OllamaLocalServerBootstrap starts `ollama serve` on demand.
# Skipped where the Ollama.app CLI already exists (the M4 has it in /usr/local/bin):
# the app prefers /opt/homebrew/bin, so a second copy would silently switch it.
brew "ollama" unless File.exist?("/usr/local/bin/ollama")
brew "smartmontools" # smartctl — DriveHealth / drive_temps.py / DriveTempsMenuBar
brew "rsync"         # rsync 3.x for migrate_data.sh (macOS /usr/bin/rsync is openrsync, protocol 29)
brew "media-info"    # mediainfo CLI — second opinion beside ffprobe when triaging odd files

# ---- Native build dependencies (first venv install) ----
brew "cmake"         # builds dlib from source
brew "libpng"        # macOS 26+ SDK removed <fp.h>; dlib's vendored libpng/arm fails. System libpng works.
brew "jpeg-turbo"    # libjpeg for dlib's CMake, linked into /opt/homebrew/lib. (The old `jpeg` entry is
                     # keg-only — never linked — so CMake could not find it; jpeg-turbo is what dlib uses on the M4.)

# ---- Developer tooling ----
brew "git-lfs"       # scripts/install_hallie_kokoro.sh pulls the Kokoro voice model over LFS
brew "gh"            # GitHub CLI — issues, PRs, metrics, adversarial nightly
brew "node"          # Node ≥ 24: tools/engineering-room, scripts/run_python_tests.sh (the M4 runs brew node, not nvm)
brew "swiftlint"     # Swift static analysis (pre-commit + CI)
brew "periphery"     # Swift unused-code finder (CI)
brew "pre-commit"    # git hook framework
brew "jq"            # JSON in shell scripts

# Notes
# - GUI apps (Claude desktop, editors) are installed by hand, not here.
# - The Claude Code CLI uses its own installer and lives in ~/.local/bin;
#   codex likewise (~/.local/bin/codex). Both are checked, not installed,
#   by install_videoscan_dev_dependencies/.
# - Xcode comes from the Mac App Store.
# - `timeout` (coreutils) is deliberately absent: the shell scripts that need a
#   deadline carry their own watchdogs, and the M4 runs without it.
