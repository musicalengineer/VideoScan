#!/bin/bash
# nightly_hallie_replay.sh — replay Rick's recorded Hallie questions through
# the real app and the real model, and say honestly what passed.
#
# Rick, 2026-09-07: "I thought we had an automated hallie testbed to identify
# and prevent regressions?" We had the recorder (hallie_harvest_queries.py,
# every session) and the harness (hallie_eval.py), and NOTHING ran them: the
# last full replay was 09/03 and the harness exited 0 whatever happened. codex
# fixed the harness semantics (#1190); this is the runner.
#
# Two lanes, reported separately and never blended:
#   STRICT    tests/hallie_strict_regressions.json — live misses whose fix has
#             a unit test. A defect on ANY entry fails the strict verdict.
#   ADVISORY  tests/hallie_eval_corpus.json — every harvested question. Graded
#             and counted; unreviewed expectations never count as "passed".
#
# Output: one JSON object (--out) the nightly merges into its durable row, with
# provenance a reader can reproduce from: git SHA, binary and its mtime, model,
# host, corpus and manifest SHA-256, compiled-tree generation. Status is one of
# ok | failed | incomplete | not-run, and a lane that did not finish inside the
# budget is INCOMPLETE with its completed count — never a subset presented as
# the whole (codex #1189).
#
# On demand:  scripts/nightly_hallie_replay.sh --out /tmp/hallie.json
# Options:    --bin <VideoScan binary>  --host <ollama url>  --model <tag>
#             --budget-seconds <N>  --strict-only  --advisory-only  --dry-run
# Defaults:   host  http://127.0.0.1:11434 — the M4's OWN ollama (GH #181:
#                   it binds loopback only, so never RicksM4.local)
#             model the app's SELECTED Hallie brain (Settings > Archivist
#                   Brain, read-only from UserDefaults), else qwen3.8:27b-mlx
# Overrides:  VIDEOSCAN_HALLIE_REPLAY_HOST / VIDEOSCAN_HALLIE_REPLAY_MODEL for
#             a manual run against the M5; --host / --model outrank them.
# Preflight: /api/tags must answer AND list that exact tag, or the row is
# `failed` in seconds with a one-line reason naming host + tag.
set -u
REPO=${REPO:-$HOME/dev/VideoScan}
PY=${PY:-$REPO/venv/bin/python}
[ -x "$PY" ] || PY=python3
LOGDIR=${LOGDIR:-$HOME/Library/Logs/VideoScan/hallie-eval}
mkdir -p "$LOGDIR"

OUT=""; BIN=""; HOST=""; MODEL=""; BUDGET=${NIGHTLY_HALLIE_BUDGET_SECONDS:-3600}
LANES="strict advisory"; DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --bin) BIN="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --budget-seconds) BUDGET="$2"; shift 2 ;;
        --strict-only) LANES="strict"; shift ;;
        --advisory-only) LANES="advisory"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 64; }

# WHICH HOST, WHICH MODEL (2026-09-12). Rick's standing ruling (codex #1359):
# Hallie tests run on the M4, against the M4's own brain. This script used to
# default to ricksm5, and on the night of 09/11->12 the M5 was asleep at
# 02:xx: "host http://ricksm5.local:11434 did not answer /api/tags" and the
# night produced nothing. The M4's ollama binds 127.0.0.1 only (GH #181), so
# the default is the loopback address — never RicksM4.local, which resolves
# to IPv6 link-local and times out from the M4 itself.
#
# The model is the one Rick actually uses: the app's SELECTED brain, read
# (read-only) from the same UserDefaults key the Settings pane writes
# (archivist.ollamaModel in Rick-Breen.VideoScan; `defaults` follows the
# sandbox container). Unset -> the documented brain, qwen3.8:27b-mlx. The
# host's tag list no longer chooses: a replay against whichever model
# happens to be installed measures a different brain than the one Rick
# talks to, and that is how the 09/08 night paired zero turns.
#
# Env overrides exist so a hand run can point at the M5:
#   VIDEOSCAN_HALLIE_REPLAY_HOST / VIDEOSCAN_HALLIE_REPLAY_MODEL
# (--host / --model outrank them). VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS is
# for the tests only: a plist path standing in for the app's domain.
HOST=${HOST:-${VIDEOSCAN_HALLIE_REPLAY_HOST:-http://127.0.0.1:11434}}
APP_DEFAULTS=${VIDEOSCAN_HALLIE_REPLAY_APP_DEFAULTS:-Rick-Breen.VideoScan}
DOCUMENTED_BRAIN="qwen3.8:27b-mlx"
MODEL_SOURCE="--model"
if [ -z "$MODEL" ]; then
    if [ -n "${VIDEOSCAN_HALLIE_REPLAY_MODEL:-}" ]; then
        MODEL=$VIDEOSCAN_HALLIE_REPLAY_MODEL; MODEL_SOURCE="VIDEOSCAN_HALLIE_REPLAY_MODEL"
    else
        MODEL=$(defaults read "$APP_DEFAULTS" archivist.ollamaModel 2>/dev/null | tr -d '[:space:]')
        if [ -n "$MODEL" ]; then
            MODEL_SOURCE="app setting archivist.ollamaModel"
        else
            MODEL=$DOCUMENTED_BRAIN; MODEL_SOURCE="documented brain (app setting unset)"
        fi
    fi
fi

# PREFLIGHT: THE HOST MUST ANSWER AND LIST THAT EXACT TAG, OR SAY SO IN
# SECONDS. First nightly run, 2026-09-08 02:37: the wrong tag sat for its
# whole 900 s share pairing zero turns. The row said "incomplete" — honest,
# but an hour of the night for a name. A host that does not answer, or a
# model the host does not have, is `failed` with host + tag in the reason —
# never a 900 s wait.
PREFLIGHT_REASON=""
TAGS=$(curl -s --max-time 15 "$HOST/api/tags" 2>/dev/null \
    | python3 -c 'import json,sys
try: print("\n".join(m["name"] for m in json.load(sys.stdin).get("models",[])))
except Exception: pass' 2>/dev/null)
if [ -z "$TAGS" ]; then
    PREFLIGHT_REASON="host $HOST did not answer /api/tags (or lists no models); wanted model $MODEL ($MODEL_SOURCE)"
elif ! printf '%s\n' "$TAGS" | grep -qx "$MODEL"; then
    PREFLIGHT_REASON="model $MODEL ($MODEL_SOURCE) is not on $HOST (has: $(printf '%s' "$TAGS" | tr '\n' ' '))"
fi
if [ "$DRY_RUN" = 1 ]; then
    echo "dry-run: host=$HOST model=$MODEL source=\"$MODEL_SOURCE\" ${PREFLIGHT_REASON:+reason=$PREFLIGHT_REASON}"
    [ -z "$PREFLIGHT_REASON" ]; exit $?
fi
if [ -n "$PREFLIGHT_REASON" ]; then
    python3 - "$OUT" "$PREFLIGHT_REASON" "$HOST" "$MODEL" "$MODEL_SOURCE" "$(date +%Y%m%dT%H%M%S)" \
        "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" <<'PYEOF'
import json, sys
out, reason, host, model, source, stamp, sha = sys.argv[1:8]
row = {"hallie_replay_status": "failed", "hallie_replay_reason": reason,
       "hallie_replay_elapsed_s": 0, "hallie_replay_stamp": stamp,
       "hallie_replay_git_sha": sha, "hallie_replay_host": host,
       "hallie_replay_model": model or None, "hallie_replay_model_source": source}
for lane in ("strict", "advisory"):
    row.update({f"hallie_{lane}_status": "not-run", f"hallie_{lane}_expected": 0,
                f"hallie_{lane}_completed": 0, f"hallie_{lane}_pass": 0,
                f"hallie_{lane}_fail": 0, f"hallie_{lane}_incomplete": 0})
json.dump(row, open(out, "w"), separators=(",", ":"))
print(f"hallie replay failed before any lane: {reason}")
PYEOF
    exit 1
fi

STRICT_CORPUS="$REPO/tests/hallie_strict_regressions.json"
ADVISORY_CORPUS="$REPO/tests/hallie_eval_corpus.json"
STAMP=$(date +%Y%m%dT%H%M%S)
SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
TREE_GEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' \
    "$HOME/Library/Application Support/VideoScan/family-tree/compiled/current.json" 2>/dev/null || echo unknown)
sha256() { shasum -a 256 "$1" 2>/dev/null | cut -c1-16; }

# The lane runner. Writes <lane>.summary.json via the harness and returns the
# harness's own verdict; a lane that overruns its share of the budget is
# reported incomplete, not skipped.
run_lane() {
    local lane="$1" corpus="$2" strict_flag="$3" budget="$4"
    local run="$LOGDIR/nightly-$STAMP-$lane.json"
    local args=(run --corpus "$corpus" --out "$run" --timeout "$budget")
    [ -n "$BIN" ]   && args+=(--bin "$BIN")
    [ -n "$HOST" ]  && args+=(--host "$HOST")
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    args+=(--build-sha "$SHA")
    "$PY" "$REPO/scripts/hallie_eval.py" "${args[@]}" > "$LOGDIR/nightly-$STAMP-$lane.run.log" 2>&1
    local run_rc=$?
    if [ ! -s "$run" ]; then
        echo "{\"status\":\"failed\",\"expected\":0,\"completed\":0,\"clean\":0,\"defects\":0,\"incomplete\":0,\"runRC\":$run_rc}"
        return 1
    fi
    "$PY" "$REPO/scripts/hallie_eval.py" grade --run "$run" $strict_flag > "$LOGDIR/nightly-$STAMP-$lane.grade.log" 2>&1
    local grade_rc=$?
    # codex's harness writes <run>.summary.json; the GRADE_SUMMARY line is the
    # fallback if the file is missing.
    local summary="${run%.json}.summary.json"
    if [ -s "$summary" ]; then
        python3 - "$summary" "$run_rc" "$grade_rc" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
s["runRC"] = int(sys.argv[2]); s["gradeRC"] = int(sys.argv[3])
print(json.dumps(s, separators=(",", ":")))
PYEOF
    else
        grep -m1 '^GRADE_SUMMARY: ' "$LOGDIR/nightly-$STAMP-$lane.grade.log" | sed 's/^GRADE_SUMMARY: //' \
            || echo "{\"status\":\"failed\",\"expected\":0,\"completed\":0,\"clean\":0,\"defects\":0,\"incomplete\":0,\"runRC\":$run_rc,\"gradeRC\":$grade_rc}"
    fi
    return "$grade_rc"
}

STARTED=$(date +%s)
STRICT_JSON='null'; ADVISORY_JSON='null'; STRICT_RC=""; ADVISORY_RC=""
for lane in $LANES; do
    elapsed=$(( $(date +%s) - STARTED ))
    remaining=$(( BUDGET - elapsed ))
    case "$lane" in
        strict)
            # The strict lane is small and runs first with its own generous
            # share; the gate must never be starved by the advisory lane.
            share=$(( remaining < 900 ? remaining : 900 ))
            STRICT_JSON=$(run_lane strict "$STRICT_CORPUS" "--strict" "$share"); STRICT_RC=$? ;;
        advisory)
            share=$remaining
            if [ "$share" -le 60 ]; then
                ADVISORY_JSON='{"status":"not-run","reason":"no budget left after the strict lane"}'; ADVISORY_RC=2
            else
                ADVISORY_JSON=$(run_lane advisory "$ADVISORY_CORPUS" "" "$share"); ADVISORY_RC=$?
            fi ;;
    esac
done
ELAPSED=$(( $(date +%s) - STARTED ))

# One verdict for the lane that gates: ok only when the strict lane completed
# clean. Incomplete stays incomplete. The advisory lane never changes it.
STATUS=$(python3 - "$STRICT_JSON" "${STRICT_RC:-}" <<'PYEOF'
import json, sys
s = json.loads(sys.argv[1]) if sys.argv[1] != 'null' else None
rc = sys.argv[2]
if s is None: print("not-run")
elif s.get("status") == "incomplete" or rc == "2": print("incomplete")
elif s.get("status") == "failed" or int(s.get("defects", 0) or 0) > 0 or rc not in ("0", ""): print("failed")
else: print("ok")
PYEOF
)

python3 - "$OUT" "$STATUS" "$STRICT_JSON" "$ADVISORY_JSON" "$ELAPSED" "$SHA" "$BIN" "$HOST" "$MODEL" "$TREE_GEN" \
        "$(sha256 "$STRICT_CORPUS")" "$(sha256 "$ADVISORY_CORPUS")" "$STAMP" "$MODEL_SOURCE" <<'PYEOF'
import json, os, sys, time
out, status, strict, advisory, elapsed, sha, binary, host, model, tree, msha, csha, stamp, source = sys.argv[1:15]
def incomplete_count(s):
    # The harness summary says incomplete: true/false; the row wants how many.
    v = s.get("incomplete", 0)
    if isinstance(v, bool):
        return max(0, int(s.get("expected", s.get("total", 0)) or 0) - int(s.get("completed", 0) or 0)) if v else 0
    return int(v or 0)

def lane(js, name):
    s = json.loads(js) if js and js != 'null' else {"status": "not-run"}
    return {f"hallie_{name}_status": s.get("status", "not-run"),
            f"hallie_{name}_expected": s.get("expected", s.get("total", 0)),
            f"hallie_{name}_completed": s.get("completed", 0),
            f"hallie_{name}_pass": s.get("clean", 0),
            f"hallie_{name}_fail": s.get("defects", 0),
            f"hallie_{name}_incomplete": incomplete_count(s),
            f"hallie_{name}_run_id": s.get("runID"),
            f"hallie_{name}_flags": s.get("flags")}
row = {"hallie_replay_status": status,
       "hallie_replay_elapsed_s": int(elapsed),
       "hallie_replay_stamp": stamp,
       "hallie_replay_git_sha": sha,
       "hallie_replay_binary": binary or None,
       "hallie_replay_binary_mtime": (time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(os.path.getmtime(binary))) if binary and os.path.exists(binary) else None),
       "hallie_replay_host": host or None,
       "hallie_replay_model": model or None,
       "hallie_replay_model_source": source,
       "hallie_replay_tree_generation": tree,
       "hallie_replay_manifest_sha256": msha,
       "hallie_replay_corpus_sha256": csha}
row.update(lane(strict, "strict"))
row.update(lane(advisory, "advisory"))
json.dump(row, open(out, "w"), separators=(",", ":"))
print(f"hallie replay {status}: strict {row['hallie_strict_pass']}/{row['hallie_strict_expected']} pass, "
      f"{row['hallie_strict_fail']} fail, {row['hallie_strict_incomplete']} incomplete; "
      f"advisory {row['hallie_advisory_pass']}/{row['hallie_advisory_expected']} pass, "
      f"{row['hallie_advisory_fail']} fail ({row['hallie_advisory_status']}); {elapsed}s")
PYEOF
case "$STATUS" in ok) exit 0 ;; incomplete) exit 2 ;; *) exit 1 ;; esac
