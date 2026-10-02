#!/usr/bin/env python3
"""Tests for tools/nightly_findings_to_issues.py and the morning alert.

No network. Every GitHub interaction goes through FakeGh, an in-memory issue
tracker that implements the same seam as GhCli. One test drives GhCli itself
through a fake subprocess runner to pin the exact `gh` argv.

Five-dimension checklist (CLAUDE.md):
  Logic     parsers per tool, severity mapping, fingerprints, the issue
            lifecycle (open / comment-on-change / 3-night close / reopen).
  Scale     5,000 findings plan in a time budget; the digest body stays under
            GitHub's 65,536-character limit with 3,000 overflow findings.
  Media     n/a. The tool reads analysis logs, not media.
  Isolation an INCOMPLETE tool (failed job, missing artifact) never advances
            the "gone" counter. A same-day rerun never double-counts. These
            are the poisoned-state cases that would mass-close real issues.
  Sensor    the end-to-end run over the fixture tree pins the per-tool
            counts, so a parser that silently stops matching shows up as a
            count change.
"""
from __future__ import annotations

import datetime as dt
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "nightly_findings"
sys.path.insert(0, str(REPO / "tools"))
sys.path.insert(0, str(REPO / "scripts"))

import nightly_findings_to_issues as nf  # noqa: E402
import nightly_findings_alert as alert  # noqa: E402


# --------------------------------------------------------------------------
# Fake GitHub
# --------------------------------------------------------------------------


class FakeGh:
    def __init__(self, issues: list[nf.Issue] | None = None, labels: set[str] | None = None,
                 fail_on: str | None = None):
        self.issues = {i.number: i for i in (issues or [])}
        self.labels = set(labels or {"wontfix", "High Priority"})
        self.calls: list[tuple] = []
        self.fail_on = fail_on
        self._next = max(self.issues, default=0) + 1

    def _maybe_fail(self, kind):
        if self.fail_on == kind:
            raise RuntimeError(f"simulated gh failure on {kind}")

    def list_issues(self, label):
        self.calls.append(("list_issues", label))
        return [nf.Issue(i.number, i.title, i.state, i.state_reason, list(i.labels), i.body)
                for i in self.issues.values() if label in i.labels]

    def list_labels(self):
        return set(self.labels)

    def create_label(self, name, color, desc):
        self.calls.append(("create_label", name))
        self.labels.add(name)

    def create_issue(self, title, body, labels):
        self._maybe_fail("create")
        n = self._next
        self._next += 1
        self.issues[n] = nf.Issue(n, title, "OPEN", None, list(labels), body)
        self.calls.append(("create", n, title, tuple(labels)))
        return n

    def comment(self, number, body):
        self.calls.append(("comment", number, body))

    def edit_body(self, number, body):
        self.issues[number].body = body
        self.calls.append(("edit", number))

    def add_labels(self, number, labels):
        self.issues[number].labels += list(labels)
        self.calls.append(("add_labels", number, tuple(labels)))

    def close(self, number, comment):
        i = self.issues[number]
        i.state, i.state_reason = "CLOSED", "COMPLETED"
        self.calls.append(("close", number, comment))

    def reopen(self, number, comment):
        i = self.issues[number]
        i.state, i.state_reason = "OPEN", "REOPENED"
        self.calls.append(("reopen", number, comment))

    def kinds(self, kind):
        return [c for c in self.calls if c[0] == kind]

    def finding_issues(self):
        return [i for i in self.issues.values() if nf.DIGEST_LABEL not in i.labels]

    def digest(self):
        return [i for i in self.issues.values() if nf.DIGEST_LABEL in i.labels]


def F(tool="codeql", rule="r", file="a.swift", line=1, msg="m", sev="medium"):
    return nf.Finding(tool, rule, file, line, msg, sev)


def night(gh, findings, today, complete=None, cap=10):
    groups = nf.group_findings(findings)
    comp = complete if complete is not None else {t: True for t in nf.TOOLS}
    p = nf.plan(groups, gh.list_issues(nf.BASE_LABEL), comp, today, "https://run", cap)
    nf.ensure_labels(gh, {lb for a in p.actions for lb in a.labels})
    gh.calls.clear()
    numbers, errors = nf.apply(p, gh)
    assert errors == []
    return p


# --------------------------------------------------------------------------
# Fingerprints
# --------------------------------------------------------------------------


class TestFingerprint:
    def test_line_numbers_do_not_change_identity(self):
        a = nf.fingerprint("strict-concurrency", "concurrency", "X.swift",
                           "sending 'self' risks causing data races")
        b = nf.fingerprint("strict-concurrency", "concurrency", "X.swift",
                           "sending 'self' risks causing data races")
        assert a == b

    def test_timings_addresses_and_link_indexes_are_normalised(self):
        assert nf.normalise_key("took 113ms") == nf.normalise_key("took 475ms")
        assert nf.normalise_detail("at 0x7b0c0001 (pid=12)") == "at 0x#"
        assert nf.normalise_detail("from [spouse](1).") == nf.normalise_detail("from [spouse](2).")
        assert nf.normalise_detail("see File.swift:120:4 now") == "see File.swift now"
        assert nf.normalise_detail("msg [#ExistentialAny]") == "msg"

    def test_file_rule_and_tool_are_part_of_identity(self):
        base = nf.fingerprint("codeql", "r", "a.swift", "m")
        assert base != nf.fingerprint("codeql", "r", "b.swift", "m")
        assert base != nf.fingerprint("codeql", "r2", "a.swift", "m")
        assert base != nf.fingerprint("periphery", "r", "a.swift", "m")

    def test_runner_paths_become_repo_relative(self):
        p = "/Users/runner/work/VideoScan/VideoScan/VideoScan/VideoScan/App/A.swift"
        assert nf.relativise(p) == "VideoScan/VideoScan/App/A.swift"
        assert nf.relativise("/ws/x/A.swift", "/ws/x") == "A.swift"


# --------------------------------------------------------------------------
# Parsers + severity mapping
# --------------------------------------------------------------------------


class TestParsersAndSeverity:
    def test_codeql_security_is_high_warning_medium_note_low(self):
        groups = nf.group_findings(nf.parse_sarif(FIX / "codeql.sarif"))
        by_rule = {g.rule: g for g in groups.values()}
        assert by_rule["swift/cleartext-logging"].severity == "high"
        assert by_rule["swift/cleartext-logging"].count == 2     # two lines, one fingerprint
        assert by_rule["swift/unused-variable"].severity == "medium"
        assert by_rule["swift/redundant-note"].severity == "low"
        assert len(groups) == 3

    def test_compiler_warning_buckets(self):
        fs = nf.parse_compiler_warnings(FIX / "all-warnings.txt", None)
        groups = nf.group_findings(fs)
        sev = {(g.file.rsplit("/", 1)[-1], g.rule): g.severity for g in groups.values()}
        assert sev[("ArchiveAngelJob.swift", "concurrency")] == "high"          # "data race"
        assert sev[("ContentView.swift", "concurrency")] == "low"              # isolation, no race
        assert sev[("BundleModels.swift", "upcoming-feature-or-other")] == "low"
        assert sev[("Globals.swift", "concurrency")] == "low"
        # Type-check timing lines are owned by typecheck_timing_ratchet.py.
        assert not any("type-check" in f.message for f in fs)
        # A memory-safety line belongs to the memory-safety tool, never here.
        assert not any(g.rule == "memory-safety" for g in groups.values())
        assert len(fs) == 5 and len(groups) == 4

    def test_memory_safety_is_its_own_low_severity_tool(self):
        fs = nf.parse_compiler_warnings(FIX / "memory-safety-findings.txt", None, "memory-safety")
        groups = nf.group_findings(fs)
        assert {g.tool for g in groups.values()} == {"memory-safety"}
        assert {g.severity for g in groups.values()} == {"low"}
        # Two FrameDecoder lines -> one fingerprint; the macro-expansion
        # buffer (no real path) is skipped.
        assert len(fs) == 3 and len(groups) == 2
        # The same file through the strict-concurrency parser yields nothing.
        assert nf.parse_compiler_warnings(FIX / "memory-safety-findings.txt", None) == []

    def test_tsan_and_asan_are_high_ubsan_medium(self):
        tsan = nf.group_findings(nf.parse_sanitizer_log(FIX / "tsan.log", "tsan", None))
        asan = nf.group_findings(nf.parse_sanitizer_log(FIX / "asan.log", "asan", None))
        ubsan = nf.group_findings(nf.parse_sanitizer_log(FIX / "ubsan.log", "ubsan", None))
        assert {g.severity for g in tsan.values()} == {"high"}
        assert {g.severity for g in asan.values()} == {"high"}
        assert {g.severity for g in ubsan.values()} == {"medium"}
        assert len(tsan) == 2            # two setter lines share one fingerprint + one dylib frame
        files = sorted(g.file for g in tsan.values())
        assert files == ["<libswiftCore.dylib>", "VideoScan/VideoScan/Model/VideoScanModel.swift"]
        (a,) = asan.values()
        assert a.rule == "heap-use-after-free" and a.file.endswith("Media/FrameDecoder.swift")
        assert len(ubsan) == 2           # overflow (x2 values) + misaligned load; SUMMARY not double-counted

    def test_periphery_is_low(self):
        groups = nf.group_findings(nf.parse_periphery(FIX / "periphery-strict.txt", None))
        assert len(groups) == 3
        assert {g.severity for g in groups.values()} == {"low"}
        assert any(g.rule == "Unused function '…'" for g in groups.values())

    def test_high_findings_get_high_priority_label(self):
        g = nf.group_findings([F(sev="high")])
        (only,) = g.values()
        assert nf.labels_for(only) == ["nightly-finding", "codeql", "High Priority"]
        (low,) = nf.group_findings([F(tool="periphery", sev="low")]).values()
        assert nf.labels_for(low) == ["nightly-finding", "periphery"]


# --------------------------------------------------------------------------
# Lifecycle
# --------------------------------------------------------------------------


class TestLifecycle:
    def test_new_finding_opens_one_issue_and_rerun_is_silent(self):
        gh = FakeGh()
        fs = [F(line=10), F(line=20)]                   # same fingerprint, two lines
        night(gh, fs, "2026-10-02")
        assert len(gh.finding_issues()) == 1
        night(gh, [F(line=11), F(line=21)], "2026-10-03")   # code moved, nothing else changed
        assert gh.calls == []                           # no comment, no edit, no new issue

    def test_changed_finding_gets_exactly_one_comment(self):
        gh = FakeGh()
        night(gh, [F(line=1)], "2026-10-02")
        night(gh, [F(line=1), F(line=2)], "2026-10-03")     # count 1 -> 2
        comments = gh.kinds("comment")
        assert len(comments) == 1 and "Occurrences: 1 → 2" in comments[0][2]
        night(gh, [F(line=1), F(line=2)], "2026-10-04")     # unchanged again
        assert gh.kinds("comment") == []

    def test_severity_escalation_adds_high_priority(self):
        gh = FakeGh()
        night(gh, [F(sev="medium")], "2026-10-02")
        night(gh, [F(sev="high")], "2026-10-03")
        assert gh.kinds("add_labels")
        (iss,) = gh.finding_issues()
        assert "High Priority" in iss.labels

    def test_gone_three_complete_nights_closes(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        night(gh, [], "2026-10-03")
        night(gh, [], "2026-10-04")
        assert gh.kinds("close") == []
        (iss,) = gh.finding_issues()
        assert iss.is_open and iss.marker["missing_dates"] == ["2026-10-03", "2026-10-04"]
        night(gh, [], "2026-10-05")
        assert len(gh.kinds("close")) == 1
        assert not gh.finding_issues()[0].is_open

    def test_seen_again_resets_the_gone_counter(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        night(gh, [], "2026-10-03")
        night(gh, [], "2026-10-04")
        night(gh, [F()], "2026-10-05")
        assert gh.finding_issues()[0].marker["missing_dates"] == []
        night(gh, [], "2026-10-06")
        night(gh, [], "2026-10-07")
        assert gh.finding_issues()[0].is_open

    def test_incomplete_tool_never_advances_the_counter(self):
        """Poisoned state: the CodeQL build broke, so CodeQL reported nothing.
        That is not three nights of fixes."""
        gh = FakeGh()
        night(gh, [F(tool="codeql")], "2026-10-02")
        incomplete = {t: True for t in nf.TOOLS} | {"codeql": False}
        for d in ("2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06"):
            p = night(gh, [], d, complete=incomplete)
            assert p.held_incomplete
        iss = gh.finding_issues()[0]
        assert iss.is_open and not iss.marker["missing_dates"]

    def test_same_day_rerun_does_not_double_count(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        for _ in range(4):
            night(gh, [], "2026-10-03")
        iss = gh.finding_issues()[0]
        assert iss.is_open and iss.marker["missing_dates"] == ["2026-10-03"]

    def test_auto_closed_finding_that_returns_is_reopened(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        p = night(gh, [F()], "2026-10-06")
        assert len(gh.kinds("reopen")) == 1 and gh.kinds("create") == []
        assert gh.finding_issues()[0].is_open
        assert [g.fp for g in p.newly_seen] == p.opened


class TestWontfix:
    def _closed_wontfix(self, finding, labels, reason="COMPLETED"):
        (g,) = nf.group_findings([finding]).values()
        st = {"v": 1, "fp": g.fp, "tool": g.tool, "digest": "old", "count": 9,
              "severity": g.severity, "missing_dates": []}
        return nf.Issue(7, "t", "CLOSED", reason, labels, nf.render_marker(st) + "\nbody")

    def test_wontfix_label_is_never_reopened_or_duplicated(self):
        f = F(sev="high")
        gh = FakeGh([self._closed_wontfix(f, ["nightly-finding", "codeql", "wontfix"])])
        p = night(gh, [f], "2026-10-02")
        assert gh.calls == [] and p.skipped_wontfix and not p.newly_seen

    def test_closed_as_not_planned_is_treated_as_wontfix(self):
        f = F()
        gh = FakeGh([self._closed_wontfix(f, ["nightly-finding", "codeql"], reason="NOT_PLANNED")])
        night(gh, [f], "2026-10-02")
        assert gh.calls == []

    def test_open_issue_with_wontfix_gets_no_comment_and_is_not_closed(self):
        f = F()
        iss = self._closed_wontfix(f, ["nightly-finding", "codeql", "wontfix"])
        iss.state, iss.state_reason = "OPEN", None
        gh = FakeGh([iss])
        night(gh, [f, F(line=99)], "2026-10-02")        # changed count
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        assert gh.issues[7].is_open
        assert not any(c[0] in ("comment", "close", "edit") and c[1] == 7 for c in gh.calls)


class TestCapAndDigest:
    def _many(self, n_high, n_medium):
        return ([F(file=f"h{i}.swift", sev="high") for i in range(n_high)]
                + [F(tool="ubsan", file=f"m{i}.c", sev="medium") for i in range(n_medium)])

    def test_cap_ten_high_first_rest_in_one_digest(self):
        gh = FakeGh()
        p = night(gh, self._many(3, 12), "2026-10-02")
        created = gh.finding_issues()
        assert len(created) == 10
        assert sum("High Priority" in i.labels for i in created) == 3     # all highs got issues
        (dg,) = gh.digest()
        assert dg.is_open and "5 nightly findings waiting" in dg.body
        assert len(p.overflow) == 5 and len(p.newly_seen) == 15

    def test_overflow_drains_on_later_nights_and_is_not_new_again(self):
        gh = FakeGh()
        fs = self._many(0, 15)
        night(gh, fs, "2026-10-02")
        p2 = night(gh, fs, "2026-10-03")
        assert len(gh.finding_issues()) == 15
        assert p2.newly_seen == []                     # they waited in the digest; not "new"
        assert len(gh.kinds("close")) == 1             # digest closed: nothing waiting
        assert not gh.digest()[0].is_open

    def test_reopen_counts_against_the_cap(self):
        gh = FakeGh()
        night(gh, [F(file="old.swift")], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        p = night(gh, [F(file="old.swift")] + self._many(0, 10), "2026-10-06", cap=10)
        assert len(p.opened) == 10 and len(p.overflow) == 1

    def test_digest_body_fits_github_limit_at_scale(self):
        gh = FakeGh()
        fs = [F(tool="ubsan", file=f"VideoScan/VideoScan/Deep/Path/File{i}.c",
                msg="load of misaligned address for type 'p" + "x" * 80 + f"{i}'", sev="medium")
              for i in range(3000)]
        night(gh, fs, "2026-10-02")
        (dg,) = gh.digest()
        assert len(dg.body) < nf.GITHUB_BODY_LIMIT
        assert len(nf._digest_fps(dg)) == 2990      # every overflow fp is remembered


def LOW(i, tool="periphery", rule="Unused function '…'"):
    return F(tool=tool, rule=rule, file=f"VideoScan/VideoScan/F{i}.swift", line=i,
             msg=f"Unused function 'f{i}()'", sev="low")


class TestLowDigests:
    """Manager ruling 2026-10-01: low findings never get individual issues,
    only ONE rolling digest per tool, edited in place each night."""

    def low_digest(self, gh, tool):
        found = [i for i in gh.digest() if f"nightly-low-digest" in i.body and f'"tool": "{tool}"' in i.body]
        assert len(found) == 1, found
        return found[0]

    def test_lows_get_no_individual_issue_one_digest_per_tool(self):
        gh = FakeGh()
        fs = [LOW(i) for i in range(30)] + [LOW(i, tool="memory-safety", rule="memory-safety")
                                           for i in range(5)]
        p = night(gh, fs, "2026-10-02")
        assert gh.finding_issues() == [] and p.opened == []
        per = self.low_digest(gh, "periphery")
        assert "30 low-severity findings" in per.body and "First digest" in per.body
        assert per.body.count("| low |") == 20                     # top 20 new items
        assert {"nightly-finding", "nightly-digest", "periphery"} <= set(per.labels)
        assert self.low_digest(gh, "memory-safety").is_open
        assert p.low_digests["periphery"]["new"] == 30

    def test_digest_is_edited_in_place_with_deltas(self):
        gh = FakeGh()
        night(gh, [LOW(i) for i in range(10)], "2026-10-02")
        num = self.low_digest(gh, "periphery").number
        p = night(gh, [LOW(i) for i in range(1, 12)], "2026-10-03")   # -1 gone (0), +2 new (10, 11)
        d = self.low_digest(gh, "periphery")
        assert d.number == num and len(gh.digest()) == 1           # same issue, no new one
        assert "**+2 new, −1 gone**" in d.body and "Since 2026-10-02 (10 findings)" in d.body
        assert "F10.swift" in d.body and "F11.swift" in d.body
        assert p.low_digests["periphery"] == {**p.low_digests["periphery"], "new": 2, "gone": 1,
                                              "count": 11, "action": "edit"}

    def test_incomplete_tool_leaves_digest_alone(self):
        gh = FakeGh()
        night(gh, [LOW(i) for i in range(10)], "2026-10-02")
        before = self.low_digest(gh, "periphery").body
        incomplete = {t: True for t in nf.TOOLS} | {"periphery": False}
        p = night(gh, [LOW(1)], "2026-10-03", complete=incomplete)
        assert p.low_held == ["periphery"]
        assert self.low_digest(gh, "periphery").body == before
        assert gh.calls == []

    def test_digest_closes_when_tool_reports_no_lows(self):
        gh = FakeGh()
        night(gh, [LOW(1)], "2026-10-02")
        night(gh, [], "2026-10-03")
        assert not self.low_digest(gh, "periphery").is_open
        night(gh, [LOW(2)], "2026-10-04")                          # comes back -> reopened
        d = self.low_digest(gh, "periphery")
        assert d.is_open and len(gh.digest()) == 1

    def test_wontfix_digest_is_silenced(self):
        gh = FakeGh()
        night(gh, [LOW(1)], "2026-10-02")
        self.low_digest(gh, "periphery").labels.append("wontfix")
        night(gh, [LOW(1), LOW(2)], "2026-10-03")
        assert gh.calls == []

    def test_low_digest_fits_github_limit_at_scale(self):
        gh = FakeGh()
        fs = [LOW(i, rule=f"Unused function '{'x' * 90}{i % 40}'") for i in range(3000)]
        night(gh, fs, "2026-10-02")
        d = self.low_digest(gh, "periphery")
        assert len(d.body) < nf.GITHUB_BODY_LIMIT

    def test_lows_do_not_use_the_cap(self):
        gh = FakeGh()
        fs = [LOW(i) for i in range(50)] + [F(file=f"m{i}.swift", sev="medium") for i in range(4)]
        p = night(gh, fs, "2026-10-02")
        assert len(p.opened) == 4 and p.overflow == []


class TestScale:
    def test_five_thousand_findings_plan_within_budget(self):
        fs = [F(tool="ubsan", file=f"f{i % 900}.c", line=i, msg=f"runtime error kind {i}",
                sev="medium") for i in range(5000)]
        t0 = time.monotonic()
        groups = nf.group_findings(fs)
        p = nf.plan(groups, [], {t: True for t in nf.TOOLS}, "2026-10-02", "", 10)
        assert time.monotonic() - t0 < 5.0
        assert len(p.opened) == 10 and len(p.overflow) == len(groups) - 10


# --------------------------------------------------------------------------
# End to end over the fixture artifact tree
# --------------------------------------------------------------------------


def make_artifacts(tmp: Path, *, codeql_status: bool | None = None) -> Path:
    art = tmp / "artifacts"
    (art / "codeql-results").mkdir(parents=True)
    shutil.copy(FIX / "codeql.sarif", art / "codeql-results" / "swift.sarif")
    (art / "strict-concurrency-log").mkdir()
    shutil.copy(FIX / "all-warnings.txt", art / "strict-concurrency-log" / "all-warnings.txt")
    shutil.copy(FIX / "memory-safety-findings.txt",
                art / "strict-concurrency-log" / "memory-safety-findings.txt")
    (art / "tsan-log").mkdir()
    shutil.copy(FIX / "tsan.log", art / "tsan-log" / "tsan.log")
    (art / "sanitizer-address").mkdir()
    shutil.copy(FIX / "asan.log", art / "sanitizer-address" / "sanitizer-address.log")
    (art / "sanitizer-undefined").mkdir()
    shutil.copy(FIX / "ubsan.log", art / "sanitizer-undefined" / "sanitizer-undefined.log")
    (art / "lint-strict").mkdir()
    shutil.copy(FIX / "periphery-strict.txt", art / "lint-strict" / "periphery-strict.txt")
    # An .xcresult bundle's internal logs must not be read as sanitizer output.
    junk = art / "sanitizer-address" / "R.xcresult" / "Data"
    junk.mkdir(parents=True)
    (junk / "noise.log").write_text("SUMMARY: AddressSanitizer: SEGV /x.c:1 in nope\n")
    if codeql_status is not None:
        (art / "codeql-results" / "nightly-status-codeql.json").write_text(
            json.dumps({"complete": codeql_status}))
    return art


class TestEndToEnd:
    def test_summary_counts_per_tool(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh()
        out = tmp_path / "s.json"
        rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--today", "2026-10-02",
                     "--summary-out", str(out), "--job-result", "codeql=success"],
                    gh_factory=lambda repo: gh)
        assert rc == 0
        s = json.loads(out.read_text())
        fps = {t: v["fingerprints"] for t, v in s["tools"].items()}
        assert fps == {"codeql": 3, "strict-concurrency": 4, "memory-safety": 2, "tsan": 2,
                       "asan": 1, "ubsan": 2, "periphery": 3}
        assert s["fingerprints"] == 17
        # high: codeql cleartext, strict data race, 2x tsan, asan
        # medium: codeql warning, 2x ubsan
        # low: codeql note, 3x strict non-race, 2x memory-safety, 3x periphery
        assert s["by_severity"] == {"high": 5, "medium": 3, "low": 9}
        assert len(s["new_high"]) == 5
        assert s["opened_or_reopened"] == 8 and s["overflow"] == 0
        assert all(it["issue"] for it in s["new_high"])
        assert sorted(s["low_digests"]) == ["codeql", "memory-safety", "periphery", "strict-concurrency"]
        assert len([i for i in gh.issues.values() if "nightly-digest" not in i.labels]) == 8
        assert "nightly-finding" in gh.labels and "asan" in gh.labels

    def test_failed_job_or_status_marks_tool_incomplete(self, tmp_path):
        art = make_artifacts(tmp_path, codeql_status=False)
        runs = nf.collect(art, {"strict-concurrency": "failure"}, None)
        assert not runs["codeql"].complete
        assert not runs["strict-concurrency"].complete
        assert runs["periphery"].complete
        missing = nf.collect(tmp_path / "nowhere", {}, None)
        assert not any(r.complete for r in missing.values())

    def test_dry_run_writes_nothing(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh()
        out = tmp_path / "s.json"
        plan_md = tmp_path / "plan.md"
        rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--today", "2026-10-02",
                     "--summary-out", str(out), "--plan-out", str(plan_md), "--dry-run"],
                    gh_factory=lambda repo: gh)
        assert rc == 0 and gh.issues == {}
        assert [c[0] for c in gh.calls] == ["list_issues"]
        s = json.loads(out.read_text())
        assert s["dry_run"] is True and s["opened_or_reopened"] == 8
        # The planned list is recorded in full, digest bodies included, so the
        # morning brief can show exactly what would be filed.
        pr = s["plan"]
        assert len(pr["would_open"]) == 8
        assert {o["severity"] for o in pr["would_open"]} == {"high", "medium"}
        assert sorted(d["tool"] for d in pr["digests"]) == [
            "codeql", "memory-safety", "periphery", "strict-concurrency"]
        assert all("nightly-low-digest" in d["body"] for d in pr["digests"])
        text = plan_md.read_text()
        assert "## Would open (8)" in text and "nightly-low-digest" in text

    def test_gh_failure_is_a_pipeline_failure_but_summary_still_written(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh(fail_on="create")
        out = tmp_path / "s.json"
        rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--today", "2026-10-02",
                     "--summary-out", str(out)], gh_factory=lambda repo: gh)
        assert rc == 1
        assert json.loads(out.read_text())["errors"]

    def test_findings_alone_never_fail_the_run(self, tmp_path):
        art = make_artifacts(tmp_path)
        rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--summary-out",
                     str(tmp_path / "s.json")], gh_factory=lambda repo: FakeGh())
        assert rc == 0


class TestGhCliSeam:
    def test_argv_shape_and_issue_number_parsing(self):
        seen = []

        def runner(argv, input=None, capture_output=None, text=None):
            seen.append((argv, input))
            out = "https://github.com/o/r/issues/321\n" if argv[1:3] == ["issue", "create"] else "[]"
            return subprocess.CompletedProcess(argv, 0, out, "")

        gh = nf.GhCli("o/r", runner=runner)
        assert gh.create_issue("T", "B", ["nightly-finding", "High Priority"]) == 321
        argv, stdin = seen[-1]
        assert argv[:2] == ["gh", "issue"] and argv[-2:] == ["--repo", "o/r"]
        assert "--body-file" in argv and stdin == "B"
        assert argv.count("--label") == 2
        gh.close(5, "bye")
        assert seen[-1][0][:6] == ["gh", "issue", "close", "5", "--reason", "completed"]

    def test_gh_error_raises(self):
        def runner(argv, **kw):
            return subprocess.CompletedProcess(argv, 1, "", "HTTP 403")
        with pytest.raises(RuntimeError, match="HTTP 403"):
            nf.GhCli("o/r", runner=runner).list_labels()


# --------------------------------------------------------------------------
# Morning alert
# --------------------------------------------------------------------------


class TestMorningAlert:
    NOW = dt.datetime(2026, 10, 2, 16, 0, tzinfo=dt.timezone.utc)

    def _s(self, **kw):
        base = {"date": "2026-10-02", "dry_run": False, "new_high": [], "errors": []}
        return base | kw

    def test_new_high_prints_red_line(self):
        lines = alert.alert_lines(self._s(new_high=[{"issue": 12, "title": "T"}]), self.NOW)
        assert lines[0].startswith("🔴 1 NEW high-severity") and "#12 T" in lines[1]

    def test_quiet_when_nothing_new_or_stale(self):
        assert alert.alert_lines(self._s(), self.NOW) == []
        stale = self._s(date="2026-09-28", new_high=[{"issue": 1, "title": "x"}])
        assert alert.alert_lines(stale, self.NOW) == []

    def test_dry_run_shows_what_would_be_filed(self):
        s = self._s(dry_run=True, new_high=[{"issue": 900001, "title": "Race in X"}],
                    overflow=0,
                    plan={"would_open": [{"severity": "high", "title": "Race in X"}],
                          "would_reopen": [], "would_comment": [], "would_close": []},
                    low_digests={"periphery": {"count": 1404, "new": 3, "gone": 1}})
        lines = alert.alert_lines(s, self.NOW)
        assert lines[0].startswith("🔴 1 NEW") and "writes are off" in lines[0]
        assert "(would open) Race in X" in lines[1]
        yellow = [ln for ln in lines if ln.startswith("🟡")]
        assert yellow and "would open 1" in yellow[0] and "NIGHTLY_FINDINGS_WRITE" in yellow[0]
        assert any("periphery 1404 (+3/−1)" in ln for ln in lines)
        assert "#900001" not in "\n".join(lines)            # fake dry-run numbers never shown

    def test_pipeline_errors_are_red_too(self):
        assert alert.alert_lines(self._s(errors=["boom"]), self.NOW)[0].startswith("🔴")

    def test_cli_tolerates_garbage(self, tmp_path):
        p = tmp_path / "x.json"
        p.write_text("not json")
        assert alert.main(["--file", str(p)]) == 0
