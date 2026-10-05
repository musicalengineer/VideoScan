#!/usr/bin/env bash
# install_videoscan_dev_dependencies/install.sh
#
# Turns a fresh Apple Silicon Mac (macOS 27, Xcode 27) into a VideoScan
# development machine: everything needed to build, run and test the app,
# its Python scripts and its helpers. Idempotent — re-run it as often as you
# like; anything already in place is reported and left alone.
#
# What it does NOT do (Rick does these by hand — see README.md):
#   install Xcode, sign in to accounts, grant Full Disk Access, sudo steps,
#   build the app.
#
# Usage:
#   ./install.sh                     install everything that is missing
#   ./install.sh --check             report only; change nothing
#   ./install.sh --only python,models
#   ./install.sh --skip helpers
#   ./install.sh --with-models       also pull the big models (Ollama ~18 GB,
#                                    Hugging Face ~2.5 GB)
#   ./install.sh --copy-from RicksM4.local
#                                    copy the untracked CoreML face models
#                                    (models/, ~335 MB) from another Mac
#   ./install.sh --repo ~/dev/VideoScan
#                                    act on another checkout (e.g. check the
#                                    live one from a worktree)
#   ./install.sh --with-schedules    install this machine's LaunchAgents
#                                    (nightly, sanitizers). Off by default:
#                                    a new Mac must not start running nightly
#                                    jobs until its fleet role is decided.
#
# Steps, in order:  preflight homebrew xcode python models helpers devtools verify

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ALL_STEPS=(preflight homebrew xcode python models helpers devtools verify)
ONLY=""
SKIP=""
WITH_MODELS=0
WITH_SCHEDULES=0
COPY_FROM=""

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)          CHECK_ONLY=1; shift ;;
        --only)           ONLY="${2:-}"; shift 2 ;;
        --skip)           SKIP="${2:-}"; shift 2 ;;
        --with-models)    WITH_MODELS=1; shift ;;
        --with-schedules) WITH_SCHEDULES=1; shift ;;
        --copy-from)      COPY_FROM="${2:-}"; shift 2 ;;
        --repo)           REPO_ROOT="$(cd "${2:-}" && pwd)"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
export CHECK_ONLY WITH_MODELS WITH_SCHEDULES COPY_FROM REPO_ROOT

wanted() {
    local step="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$step,"* ]] || return 1
    fi
    [[ ",$SKIP," == *",$step,"* ]] && return 1
    return 0
}

started=$(date +%s)
echo "${BOLD}VideoScan developer environment${RESET} — $(scutil --get LocalHostName 2>/dev/null || hostname -s)"
echo "repo: $REPO_ROOT"
checking && echo "${YELLOW}--check: reporting only, nothing will be installed${RESET}"

ensure_brew_on_path || true

for step in "${ALL_STEPS[@]}"; do
    wanted "$step" || continue
    file=$(ls "$HERE"/steps/[0-9][0-9]_"$step".sh 2>/dev/null | head -1)
    if [[ -z "$file" ]]; then
        failed "step $step" "no steps/NN_$step.sh"
        continue
    fi
    # shellcheck source=/dev/null
    source "$file"
    # preflight stops the run when a hard prerequisite is missing: nothing
    # later can succeed without Xcode, Homebrew and an arm64 Mac.
    if [[ "$step" == "preflight" && "${PREFLIGHT_BLOCKED:-0}" == "1" ]]; then
        echo
        echo "${RED}${BOLD}Stopping: fix the preflight items above, then re-run.${RESET}"
        break
    fi
done

section "Summary"
printf "  already in place: %3d\n" "${#VS_OK[@]}"
printf "  installed now:    %3d\n" "${#VS_INSTALLED[@]}"
printf "  needs Rick:       %3d\n" "${#VS_MANUAL[@]}"
printf "  failed:           %3d\n" "${#VS_FAILED[@]}"
printf "  time:             %ss\n" "$(( $(date +%s) - started ))"

if (( ${#VS_MANUAL[@]} > 0 )); then
    echo; echo "${YELLOW}${BOLD}For you to do by hand:${RESET}"
    for item in "${VS_MANUAL[@]}"; do echo "  - $item"; done
fi
if (( ${#VS_FAILED[@]} > 0 )); then
    echo; echo "${RED}${BOLD}Failed:${RESET}"
    for item in "${VS_FAILED[@]}"; do echo "  - $item"; done
    echo; echo "Fix those, then re-run: $HERE/install.sh"
    exit 1
fi
echo; echo "${GREEN}${BOLD}Developer environment ready.${RESET}"
echo "Next: open $REPO_ROOT/VideoScan/VideoScan.xcodeproj, scheme VideoScan, Debug, ⌘R."
exit 0
