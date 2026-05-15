# VideoScan — Homebrew bundle
# Usage:  brew bundle --file=Brewfile
# Update: brew bundle --file=Brewfile --cleanup    (removes things not listed)

# ---- Runtime dependencies (required to run VideoScan) ----
brew "ffmpeg"        # ffmpeg + ffprobe — media probing, mux/demux, clip extraction
brew "python@3.12"   # interpreter for VideoScan.py, face_recognize.py, find_person.py
                     # (3.13 lacks wheels for torch 2.2 / facenet-pytorch — keep 3.12 until upstream catches up)
brew "uv"            # fast venv + package manager (replaces pip; brewed python ships no pip)
brew "cmake"         # required to build dlib from source on first venv install
brew "libpng"        # macOS 26+ SDK removed <fp.h>; dlib's vendored libpng/arm fails. System libpng works.
brew "jpeg"          # same reason as libpng — needed so dlib's CMake picks system libs over the broken vendored copy

# ---- Developer tooling (recommended) ----
brew "gh"            # GitHub CLI — issues, PRs, project board
brew "swiftlint"     # Swift static analysis (pre-commit + CI)
brew "periphery"     # Swift unused-code finder (pre-commit + CI)
brew "pre-commit"    # git hook framework wiring swiftlint/periphery
brew "jq"            # JSON in shell scripts (collect_metrics.sh, dashboard.sh)

# ---- GUI apps ----
cask "claude"               # Anthropic Claude desktop chat app
cask "claude-code"          # Anthropic Claude Code CLI (terminal AI assistant)
cask "visual-studio-code"   # optional editor; Xcode is the primary IDE

# Notes
# - Node.js is intentionally NOT listed: install via nvm to avoid conflicting
#   with system or brew-managed node.
# - Xcode itself is installed from the Mac App Store, not Homebrew.
