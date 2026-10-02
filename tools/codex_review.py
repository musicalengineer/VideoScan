#!/usr/bin/env python3
"""One command for a whole codex review cycle (Rick, 2026-09-26/27).

    python3 tools/codex_review.py --title "⌘O" --range de54a7ca..48708aba \
        --brief docs/reviews/briefs/<file>.md [--doc docs/reviews/codex/codex-review-<slug>-<date>.md] \
        [--timeout 1800]
    python3 tools/codex_review.py close --title "⌘O" --closed-by <sha> [--note "..."]
    python3 tools/codex_review.py status
    python3 tools/codex_review.py track --title "Map stage 1" --range a..b [--doc …] [--message-id N]
        (a review codex runs interactively via the channel — shows on the status line)
    python3 tools/codex_review.py verdict --title "Map stage 1" --verdict fix --findings 3 [--credits …]

Phases, each written to the state file the menu-bar monitor reads:
    briefed  -> brief validated, "started" message posted to codex on the channel
    running  -> `codex exec` is running (pid recorded, --timeout enforced)
    verdict  -> output parsed, review doc written, reply posted
    closed   -> verdict merge with 0 findings, or `close` run after the fixes
    fixing   -> findings to close
    failed   -> timeout, codex error, or output that breaks the contract

The brief must carry the output contract codex answers with:
    first line:  Credits spent: <amount> | Finding count: <N>
    and a line:  Verdict: <merge | fix | block> ...

CRITICAL: codex runs with stdin = /dev/null. With an inherited open stdin,
`codex exec` prints "Reading additional input from stdin" and waits forever.

Stdlib only. Test seams (environment):
    VIDEOSCAN_REVIEW_CYCLES     state file (default: beside the channel DB)
    VIDEOSCAN_TEAM_CHANNEL_DB   channel DB (honoured by tools/team-channel.py)
    VIDEOSCAN_CODEX_BIN         codex executable (default ~/.local/bin/codex)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHANNEL_SCRIPT = REPO / "tools" / "team-channel.py"
DEFAULT_CHANNEL_DB = (
    Path.home() / "Library" / "Application Support" / "VideoScan" / "team-channel" / "team-channel.sqlite3"
)
MAX_CYCLES = 20
MAX_SUBJECT = 160

CONTRACT_RE = re.compile(r"Credits spent:.*Finding count:", re.IGNORECASE)
FINDINGS_RE = re.compile(r"Finding count:\s*\**\s*(\d+)", re.IGNORECASE)
CREDITS_RE = re.compile(r"Credits spent:\s*\**\s*([^|\n]*?)\s*\**\s*(?:\||$)", re.IGNORECASE | re.MULTILINE)
VERDICT_RE = re.compile(r"^[\s>*_#-]*Verdict\s*:\s*\**\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
TOKENS_RE = re.compile(r"tokens used\s*\n\s*([\d,]+)", re.IGNORECASE)


# ---------------------------------------------------------------- paths/time

def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def channel_db_path() -> Path:
    override = os.environ.get("VIDEOSCAN_TEAM_CHANNEL_DB")
    return Path(override).expanduser() if override else DEFAULT_CHANNEL_DB


def state_path() -> Path:
    override = os.environ.get("VIDEOSCAN_REVIEW_CYCLES")
    if override:
        return Path(override).expanduser()
    # Same directory the monitor already reads (ChannelDB.path's parent).
    return channel_db_path().parent / "review-cycles.json"


def output_dir() -> Path:
    return state_path().parent / "review-cycles"


def codex_bin() -> str:
    return os.environ.get("VIDEOSCAN_CODEX_BIN") or str(Path.home() / ".local" / "bin" / "codex")


# ---------------------------------------------------------------- state file

@contextmanager
def locked_state():
    """Read-modify-write the cycle list under an exclusive lock; yields the list."""
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cycles = load_cycles(path)
        yield cycles
        save_cycles(cycles, path)


def load_cycles(path: Path | None = None) -> list[dict]:
    path = path or state_path()
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    return [c for c in data if isinstance(c, dict)] if isinstance(data, list) else []


def save_cycles(cycles: list[dict], path: Path | None = None) -> None:
    """Keep the newest MAX_CYCLES; write temp + rename so a reader never sees half a file."""
    path = path or state_path()
    cycles.sort(key=lambda c: c.get("id", 0))
    dropped, kept = cycles[:-MAX_CYCLES], cycles[-MAX_CYCLES:]
    cycles[:] = kept
    fd, tmp = tempfile.mkstemp(prefix=".review-cycles.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(kept, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    # The tool's own stdout/stderr captures go with their cycle.
    for cycle in dropped:
        for suffix in (".stdout", ".stderr"):
            (output_dir() / f"{cycle.get('id')}{suffix}").unlink(missing_ok=True)


def update_cycle(cycle_id: int, **fields) -> dict:
    with locked_state() as cycles:
        for cycle in cycles:
            if cycle.get("id") == cycle_id:
                if "phase" in fields and fields["phase"] != cycle.get("phase"):
                    fields.setdefault("phaseSince", utc_now())
                cycle.update(fields)
                return dict(cycle)
    raise KeyError(f"cycle {cycle_id} vanished from {state_path()}")


def new_cycle(title: str, rng: str, doc: str) -> dict:
    with locked_state() as cycles:
        now = utc_now()
        cycle = {
            "id": max((c.get("id", 0) for c in cycles), default=0) + 1,
            "title": title, "range": rng, "phase": "briefed", "phaseSince": now,
            "startedAt": now, "messageIDs": [], "pid": None, "doc": doc,
            "tokens": None, "findings": None, "verdict": None, "failure": None,
        }
        cycles.append(cycle)
        return dict(cycle)


# ---------------------------------------------------------------- channel

def post(subject: str, body: str, reply_to: int | None = None) -> int | None:
    """Optionally post a review-cycle line to the team channel.

    OFF by default (Rick, 2026-09-27). The first version posted every start /
    verdict / closed line "to codex"; codex is run directly by `codex exec`
    and never replies on the channel, so Rick's monitor showed 19 red
    "unanswered from codex" rows. The record of a cycle is review-cycles.json
    (the monitor's Review cycles section + the status line) and the review
    doc. Set VIDEOSCAN_REVIEW_ANNOUNCE=1 to post anyway (e.g. when a human
    should see it in the channel). A channel failure never fails the review.
    """
    if os.environ.get("VIDEOSCAN_REVIEW_ANNOUNCE") != "1":
        return None
    args = [sys.executable, str(CHANNEL_SCRIPT), "post", "--from", "claude", "--to", "codex",
            "--subject", subject[:MAX_SUBJECT], "--body", body]
    if reply_to is not None:
        args += ["--reply-to", str(reply_to)]
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    match = re.search(r"Posted #(\d+)", result.stdout)
    if result.returncode != 0 or not match:
        print(f"codex_review: channel post failed: {result.stderr.strip() or result.stdout.strip()}",
              file=sys.stderr)
        return None
    return int(match.group(1))


# ---------------------------------------------------------------- parsing

def validate_brief(text: str) -> str | None:
    """Return a reason the brief is unusable, or None."""
    if not text.strip():
        return "brief is empty"
    if not CONTRACT_RE.search(text):
        return "brief lacks the first-line contract 'Credits spent: … | Finding count: N'"
    if not re.search(r"Verdict\s*:", text, re.IGNORECASE):
        return "brief lacks the 'Verdict:' line of the output contract"
    return None


def parse_output(stdout: str, stderr: str) -> dict:
    """Pull the contract out of codex's answer. The LAST match wins: the answer
    comes after anything echoed earlier (e.g. the brief's own contract text)."""
    findings = FINDINGS_RE.findall(stdout)
    verdicts = VERDICT_RE.findall(stdout)
    if not findings:
        return {"failure": "malformed output: no 'Finding count: N'"}
    if not verdicts:
        return {"failure": "malformed output: no 'Verdict:' line"}
    verdict_text = verdicts[-1].strip("* ")
    word = re.match(r"[A-Za-z]+(?:-[A-Za-z]+)*", verdict_text)
    credits = CREDITS_RE.findall(stdout)
    tokens = TOKENS_RE.findall(stderr)
    return {
        "findings": int(findings[-1]),
        "verdict": word.group(0).lower() if word else verdict_text.lower(),
        "verdictText": verdict_text,
        "credits": credits[-1].strip() if credits else None,
        "tokens": int(tokens[-1].replace(",", "")) if tokens else None,
    }


def slug(title: str, rng: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s or rng.split("..")[0][:8]


def resolve(path: str) -> Path:
    p = Path(path).expanduser()
    if p.is_absolute() or p.exists():
        return p.resolve()
    return REPO / p


def display(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO))
    except ValueError:
        return str(path)


def write_doc(doc: Path, cycle: dict, parsed: dict, stdout: str, brief_text: str) -> None:
    header = [
        f"# Codex review — {cycle['title']}",
        "",
        f"- Range: `{cycle['range']}`",
        f"- Credits spent: {parsed.get('credits') or 'not reported'}",
        f"- Tokens: {parsed['tokens'] if parsed.get('tokens') is not None else 'not reported'}",
        f"- Finding count: {parsed['findings']}",
        f"- Verdict: {parsed['verdictText']}",
        f"- Run: {cycle['startedAt']} (cycle #{cycle['id']}, tools/codex_review.py)",
        "",
        "## Codex answer",
        "",
        stdout.strip(),
        "",
        "## Brief",
        "",
        brief_text.strip(),
        "",
    ]
    doc.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(header)
    if doc.exists() and doc.read_text().strip():
        text = doc.read_text().rstrip() + "\n\n---\n\n" + text
    doc.write_text(text)


# ---------------------------------------------------------------- run

def fail(cycle: dict, reason: str) -> int:
    update_cycle(cycle["id"], phase="failed", failure=reason)
    start = cycle["messageIDs"][0] if cycle["messageIDs"] else None
    post(f"Review {cycle['title']} — failed: {reason}",
         f"Cycle #{cycle['id']} ({cycle['range']}) failed: {reason}. Output: {output_dir()}/{cycle['id']}.*",
         start)
    print(f"FAILED: {reason}", file=sys.stderr)
    return 1


def run_review(title: str, rng: str, brief: str, doc: str | None, timeout: float) -> int:
    brief_path = resolve(brief)
    try:
        brief_text = brief_path.read_text()
    except OSError as error:
        print(f"codex_review: cannot read brief {brief_path}: {error}", file=sys.stderr)
        return 2
    problem = validate_brief(brief_text)
    if problem:
        print(f"codex_review: {problem} ({brief_path})", file=sys.stderr)
        return 2
    doc_path = resolve(doc) if doc else REPO / "docs" / "reviews" / "codex" / (
        f"codex-review-{slug(title, rng)}-{datetime.now().strftime('%Y-%m-%d')}.md")

    # briefed
    cycle = new_cycle(title, rng, display(doc_path))
    start_id = post(f"Review {title} ({rng}) — started",
                    f"Brief: {display(brief_path)}\nRange: {rng}\nCycle #{cycle['id']}")
    cycle = update_cycle(cycle["id"], messageIDs=[start_id] if start_id else [])

    # running
    out_dir = output_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    stdout_file = out_dir / f"{cycle['id']}.stdout"
    stderr_file = out_dir / f"{cycle['id']}.stderr"
    command = [codex_bin(), "exec", "--sandbox", "read-only", "-C", str(REPO),
               "--skip-git-repo-check", brief_text]
    with open(stdout_file, "w") as out, open(stderr_file, "w") as err:
        try:
            # stdin=DEVNULL is the point: an open stdin makes codex wait forever.
            # start_new_session ≈ setsid(), so a timeout can kill codex's children too.
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    start_new_session=True)
        except OSError as error:
            return fail(cycle, f"cannot start codex: {error}")
        cycle = update_cycle(cycle["id"], phase="running", pid=proc.pid)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            return fail(cycle, "timeout")
        except KeyboardInterrupt:
            kill_group(proc)
            fail(cycle, "interrupted")
            return 130

    stdout = stdout_file.read_text(errors="replace")
    stderr = stderr_file.read_text(errors="replace")
    if code != 0:
        return fail(cycle, f"codex exit {code}")
    parsed = parse_output(stdout, stderr)
    if "failure" in parsed:
        return fail(cycle, parsed["failure"])

    # verdict
    cycle = update_cycle(cycle["id"], phase="verdict", tokens=parsed["tokens"],
                         findings=parsed["findings"], verdict=parsed["verdict"])
    write_doc(doc_path, cycle, parsed, stdout, brief_text)
    reply = post(f"Review {title} — {parsed['verdict']}, {parsed['findings']} findings → {display(doc_path)}",
                 f"Verdict: {parsed['verdictText']}\nTokens: {parsed['tokens']}\nDoc: {display(doc_path)}",
                 start_id)
    done = parsed["verdict"] == "merge" and parsed["findings"] == 0
    fields = {"phase": "closed" if done else "fixing",
              "messageIDs": cycle["messageIDs"] + ([reply] if reply else [])}
    if done:
        fields["closedBy"] = rng.split("..")[-1]
    update_cycle(cycle["id"], **fields)
    print(f"{title}: {parsed['verdict']}, {parsed['findings']} findings → {display(doc_path)}"
          f" ({fields['phase']})")
    return 0


def kill_group(proc: subprocess.Popen) -> None:
    for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


# ---------------------------------------------------------------- close/status

def close_cycle(title: str, closed_by: str, note: str | None) -> int:
    matches = [c for c in load_cycles() if c.get("title") == title]
    if not matches:
        print(f"codex_review: no cycle titled {title!r}", file=sys.stderr)
        return 2
    cycle = max(matches, key=lambda c: c.get("id", 0))
    ids = list(cycle.get("messageIDs") or [])
    start = ids[0] if ids else None
    reply = post(f"Review {title} — closed by {closed_by}",
                 f"Cycle #{cycle['id']} ({cycle.get('range')}) closed by {closed_by}."
                 + (f"\n{note}" if note else ""), start)
    update_cycle(cycle["id"], phase="closed", closedBy=closed_by, note=note,
                 messageIDs=ids + ([reply] if reply else []))
    if cycle.get("doc"):
        doc = resolve(cycle["doc"])
        if doc.exists():
            with open(doc, "a") as handle:
                handle.write(f"\n## Closed\n\nClosed by `{closed_by}` at {utc_now()}."
                             + (f" {note}" if note else "") + "\n")
    print(f"{title}: closed by {closed_by}")
    return 0


def age_words(since: str | None, now: datetime | None = None) -> str:
    try:
        then = datetime.strptime(since or "", "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return "?"
    minutes = int(((now or datetime.now(timezone.utc)) - then).total_seconds() // 60)
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 24 * 60:
        return f"{minutes // 60}h {minutes % 60}m"
    return f"{minutes // (24 * 60)}d"


def status_lines(cycles: list[dict], now: datetime | None = None) -> list[str]:
    lines = []
    for c in sorted(cycles, key=lambda c: c.get("id", 0), reverse=True)[:5]:
        phase = c.get("phase", "?")
        extra = ""
        if phase == "closed":
            extra = f" by {c['closedBy']}" if c.get("closedBy") else ""
        elif phase == "failed":
            extra = f" ({c.get('failure')})"
        elif phase == "running":
            extra = f" pid {c.get('pid')}"
        result = (f"  {c.get('verdict')}/{c.get('findings')}" if c.get("verdict") else "")
        lines.append(f"#{c.get('id')} {c.get('title')} ({c.get('range')}) — {phase}{extra}"
                     f" {age_words(c.get('phaseSince'), now)}{result}"
                     + (f"  {c['doc']}" if c.get("doc") else ""))
    return lines


# ---------------------------------------------------------------- CLI

def track_cycle(title: str, rng: str, doc: str | None, message_id: int | None) -> int:
    """Register a review that codex runs INTERACTIVELY (Rick's own codex
    session, driven by team-channel messages) so the status line and the
    menu-bar monitor show it like a `codex exec` cycle (2026-09-29: three
    Family Map handoffs went through the channel and the line stayed empty).
    Phase `briefed` until `verdict`/`close`; the colour then says how long
    codex has had it."""
    cycle = new_cycle(title, rng, doc or "")
    if message_id is not None:
        update_cycle(cycle["id"], messageIDs=[message_id])
    print(f"#{cycle['id']} {title} ({rng}): tracking (briefed)")
    return 0


def record_verdict(title: str, verdict: str, findings: int, credits: str | None) -> int:
    """Record a verdict codex posted on the channel: `fixing` when there is
    anything to close, `closed` when a merge verdict carries no findings."""
    matches = [c for c in load_cycles() if c.get("title") == title]
    if not matches:
        print(f"codex_review: no cycle titled {title!r}", file=sys.stderr)
        return 2
    cycle = max(matches, key=lambda c: c.get("id", 0))
    done = findings == 0 and verdict.lower().startswith("merge")
    update_cycle(cycle["id"], phase="closed" if done else "fixing", verdict=verdict,
                 findings=findings, credits=credits,
                 **({"closedBy": "verdict"} if done else {}))
    print(f"#{cycle['id']} {title}: {verdict}/{findings}" + (" (closed)" if done else " (fixing)"))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["track"]:
        parser = argparse.ArgumentParser(prog="codex_review.py track")
        parser.add_argument("--title", required=True)
        parser.add_argument("--range", required=True, dest="rng")
        parser.add_argument("--doc")
        parser.add_argument("--message-id", type=int)
        args = parser.parse_args(argv[1:])
        return track_cycle(args.title, args.rng, args.doc, args.message_id)
    if argv[:1] == ["verdict"]:
        parser = argparse.ArgumentParser(prog="codex_review.py verdict")
        parser.add_argument("--title", required=True)
        parser.add_argument("--verdict", required=True)
        parser.add_argument("--findings", required=True, type=int)
        parser.add_argument("--credits")
        args = parser.parse_args(argv[1:])
        return record_verdict(args.title, args.verdict, args.findings, args.credits)
    if argv[:1] == ["status"]:
        lines = status_lines(load_cycles())
        print("\n".join(lines) if lines else "(no review cycles)")
        return 0
    if argv[:1] == ["close"]:
        parser = argparse.ArgumentParser(prog="codex_review.py close")
        parser.add_argument("--title", required=True)
        parser.add_argument("--closed-by", required=True)
        parser.add_argument("--note")
        args = parser.parse_args(argv[1:])
        return close_cycle(args.title, args.closed_by, args.note)
    parser = argparse.ArgumentParser(prog="codex_review.py",
                                     description="Run one codex review cycle (see module docstring).")
    parser.add_argument("--title", required=True)
    parser.add_argument("--range", required=True, dest="rng")
    parser.add_argument("--brief", required=True)
    parser.add_argument("--doc")
    parser.add_argument("--timeout", type=float, default=1800)
    args = parser.parse_args(argv)
    return run_review(args.title, args.rng, args.brief, args.doc, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
