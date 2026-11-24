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
    assert "test_bad.py: exit 1" in out, "the failing strand's own output is not shown"
    import json
    known = json.loads(timings.read_text())
    assert set(known) >= {"pytest:test_ok_one.py", "pytest:test_ok_two.py", "pytest:test_bad.py"}, known


def test_a_shard_that_dies_without_a_summary_is_red_never_green(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_a():\n    pass\n")
    (tmp_path / "test_dies.py").write_text("import os\ndef test_b():\n    os._exit(3)\n")
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "pytest_shards.py"), "--python", sys.executable,
                        "--jobs", "2", "--timings", str(tmp_path / "t.json"), "--", "test_ok.py", "test_dies.py"],
                       cwd=tmp_path, capture_output=True, text=True, timeout=120)
    assert p.returncode != 0
    assert "ERROR test_dies.py: exit 3 with no pytest summary" in p.stdout, p.stdout
    ok, words = lane.verdict(p.stdout, p.returncode, False, 1500)
    assert not ok, words


def test_a_file_with_no_tests_is_named_not_failed_but_a_lane_of_no_tests_is_red(tmp_path):
    # 2026-11-20, one strand per module: the tracked-file glob also matches helpers with no tests
    # (scripts/ci_test_verdict.py, scripts/pytest_shards.py); pytest exits 5 on them alone.
    (tmp_path / "test_ok.py").write_text("def test_a():\n    pass\n")
    (tmp_path / "helper_test_x.py").write_text("X = 1\n")
    run = lambda *mods: subprocess.run([sys.executable, str(ROOT / "scripts" / "pytest_shards.py"), "--python",
                                        sys.executable, "--jobs", "2", "--timings", str(tmp_path / "t.json"), "--",
                                        *mods], cwd=tmp_path, capture_output=True, text=True, timeout=120)
    p = run("test_ok.py", "helper_test_x.py")
    assert p.returncode == 0, p.stdout
    assert "no tests in 1 file(s): helper_test_x.py" in p.stdout
    assert p.stdout.strip().splitlines()[-1].startswith("1 passed in ")
    p = run("helper_test_x.py")
    assert p.returncode != 0, "a lane that ran no test at all must be red"
    (tmp_path / "test_broken.py").write_text("import no_such_module_xyz\ndef test_a():\n    pass\n")
    p = run("test_ok.py", "test_broken.py")
    assert p.returncode != 0 and "test_broken.py" in p.stdout, "an import error is never 'no tests'"


def test_a_test_that_keeps_writing_after_its_strand_is_named_and_the_summary_still_prints(tmp_path):
    # RED 2026-11-23 (full proof run): a test left a background process writing into its strand's TMPDIR; the
    # runner's TemporaryDirectory cleanup raised 'Directory not empty' and the lane printed NO summary — 2,900 tests
    # read as 'ZERO tests ran'. Now the summary always prints and the strand that kept writing is named.
    (tmp_path / "test_lingering.py").write_text(
        "import os, subprocess, sys, tempfile\n"
        "def test_spawns_a_writer():\n"
        "    d = tempfile.gettempdir()\n"
        "    subprocess.Popen([sys.executable, '-c', 'import os,time,sys\\n'\n"
        "                      't0=time.time(); i=0\\n'\n"
        "                      'while time.time()-t0 < 3:\\n'\n"
        "                      '    p=os.path.join(sys.argv[1], \"late\", \"d%d\" % (i % 50)); os.makedirs(p, exist_ok=True)\\n'\n"
        "                      '    open(os.path.join(p, \"f%d\" % i), \"w\").close(); i+=1', d],\n"
        "                     start_new_session=True)\n")
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "pytest_shards.py"), "--python", sys.executable,
                        "--jobs", "2", "--timings", str(tmp_path / "t.json"), "--", "test_lingering.py", "test_ok.py"],
                       cwd=tmp_path, capture_output=True, text=True, timeout=120)
    out = p.stdout + p.stderr
    assert "Traceback" not in out, out
    assert re.search(r"^2 passed in \d+\.\d+s$", p.stdout.strip().splitlines()[-1]), out
    assert p.returncode == 0, out
