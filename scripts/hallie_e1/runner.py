"""Run a corpus through the agent loop for each model × seed and write the results.

Layout of one run (default ~/Library/Logs/VideoScan/hallie-eval/e1-<stamp>/):
    run.json                 meta: corpus sha, snapshot, prices used, budget, key SOURCE only, spend
    <model>__<effort>__s<n>/
        turns.jsonl          one line per turn: question, answer, tool trace, latency, tokens, $
        records.jsonl        hallie_eval.py-shaped (meta line first) — `hallie_eval.py grade --run` works on it
        summary.json         scorecard for this model/seed
        scorecard.md         the same as a table + per-row sheet
    matrix.md / matrix.json  every model/seed side by side
"""
from __future__ import annotations

import datetime as dt
import glob
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field

from . import costs, keys, scoring
from .backends import AnthropicBackend, OllamaBackend, Recorder
from .fake import CassettePlayer, FakeClock, ScriptedFakeClient, parse_result
from .loop import Budget, run_turn
from .toolbox import FIXTURE_SNAPSHOT, REPO, Toolbox

SNAPSHOT_ROOT = os.path.expanduser("~/Library/Application Support/VideoScan/hallie-e1/snapshots")
LOG_ROOT = os.path.expanduser("~/Library/Logs/VideoScan/hallie-eval")
ANTHROPIC_MODELS = ("claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1")


@dataclass
class RunConfig:
    corpus: str
    models: list
    effort: str = "medium"
    seeds: int = 1
    budget_usd: float = 10.0
    dry_run: bool = False
    cassettes: str | None = None
    record: str | None = None
    snapshots: str | None = None
    include_derived_text: bool = False
    out: str | None = None
    budget: Budget = field(default_factory=Budget)
    max_tokens: int = 6000
    ollama_host: str = "http://localhost:11434"
    limit: int | None = None
    ids: list | None = None
    allow_over_projection: bool = False
    keep_requests: bool = False
    quiet: bool = False
    strict_tools: str = "all"


class RunRefused(Exception):
    pass


def say(cfg, msg: str) -> None:
    if not cfg.quiet:
        print(keys.scrub(msg), flush=True)


def write_jsonl(fh, obj) -> None:
    fh.write(keys.scrub(json.dumps(obj, ensure_ascii=False, default=str)) + "\n")
    fh.flush()


def write_json(path: str, obj) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(keys.scrub(json.dumps(obj, ensure_ascii=False, indent=1, default=str)) + "\n")


def write_text(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(keys.scrub(text))


def sha256_file(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def git_sha() -> str | None:
    try:
        return subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=5).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def default_snapshots(dry: bool) -> str:
    if dry:
        return FIXTURE_SNAPSHOT
    found = sorted(glob.glob(os.path.join(SNAPSHOT_ROOT, "*", "tree.json")))
    if not found:
        raise RunRefused(f"no snapshot under {SNAPSHOT_ROOT}; export one first (README step 0) or pass --snapshots")
    return os.path.dirname(found[-1])


def inside(path: str, root: str) -> bool:
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def label_of(model: str, effort: str, seed: int) -> str:
    return f"{model.replace(':', '-').replace('/', '-')}__{effort}__s{seed}"


def select_rows(cfg: RunConfig) -> tuple[list, dict]:
    rows, bars = scoring.load_corpus(cfg.corpus)
    if cfg.ids:
        want = set(cfg.ids)
        rows = [r for r in rows if r["id"] in want or r.get("scenarioID") in want]
    if cfg.limit:
        # never cut a conversation in half: extend to the end of the last scenario
        cut = rows[:cfg.limit]
        while len(cut) < len(rows) and rows[len(cut)].get("followsPrevious"):
            cut.append(rows[len(cut)])
        rows = cut
    return rows, bars


def projection(cfg: RunConfig, n_rows: int, prices: dict) -> dict:
    per = {}
    for m in cfg.models:
        if m.startswith("ollama:"):
            per[m] = 0.0
        else:
            per[m] = costs.per_turn_estimate(costs.price_row(prices, m), cfg.effort) * n_rows * cfg.seeds
    return {"perModelUSD": {k: round(v, 4) for k, v in per.items()}, "totalUSD": round(sum(per.values()), 4),
            "basis": "spec §8 per-turn token model (±35%); real usage replaces it"}


def ollama_fake_post(fake: ScriptedFakeClient):
    """A scripted Ollama /api/chat for dry runs: the same plans as the Anthropic fake."""
    def post(url, payload, headers, timeout):
        msgs = payload["messages"]
        q_idx = max(i for i, m in enumerate(msgs) if m["role"] == "user" and not m["content"].startswith("Budget:"))
        question = msgs[q_idx]["content"]
        step = sum(1 for m in msgs[q_idx + 1:] if m["role"] == "assistant")
        res = lambda ms: [parse_result(m["content"]) for m in ms if m["role"] == "tool"  # noqa: E731
                          and not m["content"].startswith(("ERROR", "not run"))]
        action = fake._plan(question, step, res(msgs[q_idx + 1:]), res(msgs[:q_idx]))
        fake.n += 1
        if fake.clock:
            fake.clock.advance(fake.step_s)
        if action.get("type") == "tool_use":
            call = {"function": {"name": action["name"], "arguments": action["input"]}}
        else:
            call = {"function": {"name": "submit_answer", "arguments": action}}
        return {"model": payload["model"], "message": {"role": "assistant", "content": "", "tool_calls": [call]},
                "done": True, "done_reason": "stop", "prompt_eval_count": len(json.dumps(msgs)) // 4,
                "eval_count": 100}

    def get(url, headers, timeout):
        return {"models": [{"name": "fake"}]}
    return post, get


def make_backend(cfg: RunConfig, model: str, seed: int, prices: dict, clock, recorder, key: str | None):
    if model.startswith("ollama:"):
        name = model.split(":", 1)[1]
        if cfg.dry_run:
            fake = ScriptedFakeClient(clock)
            post, get = ollama_fake_post(fake)
            return OllamaBackend(name, host="http://localhost:11434", seed=seed, prices=prices, post=post, get=get,
                                 keep_requests=cfg.keep_requests, recorder=recorder, turn_hook=fake.begin_turn)
        okey = None
        if not any(h in cfg.ollama_host for h in ("localhost", "127.0.0.1")):
            okey, _ = keys.ollama_key()
        b = OllamaBackend(name, host=cfg.ollama_host, api_key=okey, seed=seed, prices=prices,
                          keep_requests=cfg.keep_requests, recorder=recorder)
        b.check()
        return b
    if cfg.dry_run:
        fake = ScriptedFakeClient(clock)
        client = CassettePlayer(cfg.cassettes, fallback=fake, clock=clock) if cfg.cassettes else fake
    else:
        import anthropic  # only a real run needs the SDK
        client = anthropic.Anthropic(api_key=key) if key else anthropic.Anthropic()
    return AnthropicBackend(client, model, effort=cfg.effort, max_tokens=cfg.max_tokens, prices=prices,
                            recorder=recorder, keep_requests=cfg.keep_requests, clock=clock,
                            strict_tools=cfg.strict_tools)


def run(cfg: RunConfig) -> dict:
    prices = costs.load_prices()
    for m in cfg.models:
        if not m.startswith("ollama:") and m not in prices["models"]:
            raise RunRefused(f"unknown model {m!r}; known: {', '.join(prices['models'])} or ollama:<tag>")
    rows, bars = select_rows(cfg)
    if not rows:
        raise RunRefused("no corpus rows selected")
    snapshots = cfg.snapshots or default_snapshots(cfg.dry_run)
    if cfg.record and inside(cfg.record, REPO) and os.path.realpath(snapshots) != os.path.realpath(FIXTURE_SNAPSHOT):
        raise RunRefused("cassettes recorded from a real-family snapshot must never be written inside the repo; "
                         "record from the fixture snapshot or point --record outside the repo")
    proj = projection(cfg, len(rows), prices)
    if not cfg.dry_run and proj["totalUSD"] > cfg.budget_usd and not cfg.allow_over_projection:
        raise RunRefused(f"projected ${proj['totalUSD']:.2f} > --budget-usd {cfg.budget_usd:.2f}; raise the budget, "
                         "trim --limit/--models/--seeds, or pass --allow-over-projection (the hard cap still stops it)")
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = cfg.out or os.path.join(LOG_ROOT, f"e1-{stamp}{'-dry' if cfg.dry_run else ''}")
    os.makedirs(out, exist_ok=True)

    key, key_source = (None, "none (dry run)")
    if not cfg.dry_run and any(not m.startswith("ollama:") for m in cfg.models):
        key, key_source = keys.anthropic_key()
    toolbox = Toolbox(snapshots, cfg.include_derived_text)
    cap = costs.SpendCap(cfg.budget_usd)
    clock = FakeClock() if cfg.dry_run else time.monotonic
    recorder = Recorder(cfg.record) if cfg.record else None

    meta = {
        "harness": "hallie_e1", "started": dt.datetime.now().isoformat(timespec="seconds"), "git": git_sha(),
        "dryRun": cfg.dry_run, "corpus": os.path.relpath(cfg.corpus, REPO) if inside(cfg.corpus, REPO) else cfg.corpus,
        "corpusSha256": sha256_file(cfg.corpus), "turns": len(rows), "ids": [r["id"] for r in rows],
        "models": cfg.models, "effort": cfg.effort, "seeds": cfg.seeds,
        "budgets": {"maxModelCalls": cfg.budget.max_model_calls, "maxToolCalls": cfg.budget.max_tool_calls,
                    "deadlineS": cfg.budget.deadline_s, "maxTokens": cfg.max_tokens,
                    "strictTools": cfg.strict_tools},
        "spendCapUSD": cfg.budget_usd, "projection": proj,
        "prices": {"asOf": prices["asOf"], "verified": prices["verified"], "status": prices.get("status"),
                   "rows": {m: prices["models"].get(m) for m in cfg.models if not m.startswith("ollama:")}},
        "keySource": key_source, "snapshots": snapshots, "snapshotManifest": toolbox.manifest(),
        "derivedText": "INCLUDED (transcript/caption text sent to the model)" if cfg.include_derived_text
        else "excluded (redacted before leaving the Mac)",
        "cassettes": cfg.cassettes, "record": cfg.record,
    }
    write_json(os.path.join(out, "run.json"), meta)
    say(cfg, f"START hallie-e1 {'DRY RUN ' if cfg.dry_run else ''}{len(rows)} turns × {len(cfg.models)} model(s) × "
             f"{cfg.seeds} seed(s); cap ${cfg.budget_usd:.2f}; projected ${proj['totalUSD']:.2f}; "
             f"prices {'verified' if prices['verified'] else 'ESTIMATE'} {prices['asOf']}; key {key_source}; "
             f"derived text {'INCLUDED' if cfg.include_derived_text else 'excluded'} → {out}")

    stopped, all_cards, total, n_done = None, [], len(rows) * len(cfg.models) * cfg.seeds, 0
    backends = {}
    for model in cfg.models:
        if stopped:
            break
        for seed in range(cfg.seeds):
            if stopped:
                break
            label = label_of(model, cfg.effort, seed)
            d = os.path.join(out, label)
            os.makedirs(d, exist_ok=True)
            try:
                backend = make_backend(cfg, model, seed, prices, clock, recorder, key)
            except Exception as e:  # unreachable Ollama, missing SDK, …: skip this model, say why
                say(cfg, f"SKIP {label}: {type(e).__name__}: {e}")
                write_json(os.path.join(d, "summary.json"), {"skipped": f"{type(e).__name__}: {e}"})
                break
            backends[label] = backend
            records, conv, prev_scenario = [], None, None
            with open(os.path.join(d, "turns.jsonl"), "w", encoding="utf-8") as tf:
                for row in rows:
                    scenario = row.get("scenarioID") or row["id"]
                    if conv is None or not row.get("followsPrevious") or scenario != prev_scenario:
                        conv = backend.new_conversation()
                    prev_scenario = scenario
                    turn = run_turn(backend, conv, row, toolbox, cfg.budget, cap, clock)
                    turn = {"id": row["id"], "scenarioID": scenario, "category": row.get("category"),
                            "followsPrevious": bool(row.get("followsPrevious")), "model": model,
                            "provider": backend.provider, "effort": cfg.effort, "seed": seed, **turn}
                    write_jsonl(tf, turn)
                    records.append(scoring.eval_record(row, turn))
                    n_done += 1
                    say(cfg, f"[{n_done}/{total}] {label} {row['id']}: {turn['outcome']}"
                             f"{' (' + turn['fallbackReason'] + ')' if turn.get('fallbackReason') else ''} "
                             f"{turn['latencyMs'] / 1000:.1f}s ${turn['costUSD']:.4f} (run ${cap.spent_usd:.4f})")
                    if turn.get("spendCapReached"):
                        stopped = "spend_cap"
                        say(cfg, f"STOP {turn['spendCapReached']}")
                        break
                    if turn.get("fatal"):
                        stopped = f"fatal:{turn['fallbackReason']}"
                        say(cfg, f"STOP fatal backend error: {turn['fallbackReason']} {turn.get('detail', '')}")
                        break
            rmeta = {"meta": {"harness": "hallie_e1", "lane": "agent", "model": model, "effort": cfg.effort,
                              "seed": seed, "questions": len(records), "expectedIDs": [r["id"] for r in records],
                              "processReturnCode": 0 if not stopped else 2, "runID": f"{os.path.basename(out)}/{label}",
                              "unmatchedTurns": 0, "corpus": meta["corpus"], "git": meta["git"]}}
            with open(os.path.join(d, "records.jsonl"), "w", encoding="utf-8") as rf:
                write_jsonl(rf, rmeta)
                for r in records:
                    write_jsonl(rf, r)
            card = scoring.summarize(records, bars)
            card.update({"label": label, "model": model, "seed": seed, "effort": cfg.effort, "turnsRun": len(records),
                         "turnsPlanned": len(rows)})
            write_json(os.path.join(d, "summary.json"), card)
            write_text(os.path.join(d, "scorecard.md"),
                       scoring.scorecard_md(f"E1 {label}", card) + "\n## Per row\n\n" + scoring.per_row_md(records))
            all_cards.append(card)

    meta.update({"finished": dt.datetime.now().isoformat(timespec="seconds"), "spentUSD": round(cap.spent_usd, 6),
                 "modelCalls": cap.calls, "stoppedReason": stopped, "capRefusals": cap.refused})
    write_json(os.path.join(out, "run.json"), meta)
    matrix = {"run": os.path.basename(out), "spentUSD": meta["spentUSD"], "stoppedReason": stopped,
              "rows": [{"label": c["label"], "model": c["model"], "seed": c["seed"], **c["overall"]}
                       for c in all_cards]}
    write_json(os.path.join(out, "matrix.json"), matrix)
    write_text(os.path.join(out, "matrix.md"), matrix_md(meta, all_cards))
    say(cfg, f"OUTCOME hallie-e1 {sum(c['turnsRun'] for c in all_cards)} turns, spent ${cap.spent_usd:.4f} of "
             f"${cfg.budget_usd:.2f}{'; STOPPED: ' + stopped if stopped else ''} → {out}/matrix.md")
    return {"out": out, "meta": meta, "cards": all_cards, "backends": backends}


def matrix_md(meta: dict, cards: list) -> str:
    lines = [f"# E1 run {meta.get('started')} — {meta['corpus']} ({meta['turns']} turns)", "",
             f"git {meta.get('git')} · corpus sha {meta['corpusSha256'][:12]} · prices {meta['prices']['asOf']} "
             f"({'verified' if meta['prices']['verified'] else 'ESTIMATE, unverified'}) · derived text "
             f"{meta['derivedText']} · spent ${meta.get('spentUSD', 0):.4f} of ${meta['spendCapUSD']:.2f}"
             + (" · **DRY RUN: scripted fake model; tokens, $ and latency are SIMULATED**" if meta.get("dryRun") else "")
             + (f" · **STOPPED: {meta['stoppedReason']}**" if meta.get("stoppedReason") else ""), "",
             "| model | effort | seed | pattern-clean | wrong-subj | unverified | decline-ok | p50/p95 s | fallbacks | $ |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for c in cards:
        o = c["overall"]
        lat = f"{(o['p50ms'] or 0) / 1000:.1f}/{(o['p95ms'] or 0) / 1000:.1f}" if o.get("p50ms") is not None else "—"
        dc = f"{o['declineCorrectPct']:.0f}%" if o.get("declineCorrectPct") is not None else "—"
        lines.append(f"| {c['model']} | {c['effort']} | {c['seed']} | {o['patternClean']}/{o['rows']} = "
                     f"{o['patternCleanPct']:.0f}% | {o['wrongSubject']} | {o['unverifiedFacts']} | {dc} | {lat} | "
                     f"{o['fallbacks']} | {o['costUSD']:.4f} |")
    lines += ["", "Per category: each `<model>__<effort>__s<n>/scorecard.md`. Judge columns fill in after "
                  "`cli.py judge --run <this folder>`."]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit("use scripts/hallie_e1/cli.py")
