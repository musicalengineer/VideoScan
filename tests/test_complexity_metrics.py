"""scripts/complexity_metrics.py: parser, aggregation and the report-only debt
ratchet. Synthetic lizard output only; nothing here scans the repo."""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import complexity_metrics as cm  # noqa: E402


def fn(name, ccn=1, nloc=5, start=1, end=None, long_name=None):
    return SimpleNamespace(name=name, long_name=long_name or name, cyclomatic_complexity=ccn,
                           nloc=nloc, start_line=start, end_line=end if end is not None else start + nloc)


def info(path, *funcs):
    return SimpleNamespace(filename=path, function_list=list(funcs))


def func(file, name, ccn, nloc, lang="swift", key=None):
    f = cm.Func(file=file, name=name, long_name=name, ccn=ccn, nloc=nloc, start_line=1, lang=lang)
    f.key = key or f"{file}::{name}"
    return f


# ---------------------------------------------------------------- parsing

def test_folder_keys_match_collect_metrics_swift_by_folder():
    assert cm.folder_of("VideoScan/VideoScan/Hallie/Web/Page.swift") == "Hallie"
    assert cm.folder_of("VideoScan/VideoScan/VideoScanApp.swift") == "(app root)"
    assert cm.folder_of("VideoScan/VideoScanCore/Sources/X/Y.swift") == "Core"
    assert cm.folder_of("swift_cli/PersonFinder.swift") == "swift_cli"
    assert cm.folder_of("scripts/hallie/x.py") == "scripts"
    assert cm.folder_of("tools/person-eval/x.py") == "tools"


def test_records_are_repo_relative_and_skip_other_languages(tmp_path):
    root = str(tmp_path)
    funcs = cm.funcs_from_lizard([
        info(f"{root}/VideoScan/VideoScan/Catalog/A.swift", fn("load", ccn=3, nloc=10)),
        info("./scripts/b.py", fn("main", ccn=20, nloc=90)),
        info("other/c.js", fn("ignored")),
        None,
    ], root)
    assert [(f.file, f.name, f.lang) for f in funcs] == [
        ("VideoScan/VideoScan/Catalog/A.swift", "load", "swift"),
        ("scripts/b.py", "main", "python"),
    ]
    assert funcs[0].key == "VideoScan/VideoScan/Catalog/A.swift::load"
    assert funcs[1].is_offender and not funcs[0].is_offender


def test_keys_have_no_line_numbers_and_disambiguate_repeats():
    src = "\n".join([
        "struct A: View {",          # 1
        "  var body: some View {",   # 2
        "  }",                       # 3
        "  init(x: Int) { }",        # 4
        "  init(y: Int) { }",        # 5
        "}",                         # 6
        "struct B: View {",          # 7
        "  var body: some View {",   # 8
        "  }",                       # 9
        "  func go() { }",           # 10
        "  func go() { }",           # 11
        "}",
    ])
    path = "VideoScan/VideoScan/X/V.swift"
    funcs = cm.funcs_from_lizard([info(path,
        fn("body", start=2, end=3), fn("init", start=4, end=4, long_name="init x : Int"),
        fn("init", start=5, end=5, long_name="init y : Int"), fn("body", start=8, end=9),
        fn("go", start=10, end=10), fn("go", start=11, end=11))], ".", {path: src})
    keys = [f.key.split("::", 1)[1] for f in funcs]
    assert keys == ["A.body", "A.init x : Int", "A.init y : Int", "B.body", "B.go#1", "B.go#2"]
    assert len(set(keys)) == len(keys)
    # Moving everything down 50 lines keeps every key.
    moved = cm.funcs_from_lizard([info(path, *[fn(f.name, start=f.start_line + 50, end=f.end_line + 50,
                                                  long_name=f.long_name) for f in funcs])],
                                 ".", {path: "\n" * 50 + src})
    assert [f.key for f in moved] == [f.key for f in funcs]


def test_nested_accessor_carries_its_property_name():
    src = "struct S {\n  var a: Int {\n    get { 1 }\n  }\n  var b: Int {\n    get { 2 }\n  }\n}\n"
    path = "VideoScan/VideoScan/X/S.swift"
    funcs = cm.funcs_from_lizard([info(path, fn("a", start=2, end=4), fn("get", start=3, end=3),
                                       fn("b", start=5, end=7), fn("get", start=6, end=6))], ".", {path: src})
    assert sorted(f.key.split("::")[1] for f in funcs) == ["S.a", "S.a.get", "S.b", "S.b.get"]
    assert {f.display for f in funcs if f.name == "get"} == {"S.a.get", "S.b.get"}


def test_containers_ignore_braces_in_strings_and_comments():
    src = 'struct Outer {\n  let s = "{{{"  // }\n  enum Inner {\n  }\n  func f() {\n  }\n}\nfunc top() {}\n'
    owners = cm.containers_for(src, "swift")
    assert owners[5] == "Outer"           # func f, after the nested enum closed
    assert owners[8] == ""                # top-level func
    py = "class A:\n    def f(self):\n        pass\n\ndef g():\n    pass\n"
    owners = cm.containers_for(py, "python")
    assert owners[2] == "A" and owners[5] == ""


def test_swift_computed_properties_are_functions_with_real_lizard():
    lizard = pytest.importorskip("lizard")
    cm.install_swift_property_support()
    src = "\n".join([
        "struct A: View {",
        "  @State var x: Int",
        "  var y = 3",
        "  var body: some View {",
        "    if a { b() } else if c { d() }",
        "  }",
        "  func f() {",
        "    for var i in xs { if i {} }",
        "    var r: String",
        "    if t { r = \"\" }",
        "  }",
        "}",
    ])
    result = lizard.analyze_file.analyze_source_code("a.swift", src)
    by_name = {f.name: f for f in result.function_list}
    assert set(by_name) == {"body", "f"}         # x, y, i, r are not functions
    assert by_name["body"].cyclomatic_complexity == 3
    assert by_name["f"].cyclomatic_complexity == 4


# ---------------------------------------------------------------- aggregation

def test_aggregate_per_folder_and_totals():
    funcs = [func("VideoScan/VideoScan/Hallie/A.swift", "a", 20, 10),
             func("VideoScan/VideoScan/Hallie/A.swift", "b", 2, 100),
             func("VideoScan/VideoScan/Hallie/B.swift", "c", 2, 10),
             func("scripts/x.py", "main", 16, 81, lang="python")]
    lines = {"VideoScan/VideoScan/Hallie/A.swift": 900, "VideoScan/VideoScan/Hallie/B.swift": 100,
             "VideoScan/VideoScan/Shared/Empty.swift": 801, "scripts/x.py": 50}
    agg = cm.aggregate(funcs, lines)
    hallie = agg["swift_by_folder"]["Hallie"]
    assert hallie == {"files": 2, "functions": 3, "ccn_over_15": 1, "ccn_over_30": 0, "nloc_over_80": 1,
                      "offenders": 2, "files_over_800": 1, "mean_ccn": 8.0}
    assert agg["swift_by_folder"]["Shared"]["mean_ccn"] is None       # no functions: no fake zero
    assert agg["swift_by_folder"]["Shared"]["files_over_800"] == 1
    assert agg["python_by_folder"]["scripts"]["offenders"] == 1
    assert agg["totals"]["all"]["functions"] == 4 and agg["totals"]["all"]["offenders"] == 3
    assert agg["totals"]["all"]["files_over_800"] == 2


def test_top_worst_orders_by_ccn_then_nloc_and_caps():
    funcs = [func("a.swift", f"f{i}", ccn=i % 7, nloc=i) for i in range(40)]
    top = cm.top_worst(funcs)
    assert len(top) == 15
    assert [t["ccn"] for t in top] == sorted((t["ccn"] for t in top), reverse=True)
    assert set(top[0]) == {"file", "function", "ccn", "nloc", "lang"}


# ---------------------------------------------------------------- ratchet

def test_ratchet_new_worse_fixed_and_shrink_only():
    baseline = {"a.swift::keep": {"ccn": 20, "nloc": 50},
                "a.swift::worse_ccn": {"ccn": 20, "nloc": 50},
                "a.swift::worse_nloc": {"ccn": 5, "nloc": 100},
                "a.swift::jitter": {"ccn": 5, "nloc": 100},
                "a.swift::improved": {"ccn": 30, "nloc": 200},
                "a.swift::gone": {"ccn": 18, "nloc": 10},
                "a.swift::now_fine": {"ccn": 18, "nloc": 10}}
    funcs = [func("a.swift", "keep", 20, 50),
             func("a.swift", "worse_ccn", 21, 50),
             func("a.swift", "worse_nloc", 5, 111),       # +11 > max(5, 10)
             func("a.swift", "jitter", 5, 110),           # +10 is within tolerance
             func("a.swift", "improved", 25, 150),
             func("a.swift", "now_fine", 15, 80),         # at the limits = not an offender
             func("a.swift", "brand_new", 16, 3),
             func("a.swift", "harmless", 3, 3)]
    r = cm.ratchet(funcs, baseline)
    assert [f.name for f in r["new"]] == ["brand_new"]
    assert sorted(f.name for f in r["worse"]) == ["worse_ccn", "worse_nloc"]
    assert r["fixed"] == ["a.swift::gone", "a.swift::now_fine"]
    nxt = r["next_baseline"]
    assert "a.swift::brand_new" not in nxt                      # never grows on its own
    assert "a.swift::gone" not in nxt and "a.swift::now_fine" not in nxt
    assert nxt["a.swift::improved"] == {"ccn": 25, "nloc": 150}  # ratchets down
    assert nxt["a.swift::worse_ccn"] == {"ccn": 20, "nloc": 50}  # never raised: keeps nagging
    assert r["shrink_skipped"] is None


def test_ratchet_follows_a_moved_offender_instead_of_new_plus_fixed():
    baseline = {"old.swift::T.big": {"ccn": 30, "nloc": 100}}
    f = func("new.swift", "big", 28, 104, key="new.swift::U.big")
    r = cm.ratchet([f], baseline)
    assert r["new"] == [] and r["fixed"] == [] and r["moved"] == {"new.swift::U.big": "old.swift::T.big"}
    assert r["next_baseline"] == {"new.swift::U.big": {"ccn": 28, "nloc": 100}}
    grown = func("new.swift", "big", 31, 100, key="new.swift::U.big")
    r = cm.ratchet([grown], baseline)
    assert [x.key for x in r["new"]] == ["new.swift::U.big"] and r["fixed"] == ["old.swift::T.big"]


def test_shrink_guard_keeps_baseline_when_most_of_it_vanishes():
    baseline = {f"a.swift::f{i}": {"ccn": 20, "nloc": 10} for i in range(40)}
    r = cm.ratchet([func("a.swift", "f0", 20, 10)], baseline)
    assert r["shrink_skipped"] and len(r["fixed"]) == 39
    assert r["next_baseline"] == baseline
    r = cm.ratchet([], baseline)
    assert "nothing" in r["shrink_skipped"] and r["next_baseline"] == baseline


def test_baseline_round_trip_and_debt_report(tmp_path):
    path = tmp_path / "b.json"
    cm.write_baseline(str(path), {"x.swift::f": {"ccn": 30, "nloc": 90}})
    data = json.loads(path.read_text())
    assert data["entry_count"] == 1 and data["thresholds"] == {"ccn": 15, "nloc": 80}
    base = cm.load_baseline(str(path))
    assert base == {"x.swift::f": {"ccn": 30, "nloc": 90}}
    assert cm.load_baseline(str(tmp_path / "missing.json")) == {}
    funcs = [func("x.swift", "f", 31, 90), func("x.swift", "g", 40, 10)]
    r = cm.ratchet(funcs, base)
    debt = cm.debt_report(r, base, 2, "2026-10-05T05:00:00Z", "abcd1234")
    assert [d["key"] for d in debt["new"]] == ["x.swift::g"]
    assert debt["worse"][0]["base_ccn"] == 30 and debt["worse"][0]["ccn"] == 31
    row = cm.build_row(funcs, {"x.swift": 10}, debt, debt["ts"], debt["sha"], "1.22.1")
    assert (row["debt_new"], row["debt_worse"], row["debt_fixed"], row["debt_offenders"]) == (1, 1, 0, 2)
    assert row["totals"]["swift"]["functions"] == 2
    json.dumps(row)                                               # serialisable


def test_alert_lines_quiet_when_clean_and_loud_when_not(capsys, monkeypatch):
    assert cm.alert_lines({"new": [], "worse": [], "fixed": []}) == []
    debt = {"ts": "2026-10-05T05:00:00Z", "fixed": ["a::b"],
            "new": [{"file": "VideoScan/VideoScan/X/A.swift", "function": "A.big", "ccn": 22, "nloc": 40}],
            "worse": [{"file": "scripts/b.py", "function": "main", "ccn": 30, "nloc": 90,
                       "base_ccn": 25, "base_nloc": 90}]}
    lines = cm.alert_lines(debt)
    assert "1 NEW" in lines[0] and "1 got worse" in lines[0]
    assert any("A.swift :: A.big" in l for l in lines)
    assert any("was 25/90" in l for l in lines)
    assert any("1 baseline offender(s) fixed" in l for l in lines)
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(debt)))
    assert cm.main(["--alert", "-"]) == 0
    assert "NEW offender" in capsys.readouterr().out
    monkeypatch.setattr(sys, "stdin", io.StringIO("not json"))
    assert cm.main(["--alert", "-"]) == 0                         # never breaks the digest


def test_count_disables_only_guarded_rules_and_only_swift():
    src = ("// swiftlint:disable:next cyclomatic_complexity function_body_length\n"
           "// swiftlint:disable file_length\n"
           "// swiftlint:disable:next force_cast\n")
    assert cm.count_disables("a.swift", src) == {"a.swift|cyclomatic_complexity": 1,
                                                 "a.swift|function_body_length": 1,
                                                 "a.swift|file_length": 1}
    assert cm.count_disables("a.py", src) == {}


def test_disable_baseline_only_shrinks(tmp_path):
    base = {"a.swift|file_length": 2, "b.swift|file_length": 1}
    assert cm.shrink_disables(base, {"a.swift|file_length": 1}) == {"a.swift|file_length": 1}
    path = tmp_path / "b.json"
    cm.write_baseline(str(path), {}, base)
    assert cm.load_disables(str(path)) == base


def test_scope_excludes_tests_build_dirs_and_venvs():
    assert cm.in_scope("VideoScan/VideoScan/Catalog/A.swift")
    assert cm.in_scope("VideoScan/VideoScanCore/Sources/X/A.swift")
    # App code only (Rick 2026-10-06): support scripts and test beds are out of scope.
    assert not cm.in_scope("tools/person-eval/a.py")
    assert not cm.in_scope("scripts/hallie_eval.py")
    for p in ["VideoScan/VideoScanTests/A.swift", "VideoScan/VideoScanCore/.build/checkouts/x/A.swift",
              "tools/venv-mlx/lib/a.py", "scripts/a.sh", "other/a.py"]:
        assert not cm.in_scope(p), p


def test_markdown_report_lists_new_and_top15():
    funcs = [func("x.swift", "g", 40, 10)]
    r = cm.ratchet(funcs, {})
    debt = cm.debt_report(r, {}, 1, "t", "s")
    row = cm.build_row(funcs, {"x.swift": 10}, debt, "t", "s", None)
    md = cm.markdown_report(row, debt)
    assert "1 new" in md and "x.swift :: g" in md and "| 1 | 40 | 10 | `g` | `x.swift` |" in md
