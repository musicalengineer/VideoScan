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

# ── Flags: things worth a look ───────────────────────────────────────
flags = []

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
