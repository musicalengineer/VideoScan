"""scripts/xccov_union.py — line coverage of one build from K result bundles: the exact union, or a refusal.

Why it exists (2026-11-21): the nightly's app tests run as K test hosts, each with its own result bundle,
and Xcode's own merge (`xcresulttool merge` / `xccov merge`) is not the union — on 16 real bundles it
reported MORE executable lines than the build has and FEWER covered lines than one shard alone in 60
files. These tests pin, with a fake `xcrun xccov`: a line is covered when it ran in any bundle; the
denominator is the build's executable lines; the nightly's logic-only file filter; and every refusal
(other executable lines in a bundle, other files, an unreadable bundle, a target that is not there, a
file the archive lacks). With the real bundles of the 2026-11-21 measurement, when they are still under
~/Library/Caches/videoscan-nightly-shards (no build is made): the single host's bundle gives back
Xcode's own number to the line, and the 16-shard union is at least every shard, file by file.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "xccov_union.py"
spec = importlib.util.spec_from_file_location("xccov_union", SCRIPT)
xu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xu)

# `xcrun xccov view --report|--archive --json <bundle>` from the bundle's own report.json / archive.json.
FAKE_XCRUN = textwrap.dedent('''\
    import os, sys
    a = sys.argv[1:]
    assert a[:2] == ["xccov", "view"] and a[3] == "--json", a
    name = {"--report": "report.json", "--archive": "archive.json"}[a[2]]
    path = os.path.join(a[4], name)
    if not os.path.exists(path):
        sys.stderr.write("error: cannot read " + a[4] + "\\n")
        sys.exit(1)
    sys.stdout.write(open(path).read())
''')
LOGIC, VIEW, ROWF = "/src/Catalog/Ledger.swift", "/src/Catalog/LedgerView.swift", "/src/Catalog/LedgerRow.swift"


def lines(executable, ran, last=12):
    """xccov's archive records for one file: every line, executable or not, with its count and sub-ranges."""
    out = []
    for n in range(1, last + 1):
        if n in executable:
            out.append({"line": n, "isExecutable": True, "executionCount": 7 if n in ran else 0,
                        "subranges": [{"column": 5, "length": 9, "executionCount": 7 if n in ran else 0}]})
        else:
            out.append({"line": n, "isExecutable": False})
    return out


def bundle(tmp: Path, name: str, files: dict, target="VideoScan.app", report=None, others=True) -> Path:
    """files: {path: (executable line set, ran line set)}. report: {path: (covered, executable)} as Xcode's
    function-summed report would say (default: twice the distinct lines, to keep the two rulers apart)."""
    b = tmp / name
    b.mkdir()
    archive = {p: lines(ex, ran) for p, (ex, ran) in files.items()}
    if others:
        archive["/pkg/Dep.swift"] = lines({1, 2}, {1})
    rep = report or {p: (2 * len(ran & ex), 2 * len(ex)) for p, (ex, ran) in files.items()}
    targets = [{"name": target, "files": [{"path": p, "coveredLines": c, "executableLines": e} for p, (c, e) in rep.items()]},
               {"name": "Dep", "files": [{"path": "/pkg/Dep.swift", "coveredLines": 1, "executableLines": 2}]}]
    (b / "archive.json").write_text(json.dumps(archive))
    (b / "report.json").write_text(json.dumps({"targets": targets}))
    return b


@pytest.fixture
def xcrun(tmp_path):
    (tmp_path / "fake_xcrun.py").write_text(FAKE_XCRUN)
    return [sys.executable, str(tmp_path / "fake_xcrun.py")]


def cli(xcrun, *args):
    p = subprocess.run([sys.executable, str(SCRIPT), "--xcrun", " ".join(xcrun), *map(str, args)],
                       capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout.strip()


EX = {2, 3, 4, 5, 8, 9}


def test_a_line_is_covered_when_it_ran_in_any_bundle_and_the_denominator_is_the_builds(tmp_path, xcrun):
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2, 3}), VIEW: ({1, 2}, {1})})
    b = bundle(tmp_path, "b.xcresult", {LOGIC: (EX, {3, 8}), VIEW: ({1, 2}, set())})
    c = bundle(tmp_path, "c.xcresult", {LOGIC: (EX, set()), VIEW: ({1, 2}, {2})})
    u = xu.union([a, b, c], "VideoScan.app", xcrun)
    assert u["files"] == {LOGIC: [3, 6], VIEW: [2, 2]}          # {2,3,8} of 6; no bundle alone has more than 2
    assert xu.total(u["files"], logic=False) == (5, 8)
    assert xu.total(u["files"], logic=True) == (3, 6), "the View file is left out of logic-only"
    assert u["report"] == {}, "Xcode's function-summed number exists for one bundle only"
    # the other target's file never enters, and order does not matter
    assert xu.union([c, a, b], "VideoScan.app", xcrun)["files"] == u["files"]


def test_the_logic_filter_is_the_nightlys_awk_pattern():
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    assert "$2 ~ /(View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\\.swift$/ { next }" in nightly
    assert xu.LOGIC_EXCLUDE.pattern == r"(View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\.swift$"
    kept = [p for p in (LOGIC, VIEW, ROWF, "/s/VideoScanApp.swift", "/s/Viewer.swift", "/s/RowMath.swift", "/s/A.swiftx")
            if not xu.LOGIC_EXCLUDE.search(p)]
    assert kept == [LOGIC, "/s/Viewer.swift", "/s/RowMath.swift", "/s/A.swiftx"]


def test_one_bundle_gives_both_rulers_and_the_cli_prints_one_line(tmp_path, xcrun):
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2, 3, 4}), VIEW: ({1, 2}, {1})},
               report={LOGIC: (5, 11), VIEW: (1, 3)})          # closures counted again: 11 "lines" for 6
    out = tmp_path / "cov.json"
    code, text = cli(xcrun, "--target", "VideoScan.app", "--logic", "--json", out, a)
    assert code == 0, text
    assert text == ("coverage-union: 50.000% (3/6 distinct lines of VideoScan.app, logic only; union of 1 bundle(s), 2 files; "
                    "same executable lines in every bundle; union >= best bundle in every file) · the bundle's own report "
                    "(function-summed): 45.455% (5/11)")
    d = json.loads(out.read_text())
    assert (d["ok"], d["pct"], d["covered"], d["executable"], d["bundles"]) == (True, 50.0, 3, 6, 1)
    assert (d["report_pct"], d["report_covered"], d["report_executable"]) == (45.455, 5, 11)
    code, text = cli(xcrun, "--target", "VideoScan.app", a)     # every file: 4 of 8
    assert code == 0 and text.startswith("coverage-union: 50.000% (4/8 distinct lines of VideoScan.app;"), text


def test_a_bundle_with_other_executable_lines_is_refused_by_file_and_bundle(tmp_path, xcrun):
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2})})
    more = bundle(tmp_path, "more.xcresult", {LOGIC: (EX | {10}, {2, 10})})          # another build: one more line
    same_count = bundle(tmp_path, "moved.xcresult", {LOGIC: ((EX - {9}) | {10}, {2})})  # same count, other lines
    out = tmp_path / "cov.json"
    code, text = cli(xcrun, "--target", "VideoScan.app", "--json", out, a, more)
    assert code == 1 and text.startswith("coverage-union: REFUSED — ") and "%" not in text, text
    assert f"{more}: {LOGIC} has 7 executable lines, {a} has 6" in text and "not one build" in text
    assert json.loads(out.read_text())["ok"] is False and "pct" not in json.loads(out.read_text())
    code, text = cli(xcrun, "--target", "VideoScan.app", a, same_count)
    assert code == 1 and f"{same_count}: {LOGIC} has 6 executable lines, {a} has 6 (or other lines)" in text, text


def test_bundles_that_do_not_name_the_same_files_are_refused(tmp_path, xcrun):
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2}), VIEW: ({1}, {1})})
    b = bundle(tmp_path, "b.xcresult", {LOGIC: (EX, {3})})
    code, text = cli(xcrun, "--target", "VideoScan.app", a, b)
    assert code == 1 and "do not name the same files for VideoScan.app (1 differ, e.g. " + VIEW in text, text


def test_an_unreadable_bundle_a_missing_target_and_a_file_the_archive_lacks_are_refusals(tmp_path, xcrun):
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2})})
    gone = tmp_path / "gone.xcresult"
    gone.mkdir()
    code, text = cli(xcrun, "--target", "VideoScan.app", a, gone)
    assert code == 1 and f"REFUSED — {gone}: xccov view --report failed (exit 1: error: cannot read {gone})" in text, text
    code, text = cli(xcrun, "--target", "Nope.app", a)
    assert code == 1 and "its coverage report has 0 targets named 'Nope.app'" in text, text
    hole = bundle(tmp_path, "hole.xcresult", {LOGIC: (EX, {2})})
    arch = json.loads((hole / "archive.json").read_text())
    del arch[LOGIC]
    (hole / "archive.json").write_text(json.dumps(arch))
    code, text = cli(xcrun, "--target", "VideoScan.app", hole)
    assert code == 1 and f"{LOGIC} is in the report and not in the archive" in text, text
    (hole / "archive.json").write_text("{not json")
    code, text = cli(xcrun, "--target", "VideoScan.app", hole)
    assert code == 1 and "xccov view --archive did not print JSON" in text, text
    empty = bundle(tmp_path, "empty.xcresult", {VIEW: ({1}, {1})})
    code, text = cli(xcrun, "--target", "VideoScan.app", "--logic", empty)
    assert code == 1 and "has no executable line outside the excluded files" in text, text


def test_the_result_is_checked_not_assumed(monkeypatch, tmp_path, xcrun):
    """(b): the union must cover at least the best single bundle and only executable lines. True of a
    union by construction — so break the construction and see the check speak."""
    a = bundle(tmp_path, "a.xcresult", {LOGIC: (EX, {2, 3})})
    b = bundle(tmp_path, "b.xcresult", {LOGIC: (EX, {8})})

    class Forgetful(set):                       # a "union" that loses lines
        def __ior__(self, other):
            self.clear()
            self.update(other)
            return self
    real = xu.BundleCoverage

    def first_forgets(bundle_path, target, xcrun_):
        one = real(bundle_path, target, xcrun_)
        one.covered = {p: Forgetful(s) for p, s in one.covered.items()}
        return one
    monkeypatch.setattr(xu, "BundleCoverage", first_forgets)
    monkeypatch.setattr(xu, "set", lambda s: s, raising=False)       # keep the Forgetful sets as the accumulators
    with pytest.raises(xu.Refused, match="the union covers 1 lines, one bundle alone 2"):
        xu.union([a, b], "VideoScan.app", xcrun)


def test_each_archive_record_becomes_one_int_as_it_is_parsed():
    assert xu._line_code({"line": 7, "isExecutable": True, "executionCount": 3}) == 7
    assert xu._line_code({"line": 7, "isExecutable": True, "executionCount": 0}) == -7
    assert xu._line_code({"line": 7, "isExecutable": True}) == -7
    assert xu._line_code({"line": 7, "isExecutable": False}) == 0
    assert xu._line_code({"column": 1, "length": 4, "executionCount": 9}) is None
    table = {"/a.swift": [0, 2, -3]}
    assert xu._line_code(table) is table
    parsed = json.loads(json.dumps({"/a.swift": lines({2, 3}, {2}, last=3)}), object_hook=xu._line_code)
    assert parsed == {"/a.swift": [0, 2, -3]}


def test_usage_errors_exit_2(xcrun):
    p = subprocess.run([sys.executable, str(SCRIPT), "--target", "VideoScan.app"], capture_output=True, text=True)
    assert p.returncode == 2
    p = subprocess.run([sys.executable, str(SCRIPT), "x.xcresult"], capture_output=True, text=True)
    assert p.returncode == 2


# ── the real bundles of the 2026-11-21 measurement (production shape; skipped when they are gone) ──
REAL = Path.home() / "Library" / "Caches" / "videoscan-nightly-shards"
SINGLE = REAL / "single.xcresult"
SHARDS = sorted((REAL / "run2").glob("[0-9][0-9][0-9][0-9]/shard.xcresult"))
real_bundles = pytest.mark.skipif(sys.platform != "darwin" or not SINGLE.is_dir() or len(SHARDS) != 16
                                  or os.environ.get("VIDEOSCAN_SKIP_REAL_BUNDLES") == "1",
                                  reason="the measured result bundles are not on this Mac")


@real_bundles
def test_real_single_host_bundle_gives_back_xcodes_own_number_and_the_line_number():
    u = xu.union([SINGLE], "VideoScan.app")
    assert len(u["files"]) == 1144
    # Xcode's report through this tool's file filter is the nightly's awk number, to the line …
    assert xu.total(u["report"], logic=True) == (189023, 261667)       # 72.238%, what the nightly logged
    assert xu.total(u["report"], logic=False) == (197376, 341680)
    # … and the same bundle in distinct lines:
    assert xu.total(u["files"], logic=True) == (157494, 199317)        # 79.017%
    assert xu.total(u["files"], logic=False) == (161454, 235354)


@real_bundles
def test_real_sixteen_shards_union_is_at_least_every_shard_in_every_file_and_close_to_one_host():
    u = xu.union(SHARDS, "VideoScan.app")
    covered, executable = xu.total(u["files"], logic=True)
    assert executable == 199317, "the denominator is the build's, not Xcode's merged 262,105"
    assert covered == 157504                                           # 79.022%; one host: 157,494
    single = xu.union([SINGLE], "VideoScan.app")["files"]
    assert {p: v[1] for p, v in single.items()} == {p: v[1] for p, v in u["files"].items()}
    for shard in (SHARDS[0], SHARDS[7], SHARDS[15]):                   # the union is a superset of each shard
        one = xu.union([shard], "VideoScan.app")["files"]
        worse = [p for p, v in one.items() if u["files"][p][0] < v[0]]
        assert not worse, worse[:3]
