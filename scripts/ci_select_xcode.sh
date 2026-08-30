#!/usr/bin/env bash
#
# Select a Swift 6.2+ toolchain for CI and verify it.
#
# WHY THIS EXISTS
# ---------------
# Since 8826951f (2026-06-10) the app uses Swift 6.2 isolated conformances
# — `final class TranscodeJob: @MainActor MediaFileOperationJob` (SE-0470),
# in 18 files. Swift 6.1, which ships with Xcode 16.4, cannot parse that;
# it reports `error: unknown attribute 'MainActor'`. CI was pinned to
# /Applications/Xcode_16.4.app, so every run from mid-June to 2026-08-30
# died in SwiftCompile without reaching a single test.
#
# The 16.4 pin was deliberate once (a5b9e755, 2026-05-11) — a workaround
# for slow hosted test runs. It is no longer a choice: 16.4 cannot compile
# this source at all.
#
# Two design points, both aimed at not repeating the failure:
#
#  1. Resolve by glob, newest first, never a hard-coded app path. GitHub's
#     images add and retire Xcode point releases continuously; a pinned
#     path silently rots. Today the macos-15 image carries 26.0.1, 26.1.1,
#     26.2 and 26.3.
#  2. Verify the resulting compiler is actually >= 6.2 and fail loudly here
#     if not. Otherwise the failure surfaces 4 minutes later as "unknown
#     attribute", which reads like a source bug — that misdirection is why
#     this went unnoticed for ten weeks.
#
# Usage:  scripts/ci_select_xcode.sh          # newest Xcode 26.x
#         scripts/ci_select_xcode.sh 27       # newest Xcode 27.x
#         RESOLVE_ONLY=1 scripts/ci_select_xcode.sh   # print path, don't switch
#         scripts/ci_select_xcode.sh --selftest       # verify the resolver
#
# RESOLVE_ONLY prints EXACTLY ONE line on stdout — the developer dir — so it
# is safe in command substitution. Every diagnostic goes to stderr.
# XCODE_APPS_DIR overrides /Applications; it exists so --selftest can point
# the resolver at fixtures without patching the script.
#
# -e matters here (codex review, #885): without it a failing
# `sudo xcode-select -s` would fall through and the checks below would then
# describe whatever toolchain was ALREADY selected. On an image whose default
# happens to be 26.x that turns a failed selection into a silent pass — the
# exact class of masking this script exists to prevent.
set -euo pipefail

if [ "${1:-}" = "--selftest" ]; then SELFTEST=1; shift; else SELFTEST=0; fi
MAJOR_WANTED="${1:-26}"
APPS_DIR="${XCODE_APPS_DIR:-/Applications}"
MIN_SWIFT_MAJOR=6
MIN_SWIFT_MINOR=2

if [ "$SELFTEST" -eq 1 ]; then
  # Pins the resolver's contract against fixtures. These started as
  # throwaway probes during review; they belong in the repo, because every
  # one of them corresponds to a hole that review actually found.
  _self_fail=0
  _mkapp() { mkdir -p "$1/Contents/Developer/usr/bin"
             : > "$1/Contents/Developer/usr/bin/xcodebuild"
             chmod +x "$1/Contents/Developer/usr/bin/xcodebuild"; }
  _check() { # name, expected-basename-or-FAIL, apps-dir
    _out=$(XCODE_APPS_DIR="$3" RESOLVE_ONLY=1 "$0" "${4:-26}" 2>/dev/null) && _rc=0 || _rc=$?
    if [ "$2" = "FAIL" ]; then
      if [ "$_rc" -eq 0 ]; then echo "SELFTEST FAIL: $1 — expected rc!=0, got a path: $_out"; _self_fail=1
      else echo "SELFTEST PASS: $1 (rc=$_rc)"; fi
      return
    fi
    _lines=$(printf '%s\n' "$_out" | grep -c . || true)
    if [ "$_lines" != "1" ]; then
      echo "SELFTEST FAIL: $1 — RESOLVE_ONLY stdout must be exactly 1 line, got $_lines"; _self_fail=1; return
    fi
    case "$_out" in
      */"$2"/Contents/Developer) echo "SELFTEST PASS: $1 -> $2" ;;
      *) echo "SELFTEST FAIL: $1 — expected $2, got $_out"; _self_fail=1 ;;
    esac
  }

  _t=$(mktemp -d); _mkapp "$_t/Xcode_26.0.1.app"; _mkapp "$_t/Xcode_26.2.app"
  _mkapp "$_t/Xcode_26.3.app"; _mkapp "$_t/Xcode_26.10.app"
  _check "newest wins, 26.10 > 26.3 (version sort, not lexical)" "Xcode_26.10.app" "$_t"

  _t=$(mktemp -d); _mkapp "$_t/Xcode_26.3.app"; _mkapp "$_t/Xcode_26.4_beta.app"
  _mkapp "$_t/Xcode_26.5_Release_Candidate.app"
  _check "beta and RC basenames rejected" "Xcode_26.3.app" "$_t"

  _t=$(mktemp -d); _mkapp "$_t/Xcode_26.3.app"; _mkapp "$_t/Xcode_26_beta_9.app"
  ln -s "$_t/Xcode_26_beta_9.app" "$_t/Xcode_26.9.9.app"
  _check "numeric alias to a beta rejected even though it sorts higher" "Xcode_26.3.app" "$_t"

  _t=$(mktemp -d); _mkapp "$_t/Xcode_26_beta_9.app"
  ln -s "$_t/Xcode_26_beta_9.app" "$_t/Xcode_26.9.9.app"
  _check "only a beta alias present" "FAIL" "$_t"

  _t=$(mktemp -d); _mkapp "$_t/Xcode_26.3.app"; ln -s "$_t/Xcode_26.3.app" "$_t/Xcode_26.3.0.app"
  _check "legitimate alias to a stable bundle still accepted, deduped" "Xcode_26.3.app" "$_t"

  _t=$(mktemp -d); _mkapp "$_t/Xcode_16.4.app"
  _check "no 26.x installed" "FAIL" "$_t"

  # The stdout/stderr split itself: notes must not pollute the contract.
  _t=$(mktemp -d); _mkapp "$_t/Xcode_26.3.app"; ln -s "$_t/Xcode_26.3.app" "$_t/Xcode_26.3.0.app"
  _err=$(XCODE_APPS_DIR="$_t" RESOLVE_ONLY=1 "$0" 26 2>&1 >/dev/null || true)
  case "$_err" in
    *"resolves to"*) echo "SELFTEST PASS: symlink note goes to stderr" ;;
    *) echo "SELFTEST FAIL: expected a resolution note on stderr, got: $_err"; _self_fail=1 ;;
  esac

  if [ "$_self_fail" -ne 0 ]; then echo "SELFTEST: FAILURES ABOVE"; exit 1; fi
  echo "SELFTEST: all resolver checks passed"
  exit 0
fi

# Stable releases only (codex review, #903). The bare glob also matches
# Xcode_26.4_beta.app and release candidates; a CI toolchain should not be
# silently upgraded to a beta because one landed on the image. Accept a
# basename only when everything between "Xcode_" and ".app" is digits and
# dots — Xcode_26.app, Xcode_26.3.app, Xcode_26.1.1.app — then version-sort
# the survivors and take the newest.
# Accept a candidate only when BOTH the name we found it under and the
# bundle it actually resolves to are stable numeric forms.
#
# The name check alone is not enough (codex review, #913): GitHub's runner
# images publish NUMERIC ALIASES to beta bundles —
#   Xcode_27.0.0.app -> Xcode_27_beta_3.app
# The alias passes a digits-and-dots basename test, and `[ -d ]` and `-x`
# both follow the symlink, so a beta would be selected by a filter written
# to exclude betas. Canonicalising with `cd`+`pwd -P` (no readlink -f
# needed) and re-testing the REAL basename closes that.
is_stable_version_name() {
  _ver=${1#Xcode_}
  _ver=${_ver%.app}
  case "$_ver" in
    ""|*[!0-9.]*) return 1 ;;
    *) return 0 ;;
  esac
}

CANDIDATES=""
for app in "$APPS_DIR/Xcode_${MAJOR_WANTED}"*.app; do
  [ -d "$app" ] || continue          # unmatched glob stays literal; skip it
  is_stable_version_name "${app##*/}" || continue

  real=$(cd "$app" 2>/dev/null && pwd -P) || continue
  realbase=${real##*/}
  if [ "$realbase" != "${app##*/}" ]; then
    echo "note: ${app##*/} resolves to $realbase" >&2
  fi
  is_stable_version_name "$realbase" || continue

  # Also require the resolved bundle to still be the major we asked for, so
  # an alias cannot smuggle in a different release train.
  case "$realbase" in
    "Xcode_${MAJOR_WANTED}.app"|"Xcode_${MAJOR_WANTED}."*) ;;
    *) continue ;;
  esac

  [ -x "$real/Contents/Developer/usr/bin/xcodebuild" ] || continue
  CANDIDATES="${CANDIDATES}${real}
"
done
# Aliases can resolve to the same bundle twice; keep one of each.
CANDIDATES=$(printf '%s' "$CANDIDATES" | grep -v '^$' | sort -u || true)

DEV=""
NEWEST=$(printf '%s' "$CANDIDATES" | grep -v '^$' | sort -Vr | head -1 || true)
if [ -n "$NEWEST" ]; then
  DEV="$NEWEST/Contents/Developer"
fi

if [ -z "$DEV" ]; then
  echo "::error::No Xcode ${MAJOR_WANTED}.x found — this source needs Swift ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR}+. Installed: $(ls -d "$APPS_DIR"/Xcode*.app 2>/dev/null | tr '\n' ' ')"
  exit 1
fi

if [ -n "${RESOLVE_ONLY:-}" ]; then
  echo "$DEV"
  exit 0
fi

if ! sudo xcode-select -s "$DEV"; then
  echo "::error::xcode-select failed to switch to $DEV"
  exit 1
fi
echo "Selected $DEV"
xcodebuild -version

# Two corrections from codex review #903, both mine to own:
#
#  - `xcrun swift`, not bare `swift`. xcrun resolves through the developer
#    dir we just selected; a bare PATH lookup can find a different Swift
#    entirely (a toolchain installer, a Homebrew shim) and then the gate
#    describes something other than what will do the compiling.
#  - Check the exit status. The previous revision used `|| true` so that a
#    failing toolchain would still reach a readable error. That fixed one
#    silent pass and created another: a compiler that FAILS but still
#    prints a parseable "Apple Swift version 6.x" banner satisfied the
#    regex and sailed through. Keep the raw output for diagnosis, but a
#    non-zero exit is fatal on its own.
SWIFT_RC=0
SWIFT_RAW=$(xcrun swift --version 2>&1) || SWIFT_RC=$?
echo "$SWIFT_RAW"
if [ "$SWIFT_RC" -ne 0 ]; then
  echo "::error::xcrun swift --version failed (rc=$SWIFT_RC) for the toolchain at $DEV — see its output above."
  exit 1
fi
SWIFT_VER=$(printf '%s\n' "$SWIFT_RAW" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
if [ -z "$SWIFT_VER" ]; then
  echo "::error::Could not parse a Swift version from the selected toolchain at $DEV."
  exit 1
fi
SWIFT_MAJOR=${SWIFT_VER%%.*}
SWIFT_MINOR=$(echo "${SWIFT_VER}." | cut -d. -f2)
if [ "$SWIFT_MAJOR" -lt "$MIN_SWIFT_MAJOR" ] || \
   { [ "$SWIFT_MAJOR" -eq "$MIN_SWIFT_MAJOR" ] && [ "${SWIFT_MINOR:-0}" -lt "$MIN_SWIFT_MINOR" ]; }; then
  echo "::error::Swift $SWIFT_VER is too old — isolated conformances need ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR}+ (Xcode ${MAJOR_WANTED}.x)."
  exit 1
fi
echo "Swift $SWIFT_VER OK (need >= ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR})"
