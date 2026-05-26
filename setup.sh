#!/usr/bin/env bash
# VideoScan — verify-and-install setup script.
# Idempotent: safe to run repeatedly. Prints a per-dependency verdict and
# installs anything missing where it can. At the end, summarizes the run
# and tells you what to do next.
#
# Usage:   ./setup.sh
# From:    repo root (anywhere under ~/dev/VideoScan)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$REPO_ROOT/venv"
PY_VERSION="3.12"
PYTHON="python${PY_VERSION}"

# ---- Pretty output (color only when stdout is a tty) ----
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

satisfied=()
installed=()
failed=()
skipped=()

say_satisfied() { echo "  ${GREEN}✓${RESET} dependency satisfied: $1";  satisfied+=("$1"); }
say_installed() { echo "  ${CYAN}+${RESET} installed: $1";              installed+=("$1"); }
say_failed()    { echo "  ${RED}✗${RESET} failed: $1 — $2";             failed+=("$1: $2"); }
say_skipped()   { echo "  ${YELLOW}–${RESET} skipped: $1 — $2";         skipped+=("$1: $2"); }
section()       { echo; echo "${BOLD}== $1 ==${RESET}"; }

# ---------------------------------------------------------------------------
section "System prerequisites"
# ---------------------------------------------------------------------------

# Xcode + Command Line Tools (cannot be installed by this script)
if xcode-select -p >/dev/null 2>&1; then
    say_satisfied "Xcode Command Line Tools ($(xcode-select -p))"
else
    say_failed "Xcode Command Line Tools" "run: xcode-select --install"
    echo
    echo "${RED}Xcode CLT is required. Install it (popup), then re-run ./setup.sh${RESET}"
    exit 1
fi

if command -v xcodebuild >/dev/null 2>&1; then
    say_satisfied "Xcode ($(xcodebuild -version | head -1))"
else
    say_skipped "Xcode" "not detected — install from Mac App Store to build the app"
fi

# Metal Toolchain — required to compile mlx-swift's Metal kernels.
# Auto-downloaded by xcodebuild on first build, but doing it explicitly
# here keeps the first-build experience predictable on a fresh machine.
# ~688 MB system asset, persisted across all Xcode invocations.
if command -v xcodebuild >/dev/null 2>&1; then
    # `xcodebuild -showComponents` lists currently-installed components; grep
    # for MetalToolchain. If absent, kick off the download.
    if xcodebuild -showComponents 2>/dev/null | grep -qi "metal.*toolchain"; then
        say_satisfied "Metal Toolchain (Xcode component)"
    else
        echo "  ${DIM}→ downloading Metal Toolchain (~688 MB, one-time)...${RESET}"
        if xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1; then
            say_installed "Metal Toolchain"
        else
            say_skipped "Metal Toolchain" "auto-download failed; Xcode will prompt on first MLX build"
        fi
    fi
fi

# Homebrew (cannot fully auto-install — interactive prompt for sudo)
# Probe canonical paths in addition to $PATH because SSH non-login shells
# (e.g. `ssh host "./setup.sh"`) inherit /usr/bin:/bin only — brew installed
# at /opt/homebrew/bin/brew won't be on PATH despite being present.
if command -v brew >/dev/null 2>&1; then
    say_satisfied "Homebrew ($(brew --version | head -1))"
elif [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    say_satisfied "Homebrew ($(brew --version | head -1)) [added /opt/homebrew to PATH for this run]"
elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
    say_satisfied "Homebrew ($(brew --version | head -1)) [added /usr/local to PATH for this run]"
else
    say_failed "Homebrew" "install from https://brew.sh and re-run"
    echo
    echo "${RED}Homebrew is required. Install it then re-run ./setup.sh${RESET}"
    exit 1
fi

# ---------------------------------------------------------------------------
section "Homebrew formulae"
# ---------------------------------------------------------------------------

check_brew_formula() {
    local name="$1"
    if brew list --formula --versions "$name" >/dev/null 2>&1; then
        local ver
        ver=$(brew list --versions "$name" | awk '{print $2}')
        say_satisfied "$name $ver"
    else
        echo "  ${DIM}→ installing $name...${RESET}"
        if brew install "$name" >/dev/null 2>&1; then
            local ver
            ver=$(brew list --versions "$name" | awk '{print $2}')
            say_installed "$name $ver"
        else
            say_failed "$name" "brew install failed (run 'brew install $name' to see errors)"
        fi
    fi
}

for f in ffmpeg python@3.12 uv cmake gh swiftlint periphery pre-commit jq; do
    check_brew_formula "$f"
done

# ---------------------------------------------------------------------------
section "Homebrew casks (GUI apps)"
# ---------------------------------------------------------------------------

check_brew_cask() {
    local name="$1"
    if brew list --cask --versions "$name" >/dev/null 2>&1; then
        local ver
        ver=$(brew list --cask --versions "$name" | awk '{print $2}')
        say_satisfied "$name (cask) $ver"
    else
        echo "  ${DIM}→ installing $name (cask)...${RESET}"
        if brew install --cask "$name" >/dev/null 2>&1; then
            say_installed "$name (cask)"
        else
            say_failed "$name" "brew install --cask failed (run 'brew install --cask $name' to see errors)"
        fi
    fi
}

for c in claude claude-code visual-studio-code; do
    check_brew_cask "$c"
done

# ---------------------------------------------------------------------------
section "Python virtual environment"
# ---------------------------------------------------------------------------

if ! command -v uv >/dev/null 2>&1; then
    say_failed "uv" "not on PATH after brew install — re-open terminal and retry"
elif ! command -v "$PYTHON" >/dev/null 2>&1; then
    say_failed "$PYTHON" "not on PATH after brew install — re-open terminal and retry"
else
    if [[ -x "$VENV/bin/python" ]]; then
        venv_ver=$("$VENV/bin/python" --version 2>&1 | awk '{print $2}')
        say_satisfied "venv at $VENV (Python $venv_ver)"
    else
        echo "  ${DIM}→ creating venv at $VENV with uv...${RESET}"
        if uv venv --python "$PYTHON" "$VENV" >/dev/null 2>&1; then
            venv_ver=$("$VENV/bin/python" --version 2>&1 | awk '{print $2}')
            say_installed "venv at $VENV (Python $venv_ver)"
        else
            say_failed "venv" "uv venv --python $PYTHON $VENV failed"
        fi
    fi

    if [[ -x "$VENV/bin/python" ]]; then
        if [[ -f "$REPO_ROOT/requirements.txt" ]]; then
            req_count=$(grep -cE '^[A-Za-z]' "$REPO_ROOT/requirements.txt")
            echo "  ${DIM}→ verifying $req_count Python packages against requirements.txt...${RESET}"

            # Capture pre-install freeze, install, capture post-install freeze, diff.
            before=$(VIRTUAL_ENV="$VENV" uv pip freeze 2>/dev/null | sort)
            if VIRTUAL_ENV="$VENV" uv pip install --quiet -r "$REPO_ROOT/requirements.txt" >/dev/null 2>&1; then
                after=$(VIRTUAL_ENV="$VENV" uv pip freeze 2>/dev/null | sort)
                new_pkgs=$(comm -13 <(echo "$before") <(echo "$after") | wc -l | tr -d ' ')
                if [[ "$new_pkgs" == "0" ]]; then
                    say_satisfied "all $req_count Python packages already installed"
                else
                    say_installed "$new_pkgs Python package(s) (of $req_count total)"
                fi
            else
                say_failed "Python packages" "uv pip install -r requirements.txt failed (run it directly to see errors)"
            fi
        else
            say_skipped "Python packages" "requirements.txt not found at repo root"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "MLX virtual environment (audio transcription + VLM captioning)"
# ---------------------------------------------------------------------------
# mlx-vlm and mlx-whisper require transformers>=5 / numpy>=2, which break
# facenet-pytorch in the main venv. Keep them isolated in venv-mlx/.

VENV_MLX="$REPO_ROOT/venv-mlx"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    say_skipped "venv-mlx" "$PYTHON not on PATH"
else
    if [[ -x "$VENV_MLX/bin/python" ]]; then
        vmlx_ver=$("$VENV_MLX/bin/python" --version 2>&1 | awk '{print $2}')
        say_satisfied "venv-mlx at $VENV_MLX (Python $vmlx_ver)"
    else
        echo "  ${DIM}→ creating venv-mlx at $VENV_MLX...${RESET}"
        if "$PYTHON" -m venv "$VENV_MLX" >/dev/null 2>&1; then
            vmlx_ver=$("$VENV_MLX/bin/python" --version 2>&1 | awk '{print $2}')
            say_installed "venv-mlx at $VENV_MLX (Python $vmlx_ver)"
        else
            say_failed "venv-mlx" "$PYTHON -m venv $VENV_MLX failed"
        fi
    fi

    if [[ -x "$VENV_MLX/bin/python" ]]; then
        if [[ -f "$REPO_ROOT/scripts/requirements-mlx.txt" ]]; then
            req_count=$(grep -cE '^[A-Za-z]' "$REPO_ROOT/scripts/requirements-mlx.txt")
            echo "  ${DIM}→ verifying $req_count MLX packages against requirements-mlx.txt...${RESET}"
            before=$("$VENV_MLX/bin/pip" freeze 2>/dev/null | sort)
            if "$VENV_MLX/bin/pip" install --quiet -r "$REPO_ROOT/scripts/requirements-mlx.txt" >/dev/null 2>&1; then
                after=$("$VENV_MLX/bin/pip" freeze 2>/dev/null | sort)
                new_pkgs=$(comm -13 <(echo "$before") <(echo "$after") | wc -l | tr -d ' ')
                if [[ "$new_pkgs" == "0" ]]; then
                    say_satisfied "all $req_count MLX packages already installed"
                else
                    say_installed "$new_pkgs MLX package(s) (of $req_count direct deps)"
                fi
            else
                say_failed "MLX packages" "venv-mlx pip install failed (run it directly to see errors)"
            fi
        else
            say_skipped "MLX packages" "scripts/requirements-mlx.txt not found"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "Git hooks (optional dev tooling)"
# ---------------------------------------------------------------------------

if [[ -d "$REPO_ROOT/.git" ]] && command -v pre-commit >/dev/null 2>&1; then
    if [[ -f "$REPO_ROOT/.git/hooks/pre-commit" ]] && grep -q "pre-commit" "$REPO_ROOT/.git/hooks/pre-commit" 2>/dev/null; then
        say_satisfied "pre-commit git hook installed"
    elif [[ -f "$REPO_ROOT/.pre-commit-config.yaml" ]]; then
        echo "  ${DIM}→ installing pre-commit hook...${RESET}"
        if (cd "$REPO_ROOT" && pre-commit install >/dev/null 2>&1); then
            say_installed "pre-commit git hook"
        else
            say_skipped "pre-commit hook" "pre-commit install failed"
        fi
    else
        say_skipped "pre-commit hook" "no .pre-commit-config.yaml at repo root"
    fi
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------

printf "  satisfied: %3d\n" "${#satisfied[@]}"
printf "  installed: %3d\n" "${#installed[@]}"
printf "  skipped:   %3d\n" "${#skipped[@]}"
printf "  failed:    %3d\n" "${#failed[@]}"

if (( ${#failed[@]} > 0 )); then
    echo
    echo "${RED}${BOLD}Some dependencies could not be installed:${RESET}"
    for f in "${failed[@]}"; do
        echo "  - $f"
    done
    echo
    echo "Resolve the issues above, then re-run ./setup.sh"
    exit 1
fi

echo
echo "${GREEN}${BOLD}All dependencies are met.${RESET}"
echo "Launch VideoScan with:"
echo "    open ${REPO_ROOT}/VideoScan/VideoScan.xcodeproj"
echo "Then build and run (⌘R) in Xcode."
echo
echo "${BOLD}Optional dev-machine speedup:${RESET}"
echo "  Mount a 32 GB RAM disk and point Xcode DerivedData at it for"
echo "  dramatically faster builds (Debug edit-build-run loop drops"
echo "  from ~3 min to ~5 sec). On the Mac Studio M4 Max this is a"
echo "  big win. Setup script lives at:"
echo "    ~/bin/setup-xcoderam.sh"
echo "  (If missing on this machine, see VideoScan's README or ask"
echo "   Claude to recreate it — it's a 10-line shell script.)"
echo
