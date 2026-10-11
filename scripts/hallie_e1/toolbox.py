"""The E1 tool backend: the demo tool kit (scripts/hallie_demo/tools.py),
imported — never forked — plus the generated JSON Schemas and the ONE
function that turns a tool result into what leaves this machine.
"""
from __future__ import annotations

import importlib.util
import json
import os
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEMO_TOOLS = os.path.join(REPO, "scripts", "hallie_demo", "tools.py")
FIXTURE_SNAPSHOT = os.path.join(REPO, "tests", "fixtures", "hallie_e1", "snapshot")
RESULT_CHAR_BUDGET = 24000     # one tool result, serialized; larger results are cut and say so


def load_demo_tools():
    spec = importlib.util.spec_from_file_location("hallie_demo_tools", DEMO_TOOLS)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


TOOLS = load_demo_tools()

# ---------------------------------------------------------------- schemas

SUBMIT_ANSWER = {
    "name": "submit_answer",
    "description": "End the turn. Every answer — including a decline or a which-one question — is given by "
                   "calling this exactly once. Cite every fact as a claim whose `cites` are ids returned by a "
                   "tool in THIS turn, and mark it in prose as [c1], [c2].",
    "strict": True,
    "input_schema": {
        "type": "object", "additionalProperties": False,
        "required": ["questionReading", "subjectIDs", "unresolved", "claims", "prose", "outcome"],
        "properties": {
            "questionReading": {"type": "string", "description": "One sentence: what you understood the asker to want."},
            "subjectIDs": {"type": "array", "items": {"type": "string"},
                           "description": "ids from THIS turn's tool results that the answer is about"},
            "unresolved": {"type": "array", "items": {"type": "string"},
                           "description": "names the asker used that no tool resolved"},
            "outcome": {"type": "string", "enum": ["answered", "declined", "needsClarification"]},
            "declineReason": {"type": "string",
                              "enum": ["notInTree", "ambiguous", "noMedia", "noKnowledge", "outOfScope", "none"]},
            "claims": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["id", "kind", "cites", "value"],
                "properties": {
                    "id": {"type": "string", "description": "c1, c2, …"},
                    "kind": {"type": "string", "enum": ["birthDate", "deathDate", "eventPlace", "relationship",
                                                        "familyItem", "mediaFor", "catalogCount",
                                                        "mediumFeasibility", "worldFact", "inference"]},
                    "cites": {"type": "array", "items": {"type": "string"}},
                    "value": {"type": "string"}}}},
            "prose": {"type": "string",
                      "description": "Hallie's wording. Cite claims as [c1], [c2]. A sentence with a name, date, "
                                     "number or place and no citation will be removed."},
            "offers": {"type": "array", "items": {"type": "string",
                                                  "enum": ["openFamilyTree", "showPhotos", "playMedia", "narrow"]}},
        },
    },
}


STRICT_MODES = ("all", "submit", "none")


def tool_schemas(strict_tools: str = "all") -> list[dict]:
    """Anthropic tool definitions, deterministic order (cache-stable).

    strict_tools: all (spec default) | submit (only submit_answer strict — the
    fallback if the API rejects the combined strict grammar as too large) | none."""
    if strict_tools not in STRICT_MODES:
        raise ValueError(f"strict_tools must be one of {STRICT_MODES}")
    out = []
    for name, spec in TOOLS.TOOL_SPECS.items():
        props = {}
        for arg, a in spec["args"].items():
            p = {"type": a["type"]}
            if a.get("description"):
                p["description"] = a["description"]
            if a.get("enum"):
                p["enum"] = list(a["enum"])
            props[arg] = p
        t = {"name": name, "description": spec["description"], "strict": True,
             "input_schema": {"type": "object", "additionalProperties": False,
                              "properties": props, "required": list(spec["required"])}}
        if strict_tools != "all":
            t.pop("strict")
        out.append(t)
    sub = dict(SUBMIT_ANSWER)
    if strict_tools == "none":
        sub.pop("strict")
    out.append(sub)
    return out


def ollama_tool_schemas() -> list[dict]:
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["input_schema"]}} for t in tool_schemas()]


def schema_document() -> dict:
    return {"version": 1, "generatedBy": "scripts/hallie_e1/cli.py schema",
            "note": "Hallie agent-lane tool schemas (E1). Generated from scripts/hallie_demo/tools.py TOOL_SPECS; "
                    "the Swift phase-0 catalog is diffed against this file.",
            "tools": tool_schemas()}


# ---------------------------------------------------------------- privacy

def _withhold_private(x):
    if isinstance(x, dict):
        if x.get("privacy") == "private":
            return {"id": x.get("id"), "withheld": "private item: never leaves the Mac"}
        return {k: _withhold_private(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_withhold_private(v) for v in x]
    return x


def remote_serialize(result: dict) -> str:
    """THE enforcement point: the only function that turns a tool result into
    text sent to a model. Private CyberBrain items are replaced by their id;
    transcript/caption text was already redacted by the tool kit unless the
    run was started with --include-derived-text (Data.redact=False)."""
    clean = _withhold_private(result)
    body = json.dumps(clean, ensure_ascii=False, separators=(",", ":"))
    if len(body) > RESULT_CHAR_BUDGET and isinstance(clean.get("items"), list):
        items = clean["items"]
        while items and len(body) > RESULT_CHAR_BUDGET:
            items = items[: max(0, len(items) * 2 // 3)]
            clean = {**clean, "items": items, "truncated": True,
                     "transportNote": "result cut to fit; narrow the query for the rest"}
            body = json.dumps(clean, ensure_ascii=False, separators=(",", ":"))
    if len(body) > RESULT_CHAR_BUDGET:
        body = json.dumps({"ok": False, "error": "resultTooLarge",
                           "detail": "narrow the query (fewer filters matched too much)"})
    return "<tool-result>\n" + body + "\n</tool-result>"


class Toolbox:
    """One loaded snapshot shared by every turn of a run."""

    def __init__(self, snapshots: str, include_derived_text: bool = False):
        self.snapshots = snapshots
        self.include_derived_text = include_derived_text
        self.D = TOOLS.Data(snapshots, redact=not include_derived_text)

    def execute(self, name: str, args) -> tuple[dict, str, float]:
        t0 = time.monotonic()
        res = TOOLS.call_tool(self.D, name, args)
        return res, remote_serialize(res), time.monotonic() - t0

    def manifest(self) -> dict:
        path = os.path.join(self.snapshots, "manifest.json")
        if not os.path.exists(path):
            return {}
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
        return {k: m.get(k) for k in ("createdAt", "counts") if k in m}
