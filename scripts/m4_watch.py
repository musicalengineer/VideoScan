#!/usr/bin/env python3
"""m4_watch.py — the push trigger: the M4 runs the suite lane for every new commit on origin/main.

DECISIONS 2026-11-17, "The idle M4 becomes part of the merge workflow": the full
suite runs on demand for a branch AND on every push to `main`. This is the second
half. It runs ON THE M4, one short tick every ~300 s from a LaunchAgent in the GUI
session (scripts/launchd/com.videoscan.m4watch.plist; scripts/m4_watch_install.sh
installs a PINNED copy under ~/m4run/bin/watch and removes it again). It is not a
second runner: a tick only decides, then calls the pinned `m4_run.sh suite --host
m4local --ref <sha>` — the same lane, the same testbed lock, the same quiet window
before the 14:00 scheduled run, the same summary, nothing published.

    m4_watch.py tick      one look at origin/main; at most one run started
    m4_watch.py status    the verdict line and the last tick, as `status` shows them

A tick, in order (state in <root>/watch/state.json, written whole or not at all):
  1. One tick at a time (a flock on <root>/watch/lock; a second one exits).
  2. `git fetch origin +refs/heads/main:refs/m4watch/main` in the M4s own checkout
     (~/dev/VideoScan): its own ref — no branch, no worktree and not
     refs/remotes/origin/main is touched. A fetch that fails is said and the tick ends.
  3. A run this watcher started: if its run.log has an OUTCOME the verdict is
     recorded; if the testbed lock still names it, it is running (nothing to do);
     otherwise it ENDED WITHOUT AN OUTCOME (a logout of the GUI session, a restart) —
     retried ONCE, then recorded as NO-OUTCOME.
  4. ONE SLOT, the NEWEST commit: the head of origin/main is the only candidate;
     commits pushed while a run was going are never queued one by one.
  5. Never the same commit twice: a commit this watcher has a verdict for, or that
     any suite or testbed run under <root>/out already ran to GREEN, AMBER or RED
     (a run started by hand counts), is not run again. Asked twice: here, and by the
     host side again UNDER the testbed lock (`--unless-ran`), so a run by hand that
     finishes between the two is still seen (OUTCOME REFUSED already-run <verdict>).
  6. A docs-only range is skipped: when every path changed since the last commit the
     watcher settled is under docs/ or is a Markdown file, the commit is recorded as
     SKIPPED docs-only. An unknown range (no settled commit yet, history rewritten)
     is never docs-only.
  7. Start. Exit 0 from the runner = started (its output folder is remembered).
     Busy (3) and the nightly or quiet window (5) leave the commit waiting for the
     next tick. Any other failure is counted; after three the commit is recorded
     START-FAILED rather than tried forever.

What it writes, all under <root>/watch/ (the M4: ~/m4run/watch/):
  verdict.txt   ONE line, the last settled commit — `m4_run.sh status` shows it:
                2026-11-18 02:31:07 5112b8697 suite GREEN — suite: GREEN app 13941 passed, ...
  tick.txt      one line: what the last tick saw and did
  history.log   every verdict line, newest last (the last 500)
  state.json    the above, for the next tick

It never signals a process, never pushes, never writes a branch, never opens a
catalog, and refuses to run anywhere but the M4 (this Macs own name; the Ultra by
name). Counts and verdict words only: the suite summary carries no media.

No apostrophes anywhere in this file (it may be shipped inside a heredoc).
Memory: the state (KBs) and one run.log at a time. Python 3.9 is the floor.
Tests: tests/test_m4_watch.py (a fake git, a fake runner, a fake clock; no network).
"""
from __future__ import annotations

import fcntl
import json
import os
import pwd
import re
import socket
import subprocess
import sys
import time

ALLOWED_HOSTS = frozenset({"ricksm4"})
FORBIDDEN_HOSTS = frozenset({"ricksultra"})
LANE = "suite"
REF = "refs/m4watch/main"
SETTLED_KEPT = 200                  # commits remembered as settled
HISTORY_KEPT = 500
RUN_ATTEMPTS = 2                    # a run that ended without an OUTCOME is retried once
START_FAILURES = 3
GIT_TIMEOUT = 180
START_TIMEOUT = 300
RAN = ("GREEN", "AMBER", "RED")     # an OUTCOME that means the commit was really run


def _number(value) -> float:
    """A stored number, or 0 for anything else (a poisoned state file is an empty one)."""
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def _count(table, key) -> int:
    value = table.get(key) if isinstance(table, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


class Watch:
    """One tick. Everything it touches is a parameter so the tests can stand in for it."""

    def __init__(self, root: str, repo: str, runner: str, hostname: str, git: str = "git", bash: str = "/bin/bash",
                 now=time.time):
        self.root, self.repo, self.runner, self.git, self.bash, self.now = root, repo, runner, git, bash, now
        self.hostname = hostname.split(".")[0].lower()
        self.dir = os.path.join(root, "watch")
        self.state = {}

    # -- small tools

    def stamp(self) -> str:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.now()))

    def write(self, name: str, text: str) -> None:
        """Whole or not at all: a temporary file beside it, then a rename."""
        path = os.path.join(self.dir, name)
        pending = "%s.%d" % (path, os.getpid())
        with open(pending, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(pending, path)

    def tick_line(self, words: str) -> str:
        line = "%s %s" % (self.stamp(), words)
        self.write("tick.txt", line + "\n")
        return line

    def load(self) -> None:
        try:
            with open(os.path.join(self.dir, "state.json"), encoding="utf-8") as f:
                value = json.load(f)
        except (OSError, ValueError):
            value = {}
        state = value if isinstance(value, dict) else {}
        settled = state.get("settled")
        self.state = {
            "settled": [row for row in settled if isinstance(row, list) and len(row) == 2] if isinstance(settled, list) else [],
            "base": state.get("base") if isinstance(state.get("base"), str) else None,
            "current": state.get("current") if isinstance(state.get("current"), dict) else None,
            "runs": state.get("runs") if isinstance(state.get("runs"), dict) else {},
            "start_failures": state.get("start_failures") if isinstance(state.get("start_failures"), dict) else {},
        }

    def save(self) -> None:
        self.state["settled"] = self.state["settled"][-SETTLED_KEPT:]
        known = {sha for sha, _ in self.state["settled"]}
        current = (self.state.get("current") or {}).get("sha")
        for table in ("runs", "start_failures"):               # counters live only as long as their commit matters
            self.state[table] = {sha: n for sha, n in self.state[table].items() if sha == current or sha not in known}
        self.write("state.json", json.dumps(self.state, indent=1, sort_keys=True) + "\n")

    def call(self, command: list, timeout: int):
        """(exit code, stdout). A command that cannot start or overruns is exit 124; it is never signalled
        beyond what subprocess does to its own child at the timeout."""
        try:
            done = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  universal_newlines=True, timeout=timeout)
            return done.returncode, done.stdout or ""
        except (OSError, subprocess.SubprocessError):
            return 124, ""

    def settled_verdict(self, sha: str):
        for known, verdict in reversed(self.state["settled"]):
            if known == sha:
                return verdict
        return None

    def settle(self, sha: str, verdict: str, words: str = "") -> str:
        """Record the commit as done with `verdict` and write the one verdict line."""
        self.state["settled"].append([sha, verdict])
        self.state["base"] = sha
        line = "%s %s %s %s%s" % (self.stamp(), sha[:9], LANE, verdict, (" — " + words) if words else "")
        self.write("verdict.txt", line + "\n")
        history = []
        try:
            with open(os.path.join(self.dir, "history.log"), encoding="utf-8", errors="replace") as f:
                history = f.read().splitlines()
        except OSError:
            pass
        self.write("history.log", "\n".join((history + [line])[-HISTORY_KEPT:]) + "\n")
        return line

    # -- reading runs back

    def outcome_of(self, out: str):
        """(verdict word or None, the first summary line) of a run folder. A refusal reads
        "REFUSED:<its first word>" (already-run, window, busy:, ...) so the tick can tell them apart."""
        verdict = None
        try:
            with open(os.path.join(out, "run.log"), encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("OUTCOME "):
                        parts = line.split()
                        verdict = parts[1] if len(parts) > 1 else None
                        if verdict == "REFUSED" and len(parts) > 2:
                            verdict = "REFUSED:" + parts[2]
                            if parts[2] == "already-run" and len(parts) > 3:
                                verdict += ":" + parts[3]
        except OSError:
            return None, ""
        summary = ""
        try:
            with open(os.path.join(out, "summary.txt"), encoding="utf-8", errors="replace") as f:
                summary = f.readline().strip()[:300]
        except OSError:
            pass
        return verdict, summary

    def lock_names(self, out: str) -> bool:
        """True while the testbed lock is held by the run whose folder is `out` (the kernel truth, then the holder words)."""
        lockdir = os.path.join(self.root, "lock")
        try:
            fd = os.open(os.path.join(lockdir, "flock"), os.O_RDWR)
        except OSError:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                try:
                    with open(os.path.join(lockdir, "info"), encoding="utf-8", errors="replace") as f:
                        return ("out=" + out) in f.read()
                except OSError:
                    return False
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False
        finally:
            os.close(fd)

    def already_run(self, sha: str):
        """The verdict of a suite or testbed run of this commit already under <root>/out, started by anyone."""
        out = os.path.join(self.root, "out")
        try:
            names = sorted(os.listdir(out), reverse=True)
        except OSError:
            return None
        for name in names:
            if not name.endswith(("-suite", "-testbed")):
                continue
            path = os.path.join(out, name)
            try:
                with open(os.path.join(path, "run.log"), encoding="utf-8", errors="replace") as f:
                    head = f.read(4000)
            except OSError:
                continue
            if ("sha=" + sha) in head:
                verdict, _ = self.outcome_of(path)
                if verdict in RAN:
                    return verdict
        return None

    def docs_only(self, base, head: str) -> bool:
        if not base or base == head:
            return False
        code, _ = self.call([self.git, "-C", self.repo, "merge-base", "--is-ancestor", base, head], GIT_TIMEOUT)
        if code != 0:
            return False                                        # unknown range: never called docs-only
        code, text = self.call([self.git, "-C", self.repo, "diff", "--name-only", base, head], GIT_TIMEOUT)
        paths = [line for line in text.splitlines() if line.strip()]
        return code == 0 and bool(paths) and all(p.startswith("docs/") or p.endswith(".md") for p in paths)

    # -- the tick

    def refused(self):
        if self.hostname in FORBIDDEN_HOSTS:
            return "refused: this is %s (the M5 Ultra); the push watcher runs only on the M4" % self.hostname
        if self.hostname not in ALLOWED_HOSTS:
            return "refused: host %s is not the M4; the push watcher runs only on the M4" % (self.hostname or "?")
        return None

    def tick(self) -> str:
        no = self.refused()
        if no:
            return no                                           # before anything is created
        os.makedirs(self.dir, exist_ok=True)
        fd = os.open(os.path.join(self.dir, "lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return "another tick is still running"
            self.load()
            try:
                return self.tick_line(self.decide())
            finally:
                self.save()
        finally:
            os.close(fd)

    def decide(self) -> str:
        code, _ = self.call([self.git, "-C", self.repo, "fetch", "--quiet", "origin", "+refs/heads/main:" + REF], GIT_TIMEOUT)
        if code != 0:
            return "could not fetch origin/main (git exit %d) — nothing done" % code
        code, text = self.call([self.git, "-C", self.repo, "rev-parse", "--verify", "--quiet", REF + "^{commit}"], GIT_TIMEOUT)
        head = text.strip()
        if code != 0 or not re.fullmatch(r"[0-9a-f]{40}", head):
            return "could not read origin/main after the fetch — nothing done"
        saw = "saw %s" % head[:9]

        current = self.state.get("current")
        if current:
            sha, out = str(current.get("sha")), str(current.get("out"))
            verdict, summary = self.outcome_of(out)
            if verdict in RAN or verdict == "NORUN":
                self.state["current"] = None
                self.settle(sha, verdict, summary)
                saw += " — the run of %s ended %s" % (sha[:9], verdict)
            elif verdict is not None and verdict.startswith("REFUSED:already-run:") and verdict.split(":")[2] in RAN:
                # The host found, UNDER the lock, a run of this commit that reached a verdict: one
                # by hand that finished after this tick looked (Codex #315-5). Recorded, not run.
                self.state["current"] = None
                self.state["runs"][sha] = max(0, (_count(self.state["runs"], sha) or 1) - 1)
                self.settle(sha, verdict.split(":")[2], "run by hand under %s/out; not run again" % os.path.basename(self.root))
                saw += " — %s was already run (%s), found under the lock: recorded, not run again" % (sha[:9], verdict.split(":")[2])
            elif verdict is not None and verdict.split(":")[1:2] in (["window"], ["busy"]):
                # It reached the lock after a window opened, or behind another run: the commit is not at fault.
                self.state["current"] = None
                self.state["runs"][sha] = max(0, (_count(self.state["runs"], sha) or 1) - 1)
                saw += " — the start of %s waited (%s): tried again next tick" % (sha[:9], verdict.split(":")[1])
            elif verdict is not None:                           # REFUSED: it never ran (a dirty testbed, ...)
                self.state["current"] = None
                self.state["runs"][sha] = max(0, (_count(self.state["runs"], sha) or 1) - 1)
                failures = _count(self.state["start_failures"], sha) + 1
                self.state["start_failures"][sha] = failures
                saw += " — the start of %s was refused on the host (%s)" % (sha[:9], verdict)
                if failures >= START_FAILURES:
                    self.settle(sha, "START-FAILED", "the host refused it %d times (%s)" % (failures, verdict))
            elif self.lock_names(out) or self.now() - _number(current.get("started")) < 120:
                return saw + " — the run of %s is still going" % sha[:9]
            else:
                self.state["current"] = None
                if _count(self.state["runs"], sha) >= RUN_ATTEMPTS:
                    self.settle(sha, "NO-OUTCOME", "ended without an OUTCOME twice (a logout of the GUI session, a restart)")
                    saw += " — the run of %s ended without an OUTCOME again: recorded" % sha[:9]
                else:
                    saw += " — the run of %s ended without an OUTCOME: one retry" % sha[:9]
                    if sha != head:
                        self.settle(sha, "NO-OUTCOME", "ended without an OUTCOME; a newer commit is on main, so no retry")

        known = self.settled_verdict(head)
        if known:
            return saw + " — nothing to do (settled %s)" % known
        earlier = self.already_run(head)
        if earlier and _count(self.state["runs"], head) == 0:
            self.settle(head, earlier, "run by hand under %s/out; not run again" % os.path.basename(self.root))
            return saw + " — already run by hand (%s): recorded, not run again" % earlier
        base = self.state.get("base")
        if self.docs_only(base, head):
            self.settle(head, "SKIPPED", "docs-only since %s" % str(base)[:9])
            return saw + " — docs-only since %s: skipped" % str(base)[:9]
        if _count(self.state["runs"], head) >= RUN_ATTEMPTS:
            self.settle(head, "NO-OUTCOME", "ended without an OUTCOME twice")
            return saw + " — given up after %d runs without an OUTCOME" % RUN_ATTEMPTS
        return saw + " — " + self.start(head)

    def start(self, sha: str) -> str:
        code, text = self.call([self.bash, self.runner, LANE, "--host", "m4local", "--ref", sha, "--unless-ran"], START_TIMEOUT)
        if code == 0:
            m = re.search(r"started — output (\S+)", text)
            if m:
                self.state["runs"][sha] = _count(self.state["runs"], sha) + 1
                self.state["current"] = {"sha": sha, "out": m.group(1), "started": self.now()}
                return "started the %s lane (run %d of at most %d)" % (LANE, self.state["runs"][sha], RUN_ATTEMPTS)
            code = 1
        if code == 3:
            return "the testbed is busy: waiting for the next tick"
        if code == 5:
            return "inside the nightly or quiet window: waiting for the next tick"
        failures = _count(self.state["start_failures"], sha) + 1
        self.state["start_failures"][sha] = failures
        if failures >= START_FAILURES:
            self.settle(sha, "START-FAILED", "the runner would not start it %d times (exit %d)" % (failures, code))
            return "the runner would not start (exit %d) for the %dth time: recorded START-FAILED" % (code, failures)
        return "the runner would not start (exit %d); failure %d of %d" % (code, failures, START_FAILURES)

    def status(self) -> str:
        lines = []
        for name, label in (("verdict.txt", "watch verdict"), ("tick.txt", "watch last tick")):
            try:
                with open(os.path.join(self.dir, name), encoding="utf-8", errors="replace") as f:
                    lines.append("%s: %s" % (label, f.readline().strip()))
            except OSError:
                lines.append("%s: none yet" % label)
        return "\n".join(lines)


def here() -> Watch:
    home = pwd.getpwuid(os.getuid()).pw_dir                    # the account database, not $HOME
    return Watch(root=os.path.join(home, "m4run"), repo=os.path.join(home, "dev", "VideoScan"),
                 runner=os.path.join(os.path.dirname(os.path.abspath(__file__)), "m4_run.sh"),
                 hostname=socket.gethostname())


def main(argv: list, watch=None) -> int:
    if argv not in (["tick"], ["status"]):
        print(__doc__, file=sys.stderr)
        return 2
    watch = watch or here()
    if argv == ["status"]:
        print(watch.status())
        return 0
    line = watch.tick()
    print(line)
    return 1 if line.startswith("refused") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
