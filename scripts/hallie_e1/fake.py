"""Dry-run model clients: no key, no network.

ScriptedFakeClient — the same .messages.create(**kwargs) surface as the SDK.
  It reads the request (question, tool results so far) and emits a
  deterministic tool plan from the corpus row's `expect`:
    social            → submit_answer only
    graceful_decline  → resolve_person → submit (declined)
    clarify           → resolve_person → submit (needsClarification)
    catalog           → resolve_person → search_media → submit
    everything else   → resolve_person → person_facts → submit
  A row may carry "fakeScript" to exercise the harness's failure paths:
    uncited | stale | hallucinated_tool | wrong_subject | never_submit | slow
CassettePlayer — replays recorded responses keyed by (model, row, call n) and
  refuses a request whose hash differs from the recording (prompt drift is
  reported, never silently answered). Missing cassettes fall back to the
  scripted fake when one is given.
"""
from __future__ import annotations

import json
import os
import re

from .backends import BackendError, canonical_hash
from .toolbox import TOOLS

BUDGET_NOTE_PREFIX = "Budget:"


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, s: float) -> None:
        self.t += s


class FakeResponse:
    def __init__(self, d: dict):
        self._d = d

    def to_dict(self) -> dict:
        return json.loads(json.dumps(self._d))


def parse_result(block_content) -> dict:
    s = block_content if isinstance(block_content, str) else json.dumps(block_content)
    m = re.search(r"<tool-result>\s*(.*?)\s*</tool-result>", s, re.S)
    try:
        return json.loads(m.group(1) if m else s)
    except ValueError:
        return {"ok": False, "error": "unparsed", "detail": s[:200]}


def guess_name(question: str) -> str:
    words = re.findall(r"[A-Za-z][\w'’]*", question)
    low = [w.lower().replace("’", "'").split("'")[0] for w in words]
    for i, w in enumerate(low):
        if w in TOOLS.KIN or w.rstrip("s") in TOOLS.KIN:
            start = i - 1 if i and (low[i - 1] in ("maternal", "paternal", "great") or
                                    TOOLS.edit_distance(low[i - 1], "maternal") <= 2 or
                                    TOOLS.edit_distance(low[i - 1], "paternal") <= 2) else i
            return " ".join(low[start:i + 1])
    caps, run = [], []
    for i, w in enumerate(words):
        if w[0].isupper() and (i > 0 or w.lower() not in ("who", "what", "when", "where", "how", "tell", "find",
                                                           "show", "which", "count", "the", "i")):
            run.append(w.split("'")[0].split("’")[0])
        elif run:
            caps.append(run)
            run = []
    if run:
        caps.append(run)
    if caps:
        return " ".join(max(caps, key=len))
    long = [w for w in words if len(w) > 3 and w.lower() not in ("tell", "about", "show", "videos", "find", "what",
                                                                   "when", "where", "which", "there", "have")]
    return long[-1] if long else (words[-1] if words else "me")


def tool_use(n: int, name: str, inp: dict) -> dict:
    return {"type": "tool_use", "id": f"toolu_fake_{n:04d}", "name": name, "input": inp}


def submit(outcome: str, prose: str, claims=(), subject_ids=(), unresolved=(), reading="", decline="none") -> dict:
    return {"questionReading": reading or "what the asker wants", "subjectIDs": list(subject_ids),
            "unresolved": list(unresolved), "outcome": outcome, "declineReason": decline,
            "claims": list(claims), "prose": prose}


class ScriptedFakeClient:
    def __init__(self, clock: FakeClock | None = None, step_s: float = 0.35):
        self.clock = clock
        self.step_s = step_s
        self.row: dict = {}
        self.n = 0
        self.prefix_cached = False
        self.messages = self   # client.messages.create(...)

    def begin_turn(self, row: dict) -> None:
        self.row = row

    # ---------------------------------------------------------------- state
    @staticmethod
    def _turn_state(messages: list):
        q_idx, question = None, ""
        for i, m in enumerate(messages):
            if m["role"] != "user":
                continue
            content = m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}]
            for b in content:
                if b.get("type") == "text" and not b["text"].startswith(BUDGET_NOTE_PREFIX):
                    q_idx, question = i, b["text"]
        step = sum(1 for m in messages[q_idx + 1:] if m["role"] == "assistant")
        results, prev = [], []
        for i, m in enumerate(messages):
            if m["role"] != "user" or not isinstance(m["content"], list):
                continue
            for b in m["content"]:
                if b.get("type") == "tool_result" and not b.get("is_error"):
                    (results if i > q_idx else prev).append(parse_result(b.get("content")))
        return question, step, results, prev

    # ---------------------------------------------------------------- plan
    def _plan(self, question: str, step: int, results: list, prev: list) -> dict:
        row = self.row
        script = row.get("fakeScript")
        expect = row.get("expect")
        name = guess_name(question)
        last = results[-1] if results else {}
        if script == "never_submit":
            return tool_use(self.n, "resolve_person", {"name": name})
        if script == "hallucinated_tool":
            if step == 0:
                return tool_use(self.n, "delete_media", {"id": "catalog:R1"})
            return submit("declined", "I can't change or delete anything in the archive.", decline="outOfScope")
        if script == "stale":
            old = next((i for r in prev for i in r.get("ids", []) if not i.startswith("q:")), "gedcom:@I1@")
            return submit("answered", "That one was recorded in 1985 [c1].",
                          [{"id": "c1", "kind": "mediaFor", "cites": [old], "value": "1985"}], [old])
        if expect == "social":
            return submit("answered", "Hello! I'm here whenever you want to look through the family archive.")
        if step == 0:
            return tool_use(self.n, "resolve_person", {"name": name})
        cands = [i for i in (results[0].get("items") or []) if "mention" not in i.get("kinds", [])] if results else []
        if script == "uncited":
            return submit("answered", "Frank was born in 1930 [c1]. He sailed boats in 1950.",
                          [{"id": "c1", "kind": "birthDate", "cites": [], "value": "1930"}])
        if script == "wrong_subject":
            qid = results[0].get("queryID", "q:none")
            return submit("answered", "Here is what I found [c1].",
                          [{"id": "c1", "kind": "inference", "cites": [qid], "value": "something"}], [])
        if not cands:
            return submit("declined", f"I don't find {name} in the family records. Would you like me to look "
                                      "through the videos instead?", unresolved=[name], decline="notInTree")
        first = cands[0]
        if expect == "graceful_decline":
            return submit("declined", "The records don't say, so I won't guess. Want me to show what they do say?",
                          subject_ids=[first["id"]], decline="noKnowledge")
        if expect == "clarify" or (len(cands) > 1 and expect in ("clarify",)):
            claims = [{"id": f"c{i + 1}", "kind": "relationship", "cites": [c["id"]], "value": c.get("displayName", "")}
                      for i, c in enumerate(cands[:3])]
            prose = "Did you mean " + " or ".join(f"{c.get('displayName', 'this person')} [c{i + 1}]"
                                                  for i, c in enumerate(cands[:3])) + "?"
            return submit("needsClarification", prose, claims, [c["id"] for c in cands[:3]], decline="ambiguous")
        if step == 1:
            if expect == "catalog":
                return tool_use(self.n, "search_media", {"people": first["id"]})
            return tool_use(self.n, "person_facts", {"id": first["id"]})
        claims = [{"id": "c1", "kind": "relationship", "cites": [first["id"]], "value": first.get("displayName", "")}]
        prose = f"Here is what the records say about {first.get('displayName', 'them')} [c1]."
        if "matchCount" in last:
            claims.append({"id": "c2", "kind": "catalogCount", "cites": [last["queryID"]],
                           "value": str(last["matchCount"])})
            prose += f" I found {last['matchCount']} video(s) with them tagged [c2]."
        elif last.get("ok") and isinstance(last.get("items"), dict):
            birth = ((last["items"].get("tree") or {}).get("birth") or {}).get("yearText")
            if birth:
                claims.append({"id": "c2", "kind": "birthDate", "cites": [last["items"]["id"]], "value": birth})
                prose += f" The tree gives the birth as {birth} [c2]."
        return submit("answered", prose, claims, [first["id"]] + first.get("sameAs", [])[:1],
                      reading=f"facts about {name}")

    # ---------------------------------------------------------------- API surface
    def create(self, **kw):
        if self.clock:
            self.clock.advance(15.0 if self.row.get("fakeScript") == "slow" else self.step_s)
        question, step, results, prev = self._turn_state(kw["messages"])
        action = self._plan(question, step, results, prev)
        self.n += 1
        if action.get("type") != "tool_use":
            action = tool_use(self.n, "submit_answer", action)
        prefix = len(json.dumps(kw.get("system"))) // 4 + len(json.dumps(kw.get("tools"))) // 4
        tail = len(json.dumps(kw["messages"])) // 4
        usage = {"input_tokens": tail, "output_tokens": 120 + len(json.dumps(action)) // 4,
                 "cache_creation_input_tokens": 0 if self.prefix_cached else prefix,
                 "cache_read_input_tokens": prefix if self.prefix_cached else 0}
        self.prefix_cached = True
        return FakeResponse({"id": f"msg_fake_{self.n:04d}", "type": "message", "role": "assistant",
                             "model": kw["model"], "stop_reason": "tool_use", "stop_details": None,
                             "content": [{"type": "thinking", "thinking": "", "signature": "fake-signature"}, action],
                             "usage": usage})


class CassettePlayer:
    def __init__(self, root: str, fallback=None, clock: FakeClock | None = None):
        self.root, self.fallback, self.clock = root, fallback, clock
        self.row_id, self.n = None, 0
        self.hits = self.misses = 0
        self.messages = self

    def begin_turn(self, row: dict) -> None:
        self.row_id, self.n = row.get("id"), 0
        if self.fallback and hasattr(self.fallback, "begin_turn"):
            self.fallback.begin_turn(row)

    def create(self, **kw):
        path = os.path.join(self.root, kw["model"], str(self.row_id), f"{self.n}.json")
        self.n += 1
        if not os.path.exists(path):
            if self.fallback:
                self.misses += 1
                return self.fallback.create(**kw)
            raise BackendError("cassette_missing", path)
        with open(path, encoding="utf-8") as fh:
            tape = json.load(fh)
        got = canonical_hash(json.loads(json.dumps(kw, default=str)))
        if got != tape["requestHash"]:
            raise BackendError("cassette_mismatch",
                               f"{path}: request hash {got} != recorded {tape['requestHash']} (prompt/tool drift)")
        self.hits += 1
        if self.clock:
            self.clock.advance(tape.get("latencyS") or 0.0)   # replay the recorded latency
        return FakeResponse(tape["response"])
