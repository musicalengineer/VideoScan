"""RED: a removals-only nightly shrink must not turn CI's --all gate red on the
same tree (QA re-review, feat/nightly-complexity-metrics @ 082a9eae)."""
from __future__ import annotations
import sys
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
pytest.importorskip("lizard")
import complexity_gate as gate  # noqa: E402
import complexity_metrics as cm  # noqa: E402

OLD = "VideoScan/VideoScan/Catalog/Old.swift"
MOVED = "VideoScan/VideoScan/Catalog/Moved.swift"
OTHER = "VideoScan/VideoScan/Catalog/Other.swift"


def long_low_ccn(name: str, lines: int) -> str:      # NLOC over the gate, CCN 1
    body = "\n".join(f"        r += {i}" for i in range(lines))
    return f"struct M {{\n    func {name}() -> Int {{\n        var r = 0\n{body}\n        return r\n    }}\n}}\n"


def mid_ccn(name: str, ccn: int) -> str:             # report-level offender, under the gate
    body = "\n".join(f"        if x == {i} {{ r += {i} }}" for i in range(ccn - 1))
    return f"struct O {{\n    func {name}(x: Int) -> Int {{\n        var r = 0\n{body}\n        return r\n    }}\n}}\n"


def test_nightly_shrink_after_a_move_keeps_the_whole_tree_gate_green(tmp_path):
    tree = {MOVED: long_low_ccn("body", 320), OTHER: mid_ccn("body", 20)}
    funcs, _ = cm.analyze_sources(tree)
    big = next(f for f in funcs if f.file == MOVED)
    base_path = str(tmp_path / "b.json")
    cm.write_baseline(base_path, {f"{OLD}::body": {"ccn": 25, "nloc": big.nloc}})
    ov = str(tmp_path / "ov.jsonl")
    # Before the shrink: the move passes CI (complexity_gate.py function_violations).
    assert gate.run_gate(tree, base_path, ov, record_override=False, out=lambda s: None) == 0
    # The 2 AM shrink (complexity_metrics.py ratchet -> match_moves pairs the old key with
    # OTHER's CCN-20 body, sorted by CCN first; strict_shrink lowers it to ~20 lines).
    result = cm.ratchet(funcs, cm.load_baseline(base_path))
    shrunk = cm.strict_shrink(cm.load_baseline(base_path), result)
    assert not cm.verify_removals_only(cm.load_baseline(base_path), shrunk, {}, {})  # "pure" shrink
    cm.write_baseline(base_path, shrunk, {})
    lines = []
    assert gate.run_gate(tree, base_path, ov, record_override=False, out=lines.append) == 0, "\n".join(lines)


# ---------------------------------------------------------------- CCN 15 count baseline (2026-10-07)

def test_ccn15_count_shrinks_when_a_band_function_is_fixed_and_ci_stays_green(tmp_path):
    tree = {OTHER: mid_ccn("body", 20), MOVED: mid_ccn("fixed", 12)}
    funcs, _ = cm.analyze_sources(tree)
    counts = str(tmp_path / "c.json")
    cm.write_ccn15_counts(counts, 2, {OTHER: 1, MOVED: 1})
    plan = cm.ccn15_shrink_plan(str(tmp_path), counts, str(tmp_path / "ov.jsonl"), funcs=funcs)
    assert plan["changed"] and not plan["problems"]
    assert (plan["before"], plan["after"]) == (2, 1) and plan["files"] == {OTHER: 1}
    cm.write_ccn15_counts(counts, plan["after"], plan["files"])
    lines = []
    assert gate.run_gate(tree, str(tmp_path / "b.json"), str(tmp_path / "ov.jsonl"), record_override=False,
                         out=lines.append, counts_path=counts) == 0, "\n".join(lines)


def test_ccn15_count_never_grows_by_shrinking(tmp_path):
    tree = {OTHER: mid_ccn("body", 20), MOVED: mid_ccn("extra", 18)}
    funcs, _ = cm.analyze_sources(tree)
    counts = str(tmp_path / "c.json")
    cm.write_ccn15_counts(counts, 1, {OTHER: 1})
    plan = cm.ccn15_shrink_plan(str(tmp_path), counts, str(tmp_path / "ov.jsonl"), funcs=funcs)
    assert not plan["changed"] and plan["after"] == 1


def test_ccn15_count_regenerate_command_writes_todays_count(tmp_path):
    src = tmp_path / "VideoScan" / "VideoScan" / "Catalog"
    src.mkdir(parents=True)
    (src / "Other.swift").write_text(mid_ccn("body", 20) + mid_ccn("small", 3).replace("struct O", "struct P"))
    out = tmp_path / "c.json"
    assert cm.main(["--root", str(tmp_path), "--update-ccn15-counts", "--ccn15-counts", str(out)]) == 0
    data = cm.load_ccn15_counts(str(out))
    assert data["total"] == 1 and data["files"] == {OTHER: 1}


def test_ccn15_count_shrink_refuses_an_empty_scan(tmp_path):
    counts = str(tmp_path / "c.json")
    cm.write_ccn15_counts(counts, 300, {})
    plan = cm.ccn15_shrink_plan(str(tmp_path), counts, str(tmp_path / "ov.jsonl"), funcs=[])
    assert plan["problems"] and not plan["changed"]
