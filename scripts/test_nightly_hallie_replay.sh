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
    def send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        self.send({"models": [{"name": n} for n in names]})
    def do_POST(self):
        # The load call (/api/generate, no prompt). "broken:1b" is listed but will not load.
        want = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}").get("model")
        self.send({"error": "llama runner process has terminated"} if want == "broken:1b" else {"done": True})
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
    echo $!
}
PORT=$(( 20000 + RANDOM % 10000 ))
PID=$(stub "$PORT" "qwen3.8:27b-mlx,devstral:24b,broken:1b")
STUB="http://127.0.0.1:$PORT"
# Wait until the stub answers, up to 15 s. A fixed half second was not enough on
# a busy M4 (2026-11-10: the first four cases ran before python had bound the
# port and read as "host did not answer"). A stub that never comes up is said so.
STUB_WAIT=${STUB_WAIT_TENTHS:-150}; up=0
for _ in $(seq 1 "$STUB_WAIT"); do
    if curl -s -m 1 -o /dev/null "$STUB/api/tags" 2>/dev/null; then up=1; break; fi
    sleep 0.1
done
if [ "$up" != 1 ]; then
    echo "  FAIL the stub server on $STUB never answered: $(head -c 300 "$T/stub.log" 2>/dev/null)"
    kill "$PID" 2>/dev/null; rm -rf "$T"
    echo "passed 0, failed 1"; exit 1
fi

# The app's Settings > Archivist Brain, stood in for by a plist file so the
# tests never read (or depend on) Rick's real preference. UNSET points at a
# file that does not exist; SET names devstral:24b.
UNSET="$T/no-such-prefs.plist"
SET="$T/app-prefs.plist"
python3 -c 'import plistlib,sys; open(sys.argv[1],"wb").write(plistlib.dumps({"archivist.ollamaModel": "devstral:24b"}))' "$SET"

# Every case scrubs the env overrides first so a developer's shell cannot
# leak into the assertions; the case that tests an override sets it inline.
# START_OLLAMA=0: no case may start a real `ollama serve` on this machine; the
# cases that test the start set it back to 1 with a FAKE executable.
run() { env -u VIDEOSCAN_HALLIE_REPLAY_HOST -u VIDEOSCAN_HALLIE_REPLAY_MODEL -u VIDEOSCAN_HALLIE_REPLAY_GEDCOM \
            -u VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN -u VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIND \
            VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=0 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_LOG="$T/ollama.log" "$@"; }
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

echo "Test 8: a test host without the Master Archive names its tree (2026-10-30): env, then --gedcom outranks it"
mkdir -p "$T/ged-env" "$T/ged-flag"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" VIDEOSCAN_HALLIE_REPLAY_GEDCOM="$T/ged-env" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r8a.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "gedcom=$T/ged-env" && ok "env: $out" || fail "env: rc=$rc $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" VIDEOSCAN_HALLIE_REPLAY_GEDCOM="$T/ged-env" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r8b.json" --host "$STUB" --gedcom "$T/ged-flag" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "gedcom=$T/ged-flag" && ok "flag: $out" || fail "flag: rc=$rc $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r8c.json" --host "$STUB" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "gedcom=archive" && ok "default: $out" || fail "default: rc=$rc $out"

echo "Test 9: the row records which tree a run used; a missing --gedcom path is refused, not silently ignored"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$SET" VIDEOSCAN_HALLIE_REPLAY_GEDCOM="$T/ged-env" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r9a.json" --host "http://127.0.0.1:1" 2>&1); rc=$?
[ "$(field_of "$T/r9a.json" hallie_replay_gedcom)" = "$T/ged-env" ] && ok "recorded" || fail "rc=$rc gedcom=$(field_of "$T/r9a.json" hallie_replay_gedcom)"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r9b.json" --host "$STUB" --gedcom "$T/no-such-ged" --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "no-such-ged" && ok "refused: $out" || fail "missing path: rc=$rc $out"

# ── 2026-11-15: a local Ollama that is down is started; the model is loaded ──
# The nights of 11/05, 11/06 and 11/15 replayed nothing: nothing keeps Ollama
# up on the Ultra and the runner only looked. A FAKE `ollama`: it records how
# it was called and serves /api/tags on the port it was told to bind.
FAKE="$T/fake-ollama"
cat > "$FAKE" <<FAKEEOF
#!/bin/bash
echo "\$OLLAMA_HOST \$*" >> "$T/fake-calls.txt"
exec python3 - "\${OLLAMA_HOST##*:}" <<'PYEOF'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"models": [{"name": "some-other:1b"}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
FAKEEOF
chmod +x "$FAKE"
DOWN_PORT=$(( PORT + 1 )); DOWN="http://127.0.0.1:$DOWN_PORT"
started_of() { field_of "$1" hallie_replay_ollama_started; }

echo "Test 10: a remote host that is down is never started from here"
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$FAKE" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r10.json" --host "http://no-such-host.invalid:11434" 2>&1); rc=$?
[ "$rc" = 1 ] && [ ! -e "$T/fake-calls.txt" ] && [ "$(started_of "$T/r10.json")" = "False" ] && ok "not started: $(reason_of "$T/r10.json")" || fail "rc=$rc calls=$(cat "$T/fake-calls.txt" 2>/dev/null) $out"

echo "Test 11: --dry-run starts nothing; START_OLLAMA=0 starts nothing"
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$FAKE" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r11a.json" --host "$DOWN" --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && [ ! -e "$T/fake-calls.txt" ] && ok "dry-run: $out" || fail "dry-run: rc=$rc $out"
out=$(run VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$FAKE" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r11b.json" --host "$DOWN" 2>&1); rc=$?
[ "$rc" = 1 ] && [ ! -e "$T/fake-calls.txt" ] && ok "switched off: $(reason_of "$T/r11b.json")" || fail "switched off: rc=$rc $out"

echo "Test 12: a local host that is down and no ollama executable: failed, and the reason says so"
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$T/no-such-ollama" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r12.json" --host "$DOWN" 2>&1); rc=$?
reason=$(reason_of "$T/r12.json")
[ "$rc" = 1 ] && echo "$reason" | grep -q "did not answer /api/tags.*it is down and there is no ollama executable to start" \
    && [ "$(started_of "$T/r12.json")" = "False" ] && ok "$reason" || fail "rc=$rc reason=$reason"

echo "Test 13: an executable that never answers: failed in the wait, the reason names the wait and the log"
printf '#!/bin/bash\nexit 0\n' > "$T/dead-ollama"; chmod +x "$T/dead-ollama"
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_START_WAIT_TENTHS=10 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$T/dead-ollama" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r13.json" --host "$DOWN" 2>&1); rc=$?
reason=$(reason_of "$T/r13.json")
[ "$rc" = 1 ] && echo "$reason" | grep -q "it was down; started $T/dead-ollama serve and it did not answer within 1 s (see $T/ollama.log)" \
    && ok "$reason" || fail "rc=$rc reason=$reason"

echo "Test 14: a LOCAL host that is down is started: 'serve', bound to loopback on the host's port, in its own session; the row says so"
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$FAKE" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r14.json" --host "$DOWN" 2>&1); rc=$?
reason=$(reason_of "$T/r14.json")
FAKE_PIDS=$(lsof -ti "tcp:$DOWN_PORT" -sTCP:LISTEN 2>/dev/null)
if [ "$(cat "$T/fake-calls.txt" 2>/dev/null)" = "127.0.0.1:$DOWN_PORT serve" ] && [ "$(started_of "$T/r14.json")" = "True" ] \
   && echo "$out" | grep -q "^hallie replay: $DOWN was down — started $FAKE serve" \
   && echo "$reason" | grep -q "^model qwen3.8:27b-mlx (documented brain (app setting unset)) is not on $DOWN (has: some-other:1b"; then
    ok "started, then judged on what it serves: $reason"
else
    fail "rc=$rc calls=$(cat "$T/fake-calls.txt" 2>/dev/null) started=$(started_of "$T/r14.json") reason=$reason out=$out"
fi
# It outlives the run that started it (its own session), and a second run finds it up and starts nothing.
if [ -n "$FAKE_PIDS" ] && curl -s -m 2 -o /dev/null "$DOWN/api/tags"; then ok "still serving after the run ended"; else fail "the started server did not outlive the run"; fi
out=$(run VIDEOSCAN_HALLIE_REPLAY_START_OLLAMA=1 VIDEOSCAN_HALLIE_REPLAY_OLLAMA_BIN="$FAKE" VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r14b.json" --host "$DOWN" 2>&1)
[ "$(wc -l < "$T/fake-calls.txt" | tr -d ' ')" = 1 ] && [ "$(started_of "$T/r14b.json")" = "False" ] && ok "a host that answers is not started again" || fail "second run: calls=$(cat "$T/fake-calls.txt") started=$(started_of "$T/r14b.json")"
for p in $FAKE_PIDS; do kill "$p" 2>/dev/null; done

echo "Test 15: a model that is listed but will not load: failed before any lane, in the server's words"
out=$(run VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS="$UNSET" "$REPO/scripts/nightly_hallie_replay.sh" --out "$T/r15.json" --host "$STUB" --model broken:1b 2>&1); rc=$?
reason=$(reason_of "$T/r15.json"); status="$(field_of "$T/r15.json" hallie_replay_status) $(field_of "$T/r15.json" hallie_strict_status)"
[ "$rc" = 1 ] && [ "$status" = "failed not-run" ] \
    && echo "$reason" | grep -q "^model broken:1b (--model) is on $STUB but did not load: llama runner process has terminated" \
    && ok "$reason" || fail "rc=$rc status=$status reason=$reason"

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
rm -rf "$T"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
