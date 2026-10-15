"""docs/index.html, the one health page (summary first, GH #310): execute its script
under node with a fake DOM and fixture data. The headline strip, the 90-night table
and every area line must render without an error; a stream with no rows must say
"no data yet" or "—" (never a zero); the M1's build timeout must read "did not run"
(amber), never "failed"; ?all / #all must open every twist; and the page must never
read the free-text fields that ride on some rows."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"

HARNESS = r"""
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const fixtures = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const loc = JSON.parse(process.argv[3] || "{}");
const storage = JSON.parse(process.argv[4] || "{}");
globalThis.localStorage = {
  getItem(key) { return storage[key] ?? null; },
  setItem(key, value) { storage[key] = String(value); },
};
let script = html.match(/<script>\n([\s\S]*?)<\/script>/)[1];
script = script.replace(/\nloadData\(\);\s*$/, "\nglobalThis.__done = loadData();");
const elements = new Map();
function element(id = "") {
  const classes = new Set();
  const attributes = new Map();
  const value = { id, children: [], innerHTML: "", textContent: "", style: {}, className: "", open: false, listeners: [],
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x), toArray: () => [...classes] },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener(kind, fn) { this.listeners.push(kind); },
    contains() { return false; }, getAttribute(key) { return attributes.get(key) ?? null; },
    setAttribute(key, value) { attributes.set(key, String(value)); },
    removeAttribute(key) { attributes.delete(key); } };
  return value;
}
// Elements declared hidden in the HTML start hidden here too.
for (const m of html.matchAll(/<(?:div|p|details)[^>]*class="([^"]*)"[^>]*id="([^"]+)"|<(?:div|p|details)[^>]*id="([^"]+)"[^>]*class="([^"]*)"/g)) {
  const id = m[2] || m[3], cls = m[1] || m[4];
  const el = element(id);
  if (/\bhidden\b/.test(cls)) el.classList.add("hidden");
  elements.set(id, el);
}
globalThis.document = {
  documentElement: element("html"),
  getElementById(id) { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
  createElement() { return element(); },
};
const initialTheme = html.match(/<html\b[^>]*data-theme="([^"]+)"/);
if (initialTheme) document.documentElement.setAttribute("data-theme", initialTheme[1]);
if (loc.hash !== undefined) globalThis.location = { hash: loc.hash, search: loc.search || "" };
const charts = [];
globalThis.Chart = function(target, config) { charts.push({ id: target.id, config }); this.canvas = target; this.resize = () => {}; };
globalThis.fetch = async url => {
  url = String(url);
  for (const [key, body] of Object.entries(fixtures)) {
    if (url.includes(key)) {
      if (body === null) return { ok: false };
      return { ok: true, text: async () => typeof body === "string" ? body : JSON.stringify(body),
               json: async () => typeof body === "string" ? JSON.parse(body) : body };
    }
  }
  return { ok: false };
};
const errors = [];
globalThis.console = { ...console, error: (...a) => errors.push(a.map(String).join(" ")) };
(async () => {
  eval(script);
  await globalThis.__done;
  const text = el => [el.innerHTML, el.textContent, ...el.children.map(text)].join(" ");
  const out = { charts: charts.map(c => c.id), errors, sections: {}, notes: {}, open: {}, listeners: {},
    theme: document.documentElement.getAttribute("data-theme"),
    chartData: Object.fromEntries(charts.map(c => [c.id, c.config && c.config.data])) };
  for (const [id, el] of elements) {
    if (id.endsWith("-error") && !el.classList.contains("hidden")) out.errors.push(`${id}: ${el.textContent}`);
    if (id.endsWith("-note") && !el.classList.contains("hidden")) out.notes[id] = el.textContent;
    if (id.startsWith("area-")) { out.open[id] = el.open; out.listeners[id] = el.listeners; }
    out.sections[id] = text(el);
  }
  process.stdout.write(JSON.stringify(out));
})().catch(e => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""

AREAS = ["tests", "size", "debt", "san", "hallie", "events", "reviews", "speed"]
SECRETS = ["SECRET-TITLE", "SECRET-REASON", "SECRET-TEST-NAME", "Secret.swift", "/Users/rickb", "SECRET-HOST"]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def jsonl(rows):
    return "".join(json.dumps(r) + "\n" for r in rows)


def run_page(tmp_path, fixtures, location=None, storage=None):
    fx = tmp_path / "fixtures.json"
    fx.write_text(json.dumps(fixtures))
    r = subprocess.run(["node", "-e", HARNESS, str(PAGE), str(fx), json.dumps(location or {}), json.dumps(storage or {})],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def summary_fixture(now):
    """What tools/publish_metrics.py publishes: 90 nights ending today, three Macs.
    Last night: M4 red (2 failed), M5 red (1 failed), M1 did_not_run (build timeout)."""
    today = now.strftime("%Y-%m-%d")
    nights = []
    for i in range(90):
        date = (now - timedelta(days=89 - i)).strftime("%Y-%m-%d")
        hosts = {"M4": {"state": "green", "passed": 9000 + i, "failed": 0, "total": 9060 + i, "reason": None}}
        if i >= 30:
            hosts["M5"] = {"state": "green", "passed": 9000 + i, "failed": 0, "total": 9060 + i, "reason": None}
        if i in (40, 41):
            hosts["M4"] = {"state": "red", "passed": 9000, "failed": 3, "total": 9060, "reason": "failed-tests:3"}
        if i == 45:
            hosts["M4"] = {"state": "watch", "passed": 9004, "failed": 4, "total": 9060, "reason": "failed-tests:4"}
        if i == 50:
            hosts["M4"] = {"state": "did_not_run", "passed": 0, "failed": 0, "total": 0, "reason": "zero-tests-ran:test-rc=65"}
        if i >= 60:
            hosts["M1"] = {"state": "did_not_run", "passed": 0, "failed": 0, "total": 0, "reason": "build-timeout:5400s"}
        if i == 89:
            hosts["M4"] = {"state": "red", "passed": 11211, "failed": 2, "total": 11275, "reason": "failed-tests:2"}
            hosts["M5"] = {"state": "red", "passed": 11207, "failed": 1, "total": 11275, "reason": "failed-tests:1"}
        nights.append({"date": date, "hosts": hosts})
    return {
        "schemaVersion": 1, "generated": iso(now),
        "version": {"marketing": "5.1", "build": "1"},
        "github": {"open_issues": 82, "open_bugs": 11, "bugs_opened_7d": 3, "bugs_closed_7d": 11,
                   "high_priority_open": 4, "main_sha": "b07f9da43d14", "main_date": today},
        "sprint": {"title": "Week of Oct 12", "open": 8, "closed": 1, "due": (now + timedelta(days=6)).strftime("%Y-%m-%d")},
        "tags": [{"date": (now - timedelta(days=2)).strftime("%Y-%m-%d"), "name": "demo-2026-10-10"}],
        "person": {"status": "not-configured", "readiness_pct": 0, "quality_score": None},
        "nightly": {"days": 90, "hosts": ["M4", "M5", "M1"], "nights": nights},
    }


def daily_row(ts, open_bugs, opened=0, closed=0):
    return {"ts": iso(ts), "open_issues": 80, "open_bugs": open_bugs, "bugs_opened_7d": 3, "bugs_closed_7d": 11,
            "bugs_opened_1d": opened, "bugs_closed_1d": closed, "high_priority_open": 4}


def events_fixture(now, marks=True):
    """What the publisher's events_latest.json looks like (scripts/events_prototype.py --stats-json)."""
    cats = ["Birthday", "Christmas", "Thanksgiving", "Easter", "Halloween", "Wedding", "Beach / vacation",
            "Music / performance", "Graduation"]
    by_cat = dict(zip(cats, [120, 88, 40, 12, 9, 7, 30, 2, 0]))
    pbc = {c: {"yes": 0, "no": 0} for c in cats}
    pbc["Birthday"] = {"yes": 30, "no": 5}
    pbc["Christmas"] = {"yes": 8, "no": 4}
    return {"schemaVersion": 1, "ts": iso(now - timedelta(hours=2)), "active_records": 9810, "with_captions": 6120,
            "with_transcripts": 3310, "clips_with_evidence": 1274, "candidate_events": 308, "strong_events": 109,
            "by_category": by_cat, "marks_yes": 38 if marks else None, "marks_no": 9 if marks else None,
            "precision_by_category": pbc if marks else None}


BUGS_URL = "https://github.com/musicalengineer/VideoScan/issues?q=is%3Aopen+label%3Abug"
HIGH_URL = "https://github.com/musicalengineer/VideoScan/issues?q=is%3Aopen+label%3A%22High+Priority%22"
OLD_BUG_WORDING = ["not available", "CI row", "issues open in all", "fixed this week"]


def bug_tile(head):
    """The Open-bugs tile's value line and words line, as rendered."""
    m = re.search(r'<div class="label">Open bugs</div><div class="value">(.*?)</div>(?:<svg.*?</svg>)?<div class="words">(.*?)</div></div>', head)
    assert m, head
    return m.group(1), m.group(2)


def daily_fixture(now):
    """What the publisher's github_daily.jsonl looks like: 30 UTC days ending today,
    one row each, except day 20 (gh failed that morning: no row, not a null)."""
    return [daily_row(now - timedelta(days=29 - i), 20 - i // 3, opened=1, closed=i % 2)
            for i in range(30) if i != 20]


def full_fixtures(now, with_summary=True):
    fresh, old = now - timedelta(hours=3), now - timedelta(days=8)      # old: stale, and a 7-day comparison point
    nightly = [
        {"ts": iso(old), "source": "nightly-local", "host": "RicksM4", "branch": "main", "status": "ok",
         "passed": 9000, "failed": 2, "skipped": 60, "total": 9062, "elapsed_s": 1200, "coverage_logic_pct": 65.0,
         "hallie_strict_status": "failed", "hallie_strict_pass": 8, "hallie_strict_expected": 10,
         "hallie_strict_completed": 10, "hallie_advisory_pass": 3, "hallie_advisory_expected": 4,
         "hallie_advisory_completed": 4, "hallie_replay_status": "failed",
         "failed_names": ["SECRET-TEST-NAME"], "hallie_replay_reason": "SECRET-REASON /Users/rickb",
         "person_eval_status": "not-configured", "person_eval_reason": "SECRET-REASON"},
        # A replay that completed nothing (2026-10-02 on the M4): a gap, not 0 %.
        {"ts": iso(fresh - timedelta(hours=1)), "source": "nightly-local", "host": "RicksM4", "branch": "main",
         "status": "ok", "passed": 9001, "failed": 0, "skipped": 60, "total": 9061, "elapsed_s": 1100,
         "hallie_strict_status": "incomplete", "hallie_strict_pass": 0, "hallie_strict_expected": 64,
         "hallie_strict_completed": 0, "hallie_advisory_pass": 0, "hallie_advisory_expected": 775,
         "hallie_advisory_completed": 0, "hallie_replay_status": "incomplete"},
        {"ts": iso(fresh), "source": "nightly-local", "host": "SECRET-HOST", "branch": "main", "status": "failed",
         "passed": 0, "failed": 0, "skipped": 0, "total": 0, "reason": "build-timeout:5400s SECRET-REASON"},
        {"ts": iso(fresh), "source": "poi-cycle-metrics", "passed": 999999},
    ]
    return {
        "/branches/metrics": None,
        "history.jsonl": jsonl([{"ts": iso(old), "total_swift_lines": 500000, "files_over_1000": 60, "open_issues": 70},
                                {"ts": iso(fresh - timedelta(days=1)), "total_swift_lines": 540000, "app_source_lines": 374208,
                                 "files_over_1000": 60},
                                {"ts": iso(fresh), "total_swift_lines": 546428, "app_source_lines": 376166, "app_swift_lines": 374023,
                                 "app_python_lines": 2143, "test_lines": 340574, "tooling_lines": 50080, "files_over_1000": 61,
                                 "test_count": 9550, "regression_count": 209, "open_issues": 81, "worst_file": "FamilyTreeLiveModel.swift:2996",
                                 "swift_by_folder": {"Hallie": {"lines": 68739, "files": 181}, "Core": {"lines": 42550, "files": 144}}}]),
        "static_analysis.jsonl": jsonl([{"ts": iso(old), "codeql_findings": 17, "concurrency_warnings": 189, "tsan_issues": None,
                                         "strict_warning_total": 815, "swiftlint_strict": 430, "periphery_aggressive": 1521,
                                         "codeql_extracted_files": 900, "codeql_in_scope_files": 939},
                                        {"ts": iso(fresh), "codeql_findings": 17, "concurrency_warnings": 193, "tsan_issues": None,
                                         "strict_warning_total": 539, "swiftlint_strict": 387, "periphery_aggressive": 1673,
                                         "codeql_extracted_files": 1090, "codeql_in_scope_files": 1090}]),
        "testdriver.jsonl": jsonl(nightly),
        "nightly_findings_latest.json": {"date": "2026-10-02", "dry_run": True, "fingerprints": 3,
                                         "by_severity": {"high": 1, "medium": 0, "low": 2},
                                         "tools": {"codeql": {"input": True, "complete": True, "findings": 3, "fingerprints": 3},
                                                   "tsan": {"input": False, "complete": False, "findings": 0, "fingerprints": 0}},
                                         "new": [{"tool": "codeql", "severity": "high", "title": "SECRET-TITLE Donna",
                                                  "file": "VideoScan/VideoScan/People/Secret.swift"}]},
        "coverage.jsonl": jsonl([{"schemaVersion": 1, "date": (now - timedelta(days=8)).strftime("%Y-%m-%d"), "app_status": "ok", "core_status": "ok",
                                  "total": {"lines": 100, "covered": 40, "pct": 40.0, "logic_lines": 80, "logic_covered": 56,
                                            "logic_pct": 70.0, "files": 4},
                                  "folders": [{"folder": "Hallie", "lines": 100, "covered": 40, "pct": 40.0, "logic_lines": 80,
                                               "logic_covered": 56, "logic_pct": 70.0, "files": 4}]},
                                 {"schemaVersion": 1, "date": fresh.strftime("%Y-%m-%d"), "app_status": "ok", "core_status": "ok",
                                  "total": {"lines": 100, "covered": 50, "pct": 50.0, "logic_lines": 80, "logic_covered": 60,
                                            "logic_pct": 75.0, "files": 4},
                                  "folders": [{"folder": "Hallie", "lines": 100, "covered": 50, "pct": 50.0, "logic_lines": 80,
                                               "logic_covered": 60, "logic_pct": 75.0, "files": 4}]}]),
        "adversarial.jsonl": None,
        "codex_reviews.jsonl": jsonl([{"schemaVersion": 1, "date": "2026-09-27", "docs": 1, "unparsed_docs": 0,
                                       "passes": 2, "findings": 5, "closed_passes": 2}]),
        "summary_latest.json": summary_fixture(now) if with_summary else None,
        "github_daily.jsonl": jsonl(daily_fixture(now)) if with_summary else None,
        "events_latest.json": events_fixture(now),
        "/actions/workflows/ci.yml/": {"workflow_runs": [
            {"head_branch": "feature", "status": "completed", "conclusion": "failure", "updated_at": iso(fresh)},
            {"head_branch": "main", "status": "in_progress", "conclusion": None, "updated_at": iso(fresh)},
            {"head_branch": "main", "status": "completed", "conclusion": "success", "updated_at": iso(fresh), "head_sha": "2db6ac51aa"}]},
        "/actions/workflows/nightly-analysis.yml/": None,
        "search_benchmarks.jsonl": None,
        "complexity.jsonl": jsonl([backfill_row(old - timedelta(days=30)), complexity_row(old, 520, 10), complexity_row(fresh, 514, 2)]),
        "complexity_debt_latest.json": {"ts": iso(fresh), "new": [{"key": "k", "file": "VideoScan/VideoScan/Catalog/New.swift",
                                                                 "function": "NewView.body", "ccn": 22, "nloc": 90, "lang": "swift"}],
                                        "worse": [], "fixed": ["a::b"],
                                        "overrides_recent": [{"ts": iso(fresh), "reason": "SECRET-REASON", "author": "Rick Breen",
                                                              "commit": "abc1234", "function_details": [
                                                                  {"function": "Big.run", "ccn": 35, "nloc": 120}]}]},
        "exposure.jsonl": jsonl([exposure_row(old, 2600, 9), exposure_row(fresh, 2520, 3)]),
        "problem_files_latest.json": {"schemaVersion": 1, "ts": iso(fresh), "sha": "abcd1234", "formula_version": 1,
                                      "files_scored": 412, "rows": [
                                          {"file": "VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift", "score": 120.9,
                                           "offenders": 6, "worst_ccn": 39, "new_or_worse": 0, "lines": 2599,
                                           "could_be_private": 29, "widened_for_split": 0, "churn_7d": 12}]},
    }


def exposure_row(ts, could_be_private, new):
    bucket = {"files": 10, "decls": 100, "could_be_private": 12, "widened_for_split": 3, "fine": 85}
    return {"schemaVersion": 1, "ts": iso(ts), "sha": "abcd1234", "run_kind": "nightly",
            "totals": {**bucket, "decls": 16773, "could_be_private": could_be_private, "widened_for_split": 435},
            "by_folder": {"Hallie": bucket, "Catalog": {**bucket, "could_be_private": 7}},
            "top20": [{"file": "VideoScan/VideoScan/Catalog/DateTriangulator.swift", "could_be_private": 35,
                       "widened_for_split": 0, "decls": 86}],
            "baseline_before": 2520, "baseline_after": 2518, "new": new, "fixed": 2, "shrink_skipped": False}


def backfill_row(ts):
    folder = {"files": 5, "functions": 50, "mean_ccn": 4.4, "ccn_over_15": 2, "ccn_over_30": 1, "nloc_over_80": 1,
              "offenders": 3, "files_over_800": 0}
    return {"schemaVersion": 1, "ts": iso(ts), "sha": "0badf00d", "run_kind": "backfill", "backfill": True,
            "totals": {"swift": folder, "python": folder, "all": folder}, "swift_by_folder": None,
            "python_by_folder": None, "folders_mapped_pct": 40.0}


def complexity_row(ts, offenders, new):
    folder = {"files": 10, "functions": 100, "mean_ccn": 3.9, "ccn_over_15": 4, "nloc_over_80": 2,
              "offenders": 5, "files_over_800": 1}
    return {"ts": iso(ts), "sha": "abcd1234", "run_kind": "nightly",
            "swift_by_folder": {"Hallie": folder, "Core": {**folder, "mean_ccn": 3.5}},
            "python_by_folder": {"tools": {**folder, "mean_ccn": 6.3}},
            "totals": {"swift": {**folder, "mean_ccn": 3.85, "offenders": offenders, "ccn_over_15": 435, "ccn_over_30": 28,
                                 "nloc_over_80": 241, "files": 1109},
                       "python": {**folder, "mean_ccn": 6.54},
                       "all": {**folder, "offenders": offenders + 99}},
            "top15": [{"file": "tools/nightly_findings_to_issues.py", "function": "plan_ticket", "ccn": 111,
                       "nloc": 162, "lang": "python"},
                      {"file": "VideoScan/VideoScan/Hallie/HallieLineageQuestion.swift",
                       "function": "HallieLineageQuestion.detectShape", "ccn": 88, "nloc": 250, "lang": "swift"}],
            "debt_offenders": offenders, "debt_new": new, "debt_worse": 0, "debt_fixed": 1,
            "duplicate_rate_pct": 1.96, "duplicate_blocks": 178, "gate_overrides_recent": 1}


needs_node = pytest.mark.skipif(shutil.which("node") is None, reason="needs node")


@needs_node
@pytest.mark.parametrize("saved, expected", [(None, "dark"), ("invalid", "dark"), ("dark", "dark"),
                                             ("light", "light"), ("auto", None)])
def test_theme_defaults_dark_and_respects_saved_choice(tmp_path, saved, expected):
    out = run_page(tmp_path, {}, storage={} if saved is None else {"vs-theme": saved})
    assert out["errors"] == []
    assert out["theme"] == expected
    assert out["sections"]["theme-toggle"].strip() == f"Theme: {expected or 'auto'}"


@needs_node
def test_sprint_graphic_reports_actual_completion(tmp_path):
    out = run_page(tmp_path, {"summary_latest.json": summary_fixture(datetime.now(timezone.utc))})
    assert out["errors"] == []
    ring = re.search(r'<svg\b[^>]*class="ring"[^>]*>.*?</svg>', out["sections"]["head"])
    assert ring, "published sprint completion needs an accessible graphic"
    assert 'role="img"' in ring[0]
    assert 'aria-label="1 of 9 sprint items complete"' in ring[0]
    assert ">11%</text>" in ring[0]
    # Check the drawn proportion too: text alone cannot catch a full or empty arc.
    arc = re.search(r'pathLength="100"\s+stroke-dasharray="([\d.]+) 100"', ring[0])
    assert arc and float(arc[1]) == pytest.approx(100 / 9)


@needs_node
@pytest.mark.parametrize("sprint", [None, {}, {"open": 0, "closed": 0}, {"open": 8},
                                   {"open": -1, "closed": 2}, {"open": 8, "closed": "1"},
                                   {"open": 8, "closed": 0.5}])
def test_sprint_without_valid_nonempty_counts_has_no_completion_graphic(tmp_path, sprint):
    summary = summary_fixture(datetime.now(timezone.utc))
    summary["sprint"] = sprint
    out = run_page(tmp_path, {"summary_latest.json": summary})
    assert out["errors"] == []
    assert 'class="ring"' not in out["sections"]["head"]


@needs_node
def test_summary_sparkline_does_not_join_across_missing_sample(tmp_path):
    now = datetime.now(timezone.utc)
    rows = [{"ts": iso(now - timedelta(days=4 - i)), "strict_warning_total": value}
            for i, value in enumerate([10, 20, None, 30, 40])]
    out = run_page(tmp_path, {"static_analysis.jsonl": jsonl(rows)})
    assert out["errors"] == []
    spark = re.search(r'<svg\b[^>]*class="spark"[^>]*>.*?</svg>', out["sections"]["sum-san"])
    assert spark
    segments = re.findall(r'<polyline\b[^>]*points="([^"]+)"', spark[0])
    assert len(segments) == 2, "missing measurement must separate the two observed runs"
    runs = [[tuple(map(float, point.split(","))) for point in segment.split()] for segment in segments]
    assert [len(run) for run in runs] == [2, 2]
    assert runs[0][-1][0] < runs[1][0][0], "retain the missing sample's horizontal gap"
    assert all(run[0][1] > run[1][1] for run in runs), "both observed runs increase"


@needs_node
def test_summary_first_page_renders_every_line_and_twist(tmp_path):
    now = datetime.now(timezone.utc)
    out = run_page(tmp_path, full_fixtures(now), {"hash": "#all"})
    assert out["errors"] == []
    head = out["sections"]["head"]
    # Headline strip: version, app-only lines, last night per Mac, stability, open bugs, sprint.
    assert "5.1" in head and "build 1" in head and "b07f9da" in head and "CI on main" in head and "success" in head
    assert "376,166" in head and "app only" in head and "+1,958 since" in head        # app_source_lines, never total_swift_lines
    assert "546,428" not in head
    assert "11,211" in head and "2 failing on the worst Mac" in head and "3 failing" not in head, "the worst Mac's count, never a sum across Macs"
    assert "M1" in head and "did not run · build-timeout:5400s" in head and "11,207 passed · 1 failed" in head
    assert "red 1 night running" in head and "days since a red night" in head
    value, words = bug_tile(head)
    assert "Open bugs:</small> 11" in value and "High priority:</small> 4" in value
    assert f'href="{BUGS_URL}"' in words and f'href="{HIGH_URL}"' in words
    # The Open-bugs tile carries the 30-day sparkline; the day gh failed breaks it into two runs.
    bug_spark = re.search(r'<svg\b[^>]*class="spark"[^>]*>.*?</svg>', head)
    assert bug_spark and len(re.findall(r"<polyline\b", bug_spark[0])) == 2
    assert "Week of Oct 12" in head and "1 of 9" in head and re.search(r"[56] days left", head)   # due at local midnight
    # The timeline: one cell per night per Mac, the M1 amber (did_not_run), never red.
    tl = out["sections"]["tl"]
    assert tl.count('class="cell ') == 3 * 90
    assert tl.count("cell did_not_run") == 31 and tl.count("cell red") == 4 and tl.count("cell watch") == 1
    assert "9,004 passed · 4 failed (a few)" in tl
    assert 'title="M1 · ' in tl and "did not run · build-timeout:5400s" in tl and "demo-2026-10-10" in tl
    assert "1 of 90 nights" not in out["sections"]["stab"]
    stab = out["sections"]["stab"]
    assert "nights every test passed on every Mac that ran" in stab and "nights a few tests failed" in stab and "nights broken" in stab
    assert "demo-2026-10-10" in stab and "Macs ran and were green" not in stab
    table = out["sections"]["tl-table"]
    assert "did not run" in table and "failed" in table and ">failed<" not in table
    # Every area has a summary line (dot, name, sentence, number) and an opened twist with its body.
    for area in AREAS:
        line = out["sections"][f"sum-{area}"]
        assert 'class="dot' in line and 'class="sent"' in line and 'class="big"' in line, area
        assert out["sections"][f"body-{area}"].strip(), area
        assert out["open"][f"area-{area}"] is True, area
        assert "toggle" in out["listeners"][f"area-{area}"], area
    tests_line = out["sections"]["sum-tests"]
    assert "Red <b>1 night running</b>" in tests_line and "2</b> tests fail on the M4" in tests_line
    assert "1</b> test fails on the M5" in tests_line and "M1 <b>did not run</b> (build-timeout:5400s)" in tests_line
    assert "11,211 passed · 2 failed" in tests_line and "Logic coverage <b>75.0%</b>, up vs 7 days ago" in tests_line
    assert "28 over CCN 30" in out["sections"]["sum-size"] and "376,166" in out["sections"]["sum-size"]
    assert "435 over CCN 15" in out["sections"]["sum-debt"] and "2 new" in out["sections"]["sum-debt"]
    assert "sanitizers: no run" in out["sections"]["sum-san"] and "strict warnings 539 (815 a week ago)" in out["sections"]["sum-san"]
    assert "80.0%" in out["sections"]["sum-hallie"] and "8 of 10" in out["sections"]["sum-hallie"] and "incomplete" in out["sections"]["sum-hallie"]
    assert "1,274 clips with evidence" in out["sections"]["sum-events"] and "308 candidate events" in out["sections"]["sum-events"]
    assert "Codex: 2 passes, 5 findings, 2 passes closed" in out["sections"]["sum-reviews"] and "no data yet" in out["sections"]["sum-reviews"]
    assert "No catalog-search benchmark" in out["sections"]["sum-speed"]
    # The twists carry the old charts and tables.
    for chart in ["c-tests-passed", "c-tests-failed", "c-cov-folders", "c-cov-trend", "c-sa-compiler", "c-sa-codeql",
                  "c-codex", "c-hallie", "c-size-folders", "c-size-trend", "c-cx-debt", "c-cx-folders",
                  "c-ex-trend", "c-ex-folders", "c-bugs"]:
        assert chart in out["charts"], chart
    bugs = out["chartData"]["c-bugs"]
    assert len(bugs["labels"]) == 12 and [ds["label"] for ds in bugs["datasets"]] == ["opened", "fixed", "open bugs"]
    assert bugs["datasets"][2]["data"][-1] == 11 and sum(v or 0 for v in bugs["datasets"][0]["data"]) == 29   # 29 published days, 1 opened each
    assert "c-sa-san" not in out["charts"] and out["notes"]["c-sa-san-note"] == "no data yet"      # TSan null, never a zero line
    assert "detectShape" in out["sections"]["cx-top"] and "plan_ticket" not in out["sections"]["cx-top"]
    assert "NewView.body" in out["sections"]["cx-new"] and "1 new, 0 worse, 1 fixed" in out["sections"]["cx-new-title"]
    ovr = out["sections"]["cx-ovr"]
    assert "Big.run" in ovr and "35" in ovr and "abc1234" in ovr and "Rick Breen" in ovr
    assert "DateTriangulator.swift" in out["sections"]["ex-top"]
    assert "DeleteDuplicatesJob.swift" in out["sections"]["pf-table"] and "120.9" in out["sections"]["pf-table"]
    assert "412 files with any debt" in out["sections"]["pf-table-title"]
    assert "No adversarial" not in out["sections"]["body-reviews"] or "no data yet" in out["sections"]["body-reviews"]
    assert "No catalog-search benchmark data" in out["sections"]["search-benchmark-cards"]
    # The POI replay row never becomes a test count; free text riding on rows is never rendered.
    blob = json.dumps(out)
    assert "999999" not in blob
    for secret in SECRETS:
        assert secret not in blob, secret


@needs_node
def test_weekly_bug_bars_sum_the_published_days_and_never_fabricate_a_week(tmp_path):
    now = datetime.now(timezone.utc)
    monday = datetime(now.year, now.month, now.day, 9, tzinfo=timezone.utc) - timedelta(days=now.weekday())
    rows = [
        daily_row(monday - timedelta(hours=5), 10, opened=5, closed=5),        # 04:00, same UTC day as the next row:
        daily_row(monday, 10, opened=2, closed=1),                             # the later row wins, no double count
        daily_row(monday + timedelta(days=1), 11, opened=1, closed=0),         # rest of this week unpublished
        daily_row(monday - timedelta(days=4), 9, opened=3, closed=2),          # last week: one day only
        daily_row(monday - timedelta(days=21), 8, opened=1, closed=4),         # three weeks ago
    ]                                                                          # two weeks ago: nothing at all
    summary = summary_fixture(now)
    out = run_page(tmp_path, {"summary_latest.json": summary, "github_daily.jsonl": jsonl(rows)}, {"hash": "#all"})
    assert out["errors"] == []
    data = {ds["label"]: ds["data"] for ds in out["chartData"]["c-bugs"]["datasets"]}
    assert len(out["chartData"]["c-bugs"]["labels"]) == 12
    assert data["opened"][-4:] == [1, None, 3, 3] and data["fixed"][-4:] == [4, None, 2, 1]
    assert data["open bugs"][-4:] == [8, None, 9, 11]
    assert all(v is None for series in data.values() for v in series[:-4]), "weeks before the data are gaps, not zeros"
    # The tile's 30-day sparkline: the published days only, in three runs (three weeks ago; last week's day;
    # this week's days) — the unpublished days between them stay gaps.
    bug_spark = re.search(r'<svg\b[^>]*class="spark"[^>]*>.*?</svg>', out["sections"]["head"])
    assert bug_spark and len(re.findall(r"<polyline\b", bug_spark[0])) == 3
    # A day that is not a timestamp is ignored, never a crash.
    bad = rows + [{"ts": "2026-13-45T00:00:00Z", "open_bugs": 99}, {"ts": None, "open_bugs": 99}, {"open_bugs": 99}]
    out2 = run_page(tmp_path, {"summary_latest.json": summary, "github_daily.jsonl": jsonl(bad)}, {"hash": "#all"})
    assert out2["errors"] == [] and out2["chartData"]["c-bugs"] == out["chartData"]["c-bugs"]


@needs_node
def test_without_the_daily_stream_the_bug_tile_is_the_snapshot_alone(tmp_path):
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    fixtures["github_daily.jsonl"] = None
    out = run_page(tmp_path, fixtures, {"hash": "#all"})
    assert out["errors"] == []
    head = out["sections"]["head"]
    value, words = bug_tile(head)
    assert "Open bugs:</small> 11" in value and "High priority:</small> 4" in value and "GitHub issues →" in words
    assert 'class="spark"' not in head, "no daily rows: no sparkline, no fabricated trend"
    assert "c-bugs" not in out["charts"] and "github_daily.jsonl" in out["notes"]["c-bugs-note"]


@needs_node
def test_event_recognition_line_and_twist_render_counts_only(tmp_path):
    """The Event recognition area (replaces Person recognition, Rick 2026-10-12): the line is
    evidence → candidates (strong) + marks; the dot is grey with no stream, watch under 30 marks,
    green / watch by precision at 30+; the twist is the per-category table plus the coverage line."""
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    out = run_page(tmp_path, fixtures, {"hash": "#all"})
    assert out["errors"] == []
    line = out["sections"]["sum-events"]
    assert "Event recognition" in line and "dot watch" in line                      # 47 marks, 81 % < 90 %
    assert "1,274 clips with evidence → <b>308 candidate events</b> (109 strong); 47 marks, <b>81% right</b>." in line
    assert 'class="big">308 candidate events' in line and "snapshot" in line
    assert "<polyline" not in line                                                   # single snapshot: no trend line drawn
    body = out["sections"]["body-events"]
    assert "captions on <b>6,120</b> (62%)" in body and "transcripts on <b>3,310</b> (34%)" in body and "<b>9,810</b> active records" in body
    assert "<td>Birthday</td><td>120</td><td>30</td><td>5</td><td>86%</td>" in body        # per-category precision
    assert "<td>Christmas</td><td>88</td><td>8</td><td>4</td><td>67%</td>" in body
    assert "<td>Graduation</td><td>0</td><td>0</td><td>0</td><td>—</td>" in body            # no marks: no fake 0 %
    assert body.index("<td>Birthday</td>") < body.index("<td>Christmas</td>") < body.index("<td>Graduation</td>")
    # 30+ marks and 90 %+ right: green. Fewer than 30 marks: watch, whatever the ratio. No marks: watch, "no marks yet".
    green = dict(fixtures, **{"events_latest.json": dict(events_fixture(now), marks_yes=45, marks_no=3)})
    assert "dot green" in run_page(tmp_path, green, {"hash": "#all"})["sections"]["sum-events"]
    few = dict(fixtures, **{"events_latest.json": dict(events_fixture(now), marks_yes=12, marks_no=0)})
    few_line = run_page(tmp_path, few, {"hash": "#all"})["sections"]["sum-events"]
    assert "dot watch" in few_line and "12 marks, <b>100% right</b>" in few_line
    none = dict(fixtures, **{"events_latest.json": events_fixture(now, marks=False)})
    none_out = run_page(tmp_path, none, {"hash": "#all"})
    assert "dot watch" in none_out["sections"]["sum-events"] and "no marks yet" in none_out["sections"]["sum-events"]
    assert "<td>Birthday</td><td>120</td><td>—</td><td>—</td><td>—</td>" in none_out["sections"]["body-events"]
    # No stream: grey, "nothing published", no number; the twist says what is missing.
    missing = dict(fixtures, **{"events_latest.json": None})
    m_out = run_page(tmp_path, missing, {"hash": "#all"})
    assert m_out["errors"] == []
    assert "dot grey" in m_out["sections"]["sum-events"] and "nothing published yet" in m_out["sections"]["sum-events"]
    assert "events_latest.json" in m_out["sections"]["body-events"] and ">0<" not in m_out["sections"]["sum-events"]
    # Person recognition is gone from the page and its data is no longer read.
    page = PAGE.read_text()
    assert "Person recognition" not in page and "summary.person" not in page and "area-person" not in page
    assert "Person recognition" not in json.dumps(out) and "sum-person" not in out["sections"]
    for secret in SECRETS:
        assert secret not in json.dumps(out), secret


@needs_node
def test_open_bugs_tile_is_two_counts_and_github_links(tmp_path):
    """Rick's ask (2026-10-12): value line "Open bugs: XX  High priority: YY" on one line, words line
    = links into GitHub; the "not available" / "(CI row)" / "issues open in all" sentences are gone."""
    now = datetime.now(timezone.utc)
    out = run_page(tmp_path, full_fixtures(now), {"hash": "#all"})
    assert out["errors"] == []
    head = out["sections"]["head"]
    value, words = bug_tile(head)
    assert re.fullmatch(r'<span class="duo"><span><small>Open bugs:</small> 11</span><span><small>High priority:</small> 4</span></span>', value)
    assert words == (f'<a href="{BUGS_URL}" target="_blank" rel="noopener">GitHub issues →</a> · '
                     f'<a href="{HIGH_URL}" target="_blank" rel="noopener">high priority →</a>')
    for phrase in OLD_BUG_WORDING:
        assert phrase not in head, phrase
    assert 'class="spark"' in head                                  # the 30-day sparkline stays under the counts
    # High Priority unknown (that one gh call failed): "—" for it, the bug link alone, no second link.
    fixtures = full_fixtures(now)
    fixtures["summary_latest.json"]["github"]["high_priority_open"] = None
    out2 = run_page(tmp_path, fixtures, {"hash": "#all"})
    assert out2["errors"] == []
    value2, words2 = bug_tile(out2["sections"]["head"])
    assert "Open bugs:</small> 11" in value2 and "High priority:</small> —" in value2
    assert words2 == f'<a href="{BUGS_URL}" target="_blank" rel="noopener">GitHub issues →</a>'


@needs_node
def test_open_bugs_tile_without_a_summary_is_two_dashes_and_the_bug_link(tmp_path):
    now = datetime.now(timezone.utc)
    out = run_page(tmp_path, full_fixtures(now, with_summary=False))
    assert out["errors"] == []
    head = out["sections"]["head"]
    value, words = bug_tile(head)
    assert "Open bugs:</small> —" in value and "High priority:</small> —" in value
    assert words == f'<a href="{BUGS_URL}" target="_blank" rel="noopener">GitHub issues →</a>'
    assert 'class="spark"' not in head
    for phrase in OLD_BUG_WORDING:
        assert phrase not in head, phrase
    # Nothing at all published: the same two dashes and the same single link, never a count.
    out2 = run_page(tmp_path, {}, {"hash": "", "search": "?all"})
    value2, words2 = bug_tile(out2["sections"]["head"])
    assert value2.count("—") == 2 and words2 == words and not re.search(r"\d", value2)


@needs_node
def test_without_a_summary_the_page_says_so_and_still_renders(tmp_path):
    out = run_page(tmp_path, full_fixtures(datetime.now(timezone.utc), with_summary=False))
    assert out["errors"] == []
    head = out["sections"]["head"]
    assert "nightly summary not published yet" in head and head.count("—") >= 4
    value, words = bug_tile(head)
    assert value.count("—") == 2 and "81" not in value and "81" not in words   # history's open_issues is NOT a fallback
    assert f'href="{BUGS_URL}"' in words and "High Priority" not in words
    assert "no data yet" in out["sections"]["tl"] and "summary_latest.json" in out["sections"]["tl"]
    assert "Nightly summary not published yet" in out["sections"]["sum-tests"]
    assert "summary_latest.json not published yet" in out["sections"]["status"]
    for area in AREAS:
        assert out["open"][f"area-{area}"] is False, area        # no #all: twists stay closed
    assert "SECRET-HOST" not in json.dumps(out)


@needs_node
def test_everything_missing_renders_no_data_not_zero(tmp_path):
    out = run_page(tmp_path, {}, {"hash": "", "search": "?all"})
    assert out["errors"] == []
    assert out["charts"] == []
    assert "Could not load the metrics branch" in out["sections"]["status"]
    head = out["sections"]["head"]
    assert head.count("—") >= 4 and "no data yet" in head
    for area in AREAS:
        line = out["sections"][f"sum-{area}"]
        assert "dot grey" in line, area
        assert re.search(r"no data yet|nothing published|not published|No .*published", line), area
        assert ">0<" not in line, area
        assert out["open"][f"area-{area}"] is True, area           # ?all opens everything too
    for box in ["body-tests", "body-size", "body-debt", "body-san", "body-reviews"]:
        text = out["sections"][box]
        assert re.search(r"no data yet|No .* (rows|published)", text), box


def test_page_structure_every_twist_has_a_summary_line():
    page = PAGE.read_text()
    ids = [i for i in re.findall(r'\bid="([^"]+)"', page) if "${" not in i]     # literal ids, not template slots
    assert len(ids) == len(set(ids)), "duplicate element ids"
    areas = re.findall(r'<details class="area" id="area-([a-z]+)">', page)
    assert areas == AREAS
    js_areas = re.findall(r'\{ id: "([a-z]+)", name: "', page)
    assert js_areas == AREAS
    for area in AREAS:
        assert f'id="sum-{area}"' in page and f'id="body-{area}"' in page and f'id="{area}-error"' in page, area
        assert f"  {area}(d) {{" in page, f"no SUMMARY/BODIES builder for {area}"
    markup = page.split("<script>")[0]
    assert markup.count("<details") == markup.count("</details>")
    assert markup.count("<div") == markup.count("</div>")
    assert "#all" in page and "openAll(true)" in page and "?all" in page.replace("[?&]all", "?all")


def test_page_never_reads_free_text_fields():
    page = PAGE.read_text()
    for field in ["failed_names", "crashed_names", "hallie_replay_reason", "hallie_voice_reason",
                  "item.title", "zero_files", "person_eval_", ".reason"]:
        assert field not in page, field
    # The page never classifies a night itself: the publisher did (classify_nightly_row).
    # It reads the published state and never looks at a row's total/status to decide colour.
    script = page.split("<script>")[1]
    assert "did_not_run" in script and "classify" not in script
    assert "r.total || 0) > 0 ? r.passed" in script          # charts still treat "no test ran" as a gap, not a zero


def test_page_data_comes_from_public_sources_only():
    page = PAGE.read_text()
    assert "https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js" in page
    assert "raw.githubusercontent.com/${REPO}" in page
    assert 'rawUrl("summary_latest.json")' in page
    hosts = set(re.findall(r"https://([a-z0-9.-]+)/", page))
    assert hosts <= {"cdnjs.cloudflare.com", "api.github.com", "raw.githubusercontent.com", "github.com"}, hosts
    # Phone width: 16px gutters, nothing wider than the viewport.
    assert "@media (max-width: 720px)" in page and "padding: 12px 16px 32px" in page
    assert '<meta name="viewport" content="width=device-width,initial-scale=1">' in page
