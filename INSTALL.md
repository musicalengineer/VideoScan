# VideoScan — Install & Setup

Fresh-machine setup for running and developing VideoScan on macOS. Target audience: Rick, family, or anyone cloning the repo for the first time. There is no installer — VideoScan is built and run from Xcode.

**Tested on:** macOS 14+ (Sonoma) and later, Apple Silicon (M1–M5). Intel Macs are not a supported runtime target.

---

## TL;DR

```bash
# 1. Prereqs: Xcode + Command Line Tools + Homebrew (one-time, see below)
# 2. Clone
git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan
cd ~/dev/VideoScan

# 3. Brew dependencies
brew bundle --file=Brewfile

# 4. Python venv (uv replaces pip — brewed python ships no pip)
uv venv --python python3.12 venv
source venv/bin/activate
uv pip install -r requirements.txt

# 5. Open in Xcode and run
open VideoScan/VideoScan.xcodeproj
```

If that all works, you're done. Detail and troubleshooting below.

---

## 1. Prerequisites

These are installed once per machine, not via the Brewfile.

### Xcode

Install from the Mac App Store (≥ Xcode 26.0 recommended; Rick currently uses 26.3). On first launch, accept the license. Then install the Command Line Tools:

```bash
xcode-select --install
```

Verify:

```bash
xcodebuild -version
xcrun --find clang
```

### Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

On Apple Silicon, Homebrew installs to `/opt/homebrew`. The installer will tell you how to add it to your shell path — follow those instructions, then restart the terminal.

Verify:

```bash
brew --version
```

### git (already comes with Command Line Tools)

```bash
git --version
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

---

## 2. Clone the repo

The project assumes it lives at `~/dev/VideoScan`. Other locations work but some scripts hardcode this path.

```bash
mkdir -p ~/dev
git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan
cd ~/dev/VideoScan
```

---

## 3. Homebrew dependencies

The `Brewfile` at the repo root lists everything VideoScan needs from Homebrew, plus optional dev tooling and GUI apps.

```bash
brew bundle --file=Brewfile
```

What this installs:

**Required runtime**
- `ffmpeg` — provides both `ffmpeg` and `ffprobe`, used for media probing, mux/demux, and clip extraction
- `python@3.12` — interpreter for the Python scripts (3.13 currently lacks wheels for torch 2.2 / facenet-pytorch)
- `cmake` — needed to build `dlib` from source on first venv install

**Recommended dev tools**
- `gh` — GitHub CLI (issues, PRs, project board)
- `swiftlint`, `periphery`, `pre-commit` — code-quality tooling wired into the pre-commit hook and CI
- `jq` — JSON wrangling in shell scripts

**GUI apps**
- `claude` — Anthropic Claude desktop chat app
- `claude-code` — Claude Code CLI (terminal AI assistant)
- `visual-studio-code` — optional editor (Xcode is the primary IDE)

Edit the Brewfile to taste; comment out anything you don't want.

**Node.js is intentionally not in the Brewfile.** If you need Node (for example, for npm-based tooling), install [`nvm`](https://github.com/nvm-sh/nvm) and use it to manage Node versions. Mixing brew-managed and nvm-managed Node leads to PATH pain.

---

## 4. Python virtual environment

VideoScan's Python scripts (face detection, clustering, catalog generation) live under `scripts/` and expect a venv at `~/dev/VideoScan/venv`.

We use [`uv`](https://github.com/astral-sh/uv) instead of `pip` — Homebrew's `python@3.12` ships without a usable system `pip`, and `uv` is also dramatically faster at resolving and installing.

```bash
cd ~/dev/VideoScan
uv venv --python python3.12 venv
source venv/bin/activate
uv pip install -r requirements.txt
```

**Heads up — first install is slow.**

- `dlib` compiles from source via CMake. Expect 5–10 minutes on Apple Silicon. If it fails, ensure `cmake` is installed (`brew install cmake`) and the Xcode Command Line Tools are present.
- `torch` is a large download (~200 MB).
- `opencv-python` is ~100 MB.

Total first-time install is typically 10–20 minutes and a few GB on disk.

Verify the venv:

```bash
python -c "import dlib, face_recognition, torch, cv2, openpyxl; print('OK')"
```

You can deactivate with `deactivate`. The Swift app launches the venv's Python explicitly, so you do not need to keep it activated to run VideoScan.

---

## 5. Build & run the app

```bash
open VideoScan/VideoScan.xcodeproj
```

In Xcode:
1. Select the `VideoScan` scheme.
2. Choose your Mac as the run destination.
3. Build configuration: **Release** for daily use (faster), **Debug** for active development.
4. ⌘R to run.

On first launch the app will request permission to access:
- **Photos** (for Apple Photos integration in Person Finder)
- **Removable Volumes / Files and Folders** (for scanning external drives)

Grant both when prompted. macOS may also gate access to specific drives — re-grant under System Settings → Privacy & Security → Files and Folders if scans return empty.

---

## 6. Optional: dev tooling

If you plan to make changes and commit them:

```bash
cd ~/dev/VideoScan
pre-commit install
```

This wires up the swiftlint + periphery hooks on `git commit`. They run in warn-only mode by default; CI also runs them.

To run all tests locally:

```bash
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -destination 'platform=macOS' \
  -configuration Debug
```

Or use the TestDriver harness — see `TestDriver/README.md`.

---

## 7. Troubleshooting

**`brew: command not found` after install**
Restart the terminal, or `eval "$(/opt/homebrew/bin/brew shellenv)"`. Then add the eval line to `~/.zshrc`.

**`dlib` fails to install with CMake errors**
Make sure both `cmake` (brew) and the Xcode Command Line Tools (`xcode-select --install`) are present. If you upgraded macOS recently, re-run `xcode-select --install` to refresh the CLT.

**`ffprobe: command not found`**
`brew bundle` didn't run successfully, or `/opt/homebrew/bin` isn't on PATH. Re-run `brew bundle --file=Brewfile`, then verify with `which ffprobe`.

**App scans return zero files on an external drive**
macOS Files and Folders privacy gate. Open System Settings → Privacy & Security → Files and Folders, and grant VideoScan access to "Removable Volumes" (and any specific drives listed).

**Photos integration is empty**
System Settings → Privacy & Security → Photos → enable VideoScan.

**Xcode build fails with "Signing requires a development team"**
For personal use you can either sign with your Apple ID (Xcode → Settings → Accounts), or disable signing under the target's Signing & Capabilities tab and run unsigned locally.

---

## Repository layout (quick reference)

| Path | Purpose |
|---|---|
| `VideoScan/` | SwiftUI macOS app (Xcode project) |
| `swift_cli/` | Standalone Swift CLIs (PersonFinder, FaceDiagnose) |
| `scripts/` | Python helpers (catalog, face engines, metrics) |
| `tests/` | XCTest + Python test fixtures and runners |
| `TestDriver/` | Standalone test harness app |
| `docs/` | Per-subsystem design notes |
| `Brewfile` | Homebrew dependencies (this file's companion) |
| `requirements.txt` | Pinned Python dependencies |
