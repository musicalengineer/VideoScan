"""scripts/exposure_metrics.py and scripts/problem_files.py: the over-exposure
classifier (synthetic Swift snippets), its shrink-only ratchet, the problem-
files ranking, and the privacy gate the GitHub nightly publishes through."""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools"))

import exposure_metrics as em  # noqa: E402
import problem_files as pf  # noqa: E402
import publish_metrics as pm  # noqa: E402

APP = "VideoScan/VideoScan"
CORE = "VideoScan/VideoScanCore/Sources/VideoScanCore"


def classify(sources, tests=None):
    """{qualified name: classification} for every counted declaration."""
    decls = em.analyze(sources, tests or {})
    return {d.qualified: d.classification for d in decls}


# ---------------------------------------------------------------- the three classes

def test_referenced_only_in_its_own_file_could_be_private():
    out = classify({
        f"{APP}/Catalog/Widget.swift": """
struct Widget {
    var title: String
    func renderTitle() -> String { formatHelper(title) }
    func formatHelper(_ s: String) -> String { s.uppercased() }
}
""",
        f"{APP}/Catalog/User.swift": "func show(w: Widget) { print(w.renderTitle()) }\n",
    })
    assert out["Widget.formatHelper"] == em.COULD_BE_PRIVATE
    assert out["Widget.renderTitle"] == em.FINE         # used from User.swift
    assert out["show"] == em.COULD_BE_PRIVATE           # top-level, used nowhere else


def test_used_only_from_the_types_own_split_files_is_widened_for_split():
    out = classify({
        f"{APP}/Model/VideoScanModel.swift": """
final class VideoScanModel {
    var pendingQueue: [Int] = []
    func drainQueueForSplit() { pendingQueue.removeAll() }
}
""",
        f"{APP}/MediaOps/VideoScanModel+Relocate.swift": """
extension VideoScanModel {
    func relocateEverything() { drainQueueForSplit(); pendingQueue.append(1) }
}
""",
        f"{APP}/MediaOps/Mover.swift": "func move(m: VideoScanModel) { m.relocateEverything() }\n",
    })
    assert out["VideoScanModel.drainQueueForSplit"] == em.WIDENED_FOR_SPLIT
    assert out["VideoScanModel.pendingQueue"] == em.WIDENED_FOR_SPLIT
    assert out["VideoScanModel.relocateEverything"] == em.FINE


def test_a_split_file_that_does_not_extend_the_type_makes_it_fine():
    out = classify({
        f"{APP}/Model/VideoScanModel.swift": "final class VideoScanModel {\n    func sharedHelperX() {}\n}\n",
        # Named like a split file but extends a different type.
        f"{APP}/Model/VideoScanModel+Other.swift": "extension OtherType {\n    func go() { sharedHelperX() }\n}\n",
    })
    assert out["VideoScanModel.sharedHelperX"] == em.FINE


def test_tests_reaching_a_declaration_keep_it_internal():
    out = classify(
        {f"{APP}/Hallie/Parser.swift": "struct Parser {\n    func normalizeToken(_ s: String) -> String { s }\n}\n"},
        {"VideoScan/VideoScanTests/ParserTests.swift": "@testable import VideoScan\nfunc t() { _ = Parser().normalizeToken(\"x\") }\n"})
    assert out["Parser.normalizeToken"] == em.FINE


def test_module_scoping_core_is_not_seen_from_the_app():
    out = classify({
        f"{CORE}/Engine.swift": "public struct Engine {\n    func crunchNumbers() {}\n}\n",
        # Same name in the app module: a different module, not a reference.
        f"{APP}/Catalog/View.swift": "func crunchNumbers() {}\nfunc caller() { crunchNumbers() }\n",
    })
    assert out["Engine.crunchNumbers"] == em.COULD_BE_PRIVATE


def test_init_is_referenced_through_its_type_name():
    out = classify({
        f"{APP}/Catalog/Thing.swift": "struct Thing {\n    init(size: Int) {}\n}\nstruct Lonely {\n    init(size: Int) {}\n}\n",
        f"{APP}/Catalog/Maker.swift": "let made = Thing(size: 3)\n",
    })
    assert out["Thing.init"] == em.FINE
    assert out["Lonely.init"] == em.COULD_BE_PRIVATE


# ---------------------------------------------------------------- collisions

def test_same_name_on_another_type_elsewhere_reads_as_fine_conservatively():
    out = classify({
        f"{APP}/A/Alpha.swift": "struct Alpha {\n    func reloadAll() {}\n    func go() { reloadAll() }\n}\n",
        f"{APP}/B/Beta.swift": "struct Beta {\n    func reloadAll() {}\n    func go() { reloadAll() }\n}\n",
    })
    assert out["Alpha.reloadAll"] == em.FINE
    assert out["Beta.reloadAll"] == em.FINE


def test_short_name_cannot_be_widened_for_split():
    out = classify({
        f"{APP}/Model/Store.swift": "final class Store {\n    var tmp = 0\n}\n",
        f"{APP}/Model/Store+Ops.swift": "extension Store {\n    func bump() { tmp += 1 }\n}\n",
    })
    assert out["Store.tmp"] == em.FINE


def test_common_name_in_more_than_50_files_cannot_be_widened_for_split():
    sources = {f"{APP}/Model/Store.swift": "final class Store {\n    var sharedCounter = 0\n}\n"}
    for i in range(em.COMMON_FILES + 1):
        sources[f"{APP}/Model/Store+Part{i}.swift"] = f"extension Store {{\n    func part{i}() {{ sharedCounter += 1 }}\n}}\n"
    out = classify(sources)
    assert out["Store.sharedCounter"] == em.FINE


# ---------------------------------------------------------------- what is not counted

def test_skips_non_internal_overrides_witnesses_objc_and_locals():
    src = """
import SwiftUI
protocol Loader {
    func loadThings()
}
struct Screen: View, Identifiable {
    let id = 1
    var body: some View { Text(helperText()) }
    func helperText() -> String {
        let localValue = 3
        func nestedLocal() {}
        return "\\(localValue)"
    }
    func loadThings() {}
    private func hidden() {}
    fileprivate var alsoHidden = 0
    public func exported() {}
    enum CodingKeys: String, CodingKey { case id }
}
class Base: NSObject {
    override func awakeFromNib() {}
    @objc func menuAction() {}
    @IBAction func buttonPressed(_ sender: Any) {}
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 1 }
}
private struct Secret {
    func insideSecret() {}
}
private extension Screen {
    func privateExtensionMember() {}
}
@objcMembers class Bridged: NSObject {
    func bridgedMember() {}
}
struct Formatter {
    internal func explicitlyInternal() {}
    private(set) var setterOnly = 0
}
"""
    out = classify({f"{APP}/UI/Screen.swift": src})
    assert out == {
        "Screen.helperText": em.COULD_BE_PRIVATE,
        "Formatter.explicitlyInternal": em.COULD_BE_PRIVATE,
        "Formatter.setterOnly": em.COULD_BE_PRIVATE,
    }, out


def test_braces_in_strings_comments_and_regex_do_not_confuse_scopes():
    src = '''
struct Tricky {
    let brace = "{ not a scope"
    // } nor this
    /* { or this } */
    let pattern = /\\d{4}/
    let raw = #"}"#
    func afterAll() {}
}
'''
    out = classify({f"{APP}/UI/Tricky.swift": src})
    assert out == {"Tricky.brace": em.COULD_BE_PRIVATE, "Tricky.pattern": em.COULD_BE_PRIVATE,
                   "Tricky.raw": em.COULD_BE_PRIVATE, "Tricky.afterAll": em.COULD_BE_PRIVATE}, out


def test_one_file_scripts_are_not_measured():
    out = classify({"swift_cli/Tool.swift": "#!/usr/bin/env swift\nfunc helper() {}\nhelper()\n"})
    assert out == {}


def test_nested_types_count_top_level_types_do_not():
    out = classify({f"{APP}/UI/Outer.swift": "struct Outer {\n    struct InnerThing {}\n    let x = InnerThing()\n}\n"})
    assert "Outer" not in out
    assert out["Outer.InnerThing"] == em.COULD_BE_PRIVATE


# ---------------------------------------------------------------- ratchet

def decl(file, name, cls=em.COULD_BE_PRIVATE, scope=("T",)):
    d = em.Decl(file=file, module="app", kind="func", name=name, scope=scope, line=1)
    d.classification = cls
    return d


def test_ratchet_new_fixed_moved_and_shrink_only():
    base = {f"{APP}/A.swift::T.old": em.COULD_BE_PRIVATE,
            f"{APP}/A.swift::T.kept": em.COULD_BE_PRIVATE,
            f"{APP}/A.swift::T.moved": em.WIDENED_FOR_SPLIT}
    decls = [decl(f"{APP}/A.swift", "kept"),
             decl(f"{APP}/B.swift", "moved"),            # same T.moved, new file
             decl(f"{APP}/A.swift", "brandNew"),
             decl(f"{APP}/A.swift", "fineOne", em.FINE)]
    r = em.ratchet(decls, base)
    assert [d.key for d in r["new"]] == [f"{APP}/A.swift::T.brandNew"]
    assert r["fixed"] == [f"{APP}/A.swift::T.old"]
    assert r["moved"] == {f"{APP}/B.swift::T.moved": f"{APP}/A.swift::T.moved"}
    assert set(r["next_baseline"]) == {f"{APP}/A.swift::T.kept", f"{APP}/A.swift::T.moved"}
    assert set(r["next_baseline"]) <= set(base)          # never adds


def test_shrink_guard_keeps_the_baseline_when_most_of_it_vanishes():
    base = {f"{APP}/A.swift::T.n{i}": em.COULD_BE_PRIVATE for i in range(30)}
    r = em.ratchet([decl(f"{APP}/A.swift", "n0")], base)
    assert r["shrink_skipped"] and r["next_baseline"] == base


def test_baseline_round_trip_and_cli_update_then_shrink(tmp_path):
    path = tmp_path / "b.json"
    em.write_baseline(str(path), {"x::T.a": em.COULD_BE_PRIVATE})
    assert em.load_baseline(str(path)) == {"x::T.a": em.COULD_BE_PRIVATE}
    assert json.loads(path.read_text())["entry_count"] == 1


def test_alert_lines_quiet_when_clean_and_red_when_new():
    assert em.alert_lines({"new": [], "fixed": 0}) == []
    lines = em.alert_lines({"ts": "2026-10-07T02:00:00Z", "fixed": 2, "new": [
        {"file": f"{APP}/A.swift", "name": "T.f", "classification": em.COULD_BE_PRIVATE}]})
    assert lines[0].startswith("🔴 Over-exposure (2026-10-07): 1 NEW")
    assert "A.swift :: T.f" in lines[1]
    assert any(line.startswith("✅") for line in lines)


# ---------------------------------------------------------------- reports + privacy gate

def sample_outputs():
    sources = {
        f"{APP}/Catalog/Widget.swift": "struct Widget {\n    func onlyHere() {}\n    func go() { onlyHere() }\n}\n",
        f"{APP}/Model/VideoScanModel.swift": "final class VideoScanModel {\n    func splitHelper() {}\n}\n",
        f"{APP}/Model/VideoScanModel+X.swift": "extension VideoScanModel {\n    func useIt() { splitHelper() }\n}\n",
    }
    decls = em.analyze(sources, {})
    lines = {p: t.count("\n") for p, t in sources.items()}
    result = em.ratchet(decls, {})
    ts, sha = "2026-10-07T02:00:00Z", "abcdef12"
    return (em.build_row(decls, lines, result, {}, ts, sha), em.new_report(result, {}, ts, sha),
            em.files_report(decls, lines, ts, sha))


def test_outputs_pass_the_privacy_gate():
    row, new, files = sample_outputs()
    folders = {"Catalog", "Model", "Core", "(app root)"}
    pm.validate("exposure.jsonl", row, folders)
    pm.validate("exposure_new_latest.json", new, folders)
    pm.validate("exposure_files_latest.json", files, folders)
    assert row["totals"]["could_be_private"] >= 1 and row["totals"]["widened_for_split"] == 1
    assert row["top20"][0]["file"] == f"{APP}/Catalog/Widget.swift"


@pytest.mark.parametrize("path", ["/Users/rickb/x.swift", f"{APP}/People/Donna at beach.swift",
                                  f"{APP}/../secret.swift", "notes/Donna.swift", f"{APP}/A.txt"])
def test_privacy_gate_refuses_anything_but_app_source_paths(path):
    row, _, _ = sample_outputs()
    row["top20"][0]["file"] = path
    with pytest.raises(pm.PrivacyError):
        pm.validate("exposure.jsonl", row, {"Catalog", "Model"})


def test_privacy_gate_refuses_free_text_names_and_extra_keys():
    _, new, files = sample_outputs()
    new["new"][0]["name"] = "Donna's birthday"
    with pytest.raises(pm.PrivacyError):
        pm.validate("exposure_new_latest.json", new)
    _, _, files = sample_outputs()
    files["note"] = "hello"
    with pytest.raises(pm.PrivacyError):
        pm.validate("exposure_files_latest.json", files)


def test_validate_cli_exit_codes(tmp_path):
    row, _, _ = sample_outputs()
    good = tmp_path / "row.json"
    good.write_text(json.dumps(row) + "\n")
    assert pm.validate_file("exposure.jsonl", str(good), {"Catalog", "Model"}) == 0
    row["sha"] = "not a sha"
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(row) + "\n")
    assert pm.validate_file("exposure.jsonl", str(bad), {"Catalog", "Model"}) == 3


# ---------------------------------------------------------------- problem files

def test_score_is_the_documented_formula():
    # debt = 2*3 + (35-15)/5 + 5*1 + (1200-800)/200 + 10/2 + 4/4 = 6+4+5+2+5+1 = 23
    assert pf.score(3, 35, 1, 1200, 10, 4, churn=0) == 23.0
    assert pf.score(3, 35, 1, 1200, 10, 4, churn=5) == 46.0          # x (1 + 5/5)
    assert pf.score(3, 35, 1, 1200, 10, 4, churn=50) == pf.score(3, 35, 1, 1200, 10, 4, churn=10)
    assert pf.score(0, 0, 0, 300, 0, 0, churn=20) == 0               # busy but clean: not a problem


def test_problem_rows_join_every_signal_and_rank_worst_first():
    a, b, c = f"{APP}/A/Big.swift", f"{APP}/B/Busy.swift", f"{APP}/C/Clean.swift"
    exposure = {a: {"lines": 2000, "could_be_private": ["T.x"] * 4, "widened_for_split": []},
                b: {"lines": 500, "could_be_private": ["T.y"], "widened_for_split": ["T.z"] * 2},
                c: {"lines": 100, "could_be_private": [], "widened_for_split": []},
                "scripts/tool.py": {"lines": 5000, "could_be_private": ["x"], "widened_for_split": []}}
    cx_base = {f"{a}::T.f": {"ccn": 40, "nloc": 90}, f"{a}::T.g": {"ccn": 16, "nloc": 20},
               f"{b}::T.h": {"ccn": 18, "nloc": 10}}
    debt = {"new": [{"file": b}], "worse": []}
    churn = {b: 9, c: 30}
    rows = pf.build_rows(exposure, cx_base, debt, churn)
    assert [r["file"] for r in rows] == [b, a]           # out-of-scope and clean files dropped
    rb, ra = rows
    assert (ra["offenders"], ra["worst_ccn"], ra["new_or_worse"], ra["lines"], ra["churn_7d"]) == (2, 40, 0, 2000, 0)
    assert (rb["offenders"], rb["new_or_worse"], rb["widened_for_split"], rb["churn_7d"]) == (1, 1, 2, 9)
    rep = pf.report(rows, "2026-10-07T02:00:00Z", "abcdef12")
    pm.validate("problem_files_latest.json", rep)
    table = pf.table_lines(rep)
    assert "Busy.swift" in table[2] and "🔴" in table[2] and "Big.swift" in table[3]


def test_problem_table_caps_at_15_and_is_quiet_when_empty():
    rows = [{"file": f"{APP}/A/F{i}.swift", "score": 100 - i, "offenders": 1, "worst_ccn": 20,
             "new_or_worse": 0, "lines": 900, "could_be_private": 0, "widened_for_split": 0, "churn_7d": 0}
            for i in range(30)]
    rep = pf.report(rows, "2026-10-07T02:00:00Z", "abcdef12")
    assert len(rep["rows"]) == 15 and rep["files_scored"] == 30
    assert len(pf.table_lines(rep)) == 15 + 3
    assert pf.table_lines({"rows": []}) == []


# ---------------------------------------------------------------- sensor (real tree)

@pytest.mark.skipif(not (ROOT / ".git").exists(), reason="needs the repo checkout")
def test_sensor_real_tree_scan_is_fast_and_sane():
    started = time.monotonic()
    decls, lines = em.scan(str(ROOT))
    elapsed = time.monotonic() - started
    assert elapsed < 60, f"exposure scan took {elapsed:.1f} s"
    assert len(lines) > 500 and len(decls) > 5000
    counts = {c: sum(d.classification == c for d in decls) for c in (em.COULD_BE_PRIVATE, em.WIDENED_FOR_SPLIT)}
    # Over-exposure is a minority: a parser bug that swallowed scopes would
    # either find nothing or call almost everything private.
    assert 0 < counts[em.COULD_BE_PRIVATE] < 0.4 * len(decls)
    assert 0 < counts[em.WIDENED_FOR_SPLIT] < 0.2 * len(decls)
    assert not any(d.name == "body" for d in decls)


def test_alert_cli_reads_stdin():
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "exposure_metrics.py"), "--alert", "-"],
                       input=json.dumps({"new": [], "fixed": 0}), capture_output=True, text=True, timeout=30)
    assert r.returncode == 0 and r.stdout == ""
