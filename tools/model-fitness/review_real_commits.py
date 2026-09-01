#!/usr/bin/env python3
"""Turn a local model loose on REAL commits and see whether it is adequate.

Rick, 2026-08-31: "Overnight, can you have the model of your choice perform
some code reviews to see if it is adequate?"

WHY THIS AND NOT THE SYNTHETIC CORPUS.  fitness_corpus.jsonl is saturated —
both dense models score 29/29, so it can no longer tell them apart, and every
case in it is a defect I already knew about and wrote the prompt around.  This
runs the model over commits that were actually written, reviewed and tested
today.

THE TEST IS INVERTED ON PURPOSE.  These commits are believed CORRECT.  A
reviewer's usefulness is decided by what it says about code that is already
fine: the failure that makes an LLM reviewer worthless is not missing a bug,
it is crying wolf until you stop reading it.  So the expected result for most
commits is NO FINDINGS, and the headline number is the false-positive rate,
not the hit count.

Anything it does flag is worth reading twice — today proved these commits are
not above having defects in them.

    python3 tools/model-fitness/review_real_commits.py \\
        --model qwen3.8:27b-mlx --count 21
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Enough for a real diff, short of the point where a 262K-context model starts
# losing the middle of it.
MAX_DIFF_CHARS = 60_000

SYSTEM = (
    "You are a senior Swift and Python reviewer on a personal media-archive "
    "project. You are given one commit. Report ONLY defects you are confident "
    "are real: correctness bugs, concurrency hazards, data-loss risks, "
    "resource leaks, or a test that cannot fail.\n\n"
    "Do NOT report style, naming, formatting, missing documentation, or "
    "hypothetical improvements. Do NOT speculate about code you cannot see.\n\n"
    "If you find nothing you are confident about, reply with exactly:\n"
    "NO FINDINGS\n\n"
    "Otherwise, for each finding give: the file and line, one sentence saying "
    "what is wrong, and one concrete case where it produces a wrong result."
)


def configured_model() -> str:
    """Whatever Settings ▸ Archivist Brain is set to, else the shipped default.

    One dropdown governs both Hallie and this reviewer. Hard-coding a second
    copy of the tag here is how the app and its tools end up disagreeing about
    which brain is in use — the same five-copies problem the Swift side just
    finished collapsing into HallieBrain.defaultModel.
    """
    try:
        out = subprocess.run(
            ["defaults", "read", "Rick-Breen.VideoScan", "archivist.ollamaModel"],
            capture_output=True, text=True, timeout=5)
        tag = out.stdout.strip()
        if out.returncode == 0 and tag:
            return tag
    except Exception:                                 # noqa: BLE001
        pass
    return "qwen3.8:27b-mlx"


def units(args: argparse.Namespace) -> list[tuple[str, str, str]]:
    """(label, subject, diff) for whatever the caller asked to review."""
    def run(cmd: list[str]) -> str:
        return subprocess.run(cmd, capture_output=True, text=True,
                              check=True).stdout

    if args.working or args.staged:
        staged = ["--cached"] if args.staged else []
        diff = run(["git", "diff", *staged, "--stat", "--patch"])
        if not diff.strip():
            return []
        what = "staged changes" if args.staged else "working tree"
        return [("local", what, diff)]

    if args.range:
        shas = run(["git", "log", "--no-merges", "--format=%H%x00%s",
                    args.range]).splitlines()
    else:
        shas = run(["git", "log", "--no-merges", f"-{args.count}",
                    "--format=%H%x00%s"]).splitlines()
    out = []
    for line in shas:
        if "\0" not in line:
            continue
        sha, subject = line.split("\0", 1)
        out.append((sha[:8], subject, diff_of(sha)))
    return out


def commits(count: int) -> list[tuple[str, str]]:
    """(sha, subject) newest first, merges excluded."""
    out = subprocess.run(
        ["git", "log", "--no-merges", f"-{count}", "--format=%H%x00%s"],
        capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        if "\0" in line:
            sha, subject = line.split("\0", 1)
            rows.append((sha, subject))
    return rows


def diff_of(sha: str) -> str:
    text = subprocess.run(
        ["git", "show", sha, "--stat", "--patch", "--format=%s%n%n%b"],
        capture_output=True, text=True, check=True).stdout
    if len(text) > MAX_DIFF_CHARS:
        text = text[:MAX_DIFF_CHARS] + "\n\n[diff truncated]"
    return text


def ask(endpoint: str, model: str, prompt: str, timeout: float) -> tuple[str, float, str | None]:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0, "seed": 101},
    }).encode()
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/api/chat", data=body,
        headers={"Content-Type": "application/json"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read())
    except Exception as exc:                      # noqa: BLE001 - report, never raise
        return "", time.monotonic() - started, str(exc)
    answer = (payload.get("message") or {}).get("content", "")
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S).strip()
    return answer, time.monotonic() - started, None


def clean(answer: str) -> bool:
    """True when the model reported nothing."""
    head = answer.strip().upper()
    return head.startswith("NO FINDINGS") or head == "NO FINDINGS."


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model", default=None,
                        help="default: whatever Settings > Archivist Brain is set to")
    parser.add_argument("--endpoint", default="http://localhost:11434")
    parser.add_argument("--count", type=int, default=21,
                        help="review the last N commits (default)")
    parser.add_argument("--range", default=None,
                        help="a git range, e.g. origin/main..HEAD")
    parser.add_argument("--staged", action="store_true",
                        help="review what is staged, before you commit it")
    parser.add_argument("--working", action="store_true",
                        help="review the working tree, committed or not")
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)
    args.model = args.model or configured_model()

    stamp = time.strftime("%Y%m%d-%H%M")
    out = Path(args.out or (Path.home() / "Library/Logs/VideoScan"
                            / f"real-review-{stamp}"))
    out.mkdir(parents=True, exist_ok=True)

    rows = units(args)
    if not rows:
        print("nothing to review")
        return 0
    print(f"model    {args.model}")
    print(f"units    {len(rows)}")
    print(f"out      {out}\n", flush=True)

    flagged, quiet, broken = [], [], []
    for index, (short, subject, diff) in enumerate(rows, 1):
        prompt = ("Review this change.\n\n```diff\n" + diff + "\n```")
        answer, seconds, error = ask(args.endpoint, args.model, prompt, args.timeout)

        if error:
            broken.append((short, subject, error))
            state = "ERROR"
        elif clean(answer):
            quiet.append((short, subject))
            state = "quiet"
        else:
            flagged.append((short, subject, answer))
            state = "FLAGGED"

        (out / f"{index:02d}-{short}.md").write_text(
            f"# {short}  {subject}\n\n"
            f"- model: {args.model}\n- seconds: {seconds:.1f}\n"
            f"- verdict: {state}\n\n---\n\n{error or answer}\n")
        print(f"[{index:>2}/{len(rows)}] {state:<8} {short}  {subject[:56]}"
              f"   {seconds:>5.0f}s", flush=True)

    total = len(rows)
    print(f"\n{'=' * 64}")
    print(f"{args.model} over {total} change(s)")
    print(f"{'=' * 64}")
    print(f"  quiet (NO FINDINGS)  {len(quiet):>3}/{total}")
    print(f"  flagged              {len(flagged):>3}/{total}"
          f"   <- read every one of these")
    print(f"  transport errors     {len(broken):>3}/{total}")
    if total:
        print(f"\n  flag rate on correct code: {len(flagged) / total:.0%}")
        print("  (high is bad: a reviewer that cries wolf stops being read)")
    if flagged:
        print("\nflagged commits:")
        for short, subject, _ in flagged:
            print(f"  {short}  {subject[:64]}")

    # Built as a list, not one chained f-string: implicit concatenation binds
    # tighter than a conditional expression, so `f"a" f"b" if total else ""`
    # silently dropped every section after it.
    lines = [f"# Real-commit review — {args.model}", ""]
    lines.append(f"{total} commits believed correct. "
                 f"Quiet {len(quiet)}, flagged {len(flagged)}, "
                 f"errors {len(broken)}.")
    if total:
        lines.append("")
        lines.append(f"Flag rate on correct code: **{len(flagged) / total:.0%}** "
                     f"— high is bad; a reviewer that cries wolf stops being read.")
    lines += ["", "## Flagged — read every one", ""]
    lines += [f"- `{s}` {subj}" for s, subj, _ in flagged] or ["_none_"]
    lines += ["", "## Quiet", ""]
    lines += [f"- `{s}` {subj}" for s, subj in quiet] or ["_none_"]
    if broken:
        lines += ["", "## Transport errors", ""]
        lines += [f"- `{s}` {subj} — {err}" for s, subj, err in broken]
    summary = out / "SUMMARY.md"
    summary.write_text("\n".join(lines) + "\n")
    print(f"\nwrote {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
