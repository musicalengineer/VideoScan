"""Records in hallie_eval.py's shape, its own grader, and the per-category scorecard.

Grading imports `grade_record` and `load_corpus` from scripts/hallie_eval.py
(spec_from_file_location — the pattern hallie_eval.py itself uses), so
nothing is re-implemented and nothing in the grader changes.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import statistics

from .toolbox import REPO

_EVAL = None

# The review's bars (docs/reviews/hallie_demo_2026_10_10.md); a corpus's own passBars win.
DEFAULT_BARS = {"no_bluff": 100, "stats": 100, "multi_hop": 80, "conversation": 80, "loose_phrasing": 90,
                "story": 100}
JUDGE_POINTS = {"PASS": 1.0, "PARTIAL": 0.5, "FAIL": 0.0}


def hallie_eval():
    global _EVAL
    if _EVAL is None:
        spec = importlib.util.spec_from_file_location("hallie_eval", os.path.join(REPO, "scripts", "hallie_eval.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _EVAL = mod
    return _EVAL


def load_corpus(path: str) -> tuple[list[dict], dict]:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    data = json.loads(text)
    rows = hallie_eval().load_corpus(path, source_text=text)
    bars = {}
    for cat, b in (data.get("passBars") or {}).items() if isinstance(data, dict) else []:
        m = re.search(r"(\d+)\s*%", b.get("bar", ""))
        bars[cat] = int(m.group(1)) if m else 100 if "all" in b.get("bar", "") else None
    return rows, bars


EVAL_FIELDS = ("id", "scenarioID", "category", "expect", "expectedRoutes", "expectedOutcome", "expectedOutcomes",
               "expectMode", "mustContain", "mustNotContain", "mustMatch", "mustMatchQueryDescription",
               "mustMatchAttachmentOutline", "expectEvidenceCount", "noFabricatedPersonalMemory",
               "currentEvidenceOnly", "forbidRawInternals", "followsPrevious")


def eval_record(row: dict, turn: dict) -> dict:
    """One hallie_eval-shaped record (+ E1-only fields) for a finished turn."""
    rec = {k: row.get(k) for k in EVAL_FIELDS}
    for k in ("mustContain", "mustNotContain", "mustMatch", "mustMatchQueryDescription", "mustMatchAttachmentOutline"):
        rec[k] = rec[k] or []
    for k in ("noFabricatedPersonalMemory", "currentEvidenceOnly", "forbidRawInternals", "followsPrevious"):
        rec[k] = bool(rec[k])
    tools = ", ".join(f"{t['name']}({', '.join(f'{k}={v}' for k, v in (t.get('input') or {}).items())})"
                      for t in turn.get("toolTrace", []))
    rec.update({
        "question": turn["question"], "answer": turn["answer"], "route": turn.get("route"),
        "outcome": turn.get("outcome"), "outcomes": [turn.get("outcome")], "mode": None,
        "queryDescription": " | ".join(x for x in (turn.get("questionReading") or "", tools) if x),
        "attachmentOutline": [], "composedBy": "agent", "basis": None,
        "mediaEvidence": turn.get("mediaEvidence") or [], "knowledgeEvidence": turn.get("knowledgeEvidence") or [],
        "responder": "agent", "model": turn.get("model"),
        # E1-only
        "lane": "agent", "provider": turn.get("provider"), "effort": turn.get("effort"), "seed": turn.get("seed"),
        "toolCalls": turn.get("toolCalls"), "modelCalls": turn.get("modelCalls"),
        "unverifiedFacts": turn.get("unverifiedFacts", 0), "wrongSubject": bool(turn.get("wrongSubject")),
        "fallbackReason": turn.get("fallbackReason"), "latencyMs": turn.get("latencyMs"),
        "usage": turn.get("usage"), "costUSD": turn.get("costUSD"), "subjectIDs": turn.get("subjectIDs") or [],
        "expectedSubjectIDs": row.get("subjectIDs"), "expectedNumbers": row.get("expectedNumbers"),
    })
    rec["flags"] = hallie_eval().grade_record(rec)
    return rec


def decline_correct(flags: list[str], expect: str | None) -> bool | None:
    if expect not in ("graceful_decline", "catalog", "kinship", "biography"):
        return None
    return not ({"answered_unknowable", "declined_expected_answer"} & set(flags))


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]


def summarize(records: list[dict], bars: dict | None = None, judged: dict | None = None) -> dict:
    """Per-category scorecard. judged: {(model, seed, id): {"grade": PASS|PARTIAL|FAIL, ...}}."""
    bars = {**DEFAULT_BARS, **(bars or {})}   # an explicit None ("n/a") wins over a default
    cats: dict[str, list] = {}
    for r in records:
        cats.setdefault(r.get("category") or "?", []).append(r)

    def block(rs):
        defects = [r for r in rs if [f for f in r["flags"] if not f.startswith("~")]]
        dc = [decline_correct(r["flags"], r.get("expect")) for r in rs]
        dc = [x for x in dc if x is not None]
        lat = [r["latencyMs"] for r in rs if r.get("latencyMs") is not None]
        out = {"rows": len(rs), "patternClean": len(rs) - len(defects),
               "patternCleanPct": round(100 * (len(rs) - len(defects)) / max(len(rs), 1), 1),
               "unverifiedFacts": sum(r.get("unverifiedFacts") or 0 for r in rs),
               "rowsWithUnverified": sum(1 for r in rs if r.get("unverifiedFacts")),
               "wrongSubject": sum(1 for r in rs if r.get("wrongSubject")),
               "fallbacks": sum(1 for r in rs if r.get("fallbackReason")),
               "declineCorrectPct": round(100 * sum(dc) / len(dc), 1) if dc else None,
               "p50ms": pct(lat, 50), "p95ms": pct(lat, 95),
               "costUSD": round(sum(r.get("costUSD") or 0 for r in rs), 6)}
        if judged:
            g = [judged.get((r.get("model"), r.get("seed"), r["id"])) for r in rs]
            g = [x for x in g if x]
            if g:
                pts = sum(JUDGE_POINTS.get(x["grade"], 0) for x in g)
                out["judge"] = {"graded": len(g), "points": pts, "pct": round(100 * pts / len(g), 1),
                                "flags": sorted({f for x in g for f in x.get("flags", [])})}
        return out

    per = {}
    for cat, rs in sorted(cats.items()):
        b = block(rs)
        b["bar"] = bars.get(cat)
        if b.get("judge") and b["bar"] is not None:
            b["judgeMetBar"] = b["judge"]["pct"] >= b["bar"]
        per[cat] = b
    fb = {}
    for r in records:
        if r.get("fallbackReason"):
            fb[r["fallbackReason"]] = fb.get(r["fallbackReason"], 0) + 1
    return {"overall": block(records), "categories": per, "fallbackReasons": fb}


def scorecard_md(title: str, card: dict) -> str:
    lines = [f"# {title}", "",
             "| category (bar) | pattern-clean | judge | wrong-subject | unverified | decline-ok | fallbacks | p50/p95 s | $ |",
             "|---|---|---|---|---|---|---|---|---|"]

    def row(name, b, bar=None):
        j = b.get("judge")
        js = "—"
        if j:
            mark = (" ✅" if b["judgeMetBar"] else " ❌") if "judgeMetBar" in b else ""
            js = f"{j['points']:g}/{j['graded']} = {j['pct']:.0f}%{mark}"
        lat = (f"{(b['p50ms'] or 0) / 1000:.1f}/{(b['p95ms'] or 0) / 1000:.1f}") if b.get("p50ms") is not None else "—"
        dc = f"{b['declineCorrectPct']:.0f}%" if b.get("declineCorrectPct") is not None else "—"
        label = f"{name} ({bar}%)" if bar is not None else name
        return (f"| {label} | {b['patternClean']}/{b['rows']} = {b['patternCleanPct']:.0f}% | {js} | {b['wrongSubject']} "
                f"| {b['unverifiedFacts']} | {dc} | {b['fallbacks']} | {lat} | {b['costUSD']:.4f} |")

    for cat, b in card["categories"].items():
        lines.append(row(cat, b, b.get("bar")))
    lines.append(row("**all turns**", card["overall"]))
    if card.get("fallbackReasons"):
        lines += ["", "Fallbacks: " + ", ".join(f"{k} {v}" for k, v in sorted(card["fallbackReasons"].items()))]
    lines += ["", "pattern-clean = hallie_eval.py grade_record with no defect flags (lexical; route/queryDescription "
                  "flags are lane-shape artifacts, see README). judge = PASS 1 / PARTIAL 0.5 / FAIL 0 from "
                  "`cli.py judge` (— until judged)."]
    return "\n".join(lines) + "\n"


def per_row_md(records: list[dict], judged: dict | None = None) -> str:
    lines = ["| id | category | outcome | flags | WS | UF | fallback | ms | $ | judge | note |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in records:
        j = (judged or {}).get((r.get("model"), r.get("seed"), r["id"])) or {}
        flags = ",".join(f for f in r["flags"] if not f.startswith("~")) or "clean"
        lines.append(f"| {r['id']} | {r.get('category')} | {r.get('outcome')} | {flags} | "
                     f"{'WS' if r.get('wrongSubject') else ''} | {r.get('unverifiedFacts') or ''} | "
                     f"{r.get('fallbackReason') or ''} | {r.get('latencyMs')} | {r.get('costUSD') or 0:.4f} | "
                     f"{j.get('grade', '')} | {(j.get('note') or '').replace('|', '/')[:120]} |")
    return "\n".join(lines) + "\n"
