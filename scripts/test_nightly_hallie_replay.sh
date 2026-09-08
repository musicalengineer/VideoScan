#!/bin/bash
# test_nightly_hallie_replay.sh — the replay runner's preflight, against a
# stub ollama. Born of the first nightly run (2026-09-08 02:37): the wrong
# model tag cost 900 s and paired zero turns. Run: scripts/test_nightly_hallie_replay.sh
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
PID=$(stub "$PORT" "qwen3.8:27b,devstral:24b"); sleep 0.5

echo "Test 1: no --model → the host's plain tag is chosen"
out=$("$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r1.json" --host "http://127.0.0.1:$PORT" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "model=qwen3.8:27b" && ok "chose qwen3.8:27b ($out)" || fail "rc=$rc $out"

echo "Test 2: a model the host lacks fails in seconds with the reason, lanes not-run"
start=$(date +%s)
out=$("$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r2.json" --host "http://127.0.0.1:$PORT" --model qwen3.8:27b-mlx 2>&1); rc=$?
took=$(( $(date +%s) - start ))
status=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["hallie_replay_status"], d["hallie_strict_status"], d.get("hallie_replay_reason","")[:40])' "$T/r2.json" 2>/dev/null)
[ "$rc" = 1 ] && [ "$took" -lt 30 ] && echo "$status" | grep -q "^failed not-run model qwen3.8:27b-mlx is not on" && ok "failed fast (${took}s): $status" || fail "rc=$rc took=${took}s status=$status"

echo "Test 3: a host that does not answer fails with the reason"
out=$("$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r3.json" --host "http://127.0.0.1:1" --model qwen3.8:27b 2>&1); rc=$?
reason=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hallie_replay_reason",""))' "$T/r3.json" 2>/dev/null)
[ "$rc" = 1 ] && echo "$reason" | grep -q "did not answer" && ok "$reason" || fail "rc=$rc reason=$reason"

echo "Test 4: --model present on the host passes preflight"
out=$("$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r4.json" --host "http://127.0.0.1:$PORT" --model devstral:24b --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "model=devstral:24b" && ok "$out" || fail "rc=$rc $out"

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
rm -rf "$T"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
