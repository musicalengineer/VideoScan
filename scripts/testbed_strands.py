#!/usr/bin/env python3
"""The testbed's one fan-out / fan-in runner: strands run N at a time; serial is opt-in, with a reason.

Rick 2026-11-20: "we must have a well-known pattern for shelling out parallelization of testbed
strands" … "we do not want to serialize when we can parallelize". The pattern (the one `make -j`,
GNU parallel and pytest-xdist share):

  * A STRAND is one unit of testbed work that can run as its own process: a pytest module, a group
    of a shell self-test, a corpus lane, a whole suite on another Mac. It names its command, its
    working directory and environment, a timeout, and a `weight_key` under which its last wall time
    is remembered.
  * FAN-OUT: a pool of N workers (default: half the cores — Rick: "at least NUM_CPUS / 2 … which
    would allow other systems plenty of room") pulls strands from ONE queue ordered longest-first by
    the last run's measured seconds (unknown strands go by the caller's estimate). Dynamic pull, not
    fixed bins: a worker that finishes early takes the next strand, so wall ≈ max(longest strand,
    total / N).
  * ISOLATION: every strand gets its own process group (a timeout or Ctrl-C stops the whole group:
    TERM, then KILL), its own log file, and its own TMPDIR under the run folder — so two strands
    never share a scratch path by accident.
  * SERIAL IS OPT-IN: a strand with `serial="<reason>"` (a timing budget that needs a quiet machine,
    the archive lock, the real catalog) runs alone, after the parallel phase. The reason is printed.
    Nothing is serial by default.
  * FAN-IN: every strand yields a Result (rc, seconds, timed_out, log). A strand that dies, times
    out or never starts is a failed Result, never a dropped one. The caller turns Results into its
    lane's own summary grammar, so readers downstream do not change.

≈ C++: a std::priority_queue<Strand> drained by N std::jthreads, each forking a child in its own
process group and joining with a deadline.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

TERM_GRACE_S = 10.0
DEFAULT_TIMINGS = Path.home() / "Library" / "Caches" / "videoscan-strand-timings.json"


def default_jobs(cpus: Optional[int] = None) -> int:
    """Half the cores, at least 1 (Ultra 30 → 15, M4 16 → 8)."""
    return max(1, (cpus if cpus is not None else (os.cpu_count() or 2)) // 2)


@dataclass
class Strand:
    name: str
    cmd: List[str]
    cwd: Optional[str] = None
    env: Dict[str, str] = field(default_factory=dict)      # added to os.environ (TMPDIR is set per strand)
    timeout: Optional[float] = None
    weight_key: Optional[str] = None                       # timing-cache key; defaults to name
    estimate: float = 1.0                                  # seconds, when the cache has no number yet
    serial: Optional[str] = None                           # the reason it must run alone; None = parallel

    @property
    def key(self) -> str:
        return self.weight_key or self.name


@dataclass
class Result:
    strand: Strand
    rc: int
    seconds: float
    log: Path
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.rc == 0 and not self.timed_out

    def text(self) -> str:
        try:
            return self.log.read_text(errors="replace")
        except OSError:
            return ""


def load_timings(path: Path) -> Dict[str, float]:
    try:
        data = json.loads(path.read_text())
        return {str(k): float(v) for k, v in data.items() if isinstance(v, (int, float))}
    except (OSError, ValueError, AttributeError):
        return {}


def save_timings(path: Path, timings: Dict[str, float]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(timings, indent=0, sort_keys=True))
        os.replace(tmp, path)
    except OSError:
        pass


def order(strands: Sequence[Strand], timings: Dict[str, float]) -> List[Strand]:
    """Longest first by the last measured seconds (else the estimate); ties by name — deterministic."""
    return sorted(strands, key=lambda s: (-timings.get(s.key, s.estimate), s.name))


def _stop_group(p: subprocess.Popen) -> None:
    for sig, wait in ((signal.SIGTERM, TERM_GRACE_S), (signal.SIGKILL, 5.0)):
        try:
            os.killpg(p.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            p.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def _stop_groups(procs: Sequence[subprocess.Popen]) -> None:
    """Stop many strands in ONE grace period: TERM every group, wait for all against one shared
    deadline, KILL whatever is left, wait again (15 test hosts and a caller that gives us 10 s:
    one grace period each would be minutes, and the caller's KILL would orphan them)."""
    for sig, grace in ((signal.SIGTERM, TERM_GRACE_S), (signal.SIGKILL, 5.0)):
        for p in procs:                      # the whole group, also when its leader is already gone
            try:
                os.killpg(p.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
        deadline = time.monotonic() + grace
        for p in procs:
            try:
                p.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
        if all(p.poll() is not None for p in procs):
            return


class Runner:
    """Runs strands; `on_done(result)` is called as each one ends (from a worker thread, serialised)."""

    def __init__(self, run_dir: Path, jobs: Optional[int] = None, timings_path: Path = DEFAULT_TIMINGS,
                 on_done: Optional[Callable[[Result], None]] = None):
        self.run_dir = Path(run_dir)
        self.jobs = max(1, jobs if jobs is not None else default_jobs())
        self.timings_path = timings_path
        self.on_done = on_done
        self._lock = threading.Lock()
        self._live: Dict[int, subprocess.Popen] = {}
        self._stopping = False

    def _run_one(self, s: Strand, index: int) -> Result:
        d = self.run_dir / f"{index:04d}"
        tmp = d / "tmp"
        tmp.mkdir(parents=True, exist_ok=True)
        log = d / "strand.log"
        env = dict(os.environ)
        env.update(s.env)
        env["TMPDIR"] = str(tmp) + "/"
        t0 = time.monotonic()
        with open(log, "w") as fh:
            fh.write(f"# strand {s.name}: {' '.join(s.cmd)}\n")
            fh.flush()
            with self._lock:
                if self._stopping:
                    return Result(s, 130, 0.0, log)
                try:
                    p = subprocess.Popen(s.cmd, cwd=s.cwd, env=env, stdout=fh, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, start_new_session=True)
                except OSError as e:
                    fh.write(f"# could not start: {e}\n")
                    return Result(s, 127, 0.0, log)
                self._live[p.pid] = p
            timed_out = False
            try:
                rc = p.wait(timeout=s.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                _stop_group(p)
                rc = p.returncode if p.returncode is not None else -9
                fh.write(f"\n# strand {s.name}: TIMEOUT after {s.timeout:g}s — its process group was stopped\n")
            except BaseException:
                # Ctrl-C / TERM lands HERE when the strand runs on the caller's thread (the serial phase).
                # Stop the group before the `finally` forgets it: stop() only knows what is in _live, so
                # no exit from this wait may skip the kill (≈ C++: the destructor of an RAII process guard).
                _stop_group(p)
                raise
            finally:
                with self._lock:
                    self._live.pop(p.pid, None)
        return Result(s, rc, time.monotonic() - t0, log, timed_out)

    def stop(self) -> None:
        """Stop every live strand's process group (Ctrl-C, SIGTERM): nothing is left running."""
        with self._lock:
            self._stopping = True
            live = list(self._live.values())
        _stop_groups(live)

    def run(self, strands: Sequence[Strand]) -> List[Result]:
        """Parallel strands N at a time (longest first), then serial strands one by one. Results in
        input order. Measured seconds of strands that ran to an exit are remembered for next time."""
        timings = load_timings(self.timings_path)
        index = {id(s): i for i, s in enumerate(strands)}
        parallel = order([s for s in strands if not s.serial], timings)
        serial = order([s for s in strands if s.serial], timings)
        results: Dict[int, Result] = {}
        queue = list(parallel)
        qlock = threading.Lock()

        def finish(r: Result) -> None:
            with self._lock:
                results[index[id(r.strand)]] = r
                if not r.timed_out and r.rc != 130:
                    timings[r.strand.key] = round(r.seconds, 2)
            if self.on_done:
                with qlock:
                    self.on_done(r)

        def worker() -> None:
            while True:
                with qlock:
                    if not queue or self._stopping:
                        return
                    s = queue.pop(0)
                finish(self._run_one(s, index[id(s)]))

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(min(self.jobs, len(queue)) or 0)]
        try:
            for t in threads:
                t.start()
            for t in threads:
                while t.is_alive():
                    t.join(timeout=0.5)
            for s in serial:
                if self._stopping:
                    break
                finish(self._run_one(s, index[id(s)]))
        except KeyboardInterrupt:
            self.stop()
            raise
        finally:
            save_timings(self.timings_path, timings)
        for s in strands:                      # a strand that never ran is a failure, never a gap
            i = index[id(s)]
            if i not in results:
                results[i] = Result(s, 130, 0.0, self.run_dir / f"{i:04d}" / "strand.log")
        return [results[i] for i in range(len(strands))]
