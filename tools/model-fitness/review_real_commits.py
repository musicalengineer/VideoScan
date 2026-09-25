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
    """Hallie's configured brain — a LAST RESORT for this script, not a default.

    Reading the app's `archivist.ollamaModel` here coupled the nightly code
    reviewer to the family archivist's brain: changing the model in Settings
    changed the reviewer (codex #1147, 2026-09-06). nightly_review.sh now
    always passes --model, so this fallback only fires for a hand-run with
    no flag, and it warns when it does.
    """
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
    # Commits a PREVIOUS run never actually reviewed — it timed out on them or
    # ollama was down — carried forward by nightly_review.sh so a review that
    # errored is retried instead of being skipped for good (2026-09-07). They
    # are usually already outside the range, so they are appended, then the
    # whole list is deduped by sha.
    for sha in [c.strip() for c in (args.also_commits or "").split(",") if c.strip()]:
        try:
            shas.append(run(["git", "log", "--no-walk", "--format=%H%x00%s",
                             sha]).strip())
        except subprocess.CalledProcessError:
            print(f"warning: carried-forward commit {sha} is no longer in this "
                  f"repo; dropping it", file=sys.stderr)
    out, seen = [], set()
    for line in shas:
        if "\0" not in line:
            continue
        sha, subject = line.split("\0", 1)
        if sha in seen:
            continue
        seen.add(sha)
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


# How long one review may take, and how long a reply may run (2026-09-25).
#
# qwen3.8 is a THINKING model: on a 40 KB diff (Angel Checks, 9d7df1e8) it
# reasoned past the old 600 s ceiling and past a hand-passed 900 s, so the
# commit came back as a transport error and was never reviewed. The wait
# goes to 40 min, and the reply (thinking included) is capped at
# NUM_PREDICT tokens so a runaway answer ends instead of holding the model.
DEFAULT_TIMEOUT_SECONDS = 2400.0
NUM_PREDICT = 8192


def interpret(payload: dict, num_predict: int = NUM_PREDICT) -> tuple[str, str | None]:
    """(answer, error) from an /api/chat reply. Pure — table-tested.

    A reply cut off by the NUM_PREDICT cap (done_reason "length") is an
    ERROR, never a finding: half a thought is not a verdict, and an
    unclosed <think> block would otherwise be read as a flagged review.
    """
    answer = (payload.get("message") or {}).get("content", "")
    if payload.get("done_reason") == "length":
        return "", (f"reply cut off at the {num_predict}-token cap before an answer "
                    f"(raise --num-predict): " + answer[-200:].replace("\n", " "))
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S).strip()
    if not answer:
        # An empty reply is a transport/server failure, never a finding:
        # keep the raw payload so the cause (memory, context, load) is
        # readable in the verdict file.
        return "", "empty reply: " + json.dumps(payload)[:600]
    return answer, None


# Big commits are reviewed a few files at a time (2026-09-25). qwen3.8
# reasoned past 24,576 tokens (494 s) on the 40 KB Angel Checks diff and
# never answered; with thinking off it answered "NO FINDINGS" in 1 s on the
# same diff, which carried four confirmed MAJOR defects. A diff above
# SPLIT_OVER characters is cut at file boundaries into parts of at most
# SPLIT_OVER characters (a single larger file is one part of its own), each
# carrying the commit's message and --stat so the model knows the whole.
SPLIT_OVER = 16_000


def split_diff(diff: str, limit: int = SPLIT_OVER) -> list[str]:
    """Pure. The whole diff when it fits; otherwise header + file groups."""
    if len(diff) <= limit or "\ndiff --git " not in diff:
        return [diff]
    head, _, rest = diff.partition("\ndiff --git ")
    files = ["diff --git " + f for f in ("\ndiff --git " + rest).split("\ndiff --git ") if f]
    parts, current = [], ""
    for f in files:
        if current and len(current) + len(f) > limit:
            parts.append(current)
            current = ""
        current += ("\n" if current else "") + f
    if current:
        parts.append(current)
    total = len(parts)
    return [f"{head}\n\n[part {i} of {total} of this commit's diff]\n{p}" for i, p in enumerate(parts, 1)]


def review_unit(ask_fn, diff: str, limit: int = SPLIT_OVER) -> tuple[str, str, float, str | None]:
    """(state, text, seconds, error) for one commit, part by part. Pure but
    for `ask_fn(prompt) -> (answer, seconds, error)`. Any part that errored
    makes the commit ERROR (it was not fully reviewed, so it is retried);
    otherwise any flagged part makes it FLAGGED; else quiet."""
    parts = split_diff(diff, limit)
    seconds, answers, errors = 0.0, [], []
    for i, part in enumerate(parts, 1):
        answer, secs, error = ask_fn("Review this change.\n\n```diff\n" + part + "\n```")
        seconds += secs
        tag = f"[part {i}/{len(parts)}] " if len(parts) > 1 else ""
        if error:
            errors.append(tag + str(error))
        elif not clean(answer):
            answers.append(tag + answer)
    if errors:
        # The parts that DID answer are kept in the verdict file: a finding
        # in part 2 is worth reading even when part 1 must be retried.
        return "ERROR", "\n\n".join(errors + answers), seconds, "; ".join(errors)
    if answers:
        return "FLAGGED", "\n\n".join(answers), seconds, None
    return "quiet", "NO FINDINGS" + (f" ({len(parts)} parts)" if len(parts) > 1 else ""), seconds, None


def ask(endpoint: str, model: str, prompt: str, timeout: float,
        num_predict: int = NUM_PREDICT, think: bool = True) -> tuple[str, float, str | None]:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "stream": False,
        # think: False asks a thinking model (qwen3.x) to answer without its
        # reasoning pass — faster, shallower; --no-think, for diffs it
        # cannot finish thinking about inside the cap.
        "think": think,
        # num_ctx: without it ollama runs the model at its MAXIMUM context
        # (262K), and a 32B reviewer on a 48 GB Mac came back with empty
        # 200 replies that were counted as 25/25 FLAGGED (2026-09-01).
        # A diff plus the system prompt is a few thousand tokens.
        # num_predict: the reply cap (thinking included), see NUM_PREDICT.
        "options": {"temperature": 0, "seed": 101, "num_ctx": 32768,
                    "num_predict": num_predict},
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
    answer, error = interpret(payload, num_predict)
    return answer, time.monotonic() - started, error


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
    parser.add_argument("--also-commits", default=None,
                        help="comma-separated SHAs to review in ADDITION to the "
                             "range — used to retry commits an earlier run "
                             "errored on. Deduped against the range.")
    parser.add_argument("--staged", action="store_true",
                        help="review what is staged, before you commit it")
    parser.add_argument("--working", action="store_true",
                        help="review the working tree, committed or not")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
                        help=f"seconds to wait for one review (default {DEFAULT_TIMEOUT_SECONDS:.0f})")
    parser.add_argument("--num-predict", type=int, default=NUM_PREDICT,
                        help=f"reply cap in tokens, thinking included (default {NUM_PREDICT})")
    parser.add_argument("--split-over", type=int, default=SPLIT_OVER,
                        help=f"review a diff larger than this many characters a few files "
                             f"at a time (default {SPLIT_OVER})")
    parser.add_argument("--no-think", action="store_true",
                        help="ask a thinking model to answer without its reasoning pass")
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)
    if not args.model:
        args.model = configured_model()
        print(f"warning: no --model given; falling back to Hallie's configured "
              f"brain ({args.model}). The reviewer should name its own model — "
              f"see nightly_review.sh.", file=sys.stderr)

    stamp = time.strftime("%Y%m%d-%H%M")
    out = Path(args.out or (Path.home() / "Library/Logs/VideoScan"
                            / f"real-review-{stamp}"))
    out.mkdir(parents=True, exist_ok=True)

    rows = units(args)
    if not rows:
        print("nothing to review")
        return 0
    print(f"model    {args.model}")
    print(f"limits   wait {args.timeout:.0f} s per review, reply cap {args.num_predict} tokens, "
          f"thinking {'off' if args.no_think else 'on'}, split over {args.split_over} chars")
    print(f"units    {len(rows)}")
    print(f"out      {out}\n", flush=True)

    flagged, quiet, broken = [], [], []
    for index, (short, subject, diff) in enumerate(rows, 1):
        state, text, seconds, error = review_unit(
            lambda prompt: ask(args.endpoint, args.model, prompt, args.timeout,
                               args.num_predict, not args.no_think),
            diff, args.split_over)
        answer = text
        if state == "ERROR":
            broken.append((short, subject, error))
        elif state == "quiet":
            quiet.append((short, subject))
        else:
            flagged.append((short, subject, answer))

        (out / f"{index:02d}-{short}.md").write_text(
            f"# {short}  {subject}\n\n"
            f"- model: {args.model}\n- seconds: {seconds:.1f}\n"
            f"- verdict: {state}\n\n---\n\n{answer}\n")
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
    # A machine-readable line so nightly_review.sh can carry these forward
    # WITHOUT grepping the per-commit .md files. An errored commit was never
    # reviewed; before 2026-09-07 the baseline advanced past it anyway and it
    # was never looked at again — 19 of 122 commits over the first five nights.
    print("ERRORED_SHAS: " + ",".join(short for short, _, _ in broken))
    if broken:
        print("  UNREVIEWED (retried next run):")
        for short, subject, error in broken:
            print(f"    {short}  {subject[:56]}  — {str(error)[:60]}")
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
