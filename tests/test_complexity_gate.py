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


KNOWN35 = {f"{PATH}::Synthetic.big": {"ccn": 35, "nloc": 40}}
# The key format before 2026-10-05 QA fix; a baseline written then must still match.
LEGACY35 = {f"{PATH}::big": {"ccn": 35, "nloc": 40}}


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
    assert [(f.key, f.display, f.ccn) for f in funcs] == [(f"{PATH}::Synthetic.big", "Synthetic.big", 35)]


def test_new_offender_over_the_gate_is_blocked(tmp_path):
    code, out, overrides = run(tmp_path, source(swift_func("big", 35)), write_baseline(tmp_path))
    assert code == 1
    assert "BLOCKED  CCN  35" in out and "Synthetic.big" in out and "NEW function over the gate" in out
    assert "COMPLEXITY_OVERRIDE" in out                     # one line on what to do
    assert not Path(overrides).exists()                     # nothing recorded without an override


def test_unchanged_known_offender_passes_so_its_file_can_be_edited(tmp_path):
    base = write_baseline(tmp_path, KNOWN35)
    code, out, _ = run(tmp_path, source(swift_func("big", 35), swift_func("small", 2)), base)
    assert code == 0, out
    assert "OK" in out


def test_known_offender_that_got_worse_is_blocked(tmp_path):
    base = write_baseline(tmp_path, KNOWN35)
    code, out, _ = run(tmp_path, source(swift_func("big", 36)), base)
    assert code == 1 and "got WORSE (baseline CCN 35" in out


def test_known_offender_may_not_grow_past_the_line_slack(tmp_path):
    funcs, _ = cm.analyze_sources({PATH: source(swift_func("big", 35))})
    nloc = funcs[0].nloc
    base = write_baseline(tmp_path, {f"{PATH}::Synthetic.big": {"ccn": 40, "nloc": nloc - gate.NLOC_SLACK}})
    assert run(tmp_path, source(swift_func("big", 35)), base)[0] == 0          # within slack
    base = write_baseline(tmp_path, {f"{PATH}::Synthetic.big": {"ccn": 40, "nloc": nloc - gate.NLOC_SLACK - 1}})
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
    assert 'OVERRIDDEN by unknown author — "hotfix for Rick, split in #282"' in out and '🔴' in out
    rec = json.loads(Path(overrides).read_text().strip())
    assert rec["reason"] == "hotfix for Rick, split in #282" and rec["ts"] == "2026-10-05T18:00:00Z"
    assert list(rec["functions"]) == [f"{PATH}::Synthetic.big"] and rec["functions"][f"{PATH}::Synthetic.big"]["ccn"] == 35
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


# ---------------------------------------------------------------- refactors that add no debt
# QA review 2026-10-05: moving or keeping an offender without growing it must pass.

MOVED_TO = "VideoScan/VideoScan/Catalog/CatalogRowContextMenu.swift"


def _gate(tmp_path, sources, base):
    lines = []
    code = gate.run_gate(sources, base, str(tmp_path / "ov.jsonl"), out=lines.append, record_override=False)
    return code, "\n".join(lines)


def test_offender_moved_unchanged_to_a_new_file_passes(tmp_path):
    # complexity_gate.py:85 keys by file::name -> moved function reads as NEW.
    base = write_baseline(tmp_path, LEGACY35)
    code, out = _gate(tmp_path, {PATH: source(swift_func("small", 2)),
                                 MOVED_TO: source(swift_func("big", 35))}, base)
    assert code == 0, out


def test_offender_moved_and_made_smaller_passes(tmp_path):
    base = write_baseline(tmp_path, LEGACY35)
    code, out = _gate(tmp_path, {MOVED_TO: source(swift_func("big", 32))}, base)
    assert code == 0, out


def test_adding_a_small_namesake_does_not_rekey_the_untouched_offender(tmp_path):
    # complexity_metrics.py:204-207: a second `body`/`big` anywhere in the file
    # flips the offender's key from file::big to file::Synthetic.big -> NEW.
    base = write_baseline(tmp_path, LEGACY35)
    text = source(swift_func("big", 35)) + "struct Other {\n" + swift_func("big", 2) + "}\n"
    code, out = _gate(tmp_path, {PATH: text}, base)
    assert code == 0, out


def test_swiftlint_disable_moved_with_its_function_passes(tmp_path):
    # complexity_gate.py:96: disable allowance is per file, so carrying the
    # grandfathered disable:next to the new file blocks.
    d = "    // swiftlint:disable:next cyclomatic_complexity\n"
    base = write_baseline(tmp_path, LEGACY35,
                          {f"{PATH}|cyclomatic_complexity": 1})
    code, out = _gate(tmp_path, {PATH: source(swift_func("small", 2)),
                                 MOVED_TO: source(swift_func("big", 35), extra=d)}, base)
    assert code == 0, out


def test_copying_an_offender_is_not_a_move(tmp_path):
    # The original is still in its (untouched) file: the copy is NEW debt.
    base = write_baseline(tmp_path, KNOWN35)
    lines = []
    code = gate.run_gate({MOVED_TO: source(swift_func("big", 35))}, base, str(tmp_path / "ov.jsonl"),
                         out=lines.append, record_override=False,
                         read_untouched=lambda p: source(swift_func("big", 35)) if p == PATH else None)
    assert code == 1 and "NEW function over the gate" in "\n".join(lines)


def test_moved_and_grown_is_still_blocked(tmp_path):
    base = write_baseline(tmp_path, LEGACY35)
    lines = []
    code = gate.run_gate({PATH: source(swift_func("small", 2)), MOVED_TO: source(swift_func("big", 36))},
                         base, str(tmp_path / "ov.jsonl"), out=lines.append, record_override=False)
    assert code == 1


def test_whole_tree_mode_refuses_an_empty_listing(tmp_path):
    lines = []
    assert gate.run_gate({}, write_baseline(tmp_path), str(tmp_path / "ov.jsonl"), out=lines.append,
                         record_override=False, min_files=500) == 1
    assert "Refusing" in lines[0]


# ---------------------------------------------------------------- CCN 15 "no-worse" ratchet
# Rick 2026-10-07: functions over CCN 15 went 277 -> 345 in ten nights while
# the count over 30 stayed flat. Pre-commit compares HEAD with the staged copy
# of the touched files; CI compares the whole tree with a committed count.

SPLIT_TO = "VideoScan/VideoScan/Catalog/SyntheticParts.swift"


def _ratchet(tmp_path, after, before, reason="", base=None):
    lines = []
    ov = str(tmp_path / "ov.jsonl")
    code = gate.run_gate(after, base or write_baseline(tmp_path), ov, override_reason=reason,
                         out=lines.append, now=NOW, before=before)
    return code, "\n".join(lines), ov


def test_ratchet_new_function_over_15_in_a_new_file_blocks(tmp_path):
    code, out, ov = _ratchet(tmp_path, {PATH: source(swift_func("medium", 20))}, {PATH: ""})
    assert code == 1, out
    assert "RATCHET" in out and "Synthetic.medium" in out and "CCN  20" in out
    assert "0 -> 1" in out                                   # the count that rose
    assert "real concept" in out and "step1/step2" in out     # how to fix it, and how not to
    assert not Path(ov).exists()


def test_ratchet_new_function_over_15_in_an_existing_file_blocks(tmp_path):
    before = {PATH: source(swift_func("small", 2))}
    after = {PATH: source(swift_func("small", 2), swift_func("medium", 16))}
    code, out, _ = _ratchet(tmp_path, after, before)
    assert code == 1 and "RATCHET" in out and "Synthetic.medium" in out


def test_ratchet_function_rising_into_the_band_blocks(tmp_path):
    code, out, _ = _ratchet(tmp_path, {PATH: source(swift_func("f", 16))}, {PATH: source(swift_func("f", 15))})
    assert code == 1 and "RATCHET" in out


def test_ratchet_existing_band_function_rising_blocks(tmp_path):
    code, out, _ = _ratchet(tmp_path, {PATH: source(swift_func("medium", 21))},
                            {PATH: source(swift_func("medium", 20))})
    assert code == 1, out
    assert "RATCHET-WORSE" in out and "from 20" in out and "Synthetic.medium" in out


def test_ratchet_lowering_or_leaving_a_band_function_passes(tmp_path):
    before = {PATH: source(swift_func("medium", 20), swift_func("small", 2))}
    lowered = {PATH: source(swift_func("medium", 18), swift_func("small", 2))}
    untouched = {PATH: source(swift_func("medium", 20), swift_func("small", 5))}
    for after in (lowered, untouched):
        code, out, _ = _ratchet(tmp_path, after, before)
        assert code == 0, out


def test_ratchet_moving_a_band_function_between_touched_files_passes(tmp_path):
    before = {PATH: source(swift_func("medium", 20), swift_func("small", 2)), MOVED_TO: source(swift_func("x", 2))}
    after = {PATH: source(swift_func("small", 2)), MOVED_TO: source(swift_func("x", 2), swift_func("medium", 20))}
    code, out, _ = _ratchet(tmp_path, after, before)
    assert code == 0, out


def test_ratchet_moved_and_grown_band_function_blocks(tmp_path):
    before = {PATH: source(swift_func("medium", 20)), MOVED_TO: ""}
    after = {PATH: "", MOVED_TO: source(swift_func("medium", 22))}
    code, out, _ = _ratchet(tmp_path, after, before)
    assert code == 1 and "RATCHET-WORSE" in out


def test_ratchet_splitting_a_file_passes(tmp_path):
    whole = source(swift_func("a", 20), swift_func("b", 18), swift_func("c", 17), swift_func("d", 2))
    # Part of it moves out ...
    code, out, _ = _ratchet(tmp_path, {PATH: source(swift_func("a", 20), swift_func("d", 2)),
                                       SPLIT_TO: source(swift_func("b", 18), swift_func("c", 17))},
                            {PATH: whole, SPLIT_TO: ""})
    assert code == 0, out
    # ... or the file is replaced by two new ones.
    code, out, _ = _ratchet(tmp_path, {PATH: "", MOVED_TO: source(swift_func("a", 20), swift_func("b", 18)),
                                       SPLIT_TO: source(swift_func("c", 17), swift_func("d", 2))},
                            {PATH: whole, MOVED_TO: "", SPLIT_TO: ""})
    assert code == 0, out


def test_ratchet_override_passes_and_is_recorded(tmp_path):
    code, out, ov = _ratchet(tmp_path, {PATH: source(swift_func("medium", 20))}, {PATH: ""},
                             reason="demo tonight, split tomorrow")
    assert code == 0
    assert "RATCHET" in out and "OVERRIDDEN" in out                # still shown, never silent
    rec = json.loads(Path(ov).read_text().strip())
    assert rec["reason"] == "demo tonight, split tomorrow"
    key = f"{PATH}::Synthetic.medium"
    assert list(rec["functions"]) == [key] and rec["functions"][key]["ccn"] == 20
    # The morning digest shows it like any other override.
    recent = cm.recent_overrides(cm.load_overrides(ov), NOW)
    assert any("OVERRIDDEN" in l and "split tomorrow" in l for l in cm.alert_lines(
        {"new": [], "worse": [], "fixed": [], "overrides_recent": recent}))


def test_ratchet_is_off_without_a_before_picture(tmp_path):
    # Callers that give neither `before` nor a count baseline get the old gate only.
    code, _, _ = run(tmp_path, source(swift_func("medium", 25)), write_baseline(tmp_path))
    assert code == 0


# --- CI side (--all): the committed whole-tree count

def _counts(tmp_path, total, files=None):
    path = str(tmp_path / "ccn15.json")
    cm.write_ccn15_counts(path, total, files or {})
    return path


def _all(tmp_path, tree, counts_path, overrides=None):
    lines = []
    code = gate.run_gate(tree, write_baseline(tmp_path), overrides or str(tmp_path / "none.jsonl"),
                         out=lines.append, record_override=False, counts_path=counts_path)
    return code, "\n".join(lines)


def test_ci_count_at_baseline_passes_and_one_more_blocks(tmp_path):
    tree = {PATH: source(swift_func("a", 20), swift_func("b", 2))}
    assert _all(tmp_path, tree, _counts(tmp_path, 1, {PATH: 1}))[0] == 0
    tree[MOVED_TO] = source(swift_func("c", 16))
    code, out = _all(tmp_path, tree, _counts(tmp_path, 1, {PATH: 1}))
    assert code == 1
    assert "RATCHET" in out and MOVED_TO in out                    # names the file that grew


def test_ci_count_lets_a_function_move_between_files(tmp_path):
    tree = {PATH: source(swift_func("b", 2)), MOVED_TO: source(swift_func("a", 20))}
    assert _all(tmp_path, tree, _counts(tmp_path, 1, {PATH: 1}))[0] == 0


def test_ci_count_honors_a_recorded_override_at_its_size(tmp_path):
    code, _, ov = _ratchet(tmp_path, {PATH: source(swift_func("medium", 20))}, {PATH: ""}, reason="why")
    assert code == 0
    assert _all(tmp_path, {PATH: source(swift_func("medium", 20))}, _counts(tmp_path, 0), ov)[0] == 0
    assert _all(tmp_path, {PATH: source(swift_func("medium", 21))}, _counts(tmp_path, 0), ov)[0] == 1


def test_ci_count_missing_baseline_fails_closed(tmp_path):
    code, out = _all(tmp_path, {PATH: source(swift_func("b", 2))}, str(tmp_path / "missing.json"))
    assert code == 1 and "update-ccn15-counts" in out
