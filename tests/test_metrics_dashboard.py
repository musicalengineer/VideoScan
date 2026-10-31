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
const actions = JSON.parse(process.argv[5] || "[]");
globalThis.localStorage = {
  getItem(key) { return storage[key] ?? null; },
  setItem(key, value) { storage[key] = String(value); },
};
let script = html.match(/<script>\n([\s\S]*?)<\/script>/)[1];
script = script.replace(/\nloadData\(\);\s*$/, "\nglobalThis.__done = loadData();");
script += "\nglobalThis.__pollMetricsRefresh = pollMetricsRefresh;";
const elements = new Map();
function element(id = "") {
  const classes = new Set();
  const attributes = new Map();
  const value = { id, children: [], innerHTML: "", textContent: "", style: {}, className: "", open: false, listeners: [], callbacks: {}, value: "", checked: false, disabled: false,
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x), toArray: () => [...classes] },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener(kind, fn) { this.listeners.push(kind); (this.callbacks[kind] ||= []).push(fn); },
    contains() { return false; }, getAttribute(key) { return attributes.get(key) ?? null; },
    setAttribute(key, value) { attributes.set(key, String(value)); },
    removeAttribute(key) { attributes.delete(key); } };
  // Replacing a select's options resets its browser selection. Model that side
  // effect so an outage-recovery test really catches silent scope widening.
  let innerHTML = "";
  Object.defineProperty(value, "innerHTML", {get() { return innerHTML; }, set(markup) {
    innerHTML = markup;
    if (this.tagName === "SELECT") {
      const options = [...markup.matchAll(/<option\b([^>]*)>/g)];
      const chosen = options.find(o => /(?:^|\s)selected(?:\s|=|$)/.test(o[1])) || options[0];
      this.value = chosen ? (chosen[1].match(/\bvalue="([^"]*)"/) || [])[1] || "" : "";
    }
  }});
  return value;
}
// Elements declared hidden in the HTML start hidden here too.
for (const m of html.matchAll(/<(?:div|p|details|form|label)[^>]*class="([^"]*)"[^>]*id="([^"]+)"|<(?:div|p|details|form|label)[^>]*id="([^"]+)"[^>]*class="([^"]*)"/g)) {
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
for (const m of html.matchAll(/<(input|select|textarea)\b([^>]*)>/g)) {
  const id = m[2].match(/\bid="([^"]+)"/);
  if (!id) continue;
  const el = document.getElementById(id[1]);
  el.tagName = m[1].toUpperCase();
  el.checked = /\bchecked\b/.test(m[2]);
  el.disabled = /\bdisabled\b/.test(m[2]);
  el.value = (m[2].match(/\bvalue="([^"]*)"/) || [])[1] || "";
  if (m[1] === "select") {
    const inner = html.slice(m.index + m[0].length).split("</select>")[0];
    const options = [...inner.matchAll(/<option\b([^>]*)>/g)];
    const choice = options.find(o => /(?:^|\s)selected(?:\s|=|$)/.test(o[1])) || options[0];
    el.value = choice ? (choice[1].match(/\bvalue="([^"]*)"/) || [])[1] || "" : "";
  }
}
const initialTheme = html.match(/<html\b[^>]*data-theme="([^"]+)"/);
if (initialTheme) document.documentElement.setAttribute("data-theme", initialTheme[1]);
if (Object.keys(loc).length) globalThis.location = { hash: loc.hash || "", search: loc.search || "", pathname: loc.pathname || "/", ...loc };
// Polling is exercised explicitly by actions, never by wall-clock waits.
globalThis.setInterval = () => 1;
const charts = [];
globalThis.Chart = function(target, config) { charts.push({ id: target.id, config }); this.canvas = target; this.resize = () => {}; };
const requests = [];
globalThis.fetch = async (url, options = {}) => {
  url = String(url);
  const method = options.method || "GET";
  requests.push({url, method, options, body: options.body ? JSON.parse(options.body) : null});
  const planned = fixtures.__responses && fixtures.__responses[`${method} ${url}`];
  if (planned) {
    const reply = planned.length > 1 ? planned.shift() : planned[0];
    if (reply.error) throw new Error(reply.error);
    return {ok: reply.status >= 200 && reply.status < 300, status: reply.status,
      json: async () => reply.body, text: async () => JSON.stringify(reply.body)};
  }
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
  for (const action of actions) {
    for (const [id, properties] of Object.entries(action.set || {})) Object.assign(document.getElementById(id), properties);
    if (action.poll) await globalThis.__pollMetricsRefresh();
    if (action.event) {
      const el = document.getElementById(action.event.id);
      const callbacks = el.callbacks[action.event.kind] || [];
      if (!callbacks.length) throw new Error(`No ${action.event.kind} listener for ${el.id}`);
      for (const callback of callbacks) await callback({preventDefault() {}, target: el});
    }
  }
  const text = el => [el.innerHTML, el.textContent, ...el.children.map(text)].join(" ");
  const out = { charts: charts.map(c => c.id), errors, sections: {}, notes: {}, open: {}, listeners: {}, requests, controls: {},
    theme: document.documentElement.getAttribute("data-theme"),
    chartData: Object.fromEntries(charts.map(c => [c.id, c.config && c.config.data])) };
  for (const [id, el] of elements) {
    if (id.endsWith("-error") && !el.classList.contains("hidden")) out.errors.push(`${id}: ${el.textContent}`);
    if (id.endsWith("-note") && !el.classList.contains("hidden")) out.notes[id] = el.textContent;
    if (id.startsWith("area-")) { out.open[id] = el.open; out.listeners[id] = el.listeners; }
    out.sections[id] = text(el);
    if (id.startsWith("refresh-")) out.controls[id] = {value: el.value, checked: el.checked, disabled: el.disabled, hidden: el.classList.contains("hidden")};
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


def run_page(tmp_path, fixtures, location=None, storage=None, actions=None):
    fx = tmp_path / "fixtures.json"
    fx.write_text(json.dumps(fixtures))
    r = subprocess.run(["node", "-e", HARNESS, str(PAGE), str(fx), json.dumps(location or {}), json.dumps(storage or {}), json.dumps(actions or [])],
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
            # An older-shaped row: no Core or Hallie lane fields at all (the ladder shows them grey, never 0).
            hosts["M4"] = {"state": "red", "passed": 11211, "failed": 2, "total": 11275, "reason": "failed-tests:2"}
            # 2026-10-31: the app lane 1 failed, Core 2 failed, Hallie strict 52/56, advisory 142/826 cut short,
            # voice ok — the card must name the lanes and the ladder must colour each on its own.
            hosts["M5"] = {"state": "red", "passed": 11207, "failed": 1, "total": 11275, "reason": "core-failed-tests:2",
                           "core_passed": 2133, "core_failed": 2, "core_status": "failed", "hallie_status": "failed",
                           "hallie_strict_pass": 52, "hallie_strict_expected": 56, "hallie_strict_status": "failed",
                           "hallie_advisory_pass": 142, "hallie_advisory_expected": 826, "hallie_advisory_status": "incomplete",
                           "hallie_voice_status": "ok"}
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
                                 "swift_by_folder": {"Hallie": {"lines": 68739, "files": 181}, "Core": {"lines": 42550, "files": 144}, "Tests": {"lines": 300000, "files": 1000}}}]),
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
def module_bucket(lines, max_ccn, fix90, **kw):
    b = {"lines": lines, "files": 20, "functions": 200, "mean_ccn": 3.5, "max_ccn": max_ccn, "ccn_over_15": 1,
         "ccn_over_30": 0, "files_over_1000": 0, "fix_commits_90d": fix90, "fix_commits_all": fix90 + 5}
    b.update(kw)
    return b


def test_module_health_table_grades_sorts_and_excludes_tests(tmp_path):
    """The Module health table (2026-10-18): per-module rows from modules.jsonl and the
    nightly's `modules`; worst grade first; the grade's why in its tooltip; Tests never a row."""
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    old, fresh = now - timedelta(days=8), now - timedelta(hours=2)
    fixtures["modules.jsonl"] = jsonl([
        {"schemaVersion": 1, "ts": iso(old), "sha": "0badf00d", "run_kind": "backfill",
         "modules": {"Core": module_bucket(40000, 52, 100), "Core/Store": module_bucket(6000, 13, 2)}},
    ])
    nightly = complexity_row(fresh, 514, 2)
    nightly["modules"] = {
        "Core": module_bucket(43000, 52, 140, max_fn="PrunePlan.plan", deps=["SQLite3"], ccn_over_15=4,
                              top5=[{"function": "PrunePlan.plan", "file": "VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift",
                                     "ccn": 52, "nloc": 108}],
                              top3_files=[{"file": "VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift", "lines": 1245}]),
        "Core/Store": module_bucket(6344, 13, 2, deps=["GRDB"], ccn_over_15=0),
        "Steward": module_bucket(3866, 17, 8, deps=[]),
    }
    fixtures["complexity.jsonl"] = jsonl([complexity_row(old, 520, 10), nightly])
    out = run_page(tmp_path, fixtures, {"hash": "#all", "search": ""})
    assert out["errors"] == []
    table = out["sections"]["mod-health"]
    rows = re.findall(r'<tr class="mod-row".*?</tr>', table, re.S)
    names = [re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)[1] for r in rows]
    assert names[0] == "Core" and set(names) == {"Core", "Core/Store", "Steward"} and "Tests" not in table
    assert "max CCN 52 &gt; 50 forces D" in rows[0] and ">D</span>" in rows[0]
    assert "GRDB" in rows[names.index("Core/Store")] and ">A</span>" in rows[names.index("Core/Store")]
    assert "145 all-time" in rows[0] and "PrunePlan.plan" in table and "PrunePlan.swift" in table
    assert "lines <span class=\"bad\">▲3.0k" in rows[0]                    # vs the row 8 days ago
    assert "Grade = mean of the sub-grades" in table
    assert "1 at risk" in out["sections"]["sum-size"]


def test_module_health_without_per_module_rows_uses_folder_rows(tmp_path):
    """Before any per-module row is published, the table falls back to swift_by_folder
    (fewer columns, never a fake zero) and still leaves Tests out."""
    now = datetime.now(timezone.utc)
    out = run_page(tmp_path, full_fixtures(now), {"hash": "#all", "search": ""})
    assert out["errors"] == []
    table = out["sections"]["mod-health"]
    assert "Hallie" in table and "Tests" not in table and "mod-row" in table


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
    # The worst Mac counts every lane (M5: 1 app + 2 Core = 3), never a sum across Macs (5).
    assert "11,211" in head and "3 failing on the worst Mac" in head and "5 failing" not in head, "the worst Mac's count, never a sum across Macs"
    assert "M1" in head and "did not run · build-timeout:5400s" in head
    # RED 2026-10-31: every lane named with its own numbers, the lane that broke it said in words.
    assert "11,207 passed · 1 failed" in head and "Core 2,133 passed · 2 failed" in head and "Hallie replay failed" in head
    assert "broken (core-failed-tests:2)" in head
    assert "0 failed — broken" not in head
    # The M4 row has no Core lane fields (older row): it says nothing about Core rather than inventing zeros.
    assert "Core 0 passed" not in head
    # The 2 AM run is named by its own date, not as "the night of" the morning after.
    assert "2 AM run of" in head
    # RED 2026-10-31 (Rick): one ladder per Mac, one rung per lane of the 2 AM run, each rung coloured by
    # its own lane's verdict (app and Core by the 0 / under-10 / 10-plus rule; Hallie by its pass fraction
    # and status; grey where the lane did not run or the row predates it). The gauntlet is not a rung:
    # it is not part of the nightly, and a scoped run must never change this tile (the test below).
    ladders = re.findall(r'<svg\b[^>]*class="ladder"[^>]*data-host="([^"]+)"[^>]*>(.*?)</svg>', head, re.S)
    assert [h for h, _ in ladders] == ["M4", "M5", "M1"], ladders
    rungs = {h: dict(re.findall(r'data-lane="([^"]+)" data-state="([^"]+)"', body)) for h, body in ladders}
    assert rungs["M5"] == {"app": "watch", "core": "watch", "hallie-strict": "watch", "hallie-advisory": "red",
                           "hallie-voice": "green"}, rungs["M5"]
    assert rungs["M4"] == {"app": "watch", "core": "grey", "hallie-strict": "grey", "hallie-advisory": "grey",
                           "hallie-voice": "grey"}, rungs["M4"]
    assert set(rungs["M1"].values()) == {"grey"}, "a Mac whose nightly did not run has an unlit ladder"
    # Hovering a rung says the lane, its numbers and the reason code; the words under the ladder count the lanes to look at.
    assert "<title>Core package: 2,133 passed · 2 failed (core-failed-tests:2)</title>" in head
    assert "<title>Hallie advisory: 142 of 826 · incomplete</title>" in head
    assert "4 lanes to look at" in head and "all lanes green" not in head
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
                  "c-codex", "c-hallie", "c-size-trend", "c-cx-debt", "c-cx-folders",
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
def test_only_the_two_studios_show_and_an_off_rota_mac_is_never_named(tmp_path):
    """Rick 2026-10-28: the page shows only the M4 and the M5 Ultra. The laptops
    (M1, M5 Pro) stay off the rotation in nightly_rota.json, have no column and
    are not named anywhere, even when an older summary still lists them in
    nightly.off_rota. The Ultra's short label "Ultra" reads "M5 Ultra"."""
    now = datetime.now(timezone.utc)
    fx = full_fixtures(now)
    s = fx["summary_latest.json"]
    for night in s["nightly"]["nights"]:
        for h in ("M1", "M5"):
            night["hosts"].pop(h, None)
        if night is s["nightly"]["nights"][-1]:
            for h in ("M4", "Ultra"):
                night["hosts"][h] = {"state": "green", "passed": 12300, "failed": 0, "total": 12300, "reason": None}
    s["nightly"]["hosts"] = ["M4", "Ultra"]
    s["nightly"]["off_rota"] = ["M1", "M5"]
    out = run_page(tmp_path, fx, {"hash": "#all"})
    assert out["errors"] == []
    page = "".join(out["sections"].values())
    assert "off the rotation" not in page and "off the nightly rotation" not in page
    nightly = "".join(out["sections"][k] for k in ("head", "sum-tests", "tl", "stab"))
    assert "<b>M1</b>" not in nightly and "<b>M5</b>" not in nightly
    assert "the M1 " not in nightly and not re.search(r"the M5(?! Ultra)", nightly)
    head = out["sections"]["head"]
    assert "<b>M4</b>" in head and "<b>M5 Ultra</b>" in head
    assert '<div class="tile" data-state="green"><div class="label">Last night&#39;s tests</div>' in head \
        or '<div class="tile" data-state="green"><div class="label">Last night\'s tests</div>' in head
    tests_line = out["sections"]["sum-tests"]
    assert "the M5 Ultra is green" in tests_line
    tl = out["sections"]["tl"]
    assert tl.count('class="cell ') == 2 * 90 and 'title="M5 Ultra · ' in tl and 'title="M1 · ' not in tl


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


def refresh_fixture(requests=None):
    return {"capabilities": {"execution": "manager-queue", "machines": [
        {"id": "m4", "available": True}, {"id": "m5", "available": True},
        {"id": "m5Ultra", "available": False}], "areas": ["tests", "code", "hallie", "reviews"],
        "folders": ["VideoScan/VideoScan/Hallie", "tests"]}, "requests": requests or []}


def submit_refresh(**properties):
    return {"set": {"refresh-" + name: value for name, value in properties.items()},
            "event": {"id": "refresh-form", "kind": "submit"}}


@needs_node
def test_public_page_never_reads_or_writes_private_queue_even_with_poisoned_settings(tmp_path):
    out = run_page(tmp_path, {"/api/metrics-refresh": refresh_fixture()},
                   {"pathname": "/VideoScan/", "search": "?api=http://127.0.0.1:8765&machine=m4"},
                   {"metrics-api": "http://127.0.0.1:8765", "metrics-machine": "m4"},
                   [submit_refresh()])
    assert not [r for r in out["requests"] if "/api/metrics-refresh" in r["url"]]
    assert out["controls"]["refresh-form"]["hidden"]
    assert out["controls"]["refresh-submit"]["disabled"]
    assert "authenticated Engineering Room" in out["sections"]["refresh-message"]


@needs_node
def test_local_refresh_submits_explicit_selected_scope_and_never_changes_nightly_results(tmp_path):
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    fixtures["/api/metrics-refresh"] = refresh_fixture()
    fixtures["__responses"] = {"POST /api/metrics-refresh": [{"status": 201, "body": {
        "accepted": True, "queued": True, "task": {"state": "queued"}}}]}
    before = run_page(tmp_path, fixtures)
    out = run_page(tmp_path, fixtures, {"pathname": "/metrics"}, actions=[submit_refresh(
        machine={"value": "m5"}, manager={"value": "claude"}, code={"checked": False},
        reviews={"checked": True}, folder={"value": "VideoScan/VideoScan/Hallie"},
        revision={"value": "feature/metrics"}, **{"test-scope": {"value": "selected"},
        "selectors": {"value": "PairTests, tests/test_metrics_dashboard.py"}})])
    posts = [r for r in out["requests"] if r["method"] == "POST"]
    assert len(posts) == 1
    payload = posts[0]["body"]
    assert payload["machine"] == "m5" and payload["manager"] == "claude"
    assert payload["areas"] == ["tests", "reviews"]
    assert payload["testScope"] == "selected"
    assert payload["testSelectors"] == "PairTests, tests/test_metrics_dashboard.py"
    assert payload["folder"] == "VideoScan/VideoScan/Hallie" and payload["revision"] == "feature/metrics"
    assert payload["quietWindow"] is False and len(payload["requestId"]) >= 8
    assert posts[0]["url"] == "/api/metrics-refresh"
    assert posts[0]["options"]["credentials"] == "same-origin"
    for section in ["head", "tl", "sum-tests", "evidence-tests"]:
        assert out["sections"][section] == before["sections"][section], section
    assert "Waiting for a worker to claim it" in out["sections"]["refresh-message"]
    assert "measurement dates and revisions" in out["sections"]["refresh-message"]
    assert 'value="m5Ultra" disabled' in out["sections"]["refresh-machine"]


@needs_node
@pytest.mark.parametrize("settings, phrase", [
    ({"machine": {"value": "m5Ultra"}}, "not configured"),
    ({"machine": {"value": "m4"}}, "quiet window"),
    ({"test-scope": {"value": "selected"}, "selectors": {"value": ""}}, "1 and 40"),
    ({"test-scope": {"value": "selected"}, "selectors": {"value": "PairTests;touch pwn"}}, "without shell commands"),
    ({"folder": {"value": "../private"}}, "available source folders"),
])
def test_refresh_invalid_or_unavailable_choices_cannot_submit(tmp_path, settings, phrase):
    out = run_page(tmp_path, {"/api/metrics-refresh": refresh_fixture()}, {"pathname": "/metrics"},
                   actions=[submit_refresh(**settings)])
    assert not [r for r in out["requests"] if r["method"] == "POST"]
    assert phrase in out["sections"]["refresh-message"]


@needs_node
def test_refresh_uncertain_retry_reuses_key_and_accepts_already_running_request(tmp_path):
    fixtures = {"/api/metrics-refresh": refresh_fixture(), "__responses": {
        "POST /api/metrics-refresh": [{"error": "Connection lost after acceptance"}, {"status": 200,
            "body": {"accepted": True, "queued": False, "reused": True, "task": {"state": "working"}}}]}}
    out = run_page(tmp_path, fixtures, {"pathname": "/metrics"}, actions=[submit_refresh(), submit_refresh()])
    posts = [r for r in out["requests"] if r["method"] == "POST"]
    assert len(posts) == 2
    assert posts[0]["body"]["requestId"] == posts[1]["body"]["requestId"]
    message = out["sections"]["refresh-message"]
    assert "Existing request" in message and "Current task state: working" in message
    assert "could not be queued" not in message


@needs_node
def test_poll_outage_preserves_machine_folder_and_uncertain_retry_identity(tmp_path):
    fixtures = {"__responses": {
        "GET /api/metrics-refresh": [{"status": 200, "body": refresh_fixture()}, {"status": 503, "body": {}},
                                     {"status": 200, "body": refresh_fixture()}],
        "POST /api/metrics-refresh": [{"error": "Connection lost after acceptance"}, {"status": 200,
            "body": {"accepted": True, "queued": False, "reused": True, "task": {"state": "working"}}}]}}
    out = run_page(tmp_path, fixtures, {"pathname": "/metrics"}, actions=[
        submit_refresh(machine={"value": "m4"}, quiet={"checked": True}, folder={"value": "VideoScan/VideoScan/Hallie"}),
        {"poll": True}, {"poll": True}, submit_refresh()])
    posts = [r for r in out["requests"] if r["method"] == "POST"]
    assert len(posts) == 2
    assert posts[0]["body"] == posts[1]["body"], "poll recovery must neither broaden scope nor create a new request"
    assert posts[1]["body"]["machine"] == "m4" and posts[1]["body"]["folder"] == "VideoScan/VideoScan/Hallie"
    assert out["controls"]["refresh-machine"]["value"] == "m4"
    assert out["controls"]["refresh-folder"]["value"] == "VideoScan/VideoScan/Hallie"


@needs_node
def test_refresh_statuses_are_queue_evidence_and_escape_private_progress(tmp_path):
    requests = [{"state": state, "machine": "m5", "manager": "claude", "title": "Hallie folder review",
                 "progress": '<script>alert("bad")</script>', "updatedAt": "2026-10-20T12:00:00Z"}
                for state in ["queued", "working", "blocked", "done", "failed", "not-reporting", "waiting-on-human"]]
    out = run_page(tmp_path, {"/api/metrics-refresh": refresh_fixture(requests)}, {"pathname": "/metrics"})
    rendered = out["sections"]["refresh-requests"]
    for status in ["Queued", "Running", "Blocked", "Handled", "Failed"]:
        assert status in rendered
    assert "Status unknown" not in rendered
    assert "<script>" not in rendered and "&lt;script&gt;" in rendered
    assert "check their evidence date and SHA" in rendered


@needs_node
def test_freshness_reports_measurement_time_and_sha_not_latest_page_load(tmp_path):
    now = datetime.now(timezone.utc)
    stale_time = iso(now - timedelta(days=8))
    fixtures = full_fixtures(now)
    fixtures["history.jsonl"] = jsonl([{"ts": stale_time, "sha": "abcdef1234567890", "app_source_lines": 1000}])
    complexity = complexity_row(now, 500, 2)
    complexity.pop("sha", None)
    fixtures["complexity.jsonl"] = jsonl([complexity])
    out = run_page(tmp_path, fixtures)
    text = out["sections"]["evidence-size"]
    assert stale_time in text and "stale (>36h)" in text and "SHA abcdef123456" in text
    assert "revision not recorded" in text, "fresh complexity row cannot borrow code-size revision"


@needs_node
def test_passing_scoped_run_cannot_replace_full_suite_failure_or_freshness(tmp_path):
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    before = run_page(tmp_path, fixtures)
    fixtures["testdriver.jsonl"] += jsonl([{"source": "gauntlet", "schemaVersion": 1, "machine": "m5",
        "ts": iso(now), "sha": "0123456789abcdef", "dirty": True, "passed": 999999, "failed": 0, "total": 999999,
        "stages": [{"name": "unit", "status": "passed", "passed": 2, "failed": 0, "skipped": 0}]}])
    out = run_page(tmp_path, fixtures)
    for section in ["head", "tl", "sum-tests", "evidence-tests"]:
        assert out["sections"][section] == before["sections"][section], section
    assert "Stage run" in out["sections"]["body-tests"] and "SHA 0123456789ab" in out["sections"]["body-tests"]
    assert "passing subset does not verify the whole repository" in out["sections"]["body-tests"]
    assert "not run" in out["sections"]["body-tests"]
    assert "uncommitted changes" in out["sections"]["body-tests"]


@needs_node
def test_hallie_replay_revision_is_distinct_from_nightly_test_revision(tmp_path):
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    rows = [json.loads(line) for line in fixtures["testdriver.jsonl"].splitlines()]
    for row in rows:
        if row.get("source") == "nightly-local":
            row.update({"sha": "aaaaaaa123456", "hallie_replay_git_sha": "bbbbbbb123456"})
    fixtures["testdriver.jsonl"] = jsonl(rows)
    out = run_page(tmp_path, fixtures)
    assert "SHA aaaaaaa12345" in out["sections"]["evidence-tests"]
    assert "bbbbbbb" not in out["sections"]["evidence-tests"]
    assert "SHA bbbbbbb12345" in out["sections"]["evidence-hallie"]
    assert "aaaaaaa" not in out["sections"]["evidence-hallie"]


def _gedcom_rows(now, m4_pulls, ultra_pulls):
    base = {"source": "nightly-local", "branch": "main", "status": "ok", "passed": 10, "failed": 0, "skipped": 0,
            "total": 10, "hallie_strict_status": "ok", "hallie_strict_pass": 5, "hallie_strict_completed": 5,
            "hallie_strict_expected": 5, "hallie_replay_status": "ok"}
    rows = []
    for host, pulls in (("RicksM4", m4_pulls), ("RicksUltra", ultra_pulls)):
        row = dict(base, ts=iso(now - timedelta(hours=2)), host=host)
        if pulls is not None:
            row["hallie_replay_gedcom_pulls"] = pulls
        rows.append(row)
    return rows


SAME = {"status": "ok", "pulls": [{"date": "2026-08-26", "sha": "aaaa1111", "on_disk": True},
                                  {"date": None, "sha": "cccc3333", "on_disk": False},
                                  {"date": "2026-08-28", "sha": "bbbb2222", "on_disk": True}]}


@needs_node
@pytest.mark.parametrize("m4, ultra, state, words", [
    (SAME, SAME, "green", ["M5 Ultra: 26 Aug 2026 · aaaa1111, 28 Aug 2026 · bbbb2222", "M4: 26 Aug 2026 · aaaa1111"]),
    (SAME, {"status": "ok", "pulls": [{"date": "2026-09-30", "sha": "dddd4444", "on_disk": True}]}, "watch",
     ["M5 Ultra: 30 Sep 2026 · dddd4444"]),
    (SAME, {"status": "no-tree", "pulls": []}, "red", ["M5 Ultra: no readable tree"]),
    (SAME, {"status": "ok", "pulls": [{"date": None, "sha": "cccc3333", "on_disk": False}]}, "red",
     ["M5 Ultra: no readable tree"]),
    (SAME, None, "grey", ["M5 Ultra: not recorded"]),
])
def test_gedcom_line_compares_the_pulls_each_mac_replayed(tmp_path, m4, ultra, state, words):
    """GEDCOM pull dates (2026-10-30): one line in the Hallie twist, per Mac the export
    day + short hash of each pull its replay tree used. Same pulls → green, different →
    watch (yellow), a Mac with no readable tree → red; a row from before the field → grey."""
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    fixtures["testdriver.jsonl"] += jsonl(_gedcom_rows(now, m4, ultra))
    out = run_page(tmp_path, fixtures)
    body = out["sections"]["body-hallie"]
    assert f'data-state="{state}"' in body, body
    for w in words:
        assert w in body, (w, body)


@needs_node
def test_gedcom_line_never_shows_a_name_or_markup_from_the_row(tmp_path):
    now = datetime.now(timezone.utc)
    fixtures = full_fixtures(now)
    poisoned = {"status": "ok", "pulls": [{"date": "<b>SECRET</b>", "sha": "<script>x</script>", "on_disk": True,
                                           "label": "Secretsurname", "file": "SECRET-FILE.ged"}]}
    fixtures["testdriver.jsonl"] += jsonl(_gedcom_rows(now, poisoned, poisoned))
    body = run_page(tmp_path, fixtures)["sections"]["body-hallie"]
    assert "Secretsurname" not in body and "SECRET" not in body and "<script>" not in body
    assert "no date in file" in body


def test_metrics_controls_work_under_nonce_csp_without_inline_event_attributes():
    page = PAGE.read_text()
    assert not re.search(r"\bon(?:click|change|submit|keydown)\s*=", page)
