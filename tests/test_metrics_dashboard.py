"""docs/index.html, the one metrics page: execute its script under node with a fake
DOM and fixture data. Every section must render without an error, a stream with no
rows must say "no data yet" (never a zero), old data must be flagged STALE, and the
page must never read the free-text fields that ride on some rows."""
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
let script = html.match(/<script>\n([\s\S]*?)<\/script>/)[1];
script = script.replace(/\nloadData\(\);\s*$/, "\nglobalThis.__done = loadData();");
const elements = new Map();
function element(id = "") {
  const classes = new Set();
  const value = { id, children: [], innerHTML: "", textContent: "", style: {}, className: "",
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x) },
    appendChild(child) { this.children.push(child); return child; } };
  return value;
}
// Elements declared hidden in the HTML start hidden here too.
for (const m of html.matchAll(/<(?:div|p)[^>]*class="([^"]*)"[^>]*id="([^"]+)"|<(?:div|p)[^>]*id="([^"]+)"[^>]*class="([^"]*)"/g)) {
  const id = m[2] || m[3], cls = m[1] || m[4];
  const el = element(id);
  if (/\bhidden\b/.test(cls)) el.classList.add("hidden");
  elements.set(id, el);
}
globalThis.document = {
  getElementById(id) { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
  createElement() { return element(); },
};
const charts = [];
globalThis.Chart = function(target, config) { charts.push({ id: target.id, config }); };
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
  const out = { charts: charts.map(c => c.id), errors, sections: {} , notes: {} };
  for (const [id, el] of elements) {
    if (id.endsWith("-error") && !el.classList.contains("hidden")) out.errors.push(`${id}: ${el.textContent}`);
    if (id.endsWith("-note") && !el.classList.contains("hidden")) out.notes[id] = el.textContent;
    out.sections[id] = text(el);
  }
  process.stdout.write(JSON.stringify(out));
})().catch(e => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def jsonl(rows):
    return "".join(json.dumps(r) + "\n" for r in rows)


def run_page(tmp_path, fixtures):
    fx = tmp_path / "fixtures.json"
    fx.write_text(json.dumps(fixtures))
    r = subprocess.run(["node", "-e", HARNESS, str(PAGE), str(fx)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def full_fixtures(now):
    fresh, old = now - timedelta(hours=3), now - timedelta(days=5)
    nightly = [
        {"ts": iso(old), "source": "nightly-local", "host": "RicksM4", "branch": "main", "status": "ok",
         "passed": 9000, "failed": 2, "skipped": 60, "total": 9062, "elapsed_s": 1200, "coverage_logic_pct": 65.0,
         "hallie_strict_status": "failed", "hallie_strict_pass": 8, "hallie_strict_expected": 10,
         "hallie_strict_completed": 10, "hallie_advisory_pass": 3, "hallie_advisory_expected": 4,
         "hallie_advisory_completed": 4, "hallie_replay_status": "failed",
         "failed_names": ["SECRET-TEST-NAME"], "hallie_replay_reason": "SECRET-REASON /Users/rickb"},
        # A replay that completed nothing (2026-10-02 on the M4): a gap, not 0 %.
        {"ts": iso(fresh - timedelta(hours=1)), "source": "nightly-local", "host": "RicksM4", "branch": "main",
         "status": "ok", "passed": 9001, "failed": 0, "skipped": 60, "total": 9061, "elapsed_s": 1100,
         "hallie_strict_status": "incomplete", "hallie_strict_pass": 0, "hallie_strict_expected": 64,
         "hallie_strict_completed": 0, "hallie_advisory_pass": 0, "hallie_advisory_expected": 775,
         "hallie_advisory_completed": 0, "hallie_replay_status": "incomplete"},
        {"ts": iso(fresh), "source": "nightly-local", "host": "RicksM5", "branch": "main", "status": "skipped",
         "passed": 0, "failed": 0, "skipped": 0, "total": 0, "reason": "SECRET-REASON"},
        {"ts": iso(fresh), "source": "poi-cycle-metrics", "passed": 999999},
    ]
    return {
        "/branches/metrics": None,
        "history.jsonl": jsonl([{"ts": iso(old), "total_swift_lines": 500000, "files_over_1000": 60},
                                {"ts": iso(fresh), "total_swift_lines": 546428, "files_over_1000": 61, "test_count": 9550,
                                 "swift_by_folder": {"Hallie": {"lines": 68739, "files": 181}, "Core": {"lines": 42550, "files": 144}}}]),
        "static_analysis.jsonl": jsonl([{"ts": iso(old), "codeql_findings": 17, "concurrency_warnings": 189, "tsan_issues": None,
                                         "codeql_extracted_files": 900, "codeql_in_scope_files": 939}]),
        "testdriver.jsonl": jsonl(nightly),
        "nightly_findings_latest.json": {"date": "2026-10-02", "dry_run": True, "fingerprints": 3,
                                         "by_severity": {"high": 1, "medium": 0, "low": 2},
                                         "tools": {"codeql": {"input": True, "complete": True, "findings": 3, "fingerprints": 3},
                                                   "tsan": {"input": False, "complete": False, "findings": 0, "fingerprints": 0}},
                                         "new": [{"tool": "codeql", "severity": "high", "title": "SECRET-TITLE Donna",
                                                  "file": "VideoScan/VideoScan/People/Secret.swift"}]},
        "coverage.jsonl": jsonl([{"schemaVersion": 1, "date": fresh.strftime("%Y-%m-%d"), "app_status": "ok", "core_status": "ok",
                                  "total": {"lines": 100, "covered": 50, "pct": 50.0, "logic_lines": 80, "logic_covered": 60,
                                            "logic_pct": 75.0, "files": 4},
                                  "folders": [{"folder": "Hallie", "lines": 100, "covered": 50, "pct": 50.0, "logic_lines": 80,
                                               "logic_covered": 60, "logic_pct": 75.0, "files": 4}]}]),
        "adversarial.jsonl": None,
        "codex_reviews.jsonl": jsonl([{"schemaVersion": 1, "date": "2026-09-27", "docs": 1, "unparsed_docs": 0,
                                       "passes": 2, "findings": 5, "closed_passes": 2}]),
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
            "totals": {"swift": {**folder, "mean_ccn": 3.85, "offenders": offenders, "ccn_over_15": 435,
                                 "nloc_over_80": 241},
                       "python": {**folder, "mean_ccn": 6.54},
                       "all": {**folder, "offenders": offenders + 99}},
            "top15": [{"file": "tools/nightly_findings_to_issues.py", "function": "plan_ticket", "ccn": 111,
                       "nloc": 162, "lang": "python"},
                      {"file": "VideoScan/VideoScan/Hallie/HallieLineageQuestion.swift",
                       "function": "HallieLineageQuestion.detectShape", "ccn": 88, "nloc": 250, "lang": "swift"}],
            "debt_offenders": offenders, "debt_new": new, "debt_worse": 0, "debt_fixed": 1,
            "duplicate_rate_pct": 1.96, "duplicate_blocks": 178, "gate_overrides_recent": 1}


@pytest.mark.skipif(shutil.which("node") is None, reason="needs node")
def test_every_section_renders_with_honest_missing_and_stale_states(tmp_path):
    out = run_page(tmp_path, full_fixtures(datetime.now(timezone.utc)))
    assert out["errors"] == []
    strip = out["sections"]["status-strip"]
    # CI: latest COMPLETED run on main, not the feature branch, with the newer run noted.
    assert "CI on main" in strip and "success" in strip and "newer run in progress" in strip
    # Nightly: the newest row ran nothing; it is not shown as green.
    assert "skipped" in strip and "no tests ran" in strip
    # Analysis API down: falls back to the published row, and that row is 5 days old.
    assert "Actions API unavailable" in strip and "STALE" in strip
    # Adversarial stream absent: says so, in the strip and in its section.
    assert "Adversarial review" in strip and "no data yet" in strip
    assert "No adversarial review data published yet" in out["sections"]["adv-cards"]
    assert out["notes"]["c-adv-note"] == "no data yet"
    # Sections that have data drew charts.
    for chart in ["c-tests", "c-cov-folders", "c-cov-trend", "c-sa-compiler", "c-sa-codeql",
                  "c-codex", "c-hallie", "c-size-folders", "c-size-trend", "c-cx-debt", "c-cx-folders",
                  "c-ex-trend", "c-ex-folders"]:
        assert chart in out["charts"], chart
    # Over-exposure: cards with the night-over-night delta, top files, problem files.
    ex = out["sections"]["ex-cards"]
    assert "Could be private" in ex and "2520" in ex and "-80 from previous" in ex
    assert "DateTriangulator.swift" in out["sections"]["ex-top"]
    assert "DeleteDuplicatesJob.swift" in out["sections"]["pf-table"] and "120.9" in out["sections"]["pf-table"]
    assert "412 files with any debt" in out["sections"]["pf-title"]
    # Complexity: cards, the top-15 table and the latest new-offender list.
    cx = out["sections"]["cx-cards"]
    # App code only (Rick 2026-10-06): the cards read the Swift totals, never Python.
    assert "Offenders" in cx and "514" in cx and "-6 from previous" in cx and "3.85" in cx
    assert "6.54" not in cx and "613" not in cx
    assert "1.96%" in cx and "Gate overrides (48 h)" in cx
    assert "detectShape" in out["sections"]["cx-top"] and "plan_ticket" not in out["sections"]["cx-top"]
    ovr = out["sections"]["cx-ovr"]
    assert "Big.run" in ovr and "35" in ovr and "abc1234" in ovr and "Rick Breen" in ovr
    assert "NewView.body" in out["sections"]["cx-new"] and "1 new, 0 worse, 1 fixed" in out["sections"]["cx-new-title"]
    # TSan has only a null value: "no data", never a zero line.
    assert "c-sa-san" not in out["charts"]
    assert out["notes"]["c-sa-san-note"] == "no data yet"
    assert "TSan hits" in out["sections"]["static-cards"]
    # Hallie: the rate is over completed cases; the replay that completed none is skipped.
    hallie = out["sections"]["hallie-cards"]
    assert "80.0%" in hallie and "8 of 10" in hallie and "75.0%" in hallie
    assert not re.search(r"(?<![\d.])0\.0%", hallie) and "incomplete" in hallie
    # The POI replay row never becomes a test count.
    assert "999999" not in json.dumps(out)
    # Free text riding on rows is never rendered.
    blob = json.dumps(out)
    for secret in ["SECRET-TITLE", "SECRET-REASON", "SECRET-TEST-NAME", "Secret.swift", "/Users/rickb"]:
        assert secret not in blob, secret


@pytest.mark.skipif(shutil.which("node") is None, reason="needs node")
def test_everything_missing_renders_no_data_not_zero(tmp_path):
    out = run_page(tmp_path, {})
    assert out["errors"] == []
    assert out["charts"] == []
    strip = out["sections"]["status-strip"]
    assert strip.count("no data yet") >= 5
    assert "Could not load the metrics branch" in out["sections"]["status"]
    for box in ["tests-cards", "coverage-cards", "static-cards", "adv-cards", "codex-cards", "hallie-cards", "size-cards", "cx-cards", "ex-cards"]:
        text = out["sections"][box]
        assert re.search(r"no data yet|No .* (rows|published yet)", text), box
        assert ">0<" not in text, box


def test_page_never_reads_free_text_fields():
    page = PAGE.read_text()
    for field in ["failed_names", "crashed_names", "hallie_replay_reason", "hallie_voice_reason",
                  "item.title", "zero_files", "person_eval_", ".reason"]:
        assert field not in page, field


def test_page_data_comes_from_public_sources_only():
    page = PAGE.read_text()
    assert "https://cdnjs.cloudflare.com/ajax/libs/Chart.js/" in page
    assert "raw.githubusercontent.com/${REPO}" in page
    hosts = set(re.findall(r"https://([a-z0-9.-]+)/", page))
    assert hosts <= {"cdnjs.cloudflare.com", "api.github.com", "raw.githubusercontent.com", "github.com"}, hosts
