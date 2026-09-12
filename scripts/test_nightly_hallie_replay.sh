#!/bin/bash
# test_nightly_hallie_replay.sh — the replay runner's host/model defaults and
# preflight, against a stub ollama. Born of the first nightly run (2026-09-08
# 02:37): the wrong model tag cost 900 s and paired zero turns. Extended
# 2026-09-12 when the defaults moved to the M4's own ollama (127.0.0.1) and
# the app's SELECTED brain, after the M5 slept through the 09/11->12 night.
# Run: scripts/test_nightly_hallie_replay.sh
set -u
REPO=${REPO:-$HOME/dev/VideoScan}
T=$(mktemp -d /tmp/hallie-replay-test.XXXXXX)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# A stub /api/tags server listing the models named in its argument. Its
# output is redirected so the $(…) that captures the PID returns at once.
stub() {
    python3 - "$1" "$2" > "$T/stub.log" 2>&1 <<'PYEOF' &
import http.server, json, sys
port = int(sys.argv[1]); names = [n for n in sys.argv[2].split(",") if n]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"models": [{"name": n} for n in names]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
    echo $!
}
PORT=$(( 20000 + RANDOM % 10000 ))
PID=$(stub "$PORT" "qwen3.8:27b-mlx,devstral:24b"); sleep 0.5
STUB="http://127.0.0.1:$PORT"

# The app's Settings > Archivist Brain, stood in for by a plist file so the
# tests never read (or depend on) Rick's real preference. UNSET points at a
# file that does not exist; SET names devstral:24b.
UNSET="$T/no-such-prefs.plist"
SET="$T/app-prefs.plist"
python3 -c 'import plistlib,sys; open(sys.argv[1],"wb").write(plistlib.dumps({"archivist.ollamaModel": "devstral:24b"}))' "$SET"

# Every case scrubs the env overrides first so a developer's shell cannot
# leak into the assertions; the case that tests an override sets it inline.
run() { env -u VIDEOSCAN_HALLIE_REPLAY_HOST -u VIDEOSCAN_HALLIE_REPLAY_MODEL "$@"; }
reason_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hallie_replay_reason",""))' "$1" 2>/dev/null; }
field_of()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

echo "Test 1: no --model, app setting unset → the documented brain qwen3.8:27b-mlx"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r1.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'model=qwen3.8:27b-mlx source="documented brain' && ok "$out" || fail "rc=$rc $out"

echo "Test 2: no --model, app setting SET → the app's selected brain, not the host's list"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$SET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r2.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'model=devstral:24b source="app setting archivist.ollamaModel"' && ok "$out" || fail "rc=$rc $out"

echo "Test 3: VIDEOSCAN_HALLIE_REPLAY_MODEL outranks the app setting; --model outranks the env"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$SET" VIDEOSCAN_HALLIE_REPLAY_MODEL=qwen3.8:27b-mlx "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r3a.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'model=qwen3.8:27b-mlx source="VIDEOSCAN_HALLIE_REPLAY_MODEL"' && ok "env: $out" || fail "env: rc=$rc $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$SET" VIDEOSCAN_HALLIE_REPLAY_MODEL=qwen3.8:27b-mlx "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r3b.json" --host "$STUB" --model devstral:24b --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'model=devstral:24b source="--model"' && ok "flag: $out" || fail "flag: rc=$rc $out"

echo "Test 4: the default host is the M4's own ollama at 127.0.0.1:11434; the env override and --host outrank it"
# The default case may pass or fail preflight depending on what is really
# listening on this machine; only the chosen host is asserted.
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r4a.json" --model qwen3.8:27b-mlx --dry-run 2>&1)
echo "$out" | grep -q '^dry-run: host=http://127.0.0.1:11434 ' && ok "default: $out" || fail "default: $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" VIDEOSCAN_HALLIE_REPLAY_HOST="$STUB" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r4b.json" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "^dry-run: host=$STUB " && ok "env: $out" || fail "env: rc=$rc $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" VIDEOSCAN_HALLIE_REPLAY_HOST="http://127.0.0.1:1" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r4c.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "^dry-run: host=$STUB " && ok "flag: $out" || fail "flag: rc=$rc $out"

echo "Test 5: a model the host lacks fails in seconds, names host + tag, lanes not-run"
start=$(date +%s)
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r5.json" --host "$STUB" --model qwen3.8:27b 2>&1); rc=$?
took=$(( $(date +%s) - start ))
reason=$(reason_of "$T/r5.json"); status="$(field_of "$T/r5.json" hallie_replay_status) $(field_of "$T/r5.json" hallie_strict_status) $(field_of "$T/r5.json" hallie_advisory_status)"
if [ "$rc" = 1 ] && [ "$took" -lt 30 ] && [ "$status" = "failed not-run not-run" ] \
   && echo "$reason" | grep -q "^model qwen3.8:27b (--model) is not on $STUB (has: qwen3.8:27b-mlx devstral:24b"; then
    ok "failed fast (${took}s): $reason"
else
    fail "rc=$rc took=${took}s status=$status reason=$reason"
fi

echo "Test 6: a host that does not answer fails with a reason naming host AND the wanted tag"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$SET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r6.json" --host "http://127.0.0.1:1" 2>&1); rc=$?
reason=$(reason_of "$T/r6.json")
[ "$rc" = 1 ] && echo "$reason" | grep -q "^host http://127.0.0.1:1 did not answer /api/tags (or lists no models); wanted model devstral:24b (app setting archivist.ollamaModel)" \
    && [ "$(field_of "$T/r6.json" hallie_replay_model_source)" = "app setting archivist.ollamaModel" ] \
    && ok "$reason" || fail "rc=$rc reason=$reason"

echo "Test 7: --model present on the host passes preflight"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r7.json" --host "$STUB" --model devstral:24b --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "model=devstral:24b" && ok "$out" || fail "rc=$rc $out"

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
rm -rf "$T"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
