# Shared helpers for install_videoscan_dev_dependencies/. Sourced, never run.
#
# Every step reports each dependency through exactly one of four verdicts so
# the summary at the end is honest about what happened:
#   ok        already present and working
#   installed this run put it in place
#   manual    needs a human (Rick): an App Store install, a sudo step, a login
#   failed    tried and could not; the reason says what to run to see why

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

VS_OK=(); VS_INSTALLED=(); VS_MANUAL=(); VS_FAILED=()

ok()        { echo "  ${GREEN}✓${RESET} $1";                    VS_OK+=("$1"); }
installed() { echo "  ${CYAN}+${RESET} installed: $1";          VS_INSTALLED+=("$1"); }
manual()    { echo "  ${YELLOW}!${RESET} manual: $1 — $2";      VS_MANUAL+=("$1: $2"); }
failed()    { echo "  ${RED}✗${RESET} failed: $1 — $2";         VS_FAILED+=("$1: $2"); }
note()      { echo "    ${DIM}$1${RESET}"; }
section()   { echo; echo "${BOLD}== $1 ==${RESET}"; }

# CHECK_ONLY=1 means report, never change the machine. Every step must honour
# it: in check mode a missing dependency is a `failed` (or `manual`) verdict,
# never an install.
CHECK_ONLY="${CHECK_ONLY:-0}"
checking() { [[ "$CHECK_ONLY" == "1" ]]; }

# Homebrew is not on PATH in non-login shells (ssh host ./install.sh) or on a
# Mac that has only just installed it. Put it there for this run.
ensure_brew_on_path() {
    command -v brew >/dev/null 2>&1 && return 0
    local candidate
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then
            eval "$("$candidate" shellenv)"
            return 0
        fi
    done
    return 1
}

# The app and many scripts hard-code ~/dev/VideoScan (ProcessRunner,
# ArcFaceEngine, POIStorage, FamilySearchPull…). A checkout anywhere else
# builds fine and then fails at run time, so the location is a requirement.
CANONICAL_CHECKOUT="$HOME/dev/VideoScan"

# Pinned interpreter versions. These follow what the M4 actually runs every
# day (verified 2026-10-05), not older notes in the Brewfile:
#   venv            Python 3.14 — all requirements.txt packages import on it
#   venv-mlx        Python 3.12 — mlx-vlm / mlx-whisper stack, kept separate
#   venv-genealogy  Python 3.14 — getmyancestors for the FamilySearch pull
MAIN_PYTHON="python3.14"
MLX_PYTHON="python3.12"
GENEALOGY_PYTHON="python3.14"
