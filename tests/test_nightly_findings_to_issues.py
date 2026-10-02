#!/usr/bin/env python3
"""Tests for tools/nightly_findings_to_issues.py and the morning alert.

No network. Every GitHub interaction goes through FakeGh, an in-memory issue
tracker that implements the same seam as GhCli. One test drives GhCli itself
through a fake subprocess runner to pin the exact `gh` argv.

Design under test (Rick, 2026-10-02): ONE nightly ticket per night, rotated so
only one is open (a human comment in the last 48 h keeps an old one open);
separate tracking issues for HIGH severity only, at most 3 new per night;
vendored code reported in one line, never filed; morning 🔴 / ⚠️ lines.

Five-dimension checklist (CLAUDE.md):
  Logic     parsers per tool, severity mapping, fingerprints, the tracking
            lifecycle, the ticket's NEW / CHANGED / FIXED / still-open /
            low-delta sections, rotation and the human-comment guard.
  Scale     5,000 findings plan in a time budget; the ticket body stays under
            GitHub's 65,536-character limit with 3,000 medium + 3,000 low.
  Media     n/a. The tool reads analysis logs, not media.
  Isolation an INCOMPLETE tool never advances the "gone" counter and never
            reports FIXED; a same-night rerun edits the same ticket and opens
            no extra tracking issues. These are the poisoned-state cases.
  Sensor    the end-to-end run over the fixture tree pins the per-tool
            counts, so a parser that silently stops matching shows up.
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

    def list_issues(self, label, with_comments=False):
        self.calls.append(("list_issues", label))
        return [nf.Issue(i.number, i.title, i.state, i.state_reason, list(i.labels), i.body,
                         [dict(c) for c in i.comments] if with_comments else [])
                for i in self.issues.values() if label in i.labels]

    def list_labels(self):
        return set(self.labels)

    def create_label(self, name, color, desc):
        self.calls.append(("create_label", name))
        self.labels.add(name)

    def create_issue(self, title, body, labels):
        self._maybe_fail("create")
        if self.fail_on == "create_ticket" and nf.TICKET_LABEL in labels:
            raise RuntimeError("simulated ticket create failure")
        n = self._next
        self._next += 1
        self.issues[n] = nf.Issue(n, title, "OPEN", None, list(labels), body)
        self.calls.append(("create", n, title, tuple(labels)))
        return n

    def _bot_comment(self, number, body):
        self.issues[number].comments.append(
            {"author": {"login": "github-actions"}, "createdAt": "2026-10-01T05:00:00Z", "body": body})

    def comment(self, number, body):
        self._bot_comment(number, body)
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
        self._bot_comment(number, comment)
        self.calls.append(("close", number, comment))

    def reopen(self, number, comment):
        i = self.issues[number]
        i.state, i.state_reason = "OPEN", "REOPENED"
        self.calls.append(("reopen", number, comment))

    # ---- views ----
    def kinds(self, kind):
        return [c for c in self.calls if c[0] == kind]

    def tracking(self):
        return [i for i in self.issues.values() if nf.BASE_LABEL in i.labels
                and nf.DIGEST_LABEL not in i.labels]

    def tickets(self):
        return sorted((i for i in self.issues.values() if nf.TICKET_LABEL in i.labels),
                      key=lambda i: i.number)

    def open_tickets(self):
        return [t for t in self.tickets() if t.is_open]

    def tracking_calls(self):
        """Write calls that touched a tracking issue (not the ticket)."""
        tickets = {t.number for t in self.tickets()}
        out = []
        for c in self.calls:
            if c[0] in ("list_issues", "create_label"):
                continue
            if c[0] == "create":
                if nf.TICKET_LABEL not in c[3]:
                    out.append(c)
            elif c[1] not in tickets:
                out.append(c)
        return out


def F(tool="codeql", rule="r", file="a.swift", line=1, msg="m", sev="high"):
    return nf.Finding(tool, rule, file, line, msg, sev)


def LOW(i, tool="periphery", rule="Unused function '…'"):
    return F(tool=tool, rule=rule, file=f"VideoScan/VideoScan/F{i}.swift", line=i,
             msg=f"Unused function 'f{i}()'", sev="low")


def runs_from(findings, complete=None):
    runs = {t: nf.ToolRun(t, input_found=True, complete=True) for t in nf.TOOLS}
    for f in findings:
        runs[f.tool].findings.append(f)
    for t, v in (complete or {}).items():
        runs[t].complete = v
    return runs


def at(today, hour=6):
    return dt.datetime.fromisoformat(f"{today}T{hour:02d}:00:00+00:00")


def night(gh, findings, today, complete=None, cap=3, now=None, dry=False):
    runs = runs_from(findings, complete)
    gh.calls.clear()
    res = nf.run_night(gh, runs, today, now or at(today), "https://run/1", cap, dry)
    assert res.errors == []
    return res


def ticket_for(gh, today):
    (t,) = [t for t in gh.tickets() if t.ticket_marker["date"] == today]
    return t


def section(body, heading):
    """The text of one '## ' section of the ticket body."""
    start = body.index("## " + heading)
    nxt = body.find("\n## ", start + 3)
    return body[start: nxt if nxt != -1 else len(body)]


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
        assert not any("type-check" in f.message for f in fs)
        assert not any(g.rule == "memory-safety" for g in groups.values())
        assert len(fs) == 5 and len(groups) == 4

    def test_memory_safety_is_its_own_low_severity_tool(self):
        fs = nf.parse_compiler_warnings(FIX / "memory-safety-findings.txt", None, "memory-safety")
        groups = nf.group_findings(fs)
        assert {g.tool for g in groups.values()} == {"memory-safety"}
        assert {g.severity for g in groups.values()} == {"low"}
        assert len(fs) == 3 and len(groups) == 2
        assert nf.parse_compiler_warnings(FIX / "memory-safety-findings.txt", None) == []

    def test_every_sanitizer_hit_is_high(self):
        """Rick 2026-10-02: TSan/ASan/UBSan hits in our own code are tracked."""
        tsan = nf.group_findings(nf.parse_sanitizer_log(FIX / "tsan.log", "tsan", None))
        asan = nf.group_findings(nf.parse_sanitizer_log(FIX / "asan.log", "asan", None))
        ubsan = nf.group_findings(nf.parse_sanitizer_log(FIX / "ubsan.log", "ubsan", None))
        assert {g.severity for g in tsan.values()} == {"high"}
        assert {g.severity for g in asan.values()} == {"high"}
        assert {g.severity for g in ubsan.values()} == {"high"}
        assert len(tsan) == 2
        files = sorted(g.file for g in tsan.values())
        assert files == ["<libswiftCore.dylib>", "VideoScan/VideoScan/Model/VideoScanModel.swift"]
        (a,) = asan.values()
        assert a.rule == "heap-use-after-free" and a.file.endswith("Media/FrameDecoder.swift")
        assert len(ubsan) == 2           # mlx overflow (x2 values) + our misaligned load

    def test_periphery_is_low(self):
        groups = nf.group_findings(nf.parse_periphery(FIX / "periphery-strict.txt", None))
        assert len(groups) == 3
        assert {g.severity for g in groups.values()} == {"low"}
        assert any(g.rule == "Unused function '…'" for g in groups.values())

    def test_high_findings_get_high_priority_label(self):
        (only,) = nf.group_findings([F(sev="high")]).values()
        assert nf.labels_for(only) == ["nightly-finding", "codeql", "High Priority"]


# --------------------------------------------------------------------------
# Vendored code
# --------------------------------------------------------------------------


class TestVendored:
    @pytest.mark.parametrize("path", [
        "DerivedData/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx/backend/metal/device.cpp",
        "VideoScan/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx/array.cpp",
        ".build/checkouts/swift-collections/Sources/X.swift",
        "VideoScanCore/.build/checkouts/swift-argument-parser/Sources/A.swift",
        "Pods/Foo/Bar.m", "third_party/zlib/inflate.c", "Vendor/lib/x.c",
        "/Applications/Xcode.app/Contents/Developer/usr/include/x.h",
        "<libmlx.dylib>",
    ])
    def test_vendored_paths(self, path):
        assert nf.is_vendored(path)

    @pytest.mark.parametrize("path", [
        "VideoScan/VideoScan/Media/ycbcr.c", "VideoScanCore/Sources/VideoScanCore/A.swift",
        "<libswiftCore.dylib>", "?", "",
        "VideoScan/VideoScan/Model/VendorNotes.swift",   # "Vendor" as a word, not a directory
    ])
    def test_our_code_is_not_vendored(self, path):
        assert not nf.is_vendored(path)

    def test_vendored_is_never_filed_and_reported_in_one_line(self):
        gh = FakeGh()
        vend = [F(tool="ubsan", rule="member call", sev="high", msg=f"member call on null pointer {i}x",
                  file="DerivedData/SourcePackages/checkouts/mlx-swift/Source/Cmlx/device.cpp")
                for i in ("a", "b")]
        res = night(gh, vend + [F(file="ours.swift")], "2026-10-02")
        assert [i.title for i in gh.tracking()] == [nf.issue_title(next(iter(
            nf.group_findings([F(file="ours.swift")]).values())))]
        body = ticket_for(gh, "2026-10-02").body
        lines = [ln for ln in body.splitlines() if "mlx-swift" in ln]
        assert len(lines) == 1 and "Vendored / third-party (not filed): 2 finding(s)" in lines[0]
        assert "device.cpp" not in body
        assert len(res.ticket.new_high) == 1


# --------------------------------------------------------------------------
# High tracking issues: lifecycle
# --------------------------------------------------------------------------


class TestTrackingLifecycle:
    def test_new_high_opens_one_issue_and_next_night_is_silent(self):
        gh = FakeGh()
        night(gh, [F(line=10), F(line=20)], "2026-10-02")         # same fingerprint, two lines
        assert len(gh.tracking()) == 1
        night(gh, [F(line=11), F(line=21)], "2026-10-03")         # code moved, nothing else changed
        assert gh.tracking_calls() == []

    def test_medium_never_gets_a_tracking_issue(self):
        gh = FakeGh()
        res = night(gh, [F(file=f"m{i}.swift", sev="medium") for i in range(5)], "2026-10-02")
        assert gh.tracking() == [] and res.tracking.opened == []
        assert len(res.ticket.new_medium) == 5

    def test_escalation_to_high_opens_a_tracking_issue(self):
        gh = FakeGh()
        night(gh, [F(sev="medium")], "2026-10-02")
        assert gh.tracking() == []
        night(gh, [F(sev="high")], "2026-10-03")
        (iss,) = gh.tracking()
        assert "High Priority" in iss.labels

    def test_existing_open_medium_issue_keeps_its_lifecycle(self):
        (g,) = nf.group_findings([F(sev="medium")]).values()
        st = {"v": 1, "fp": g.fp, "tool": "codeql", "first_seen": "2026-09-30", "digest": "old",
              "count": 1, "severity": "medium", "missing_dates": []}
        gh = FakeGh([nf.Issue(5, "t", "OPEN", None, ["nightly-finding", "codeql"],
                              nf.render_marker(st))])
        night(gh, [F(sev="medium")], "2026-10-02")               # digest differs -> one comment
        assert len(gh.kinds("comment")) == 1
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        assert not gh.issues[5].is_open

    def test_changed_finding_gets_exactly_one_comment(self):
        gh = FakeGh()
        night(gh, [F(line=1)], "2026-10-02")
        night(gh, [F(line=1), F(line=2)], "2026-10-03")           # count 1 -> 2
        comments = gh.kinds("comment")
        assert len(comments) == 1 and "Occurrences: 1 → 2" in comments[0][2]
        night(gh, [F(line=1), F(line=2)], "2026-10-04")
        assert gh.kinds("comment") == []

    def test_gone_three_complete_nights_closes(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        night(gh, [], "2026-10-03")
        night(gh, [], "2026-10-04")
        (iss,) = gh.tracking()
        assert iss.is_open and iss.marker["missing_dates"] == ["2026-10-03", "2026-10-04"]
        res = night(gh, [], "2026-10-05")
        assert not gh.tracking()[0].is_open
        assert f"#{iss.number}" in section(ticket_for(gh, "2026-10-05").body, "FIXED")
        assert res.tracking.closed

    def test_seen_again_resets_the_gone_counter(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        night(gh, [], "2026-10-03")
        night(gh, [], "2026-10-04")
        night(gh, [F()], "2026-10-05")
        assert gh.tracking()[0].marker["missing_dates"] == []
        night(gh, [], "2026-10-06")
        night(gh, [], "2026-10-07")
        assert gh.tracking()[0].is_open

    def test_incomplete_tool_never_advances_the_counter(self):
        """Poisoned state: the CodeQL build broke, so CodeQL reported nothing.
        That is not three nights of fixes."""
        gh = FakeGh()
        night(gh, [F(tool="codeql")], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06"):
            res = night(gh, [], d, complete={"codeql": False})
            assert res.tracking.held_incomplete
            assert res.ticket.fixed == []                        # and nothing reads as FIXED
        iss = gh.tracking()[0]
        assert iss.is_open and not iss.marker["missing_dates"]

    def test_same_day_rerun_does_not_double_count(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        for _ in range(4):
            night(gh, [], "2026-10-03")
        iss = gh.tracking()[0]
        assert iss.is_open and iss.marker["missing_dates"] == ["2026-10-03"]

    def test_auto_closed_finding_that_returns_is_reopened(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        res = night(gh, [F()], "2026-10-06")
        assert len(gh.kinds("reopen")) == 1
        assert [c for c in gh.kinds("create") if nf.BASE_LABEL in c[3]] == []
        assert gh.tracking()[0].is_open
        assert [g.fp for g in res.ticket.new_high] == res.tracking.opened   # back = NEW again


class TestWontfix:
    def _wontfix(self, finding, labels, reason="COMPLETED", state="CLOSED"):
        (g,) = nf.group_findings([finding]).values()
        st = {"v": 1, "fp": g.fp, "tool": g.tool, "digest": "old", "count": 9,
              "severity": g.severity, "missing_dates": []}
        return nf.Issue(7, "t", state, reason, labels, nf.render_marker(st) + "\nbody")

    def test_wontfix_label_is_never_reopened_or_duplicated(self):
        f = F(sev="high")
        gh = FakeGh([self._wontfix(f, ["nightly-finding", "codeql", "wontfix"])])
        res = night(gh, [f], "2026-10-02")
        assert gh.tracking_calls() == [] and res.tracking.skipped_wontfix
        assert res.ticket.new_high == []
        assert "Silenced by `wontfix`: 1" in ticket_for(gh, "2026-10-02").body

    def test_closed_as_not_planned_is_treated_as_wontfix(self):
        f = F()
        gh = FakeGh([self._wontfix(f, ["nightly-finding", "codeql"], reason="NOT_PLANNED")])
        night(gh, [f], "2026-10-02")
        assert gh.tracking_calls() == []

    def test_open_issue_with_wontfix_gets_no_comment_and_is_not_closed(self):
        f = F()
        gh = FakeGh([self._wontfix(f, ["nightly-finding", "codeql", "wontfix"], reason=None, state="OPEN")])
        night(gh, [f, F(line=99)], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        assert gh.issues[7].is_open
        assert gh.issues[7].comments == []


class TestCap:
    def _highs(self, n, prefix="h"):
        return [F(file=f"{prefix}{i}.swift", sev="high") for i in range(n)]

    def test_at_most_three_new_high_tracking_issues_per_night(self):
        gh = FakeGh()
        res = night(gh, self._highs(8) + [F(tool="codeql", file=f"m{i}.swift", sev="medium")
                                          for i in range(4)], "2026-10-02")
        assert len(gh.tracking()) == 3
        assert all("High Priority" in i.labels for i in gh.tracking())
        assert len(res.tracking.pending) == 5
        # All 8 highs are listed as NEW in the ticket; 5 say they are queued.
        new = section(ticket_for(gh, "2026-10-02").body, "🔴 NEW high")
        assert new.count("\n- `") == 8 and new.count("queued (cap 3/night)") == 5

    def test_queue_drains_on_later_nights_and_is_not_new_again(self):
        gh = FakeGh()
        fs = self._highs(7)
        night(gh, fs, "2026-10-02")
        r2 = night(gh, fs, "2026-10-03")
        r3 = night(gh, fs, "2026-10-04")
        assert len(gh.tracking()) == 7
        assert r2.ticket.new_high == [] and r3.ticket.new_high == []
        assert r3.tracking.pending == []

    def test_rerun_same_night_opens_no_more(self):
        gh = FakeGh()
        fs = self._highs(9)
        night(gh, fs, "2026-10-02")
        night(gh, fs, "2026-10-02", now=at("2026-10-02", 9))
        night(gh, fs, "2026-10-02", now=at("2026-10-02", 12))
        assert len(gh.tracking()) == 3

    def test_reopen_counts_against_the_cap(self):
        gh = FakeGh()
        night(gh, [F(file="a_old.swift")], "2026-10-02")
        for d in ("2026-10-03", "2026-10-04", "2026-10-05"):
            night(gh, [], d)
        res = night(gh, [F(file="a_old.swift")] + self._highs(5), "2026-10-06")
        assert len(res.tracking.opened) == 3 and len(res.tracking.pending) == 3
        assert gh.kinds("reopen")


# --------------------------------------------------------------------------
# The nightly ticket
# --------------------------------------------------------------------------


SECTION_ORDER = ["🔴 NEW high", "NEW medium", "CHANGED", "FIXED since last night",
                 "Still open", "Low severity"]


class TestTicket:
    def test_first_night_creates_one_ticket_with_sections_in_action_order(self):
        gh = FakeGh()
        night(gh, [F(), F(file="m.swift", sev="medium")] + [LOW(i) for i in range(12)], "2026-10-02")
        (t,) = gh.tickets()
        assert t.title == "Nightly findings — 2026-10-02" and t.labels == ["nightly-findings"]
        assert nf.TICKET_LABEL in gh.labels
        positions = [t.body.index("## " + s) for s in SECTION_ORDER]
        assert positions == sorted(positions)
        assert t.body.startswith("<!-- nightly-findings-ticket ")
        assert len(t.body) < nf.GITHUB_BODY_LIMIT

    def test_every_item_has_fingerprint_file_rule_and_run_link(self):
        gh = FakeGh()
        (g,) = nf.group_findings([F(rule="swift/cleartext-logging", file="X/Y.swift")]).values()
        night(gh, [F(rule="swift/cleartext-logging", file="X/Y.swift")], "2026-10-02")
        new = section(ticket_for(gh, "2026-10-02").body, "🔴 NEW high")
        (line,) = [ln for ln in new.splitlines() if ln.startswith("- ")]
        assert f"`{g.fp}`" in line and "`X/Y.swift`" in line
        assert "`swift/cleartext-logging`" in line and "[run](https://run/1)" in line

    def test_rotation_keeps_exactly_one_ticket_open(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        night(gh, [F()], "2026-10-03")
        night(gh, [F()], "2026-10-04")
        assert len(gh.tickets()) == 3
        (open_t,) = gh.open_tickets()
        assert open_t.ticket_marker["date"] == "2026-10-04"
        prev = ticket_for(gh, "2026-10-03")
        closing = [c for c in gh.kinds("close") if c[1] == prev.number]
        assert closing and f"Superseded by #{open_t.number}" in closing[0][2]
        assert f"Compared with: #{prev.number} (2026-10-03)" in open_t.body

    def test_human_comment_in_last_48h_keeps_old_ticket_open_and_linked(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        old = ticket_for(gh, "2026-10-02")
        old.comments.append({"author": {"login": "musicalengineer"},
                             "createdAt": "2026-10-02T20:00:00Z", "body": "looking at the race"})
        night(gh, [F()], "2026-10-03", now=at("2026-10-03"))          # 10 h later
        assert old.is_open
        new = ticket_for(gh, "2026-10-03")
        assert f"#{old.number}" in new.body and "commented in the last 48 h" in new.body
        assert {t.number for t in gh.open_tickets()} == {old.number, new.number}
        # Two days of quiet later, the next rotation closes it.
        night(gh, [F()], "2026-10-05", now=at("2026-10-05"))
        assert not old.is_open and len(gh.open_tickets()) == 1

    def test_bot_and_old_comments_do_not_hold_a_ticket_open(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        old = ticket_for(gh, "2026-10-02")
        old.comments += [
            {"author": {"login": "github-actions"}, "createdAt": "2026-10-02T23:00:00Z", "body": "x"},
            {"author": {"login": "dependabot[bot]"}, "createdAt": "2026-10-02T23:00:00Z", "body": "x"},
            {"author": {"login": "musicalengineer"}, "createdAt": "2026-09-29T10:00:00Z", "body": "old"},
        ]
        night(gh, [F()], "2026-10-03")
        assert not old.is_open

    def test_recent_human_comment_unit(self):
        now = at("2026-10-03")
        mk = lambda login, ts: nf.Issue(1, "t", "OPEN", None, [], "", [  # noqa: E731
            {"author": {"login": login}, "createdAt": ts, "body": ""}])
        assert nf.recent_human_comment(mk("rick", "2026-10-01T07:00:00Z"), now)        # 47 h
        assert not nf.recent_human_comment(mk("rick", "2026-10-01T05:00:00Z"), now)    # 49 h
        assert not nf.recent_human_comment(mk("github-actions[bot]", "2026-10-03T05:00:00Z"), now)
        assert nf.recent_human_comment(mk("rick", "garbage"), now)                     # unsure -> keep

    def test_rerun_same_night_updates_the_same_ticket(self):
        gh = FakeGh()
        day1 = [F(file="a.swift"), F(file="b.swift", sev="medium")] + [LOW(i) for i in range(6)]
        night(gh, day1, "2026-10-02")
        day2 = [F(file="a.swift"), F(file="c.swift"), F(file="d.swift", sev="medium")] + \
            [LOW(i) for i in range(2, 9)]
        r1 = night(gh, day2, "2026-10-03")
        (t1,) = [t for t in gh.tickets() if t.ticket_marker["date"] == "2026-10-03"]
        body1 = t1.body
        r2 = night(gh, day2, "2026-10-03", now=at("2026-10-03", 9))
        assert len(gh.tickets()) == 2                               # no second ticket tonight
        assert not [c for c in gh.kinds("create") if nf.TICKET_LABEL in c[3]]
        assert [c[0] for c in gh.calls if c[0] != "list_issues" and c[1:2] == (t1.number,)] in ([], ["edit"])
        # Same comparison baseline -> same verdicts.
        for a, b in [(r1.ticket.new_high, r2.ticket.new_high), (r1.ticket.new_medium, r2.ticket.new_medium)]:
            assert [g.fp for g in a] == [g.fp for g in b]
        assert [fp for fp, _ in r1.ticket.fixed] == [fp for fp, _ in r2.ticket.fixed]
        assert r1.ticket.low == r2.ticket.low
        assert section(t1.body, "🔴 NEW high").count("\n- `") == section(body1, "🔴 NEW high").count("\n- `")
        assert len(gh.open_tickets()) == 1
        # Yesterday's ticket was closed exactly once.
        prev = ticket_for(gh, "2026-10-02")
        assert sum(1 for c in prev.comments if "Superseded" in c["body"]) == 1

    def test_new_changed_fixed_and_still_open(self):
        gh = FakeGh()
        A, B, M = F(file="a.swift"), F(file="b.swift"), F(file="m.swift", sev="medium")
        night(gh, [A, B, M], "2026-10-02")
        C = F(file="c.swift")
        res = night(gh, [A, F(file="a.swift", line=9), C, M], "2026-10-03")   # A count 1 -> 2
        fp = lambda f: nf.fingerprint(f.tool, f.rule, f.file, f.message)  # noqa: E731
        tk = res.ticket
        assert [g.fp for g in tk.new_high] == [fp(C)] and tk.new_medium == []
        assert [g.fp for g, _ in tk.changed] == [fp(A)]
        assert [f for f, _ in tk.fixed] == [fp(B)]
        assert {g.fp for g, _ in tk.still_open} == {fp(A), fp(M)}
        body = ticket_for(gh, "2026-10-03").body
        assert fp(B) in section(body, "FIXED") and "b.swift" in section(body, "FIXED")
        assert fp(A) in section(body, "CHANGED") and "now ×2" in section(body, "CHANGED")
        oldest = section(body, "Still open")
        assert "since 2026-10-02" in oldest and "| codeql | 2 | 1 | 0 |" in oldest

    def test_incomplete_tool_carries_state_and_is_not_new_when_it_returns(self):
        gh = FakeGh()
        X = F(tool="ubsan", file="VideoScan/VideoScan/Media/ycbcr.c", rule="load of misaligned")
        night(gh, [X, F()], "2026-10-02")
        r2 = night(gh, [F()], "2026-10-03", complete={"ubsan": False})
        assert r2.ticket.fixed == []
        assert "Incomplete tonight" in ticket_for(gh, "2026-10-03").body
        r3 = night(gh, [X, F()], "2026-10-04")
        assert r3.ticket.new_high == []

    def test_low_counts_and_deltas_top_five_only_never_filed(self):
        gh = FakeGh()
        night(gh, [LOW(i) for i in range(40)], "2026-10-02")
        res = night(gh, [LOW(i) for i in range(3, 52)], "2026-10-03")     # -3 gone, +12 new
        assert gh.tracking() == []
        low = section(ticket_for(gh, "2026-10-03").body, "Low severity")
        assert "| periphery | 49 | +12 | −3 | was 40 |" in low
        assert low.count("\n- `") == 5 and "top 5 of 12 new" in low
        assert res.ticket.low["periphery"]["new_total"] == 12

    def test_low_held_for_incomplete_tool(self):
        gh = FakeGh()
        night(gh, [LOW(i) for i in range(10)], "2026-10-02")
        night(gh, [LOW(1)], "2026-10-03", complete={"periphery": False})
        low = section(ticket_for(gh, "2026-10-03").body, "Low severity")
        assert "| periphery | 10 | – | – | incomplete tonight; count as of 2026-10-02 |" in low
        res = night(gh, [LOW(i) for i in range(10)], "2026-10-04")
        assert res.ticket.low["periphery"]["new_total"] == 0
        assert res.ticket.low["periphery"]["gone"] == 0

    def test_legacy_digest_issues_are_closed_with_a_pointer(self):
        legacy = nf.Issue(3, "[nightly/periphery] Low-severity findings (rolling digest)", "OPEN", None,
                          ["nightly-finding", "nightly-digest", "periphery"],
                          '<!-- nightly-low-digest {"v": 1, "tool": "periphery", "fp8": ""} -->')
        gh = FakeGh([legacy])
        night(gh, [LOW(1)], "2026-10-02")
        assert not gh.issues[3].is_open
        t = ticket_for(gh, "2026-10-02")
        assert any(f"#{t.number}" in c["body"] for c in gh.issues[3].comments)

    def test_ticket_create_failure_never_closes_the_previous_ticket(self):
        gh = FakeGh()
        night(gh, [F()], "2026-10-02")
        gh.fail_on = "create_ticket"
        res = nf.run_night(gh, runs_from([F()]), "2026-10-03", at("2026-10-03"), "", 3)
        assert res.errors and len(gh.open_tickets()) == 1

    def test_dry_run_through_run_night_writes_nothing(self):
        gh = FakeGh()
        dry = nf.DryRunGh(gh)
        res = nf.run_night(dry, runs_from([F(), LOW(1)]), "2026-10-02", at("2026-10-02"), "u", 3, True)
        assert gh.issues == {} and res.errors == []
        assert "tracking: would be opened" in res.ticket.body
        assert "DRY RUN" in res.ticket.body


class TestScaleAndBudget:
    def test_five_thousand_findings_plan_within_budget(self):
        fs = [F(tool="ubsan", file=f"f{i % 900}.c", line=i, msg=f"runtime error kind {i}",
                sev="high") for i in range(5000)]
        gh = FakeGh()
        t0 = time.monotonic()
        res = night(gh, fs, "2026-10-02")
        assert time.monotonic() - t0 < 10.0
        assert len(res.tracking.opened) == 3
        assert len(ticket_for(gh, "2026-10-02").body) < nf.GITHUB_BODY_LIMIT

    def test_ticket_fits_github_limit_at_scale_and_degrades_honestly(self):
        gh = FakeGh()
        fs = ([F(tool="codeql", file=f"VideoScan/VideoScan/Deep/Path/File{i}.swift",
                 msg="x" * 80 + f" {i}", sev="medium") for i in range(3000)]
              + [LOW(i) for i in range(3000)])
        night(gh, fs, "2026-10-02")
        t = ticket_for(gh, "2026-10-02")
        assert len(t.body) < nf.GITHUB_BODY_LIMIT
        st = t.ticket_marker
        assert st["degraded"]
        # Every medium fingerprint is still remembered (full record or prefix).
        remembered = set(st["hm"]) | {p for b in st["hm8"].values() for p in nf.blob_to_set(b)}
        assert len({fp[:8] for fp in remembered}) == 3000
        assert "State marker over budget" in t.body
        r2 = night(gh, fs, "2026-10-03")
        assert r2.ticket.new_medium == []

    def test_realistic_scale_does_not_degrade(self):
        """Tonight's real shape: ~31 high, ~2 medium, ~2,000 low."""
        gh = FakeGh()
        fs = ([F(file=f"H{i}.swift") for i in range(31)]
              + [F(file=f"M{i}.swift", sev="medium") for i in range(2)]
              + [LOW(i) for i in range(1458)]
              + [LOW(i, tool="memory-safety", rule="memory-safety") for i in range(290)]
              + [LOW(i, tool="strict-concurrency", rule="concurrency") for i in range(265)])
        night(gh, fs, "2026-10-02")
        st = ticket_for(gh, "2026-10-02").ticket_marker
        assert st["degraded"] == [] and len(st["hm"]) == 33


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
    junk = art / "sanitizer-address" / "R.xcresult" / "Data"
    junk.mkdir(parents=True)
    (junk / "noise.log").write_text("SUMMARY: AddressSanitizer: SEGV /x.c:1 in nope\n")
    if codeql_status is not None:
        (art / "codeql-results" / "nightly-status-codeql.json").write_text(
            json.dumps({"complete": codeql_status}))
    return art


ARGS = ["--repo", "o/r", "--today", "2026-10-02", "--now", "2026-10-02T06:00:00Z",
        "--run-url", "https://github.com/o/r/actions/runs/1"]


class TestEndToEnd:
    def test_summary_counts_per_tool(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh()
        out = tmp_path / "s.json"
        rc = nf.run(["--artifacts", str(art), *ARGS, "--summary-out", str(out),
                     "--job-result", "codeql=success"], gh_factory=lambda repo: gh)
        assert rc == 0
        s = json.loads(out.read_text())
        fps = {t: v["fingerprints"] for t, v in s["tools"].items()}
        assert fps == {"codeql": 3, "strict-concurrency": 4, "memory-safety": 2, "tsan": 2,
                       "asan": 1, "ubsan": 1, "periphery": 3}
        assert s["tools"]["ubsan"]["vendored"] == 1 and s["vendored"]["count"] == 1
        assert s["fingerprints"] == 16
        # high: codeql cleartext, strict data race, 2x tsan, asan, ubsan (ours)
        # medium: codeql warning; low: codeql note, 3 strict, 2 memory-safety, 3 periphery
        assert s["by_severity"] == {"high": 6, "medium": 1, "low": 9}
        assert len(s["new_high"]) == 6 and len(s["new_medium"]) == 1
        assert len(s["tracking"]["opened"]) == 3 and s["tracking"]["pending"] == 3
        assert s["ticket"]["url"] == f"https://github.com/o/r/issues/{s['ticket']['number']}"
        assert s["ticket"]["action"] == "create"
        assert len(gh.tracking()) == 3 and len(gh.tickets()) == 1

    def test_failed_job_or_status_marks_tool_incomplete(self, tmp_path):
        art = make_artifacts(tmp_path, codeql_status=False)
        runs = nf.collect(art, {"strict-concurrency": "failure"}, None)
        assert not runs["codeql"].complete
        assert not runs["strict-concurrency"].complete
        assert runs["periphery"].complete
        missing = nf.collect(tmp_path / "nowhere", {}, None)
        assert not any(r.complete for r in missing.values())

    def test_dry_run_writes_nothing_and_records_the_ticket(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh()
        out = tmp_path / "s.json"
        plan_md = tmp_path / "plan.md"
        rc = nf.run(["--artifacts", str(art), *ARGS, "--summary-out", str(out),
                     "--plan-out", str(plan_md), "--dry-run"], gh_factory=lambda repo: gh)
        assert rc == 0 and gh.issues == {}
        assert {c[0] for c in gh.calls} == {"list_issues"}
        s = json.loads(out.read_text())
        assert s["dry_run"] is True and s["ticket"]["url"] is None
        assert len(s["plan"]["would_open"]) == 3
        assert {o["severity"] for o in s["plan"]["would_open"]} == {"high"}
        assert s["plan"]["ticket"]["action"] == "create"
        text = plan_md.read_text()
        assert "## Ticket: create" in text and "# Nightly findings — 2026-10-02" in text

    def test_gh_failure_is_a_pipeline_failure_but_summary_still_written(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh(fail_on="create")
        out = tmp_path / "s.json"
        rc = nf.run(["--artifacts", str(art), *ARGS, "--summary-out", str(out)],
                    gh_factory=lambda repo: gh)
        assert rc == 1
        assert json.loads(out.read_text())["errors"]

    def test_findings_alone_never_fail_the_run(self, tmp_path):
        art = make_artifacts(tmp_path)
        rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--summary-out",
                     str(tmp_path / "s.json")], gh_factory=lambda repo: FakeGh())
        assert rc == 0

    def test_two_runs_same_night_one_ticket(self, tmp_path):
        art = make_artifacts(tmp_path)
        gh = FakeGh()
        for hour in ("06", "09"):
            rc = nf.run(["--artifacts", str(art), "--repo", "o/r", "--today", "2026-10-02",
                         "--now", f"2026-10-02T{hour}:00:00Z", "--summary-out", str(tmp_path / "s.json")],
                        gh_factory=lambda repo: gh)
            assert rc == 0
        assert len(gh.tickets()) == 1 and len(gh.tracking()) == 3
        s = json.loads((tmp_path / "s.json").read_text())
        assert s["ticket"]["action"] in ("edit", "unchanged") and len(s["new_high"]) == 6


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
        gh.list_issues("nightly-findings", with_comments=True)
        assert seen[-1][0][seen[-1][0].index("--json") + 1].endswith(",comments")
        gh.list_issues("nightly-finding")
        assert "comments" not in seen[-1][0][seen[-1][0].index("--json") + 1]

    def test_list_issues_parses_comments(self):
        def runner(argv, **kw):
            out = json.dumps([{"number": 4, "title": "t", "state": "OPEN", "stateReason": None,
                               "labels": [{"name": "nightly-findings"}], "body": "b",
                               "comments": [{"author": {"login": "rick"}, "createdAt": "2026-10-02T00:00:00Z"}]}])
            return subprocess.CompletedProcess(argv, 0, out, "")
        (iss,) = nf.GhCli("o/r", runner=runner).list_issues("nightly-findings", with_comments=True)
        assert iss.comments[0]["author"]["login"] == "rick"

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
    URL = "https://github.com/o/r/issues/77"

    def _s(self, **kw):
        base = {"date": "2026-10-02", "dry_run": False, "new_high": [], "new_medium": [],
                "errors": [], "ticket": {"number": 77, "url": self.URL}, "tracking": {"open_high": []}}
        return base | kw

    def test_new_high_prints_red_line_with_ticket_url(self):
        lines = alert.alert_lines(self._s(new_high=[{"issue": 12, "title": "T"}]), self.NOW)
        assert lines[0].startswith("🔴 Nightly findings 2026-10-02: 1 NEW high, 0 NEW medium")
        assert self.URL in lines[0] and "[high] T (tracking #12)" in lines[1]

    def test_new_medium_alone_is_red_too(self):
        lines = alert.alert_lines(self._s(new_medium=[{"title": "W"}]), self.NOW)
        assert lines[0].startswith("🔴") and "1 NEW medium" in lines[0] and self.URL in lines[0]
        assert "[medium] W" in lines[1]

    def test_quiet_when_nothing_new_or_stale(self):
        assert alert.alert_lines(self._s(), self.NOW) == []
        stale = self._s(date="2026-09-28", new_high=[{"issue": 1, "title": "x"}])
        assert alert.alert_lines(stale, self.NOW) == []

    def test_high_tracking_issue_older_than_seven_days_warns(self):
        s = self._s(tracking={"open_high": [
            {"issue": 5, "since": "2026-09-20"},      # 12 days
            {"issue": 6, "since": "2026-09-25"},      # 7 days: not yet
            {"issue": 7, "since": "2026-10-02"},
        ]})
        lines = alert.alert_lines(s, self.NOW)
        assert len(lines) == 1 and lines[0].startswith("⚠️ 1 high-severity tracking issue")
        assert "#5 (12 d)" in lines[0] and "#6" not in lines[0] and self.URL in lines[0]

    def test_dry_run_has_no_fake_numbers(self):
        s = self._s(dry_run=True, ticket={"number": None, "url": None},
                    new_high=[{"issue": 900001, "title": "Race in X"}],
                    plan={"ticket": {"action": "create"}, "would_open": [{"severity": "high"}],
                          "would_reopen": [], "would_comment": [], "would_close": []})
        lines = alert.alert_lines(s, self.NOW)
        assert lines[0].startswith("🔴") and "(dry run: no ticket written)" in lines[0]
        assert "#900001" not in "\n".join(lines)
        yellow = [ln for ln in lines if ln.startswith("🟡")]
        assert yellow and "would create the nightly ticket" in yellow[0]
        assert "NIGHTLY_FINDINGS_WRITE" in yellow[0]

    def test_pipeline_errors_are_red_too(self):
        lines = alert.alert_lines(self._s(errors=["boom"]), self.NOW)
        assert lines[0].startswith("🔴") and self.URL in lines[0]

    def test_cli_tolerates_garbage(self, tmp_path):
        p = tmp_path / "x.json"
        p.write_text("not json")
        assert alert.main(["--file", str(p)]) == 0

    def test_end_to_end_summary_feeds_the_alert(self, tmp_path):
        art = make_artifacts(tmp_path)
        out = tmp_path / "s.json"
        assert nf.run(["--artifacts", str(art), *ARGS, "--summary-out", str(out)],
                      gh_factory=lambda repo: FakeGh()) == 0
        lines = alert.alert_lines(json.loads(out.read_text()), self.NOW)
        assert lines[0].startswith("🔴 Nightly findings 2026-10-02: 6 NEW high, 1 NEW medium")
        assert "https://github.com/o/r/issues/" in lines[0]
