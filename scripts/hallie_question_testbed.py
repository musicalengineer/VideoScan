#!/usr/bin/env python3
"""Extract and grade one-case-per-question Hallie conversation testbeds.

The testbed deliberately stores the response seen in the log as a *baseline*,
not as ground truth.  A later run can therefore be compared mechanically while
leaving room for a human semantic score and for correcting bad historical
answers.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import re
import sys
from pathlib import Path


def _read_events(paths):
    for path in paths:
        with open(path, encoding="utf-8") as stream:
            for line_no, line in enumerate(stream, 1):
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"{path}:{line_no}: invalid JSON: {exc}")
                event["_source"] = str(path)
                yield event


def _norm(text):
    return re.sub(r"\s+", " ", str(text or "").strip().casefold())


def _next_assistant(events, index, session):
    for event in events[index + 1 :]:
        if event.get("sessionID") == session and event.get("kind") == "assistant":
            return event
    return None


def extract(paths):
    events = list(_read_events(paths))
    cases = []
    used_ids = collections.Counter()
    for index, user in enumerate(events):
        if user.get("kind") != "user":
            continue
        source = Path(user["_source"]).name
        date = re.search(r"(\d{4}-\d{2}-\d{2})", source)
        date = date.group(1) if date else "unknown-date"
        session = str(user.get("sessionID") or "no-session")
        base_id = f"{date}-{session[:8]}-q{user.get('sequence', index)}"
        used_ids[base_id] += 1
        case_id = base_id if used_ids[base_id] == 1 else f"{base_id}-{used_ids[base_id]}"
        assistant = _next_assistant(events, index, session)
        if assistant is None:
            assistant = {}
        media = assistant.get("mediaEvidence") or []
        knowledge = assistant.get("knowledgeEvidence") or []
        cases.append({
            "id": case_id,
            "source": source,
            "sessionID": session,
            "sequence": user.get("sequence"),
            "timestamp": user.get("timestamp"),
            "question": user.get("text", ""),
            "reference": {
                "outcome": assistant.get("outcome"),
                "route": assistant.get("route"),
                "queryDescription": assistant.get("queryDescription"),
                "answerText": assistant.get("text", ""),
                "basisLine": assistant.get("basisLine"),
                "mediaEvidenceCount": len(media),
                "knowledgeEvidenceCount": len(knowledge),
                "offeredActions": assistant.get("offeredActions") or [],
            },
            "humanGrade": None,
            "reviewNotes": "",
        })
    return {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "sourceLogs": sorted({c["source"] for c in cases}),
        "cases": cases,
    }


def _actual_cases(paths):
    return extract(paths)["cases"]


def grade(manifest, paths):
    actual = _actual_cases(paths)
    occurrences = collections.Counter()
    by_key = {}
    for case in actual:
        key0 = _norm(case["question"])
        occurrences[key0] += 1
        by_key[(key0, occurrences[key0])] = case
    report = []
    expected_occurrences = collections.Counter()
    for expected in manifest["cases"]:
        key0 = _norm(expected["question"])
        # Cases from a source log have an occurrence number among identical text.
        expected_occurrences[key0] += 1
        occurrence = expected_occurrences[key0]
        got = by_key.get((key0, occurrence))
        ref = expected["reference"]
        checks = {}
        if got is None:
            checks["responsePresent"] = False
        else:
            actual_ref = got["reference"]
            checks = {
                "responsePresent": (
                    bool(actual_ref.get("answerText"))
                    or actual_ref.get("outcome") is not None
                    or actual_ref.get("mediaEvidenceCount", 0) > 0
                    or actual_ref.get("knowledgeEvidenceCount", 0) > 0
                    or bool(actual_ref.get("offeredActions"))
                ),
                "outcome": actual_ref.get("outcome") == ref.get("outcome"),
                "route": actual_ref.get("route") == ref.get("route"),
                "queryDescription": actual_ref.get("queryDescription") == ref.get("queryDescription"),
                "evidenceShape": (
                    actual_ref.get("mediaEvidenceCount") == ref.get("mediaEvidenceCount")
                    and actual_ref.get("knowledgeEvidenceCount") == ref.get("knowledgeEvidenceCount")
                ),
            }
        baseline_match_score = round(100 * sum(checks.values()) / len(checks), 1) if checks else 0.0
        human_grade = expected.get("humanGrade")
        status = human_grade if human_grade in ("pass", "fail") else "ungraded"
        report.append({"id": expected["id"], "question": expected["question"],
                       "baselineMatchScore": baseline_match_score,
                       "score": baseline_match_score, "status": status, "checks": checks})
    graded = [x for x in report if x["status"] in ("pass", "fail")]
    passed = sum(x["status"] == "pass" for x in graded)
    return {"schemaVersion": 1, "cases": report,
            "summary": {
                "count": len(report),
                "baselineMatches": sum(x["baselineMatchScore"] == 100.0 for x in report),
                "gradedCount": len(graded),
                "passed": passed,
                "failed": len(graded) - passed,
                "ungraded": len(report) - len(graded),
                "passRatePct": round(100 * passed / len(graded), 1) if graded else None,
            }}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    ex = sub.add_parser("extract")
    ex.add_argument("logs", nargs="+", type=Path)
    ex.add_argument("-o", "--output", required=True, type=Path)
    gr = sub.add_parser("grade")
    gr.add_argument("manifest", type=Path)
    gr.add_argument("logs", nargs="+", type=Path)
    gr.add_argument("-o", "--output", type=Path)
    args = parser.parse_args(argv)
    if args.command == "extract":
        result = extract(args.logs)
    else:
        with open(args.manifest, encoding="utf-8") as stream:
            result = grade(json.load(stream), args.logs)
    rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if getattr(args, "output", None):
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)


if __name__ == "__main__":
    main()
