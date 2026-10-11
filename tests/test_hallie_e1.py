"""Offline tests for the Hallie E1 harness (scripts/hallie_e1/).

Everything runs in dry-run: the synthetic fixture snapshot, a scripted fake
model, cassettes recorded into tmp_path. No key, no network, no Application
Support. Run:  venv/bin/python -m pytest tests/test_hallie_e1.py -q
"""
import argparse
import io
import json
import os
import sys
import types
from contextlib import redirect_stdout
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from hallie_e1 import costs, keys, scoring, verifier  # noqa: E402
from hallie_e1.backends import AnthropicBackend, Conversation  # noqa: E402
from hallie_e1.fake import FakeClock, FakeResponse, ScriptedFakeClient  # noqa: E402
from hallie_e1.judge import judge_run  # noqa: E402
from hallie_e1.loop import Budget, route_of, run_turn  # noqa: E402
from hallie_e1.runner import RunConfig, RunRefused, run  # noqa: E402
from hallie_e1.toolbox import FIXTURE_SNAPSHOT, TOOLS, Toolbox, remote_serialize, schema_document, tool_schemas  # noqa: E402

FIXTURE_CORPUS = str(REPO / "tests/fixtures/hallie_e1/corpus.json")
CANARY_TRANSCRIPT = "CANARY-TRANSCRIPT-7f3a"
PRIVATE_CANARY = "PRIVATE-CANARY-55c1"


def dry(tmp_path, **kw):
    cfg = RunConfig(corpus=kw.pop("corpus", FIXTURE_CORPUS), models=kw.pop("models", ["claude-haiku-5-5"]),
                    dry_run=kw.pop("dry_run", True), out=str(tmp_path / kw.pop("name", "run")), quiet=True, **kw)
    return run(cfg)


def turns_of(res, label=None):
    label = label or next(iter(res["backends"]))
    with open(os.path.join(res["out"], label, "turns.jsonl")) as fh:
        return {t["id"]: t for t in map(json.loads, fh)}


def all_output_text(folder) -> str:
    out = []
    for root, _, files in os.walk(folder):
        for f in files:
            out.append(Path(root, f).read_text(encoding="utf-8", errors="replace"))
    return "\n".join(out)


# ---------------------------------------------------------------- the loop

def test_scripted_loop_end_to_end_on_the_fixture(tmp_path):
    res = dry(tmp_path)
    t = turns_of(res)
    assert len(t) == 14
    assert t["e1-fixture-nb-02"]["outcome"] == "needsClarification"           # nana → which one?
    assert t["e1-fixture-so-01"]["toolCalls"] == 0 and t["e1-fixture-so-01"]["route"] == "social"
    assert t["e1-fixture-mh-01"]["route"] == "presence"
    assert t["e1-fixture-ma"]["outcome"] == "answered" and "1933" in t["e1-fixture-ma"]["answer"]
    assert t["e1-fixture-ma"]["claims"] and not t["e1-fixture-ma"]["droppedClaims"]
    bad_tool = t["e1-fixture-bad-tool"]
    assert bad_tool["toolTrace"][0]["error"] == "unknownTool" and bad_tool["outcome"] == "declined"
    for tt in t.values():                                     # every turn carries the measurements
        assert {"latencyMs", "modelCalls", "toolCalls", "usage", "costUSD", "toolTrace"} <= set(tt)
    summary = json.load(open(os.path.join(res["out"], "claude-haiku-5-5__medium__s0", "summary.json")))
    assert summary["overall"]["rows"] == 14 and summary["overall"]["wrongSubject"] == 2


def test_model_call_budget_and_deadline_fall_back_to_decline(tmp_path):
    t = turns_of(dry(tmp_path))
    loop = t["e1-fixture-bad-loop"]
    assert loop["fallbackReason"] == "model_calls" and loop["modelCalls"] == 6 and loop["outcome"] == "declined"
    slow = t["e1-fixture-bad-slow"]
    assert slow["fallbackReason"] == "deadline" and slow["outcome"] == "declined"


def test_tool_call_budget_is_enforced(tmp_path):
    t = turns_of(dry(tmp_path, ids=["e1-fixture-bad-loop"], budget=Budget(max_model_calls=6, max_tool_calls=3)))
    loop = t["e1-fixture-bad-loop"]
    assert loop["toolCalls"] == 3
    assert [x.get("error") for x in loop["toolTrace"]].count("toolBudget") == 3   # calls 4–6 refused


def test_follow_up_keeps_history_and_new_scenario_resets(tmp_path):
    res = dry(tmp_path, ids=["conversation-cv-01", "e1-fixture-so-01"], keep_requests=True)
    reqs = next(iter(res["backends"].values())).requests
    t2_first = next(r for r in reqs if "when was that video made" in json.dumps(r["messages"]))
    assert "tell me about Frank Fixture" in json.dumps(t2_first["messages"])      # history kept
    social = [r for r in reqs if "hello Hallie" in json.dumps(r["messages"])]
    assert all("Frank Fixture" not in json.dumps(r["messages"]) for r in social)  # reset at the boundary


def test_spend_cap_stops_the_run_and_is_never_exceeded(tmp_path):
    res = dry(tmp_path, models=["claude-fable-5-1"], budget_usd=0.6)
    meta = res["meta"]
    assert meta["stoppedReason"] == "spend_cap"
    assert meta["spentUSD"] <= 0.6
    assert meta["capRefusals"]
    t = turns_of(res)
    assert len(t) < 14 and list(t.values())[-1]["fallbackReason"] == "spend_cap"


def test_spend_cap_unit():
    cap = costs.SpendCap(1.0)
    cap.check(0.9)
    cap.add(0.5)
    with pytest.raises(costs.SpendCapReached):
        cap.check(0.51)
    assert cap.refused


def test_cost_accounting_against_a_frozen_price_row():
    row = {"input": 2.0, "output": 10.0, "cacheRead": 0.2, "cacheWrite": 2.5}
    usage = {"input": 200, "cacheWrite": 3600, "cacheRead": 16000, "output": 1750}
    assert costs.cost_usd(usage, row) == pytest.approx(0.0301)          # the spec's Sonnet worked example
    assert costs.call_ceiling_usd(3000, 1000, row) > (1000 * 10.0) / 1e6


def test_price_table_is_dated_sourced_and_flagged():
    p = costs.load_prices()
    assert p["asOf"] and p["source"] and "verified" in p
    assert set(p["models"]) == {"claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"}
    for row in p["models"].values():
        assert row["cacheWrite"] == pytest.approx(row["input"] * p["cacheWriteMultiplier"])


def test_projection_over_budget_refuses_a_real_run(tmp_path):
    with pytest.raises(RunRefused):
        dry(tmp_path, dry_run=False, models=["claude-fable-5-1"], budget_usd=0.01, snapshots=FIXTURE_SNAPSHOT)


# ---------------------------------------------------------------- cassettes

def test_cassette_record_then_replay_is_identical_and_drift_is_reported(tmp_path):
    tapes = tmp_path / "tapes"
    a = turns_of(dry(tmp_path, name="rec", record=str(tapes)))
    assert any(tapes.rglob("0.json"))
    b = turns_of(dry(tmp_path, name="replay", cassettes=str(tapes)))
    for k in a:
        assert (a[k]["outcome"], a[k]["answer"]) == (b[k]["outcome"], b[k]["answer"])
    # prompt drift (a different effort changes the request hash) must be reported, never answered
    c = turns_of(dry(tmp_path, name="drift", cassettes=str(tapes), effort="high"))
    assert all(t["fallbackReason"] == "cassette_mismatch" for t in c.values())


def test_record_refuses_real_family_cassettes_in_the_repo(tmp_path):
    snap = tmp_path / "realish"
    snap.mkdir()
    for f in ("tree.json", "people.json", "brain.json", "catalog.json"):
        (snap / f).write_text(Path(FIXTURE_SNAPSHOT, f).read_text())
    with pytest.raises(RunRefused):
        dry(tmp_path, snapshots=str(snap), record=str(REPO / "tests/fixtures/hallie_e1/cassettes"))


def test_fixture_is_synthetic_and_ids_are_fixture_ids():
    m = json.load(open(Path(FIXTURE_SNAPSHOT, "manifest.json")))
    assert m["synthetic"] is True
    rows, _ = scoring.load_corpus(FIXTURE_CORPUS)
    assert all(r["id"].startswith("e1-fixture-") for r in rows)


# ---------------------------------------------------------------- keys

def test_key_lookup_order_env_then_keychain_then_profile():
    assert keys.resolve_key("ANTHROPIC_API_KEY", "anthropic", env={"ANTHROPIC_API_KEY": "sk-env-1234567890"},
                            runner=None) == ("sk-env-1234567890", "env")

    def keychain(cmd, **kw):
        assert cmd[:2] == ["security", "find-generic-password"] and "hallie-e1" in cmd and "anthropic" in cmd
        return types.SimpleNamespace(returncode=0, stdout="sk-keychain-abcdefgh\n")
    assert keys.resolve_key("ANTHROPIC_API_KEY", "anthropic", env={}, runner=keychain) == \
        ("sk-keychain-abcdefgh", "keychain")

    def missing(cmd, **kw):
        return types.SimpleNamespace(returncode=44, stdout="")
    assert keys.resolve_key("ANTHROPIC_API_KEY", "anthropic", env={}, runner=missing) == (None, "profile")


def test_key_canary_never_reaches_output_or_console(tmp_path, monkeypatch):
    """A 'real' run with a stub SDK: the canary key is handed to the client in
    memory, an SDK error even echoes it — and it appears in no file and no
    console line; run.json records only the key SOURCE."""
    canary = "sk-ant-CANARY-KEY-0123456789abcdef"
    monkeypatch.setenv("ANTHROPIC_API_KEY", canary)
    seen = {}

    class EchoingError(Exception):
        status_code = 500

    class StubAnthropic:
        def __init__(self, api_key=None, **kw):
            seen["key"] = api_key
            self.inner = ScriptedFakeClient(FakeClock())
            self.messages = self
            self.row = {}

        def begin_turn(self, row):
            self.row = row
            self.inner.begin_turn(row)

        def create(self, **kw):
            if self.row.get("id") == "e1-fixture-so-01":
                raise EchoingError(f"upstream said: bad header x-api-key: {canary}")
            return self.inner.create(**kw)

    monkeypatch.setitem(sys.modules, "anthropic", types.SimpleNamespace(Anthropic=StubAnthropic))
    buf = io.StringIO()
    with redirect_stdout(buf):
        res = run(RunConfig(corpus=FIXTURE_CORPUS, models=["claude-haiku-5-5"], dry_run=False,
                            snapshots=FIXTURE_SNAPSHOT, out=str(tmp_path / "real"), budget_usd=1.0,
                            ids=["e1-fixture-nb-01", "e1-fixture-so-01", "e1-fixture-ma"]))
    assert seen["key"] == canary                                    # the client got it, in memory
    assert res["meta"]["keySource"] == "env"
    t = turns_of(res)
    assert t["e1-fixture-so-01"]["fallbackReason"].startswith("api_error")
    blob = all_output_text(res["out"]) + buf.getvalue()
    assert canary not in blob
    assert "[REDACTED-KEY]" in blob                                # the echo was caught and scrubbed


# ---------------------------------------------------------------- verifier

def test_turn_local_citation_check_drops_facts_from_earlier_turns():
    sub = {"outcome": "answered", "subjectIDs": ["gedcom:@I2@", "gedcom:@I9@"], "unresolved": [],
           "claims": [{"id": "c1", "kind": "birthDate", "cites": ["gedcom:@I2@"], "value": "1930"},
                      {"id": "c2", "kind": "birthDate", "cites": ["gedcom:@I9@"], "value": "1870"},
                      {"id": "c3", "kind": "inference", "cites": [], "value": "x"}],
           "prose": "Frank was born in 1930 [c1]. Patrick was born about 1870 [c2]. He liked boats in 1950. "
                    "That's all I have."}
    v = verifier.verify(sub, {"gedcom:@I2@", "q:q-1"}, "tell me about Frank", [])
    assert [c["id"] for c in v["claims"]] == ["c1"]
    assert v["unverifiedFacts"] == 2                               # c2 from another turn, c3 uncited
    assert "1930" in v["answer"] and "1870" not in v["answer"] and "1950" not in v["answer"]
    assert "[c1]" not in v["answer"] and "That's all I have." in v["answer"]
    assert v["subjectIDs"] == ["gedcom:@I2@"] and v["subjectIDsNotThisTurn"] == ["gedcom:@I9@"]


def test_stale_fact_from_the_previous_turn_is_counted_in_the_loop(tmp_path):
    t = turns_of(dry(tmp_path, ids=["conversation-cv-01"]))
    t2 = t["e1-fixture-cv-01-t2"]
    assert t2["unverifiedFacts"] == 1 and t2["toolCalls"] == 0
    assert "1985" not in t2["answer"]


def test_subject_check_turns_a_wrong_subject_into_a_decline():
    res = {"ok": True, "items": [{"id": "gedcom:@I20@", "sameAs": ["people:P-DORA"]}]}
    sub = {"outcome": "answered", "subjectIDs": [], "unresolved": [], "prose": "Here she is [c1].",
           "claims": [{"id": "c1", "kind": "inference", "cites": ["q:q-1"], "value": "x"}]}
    v = verifier.verify(sub, {"q:q-1", "gedcom:@I20@"}, "tell me about Dora", [("Dora", res)])
    assert v["wrongSubject"] and v["outcome"] == "declined" and v["wrongSubjectNames"] == ["Dora"]
    ok = verifier.verify({**sub, "subjectIDs": ["people:P-DORA"]}, {"q:q-1", "people:P-DORA"},
                         "tell me about Dora", [("Dora", res)])
    assert not ok["wrongSubject"] and ok["outcome"] == "answered"
    # a resolve the model made on its own (not a name the asker used) is not checked
    side = verifier.verify(sub, {"q:q-1"}, "how many videos are there", [("Dora", res)])
    assert not side["wrongSubject"]


def test_clarifying_question_may_name_candidates_and_asker_words_are_not_facts():
    sub = {"outcome": "needsClarification", "subjectIDs": [], "unresolved": [], "claims": [],
           "prose": "Did you mean Gladys Ashby or Ivy Harlow?"}
    assert verifier.verify(sub, set(), "find nana", [])["answer"] == "Did you mean Gladys Ashby or Ivy Harlow?"
    sub = {"outcome": "declined", "subjectIDs": [], "unresolved": ["Zebulon"], "claims": [],
           "prose": "I don't find Zebulon in the family records. Want me to search the videos?"}
    assert "Zebulon" in verifier.verify(sub, set(), "what was Zebulon's favourite song?", [])["answer"]


# ---------------------------------------------------------------- loop edge cases (hand-made clients)

class OneShot:
    """A client that returns one fixed response."""

    def __init__(self, resp):
        self.resp, self.messages = resp, self

    def create(self, **kw):
        return FakeResponse(self.resp)


def one_turn(resp, budget=Budget(), clock=None):
    be = AnthropicBackend(OneShot(resp), "claude-haiku-5-5")
    cap = costs.SpendCap(1.0)
    return run_turn(be, Conversation(), {"id": "x", "text": "hello"}, Toolbox(FIXTURE_SNAPSHOT), budget, cap,
                    clock or FakeClock())


def test_prose_without_submit_is_a_counted_fallback():
    r = one_turn({"content": [{"type": "text", "text": "Frank was born in 1930."}], "stop_reason": "end_turn",
                  "usage": {"input_tokens": 10, "output_tokens": 5}})
    assert r["fallbackReason"] == "no_submission" and r["answerRaw"] == "Frank was born in 1930."
    assert "1930" not in r["answer"]


def test_refusal_and_max_tokens_are_recorded_not_routed_around():
    r = one_turn({"content": [], "stop_reason": "refusal", "stop_details": {"category": "cyber"},
                  "usage": {"input_tokens": 10, "output_tokens": 0}})
    assert r["fallbackReason"] == "refusal" and r["outcome"] == "declined"
    r = one_turn({"content": [], "stop_reason": "max_tokens", "usage": {"input_tokens": 10, "output_tokens": 9}})
    assert r["fallbackReason"] == "max_tokens"


def test_usage_and_cost_come_from_the_response():
    r = one_turn({"content": [{"type": "tool_use", "id": "t1", "name": "submit_answer",
                               "input": {"questionReading": "hi", "subjectIDs": [], "unresolved": [], "claims": [],
                                         "outcome": "answered", "prose": "Hello there!"}}],
                  "stop_reason": "tool_use",
                  "usage": {"input_tokens": 1000, "output_tokens": 2000, "cache_creation_input_tokens": 3000,
                            "cache_read_input_tokens": 4000}})
    assert r["usage"] == {"input": 1000, "output": 2000, "cacheWrite": 3000, "cacheRead": 4000}
    assert r["costUSD"] == pytest.approx((1000 * 0.10 + 2000 * 0.50 + 3000 * 0.125 + 4000 * 0.01) / 1e6)
    assert r["answer"] == "Hello there!"


def test_route_mapping():
    assert route_of([]) == "social"
    assert route_of([{"name": "resolve_person"}, {"name": "search_media"}]) == "presence"
    assert route_of([{"name": "catalog_stats", "input": {"surname": "Harlow"}}]) == "graph"
    assert route_of([{"name": "catalog_stats", "input": {"group_by": "decade"}}]) == "catalog-stats"


def test_ollama_backend_runs_the_same_loop(tmp_path):
    res = dry(tmp_path, models=["ollama:qwen3.8:27b-mlx"], ids=["e1-fixture-ma", "conversation-cv-01"], keep_requests=True)
    t = turns_of(res)
    assert t["e1-fixture-ma"]["outcome"] == "answered" and t["e1-fixture-ma"]["provider"] == "ollama"
    assert t["e1-fixture-ma"]["costUSD"] == 0
    reqs = next(iter(res["backends"].values())).requests
    assert any(m["role"] == "tool" for r in reqs for m in r["messages"])
    assert reqs[0]["tools"][0]["type"] == "function"


# ---------------------------------------------------------------- privacy

def test_remote_serializer_never_emits_family_media_and_proves_the_gate(tmp_path):
    red = dry(tmp_path, name="redacted", keep_requests=True)
    body = json.dumps(next(iter(red["backends"].values())).requests)
    assert "catalog:FX-004" in body                       # the canary RECORD's id does go out (ids kept)…
    assert CANARY_TRANSCRIPT not in body                  # …its transcript text does not
    assert PRIVATE_CANARY not in body
    assert CANARY_TRANSCRIPT not in all_output_text(red["out"])
    full = dry(tmp_path, name="included", keep_requests=True, include_derived_text=True)
    body = json.dumps(next(iter(full["backends"].values())).requests)
    assert CANARY_TRANSCRIPT in body                      # the gate is real: flip it and the text flows
    assert PRIVATE_CANARY not in body                     # private items never leave, in either mode
    assert "INCLUDED" in full["meta"]["derivedText"]


def test_remote_serialize_withholds_private_items_and_caps_size():
    s = remote_serialize({"ok": True, "items": [{"id": "brain:x", "privacy": "private", "text": "secret"}]})
    assert "secret" not in s and "withheld" in s and s.startswith("<tool-result>")
    big = {"ok": True, "items": [{"id": f"catalog:{i}", "text": "x" * 500} for i in range(200)]}
    out = remote_serialize(big)
    assert len(out) < 25000 and '"truncated":true' in out


# ---------------------------------------------------------------- scoring + schemas

def test_records_grade_with_the_existing_hallie_eval_grader(tmp_path):
    res = dry(tmp_path)
    path = os.path.join(res["out"], "claude-haiku-5-5__medium__s0", "records.jsonl")
    he = scoring.hallie_eval()
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = he.grade(argparse.Namespace(run=path, show=0, compare=None, strict=False))
    assert rc == 0                                         # complete, advisory
    summary = json.load(open(path.replace(".jsonl", ".summary.json")))
    assert summary["status"] == "advisory" and summary["completed"] == 14
    rec = json.loads(open(path).readlines()[1])
    for k in ("id", "category", "expect", "answer", "route", "outcome", "queryDescription", "mediaEvidence",
              "lane", "toolCalls", "modelCalls", "unverifiedFacts", "wrongSubject", "latencyMs", "usage", "costUSD"):
        assert k in rec


def test_judge_dry_run_fills_the_scorecard(tmp_path):
    res = dry(tmp_path)
    s = judge_run(res["out"], dry_run=True, quiet=True)
    assert s["judged"] == 14 and s["spentUSD"] <= 3.0
    card = json.load(open(os.path.join(res["out"], "claude-haiku-5-5__medium__s0", "summary.json")))
    assert card["overall"]["judge"]["graded"] == 14
    assert card["categories"]["no_bluff"]["judgeMetBar"] in (True, False)
    md = open(os.path.join(res["out"], "claude-haiku-5-5__medium__s0", "scorecard.md")).read()
    assert "judge: claude-fable-5-1" in md


def test_judge_respects_its_own_cap(tmp_path):
    res = dry(tmp_path)
    s = judge_run(res["out"], dry_run=True, quiet=True, budget_usd=0.02)
    assert s["stopped"] and s["spentUSD"] <= 0.02


def test_tool_schemas_are_strict_generated_from_the_tool_kit_and_golden():
    ts = tool_schemas()
    assert [t["name"] for t in ts] == list(TOOLS.TOOL_SPECS) + ["submit_answer"]
    for t in ts:
        assert t["strict"] is True
        assert t["input_schema"]["additionalProperties"] is False
        assert set(t["input_schema"]["required"]) <= set(t["input_schema"]["properties"])
    golden = json.load(open(REPO / "docs/hallie_tools.schema.json"))
    assert golden == json.loads(json.dumps(schema_document())), "regenerate: scripts/hallie_e1/cli.py schema"


def test_real_sdk_accepts_the_request_and_parses_the_reply_offline():
    """The real anthropic client over a mock transport (no network): our kwargs
    serialize, the key goes only in the header, and the reply parses."""
    anthropic = pytest.importorskip("anthropic")
    httpx2 = pytest.importorskip("httpx2")
    captured = {}
    reply = {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
             "stop_reason": "tool_use", "stop_sequence": None,
             "content": [{"type": "thinking", "thinking": "", "signature": "sig"},
                         {"type": "tool_use", "id": "toolu_1", "name": "submit_answer",
                          "input": {"questionReading": "hi", "subjectIDs": [], "unresolved": [], "claims": [],
                                    "outcome": "answered", "prose": "Hello!"}}],
             "usage": {"input_tokens": 12, "output_tokens": 34, "cache_creation_input_tokens": 3500,
                       "cache_read_input_tokens": 0}}

    def handler(request):
        captured["body"] = json.loads(request.content)
        captured["key"] = request.headers.get("x-api-key")
        return httpx2.Response(200, json=reply)

    canary = "sk-ant-OFFLINE-CANARY-000000000000"
    client = anthropic.Anthropic(api_key=canary, base_url="http://mock.invalid", max_retries=0,
                                 http_client=anthropic.DefaultHttpxClient(transport=httpx2.MockTransport(handler)))
    be = AnthropicBackend(client, "claude-haiku-5-5", effort="low")
    r = run_turn(be, Conversation(), {"id": "x", "text": "hello"}, Toolbox(FIXTURE_SNAPSHOT), Budget(),
                 costs.SpendCap(1.0))
    body = captured["body"]
    assert captured["key"] == canary and canary not in json.dumps(body)
    assert body["output_config"] == {"effort": "low"} and body["cache_control"] == {"type": "ephemeral"}
    assert "thinking" not in body and "tool_choice" not in body          # adaptive by default; no forced tools
    assert body["system"][-1]["cache_control"] == {"type": "ephemeral"}
    assert all(t["strict"] for t in body["tools"])
    assert r["answer"] == "Hello!" and r["usage"]["cacheWrite"] == 3500
