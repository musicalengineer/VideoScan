#!/usr/bin/env bash
# install_gh_runner.sh — the GitHub Actions self-hosted runner on a fleet Mac (the M4):
# downloaded, registered to the repo, and kept alive as a LaunchAgent in the host's GUI
# session, so ci.yml's macOS jobs run on the M4 instead of waiting for a hosted image
# with Xcode 27 (docs/guides/operations.md §1).
#
#   scripts/install_gh_runner.sh install [--host m4|local] [--version X.Y.Z] [--labels a,b] [--name N]
#                                        [--token T] [--sha256 HEX] [--dry-run]
#   scripts/install_gh_runner.sh status  [--host m4|local] [--dry-run]
#   scripts/install_gh_runner.sh remove  [--host m4|local] [--token T] [--dry-run]
#
# Shape (install). The caller (normally the Ultra, where gh is logged in) does:
#   1. a registration token: --token, else
#      `gh api -X POST repos/<repo>/actions/runners/registration-token` — valid one hour,
#      good for one registration; it travels to the host on the ssh session's stdin,
#      never on a command line or in a file;
#   2. ships this script + scripts/gh_runner_release.py under <root>/bin/ on the host
#      (ssh for --host m4; a copy for --host local) and runs the host side there.
# The host side:
#   3. refuses if <root>/.runner exists (already registered: `remove` first; exit 3);
#   4. resolves the runner release (api.github.com: --version or latest; the asset
#      actions-runner-osx-arm64-<v>.tar.gz and its SHA-256 from the release notes —
#      gh_runner_release.py), downloads it into <root>/ (kept; a second install reuses it),
#      verifies the digest (--sha256 overrides the notes; no digest anywhere = refused),
#      and extracts it over <root>/;
#   5. `config.sh --unattended --replace` with the host's name and labels (the workflow
#      picks the M4 with runs-on: [self-hosted, macOS, ARM64, m4]);
#   6. writes a LaunchAgent com.videoscan.gh-runner (RunAtLoad + KeepAlive,
#      LimitLoadToSessionType Aqua, ProcessType Standard, PATH with Homebrew) that runs
#      <root>/run.sh, and bootstraps it in gui/<uid>. Ours, not the runner's svc.sh: that
#      plist creates its own session (SessionCreate), which has no window server, and
#      `xcodebuild test` launches the app as its test host in the logged-in desktop — the
#      same reason scripts/m4_run.sh uses a GUI LaunchAgent and not plain ssh.
#
# Roots: <root> = ~/actions-runner (the runner, its _work checkouts, _diag logs);
#        log ~/Library/Logs/VideoScan/gh_runner.log. DerivedData for the jobs is the
#        workflow's business (~/Library/Caches/videoscan-ghrunner-dd, ci.yml).
# Worst case on disk: the runner ~200 MB, one checkout under _work (~1 GB), the jobs'
# DerivedData (~15 GB, Debug), xcresults under _work kept until the next run.
#
# Exit: 0 · 1 host error · 2 usage · 3 already configured.
# Tests: tests/test_install_gh_runner.py (argument parsing, dry-run plans, the plist, the
# already-configured refusal, the release resolver). Nothing in the tests touches a host.

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

REPO_SLUG="${GH_RUNNER_REPO:-musicalengineer/VideoScan}"
REPO_URL="https://github.com/$REPO_SLUG"
RELEASES_API="${GH_RUNNER_RELEASES_API:-https://api.github.com/repos/actions/runner/releases}"
LABEL="com.videoscan.gh-runner"

usage() {
    sed -n '7,10p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 2
}

die() { echo "install_gh_runner: $*" >&2; exit "${2:-1}"; }

# ── Host configuration ────────────────────────────────────────────────────
# Same account on every fleet Mac, so $HOME names the host's home too.
host_config() {
    case "$1" in
        m4)    H_SSH="ricksm4.local"; H_NAME="M4"; DEFAULT_RUNNER_NAME="RicksM4"; DEFAULT_LABELS="m4,videoscan" ;;
        local) H_SSH=""; H_NAME="this Mac"
               DEFAULT_RUNNER_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
               DEFAULT_LABELS="videoscan" ;;
        *) die "unknown host '$1' (m4|local)" 2 ;;
    esac
    H_ROOT="$HOME/actions-runner"
    H_BIN="$H_ROOT/bin"
    H_LOG="$HOME/Library/Logs/VideoScan/gh_runner.log"
    H_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
}

# ── Running a command on the host (or printing it under --dry-run) ────────
on_host() {   # on_host <shell snippet>
    if [ "$DRY" = 1 ]; then
        if [ -n "$H_SSH" ]; then echo "+ ssh $H_SSH bash -s <<'SNIPPET'"; else echo "+ bash -s <<'SNIPPET'"; fi
        printf '%s\n' "$1" | sed 's/^/    /'
        echo "  SNIPPET"
        return 0
    fi
    if [ -n "$H_SSH" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$H_SSH" bash -s <<<"$1"
    else
        bash -s <<<"$1"
    fi
}

copy_to_host() {   # copy_to_host <local file> <host path>
    if [ "$DRY" = 1 ]; then
        echo "+ install $1 -> ${H_SSH:+$H_SSH:}$2"
        return 0
    fi
    if [ -n "$H_SSH" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$H_SSH" "cat > '$2' && chmod +x '$2'" <"$1"
    else
        cp "$1" "$2" && chmod +x "$2"
    fi
}

plist_xml() {   # the LaunchAgent: <root>/run.sh in the GUI session, restarted if it exits
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "  <key>Label</key><string>$LABEL</string>"
    echo '  <key>ProgramArguments</key>'
    echo '  <array>'
    echo '    <string>/bin/bash</string>'
    echo "    <string>$H_ROOT/run.sh</string>"
    echo '  </array>'
    echo "  <key>WorkingDirectory</key><string>$H_ROOT</string>"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo '  <key>LimitLoadToSessionType</key><string>Aqua</string>'
    # Standard, not Background (install_nightly.sh, 2026-10-01): Background pins a
    # build to the efficiency cores.
    echo '  <key>ProcessType</key><string>Standard</string>'
    echo '  <key>EnvironmentVariables</key>'
    echo '  <dict>'
    echo '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>'
    echo "    <key>HOME</key><string>$HOME</string>"
    echo '  </dict>'
    echo "  <key>StandardOutPath</key><string>$H_LOG</string>"
    echo "  <key>StandardErrorPath</key><string>$H_LOG</string>"
    echo '</dict>'
    echo '</plist>'
}

# ── Caller side ───────────────────────────────────────────────────────────
fetch_token() {   # fetch_token registration|remove → TOKEN
    local kind="$1"
    if [ -n "$TOKEN" ]; then return 0; fi
    if [ "$DRY" = 1 ]; then
        echo "+ gh api -X POST repos/$REPO_SLUG/actions/runners/$kind-token --jq .token   (on this machine)"
        TOKEN="<$kind token>"
        return 0
    fi
    command -v gh >/dev/null 2>&1 || die "no --token and no gh on this machine: pass --token (GitHub → Settings → Actions → Runners → New self-hosted runner)"
    TOKEN="$(gh api -X POST "repos/$REPO_SLUG/actions/runners/$kind-token" --jq .token 2>/dev/null)" \
        || die "gh could not mint a $kind token for $REPO_SLUG (is gh logged in as the repo's owner?)"
    [ -n "$TOKEN" ] || die "gh returned an empty $kind token"
}

ship() {
    on_host "mkdir -p '$H_BIN'" || die "could not prepare $H_BIN on $H_NAME"
    copy_to_host "$SELF" "$H_BIN/install_gh_runner.sh" || die "could not install this script on $H_NAME"
    copy_to_host "$SCRIPT_DIR/gh_runner_release.py" "$H_BIN/gh_runner_release.py" \
        || die "could not install the release resolver on $H_NAME"
}

start_install() {
    echo "install_gh_runner: $REPO_SLUG runner '$RUNNER_NAME' (labels $LABELS, release $VERSION) on $H_NAME"
    fetch_token registration
    ship
    local args="__host install --host '$HOST' --name '$RUNNER_NAME' --labels '$LABELS' --version '$VERSION'"
    [ -n "$SHA256" ] && args="$args --sha256 '$SHA256'"
    # The token rides the ssh session's stdin inside the snippet (never argv, never a file).
    # Under --dry-run the snippet shows the variable, never the value.
    local token_line="export GH_RUNNER_TOKEN='<redacted>'"
    [ "$DRY" = 1 ] || token_line="export GH_RUNNER_TOKEN='$TOKEN'"
    on_host "$token_line
bash '$H_BIN/install_gh_runner.sh' $args" || die "install on $H_NAME failed (see above)"
    [ "$DRY" = 1 ] && { echo "+ (then: the plist below, bootstrapped in gui/<uid>)"; plist_xml; }
    echo "install_gh_runner: check with: scripts/install_gh_runner.sh status --host $HOST"
}

start_remove() {
    echo "install_gh_runner: removing runner from $REPO_SLUG on $H_NAME (files under $H_ROOT stay)"
    fetch_token remove
    ship
    local token_line="export GH_RUNNER_TOKEN='<redacted>'"
    [ "$DRY" = 1 ] || token_line="export GH_RUNNER_TOKEN='$TOKEN'"
    on_host "$token_line
bash '$H_BIN/install_gh_runner.sh' __host remove --host '$HOST'" || die "remove on $H_NAME failed (see above)"
}

status_snippet() {
    cat <<SNIPPET
root='$H_ROOT'
if [ -f "\$root/.runner" ]; then
  python3 - "\$root/.runner" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("$H_NAME: runner %s registered at %s (work %s)" % (r.get("agentName","?"), r.get("gitHubUrl","?"), r.get("workFolder","?")))
PY
else
  echo "$H_NAME: no runner configured under \$root"
fi
state="\$(launchctl print "gui/\$(id -u)/$LABEL" 2>/dev/null | grep -E '^[[:space:]]*(state|pid) = ' | tr -s ' ' | tr '\n' ' ')"
echo "agent $LABEL: \${state:-not loaded}"
newest="\$(ls -t "\$root"/_diag/Runner_*.log 2>/dev/null | head -1)"
if [ -n "\$newest" ]; then
  echo "last from \$(basename "\$newest"):"
  grep -E 'Listening for Jobs|Running job:|Job .* completed with result' "\$newest" | tail -3 | sed 's/^/  /'
fi
SNIPPET
}

# ── Host side ─────────────────────────────────────────────────────────────
host_install() {
    local token="${GH_RUNNER_TOKEN:-}"
    mkdir -p "$H_ROOT" "$(dirname "$H_LOG")" "$(dirname "$H_PLIST")" || die "cannot prepare $H_ROOT"
    if [ -f "$H_ROOT/.runner" ]; then
        local who
        who="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agentName","?"))' "$H_ROOT/.runner" 2>/dev/null || echo '?')"
        echo "install_gh_runner: already configured under $H_ROOT as '$who' — scripts/install_gh_runner.sh remove --host $HOST first"
        exit 3
    fi
    [ -n "$token" ] || die "no registration token (GH_RUNNER_TOKEN is empty)"
    local api="$RELEASES_API/latest"
    [ "$VERSION" = latest ] || api="$RELEASES_API/tags/v$VERSION"
    curl -fsSL -H 'Accept: application/vnd.github+json' "$api" >"$H_ROOT/release.json" \
        || die "cannot read the runner release from $api"
    local ver url sha
    read -r ver url sha < <(python3 "$SCRIPT_DIR/gh_runner_release.py" "$H_ROOT/release.json") \
        || die "no osx-arm64 build in that release (see above)"
    [ -n "$SHA256" ] && sha="$SHA256"
    [ "$sha" != "-" ] || die "the release notes carry no SHA-256 for osx-arm64 — pass --sha256 <hex> from https://github.com/actions/runner/releases/tag/v$ver"
    local tgz="$H_ROOT/actions-runner-osx-arm64-$ver.tar.gz"
    if [ ! -f "$tgz" ]; then
        echo "downloading $url"
        { curl -fsSL -o "$tgz.part" "$url" && mv "$tgz.part" "$tgz"; } || die "download failed"
    fi
    local actual
    actual="$(shasum -a 256 "$tgz" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
        mv "$tgz" "$tgz.bad"
        die "SHA-256 mismatch for $(basename "$tgz"): got $actual, release says $sha (moved aside as .bad)"
    fi
    echo "runner $ver verified; extracting into $H_ROOT"
    tar xzf "$tgz" -C "$H_ROOT" || die "extract failed"
    ( cd "$H_ROOT" && ./config.sh --unattended --replace --url "$REPO_URL" --token "$token" \
        --name "$RUNNER_NAME" --labels "$LABELS" --work _work ) || die "config.sh failed"
    plist_xml >"$H_PLIST"
    local uid
    uid="$(id -u)"
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$H_PLIST" || die "could not bootstrap $LABEL in gui/$uid (is a user logged in at the desktop?)"
    echo "install_gh_runner: runner '$RUNNER_NAME' registered; LaunchAgent $LABEL running in gui/$uid; log $H_LOG"
}

host_remove() {
    local token="${GH_RUNNER_TOKEN:-}" uid
    uid="$(id -u)"
    if launchctl bootout "gui/$uid/$LABEL" 2>/dev/null; then echo "agent $LABEL stopped"; else echo "agent $LABEL was not loaded"; fi
    if [ -f "$H_PLIST" ]; then mv "$H_PLIST" "$H_PLIST.removed" && echo "plist moved aside: $H_PLIST.removed"; fi
    if [ -f "$H_ROOT/.runner" ]; then
        [ -n "$token" ] || die "no removal token (GH_RUNNER_TOKEN is empty)"
        ( cd "$H_ROOT" && ./config.sh remove --token "$token" ) || die "config.sh remove failed"
        echo "runner unregistered from $REPO_SLUG; files kept under $H_ROOT"
    else
        echo "no runner configured under $H_ROOT"
    fi
}

# ── Arguments ─────────────────────────────────────────────────────────────
CMD="${1:-}"; [ $# -gt 0 ] && shift
HOST=m4; DRY=0; VERSION=latest; LABELS=""; RUNNER_NAME=""; TOKEN=""; SHA256=""
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 || usage ;;
        --version) VERSION="${2:-}"; shift 2 || usage ;;
        --labels) LABELS="${2:-}"; shift 2 || usage ;;
        --name) RUNNER_NAME="${2:-}"; shift 2 || usage ;;
        --token) TOKEN="${2:-}"; shift 2 || usage ;;
        --sha256) SHA256="${2:-}"; shift 2 || usage ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        --*) die "unknown option $1" 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done
[ "$VERSION" = latest ] || [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "--version wants X.Y.Z or latest" 2
[ -z "$LABELS" ] || [[ "$LABELS" =~ ^[A-Za-z0-9_.,-]+$ ]] || die "--labels wants a,b (letters, digits, . _ -)" 2
[ -z "$SHA256" ] || [[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 wants 64 hex digits" 2
host_config "$HOST"
[ -n "$LABELS" ] || LABELS="$DEFAULT_LABELS"
[ -n "$RUNNER_NAME" ] || RUNNER_NAME="$DEFAULT_RUNNER_NAME"

case "$CMD" in
    install)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        start_install ;;
    remove)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        start_remove ;;
    status)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        [ "$DRY" = 1 ] && { on_host "$(status_snippet)"; exit 0; }
        on_host "$(status_snippet)" || die "cannot reach $H_NAME (${H_SSH:-local})" ;;
    __host)
        # On the host itself: no ssh, whatever --host says.
        H_SSH=""
        [ ${#POS[@]} -eq 1 ] || die "__host install|remove" 2
        case "${POS[0]}" in
            install) host_install ;;
            remove) host_remove ;;
            *) die "bad host command ${POS[0]}" 2 ;;
        esac ;;
    ""|-h|--help) usage ;;
    *) die "unknown command '$CMD' (install|status|remove)" 2 ;;
esac
