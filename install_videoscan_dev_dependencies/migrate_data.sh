#!/usr/bin/env bash
# install_videoscan_dev_dependencies/migrate_data.sh
#
# Copies VideoScan's DATA from an old Mac to this one, for a migration like
# M4 → M5 Ultra. The dev tools come from install.sh; this is the part that
# cannot be re-downloaded: the catalog, People, CyberBrain, ledger, archive
# journals, and the git-ignored family photos and models in the checkout.
#
# Safety rules (Rick's delete-safety principle applies to copies too):
#   - PULL ONLY. The source Mac is read, never written (not even git's index).
#   - DRY RUN BY DEFAULT. Nothing is copied or moved until you add --go.
#   - Never deletes on this Mac. A file this copy would replace is kept
#     beside it as <name>.pre-migrate-<stamp>.
#   - Refuses while VideoScan, its helpers, or anything else has a database
#     open on either Mac (WAL files must be quiescent to copy consistently).
#   - Copies only git-IGNORED files into the checkout, from a list made on
#     the source, so it can never overwrite tracked code in the fresh clone.
#
# Usage:
#   ./migrate_data.sh --from RicksM4.local              dry run: what would copy
#   ./migrate_data.sh --from RicksM4.local --go         copy it
#   add --with-ollama  to also copy ~/.ollama/models   (~56 GB; or re-pull)
#   add --with-hf      to also copy ~/.cache/huggingface (~9 GB; or re-download)

set -euo pipefail

SOURCE=""
GO=0
WITH_OLLAMA=0
WITH_HF=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)        SOURCE="${2:-}"; shift 2 ;;
        --go)          GO=1; shift ;;
        --with-ollama) WITH_OLLAMA=1; shift ;;
        --with-hf)     WITH_HF=1; shift ;;
        -h|--help)     sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$SOURCE" ]] || { echo "usage: $0 --from HOST [--go] [--with-ollama] [--with-hf]" >&2; exit 2; }

die() { echo "REFUSING: $*" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
CHECKOUT="$HOME/dev/VideoScan"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

# macOS ships openrsync (protocol 29) as /usr/bin/rsync; it lacks the
# options used here. Use Homebrew's rsync 3.x on both ends.
RSYNC=/opt/homebrew/bin/rsync
[[ -x "$RSYNC" ]] || { echo "need Homebrew rsync on this Mac: brew install rsync" >&2; exit 1; }
"${SSH[@]}" "$SOURCE" test -x /opt/homebrew/bin/rsync \
    || { echo "need Homebrew rsync on $SOURCE (or $SOURCE unreachable): brew install rsync" >&2; exit 1; }

# -s protects paths with spaces ("Application Support"); --backup keeps any
# file this copy would replace; no --delete, ever.
RSYNC_OPTS=(-a -s --human-readable --stats
            --rsync-path=/opt/homebrew/bin/rsync
            -e "ssh -o BatchMode=yes -o ConnectTimeout=10"
            --backup --suffix=".pre-migrate-$STAMP")
if [[ "$GO" == "1" ]]; then
    echo "COPYING from $SOURCE (backups of replaced files: *.pre-migrate-$STAMP)"
else
    RSYNC_OPTS+=(--dry-run)
    echo "DRY RUN from $SOURCE — nothing will be copied or moved. Add --go to copy."
fi
[[ -d "$CHECKOUT/.git" ]] || { echo "clone the repo to $CHECKOUT first (then run install.sh)" >&2; exit 1; }

section() { echo; echo "== $1 =="; }

APP_SUPPORT="$HOME/Library/Application Support/VideoScan"
SRC_APP_SUPPORT="Library/Application Support/VideoScan"

# ---- refuse while anything has the data open, on either Mac ----
# `pgrep -x VideoScan` alone missed the --hallie helper, scripts and sqlite3
# (codex #122 F1). Two tests: the app and its helpers by command line, then
# lsof on every SQLite file in App Support. An ssh failure is a refusal, never
# "nothing running".
APP_PROCS='VideoScan[.]app/Contents/MacOS/|previewsweepd|findtagd'
DB_PATTERN='[.]sqlite(-wal|-shm|-journal)?$'
if pgrep -f "$APP_PROCS" >/dev/null; then
    die "VideoScan or one of its helpers is running on this Mac. Quit it first."
fi
rc=0; "${SSH[@]}" "$SOURCE" "pgrep -f '$APP_PROCS'" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] || {
    [[ "$rc" == "0" ]] && die "VideoScan or one of its helpers is running on $SOURCE. Quit it there first."
    die "could not check running processes on $SOURCE (ssh exit $rc)."
}
here_open=$( { lsof -Fn +d "$APP_SUPPORT" 2>/dev/null || true; } | { grep -E "$DB_PATTERN" || true; })
[[ -z "$here_open" ]] || die "a database in App Support is open on this Mac:"$'\n'"$here_open"
src_open=$("${SSH[@]}" "$SOURCE" "lsof -Fn +d '$SRC_APP_SUPPORT' 2>/dev/null | grep -E '$DB_PATTERN'; true") \
    || die "could not run lsof on $SOURCE."
[[ -z "$src_open" ]] || die "a database in App Support is open on $SOURCE:"$'\n'"$src_open"

# ---- 0. the databases travel as matched sets ----
# Since the 10/18 switch the catalog is catalog.sqlite + its WAL, with the
# catalog.cutover marker and the frozen catalog.json beside it. A Mac without
# the marker refuses to open the catalog (#354). EVERY SQLite file here
# (catalog, audio fingerprints, caches, catalog.pre-*.sqlite backups) is
# corrupted if it is paired with a WAL or journal left over from a DIFFERENT
# copy (codex #122 F1), so any such leftover on this Mac is moved aside first,
# and each copied set is proven byte-for-byte afterwards. -shm is never
# copied: SQLite rebuilds it from the WAL.
section "Database sets on $SOURCE"
for f in catalog.sqlite catalog.cutover; do
    "${SSH[@]}" "$SOURCE" "test -f '$SRC_APP_SUPPORT/$f'" \
        || die "$SOURCE has no $f (or is unreachable). Without both catalog.sqlite and catalog.cutover this Mac would refuse to open the catalog (#354)."
done
SRC_SET=$("${SSH[@]}" "$SOURCE" "cd '$SRC_APP_SUPPORT' && ls -1" | { grep -E '[.]sqlite(-wal|-journal)?$|^catalog[.](cutover|json)$' || true; }) \
    || die "could not list App Support on $SOURCE."
grep -qx 'catalog.sqlite' <<< "$SRC_SET" || die "the listing of $SOURCE has no catalog.sqlite."
# The hash commands below pass these names unquoted; refuse anything odd.
grep -qvE '^[A-Za-z0-9._-]+$' <<< "$SRC_SET" && die "a database file name on $SOURCE has unexpected characters:"$'\n'"$SRC_SET"
SRC_DBS=$(grep -E '[.]sqlite$' <<< "$SRC_SET")
SET_NAMES=$(tr '\n' ' ' <<< "$SRC_SET")

# "<sha256>  <name>" for every set file; fails if any file is missing or unreadable.
set_hashes() {
    if [[ "$1" == "source" ]]; then
        "${SSH[@]}" "$SOURCE" "cd '$SRC_APP_SUPPORT' && shasum -a 256 $SET_NAMES"
    else
        (cd "$APP_SUPPORT" && shasum -a 256 $SET_NAMES)
    fi
}
SRC_HASHES_BEFORE=$(set_hashes source) || die "could not hash the database set on $SOURCE."
echo "$SRC_HASHES_BEFORE"

while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    for side in -wal -shm -journal; do
        f="$db$side"
        [[ -e "$APP_SUPPORT/$f" ]] || continue
        if [[ "$GO" == "1" ]]; then
            mv -n "$APP_SUPPORT/$f" "$APP_SUPPORT/$f.pre-migrate-$STAMP"
            [[ -e "$APP_SUPPORT/$f" ]] && die "could not move the leftover $f here aside."
            echo "moved a leftover $f here aside: $f.pre-migrate-$STAMP"
        else
            echo "would move a leftover $f here aside (a WAL or journal beside a different $db corrupts it)"
        fi
    done
done <<< "$SRC_DBS"

# ---- 1. App Support: catalog, People, CyberBrain, ledger, journals ----
section "Application Support/VideoScan"
# HallieKokoro is rebuilt by install.sh (it is a compiled binary + model);
# preview-cache is regenerated on demand.
"$RSYNC" "${RSYNC_OPTS[@]}" \
    --exclude "HallieKokoro*" --exclude "preview-cache/" --exclude "*.sqlite-shm" \
    "$SOURCE:$SRC_APP_SUPPORT/" \
    "$APP_SUPPORT/"

# ---- 2. git-ignored data inside the checkout ----
section "Git-ignored data in ~/dev/VideoScan (family photos, models, profiles)"
# Built on the SOURCE, so it is exactly what that checkout ignores.
# --no-optional-locks: a plain `git status` may refresh and rewrite the
# source's .git/index (codex #122 F2). The list stays in memory: no temp file.
# A failed ssh or git aborts (F4); only the filters may legitimately match
# nothing. Excludes what install.sh rebuilds and scratch: venvs, build
# products, caches, worktrees, the repo trash, profiler output.
IGNORED=$("${SSH[@]}" "$SOURCE" "git --no-optional-locks -C dev/VideoScan status --ignored --porcelain -z" | tr '\0' '\n') \
    || die "could not list the ignored files in $SOURCE's checkout."
LIST=$(sed -n 's/^!! //p' <<< "$IGNORED" \
    | { grep -v -E '^(venv|venv-[^/]*|\.build|\.cache|\.pytest_cache|\.trash|\.worktrees|\.codex-worktrees|codex-worktrees|\.claude/worktrees)(/|$)' || true; } \
    | { grep -v -E '(^|/)(\.build[^/]*|__pycache__|DerivedData|\.swiftpm)(/|$)|\.DS_Store|default\.profraw' || true; })
count=$( [[ -z "$LIST" ]] && echo 0 || wc -l <<< "$LIST" | tr -d ' ')
echo "$count ignored paths listed on $SOURCE"
if [[ "$count" == "0" ]]; then
    echo "  (nothing to copy from the checkout: $SOURCE's checkout has no ignored data after the filters)"
else
    "$RSYNC" "${RSYNC_OPTS[@]}" -r --files-from=<(printf '%s\n' "$LIST") \
        "$SOURCE:dev/VideoScan/" "$CHECKOUT/"
fi

# ---- 3. optional big caches ----
if [[ "$WITH_OLLAMA" == "1" ]]; then
    section "Ollama models (~/.ollama/models)"
    "$RSYNC" "${RSYNC_OPTS[@]}" "$SOURCE:.ollama/models/" "$HOME/.ollama/models/"
fi
if [[ "$WITH_HF" == "1" ]]; then
    section "Hugging Face cache (~/.cache/huggingface)"
    "$RSYNC" "${RSYNC_OPTS[@]}" "$SOURCE:.cache/huggingface/" "$HOME/.cache/huggingface/"
fi

# ---- 4. prove the database copies ----
# Hashes first, before anything opens a copy. Then SQLite's own checks.
# The source DBs are never opened: equal bytes prove the row counts are equal.
# Every check that cannot run is a failure, never a pass (codex #122 F3).
# sqlite3 -readonly cannot open a WAL database whose -shm is absent (we never
# copy -shm), and a writable open would rebuild -shm and may checkpoint the
# WAL — changing the bytes just proven. So each check runs on a scratch copy
# of the set; the copied files are never opened.
sql_on_copy() {
    local t rc=0
    t=$(mktemp -d "${TMPDIR:-/tmp}/videoscan-migrate-check.XXXXXX") || return 1
    cp "$APP_SUPPORT/$1" "$t/" || rc=1
    [[ "$rc" == "0" && -f "$APP_SUPPORT/$1-wal" ]] && { cp "$APP_SUPPORT/$1-wal" "$t/" || rc=1; }
    [[ "$rc" == "0" ]] && { sqlite3 "$t/$1" "$2" 2>&1 || rc=$?; }
    rm -rf "$t"
    return "$rc"
}
if [[ "$GO" == "1" ]]; then
    section "Database check"
    bad=0
    SRC_HASHES_AFTER=$(set_hashes source) || { echo "  ✗ could not re-hash the set on $SOURCE"; SRC_HASHES_AFTER=""; bad=1; }
    HERE_HASHES=$(set_hashes here)        || { echo "  ✗ a set file is missing or unreadable here"; HERE_HASHES=""; bad=1; }
    if [[ "$SRC_HASHES_AFTER" != "$SRC_HASHES_BEFORE" ]]; then
        echo "  ✗ the database set changed on $SOURCE during the copy"; bad=1
    fi
    if [[ -n "$HERE_HASHES" && "$HERE_HASHES" == "$SRC_HASHES_BEFORE" ]]; then
        echo "  ✓ $(wc -l <<< "$SRC_SET" | tr -d ' ') files (databases, WALs, catalog.cutover, catalog.json) are byte-identical to $SOURCE's"
    else
        echo "  ✗ the copied set differs from $SOURCE's:"
        diff <(echo "$SRC_HASHES_BEFORE") <(echo "$HERE_HASHES") | sed 's/^/      /' || true
        bad=1
    fi
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        qc=$(sql_on_copy "$db" "pragma quick_check;") || true
        if [[ "$qc" == "ok" ]]; then echo "  ✓ quick_check ok: $db"; else echo "  ✗ quick_check $db: $qc"; bad=1; fi
    done <<< "$SRC_DBS"
    uv=$(sql_on_copy catalog.sqlite "pragma user_version;") || true
    rows=$(sql_on_copy catalog.sqlite "select count(*) from files;") || true
    if [[ "$uv" =~ ^[0-9]+$ ]] && (( uv >= 12 )); then
        echo "  ✓ catalog schema version $uv"
    else
        echo "  ✗ catalog schema version '$uv' (want 12 or newer)"; bad=1
    fi
    if [[ "$rows" =~ ^[0-9]+$ ]]; then
        echo "  ✓ catalog files rows: $rows (the Catalog tab here should show the same count as on $SOURCE)"
    else
        echo "  ✗ could not count catalog files: $rows"; bad=1
    fi
    if [[ "$bad" == "1" ]]; then
        echo
        echo "DATABASE COPY FAILED THE CHECK. Do not open VideoScan on this Mac." >&2
        echo "Anything replaced here is kept as *.pre-migrate-$STAMP." >&2
        exit 1
    fi
fi

# ---- 5. exactly one master ----
# Read-only: this script never writes either Mac's settings. The two Macs
# must agree on the master before either app is launched again. Unset means
# the app's built-in default (CatalogSync.swift defaultMasterHostname);
# unreadable is a failure, never a default (codex #122 F5).
section "Catalog master"
APP_DEFAULT_MASTER="RicksM4.local"
KEY="defaults read Rick-Breen.VideoScan CatalogSyncMasterHostname"
here_raw=$($KEY 2>/dev/null) && here_state="set" || { here_raw=""; here_state="unset"; }
src_out=$("${SSH[@]}" "$SOURCE" "v=\$($KEY 2>/dev/null) && echo \"set \$v\" || echo unset") \
    || die "could not read the master setting on $SOURCE."
src_state=${src_out%% *}
src_raw=""; [[ "$src_state" == "set" ]] && src_raw=${src_out#set }
here_master=${here_raw:-$APP_DEFAULT_MASTER}
src_master=${src_raw:-$APP_DEFAULT_MASTER}
echo "  this Mac:   $here_master ($here_state$([[ "$here_state" == "unset" ]] && echo ", app default"))"
echo "  $SOURCE: $src_master ($src_state$([[ "$src_state" == "unset" ]] && echo ", app default"))"
if [[ "$here_master" != "$src_master" ]]; then
    echo "  ✗ THEY DISAGREE: two masters would let two catalogs drift apart. On BOTH Macs, before launching:" >&2
    echo "      defaults write Rick-Breen.VideoScan CatalogSyncMasterHostname <the one master>.local" >&2
    exit 3
fi
echo "  ✓ both Macs name $here_master as the master."
[[ "$here_state" == "unset" && "$src_state" == "unset" ]] \
    && echo "    (neither sets it; if this Mac should become the master, set it explicitly on BOTH Macs)"

echo
if [[ "$GO" == "1" ]]; then
    echo "Done. Next: ./install.sh --check, then open VideoScan and confirm the catalog count matches $SOURCE."
else
    echo "Dry run complete. Review the totals above, then re-run with --go."
fi
