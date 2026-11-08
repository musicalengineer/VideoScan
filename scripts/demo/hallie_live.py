"""Hallie, live and in colour: runs the E1 question set through Hallie's tool loop
on the LOCAL Ollama model and prints each question, every tool call, and the
verified answer as it happens. Nothing leaves the Mac.

  venv/bin/python scripts/demo/hallie_live.py [N] [model]
    N      how many questions (default 12)
    model  ollama tag (default qwen3.8:27b-mlx, Hallie's model)
"""
import sys, os, textwrap, json

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "scripts"))
from hallie_e1 import runner, cli  # noqa: E402

N = sys.argv[1] if len(sys.argv) > 1 else "12"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "qwen3.8:27b-mlx"

R, B, DIM = "\033[0m", "\033[1m", "\033[2m"
CYAN, YEL, GRN, RED, MAG, WHT, BLU = "\033[36m", "\033[33m", "\033[32m", "\033[31m", "\033[35m", "\033[97m", "\033[34m"
W = 100
count = {"n": 0}


def short(d, n=70):
    s = ", ".join(f"{k}={v}" for k, v in (d or {}).items())
    return s if len(s) <= n else s[: n - 1] + "…"


_orig_turn = runner.run_turn


def live_turn(backend, conv, row, toolbox, budget, cap, clock=None):
    count["n"] += 1
    q = row["text"]
    print(f"\n{BLU}{'─' * W}{R}")
    print(f"{B}{CYAN}Q{count['n']}  {q}{R}   {DIM}[{row.get('category', '')}]{R}", flush=True)

    orig_exec = toolbox.execute

    def exec_live(name, inp):
        res, body, secs = orig_exec(name, inp)
        ok = bool(res.get("ok"))
        mark = f"{GRN}✓{R}" if ok else f"{RED}✗ {res.get('error')}{R}"
        n_ids = len(res.get("ids") or [])
        print(f"   {YEL}→ {name}{R}{DIM}({short(inp)}){R}  {mark} {DIM}{n_ids} ids · {secs*1000:.0f} ms{R}", flush=True)
        return res, body, secs

    toolbox.execute = exec_live
    try:
        turn = _orig_turn(backend, conv, row, toolbox, budget, cap, *( [clock] if clock else []))
    finally:
        toolbox.execute = orig_exec

    outcome = turn.get("outcome")
    colour = GRN if outcome == "answered" else (MAG if outcome == "declined" else YEL)
    ans = (turn.get("answer") or "").strip()
    print(f"   {colour}{B}{outcome.upper()}{R} {DIM}{turn['latencyMs']/1000:.1f} s · "
          f"{turn['modelCalls']} model calls · {turn['toolCalls']} tool calls"
          f"{' · ' + turn['fallbackReason'] if turn.get('fallbackReason') else ''}{R}")
    for line in textwrap.wrap(ans, W - 6):
        print(f"   {WHT}{line}{R}")
    ev = turn.get("mediaEvidence") or []
    if ev:
        print(f"   {DIM}evidence: " + ", ".join(e["filename"] for e in ev[:4]) + (" …" if len(ev) > 4 else "") + R)
    sys.stdout.flush()
    return turn


runner.run_turn = live_turn
print(f"{B}{MAG}Hallie, live — {MODEL} on this Mac, her own tools, every answer verified against what the tools returned{R}")
sys.exit(cli.main(["run", "--models", f"ollama:{MODEL}", "--limit", N, "--deadline-s", "180",
                   "--max-model-calls", "8", "--budget-usd", "0.01"]))
