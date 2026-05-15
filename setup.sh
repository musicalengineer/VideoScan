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
PY_VERSION="3.13"
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

# Homebrew (cannot fully auto-install — interactive prompt for sudo)
if command -v brew >/dev/null 2>&1; then
    say_satisfied "Homebrew ($(brew --version | head -1))"
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

for f in ffmpeg python@3.13 cmake gh swiftlint periphery pre-commit jq; do
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

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    say_failed "$PYTHON" "not on PATH after brew install — re-open terminal and retry"
else
    if [[ -x "$VENV/bin/python" ]]; then
        venv_ver=$("$VENV/bin/python" --version 2>&1 | awk '{print $2}')
        say_satisfied "venv at $VENV (Python $venv_ver)"
    else
        echo "  ${DIM}→ creating venv at $VENV...${RESET}"
        if "$PYTHON" -m venv "$VENV" >/dev/null 2>&1; then
            venv_ver=$("$VENV/bin/python" --version 2>&1 | awk '{print $2}')
            say_installed "venv at $VENV (Python $venv_ver)"
        else
            say_failed "venv" "$PYTHON -m venv failed"
        fi
    fi

    if [[ -x "$VENV/bin/pip" ]]; then
        # Upgrade pip silently if behind.
        "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true

        if [[ -f "$REPO_ROOT/requirements.txt" ]]; then
            req_count=$(grep -cE '^[A-Za-z]' "$REPO_ROOT/requirements.txt")
            echo "  ${DIM}→ verifying $req_count Python packages against requirements.txt...${RESET}"

            # Capture pre-install freeze, install, capture post-install freeze, diff.
            before=$("$VENV/bin/pip" freeze 2>/dev/null | sort)
            if "$VENV/bin/pip" install --quiet -r "$REPO_ROOT/requirements.txt" >/dev/null 2>&1; then
                after=$("$VENV/bin/pip" freeze 2>/dev/null | sort)
                new_pkgs=$(comm -13 <(echo "$before") <(echo "$after") | wc -l | tr -d ' ')
                if [[ "$new_pkgs" == "0" ]]; then
                    say_satisfied "all $req_count Python packages already installed"
                else
                    say_installed "$new_pkgs Python package(s) (of $req_count total)"
                fi
            else
                say_failed "Python packages" "pip install -r requirements.txt failed (run it directly to see errors)"
            fi
        else
            say_skipped "Python packages" "requirements.txt not found at repo root"
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
