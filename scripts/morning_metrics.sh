#!/usr/bin/env bash
# Morning test-metrics digest.
#
# Pulls the test-result rows from origin/metrics (testdriver.jsonl) plus a
# little static-analysis context, prints a compact per-host summary of the
# most recent nightly run, and flags any major day-over-day change so we can
# decide whether it needs investigation.
#
# Used two ways:
#   - scripts/morning_metrics.sh           — run it by hand any time
#   - .claude/scripts/session_morning_hook — first Claude session of the day
#
# Read-only: fetches origin/metrics, never touches your working tree/branch.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

git fetch origin metrics --quiet 2>/dev/null || true

TD="$(git show origin/metrics:metrics/testdriver.jsonl 2>/dev/null || true)"
SA="$(git show origin/metrics:metrics/static_analysis.jsonl 2>/dev/null || true)"

if [ -z "$TD" ]; then
    echo "VideoScan — Test Metrics: no testdriver rows found on origin/metrics."
    exit 0
fi

TD_ROWS="$TD" TD_SA="$SA" python3 - <<'PY'
import sys, os, json, datetime

def norm_host(h):
    h = (h or "").lower()
    if "m5" in h or "studio" in h: return "M5"
    if "m4" in h: return "M4"
    if "m1" in h or "macbook" in h: return "M1"
    return (h or "?").upper()[:6]

def load(stream):
    rows = []
    for line in stream:
        line = line.strip()
        if not line: continue
        try: rows.append(json.loads(line))
        except Exception: continue
    return rows

def datestr(ts): return str(ts or "")[:10]

rows = load(os.environ.get("TD_ROWS", "").splitlines())
for r in rows:
    r["_host"] = norm_host(r.get("host"))
    r["_date"] = datestr(r.get("ts"))
rows.sort(key=lambda r: str(r.get("ts","")))

# Person metrics ride additively on nightly-local rows. Manual TestDriver rows
# may omit them, so retain the newest metric-bearing row. No row yet is the
# deliberate red readiness zero—not a fabricated 0% recognition result.
person_rows = [r for r in rows
               if r.get("person_eval_readiness_pct") is not None
               and r.get("source") == "nightly-local"
               and r.get("branch") == "main"
               and r.get("dirty") is not True]
cycle_rows = [r for r in rows
              if r.get("poi_cycle_stream_status") is not None
              and r.get("source") == "nightly-local"
              and r.get("branch") == "main"
              and r.get("dirty") is not True]
cycle_sensor = cycle_rows[-1] if cycle_rows else None
cycle_sensor_stale = True
if cycle_sensor:
    try:
        cycle_time = datetime.datetime.fromisoformat(str(cycle_sensor.get("ts", "")).replace("Z", "+00:00"))
        cycle_sensor_stale = (datetime.datetime.now(datetime.timezone.utc) - cycle_time).total_seconds() / 3600 > 36
    except (TypeError, ValueError):
        cycle_sensor_stale = True
person = person_rows[-1] if person_rows else {
    "person_eval_readiness_pct": 0,
    "person_eval_readiness_band": "red",
    "person_eval_publish_eligible": False,
    "person_eval_quality_score": None,
    "person_eval_status": "not-configured",
    "person_eval_reason": "quality-holdout-not-configured",
}
if person_rows:
    try:
        metric_time = datetime.datetime.fromisoformat(str(person.get("ts", "")).replace("Z", "+00:00"))
        metric_age_h = (datetime.datetime.now(datetime.timezone.utc) - metric_time).total_seconds() / 3600
    except (TypeError, ValueError):
        metric_age_h = float("inf")
    if metric_age_h > 36:
        person = dict(person)
        prior_readiness = float(person.get("person_eval_readiness_pct") or 0)
        person.update({
            "person_eval_status": "stale",
            "person_eval_reason": "last-clean-main-person-metric-older-than-36h",
            "person_eval_readiness_pct": min(prior_readiness, 75),
            "person_eval_readiness_band": "red" if prior_readiness < 25 else "orange",
            "person_eval_publish_eligible": False,
            "person_eval_quality_score": None,
        })

today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

# Latest row per host (any status) — drives the table.
latest = {}
for r in rows:
    latest[r["_host"]] = r   # rows are sorted ascending, so last wins

# "Current run" = newest GREEN row overall; baseline = newest green row on an
# earlier date, for day-over-day deltas.
greens = [r for r in rows if r.get("status") == "ok" and int(r.get("total") or 0) > 0]
current = greens[-1] if greens else None
baseline = None
if current:
    cd = current["_date"]
    for r in reversed(greens):
        if r["_date"] < cd:
            baseline = r
            break

W = datetime.datetime.now(datetime.timezone.utc).strftime("%a %b %d")
print(f"VideoScan — Test Metrics   {W} (UTC)")
print("─" * 46)
print(f"{'Host':<5} {'Status':<8} {'P/F/S':<13} {'Cov':>6}  {'When':<11}")

order = ["M5", "M4", "M1"]
seen = set()
def emit(h):
    r = latest.get(h)
    if not r:
        print(f"{h:<5} {'(no row)':<8}")
        return
    st = r.get("status") or "—"
    icon = "✅" if st == "ok" else ("❌" if st == "failed" else "·")
    pfs = f"{r.get('passed',0)}/{r.get('failed',0)}/{r.get('skipped',0)}"
    cov = r.get("coverage_logic_pct")
    covs = f"{cov:.1f}%" if isinstance(cov,(int,float)) else "—"
    when = r["_date"]
    if st == "failed":
        pfs = f"{r.get('reason','failed')}"
        covs = "—"
    print(f"{h:<5} {icon} {st:<5} {pfs:<13} {covs:>6}  {when:<11}")
    seen.add(h)

for h in order:
    if h in latest: emit(h)
for h in latest:
    if h not in seen and h not in order: emit(h)

readiness = float(person.get("person_eval_readiness_pct") or 0)
band = person.get("person_eval_readiness_band") or "red"
band_icon = {"red": "🔴", "yellow": "🟡", "orange": "🟠", "green": "🟢"}.get(band, "🔴")
eligible = person.get("person_eval_publish_eligible") is True
quality = person.get("person_eval_quality_score") if eligible else None
quality_text = f"{quality:.1f}/100" if isinstance(quality, (int, float)) else "N/A"
print("─" * 46)
print(f"Person recognition: {band_icon} readiness {readiness:.0f}% | quality {quality_text}")
if eligible:
    p = person.get("person_eval_identity_precision")
    r = person.get("person_eval_identity_recall")
    ps = f"{100*p:.1f}%" if isinstance(p, (int, float)) else "N/A"
    rs = f"{100*r:.1f}%" if isinstance(r, (int, float)) else "N/A"
    print(f"   precision {ps} | recall {rs} | FP {person.get('person_eval_false_positives', '—')} | FN {person.get('person_eval_false_negatives', '—')}")
else:
    print(f"   {person.get('person_eval_status', 'not-configured')}: {person.get('person_eval_reason', 'quality not measured')}")
if cycle_sensor:
    cycle_state = "stale" if cycle_sensor_stale else cycle_sensor.get("poi_cycle_stream_status", "invalid")
    print(f"POI cycle sensor: {cycle_state} | latest {cycle_sensor.get('poi_cycle_latest_label', '—')} ({cycle_sensor.get('poi_cycle_latest_evidence_tier', '—')}) | production {cycle_sensor.get('poi_cycle_production_label', '—')}")
else:
    print("POI cycle sensor: no nightly row")

# ── Flags: things worth a look ───────────────────────────────────────
flags = []

if cycle_sensor is None:
    flags.append("POI cycle stream has not reported through the nightly sensor.")
elif cycle_sensor_stale:
    flags.append("POI cycle nightly sensor is older than 36 hours.")
elif cycle_sensor.get("poi_cycle_stream_status") != "ok":
    flags.append(f"POI cycle stream is {cycle_sensor.get('poi_cycle_stream_status', 'invalid')}.")

if readiness < 80:
    flags.append(f"Person-recognition benchmark readiness is {readiness:.0f}% ({person.get('person_eval_status','not-configured')}).")
elif not eligible:
    flags.append("Person-recognition benchmark is prepared but has no publishable quality result.")
elif isinstance(quality, (int, float)) and quality < 80:
    flags.append(f"Person-recognition identity F1 is {quality:.1f}/100 (target: 80+).")

green_today = any(r["_date"] == today and r.get("status")=="ok" and int(r.get("total") or 0)>0 for r in rows)
if not green_today:
    flags.append("CRITICAL: no green nightly run for today yet — failover may still be in progress, or all hosts failed.")

for h in order:
    r = latest.get(h)
    if r and r.get("status") == "failed":
        flags.append(f"{h} last run FAILED ({r.get('reason','?')}, {r['_date']}).")
    elif r and (today_minus := (datetime.date.fromisoformat(today) - datetime.date.fromisoformat(r["_date"])).days) >= 3:
        flags.append(f"{h} hasn't reported in {today_minus} days (last {r['_date']}).")

if current and int(current.get("failed") or 0) > 0:
    flags.append(f"{current.get('failed')} TEST(S) FAILING in newest green run ({current['_host']} {current['_date']}).")

if current and baseline:
    cc = current.get("coverage_logic_pct"); bc = baseline.get("coverage_logic_pct")
    if isinstance(cc,(int,float)) and isinstance(bc,(int,float)):
        d = cc - bc
        if d <= -1.0:
            flags.append(f"Coverage DROPPED {d:+.1f}% ({bc:.1f}% → {cc:.1f}%) vs {baseline['_date']}.")
    ct = int(current.get("total") or 0); bt = int(baseline.get("total") or 0)
    if bt and ct - bt <= -20:
        flags.append(f"Test count DROPPED {ct-bt:+d} ({bt} → {ct}) vs {baseline['_date']} — tests removed or not compiled?")

# Static-analysis day-over-day (concurrency warnings are the live regression knob).
sa_rows = load((TD_SA := os.environ.get("TD_SA","")).splitlines()) if os.environ.get("TD_SA") else []
sa_rows.sort(key=lambda r: str(r.get("ts","")))
if len(sa_rows) >= 2:
    a, b = sa_rows[-2], sa_rows[-1]
    for key, label in (("concurrency_warnings","concurrency warnings"),
                       ("swiftlint_strict","swiftlint-strict"),
                       ("codeql_findings","CodeQL findings")):
        av, bv = a.get(key), b.get(key)
        if isinstance(av,int) and isinstance(bv,int) and bv - av >= 5:
            flags.append(f"{label} rose {bv-av:+d} ({av} → {bv}).")

print("─" * 46)
if flags:
    print("⚠  Needs a look:")
    for f in flags:
        print(f"   • {f}")
else:
    delta = ""
    if current and baseline:
        cc = current.get("coverage_logic_pct"); bc = baseline.get("coverage_logic_pct")
        if isinstance(cc,(int,float)) and isinstance(bc,(int,float)):
            delta = f"  (coverage {cc-bc:+.1f}% vs {baseline['_date']})"
    print(f"✅ No major change vs previous day.{delta}")
PY
