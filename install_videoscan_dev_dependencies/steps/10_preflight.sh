# Step: preflight — hard prerequisites the script cannot install itself.
# Sourced by install.sh. Sets PREFLIGHT_BLOCKED=1 to stop the run.

section "Preflight"
PREFLIGHT_BLOCKED=0

if [[ "$(uname -m)" == "arm64" ]]; then
    ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"
else
    failed "Apple Silicon" "VideoScan's MLX, Metal and Kokoro pieces need an arm64 Mac"
    PREFLIGHT_BLOCKED=1
fi

macos_version=$(sw_vers -productVersion)
if [[ "${macos_version%%.*}" -ge 27 ]]; then
    ok "macOS $macos_version"
elif [[ "${macos_version%%.*}" -ge 26 ]]; then
    manual "macOS $macos_version" "the app deploys to 26, but the fleet develops on 27 — update when convenient"
else
    failed "macOS $macos_version" "the app's deployment target is macOS 26; update macOS first"
    PREFLIGHT_BLOCKED=1
fi

if [[ -d /Applications/Xcode.app ]] && xcodebuild -version >/dev/null 2>&1; then
    xcode_version=$(xcodebuild -version | head -1)
    ok "$xcode_version ($(xcode-select -p))"
    if [[ "$xcode_version" != "Xcode 27"* ]]; then
        manual "$xcode_version" "the fleet uses Xcode 27; CI uses 26.3 — install 27 from the App Store"
    fi
    # Exit status 0 means the license is accepted and first-launch packages are in.
    if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        manual "Xcode first launch" "open Xcode once and accept the license (or: sudo xcodebuild -runFirstLaunch)"
    fi
    if [[ "$(xcode-select -p)" != "/Applications/Xcode.app/Contents/Developer" ]]; then
        manual "xcode-select" "points at $(xcode-select -p); run: sudo xcode-select -s /Applications/Xcode.app"
    fi
else
    manual "Xcode" "install Xcode 27 from the Mac App Store, open it once, then re-run"
    PREFLIGHT_BLOCKED=1
fi

if command -v brew >/dev/null 2>&1; then
    ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
else
    # The Homebrew installer asks for a sudo password, so it is Rick's step.
    manual "Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" then add `eval "$(/opt/homebrew/bin/brew shellenv)"` to ~/.zprofile'
    PREFLIGHT_BLOCKED=1
fi

if [[ "$REPO_ROOT" == "$CANONICAL_CHECKOUT" ]]; then
    ok "checkout at $CANONICAL_CHECKOUT"
elif [[ -d "$CANONICAL_CHECKOUT/.git" || -f "$CANONICAL_CHECKOUT/.git" ]]; then
    # A worktree of the real checkout: fine for checking this branch, and the
    # app will use the canonical one at run time.
    ok "running from $REPO_ROOT (canonical checkout also present at $CANONICAL_CHECKOUT)"
else
    failed "checkout location" "the app hard-codes $CANONICAL_CHECKOUT; clone there: git clone https://github.com/musicalengineer/VideoScan.git $CANONICAL_CHECKOUT"
fi

free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [[ "$free_gb" -ge 150 ]]; then
    ok "free disk: ${free_gb} GB"
else
    manual "free disk ${free_gb} GB" "a full setup with models needs ~150 GB (Xcode, venvs, Ollama, caches)"
fi
