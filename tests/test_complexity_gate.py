"""scripts/complexity_gate.py (GH #281): the BLOCKING complexity gate used by
the pre-commit hook (staged files) and CI preflight (whole tree). Synthetic
sources and baselines only; nothing here scans the repo or touches git."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

pytest.importorskip("lizard")

import complexity_gate as gate  # noqa: E402
import complexity_metrics as cm  # noqa: E402

PATH = "VideoScan/VideoScan/Catalog/Synthetic.swift"
NOW = datetime(2026, 10, 5, 18, 0, tzinfo=timezone.utc)


def swift_func(name: str, ccn: int) -> str:
    """A Swift function whose lizard CCN is exactly `ccn` (1 + one per `if`)."""
    body = "\n".join(f"        if x == {i} {{ r += {i} }}" for i in range(ccn - 1))
    return f"    func {name}(x: Int) -> Int {{\n        var r = 0\n{body}\n        return r\n    }}\n"


def source(*funcs: str, extra: str = "") -> str:
    return "struct Synthetic {\n" + extra + "".join(funcs) + "}\n"


def write_baseline(tmp_path, entries=None, disables=None) -> str:
    path = tmp_path / "complexity_debt.json"
    cm.write_baseline(str(path), entries or {}, disables or {})
    return str(path)


def run(tmp_path, text, baseline, reason="", path=PATH):
    lines = []
    overrides = str(tmp_path / "complexity_overrides.jsonl")
    code = gate.run_gate({path: text}, baseline, overrides, override_reason=reason,
                         out=lines.append, now=NOW)
    return code, "\n".join(lines), overrides


def test_synthetic_function_has_the_ccn_we_think():
    funcs, _ = cm.analyze_sources({PATH: source(swift_func("big", 35))})
    assert [(f.key, f.display, f.ccn) for f in funcs] == [(f"{PATH}::big", "Synthetic.big", 35)]


def test_new_offender_over_the_gate_is_blocked(tmp_path):
    code, out, overrides = run(tmp_path, source(swift_func("big", 35)), write_baseline(tmp_path))
    assert code == 1
    assert "BLOCKED  CCN  35" in out and "Synthetic.big" in out and "NEW function over the gate" in out
    assert "COMPLEXITY_OVERRIDE" in out                     # one line on what to do
    assert not Path(overrides).exists()                     # nothing recorded without an override


def test_unchanged_known_offender_passes_so_its_file_can_be_edited(tmp_path):
    base = write_baseline(tmp_path, {f"{PATH}::big": {"ccn": 35, "nloc": 40}})
    code, out, _ = run(tmp_path, source(swift_func("big", 35), swift_func("small", 2)), base)
    assert code == 0, out
    assert "OK" in out


def test_known_offender_that_got_worse_is_blocked(tmp_path):
    base = write_baseline(tmp_path, {f"{PATH}::big": {"ccn": 35, "nloc": 40}})
    code, out, _ = run(tmp_path, source(swift_func("big", 36)), base)
    assert code == 1 and "got WORSE (baseline CCN 35" in out


def test_known_offender_may_not_grow_past_the_line_slack(tmp_path):
    funcs, _ = cm.analyze_sources({PATH: source(swift_func("big", 35))})
    nloc = funcs[0].nloc
    base = write_baseline(tmp_path, {f"{PATH}::big": {"ccn": 40, "nloc": nloc - gate.NLOC_SLACK}})
    assert run(tmp_path, source(swift_func("big", 35)), base)[0] == 0          # within slack
    base = write_baseline(tmp_path, {f"{PATH}::big": {"ccn": 40, "nloc": nloc - gate.NLOC_SLACK - 1}})
    assert run(tmp_path, source(swift_func("big", 35)), base)[0] == 1          # one line too many


def test_functions_between_report_and_gate_limits_pass(tmp_path):
    code, _, _ = run(tmp_path, source(swift_func("medium", 25)), write_baseline(tmp_path))
    assert code == 0                                       # the nightly reports these; the gate does not block


def test_new_swiftlint_disable_is_blocked_and_grandfathered_ones_pass(tmp_path):
    disable = "    // swiftlint:disable:next cyclomatic_complexity function_body_length\n"
    base = write_baseline(tmp_path)
    code, out, _ = run(tmp_path, source(swift_func("f", 2), extra=disable), base)
    assert code == 1
    assert "swiftlint:disable cyclomatic_complexity" in out and "swiftlint:disable function_body_length" in out
    base = write_baseline(tmp_path, disables={f"{PATH}|cyclomatic_complexity": 1,
                                              f"{PATH}|function_body_length": 1})
    assert run(tmp_path, source(swift_func("f", 2), extra=disable), base)[0] == 0
    # A second one in the same file is new again.
    assert run(tmp_path, source(swift_func("f", 2), extra=disable * 2), base)[0] == 1
    # Other rules are not the gate's business.
    plain = "    // swiftlint:disable:next force_cast\n"
    assert run(tmp_path, source(swift_func("f", 2), extra=plain), write_baseline(tmp_path))[0] == 0


def test_override_passes_and_is_logged_then_honored_by_ci(tmp_path):
    base = write_baseline(tmp_path)
    text = source(swift_func("big", 35))
    code, out, overrides = run(tmp_path, text, base, reason="hotfix for Rick, split in #282")
    assert code == 0
    assert "BLOCKED  CCN  35" in out                       # still shown, never silent
    assert 'OVERRIDDEN — "hotfix for Rick, split in #282"' in out
    rec = json.loads(Path(overrides).read_text().strip())
    assert rec["reason"] == "hotfix for Rick, split in #282" and rec["ts"] == "2026-10-05T18:00:00Z"
    assert rec["functions"] == {f"{PATH}::big": {"ccn": 35, "nloc": rec["functions"][f"{PATH}::big"]["nloc"]}}
    # CI (no override env) honors the recorded override at its recorded size ...
    lines = []
    assert gate.run_gate({PATH: text}, base, overrides, out=lines.append, record_override=False) == 0
    # ... but growing it further blocks again.
    assert gate.run_gate({PATH: source(swift_func("big", 36))}, base, overrides,
                         out=lines.append, record_override=False) == 1
    # And the nightly reports it in the morning digest.
    recent = cm.recent_overrides(cm.load_overrides(overrides), NOW)
    assert recent and recent[0]["reason"] == "hotfix for Rick, split in #282"
    lines = cm.alert_lines({"new": [], "worse": [], "fixed": [], "overrides_recent": recent})
    assert any("OVERRIDDEN" in l and "split in #282" in l for l in lines)


def test_blank_override_reason_does_not_override(tmp_path):
    code, _, overrides = run(tmp_path, source(swift_func("big", 35)), write_baseline(tmp_path), reason="   ")
    assert code == 1 and not Path(overrides).exists()


def test_out_of_scope_files_are_ignored(tmp_path):
    for path in ["VideoScan/VideoScanTests/BigTests.swift", "other/x.swift", "scripts/venv/lib/x.py"]:
        assert run(tmp_path, source(swift_func("big", 35)), write_baseline(tmp_path), path=path)[0] == 0, path
