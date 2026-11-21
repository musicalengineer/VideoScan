"""scripts/testbed_strands.py — the testbed's one fan-out / fan-in runner (Rick 2026-11-20)."""
import importlib.util
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("testbed_strands", ROOT / "scripts" / "testbed_strands.py")
ts = importlib.util.module_from_spec(spec)
sys.modules["testbed_strands"] = ts
spec.loader.exec_module(ts)


def sleeper(name, secs, rc=0, **kw):
    code = f"import time,sys; time.sleep({secs}); sys.exit({rc})"
    return ts.Strand(name=name, cmd=[sys.executable, "-c", code], **kw)


def test_default_width_is_half_the_cores():
    assert ts.default_jobs(30) == 15 and ts.default_jobs(16) == 8 and ts.default_jobs(1) == 1


def test_strands_run_n_at_a_time_and_results_come_back_in_input_order(tmp_path):
    work = [sleeper(f"s{i}", 1.0) for i in range(6)]
    t0 = time.monotonic()
    results = ts.Runner(tmp_path / "run", jobs=6, timings_path=tmp_path / "t.json").run(work)
    wall = time.monotonic() - t0
    assert [r.strand.name for r in results] == [f"s{i}" for i in range(6)]
    assert all(r.ok for r in results)
    assert wall < 3.0, f"six 1 s strands at width 6 took {wall:.1f}s — they did not run at once"


def test_width_bounds_how_many_run_at_once(tmp_path):
    seen, live, lock = [], [0], threading.Lock()
    marker = tmp_path / "live"
    marker.mkdir()
    code = ("import os,time,sys; d=sys.argv[1]; p=os.path.join(d,str(os.getpid())); open(p,'w').close();"
            "n=len(os.listdir(d)); time.sleep(0.5); os.remove(p); print('LIVE',n)")
    work = [ts.Strand(name=f"s{i}", cmd=[sys.executable, "-c", code, str(marker)]) for i in range(8)]
    results = ts.Runner(tmp_path / "run", jobs=3, timings_path=tmp_path / "t.json").run(work)
    peaks = [int(r.text().rsplit("LIVE", 1)[1].split()[0]) for r in results]
    assert max(peaks) <= 3, peaks


def test_longest_first_from_the_last_run_and_wall_is_near_the_longest_strand(tmp_path):
    timings = tmp_path / "t.json"
    timings.write_text(json.dumps({"long": 2.0, "a": 0.5, "b": 0.5, "c": 0.5, "d": 0.5}))
    order = ts.order([sleeper(n, 0) for n in ("a", "b", "long", "c", "d")], ts.load_timings(timings))
    assert order[0].name == "long", "the longest strand must start first or it sets the wall"
    work = [sleeper("a", 0.5), sleeper("b", 0.5), sleeper("long", 2.0), sleeper("c", 0.5), sleeper("d", 0.5)]
    t0 = time.monotonic()
    ts.Runner(tmp_path / "run", jobs=2, timings_path=timings).run(work)
    assert time.monotonic() - t0 < 3.2, "longest-first at width 2 should finish near 2 s, not 2 + 0.5 x k"
    assert set(json.loads(timings.read_text())) >= {"long", "a", "b", "c", "d"}, "measured times not remembered"


def test_a_timeout_stops_the_strands_whole_process_group_and_is_a_failure(tmp_path):
    pidfile = tmp_path / "grandchild.pid"
    code = ("import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']);"
            f"open({str(pidfile)!r},'w').write(str(p.pid)); time.sleep(60)")
    s = ts.Strand(name="hang", cmd=[sys.executable, "-c", code], timeout=1.0)
    old = ts.TERM_GRACE_S
    ts.TERM_GRACE_S = 1.0
    try:
        [r] = ts.Runner(tmp_path / "run", jobs=2, timings_path=tmp_path / "t.json").run([s])
    finally:
        ts.TERM_GRACE_S = old
    assert r.timed_out and not r.ok
    assert "TIMEOUT after 1s" in r.text()
    gpid = int(pidfile.read_text())
    time.sleep(0.3)
    with pytest.raises(ProcessLookupError):
        os.kill(gpid, 0)                     # the strand's own child is gone too, not orphaned
    assert "hang" not in json.loads((tmp_path / "t.json").read_text()), "a timed-out run is no timing"


def test_serial_strands_run_alone_after_the_parallel_phase(tmp_path):
    log = tmp_path / "order.log"
    def stamp(name, secs, **kw):
        code = (f"import time; open({str(log)!r},'a').write('start {name} %f\\n' % time.time()); time.sleep({secs});"
                f"open({str(log)!r},'a').write('end {name} %f\\n' % time.time())")
        return ts.Strand(name=name, cmd=[sys.executable, "-c", code], **kw)
    work = [stamp("timing", 0.3, serial="timing budget needs a quiet machine"), stamp("p1", 0.5), stamp("p2", 0.5)]
    results = ts.Runner(tmp_path / "run", jobs=4, timings_path=tmp_path / "t.json").run(work)
    assert all(r.ok for r in results)
    events = {(w[0], w[1]): float(w[2]) for w in (l.split() for l in log.read_text().splitlines())}
    assert events[("start", "timing")] >= max(events[("end", "p1")], events[("end", "p2")]), \
        "the serial strand started while parallel strands were still running"


def test_each_strand_gets_its_own_tmpdir(tmp_path):
    code = "import os,tempfile; print('TMP', tempfile.gettempdir())"
    work = [ts.Strand(name=f"s{i}", cmd=[sys.executable, "-c", code]) for i in range(3)]
    results = ts.Runner(tmp_path / "run", jobs=3, timings_path=tmp_path / "t.json").run(work)
    dirs = {r.text().rsplit("TMP", 1)[1].split()[0] for r in results}
    assert len(dirs) == 3 and all(d.startswith(str(tmp_path)) for d in dirs), dirs


def test_a_strand_that_cannot_start_is_a_failed_result_never_a_gap(tmp_path):
    work = [ts.Strand(name="missing", cmd=["/nonexistent/binary"]), sleeper("ok", 0)]
    results = ts.Runner(tmp_path / "run", jobs=2, timings_path=tmp_path / "t.json").run(work)
    assert [r.strand.name for r in results] == ["missing", "ok"]
    assert results[0].rc == 127 and not results[0].ok and results[1].ok


def test_ctrl_c_stops_every_running_strand_and_starts_no_more(tmp_path):
    driver = tmp_path / "drive.py"
    driver.write_text(f"""
import sys, time
sys.path.insert(0, {str(ROOT / 'scripts')!r})
import testbed_strands as ts
ts.TERM_GRACE_S = 1.0
work = [ts.Strand(name=f"s{{i}}", cmd=[sys.executable, "-c", "import os,time; print(os.getpid(), flush=True); time.sleep(60)"])
        for i in range(6)]
ts.Runner({str(tmp_path / 'run')!r}, jobs=2, timings_path={str(tmp_path / 't.json')!r}).run(work)
""")
    p = subprocess.Popen([sys.executable, str(driver)], start_new_session=True)
    time.sleep(1.5)
    os.kill(p.pid, signal.SIGINT)
    p.wait(timeout=20)
    logs = sorted((tmp_path / "run").glob("*/strand.log"))
    assert len(logs) == 2, f"{len(logs)} strands started at width 2 — Ctrl-C must start no more"
    for log in logs:
        pid = int(log.read_text().splitlines()[1])
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


def test_stop_asks_every_strand_to_end_at_once_not_one_grace_period_each(tmp_path):
    # 15 test hosts each take a moment to wind down on TERM. Stopped one after another, a caller that
    # waits 10 s before KILLing the runner (run_tests' lane budget) would orphan most of them.
    import threading
    code = ("import signal,sys,time\n"
            "def bye(*a):\n    time.sleep(1.0); sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, bye); print('up', flush=True); time.sleep(60)")
    work = [ts.Strand(name=f"s{i}", cmd=[sys.executable, "-c", code]) for i in range(6)]
    runner = ts.Runner(tmp_path / "run", jobs=6, timings_path=tmp_path / "t.json")
    th = threading.Thread(target=lambda: runner.run(work), daemon=True)
    th.start()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and sum("up" in l.read_text() for l in (tmp_path / "run").glob("*/strand.log")) < 6:
        time.sleep(0.05)
    t0 = time.monotonic()
    runner.stop()
    took = time.monotonic() - t0
    th.join(10)
    assert took < 3.0, f"stopping 6 strands that each need 1 s took {took:.1f}s — they were stopped one by one"
