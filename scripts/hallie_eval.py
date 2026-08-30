#!/usr/bin/env python3
"""Hallie conversational-quality evaluation harness (Rick, 2026-08-21).

Feeds a corpus of questions through the headless read-only Hallie shell in ONE
session (the 7k-record catalog loads once), then joins the questions to the
structured turns Hallie writes to her JSONL conversation log — route, outcome,
composedBy, basis, evidence — and grades them.

The point is a repeatable before/after number for "does she feel like a person
who knows this family", not a pass/fail gate. Grades are heuristic and
deliberately conservative: they flag what a human should read, they do not
pretend to judge warmth on their own.

Usage:
  scripts/hallie_eval.py run   --corpus tests/hallie_eval_corpus.json --out runs/base.jsonl
  scripts/hallie_eval.py grade --run runs/base.jsonl [--compare runs/prev.jsonl]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOG_DIR = Path.home() / "Library/Logs/VideoScan/Hallie"
HALLIE = REPO / "scripts/hallie"
MEDIA_FILENAME_EXTENSIONS = (
    "mov|mp4|m4v|avi|mkv|mxf|mts|m2ts|ts|mpg|mpeg|m2v|vob|wmv|asf|"
    "webm|ogv|ogg|rm|rmvb|divx|flv|f4v|3gp|3g2|dv|dif|braw|r3d|vro|"
    "mod|tod|wav|aif|aiff|mp3|mp2|m4a|aac|flac|caf|wma|ac3|oga|opus|"
    "alac|amr|au|snd"
)

# ---------------------------------------------------------------- run


def load_corpus(path):
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, list):
        return data
    if "questions" in data:
        return data["questions"]

    questions = []
    for category in data.get("categories", []):
        inherited = {
            key: value for key, value in category.items()
            if key not in ("id", "prompts", "sessions")
        }
        category_id = category["id"]
        for index, prompt in enumerate(category.get("prompts", []), 1):
            turn = dict(prompt) if isinstance(prompt, dict) else {"text": prompt}
            turn = inherited | turn
            turn.setdefault("id", f"{category_id}-{index:03d}")
            turn["category"] = category_id
            turn["scenarioID"] = turn["id"]
            turn["followsPrevious"] = False
            questions.append(turn)
        for session in category.get("sessions", []):
            scenario = f"{category_id}-{session['id']}"
            for index, prompt in enumerate(session.get("turns", []), 1):
                turn = dict(prompt) if isinstance(prompt, dict) else {"text": prompt}
                turn = inherited | turn
                turn.setdefault("id", f"{scenario}-t{index}")
                turn["category"] = category_id
                turn["scenarioID"] = scenario
                turn["followsPrevious"] = index > 1
                questions.append(turn)

    declared = data.get("turnCount")
    if declared is not None and declared != len(questions):
        raise ValueError(
            f"corpus declares {declared} turns but expands to {len(questions)}")
    ids = [q["id"] for q in questions]
    if len(ids) != len(set(ids)):
        raise ValueError("corpus turn IDs are not unique")
    return questions


def build_stdin(questions):
    """Use one real `:reset` at each scenario boundary. Multi-turn scenarios
    retain their context; unrelated prompts never share a referent."""
    lines = []
    previous_scenario = None
    for q in questions:
        # A flat corpus marks chains with followsPrevious; a scenario corpus
        # shares a scenarioID. Either way a follow-up must NOT be preceded by
        # :reset, or every "and the newest?" is graded against a blank slate
        # (7 false failures in the 2026-08-21 baseline).
        if q.get("followsPrevious") and previous_scenario is not None:
            scenario = previous_scenario
        else:
            scenario = q.get("scenarioID", q["id"])
        if scenario != previous_scenario:
            lines.append(":reset")
        lines.append(q["text"].replace("\n", " "))
        previous_scenario = scenario
    lines.append(":quit")
    return "\n".join(lines) + "\n"


def normalize_question(text):
    """Loose key for pairing a logged turn back to its corpus entry."""
    return " ".join((text or "").lower().split())


def newest_build():
    """The most recently built VideoScan binary among the places this repo
    builds to. Newest wins; None when nothing is built."""
    import glob
    roots = [
        str(REPO / ".build-dd/Build/Products/*/VideoScan.app/Contents/MacOS/VideoScan"),
        "/Volumes/XcodeRAM/VideoScan-*/Build/Products/*/VideoScan.app/Contents/MacOS/VideoScan",
        str(Path.home() / "Library/Developer/Xcode/DerivedData/VideoScan-*/Build/Products/*/VideoScan.app/Contents/MacOS/VideoScan"),
        "/private/tmp/VideoScan-*/Build/Products/*/VideoScan.app/Contents/MacOS/VideoScan",
        "/private/tmp/claude-501/**/scratchpad/dd/Build/Products/*/VideoScan.app/Contents/MacOS/VideoScan",
    ]
    found = []
    for pattern in roots:
        found.extend(glob.glob(pattern, recursive=True))
    if not found:
        return None
    return max(found, key=os.path.getmtime)


def read_run_turns(run_id):
    """Read only this process's events across every UTC-rotated log file.
    The app may append concurrently; its events have no matching runID."""
    turns = []
    for filename in sorted(LOG_DIR.glob("hallie-conversation-*.jsonl")):
        with open(filename) as f:
            for line in f:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("runID") == run_id:
                    turns.append(event)
    return sorted(turns, key=lambda event: event.get("timestamp", ""))


def run(args):
    questions = load_corpus(args.corpus)
    if args.limit:
        questions = questions[: args.limit]
    run_id = f"hallie-eval-{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}"

    cmd = [str(HALLIE), "--no-actions", "--log-run-id", run_id]
    if not args.no_compose:
        cmd.append("--compose")
    if args.host:
        cmd += ["--host", args.host]
    if args.model:
        cmd += ["--model", args.model]

    # PIN THE BINARY. The launcher otherwise picks the newest build it can
    # DISCOVER, which is not necessarily the one carrying the change under
    # test — on 2026-08-21 two full passes silently measured a stale XcodeRAM
    # build and read as "no improvement". A run that cannot name its binary
    # is not a measurement.
    env = dict(os.environ)
    binary = args.bin or newest_build()
    if binary:
        env["VIDEOSCAN_APP_BIN"] = binary
        built = time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(binary)))
        print(f"[eval] binary: {binary} (built {built})", flush=True)
    else:
        raise RuntimeError("no built VideoScan executable found; build once before eval")

    print(f"[eval] {len(questions)} questions → {' '.join(cmd)}", flush=True)
    t0 = time.time()
    proc = subprocess.run(
        cmd,
        input=build_stdin(questions),
        capture_output=True,
        text=True,
        timeout=args.timeout,
        cwd=str(REPO),
        env=env,
    )
    elapsed = time.time() - t0
    print(f"[eval] session finished in {elapsed:.0f}s (exit {proc.returncode})", flush=True)

    unmatched = []
    turns = read_run_turns(run_id)
    # Pair: assistant turns carry `outcome`; user turns don't. Walk in order.
    pairs, pending = [], None
    for t in turns:
        if t.get("kind") == "system":
            pending = None
            continue
        if t.get("kind") == "user":
            pending = t.get("text", "")
            continue
        if t.get("kind") in ("assistant", "error") and pending is not None:
            pairs.append((pending, t))
            pending = None

    # Align by the QUESTION TEXT the log recorded, never by position: a turn
    # that logs nothing (or twice) used to shift every later label, which
    # attributed "Have a good night." to the temporal category and made
    # per-category numbers untrustworthy (2026-08-21). Duplicate texts are
    # consumed in order, so repeated phrasings still line up.
    by_text = {}
    for index, q in enumerate(questions):
        by_text.setdefault(normalize_question(q["text"]), []).append(index)
    used = set()

    records = []
    for asked, ans in pairs:
        if asked is not None and asked.strip().startswith(":"):
            continue
        key = normalize_question(asked or "")
        candidates = [i for i in by_text.get(key, []) if i not in used]
        if not candidates:
            unmatched.append(asked)
            continue
        qi = candidates[0]
        used.add(qi)
        q = questions[qi]
        records.append(
            {
                "id": q.get("id"),
                "scenarioID": q.get("scenarioID"),
                "category": q.get("category"),
                "expect": q.get("expect"),
                "expectedRoutes": q.get("expectedRoutes"),
                "expectedOutcome": q.get("expectedOutcome"),
                "expectedOutcomes": q.get("expectedOutcomes"),
                "mustContain": q.get("mustContain", []),
                "mustNotContain": q.get("mustNotContain", []),
                "noFabricatedPersonalMemory": bool(
                    q.get("noFabricatedPersonalMemory")),
                "currentEvidenceOnly": bool(q.get("currentEvidenceOnly")),
                "forbidRawInternals": bool(q.get("forbidRawInternals")),
                "followsPrevious": bool(q.get("followsPrevious")),
                "question": asked if asked is not None else q["text"],
                "answer": ans.get("text", ""),
                "route": ans.get("route"),
                "outcome": ans.get("outcome"),
                "composedBy": ans.get("composedBy"),
                "basis": ans.get("basisLine"),
                "mediaEvidence": ans.get("mediaEvidence") or [],
                "knowledgeEvidence": ans.get("knowledgeEvidence") or [],
                "responder": ans.get("responder"),
                "model": ans.get("model"),
                "sessionID": ans.get("sessionID"),
                "eventID": ans.get("eventID"),
            }
        )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        f.write(json.dumps({"meta": {
            "questions": len(questions), "paired": len(records),
            "elapsed_s": round(elapsed), "compose": not args.no_compose,
            "when": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "runID": run_id,
            "binary": binary,
            "binary_built": time.strftime("%Y-%m-%dT%H:%M:%S",
                                          time.localtime(os.path.getmtime(binary)))
            if binary else None,
            "git": subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                                  capture_output=True, text=True,
                                  cwd=str(REPO)).stdout.strip(),
        }}) + "\n")
        for r in records:
            f.write(json.dumps(r) + "\n")
    print(f"[eval] wrote {len(records)} paired turns → {out}")
    if len(records) < len(questions):
        missing = [q["id"] for i, q in enumerate(questions) if i not in used]
        print(f"[eval] WARNING: {len(questions) - len(records)} questions produced no "
              f"matched turn: {', '.join(missing[:12])}"
              + (" …" if len(missing) > 12 else ""))
    if unmatched:
        print(f"[eval] WARNING: {len(unmatched)} logged turns matched no corpus question")
    if proc.returncode != 0:
        print(proc.stderr[-2000:], file=sys.stderr)
    return 0


# ---------------------------------------------------------------- grade

DECLINE_PAT = re.compile(
    r"don'?t have evidence|no evidence|couldn'?t find|i'?m not sure|cannot answer|"
    r"don'?t know|unable to",
    re.I,
)
# A sentence that starts mid-thought — the fragment bug class.
FRAGMENT_PAT = re.compile(r"^\s*(?:'s|s |and |but |or )", re.I)
HEDGE_PAT = re.compile(r"as an ai|i am an ai|language model", re.I)
PERSONAL_MEMORY_PAT = re.compile(
    r"\bi remember\b|\bwhen i was\b|\bi used to\b|\bmy childhood\b|"
    r"\bi grew up\b|\bmy (?:mother|father|parents)\b",
    re.I,
)
RAW_INTERNAL_PAT = re.compile(
    r"strict ast|queryast|decoder|json schema|ollama|endpoint|hostname|"
    r"stack trace|localizeddescription|swift|http \d{3}",
    re.I,
)
# The relax-and-explain shape: names what it set aside, then offers what exists.
RELAXED_PAT = re.compile(r"setting aside .*(i do have|want those)", re.I | re.S)


def grade_record(r):
    """Return (flags, ok). Conservative: flags mean 'a human should look'."""
    flags = []
    a = (r.get("answer") or "").strip()
    expect = r.get("expect")
    outcome = r.get("outcome")

    if not a:
        flags.append("empty")
        return flags
    if r.get("route") in (None, "") and outcome is None:
        flags.append("no_route")

    # A relax-and-explain offer ("Nothing matches all of that. Setting aside
    # the years you asked for, I do have 34 items. Want those?") IS the
    # intended good answer for a near miss — it names what it set aside and
    # offers what exists. Grading it as a failed answer would penalise the
    # very behaviour the feature adds, so it counts as helpful and is
    # reported separately.
    relaxed_offer = bool(RELAXED_PAT.search(a))
    declined = (outcome == "declined" or bool(DECLINE_PAT.search(a))) and not relaxed_offer
    if relaxed_offer:
        flags.append("~relaxed_offer")
    # A conversation-repair turn ("that's wrong", "you gave me people from
    # the 1300s") is acknowledged and restated, never searched. Counted
    # separately so the repair rate is visible; not a defect.
    if outcome == "repaired":
        flags.append("~repaired")

    # Expectation mismatches
    if expect in ("catalog", "kinship", "biography") and declined:
        flags.append("declined_expected_answer")
    if expect == "social" and declined:
        flags.append("social_declined")          # the "no evidence" for "how are you" bug
    if expect == "social" and r.get("mediaEvidence"):
        flags.append("social_hit_catalog")
    if expect == "graceful_decline" and not declined:
        flags.append("answered_unknowable")      # invention risk

    # Prose quality
    if FRAGMENT_PAT.match(a):
        flags.append("fragment")
    if a and a[0].islower():
        flags.append("lowercase_start")
    if HEDGE_PAT.search(a):
        flags.append("ai_disclaimer")
    if len(a.split()) <= 3 and expect != "social" and r.get("category") != "smalltalk":
        flags.append("terse")
    # Warmth proxy: a decline that offers nothing is a dead end.
    if declined and not re.search(r"\?|would you|want|try|i do have|i can", a, re.I):
        flags.append("dead_end_decline")

    expected_routes = r.get("expectedRoutes") or []
    if expected_routes and r.get("route") not in expected_routes:
        flags.append("route_mismatch")
    expected_outcomes = r.get("expectedOutcomes") or []
    if r.get("expectedOutcome"):
        expected_outcomes = [r["expectedOutcome"]]
    normalized_outcome = "needsClarification" if outcome == "needs-clarification" else outcome
    if expected_outcomes and normalized_outcome not in expected_outcomes:
        flags.append("outcome_mismatch")

    lowered = a.lower()
    for forbidden in r.get("mustNotContain") or []:
        if forbidden.lower() in lowered:
            flags.append("forbidden_text")
            break
    for required in r.get("mustContain") or []:
        if required.lower() not in lowered:
            flags.append("missing_required_text")
            break
    # Semantic answer contracts can tolerate model wording changes while
    # still pinning the required concepts. Patterns are corpus-authored,
    # case-insensitive, and may span lines. A malformed expectation is a
    # grading defect, never a reason for the evaluator itself to crash.
    required_patterns = r.get("mustMatch") or []
    if isinstance(required_patterns, str):
        required_patterns = [required_patterns]
    for pattern in required_patterns:
        try:
            matches = re.search(pattern, a, re.I | re.S)
        except (re.error, TypeError):
            flags.append("invalid_expected_regex")
            continue
        if not matches:
            flags.append("missing_required_match")
            break
    if r.get("noFabricatedPersonalMemory") and PERSONAL_MEMORY_PAT.search(a):
        flags.append("fabricated_personal_memory")
    if r.get("forbidRawInternals") and RAW_INTERNAL_PAT.search(a):
        flags.append("raw_internal_error")

    # Any filename printed in prose must be present in this turn's evidence.
    # This catches the observed previous-result leakage without pretending to
    # semantically grade every ordinary noun.
    if r.get("currentEvidenceOnly"):
        remainder = a.lower()
        cited = [
            (item.get("filename") or "").lower()
            for item in (r.get("mediaEvidence") or [])
            if item.get("filename")
        ]
        # Remove exact evidence names first. Tokenizing a filename with spaces
        # turned "Clip 01.dv" into the false unknown name "01.dv".
        for filename in sorted(cited, key=len, reverse=True):
            remainder = remainder.replace(filename, "")
        mentioned = {
            match.group(0).lower()
            for match in re.finditer(
                rf"\b[^\s,;()]+\.(?:{MEDIA_FILENAME_EXTENSIONS})\b",
                remainder,
                re.I,
            )
        }
        if mentioned:
            flags.append("named_item_not_in_current_evidence")

    return flags


def grade(args):
    recs = []
    with open(args.run) as f:
        meta = json.loads(f.readline())
        for line in f:
            recs.append(json.loads(line))

    by_cat, flag_counts, flagged = {}, {}, []
    for r in recs:
        flags = grade_record(r)
        r["flags"] = flags
        # Flags starting with "~" are informational, not defects.
        defects = [f for f in flags if not f.startswith("~")]
        c = by_cat.setdefault(r.get("category", "?"), {"n": 0, "clean": 0})
        c["n"] += 1
        if not defects:
            c["clean"] += 1
        else:
            flagged.append(r)
        for fl in flags:
            flag_counts[fl] = flag_counts.get(fl, 0) + 1

    total = len(recs)
    clean = sum(c["clean"] for c in by_cat.values())
    m = meta.get("meta", {})
    print(f"\n=== Hallie eval: {args.run}")
    print(f"turns: {total}   clean: {clean} ({100*clean/max(total,1):.0f}%)   "
          f"elapsed: {m.get('elapsed_s','?')}s")
    print(f"git {m.get('git','?')}   binary built {m.get('binary_built','?')}\n")

    print(f"{'category':22} {'n':>4} {'clean':>6} {'%':>5}")
    for cat in sorted(by_cat):
        c = by_cat[cat]
        print(f"{cat:22} {c['n']:>4} {c['clean']:>6} {100*c['clean']/c['n']:>4.0f}%")

    print("\nflags:")
    for fl, n in sorted(flag_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:>4}  {fl}")

    if args.show:
        print("\n--- flagged examples ---")
        for r in flagged[: args.show]:
            print(f"\n[{r.get('id')}] ({r.get('category')}, expect={r.get('expect')}, "
                  f"route={r.get('route')}, {','.join(r['flags'])})")
            print(f"  Q: {r.get('question')}")
            print(f"  A: {(r.get('answer') or '')[:300]}")

    if args.compare and Path(args.compare).exists():
        prev = []
        with open(args.compare) as f:
            f.readline()
            for line in f:
                prev.append(json.loads(line))
        pclean = sum(1 for r in prev
                     if not [f for f in grade_record(r) if not f.startswith("~")])
        print(f"\ncompare {args.compare}: {pclean}/{len(prev)} "
              f"({100*pclean/max(len(prev),1):.0f}%) → this run "
              f"{clean}/{total} ({100*clean/max(total,1):.0f}%)  "
              f"delta {100*clean/max(total,1) - 100*pclean/max(len(prev),1):+.0f} pts")

    out = Path(args.run).with_suffix(".graded.jsonl")
    with open(out, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    print(f"\ngraded → {out}")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("run")
    pr.add_argument(
        "--corpus",
        default=str(REPO / "tests/hallie_interaction_corpus.json"),
    )
    pr.add_argument("--out", required=True)
    pr.add_argument("--limit", type=int)
    pr.add_argument("--host")
    pr.add_argument("--model", default="qwen3.6:35b-a3b-nvfp4")
    pr.add_argument("--no-compose", action="store_true")
    pr.add_argument("--bin", help="pin this VideoScan binary (default: newest built)")
    pr.add_argument("--timeout", type=int, default=5400)
    pr.set_defaults(func=run)

    pg = sub.add_parser("grade")
    pg.add_argument("--run", required=True)
    pg.add_argument("--compare")
    pg.add_argument("--show", type=int, default=0)
    pg.set_defaults(func=grade)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
