"""scripts/pytest_shards.py — the Python lane as N concurrent pytest shards, one pytest-shaped summary."""
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pytest_shards", ROOT / "scripts" / "pytest_shards.py")
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)

# The lane's own reader of the last line (scripts/script_tests_lane.py), so the contract is tested against it.
spec2 = importlib.util.spec_from_file_location("script_tests_lane", ROOT / "scripts" / "script_tests_lane.py")
lane = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(lane)


def test_modules_are_dealt_longest_first_to_the_lightest_shard_and_every_module_once():
    timings = {"a.py": 100.0, "b.py": 60.0, "c.py": 50.0, "d.py": 10.0, "e.py": 5.0}
    shards = ps.deal(list(timings), 2, timings)
    assert sorted(m for s in shards for m in s) == sorted(timings)
    loads = sorted(sum(timings[m] for m in s) for s in shards)
    assert loads == [110.0, 115.0], loads          # LPT: a | b+c+e … balanced within one module
    assert ps.deal(["x.py"], 8, {}) == [["x.py"]], "never more shards than modules"
    assert ps.deal(list(timings), 1, timings) == [sorted(timings)], "N=1 is one pytest over every module"


def test_the_summary_sums_shards_in_pytests_own_grammar_and_the_lane_reads_it():
    a = ps.summary_counts("....\n1 failed, 40 passed, 2 skipped, 1 warning, 3 subtests passed in 1.20s\n")
    b = ps.summary_counts("== 60 passed, 1 warning in 2.00s ==\n")
    c = ps.summary_counts("no tests ran in 0.01s\n")
    assert c == {}
    line = ps.summary_line(ps.merge([a, b, c]), 3.5)
    assert line == "1 failed, 100 passed, 2 skipped, 2 warnings, 3 subtests passed in 3.50s", line
    ok, words = lane.verdict("some output\n" + line + "\n", 1, False, 1500)
    assert not ok and words.startswith("script tests RED (1 failed"), words
    ok, words = lane.verdict("2 passed, 1 skipped, 4 subtests passed in 0.50s\n", 0, False, 1500)
    assert ok and words == "script tests GREEN (2 passed)", words


def test_shards_run_at_once_a_failure_is_shown_and_the_exit_is_nonzero(tmp_path):
    (tmp_path / "test_ok_one.py").write_text("import time\ndef test_a():\n    time.sleep(1.0)\n")
    (tmp_path / "test_ok_two.py").write_text("import time\ndef test_b():\n    time.sleep(1.0)\n")
    (tmp_path / "test_bad.py").write_text("import time\ndef test_c():\n    time.sleep(1.0)\n    assert 1 == 2\n")
    timings = tmp_path / "timings.json"
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "pytest_shards.py"), "--python", sys.executable,
                        "--jobs", "3", "--timings", str(timings), "--",
                        "test_ok_one.py", "test_ok_two.py", "test_bad.py"],
                       cwd=tmp_path, capture_output=True, text=True, timeout=120)
    out = p.stdout
    assert p.returncode != 0, out
    last = out.strip().splitlines()[-1]
    assert re.match(r"^1 failed, 2 passed in (\d+\.\d+)s$", last), last
    secs = float(re.search(r"in (\d+\.\d+)s", last).group(1))
    assert secs < 2.6, f"three 1 s modules in 3 shards took {secs}s — they did not run at once"
    assert "FAILED test_bad.py::test_c" in out
    assert "shard" in out and "exit 1" in out, "the failing shard's own output is not shown"
    import json
    known = json.loads(timings.read_text())
    assert set(known) >= {"test_ok_one.py", "test_ok_two.py", "test_bad.py"}, "per-module timings not recorded"


def test_a_shard_that_dies_without_a_summary_is_red_never_green(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_a():\n    pass\n")
    (tmp_path / "test_dies.py").write_text("import os\ndef test_b():\n    os._exit(3)\n")
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "pytest_shards.py"), "--python", sys.executable,
                        "--jobs", "2", "--timings", str(tmp_path / "t.json"), "--", "test_ok.py", "test_dies.py"],
                       cwd=tmp_path, capture_output=True, text=True, timeout=120)
    assert p.returncode != 0
    assert "ERROR shard-" in p.stdout and "with no pytest summary" in p.stdout
    ok, words = lane.verdict(p.stdout, p.returncode, False, 1500)
    assert not ok, words
