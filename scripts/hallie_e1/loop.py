"""The bounded agent loop: one question in, one verified record out.

Manual loop (not the SDK tool runner): we need a per-turn deadline, call and
tool budgets, request recording for cassettes, and per-call usage — the
documented shape: create → stop_reason tool_use → run tools → ALL results in
one user message → repeat, until the model calls submit_answer.
"""
from __future__ import annotations

import time
from dataclasses import dataclass

from . import verifier
from .backends import BackendError
from .costs import SpendCapReached

FALLBACK_TEXT = "I couldn't finish looking that up just now, so I won't guess. Could you ask me again?"
REFUSAL_TEXT = "I'm not able to help with that one."
LAST_CALL_NOTE = ("Budget: this is your last reply for this turn. Call submit_answer now with what you have "
                  "(or decline).")
TOOL_BUDGET_NOTE = "Budget: the tool budget for this turn is spent. Call submit_answer now."

TREE_TOOLS = {"resolve_person", "person_facts", "relatives", "relationship_between", "family_knowledge"}


@dataclass
class Budget:
    max_model_calls: int = 6
    max_tool_calls: int = 8
    deadline_s: float = 20.0


def route_of(trace: list) -> str:
    """Map the tools used onto today's route names so expectedRoutes grade alike."""
    counts = {"graph": 0, "presence": 0, "catalog-stats": 0}
    for t in trace:
        name, inp = t["name"], t.get("input") or {}
        if name == "search_media":
            counts["presence"] += 1
        elif name == "catalog_stats":
            if inp.get("surname") or inp.get("born_in") or inp.get("scope"):
                counts["graph"] += 1
            else:
                counts["catalog-stats"] += 1
        elif name in TREE_TOOLS and name != "resolve_person":
            counts["graph"] += 1
    if not any(counts.values()):
        return "graph" if any(t["name"] == "resolve_person" for t in trace) else "social"
    return max(counts, key=lambda k: (counts[k], k == "graph"))


def _catalog_names(results: list) -> dict:
    """catalog id → filename, from every result seen this turn."""
    out = {}

    def walk(x):
        if isinstance(x, dict):
            if isinstance(x.get("id"), str) and x["id"].startswith("catalog:") and x.get("filename"):
                out[x["id"]] = x["filename"]
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    for r in results:
        walk(r)
    return out


def run_turn(backend, conv, row: dict, toolbox, budget: Budget, cap, clock=time.monotonic) -> dict:
    question = row["text"]
    backend.begin_turn(row)
    backend.add_user_text(conv, question)
    t0 = clock()
    calls = tool_calls = 0
    trace, results_seen, resolve_calls = [], [], []
    turn_ids: set[str] = set()
    usage = {"input": 0, "cacheWrite": 0, "cacheRead": 0, "output": 0}
    cost = model_s = tool_s = 0.0
    rec = {"fallbackReason": None, "submitted": False, "answerRaw": None}

    def finish(outcome, answer, **extra):
        elapsed = clock() - t0
        names = _catalog_names(results_seen)
        out = {
            "question": question, "outcome": outcome, "answer": answer,
            "latencyMs": round(elapsed * 1000), "modelMs": round(model_s * 1000), "toolMs": round(tool_s * 1000),
            "modelCalls": calls, "toolCalls": tool_calls, "toolTrace": trace, "usage": usage,
            "costUSD": round(cost, 6), "route": route_of(trace), **rec, **extra,
        }
        cited = set(out.get("subjectIDs") or [])
        for c in out.get("claims") or []:
            cited |= set(c.get("cites") or [])
        out["mediaEvidence"] = [{"id": i, "filename": names[i]} for i in sorted(cited) if i in names]
        out["knowledgeEvidence"] = sorted(i for i in cited
                                          if i.startswith("brain:") or (i.startswith("people:") and "#" in i))
        return out

    def fallback(reason, answer=FALLBACK_TEXT, **extra):
        rec["fallbackReason"] = reason
        return finish("declined", answer, unverifiedFacts=0, wrongSubject=False, **extra)

    while True:
        elapsed = clock() - t0
        if elapsed > budget.deadline_s:
            return fallback("deadline")
        if calls >= budget.max_model_calls:
            return fallback("model_calls")
        try:
            cap.check(backend.ceiling_usd(conv), f"{row.get('id')} call {calls + 1}")
        except SpendCapReached as e:
            out = fallback("spend_cap")
            out["spendCapReached"] = str(e)
            return out
        try:
            reply = backend.call(conv, timeout=budget.deadline_s - elapsed + 2.0)
        except BackendError as e:
            out = fallback(e.kind, detail=e.detail)
            out["fatal"] = e.fatal
            return out
        calls += 1
        model_s += reply.latency_s
        for k in usage:
            usage[k] += reply.usage.get(k, 0)
        c = backend.cost(reply.usage)
        cost += c
        cap.add(c)

        if reply.stop_reason == "refusal":
            return fallback("refusal", REFUSAL_TEXT, stopDetails=reply.stop_details)
        if reply.stop_reason == "max_tokens":
            return fallback("max_tokens")
        sub = next((u for u in reply.tool_uses if u.name == "submit_answer"), None)
        if sub:
            rec["submitted"] = True
            rec["answerRaw"] = sub.input.get("prose")
            if clock() - t0 > budget.deadline_s:
                return fallback("deadline", lateSubmit=True)
            v = verifier.verify(sub.input, turn_ids, question, resolve_calls)
            return finish(v.pop("outcome"), v.pop("answer"), questionReading=sub.input.get("questionReading"),
                          declineReason=sub.input.get("declineReason"), offers=sub.input.get("offers") or [],
                          submittedOutcome=sub.input.get("outcome"), **v)
        if not reply.tool_uses:
            rec["answerRaw"] = reply.text
            return fallback("no_submission")

        results = []
        for u in reply.tool_uses:
            if tool_calls >= budget.max_tool_calls:
                results.append((u.id, u.name, "tool budget for this turn is spent; call submit_answer", True))
                trace.append({"name": u.name, "input": u.input, "ok": False, "error": "toolBudget"})
                continue
            res, body, secs = toolbox.execute(u.name, u.input)
            tool_calls += 1
            tool_s += secs
            ok = bool(res.get("ok"))
            if ok:
                turn_ids |= set(res.get("ids") or [])
                results_seen.append(res)
                if u.name == "resolve_person":
                    resolve_calls.append((str((u.input or {}).get("name") or ""), res))
            trace.append({"name": u.name, "input": u.input, "ok": ok, "error": None if ok else res.get("error"),
                          "detail": None if ok else res.get("detail"), "ids": len(res.get("ids") or []),
                          "ms": round(secs * 1000), "resultChars": len(body)})
            results.append((u.id, u.name, body, not ok))
        note = None
        if calls + 1 >= budget.max_model_calls or clock() - t0 > budget.deadline_s * 0.75:
            note = LAST_CALL_NOTE
        elif tool_calls >= budget.max_tool_calls:
            note = TOOL_BUDGET_NOTE
        backend.add_tool_results(conv, results, note)
