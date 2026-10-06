"""Morning Hallie-eval alarm (2026-10-06): decline-rate jump and NEW decline
reason rules, reason normalisation, and the file-reading main(). Synthetic
numbers only — never Rick's logs."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("hallie_eval_alert", ROOT / "scripts" / "hallie_eval_alert.py")
alert = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alert)


def turn(declined=False, basis="", answer="An answer.", flags=()):
    r = {"answer": answer, "basis": basis, "flags": list(flags)}
    if declined:
        r["outcome"] = "declined"
    return r


def run(n=100, declines=None, flagged=0):
    """n turns; `declines` maps basis -> count; `flagged` turns carry a defect."""
    recs = []
    for basis, count in (declines or {}).items():
        recs += [turn(True, basis, flags=["declined_expected_answer"]) for _ in range(count)]
    recs += [turn(flags=["terse"]) for _ in range(flagged)]
    recs += [turn() for _ in range(n - len(recs))]
    return recs


def lines(today, prev, **kw):
    return alert.alert_lines(alert.summarize(today), alert.summarize(prev) if prev is not None else None, **kw)


def reds(out):
    return [l for l in out if l.startswith("🔴")]


def test_quiet_night_prints_only_the_numbers_line():
    out = lines(run(declines={"Basis: no matching catalog evidence.": 20}),
                run(declines={"Basis: no matching catalog evidence.": 19}))
    assert reds(out) == []
    assert len(out) == 1
    assert "declines 20.0% (+1.0) of 100" in out[0]
    assert "20× no matching catalog evidence" in out[0]


def test_jump_over_five_points_is_red():
    out = lines(run(declines={"Basis: a.": 26}), run(declines={"Basis: a.": 20}))
    assert len(reds(out)) == 1 and "20.0% → 26.0% (+6.0 pts" in reds(out)[0]


def test_jump_of_exactly_five_points_is_not_red():
    assert reds(lines(run(declines={"Basis: a.": 25}), run(declines={"Basis: a.": 20}))) == []


def test_drop_is_never_red():
    assert reds(lines(run(declines={"Basis: a.": 5}), run(declines={"Basis: a.": 30}))) == []


def test_new_reason_at_threshold_is_red_even_without_a_rate_jump():
    out = lines(run(declines={"Basis: a.": 15, "Basis: profile evidence could not be read.": 5}),
                run(declines={"Basis: a.": 18}))
    r = reds(out)
    assert len(r) == 1 and "NEW decline reason on 5 questions" in r[0]
    assert "profile evidence could not be read" in r[0]


def test_new_reason_below_threshold_is_noise():
    assert reds(lines(run(declines={"Basis: a.": 20, "Basis: one-off thing.": 4}),
                      run(declines={"Basis: a.": 20}))) == []


def test_first_night_has_no_comparison_and_no_red():
    out = lines(run(declines={"Basis: a.": 90}), None)
    assert reds(out) == [] and "(+" not in out[0]


def test_the_10_05_regression_shape_raises_both_alarms():
    prev = run(775, {"Basis: no matching catalog evidence.": 167})
    today = run(775, {"Basis: no matching catalog evidence.": 141,
                      "Basis: profile evidence could not be read.": 82})
    r = reds(lines(today, prev))
    assert any("decline rate jumped" in l for l in r)
    assert any("profile evidence could not be read" in l for l in r)


def test_reason_normalisation_merges_quotes_numbers_and_tails():
    a = alert.decline_reason({"basis": "Basis: the question says 1985; the translator left it out"})
    b = alert.decline_reason({"basis": "Basis: the question says 2001; something else"})
    assert a == b == "the question says N"
    q1 = alert.decline_reason({"basis": "Basis: read “Christmas” as a word."})
    q2 = alert.decline_reason({"basis": "Basis: read “Easter” as a word."})
    assert q1 == q2
    fallback = alert.decline_reason({"basis": "", "answer": "I can't answer that because X. More."})
    assert fallback == "I can't answer that because X"


def test_pass_and_decline_rates_and_clause_declines():
    recs = run(10, {"Basis: a.": 2}, flagged=3) + [{"outcome": "answered", "outcomes": ["answered", "declined"],
                                                    "flags": ["~relaxed_offer"], "basis": "Basis: b."}]
    s = alert.summarize(recs)
    assert s["n"] == 11 and s["declined"] == 3 and s["pass"] == 6


def _write(d, stamp, recs, incomplete=None):
    p = d / f"nightly-{stamp}-advisory.graded.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in recs))
    if incomplete is not None:
        (d / f"nightly-{stamp}-advisory.summary.json").write_text(json.dumps({"incomplete": incomplete}))


def test_main_compares_newest_two_complete_runs(tmp_path, capsys):
    _write(tmp_path, "20261004T022839", run(declines={"Basis: a.": 20}))
    _write(tmp_path, "20261005T023020", run(declines={"Basis: a.": 20, "Basis: profiles gone.": 9}))
    assert alert.main(["--dir", str(tmp_path), "--now", "2026-10-05T08:00"]) == 0
    out = capsys.readouterr().out
    assert "🔴" in out and "profiles gone" in out and "jumped" in out


def test_main_skips_comparison_for_an_incomplete_run(tmp_path, capsys):
    _write(tmp_path, "20261004T022839", run(declines={"Basis: a.": 20}), incomplete=False)
    _write(tmp_path, "20261005T023020", run(40, declines={"Basis: b.": 30}), incomplete=True)
    alert.main(["--dir", str(tmp_path), "--now", "2026-10-05T08:00"])
    out = capsys.readouterr().out
    assert "🔴" not in out and "🟡" in out and "incomplete" in out


def test_main_flags_a_stale_eval(tmp_path, capsys):
    _write(tmp_path, "20261001T022839", run())
    alert.main(["--dir", str(tmp_path), "--now", "2026-10-05T08:00"])
    assert "has not run since" in capsys.readouterr().out


def test_main_is_quiet_without_logs(tmp_path, capsys):
    assert alert.main(["--dir", str(tmp_path / "missing")]) == 0
    assert capsys.readouterr().out == ""
